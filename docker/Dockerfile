# K230 Docker Image (Single Image - 4 Toolchains)
#
# Design: Single image, users control which toolchains to download at runtime
# via `k230 download-toolchains <name ..>`.
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

# NOTE: which toolchains get provisioned is decided at RUNTIME, by explicitly
# running `k230 download-toolchains <TC1..TC6|linux|rtos|nuttx|...>` — NOT
# baked in here.

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
    python3-dev \
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
    # .NET dependency (SDK itself installed via dotnet-install.sh below) +
    # uuid headers required by the nncase host GNNE simulator build
    libicu-dev \
    uuid-dev \
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
#  - west: NuttX SDK entry point (CMake build)
#  - gmssl/pycryptodome: K230 image signing (west image)
#  - conan: nncase C++ dependency manager (pinned to the version nncase v2.11 uses)
RUN pip3 install --no-cache-dir \
    west \
    gmssl \
    pycryptodome \
    jsonschema \
    jinja2 \
    conan==2.6.0 \
    numpy \
    build \
    cibuildwheel

# kconfiglib (NuttX's Kconfig frontend) ships flat top-level modules
# (menuconfig.py, olddefconfig.py, ...) that, if installed into the global
# site-packages, collide with other SDKs' own same-named modules — e.g. the
# RTOS/RT-Smart SDK's `rt-thread/tools/menuconfig.py` (imported via `from
# menuconfig import mk_rtconfig`). Since RT-Thread appends rather than
# prepends its tools/ dir to sys.path, the global kconfiglib module would
# win that import and break the RTOS build. Isolate kconfiglib in its own
# venv, and symlink only its console scripts (not its python3/pip, which
# would otherwise shadow the system python3 on PATH) into /usr/local/bin —
# that's all NuttX's build needs, since it locates them via `command -v
# menuconfig`. The venv's site-packages never appears in any other build's
# sys.path.
RUN python3 -m venv /opt/kconfiglib-venv && \
    /opt/kconfiglib-venv/bin/pip install --no-cache-dir kconfiglib && \
    for tool in menuconfig guiconfig oldconfig olddefconfig alldefconfig \
                allnoconfig allyesconfig allmodconfig defconfig genconfig \
                listnewconfig savedefconfig setconfig; do \
        ln -s "/opt/kconfiglib-venv/bin/$tool" "/usr/local/bin/$tool"; \
    done

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

# .NET SDK 7.0.302 — matches nncase v2.11 CI; required to build the nncase C#
# compiler (dotnet build/restore). The SDK bundles the runtime, so no separate
# dotnet-runtime package is needed.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    bash /tmp/dotnet-install.sh --version 7.0.302 --install-dir /opt/dotnet && \
    rm -f /tmp/dotnet-install.sh
ENV DOTNET_ROOT=/opt/dotnet
ENV PATH=/opt/dotnet:${PATH}
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_NUGET_SIGNATURE_VERIFICATION=false

# Newer CMake for nncase: conan 2.6 emits CMakePresets requiring cmake >= 3.25,
# but the apt cmake (3.22) is what the K230 SDK builds use and expect. To avoid
# changing SDK behavior we install a modern cmake side-by-side at /opt/cmake and
# leave it OFF the default PATH; the `nncase` CLI prepends /opt/cmake/bin itself.
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz -o /tmp/cmake.tar.gz && \
    mkdir -p /opt/cmake && tar -xzf /tmp/cmake.tar.gz -C /opt/cmake --strip-components=1 && \
    rm -f /tmp/cmake.tar.gz && \
    /opt/cmake/bin/cmake --version

# nncase build caches (conan packages + NuGet packages) live inside the
# persistent /opt/toolchains volume, so third-party deps download once and are
# reused across container runs (which are --rm and otherwise lose the caches).
ENV CONAN_HOME=/opt/toolchains/.conan2
ENV NUGET_PACKAGES=/opt/toolchains/.nuget

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
COPY scripts/download-toolchains /usr/local/bin/download-toolchains
COPY scripts/list-toolchains /usr/local/bin/list-toolchains
COPY scripts/nncase /usr/local/bin/nncase
RUN chmod +x /entrypoint.sh \
    /usr/local/bin/toolchain.sh \
    /usr/local/bin/download-toolchains \
    /usr/local/bin/list-toolchains \
    /usr/local/bin/nncase

ENTRYPOINT ["/entrypoint.sh"]
