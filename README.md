# skills

Sassy Dog AI agent skills marketplace for Claude Code, Gemini CLI, and other AI coding tools.

Everything here is plain Markdown plus Bash. Claude Code consumes it as a plugin via the marketplace below; any other agent that can read a Markdown instruction file and run a shell script can use the same `skills/` directory directly. Model choice is harness-neutral: every dispatch site names a tier, bound per harness in [`docs/MODEL-TIERS.md`](docs/MODEL-TIERS.md). The dispatch *mechanics* are still Claude-Code-shaped (the Agent tool, `isolation: "worktree"`, `${CLAUDE_PLUGIN_ROOT}`), so another harness has to supply those.

**[Contributing](CONTRIBUTING.md)** · **[Security](SECURITY.md)** · **[Versioning](docs/VERSIONING.md)** · Licensed [Apache-2.0](LICENSE)

## Plugins

| Plugin | Skills | Description |
|--------|--------|-------------|
| `sassy-dog` | `survey-work` | Prioritized work plate — customer pain, backlog, tech debt, security exposure, dev experience, synthesized next bets (formerly `plate-it`) |
| `sassy-dog` | `groom-backlog` | Backlog grooming — refine issues until dispatchable, then promote to Ready (formerly `groom-it`, originally `fill-it`) |
| `sassy-dog` | `take-it` | Parallel issue-shipping — "take #341, #432", one worktree sub-agent per issue |
| `sassy-dog` | `dispatch-ready` | Loop-driven Ready dispatcher — one idempotent tick per invocation, under `/loop` (formerly `drain-it`) |
| `sassy-dog` | `send-it` | Single-PR end-to-end — worktree audit, freshness gates, pre-flight, doc reconciliation, PR body, watch, merge |
| `sassy-dog` | `tidy-repo` | Post-shipping git reconciliation — stale branches, worktrees, stashes, untracked noise (formerly `clean-it`) |
| `sassy-dog` | `github-secrets` | GitHub Actions secrets & variables — scope hierarchy, CLI usage, common mistakes |
| `sassy-dog` | `testflight` | TestFlight / App Store Connect API — builds, testers, feedback |
| `sassy-dog` | `assess-it` | Multi-agent repository audit → deduped, PR-sized GitHub Issues under a tracking Epic |
| `sassy-dog` | `recap` | Session wrap-up report — work completed, what surfaced, issues to file, immediate next steps |
| `sassy-dog` | `setup-repo` | Orchestrator: owns the broad "set up this repo" intent — runs `setup-config` → `setup-hooks` → `setup-deps` strictly in sequence behind one combined plan gate, and reports what ran, what was skipped, and why |
| `sassy-dog` | `setup-config` | Generator/refresher: writes and re-syncs a repo's `.claude/sassy-dog/*.md` workflow-skill config plus its `.claude/settings.json` plugin declaration |
| `sassy-dog` | `setup-hooks` | Generator/refresher: renders a repo's Claude Code hooks (`.claude/hooks/sassydog-*.sh` + settings.json wiring) — a stack-specific format-on-edit/lint dispatcher from detection, plus an always-on stray-artifact guard that keeps throwaway binaries out of the repo root; re-runnable as the stack evolves |
| `sassy-dog` | `setup-deps` | Generator/refresher: renders a repo's `.github/dependabot.yml` (grouped, per detected ecosystem) plus its dependency automation workflows — auto-merge, `bun.lock` sync, pod lockfile sync — from stack detection; re-runnable as the stack evolves |
| `sassy-dog` | `github-issues` | Issue/board reads, stale-issue detection, idempotent dedupe-then-file issue creation |
| `sassy-dog` | `sentry-triage` | Gate-and-escalate Sentry triage; qualifying hits escalate via `github-issues` |
| `sassy-dog` | `pr-shepherd` | PR lifecycle mechanics — check polling, merge queue vs direct merge, coupled-PR serialization, worktree teardown |
| `sassy-dog` | `repo-cleanup` | Post-shipping git reconciliation mechanics — `[gone]`/squash-merged branch sweep, stale-worktree teardown, stash triage, untracked-noise sweep (the engine behind a repo's `tidy-repo`) |
| `sassy-dog` | `repo-health` | Scripted signal scans — TODO/FIXME markers, skipped tests, CI duration/flake, mobile release lag, code/secret scanning |
| `sassy-dog` | `whats-on-fire` | Org-wide portfolio sweep — Sentry issues + crons, stalled PRs, red default branches, Dependabot exposure, code/secret scanning, and blind spots (products with no monitoring/alerting/scanning); ranks across products and routes each to the owning repo's `survey-work` |
| `sassy-dog` | `whats-behind` | Portfolio currency audit — peer-relative version drift across pinned Actions, toolchains, runner labels, and Dependabot coverage; reports which repos lag and whether the cause is a missing automation config |
| `sassy-dog` | `work-recommendations` | Work a survey-work plate in order — resolve each recommendation to an issue (filing the issue-less ones behind one preview), then ship them through `take-it` in plate order |
| `sassy-dog` | `work-fire-watch` | Work this repo's items from the latest `daily-fire-watch` Slack post — exact-name routing, report order preserved, delegates the loop to `work-recommendations` |

### Workflow skills + capability skills

The six workflow skills — `survey-work` (prioritized work plate), `groom-backlog` (backlog grooming to
Ready), `take-it` (parallel issue-shipping: "take #341, #432"), `dispatch-ready` (loop-driven Ready
dispatcher), `send-it` (single-PR end-to-end), and `tidy-repo` (post-shipping git reconciliation) —
each have **one** generic implementation, shipped in the plugin. There is no per-repo copy.

Per-repo behavior lives in that repo's `.claude/sassy-dog/<skill>.md`: YAML frontmatter for facts
and toggles, `##` sections for freeform prose that survives refreshes. Each skill inlines its config
at load time, and treats a missing config as a first-class `NO_CONFIG` state — degrading to a
conservative mode rather than erroring. `take-it` and `dispatch-ready` are the two exceptions that stop
instead, because both act unattended and outward-facing (the two dispatch front-ends below stop
with them).

Facts that can be derived are never configured: repo slug, default branch, and
`delete_branch_on_merge` all come from `gh repo view` at runtime, so they cannot drift.

Two dispatch front-ends sit on top of the six workflow skills and carry **no config template of their own**:
`work-recommendations` turns a `survey-work` plate's ordered recommendations into one `take-it`
batch (filing the issue-less items first, preview-then-confirm), and `work-fire-watch` reads the
latest `daily-fire-watch` post from Slack, keeps the lines routed to the current repo by exact
name, and hands them to `work-recommendations` — one implementation of the loop. Both read the
repo's existing `take-it.md` only, and stop on `NO_CONFIG`.

[Stacked PRs](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs) are supported
and **opt-in per repo** via a `stacked_prs:` config block, absent by default. Handling an existing
stack safely is not opt-in: `pr-shepherd` always probes before merging, because a middle layer
reports green + `MERGEABLE` + `CLEAN` exactly like an ordinary PR and merging on that reading lands
it out of order. Whether a repo is enabled for the preview, whether a PR is a layer, and whether a
layer is safe to merge now are all derived at runtime by `pr-shepherd`'s `stack-probe.sh` — the
config carries only the policy.

Workflow skills stay thin by delegating shared mechanics to the capability skills
(`github-issues`, `sentry-triage`, `pr-shepherd`, `repo-cleanup`, `repo-health`, `testflight`).
`repo-cleanup` remains distinct from `tidy-repo`: the former is the mechanics engine, the latter the
user-facing flow.

`setup-hooks` is the same pattern one layer down: it detects the repo's stack (ruff,
prettier, markdownlint, shellcheck, dart, rustfmt, gofmt, dotnet format — keyed on repo config, not
installed binaries) and renders a PostToolUse dispatcher into `.claude/hooks/`, wired into
`.claude/settings.json`. Formatters fix silently; unfixable lint findings exit 2 so they feed
straight back for an immediate fix. Alongside it, a stack-agnostic **stray-artifact guard** is
always rendered: it keeps screenshots and other throwaway binaries out of the repo root, pointing
them at a gitignored `tmp/` that `tidy-repo` already sweeps. It reports, never relocates. Re-runs reconcile only entries the generator owns (command path
references `sassydog-`), never hand-written hooks. The generated script itself carries a
`generated-by:` producer marker, and because that marker is committed in every consumer repo the
ownership matcher accepts every producer name this generator has ever emitted, in either marker
namespace, and normalises to the current form on write — a matcher narrowed to the current name
would treat every pre-rename consumer script as hand-written and silently skip it.

