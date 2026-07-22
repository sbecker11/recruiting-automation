#!/bin/zsh
#
# One tick of the 48-hour recruiting automation window:
#   comms-migration classify (personal_hub, then recruiting_funnel w/ spam sweep, live+LLM fallback)
#   -> job-tracker triage_recruiter_inbox.py (live, LLM eval + generation on pursue)
#   -> job-tracker scan_communications.py (LinkedIn replies + Sent-folder matches)
#   -> job-tracker process_awaiting_llm_review.py (full-LLM-review sweep for stuck leads)
#   -> job-tracker resync_labels.py (re-sync stale JobTracker/* labels)
#   -> job-tracker render_pending_actions.py (static HTML refresh)
#
# Safety behavior (see lib/cycle_safety.sh for the implementation, factored
# out so tests/*.bats can exercise it in isolation):
#   - Every step runs in sequence; the FIRST non-zero exit halts the whole
#     cycle immediately (remaining steps in this tick are skipped).
#   - On halt (error) or once the 48-hour window has expired, this script
#     writes/finds a sentinel and unloads its own LaunchAgent so the hourly
#     schedule stops calling it — no silent retries, no runaway spend.
#   - Every tick's full output is captured to its own timestamped log file
#     under logs/ for Monday's triage.
#
# All RECRUITING_AUTOMATION_* env vars below are test-only overrides — every
# one defaults to the real production path/label when unset, so normal
# (launchd- or manually-invoked) runs are unaffected.

set -uo pipefail

# See install.sh's comment on WORKSPACE_ROOT — single source of truth for
# the sibling-repos parent dir, shared across every script here. Exported
# (not just set) so it also reaches the comms-migration/job-tracker Python
# subprocesses run_step invokes below — both packages' __init__.py check
# this same var before falling back to their own file-relative derivation,
# so a WORKSPACE_ROOT override here stays consistent end-to-end rather than
# only affecting which repo run_cycle.sh itself calls into.
WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
export RECRUITING_AUTOMATION_WORKSPACE_ROOT="$WORKSPACE_ROOT"
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
STATE_DIR="$BASE/state"
LOGS_DIR="$BASE/logs"
HALT_FILE="$STATE_DIR/HALT"
EXPIRY_FILE="$STATE_DIR/expiry_epoch"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
PLIST_PATH="${RECRUITING_AUTOMATION_PLIST_PATH:-$HOME/Library/LaunchAgents/$PLIST_LABEL.plist}"

COMMS_REPO="${RECRUITING_AUTOMATION_COMMS_REPO:-$WORKSPACE_ROOT/comms-migration}"
JOBTRACKER_REPO="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$WORKSPACE_ROOT/job-tracker}"

mkdir -p "$LOGS_DIR" "$STATE_DIR"

LOG="$LOGS_DIR/run-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG"

# Guards against a step HANGING (e.g. an OAuth refresh token hit its 7-day
# "Testing app" hard expiry and the code fell back to an interactive browser
# login that nobody unattended can complete) rather than failing outright.
# Without this, a hang wouldn't trip the halt-on-error logic below at all —
# it would just silently freeze the schedule for the rest of the window.
#
# Raised 900s -> 1800s (2026-07-18): a real production run legitimately took
# the full 900s and got killed mid-batch — several dense multi-JD digest
# emails in one hour, each needing its own chain of extract/evaluate/generate
# LLM calls, not a stuck OAuth prompt (verified live: Gmail auth succeeded in
# ~2s immediately after). Every other cycle in the surrounding week finished
# in 1-60s, so 1800s still leaves ample margin under the hourly StartInterval
# (3600s) — no risk of two cycles overlapping — while giving a legitimately
# heavy batch enough runway not to trip a false-positive halt.
STEP_TIMEOUT_SECS="${RECRUITING_AUTOMATION_STEP_TIMEOUT_SECS:-1800}"
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

