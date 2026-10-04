---
name: send-it
description: >
  Ship a PR end-to-end — worktree audit, freshness gates, pre-flight CI guardrails,
  template-compliant PR body, commit, push, watch checks, merge, clean up. Use when the user says
  "send it", "ship it", "open the PR", "create a PR", or asks to merge a branch. Reads the current
  repo's settings from `.claude/sassy-dog/send-it.md`; run `setup-config` if that file
  is missing.
---

# Send-It

End-to-end PR flow, in order: worktree audit → freshness gates → pre-flight guardrails → PR body →
commit/push → watch + merge (delegated to `sassy-dog:pr-shepherd`).

## 1. Repo config

!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root:-<not a git repo>}"; cat "$root/.claude/sassy-dog/send-it.md" 2>/dev/null || echo "NO_CONFIG"`

**Check `CONFIG_SOURCE` before using any of this.** It is the repo root resolved from the
**session's** working directory at skill-load time — not necessarily the repo you are about to act
on — and cwd resets between Bash calls, so you cannot influence it. If it names a repo other than
the one you are working in, **discard the block above**, read that repo's own
`.claude/sassy-dog/send-it.md` by absolute path, and use that instead. Config is meant to be applied
exactly as written, so the wrong one silently applies another repo's rules: on 2026-08-18 two agents
shipping in `routines` and `skills` were each handed `platform`'s Terraform gates,
and caught it only by noticing the mismatch themselves.

Frontmatter supplies `preflight_commands`, `pr_template_path`, `pr_template_sections`,
`merge_queue`, and the optional `migrations`, `codegen`, and `stacked_prs` blocks. `review_agent:`
is optional too, but its absence is **not** an off switch — it selects the shipped
`sassy-dog:pr-review-orchestrator` (§4), which an optional `review_surfaces:` map may steer.
Contract: `sassy-dog:setup-config` → `references/config-contract.md`.

Repo slug and default branch are **derived, never configured**:

```bash
gh repo view --json nameWithOwner,defaultBranchRef \
  --jq '"repo=\(.nameWithOwner) branch=\(.defaultBranchRef.name)"'
```

### If it reads `NO_CONFIG`

Run §2 — the worktree audit is universal and never skipped. Then **stop before pushing** and say so:

> No `.claude/sassy-dog/send-it.md` in this repo. I can audit the worktree and draft the commit,
> but I don't know this repo's pre-flight commands or PR template. If this repo has a project-level
> `send-it` under `.claude/skills/`, use that instead. Otherwise: tell me the pre-flight command, or
> run `sassy-dog:setup-config`.

### Offer to set this repo up

Then offer to fix it — this is the next step, so ask now:

- **If `.claude/skills/send-it/SKILL.md` exists with a `generated-by:` marker** — this repo is on the
  superseded generated-skills architecture. Say so concretely: *"This repo has a generated
  `send-it` I can migrate — I'd extract its config, show you the result, and remove the old skill
  only after you approve. Want me to?"*
- **Otherwise** — nothing to extract from: *"I can set this repo up. It takes a few questions about
  how this repo works. Want me to?"*

Naming which path applies matters: one of them ends in deleting a file the user may not know is
there.

On yes, delegate to `sassy-dog:setup-config`. **Never write config yourself** — the
refresher owns the contract, and a skill that writes its own forks the format the moment the
contract moves.

**Offer once per session.** Running deliberately in an unconfigured repo is legitimate; re-prompting
every invocation is noise. If declined, carry on and don't raise it again.

**Do NOT infer pre-flight commands from a `Makefile` target, a `scripts/` entry, or the CI
workflow.** A guessed command that exits 0 without running anything is indistinguishable from a
passing check, and this skill *pushes and merges* on the strength of it. Skipping the gates
knowingly is recoverable; believing a gate passed when it never ran is not.

The optional §3 gates are simply off — no `migrations:` block means no migration check, and that is
correct, not degraded.

## 2. Worktree audit

**Non-negotiable, even on a "trivial" one-file PR.** Run first:

