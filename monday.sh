#!/bin/zsh
# Monday v1 — zero dead-time decision briefing.
#
# Refreshes pending-actions JSON, then prints the decision queues ranked for
# interview likelihood. Run anytime a lead arrives or at the start of a work block.
#
#   ./monday.sh
#   ./monday.sh --json
#
set -uo pipefail

WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
export RECRUITING_AUTOMATION_WORKSPACE_ROOT="$WORKSPACE_ROOT"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
JOBTRACKER_REPO="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$WORKSPACE_ROOT/job-tracker}"

echo "=== Monday v1 ==="
echo "workspace: $WORKSPACE_ROOT"
echo ""

# Schedule one-liner (full detail: ./status.sh)
if [[ -f "$BASE/state/HALT" ]]; then
  echo "SCHEDULE: HALTED — $(cat "$BASE/state/HALT")"
  echo "  fix: cd \"$BASE\" && ./install.sh"
else
  echo "SCHEDULE: not halted (see ./status.sh for cycle history)"
fi
echo ""

if [[ ! -d "$JOBTRACKER_REPO/.venv" && -z "${JOBTRACKER_VENV:-}" ]]; then
  echo "ERROR: no venv at $JOBTRACKER_REPO/.venv — create it first (see job-tracker README)."
  echo "  Or set JOBTRACKER_VENV=/path/to/venv"
  exit 1
fi

VENV="${JOBTRACKER_VENV:-$JOBTRACKER_REPO/.venv}"
# shellcheck disable=SC1091
source "$VENV/bin/activate"

cd "$JOBTRACKER_REPO"

echo "--- refreshing pending-actions UI data ---"
python scripts/render_pending_actions.py --no-rescore 2>&1 | tail -5
echo ""

echo "--- decision report ---"
python scripts/monday_report.py \
  --state-dir "$BASE/state" \
  "$@"
rc=$?

echo ""
echo "Tip: open http://127.0.0.1:3174/ for stage UI (Clarify → Send → Wait → Decide)."
echo "Full schedule health: $BASE/status.sh"
exit $rc
