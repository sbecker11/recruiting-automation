#!/bin/zsh
# Unload the 3-minute lead-comms LaunchAgent (plist left in place).
set -uo pipefail

LABEL="${RECRUITING_AUTOMATION_COMMS_FAST_LABEL:-com.sbecker11.recruiting-automation.comms-fast}"
PLIST_PATH="${RECRUITING_AUTOMATION_COMMS_FAST_PLIST_PATH:-$HOME/Library/LaunchAgents/$LABEL.plist}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
  || launchctl unload "$PLIST_PATH" 2>/dev/null \
  || true

echo "Stopped: $LABEL"
echo "Re-start with: $(dirname "$0")/install_comms_fast.sh"
