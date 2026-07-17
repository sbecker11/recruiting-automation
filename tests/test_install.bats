#!/usr/bin/env bats
#
# Tests for install.sh against a throwaway BASE/PLIST_LABEL/PLIST_PATH
# sandbox. install.sh's whole job is real launchd side effects (writing a
# real plist, bootstrapping a real agent under that label) — this test
# lets it do exactly that, but scoped to a test-only label that can never
# collide with (or touch) the real com.sbecker11.recruiting-automation, and
# always cleans that dummy agent back out again in teardown.

setup() {
  TEST_DIR="$(mktemp -d)"
  BASE="$TEST_DIR/base"
  BASE_PARENT="$TEST_DIR/workspace-root"
  PLIST_LABEL="com.sbecker11.recruiting-automation-TEST-$$"
  PLIST_PATH="$TEST_DIR/test.plist"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() {
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}

run_install() {
  run env \
    RECRUITING_AUTOMATION_BASE="$BASE" \
    RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
    RECRUITING_AUTOMATION_PLIST_PATH="$PLIST_PATH" \
    "$REPO_ROOT/install.sh" "$@"
}

@test "clears a pre-existing HALT sentinel" {
  mkdir -p "$BASE/state"
  echo "old failure" > "$BASE/state/HALT"
  run_install
  [ "$status" -eq 0 ]
  [[ ! -f "$BASE/state/HALT" ]]
}

@test "writes an expiry_epoch roughly WINDOW_HOURS from now, honoring the arg" {
  run_install 10
  [ "$status" -eq 0 ]
  [[ -f "$BASE/state/expiry_epoch" ]]
  local expiry now delta
  expiry=$(cat "$BASE/state/expiry_epoch")
  now=$(date +%s)
  delta=$(( expiry - now - 10 * 3600 ))
  # allow a few seconds of test-run slack either side of exactly 10h
  [ "${delta#-}" -lt 30 ]
}

@test "defaults to a 48-hour window when no arg and no .env are given" {
  run_install
  [ "$status" -eq 0 ]
  local expiry now delta
  expiry=$(cat "$BASE/state/expiry_epoch")
  now=$(date +%s)
  delta=$(( expiry - now - 48 * 3600 ))
  [ "${delta#-}" -lt 30 ]
}

@test "honors WINDOW_HOURS from .env when no CLI arg is given" {
  mkdir -p "$BASE"
  echo "WINDOW_HOURS=10" > "$BASE/.env"
  run_install
  [ "$status" -eq 0 ]
  local expiry now delta
  expiry=$(cat "$BASE/state/expiry_epoch")
  now=$(date +%s)
  delta=$(( expiry - now - 10 * 3600 ))
  [ "${delta#-}" -lt 30 ]
}

@test "a CLI arg overrides WINDOW_HOURS from .env" {
  mkdir -p "$BASE"
  echo "WINDOW_HOURS=10" > "$BASE/.env"
  run_install 5
  [ "$status" -eq 0 ]
  local expiry now delta
  expiry=$(cat "$BASE/state/expiry_epoch")
  now=$(date +%s)
  delta=$(( expiry - now - 5 * 3600 ))
  [ "${delta#-}" -lt 30 ]
}

@test "records CLI-arg source and value in state/window_hours and logs/install.log" {
  run_install 10
  [ "$status" -eq 0 ]
  [[ "$(cat "$BASE/state/window_hours")" == "10" ]]
  [[ -f "$BASE/logs/install.log" ]]
  grep -q 'window=10h source="CLI arg"' "$BASE/logs/install.log"
}

@test "records .env as the source in logs/install.log when no CLI arg is given" {
  mkdir -p "$BASE"
  echo "WINDOW_HOURS=7" > "$BASE/.env"
  run_install
  [ "$status" -eq 0 ]
  [[ "$(cat "$BASE/state/window_hours")" == "7" ]]
  grep -q 'window=7h source=".env' "$BASE/logs/install.log"
}

@test "records hardcoded-default as the source in logs/install.log when neither arg nor .env is given" {
  run_install
  [ "$status" -eq 0 ]
  [[ "$(cat "$BASE/state/window_hours")" == "48" ]]
  grep -q 'window=48h source="hardcoded default"' "$BASE/logs/install.log"
}

@test "records RECRUITING_AUTOMATION_INSTALL_REASON in logs/install.log when set" {
  run env \
    RECRUITING_AUTOMATION_BASE="$BASE" \
    RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
    RECRUITING_AUTOMATION_PLIST_PATH="$PLIST_PATH" \
    RECRUITING_AUTOMATION_INSTALL_REASON="login-check: not loaded" \
    "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  grep -q 'reason="login-check: not loaded"' "$BASE/logs/install.log"
}

@test "defaults the install.log reason to manual/direct invocation when unset" {
  run_install
  [ "$status" -eq 0 ]
  grep -q 'reason="manual/direct invocation"' "$BASE/logs/install.log"
}

@test "writes a valid plist pointing at this repo's run_cycle.sh under the test label" {
  run_install
  [ "$status" -eq 0 ]
  [[ -f "$PLIST_PATH" ]]
  run plutil -lint "$PLIST_PATH"
  [ "$status" -eq 0 ]
  grep -q "<string>$PLIST_LABEL</string>" "$PLIST_PATH"
  grep -q "$BASE/run_cycle.sh" "$PLIST_PATH"
}

@test "actually bootstraps the agent under the test label" {
  run_install
  [ "$status" -eq 0 ]
  run launchctl print "gui/$(id -u)/$PLIST_LABEL"
  [ "$status" -eq 0 ]
}

@test "is safe to re-run (idempotent bootstrap)" {
  run_install
  [ "$status" -eq 0 ]
  run_install
  [ "$status" -eq 0 ]
  run launchctl print "gui/$(id -u)/$PLIST_LABEL"
  [ "$status" -eq 0 ]
}

@test "RECRUITING_AUTOMATION_WORKSPACE_ROOT sets BASE's default when RECRUITING_AUTOMATION_BASE is unset" {
  # Deliberately does NOT set RECRUITING_AUTOMATION_BASE (unlike run_install
  # above) so BASE actually falls through to $WORKSPACE_ROOT/recruiting-automation
  # — proving the 2026-07-15 single-source-of-truth consolidation works.
  run env \
    RECRUITING_AUTOMATION_WORKSPACE_ROOT="$BASE_PARENT" \
    RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
    RECRUITING_AUTOMATION_PLIST_PATH="$PLIST_PATH" \
    "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ -f "$BASE_PARENT/recruiting-automation/state/expiry_epoch" ]]
}
