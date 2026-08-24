# Recruiting pipeline migration plan

**Created:** 2026-08-24 (reconstructed from Aug 23 planning sessions)  
**Production host:** mini2 (`~/workspace-recruiting-automation`)  
**Dev host:** mini1 / Cursor (local clone; do not edit prod over SMB)

---

## Overriding objective

Turn inbound recruiting noise into **a small, trustworthy set of pursue-worthy jobs**, each with **accurate scoring against Shawn's profile** (`~/CLAUDE.md`) and — when pursue is justified — **ready-to-send résumé/cover-letter packages**, while keeping Gmail labels and a CRM timeline honest enough that **you can trust the funnel without living in the inbox**.

**North star:** zero dead-time between lead arrival and decision; prioritize leads with the **highest interview / hire likelihood**. Draft yes, send no.

| Sibling | Role |
|---------|------|
| **comms-migration** | Routing — hubs, contacts, classify/label/archive |
| **job-tracker** | Processing — triage, score, packages, CRM |
| **recruiting-automation** | Orchestration — hourly launchd, HALT, status |

---

## Two parallel tracks

This plan covers **Track A** (pipeline improvement Phases 0–6). **Track B** is the longer communications consolidation in [`comms-migration/comms-migration-runbook.md`](comms-migration/comms-migration-runbook.md) (Nextiva, hub migration, sender lists). Track B proceeds independently; Track A assumes mail already flows into the hourly cycle.

---

## mini1 ↔ mini2 workflow

| | mini2 (production) | mini1 (dev) |
|---|-------------------|-------------|
| Pipeline | launchd hourly + 3-min comms_fast | Not loaded (expected) |
| Code | Checked-out repos | Local git clone |
| Data | `leads.db`, OAuth, `state/`, logs | Does not drive live pipeline |

**Safe deploy while mini2 runs:**

1. Develop + test on mini1 → commit → push
2. SSH mini2 → `./status.sh` (confirm cycle idle; look for `=== Cycle complete ===` in latest log)
3. `git pull` in all three repos
4. If Python changed: `cd job-tracker && source .venv/bin/activate && pip install -e ".[dev]"`
5. Verify: `./status.sh`, `./monday.sh`

**Avoid:** editing mini2 files over `/Volumes/sbecker11/...` SMB; `git pull` mid-cycle; `./install.sh` unless clearing HALT / restarting window.

---

## Phase 0 — Baseline & guardrails (3–5 days)

**Goal:** measure before changing behavior.

| Work | Owner | Deliverable | Status |
|------|-------|-------------|--------|
| KPI table in umbrella docs | U | Minutes/day in Gmail, unmatched, awaiting-LLM age, packages ready, label drift, framework sync, HALT/week, $/pursue (Phase 4) | Implemented locally, **uncommitted** |
| `status.sh` KPI snapshot + `--json` | RA | Decision-queue counts + schedule health | Implemented locally, **uncommitted** |
| `verify_framework_sync.py` | JT | `~/CLAUDE.md` ↔ `config/framework.yaml`; wired into `coverage.sh` | Implemented locally, **uncommitted** |
| `kpi_snapshot.py` | JT | JSON emitter for status/cycle | Implemented locally, **uncommitted** |
| Monday command spec | U/RA | Document in Phase 0; implement Phase 1 | Spec done; **Monday v1 shipped** (committed) |

**Exit criteria:** KPIs visible via `./status.sh`; framework sync fails loudly on drift.

**Commands:**

```bash
cd job-tracker && python scripts/verify_framework_sync.py
cd recruiting-automation && ./status.sh          # human
cd recruiting-automation && ./status.sh --json   # scripts
```

---

## Phase 1 — “What needs me today?” (1–2 weeks)

**Goal:** one surface answers clarify → send → wait → decide.

| Work | Owner | Deliverable | Status |
|------|-------|-------------|--------|
| `./monday.sh` + `monday_report.py` | JT/RA | Ranked decision queues by interview likelihood | **Committed** (`65e53eb`, `5f7107b`) |
| `build_kpi_counts()` for status/cycle | JT | Lightweight counts for logs | Implemented locally, **uncommitted** |
| `run_cycle.sh` KPI footer | RA | One KPI line after each OK cycle | Implemented locally, **uncommitted** |
| Pending-actions urgency ranking | JT | Reply-due → direct recruiter → match % → age | Partially committed + **uncommitted UI polish** |
| Packages-ready clarity in UI | JT | `N/M packages ready on disk` in Send résumé tab | Implemented locally, **uncommitted** |

