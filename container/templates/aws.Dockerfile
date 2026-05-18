{#
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#}
# === BEGIN templates/aws.Dockerfile ===
#############################
########## AWS EFA ##########
#############################
#
# This stage extends the runtime/dev stage with the AWS EFA userspace stack:
#   1. AWS EFA installer (libfabric + aws-ofi-nccl plugin) — stock binaries
#   2. Upstream ofiwg/libfabric (v2.5.1 by default) installed OVER the stock
#      binary — carries the CUDA dmabuf MR fix that makes fi_mr_reg succeed
#      when registering VRAM on GB200 EFA hardware. Without this, the EFA
#      installer's stock libfabric (and aws/libfabric forks < v2.5) falls
#      through to ibv_reg_mr() with a GPU VA and returns EFAULT on aws-64k.
#
# Use this stage when deploying on AWS infrastructure with EFA support
# (p6e-gb200, p5e, p5, p4d).

FROM ${EFA_BASE_IMAGE} AS aws

ARG EFA_VERSION
ARG PATCHED_LIBFABRIC_REPO
ARG PATCHED_LIBFABRIC_REF

{% if target == "runtime" %}
USER root
{% endif %}

# Install AWS EFA installer with bundled libfabric and aws-ofi-nccl
# Flags explanation:
#   --skip-kmod: Skip kernel module installation (handled by host)
#   --skip-limit-conf: Skip ulimit configuration (handled by container runtime)
#   --no-verify: Skip GPG verification (optional, can be removed if verification is needed)
# Cache apt downloads; sharing=locked avoids apt/dpkg races with concurrent builds.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    mkdir -p /tmp/efa && \
    cd /tmp/efa && \
    curl --retry 3 --retry-delay 2 -fsSL -o aws-efa-installer-${EFA_VERSION}.tar.gz \
        https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_VERSION}.tar.gz && \
    tar -xf aws-efa-installer-${EFA_VERSION}.tar.gz && \
    cd aws-efa-installer && \
    apt-get update && \
    ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify && \
    rm -rf /tmp/efa && \
    # Disable the EFA installer's aws-ofi-nccl plugin: it crashes TRT-LLM at engine init.
    # The plugin is installed at /opt/amazon/ofi-nccl (no `aws-` prefix), but ld.so picks
    # it up via /etc/ld.so.conf.d/aws-ofi-nccl.conf (which DOES carry the `aws-` prefix).
    # Remove both, and also the cuda-dl-base location /opt/amazon/aws-ofi-nccl if present,
    # before re-running ldconfig.
    rm -rf /opt/amazon/aws-ofi-nccl /opt/amazon/ofi-nccl \
           /etc/ld.so.conf.d/aws-ofi-nccl.conf && \
    ldconfig

