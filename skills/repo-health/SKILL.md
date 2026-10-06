---
name: repo-health
description: >
  This skill should be used when the user asks to "list TODO/FIXME/HACK markers", "scan tech debt
  markers", "find skipped tests", "how slow is CI", "CI duration and flake report", "is CI flaky",
  "is the release pipeline lagging", "mobile release lag", "is TestFlight behind main", or wants a
  quick scripted signals scan of code-debt markers, CI workflow health (median/p90 duration, flake
  hints), and release lag — the fast inputs a prioritization pass consumes. Also triggers when a
  project workflow skill (a generated survey-work) invokes sassy-dog:repo-health by name.
  For a full multi-agent engineering audit filed as GitHub Issues, use assess-it instead.
---

# Repo Health

Fast, scripted, read-only signal scans: tech-debt markers, skipped tests, CI duration/flake, mobile release lag. Each scan is one bundled script emitting parseable output. This is the cheap input layer for prioritization (e.g. a project survey-work); it makes no writes and files no issues.

## Scans

### Tech debt markers + skipped tests

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/repo-health`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
SCAN_PATHS="apps/ packages/" \
EXCLUDE_PATHSPECS="packages/db/src/migrations/** src/generated/**" \
bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-tech-debt.sh
```

- `SCAN_PATHS` defaults to the whole tracked tree; pass source dirs to cut noise.
- `EXCLUDE_PATHSPECS` for generated/migration dirs the caller knows about. Pass **bare paths** — the script adds the `:(exclude)` magic itself. A leading `:(exclude)` is stripped for back-compat with configs written against the old contract, but only one: doubling it produces a pathspec git accepts and silently ignores. Values reach git literally (the loop is fenced with `set -f`), so a `**` here is a git pathspec, not a shell glob. An element that is unusable after the strip — a lone `:(exclude)`, or a remainder still starting with `:` — is dropped with a warning on stderr rather than passed through, because a bare `:(exclude)` is an empty pattern git reads as "exclude everything".
- Output sections: `todo-markers` (capped 200), `skipped-tests` (capped 100), `todo-by-dir` (top 20 directories by marker count).

### CI duration + flake

```bash
WORKFLOW=ci.yml bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-ci-health.sh
```

