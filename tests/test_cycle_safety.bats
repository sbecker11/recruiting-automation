#!/usr/bin/env bats
#
# Unit tests for lib/cycle_safety.sh — every test sources it fresh inside its
# own `zsh -c` subprocess via bats' `run` (required for the functions that
# call `exit`, e.g. preflight_check/stop_schedule — calling those directly
# in bats' own shell would kill the test run itself), with LOG/HALT_FILE/
# EXPIRY_FILE/PLIST_LABEL/PLIST_PATH all pointed at a throwaway tmp sandbox.
# Never touches the real production LaunchAgent, and run_step's "commands"
# here are always harmless builtins (true/false/sleep) standing in for the
# real comms-migration/job-tracker invocations — this suite is about the
# safety-net logic, not the pipeline steps themselves.

setup() {
  TEST_DIR="$(mktemp -d)"
  LOG="$TEST_DIR/cycle.log"
  HALT_FILE="$TEST_DIR/HALT"
  EXPIRY_FILE="$TEST_DIR/expiry_epoch"
  # A label guaranteed not to correspond to any real LaunchAgent, so
  # unload_self's launchctl calls harmlessly no-op (both already have
  # `|| true` fallbacks) instead of ever touching production.
  PLIST_LABEL="com.sbecker11.recruiting-automation-TEST-$$"
  PLIST_PATH="$TEST_DIR/fake.plist"
  STEP_TIMEOUT_SECS=5
  TIMEOUT_BIN="/usr/local/bin/timeout"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  touch "$LOG"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Runs `zsh -c "$1"` with the standard sandbox env + cycle_safety.sh
# pre-sourced, capturing status/output via bats' `run`.
run_in_sandbox() {
  run env \
    LOG="$LOG" HALT_FILE="$HALT_FILE" EXPIRY_FILE="$EXPIRY_FILE" \
    PLIST_LABEL="$PLIST_LABEL" PLIST_PATH="$PLIST_PATH" \
    STEP_TIMEOUT_SECS="$STEP_TIMEOUT_SECS" TIMEOUT_BIN="$TIMEOUT_BIN" \
    zsh -c "source '$REPO_ROOT/lib/cycle_safety.sh'; $1"
}

@test "run_step logs OK and does not touch HALT_FILE on success" {
  run_in_sandbox "run_step 'a trivial success' true"
  [ "$status" -eq 0 ]
  grep -q "OK: a trivial success" "$LOG"
  [[ ! -f "$HALT_FILE" ]]
}

@test "run_step writes HALT_FILE and exits 1 on failure" {
  run_in_sandbox "run_step 'a trivial failure' false"
  [ "$status" -eq 1 ]
  [[ -f "$HALT_FILE" ]]
  grep -q "a trivial failure failed" "$HALT_FILE"
}

@test "run_step marks a timeout distinctly from a plain failure" {
  STEP_TIMEOUT_SECS=1
  run_in_sandbox "run_step 'a slow step' sleep 5"
  [ "$status" -eq 1 ]
  [[ -f "$HALT_FILE" ]]
  grep -q "timed out" "$HALT_FILE"
}

@test "preflight_check returns (does not exit) when neither HALT nor expiry apply" {
  run_in_sandbox "preflight_check; echo REACHED_AFTER_PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_AFTER_PREFLIGHT"* ]]
}

@test "preflight_check exits 1 and logs when HALT_FILE is present" {
  echo "some prior failure" > "$HALT_FILE"
  run_in_sandbox "preflight_check; echo REACHED_AFTER_PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" != *"REACHED_AFTER_PREFLIGHT"* ]]
  [[ "$output" == *"HALT sentinel present"* ]]
}

@test "preflight_check stops the schedule when the expiry window has passed" {
  echo "$(( $(date +%s) - 60 ))" > "$EXPIRY_FILE"
  run_in_sandbox "preflight_check; echo REACHED_AFTER_PREFLIGHT"
  [ "$status" -eq 1 ]
  [[ "$output" != *"REACHED_AFTER_PREFLIGHT"* ]]
  [[ "$output" == *"36-hour window has expired"* ]]
}

@test "preflight_check proceeds when the expiry window has NOT passed yet" {
  echo "$(( $(date +%s) + 3600 ))" > "$EXPIRY_FILE"
  run_in_sandbox "preflight_check; echo REACHED_AFTER_PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REACHED_AFTER_PREFLIGHT"* ]]
}

@test "shutdown_trap fires on SIGTERM to the whole process tree, exits 0, writes no HALT" {
  # Real shutdown/logout signals every process directly (not just the top of
  # a job's process group), so the meaningful test sends SIGTERM to the
  # wrapper AND its blocked child together — mirrors how this fix was first
  # verified manually (see README's venv/move history for that context).
  cat > "$TEST_DIR/harness.sh" <<HARNESS
#!/bin/zsh
set -uo pipefail
LOG="$LOG"; HALT_FILE="$HALT_FILE"; EXPIRY_FILE="$EXPIRY_FILE"
PLIST_LABEL="$PLIST_LABEL"; PLIST_PATH="$PLIST_PATH"
STEP_TIMEOUT_SECS=300; TIMEOUT_BIN="$TIMEOUT_BIN"
source "$REPO_ROOT/lib/cycle_safety.sh"
trap shutdown_trap SIGTERM
log "harness start"
"\$TIMEOUT_BIN" "\$STEP_TIMEOUT_SECS" sleep 300
log "unreachable"
HARNESS
  chmod +x "$TEST_DIR/harness.sh"

  "$TEST_DIR/harness.sh" &
  local harness_pid=$!
  sleep 1
  local child_pid grandchild_pid
  child_pid=$(pgrep -P "$harness_pid" | head -1)
  grandchild_pid=$(pgrep -P "$child_pid" | head -1)

  kill -TERM "$harness_pid" "$child_pid" "$grandchild_pid" 2>/dev/null
  wait "$harness_pid" 2>/dev/null
  local exit_code=$?

  [ "$exit_code" -eq 0 ]
  [[ ! -f "$HALT_FILE" ]]
  grep -q "Received SIGTERM" "$LOG"
  run grep -q "unreachable" "$LOG"
  [ "$status" -ne 0 ]
}
