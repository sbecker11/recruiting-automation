#!/bin/zsh
# Weekly ops on mini2 — drift, rejections, spend, quiet jobs.
#
#   ./scripts/weekly_ops_mini2.sh
#
# scan_rejection_backlog.py runs dry-run by default. To apply fixes:
#   SCAN_REJECTION_APPLY=1 ./scripts/weekly_ops_mini2.sh
#
set -uo pipefail

WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
JOBTRACKER_REPO="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$WORKSPACE_ROOT/job-tracker}"

echo "=== Weekly ops (mini2) ==="
echo "workspace: $WORKSPACE_ROOT"
echo ""

if [[ ! -d "$JOBTRACKER_REPO/.venv" && -z "${JOBTRACKER_VENV:-}" ]]; then
  echo "ERROR: no venv at $JOBTRACKER_REPO/.venv"
  echo "  fix: cd \"$WORKSPACE_ROOT/recruiting-automation\" && ./scripts/deploy_mini2.sh"
  exit 1
fi

VENV="${JOBTRACKER_VENV:-$JOBTRACKER_REPO/.venv}"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
cd "$JOBTRACKER_REPO"

run() {
  echo ""
  echo "--- $1 ---"
  shift
  "$@"
}

run "label drift" python scripts/audit_label_drift.py
if [[ -n "${SCAN_REJECTION_APPLY:-}" ]]; then
  run "rejection backlog (apply)" python scripts/scan_rejection_backlog.py --apply --yes
else
  run "rejection backlog (dry-run)" python scripts/scan_rejection_backlog.py
fi
run "spend rollup" python scripts/spend_report.py
run "quiet jobs" python scripts/quiet_jobs_report.py

echo ""
echo "Weekly ops complete."
