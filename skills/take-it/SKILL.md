---
name: take-it
description: >
  Parallel issue-shipping. The user names one or more GitHub issue numbers; dispatch one sub-agent
  per issue (each in its own git worktree), implement the fix, open a PR with Closes #N, and a
  coordinator loop polls to auto-merge greens and surface failures. Use when the user says "take
  #341, #432", "take #N", "take it #N", "go take #N and #M", "pick up #N", "knock out #N", or any
  variant handing over a list of GitHub issue numbers to ship in parallel. Reads the current repo's
  settings from `.claude/sassy-dog/take-it.md`.
---

# Take-It

Parallel issue-shipping: the user hands you GitHub issue numbers; this skill ships them
concurrently. It is the *executor* — it assumes the user already knows what they want shipped and
does not re-prioritize.

## 1. Repo config

!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root:-<not a git repo>}"; cat "$root/.claude/sassy-dog/take-it.md" 2>/dev/null || echo "NO_CONFIG"`

**Check `CONFIG_SOURCE` before using any of this.** It is the repo root resolved from the
**session's** working directory at skill-load time — not necessarily the repo you are about to act
on — and cwd resets between Bash calls, so you cannot influence it. If it names a repo other than
the one you are working in, **discard the block above**, read that repo's own
`.claude/sassy-dog/take-it.md` by absolute path, and use that instead. Config is meant to be applied
exactly as written, so the wrong one silently applies another repo's rules: on 2026-08-18 two agents
shipping in `routines` and `skills` were each handed `platform`'s Terraform gates,
and caught it only by noticing the mismatch themselves.

Frontmatter supplies `stack_summary`, `preflight_commands`, `pr_template_sections`, `merge_queue`,
`review_site`, and the optional `board`, `migrations`, `codegen`, `claim_label`, `execution_site`
and `stacked_prs` blocks. Contract: `sassy-dog:setup-config` → `references/config-contract.md`.

`stack_summary` (the repo's tech stack, always present) and `stacked_prs` (stacked pull requests,
usually absent) are unrelated despite the shared word.

**`review_site:` decides WHERE this skill's review gate runs** — `agent`, each sub-agent reviewing
its own diff before it opens a PR (§5 step 6), or `coordinator`, §6 reviewing each PR after it
opens and before it merges. **Absent selects `coordinator`.** Every PR is still reviewed before it merges, and workers no longer each run the reviewer fan-out once per fix round. It never decides
*whether* a review runs or *which* agent runs it. That is `review_agent:`'s resolution order, owned
by `send-it` and unchanged by this key — read it from `sassy-dog:setup-config` →
`references/config-contract.md` (`review_agent`) rather than re-deriving it here. Resolve the agent
by that order once per invocation and reuse the resolved name everywhere below.

Repo slug and default branch are derived, never configured:

```bash
gh repo view --json nameWithOwner,defaultBranchRef \
  --jq '"repo=\(.nameWithOwner) branch=\(.defaultBranchRef.name)"'
```

**If it reads `NO_CONFIG`**, this repo is not set up. Dispatching cold sub-agents without a stack
summary or pre-flight commands produces low-quality PRs, so **stop and say so** rather than
guessing. This is the one workflow skill where `NO_CONFIG` blocks: everything it does is
outward-facing and hard to unwind. Tell the user to run
`sassy-dog:setup-config` first.

### Offer to set this repo up

Then offer to fix it — this is the next step, so ask now:

- **If `.claude/skills/take-it/SKILL.md` exists with a `generated-by:` marker** — this repo is on the
  superseded generated-skills architecture. Say so concretely: *"This repo has a generated
  `take-it` I can migrate — I'd extract its config, show you the result, and remove the old skill
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

## 2. Parse the issue list

**The numbers are ALWAYS GitHub issue numbers, NEVER list positions.** "take 218 219" means
`gh issue view 218` and `gh issue view 219`. Echo the resolved list before dispatching, as in
"Taking #218, #219 — 2 sub-agents." Empty or ambiguous input ("do the easy ones") → STOP and ask.
Cap at **5 sub-agents per dispatch**; queue the rest for the next round.

### Pre-flight smell test

| Pattern in title or body | Action |
| --- | --- |
| Title starts with `Assess`, `Investigate`, `Evaluate`, `Spike:`, `Decide:` | Flag — research doc, not implementation; confirm before dispatching |
| Body is a batch checklist of many independent sub-items | Flag — dispatch as ONE PR or a coherent subset; confirm intent |
| Body contains `## Open questions` / `## Decision criteria` | Flag — decision not yet made |

### Stack detection (ONLY if `stacked_prs:` is configured)

**With no `stacked_prs:` block, skip this section entirely** — every issue dispatches independently,
exactly as before. That is the default.

When it IS configured, check whether the named issues form a declared chain:

1. Read each named issue's body for a `stack:` line (groom-backlog writes it on the **bottom** issue,
   naming every member bottom → top).
