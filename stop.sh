#!/bin/zsh
# Manually stop the recruiting automation early (before the 36h window or a halt fires on its own).
set -uo pipefail

BASE="$HOME/workspace-recruiting-automation/recruiting-automation"
PLIST_LABEL="com.sbecker11.recruiting-automation"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "manually stopped at $(date +"%Y-%m-%d %H:%M:%S %z")" > "$BASE/state/HALT"
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
echo "Stopped and unloaded $PLIST_LABEL."
