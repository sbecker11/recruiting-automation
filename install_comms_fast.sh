#!/bin/zsh
# Install/reload the 3-minute lead-comms LaunchAgent.
set -uo pipefail

WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
LABEL="${RECRUITING_AUTOMATION_COMMS_FAST_LABEL:-com.sbecker11.recruiting-automation.comms-fast}"
PLIST_PATH="${RECRUITING_AUTOMATION_COMMS_FAST_PLIST_PATH:-$HOME/Library/LaunchAgents/$LABEL.plist}"
INTERVAL="${RECRUITING_AUTOMATION_COMMS_FAST_INTERVAL:-180}"

mkdir -p "$BASE/logs" "$BASE/state"
chmod +x "$BASE/run_comms_fast.sh" "$BASE/stop_comms_fast.sh" 2>/dev/null || true

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BASE/run_comms_fast.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$BASE/logs/comms_fast.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$BASE/logs/comms_fast.launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Installed: $PLIST_PATH"
echo "Label:     $LABEL"
echo "Interval:  ${INTERVAL}s (default 180 = 3 min)"
echo "Runs now (RunAtLoad), then every ${INTERVAL}s."
echo "Stop with: $BASE/stop_comms_fast.sh"
echo "Logs:      $BASE/logs/comms_fast.log"
echo "UI open:   http://127.0.0.1:3174/ on each new inbound alert"
