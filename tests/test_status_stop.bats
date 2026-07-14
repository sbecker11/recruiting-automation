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
}

teardown() {
  rm -rf "$TEST_DIR"
}

run_status() {
  run env RECRUITING_AUTOMATION_BASE="$BASE" RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
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

@test "stop.sh writes a HALT sentinel with a timestamp" {
  run_stop
  [ "$status" -eq 0 ]
  [[ -f "$BASE/state/HALT" ]]
  grep -q "manually stopped at" "$BASE/state/HALT"
}
