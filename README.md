# recruiting-automation

Orchestration layer that ties the two sibling repos together into one
unattended, scheduled pipeline:

```
comms-migration: classify personal_hub      (label + archive recruiter_job etc.)
        ↓
comms-migration: classify recruiting_funnel (same, full category taxonomy)
        ↓
job-tracker: triage_recruiter_inbox.py       (LLM eval + résumé/cover-letter
                                               generation on a "pursue" verdict)
        ↓
job-tracker: render_pending_actions.py       (refreshes the static
                                               pending-actions.html dashboard)
```

Each step is a real repo's own CLI script (`run_cycle.sh` just calls them in
order with a per-step timeout) — this directory owns none of the actual
business logic, only the scheduling/safety wrapper around it. See:
- [`comms-migration` README](../comms-migration/README.md)
- [`job-tracker` README](../job-tracker/README.md)

## Project layout

All three projects are siblings under one parent, `~/workspace-recruiting-automation/`:

```
~/workspace-recruiting-automation/
  comms-migration/     (own git repo + remote, own .venv)
  job-tracker/          (own git repo + remote, own .venv)
  recruiting-automation/  (this directory — not yet its own git repo)
```

**History:** originally `comms-migration` and `job-tracker` each lived under
their own separate `~/workspace-comms/` / `~/workspace-job-tracker/` parent,
and this directory lived at `~/bin/recruiting-automation` (untracked —
`~/bin` is its own git repo, but its `.gitignore` blanket-ignores all
subfolders, so nothing here was ever backed up). Consolidated into one
shared parent on 2026-07-13, both to give this layer proper git backup
potential and because it's outgrown "one-off script in `~/bin`" — it's a
real project with its own state machine and pending feature work now.

**Gotcha hit during that move, worth remembering for next time anything
here needs relocating again:** Python venvs (`.venv/`) are **not
relocatable** — `venv`'s `activate` script and `pyvenv.cfg` bake in the
venv's absolute path *literally* at creation time (not computed
dynamically from the script's own location), so moving the parent repo
silently leaves `.venv/bin/activate` pointing at the old, now-nonexistent
path. The symptom is confusing: `source .venv/bin/activate` "succeeds" with
no error, but `python3` inside it silently resolves back to the system
interpreter instead of the venv's — so imports of anything only installed
in the venv (e.g. `jsonschema`, `anthropic`) fail with
`ModuleNotFoundError`, and it looks like a dependency problem rather than a
path problem. Fix: `rm -rf .venv && python3 -m venv .venv && source
.venv/bin/activate && pip install -r requirements.txt` — cheap to just
always do this after moving/renaming a repo rather than trying to diagnose
whether it's actually needed.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Start (or restart) the automation: clears any `state/HALT`, resets the window from "now" (`WINDOW_HOURS` from `.env` if present, else 48h — a CLI arg overrides both), writes/reloads the main LaunchAgent. **Safe to re-run anytime** — this is also the fix for "the schedule stopped and I want it running again." |
| `.env` | Optional local override for `WINDOW_HOURS`. Git-ignored, no secrets — see `.env.example`. |
| `run_cycle.sh` | One tick of the pipeline (see diagram above). Called hourly by launchd, and once immediately on install (`RunAtLoad`). Sources `lib/cycle_safety.sh` for all the safety behavior — see below. |
| `lib/cycle_safety.sh` | The actual halt/timeout/shutdown-trap logic, factored out of `run_cycle.sh` (2026-07-13) specifically so `tests/` can exercise it in isolation. Not meant to be run directly. |
| `ensure_running.sh` | Runs once per login (see the login-check LaunchAgent below). If the main automation isn't loaded, or is loaded but halted, re-runs `install.sh`. No-ops otherwise. |
| `status.sh` | Quick health check: launchd state, halt sentinel, configured window + time remaining, last 5 install-log entries, last 5 cycles' pass/fail outcomes, whether both sibling repos actually resolve `ANTHROPIC_API_KEY`, and a tail of the latest log. This is the one command to run for "what's the current and historic status of the process." |
| `stop.sh` | Manually stop early (writes `HALT`, unloads the LaunchAgent). |
| `tests/` | `bats-core` test suite for all of the above — see `tests/README.md`. |
| `state/HALT` | Sentinel file. Presence means the schedule is stopped and `run_cycle.sh` will no-op + unload itself on its next tick if somehow still loaded. Cleared automatically by `install.sh`/`ensure_running.sh`. |
| `state/expiry_epoch` | Unix epoch when the current window ends. Written by `install.sh`. On expiry, `run_cycle.sh` stops itself with reason "ready for Monday triage" — this is a deliberate design (forces a periodic manual check-in), not a bug; re-run `install.sh` to start a fresh window. |
| `state/window_hours` | The `WINDOW_HOURS` value `install.sh` actually used to compute the expiry above — lets `status.sh` show the configured length, not just time remaining. |
| `logs/run-*.log` | One timestamped log per cycle tick, full output of all 4 steps. |
| `logs/login-check.log` | `ensure_running.sh`'s own log (one line per login: no-op, or "restarting" with a reason). |
| `logs/install.log` | Durable one-line-per-run history of every `install.sh` invocation (added 2026-07-15): timestamp, `WINDOW_HOURS` used, its source (CLI arg / `.env` / hardcoded default), resulting expiry, and *why* — `ensure_running.sh` passes its own restart reason through via `RECRUITING_AUTOMATION_INSTALL_REASON` so a login-triggered restart shows up distinctly from a manual one. Unlike `install.sh`'s own `echo` output (only captured when invoked through `ensure_running.sh`, lost otherwise), this always persists regardless of how `install.sh` was invoked. |
| `logs/launchd.{out,err}.log` | Raw launchd stdout/stderr for the main agent (usually empty/redundant with `run-*.log`, since `run_cycle.sh` does its own logging+`tee`). |

