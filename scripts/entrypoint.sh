#!/bin/bash
set -e

# Source toolchain functions + profile resolver
source /usr/local/bin/toolchain.sh
source /usr/local/bin/profile.sh

# ============================================
# User mapping configuration
# ============================================
HOST_UID=${HOST_UID:-1000}
HOST_GID=${HOST_GID:-1000}
USERNAME=${USERNAME:-k230}

# ============================================
# Create user if not exists
# ============================================
create_user() {
    # Check if group already exists
    if getent group "$HOST_GID" > /dev/null 2>&1; then
        GROUP_NAME=$(getent group "$HOST_GID" | cut -d: -f1)
    else
        GROUP_NAME="$USERNAME"
        echo "[k230] Creating group: $GROUP_NAME (GID: $HOST_GID)"
        groupadd -g "$HOST_GID" "$GROUP_NAME"
    fi

    # Check if user already exists
    if id "$HOST_UID" > /dev/null 2>&1; then
        USERNAME=$(id -un "$HOST_UID")
        echo "[k230] User already exists: $USERNAME (UID: $HOST_UID)"
    else
        echo "[k230] Creating user: $USERNAME (UID: $HOST_UID, GID: $HOST_GID)"
        useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash "$USERNAME"
    fi
}

# ============================================
# Setup SSH keys and Git config from host
# ============================================
setup_host_config() {
    local home_dir
    home_dir=$(getent passwd "$HOST_UID" | cut -d: -f6)

    # SSH: copy keys from host mount to user home
    if [ -d /tmp/host-ssh ] && [ -n "$(ls -A /tmp/host-ssh 2>/dev/null)" ]; then
        mkdir -p "$home_dir/.ssh"
        cp -r /tmp/host-ssh/* "$home_dir/.ssh/"
        chmod 700 "$home_dir/.ssh"
        chmod 600 "$home_dir/.ssh"/* 2>/dev/null || true
        chown -R "$HOST_UID:$HOST_GID" "$home_dir/.ssh"
        echo "[k230] SSH keys loaded from host"
    fi

    # Git config: copy from host mount to user home
    if [ -f /tmp/host-gitconfig ]; then
        cp /tmp/host-gitconfig "$home_dir/.gitconfig"
        chown "$HOST_UID:$HOST_GID" "$home_dir/.gitconfig"
        echo "[k230] Git config loaded from host"
    fi
}

# ============================================
# Initialize toolchains
# ============================================
# (resolve_profile is defined in scripts/profile.sh, sourced above)
init_toolchains() {
    [ "$ENABLE_TC1" = "1" ] && download_tc1
    [ "$ENABLE_TC2" = "1" ] && download_tc2
    [ "$ENABLE_TC3" = "1" ] && download_tc3
    [ "$ENABLE_TC4" = "1" ] && download_tc4
    [ "$ENABLE_TC5" = "1" ] && download_tc5
    [ "$ENABLE_TC6" = "1" ] && download_tc6
    return 0
}

# ============================================
# Setup environment
# ============================================
k230_setup_env() {
    # Set HOME/USER/LOGNAME for correct gosu behavior
    HOME=$(getent passwd "$HOST_UID" | cut -d: -f6)
    export HOME
    export USER="$USERNAME"
    export LOGNAME="$USERNAME"

    # TC1: xuantie-5.10.4
    if [ -d "/opt/toolchains/Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0/bin" ]; then
        export PATH="/opt/toolchains/Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0/bin:$PATH"
    fi
    # TC2: xuantie-6.6.0
    if [ -d "/opt/toolchains/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2/bin" ]; then
        export PATH="/opt/toolchains/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2/bin:$PATH"
    fi
    # TC3: musl
    if [ -d "/opt/toolchains/riscv64-linux-musleabi_for_x86_64-pc-linux-gnu/bin" ]; then
        export PATH="/opt/toolchains/riscv64-linux-musleabi_for_x86_64-pc-linux-gnu/bin:$PATH"
    fi
    # TC4: ilp32 (bin dir is under riscv/ subdirectory)
    if [ -d "/opt/toolchains/riscv64ilp32-elf-ubuntu-22.04-gcc-nightly-2024.06.25/riscv/bin" ]; then
        export PATH="/opt/toolchains/riscv64ilp32-elf-ubuntu-22.04-gcc-nightly-2024.06.25/riscv/bin:$PATH"
    fi
    # TC5: NuttX bare-metal GCC (riscv-none-elf- + riscv64-unknown-elf- symlinks)
    if [ -d "/opt/toolchains/xpack-riscv-none-elf-gcc-13.2.0-2/bin" ]; then
        export PATH="/opt/toolchains/xpack-riscv-none-elf-gcc-13.2.0-2/bin:$PATH"
    fi
    # TC6: LLVM / clang (structure only; present once TC6 is configured)
    if [ -d "/opt/toolchains/llvm-riscv-none-elf/bin" ]; then
        export PATH="/opt/toolchains/llvm-riscv-none-elf/bin:$PATH"
    fi

    # Ensure workspace directory exists and has correct ownership
    mkdir -p /workspace
    chown "$HOST_UID:$HOST_GID" /workspace
}

# ============================================
# Main execution
# ============================================
create_user

setup_host_config

# Resolve K230_PROFILE -> ENABLE_TC* (exported; inherited by the
# download-toolchains exec below and by init_toolchains).
resolve_profile

# When a profile is explicitly requested, auto-provision its toolchains so
# `K230_PROFILE=nuttx k230 west build` works in one shot.  With no profile
# (legacy), provisioning stays on-demand via `k230 download-toolchains`.
# Skip auto-provision for the toolchain management commands themselves.
case "${1:-}" in
    download-toolchains|list-toolchains) ;;
    *) [ -n "${K230_PROFILE:-}" ] && init_toolchains ;;
esac

# (Re)build PATH now that any freshly-downloaded toolchains exist on disk.
k230_setup_env

case "${1:-}" in
    download-toolchains|list-toolchains)
        exec /usr/local/bin/"$1" "${@:2}"
        ;;
esac

echo "[k230] Switching to user: $USERNAME"
if [ $# -eq 0 ]; then
    exec gosu "$HOST_UID:$HOST_GID" env \
        HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH="$PATH" \
        bash
else
    exec gosu "$HOST_UID:$HOST_GID" env \
        HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH="$PATH" \
        "$@"
fi
