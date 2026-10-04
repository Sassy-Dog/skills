---
name: whats-on-fire
description: >
  This skill should be used when the user asks "what's on fire", "what's on fire today", "what's
  broken", "what's broken across our products", "what's stuck", "what's red", "anything burning",
  "portfolio status", "portfolio health", "how's the portfolio looking", "which product needs
  attention", "cross-product status", "any leaked secrets", "security exposure", or wants one
  cross-product sweep of production failures and stalled work spanning EVERY repo in a GitHub org
  rather than a single repository. Pulls Sentry issues and cron monitors, org-wide open issues and
  pull requests, failing workflows, Dependabot exposure, and structural blind spots (products with
  no error monitoring, no alerting, or no dependency scanning), then ranks them across products and
  routes each one to the owning repo. Read-only — never files issues, never mutates state. For deep
  single-repo prioritization, defer to that repository's own survey-work skill.
---

# What's On Fire

One cross-product sweep of everything currently broken or stalled across a GitHub org, ranked, and
routed to the repo that owns it.

This skill is **read-only**. It pulls, correlates, ranks, and reports. It NEVER files issues, changes
Sentry status, or mutates anything — which is what makes it safe to run on a loop or a schedule.

**Scope boundary.** This decides *which product* deserves attention today. It deliberately does not
decide *what to do inside* that product — no tech-debt scan, no next-bet synthesis, no backlog
grooming. Those don't roll up meaningfully across a dozen products, and each repo's own `survey-work`
already does them with repo-specific knowledge this skill has no business duplicating. Report the
fire, name the repo, hand off.

## 1. Prerequisites

Run these probes. For each failure, label that surface `skipped — <reason>` in the output and
continue. **Never abort the whole sweep on one missing precondition.**

```bash
command -v gh && gh auth status
```

- **GitHub CLI** — `gh` missing entirely (cloud/CCR routine sessions ship without it) is the one
  probe failure that does NOT skip its surfaces: route the section 2B pulls through the GitHub-MCP
  fallback in `references/cloud-fallback.md` instead. Three parts of that surface have no MCP
  equivalent at all — Dependabot alerts, code-scanning alerts and secret-scanning alerts — and each
  is named on the sources line like any other skip: `skipped — no gh CLI (Dependabot API
  unreachable)` and `Security scanning skipped — no MCP capability (code + secret scanning alerts
  unreachable)`. **`check-dispatch-recovery.sh` (section 2A) also needs `gh`**, and its fallback is
  in the same reference: query the runs capability scoped to the ONE
  workflow, never a repo-wide page. That distinction is not a detail — a repo-wide page truncates
  the evidence away and turns a verified-green control into a P0. `gh` present but unauthenticated
  stays an ordinary skip.
- **Sentry** — probe by listing projects for the Sentry org; on error, skip both Sentry surfaces.
- **Portfolio root** — the local checkout directory (env `PORTFOLIO_ROOT`, default
  `~/Repos/sassy-dog`). Only needed for the two blind spots that compare the org against local
  clones; if it's missing, skip those two rows and keep the rest.

Defaults for Sassy Dog: GitHub org `Sassy-Dog`, Sentry org `sassy-dog`, region
`https://us.sentry.io`. Pass a different `ORG` to the scripts for another org.

## 2. Pull all surfaces in parallel

Issue the independent pulls in a single message with multiple tool calls.

### A. Production fires

**Sentry issues** — invoke `sassy-dog:sentry-triage`: org `sassy-dog`, all projects. Gate
policy: **report-only, no escalation** — this skill has no write path, so the gate classifies and
ranks but never files. It already owns the qualifying gate, the `!is:resolved` query shape, and GH
cross-referencing; don't reimplement any of that here.

**Sentry crons** — MCP-first, resolving the tool by capability rather than a hardcoded tool id
(same convention as `sentry-triage`; never a literal `mcp__...` id). No MCP connected → fall back
to REST exactly as the issues surface does: the cron-monitor recipe in `sentry-triage`'s
`references/api-fallback.md` (`SENTRY_AUTH_TOKEN`; the monitors endpoint needs `org:read` or
`alerts:read`, not just the issue scopes). With neither MCP nor a token, or on a failed call, mark
the surface `skipped — <reason>` per section 1 — the fallback must never turn "could not check"
into silence. List cron monitors for the org and read each monitor's per-environment state
(`environments[].status`, not the lifecycle-only monitor `status`). A `missed` or `timeout`
environment is a P0, always — no dispatch can vouch for a schedule that never fired. An `error`
environment is a P0 **only if BOTH cross-references come back negative**, and they answer different
questions:

