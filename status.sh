#!/bin/zsh
# Quick status check: is the schedule loaded, is it halted, how much time is
# left, latest log tail, recent install history, recent cycle outcomes,
# decision-queue KPIs, framework sync, and whether both sibling repos actually
# have ANTHROPIC_API_KEY available.
#
#   ./status.sh          # human-readable
#   ./status.sh --json   # machine-readable KPI + schedule snapshot
#
# RECRUITING_AUTOMATION_* env vars are test-only overrides (see tests/).
set -uo pipefail

_JSON=0
if [[ "${1:-}" == "--json" ]]; then
  _JSON=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: $0 [--json]" >&2
  exit 2
fi

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

if (( _JSON )); then
  BASE="$BASE" WORKSPACE_ROOT="$WORKSPACE_ROOT" JOBTRACKER_REPO="$JOBTRACKER_REPO" python3 -c '
import json, os, subprocess
from pathlib import Path

base = Path(os.environ["BASE"])
jobtracker = Path(os.environ["JOBTRACKER_REPO"])
halt_file = base / "state" / "HALT"
payload = {
    "halted": halt_file.is_file(),
    "haltReason": halt_file.read_text(encoding="utf-8").strip() if halt_file.is_file() else "",
    "workspaceRoot": os.environ["WORKSPACE_ROOT"],
    "recruitingAutomationBase": str(base),
}
venv_py = jobtracker / ".venv" / "bin" / "python3"
if venv_py.is_file():
    proc = subprocess.run(
        [str(venv_py), "scripts/kpi_snapshot.py", "--state-dir", str(base / "state"), "--check-framework", "--check-label-drift", "--check-spend"],
        cwd=jobtracker,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        start = proc.stdout.find("{")
        if start >= 0:
            payload.update(json.loads(proc.stdout[start:]))
        else:
            payload["kpiError"] = proc.stdout.strip()[:500]
    else:
        payload["kpiError"] = (proc.stderr or proc.stdout or "kpi_snapshot failed").strip()[:500]
else:
    payload["kpiError"] = "no venv at %s/.venv" % jobtracker
print(json.dumps(payload, indent=2))
'
  exit 0
fi

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
if [[ -f "$BASE/state/window_hours" && "$(cat "$BASE/state/window_hours")" == "0" ]]; then
  echo "configured window: none — runs indefinitely, no forced check-in"
elif [[ -f "$BASE/state/expiry_epoch" ]]; then
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
else
  echo "(no expiry state recorded yet — run install.sh)"
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

_kpi_section() {
  if [[ ! -d "$JOBTRACKER_REPO/.venv" ]]; then
    echo "(skipped — no job-tracker .venv at $JOBTRACKER_REPO/.venv)"
    return
  fi
  local kpi_raw
  kpi_raw=$(
    cd "$JOBTRACKER_REPO" && "$JOBTRACKER_REPO/.venv/bin/python" scripts/kpi_snapshot.py --state-dir "$BASE/state" --check-framework --check-label-drift --check-spend 2>/dev/null
  )
  python3 -c '
import json, sys
raw = sys.argv[1]
start = raw.find("{")
if start < 0:
    print("(KPI snapshot unavailable)")
    raise SystemExit(0)
try:
    d = json.loads(raw[start:])
except json.JSONDecodeError:
    print("(KPI snapshot unavailable)")
    raise SystemExit(0)
kpis = d.get("kpis") or {}
counts = kpis.get("counts") or {}
sch = kpis.get("schedule") or {}
gate = kpis.get("llmReviewGatePct")
level = sch.get("level", "?")
summary = sch.get("summary", "")
print("  schedule: [%s] %s" % (level, summary))
print("  queues (act top-down):")
print("    unmatched/clarify     %s" % counts.get("unmatchedCommunications", "?"))
awaiting = counts.get("awaitingLlmReview", "?")
if gate:
    print("    awaiting LLM review   %s  (gate >= %.0f%%)" % (awaiting, gate))
else:
    print("    awaiting LLM review   %s" % awaiting)
print("    packages ready        %s" % counts.get("packagesReady", "?"))
print("    waiting on them       %s" % counts.get("waitingOnThem", "?"))
print("    needs your decision   %s" % counts.get("needsDecision", "?"))
fs = d.get("frameworkSync")
if fs is not None:
    if fs.get("ok"):
        print("  framework sync: OK (~/CLAUDE.md <-> config/framework.yaml)")
    else:
        print("  framework sync: DRIFT — run: cd job-tracker && python scripts/verify_framework_sync.py")
        for err in fs.get("errors") or []:
            print("    - %s" % err)
drift = d.get("labelDriftWouldRelabel")
if drift is not None:
    if drift == 0:
        print("  label drift: OK (0 would relabel)")
    else:
        print("  label drift: %s would relabel — run: cd job-tracker && python scripts/audit_label_drift.py" % drift)
sp = d.get("spend")
if sp is not None:
    print("  spend: $%.4f eval · %s pursue · %s packages" % (
        sp.get("totalEvalCostUsd", 0),
        sp.get("pursueLeads", "?"),
        sp.get("packagesGenerated", "?"),
    ))
print("  full briefing: ./monday.sh")
' "$kpi_raw"
}

echo ""
echo "--- decision-queue KPIs ---"
_kpi_section

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