`setup-deps` is the third generator in that family, aimed at dependency automation: it detects the
repo's ecosystems from tracked files, renders `.github/dependabot.yml` grouped per ecosystem, and
adds the workflows that keep Dependabot's PRs mergeable — auto-merge behind a real required check,
plus `bun.lock` / `Podfile.lock` sync where Dependabot cannot rewrite the lockfile itself. Its
`generated-by:` marker is committed inside every consumer repo's `.github/`, so the same ownership
rule applies: the matcher accepts every producer name this generator has ever emitted, in either
marker namespace, normalising to the current form on write, while a file with no marker at all is
reported as hand-written and never overwritten.

`setup-repo` sits above all three as the umbrella entry point, and owns the broad *"set up this
repo"* intent so nobody reaches for one generator and silently gets a third of a setup. It holds no
generation logic — it picks which generators apply, prints one combined plan of every file they
would touch, runs them **strictly in sequence** (`setup-config` → `setup-hooks` → `setup-deps`), and
reports what ran and what was skipped. The order is load-bearing rather than cosmetic: the first two
both write `.claude/settings.json` (the marketplace/plugin declaration and the `PostToolUse` entry),
each merging surgically into its own keys, so sequential runs compose while a concurrent or
last-write-wins run drops one of the two with no error anywhere.

