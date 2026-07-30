#!/usr/bin/env bash
# T4 nncase test — exercise `k230 nncase ...` end-to-end and assert products.
#
#   ./tests/t4-nncase.sh <compiler|kmodel|runtime-rtos|runtime-linux|runtime-nuttx>
#
#   compiler        build the host compiler from scratch; assert a FRESH
#                   Nncase.Compiler.dll
#   kmodel          compile tests/fixtures/tiny.onnx -> .kmodel (the one real
#                   FUNCTIONAL check of the whole compiler stack); needs the
#                   compiler stage to have run first
#   runtime-rtos    on-device runtime; needs the rtos SDK built (t3) — reuses
#   runtime-linux   the same workspace SDK dirs, so run after the sdk stages
#   runtime-nuttx   needs a NuttX export sysroot (K230_CI_NUTTX_EXPORT)
#
# Like t3, every product must be REBUILT THIS RUN — the workspace repos persist
# across CI runs, so a stale artifact would otherwise pass the assertion without
# anything having been compiled. scripts/nncase already rm -rf's its cmake/conan
# build dirs, so the native half is from-scratch on its own; the dotnet half is
# not, hence the prune before the compiler stage. Every assertion is
# freshness-checked against a marker touched right before the build.
#
# Config (usually via tests/ci.env): K230_CI_WORKSPACE must contain the
# nncase-k80 plugin repo (dir with modules/Nncase.Modules.K230); the base
# nncase repo is auto-cloned by scripts/nncase when missing.
#   K230_CI_NO_CLEAN=1  skip the prune — LOCAL DEBUGGING ONLY.
# Exits 77 (SKIP) when the workspace/plugin/prerequisite dir is missing.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

skip() { echo "[t4] SKIP: $*"; exit 77; }

sub="${1:-}"
IMAGE="${K230_CI_IMAGE:-k230-builder:latest}"
VOLUME="${K230_CI_VOLUME:-k230_toolchains_ci}"
WS="${K230_CI_WORKSPACE:-}"
BASE="${NNCASE_BASE_DIR:-nncase}"

[ -n "$WS" ] && [ -d "$WS" ] || skip "K230_CI_WORKSPACE not set / missing (see tests/ci.env.example)"

