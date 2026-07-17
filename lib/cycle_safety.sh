#!/bin/zsh
#
# Shared safety-net logic for run_cycle.sh, factored out into its own
# sourceable file (2026-07-13) specifically so tests/*.bats can exercise it
# directly against a throwaway sandbox — fake BASE dir, fake PLIST_LABEL,
# fake commands standing in for the real comms-migration/job-tracker steps —
# without ever touching the real production LaunchAgent or making a live
# Gmail/Anthropic call. run_cycle.sh sources this unchanged for production
# use; nothing in here should assume it's only ever used there.
#
# Expects these variables already set by the caller before sourcing:
#   LOG                - path to this cycle's log file (must exist/be creatable)
#   HALT_FILE          - sentinel path
#   EXPIRY_FILE        - 48h-window expiry-epoch path
#   PLIST_LABEL        - launchd label to unload on halt/expiry
#   PLIST_PATH         - path to that label's plist (unload fallback)
#   STEP_TIMEOUT_SECS  - per-step timeout in seconds
#   TIMEOUT_BIN        - absolute path to the `timeout` binary

log() {
  echo "[$(date +"%Y-%m-%d %H:%M:%S %z")] $*" | tee -a "$LOG"
}

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# Shell equivalent of a Java shutdown hook / C atexit(): SIGTERM is what
# launchd/macOS sends first on a normal shutdown or logout (SIGKILL only
# follows if we don't exit promptly, and can't be trapped at all). Without
# this, a shutdown mid-cycle just truncates the log with no explanation,
# indistinguishable later from a real hang. This is purely for a legible
# log entry — no HALT file, no unload, no notification: a shutdown isn't a
# pipeline failure, so the schedule should come back naturally next login
# (see ensure_running.sh) or next hourly tick if the Mac never went away.
shutdown_trap() {
  log "Received SIGTERM (likely system shutdown/logout) — exiting cleanly, no HALT written."
  exit 0
}

unload_self() {
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >>"$LOG" 2>&1 \
    || launchctl unload "$PLIST_PATH" >>"$LOG" 2>&1 \
    || true
}

stop_schedule() {
  local reason="$1"
  log "STOPPING SCHEDULE: $reason"
  unload_self
  notify "Recruiting automation stopped" "$reason"
  exit 1
}

# Halt sentinel or expired window -> log + unload + exit 1. Only returns
# (without exiting) when neither condition applies, letting the caller
# proceed into its real cycle.
preflight_check() {
  if [[ -f "$HALT_FILE" ]]; then
    log "HALT sentinel present: $(cat "$HALT_FILE")"
    log "Skipping this tick and unloading the schedule (already halted)."
    unload_self
    exit 1
  fi

  if [[ -f "$EXPIRY_FILE" ]]; then
    local now_epoch expiry_epoch
    now_epoch=$(date +%s)
    expiry_epoch=$(cat "$EXPIRY_FILE")
    if (( now_epoch >= expiry_epoch )); then
      log "48-hour window has expired (expiry was $(date -r "$expiry_epoch" 2>/dev/null || echo "$expiry_epoch"))."
      stop_schedule "48-hour window complete — ready for Monday triage."
    fi
  fi
}

run_step() {
  local desc="$1"; shift
  log "--- $desc ---"
  if "$TIMEOUT_BIN" "$STEP_TIMEOUT_SECS" "$@" >>"$LOG" 2>&1; then
    log "OK: $desc"
  else
    local rc=$?
    if (( rc == 124 )); then
      log "TIMED OUT: $desc (>${STEP_TIMEOUT_SECS}s — likely stuck waiting on an interactive OAuth login)"
      echo "$desc timed out after ${STEP_TIMEOUT_SECS}s at $(date +"%Y-%m-%d %H:%M:%S %z") — likely needs manual Google re-auth. See $LOG" > "$HALT_FILE"
      notify "Recruiting automation: step timed out" "$desc — likely needs manual Google sign-in. Schedule halted."
      stop_schedule "$desc timed out (likely needs manual OAuth re-auth)"
    fi
    log "FAILED: $desc (exit $rc)"
    echo "$desc failed (exit $rc) at $(date +"%Y-%m-%d %H:%M:%S %z") — see $LOG" > "$HALT_FILE"
    notify "Recruiting automation: step failed" "$desc (exit $rc). Schedule halted — see $LOG"
    stop_schedule "$desc failed (exit $rc)"
  fi
}
