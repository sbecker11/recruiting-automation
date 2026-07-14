#!/bin/zsh
#
# One tick of the 36-hour recruiting automation window:
#   comms-migration classify (personal_hub, then recruiting_funnel, live+LLM fallback)
#   -> job-tracker triage_recruiter_inbox.py (live, LLM eval + generation on pursue)
#   -> job-tracker render_pending_actions.py (static HTML refresh)
#
# Safety behavior (see lib/cycle_safety.sh for the implementation, factored
# out so tests/*.bats can exercise it in isolation):
#   - Every step runs in sequence; the FIRST non-zero exit halts the whole
#     cycle immediately (remaining steps in this tick are skipped).
#   - On halt (error) or once the 36-hour window has expired, this script
#     writes/finds a sentinel and unloads its own LaunchAgent so the hourly
#     schedule stops calling it — no silent retries, no runaway spend.
#   - Every tick's full output is captured to its own timestamped log file
#     under logs/ for Monday's triage.
#
# All RECRUITING_AUTOMATION_* env vars below are test-only overrides — every
# one defaults to the real production path/label when unset, so normal
# (launchd- or manually-invoked) runs are unaffected.

set -uo pipefail

BASE="${RECRUITING_AUTOMATION_BASE:-$HOME/workspace-recruiting-automation/recruiting-automation}"
STATE_DIR="$BASE/state"
LOGS_DIR="$BASE/logs"
HALT_FILE="$STATE_DIR/HALT"
EXPIRY_FILE="$STATE_DIR/expiry_epoch"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
PLIST_PATH="${RECRUITING_AUTOMATION_PLIST_PATH:-$HOME/Library/LaunchAgents/$PLIST_LABEL.plist}"

COMMS_REPO="${RECRUITING_AUTOMATION_COMMS_REPO:-$HOME/workspace-recruiting-automation/comms-migration}"
JOBTRACKER_REPO="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$HOME/workspace-recruiting-automation/job-tracker}"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

LOG="$LOGS_DIR/run-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG"

# Guards against a step HANGING (e.g. an OAuth refresh token hit its 7-day
# "Testing app" hard expiry and the code fell back to an interactive browser
# login that nobody unattended can complete) rather than failing outright.
# Without this, a hang wouldn't trip the halt-on-error logic below at all —
# it would just silently freeze the schedule for the rest of the window.
STEP_TIMEOUT_SECS="${RECRUITING_AUTOMATION_STEP_TIMEOUT_SECS:-900}"
TIMEOUT_BIN="/usr/local/bin/timeout"

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib/cycle_safety.sh"

trap shutdown_trap SIGTERM

preflight_check

log "=== Cycle start ==="

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