### Harness support

Which skills are expected to run outside Claude Code. Statuses are `expected`, `untested` or
`not supported`. **`untested` is the default**: the plugin installs and loads on [omp](https://omp.sh), but no shipped skill
has been run end to end through a model there (only narrow probes: toy skills, and two shipped skills stopped before any workflow step, see below), so no omp cell says `expected`. Claude Code is the shipping target. The rows cited are the mechanism
numbers in the inventory of [`docs/HARNESS-PORTABILITY.md`](docs/HARNESS-PORTABILITY.md), and each
skill's rows are the ones whose reproducing command matches files under that skill, except row 14 (`mcp__` literals), which the inventory says is not a dependency and which this matrix omits. The omp spike
([#424](https://github.com/Sassy-Dog/skills/issues/424)) reported: row 5 (`${CLAUDE_PLUGIN_ROOT}`)
has a path-resolvable equivalent, and row 6 (`` !`...` `` config injection) has no load-time equivalent:
the `` !`...` `` line reaches the model unexecuted. The model-backed checks of
[#440](https://github.com/Sassy-Dog/skills/issues/440) then ran toy probe skills on omp 18.6.0, with this repo's own
`CLAUDE.md` in the model's context per omp's source (it walks up past a nested repository's root), one run each with one model: the agent
ran the literal `${CLAUDE_PLUGIN_ROOT}` token first, failed, and recovered by searching, and an agent told to
read the repo config by absolute path did so and used its value. Neither result is evidence about a consumer repo.
[#425](https://github.com/Sassy-Dog/skills/issues/425) then repeated both out of tree on shipped skills with no context file loaded, again one model, ten runs: with
`github-issues` unchanged the agent searched for the script, and with a root-resolution paragraph that also forbids searching it used the right root and did not search in 2 of 2 runs, and a wording without that clause searched in its one run; the unchanged `send-it`
was handled correctly in three runs even though its `` !`...` `` line arrives unexecuted, because the agent ran or read the config itself. The designs for both rows are in
[`docs/HARNESS-PORTABILITY.md`](docs/HARNESS-PORTABILITY.md). Row 5's paragraph has since shipped
([#454](https://github.com/Sassy-Dog/skills/issues/454)): every `SKILL.md` that carries `${CLAUDE_PLUGIN_ROOT}` now carries one token-free paragraph before the first fenced command that uses it,
which tells an agent whose harness leaves the placeholder unexpanded to take the plugin root from the skill's own path line and not to search. On omp it was run out of tree, five runs with one model: on `github-issues` the first command used the right
root with no search in 3 of 3 runs, and a reference-doc command did too in 2 of 2, but not through the `PLUGIN_ROOT` preamble (see [A‴ in the doc](docs/HARNESS-PORTABILITY.md#token-free-paragraph-at-the-shipping-placement-454)). It is inert in Claude Code, which was checked once. Row 6 has shipped too ([#455](https://github.com/Sassy-Dog/skills/issues/455)): `send-it`, `survey-work`, `groom-backlog` and `tidy-repo`, whose failure on an unrun config line would be silent, carry a paragraph under the `` !`...` `` line that tells an agent whose harness leaves the line as text to read the repo's config file by absolute path, and to treat a missing file as `NO_CONFIG`, never an unrun line as "no config exists". The four skills that stop on `NO_CONFIG` (`take-it`, `dispatch-ready`, `work-recommendations`, `work-fire-watch`) do not carry it: the unchanged `take-it` and `dispatch-ready` were right in 12 of 12 omp runs, config present and absent, on prompts that did not mention config, while `work-recommendations` and `work-fire-watch` were never run and are included by inference from `take-it`'s runs. That was one model, one prompt shape per skill and gh unauthenticated, and the paragraph's absent branch was run once, on `send-it`. No cell below changed, because no shipped skill
has been run end to end through a model.

The dispatch family is `not supported` on omp: it concentrates Agent-tool fan-out (row 1),
`isolation: "worktree"` (row 3) and skill-to-skill delegation (row 4), whose omp equivalents
the spike found, and which also need omp settings a plugin cannot ship. #440 probed only row 3, narrowly (two
isolated `task` calls, one per merge mode: patch mode dirties the parent checkout and branch mode commits onto it).
[#426](https://github.com/Sassy-Dog/skills/issues/426) then found that `task.isolation.apply: false` left the parent untouched with a verified push, and its contract requires
`task.isolation.enabled: true`, `task.isolation.apply: false` and `task.isolation.merge: patch`. Until the `take-it` and `dispatch-ready` implementation issues land, the contract's outcome on omp is Stop, so the matrix keeps `not supported`. The review gate (`pr-review-orchestrator` and the nine `*-reviewer` agents) is
in that family and follows it.

| Skill | Family | Claude Code | omp | Inventory rows |
|-------|--------|-------------|-----|----------------|
| `take-it` | Dispatch | expected | not supported | 1, 3, 4, 5, 6, 7, 13 |
| `dispatch-ready` | Dispatch | expected | not supported | 1, 3, 4, 5, 6, 7, 11 |
| `send-it` | Dispatch | expected | not supported | 1, 4, 5, 6, 7, 13 |
| `assess-it` | Dispatch | expected | not supported | 1, 2, 5 |
| `work-recommendations` | Dispatch | expected | not supported | 4, 5, 6, 7, 13 |
| `work-fire-watch` | Dispatch | expected | not supported | 4, 6, 7, 13 |
| `survey-work` | Config-driven workflow | expected | untested | 4, 5, 6, 7 |
| `groom-backlog` | Config-driven workflow | expected | untested | 4, 5, 6, 7 |
| `tidy-repo` | Config-driven workflow | expected | untested | 4, 6, 7, 13 |
| `whats-on-fire` | Config-driven workflow | expected | untested | 1, 4, 5, 7 |
| `setup-repo` | Generator | expected | untested | 4, 7, 8, 9 |
| `setup-config` | Generator | expected | untested | 5, 6, 7, 8, 9, 10, 13 |
| `setup-hooks` | Generator | expected | untested | 5, 9 |
| `setup-deps` | Generator | expected | untested | 5 |
| `github-issues` | Capability | expected | untested | 5, 7, 11 |
| `pr-shepherd` | Capability | expected | untested | 3, 5, 15 |
| `repo-cleanup` | Capability | expected | untested | 3, 5, 15 |
| `repo-health` | Capability | expected | untested | 5, 8, 9, 13, 15 |
| `whats-behind` | Capability | expected | untested | 5 |
| `sentry-triage` | Capability | expected | untested | none |
| `testflight` | Capability | expected | untested | none |
| `github-secrets` | Capability | expected | untested | none |
| `recap` | Session report | expected | untested | none |

Notes on reading it:

- `none` means no inventory mechanism matched under that skill's directory (row 14 excluded: not a dependency per the inventory), which is not evidence
  it runs on omp. The skill may still use a Claude Code tool that no row covers.
- `whats-on-fire` hits row 1 only through its cloud-routine fallback, and `pr-shepherd` and
  `repo-cleanup` hit row 3 only to describe worktree teardown. Both are weaker dependencies than
  the same row in the dispatch family, but neither has been verified on omp.
- `setup-config` and `setup-hooks` write Claude Code files (`.claude/settings.json`,
  `.claude/hooks/`), so what they generate is Claude-Code-shaped even where the skill itself runs.
- The row sets above were derived with the reproducing commands in the inventory scoped to
  `skills/<name>`. Nothing gates them, so re-run the commands rather than trusting this table when
  the tree moves.

### Review agents

Nine domain reviewers ship with the plugin (namespaced `sassy-dog:<name>`):
`architecture-reviewer`, `code-quality-reviewer`, `security-reviewer`, `testing-reviewer`,
`cicd-release-reviewer`, `infra-platform-reviewer`, `observability-ops-reviewer`,
`dx-docs-reviewer`, `dependency-supply-chain-reviewer`. Each runs in either of two modes and
returns the same findings envelope (`{"findings": [...]}`) and finding schema in both: **audit mode**, a whole-repo sweep dispatched by
`assess-it`, and **diff-scoped mode**, one changeset dispatched by `pr-review-orchestrator`.

`pr-review-orchestrator` is the tenth agent and the diff-scoped entry point, dispatched by `send-it`
before the PR body is drafted. It reads the diff versus the derived default branch, classifies the
changed paths into surfaces, fans out in parallel to the touched surfaces' reviewers only, runs its
own integration-check pass for the cross-surface concerns no single specialist can see, then
aggregates and dedupes into one report split into Blocking versus Nits. It dispatches **only** these
nine — a default fanning out to an agent a consumer repo may not have fails the whole review rather
than degrading.

**It is the default reviewer**, so no repo has to opt in: `send-it` dispatches the `review_agent:`
configured in `.claude/sassy-dog/send-it.md` if there is one, and this orchestrator otherwise. A
repo that wants a different reviewer names it; a repo that genuinely wants none says so explicitly,
and that run still reports the verbatim line
`review: SKIPPED — no review_agent resolved (lint/type/test only)`:

```yaml
review_agent: my-own-orchestrator   # override — omit the key to get sassy-dog:pr-review-orchestrator
# review_agent: skip                # explicit opt-out: no review runs, and the run says so
review_surfaces:                    # optional — steer the routing without owning an agent
  "ops/**": sassy-dog:infra-platform-reviewer
```

Between those two sits a third tier. The optional **`review_surfaces:`** map steers which of the
nine a path routes to, for a repo whose layout the built-in heuristics do not match. It only ever
*adds* a route — nothing it can say removes one, so it cannot quietly under-dispatch — its values
are restricted to the nine agents that ship here, and an unresolvable value discards the whole map
and comes back as a Blocking finding rather than a skipped surface.

The two dispatching paths reach the same gate through **`review_site:`** in their own config
(`take-it.md`, `dispatch-ready.md`), which chooses *where* it runs: `agent`, each dispatched
sub-agent reviewing its own diff before it opens a PR, or `coordinator`, the dispatching loop
reviewing each PR after it opens and before it merges. An absent key selects `coordinator`.
`setup-config` seeds it once from repo visibility (public → `agent`, internal/private →
`coordinator`) and writes the resolved value explicitly rather than re-deriving it, so a later
visibility change cannot silently rewrite a repo's review architecture. It chooses only the site —
`review_agent:` still chooses the agent — and a Blocking finding is never merged past. The
unattended paths share one automatic recovery allowance across failed checks, Blocking findings,
missing/faulty reports and parent fan-out recovery; another failure gets the `blocked` label.
The durable `recovery_used` value survives new heads, agents and dispatcher ticks.
Only authenticated workflow-owned records bound to the actual attempt supply that budget.
`send-it` checkpoints issue-less pre-PR recovery under the Git common directory and transfers
the consumed state into the eventual PR; later-tick retries reserve pending state before the
scheduling tick ends.
Exhausted failures before PR creation use an authenticated issue-only terminal handoff.
Both coordinators reconcile it before PR filtering; only confirmed blocking frees capacity,
and an absent PR or spent reservation alone never labels a still-working agent terminal.

**However the gate is sited, the report is *returned*** — it is the reviewing agent's final text,
never a message sent to a session it would first have to address, because an address is the thing a
reviewer cannot reliably resolve. The dispatching side of that rule is carried by all three shipping
paths — `send-it`, `take-it` and `dispatch-ready` — since one living only in `send-it` never runs
for the two that carry most of the PR volume: read the returned report yourself, never block while a
review you dispatched is outstanding, and treat a dispatch that came back with nothing as its own
outcome —

```text
review: NO REPORT — <agent> dispatched, no report returned (lint/type/test only)
```

— never as the SKIPPED line above, which says no agent ran at all. In the two **dispatching** paths
(`take-it`, `dispatch-ready`) a PR whose review reached nobody is additionally **held** rather than
merged, on either `review_site:`. The discriminator is **unattended merging**, not whether a PR
exists yet: those two go on to merge with nobody reading along, so a lost report there becomes an
unreviewed merge. `send-it` hands its run back to the person who started it, who is reading the
output, so it records the outcome and carries on.

**Nested fan-out remains the default.** Only the shipped PR orchestrator supports the
[parent recovery protocol](agents/pr-review-orchestrator.md#parent-recovery-protocol):
an explicit plan-only request or inability to dispatch nested reviewers returns a
`review-fanout-plan` control object, not reviewed coverage or a completed report. Its actual
caller may dispatch only missing/unusable surfaces in one concurrent round, retaining real
successful returns, then request `aggregate-only` with the complete plan and results. The
orchestrator rechecks changeset and context identity, rejects stale reuse, performs its
whole-diff integration pass and returns the usual Markdown report. It never reruns successful
specialists during aggregation. This does not change audit mode, custom reviewers or `review_site:`.

That batch plus aggregation consumes the same single recovery allowance, not one per surface.
A control object alone, failed aggregation or still-missing required surface is **NO REPORT**,
with causes and any partial report retained — never SKIPPED or clean. `take-it` and
`dispatch-ready` hold the PR and use their existing second-failure path once recovery is spent.
`send-it` records the degraded outcome and continues its operator-facing flow; its one automatic
recovery does not limit an explicit operator-directed repair.

**The same rule binds the fan-out one level down.** Each of the nine reviewers returns its findings
envelope as its own final text — `{"findings": []}` included — because a reviewer can no more reliably
address the orchestrator that dispatched it than the orchestrator can address the session that
dispatched *it*, and the fan-out brief carries that rule down as one of its enumerated items rather
than assuming each agent's own file gets read. It does not make the hop reliable and is not meant
to: a reviewer that errors, times out, or comes back unparseable is still scored `!` and named on
every run, never rolled into Clean. **Audit mode scores a lost reviewer too, in its own idiom** — the sibling of that rule rather than a copy of it: `assess-it` keeps a per-domain outcome ledger and prints it in the Phase 4 preview *before* the approval prompt, so a domain whose reviewer never came back is named dark rather than filed as clean. The consequence differs because audit mode **writes**: a diff-scoped hole costs a re-run, while a filed Epic missing a domain becomes the durable record and reads complete. It is surfaced, not a veto — filing still proceeds on approval.

Each dispatch site names a **model tier** rather than letting its agent inherit the session's
model. Implementation workers and the nine reviewers run at `terra` (Sonnet on
Claude Code), and the orchestrator runs at `sol` (Opus). On the coordinator site a worker is told
outright not to review, and reports `review=deferred`. Tiers are harness-neutral words so the
skills port beyond Claude Code. The bindings live in [`docs/MODEL-TIERS.md`](docs/MODEL-TIERS.md),
and `scripts/test-model-tiers.sh` enumerates the sites and holds each one to that table.

## Installation

### Claude Code

```bash
# Add as a marketplace
claude plugin marketplace add Sassy-Dog/skills

# Install the plugin
claude plugin install sassy-dog
```

### Local Development

```bash
claude --plugin-dir ~/Repos/sassy-dog/skills
```

## Updating / Troubleshooting

### One-time re-add after the rename to `sassy-dog` (legacy — pre-2026-08 installs only)

> Skip this unless you installed the plugin before August 2026 under its old name. A fresh
> install from the [Installation](#installation) section above is unaffected.

The plugin was renamed `ai-agent-skills` → `sassy-dog` and the marketplace `sassy-dog-skills` →
`skills` in the same release (issue #71). A machine that added the marketplace under the
old name cannot update across the rename — plugin name, marketplace name, and cache path all moved
at once. Treat it as uninstall-and-reinstall, exactly once per machine:

```bash
claude plugin marketplace remove sassy-dog-skills
claude plugin marketplace add Sassy-Dog/skills
claude plugin install sassy-dog
```

Plugin updates are **manual** — the cache does not follow the repo. Content lands on `main` on every merge, while `.claude-plugin/plugin.json` is stamped only by a dedicated release PR (`scripts/stamp-version.sh` — see `docs/VERSIONING.md`), so "has there been a release?" is the wrong question to ask. Run the update whenever you want `main`'s current skills, and use the content check below to find out whether you are behind:

```bash
claude plugin update sassy-dog@skills --scope user   # or: project, local, managed
```

`--scope` defaults to `user`. If this machine has a *project*-scope install of the plugin, that is the copy your sessions in that project run, and the bare command will not touch it — see step 1 below for how to tell.

**To do all of it for every copy on this machine at once**, run the bundled script from a checkout of this repo — it refreshes the clone, updates the `user` copy and every live `project` copy from inside its own path, prunes registry entries left by torn-down worktrees, and verifies each survivor **by content** rather than version string. Dry run by default:

```bash
bash scripts/update-plugin-everywhere.sh          # report only
bash scripts/update-plugin-everywhere.sh --apply  # update, prune, verify; then restart sessions
```

It also names the one stale state the installer cannot fix: every copy already at the latest *stamped* version while `main` has merged newer content. `claude plugin update` is version-keyed and copies nothing there; the remedy is a release stamp (`docs/VERSIONING.md`), after which the next run installs a fresh version directory.

### The bare plugin name fails

`claude plugin update sassy-dog` returns "not found" — the error doesn't hint at the fix. The marketplace-qualified name is required: `sassy-dog@skills`.

### `claude plugin marketplace update` is not a plugin update

`claude plugin marketplace update` only `git pull`s the marketplace clone. It succeeds even when the *plugin cache* — the code your skills actually run from — is still stale.

**Do not diagnose this by comparing version strings.** The manifest is stamped only by a dedicated release PR, while content lands on every merge, so a cached copy and `main` routinely carry the *same* `version` over different files. Measured 2026-08-28: the marketplace clone, the live cache and `main` all read `2026.8.100`, and 18 skill files differed along with every file in `agents/` — all nine reviewers and the orchestrator ([#296](https://github.com/Sassy-Dog/skills/issues/296)). Matching version strings are not evidence that the cache is current — only comparing content is.

**1. Find which cached copy is live.** The cache keeps every version ever installed (ten directories on the machine measured above) and installs are per scope, so `ls` cannot answer this. Run this from the project *root* (the match is an exact path comparison — a subdirectory returns only the `user` row):

```bash
jq -r --arg p "$PWD" '
  .plugins["sassy-dog@skills"][]
  | select(.scope != "project" or .projectPath == $p)
  | "\(.scope)\t\(.installPath)"
' ~/.claude/plugins/installed_plugins.json
```

A `project` row wins for sessions in that project; the `user` row is the answer when there is no project row. Do not assume a worktree has no project row — most do, written when a session first runs there, which is where `take-it` and `dispatch-ready` do nearly all of this repo's work. Read the filter's output rather than predicting it. **Keep both the `installPath` and the `scope`** — the path is what you compare in step 3, and the scope is what you must pass when you fix it. The two are routinely at *different* versions — `2026.8.100` user against `2026.8.94` project on the machine measured — so picking the wrong one silently checks a copy you are not running. Ignore `gitCommitSha` in that file: it records the commit the *marketplace* was added at, is not refreshed by a plugin update, and was 101 commits behind on the machine measured.

**2. Refresh the marketplace clone**, so that what you compare against is current:

```bash
claude plugin marketplace update skills
```

**3. Compare content** — the clone against that install path, over all three directories that load or execute:

```bash
INSTALL_PATH='<paste the installPath from step 1>'
CLONE="$HOME/.claude/plugins/marketplaces/skills"
for d in skills agents scripts; do
  [ -d "$INSTALL_PATH/$d" ] || { echo "NOT COMPARED: $d — check INSTALL_PATH"; continue; }
  diff -rq "$CLONE/$d" "$INSTALL_PATH/$d" 2>&1
done
```

The quoting and the `[ -d ]` guard are not decoration. The quotes are what make pasting with the placeholder left in merely set a literal string — **unquoted**, `INSTALL_PATH=<...>` is a *redirection* and the block dies with a syntax error, which is the form to avoid; pointed at a path that does not exist, `diff` writes to **stderr** and stdout stays empty — so an unguarded version of this block reports silence, and silence is the answer that means "current". The `2>&1` and the guard exist so that the rule below is true of what you actually see.

`scripts/` belongs in that list because of one file: `align-labels.sh` is the only root-`scripts/` path any skill invokes at runtime through `${CLAUDE_PLUGIN_ROOT}` (every other bundled script lives under `skills/` — almost all under `skills/<skill>/scripts/`, plus the two `skills/setup-hooks/references/templates/*.template.sh` renderer inputs — and is already covered by the first directory). One file is enough — a merge touching only it leaves `skills/` and `agents/` identical while changing what a label-writing run actually executes, which is the #167 failure. Most of root `scripts/` is CI gates that never run at plugin runtime, so drift counts there are not evidence about runtime behaviour and are not offered as any.

**Any output at all means the cache is stale, or the comparison did not run** — either way it is not current, so run the update in step 4. Silence across all three directories means it is current. The shapes say different things, and a reader scanning only for the word "differ" skips the one that matters most:

| Output | Meaning |
| --- | --- |
| `Files … differ` | that file changed upstream |
| `Only in …/marketplaces/…` | your cache is missing that file outright — a whole skill or bundled script may be absent |
| `Only in …/cache/…` | that file was removed upstream |
| no output | that directory is current |

Measured against the `2026.8.94` project copy, `verify-gotcha-claims.sh` — one of the bundled scripts issue #296 cites — was **absent** rather than merely changed, which is why the row exists. (Every count on this page names the copy it came from: the two copies on the measured machine disagree, which is the section's whole point.)

An error naming a path that does not exist is **not** a clean result: the comparison did not run. Fix `INSTALL_PATH` and repeat.

**4. Update the scope you actually found**, because the default is not always yours:

```bash
claude plugin update sassy-dog@skills --scope project   # or: user, local, managed
```

`--scope` defaults to `user`. A reader who correctly identifies a `project` copy in step 1 and then runs the bare command updates the *user* copy, sees no error, and finds step 3 unchanged — the same wrong-copy trap as step 1, on the write side. The update also says "restart required to apply": until you restart, the session keeps running the old skills and agents. Then re-run step 1 and step 3 — an update that crosses a release installs into a *new* version directory, so the `INSTALL_PATH` you just used now points at an abandoned copy that will differ forever.

Step 2 is load-bearing rather than tidiness: an unrefreshed clone is stale in the same way the cache is, and matches it exactly. On the measurement above that identical pair of directories reported **zero** differences before the refresh and **28** after it, with nothing about the repo having changed in between.

This failure mode is silent: no error anywhere — skills just keep old bugs and trigger phrases stop matching.

### Updates freeze at the cached version

Re-run the update from step 4 above, with the `--scope` that matches the copy you are running. There is no marketplace auto-refresh unless you opt in, so a cache goes stale simply because nobody refreshed it.

This repo is **public**, so install and update clone it over anonymous HTTPS — no SSH key, no SSO authorization, no SAML step. If you are reading an older note about `Configure SSO` on <https://github.com/settings/keys>, it applied while the repo was `INTERNAL` and no longer does.

## Repository layout

This repo is a single plugin: skills, agents, and the manifest live at the root.

```
skills/
├── .claude-plugin/plugin.json   # Plugin manifest
├── agents/                      # Subagents (auto-discovered, namespaced sassy-dog:<name>)
│   ├── *-reviewer.md            # Nine domain reviewers — audit mode or diff-scoped mode
│   └── pr-review-orchestrator.md  # Diff-scoped fan-out over those nine
└── skills/
    └── my-skill/
        ├── SKILL.md             # Required — frontmatter + instructions
        ├── references/          # Optional — detailed reference docs
        └── scripts/             # Optional — executable tools
```
