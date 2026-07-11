#!/bin/bash
set -e
set -u

TOOLCHAIN_ROOT=${K230_TOOLCHAIN_ROOT:-/opt/toolchains}

# NOTE: do NOT default ENABLE_TC* here.  entrypoint.sh's resolve_profile()
# (via K230_PROFILE) and download-toolchains own that defaulting; pre-setting
# them to 1 here would make a profile like K230_PROFILE=nuttx unable to
# disable TC1-4.

# ===== TC1: Xuantie-900 gcc 5.10.4 (glibc, bz2) =====
TC1_URLS=${TC1_URLS:-"https://kendryte-download.canaan-creative.com/k230/toolchain/Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0.tar.bz2"}
TC1_VERSION=${TC1_VERSION:-"V2.6.0"}
TC1_DIR=${TC1_DIR:-"Xuantie-900-gcc-linux-5.10.4-glibc-x86_64-V2.6.0"}
TC1_BIN=${TC1_BIN:-"riscv64-unknown-linux-gnu-gcc"}
TC1_BIN_FULL="bin/${TC1_BIN}"
TC1_SHA256=${TC1_SHA256:-"17decb02130b8d79a1eb8c2126e17749fbea603dae7d95f20cd4ab411f3f1a41"}

# ===== TC2: Xuantie-900 gcc 6.6.0 (glibc, gz) =====
TC2_URLS=${TC2_URLS:-"https://kendryte-download.canaan-creative.com/k230/downloads/dl/gcc/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2-20250410.tar.gz"}
TC2_VERSION=${TC2_VERSION:-"V3.0.2"}
TC2_DIR=${TC2_DIR:-"Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2"}
TC2_BIN=${TC2_BIN:-"riscv64-unknown-linux-gnu-gcc"}
TC2_BIN_FULL="bin/${TC2_BIN}"
TC2_SHA256=${TC2_SHA256:-"2215e1ffe1b9b9277b1f5af2f61102e83973163404f29b04da7097fdafa9e1b7"}

# ===== TC3: musl (RT-Smart, bz2) =====
TC3_URLS=${TC3_URLS:-"https://kendryte-download.canaan-creative.com/k230/toolchain/riscv64-unknown-linux-musl-rv64imafdcv-lp64d-20230420.tar.bz2"}
TC3_VERSION=${TC3_VERSION:-"20230420"}
TC3_DIR=${TC3_DIR:-"riscv64-linux-musleabi_for_x86_64-pc-linux-gnu"}
TC3_BIN=${TC3_BIN:-"riscv64-unknown-linux-musl-gcc"}
TC3_BIN_FULL="bin/${TC3_BIN}"
TC3_SHA256=${TC3_SHA256:-"8e09965b2f5d9b6f19d7f552e63d09eb1d217451ba352e5196158e32fb0ee08a"}

# ===== TC4: ILP32 elf (riscv/ subdirectory, gz) =====
TC4_URLS=${TC4_URLS:-"https://github.com/ruyisdk/riscv-gnu-toolchain-rv64ilp32/releases/download/2024.06.25/riscv64ilp32-elf-ubuntu-22.04-gcc-nightly-2024.06.25-nightly.tar.gz"}
TC4_VERSION=${TC4_VERSION:-"2024.06.25"}
TC4_DIR=${TC4_DIR:-"riscv64ilp32-elf-ubuntu-22.04-gcc-nightly-2024.06.25"}
TC4_BIN=${TC4_BIN:-"riscv64-unknown-elf-gcc"}
TC4_BIN_FULL="riscv/bin/${TC4_BIN}"
TC4_SHA256=${TC4_SHA256:-"65cbdaa654890b02bf5d83c8f9a054bbf105126a08bb483d31620890851310bf"}

# ===== TC5: xPack riscv-none-elf bare-metal GCC (NuttX SDK, gz) =====
# NuttX's arch/risc-v cmake auto-detects `riscv-none-elf-gcc`.  We also symlink
# `riscv64-unknown-elf-*` (see download_tc5) so the OpenSBI make
# (CROSS_COMPILE=riscv64-unknown-elf-) and the host baseline both work.
TC5_URLS=${TC5_URLS:-"https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v13.2.0-2/xpack-riscv-none-elf-gcc-13.2.0-2-linux-x64.tar.gz"}
TC5_VERSION=${TC5_VERSION:-"13.2.0-2"}
TC5_DIR=${TC5_DIR:-"xpack-riscv-none-elf-gcc-13.2.0-2"}
TC5_BIN=${TC5_BIN:-"riscv-none-elf-gcc"}
TC5_BIN_FULL="bin/${TC5_BIN}"
TC5_SHA256=${TC5_SHA256:-""}   # optional; fill to enable integrity check

