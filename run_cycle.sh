#!/bin/zsh
#
# One tick of the 36-hour recruiting automation window:
#   comms-migration classify (personal_hub, then recruiting_funnel, live+LLM fallback)
#   -> job-tracker triage_recruiter_inbox.py (live, LLM eval + generation on pursue)
#   -> job-tracker render_pending_actions.py (static HTML refresh)
#
# Safety behavior:
#   - Every step runs in sequence; the FIRST non-zero exit halts the whole
#     cycle immediately (remaining steps in this tick are skipped).
#   - On halt (error) or once the 36-hour window has expired, this script
#     writes/finds a sentinel and unloads its own LaunchAgent so the hourly
#     schedule stops calling it — no silent retries, no runaway spend.
#   - Every tick's full output is captured to its own timestamped log file
#     under logs/ for Monday's triage.

set -uo pipefail

BASE="$HOME/workspace-recruiting-automation/recruiting-automation"
STATE_DIR="$BASE/state"
LOGS_DIR="$BASE/logs"
HALT_FILE="$STATE_DIR/HALT"
EXPIRY_FILE="$STATE_DIR/expiry_epoch"
PLIST_LABEL="com.sbecker11.recruiting-automation"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

COMMS_REPO="$HOME/workspace-recruiting-automation/comms-migration"
JOBTRACKER_REPO="$HOME/workspace-recruiting-automation/job-tracker"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

LOG="$LOGS_DIR/run-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG"

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
trap shutdown_trap SIGTERM

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

# --- Pre-flight: halt sentinel or expired window means no-op + unload ---
if [[ -f "$HALT_FILE" ]]; then
  log "HALT sentinel present: $(cat "$HALT_FILE")"
  log "Skipping this tick and unloading the schedule (already halted)."
  unload_self
  exit 1
fi

if [[ -f "$EXPIRY_FILE" ]]; then
  now_epoch=$(date +%s)
  expiry_epoch=$(cat "$EXPIRY_FILE")
  if (( now_epoch >= expiry_epoch )); then
    log "36-hour window has expired (expiry was $(date -r "$expiry_epoch" 2>/dev/null || echo "$expiry_epoch"))."
    stop_schedule "36-hour window complete — ready for Monday triage."
  fi
fi

log "=== Cycle start ==="

# Guards against a step HANGING (e.g. an OAuth refresh token hit its 7-day
# "Testing app" hard expiry and the code fell back to an interactive browser
# login that nobody unattended can complete) rather than failing outright.
# Without this, a hang wouldn't trip the halt-on-error logic below at all —
# it would just silently freeze the schedule for the rest of the window.
STEP_TIMEOUT_SECS=900
TIMEOUT_BIN="/usr/local/bin/timeout"

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

# `exec` on the final command matters here: it replaces the zsh wrapper's
# process image with python3 instead of running it as a child, so when
# `timeout` sends SIGTERM to the wrapper, python3 receives it directly
# rather than being orphaned while a stuck zsh gets killed out from under it.
run_step "comms-migration: classify personal_hub (live, LLM fallback default-on)" \
  zsh -c "cd '$COMMS_REPO' && source .venv/bin/activate && exec python3 scripts/run_classifier.py --account personal_hub --limit 300"

run_step "comms-migration: classify recruiting_funnel (live, LLM fallback default-on)" \
  zsh -c "cd '$COMMS_REPO' && source .venv/bin/activate && exec python3 scripts/run_classifier.py --account recruiting_funnel --limit 300"

run_step "job-tracker: triage_recruiter_inbox (live, LLM eval + llm-fallback extraction + auto-generate on pursue)" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/triage_recruiter_inbox.py --llm-fallback --limit 100"

run_step "job-tracker: render_pending_actions" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/render_pending_actions.py"

log "=== Cycle complete ==="
