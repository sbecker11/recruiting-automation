#!/bin/zsh
# Quick status check: is the schedule loaded, is it halted, how much time is left, latest log tail.
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/).
set -uo pipefail

BASE="${RECRUITING_AUTOMATION_BASE:-$HOME/workspace-recruiting-automation/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"

echo "--- launchd status ---"
launchctl print "gui/$(id -u)/$PLIST_LABEL" 2>&1 | head -20 || echo "(not loaded)"

echo ""
echo "--- halt sentinel ---"
if [[ -f "$BASE/state/HALT" ]]; then
  echo "HALTED: $(cat "$BASE/state/HALT")"
else
  echo "not halted"
fi

echo ""
echo "--- expiry ---"
if [[ -f "$BASE/state/expiry_epoch" ]]; then
  expiry_epoch=$(cat "$BASE/state/expiry_epoch")
  now_epoch=$(date +%s)
  remaining=$(( expiry_epoch - now_epoch ))
  echo "expires: $(date -r "$expiry_epoch")"
  if (( remaining > 0 )); then
    echo "remaining: $(( remaining / 3600 ))h $(( (remaining % 3600) / 60 ))m"
  else
    echo "remaining: EXPIRED"
  fi
fi

echo ""
echo "--- latest log ---"
latest=$(ls -t "$BASE/logs"/*.log 2>/dev/null | head -1)
if [[ -n "${latest:-}" ]]; then
  echo "$latest"
  tail -30 "$latest"
else
  echo "(no logs yet)"
fi
