#!/usr/bin/env bats
#
# job-tracker/docs/REQUIREMENTS.md SYS-1, SYS-3 (hourly side), SYS-4, SYS-5.
# Static checks on run_cycle.sh / run_comms_fast.sh plus run_step's lock
# retry in a sandbox — nothing here runs a real pipeline step.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CYCLE="$REPO_ROOT/run_cycle.sh"
  TEST_DIR="$(mktemp -d)"
  LOG="$TEST_DIR/cycle.log"
  HALT_FILE="$TEST_DIR/HALT"
  touch "$LOG"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "SYS-1: hourly steps run in the documented order" {
  run zsh -c "grep -o 'run_step \"[^:]*: [a-z_]*' '$CYCLE' | sed 's/.*: //'"
  [ "$status" -eq 0 ]
  expected="classify
triage_recruiter_inbox
scan_communications
triage_imap_inbox
triage_imap_inbox
promote_unmatched_llm
auto_skip_leads
process_awaiting_llm_review
extract_required_skills
resync_labels
render_pending_actions
render_contacts"
  [ "$output" = "$expected" ]
  grep -q 'run_step "job-tracker: triage_imap_inbox (shawn.becker@spexture.com' "$CYCLE"
  grep -q 'run_step "job-tracker: triage_imap_inbox (sbecker11@icloud.com' "$CYCLE"
}

@test "SYS-3: every hourly job-tracker step that writes leads.db goes through the DB lock" {
  grep -q 'DB_LOCK_PREFIX="exec python3 scripts/with_db_lock.py --lock var/comms_fast.lock' "$CYCLE"
  # resync_labels (Gmail labels only) and render_contacts (read-only) skip the
  # lock; extract_required_skills takes it per write via --lock instead.
  run zsh -c "grep \"cd '\\\$JOBTRACKER_REPO'\" '$CYCLE' | grep -v 'DB_LOCK_PREFIX' | grep -v -e 'scripts/resync_labels.py' -e 'scripts/render_contacts.py' -e 'scripts/extract_required_skills.py --apply --create-folders --lock var/comms_fast.lock'"
  [ -z "$output" ]
}

@test "SYS-4: per-step hard timeout defaults to 1800s" {
  grep -q 'STEP_STALL_KILL_SECS="${RECRUITING_AUTOMATION_STEP_STALL_KILL_SECS:-${RECRUITING_AUTOMATION_STEP_TIMEOUT_SECS:-1800}}"' "$CYCLE"
}

@test "SYS-4: exit 75 (DB lock busy) retries once, then succeeds without HALT" {
  counter="$TEST_DIR/attempts"
  cat > "$TEST_DIR/step.sh" <<EOF
#!/bin/zsh
n=\$(cat '$counter' 2>/dev/null || echo 0)
echo \$((n+1)) > '$counter'
(( n >= 1 )) || exit 75
EOF
  chmod +x "$TEST_DIR/step.sh"
  run env LOG="$LOG" HALT_FILE="$HALT_FILE" STEP_STALL_KILL_SECS=10 \
    TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)" \
    PLIST_LABEL="com.sbecker11.recruiting-automation-TEST-$$" PLIST_PATH="$TEST_DIR/fake.plist" \
    zsh -c "source '$REPO_ROOT/lib/cycle_safety.sh'; sleep() { :; }; run_step 'lock retry' '$TEST_DIR/step.sh'"
  [ "$status" -eq 0 ]
  [ "$(cat "$counter")" = "2" ]
  grep -q "DB lock busy (exit 75)" "$LOG"
  [[ ! -f "$HALT_FILE" ]]
}

@test "SYS-4: exit 75 twice in a row HALTs" {
  run env LOG="$LOG" HALT_FILE="$HALT_FILE" STEP_STALL_KILL_SECS=10 \
    TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)" \
    PLIST_LABEL="com.sbecker11.recruiting-automation-TEST-$$" PLIST_PATH="$TEST_DIR/fake.plist" \
    zsh -c "source '$REPO_ROOT/lib/cycle_safety.sh'; sleep() { :; }; run_step 'always busy' zsh -c 'exit 75'"
  [ "$status" -eq 1 ]
  grep -q "always busy failed (exit 75)" "$HALT_FILE"
}

@test "SYS-5: the 3-minute intake tick never checks HALT" {
  ! grep -q HALT "$REPO_ROOT/run_comms_fast.sh"
  ! grep -q HALT "$REPO_ROOT/../job-tracker/scripts/comms_fast_cycle.py"
}

@test "SYS-5: stop.sh halts only the hourly schedule, not the intake tick" {
  ! grep -q "comms-fast\|comms_fast" "$REPO_ROOT/stop.sh"
}