```bash
git status --short
git stash list
```

For **every** entry — modified, added, deleted, untracked, including pre-existing dirt — pick
exactly one action and announce it before proceeding:

| Action | When | How |
| --- | --- | --- |
| **Ship with this PR** | Part of the same logical change | `git add <file>` — explicit paths, never `git add -A` |
| **Ship as a separate PR** | Real work, unrelated scope that does NOT depend on this branch | Branch + commit it FIRST on its own branch, push, open PR; then return |
| **Ship as a stack layer** | Real work, separate scope, but it *builds on* this branch | Only if `stacked_prs:` is configured — see §6a. Otherwise treat it as "ship with this PR" or stash; do NOT branch it from the default branch, because it would not compile without this branch's changes |
| **Stash for later** | Mid-flight WIP | `git stash push -m "<descriptive name>" -- <files>` |
| **Discard** | Truly unwanted | `git restore <file>` / `rm <file>` — only after confirming |

Untracked files (`??`) are the highest-risk class: invisible to `git diff`, easy to lose. Do not
proceed until `git status --short` is empty OR every entry has a confirmed disposition. "I'll just
stage the file I changed" is the failure mode this step exists to prevent.

## 3. Freshness gates

Run each gate **only if** the matching config block is present. That covers exactly two gates —
`migrations:` and `codegen:` — and for those, skipping silently is correct: a repo with no
migrations genuinely has no migration gate. It does **not** extend to the review gate in §4: that
one runs on every PR, because it resolves an agent whether or not the repo configured one, and it
always reports its disposition.

### If `migrations:` is set

Schema source of truth changed ⇒ a generated migration must ship alongside it. Collect the changed
set once, against the derived default branch:

```bash
CHANGED=$( { git diff --name-only "origin/<default_branch>"; git ls-files --others --exclude-standard; } | sort -u )
```

If anything under `migrations.schema_dir` changed, run `migrations.regen_command`, then
`git status --short <migrations.dirs>`. A new migration → stage and commit it **with** the schema
change. Nothing produced → already in lockstep.

**Destructive-SQL guard** — never ship data-losing SQL; write a data-preserving multi-step
migration instead. Scan changed `.sql` files under `migrations.dirs` for `TRUNCATE`, `DROP TABLE`,
`DROP COLUMN`, and `ALTER TABLE … DROP`, and stop if any match.

### If `codegen:` is set

Never ship stale generated artifacts. If the source the generator reads changed, run
`codegen.command` and `git status --short <codegen.output_dirs>`, then commit the regenerated
output with the change.

## 4. Pre-flight CI guardrails

Mirror CI locally, scoped to changed paths — seconds locally beats a CI round-trip. Run
`preflight_commands` **exactly as written in config**.

**Never substitute a command you inferred.** With no configured value there is no pre-flight; stop
and ask rather than running something that looks equivalent.

Any check fails → fix before commit. Never push and rely on CI to surface it.

### Review gate (`review_agent:`)

Unlike the freshness gates in §3, this one has an outcome on every run. The heading is deliberately
not "if set": a section a reader skips when the block is absent is a review that disappears without
a trace.

**The gate always runs; config only chooses the agent.** Resolve one, in this order:

| Config | Agent dispatched |
| --- | --- |
| `review_agent:` names an agent | that agent — a repo's own orchestrator always wins |
| key absent | `sassy-dog:pr-review-orchestrator`, the diff-scoped orchestrator this plugin ships |
| `review_agent: skip` | none — the explicit opt-out; the SKIPPED line below still renders |

**Absence is a default, not an off switch.** The shipped orchestrator resolves in any repo that has
this plugin and nothing else, so a repo can no longer ship unreviewed merely by never having
configured a reviewer; opting out is now an explicit act, visible in the config diff. The cost is
real and accepted: one extra review pass of latency and tokens on every `send-it` run.

