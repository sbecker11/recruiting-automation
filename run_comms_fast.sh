#!/bin/zsh
# Fast lead-communications tick (every 3 minutes via LaunchAgent).
# Scans recruiting Gmail + personal_hub + Spexture IMAP, refreshes pending-actions,
# and fires a macOS notification when new inbound lead mail is archived.
# Does not open a browser tab (--no-open); the already-open React UI polls JSON.
set -uo pipefail

WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
JOBTRACKER_REPO="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$WORKSPACE_ROOT/job-tracker}"
LOGS_DIR="$BASE/logs"
mkdir -p "$LOGS_DIR" "$BASE/state"

LOG="$LOGS_DIR/comms_fast-$(date +%Y%m%d-%H%M%S).log"
{
  echo "=== comms_fast start $(date +"%Y-%m-%d %H:%M:%S %z") ==="
  cd "$JOBTRACKER_REPO" || exit 1
  # Prefer venv python (launchd PATH is minimal; nvm not sourced).
  PY="$JOBTRACKER_REPO/.venv/bin/python"
  if [[ ! -x "$PY" ]]; then
    PY="$(command -v python3 || true)"
  fi
  if [[ -z "$PY" || ! -x "$PY" ]]; then
    echo "comms_fast: python not found" >&2
    exit 1
  fi
  "$PY" scripts/comms_fast_cycle.py --no-open
  rc=$?
  echo "=== comms_fast end rc=$rc ==="
  exit $rc
} >>"$LOG" 2>&1
rc=$?
ln -sfn "$LOG" "$LOGS_DIR/comms_fast.log" 2>/dev/null || cp "$LOG" "$LOGS_DIR/comms_fast.log"
exit $rc
