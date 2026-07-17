#!/usr/bin/env bash
# Run coverage (or test suites) for all sibling projects in the workspace and
# print a per-project + group rollup.
#
# Usage (from anywhere):
#   ./scripts/report-coverage-all.sh
#   # or from the workspace parent:
#   ./report-coverage.sh
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

  local tests_line cov_line br_line note=""
  tests_line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed|^--- .* summary ---|[0-9]+ passed,' | tail -5 || true)"

  # Prefer the summary block the per-project scripts print.
  local line_pct branch_pct tests_summary
  line_pct="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Line coverage:[[:space:]]*//p' | tail -1)"
  branch_pct="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Branch coverage:[[:space:]]*//p' | tail -1)"
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
printf '%-24s  %-36s  %-28s  %-28s  %s\n' "Project" "Tests" "Line coverage" "Branch coverage" "Status"
printf '%-24s  %-36s  %-28s  %-28s  %s\n' "------------------------" "------------------------------------" "----------------------------" "----------------------------" "------"
for row in "${ROWS[@]}"; do
  IFS='|' read -r name tests line br status <<<"$row"
  printf '%-24s  %-36s  %-28s  %-28s  %s\n' "$name" "$tests" "$line" "$br" "$status"
done
echo
echo "Python projects measure classifier/ / job_tracker packages via pytest-cov."
echo "recruiting-automation is bats/shell — coverage marked N/A."
echo

if [[ "$failures" -gt 0 ]]; then
  echo "RESULT: $failures project suite(s) failed." >&2
  exit 1
fi
echo "RESULT: all project suites passed."
exit 0
