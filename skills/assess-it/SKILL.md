---
name: assess-it
description: >
  This skill should be used when the user asks to "assess this repo", "assess it", "audit the codebase",
  "run a project assessment", "do a full repository health check", "review the whole repo and
  file issues", "what tech debt do we have", "find risks across the codebase", or wants a
  comprehensive, evidence-based engineering audit (architecture, security, testing, CI/CD,
  infra, DX, dependencies, observability) turned into a tracked GitHub Issue backlog. Also
  triggers for periodic re-assessment, e.g. "a new frontier model dropped, re-assess the repo".
---

# Assess-It

Turn a whole repository into a deduped, evidence-backed, PR-sized GitHub Issue backlog under one tracking **Epic** — by fanning out specialized review agents, adversarially verifying their findings, and filing only what survives.

**Repo-agnostic.** Works on any GitHub repo. Operates on **one repo per run** (the current working dir unless a target is given). A periodic routine loops multiple repos — that lives outside this skill.

**Default = preview, not file.** Filing issues is outward-facing and hard to undo. Always present the proposed Epic + child issues for approval and file only after the user confirms. Never create issues silently.

## Core Principle

A finding only earns an issue if it has **concrete `file:line` evidence**, survives an **adversarial second look**, and is **not already tracked** by an existing issue. Everything else is noise — drop it. One issue = one coherent PR's worth of work.

## Workflow

Follow the five phases. Full dispatch details, the finding schema, and exact `gh` commands live in the reference files — read them when you reach that phase.

### Phase 0 — Scope & detect (you, the main agent)

1. Resolve the target repo (cwd or the path/arg given). Confirm a GitHub remote:
   `gh repo view --json nameWithOwner,defaultBranchRef`.
2. Detect stack(s) by globbing manifests: `package.json`, `*.csproj`, `Cargo.toml`, `pubspec.yaml`, `*.tf`/`*.bicep`, `Dockerfile`, `.github/workflows/`, Nx/Bun/tRPC config. This decides which review agents to dispatch.
3. **Build the dedupe index** (used in Phase 2 and Phase 4):
   `gh issue list --state open --limit 500 --json number,title,labels,body`
   (also pull recently-closed for context). Keep it in memory for the whole run.

### Phase 1 — Fan out (parallel review agents)

