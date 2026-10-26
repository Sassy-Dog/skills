# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, omp and others) working in this repository. `CLAUDE.md` holds only an `@AGENTS.md` import, per the org agent-guidance spec: edit this file, never `CLAUDE.md`. This file and any nested `AGENTS.md` are held to the org's 32 KiB guidance budget (`test-doc-reconciliation.sh` §9); put depth in `docs/`, not here.

## What this repo is

A **Claude Code plugin marketplace** containing a single plugin (`sassy-dog`) that bundles reusable skills and review agents for Claude Code, Gemini CLI, and other AI coding tools. Repo visibility is **`PUBLIC`** — a deliberate exception to the org's `INTERNAL` default, taken on 2026-08-12 because the claude.ai account-level plugin marketplace **cannot sync a non-public repo** (a non-public source fails with `Marketplace sync failed` regardless of org app install or SSO state; see [#175](https://github.com/Sassy-Dog/skills/issues/175)). Two consequences follow and must not be undone by a later "align with the org default" sweep: org secrets with `private` visibility do not reach this repo (that is *desirable* here — see [#178](https://github.com/Sassy-Dog/skills/issues/178)), and CI runs on GitHub-hosted runners rather than the self-hosted fleet, because `on: pull_request` fires for fork PRs. Licensed Apache-2.0.

There is **no build step** — the entire repo is Markdown (skills/agents) plus the Bash scripts bundled inside skills' `scripts/` directories. CI (`.github/workflows/ci.yml`, required on `main`) runs `bash scripts/preflight.sh` — the single source of truth for every gate: shellcheck, `scripts/check-frontmatter.sh` (loader requirements on every tracked skill/agent file, plus the Agent Skills spec constraints on `SKILL.md` alone), the positional-token and legacy-name guards, manifest JSON validation, the CalVer version-of-record guard, markdownlint (`.markdownlint-cli2.jsonc`), and the 55 `scripts/test-*.sh` gates. The test gates run **in parallel** inside preflight ([#567](https://github.com/Sassy-Dog/skills/issues/567)): `scripts/lib-parallel-gates.sh` starts them up front, `PREFLIGHT_JOBS` slots at a time (default the CPU count; `PREFLIGHT_JOBS=1` is the old fully serial run; the slot count is not a hard cap on processes, because `test-deps-cadence-policy.sh` forks up to 8 shards of its own outside it), captures each one's output and prints it whole at its numbered gate, and the closing summary names every failed gate. The CI shape is unchanged: one `ci` job, one `Preflight gates` step, and the push-on-`main` run stays (`default_branch_ci` reads it). **Run `bash scripts/preflight.sh` locally before every PR** (`--fix` auto-fixes markdownlint findings, before any gate starts).

**Each gate's rationale lives in its own script header. Read it there; never restate it here.** Those headers are load-bearing prose rather than commentary — nearly every one records a decision that *reads* like drift, an inconsistency, or dead weight and is deliberate, together with the mutation proving the gate is not vacuously green. Before editing a gate, or the `SKILL.md` prose a gate pins, read that header first, and never delete a rule merely because it looks inconsistent with a governing principle stated elsewhere: that specific edit is what most of these gates exist to stop. This paragraph replaced a 118 KB transcription of those headers which had already drifted — it documented 24 of the 27 gates that existed when it was removed — and which was the same third-copy shape this repo refuses for its label taxonomy (`test-label-taxonomy.sh`), turned on its own documentation. Nothing enforces that here, which is exactly why it grew.

Which header to read, keyed by what you are touching:

