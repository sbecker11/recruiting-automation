#!/bin/zsh
# Manually stop the recruiting automation early (before the 48h window or a halt fires on its own).
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/).
set -uo pipefail

# See install.sh's comment on WORKSPACE_ROOT — single source of truth for
# the sibling-repos parent dir, shared across every script here.
WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
PLIST_PATH="${RECRUITING_AUTOMATION_PLIST_PATH:-$HOME/Library/LaunchAgents/$PLIST_LABEL.plist}"

echo "manually stopped at $(date +"%Y-%m-%d %H:%M:%S %z")" > "$BASE/state/HALT"
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
echo "Stopped and unloaded $PLIST_LABEL."
