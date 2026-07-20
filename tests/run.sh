#!/usr/bin/env bash
# T0 unit tests — resolve_toolchain_set() alias table. Zero external deps.
#
#   ./tests/run.sh
#
# Rule under test: a CLI arg (bare TCn, case-insensitive, or a human name like
# linux/rtos/rt-smart/nuttx/llvm/all) resolves to the space-separated TC list
# it needs; an unknown name is an error.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/toolchain.sh
source "$HERE/../scripts/toolchain.sh"

pass=0
fail=0

check() { # desc  input  want ("<error>" if resolve_toolchain_set should fail)
    local desc="$1" input="$2" want="$3" got
    got="$(resolve_toolchain_set "$input" 2>/dev/null)" || got="<error>"
    if [ "$got" = "$want" ]; then
        echo "ok   - $desc"
        pass=$((pass + 1))
    else
        echo "FAIL - $desc: got='$got' want='$want'"
        fail=$((fail + 1))
    fi
}

#      description                     input        want
check "bare tc1 passes through"       "tc1"        "tc1"
check "bare TC5 is case-insensitive"  "TC5"        "tc5"
check "linux -> tc1+tc2"              "linux"      "tc1 tc2"
check "rtos -> tc1+tc3"                "rtos"       "tc1 tc3"
check "rt-smart is an alias for rtos" "rt-smart"   "tc1 tc3"
check "RT-SMART is case-insensitive"  "RT-SMART"   "tc1 tc3"
check "nuttx -> tc5"                   "nuttx"      "tc5"
check "llvm -> tc6"                    "llvm"       "tc6"
check "all -> tc1+tc2+tc3+tc5"         "all"        "tc1 tc2 tc3 tc5"
check "unknown name is an error"       "bogus"      "<error>"
check "empty arg is an error"          ""           "<error>"

# ---- Toolchain directory consistency ---------------------------------------
# toolchain.sh's TCx_DIR is the single source of truth for install dirs, but
# scripts/nncase (TC_RTOS/TC_LINUX/TC_NUTTX) and scripts/entrypoint.sh (PATH
# entries) hardcode the same paths.  Renaming a dir in toolchain.sh without
# updating them breaks nncase/PATH silently — catch that here.

tc_dir() { # N -> default TCN_DIR parsed out of toolchain.sh
    sed -n "s/^TC$1_DIR=\${TC$1_DIR:-\"\([^\"]*\)\"}.*/\1/p" "$HERE/../scripts/toolchain.sh"
}

check_ref() { # desc  file  literal-needle
    local desc="$1" file="$2" needle="$3"
    if [ -n "$needle" ] && grep -qF "$needle" "$HERE/../$file"; then
        echo "ok   - $desc"
        pass=$((pass + 1))
    else
        echo "FAIL - $desc: '$needle' not found in $file"
        fail=$((fail + 1))
    fi
}

TC2D="$(tc_dir 2)" TC3D="$(tc_dir 3)" TC5D="$(tc_dir 5)"
for v in TC2D TC3D TC5D; do
    [ -n "${!v}" ] || { echo "FAIL - could not parse ${v%D}_DIR from toolchain.sh"; fail=$((fail + 1)); }
done

check_ref "nncase TC_LINUX matches TC2_DIR" "scripts/nncase" "TC_LINUX=\"/opt/toolchains/$TC2D\""
check_ref "nncase TC_RTOS matches TC3_DIR"  "scripts/nncase" "TC_RTOS=\"/opt/toolchains/$TC3D\""
check_ref "nncase TC_NUTTX matches TC5_DIR" "scripts/nncase" "TC_NUTTX=\"/opt/toolchains/$TC5D\""
for n in 1 2 3 5; do
    check_ref "entrypoint PATH has TC$n dir" "scripts/entrypoint.sh" "/opt/toolchains/$(tc_dir "$n")/bin"
done
check_ref "entrypoint PATH has TC4 riscv/bin" "scripts/entrypoint.sh" "/opt/toolchains/$(tc_dir 4)/riscv/bin"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