| Touching | Gate |
|---|---|
| any pipeline into `grep -q` under `pipefail` (corpus: `scripts/*.sh`, `skills/*/scripts/*.sh`) | `test-pipefail-grep.sh` |
| Sentry plate rules, the `sentry:` key, the four-key `none` asymmetry | `test-sentry-verification.sh`, `test-sentry-counts.sh` |
| `sentry-triage` §5's breadcrumb evidence pull and its redaction, `groom-backlog`'s `sentry-source` re-validation, the catalog executor's three-tool limit | `test-sentry-breadcrumbs.sh` |
| the review gate, `review_agent:` / `review_site:` / `review_surfaces:`, `assess-it`'s audit mode, the nine reviewer agents | `test-review-gate-decisions.sh`, `test-review-orchestrator-allowlist.sh`, `test-audit-lost-reviewer.sh` |
| `dispatch-ready` terminal states, claim lifecycle, PR polling, platform-degradation probe | `test-drain-terminal-states.sh` (§7's terminal-state canon), `test-isolation-contract.sh` (isolation and serial-fallback prose), `test-checkout-guard.sh` (the guard executed), `test-claim-lifecycle.sh`, `test-poll-queue-eject.sh`, `test-platform-health-probe.sh` |
| `setup-deps`, `dependabot.yml` rendering, the workflow templates | `test-dependabot-render.sh` (the renderer and validator), `test-template-actionlint.sh`, `test-visibility-preconditions.sh`, `test-ownership-matchers.sh`, `test-auto-merge-policy.sh` (the auto-merge template), `test-template-action-pins.sh` (action pins against `.github/workflows/template-action-pins.yml`), `test-lockfile-sync-policy.sh` (the bun and pod lockfile-sync templates, validators executed), `test-deps-cadence-policy.sh` (the monthly refresh and the opt-in codegen workflow), `test-deps-cadence-render.sh` (`render-cadence.sh`), `test-npm-lane-conversion.sh` (`convert-npm-lanes.sh`) |
| `setup-config`'s contract — config keys, marker recognition, the frontmatter/prose split, what the capability probe may read | `test-gotcha-claims.sh`, `test-doc-reconciliation.sh`, `test-review-gate-decisions.sh`, `test-sentry-verification.sh`, `test-detect-capabilities.sh` |
| `setup-hooks`, stack detection, `generated-by:` ownership, the stray-artifact guard | `test-detect-hook-stack.sh`, `test-ownership-matchers.sh`, `test-artifact-guard.sh` |
| the public-repo tracking choice — `skills/setup-config/scripts/tracking-state.sh`, the end-state table in `setup-config`'s "Tracking choice in the plan", `setup-hooks`' calls to it, `setup-repo`'s passed target | `test-tracking-state.sh`, `test-review-gate-decisions.sh` (no live visibility read in the section) |
| the label taxonomy or `align-labels.sh` | `test-label-taxonomy.sh`, `test-label-migrate.sh` |
| `github-issues` scripts — stale detection, `gotcha_summary`, grooming drift, and how a SKILL.md or reference doc may invoke `board-snapshot.sh` | `test-stale-issues.sh`, `test-gotcha-claims.sh`, `test-verify-issue-refs.sh`, `test-board-snapshot-calls.sh` |
| `queue-snapshot.sh` — its emitted key set, the `touches:`/`Depends on #N`/`stack:` body parse, and the execution-site read (why a label rather than a body contract, and why several `site:` labels are a conflict rather than "any site") | `test-queue-snapshot-site.sh` |
| the execution-site CONSUMERS — `dispatch-ready` §4's Site filter, `take-it`'s refusal before the claim, `queue-snapshot.sh --sites-of` (the one resolver both reach for labels the buckets never saw), and the one folded spelling of `not sites or execution_site.lower() in sites` every subject is held to | `test-site-filter.sh` |
| `execution_site`'s human surface — `groom-backlog` rubric #9, the plate's backlog lines, `setup-config`'s interview question, and where the `uname -s` proposal table may live | `test-execution-site-surface.sh` |
| `file-or-link-issue.sh` — the two idempotency stages, the delimited-footer match, the refusal to file on an unverified scan | `test-file-or-link-issue.sh` |
| `repo-health` security pulls (code scanning and secret scanning states) | `test-scanning-states.sh` |
| `repo-health`'s tech-debt scan — `EXCLUDE_PATHSPECS` / the config `exclude_pathspecs` spelling, the built-in lockfile excludes (why they are bare rather than `**/`-prefixed), and why `SCAN_PATHS` is out of scope | `test-tech-debt-excludes.sh` |
| `whats-on-fire`'s ranking and reporting — a security-labelled issue is never collapsed into a bare count | `test-security-listing.sh` |
| `pull-repo-signals.sh`'s `default_branch_ci` — the recovery re-query's shape, and what a surviving null may mean | `test-repo-signals-recovery.sh` |
| `pr-shepherd`'s `teardown.sh` arguments, `--sweep`'s live-worker guards, and its refusal to mutate under a held checkout guard (`merge-shepherd.sh`'s post-merge teardown makes the same `check`) | `test-teardown-args.sh` |
| `merge-shepherd.sh`'s reviewed-head binding (`--expected-head`, exit 25) | `test-poll-queue-eject.sh` (part 7) |
| `scripts/update-plugin-everywhere.sh` — the per-machine plugin updater, its prune and backup | `test-update-plugin-everywhere.sh` |
| `scripts/preflight.sh`'s parallel runner (`scripts/lib-parallel-gates.sh`), `PREFLIGHT_JOBS`, or adding any `scripts/test-*.sh` (wired exactly once, through `pg_gate`) | `test-preflight-wiring.sh`, `test-doc-reconciliation.sh` §6 (the stated gate count) |
| doc reconciliation, `CLAUDE.md` staying the exact two-line `@AGENTS.md` import (section 8), versioning/CalVer, the stale-cache diagnostic | `test-doc-reconciliation.sh`, `test-versioning.sh`, `test-stale-cache-diagnostic.sh` |
| the release-lag checker, normalized runtime inventory, first-parent release baseline or pending-age clocks | `test-release-lag.sh` |
| `${CLAUDE_PLUGIN_ROOT}` or `$PLUGIN_ROOT` in any `skills/*/references/*.md` command, or the root-resolution paragraph in any `skills/*/SKILL.md` | `test-plugin-root-in-references.sh`, `test-plugin-root-paragraph.sh` |
| the "Unrun config line" paragraph under the `!` config line and the "what the line printed is unconfirmed until read at the root" paragraph (the four conservative-mode carriers, the four `NO_CONFIG` stoppers, the line's form; [#574](https://github.com/Sassy-Dog/skills/issues/574), [#576](https://github.com/Sassy-Dog/skills/issues/576)) | `test-config-fallback-paragraph.sh` |
| a unit of agent-run text that runs `git` and also carries a shell expansion ([#574](https://github.com/Sassy-Dog/skills/issues/574), [#576](https://github.com/Sassy-Dog/skills/issues/576), [#578](https://github.com/Sassy-Dog/skills/issues/578)) | `scripts/preflight.sh` (guards 3 and 3b), `scripts/check-git-expansion.sh` |
| model tiers — `docs/MODEL-TIERS.md`, any dispatch site's inline `tier` binding, a `model:` on an agent | `test-model-tiers.sh` |
| `take-it` / `dispatch-ready` isolation and serial execution, or `skills/take-it/references/isolation-confirmation.md` | `test-isolation-contract.sh`, `test-drain-terminal-states.sh` (§7 holds), `test-model-tiers.sh` (dispatch tiers); model-driven evidence and limits in `docs/HARNESS-PORTABILITY.md` |
| `skills/pr-shepherd/scripts/checkout-guard.sh` — checkout ownership, the foreground runner, `abandon`, and the read-only `check` that `teardown.sh` and `merge-shepherd.sh` call; `repo-cleanup` reads `status` instead | `test-checkout-guard.sh` (real processes, scratch Git and bare remotes via `scripts/fixtures/checkout-guard.py`; reads no prose, so it cannot replace the two prose gates above) |
| the `testflight` skill's App Store Connect JWT signer (`asc-jwt.sh`) — openssl only, and why there is no PyJWT path | `test-testflight-jwt.sh` |

Two of those gates read **this file** as one of their count sites and re-derive its spelled numbers in CI ([#276](https://github.com/Sassy-Dog/skills/issues/276), [#278](https://github.com/Sassy-Dog/skills/issues/278)), so a count that goes stale here fails the build. Be exact about what that does and does not buy: the gates verify the three spelled numbers and each description's own closing terminator, **not** the prose around them, which stays green when reworded and even when a decision is inverted. Green is therefore not a review of these two sentences — re-read them by hand whenever the gate they describe changes. The sentry-verification tests (`scripts/test-sentry-verification.sh` — `setup-config` may only write a `sentry:` block for a project verified **by culprit** against the repo being configured, since a Sentry project and a repo can share a name and belong to different codebases; a failed verification records `sentry: none`, the config contract's first documented exception to presence-is-the-toggle. The `none` form spans four keys and is deliberately **asymmetric**: `sentry: none` keeps its blind-spot row, while `testflight: none`, `posthog: none` and `mobile: none` take one `(n/a)` token on the clean line and no row at all — absent error monitoring is a gap somebody could close, an absent mobile app is a product fact. Source-level, with must-not-exist checks run against a flattened copy; eight tracked files, no `gh`, no network) sit beside the sentry-counts tests and the security-listing tests in that family, and alongside the review-gate decision tests (`scripts/test-review-gate-decisions.sh` — the seven decisions settled about the review gate, every one of which reads like drift to a later "align with the governing principle" sweep: 1. the gate is unconditional, because an absent `review_agent:` resolves the shipped orchestrator, and the verbatim `review: SKIPPED` line survives that default as the backstop for *resolution* failure; 2. `review_agent:` is deliberately not presence-is-the-toggle; 3. the opt-out is `review_agent: skip` and never `none`; 4. `review_site:` is configured rather than derived, so taking a repo private cannot silently downgrade its review architecture; 5. a Blocking finding blocks the merge with exactly one automatic recovery shared with failed checks, missing/faulty reports and parent fallback, durably carried rather than reset by a new agent/head/tick; 6. a review report is **returned** as the reviewing agent's final text rather than sent to an address it cannot resolve, with `review: NO REPORT` as its own third outcome, including incomplete parent fallback. The shipped orchestrator's recovery checks bind actual caller sites, complete identity/provenance, missing-only dispatch and aggregate-only boundaries; and 7. the nine reviewers deliver to the orchestrator the same way, the delivery rule riding as one member of a fan-out brief whose list stays closed. Source-level and flattened; twenty-one tracked files, no `gh`, no network).

Five rules have **no gate of their own**, so nothing fails when they are undone:

- **shellcheck runs twice, and the second pass is not redundant.** The tree-wide run is `-S warning`; SC2006 is `style`, so that run cannot see it, and a second pass exists for SC2006 alone. Do not fold them together — an unescaped backtick inside a double-quoted string is command substitution, and this gap shipped the same defect twice (three test labels in `test-sentry-verification.sh` were silently executing `which`, `that` and `where`). A bespoke grep was tried and rejected: 3 true positives against 7 false, because a backtick inside a single-quoted string is a different question that only a shell parser answers.
- **actionlint is CI's own step, not preflight's, and that split is forced.** In CI, two separate steps run a pinned native binary (never the dockerized action): the bare tree-wide run, and the rendered-template gate. `ci.yml` puts that binary on `$GITHUB_PATH`, which reaches only *later* steps, while preflight runs before the install — so preflight skips both in CI and runs them locally when `actionlint` is on `PATH`, falling back to the pinned `rhysd/actionlint` image when it is not. That local docker fallback is the only linting a contributor without the binary gets; do not delete it as redundant with CI.
- **actionlint lints the workflow templates' embedded `run:` blocks, but ONLY because shellcheck is already on `PATH` when it runs.** actionlint's shellcheck integration is what covers that shell, and nothing anywhere asserts the ordering: `ci.yml`'s `Install shellcheck (pinned + sha256-verified)` step puts it on `$GITHUB_PATH`, and `actionlint (setup-deps workflow templates)` is a later step that inherits it. Reorder those two and the highest-consequence YAML in the tree silently stops being shell-linted while CI stays green.
- **Every `scripts/test-*.sh` must be safe to run beside every other one** ([#567](https://github.com/Sassy-Dog/skills/issues/567)), because preflight runs them concurrently. That means its own `mktemp -d` scratch space, no fixed path (`/tmp/x`, `$HOME`, anywhere in the checkout), no write inside the checkout, no port and no named container, and no mutation of the real repo's git state (`git status` and friends take `index.lock`). The audit was done once, by hand, when the runner landed; `test-preflight-wiring.sh` pins the wiring and the runner, not the safety of a suite that arrives later. A suite that genuinely cannot comply goes through `pg_gate_serial` and records why in `preflight.sh`'s header.
- **Green is necessary, not sufficient.** "Correctness" still means accurate trigger phrases and skill instructions that actually work when invoked. Verify by installing the plugin locally (below) and exercising the skill.

## Layout (flat — everything at root)

This repo *is* the plugin; there is no nesting under a plugin subdirectory.

```
.claude-plugin/
  plugin.json        # plugin manifest — version is the version-of-record, stamped by scripts/stamp-version.sh (never hand-edit)
  marketplace.json   # marketplace entry pointing at the GitHub repo
agents/
  *-reviewer.md      # subagents, auto-discovered, namespaced sassy-dog:<name>
  pr-review-orchestrator.md  # diff-scoped fan-out over the nine reviewers
skills/
  <skill>/
    SKILL.md         # required: frontmatter (name + description) + instructions
    references/      # optional: deep reference docs (progressive disclosure)
    scripts/         # optional: executable tools the skill calls
```

## How the pieces fit together

- **Generator + capability skills.** The six workflow skills (`survey-work`, `groom-backlog`, `take-it`, `dispatch-ready`, `send-it`, `tidy-repo`) are generic, with exactly one implementation each; per-repo behaviour lives in that repo's `.claude/sassy-dog/<skill>.md`. Fix shared mechanics in the capability skill, never in a workflow skill. `setup-repo` runs its generators strictly in sequence, never as parallel sub-agents.
- **Orchestrator + reviewer agents.** Nine `*-reviewer` agents serve two orchestrators (`assess-it` in audit mode, `pr-review-orchestrator` diff-scoped) and return one finding schema in both modes. A review report is returned as the reviewer's final text, never sent to a session.

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before changing any workflow, capability or generator skill, the review gate, or a reviewer agent.

## Conventions that matter

- **`whats-on-fire`'s rules carry parity markers, and the CI gate for them is in the OTHER repo.**
The skill has two intentional homes: this plugin copy (`SKILL.md` + `references/`) and the
flattened, self-contained copy in `Sassy-Dog/routines` that the `daily-fire-watch` cloud
routine reads by path, which exists because plugin skills cannot load in a routine session
([#175](https://github.com/Sassy-Dog/skills/issues/175)). Nothing used to check that the
two agreed, and on 2026-08-20 that produced a false P0 in the scheduled run — **a fix applied to
this copy would not have changed the routine's behaviour at all** ([#221](https://github.com/Sassy-Dog/skills/issues/221)).
Every load-bearing rule now carries a `<!-- rule: <id> -->` marker beside it in *both* homes, and
`routines`' `scripts/check-skill-parity.sh` fails when the marker sets differ. **Adding a
rule here means adding the marker here, the marker there, and a line in that repo's
`parity/whats-on-fire-rules.tsv`.** Two things not to redesign: the check compares marker
*identity* and never prose, because the two homes word the same rule differently and wrap it
differently — a wording-based check reports the routine as missing rules it plainly carries; and it
cannot move into this repo, because this repo is PUBLIC and that one is INTERNAL, so its CI can
clone this one anonymously while this one's CI cannot authenticate to it at all (the
`private`-visibility trap of [#178](https://github.com/Sassy-Dog/skills/issues/178)). A
change spanning both repos lands **here first**, or that repo's CI clones a `main` without the new
marker and fails.
The stale-verdict section ([#375](https://github.com/Sassy-Dog/skills/issues/375)) renders
the existing `ci-verdict-age-bound` rule, whose marker was added in
[#379](https://github.com/Sassy-Dog/skills/pull/379); it does not introduce another rule
identity. Its marker counterpart was reconciled in
[routines#60](https://github.com/Sassy-Dog/routines/issues/60); that marker-only
change does not establish parity of the rendering instructions.
- **Every dispatch site names a tier, bound inline where the agent is dispatched.** Tiers are harness-neutral words (`astra`/`sol`/`terra`/`luna`), because the skills must port beyond Claude Code and no single `model:` value is valid in two harnesses. The binding table is [`docs/MODEL-TIERS.md`](docs/MODEL-TIERS.md), and agent files carry **no** `model:` frontmatter. Implementation workers and the nine reviewers run at `terra`; the orchestrator runs at `sol`. A dispatch site that names no tier silently inherits the session model, which is how implementation and review both ended up on the most expensive tier. `test-model-tiers.sh` counts each site's binding and checks it against the table. Its `required` table is the enumerated site list, so a new dispatch site joins that table in the same PR.
- **Skill `description` is a trigger spec, not a summary.** It is dense with quoted user phrases ("set a GitHub secret", "check TestFlight feedback") because matching those phrases is what activates the skill. When adding/editing a skill, write the description as the list of utterances that should trigger it.
- **Progressive disclosure.** SKILL.md stays thin and actionable; depth goes in `references/*.md` that the skill says to read "when you reach that phase." Don't inline reference-doc detail into SKILL.md.
- **`${CLAUDE_PLUGIN_ROOT}` expands only in `SKILL.md`, at load time.** It is NOT substituted in `references/*.md` and is not a shell variable, so a reference doc or a bundled script that writes the token raw emits it literally and the path silently fails to resolve. A reference doc must take the already-resolved absolute path from the `SKILL.md` that invoked it. The thirteen reference-doc commands that wrote the token raw were repointed in [#329](https://github.com/Sassy-Dog/skills/issues/329): each doc now opens with a **path-resolution preamble** setting `PLUGIN_ROOT`, and its commands quote `"$PLUGIN_ROOT/..."`. `test-plugin-root-in-references.sh` keeps it that way — it bans the token in COMMAND usage (keyed on fenced code blocks) while deliberately sparing the prose in `skills/assess-it/references/github-issue-ops.md` that documents the trap, and it fails a doc that uses `$PLUGIN_ROOT` without defining it, since an unset variable resolves against `/` exactly like the token did. **The one place a SKILL.md must NOT spell the token** is the root-resolution paragraph ([#454](https://github.com/Sassy-Dog/skills/issues/454)): every `SKILL.md` that carries the token also carries one paragraph before the first fenced command that uses it, for harnesses (omp) that neither substitute nor export it, and Claude Code substitutes the token anywhere in a `SKILL.md`, so a paragraph that spelled it would be rewritten into a path inside its own sentence. It says "the plugin-root placeholder" instead. `test-plugin-root-paragraph.sh` pins the text, the placement and the token-freedom; the text is the wording that passed on omp, so change it only with a re-run.
- **A count stated in prose is safe only when its members are enumerated beside it, or when a gate re-derives it.** A bare number with neither support rots silently — nothing fails when it stops being true, which is the whole reason #268/#276/#278 exist. Several gate headers defer to this rule by name rather than restating it (`test-drain-terminal-states.sh`, `test-audit-lost-reviewer.sh`), so it must keep a home here.
- **Reviewer agents carry a "Sassy Dog calibration" section** applied only when the relevant stack is present (e.g. Doppler is the secrets source of truth, all-secrets/zero-`vars.*`, managed identity + Key Vault `kv-sassydog`, pin Actions to SHAs). New org-wide policies belong in the matching reviewer's calibration block.
- **No bare `$1`–`$9`/`$@`/`$*` in SKILL.md bodies or dev-workflow templates.** Skill bodies are arg-substitution surfaces: when a skill is invoked with args (as every thin generated skill invokes its capability skill), positional tokens in the rendered body get replaced with args tokens, corrupting embedded commands. CI greps for them (`skills/*/SKILL.md`, `.claude/skills/*/SKILL.md`, `setup-config/references/templates/*`). The guard now asserts that template pathspec is non-empty first — an empty pathspec used to make it pass while covering nothing. Use `cut -f1`/`%(format)` idioms instead, or move the snippet to a `references/` doc or bundled script — neither is substituted.
- **Outward-facing actions require preview-then-confirm.** `assess-it` never files GitHub Issues silently — it prints the full Epic + child-issue preview and files only on approval. Preserve this guard in any change.
- **Irreversible actions are gated structurally, not by ordering.** `scripts/align-labels.sh --migrate` folds a repo's one-off labels onto the canonical set, and deleting a label strips it from every issue carrying it unrecoverably. "Relabel first, delete second" is therefore control flow, not a comment: `gh label delete` has exactly ONE call site, inside `migrate_delete_gate()`, whose own body re-queries GitHub immediately above it and returns without deleting on every path that is not "zero issues still carry the old label" — **including "the re-query itself failed", because unknown is not verified**. The relabel loop's counters are not a parameter of that function; the migration's own success message is never the evidence. Pinned by `test-label-migrate.sh`, which asserts the single-call-site invariant against the source and mutation-proves the gate. Any new destructive capability goes behind the same shape: one call site, its own fresh verification in the same body.
- **A taxonomy consumer runs the owner or reads its `taxonomy` emitter — it never transcribes the table.** Two tables exist: `scripts/align-labels.sh` (10 engineering dimensions + 4 severities) and `skills/github-issues/scripts/issue-claim.sh` (the 4 dev-workflow state labels). Each exposes `taxonomy` (`name|color|description`; no gh, jq, repo or network), and each reads the other through it — that is how `--collisions` scores both sets without a copy. `assess-it` was the counter-example: a third transcription in a reference doc, frozen at pre-#158 colours, so recolouring `tech-debt` created a collision *inside a file that change never saw* and shipped into every repo it audited ([#167](https://github.com/Sassy-Dog/skills/issues/167)). It now invokes `align-labels.sh --repo <target>`; `test-label-taxonomy.sh` fails on any taxonomy colour found outside its home.
- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`). Recent history uses PRs to `main`.

## Local development

```bash
# Run Claude Code with this plugin loaded from the working tree
claude --plugin-dir ~/Repos/sassy-dog/skills

# Install from the published marketplace
claude plugin marketplace add Sassy-Dog/skills
claude plugin install sassy-dog
```

After editing a skill or agent, reload via `--plugin-dir` and invoke the skill to confirm frontmatter parses and triggers fire.

## Releasing

The plugin version is **monthly-rolling CalVer** (`YYYY.M.<commits-this-month>`, e.g. `2026.7.16`) per the org Versioning spec; the committed `version` in `.claude-plugin/plugin.json` is the version-of-record. **Never hand-edit it** — stamp it:

```bash
bash scripts/stamp-version.sh   # resolves CalVer and writes .claude-plugin/plugin.json
```

Commit the stamped manifest in the release PR. Build number: N/A for this repo; tags optional. Full instance doc — including the **one-way ratchet** (no `0.x`/`1.x` may ever follow CalVer): [`docs/VERSIONING.md`](docs/VERSIONING.md). Keep `README.md`'s plugin/skill table, the agent list and the `### Harness support` matrix in sync when skills or reviewer agents are added or removed.
