#!/usr/bin/env bash
# T3 SDK build test — clean the SDK checkout, rebuild it from scratch through
# the real `k230` CLI, and assert a FRESH image artifact appeared.
#
#   ./tests/t3-sdk.sh <linux|rtos|nuttx>
#
# Every regression run is a full from-scratch build. The SDK checkouts under
# K230_CI_WORKSPACE persist across runs, so without an explicit clean the build
# is an incremental no-op: nothing gets compiled and the stage passes without
# having tested anything. Hence the flow: clean -> prove the clean worked ->
# build -> assert fresh output. A clean is almost entirely a CPU cost, not a
# bandwidth one: the big caches live OUTSIDE the cleaned dirs (buildroot's dl/ is
# a sibling of output/ and holds even the buildroot tarball; the rtos toolchains
# are in ~/.kendryte; the west projects keep their git object stores). The one
# exception is nuttx — `west clean` runs `git clean -xdf` per project, which also
# drops ~4MB of in-tree downloaded tarballs (libcxx, argtable3), so that clean
# does need network.
#
# The assertion stays artifact-only (matches the glob, above a size floor,
# newer than the marker): SDK builds are not reproducible, so a byte comparison
# would only produce false alarms.
#
# Config (usually via tests/ci.env — see ci.env.example):
#   K230_CI_WORKSPACE      root holding the SDK checkouts        (required)
#   K230_CI_<X>_SDK        SDK dir name under workspace, or an absolute path
#   K230_CI_<X>_CLEAN_CMD  clean command, run as `k230 bash -c "$CLEAN_CMD"`
#                          from the SDK dir before every build — same container
#                          and same paths as the build
#   K230_CI_<X>_CMD        build command, run the same way — may be a full
#                          shell sequence ("make list-def && make ... && make",
#                          "a; b", ...), not just a single command
#   K230_CI_<X>_ART        artifact glob for find -name          (default *.img)
#   K230_CI_NO_CLEAN=1     skip the clean — LOCAL DEBUGGING ONLY, it restores
#                          the vacuous-pass behaviour the clean exists to stop
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
        # output/ holds the build AND the extracted buildroot; dl/ (the download
        # cache, buildroot tarball included) is its sibling and survives, so
        # `make CONF=...` re-extracts and re-configures for free via the
        # Makefile's sync + $(BRW_BUILD_DIR)/.config rules.
        clean="${K230_CI_LINUX_CLEAN_CMD:-rm -rf output}"
        cmd="${K230_CI_LINUX_CMD:-make CONF=k230_canmv_defconfig}"
        art="${K230_CI_LINUX_ART:-*.img}"
        ;;
    rtos)
        sdk="${K230_CI_RTOS_SDK:-k230_rtos_sdk}"
        # `make clean` FIRST (it needs .config and an intact tree) to drop the
        # in-tree objects rtsmart/uboot/opensbi/canmv leave under src/, THEN
        # rm -rf output. NOT distclean: that deletes .config, which the default
        # build command needs (`make CONF=...` is not a %_defconfig goal, so the
        # next build would die with "Please run make xxx_defconfig first").
        # `;` not `&&`: on a checkout with no .config yet `make clean` errors and
        # we still want output/ removed.
        clean="${K230_CI_RTOS_CLEAN_CMD:-make clean; rm -rf output}"
        cmd="${K230_CI_RTOS_CMD:-make CONF=k230_canmv_defconfig}"
        art="${K230_CI_RTOS_ART:-*.img}"
        ;;
    nuttx)
        sdk="${K230_CI_NUTTX_SDK:-k230_nuttx_sdk}"
        # `west clean` (a manifest extension command) removes build/, output/ and
        # the top-level *.img, and runs `git clean -xdf` in every west project —
        # that last part is what removes nuttx/build-<board>/, which a plain
        # `rm -rf build` would miss.
        clean="${K230_CI_NUTTX_CLEAN_CMD:-west clean}"
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