# ===== TC6: LLVM / clang for riscv (NuttX SDK, structure only) =====
# Placeholder slot for the future LLVM switch.  Leave TC6_URLS empty to keep it
# a no-op; when set, NuttX's CLANG toolchain expects `riscv64-unknown-elf-clang`
# / `riscv64-unknown-elf-llvm-*` on PATH (see Toolchain.cmake CLANG branch).
TC6_URLS=${TC6_URLS:-""}
TC6_VERSION=${TC6_VERSION:-"unset"}
TC6_DIR=${TC6_DIR:-"llvm-riscv-none-elf"}
TC6_BIN=${TC6_BIN:-"clang"}
TC6_BIN_FULL="bin/${TC6_BIN}"
TC6_SHA256=${TC6_SHA256:-""}

# ===== Check if toolchain is already installed and valid =====
# Args: DIR, VERSION, BIN (filename only), BIN_FULL (relative path from DIR)
check_toolchain() {
    local DIR=$1
    local VERSION=$2
    local BIN=$3
    local BIN_FULL=$4

    # 1. Check installation flag
    if [ ! -f "$DIR/.installed" ]; then
        echo "[k230] $DIR/.installed not found"
        return 1
    fi

    # 2. Check version file
    if [ ! -f "$DIR/.version" ]; then
        echo "[k230] $DIR/.version not found"
        return 1
    fi

    # 3. Check version match
    local INSTALLED_VERSION
    INSTALLED_VERSION=$(cat "$DIR/.version")
    if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
        echo "[k230] version mismatch: installed=$INSTALLED_VERSION, expected=$VERSION"
        return 1
    fi

    # 4. Check critical binary exists
    if [ ! -f "$DIR/$BIN_FULL" ]; then
        echo "[k230] binary not found: $DIR/$BIN_FULL"
        return 1
    fi

    return 0
}

# ===== Download with fallback (multiple space-separated URLs) =====
download_with_fallback() {
    local URLS=$1
    local OUTPUT=$2

    for url in $URLS; do
        echo "[k230] downloading: $url"
        if curl -L --fail \
                --connect-timeout 30 \
                --retry 20 \
                --retry-delay 5 \
                --show-error \
                -C - -o "$OUTPUT" \
                "$url"; then
            echo "[k230] download success"
            return 0
        fi
        echo "[k230] download failed, trying next source..."
    done

    echo "[k230] error: all download sources failed"
    return 1
}