# Resolve the plugin repo the same way scripts/nncase:68-87 does, but on the
# host: besides the skip decision, the prune below needs its real path.
resolve_plugin() {
    local p d
    if [ -n "${NNCASE_PLUGIN_DIR:-}" ]; then
        p="$WS/$NNCASE_PLUGIN_DIR"
        [ -d "$p/modules/Nncase.Modules.K230" ] || return 1
        printf '%s' "$p"; return 0
    fi
    if [ -d "$WS/modules/Nncase.Modules.K230" ]; then
        printf '%s' "$WS"; return 0
    fi
    for d in "$WS"/*/; do
        if [ -d "${d}modules/Nncase.Modules.K230" ]; then
            printf '%s' "${d%/}"; return 0
        fi
    done
    return 1
}
resolve_plugin >/dev/null \
    || skip "no nncase-k80 plugin repo under $WS (dir with modules/Nncase.Modules.K230)"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { echo "[t4] FAIL: image not found locally: $IMAGE"; exit 1; }

# Freshness baseline; touched right before each build below.
marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT

run_k230() { # [ENV=VAL ...] -- k230 args...
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    ( cd "$WS" && env "${envs[@]}" \
        K230_BUILDER_IMAGE="$IMAGE" K230_BUILDER_VOLUME="$VOLUME" \
        "$REPO/k230" "$@" )
}

assert_static_libs() { # install-dir-name
    local out="$WS/$1"
    [ -d "$out" ] || { echo "[t4] FAIL: no output dir $out"; exit 1; }
    local n stale
    n=$(find "$out" -name "*.a" | wc -l)
    [ "$n" -gt 0 ] || { echo "[t4] FAIL: no static libs (*.a) under $out"; exit 1; }
    # scripts/nncase:190 empties $install before each runtime build, so every .a
    # here is from this run by construction. Assert it locally anyway, so the
    # guarantee doesn't evaporate silently if that rm -rf ever moves.
    stale=$(find "$out" -name "*.a" ! -newer "$marker" | wc -l)
    if [ "$stale" -ne 0 ]; then
        echo "[t4] FAIL: $stale of $n static lib(s) under $out predate this build"
        find "$out" -name "*.a" ! -newer "$marker" | sed 's/^/[t4]   stale: /'
        exit 1
    fi
    echo "[t4] $n static libs under $out (all fresh):"
    find "$out" -name "*.a" -exec du -h {} + | sed 's/^/[t4]   /'
}

# Delete the dotnet build output that `nncase compiler` would otherwise reuse.
# scripts/nncase already rm -rf's its cmake/conan build dirs (:107, :116, :190,
# :194, :210), so the native half rebuilds from scratch on its own. What survives
# across runs and makes the build incremental is the dotnet half — bin/ + obj/
# next to each *.csproj in BOTH repos — plus the cmake install prefix
# $BASE/nncase-native (scripts/nncase:101, written at :112/:122, never deleted).
#
# ONLY bin/obj dirs sitting next to a *.csproj are removed, and only if git has
# nothing tracked in them. `bin` is an ordinary directory name — the base repo's
# own install prefix has one (nncase-native/bin) — so a blind
# `find -name bin -exec rm -rf` would eat it.
#
# NOT touched, deliberately: the base repo dir itself (scripts/nncase:56-66
# re-clones it over the network when missing, so deleting it is not free), and
# the conan (/opt/toolchains/.conan2) + NuGet (/opt/toolchains/.nuget) caches,
# which live in the docker volume and are legitimate content-addressed caches.
prune_dotnet() { # repo-root  label
    local root="$1" label="$2" d n=0
    local -a dirs=()
    mapfile -t -d '' dirs < <(
        find "$root" -name .git -prune -o \
             -type d \( -name bin -o -name obj \) -print0)
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue                                 # parent already gone
        compgen -G "${d%/*}/*.csproj" >/dev/null || continue     # not a dotnet project dir
        if git -C "$root" ls-files --error-unmatch -- "$d" >/dev/null 2>&1; then
            echo "[t4] keeping git-tracked dir: $d"
            continue
        fi
        rm -rf "$d"
        n=$((n + 1))
    done
    echo "[t4] pruned $n dotnet bin/obj dir(s) under $label"
}

case "$sub" in
    compiler)
        base="$WS/$BASE"
        plugin="$(resolve_plugin)"
        dll="$base/src/Nncase.Compiler/bin/Release/net7.0/Nncase.Compiler.dll"

        if [ -n "${K230_CI_NO_CLEAN:-}" ]; then
            echo "[t4] clean: SKIPPED (K230_CI_NO_CLEAN set) — build will be incremental"
        else
            echo "[t4] clean: nncase-native + dotnet bin/obj (base + plugin)"
            rm -rf "$base/nncase-native"
            if [ -d "$base" ]; then prune_dotnet "$base" "base:$base"; fi
            prune_dotnet "$plugin" "plugin:$plugin"
            # Same "give the clean teeth" rule as t3: prove the thing we are about
            # to assert on is really gone before building, so a prune that misses
            # it can't silently degrade this stage back to a vacuous pass.
            if [ -e "$dll" ]; then
                echo "[t4] FAIL: clean left the compiler dll behind: $dll"
                echo "[t4] (its bin/ was skipped as git-tracked, or does not sit"
                echo "[t4]  next to a *.csproj — prune_dotnet needs adjusting)"
                exit 1
            fi
            echo "[t4] clean ok: $dll is gone"
        fi

        touch "$marker"
        run_k230 -- nncase compiler
        [ -f "$dll" ] || { echo "[t4] FAIL: missing $dll"; exit 1; }
        [ "$dll" -nt "$marker" ] \
            || { echo "[t4] FAIL: $dll was not rebuilt this run (stale)"; exit 1; }
        echo "[t4] ok: $dll ($(stat -c %s "$dll")B, fresh)"
        ;;

    kmodel)
        out="$WS/.ci-tiny.kmodel"
        # Drop the previous run's kmodel: the assertion is "exists AND newer than
        # the marker", and a leftover from an earlier run is exactly what makes a
        # silently-failing compile look like a pass.
        rm -f "$out"
        cp "$HERE/fixtures/tiny.onnx" "$WS/.ci-tiny.onnx"
        touch "$marker"
        run_k230 -- nncase kmodel .ci-tiny.onnx .ci-tiny.kmodel
        [ -f "$out" ] || { echo "[t4] FAIL: no kmodel produced"; exit 1; }
        [ "$out" -nt "$marker" ] \
            || { echo "[t4] FAIL: kmodel not written this run (stale): $out"; exit 1; }
        size=$(stat -c %s "$out")
        [ "$size" -ge 1024 ] || { echo "[t4] FAIL: kmodel suspiciously small (${size}B)"; exit 1; }
        echo "[t4] ok: .ci-tiny.kmodel (${size}B, fresh, header: $(head -c 8 "$out" | od -An -tx1 | tr -d ' \n'))"
        ;;

    runtime-rtos)
        sdk="${K230_CI_RTOS_SDK:-k230_rtos_sdk}"
        [ -d "$WS/$sdk" ] || skip "rtos SDK dir missing: $WS/$sdk (build it with the sdk-rtos stage)"
        run_k230 -- download-toolchains rtos
        touch "$marker"
        run_k230 K230_RTOS_SDK_DIR="$sdk" -- nncase runtime rtos
        assert_static_libs nncase_rtt_runtime
        ;;

    runtime-linux)
        sdk="${K230_CI_LINUX_SDK:-k230_linux_sdk}"
        [ -d "$WS/$sdk" ] || skip "linux SDK dir missing: $WS/$sdk (build it with the sdk-linux stage)"
        run_k230 -- download-toolchains linux
        touch "$marker"
        run_k230 K230_LINUX_SDK_DIR="$sdk" -- nncase runtime linux
        assert_static_libs nncase_linux_runtime
        ;;

    runtime-nuttx)
        exp="${K230_CI_NUTTX_EXPORT:-}"
        [ -n "$exp" ] || skip "K230_CI_NUTTX_EXPORT not set (NuttX export sysroot) — stage disabled"
        [ -d "$WS/$exp/include" ] || skip "not an export sysroot (no include/): $WS/$exp"
        run_k230 -- download-toolchains nuttx
        touch "$marker"
        run_k230 K230_NUTTX_EXPORT_DIR="$exp" -- nncase runtime nuttx
        assert_static_libs nncase_nuttx_runtime
        ;;

    *) echo "usage: $0 <compiler|kmodel|runtime-rtos|runtime-linux|runtime-nuttx>"; exit 2 ;;
esac

echo "[t4] PASS ($sub)"