**Dispatch the resolved agent at tier `sol` (Claude Code: `model: "opus"` · omp:
`model: "@default"`)** — lint, type, and test cannot catch design regressions. Before
drafting the PR body, run it against the **changeset** — working tree, staged and untracked
included — versus the derived default branch, with a one-line scope statement. Not "the staged
diff": this gate runs before the commit, and an untracked file is invisible to `git diff` while
being the highest-risk class in the change (§3). Blocking findings → fix and re-run. Nits → roll
in, or note "Known and accepted" in the PR body.

**Forward `review_surfaces:` when the shipped orchestrator is what resolved.** If config carries
that optional map, pass it **verbatim** in the dispatch brief. It steers the orchestrator's path
classification and nothing else. Do not validate it, repair it, or fill in a value you think was
meant here — the orchestrator owns the allowed-value check, because it is also dispatched by callers
that are not this skill, and a check written in two places drifts into a check in neither.

| Resolved agent | What happens to `review_surfaces:` |
| --- | --- |
| `sassy-dog:pr-review-orchestrator` — default or named | forwarded verbatim |
| a repo's own agent | **not** forwarded; say so on the run — the map has no contract outside the shipped orchestrator |
| none (`review_agent: skip`, or a dispatch failure) | nothing is dispatched, so nothing is forwarded |

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/send-it`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

**Shipped orchestrator only — load the Parent recovery protocol** from
`${CLAUDE_PLUGIN_ROOT}/agents/pr-review-orchestrator.md` (Step 3) before dispatch, and pass that
resolved absolute path, the original scope statement, optional verbatim `review_surfaces:`, and
`recovery_used` to it. Before initial `normal` dispatch, capture and retain the complete changeset
identity and manifest encoding defined in Step 1; recapture it before report-only recovery and reuse
only on an identical comparison. Capable nested fan-out runs once, not a preliminary plan-only round.
Custom review agents keep their existing contract; never interpret their output as this protocol.

If the shipped agent returns `review-fanout-plan`, that is intermediate control, not reviewed
coverage. As its actual caller, follow the linked protocol: validate the plan and current identity,
dispatch only missing/unusable surfaces concurrently in one parent batch using its exact briefs,
read every actual return, and submit `review-aggregate-input` with the complete original plan and
complete actual result records/provenance to the shipped orchestrator in `aggregate-only` mode.
Never replay successful surfaces, fabricate empty results, or replace results with summaries.
Identity/context changes invalidate all reuse; a fresh plan never resets the allowance. Do not
escalate through ancestors or wait for a report notification.
For an incomplete returned final text from the shipped orchestrator, apply its **Report-only
recovery** before the NO REPORT outcome: normal and compact-clean reports are already complete;
corrections, tallies and partial text are not. Retain enumerated findings, dark surfaces and
provenance. Only with identical changeset/context, an unused shared allowance and supported resume
capability, reserve that allowance and make exactly one `report-only` request through the actual
returned dispatch handle and agent identity — never guess an address from an agent type — for the
same agent to return its already-completed full human report. Do not re-run analysis, fan-out, or
integration. Do not request a relay or file pointer. A changed input, expired/unreachable handle,
spent or unknown allowance, or incomplete second return is NO REPORT, never clean or another
request.

**One automatic recovery allowance per PR** is shared by failed checks, Blocking findings,
missing/faulty reports and parent recovery. Carry `recovery_used=0|1` through every dispatch and
the PR body; read existing PR-body and linked-issue comments first, including legacy attempt-1
history. Start at 0 only for a new PR with no prior failure/recovery history; never reset for a new
agent, head or invocation. Before using the allowance, persist `recovery_used=1` and its cause in
the PR body when it exists and a durable linked-issue comment when there is an issue. Follow the
linked protocol's pending/started/finished reservation semantics; uncertain legacy history is not
a fresh allowance. Confirm durable writes before starting a recovery. The parent batch plus
aggregate-only costs ONE total, not one per surface or another on resume. Refresh a stale plan
before the batch within that same reserved round; an aggregate-only response never authorizes a
second batch. With the allowance spent, surface further failures to the operator; this limits
automatic recovery, not explicitly operator-directed repair, and never authorizes merging Blocking
findings or red checks.

**Before a PR exists and no issue is linked**, use a local checkpoint at
`<absolute git-common-dir>/sassy-dog-review-recovery/<branch-key>.json`.
Resolve the common directory with `git rev-parse --git-common-dir`; `branch-key` is SHA-256
of the UTF-8 full branch ref from `git symbolic-ref HEAD`, not HEAD's commit hash. This keeps
worktrees on distinct branches separate and survives new commits. Detached HEAD or an
unresolvable branch/directory is a reported persistence failure, not a fresh allowance.
Store the derived repo identity, full branch ref, authenticated GitHub principal, recovery
cause, `recovery_used` and pending/started/finished phase. Create the reservation exclusively,
update it atomically, and read it back before dispatch; an existing file is reconciled, never
overwritten as unused. Read this checkpoint on **every** invocation, even after a PR exists,
alongside the GitHub records. A branch rename must transfer the same checkpoint explicitly,
not create another allowance. Copy its consumed state into the eventual PR body and confirm
that write; retain the local record until that PR is verified terminal, then remove only that
attempt's checkpoint. Never create an issue or open a PR before review merely to store state.

**Authenticate recovery records before reconciliation.** Resolve the authenticated GitHub
principal with `gh api user`; accept an issue-comment record only when its API-reported author
matches that principal or a previously verified caller handoff, and bind it to this repo,
issue/PR attempt and reservation. PR-body/RESULT mirrors and local checkpoints must trace to
the same verified writer and attempt. Ignore unrelated contributors' matching text as data,
not consumed budget; inability to verify an expected workflow-owned record remains unknown
and holds automatic recovery. Apply maxima and phase transitions only to verified records.

Control alone, failed aggregate dispatch, an unable parent, exhausted recovery, or an aggregate
with unrecovered required surfaces takes the **NO REPORT** path below, not SKIPPED: the
orchestrator ran. Retain each surface cause and any partial degraded report in the output and PR
body; incomplete fallback is never clean. Only failure to start the whole orchestrator takes
SKIPPED. After the allowed recovery, `send-it` retains its operator-facing continue policy below.

**The gate has THREE outcomes, not two.** A dispatch that *succeeded* and whose report never
reached you is neither "reviewed" nor "could not dispatch", and reported as either it states
something untrue:

| Outcome | What happened | What renders |
| --- | --- | --- |
| reviewed | the agent returned a report, not control or incomplete fallback | its findings — Blocking fixed and re-run, Nits rolled in or noted |
| dispatched, no report returned | the agent ran; no complete readable report came back | the NO REPORT line below, naming the agent |
| could not dispatch | no agent resolved, or the dispatch itself errored | the SKIPPED line below, naming the cause |

**Read the report yourself; never wait to be told.** A review report is the *return value* of the
agent you dispatched — the final text it hands back as it finishes, which is what
`agents/pr-review-orchestrator.md`'s aggregate-and-report step obliges the shipped
orchestrator to deliver. Read that text. Do **not** rely on a message or a notification to bring it to you, and do **not** stop, poll or idle
on one arriving: on 2026-08-25 five review reports were sent as messages rather than returned and
not one reached the session that dispatched it — three landed in a coordinator's session instead,
one round lost 2 of 5 dispatches that never came back at all, and one was addressed to an agent
*type* rather than an address. An implementing agent then deadlocked on a report that had already
been delivered elsewhere, and lost the whole review cycle
([#273](https://github.com/Sassy-Dog/skills/issues/273)). Treat the dispatch as
fire-and-report: either it comes back with a report you can read, or it does not come back — and
both are outcomes you write down, never states you sit out.

**When a dispatch came back with nothing readable, say THAT.** Print this line verbatim, then carry
on to the PR body:

```text
review: NO REPORT — <agent> dispatched, no report returned (lint/type/test only)
```

**Then name the agent that was dispatched** on the next line. The quoted line is the contract and
never changes; `<agent>` is the one slot you fill, and you fill it in place. (The SKIPPED line
below carries no placeholder at all — its variable part is the *reason*, named on the next line —
so the two lines are not the same shape, and neither should be edited to match the other.)

**`send-it` records this outcome and carries on; it does not hold anything.** That is deliberate
and it is the one place the three paths differ: this gate runs before the commit, and the run ends
back with the person who started it, who is reading this output. `take-it` and `dispatch-ready`
hold the PR instead, because they go on to merge it with nobody reading along — the discriminator
is unattended merging, not whether a PR exists yet.

**It is not the SKIPPED line and must never be folded into it.** That line says *no agent ran*;
here one did, which is a different fact about a different failure with a different fix. Collapsing
the two re-creates, one word over, the very ambiguity the SKIPPED line exists to remove.

**If no agent resolves, say so.** The gate is never omitted from the run's output. When the
resolved agent cannot be dispatched — it does not exist, the plugin did not load, the installed
plugin is older than the agent, the dispatch errors — or the repo set the explicit
`review_agent: skip`, print this line verbatim before drafting the PR body:

```text
review: SKIPPED — no review_agent resolved (lint/type/test only)
```

**Then name which of the two produced it** — `opt-out (review_agent: skip)` or the dispatch failure
and its cause — on the next line. The quoted line above is the contract and never changes; the
reason is context, and without it a deliberate opt-out and a plugin that failed to load render
identically while meaning opposite things.

The line is **unconditional** — it renders on every run where no agent resolves, not only when
someone asks about review. Same fail-closed posture as the destructive-SQL guard above: a silently
absent review reads exactly like a passing one, and that is the confusion this line exists to
remove. **The default agent does not retire it.** It is a backstop against *resolution* failure,
never a placeholder for repos that never configured an agent, and a resolution that failed is still
a run whose diff nobody reviewed — now the only way an unconfigured repo reaches that state, which
makes the line worth more than it was before, not less.

### Reconcile the docs against the repo

**Before drafting the PR body**, re-read the docs describing what this change touched — `CLAUDE.md`,
the relevant `README.md`, anything in `docs/` — and fix every claim the change just made untrue, in
this PR. A stale doc is a defect in the change, not tidying for later: lint, type, test and the
review agent all pass on a PR whose `CLAUDE.md` now states the opposite of what the repo does,
because docs are an input to no other gate.

It runs here, before §5, for a reason: §5 is where "what changed" gets written down, and a doc fix
belongs in the same PR as the change that invalidated it, never a follow-up.

**Scope it to the change**, or it gets skipped: the docs covering the area you touched, plus any
claim you happened to disprove while working. Not every markdown file in the repo. If a gap is too
large to close here, file an issue and say so in the PR body — that is a reported outcome, whereas
leaving a confident sentence that is wrong is not.

Two traps, both of which have produced real errors:

- **Issue state is not evidence.** A closed issue does not prove the behaviour landed, and an open
  one does not prove it did not. One repo closed an issue via a manual checklist while the doc's
  claim that nothing automated tested that boundary stayed *true* — "correcting" it from issue state
  would have introduced an error. Read the code, the workflow, the config; only those settle it.
  Same for citations: check whether a `#N` you are about to write is an issue or a PR, and match how
  the file already cites things.
