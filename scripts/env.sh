#!/bin/bash
# =========================
# scripts/env.sh
# Sourceable environment setup for all 4 K230 toolchains
# Usage: source /usr/local/bin/env.sh
# =========================

# Toolchain root (can be overridden before sourcing)
K230_TOOLCHAIN_ROOT="${K230_TOOLCHAIN_ROOT:-/opt/toolchains}"

# SDK compatibility (used by RTOS SDK mkenv.mk)
export SDK_TOOLCHAIN_DIR=/opt/toolchain

# ---- TC1: xuantie-5.10.4 ----
export K230_TC1_DIR="${K230_TC1_DIR:-$K230_TOOLCHAIN_ROOT/Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0}"

# ---- TC2: xuantie-6.6.0 (Linux SDK default) ----
export K230_TC2_DIR="${K230_TC2_DIR:-$K230_TOOLCHAIN_ROOT/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2}"

# ---- TC3: musl ----
export K230_TC3_DIR="${K230_TC3_DIR:-$K230_TOOLCHAIN_ROOT/riscv64-linux-musleabi_for_x86_64-pc-linux-gnu}"

# ---- TC4: ilp32 (bin lives under riscv/ subdirectory) ----
export K230_TC4_DIR="${K230_TC4_DIR:-$K230_TOOLCHAIN_ROOT/riscv64ilp32-elf-ubuntu-22.04-gcc-nightly-2024.06.25}"

# ---- TC5: NuttX bare-metal GCC (xPack riscv-none-elf) ----
export K230_TC5_DIR="${K230_TC5_DIR:-$K230_TOOLCHAIN_ROOT/xpack-riscv-none-elf-gcc-13.2.0-2}"

# ---- TC6: LLVM / clang (NuttX SDK, structure only) ----
export K230_TC6_DIR="${K230_TC6_DIR:-$K230_TOOLCHAIN_ROOT/llvm-riscv-none-elf}"

# ---- Legacy aliases for backward compatibility ----
export K230_LINUX_TOOLCHAIN="$K230_TC2_DIR"
export K230_RTOS_TOOLCHAIN="$K230_TC3_DIR"
export K230_NUTTX_TOOLCHAIN_DIR="$K230_TC5_DIR"

# ---- Build PATH (only add if directory exists) ----
_add_path() {
    if [ -d "$1" ]; then
        export PATH="$1:$PATH"
    fi
}

_add_path "$K230_TC1_DIR/bin"
_add_path "$K230_TC2_DIR/bin"
_add_path "$K230_TC3_DIR/bin"
_add_path "$K230_TC4_DIR/riscv/bin"
_add_path "$K230_TC5_DIR/bin"
_add_path "$K230_TC6_DIR/bin"

# =========================
# example docker run
# =========================
# docker run -it \
#   -e HOST_UID=$(id -u) \
#   -e HOST_GID=$(id -g) \
#   -v k230_toolchains:/opt/toolchains \
#   -v $(pwd):/workspace \
#   -w /workspace \
#   ghcr.io/huangzhenming/k230-builder:latest