Dispatch the relevant `sassy-dog:*-reviewer` agents **in a single message with multiple Agent tool calls** so they run concurrently, each at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`) — the tier the nine reviewers run at in both review modes. Skip domains with no signal (no IaC → skip `infra-platform-reviewer`). Give each agent the repo path, the detected stack, and its scope. Each returns only the JSON object `{"findings": [...]}` as final text, with findings in the shared schema and mandatory `file:line` evidence. Accept `returned` only for a usable envelope per `orchestration.md`; `{"findings": []}` is completed-empty, while missing or malformed results are `no report`, never clean. Unwrap usable `findings` for Phase 2 verification.

**Record an outcome for every domain as the fan-out returns** — `returned`, `no report`, or `could not dispatch` — plus `not dispatched`, with its reason, for a domain the Phase-0 stack detection skipped. That ledger is Phase 4's input **and the Epic body's** (#294): a domain whose outcome is not `returned` is **dark**, and a dark domain is never scored as clean and never reported as "no findings". In the executive summary its rubric dimension scores `n/a — not measured (dark)`, never a number — the table and this rule otherwise leave no compliant answer, and an agent facing that invents a score, which is worse than a missing one because it is quantitative. A reviewer that came back with nothing looks exactly like one that found nothing, and writing down which happened is the only thing that separates them. Carry the ledger through Phases 2 and 3 unchanged — nothing there adds a domain or clears one.

See **`orchestration.md`** for the agent→domain map, the four outcomes and what each one means, and the finding schema.

### Phase 2 — Adversarial review (you)

For every finding: open the cited `file:line` and confirm the evidence is real and the problem genuine (not mere preference/convention); sanity-check severity, likelihood, and blast radius. Dedupe findings against each other **and against the Phase-0 GitHub index**. For high-impact findings, optionally dispatch perspective-diverse skeptic subagents prompted to *refute* — keep only survivors. Be skeptical by default; a false issue costs more than a missed one.

### Phase 3 — Group into PR-sized work items

Cluster surviving findings so each cluster is one coherent PR (e.g. "harden GitHub Actions workflows" may bundle 3 findings). Each cluster becomes one child issue.

### Phase 4 — Preview, then file

1. **Print the full preview**: the Epic (exec summary + scores) and every child issue (title, body, labels, and its dedupe decision).
2. **Print the Phase-1 ledger in that preview, before you ask for approval.** Every domain, with its outcome, rendered so a reader sees the coverage without opening anything:

   ```text
   Domain coverage — 9 dispatched, 7 returned, 2 dark (+0 not dispatched)
     returned:           architecture, code-quality, testing, dx-docs, observability-ops, cicd-release, dependency-supply-chain
     no report:          infra-platform — came back with prose, not a findings envelope
     could not dispatch: security — Agent call errored (agent not resolved)
     not dispatched:     (none)

   2 domains are DARK. This audit does not cover them, and nothing above is
   evidence that they are clean. `dispatched` counts the fan-out only, so a
   `not dispatched` domain is never one of it and is carried in its own tally.
   ```

   Print this block on **every** run, the all-clear included. A coverage line that shows up only when something went wrong teaches the reader that its absence means nothing, which is the habit that made a dark domain invisible in the first place (issue [#284](https://github.com/Sassy-Dog/skills/issues/284)).
3. Now ask the user to approve, edit, or cancel. **File nothing yet.** A dark domain is surfaced, not a veto: it does not stop the run and does not block filing, and on approval everything that did come back is filed as normal.
4. On approval, **align the target repo's labels first** — the engineering-dimension + severity taxonomy is owned by one script in this plugin, and this skill invokes it rather than carrying a copy (issue #167). The path below is resolved when this skill loads; pass it on as `ALIGN=<that path>` to anything that needs it, because `references/*.md` are read raw and never get the substitution:

   **Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/assess-it`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo "$REPO" --dry-run   # preview drift, writes nothing
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo "$REPO"             # create missing + correct drifted
   ```

5. Then follow **`references/github-issue-ops.md`**: re-check dedupe per issue right before creation (comment on a match instead of duplicating), create child issues, create the Epic **with the coverage block in its body**, then attach each child as a **native sub-issue** (`gh api`), with a task-list fallback.

### Phase 5 — Report

Print the Epic URL, the child issue list, the executive summary, and the same coverage block Phase 4 previewed. **The Epic body now carries that coverage block too** ([#294](https://github.com/Sassy-Dog/skills/issues/294)) — see `references/github-issue-ops.md` §4 — so the durable artefact records what was and was not audited, and a later reader of a backlog missing a whole domain is told so instead of finding a set that reads complete. This reprint is for the operator who just approved the filing; the Epic's copy is for everyone after them, and the two are not interchangeable: session output reaches one person once.

## Reference Files

- **`assessment-rubric.md`** — the 15 assessment areas, scoring (1–10 health/security/DX/maintainability), severity & likelihood definitions, and the executive-summary format. Review agents consult their section; you use it for the Epic summary.
- **`orchestration.md`** — agent→domain map, per-agent scope, the four dispatch outcomes and the dark-domain rule, the finding output schema, and the adversarial-review / dedupe / grouping logic.
- **`references/github-issue-ops.md`** — label *routing* (which dimension label a finding gets; the taxonomy itself is owned by `scripts/align-labels.sh`, never copied), child-issue & Epic body templates, and exact `gh`/`gh api` commands for dedupe, issue creation, and native sub-issue linking.

## Red Flags — STOP

- About to file an issue with no `file:line` evidence → drop it or downgrade to the Epic's "watch list".
- About to create issues without showing the preview first → STOP, preview and get approval.
- A finding that's "best practice" with no concrete harm in *this* repo → that's cargo-cult; drop it.
- Skipped the dedupe index fetch → you will create duplicates. Fetch it in Phase 0.
- About to call a domain clean, or write "no findings" for it, when its reviewer did not come back → STOP. That is the one claim this audit cannot make. Report it dark, with its outcome, and file the rest.
- About to show the preview with a domain missing from the coverage block → STOP, add it with its outcome, then show the preview and carry on. A domain absent from the ledger is one the reader cannot tell apart from a clean one, and this preview is the last moment before the backlog becomes the record. This is a missing line to add, never a reason to abandon the run.
- About to type a `gh label create` with a colour in it → STOP. Run `align-labels.sh` (Phase 4). A hardcoded hex here is a second copy of the taxonomy, and the last one silently painted stale colours into every repo this skill audited.