# ===== Verify SHA256 (optional, skipped if not configured) =====
verify_sha256() {
    local FILE=$1
    local EXPECTED=$2

    [ -z "$EXPECTED" ] && return 0

    local ACTUAL
    ACTUAL=$(sha256sum "$FILE" 2>/dev/null | awk '{print $1}')

    if [ -z "$ACTUAL" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "[k230] error: sha256 mismatch"
        echo "[k230] expected: $EXPECTED"
        echo "[k230] actual:   $ACTUAL"
        return 1
    fi

    echo "[k230] sha256 verified"
    return 0
}

# ===== Install toolchain (generic, handles all 4 TCs) =====
# Args: NAME, VERSION, BIN (filename), BIN_FULL (relative path), URLS, SHA256, DIR_NAME, EXTENSION
install_toolchain() {
    local NAME=$1
    local VERSION=$2
    local BIN=$3
    local BIN_FULL=$4
    local URLS=$5
    local SHA256=$6
    local DIR_NAME=$7
    local EXTENSION=${8:-"bz2"}

    local DIR=$TOOLCHAIN_ROOT/$DIR_NAME
    local TMP=/tmp/${NAME}.tar.${EXTENSION}
    local LOCKFILE="$TOOLCHAIN_ROOT/.lock"

    # Acquire lock to prevent concurrent install of same toolchain
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
        echo "[k230] $NAME is being installed by another process, waiting..."
        flock 9
    fi

    # Check if already installed and valid
    if check_toolchain "$DIR" "$VERSION" "$BIN" "$BIN_FULL"; then
        echo "[k230] $NAME already installed (version=$VERSION)"
        exec 9>&-
        return 0
    fi

    echo "[k230] installing $NAME (version=$VERSION)..."

    # Clean up old installation
    rm -rf "$DIR"
    mkdir -p "$TOOLCHAIN_ROOT"

    # Download
    download_with_fallback "$URLS" "$TMP"

    # Determine extraction command
    local EXTRACT_CMD=""
    case $EXTENSION in
        bz2) EXTRACT_CMD="tar -xjf" ;;
        gz)  EXTRACT_CMD="tar -xzf" ;;
        xz)  EXTRACT_CMD="tar -xJf" ;;
        *)   EXTRACT_CMD="tar -xf" ;;
    esac

    # Determine list flags
    local LIST_FLAGS=""
    case $EXTENSION in
        bz2) LIST_FLAGS="-tjf" ;;
        gz)  LIST_FLAGS="-tzf" ;;
        xz)  LIST_FLAGS="-tJf" ;;
        *)   LIST_FLAGS="-tf" ;;
    esac

    # Detect actual directory name inside tarball
    local EXTRACTED_DIR
    EXTRACTED_DIR=$(tar $LIST_FLAGS "$TMP" 2>/dev/null | head -1 | sed 's|^\./||' | cut -f1 -d"/")
    echo "[k230] extracted dir: $EXTRACTED_DIR"

    # Extract
    $EXTRACT_CMD "$TMP" -C "$TOOLCHAIN_ROOT"

    # Rename to SDK-expected directory name
    if [ -d "$TOOLCHAIN_ROOT/$EXTRACTED_DIR" ]; then
        if [ "$EXTRACTED_DIR" != "$DIR_NAME" ]; then
            mv "$TOOLCHAIN_ROOT/$EXTRACTED_DIR" "$DIR"
            echo "[k230] renamed $EXTRACTED_DIR -> $DIR_NAME"
        else
            echo "[k230] directory already named $DIR_NAME"
        fi
    else
        echo "[k230] error: unexpected directory structure in tarball"
        exit 1
    fi

    # Verify SHA256 (optional)
    if ! verify_sha256 "$TMP" "$SHA256"; then
        echo "[k230] error: integrity check failed"
        exit 1
    fi

    # Write version info
    echo "$VERSION" > "$DIR/.version"
    touch "$DIR/.installed"

    rm -f "$TMP"

    echo "[k230] $NAME installed (version=$VERSION)"
    exec 9>&-
}

# ===== Download functions for each toolchain =====

download_tc1() {
    install_toolchain \
        "tc1-xuantie-5.10.4" \
        "$TC1_VERSION" \
        "$TC1_BIN" \
        "$TC1_BIN_FULL" \
        "$TC1_URLS" \
        "$TC1_SHA256" \
        "$TC1_DIR" \
        "bz2"
}

download_tc2() {
    install_toolchain \
        "tc2-xuantie-6.6.0" \
        "$TC2_VERSION" \
        "$TC2_BIN" \
        "$TC2_BIN_FULL" \
        "$TC2_URLS" \
        "$TC2_SHA256" \
        "$TC2_DIR" \
        "gz"
}

download_tc3() {
    install_toolchain \
        "tc3-musl" \
        "$TC3_VERSION" \
        "$TC3_BIN" \
        "$TC3_BIN_FULL" \
        "$TC3_URLS" \
        "$TC3_SHA256" \
        "$TC3_DIR" \
        "bz2"
}

download_tc4() {
    install_toolchain \
        "tc4-ilp32" \
        "$TC4_VERSION" \
        "$TC4_BIN" \
        "$TC4_BIN_FULL" \
        "$TC4_URLS" \
        "$TC4_SHA256" \
        "$TC4_DIR" \
        "gz"
}

download_tc5() {
    install_toolchain \
        "tc5-nuttx-gcc" \
        "$TC5_VERSION" \
        "$TC5_BIN" \
        "$TC5_BIN_FULL" \
        "$TC5_URLS" \
        "$TC5_SHA256" \
        "$TC5_DIR" \
        "gz"

    # Symlink riscv64-unknown-elf-* -> riscv-none-elf-* so the OpenSBI make
    # (CROSS_COMPILE=riscv64-unknown-elf-) and the host baseline both resolve.
    local bindir="$TOOLCHAIN_ROOT/$TC5_DIR/bin"
    if [ -d "$bindir" ]; then
        local f base alias
        for f in "$bindir"/riscv-none-elf-*; do
            [ -e "$f" ] || continue
            base=$(basename "$f")
            alias="riscv64-unknown-elf-${base#riscv-none-elf-}"
            [ -e "$bindir/$alias" ] || ln -sf "$base" "$bindir/$alias"
        done
        echo "[k230] tc5: riscv64-unknown-elf-* symlinks ready"
    fi
}