## LaunchAgents (macOS scheduling)

Two separate agents, both under `~/Library/LaunchAgents/`:

1. **`com.sbecker11.recruiting-automation`** — the main schedule.
   `StartInterval=3600` (hourly) + `RunAtLoad=true`. Installed/reloaded by
   `install.sh`. Unloads itself (see `run_cycle.sh`'s `unload_self`) on halt
   or 48h expiry — a stopped schedule is *not* loaded, not just idle.
2. **`com.sbecker11.recruiting-automation-login-check`** (added
   2026-07-13) — `RunAtLoad=true` **only**, no interval. Fires
   `ensure_running.sh` once per actual login/reboot. This is a safety net
   for the case where agent #1 halted (or the Mac rebooted/crashed) and
   nobody noticed — **it does NOT fire on sleep/wake**, only on a real
   login event, since the Mac never actually logs out during sleep. See
   "Sleep vs. shutdown vs. login" below for why this still matters.

Check both are loaded: `launchctl print "gui/$(id -u)/com.sbecker11.recruiting-automation"` (swap in `-login-check` for the other one).

## Safety behavior in `run_cycle.sh`

- **Per-step timeout (900s / 15min)**, via `/usr/local/bin/timeout`. Guards
  against a step *hanging* (e.g. a stuck interactive OAuth prompt nobody's
  there to complete) rather than failing outright — without this, a hang
  wouldn't trip the halt-on-error logic below at all, it'd just silently
  freeze the schedule for the rest of the window.
- **Halt-on-first-failure, no retry.** The first non-zero exit (or timeout)
  in a cycle writes `state/HALT`, sends a desktop notification, unloads the
  LaunchAgent, and stops — remaining steps in that tick are skipped, and the
  hourly schedule won't fire again until someone (or `ensure_running.sh`, at
  next login) clears it. **This is deliberate, not a gap** — explicitly
  decided 2026-07-13: "if the host is unreachable, it's fine for the
  pipeline to shut down" rather than adding retry/backoff resilience for
  transient network blips. If that decision ever changes, the place to add
  it is `run_step()`'s failure branch.
- **`SIGTERM` trap** (added 2026-07-13) — the shell equivalent of a Java
  shutdown hook / C `atexit()`. When macOS sends `SIGTERM` on a normal
  shutdown/logout, the trap logs "Received SIGTERM ... exiting cleanly, no
  HALT written" instead of the log just truncating silently mid-cycle
  (which otherwise looks identical to a real hang when read later). Doesn't
  fire on `SIGKILL` — same limitation Java's shutdown hooks have; not a
  concern here since the trap exits immediately once it does fire.

## Sleep vs. shutdown vs. login — why this distinction keeps mattering

Three different states, three different implications for this pipeline:

- **Sleep** (lid closed, or idle sleep): the Mac stays logged in, launchd
  agents stay loaded, but the network stack may not fully reassociate
  during macOS's brief periodic "dark wake" / Power Nap windows — this is
  the confirmed root cause of a real overnight outage (2026-07-13,
  `OSError: [Errno 65] No route to host` at 2:09 AM, sat halted until ~7:12
  AM before someone noticed). **Fix: don't close the lid overnight**, or
  use true clamshell mode (lid closed + external keyboard AND mouse/
  trackpad AND display all connected) so the Mac does full wakes instead.
  A login script can't help here since no login/logout ever happens.
- **Shutdown/logout**: `SIGTERM` reaches every process; the trap above just
  makes the log legible about why the cycle stopped. `ensure_running.sh`
  picks the schedule back up automatically on the next login.
- **Login/reboot**: `com.sbecker11.recruiting-automation-login-check` fires
  `ensure_running.sh`, which restarts the main schedule if it isn't already
  loaded and healthy.

## Testing

```bash
brew install bats-core
bats tests/
```

Every script (`run_cycle.sh`, `install.sh`, `status.sh`, `stop.sh`,
`ensure_running.sh`) reads its `BASE`/`PLIST_LABEL`/`PLIST_PATH`/repo paths
from `RECRUITING_AUTOMATION_*` environment variables, each defaulting to the
real production value when unset — so normal use is completely unaffected,
but `tests/` can point every one of them at a throwaway sandbox instead and
never touch the real `HALT` sentinel, the real 48-hour window, the real
LaunchAgent, or make a live Gmail/Anthropic call. See `tests/README.md` for
exactly what's covered and how the isolation works.