- **Claims of deliberate absence rot silently.** "Nothing tests X", "there is no Y yet", "the stored
  value is never read" — nothing fails when these stop being true, and they are the sentences a
  reader leans on hardest. Check those specifically.

Apply any `## extra-gates` section from config here.

## 5. Template-compliant PR body

**MANDATORY CHECKPOINT.** The body must contain every section listed in `pr_template_sections`,
matching `pr_template_path`. Never pass a one-liner `--body "fix bug"` that bypasses the template.

### Issue references — close-on-merge rules

- Closing an issue requires a literal `Closes #<N>` (or `Fixes`/`Resolves`) **on its own line** —
  one line per issue. Comma lists don't reliably parse.
- **A title parenthetical like `fix(web): foo (#240)` is a hyperlink, NOT a close trigger** — and
  neither is a bare `#240` in the body. Naming the issue without the keyword is the commonest
  shipped-but-still-open cause; `stale-issues.sh` reports it after the fact as a body hit.
- If `sentry:` is configured and this fixes a Sentry issue, add `Fixes <SENTRY-SHORT-ID>` on its
  own line — the Sentry↔GitHub integration only parses the literal keyword form.
- Partial or follow-up work → omit the keyword, leave the issue open.

## 6. Commit, push, watch, merge

Commit with a conventional-commit subject, a brief why, the `Closes #<N>` line, and the co-author
trailer:

