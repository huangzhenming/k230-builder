#!/usr/bin/env bash
# report.sh — regression pipeline orchestrator + Markdown report generator.
#
#   ./tests/report.sh [stage ...]        (no args = full pipeline)
#
# Stages (in dependency order — runtimes reuse the SDK dirs the sdk-* stages
# built, kmodel needs the compiler stage):
#   image smoke unit toolchains
#   sdk-linux sdk-rtos sdk-nuttx
#   nncase-compiler nncase-kmodel
#   nncase-runtime-rtos nncase-runtime-linux nncase-runtime-nuttx
#
# Per stage: pass / FAIL / TIMEOUT (exit 124) / skip (exit 77), duration, log
# tail on failure. Set K230_CI_STAGE_TIMEOUT (e.g. 4h) to cap each stage.
# Output: reports/report-<ts>.md (+ latest.md / latest-logs/ copies for CI
# artifact upload) and $GITHUB_STEP_SUMMARY when running under Actions.
# Exit code: non-zero iff any stage failed (skips don't fail the run).
#
# Config: sourced from tests/ci.env when present (see ci.env.example).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

# shellcheck source=/dev/null
if [ -f "$HERE/ci.env" ]; then
    set -a; source "$HERE/ci.env"; set +a
fi
export K230_CI_IMAGE="${K230_CI_IMAGE:-k230-builder:regression}"
export K230_CI_VOLUME="${K230_CI_VOLUME:-k230_toolchains_ci}"

# ALL_STAGES=(image smoke unit toolchains
#             sdk-linux sdk-rtos sdk-nuttx
#             nncase-compiler nncase-kmodel
#             nncase-runtime-rtos nncase-runtime-linux nncase-runtime-nuttx)
ALL_STAGES=(image smoke unit toolchains
            sdk-linux sdk-rtos sdk-nuttx)

if [ $# -gt 0 ]; then STAGES=("$@"); else STAGES=("${ALL_STAGES[@]}"); fi

TS="$(date +%Y%m%d-%H%M%S)"
RPT_DIR="${K230_CI_REPORT_DIR:-$REPO/reports}"
LOG_DIR="$RPT_DIR/logs-$TS"
REPORT="$RPT_DIR/report-$TS.md"
mkdir -p "$LOG_DIR"

# Optional per-stage wall-clock cap (K230_CI_STAGE_TIMEOUT, any `timeout`
# duration — e.g. 4h). Worth setting in CI: this script writes its Markdown only
# after the stage loop, so a job-level timeout loses the report entirely and the
# `if: always()` upload step ships the PREVIOUS run's latest.md, which is worse
# than no report. With a per-stage cap, one hung stage just fails (timeout exits
# 124, landing in the FAIL branch below) and the report still gets written.
# Caveat: `timeout` kills the `docker run` client, not necessarily the processes
# still running inside the container.
TMO=()
if [ -n "${K230_CI_STAGE_TIMEOUT:-}" ]; then
    TMO=(timeout --foreground "$K230_CI_STAGE_TIMEOUT")
fi

run_stage() {
    case "$1" in
        image)      "${TMO[@]}" docker build -f "$REPO/docker/Dockerfile" -t "$K230_CI_IMAGE" "$REPO" ;;
        smoke)      "${TMO[@]}" "$HERE/smoke.sh" "$K230_CI_IMAGE" ;;
        unit)       "${TMO[@]}" "$HERE/run.sh" ;;
        toolchains) "${TMO[@]}" "$HERE/t2-toolchains.sh" ;;
        sdk-*)      "${TMO[@]}" "$HERE/t3-sdk.sh" "${1#sdk-}" ;;
        nncase-*)   "${TMO[@]}" "$HERE/t4-nncase.sh" "${1#nncase-}" ;;
        *)          echo "unknown stage: $1"; return 2 ;;
    esac
}

fmt_dur() { printf '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"; }

rows=""
failed_stages=()
overall=0

for st in "${STAGES[@]}"; do
    log="$LOG_DIR/$st.log"
    echo ""
    echo "[report] ===== stage: $st ====="
    start=$SECONDS
    run_stage "$st" 2>&1 | tee "$log"
    rcode=${PIPESTATUS[0]}
    dur=$((SECONDS - start))

    note="$(grep -v '^\s*$' "$log" | tail -1 | tr '|`' '/·' | cut -c1-100)"
    case $rcode in
        0)   res="✅ pass" ;;
        77)  res="⏭️ skip" ;;
        # 124 = killed by the K230_CI_STAGE_TIMEOUT cap. Still a FAIL, but label
        # it so a timeout isn't mistaken for a build error.
        124) res="⏱️ **TIMEOUT**"; overall=1; failed_stages+=("$st") ;;
        *)   res="❌ **FAIL**"; overall=1; failed_stages+=("$st") ;;
    esac
    echo "[report] stage $st: $res ($(fmt_dur $dur))"
    rows+="| $st | $res | $(fmt_dur $dur) | $note |"$'\n'
done

# ---- Markdown report --------------------------------------------------------
git_desc="$(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null || echo 'n/a')"
git_branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'n/a')"
img_id="$(docker image inspect -f '{{.Id}}' "$K230_CI_IMAGE" 2>/dev/null | cut -c8-19 || true)"

{
    echo "# k230-builder 回归测试报告"
    echo ""
    echo "- 时间: $(date '+%Y-%m-%d %H:%M:%S %Z')  主机: $(hostname)"
    echo "- 代码: \`$git_branch\` @ $git_desc"
    echo "- 镜像: \`$K230_CI_IMAGE\` (${img_id:-未构建})  工具链卷: \`$K230_CI_VOLUME\`"
    echo ""
    echo "| Stage | 结果 | 耗时 | 备注 |"
    echo "|---|---|---|---|"
    printf '%s' "$rows"
    echo ""
    if [ ${#failed_stages[@]} -gt 0 ]; then
        echo "## 失败详情"
        for st in "${failed_stages[@]}"; do
            echo ""
            echo "### $st（日志末尾 30 行）"
            echo '```text'
            tail -30 "$LOG_DIR/$st.log"
            echo '```'
        done
    fi
} > "$REPORT"

# Stable copies for CI artifact upload / failure-issue body.
cp -f "$REPORT" "$RPT_DIR/latest.md"
rm -rf "$RPT_DIR/latest-logs"
cp -r "$LOG_DIR" "$RPT_DIR/latest-logs"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"

echo ""
echo "[report] written: $REPORT"
if [ "$overall" -ne 0 ]; then
    echo "[report] RESULT: FAIL (${failed_stages[*]})"
else
    echo "[report] RESULT: PASS"
fi
exit "$overall"
