#!/bin/bash
# scripts/profile.sh — map K230_PROFILE -> ENABLE_TC* defaults.
#
# Sourced by entrypoint.sh; also unit-tested directly (tests/run.sh).  Sourcing
# has NO side effects: it only defines resolve_profile().  Keep it dependency-
# free so the unit tests can source it on the host without a toolchain / image.
#
# Rule: an explicitly-set ENABLE_TCx always wins over the profile.

resolve_profile() {
    local p="${K230_PROFILE:-}"
    local d1 d2 d3 d4 d5 d6
    case "$p" in
        nuttx)  d1=0 d2=0 d3=0 d4=0 d5=1 d6=0 ;;
        linux)  d1=1 d2=1 d3=0 d4=0 d5=0 d6=0 ;;
        rtos)   d1=1 d2=0 d3=1 d4=0 d5=0 d6=0 ;;
        all)    d1=1 d2=1 d3=1 d4=0 d5=1 d6=0 ;;
        "")     # legacy: preserve prior behavior (TC1-4 on, TC5/TC6 off)
                d1=1 d2=1 d3=1 d4=1 d5=0 d6=0 ;;
        *)
            echo "[k230] warning: unknown K230_PROFILE='$p' (use nuttx|linux|rtos|all); treating as legacy" >&2
            d1=1 d2=1 d3=1 d4=1 d5=0 d6=0 ;;
    esac
    export ENABLE_TC1="${ENABLE_TC1:-$d1}"
    export ENABLE_TC2="${ENABLE_TC2:-$d2}"
    export ENABLE_TC3="${ENABLE_TC3:-$d3}"
    export ENABLE_TC4="${ENABLE_TC4:-$d4}"
    export ENABLE_TC5="${ENABLE_TC5:-$d5}"
    export ENABLE_TC6="${ENABLE_TC6:-$d6}"
    if [ -n "$p" ]; then
        echo "[k230] profile '$p' -> TC1=$ENABLE_TC1 TC2=$ENABLE_TC2 TC3=$ENABLE_TC3 TC4=$ENABLE_TC4 TC5=$ENABLE_TC5 TC6=$ENABLE_TC6"
    fi
    return 0
}
