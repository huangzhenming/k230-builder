#!/usr/bin/env bash
# T2 toolchain provisioning test — through the real `k230` CLI.
#
#   K230_CI_IMAGE=k230-builder:regression ./tests/t2-toolchains.sh
#
# `k230 download-toolchains all` downloads TC1/TC2/TC3/TC5 into the CI volume
# (sha256-verified by toolchain.sh; ~5GB on first run, then cached).
# Each toolchain then cross-compiles hello.c and its own readelf asserts a
# RISC-V ELF, so a bad URL/sha/extracted layout fails loudly here instead of
# midway through a 1-hour SDK build.
#
# Env: K230_CI_IMAGE  (default k230-builder:latest — must exist locally)
#      K230_CI_VOLUME (default k230_toolchains_ci)

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

IMAGE="${K230_CI_IMAGE:-k230-builder:latest}"
VOLUME="${K230_CI_VOLUME:-k230_toolchains_ci}"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { echo "[t2] FAIL: image not found locally: $IMAGE (run the 'image' stage first)"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/hello.c" <<'EOF'
int main(void) { return 42; }
EOF

# Runs inside the container AFTER `download-toolchains all` has provisioned the
# toolchains. TCx_DIR come from the image's own toolchain.sh (definitions
# only), so this never drifts from what the image actually installs. TC1/TC2
# share a binary name, so every gcc is invoked by absolute path.
cat > "$WORK/check.sh" <<'EOF'
set -eu
source /usr/local/bin/toolchain.sh
root=/opt/toolchains
rc=0

check() { # label  gcc-abs-path  link|obj
    local label="$1" gcc="$2" mode="$3" out
    echo "== $label =="
    [ -x "$gcc" ] || { echo "FAIL($label): missing $gcc"; rc=1; return 0; }
    "$gcc" --version | head -1
    out="/tmp/hello-$label"
    if [ "$mode" = link ]; then
        "$gcc" hello.c -o "$out" || { echo "FAIL($label): compile+link"; rc=1; return 0; }
    else # bare-metal: object only (linking needs a target linker script)
        "$gcc" -c hello.c -o "$out" || { echo "FAIL($label): compile"; rc=1; return 0; }
    fi
    "${gcc%-gcc}-readelf" -h "$out" | grep -q "RISC-V" \
        || { echo "FAIL($label): output is not a RISC-V ELF"; rc=1; return 0; }
    echo "ok($label)"
}

check tc1 "$root/$TC1_DIR/bin/riscv64-unknown-linux-gnu-gcc"  link
check tc2 "$root/$TC2_DIR/bin/riscv64-unknown-linux-gnu-gcc"  link
check tc3 "$root/$TC3_DIR/bin/riscv64-unknown-linux-musl-gcc" link
check tc5 "$root/$TC5_DIR/bin/riscv-none-elf-gcc"             obj

# OpenSBI builds with CROSS_COMPILE=riscv64-unknown-elf-, served by TC5 symlinks
[ -x "$root/$TC5_DIR/bin/riscv64-unknown-elf-gcc" ] \
    || { echo "FAIL(tc5): riscv64-unknown-elf-gcc alias symlink missing"; rc=1; }

exit $rc
EOF

echo "[t2] image: $IMAGE  volume: $VOLUME"
echo "[t2] provisioning toolchains via 'download-toolchains all' (cached in volume after first run)"
cd "$WORK"
K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
    "$REPO/k230" download-toolchains all
K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
    "$REPO/k230" bash check.sh

echo "[t2] PASS"
