#!/bin/zsh
# Quick status check: is the schedule loaded, is it halted, how much time is
# left, latest log tail, recent install history, recent cycle outcomes, and
# whether both sibling repos actually have ANTHROPIC_API_KEY available.
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/).
set -uo pipefail

# See install.sh's comment on WORKSPACE_ROOT — single source of truth for
# the sibling-repos parent dir, shared across every script here. Exported
# for the same reason as run_cycle.sh: the ANTHROPIC_API_KEY check below
# spawns real job_tracker/classifier Python imports, which check this same
# var themselves before falling back to their own file-relative derivation.
WORKSPACE_ROOT="${RECRUITING_AUTOMATION_WORKSPACE_ROOT:-$HOME/workspace-recruiting-automation}"
export RECRUITING_AUTOMATION_WORKSPACE_ROOT="$WORKSPACE_ROOT"
# job_tracker's own ANTHROPIC_API_KEY-source diagnostic is opt-in (quiet for
# interactive CLI use elsewhere — see job_tracker/__init__.py) but the health
# check below spawns a real `import job_tracker` specifically to see that
# line, so it needs to opt back in here too.
export JOB_TRACKER_LOG_ENV_SOURCE=1
BASE="${RECRUITING_AUTOMATION_BASE:-$WORKSPACE_ROOT/recruiting-automation}"
PLIST_LABEL="${RECRUITING_AUTOMATION_PLIST_LABEL:-com.sbecker11.recruiting-automation}"
COMMS_REPO="${RECRUITING_AUTOMATION_COMMS_REPO:-$WORKSPACE_ROOT/comms-migration}"
JOBTRACKER_REPO="${RECRUITING_AUTOMATION_JOBTRACKER_REPO:-$WORKSPACE_ROOT/job-tracker}"

echo "--- launchd status ---"
launchctl print "gui/$(id -u)/$PLIST_LABEL" 2>&1 | head -20 || echo "(not loaded)"

echo ""
echo "--- halt sentinel ---"
if [[ -f "$BASE/state/HALT" ]]; then
  echo "HALTED: $(cat "$BASE/state/HALT")"
else
  echo "not halted"
fi

echo ""
echo "--- expiry ---"
if [[ -f "$BASE/state/expiry_epoch" ]]; then
  expiry_epoch=$(cat "$BASE/state/expiry_epoch")
  now_epoch=$(date +%s)
  remaining=$(( expiry_epoch - now_epoch ))
  if [[ -f "$BASE/state/window_hours" ]]; then
    echo "configured window: $(cat "$BASE/state/window_hours")h"
  fi
  echo "expires: $(date -r "$expiry_epoch")"
  if (( remaining > 0 )); then
    echo "remaining: $(( remaining / 3600 ))h $(( (remaining % 3600) / 60 ))m"
  else
    echo "remaining: EXPIRED"
  fi
fi

echo ""
echo "--- install history (last 5) ---"
if [[ -f "$BASE/logs/install.log" ]]; then
  tail -5 "$BASE/logs/install.log"
else
  echo "(no installs recorded yet)"
fi

echo ""
echo "--- recent cycle outcomes (last 5) ---"
recent_cycles=("${(@f)$(ls -t "$BASE/logs"/run-*.log 2>/dev/null | head -5)}")
if (( ${#recent_cycles[@]} == 0 )); then
  echo "(no cycle logs yet)"
else
  for f in "${recent_cycles[@]}"; do
    if grep -q "=== Cycle complete ===" "$f"; then
      outcome="OK"
    elif grep -q "STOPPING SCHEDULE" "$f"; then
      outcome="STOPPED: $(grep "STOPPING SCHEDULE" "$f" | tail -1 | sed 's/.*STOPPING SCHEDULE: //')"
    elif grep -q "FAILED:" "$f"; then
      outcome="FAILED: $(grep "FAILED:" "$f" | tail -1 | sed 's/.*FAILED: //')"
    else
      outcome="INCOMPLETE (no completion marker — likely killed mid-cycle)"
    fi
    echo "$(basename "$f"): $outcome"
  done
fi

echo ""
echo "--- ANTHROPIC_API_KEY (siblings) ---"
# NOTE: variables must be braced (${VAR}, not $VAR) before an immediately
# following ":letter" — zsh parses unbraced "$VAR:c" as a history-style
# modifier expansion (silently consuming the "c"), not literal text. Bit
# recruiting-automation once already (2026-07-15): "$COMMS_REPO:classifier"
# silently mangled into ".../comms-migrationlassifier".
for pair in "job-tracker:${JOBTRACKER_REPO}:job_tracker" "comms-migration:${COMMS_REPO}:classifier"; do
  name="${pair%%:*}"
  rest="${pair#*:}"
  repo_dir="${rest%%:*}"
  module="${rest#*:}"
  if [[ -d "$repo_dir/.venv" ]]; then
    ( cd "$repo_dir" && source .venv/bin/activate && python3 -c "import $module" ) 2>&1 || echo "[$name] failed to import $module — see above"
  else
    echo "[$name] no .venv found at $repo_dir — skipped"
  fi
done

echo ""
echo "--- latest log ---"
latest=$(ls -t "$BASE/logs"/*.log 2>/dev/null | head -1)
if [[ -n "${latest:-}" ]]; then
  echo "$latest"
  tail -30 "$latest"
else
  echo "(no logs yet)"
fi