# --include-spam (2026-07-21): verified live that a real recruiter's JD
# email (CRB Workforce, re: DIRECTV) landed in Spam and sat invisible to
# every part of this pipeline for a full day — Gmail search excludes
# Spam/Trash unless asked, and this account's DEFAULT_QUERY is `in:inbox`.
# Rules first (free), then a high-confidence-only LLM fallback (see
# classifier/run.py's module docstring) since the motivating case came from
# a one-off agency domain with no existing sender rule. --spam-categories
# recruiter_job keeps the automated sweep from also pulling political/ai/
# spam_unknown mail out of Spam just because it was confidently
# classifiable as *something* — only mail this pipeline actually cares
# about gets rescued. Each spam message is only ever classified once
# (classifier/spam_sweep_state.py), so recurring cost is bounded by new
# spam volume, not by re-scanning an unchanged backlog every hour.
#
# --spam-limit 100 (added 2026-07-22, after this exact step timed out and
# unloaded its own LaunchAgent the first time it ran unbounded): with no
# limit, the very first sweep hit the *entire* unresolved Spam backlog
# (834 LLM calls) and blew straight through the 1800s step timeout below.
# The normal (no-spam) version of this same step usually finishes in
# ~10-15s (steady-state inbox volume is low), so 100 spam messages/cycle
# (~a few minutes worst-case, at ~2s/LLM-call) leaves a wide safety margin
# while still working through even a large backlog within a handful of
# hourly cycles — the persistent seen-cache means nothing already-scanned
# gets re-billed on the next cycle.
run_step "comms-migration: classify recruiting_funnel (live, LLM fallback default-on, spam sweep)" \
  zsh -c "cd '$COMMS_REPO' && source .venv/bin/activate && exec python3 scripts/run_classifier.py --account recruiting_funnel --limit 300 --include-spam --spam-limit 100 --spam-categories recruiter_job"

run_step "job-tracker: triage_recruiter_inbox (live, LLM eval + llm-fallback extraction + auto-generate on pursue)" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/triage_recruiter_inbox.py --llm-fallback --limit 100"

# Archives the recruiter/LinkedIn traffic the step above never sees (mail
# comms-migration deliberately routes to Category/social instead of
# Category/recruiter_job — see scan_communications.py's module docstring
# for the 2026-07-17 incident that motivated this). --include-sent is Tier-1
# (thread id / known contact) only, never bills an LLM call, so it's safe to
# run every cycle; --llm-fallback on the inbound side is opt-in-but-on here
# since a haiku-tier cached-by-message_id call is cheap relative to the cost
# of a real reply sitting untracked.
run_step "job-tracker: scan_communications (LinkedIn replies + Sent-folder thread matches)" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/scan_communications.py --llm-fallback --include-sent --newer-than 3"

# Closes the "Awaiting full-LLM-review" loop (2026-07-19) — leads whose free
# rule-based score already cleared the LLM-review gate but never got the
# real LLM call, most commonly scan_communications's own stub leads (that
# step deliberately stops at a rule-based score only, see its "No happy
# path" docstring) but also any digest lead the LLM call hadn't reached yet
# at initial triage. Verified live: 21 leads sitting in this exact state,
# several 12+ days old, with nothing in this cycle ever revisiting them
# before this step existed. Runs the same apply_package.py two-tier
# pipeline per lead (full review always, résumé+cover-letter only on an
# actual "pursue"), so cost is bounded by however many leads are actually
# eligible, not a flat rate — see cli/process_awaiting_llm_review.py.
run_step "job-tracker: process_awaiting_llm_review (full-LLM-review sweep for leads stuck past the score gate)" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/process_awaiting_llm_review.py"

# Re-syncs each already-triaged message's JobTracker/PURSUE|SKIP|
# NEEDS_REVIEW label to its lead(s)' CURRENT verdict (2026-07-19) — without
# this, a label frozen at initial-triage time silently goes stale the moment
# a later full-LLM-review or manual status change disagrees with it, which
# defeats the point of trusting Gmail's own label state at all. Pure label
# swap (no re-evaluation, no LLM spend, no INBOX/archive changes) — cheap
# enough to run every cycle. See cli/resync_labels.py's module docstring.
run_step "job-tracker: resync_labels (re-sync stale JobTracker/* labels to current verdicts)" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/resync_labels.py"

run_step "job-tracker: render_pending_actions" \
  zsh -c "cd '$JOBTRACKER_REPO' && source .venv/bin/activate && exec python3 scripts/render_pending_actions.py"

log "=== Cycle complete ==="