- **Findings** (`references/cron-recovery.md`, "the findings cross-reference"): a check-in has only
  `ok` and `error`, and most controls deliberately map both *"I found something"* and *"I could not
  look"* onto `error`. If the owning repo has an **open auto-managed issue naming this workflow**,
  the control WORKED and reported a tracked finding — the fourth state, "working — tracked in
  `<issue>`" (section 5). Rank the finding on its own merits; never the monitor. Skipping this
  ranked a correct CVE scan as a P0 production outage on 2026-08-20 (`Sassy-Dog/platform#735`).
- **Recovery** (same file): check-ins are gated to `schedule` runs, so a fix verified green via
  `workflow_dispatch` leaves the monitor red until the next scheduled run — up to a week — and
  reporting that as a live fire is a false alarm this sweep has produced twice. A downgraded
  monitor becomes the third state "fixed, awaiting scheduled confirmation" (section 5).

Neither downgrade makes it `✓ Clean`. Run both for every `error` environment before ranking it.
Note which projects own monitors — a product with zero monitors isn't passing, it's unmonitored,
which belongs in blind spots.

### B. Stuck shipping + backlog heat

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/whats-on-fire`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/whats-on-fire/scripts/pull-org-github.sh
bash ${CLAUDE_PLUGIN_ROOT}/skills/whats-on-fire/scripts/pull-repo-signals.sh
```

- `pull-org-github.sh` — three org-level calls: the repo roster, every open PR (with `idle_days`
  precomputed), and every open issue. Archived repos are flagged in `repos` but excluded from `prs`
  and `issues`; read the script header for why that filtering is load-bearing.
