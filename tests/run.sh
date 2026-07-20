#!/usr/bin/env bash
# T0 unit tests — resolve_profile() mapping. Zero external deps (plain bash).
#
#   ./tests/run.sh
#
# Signature = "$ENABLE_TC1$ENABLE_TC2$ENABLE_TC3$ENABLE_TC4$ENABLE_TC5$ENABLE_TC6"
# Rule under test: K230_PROFILE picks defaults; an explicit ENABLE_TCx wins.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/profile.sh
source "$HERE/../scripts/profile.sh"

pass=0
fail=0

# run_case ENV... -> prints the 6-digit ENABLE_TC signature.
# Each case runs in a subshell with a clean ENABLE_TC*/K230_PROFILE env so
# exports from one case never leak into the next.
run_case() {
    (
        unset ENABLE_TC1 ENABLE_TC2 ENABLE_TC3 ENABLE_TC4 ENABLE_TC5 ENABLE_TC6 K230_PROFILE
        while [ $# -gt 0 ]; do export "${1?}"; shift; done
        resolve_profile >/dev/null 2>&1
        printf '%s%s%s%s%s%s' \
            "$ENABLE_TC1" "$ENABLE_TC2" "$ENABLE_TC3" "$ENABLE_TC4" "$ENABLE_TC5" "$ENABLE_TC6"
    )
}

check() { # desc  want  ENV...
    local desc="$1" want="$2"; shift 2
    local got; got="$(run_case "$@")"
    if [ "$got" = "$want" ]; then
        echo "ok   - $desc"
        pass=$((pass + 1))
    else
        echo "FAIL - $desc: got=$got want=$want"
        fail=$((fail + 1))
    fi
}

#      description                     want(TC1..TC6)   env
check "legacy (no profile) = TC1-4"    "111100"
check "profile nuttx = only TC5"       "000010"         "K230_PROFILE=nuttx"
check "profile linux = TC1+TC2"        "110000"         "K230_PROFILE=linux"
check "profile rtos = TC1+TC3"         "101000"         "K230_PROFILE=rtos"
check "profile all = TC1-3 + TC5"      "111010"         "K230_PROFILE=all"
check "explicit ENABLE_TC1 wins"       "100010"         "K230_PROFILE=nuttx" "ENABLE_TC1=1"
check "explicit disable in legacy"     "111000"         "ENABLE_TC4=0"
check "unknown profile -> legacy"      "111100"         "K230_PROFILE=bogus"

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
