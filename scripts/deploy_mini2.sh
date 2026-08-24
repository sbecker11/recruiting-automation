#!/bin/zsh
# Routine deploy for mini2 (or any production host).
# Pulls all three sibling repos, refreshes job-tracker venv, verifies health.
#
#   ./scripts/deploy_mini2.sh
#
set -uo pipefail

WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="$WORKSPACE_ROOT/recruiting-automation"

echo "=== Deploy recruiting pipeline ==="
echo "workspace: $WORKSPACE_ROOT"
echo ""

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
echo "--- decision briefing (optional) ---"
echo "Run: cd $BASE && ./monday.sh"
echo "Deploy complete."
