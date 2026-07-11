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

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
