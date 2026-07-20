#!/usr/bin/env bash
# T4 nncase test — exercise `k230 nncase ...` end-to-end and assert products.
#
#   ./tests/t4-nncase.sh <compiler|kmodel|runtime-rtos|runtime-linux|runtime-nuttx>
#
#   compiler        build the host compiler; assert Nncase.Compiler.dll
#   kmodel          compile tests/fixtures/tiny.onnx -> .kmodel (the one real
#                   FUNCTIONAL check of the whole compiler stack); needs the
#                   compiler stage to have run first
#   runtime-rtos    on-device runtime; needs the rtos SDK built (t3) — reuses
#   runtime-linux   the same workspace SDK dirs, so run after the sdk stages
#   runtime-nuttx   needs a NuttX export sysroot (K230_CI_NUTTX_EXPORT)
#
# Config (usually via tests/ci.env): K230_CI_WORKSPACE must contain the
# nncase-k80 plugin repo (dir with modules/Nncase.Modules.K230); the base
# nncase repo is auto-cloned by scripts/nncase when missing.
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

# Same plugin-repo detection rule as scripts/nncase, for the skip decision.
has_plugin() {
    [ -d "$WS/${NNCASE_PLUGIN_DIR:-}/modules/Nncase.Modules.K230" ] && return 0
    local d
    for d in "$WS"/*/; do
        [ -d "${d}modules/Nncase.Modules.K230" ] && return 0
    done
    return 1
}
has_plugin || skip "no nncase-k80 plugin repo under $WS (dir with modules/Nncase.Modules.K230)"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || { echo "[t4] FAIL: image not found locally: $IMAGE"; exit 1; }

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
    local n
    n=$(find "$out" -name "*.a" | wc -l)
    [ "$n" -gt 0 ] || { echo "[t4] FAIL: no static libs (*.a) under $out"; exit 1; }
    echo "[t4] $n static libs under $out:"
    find "$out" -name "*.a" -exec du -h {} + | sed 's/^/[t4]   /'
}

case "$sub" in
    compiler)
        run_k230 -- nncase compiler
        dll="$WS/$BASE/src/Nncase.Compiler/bin/Release/net7.0/Nncase.Compiler.dll"
        [ -f "$dll" ] || { echo "[t4] FAIL: missing $dll"; exit 1; }
        echo "[t4] ok: $dll"
        ;;

    kmodel)
        cp "$HERE/fixtures/tiny.onnx" "$WS/.ci-tiny.onnx"
        run_k230 -- nncase kmodel .ci-tiny.onnx .ci-tiny.kmodel
        out="$WS/.ci-tiny.kmodel"
        [ -f "$out" ] || { echo "[t4] FAIL: no kmodel produced"; exit 1; }
        size=$(stat -c %s "$out")
        [ "$size" -ge 1024 ] || { echo "[t4] FAIL: kmodel suspiciously small (${size}B)"; exit 1; }
        echo "[t4] ok: .ci-tiny.kmodel (${size}B, header: $(head -c 8 "$out" | od -An -tx1 | tr -d ' \n'))"
        ;;

    runtime-rtos)
        sdk="${K230_CI_RTOS_SDK:-k230_rtos_sdk}"
        [ -d "$WS/$sdk" ] || skip "rtos SDK dir missing: $WS/$sdk (build it with the sdk-rtos stage)"
        run_k230 -- download-toolchains rtos
        run_k230 K230_RTOS_SDK_DIR="$sdk" -- nncase runtime rtos
        assert_static_libs nncase_rtt_runtime
        ;;

    runtime-linux)
        sdk="${K230_CI_LINUX_SDK:-k230_linux_sdk}"
        [ -d "$WS/$sdk" ] || skip "linux SDK dir missing: $WS/$sdk (build it with the sdk-linux stage)"
        run_k230 -- download-toolchains linux
        run_k230 K230_LINUX_SDK_DIR="$sdk" -- nncase runtime linux
        assert_static_libs nncase_linux_runtime
        ;;

    runtime-nuttx)
        exp="${K230_CI_NUTTX_EXPORT:-}"
        [ -n "$exp" ] || skip "K230_CI_NUTTX_EXPORT not set (NuttX export sysroot) — stage disabled"
        [ -d "$WS/$exp/include" ] || skip "not an export sysroot (no include/): $WS/$exp"
        run_k230 -- download-toolchains nuttx
        run_k230 K230_NUTTX_EXPORT_DIR="$exp" -- nncase runtime nuttx
        assert_static_libs nncase_nuttx_runtime
        ;;

    *) echo "usage: $0 <compiler|kmodel|runtime-rtos|runtime-linux|runtime-nuttx>"; exit 2 ;;
esac

echo "[t4] PASS ($sub)"
