#!/usr/bin/env bash
# T3 SDK build test — build one SDK through the real `k230` CLI and assert a
# fresh image artifact appeared.
#
#   ./tests/t3-sdk.sh <linux|rtos|nuttx>
#
# The assertion is deliberately artifact-only (a file matching the glob,
# above a size floor, that's either freshly written this run or was already
# present before the build): SDK builds are not reproducible, so byte
# comparison would only produce false alarms. "Already present" is accepted
# too because SDK checkouts persist across CI runs — an unchanged source
# tree legitimately produces an incremental no-op build that never touches
# its output.
#
# Config (usually via tests/ci.env — see ci.env.example):
#   K230_CI_WORKSPACE    root holding the SDK checkouts        (required)
#   K230_CI_<X>_SDK      SDK dir name under workspace, or an absolute path
#   K230_CI_<X>_CMD      build command, run as `k230 bash -c "$CMD"` — may be
#                        a full shell sequence ("make list-def && make ... &&
#                        make", "a; b", ...), not just a single command
#   K230_CI_<X>_ART      artifact glob for find -name          (default *.img)
#   K230_CI_IMAGE / K230_CI_VOLUME as in t2.
#
# Exits 77 (SKIP) when the workspace/SDK dir is not configured or missing.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

skip() { echo "[t3] SKIP: $*"; exit 77; }

target="${1:-}"
case "$target" in
    linux)
        sdk="${K230_CI_LINUX_SDK:-k230_linux_sdk}"
        cmd="${K230_CI_LINUX_CMD:-make CONF=k230_canmv_defconfig}"
        art="${K230_CI_LINUX_ART:-*.img}"
        ;;
    rtos)
        sdk="${K230_CI_RTOS_SDK:-k230_rtos_sdk}"
        cmd="${K230_CI_RTOS_CMD:-make CONF=k230_canmv_defconfig}"
        art="${K230_CI_RTOS_ART:-*.img}"
        ;;
    nuttx)
        sdk="${K230_CI_NUTTX_SDK:-k230_nuttx_sdk}"
        cmd="${K230_CI_NUTTX_CMD:-west build}"
        art="${K230_CI_NUTTX_ART:-*.img}"
        ;;
    *) echo "usage: $0 <linux|rtos|nuttx>"; exit 2 ;;
esac

IMAGE="${K230_CI_IMAGE:-k230-builder:latest}"
VOLUME="${K230_CI_VOLUME:-k230_toolchains_ci}"

case "$sdk" in
    /*) dir="$sdk" ;;
    *)  [ -n "${K230_CI_WORKSPACE:-}" ] || skip "K230_CI_WORKSPACE not set (see tests/ci.env.example)"
        dir="$K230_CI_WORKSPACE/$sdk" ;;
esac
[ -d "$dir" ] || skip "SDK dir not found: $dir"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { echo "[t3] FAIL: image not found locally: $IMAGE"; exit 1; }

marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT

echo "[t3] target: $target  sdk: $dir"
cd "$dir"

# SDK checkouts under K230_CI_WORKSPACE persist across CI runs (unlike the
# git checkout itself), so a build with an unchanged source tree legitimately
# does an incremental no-op and never touches its output artifact. Snapshot
# what already matches the glob before building, so such an untouched-but-
# pre-existing artifact still counts as a pass instead of a false FAIL.
declare -A preexisting
while IFS= read -r -d '' f; do
    preexisting["$f"]=1
done < <(find . -path ./.git -prune -o -type f -name "$art" -size +1M -print0)

echo "[t3] provisioning toolchains: download-toolchains $target"
K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
    "$REPO/k230" download-toolchains "$target"

echo "[t3] build : k230 bash -c '$cmd'  (image=$IMAGE)"
# Run through a shell (not argv word-splitting) so K230_CI_*_CMD can be a
# sequence ("make list-def && make CONF=... && make", "a; b; c", ...), not
# just a single command.
K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
    "$REPO/k230" bash -c "$cmd"

echo "[t3] asserting artifacts: $art (fresh, or pre-existing and left untouched by an idempotent no-op build)"
mapfile -t -d '' candidates < <(find . -path ./.git -prune -o \
    -type f -name "$art" -size +1M -print0)

fresh=() unchanged=()
for f in "${candidates[@]}"; do
    if [ "$f" -nt "$marker" ]; then
        fresh+=("$f")
    elif [ -n "${preexisting[$f]:-}" ]; then
        unchanged+=("$f")
    fi
done

if [ ${#fresh[@]} -eq 0 ] && [ ${#unchanged[@]} -eq 0 ]; then
    echo "[t3] FAIL: build succeeded but produced no '$art' artifact (fresh or pre-existing)"
    exit 1
fi
for f in "${fresh[@]}"; do
    echo "[t3]   $(du -h "$f" | cut -f1)  $f  (fresh)"
done
for f in "${unchanged[@]}"; do
    echo "[t3]   $(du -h "$f" | cut -f1)  $f  (unchanged — incremental no-op build, already up to date)"
done

echo "[t3] PASS ($target)"