**Exit criteria:** Run one command (or open UI) and act without opening Gmail.

**Commands:**

```bash
cd recruiting-automation && ./monday.sh
# UI: http://127.0.0.1:3174/  — Clarify → Send → Wait → Decide
```

---

## Phase 2 — Intake completeness (1–2 weeks)

**Goal:** no recruiting signal dies outside the pipeline.

| Work | Owner | Deliverable |
|------|-------|-------------|
| Rejection-email scanner | JT | Confirm-before-write → `rejected` + cooldown |
| Mailbox coverage matrix | U/CM | Every address → forward/API/IMAP → cycle step; mark gaps |
| Close matrix gaps | CM/JT | Yahoo/MIT/Hostinger historical; spam rescue (partial today) |
| Backfill playbook | JT | Scripted “after:DATE” classify+triage; document in `PRIMER.md` |

**Exit criteria:** Matrix shows 0 unwatched active sources; rejection path works with human confirm.

**Refs:** `comms-migration/routing-inventory.md`, `recruiting-automation/run_cycle.sh` (7 steps).

---

## Phase 3 — Label/DB trust (3–7 days)

**Goal:** Gmail label == current lead truth.

| Work | Owner | Deliverable |
|------|-------|-------------|
| Drift auditor | JT | `audit_label_drift.py`: scan JobTracker/* vs DB; report + optional `--apply` |
| Drift count in status / Monday | RA/JT | KPI from Phase 0 (`kpi_snapshot --check-label-drift` stub exists) |
| Test fixtures for drift cases | JT | Stale PURSUE after later skip, etc. |

**Partial foundation:** `resync_labels.py` already in hourly cycle.

**Exit criteria:** Drift count stays 0 in normal weekly use.

---

## Phase 4 — Spend discipline (1 week)

**Goal:** $ only when it changes pursue/pass.

| Work | Owner | Deliverable |
|------|-------|-------------|
| Weekly cost rollup | JT | From LLM call logs → $ / messages / pursue packages |
| Short-circuit metrics | JT | Thread-link hits, rejection-cooldown skips, cache hits |
| Tune cycle caps | JT/RA | spam-limit, imap-limit, awaiting-LLM `--limit` from data |
| Optional: skip LLM when keyword << gate | JT | Config flag; measure false-negative risk |

**Exit criteria:** Weekly one-pager (or `status.sh` section) shows spend vs pursues.

---

## Phase 5 — CRM depth for the long middle (2–4 weeks)

**Goal:** relationship continuity after triage (vision UC-7–9).

**Ref:** [`job-tracker/docs/JOB_CRM_VISION.md`](job-tracker/docs/JOB_CRM_VISION.md)

| Work | Owner | Deliverable |
|------|-------|-------------|
| Quiet-jobs sweep | JT | Report: `awaiting_response` older than N days (periodic) |
| Offer comparison v1 | JT | Read-only table from `job_offers` for `status=offered` |
| Market-withdrawal draft | JT | Generate text; **never auto-send** |
| Transition validation on `advance_status` | JT | Reject illegal stage jumps |
| Optional: link CM contact IDs | JT/CM | Soft reference only |

**Exit criteria:** Manage interview → offer without spreadsheet side channels.

---

## Phase 6 — Unattended reliability (ongoing; start early)

**Goal:** fewer false HALTs; faster recovery.

| Work | Owner | Deliverable | Status |
|------|-------|-------------|--------|
| DB lock + WAL | JT | `with_db_lock.py`, 180s wait | **Shipped** |
| HALT-on-first-failure | RA | No silent retries | **Shipped** |
| 3-min comms_fast LaunchAgent | RA | Faster inbox tick | **Shipped** |
| Remove forced expiry window | RA | `WINDOW_HOURS=0` option | **Shipped** |
| HALT notification quality | RA | Reason + log path + `./install.sh` hint | Planned |
| Soft-retry allowlist | RA | Transient network only; max 1 retry | Planned |
| DB lock telemetry | JT | Log flock wait time; alert if high | Planned |

**Exit criteria:** Overnight HALTs from sleep/network drop; remaining HALTs are real bugs.

---

## Suggested calendar

```
Week 1:     Phase 0 finish + commit/deploy; start Phase 6 notifications
Week 2–3:   Phase 1 finish (deploy UI/KPI leftovers)
Week 3–4:   Phase 2 (intake) ∥ Phase 3 (drift audit)
Week 5:     Phase 4 (spend)
Week 6–8:   Phase 5 (CRM)
```

Phase 4 can overlap 2/3. Phase 6 stays open throughout.

---

## Cross-cutting rules (every phase)

1. **No auto-send** — drafts only.
2. **Profile canon** — packages/eval from `~/CLAUDE.md` only; run `verify_framework_sync` before merging scoring changes.
3. **Docs** — update slim README + PRIMER for user-facing commands; deep detail → `docs/REFERENCE.md`.
4. **Ship behind flags** — new cycle steps default off or dry-run until one clean week.
5. **One KPI review** after each phase before starting the next.

---

**Last updated:** 2026-08-24 — Phases 0–6 **code complete**; mini2 deploy pending (`./scripts/deploy_mini2.sh`).

---

## Implementation status (2026-08-24)

| Phase | Status | Key deliverables |
|-------|--------|------------------|
| **0** | Shipped | KPI table, `status.sh --json`, `verify_framework_sync`, `kpi_snapshot` |
| **1** | Shipped | `./monday.sh`, UI urgency, cycle KPI footer |
| **2** | Shipped | `MAILBOX_COVERAGE.md`, `scan_rejection_backlog.py`, PRIMER backfill § |
| **3** | Shipped | `audit_label_drift.py`, `label_drift.py`, drift in `status.sh` |
| **4** | Shipped | `spend_report.py`, spend in `status.sh` / `kpi_snapshot --check-spend` |
| **5** | Shipped | `quiet_jobs_report.py`, `offer_comparison.py`, `market_withdrawal_draft.py` |
| **6** | Shipped | DB-lock retry (exit 75), lock wait telemetry, HALT hints, `deploy_mini2.sh` |

**Your action (one time on mini2):**

```bash
cd ~/workspace-recruiting-automation/recruiting-automation
./scripts/deploy_mini2.sh
```

---

## Day 0–1 checklist

### Day 0 — mini1

- [x] Phase 0/1 code committed and pushed
- [x] Phases 2–6 code committed and pushed

### Day 1 — mini2 (unattended deploy script)

- [ ] Run `./scripts/deploy_mini2.sh` on mini2 between cycles
- [ ] Confirm `./status.sh` shows KPIs + framework sync OK
- [ ] Run `./monday.sh` once

### Ongoing ops (weekly)

- [ ] `python scripts/spend_report.py`
- [ ] `python scripts/audit_label_drift.py`
- [ ] `python scripts/scan_rejection_backlog.py` (apply if needed)
- [ ] `python scripts/quiet_jobs_report.py`

---

## Day 0–1 checklist (archived)

---

## KPI baseline (Phase 0)

| KPI | Source | Healthy target |
|-----|--------|----------------|
| Minutes/day in Gmail for recruiting | Manual (weekly) | → 0 |
| Unmatched communications | `status.sh` / `./monday.sh` | 0 |
| Awaiting full LLM review | `status.sh` / `./monday.sh` | Low; none > 3 days |
| Packages ready to send | `status.sh` / pending-actions UI | Same day |
| Waiting on them (stale) | `status.sh` | Follow up at threshold |
| Label↔DB drift | `resync_labels.py --dry-run` | 0 would-relabel |
| Framework sync | `verify_framework_sync.py` | OK |
| HALT incidents / week | `logs/run-*.log` | 0 |
| $ / pursue package / week | LLM logs (Phase 4) | TBD |

---

## Key references

| Doc | Path |
|-----|------|
| Umbrella ops | [`README.md`](README.md) |
| Comms consolidation (Track B) | [`comms-migration/comms-migration-runbook.md`](comms-migration/comms-migration-runbook.md) |
| Pipeline stages | [`job-tracker/PRIMER.md`](job-tracker/PRIMER.md) |
| CRM vision | [`job-tracker/docs/JOB_CRM_VISION.md`](job-tracker/docs/JOB_CRM_VISION.md) |
| Routing inventory | [`comms-migration/routing-inventory.md`](comms-migration/routing-inventory.md) |
| Status / Monday | `recruiting-automation/status.sh`, `recruiting-automation/monday.sh` |

---

## Session history

Plan originally proposed in Cursor session [3-repo README review](be473ebe-544c-417f-9a9f-adc18ea473b8) (Aug 23). Monday v1 shipped same day. Phase 0/1 leftovers implemented in [Phase 0/1 session](d349d791-dd2f-4ed1-a66b-63a5c7366cc9) but not yet committed.