### `RECRUITING_AUTOMATION_WORKSPACE_ROOT` — single source of truth for the parent dir

All five scripts above, plus `job_tracker/__init__.py` and
`classifier/__init__.py` in the sibling repos, independently needed to know
where `~/workspace-recruiting-automation/` (the shared parent holding all
three sibling repos) lives — before 2026-07-15 that was five separate
hardcoded `$HOME/workspace-recruiting-automation/...` defaults in the shell
scripts plus two independently-counted `Path(__file__).resolve().parents[N]`
computations in the Python packages. Renaming or relocating the workspace
meant hunting down and updating all seven.

Now there's one override point: set `RECRUITING_AUTOMATION_WORKSPACE_ROOT`
(as a real exported env var, e.g. in `~/.zshrc`, or per-invocation) to
change the parent directory everywhere at once. Precedence, same pattern as
every other `RECRUITING_AUTOMATION_*` var here:

1. The more specific var, if set directly (`RECRUITING_AUTOMATION_BASE`,
   `RECRUITING_AUTOMATION_COMMS_REPO`, `RECRUITING_AUTOMATION_JOBTRACKER_REPO`)
   — this is what every existing test does, so test isolation is unaffected.
2. `RECRUITING_AUTOMATION_WORKSPACE_ROOT`, if set — every script derives its
   own default (`$WORKSPACE_ROOT/recruiting-automation`, `.../comms-migration`,
   `.../job-tracker`) from it.
3. The hardcoded fallback, `$HOME/workspace-recruiting-automation`.

`run_cycle.sh` and `status.sh` (the two scripts that spawn Python
subprocesses into the sibling repos) `export` the resolved value as
`RECRUITING_AUTOMATION_WORKSPACE_ROOT` before invoking them, so an override
set on the shell script's own invocation reaches `job_tracker/__init__.py` /
`classifier/__init__.py` too — both check the same env var before falling
back to their own file-relative derivation (`_PROJECT_ROOT_ENV.parent.parent`,
which itself no longer needs a second independently-counted `parents[N]`).

## OAuth token expiry (resolved 2026-07-13)

The Google OAuth app both sibling repos authenticate against
(`job-tracker-desktop`) was in Testing publishing status, which hard-expired
refresh tokens every 7 days regardless of use — the other historical cause
of unattended-schedule interruptions (distinct from the sleep/network issue
above). Moved to "In production" 2026-07-13; all 5 token grants across both
repos were force-refreshed under the new policy the same day. Full details
and the account/scope table live in `comms-migration`'s README
("Re-authenticating when a login expires"). Should not recur; if it does,
that section explains what to check first.

## Shared config across sibling repos

`~/workspace-recruiting-automation/.env` (not tracked by any git repo — that
parent directory isn't one) holds the single copy of `ANTHROPIC_API_KEY`
used by both `job-tracker` and `comms-migration`, instead of duplicating the
same key in each repo's own `.env`. Each repo's own `.env` still wins if it
sets the key locally (see `job_tracker/__init__.py` /
`classifier/__init__.py`'s load order) — only fall back there if you
genuinely want one repo using a different key than the other. Both repos
print a one-line diagnostic at import time (`[job_tracker] ANTHROPIC_API_KEY:
loaded from shared .env (...) (108 chars).` or a `WARNING: ... is not set`
if neither file nor the shell environment has it) — this shows up in every
`run-*.log` automatically, and `status.sh` also checks it directly.

## Common tasks

```bash
./status.sh              # full health check: loaded/halted/expiry, install
                          # history, recent cycle outcomes, sibling API-key
                          # status, latest log tail
./install.sh              # (re)start a fresh window, clearing any halt
                          # (WINDOW_HOURS from .env if present, else 48h)
./install.sh 72           # same, but a 72-hour window — CLI arg always wins over .env
./stop.sh                 # stop early on purpose
tail -f logs/run-*.log    # follow the current/latest cycle live
tail logs/install.log     # history of every (re)install: when, what window, why
```

## Known pending work (not yet built)

- **Rejection-email detection.** Plan (as of 2026-07-13, not yet
  implemented): scan Mac Mail's per-account Archive mailboxes via
  AppleScript (the "All Archives" Smart Mailbox itself isn't scriptable —
  confirmed; must iterate `sbecker11@icloud.com`, `scbboston@gmail.com`,
  `shawn.becker@spexture.com` (Hostinger IMAP — not Gmail-API-backed, unlike
  everything else this pipeline touches), `admin@spexture.com`,
  `shawn.becker@yahoo.com`, and the Exchange account individually), reuse/
  extend the rejection regex patterns already in job-tracker's
  `job_tracker/email/classifier.py`, fuzzy-match hits against
  `job_leads.company`, and — per explicit preference — show a confirm-before-
  write review list rather than auto-updating `leads.db`, then fold the
  whole thing into this hourly schedule as a 5th step once it's trustworthy.
- **`rejected_at` column vs. reusing `status='skipped'`** for rejection
  hits — undecided; revisit when building the scanner above.
