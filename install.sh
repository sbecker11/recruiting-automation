#!/bin/zsh
# Install and start the 36-hour recruiting automation window.
# Safe to re-run: clears any prior HALT sentinel and resets the 36h clock from "now".
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/) —
# every one defaults to the real production path/label when unset.
set -uo pipefail

BASE="${RECRUITING_AUTOMATION_BASE:-$HOME/workspace-recruiting-automation/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
PLIST_PATH="${RECRUITING_AUTOMATION_PLIST_PATH:-$HOME/Library/LaunchAgents/$PLIST_LABEL.plist}"
WINDOW_HOURS=${1:-36}

mkdir -p "$BASE/state" "$BASE/logs"
rm -f "$BASE/state/HALT"

now_epoch=$(date +%s)
expiry_epoch=$(( now_epoch + WINDOW_HOURS * 3600 ))
echo "$expiry_epoch" > "$BASE/state/expiry_epoch"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BASE/run_cycle.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$BASE/logs/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$BASE/logs/launchd.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "Installed and loaded $PLIST_LABEL."
echo "Window: $WINDOW_HOURS hours, expires $(date -r "$expiry_epoch")."
echo "First cycle runs immediately (RunAtLoad), then hourly."
echo "Status:  $BASE/status.sh"
echo "Stop early: $BASE/stop.sh"
