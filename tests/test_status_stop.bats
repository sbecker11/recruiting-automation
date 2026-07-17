#!/usr/bin/env bats
#
# Sanity tests for status.sh and stop.sh against a throwaway BASE/
# PLIST_LABEL sandbox — a label guaranteed not to correspond to any real
# LaunchAgent, so both scripts' launchctl calls harmlessly report "not
# loaded" / no-op rather than ever touching production.

setup() {
  TEST_DIR="$(mktemp -d)"
  BASE="$TEST_DIR/base"
  mkdir -p "$BASE/state" "$BASE/logs"
  PLIST_LABEL="com.sbecker11.recruiting-automation-TEST-$$"
  PLIST_PATH="$TEST_DIR/fake.plist"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Deliberately nonexistent — status.sh's ANTHROPIC_API_KEY section must
  # degrade to "no .venv found — skipped" for these rather than ever
  # touching the real job-tracker/comms-migration repos or their venvs.
  FAKE_COMMS_REPO="$TEST_DIR/no-such-comms-migration"
  FAKE_JOBTRACKER_REPO="$TEST_DIR/no-such-job-tracker"
}

teardown() {
  rm -rf "$TEST_DIR"
}

run_status() {
  run env \
    RECRUITING_AUTOMATION_BASE="$BASE" \
    RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
    RECRUITING_AUTOMATION_COMMS_REPO="$FAKE_COMMS_REPO" \
    RECRUITING_AUTOMATION_JOBTRACKER_REPO="$FAKE_JOBTRACKER_REPO" \
    "$REPO_ROOT/status.sh"
}

run_stop() {
  run env \
    RECRUITING_AUTOMATION_BASE="$BASE" \
    RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
    RECRUITING_AUTOMATION_PLIST_PATH="$PLIST_PATH" \
    "$REPO_ROOT/stop.sh"
}

@test "status.sh reports 'not halted' when no HALT file exists" {
  run_status
  [[ "$output" == *"not halted"* ]]
}

@test "status.sh reports the HALT reason when one exists" {
  echo "something broke" > "$BASE/state/HALT"
  run_status
  [[ "$output" == *"HALTED: something broke"* ]]
}

@test "status.sh reports remaining time for a future expiry" {
  echo "$(( $(date +%s) + 7200 ))" > "$BASE/state/expiry_epoch"
  run_status
  [[ "$output" == *"remaining: 1h"* || "$output" == *"remaining: 2h"* ]]
}

@test "status.sh reports EXPIRED for a past expiry" {
  echo "$(( $(date +%s) - 60 ))" > "$BASE/state/expiry_epoch"
  run_status
  [[ "$output" == *"remaining: EXPIRED"* ]]
}

@test "status.sh doesn't crash when there are no logs yet" {
  run_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no logs yet"* ]]
}

@test "status.sh reports the configured window length alongside remaining time" {
  echo "$(( $(date +%s) + 7200 ))" > "$BASE/state/expiry_epoch"
  echo "48" > "$BASE/state/window_hours"
  run_status
  [[ "$output" == *"configured window: 48h"* ]]
}

@test "status.sh reports install history from install.log" {
  echo '[2026-07-15 16:00:00 -0600] window=48h source="CLI arg" expiry="Fri Jul 17" reason="manual/direct invocation" pid=1234' > "$BASE/logs/install.log"
  run_status
  [[ "$output" == *"install history"* ]]
  [[ "$output" == *"window=48h source=\"CLI arg\""* ]]
}

@test "status.sh reports '(no installs recorded yet)' when install.log is absent" {
  run_status
  [[ "$output" == *"(no installs recorded yet)"* ]]
}

@test "status.sh classifies a completed cycle log as OK" {
  cat > "$BASE/logs/run-20260101-000000.log" <<'LOG'
[2026-01-01 00:00:00 -0600] === Cycle start ===
[2026-01-01 00:00:01 -0600] === Cycle complete ===
LOG
  run_status
  [[ "$output" == *"run-20260101-000000.log: OK"* ]]
}

@test "status.sh classifies a stopped cycle log with its stop reason" {
  cat > "$BASE/logs/run-20260101-010000.log" <<'LOG'
[2026-01-01 01:00:00 -0600] === Cycle start ===
[2026-01-01 01:00:01 -0600] STOPPING SCHEDULE: 48-hour window complete — ready for Monday triage.
LOG
  run_status
  [[ "$output" == *"run-20260101-010000.log: STOPPED: 48-hour window complete"* ]]
}

@test "status.sh skips the ANTHROPIC_API_KEY check for a nonexistent sibling repo" {
  run_status
  [[ "$output" == *"no .venv found"* ]]
}

@test "stop.sh writes a HALT sentinel with a timestamp" {
  run_stop
  [ "$status" -eq 0 ]
  [[ -f "$BASE/state/HALT" ]]
  grep -q "manually stopped at" "$BASE/state/HALT"
}