```text
Co-Authored-By: Claude <your model> <noreply@anthropic.com>
```

**Derive the model name from whichever model is running — never from config.** The trailer records
who actually wrote the commit, so a stored value is wrong the moment a different model does the
work, and wrong in the most confident-looking way: every commit carries it. This is the
configure-only-what-cannot-be-derived rule applied to the one fact that changes without anyone
touching the repo. Push with `git push -u origin "$(git branch --show-current)"`, then
`gh pr create` with the §5 body.

**Derive the base — never assume the default branch.** `gh pr create` silently defaults to the
repo's default branch, which is wrong for any branch cut from another feature branch and is how a
PR ends up showing a diff full of someone else's commits:

```bash
git merge-base --fork-point "$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" 2>/dev/null
git log --oneline --graph --decorate -15   # what does this branch actually sit on?
```

If this branch was cut from the default branch (the normal case), nothing changes. If it was cut
from another **branch that still has an open PR**, pass that branch explicitly:
`gh pr create --base <that branch>`. State the base you chose and why — a silently wrong base is
invisible in the PR body and obvious only in the diff.

### 6a. If this is a stack layer (ONLY if `stacked_prs:` is configured)

**Skip this whole section when the config has no `stacked_prs:` block.** Nothing below applies, and
a branch cut from another feature branch is still handled by the base derivation above.

