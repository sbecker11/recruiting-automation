#!/bin/zsh
#
# Run at every login (see com.sbecker11.recruiting-automation-login-check.plist,
# RunAtLoad-only, no interval): if the main hourly automation isn't currently
# loaded in launchd, or it IS loaded but a HALT sentinel is sitting there from
# a prior failure (run_cycle.sh unloads itself on halt, so "loaded" already
# implies "not halted" in practice — the HALT check here is just defense in
# depth against that invariant ever drifting), re-run install.sh to clear the
# halt and restart a fresh 36-hour window.
#
# Deliberately does NOT touch anything when the automation is already loaded
# and healthy — this runs on every login (including ones where nothing is
# wrong), so it must be a safe no-op in the common case rather than always
# resetting the 36-hour window just because a login happened.
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/) —
# every one defaults to the real production path/label/script when unset.

set -uo pipefail

BASE="${RECRUITING_AUTOMATION_BASE:-$HOME/workspace-recruiting-automation/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
HALT_FILE="$BASE/state/HALT"
LOG="$BASE/logs/login-check.log"
INSTALL_SCRIPT="${RECRUITING_AUTOMATION_INSTALL_SCRIPT:-$BASE/install.sh}"

mkdir -p "$BASE/logs"

log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S %z")] $*" >> "$LOG"
}

is_loaded() {
  launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
}

if is_loaded && [[ ! -f "$HALT_FILE" ]]; then
  log "login check: already loaded and healthy, nothing to do."
  exit 0
fi

if [[ -f "$HALT_FILE" ]]; then
  log "login check: HALT sentinel present ($(cat "$HALT_FILE")) — restarting."
else
  log "login check: not loaded — restarting."
fi

"$INSTALL_SCRIPT" >> "$LOG" 2>&1
log "login check: restart complete."