Emits JSON: `{sample, median_min, p90_min, flake_runs, flake_shas}`. `REPO` defaults to cwd; `LIMIT` defaults to 50 runs. A "flake" is the same (headSha, event) failing then passing — the event key deliberately excludes merge-queue false positives (explained in the script header; don't simplify it away).

### Dependency exposure + remediation

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-dependency-exposure.sh
```

Emits JSON: `{enabled, open, high_crit, oldest_high_crit_age_days, vulnerable_packages, open_fix_prs, unremediated_packages, parked_green}`. `REPO` defaults to cwd.

**Rank by remediation state, never by alert count.** The count is lagging — it falls only when a fix merges, so a same-day CVE batch with fixes already queued is indistinguishable from a year of neglect:

| Condition | Tier |
|---|---|
| `parked_green[]` with `age_days >= 3` | **P0** — green, mergeable, and nobody is merging it. Quote the PR number and the merge command. |
| `unremediated_packages` non-empty, `oldest_high_crit_age_days >= 14` | **P0** — no PR was ever opened; the plumbing is broken. |
| `open_fix_prs[].state` is `BLOCKED`/`DIRTY`/`UNSTABLE` | **P1** — the bot did its job, the repo's CI rejects the fix. Usually a lockfile the updater cannot regenerate. |
| `unremediated_packages` non-empty, age `< 14` | **P1** — check whether a patched version exists upstream before escalating. |
| age `<= 2` and every vulnerable package is covered by an `open_fix_prs[]` entry | **not a finding** — one line on the clean list. The system is working. |

`open_fix_prs` is already filtered to PRs whose head ref names a vulnerable package, so an unrelated actions-group PR is never mistaken for a fix — judge per package, not per repo. `enabled: null` means "this token cannot see alerts", NOT "disabled"; report it as a scope question.

### Code scanning (CodeQL and other SARIF uploads)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-code-scanning.sh
```

Emits JSON: `{enabled, analyzed, truncated, open, default_branch, tools, new, inherited}`.
`REPO` defaults to cwd.

**`analyzed` is not `enabled`.** The API answers 404 for both "Advanced Security is off" and "on,
but no analysis has ever run", and both produce `open: 0`. `analyzed: false` with `enabled: true`
is a repo that has never been scanned — a blind spot, not a clean bill of health. `enabled: null`
is a token-scope question, exactly as with Dependabot.

**`truncated: true` makes `open` a floor, not a count.** Report it as "at least N".

Alerts are filtered to the resolved default branch and clustered by rule, then split at 14 days:

| Condition | Tier |
|---|---|
| `new[]` rule, severity `critical` | **P0** — just shipped, fixable while the code is fresh |
| `new[]` rule with `autofix: "ready"` | **P0** — the `parked_green` shape: the fix exists and only a human press is missing |
| `new[]` rule, severity `high` | **P1** |
| `inherited` | **one debt line** — never enumerated, never in a top 5 |
| `analyzed: false` | not a finding — a **blind spot** row |

`autofix` is probed only for critical/high rules, so it can only upgrade a P1 to P0; a medium rule
is never probed and stays `null`.

### Secret scanning

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-secret-scanning.sh
```

Emits JSON: `{enabled, open, oldest_age_days, active, unknown_validity, inactive}`. `REPO` defaults
to cwd.

| Condition | Tier |
|---|---|
| `validity == "active"` | **P0** on day zero — GitHub validated it against the provider; it is a live credential. No age math. |
| `bypassed == true` | **P0** — a human overrode push protection to commit it |
| `unknown_validity[]` entry with `age_days >= 30` | **P0** — unverified and untriaged for a month is itself the finding |
| `unknown_validity[]` entry with `age_days < 30` | **P1** — verify or dismiss |
| `inactive` | not a finding — already rotated; one line on the clean list |
| `enabled: false` | not a finding — a **blind spot** row |

`unknown` is not "probably fine" — it usually means GitHub cannot validate that provider's format
at all. Never rank an active credential by age; that buries the only unambiguous finding this
endpoint produces.

### Mobile release lag

```bash
WORKFLOW=mobile-release.yml MOBILE_PATH_PREFIX=apps/mobile/ \
bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-mobile-release-lag.sh
```

Emits JSON: last green iOS build (run/sha/date), `days_since_ios_success`, `mobile_commits_since`, and the latest run's iOS-leg state (catches a currently-stuck build). Skip this scan entirely for repos with no mobile app.

### Plugin drift (which checkouts run a stale plugin)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/repo-health/scripts/pull-plugin-drift.sh [<abs-checkout-path>...]
```

Emits JSON: the `reference` version an update would install, `user_scope`, one row per live
project pin with `current`, the `behind` subset, `no_entry` for any path you asked about that has
none, and the `pruned` counts. Read-only, no network, no `gh`.

**A project-scope install pins the version resolved when that checkout was first opened, and
nothing re-resolves it.** User and project scope drift independently, so `claude plugin update`
can report success while a repo keeps loading a months-old plugin — and the first symptom is
usually a feature "not working" in a repo whose config is perfectly correct. Run this before
treating any per-repo plugin behaviour as evidence.

**Restarting does not move a project pin, and neither does the bare update command.** Both were
measured on 2026-09-06: after a full restart this repo's pin was still `2026.8.94`, and
`claude plugin update sassy-dog@skills` answered *"Checking for updates … **at user
scope** … already at the latest version (2026.9.4)"* — a success message that changed nothing for
the checkout it was run in. The scope flag is what moves it, from inside the target repo:

```bash
claude plugin update <plugin>@<marketplace> --scope project   # then restart
```

So that route is **three** steps, not two, and the middle one is the one that looks done:
`marketplace update` refreshes metadata, `plugin update --scope project` moves the pin, and the
session must restart to load it.

**The cheaper route: delete the stale entry and let the next open re-take the snapshot.** A pin is
created when a session first opens a checkout whose `.claude/settings.json` declares the plugin,
and it is created **at whatever version is current then** — so a deleted pin does not come back
stale, it comes back fresh. Measured 2026-09-06: entries removed from
`~/.claude/plugins/installed_plugins.json` were re-created at `2026.9.4` on the next open, with no
per-repo update at all. That is also the only way to clear the entries left by torn-down agent
worktrees, which cannot be `cd`-ed into — 94 of them on this machine, every one a snapshot of a
directory that no longer exists.

> **Never clear a pin with `claude plugin uninstall --scope project`.** It does not only remove
> local state: it **edits the repo's committed `.claude/settings.json`**, emptying `enabledPlugins`
> — which strips the declaration `sassy-dog:setup-config` writes, so the repo then loads nothing
> for local sessions on other machines (cloud sessions and routines never read it; #468). Measured 2026-09-06 across 13 checkouts,
> 10 of which had the key silently deleted from a tracked file. It also makes a naive experiment
> lie: uninstall-then-reopen looks like the pin "stays gone", when what actually happened is that
> the declaration which creates it was deleted too.

**The declaration and the local pin are one mechanism, and you cannot keep one without the other.**
The declaration is a repo file (committed, or kept local in a public repo per `setup-config` Phase 7 step 2) that makes the plugin resolve for local sessions (it does
not reach cloud sessions, #468); the pin is the local snapshot it causes. Removing the declaration
to avoid the pin trades a silent staleness problem for a silent no-skills-at-all problem locally,
which is strictly worse.

Two results that are not what they look like:

- **`no_entry` is not clean, and it has two causes that look identical here.** Either no session
  has opened that checkout **since the declaration reached its working tree** — in which case the
  next one creates an entry pinned to whatever is current — or the repo is missing the
  `.claude/settings.json` declaration `sassy-dog:setup-config` writes, in which case it would load
  no skill at all for local sessions on other machines. **This report cannot tell them apart**:
  read the repo's `.claude/settings.json` for `enabledPlugins` *and* `extraKnownMarketplaces`
  before concluding anything, and read it **in the checkout**, not on the default branch: a repo
  can be committed-correct and locally behind. `mission-control` was exactly that — it ran a
  session on 2026-08-16 and still has no entry, because the declaring commit did not reach its
  working tree until a `git merge` three weeks later. "Has never been opened" is the reading that
  case punishes; the file on disk at session time is what decided it. Measured 2026-09-06, all
  three `no_entry` repos here had a correct tracked declaration and no pin; assuming the other
  cause would have manufactured three PRs that changed nothing.
- **`stale_clone_hint: true`** means an installed copy is newer than the marketplace clone, so
  `claude plugin update` cannot reach the current version yet — `claude plugin marketplace update`
  has to run first. That command refreshes metadata only and reports success either way.

## Interpreting results

Read `references/scoring.md` for the default severity thresholds (CI p90 > 25/40 min, flake > 5%, lag rules, skipped-test placement). Callers with their own scoring override it; absent that, apply the defaults and report:

- One line per signal with the number and its threshold (e.g. "CI p90: 31 min (target < 25) → P1").
- Empty/clean signals collapse into a single "clean" line — no section per empty surface.
- Never enumerate every TODO marker; surface directory hotspots and anything naming an incident or security concern.

## Degradation

Each script degrades independently: exit 10 with a `skipped: <reason>` line on stderr (not in a git repo, `gh` scope missing, workflow name wrong). Report the surface as "skipped — reason" and continue with the rest; never abort the whole scan over one missing input.
