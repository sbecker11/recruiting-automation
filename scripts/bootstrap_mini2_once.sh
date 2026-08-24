#!/bin/zsh
# ONE-TIME bootstrap for mini2 after Phases 0–6 migration push.
# Pull this script via:  cd recruiting-automation && git pull origin main
# Run between cycles:    ./scripts/bootstrap_mini2_once.sh
# Then delete this file from the repo (it is not needed again).
#
set -uo pipefail

WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="$WORKSPACE_ROOT/recruiting-automation"

echo "=== ONE-TIME mini2 bootstrap (Phases 0–6) ==="
echo "workspace: $WORKSPACE_ROOT"
echo ""
echo "Confirm the pipeline is idle before continuing (latest log should end with"
echo "  === Cycle complete ===). Press Ctrl-C to abort, Enter to continue."
read -r _

for r in comms-migration job-tracker recruiting-automation; do
  echo "--- git pull $r ---"
  git -C "$WORKSPACE_ROOT/$r" pull --ff-only origin main
done

echo ""
echo "--- pip install job-tracker ---"
cd "$WORKSPACE_ROOT/job-tracker"
if [[ ! -d .venv ]]; then
  python3.12 -m venv .venv || python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -U pip
pip install -q -e ".[dev]"

echo ""
echo "--- health check ---"
cd "$BASE"
./status.sh

echo ""
echo "--- decision briefing ---"
./monday.sh

echo ""
echo "=== Bootstrap complete ==="
echo "Next: remove scripts/bootstrap_mini2_once.sh from git (one-time only)."
echo "Future deploys: ./scripts/deploy_mini2.sh"