# Both assertions below — "after the clean, nothing matches" and "after the
# build, something fresh matches" — must look at EXACTLY the same set of files,
# or the first can certify a tree the second then finds leftovers in. One
# function, one definition of "artifact". Must be called from inside the SDK
# dir. .git is pruned at every level (it never holds a build product, and
# skipping it avoids traversing the west projects' / .repo's object stores);
# the >1MB floor drops incidental small matches.
list_artifacts() { # -> NUL-separated paths on stdout
    find . -name .git -prune -o -type f -name "$art" -size +1M -print0
}

echo "[t3] target: $target  sdk: $dir"
cd "$dir"

# Toolchains first. They are provisioned into the docker volume, not the SDK
# dir, so this is independent of the clean — and doing it first means a broken
# toolchain fetch fails the stage while the previous build output is still
# around to debug with. The rtos clean also delegates to component kbuild,
# which wants the cross toolchain on PATH.
echo "[t3] provisioning toolchains: download-toolchains $target"
K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
    "$REPO/k230" download-toolchains "$target"

# ---- clean ------------------------------------------------------------------
# The SDK checkouts persist across CI runs, so without this the build is an
# incremental no-op that compiles nothing and passes anyway. The clean goes
# through the SAME `k230 bash -c` path as the build, so make/west come from the
# container image and the paths it sees are the paths the build will see; the
# bind mount also fences it to this SDK dir (k230 mounts only $(pwd)).
if [ -n "${K230_CI_NO_CLEAN:-}" ]; then
    echo "[t3] clean : SKIPPED (K230_CI_NO_CLEAN set) — build will be incremental"
else
    echo "[t3] clean : k230 bash -c '$clean'"
    K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
        "$REPO/k230" bash -c "$clean"

    # Give the clean teeth. If the artifact glob still matches, the clean did not
    # remove what the build produces, and the build after it would be exactly the
    # incremental no-op this stage exists to catch. Fail here — loudly, in
    # seconds — instead of hours later or, worse, silently.
    # This is not paranoia: `west clean` reports a failed per-project `git clean`
    # via log.err and STILL EXITS 0, so a broken clean is invisible to set -e.
    mapfile -t -d '' leftover < <(list_artifacts)
    if [ ${#leftover[@]} -gt 0 ]; then
        echo "[t3] FAIL: clean left ${#leftover[@]} '$art' artifact(s) behind:"
        printf '[t3]   %s\n' "${leftover[@]}"
        echo "[t3] the build after this would be an incremental no-op. Either"
        echo "[t3]   K230_CI_${target^^}_CLEAN_CMD misses them (now: $clean)"
        echo "[t3]   or K230_CI_${target^^}_ART is too loose (now: $art) and is"
        echo "[t3]   matching files that are not build products."
        exit 1
    fi
    echo "[t3] clean ok: no '$art' artifact left under $dir"
fi

# Freshness baseline: everything the build writes must be newer than this.
# Touched AFTER the clean so the window is exactly the build — a slow rm -rf or
# toolchain download can't blur it. (The marker file itself is created early, at
# mktemp, only so the EXIT trap covers it from the start.)
touch "$marker"

echo "[t3] build : k230 bash -c '$cmd'  (image=$IMAGE)"
# Run through a shell (not argv word-splitting) so K230_CI_*_CMD can be a
# sequence ("make list-def && make CONF=... && make", "a; b; c", ...), not
# just a single command.
K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
    "$REPO/k230" bash -c "$cmd"

echo "[t3] asserting artifacts: $art (fresh — written after the pre-build marker)"
mapfile -t -d '' candidates < <(list_artifacts)

fresh=()
for f in "${candidates[@]}"; do
    if [ "$f" -nt "$marker" ]; then
        fresh+=("$f")
    fi
done

if [ ${#fresh[@]} -eq 0 ]; then
    echo "[t3] FAIL: build succeeded but produced no fresh '$art' artifact"
    if [ ${#candidates[@]} -gt 0 ]; then
        echo "[t3] (${#candidates[@]} stale match(es), written before this build started:)"
        printf '[t3]   %s\n' "${candidates[@]}"
    fi
    exit 1
fi
for f in "${fresh[@]}"; do
    echo "[t3]   $(du -h "$f" | cut -f1)  $f  (fresh)"
done

echo "[t3] PASS ($target)"