# Overlay upstream libfabric (built in the wheel_builder stage) onto the EFA installer's
# stock binary.
#
# EFA installer releases through 1.48.x ship pre-v2.5 libfabric in the
# 2.4.0amzn{1,3}.x line. We pin EFA_VERSION to 1.46.x/1.47.x in context.yaml
# because 1.48.0 has a separate Ubuntu 24.04 packaging issue (libfabric1-aws
# requires ibverbs-providers >= 59; Ubuntu 24.04 ships 50.x). All of these
# pre-v2.5 versions share the same bug: their CUDA HMEM path falls through
# to ibv_reg_mr() with a GPU virtual address and fails with EFAULT on GB200
# VRAM registration. ofiwg/libfabric v2.5.x carries the fix —
# "prov/efa: Implement dmabuf try/fallback logic"
# (commit c9e3c0c1bc5474b96b4e08498f35810ba6bddad2) — which adds CUDA to the
# dmabuf-fast-path with a robust ibv_reg_mr fallback. No sed-patch needed.
#
# The patched libfabric is built in wheel_builder (see wheel_builder.Dockerfile)
# at /opt/amazon/efa-patched/ and bind-mounted here. Bind-mount (not COPY)
# keeps the build deps and intermediate artifacts out of the runtime image's
# layers — only the resulting .so + fi_info land in the final image.
#
# The EFA installer's libfabric.so.1 symlink may not match the patched build's
# SONAME, so apps using SONAME-based resolution can still load the stock binary
# unless we force the symlink. We update the symlink in BOTH /opt/amazon/efa/lib
# and /opt/amazon/efa/lib64 (EFA installer can populate either depending on
# distro) AND delete any pre-existing versioned libfabric binaries that don't
# match our just-built one. Validation: fi_info --version must report the
# patched libfabric version at runtime — fail the build if not.
RUN --mount=type=bind,from=wheel_builder,source=/opt/amazon/efa-patched,target=/tmp/patched-libfabric \
    set -e && \
    # Overlay patched .so files (symlinks + versioned .so) into both possible lib dirs.
    cp -Pf /tmp/patched-libfabric/lib/libfabric.so* /opt/amazon/efa/lib/ && \
    if [ -d /opt/amazon/efa/lib64 ]; then \
        cp -Pf /tmp/patched-libfabric/lib/libfabric.so* /opt/amazon/efa/lib64/; \
    fi && \
    # Overlay fi_info (its --version output is the validation signal below).
    cp -f /tmp/patched-libfabric/bin/fi_info /opt/amazon/efa/bin/fi_info && \
    # Force libfabric.so.1 SONAME to point at the patched binary in BOTH lib dirs,
    # and delete any pre-existing versioned binaries that aren't our just-built one
    # (defends against apps with hardcoded RPATHs resolving to a stock 1.x.y file).
    PATCHED_SONAME=$(basename "$(readlink /opt/amazon/efa/lib/libfabric.so)") && \
    [ -n "${PATCHED_SONAME}" ] || { echo "ERROR: could not resolve patched libfabric SONAME via /opt/amazon/efa/lib/libfabric.so" >&2; exit 1; } && \
    for libdir in /opt/amazon/efa/lib /opt/amazon/efa/lib64; do \
        [ -d "$libdir" ] || continue; \
        if [ -f "$libdir/$PATCHED_SONAME" ]; then \
            ln -sfT "$PATCHED_SONAME" "$libdir/libfabric.so.1"; \
        else \
            ln -sfT "/opt/amazon/efa/lib/$PATCHED_SONAME" "$libdir/libfabric.so.1"; \
        fi; \
        for f in "$libdir"/libfabric.so.1.*; do \
            base=$(basename "$f"); \
            if [ -e "$f" ] && [ "$base" != "$PATCHED_SONAME" ]; then \
                rm -f "$f"; \
            fi; \
        done; \
    done && \
    ldconfig && \
    # Validate runtime libfabric is the patched build. Fail the build if not.
    if ! /opt/amazon/efa/bin/fi_info --version 2>&1 | grep -q "^libfabric: ${PATCHED_LIBFABRIC_REF#v}"; then \
        echo "ERROR: runtime libfabric did not resolve to patched ${PATCHED_LIBFABRIC_REF}" >&2; \
        /opt/amazon/efa/bin/fi_info --version >&2 || true; \
        exit 1; \
    fi && \
    echo "[aws] runtime libfabric verified as patched ${PATCHED_LIBFABRIC_REF}"

ENV EFA_VERSION="${EFA_VERSION}"
ENV PATCHED_LIBFABRIC_VERSION="${PATCHED_LIBFABRIC_REF}"

{% if framework == "trtllm" %}
# Override the upstream trtllm_runtime stage's LD_PRELOAD / NIXL_PLUGIN_DIR
# workaround for ai-dynamo/nixl#1668. That workaround force-loads TRT-LLM's
# bundled NIXL 0.9.0 to dodge a UCX 1.20.0 hang in nixl-cu13 0.10.1, but
# TRT-LLM's bundled NIXL plugins directory does NOT ship libplugin_LIBFABRIC.so —
# so the LIBFABRIC backend has no plugin to load and the EFA / VRAM-RDMA path is
# unusable with the upstream defaults.
#
# For --make-efa images, point NIXL_PLUGIN_DIR back at Dynamo's wheel_builder-
# built NIXL 0.10.1 (which DOES ship libplugin_LIBFABRIC.so, built against the
# overlaid libfabric in this stage) and drop LD_PRELOAD so the dynamic linker
# picks Dynamo's libnixl.so via the standard ldconfig order.
#
# Trade-off: this exposes the image to ai-dynamo/nixl#1668's UCX 1.20.0 hang
# IF the deployment uses the UCX backend with two NIXL agents on the same host.
# The LIBFABRIC backend goes through libfabric directly (not UCX), so it is
# unaffected — and LIBFABRIC is the recommended backend for EFA anyway
# (TRTLLM_NIXL_KVCACHE_BACKEND=LIBFABRIC). Drop this block once the upstream
# UCX-hang fix lands and the LD_PRELOAD workaround is removed from
# trtllm_runtime.Dockerfile.
ENV LD_PRELOAD=""
ENV NIXL_PLUGIN_DIR=/opt/nvidia/nvda_nixl/lib64/plugins
{% endif %}

{% if target == "runtime" %}
USER dynamo
{% endif %}

ENTRYPOINT ["/opt/nvidia/nvidia_entrypoint.sh"]
CMD []
