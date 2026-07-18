# recruiting-automation — Cursor project instructions

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

## Venv gotcha

Sibling `.venv/` dirs are **not relocatable**. After moving repos, recreate
venvs rather than debugging mysterious `ModuleNotFoundError`s.
