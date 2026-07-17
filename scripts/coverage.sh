#!/usr/bin/env bash
# Run the recruiting-automation bats suite.
# Shell/bats has no built-in line coverage (kcov not assumed); this script
# reports pass/fail counts and marks coverage N/A.
# Usage: ./scripts/coverage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v bats >/dev/null 2>&1; then
  echo "error: bats not found. Install with: brew install bats-core" >&2
  exit 1
fi

echo "=== recruiting-automation tests (bats) ==="
echo "Coverage tooling: N/A (shell scripts; bats-core only — no kcov in this environment)"
echo

# bats prints a TAP plan "1..N" and one ok/not ok line per test.
set +e
output="$(bats tests/ 2>&1)"
bats_rc=$?
set -e
printf '%s\n' "$output"

planned="$(printf '%s\n' "$output" | awk '/^1\.\./ { sub(/^1\.\./,""); print; exit }')"
failed="$(printf '%s\n' "$output" | grep -c '^not ok ' || true)"
passed="$(printf '%s\n' "$output" | grep -c '^ok ' || true)"
planned="${planned:-0}"

echo
echo "--- recruiting-automation summary ---"
echo "  Tests:             ${passed} passed / ${failed} failed / ${planned} planned"
echo "  Line coverage:     N/A (shell/bats)"
echo "  Branch coverage:   N/A"

exit "$bats_rc"
