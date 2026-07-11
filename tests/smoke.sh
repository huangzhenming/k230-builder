#!/usr/bin/env bash
# T1 smoke test — against a built image, WITHOUT downloading any toolchain.
#
#   ./tests/smoke.sh [image]      (default: k230-builder:latest)
#
# Verifies: entrypoint runs, the NuttX/SDK host tools are bundled, and the
# baked profile.sh resolves K230_PROFILE correctly.  No K230_PROFILE is set for
# the tool check, so the entrypoint does NOT auto-provision toolchains (fast).

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
if ! docker run --rm "${UIDGID[@]}" "$IMAGE" bash -c '
set -e
for t in west cmake ninja dtc genromfs gperf xxd; do
    command -v "$t" >/dev/null || { echo "MISSING: $t"; exit 1; }
done
python3 -c "import kconfiglib, Crypto, gmssl" || { echo "MISSING: a python module (kconfiglib/Crypto/gmssl)"; exit 1; }
echo "  ok: $(west --version | tr -d "\n") / $(cmake --version | head -1)"
'; then
    echo "[smoke] FAIL: bundled tool check"; exit 1
fi

echo "[smoke] 2/3 profile.sh resolves K230_PROFILE=nuttx -> only TC5"
sig=$(docker run --rm -e K230_PROFILE=nuttx --entrypoint bash "$IMAGE" -c '
    source /usr/local/bin/profile.sh
    resolve_profile >/dev/null 2>&1
    printf "%s%s%s%s%s%s" "$ENABLE_TC1" "$ENABLE_TC2" "$ENABLE_TC3" "$ENABLE_TC4" "$ENABLE_TC5" "$ENABLE_TC6"')
[ "$sig" = "000010" ] || { echo "[smoke] FAIL: nuttx profile sig=$sig want=000010"; exit 1; }
echo "  ok: nuttx -> $sig"

echo "[smoke] 3/3 list-toolchains advertises TC5/TC6"
docker run --rm --entrypoint list-toolchains "$IMAGE" | grep -q "TC5" \
    || { echo "[smoke] FAIL: list-toolchains missing TC5"; exit 1; }
echo "  ok"

echo "[smoke] PASS"
