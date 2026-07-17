#!/usr/bin/env bash
# Run coverage (or test suites) for all sibling projects in the workspace and
# print a per-project + group rollup.
#
# Usage (from anywhere):
#   ./scripts/report-coverage-all.sh
#   # or from the workspace parent:
#   ./report-coverage.sh
#
# Coverage % colors: green ≥90 · yellow ≥70 · red <70
#
# Exits non-zero if any project suite fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-}" ]]; then
  WORKSPACE="$RECRUITING_AUTOMATION_WORKSPACE_ROOT"
else
  WORKSPACE="$(cd "$RA_ROOT/.." && pwd)"
fi

JOB_TRACKER="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$WORKSPACE/job-tracker}"
COMMS="${RECRUITING_AUTOMATION_COMMS_REPO:-$WORKSPACE/comms-migration}"
RA="${RECRUITING_AUTOMATION_BASE:-$RA_ROOT}"

# ANSI — green ≥90 · yellow ≥70 · red <70
RESET=$'\033[0m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

strip_ansi() {
  # shellcheck disable=SC2001
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

# Color a coverage cell (e.g. "71.5%  (...)" or "N/A (...)"). Leaves N/A plain.
color_cov_cell() {
  local cell="$1"
  local plain num
  plain="$(strip_ansi "$cell")"
  if [[ "$plain" == N/A* ]] || [[ "$plain" == n/a* ]] || [[ -z "$plain" ]]; then
    printf '%s' "$plain"
    return
  fi
  num="$(printf '%s' "$plain" | sed -n 's/^[[:space:]]*\([0-9.][0-9.]*\)%.*/\1/p')"
  if [[ -z "$num" ]]; then
    printf '%s' "$plain"
    return
  fi
  # Compare as integers (×10) to avoid bc dependency
  local tenths code
  tenths="$(awk -v n="$num" 'BEGIN { printf "%.0f", n * 10 }')"
  if (( tenths >= 900 )); then
    code="$GREEN"
  elif (( tenths >= 700 )); then
    code="$YELLOW"
  else
    code="$RED"
  fi
  # Re-color only the leading "NN.N%" token; keep trailing detail plain
  printf '%s' "$plain" | sed "s/^\([[:space:]]*\)\([0-9.][0-9.]*\)%/\1${code}\2%${RESET}/"
}

echo "========================================"
echo " Workspace coverage rollup"
echo " Workspace: $WORKSPACE"
echo "========================================"
echo

failures=0
declare -a ROWS=()

run_one() {
  local name="$1"
  local dir="$2"
  local script="$dir/scripts/coverage.sh"

  if [[ ! -x "$script" ]]; then
    echo "!!! $name: missing executable $script" >&2
    ROWS+=("$name|MISSING|n/a|n/a|script missing")
    failures=$((failures + 1))
    return
  fi

  echo
  set +e
  out="$("$script" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"

  local line_pct branch_pct tests_summary note=""
  # Prefer the summary block the per-project scripts print; strip ANSI for storage.
  line_pct="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Line coverage:[[:space:]]*//p' | tail -1)"
  line_pct="$(strip_ansi "${line_pct:-}")"
  branch_pct="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Branch coverage:[[:space:]]*//p' | tail -1)"
  branch_pct="$(strip_ansi "${branch_pct:-}")"
  tests_summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed' | tail -1 || true)"
  if [[ -z "$tests_summary" ]]; then
    tests_summary="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Tests:[[:space:]]*//p' | tail -1)"
  fi
  if [[ "$rc" -ne 0 ]]; then
    note="FAILED (exit $rc)"
    failures=$((failures + 1))
  else
    note="ok"
  fi

  ROWS+=("$name|${tests_summary:-see output}|${line_pct:-n/a}|${branch_pct:-n/a}|$note")
}

run_one "job-tracker" "$JOB_TRACKER"
run_one "comms-migration" "$COMMS"
run_one "recruiting-automation" "$RA"

echo
echo "========================================"
echo " Group rollup (not a merged % — mixed Python/shell tooling)"
echo "========================================"
printf '%-24s  %-36s  %-40s  %-40s  %s\n' "Project" "Tests" "Line coverage" "Branch coverage" "Status"
printf '%-24s  %-36s  %-40s  %-40s  %s\n' "------------------------" "------------------------------------" "----------------------------------------" "----------------------------------------" "------"
for row in "${ROWS[@]}"; do
  IFS='|' read -r name tests line br status <<<"$row"
  colored_line="$(color_cov_cell "$line")"
  colored_br="$(color_cov_cell "$br")"
  # Visible width ignores ANSI; pad using plain text length then inject color.
  # Simpler: print with fixed plain columns if color makes printf misalign —
  # use plain for width calc via printf of stripped, then overwrite visually.
  printf '%-24s  %-36s  ' "$name" "$tests"
  # Pad colored cells to ~40 visible cols
  plain_line="$(strip_ansi "$colored_line")"
  plain_br="$(strip_ansi "$colored_br")"
  pad_line=$((40 - ${#plain_line}))
  pad_br=$((40 - ${#plain_br}))
  (( pad_line < 0 )) && pad_line=0
  (( pad_br < 0 )) && pad_br=0
  printf '%s%*s  %s%*s  %s\n' "$colored_line" "$pad_line" "" "$colored_br" "$pad_br" "" "$status"
done
echo
echo "Python projects measure classifier/ / job_tracker packages via pytest-cov."
echo "recruiting-automation is bats/shell — coverage marked N/A."
echo "Colors: green ≥90% · yellow ≥70% · red <70%"
echo

if [[ "$failures" -gt 0 ]]; then
  echo "RESULT: $failures project suite(s) failed." >&2
  exit 1
fi
echo "RESULT: all project suites passed."
exit 0