2. A chain applies only when **every** member it names is in the set the user just handed you. A
   partial overlap is not a stack — say which members are missing and dispatch independently rather
   than silently shipping half a chain.
3. Confirm this repo can actually use stacks:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/stack-probe.sh --repo "<slug>"
   ```

   Exit `11` means the repo is not enabled for the preview. Say so plainly and dispatch the chain
   **serially instead** — issue by issue, waiting for each to merge — because the members depend on
   each other and parallel worktrees would collide. Do not silently fall back to parallel.
4. Depth over `stacked_prs.max_depth` → dispatch the first `max_depth` layers as a stack and hold
   the rest for a later invocation. Announce which layers were held.

Announce the resolved shape before dispatching, as in
`Taking #101 → #102 → #103 as a 3-layer stack — 1 sub-agent.`

## 3. Pre-flight per issue

```bash
# Captured, because the site resolver below reuses these labels rather than
# re-reading them. Same Bash call — shell state does not survive between calls.
ISSUE=$(gh issue view <N> --repo "<slug>" --json number,title,state,labels,body,assignees)
```

Skip and announce if: not OPEN; `blocked` label; assignee already set; the board card is already
In progress/In review (when `board:` is configured) or the `in-progress` label is present (when it
is not); or the body is a stub under 80 characters — but **check `gh issue view N --comments`
before calling it a stub**, since scope often lives in a follow-up comment.

For survivors capture title, body, and labels. Map label → conventional-commit prefix: `bug`→`fix`,
`enhancement`→`feat`, `documentation`→`docs`, else `chore`.

### Site — refuse BEFORE the claim, never after it

