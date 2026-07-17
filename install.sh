#!/bin/zsh
# Install and start the 48-hour recruiting automation window.
# Safe to re-run: clears any prior HALT sentinel and resets the 48h clock from "now".
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/) —
# every one defaults to the real production path/label when unset.
set -uo pipefail

# WORKSPACE_ROOT is the single source of truth for "where do the three
# sibling repos live" (added 2026-07-15) — every script here derives its own
# BASE/COMMS_REPO/JOBTRACKER_REPO default from it instead of each
# independently hardcoding "$HOME/workspace-recruiting-automation/...".
# RECRUITING_AUTOMATION_BASE below still wins outright if set directly
# (that's what every existing test does), so this is purely a shared
# fallback, not a behavior change for anything that already overrides BASE.
WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
PLIST_PATH="${RECRUITING_AUTOMATION_PLIST_PATH:-$HOME/Library/LaunchAgents/$PLIST_LABEL.plist}"

# Optional local override: WINDOW_HOURS can be set in .env (git-ignored, see
# .env.example) instead of editing/committing this script. Precedence is
# CLI arg > .env > the hardcoded 48h fallback below. Test sandboxes never
# have a $BASE/.env unless a test creates one, so this is a safe no-op there.
# WINDOW_SOURCE is tracked alongside the value purely for the install.log
# line below — so "why is the window N hours" is answerable later without
# having to reverse-engineer it from the CLI history or .env's git blame.
ENV_FILE="$BASE/.env"
WINDOW_HOURS_FROM_ENV=""
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
  WINDOW_HOURS_FROM_ENV="${WINDOW_HOURS:-}"
fi

if [[ -n "${1:-}" ]]; then
  WINDOW_HOURS="$1"
  WINDOW_SOURCE="CLI arg"
elif [[ -n "$WINDOW_HOURS_FROM_ENV" ]]; then
  WINDOW_HOURS="$WINDOW_HOURS_FROM_ENV"
  WINDOW_SOURCE=".env ($ENV_FILE)"
else
  WINDOW_HOURS=48
  WINDOW_SOURCE="hardcoded default"
fi

mkdir -p "$BASE/state" "$BASE/logs"
rm -f "$BASE/state/HALT"

now_epoch=$(date +%s)
expiry_epoch=$(( now_epoch + WINDOW_HOURS * 3600 ))
echo "$expiry_epoch" > "$BASE/state/expiry_epoch"
echo "$WINDOW_HOURS" > "$BASE/state/window_hours"

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

# Durable history of every (re)install — unlike the echoes below, which are
# lost the moment they scroll off a manually-run terminal (they're only
# captured when this script is invoked via ensure_running.sh, which appends
# its own stdout/stderr to logs/login-check.log). This is what makes "how
# many times has this window been reset, when, to what length, and why" a
# quick `tail logs/install.log` instead of cross-referencing timestamps
# across login-check.log/run-*.log/state/ by hand.
echo "[$(date +"%Y-%m-%d %H:%M:%S %z")] window=${WINDOW_HOURS}h source=\"$WINDOW_SOURCE\" expiry=\"$(date -r "$expiry_epoch")\" reason=\"${RECRUITING_AUTOMATION_INSTALL_REASON:-manual/direct invocation}\" pid=$$" >> "$BASE/logs/install.log"

echo "Installed and loaded $PLIST_LABEL."
echo "Window: $WINDOW_HOURS hours (source: $WINDOW_SOURCE), expires $(date -r "$expiry_epoch")."
echo "First cycle runs immediately (RunAtLoad), then hourly."
echo "Status:  $BASE/status.sh"
echo "Stop early: $BASE/stop.sh"
