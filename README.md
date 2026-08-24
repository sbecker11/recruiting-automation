# recruiting-automation

**Orchestration only** — schedules and wraps sibling CLIs. Owns none of the
routing or JD/package business logic.

```
comms-migration (classify)
  → job-tracker (triage + packages + pending-actions)
  → this repo (hourly launchd + HALT / status)
```

Umbrella install / ops: [`../README.md`](../README.md) (or [`docs/WORKSPACE.md`](docs/WORKSPACE.md))  
Secrets / git-crypt: [`../SECRETS.md`](../SECRETS.md) (or [`docs/SECRETS.md`](docs/SECRETS.md))  
Full historical detail: [`docs/REFERENCE.md`](docs/REFERENCE.md)

## Quick start

```bash
# From this directory (siblings must sit next to it under the same parent)
brew install bats-core          # for tests
./install.sh                    # start/restart schedule (clears HALT)
# ./install.sh 0                # no expiry window — run until stop.sh
./status.sh                     # health check
```

Optional local override: `.env` with `WINDOW_HOURS=…` (git-crypt encrypted —
unlock per [`../SECRETS.md`](../SECRETS.md)).

```bash
./stop.sh                       # intentional stop
```

## Common commands

| Goal | Command |
|------|---------|
| **Monday briefing** | `./monday.sh` |
| Is it healthy? | `./status.sh` (add `--json` for scripts) |
| Restart after HALT | `./install.sh` |
| Stop | `./stop.sh` |
| Follow latest cycle | `tail -f logs/run-*.log` |
| Install history | `tail logs/install.log` |
| Tests | `brew install bats-core && bats tests/` or `./scripts/coverage.sh` |
| Workspace coverage | `../report-coverage.sh` |

`./monday.sh` is the zero-dead-time entry point: refresh pending-actions UI
data, then print clarify / LLM-backlog / packages-ready / waiting / decide
queues ranked for interview likelihood.

## Safety model (do not “fix away”)

| Signal | Meaning |
|--------|---------|
| `state/HALT` | Schedule stopped; `run_cycle.sh` no-ops / unloads |
| `state/expiry_epoch` | Window end (only when `WINDOW_HOURS` ≠ 0) |
| Halt-on-first-failure | Deliberate — no auto-retry for network blips |
| Per-step timeout | 1800s — guards hangs, not “slow but fine” runs |

`install.sh` is safe to re-run anytime. Login LaunchAgent
(`…-login-check`) restarts a halted schedule after reboot/login — **not**
after sleep/wake. Prefer leaving the Mac awake overnight (or true clamshell
with display + keyboard + mouse).

## Workspace root

Scripts default to `$HOME/workspace-recruiting-automation`. Override:

```bash
export RECRUITING_AUTOMATION_WORKSPACE_ROOT=/Volumes/sbecker11/workspace-recruiting-automation
```

Sibling `.venv/` dirs are **not relocatable** — recreate after moving repos.

## Layout (this repo)

| Path | Purpose |
|------|---------|
| `install.sh` / `stop.sh` / `status.sh` | Lifecycle |
| `run_cycle.sh` | One hourly tick (7 steps across siblings) |
| `ensure_running.sh` | Login safety net |
| `lib/cycle_safety.sh` | Halt / timeout / SIGTERM trap |
| `state/` | HALT, expiry, window metadata |
| `logs/` | Per-cycle and install logs |
| `tests/` | bats-core suite |

## Candidate profile

Do **not** invent experience, rates, or house rules here. Package generation
runs inside **job-tracker**, which loads `~/CLAUDE.md`.