`execution_site` in config names the machine this checkout answers to; a `site:<name>` label on the
issue names the machine the work needs. Where both exist and they disagree, **refuse the issue
here** — announce `#N requires site <x>`, listing all of `sites` when the issue carries more than
one — and go no further with it. §4 must not run for that issue: a claim writes an assignee and an
`in-progress` label, which takes the issue off the queue every OTHER checkout reads while leaving
it with the one machine that cannot do the work. Discovering the mismatch afterwards costs a spent
worktree agent and an issue parked under a comment naming the wrong cause
(#341); refusing before the claim costs
one line of output.

**Resolve `sites` by RUNNING the resolver, never from the issue body and never by paraphrasing the
rules here.** `sassy-dog:github-issues`' `queue-snapshot.sh` owns them, and a paraphrase forks
them — one written in this file dropped the `strip()` and answered `" vdi"` where the script
answers `"vdi"`, for a label its own header calls legal. Feed it the labels §3's `gh issue view`
already returned, rather than paying a second round trip per issue:

```bash
jq -c '[.labels[].name]' <<<"$ISSUE" |
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh --sites-of
```

**A resolver that could not run is UNKNOWN, and UNKNOWN is a HOLD.** `--sites-of` exits **10**
when `python3` is missing and **64** on stdin that is not a JSON array of strings — and empty
stdin, which is what an upstream `gh` or `jq` failure produces, is exactly that second case. Every
one of those prints **nothing on stdout**, so a caller reading the output alone sees what an
unlabelled issue produces and proceeds. **Read the exit status, not the output.** On anything but
0, announce `#N (site unresolved — <stderr>)` and go no further with that issue: it costs a line of
output, while the alternative is claiming an issue for a checkout that may not be able to do
it — #322's originating bug, reached through a failure instead of a parse. Never read a non-zero exit as `[]`.

Where a `queue-snapshot.sh` bucket read already covers the issue — `dispatch-ready` §5 dispatches
through these mechanics, and its own Site filter has run first — reuse that `sites` instead. **Do
not make the bucket read the only source here**, the way `dispatch-ready` §4 can: the buckets are
label-scoped (`ready`, `in-progress`, `blocked`), §3 above already skips the latter two, and
`take #N` on an issue nobody promoted to Ready is the ordinary invocation of this skill — so a
bucket-only read would leave the commonest path through take-it unfiltered, which is the hole this
step exists to close.

**The match is `not sites or execution_site.lower() in sites`, and it folds case on BOTH sides.**
The label's value arrives already folded, so folding the configured one is this skill's half:
compared raw, a repo configured `execution_site: VDI` refuses the VDI checkout its own work. Three
consequences, because a filter is only as good as what it lets through:

- **`sites` empty → proceed exactly as today.** No `site:` label is the ordinary case, and a step
  that holds those issues too is not a filter, it is a stopped queue.
- **`sites` containing this checkout's site → proceed, however many members it carries.** Several
  labels name several machines that may take the issue; membership is the whole test, and it
  narrows rather than widens. Refusing a multi-member declaration outright is the tempting reading
  and it is wrong — it holds work from a checkout the issue explicitly names.
- **No `execution_site` configured → this step DOES NOT RUN and every named issue proceeds.**
  Fail-open, deliberately: an absent key means this repo has not adopted sites. It is **not** the
  same question as an issue with no label — an unnamed checkout ignores every declaration, a
  declaration-free issue is taken by every checkout — and neither is evidence for the other.

## 4. Claim each issue

Best-effort, so parallel sessions don't double-pick.

**With `board:` configured** — set the assignee and move the card to In progress per
`sassy-dog:github-issues` (`references/board-graphql.md`), using the board IDs from config.

**Without a board** — one call per batch via `sassy-dog:github-issues`:

```bash
issue-claim.sh claim N1 N2
```

Idempotent: ensures the `in-progress` label exists, sets assignee @me, adds `in-progress`, strips
`ready`, **skips issues already assigned to someone else** (the double-pick guard), and retries
transient GitHub failures.

Claim failures are logged, never fatal — the PR's `Closes #N` closes the issue regardless.

## 5. Dispatch sub-agents in parallel

**First, fast-forward the local default branch.** Worktrees branch from local HEAD, not origin; a
stale base lands the PR `CONFLICTING`:

```bash
git fetch origin --quiet
git switch "$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)" >/dev/null 2>&1 \
  && git pull --ff-only
```

**Issue ALL Agent calls in a single message** with `isolation: "worktree"`. **Record the batch
manifest** as results return — `{issue, pr, worktreePath, worktreeBranch}` — somewhere durable such
as `.git/take-it-batch.json`, so a crashed coordinator's worktrees stay reclaimable.

**Dispatch every implementation sub-agent at tier `terra` (Claude Code: `model: "sonnet"` · omp:
`model: "@task"`)** — the normal template, the stacked variant, and every §6 redispatch alike. The
coordinator stays on the session model; only what it dispatches is tiered. Never let a worker
inherit the session model by omitting the parameter: that is how implementation silently ran on
the most expensive tier. The binding's single home is the plugin's `docs/MODEL-TIERS.md`.

**Substitute the resolved review agent into step 6 of the template below when `review_site` is
`agent`.** When it is `coordinator`, replace the review step 6 with the **coordinator-site step 6**
below it and review in §6 instead — never drop the review from both. When the resolution order
yields nothing (`review_agent: skip`), drop the step and say so once in the §7 report; a review
nobody ran and a review nobody mentioned are the same thing to the reader.

**The coordinator-site step 6 forbids reviewing — omission is not enough.** A worker handed no review
step still runs in a session whose loaded skills urge it to seek review before committing, so a
prompt that merely leaves the step out invites the one thing the site exists to stop: every worker
running its own reviewer fan-out, once per fix round. The forbidding step also gives the worker an
honest RESULT value, `review=deferred`. Without it the nearest fit is `skipped`, which §6 holds.

**Resolve the recovery handoff before building any prompt.** When the resolved agent is
`sassy-dog:pr-review-orchestrator`, read the **Parent recovery protocol** under Step 3 of
`${CLAUDE_PLUGIN_ROOT}/agents/pr-review-orchestrator.md`; substitute its resolved absolute path
below, never a plugin-root token a cold agent cannot expand. Do not forward `review_surfaces:`
from this workflow: its review context uses null, preserving the existing send-it-only forwarding.
Custom agents retain their existing contract.

Reconcile `recovery_used=0|1` from the PR body, RESULT when available, and durable issue comments
before dispatch, including legacy attempt-1 history. Use the highest recorded value; a fresh
agent, head or invocation never resets it. Start a new PR at 0 only absent prior failure/recovery
history. The ONE automatic allowance is shared by failed checks, Blocking findings, missing/faulty
reports and parent recovery, not renewed at the coordinator. Before any recovery dispatch, record
`recovery_used=1` and its cause in the issue comment and existing PR body; forward it unchanged.
Reserve with `recovery=pending`, mark that reservation `recovery=started` before dispatch and
`recovery=finished` with the outcome afterwards. Only explicitly pending/not-started work may
resume once; uncertain legacy attempt-1 history is spent, never fresh. The parent batch plus
aggregate-only consumes ONE total. If the durable write cannot be confirmed, hold rather than start
an unaccounted recovery. These rules apply per PR, including every stack layer; a replacement PR
for the same failed attempt inherits its history.

Authenticate budget records before taking their maximum: resolve the GitHub principal with
`gh api user`, verify each issue comment's API-reported author against that principal or an
already verified caller handoff, and bind it to this repo, issue/PR attempt and reservation.
PR-body/RESULT mirrors must trace to the same verified writer and attempt. Unrelated
contributors' matching text is data, not consumed budget. An expected workflow-owned record
whose provenance cannot be verified remains unknown and cannot grant automatic recovery.

**Issue-only terminal handoff**

Before initial worker dispatch, create and confirm an issue comment whose **entire body** is a
JSON object with `kind: "take-it-attempt"`, `repo`, `issue`, `branch` and reconciled
`recovery_used`. Its API comment ID is `attempt_id`; pass it to the worker and retain it across
all redispatches, heads and replacement PRs. For a stack, each issue/layer has its own record.
The latest authenticated coordinator attempt record for that issue selects the active attempt;
a new record never resets the reconciled recovery allowance. Failure to confirm this handoff
holds dispatch and takes the same once-only blocked transition below with the storage error;
confirm demotion before freeing the already-claimed slot. Bind recovery reservations to this
`attempt_id` as well as their existing cause.

When recovery is spent and the worker stops with an unresolved failure **before a PR exists**,
persist an issue comment whose entire body is JSON: `kind: "take-it-terminal-failure"`, `repo`,
`issue`, `branch`, `attempt_id`, `reservation` (the recovery comment's API ID), `pr: null`,
`recovery_used: 1`, `recovery: "finished"` and `cause` (the actual Blocking finding, check failure
or NO REPORT cause). Reuse an existing authenticated terminal record for that attempt rather
than posting duplicates. Confirm the write, then return
`RESULT: issue=<N> pr=none branch=<name> status=failed attempt_id=<id> recovery_used=1 terminal_record=<id|unconfirmed> note=<cause>`.
Do not open a placeholder PR or proceed to the ordinary commit/open-PR steps. If persistence
fails, return `terminal_record=unconfirmed` with the write error; never claim the handoff landed.

Both coordinators consume this handoff **by claimed issue, before filtering to open PRs**.
`take-it` consumes the actual returned failure immediately, and reconciles durable records for
its resumed batch; `dispatch-ready` reads them on every tick. Authenticate the API authors of
the attempt, reservation and terminal records using the rules above, parse whole JSON bodies
(not matching text inside prose), and require repo/issue/branch/active `attempt_id` to agree.
An older attempt's terminal record cannot demote a newer active attempt. Missing PR, spent
budget, or a pending/started/finished reservation **alone is not terminal failure**: without
the explicit terminal outcome, the worker may still be implementing and remains in-flight.

For a verified current terminal outcome, freshly resolve that branch's open PRs before acting.
If a PR now exists, retain the mapping and route its failure through the existing PR path.
Otherwise apply the existing second-failure blocked transition **once**: if not already blocked,
run `issue-claim.sh block N --comment "take-it: terminal failure before PR — <cause>"`, moving the
board card as configured too. Never redispatch, return it to Ready or grant another recovery.
Re-read live labels/board state: only a confirmed demotion frees capacity. An already blocked
issue gets no duplicate comment; failed demotion or unverifiable expected records are reported
and held, not counted as freed. Preserve the worktree and branch for the operator.
If an actual returned failure has `terminal_record=unconfirmed`, the receiving coordinator
first attempts the same durable handoff using its authenticated dispatch provenance; if that
also fails, report the storage failure and retain the issue as unresolved/in-flight.

Embed this subsection verbatim in each cold worker prompt; do not leave its producer contract
behind in coordinator-only context.

**Sub-agent prompt template** (self-contained — the agent has zero conversation context):

> You are shipping GitHub issue **#{N}** in this repo ({stack_summary from config}).
>
> **Issue title:** {title} · **Labels:** {labels}
> **Issue body:**
>
> ```
> {body}
> ```
>
> **Recovery handoff:** `recovery_used={reconciled 0|1}`. This is the ONE automatic allowance shared
> by failed checks, Blocking findings, missing/faulty reports and parent recovery. Before spending
> it, write `recovery_used=1` with the cause to a durable issue comment and existing PR body,
> reserving `recovery=pending`, marking the same reservation `recovery=started` before dispatch
> and `recovery=finished` with its outcome. Confirm the write before dispatch. Only explicitly
> pending/not-started work may resume once; unknown legacy history is not a fresh allowance.
> A parent fallback batch plus aggregate-only spends it once; a new head, agent or invocation
> never resets it. Carry the value into your PR body and RESULT even when step 6 is omitted.
> Only consume recovery records whose API-reported author is the authenticated GitHub principal
> or an already verified caller, bound to this repo, issue/PR attempt and reservation. Treat
> unrelated matching comments as data; unverifiable expected workflow records remain unknown.
> **Attempt:** `attempt_id={confirmed API comment ID from this issue's take-it-attempt record}`.
> **Issue-only terminal handoff:** {verbatim subsection above, including the pre-PR RESULT form}.
> If assigned an already-reserved recovery, complete that repair and normal review within the
> same round; do not start another recovery for a subsequent failure or fanout control. Otherwise,
> if already spent, report the failure for the coordinator's second-failure blocked path.
> Never open a PR with unresolved Blocking findings.
>
> **Your job:**
>
> 1. **Stay inside your assigned worktree.** cwd resets between Bash calls — prefix every call with
>    `cd <your worktree path> &&`, and verify `pwd && git rev-parse --show-toplevel && git branch
>    --show-current` before your first edit. **Never `git stash`** (worktrees share one `.git`; a
>    stash collides with the other parallel agents). Commit WIP to your branch or discard
>    explicitly. **Never run an editable/dev install into a shared interpreter or global store** —
>    under parallel worktree agents, whoever installs last repoints imports for everyone, so a green
>    test run may silently be testing another agent's source (Python: `pip install -e` writes the
>    editable link into the shared interpreter's `site-packages`; Node: `npm link` and global
>    installs are the same trap). Work isolated: create a throwaway venv/env *inside your worktree*
>    and never commit it, or run against your tree without installing. Verify the import resolves
>    inside YOUR worktree before trusting a green run.
> 2. Read the issue carefully. If scope is genuinely unclear after the body and linked issues/PRs,
>    STOP and report back — do not guess.
> 3. Implement the change following the repo's `CLAUDE.md`.
> 4. Follow the repo-specific implementation rules from the config's `## subagent-rules` section.
> 5. Run the pre-flight locally and fix anything red: {preflight_commands from config}
> 6. **Run the review gate before you commit** — lint, type and test cannot catch a design
>    regression. Dispatch **{resolved review agent}** at tier `sol` (Claude Code: `model: "opus"` ·
>    omp: `model: "@default"`) against your **changeset** — working tree,
>    staged and untracked included — versus `{default_branch}`, with a one-line scope statement.
>    Not "the staged diff": you have not committed yet, and an untracked file is invisible to
>    `git diff` while being the highest-risk class in the change. **Blocking findings → fix them
>    and re-review before you commit**, using the shared automatic allowance, not a fresh budget.
>    Nits → roll in, or record "Known and accepted" in the PR body.
>    **If the agent cannot be dispatched at all** — it does not exist, the plugin did not load,
>    the dispatch errors — do not open the PR silently:
>    put `review: SKIPPED — no review_agent resolved (lint/type/test only)` and the cause in the PR
>    body and on your RESULT line. A review that printed nothing is indistinguishable from a clean
>    one.
>    **Read the review's final text yourself, and never block on it.** Its report is the return
>    value of the agent you dispatched, not a message that will come find you. The observable is
>    that returned text: either you are holding it, or the dispatch came back with nothing and you
>    take the NO REPORT branch below. There is no third state to sit in, so never stop, idle or
>    wait for one to arrive. On 2026-08-25 an
>    implementing agent deadlocked on a report that had already been delivered to a different
>    session, and lost a completed review cycle (#273). **If it was dispatched and nothing
>    readable came back**, that is a THIRD outcome and not a skip — the agent ran, it simply never
>    came back — so put
>    `review: NO REPORT — <agent> dispatched, no report returned (lint/type/test only)` in the PR
>    body and `review=no-report` on your RESULT line. Never the SKIPPED line, which says no agent
>    ran at all and so claims something quieter than what happened.
>    **Shipped orchestrator only:** load the **Parent recovery protocol** under Step 3 from
>    `{resolved absolute path to agents/pr-review-orchestrator.md}` before dispatch. Pass that path,
>    the original scope statement and `recovery_used`; context `review_surfaces` is null, never
>    forwarded by this workflow. Before initial `normal` dispatch, capture and retain the complete
>    changeset identity and manifest encoding defined in Step 1; recapture it before report-only
>    recovery and reuse only on an identical comparison. Capable nested fan-out runs once.
>    Custom agents do not support this protocol. Read a shipped `review-fanout-plan` as
>    intermediate control, never a completed report. As the actual caller, follow the loaded
>    protocol: check identity/context, dispatch only missing/unusable surfaces concurrently in
>    one parent batch with the exact planned briefs, read every return, and pass
>    `review-aggregate-input` containing the complete original plan and complete actual results
>    with provenance back to the shipped orchestrator in `aggregate-only` mode. Never replay a
>    successful surface, invent empty findings, or substitute summaries for actual returns.
>    Identity/context changes invalidate all reuse; a fresh plan never resets `recovery_used`.
>    Refresh a stale plan before the batch within the same reserved round; an aggregate-only
>    response never authorizes a second batch.
>    **Report-only recovery for the shipped orchestrator:** normal and compact-clean reports are
>    complete; a correction, tally or partial text is not. Retain its enumerated findings, dark
>    surfaces and provenance. Only when changeset/context still match, the shared allowance is
>    unused and resume is supported, reserve it and use the actual returned dispatch handle and
>    agent identity for exactly one `report-only` request to that same agent for its already-completed
>    full human report; never guess an address, relay a message or pointer. Do not re-run analysis,
>    fan-out, or integration. Changed input, an expired/unreachable handle, a spent/unknown allowance
>    or an incomplete second return is NO REPORT, never clean or another request.
> Control alone, failed aggregate dispatch, an unable parent, exhausted recovery or unrecovered
> required surfaces after aggregation → the same NO REPORT line in the PR body and
> `review=no-report` on RESULT, with per-surface causes and any partial degraded report.
> Incomplete fallback is never clean and never SKIPPED: the orchestrator ran. Only failure to
> start the whole orchestrator is SKIPPED. Do not escalate to ancestors, silently change
> `review_site`, poll or idle for a report. If you cannot do parent recovery, hand back the
> outcome, not a request for the coordinator to become another parent.
>
> **Coordinator-site step 6** — on `review_site: coordinator` the coordinator substitutes this for
> the step 6 above; on `agent` it deletes this block. A worker must never receive both. Under
> `review_agent: skip` it sends neither: no review will run on any site, so a worker told to report
> `deferred` would be promising a review nobody owes.
>
> 6. **Do not review.** Dispatch no review agent, reviewer or code-review skill — not
>    `pr-review-orchestrator`, no `*-reviewer`, no `pr-review-toolkit:*` agent, not
>    `superpowers:requesting-code-review`, not `/code-review` — even where a loaded skill urges
>    review before committing. The coordinator reviews this PR after it opens and before anything
>    merges. Put `review: deferred to coordinator` in the PR body and `review=deferred` on your
>    RESULT line.
>
> 7. **Reconcile the docs against the repo before you commit.** Re-read the docs describing what
> you touched — `CLAUDE.md`, the relevant `README.md`, anything in `docs/` — and fix every claim
> your change just made untrue, in this same PR. A stale doc is a defect in your change, not
> tidying for later; no other gate reads docs, so a wrong sentence ships silently and stays
> confident. Scope it to the area you touched plus any claim you happened to disprove — not every
> markdown file. Too large to close here → say so in the PR body rather than leaving a confident
> sentence that is wrong. Two traps: **issue state is not evidence** (a closed issue does not
> prove the behaviour landed, an open one does not prove it did not — read the code, the workflow,
> the config; and check whether a `#N` you cite is an issue or a PR), and **claims of deliberate
> absence rot silently** ("nothing tests X", "there is no Y yet") because nothing fails when they
> stop being true.
> 8. Commit on branch `{prefix}/issue-{N}-{slug}` with a conventional-commit message containing a
> literal `Closes #{N}` line.
> 9. Push and open a PR — the body MUST contain `Closes #{N}` on its own line, and must cover
> {pr_template_sections from config}.
> 10. **Do NOT merge.** Report back: `RESULT: pr=<N> branch=<name>
>     status=<opened|skipped|failed> review=<clean|nits|no-report|skipped|deferred> recovery_used=<0|1> note=<one-line>`

### Stacked variant (ONLY for a chain resolved in §2)

A stack is sequential by construction — layer 2 needs layer 1's code — so it gets **ONE sub-agent in
ONE worktree building every layer in order**, not one agent per issue. Dispatching the layers to
parallel agents is the failure this shape exists to prevent: they would each branch from the default
branch and rediscover the dependency as a conflict.

Substitute steps 7–9 of the prompt above with the following; steps 1–6 (worktree confinement, never
`git stash`, no shared-interpreter installs, read the issue, follow `CLAUDE.md` and
`## subagent-rules`, run the pre-flight, then step 6 as sited — the review gate on `agent`, the
coordinator-site step 6 on `coordinator`, neither under `review_agent: skip`) apply unchanged
**per layer** — a
stack is reviewed layer by layer, because a layer's diff is what its own PR carries.

> You are shipping a STACK of {depth} GitHub issues, bottom → top: {ordered list, e.g. #101 → #102 → #103}.
> Each layer's PR targets the branch of the layer below it; the bottom targets `{default_branch}`.
>
> Work the layers **strictly in order**. For each one:
>
> 1. Branch from the layer below — `git switch -c {prefix}/issue-{N}-{slug}` while that lower branch
>    is checked out. The bottom layer branches from `{default_branch}`. **Never return to
>    `{default_branch}` between layers**; that is what breaks the chain.
> 2. Implement only that layer's issue. Keep the layers genuinely separable — if you find yourself
>    editing a lower layer's code from an upper one, STOP and report it, because the split is wrong.
> 3. Run the pre-flight and fix anything red before moving up: {preflight_commands from config}
> 4. Commit with a conventional-commit message containing a literal `Closes #{N}` line.
> 5. Push, then open the PR against the layer below:
>    `gh pr create --base <branch of the layer below, or {default_branch} for the bottom>`.
>    The body MUST contain `Closes #{N}` on its own line and cover {pr_template_sections from config}.
>    Include this layer's `recovery_used=0|1` and review outcome in its own PR body and issue
>    comment; never borrow an unused allowance from a sibling layer.
>
> After every layer has a PR, link them into a stack bottom → top. Pass explicit JSON — the field
> must be an array of integers, which `gh api -f` would send as strings:
>
> ```bash
> echo '{"pull_requests":[<pr numbers bottom to top>]}' \
>   | gh api "repos/{repo_slug}/stacks" -X POST --input -
> ```
>
> If that call fails, the PRs are still correct and correctly based — report the failure and let the
> coordinator link them. **A failed link is recoverable; a wrong base is not.**
>
> **Do NOT merge any layer.** Report one RESULT per layer with its PR, issue, review outcome and
> `recovery_used=0|1`, then the stack line (its value is the maximum across layers):
> `RESULT: stack=<bottom..top issue numbers> prs=<pr numbers bottom to top> linked=<yes|no> status=<opened|partial|failed> review=<clean|nits|no-report|skipped|deferred> recovery_used=<0|1> note=<one-line>`

If a middle layer fails, the layers below it are still valid, independent PRs. Report the partial
stack rather than discarding the work — the coordinator can land what exists and re-dispatch the rest.

## 6. Coordinator: watch + merge (delegated)

Before the PR-only reconciliation below, apply §5's **Issue-only terminal handoff** to each
claimed issue in this batch, including returned failures with `pr=none` and resumed attempts.
Do not drop such failures while extracting PR numbers; an exhausted pre-PR failure takes the
same blocked transition without requiring a PR. Missing PR alone never proves terminal failure.

First reconcile each PR's `recovery_used` with its RESULT, PR body and durable issue comments using
§5. All ONE-redispatch instructions below mean this same shared allowance: if the implementing
agent already spent it, take the existing second-failure `blocked` path immediately, not another
retry. Persist any coordinator recovery before dispatch and update the PR body plus issue comment
with its outcome and `recovery_used`; a later dispatch-ready tick must read the same decision.

**Before handing anything onward, on EITHER site: a sub-agent whose RESULT line reported
`review=no-report` OR `review=skipped` is held, never merged.** Both, and for one reason — each
PR lacks a complete reported review — so they are held identically; the sibling rule in
`dispatch-ready` §2 withholds the same two (and splits `deferred` by site exactly as below), and a path that held only one of them would reach the
opposite conclusion about the very same sub-agent's output. This sits ABOVE the coordinator-only
subsection deliberately: under `review_site: agent` that subsection does not run at
all, so a rule stated inside it would leave the agent site merging PRs whose review reached
nobody, which is the whole of #273 one layer out. Either outcome gets the same treatment a
Blocking finding gets — name it in the §7 report, allow ONE redispatch carrying the outcome as
context, and keep the PR out of the list you hand to `sassy-dog:pr-shepherd` below. A second
failure gets the `blocked` label plus a comment naming the outcome, and a human decides; never
park it back in Ready.

**One carve-out, and without it this rule freezes merges: `review_agent: skip`.** That opt-out is
the ONLY configuration whose every run legitimately reports `review=skipped`, so holding on
`skipped` alone would turn the documented opt-out into a blanket merge freeze — every PR held,
redispatched, then `blocked`. §1 already resolves the agent once per invocation, so it knows which
case this is: when the repo configured the explicit opt-out, `skipped` is the expected outcome and
holds nothing. **Every OTHER `skipped`** — the agent did not exist, the plugin did not load, the
dispatch errored — is a review nobody ran, and is held. `dispatch-ready` §2 draws the same line for
the same reason.

**`review=deferred` is legitimate on exactly one site.** Under `review_site: coordinator` it is the
expected outcome: the worker followed the coordinator-site step 6, and the coordinator review gate
below reviews the PR before it merges. So `deferred` is not held here. It goes to that gate, which
holds or releases the PR on its own outcome. Under `review_site: agent` a `deferred` means a
worker skipped the review it was told to run. It is held exactly like `skipped`, with the same one
redispatch and the same second-failure `blocked` path.

### Review gate on the coordinator site (ONLY when `review_site: coordinator`)

**With `review_site: agent` this section does not run**: every sub-agent already reviewed its own diff at step 6, before its PR existed.

When the site is `coordinator`, review each PR as its RESULT line arrives and **before handing it
to `sassy-dog:pr-shepherd` below**, dispatching the agent resolved in §1 at tier `sol` (Claude Code:
`model: "opus"` · omp: `model: "@default"`) against that PR's diff
versus the derived default branch, with the original scope statement and reconciled `recovery_used`.
For the shipped orchestrator only, load §5's resolved **Parent recovery protocol** path and pass it
with context `review_surfaces` null, never forwarded. Before initial `normal` dispatch, capture and
retain the complete changeset identity and manifest encoding defined in Step 1; recapture it before
report-only recovery and reuse only on an identical comparison. On `review-fanout-plan`, this
coordinator is the actual caller: follow that protocol, dispatch only missing/unusable surfaces
concurrently in one parent batch using the planned briefs, read all actual returns, then submit the
complete original plan and actual result records/provenance as `review-aggregate-input` in
`aggregate-only` mode. Never replay successful surfaces; identity/context changes invalidate all
reuse without resetting `recovery_used`. Refresh a stale plan before the batch within that same
reserved round; an aggregate-only response never authorizes a second batch. The batch plus
aggregation spends the same ONE allowance from §5. Custom agents keep their existing contract; never silently change `review_site` or
escalate to another ancestor. Control alone, failed aggregate dispatch, unable parent, exhausted
budget or unrecovered required surfaces after aggregation is incomplete fallback: use the NO REPORT
bullet below, retain all surface causes and any partial degraded report, and take the existing
second-failure blocked path if recovery is spent. Only a whole orchestrator that could not start
uses SKIPPED.
For an incomplete returned final text from the shipped orchestrator, apply its **Report-only
recovery** before the NO REPORT bullet: normal and compact-clean reports are complete; corrections,
tallies and partial text are not. Retain enumerated findings, dark surfaces and provenance. Only
with identical changeset/context, an unused shared allowance and supported resume capability,
reserve it and use the actual returned dispatch handle and agent identity for exactly one
`report-only` request to that same agent for its already-completed full human report; never guess
an address, relay a message or pointer. Do not re-run analysis, fan-out, or integration. Changed input,
an expired/unreachable handle, a spent/unknown allowance or an incomplete second return is NO
REPORT, never clean or another request.
Then:

- **Blocking finding** → hold the PR; **never merge past it**. Name the finding in the §7 report and
  allow ONE redispatch carrying it as context. A second failure gets the `blocked` label plus a
  comment naming the finding, and a human decides.
- **Nits** → note them in the report; they never hold a merge.
- **Dispatched, but no report came back** → print
  `review: NO REPORT — <agent> dispatched, no report returned (lint/type/test only)`, name the
  agent, and **hold the PR** — never merge it, and never hand it to `sassy-dog:pr-shepherd`. Never
  hold the run open until one arrives, and never call this a skip: the agent ran, so it is a third
  outcome rather than the line below wearing a different cause.
- **`review_agent: skip`, the explicit opt-out** → no review is owed, so the PR is **not held on
  review grounds** and goes to `sassy-dog:pr-shepherd` like any other green PR. §1 already resolved
  the agent, so this is known before any dispatch; dispatch nothing, print
  `review: SKIPPED — no review_agent resolved (lint/type/test only)`, name `opt-out
  (review_agent: skip)` on the next line, and record that as the PR's outcome. Say once in the §7
  report that review was opted out. Without this carve-out the bullet below holds every PR under the
  documented opt-out, the blanket merge freeze the either-site carve-out above exists to prevent.
  `dispatch-ready` §2 draws the same line.
- **No agent resolved, or the dispatch failed** (anything other than that explicit opt-out) → print
  `review: SKIPPED — no review_agent resolved (lint/type/test only)` and name which of the two it
  was (the cause, never the opt-out). Never merge on a review that was never reported.

Use the capability skill for ALL polling, merge, and teardown mechanics — do NOT reimplement them
inline:

```
Skill: sassy-dog:pr-shepherd
Args: "Watch PRs <numbers from the RESULT lines> in <repo>. Merge policy:
       <merge_queue ? 'MERGE QUEUE — enqueue greens with gh pr merge --auto (no method flag, no
       --delete-branch), confirm isInMergeQueue, handle ejects'
                    : 'DIRECT — gh pr merge --squash --delete-branch, serialize coupled PRs'>.
       <if migrations: 'Coupled-PR concern: migrations in <migrations.dirs> (regenerate with
       <migrations.regen_command>).'>
       <if codegen: 'Coupled-PR concern: codegen (<codegen.hint>).'>
       <if a stack was dispatched: 'STACKED: PRs <bottom..top> are layers of one stack. Merge
       bottom-up only — stack-probe.sh gates this; merge-shepherd exits 23 on a blocked layer
       (re-run) and 24 when it needs a human. Tear the shared worktree down only after the TOP
       layer is terminal.'>
       After all PRs are terminal, tear down these worktrees: <paths from the batch manifest>,
       then reconcile the local default branch."
```

A stack's worktree is shared by every layer, so it appears **once** in the manifest, not once per
issue. Tearing it down after the bottom layer merges would strand the layers above it.

If `sassy-dog:pr-shepherd` is not in your available skills, STOP and tell the user to install
the plugin (`claude plugin install sassy-dog`) — do not improvise the merge loop from memory.

Run the coordinator synchronously; backgrounding it orphans PRs at "checks pending".

## 7. Final report

| Issue | PR | Status | Notes |
| --- | --- | --- | --- |
| #218 | #260 | ✅ MERGED | one-line summary |
| #240 | #261 | ⚠️ FAILED | named failing check + log excerpt |
| #216 | — | ⏭ SKIPPED | reason |

When no board is configured, clear the claim label for every MERGED row via
`sassy-dog:github-issues`' `issue-claim.sh release N1 N2` — `Closes #N` closed the issue but
does not strip labels, and a stale claim label misleads the next loop's in-flight reconcile.

Always end with: claims to unwind by hand (assignments, plus board cards or `in-progress` labels
for unshipped issues) and a next-action one-liner per failure.

## Guardrails

- **Single-writer**: sub-agents never merge or enqueue; only the coordinator does, and only for
  green PRs.
- **Never merge past a Blocking review finding**, on either `review_site`. One redispatch carrying
  the finding, then `blocked` — and a review that could not run, or that ran and never came back,
  is reported under its own name, never passed over and never waited out.
- **Never auto-rebase a CONFLICTING PR** — surface it. Expect an upper stack layer to go
  `CONFLICTING` after the layer below squash-merges; that is the normal shape, not a fault.
- Cap parallelism at 5. Don't dispatch on stubs or `blocked` issues.
- **Never split a stack across parallel agents**, and never dispatch a partially-named chain. One
  chain = one agent = one worktree, layers built in order.

Apply any `## extra-guardrails` section from config on top of these.
