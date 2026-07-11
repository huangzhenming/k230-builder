# K230 Docker Image (Single Image - 4 Toolchains)
#
# Design: Single image, users control which toolchains to download at runtime
# via ENABLE_TC{1-4} build args or environment variables.
#
# Toolchains:
#   TC1: Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0 (RTOS U-Boot/OpenSBI)
#   TC2: Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2 (Linux SDK main)
#   TC3: riscv64-linux-musleabi (RTOS RT-Smart)
#   TC4: riscv64ilp32-elf (Linux ILP32 kernel)
#
# Build:
#   docker build -t k230-builder:latest -f docker/Dockerfile .
#
# Run:
#   docker run --rm -it -v k230_toolchains:/opt/toolchains k230-builder:latest bash

FROM ubuntu:22.04

# NOTE: which toolchains get provisioned is decided at RUNTIME by
# entrypoint.sh's resolve_profile() (K230_PROFILE + ENABLE_TC* env), NOT baked
# in here.  Baking ENABLE_TC*=1 as image ENV would make it look "user-set" and
# stop a profile (e.g. K230_PROFILE=nuttx) from disabling TC1-4.

ENV DEBIAN_FRONTEND=noninteractive

# Install packages based on official kendryte Dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    openssh-client \
    wget \
    curl \
    python3 \
    python3-pip \
    python-is-python3 \
    python3-venv \
    ninja-build \
    bzip2 \
    gzip \
    gosu \
    # Core build tools (from kendryte)
    make \
    patch \
    perl \
    tar \
    cpio \
    unzip \
    rsync \
    file \
    bc \
    findutils \
    sed \
    binutils \
    diffutils \
    bash \
    # Libraries
    libncurses-dev \
    libssl-dev \
    # Parser generators
    bison \
    flex \
    # Extra utilities
    gawk \
    bash-completion \
    parted \
    scons \
    # .NET Runtime (for nncase v2)
    dotnet-runtime-7.0 \
    libicu-dev \
    # Docker CLI (mount /var/run/docker.sock at runtime)
    docker.io \
    # genimage dependencies
    libconfuse-dev \
    libffi-dev \
    pkg-config \
    xz-utils \
    # NuttX SDK build deps (Kconfig/ROMFS/device-tree/gperf/xxd)
    genromfs \
    device-tree-compiler \
    gperf \
    xxd \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages for K230 SDK
#  - west + kconfiglib: NuttX SDK entry point + Kconfig frontend (CMake build)
#  - gmssl/pycryptodome: K230 image signing (west image)
RUN pip3 install --no-cache-dir \
    west \
    kconfiglib \
    gmssl \
    pycryptodome \
    jsonschema \
    jinja2

# Install repo tool from Google
RUN mkdir -p /opt/repo && \
    curl -s https://storage.googleapis.com/git-repo-downloads/repo > /opt/repo/repo && \
    chmod +x /opt/repo/repo && \
    mv /opt/repo/repo /usr/local/bin/

# Install genimage (required for building K230 images)
RUN wget -q https://github.com/pengutronix/genimage/releases/download/v16/genimage-16.tar.xz -O /tmp/genimage.tar.xz && \
    cd /tmp && tar -xf genimage.tar.xz && \
    cd genimage-16 && \
    ./configure && make -j$(nproc) && make install && \
    cd / && rm -rf /tmp/genimage*

# Toolchain paths (SDK compatible)
# Create symlink for SDK compatibility (/opt/toolchain -> /opt/toolchains)
RUN ln -sf /opt/toolchains /opt/toolchain
ENV SDK_TOOLCHAIN_DIR=/opt/toolchain
ENV K230_TOOLCHAIN_ROOT=/opt/toolchains

# Create mount points
RUN mkdir -p /opt/toolchains

VOLUME ["/opt/toolchains"]

# Copy scripts
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/toolchain.sh /usr/local/bin/toolchain.sh
COPY scripts/profile.sh /usr/local/bin/profile.sh
COPY scripts/download-toolchains /usr/local/bin/download-toolchains
COPY scripts/list-toolchains /usr/local/bin/list-toolchains
COPY scripts/env.sh /usr/local/bin/env.sh
RUN chmod +x /entrypoint.sh \
    /usr/local/bin/toolchain.sh \
    /usr/local/bin/profile.sh \
    /usr/local/bin/download-toolchains \
    /usr/local/bin/list-toolchains \
    /usr/local/bin/env.sh

ENTRYPOINT ["/entrypoint.sh"]