- `pull-repo-signals.sh` — per-repo workflow failure counts, the **newest concluded** default-branch CI
  conclusion, currently-failing scheduled workflows, and Dependabot state — including alert AGE and
  per-package fix-PR state. Slower: 1 + 4N calls, plus one more per repo that actually has
  high/critical alerts (free for a healthy org) and one more per repo whose sample yields no
  default-branch CI verdict — which is **not** free for a healthy org, since a quiet repo triggers
  it (5 of 15 in [#367](https://github.com/Sassy-Dog/skills/issues/367)). Run it
  concurrently with the Sentry pulls, not after them.

`default_branch_ci` and `scheduled_failing` are separate fields and must stay separate in the
report, carried with its age. Push-class red **within 14 days** means shipping is blocked (P0) —
older than that it is a last known state, not a live outage, and ranks P1 (`references/scoring.md`).
A failing nightly job is an ops problem that
blocks nobody (P1). Merging them manufactures false alarms.

Both honor `ORG`, degrade with exit 10 + `skipped: <reason>` on stderr, and emit one JSON object.

**No `gh` on PATH** — both scripts exit 10 with `skipped: gh not on PATH`, but do not accept that
skip: follow `references/cloud-fallback.md` instead. It rebuilds both pulls from the session's
GitHub MCP tools, resolved by capability exactly like the Sentry crons above (never a literal
`mcp__...` id): roster via list-repos, per-repo tool scope widened with `add_repo`, per-repo pulls
fanned out to parallel subagents, every output field mapped so sections 3–5 consume the same shape.
The one exception is the Dependabot half of `pull-repo-signals.sh`, which has NO MCP equivalent: it
MUST be rendered `skipped — no gh CLI (Dependabot API unreachable)` and named on the sources line
(sections 1 and 5) — a named skip, never an approximation.

### C. Blind spots

Assemble from data already pulled, plus two local comparisons:

- Dependabot `enabled == false` → disabled. `enabled == null` → **unknown**, report as a token-scope
  question, never as "disabled".
- A repo with `unremediated_packages` non-empty **and no `open_fix_prs` at all** → *Dependabot is
  alerting but not fixing*. This is a structural blind spot, not a backlog item: the usual cause is
  that the repo's `dependabot.yml` dropped the ecosystem to dodge a lockfile its updater cannot
  regenerate (Bun, CocoaPods), while **security** updates keep firing regardless — they cannot be
  opted out of that way. Name the ecosystem and route it; the remedy is a lockfile-sync workflow, not
  a version bump.
- `code_scanning.enabled == false` → code scanning disabled. `analyzed == false` with
  `enabled == true` → **enabled but never analyzed**, which is a different row: the workflow exists
  or the feature is on, and no scan has ever produced a result. Both render `open: 0`, so reporting
  either as clean is the failure this row exists to prevent. `enabled == null` → token scope.
- `secret_scanning.enabled == false` → secret scanning disabled. `enabled == null` → token scope.
- Active repos with no matching Sentry project → no error monitoring.
- Zero metric alert rules org-wide → no alerting. Check once via the alert-rules tool.
- Roster entries with no directory under `PORTFOLIO_ROOT` → never cloned.
- Local directories whose repo is `archived` → archived but still checked out.
- Active repos with no `.claude/sassy-dog/survey-work.md` → no tuned deep-dive to route to. `survey-work`
  itself is a plugin skill present everywhere, so directory existence proves nothing; the **config**
  is what makes it repo-aware. An unconfigured repo still runs `survey-work`, just degraded. A repo
  carrying only the legacy `.claude/sassy-dog/plate-it.md` is a **different** row: "config predates
  the survey-work rename" — it has a tuned config, it just needs `setup-config` update mode; never
  report it as missing.

## 3. Roster and rollup

**The roster is the org, not the local directory.** Local checkouts drift: repos get archived while
their clone lingers, and org repos may never have been cloned at all. Take the active set from
`repos[] | select(.archived | not)`, and use the local comparison only to produce blind spots.

Products map to repos many-to-one. Report per repo, then group under the product heading. At Sassy
Dog the non-obvious ones are `velovate` → repos `velovate` + `velovate-web` (the local directory
`velovate-app` maps to the repo named `velovate`), `lupita` → `lupita` + `lupita-web` (both
archived), and `devcanopy` → `devcanopy`. Everything else is one product, one repo — and that
default is a **name match**, which is the one piece of evidence here that lies.

**A Sentry project and a repo sharing a name are not evidence of ownership.** A project slug can
match a repo that does not own it — a marketing-site repo `<product>-web` alongside a Sentry
project `<product>-web` fed by a member-app frontend that lives in a different repo entirely. Note
which way the selection runs: the entries listed above are *in* the map precisely because their
names lie, so the projects that most need the map are exactly the ones a name match resolves most
confidently. Absence from the map means unverified, never verified.

So the default is qualified, and the qualification applies to every walk on this map. A pairing the
map names explicitly is **routed**. A pairing resolved only because the two names match is
**unconfirmed routing** — still report it and still name the best-candidate repo, but mark it on
the line (`<repo> — routing unconfirmed, name match only`) rather than asserting that repo owns it.
To confirm, check that the project's recent `culprit`/file paths resolve in that repo, or that the
repo actually initializes that project's DSN; once confirmed, add the pairing above so the next
sweep reads it as fact. Never silently promote a name match to ownership.

This same map is what resolves a red cron monitor's **owning repo** for the recovery
cross-reference (`references/cron-recovery.md`): monitor → its Sentry project → the owning product
→ that product's repo(s). It is already load-bearing in the reverse direction — blind spots walk
repo → Sentry project — so keep both walks on this one map; a second, separate mapping would be
one more place to drift. The caveat above travels with the map for the same reason: it is stated
here once, and the cron walk points back at it instead of carrying its own copy. That walk is where
an unconfirmed route costs the most — it decides which repo's green dispatch is allowed to vouch
for a monitor — so `references/cron-recovery.md` spells out what unconfirmed means there.

<!-- rule: coverage-not-assumed -->
### Coverage is counted, never assumed

**The roster is the denominator, and every aggregate claim needs a per-repo verdict behind it.**
State coverage explicitly — `swept N of M active repos` — and name every repo that produced no
verdict, with why. A repo the sweep could not read is reported as unread; it is never folded into
an aggregate and never quietly dropped from the count.

The sentence this exists to prevent is *"CI is green across all M repos"* written after only N of
them were actually reduced. That is not a ranking mistake, so no tier rule catches it: the repos
that were read really were green, and the claim is false only because of the ones that were not.
An unread repo omitted from the report is indistinguishable from a healthy one.

Two numbers make it checkable, so carry both: the roster count, and the count of repos that
produced a verdict. If they differ, the difference is the finding — say which repos and why before
saying anything about the ones that worked.

This binds the report, not the puller. A puller is free to fail per repo; what it may not do is let
the failure disappear between the pull and the summary.

## 4. Score

Apply `references/scoring.md`. The two rules that matter most:

- **Stuck work escalates with age; customer pain decays with it.** Never share one curve. A PR idle
  123 days outranks one idle 3 days.
- **A red default branch is P0 on its own when `default_branch_ci_age_days` is 14 or less**,
  independent of historical failure rate. Rate answers "is CI trustworthy"; a *recent* conclusion
  answers "is it broken right now". A verdict may be recovered by a narrow re-query and be months
  old, so age is what separates a live outage from a last known state: a `failure` older than
  14 days ranks P1, and a stale `success` never earns `✓ Clean today:` — it renders under
  `🕰 Stale CI verdicts` below, its one destination. A **null** age is not a young one: an undated
  verdict resolves the same way in both directions (`references/scoring.md`).
- **Dependabot exposure is ranked by REMEDIATION STATE, never by alert count.** The count is a
  lagging indicator — it falls only when a fix merges, so "we were slow" and "the world just
  changed" produce the identical number. Rank from `dependabot.oldest_high_crit_age_days`,
  `open_fix_prs[].state`, and `unremediated_packages`:

  | Condition | Tier | Why |
  |---|---|---|
  | `open_fix_prs[]` has a `CLEAN` PR with `age_days >= 3` | **P0** | The fix exists, it is green, and nobody is merging it. A pure process failure — the cheapest P0 you will ever close. |
  | `unremediated_packages` non-empty and `oldest_high_crit_age_days >= 14` | **P0** | No PR was ever opened and the exposure is real. Broken plumbing, not a busy week. |
  | `open_fix_prs[]` PR is `BLOCKED`/`DIRTY`/`UNSTABLE` | **P1** | Dependabot did its job; the repo's CI rejects the fix. Name the failing check — this is usually a lockfile the bot cannot regenerate. |
  | `unremediated_packages` non-empty, `oldest_high_crit_age_days < 14` | **P1** | Genuinely unfixed, but young enough that it may simply be unpatched upstream. Check whether a patched version exists before escalating. |
  | `oldest_high_crit_age_days <= 2` **and** every vulnerable package appears in some `open_fix_prs[].addresses` | **not a fire** | A fresh advisory batch with fixes already queued is the system WORKING. One line under `✓ Clean today:`. |

  Judge remediation **per package**, never per repo — `open_fix_prs` is already filtered to PRs whose
  head ref names a vulnerable package, precisely so an unrelated actions-group PR cannot be mistaken
  for a fix. Report `unremediated_packages` by name; "3 high/critical" tells nobody what to do.

Normalize priority labels across the repos' differing taxonomies using the map in the reference —
but never re-derive a priority a maintainer already assigned.

**An issue labelled `security` or `area:security` is always listed by number, whatever tier it
normalizes to — `unranked` included.** Its tier is untouched; only its visibility is guaranteed. A security issue must
never end up inside a bare `P2: 10` count — and since this edition cannot read code- or
secret-scanning alerts at all, a human-filed issue is the only route those findings have into
this report.

## 5. Output format

> The routine edition of this skill (in `routines`) has one automated consumer,
> `work-fire-watch`, which reads only the `fire-watch-v1` block that edition appends —
> `docs/ROUTINES.md` lists the sentinels. This interactive edition appends no block.

Render inline as markdown. Two anti-verbosity rules are non-negotiable: (1) empty surfaces get a
single token on the consolidated `✓ Clean today:` line, never their own section; (2) within a
section, skip empty tiers. Recommendations go LAST.

**`Load:` is a REQUIRED field on the sources line — always rendered, never dropped**, and the
anti-verbosity rules above do not apply to it: it has no empty state to collapse. Its value is
`plugin` when this skill ran as `sassy-dog:whats-on-fire`, and `fallback (degraded)` when this body
was read from `skills/whats-on-fire/SKILL.md` because the plugin skill was not among the session's
available skills (the routine fallback clause in `CLAUDE.md`). It is a field rather than a sentence
for one reason: a missing sentence reads as a healthy run, while an empty slot reads as broken — on
2026-08-11 a degraded run silently omitted its degraded note and delivered an otherwise complete,
authoritative report (#146). It is distinct from the skips that follow it on the same line: those
say a *surface* could not be pulled, this says the *skill body* itself came from the fallback path.
The field is still this run's own claim about itself, so it is never the authority: **where the
report and the run log disagree, the run log wins** — settle it with the out-of-band check in
`docs/ROUTINES.md`.

```markdown
# What's on fire (YYYY-MM-DD)

_Load: <plugin|fallback (degraded)> · Sources: <pulled, with any "skipped — reason">_
_Coverage: swept <N> of <M> active repos — <named repos with no verdict, and why>_

✓ Clean today: <surface> · <surface> · ...

## 🔥 Production fires (P0: N · P1: N)
### P0
- **<product> — <title>**
  - Impact: <N users, M events, last seen Yh ago> | <monitor env state> | <branch is red>
  - Sources: [Sentry](url) · [run](url)
  - Why this matters: <one line>

### ⏳ Fixed, awaiting scheduled confirmation
- **<product> — `<monitor>` (<project>/<env>)** — green [dispatch](url) at <time>; awaiting
  scheduled confirmation <nextCheckIn date>

### ✅ Working, reporting a tracked finding
- **<product> — `<monitor>` (<project>/<env>)** — control ran and reported; tracked in
  [<repo>#<N>](url). Finding ranked separately above.

## 🔒 Security exposure (P0: N · P1: N)
### P0
- **<product> — <credential type or rule>** — <repo>
  - Evidence: <alert numbers> · <validity or severity> · open <N>d
  - Fix: <rotate and revoke | merge PR #N | autofix ready>
_Inherited: <repo> N alerts across M rules, oldest Dd._

## 🚧 Stuck shipping
- **<repo>#<N> <title>** — idle <D>d · <one-line why>

## 🎯 Backlog heat
- **<repo>#<N> <title>** — `<label>` — <one-line why>

## 🕰 Stale CI verdicts (not a tier)
- **<repo>** — `CI last green <N>d ago` — [run](url)
- **<repo>** — `CI last green — age unknown` — [run](url)

## 🕶 Blind spots (silent, not healthy)
- <condition> — <affected repos>

## 👉 Today's top 5 (cross-product)
1. **<title>** — <product> · <one-line why>

_⚠ Cron recovery cross-reference could not run for: <repo> · <repo> — red monitors there are
shown at full severity._

_To dig in: `cd <product> && /survey-work`_
_To ship: `cd <product> && take #<N>`_
```

Keep the footer. This skill's job ends at naming the product; the per-repo `survey-work` and `take-it`
take it from there, and the footer is what makes that handoff explicit rather than implied.

`🕰 Stale CI verdicts` is the ONLY place a stale `success` renders, and it is a real section
rather than a phrase an agent is left to place. A `default_branch_ci` of `success` whose
`default_branch_ci_age_days` is over 14 or `null` is the newest evidence there is and is not
evidence about today: it is not a fire, not a tier, and not `✓ Clean today:`. It does not go on the
`Coverage:` line either — that line names repos with **no** verdict, and a stale success has one.
Empty, this section collapses to a token on the clean line like any other surface. Full rule:
`references/scoring.md`.

P0 security items are **not** duplicated into Production fires. The cross-product top 5 is where
urgency gets expressed; this skill's existing rule is that semantically distinct signals stay in
separate fields rather than merging into false alarms.

Four rules for the cron lines, from `references/cron-recovery.md`:

- **"Working, reporting a tracked finding" is a fourth state** (rule 0) — never folded into P0 and
  never onto `✓ Clean today:`. Link the owning auto-managed issue. Do NOT report an outage duration
  for it: the monitor has been `error` for as long as the finding has existed, which says nothing
  about the world. Unlike the third state it never clears on its own, so it must not re-page daily.
<!-- rule: monitor-issue-not-independent-source -->
<!-- rule: dupe-cron -->
- **A `monitor_check_in_failure` Sentry issue is not an independent source.** It is *generated by*
  the check-in, so citing it beside the monitor row counts one non-event twice — which is exactly
  how the 2026-08-20 alert came to read `Sentry · CI run` for a single cron failure. Read the
  issue's `monitor.slug`; if a cron row already covers that slug, drop it as `dupe-cron`.
- **"Fixed, awaiting scheduled confirmation" is a third state** — never folded into P0, never onto
  `✓ Clean today:`. Link the verifying dispatch and name the environment's own `nextCheckIn` as the
  confirmation date (unknown when null — never invent one). Do not lead with the outage duration:
  "`error` for 6d" is true of the monitor and misleading about the world. The section follows the
  skip-empty-tiers rule like any other.
- **The cross-reference footer appears only when a lookup actually failed** (missing `actions:read`,
  network, 5xx — the exit-10 cases), and it names each repo it could not read. A 404 — no such
  workflow in the owning repo — is "not applicable", never a footer entry; a footer that fires on
  every sweep is a footer nobody reads.

## 6. Read-only contract

This skill NEVER files GitHub issues, changes Sentry status, moves board cards, or mutates anything.
If a fire deserves an issue, say so in the report and name the flow that would file it — the human
runs that deliberately, in the owning repo, where the repo's own gates and labels apply.

There is no conditional write gate here, and adding one would be a mistake: a portfolio-level filer
has no principled answer to "which repo does this get filed against" for a cross-product signal, and
the per-repo skills already own filing with better context.
