#!/usr/bin/env bats
#
# Tests for ensure_running.sh's decision logic (the login watchdog).
# RECRUITING_AUTOMATION_PLIST_LABEL/BASE/INSTALL_SCRIPT are pointed at a
# throwaway sandbox for every test — this never bootstraps/checks the real
# production LaunchAgent, and INSTALL_SCRIPT is always a stub that just
# leaves a marker rather than the real install.sh (which would reload a
# real LaunchAgent and reset the real 48h window if invoked for real).

setup() {
  TEST_DIR="$(mktemp -d)"
  BASE="$TEST_DIR/base"
  mkdir -p "$BASE"
  PLIST_LABEL="com.sbecker11.recruiting-automation-TEST-$$"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  STUB_INSTALL="$TEST_DIR/stub_install.sh"
  cat > "$STUB_INSTALL" <<'STUB'
#!/bin/zsh
echo "stub install invoked" >> "$STUB_MARKER"
echo "reason received: ${RECRUITING_AUTOMATION_INSTALL_REASON:-<unset>}" >> "$STUB_MARKER"
STUB
  chmod +x "$STUB_INSTALL"
  STUB_MARKER="$TEST_DIR/stub_marker.log"
}

teardown() {
  # In case the "already loaded" test's real dummy agent is still around
  # for any reason (e.g. this test failed before its own cleanup ran).
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}

run_ensure_running() {
  run env \
    RECRUITING_AUTOMATION_BASE="$BASE" \
    RECRUITING_AUTOMATION_PLIST_LABEL="$PLIST_LABEL" \
    RECRUITING_AUTOMATION_INSTALL_SCRIPT="$STUB_INSTALL" \
    STUB_MARKER="$STUB_MARKER" \
    "$REPO_ROOT/ensure_running.sh"
}

@test "restarts (invokes install script) when the label isn't loaded at all" {
  # PLIST_LABEL here was never bootstrapped, so launchctl print on it always
  # fails — exactly the "agent unloaded" case (crash/reboot/never installed).
  run_ensure_running
  [ "$status" -eq 0 ]
  [[ -f "$STUB_MARKER" ]]
  grep -q "not loaded — restarting" "$BASE/logs/login-check.log"
}

@test "restarts when HALT is present even though nothing else is loaded" {
  mkdir -p "$BASE/state"
  echo "some prior failure" > "$BASE/state/HALT"
  run_ensure_running
  [ "$status" -eq 0 ]
  [[ -f "$STUB_MARKER" ]]
  grep -q "HALT sentinel present" "$BASE/logs/login-check.log"
}

@test "passes the restart reason through to install.sh via RECRUITING_AUTOMATION_INSTALL_REASON" {
  # So logs/install.log's "reason=" field (written by install.sh) can say
  # *why* a login triggered it, not just that it did — see install.sh.
  mkdir -p "$BASE/state"
  echo "some prior failure" > "$BASE/state/HALT"
  run_ensure_running
  [ "$status" -eq 0 ]
  grep -q "reason received: login-check: HALT sentinel present (some prior failure)" "$STUB_MARKER"
}

@test "restarts when the label IS loaded but the 48-hour window has expired" {
  # Reproduces the 2026-07-15 bug: a login can race the sibling main-schedule
  # plist's own RunAtLoad reload, catching is_loaded() at "true" for a window
  # that already expired (and is about to unload itself again a moment
  # later). The expiry check must force a restart independent of that race.
  mkdir -p "$BASE/state"
  echo "$(( $(date +%s) - 3600 ))" > "$BASE/state/expiry_epoch"

  local plist="$TEST_DIR/dummy.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sleep</string><string>2</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$(id -u)" "$plist"

  run_ensure_running
  [ "$status" -eq 0 ]
  [[ -f "$STUB_MARKER" ]]
  grep -q "48-hour window expired" "$BASE/logs/login-check.log"

  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
}

@test "no-ops when the label IS loaded, unexpired, and no HALT is present" {
  # Bootstrap a real, trivial, harmless dummy agent under the fake test
  # label so is_loaded() genuinely returns true for it — then confirm we
  # clean it up again regardless of test outcome (see teardown too).
  local plist="$TEST_DIR/dummy.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sleep</string><string>2</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$(id -u)" "$plist"

  run_ensure_running
  [ "$status" -eq 0 ]
  [[ ! -f "$STUB_MARKER" ]]
  grep -q "already loaded and healthy" "$BASE/logs/login-check.log"

  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
}
