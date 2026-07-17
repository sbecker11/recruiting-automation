# Tests

Uses [bats-core](https://github.com/bats-core/bats-core) (`brew install bats-core`).

```bash
bats tests/                      # everything
bats tests/test_cycle_safety.bats  # one file
```

## What's covered

| File | Covers |
|---|---|
| `test_cycle_safety.bats` | `lib/cycle_safety.sh`: `run_step` (success/failure/timeout), `preflight_check` (HALT sentinel, expired/unexpired 48h window), the `SIGTERM` shutdown trap |
| `test_ensure_running.bats` | `ensure_running.sh`'s restart-vs-no-op decision (label not loaded, HALT present, expired window even while loaded, or genuinely loaded+unexpired+healthy), and that its restart reason is passed through to `install.sh` via `RECRUITING_AUTOMATION_INSTALL_REASON` |
| `test_install.bats` | `install.sh`: clears HALT, writes a correct `expiry_epoch` (default, from `.env`, and CLI-arg-overrides-`.env`), writes `state/window_hours` and `logs/install.log` with the right source/reason, writes a valid plist, actually bootstraps, is idempotent |
| `test_status_stop.bats` | `status.sh`/`stop.sh`: basic reporting/sentinel-writing sanity, configured-window display, install-history and recent-cycle-outcome reporting, and that the sibling `ANTHROPIC_API_KEY` check safely no-ops for a nonexistent repo |

**Deliberately not covered here:** the real `comms-migration`/`job-tracker`
steps `run_cycle.sh` invokes — those have their own test suites in their own
repos. This suite is only about the orchestration/safety-net layer around
them (halt-on-failure, timeouts, the login watchdog, clean shutdown
logging), which is exactly the code that had no test coverage at all before
2026-07-13 and where a couple of real, non-obvious bugs (the `SIGTERM`
trap's deferred-delivery behavior while blocked on a child process,
`ensure_running.sh`'s loaded/healthy decision logic) were originally only
caught by hand.

## How every test avoids touching production

Every script here defaults every path/label it uses (`BASE`, `PLIST_LABEL`,
`PLIST_PATH`, and `ensure_running.sh`'s `INSTALL_SCRIPT`) to the real
production value via a `RECRUITING_AUTOMATION_*` environment variable
override — see the top of each `.sh` file. Every test in this folder sets
those to a throwaway `mktemp -d` sandbox and a `PLIST_LABEL` suffixed with
`-TEST-$$` (guaranteed not to collide with, or ever resolve to,
`com.sbecker11.recruiting-automation`), so:

- Nothing ever writes to the real `state/HALT` or `state/expiry_epoch`.
- Nothing ever bootstraps, bootouts, or reads the real LaunchAgent.
- `run_step`'s test commands are always harmless builtins (`true`/`false`/
  `sleep`), never the real `comms-migration`/`job-tracker` Python
  invocations — no live Gmail reads, no Anthropic API spend, ever, from
  running this suite.

`test_install.bats` and `test_ensure_running.bats` *do* make real
`launchctl bootstrap`/`bootout` calls — but always scoped to their own
`-TEST-$$` label, and every test that creates one cleans it up in its own
body and again in `teardown()` as a backstop.
