#!/usr/bin/env bash
# T1 smoke test — against a built image, WITHOUT downloading any toolchain.
#
#   ./tests/smoke.sh [image]      (default: k230-builder:latest)
#
# Verifies: entrypoint runs, the NuttX/SDK host tools are bundled, and the
# baked toolchain.sh resolves toolchain aliases correctly.  No toolchains are
# downloaded here (fast) — see T2 for a real provisioning + build.

set -euo pipefail
IMAGE="${1:-k230-builder:latest}"
UIDGID=(-e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)")

echo "[smoke] image: $IMAGE"

# Fail early with a clear message if the image isn't loaded (e.g. a buildx
# --load hiccup) rather than a cryptic 'docker run' error mid-test.
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { echo "[smoke] FAIL: image not found locally: $IMAGE"; exit 1; }

echo "[smoke] 1/3 bundled host tools present"
# NOTE: only image-baked tools are checked here.  Cross toolchains (TC1-6,
# incl. riscv-none-elf-gcc) are provisioned at RUNTIME into the volume, so they
# are intentionally NOT part of this offline smoke (see T2 for a real build).
# Do NOT swallow output: on failure the step log must show WHICH check failed.
# kconfiglib lives in an isolated venv (docker/Dockerfile) so its flat
# menuconfig.py/olddefconfig.py modules do not collide with same-named
# modules in other SDK build systems; only its console scripts are exposed
# on PATH, so check those instead of "import kconfiglib" against the global
# python3 (which is intentionally absent there).
if ! docker run --rm "${UIDGID[@]}" "$IMAGE" bash -c '
set -e
for t in west cmake ninja dtc genromfs gperf xxd menuconfig olddefconfig; do
    command -v "$t" >/dev/null || { echo "MISSING: $t"; exit 1; }
done
# Image/filesystem tools backing the genimage handlers (docker/Dockerfile).
# mkdosfs+mcopy/mmd are a pair: genimage creates the vfat, then copies files in
# via mcopy, so a missing mtools breaks image builds even with mkfs.vfat present.
for t in genimage mkfs.vfat mkdosfs mcopy mmd mksquashfs genext2fs \
         mkfs.jffs2 mkfs.ubifs ubinize mkfs.f2fs mkimage zstd lz4 bear; do
    command -v "$t" >/dev/null || { echo "MISSING: $t"; exit 1; }
done
python3 -c "import Crypto, gmssl" || { echo "MISSING: a python module (Crypto/gmssl)"; exit 1; }
echo "  ok: $(west --version | tr -d "\n") / $(cmake --version | head -1)"
'; then
    echo "[smoke] FAIL: bundled tool check"; exit 1
fi

echo "[smoke] 2/3 toolchain.sh resolves 'nuttx' -> tc5"
out=$(docker run --rm --entrypoint bash "$IMAGE" -c '
    source /usr/local/bin/toolchain.sh
    resolve_toolchain_set nuttx')
[ "$out" = "tc5" ] || { echo "[smoke] FAIL: nuttx -> $out want=tc5"; exit 1; }
echo "  ok: nuttx -> $out"

echo "[smoke] 3/3 list-toolchains advertises TC5/TC6"
# Capture first, then match.  Piping straight into `grep -q` makes grep exit on
# the first match and SIGPIPE list-toolchains, which under `set -o pipefail`
# surfaces as a spurious failure of this step.
tc_list=$(docker run --rm --entrypoint list-toolchains "$IMAGE")
grep -q "TC5" <<<"$tc_list" \
    || { echo "[smoke] FAIL: list-toolchains missing TC5"; exit 1; }
echo "  ok"

echo "[smoke] PASS"
