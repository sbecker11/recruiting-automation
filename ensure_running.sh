#!/bin/zsh
#
# Run at every login (see com.sbecker11.recruiting-automation-login-check.plist,
# RunAtLoad-only, no interval): if the main hourly automation isn't currently
# loaded in launchd, or it IS loaded but a HALT sentinel is sitting there from
# a prior failure, or its 48-hour window has already expired, re-run
# install.sh to clear the halt and restart a fresh window.
#
# The expiry check matters on its own, not just as defense in depth: macOS
# reloads every plist under ~/Library/LaunchAgents (RunAtLoad) at login,
# including this one's sibling main-schedule plist, which races this script's
# is_loaded() check. If the window already expired before this login,
# run_cycle.sh's own preflight_check unloads itself again within about a
# second of being reloaded — but is_loaded() can sample "true" in that brief
# window before the unload lands, making a loaded-but-already-expired
# schedule look "healthy" and skip the restart entirely. (Caught 2026-07-15:
# a real logout/login did not recover an expired window because of exactly
# this race — see recruiting-automation repo history.) Checking expiry
# directly sidesteps the race: it doesn't matter whether is_loaded() won or
# lost that race, because an expired window always forces a restart here.
#
# Deliberately does NOT touch anything when the automation is already loaded,
# unhalted, and unexpired — this runs on every login (including ones where
# nothing is wrong), so it must be a safe no-op in the common case rather than
# always resetting the 48-hour window just because a login happened.
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/) —
# every one defaults to the real production path/label/script when unset.

set -uo pipefail

# See install.sh's comment on WORKSPACE_ROOT — single source of truth for
# the sibling-repos parent dir, shared across every script here.
WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
HALT_FILE="$BASE/state/HALT"
EXPIRY_FILE="$BASE/state/expiry_epoch"
LOG="$BASE/logs/login-check.log"
INSTALL_SCRIPT="${RECRUITING_AUTOMATION_INSTALL_SCRIPT:-$BASE/install.sh}"

mkdir -p "$BASE/logs"

log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S %z")] $*" >> "$LOG"
}

is_loaded() {
  launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
}

is_expired() {
  [[ -f "$EXPIRY_FILE" ]] || return 1
  local expiry_epoch now_epoch
  expiry_epoch=$(cat "$EXPIRY_FILE")
  now_epoch=$(date +%s)
  (( now_epoch >= expiry_epoch ))
}

if is_loaded && [[ ! -f "$HALT_FILE" ]] && ! is_expired; then
  log "login check: already loaded and healthy, nothing to do."
  exit 0
fi

if [[ -f "$HALT_FILE" ]]; then
  REASON="HALT sentinel present ($(cat "$HALT_FILE"))"
elif is_expired; then
  REASON="48-hour window expired ($(date -r "$(cat "$EXPIRY_FILE")" 2>/dev/null || cat "$EXPIRY_FILE"))"
else
  REASON="not loaded"
fi
log "login check: $REASON — restarting."

RECRUITING_AUTOMATION_INSTALL_REASON="login-check: $REASON" "$INSTALL_SCRIPT" >> "$LOG" 2>&1
log "login check: restart complete."
