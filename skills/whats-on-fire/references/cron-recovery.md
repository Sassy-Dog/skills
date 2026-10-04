# Cron recovery cross-reference

Whether a red cron monitor is a live P0 or a fix already verified and merely waiting for the
schedule to confirm it.

> **Path resolution.** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at load time only — **not** into this file (reference docs are read raw), and it is **not** an environment variable in the shell. Before running anything below, set `PLUGIN_ROOT` to the plugin root's absolute path: where it comes from depends on the harness. On Claude Code the invoking `SKILL.md`'s command lines carry the root already substituted; on a harness that leaves the plugin-root placeholder unexpanded (omp), use the root that `SKILL.md`'s **Plugin root.** paragraph resolves, which is the `[Skill file: ...]` or `[Skill directory: ...]` path cut at `/skills/<skill-name>`. Do not search for it. Every command below quotes `"$PLUGIN_ROOT/..."`, so an unset value fails loudly with a 127 rather than resolving against `/`.

## Why the monitor lies for up to a week

Sentry recovers a monitor environment **only on a real check-in**, and the detective controls gate
check-ins to `schedule` events at both ends of every workflow. That gate is correct and must stay:
if a dispatch could satisfy a check-in, anyone re-running a workflow by hand would mask a dead cron
— the exact failure the liveness monitors exist to catch (platform#226/#146).

The consequence: the standard fix loop — merge the fix, `workflow_dispatch` to verify green against
live infrastructure — produces a green run that emits **no check-in**. The environment keeps
`status=error` with an open incident until the next scheduled run, up to a full cron interval away
(7 days for the weekly controls). A sweep that reads "not `ok`" as P0 reports a control that was
fixed and proven green as a live production fire, daily, until the schedule clears it. This
happened twice (platform#608, and the 2026-08-06 sweep that ranked `cron-relay-drift-check` as the
org's single P0 three days after its fix was verified).

**This is a port, not an invention.** platform#610 shipped the identical contract for the digest
consumer in `Sassy-Dog/platform:jobs/src/monitors/recovery.ts` (tests:
`jobs/test/recovery.test.ts`). This skill is the second independent consumer of the same Sentry
monitor state; keep the two contracts aligned — a subtly different reimplementation recreates the
split this fix closes. The one deliberate widening is repo resolution (below): the digest is
platform-local, this sweep is org-wide.

## Rule 0 — is the control actually broken?

**Check this before any rule below.** The rules that follow decide whether a BROKEN control has
since been fixed. This one decides whether it was ever broken.

Before the dispatch cross-reference, search the owning repo's open issues for the workflow basename
or the control's issue title. An open issue that the workflow itself files and auto-closes on a
clean run is a **durable owner**: proof the control ran and reported. Rank the underlying finding
on its own merits and report the monitor as the fourth state, "working — tracked in `<issue>`".

Two things follow, and both were got wrong on 2026-08-20 for `cron-ci-runner-cve-watch`:

- **The dispatch cross-reference is meaningless for this class.** A CVE backlog is cleared by a pin
  bump or a suppression entry, never by re-running the scanner, so no human would ever dispatch it.
  "No qualifying green dispatch since the failing check-in" was true, and carried no information.
- **This state does not clear, and must not re-page.** It persists as long as the finding does —
  the monitor checks in `error` every single day. Re-raising it as a fresh outage each morning is
  the unbounded-nag failure mode: an alert whose only remedy is "the outstanding work is still
  outstanding".

## The four rules — each one exists because a weaker version failed

**1. Only `error` qualifies for downgrade. `missed` and `timeout` always escalate.**
A `missed` check-in means the schedule never fired; a `timeout` means it fired and never finished.
A green dispatch disproves neither, and downgrading them would let a manual re-run quiet the
dead-cron alarm — the precise failure the schedule gate exists to prevent. `error` is the one
status meaning **"it ran"**, which is what a fix-and-verify dispatch can re-test at all. Treat any
unknown future status like `missed`: never downgrade it.

This rule used to read *"`error` is the one status meaning 'it ran, and the check it performed
**failed**'"*, and that second clause was wrong. Sentry offers a check-in exactly two states, so a
control with a findings tier has nowhere to put "it ran, the check SUCCEEDED, and it found
something tracked" — most controls in this org deliberately map that onto `error` too. `error`
therefore means "it ran", and nothing more. Which of the two it was is what rule 0 decides.

**2. The dispatch must post-date the most recent FAILING CHECK-IN, not merely the incident start.**
The reference instant is the environment's `lastCheckIn`; the incident start (from
`activeIncident`) is the fallback **only** when the payload carries no usable check-in. platform
hit this live: a green dispatch on 2026-08-01T15:41Z was followed by a **failing** scheduled run on
2026-08-03T16:47Z inside the same incident (open since 2026-07-27) — comparing against the incident
start alone would have called that control "fixed" while it was demonstrably still failing. A run
qualifies only with `conclusion == success` completed **strictly after** the reference; when
several qualify, cite the newest. Neither instant usable → never guess → the monitor stays P0 (no
footer — that is a payload gap, not a failed lookup).

**3. No evidence means ESCALATE — and say so.**
An unavailable read and an empty run list are different answers and must stay distinguishable. An
empty run list is *evidence* (nobody dispatched — no downgrade, no footer). A failed lookup — no
token, 401/403, network, 5xx, unparseable body — is the *absence* of evidence: the monitor reports
at **full severity** AND the report carries the footer naming the repo that could not be read
(section 5 of SKILL.md). A reader must be able to tell "nothing was fixed" from "we could not check
whether anything was fixed". Never let a failed lookup silently downgrade a P0; failing closed
leaves things louder, never quieter.

**4. Map monitor slug → workflow by DERIVATION, never a table.**
`cron-<basename>` → `<basename>.yml`. A new control gets coverage the day it is registered, with no
table to update and no second place to forget. A slug not starting with `cron-` (or bare `cron-`)
has no workflow to derive: **not applicable** — the monitor ranks normally and the footer stays
off. At Sassy Dog that is `llm-serving` and `ci-runner-ensure` (systemd probes on ubu-3xdv) and
`sentry-monitor-digest` (the digest job itself, trigger.dev). "Not applicable" is not
"unavailable": claiming the cross-reference was degraded for a monitor that never had a workflow
would be a false alarm about this sweep's own coverage.

## Resolving the owning repo — the org-wide widening

`recovery.ts` hardcodes `Sassy-Dog/platform` because the digest is platform-local. This sweep spans
the org, so the repo is an **input to resolve, not a constant** — `mission-control-health-cron`
belongs to another repo, which is a reason to look it up *there*, not a reason to skip it.

Resolution reuses the correlation the sweep already performs, run forward:

> monitor → its Sentry project → the owning product → that product's repo(s) → `<basename>.yml`
> in that repo

The product↔repo map is SKILL.md section 3 — the same map blind spots walk in reverse ("active
repo with no matching Sentry project"). Do not build a second mapping; one more map is one more
place to drift.

**Its collision caveat lives there too, and is not restated here.** SKILL.md section 3 states once
that a Sentry project and a repo sharing a name are not evidence of ownership, and that a pairing
resolved on name alone is *unconfirmed routing*. Read it there; what belongs here is what it costs
on this walk, which is more than a wrong line in a report. A downgrade asserts that one specific
repo's green dispatch re-tested *this* monitor's check — an unconfirmed route cannot carry that
assertion, so a route holding only by name match **never downgrades**: the monitor ranks at full
severity with its route named unconfirmed on the line. That is rule 3's shape (no evidence →
escalate, and say so) without rule 3's footer — the footer names repos whose lookup failed, and an
unconfirmed route is a read that was never entitled to be believed, not one that broke.

Resolution comes **before** any judgment about the workflow: never carry over `recovery.ts`'s
platform-local shortcut of listing other repos' monitors as permanently external. Whether the
derived workflow exists is answered *in the owning repo* (found → cross-reference; 404 → not
applicable), and a slug that yields no derivation at all is not applicable wherever it lives.

Two constraints fall out of going org-wide:

- **Products map to repos many-to-one** (`velovate` → `velovate` + `velovate-web`). When the
  resolved product spans several repos, look for the derived workflow across that set. Found in
  exactly one → cross-reference it there. Found in none, or in more than one → **not applicable,
  escalate**. Never guess which repo's run vouches for the fix.
- **`cron-<basename>` is a platform convention**, enforced there by `lint-detective-manifest.sh`.
  No other repo carries that guarantee, so outside platform the derivation is a hypothesis and a
  miss must be cheap and silent — which is why a 404 is split out below.

## Outcome table — 404 is an answer, 403 is the absence of one

`recovery.ts` collapses every failure into "unavailable". That is safe in platform, where the
manifest lint guarantees a registered control's workflow exists — a 404 there is nearly impossible.
Org-wide it inverts: every repo not following the convention would 404 on every monitor and flip
the footer on every sweep, and a footer that always fires is a footer nobody reads.

| Outcome | Meaning | Downgrade? | Footer? |
|---|---|---|---|
| Workflow resolved, green dispatch after the reference instant | verified fixed | **yes** | no |
| Workflow resolved, no qualifying run (including an empty list) | evidence: nobody verified — **only if the query was workflow-scoped**, see below | no | no |
| **404** — successful call, no such workflow in the owning repo | not applicable (convention not followed there) | no | **no** |
| 401 / 403 — no `actions:read` on that repo | absence of evidence | no | **yes, naming the repo** |
| Timeout / network / 5xx / unparseable | absence of evidence | no | **yes, naming the repo** |

A 404 is a *definitive answer from a successful request*; a 403 or a timeout is the *absence of an
answer*. Rule 3 is about the second kind only. Conflating them either poisons the footer (org-wide)
or hides a dead token behind a plausible-looking "no runs found".

**Token scope is a portfolio concern**: the lookup needs `actions:read` across the org. A repo the
token cannot read degrades **per repo** — that repo's monitors report at full severity with the
footer naming it — and never aborts the sweep, per SKILL.md section 1.

## Running the check

Run the cross-reference **only** for environments in `error` (rule 1 — other statuses never
qualify, so they cost no API call), after resolving the owning repo and deriving the workflow file.
One lookup per (repo, workflow) pair — reuse the result across environments that share a monitor.

```bash
ORG=Sassy-Dog REPO=platform WORKFLOW_FILE=relay-drift-check.yml \
  SINCE=2026-08-03T16:47:35Z \
  bash "$PLUGIN_ROOT/skills/whats-on-fire/scripts/check-dispatch-recovery.sh"
```

**A truncated page is a third state, and it renders exactly like an empty one.** The script's
query is scoped server-side to the one workflow (`/actions/workflows/<file>/runs?event=workflow_dispatch&status=completed&per_page=10`),
which is what makes "no qualifying run" trustworthy: 10 runs of one workflow reach back months. Any
reimplementation that pulls a repo-wide page and filters afterwards loses that guarantee — a
repo-wide page is **30 runs deep, not N hours deep**, and on `Sassy-Dog/platform` that has been
measured at under an hour. On 2026-08-18 exactly that cost a day of false P0 on
`cron-doppler-audit`: 52 unrelated runs landed between the green dispatch and the sweep, so the
page held zero `doppler-audit.yml` runs and the miss was reported as evidence. If you cannot scope
the query to the workflow, you have no answer — exit 10, full severity, footer. Never treat a
repo-wide page's miss as evidence.

`SINCE` is the reference instant of rule 2: the environment's `lastCheckIn`, or the incident start
only when no check-in is present; if neither is usable, do not run the check — the monitor stays P0
with no footer. The script honors the sibling-script contract (`ORG`, one JSON object on stdout,
exit 10 + `skipped: <reason>` on stderr when it cannot answer) and encodes the outcome table:

- exit 0, `"outcome": "checked"` — read `qualifying_run`: non-null → downgrade, citing its `url`
  and `completed_at`; null → no downgrade, no footer.
- exit 0, `"outcome": "not_applicable"` — the 404 row: rank normally, no footer.
- exit 10 — the absence-of-evidence rows: full severity, add the repo to the footer.

## Reporting the third state

A downgraded monitor is **not dropped** and **not** folded onto the `✓ Clean today:` line. It gets
its own entry under "fixed, awaiting scheduled confirmation" (SKILL.md section 5), with the
verifying run linked and the environment's own `nextCheckIn` named as the confirmation date. When
`nextCheckIn` is null, say the next check-in is unknown — never invent a date.

Do **not** lead with the outage duration. A control fixed on Monday and confirmed the following
Monday would otherwise read "`error` for 6d" every morning — technically true of the monitor,
actively misleading about the world, and the exact daily escalation this contract exists to stop.
