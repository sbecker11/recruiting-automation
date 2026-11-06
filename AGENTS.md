# recruiting-automation — Cursor project instructions

**Humans:** [`README.md`](README.md) · umbrella [`docs/WORKSPACE.md`](docs/WORKSPACE.md) · secrets [`docs/SECRETS.md`](docs/SECRETS.md).

**Orchestration only.** This layer schedules and wraps sibling CLIs; it owns
none of the routing or JD/package business logic.

```
comms-migration (classify) → job-tracker (triage + packages) → pending-actions.html
```

## Sibling ownership

| Sibling | Owns |
|---|---|
| `../comms-migration/` | Routing truth — hubs, senders, classifier categories |
| `../job-tracker/` | Processing — Gmail read, scoring, résumé/cover-letter packages |
| **this repo** | `launchd` schedule, halt/expiry window, cycle safety, status |

## Candidate profile

Do **not** invent or hardcode Shawn’s experience, rates, or house rules here.

- Package generation and JD evaluation run inside **job-tracker**, which loads
  `~/CLAUDE.md`.
- Only open `~/CLAUDE.md` if you are changing something that must stay aligned
  with that profile (rare in this repo). Prefer editing job-tracker or CLAUDE.md
  directly for candidate-facing rules.

## Safety model (do not “fix away”)

- `state/HALT` — schedule stopped; `run_cycle.sh` no-ops / unloads
- `state/expiry_epoch` — window end; expiry is intentional (“ready for Monday triage”), not a bug — re-run `install.sh` for a fresh window
- `install.sh` — safe to re-run anytime to clear halt and restart
- `status.sh` — first command for “is it healthy?”

## Standing authority to restart (granted by Shawn 2026-11-03)

Whenever an agent finds the schedule stopped (`state/HALT` present, or the
window expired), it may restart it without asking:

1. Read the HALT reason and the tail of the newest `logs/run-*.log`.
2. Run `./install.sh` (no args, so `.env`'s `WINDOW_HOURS` is kept), then `./status.sh`.
3. Tell Shawn it was stopped, why, and that it was restarted.

Do not restart if the cause needs Shawn himself (e.g. an interactive Google
re-login) — tell him what to do instead. If it HALTs again on the same step
right after a restart, stop and report rather than looping.

## Venv gotcha

Sibling `.venv/` dirs are **not relocatable**. After moving repos, recreate
venvs rather than debugging mysterious `ModuleNotFoundError`s.