download_tc6() {
    if [ -z "$TC6_URLS" ]; then
        echo "[k230] tc6 (LLVM) URL not configured — set TC6_URLS to enable; skipping"
        return 0
    fi
    install_toolchain \
        "tc6-llvm" \
        "$TC6_VERSION" \
        "$TC6_BIN" \
        "$TC6_BIN_FULL" \
        "$TC6_URLS" \
        "$TC6_SHA256" \
        "$TC6_DIR" \
        "${TC6_EXT:-xz}"
}

# ===== Legacy compatibility =====
download_toolchain() {
    local NAME=${1:-}

    case $NAME in
        tc1)  download_tc1 ;;
        tc2)  download_tc2 ;;
        tc3)  download_tc3 ;;
        tc4)  download_tc4 ;;
        tc5)  download_tc5 ;;
        tc6)  download_tc6 ;;
        linux)  download_tc2 ;;
        rtos)   download_tc3 ;;
        nuttx)  download_tc5 ;;
        llvm)   download_tc6 ;;
        all)
            download_tc1
            download_tc2
            download_tc3
            download_tc4
            download_tc5
            ;;
        *)
            echo "[k230] error: unknown toolchain '$NAME'"
            echo "[k230] usage: download_toolchain {tc1|tc2|tc3|tc4|tc5|tc6|linux|rtos|nuttx|llvm|all}"
            return 1
            ;;
    esac
}

# ===== Setup environment variables =====
# Args: NAME (tc1, tc2, tc3, tc4, linux, rtos, all)
setup_env() {
    local NAME=${1:-all}

    case $NAME in
        tc1)
            export K230_LINUX_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC1_DIR
            export PATH=$K230_LINUX_TOOLCHAIN/bin:$PATH
            ;;
        tc2)
            export K230_LINUX_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC2_DIR
            export PATH=$K230_LINUX_TOOLCHAIN/bin:$PATH
            ;;
        tc3)
            export K230_RTOS_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC3_DIR
            export PATH=$K230_RTOS_TOOLCHAIN/bin:$PATH
            ;;
        tc4)
            export K230_ILP32_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC4_DIR
            export PATH=$K230_ILP32_TOOLCHAIN/riscv/bin:$PATH
            ;;
        tc5|nuttx)
            # NuttX bare-metal GCC (riscv-none-elf-, plus riscv64-unknown-elf- symlinks)
            export K230_NUTTX_TOOLCHAIN_DIR=$TOOLCHAIN_ROOT/$TC5_DIR
            export PATH=$K230_NUTTX_TOOLCHAIN_DIR/bin:$PATH
            ;;
        tc6|llvm)
            export K230_LLVM_TOOLCHAIN_DIR=$TOOLCHAIN_ROOT/$TC6_DIR
            export PATH=$K230_LLVM_TOOLCHAIN_DIR/bin:$PATH
            ;;
        linux)
            # linux SDK uses TC2 (6.6.0) as primary
            export K230_LINUX_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC2_DIR
            export PATH=$K230_LINUX_TOOLCHAIN/bin:$PATH
            ;;
        rtos)
            # rtos SDK uses TC3 (musl) as primary
            export K230_RTOS_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC3_DIR
            export PATH=$K230_RTOS_TOOLCHAIN/bin:$PATH
            ;;
        all)
            export K230_LINUX_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC2_DIR
            export K230_RTOS_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC3_DIR
            export K230_ILP32_TOOLCHAIN=$TOOLCHAIN_ROOT/$TC4_DIR
            export K230_NUTTX_TOOLCHAIN_DIR=$TOOLCHAIN_ROOT/$TC5_DIR
            export PATH=$K230_LINUX_TOOLCHAIN/bin:$K230_RTOS_TOOLCHAIN/bin:$K230_ILP32_TOOLCHAIN/riscv/bin:$K230_NUTTX_TOOLCHAIN_DIR/bin:$PATH
            ;;
        *)
            echo "[k230] error: unknown toolchain '$NAME'"
            echo "[k230] usage: setup_env {tc1|tc2|tc3|tc4|tc5|tc6|linux|rtos|nuttx|llvm|all}"
            return 1
            ;;
    esac
}