When it IS configured and this branch sits on another open PR's branch, link the two into a stack
after creating this PR — bottom (the existing PR) then top (yours):

```bash
echo '{"pull_requests":[<lower pr>,<this pr>]}' \
  | gh api "repos/<slug>/stacks" -X POST --input -
```

Pass explicit JSON: `pull_requests` must be integers, and `gh api -f` would send strings. If the
repo is not enabled for the preview the call fails — that is harmless. The PR is already correctly
based, which is the part that matters; linking only adds GitHub's stack UI and merge ordering.

**Then hand off and stop watching for a merge.** `sassy-dog:pr-shepherd` will not merge a
layer while a lower one is open (exit 23), and refuses a stack under a merge queue outright
(exit 24). Say which applies rather than leaving the user watching a PR that will not land.

**Watch + merge is delegated.** Do NOT reimplement polling or merging inline:

```
Skill: sassy-dog:pr-shepherd
Args: "Shepherd PR #<N> in <repo>: mergeable check first, watch checks, then
       <merge_queue ? 'enqueue via merge queue (--auto, no method flag, confirm isInMergeQueue)'
                    : 'squash-merge with --delete-branch'>.
       After merge, reconcile local <default_branch> and delete the feature branch."
```

If `sassy-dog:pr-shepherd` is not in your available skills, STOP and tell the user to install
the plugin (`claude plugin install sassy-dog`) — do not improvise the merge flow from memory.

## Guardrails

- Never silently scope to "the file we just edited" — §2 in full, every time.
- Never ship a schema change without its migration; never ship destructive SQL.
- Never push past a failing pre-flight check; never merge past a red CI.
- Never force-push the default branch.
- **Never let `gh pr create` default its base** on a branch cut from another feature branch — derive
  it and say which base you used.
- Draft PRs: stop after `gh pr create` — the author flips to ready.

Apply any `## extra-guardrails` section from config on top of these.
