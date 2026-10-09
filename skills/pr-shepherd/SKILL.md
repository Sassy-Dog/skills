---
name: pr-shepherd
description: >
  This skill should be used when the user asks to "watch this PR and merge when green",
  "babysit the PRs", "poll PR checks", "auto-merge the green ones", "enqueue to the merge queue",
  "why is my PR stuck in the queue", "retry that flaky gh call", "clean up the worktrees after the batch",
  "why did CI never start on this PR", "is this a GitHub outage or a real failure",
  or any PR-lifecycle mechanics: mergeable checks, check polling, transient-failure retry,
  platform-degradation probing, merge-queue vs direct merge, serialization of
  migration/codegen-coupled PRs, post-merge
  worktree teardown and branch reconcile. Also triggers when a project workflow skill
  (a generated take-it or send-it) invokes sassy-dog:pr-shepherd by name.
---

# PR Shepherd

PR lifecycle mechanics from "PR opened" to "merged and cleaned up": verify mergeable, watch checks, retry transient GitHub failures, merge (or enqueue) greens, serialize coupled PRs, tear down batch worktrees. Works in any GitHub repo; project workflow skills delegate here so the mechanics live in one place.

This skill does NOT decide *what* to merge — the caller (user or project skill) owns that. It also never auto-rebases a `CONFLICTING` PR; conflicts are surfaced for a human decision.

## Inputs to establish first

From the caller's request (ask if missing and not inferable):

1. **Repo** — `owner/name`, or infer from cwd.
2. **PR number(s)** — what to shepherd.
3. **Merge policy** — merge queue or direct merge. Project skills state this explicitly; otherwise detect (see `references/merge-queue.md`) and confirm a guess rather than acting on it.
4. **Coupled-PR concerns** — does the batch touch migrations / codegen / other derived artifacts? (See `references/serialization.md`.)
5. **Teardown scope** — worktree paths from a batch manifest, if the caller ran parallel sub-agents.
6. **Stacked PRs** — is any PR a layer of a stack? Detected automatically by `scripts/stack-probe.sh`, never asked. (See `references/stacked-prs.md`.)

## Workflow

### 1. Mergeable check — always first

`CONFLICTING` silently blocks CI from firing ("no checks reported" looks identical to "CI hasn't started"). Check before any watch loop:

```bash
gh pr view "$PR" --repo "$REPO" --json mergeable,mergeStateStatus --jq '"\(.mergeable) \(.mergeStateStatus)"'
```

For more than one PR — or a "where does everything stand" probe — prefer the scripted snapshot over hand-rolled `--jq` variants; it reuses the poller's type-aware pending predicate and prints the same table + JSON as a watch tick:

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/pr-shepherd`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
REPO="$REPO" bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/poll-prs.sh --once "$PR"   # zero PR args = every open PR
```

Surface `CONFLICTING` immediately — do not auto-rebase. For generated-file conflicts, point the caller at the regenerate-don't-hand-merge recipe in `references/serialization.md`.

### 1b. Stack check — before any merge decision

A middle layer of a stacked PR reports green + `MERGEABLE` + `CLEAN` exactly like an ordinary PR, because its base *is* a real branch and there is no textual conflict. Merging on that reading lands an upper layer into a lower layer's branch while the bottom is still open. `merge-shepherd.sh` gates this automatically; when driving by hand, probe first:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/stack-probe.sh "$PR" --repo "$REPO"
```

Exit `0` in a stack · `10` not stacked · `11` stacks unavailable in this repo · `1` error. A non-empty `lower_open` means **merge the layer below first**. Read `references/stacked-prs.md` before acting on a stack — in particular, why detection needs two probes and why a merge queue plus a stack is refused rather than guessed.

### 2. Watch checks

Single PR, interactive: `gh pr checks "$PR" --watch --fail-fast`.

Multiple PRs (batch): use the bundled poller — read-only, polls every 60s, exits when all PRs are terminal, emits final JSON for the merge decision:

```bash
REPO="$REPO" bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/poll-prs.sh "$PR1" "$PR2"
```

Run it synchronously — backgrounding the watcher orphans PRs at "checks pending" with nobody deciding. For a single no-wait snapshot (state reconciliation at the top of a loop tick, not a watch), use `--once` — exit `0` = all terminal, `11` = something still pending (same "re-run later" code as `merge-shepherd.sh`).

### 2b. Platform degradation probe — when a watch goes nowhere

A `gh` call that *errors* is already handled everywhere: an API-failure tick proves nothing, and every caller knows it. The unhandled case is a call that **succeeds and returns incomplete data**, which a coordinator then reads as live state. Measured on 2026-08-26 during a platform outage: `gh pr view --json statusCheckRollup` exited 0 carrying two checks and no `ci`; no `CI` workflow run existed for that head across ~40 minutes while the two prior heads on the same branch each had one within minutes; `mergeStateStatus` read `BLOCKED`; later `ci` appeared in the rollup with an **empty state** and still no run behind it. Nothing errored. Three hypotheses were produced — Actions queueing, a workflow path filter, a transient miss — and all three were wrong, and the proposed remedy (close and reopen the PR to re-trigger CI) could have made things worse during an outage. Degradation is a recurring operating mode here, not an exception.

Run the probe when a watch has gone nowhere — a required check that never appears, a rollup that shrank, a tick that reconciles to the same nothing. **Do not wait for `poll-prs.sh` to tell you so**, and do not read that as the poller being the only sibling that disagrees with this probe. Three readers classify the same rollup entry, and no two of them agree across all of its shapes — measured, not assumed:

| rollup entry | this probe | `poll-prs.sh` pending filter | `merge-shepherd.sh` `checks()` |
| --- | --- | --- | --- |
| `status`/`conclusion`/`state` all `""` | anomaly | not pending | **pending** |
| `conclusion: null`, no `status` | anomaly | **pending** | not pending |
| `conclusion` absent, no `status` | anomaly | **pending** | not pending |
| `StatusContext` with `state: ""` | anomaly | not pending | not pending |

So “the poller went quiet” is evidence for rows 1 and 4 only; for rows 2 and 3 the poller reports *pending*. **The row that matters for a merge is not the row the poller disagrees about most loudly.** `merge-shepherd.sh` is the only one of the three that **writes**, and on row 1 it is the *safer* reader — it counts the entry pending, prints `WAITING` and returns 11, so it holds. Rows 2, 3 and 4 are the dangerous ones: `merge-shepherd.sh` counts them neither pending nor failing, so on a `CLEAN` `mergeStateStatus` its `pend -eq 0` condition is satisfied and it **enqueues or merges** — past a check that has not reported. Measured against both predicates directly. Both siblings carry parity comments naming each other, and those comments are silent about exactly these shapes. Reconciling the three is a separate change to two untouched files, so until it lands the trigger is a stalled `mergeStateStatus`, a missing required check, or your own judgement — never a poller that went quiet. Note also that all three of its `gh` calls are bounded by `PLATFORM_GH_TIMEOUT` through `timeout`/`gtimeout`, at a per-call **ceiling of 25s** — the 20s bound plus a fixed 5s kill grace, which is the number to plan a tick around rather than the knob's own default; the attribution fetch is `curl`, bounded separately by `PLATFORM_STATUS_TIMEOUT` (5s). **Worst case end to end is 80s**, deliberately inside the 120s default tool timeout, because a harness kill yields no JSON and no stderr at all — so raising `PLATFORM_GH_TIMEOUT` past ~33 means owning that tool timeout too. The repo is derived from the checkout's `origin` remote with `git` and never through a `gh` call, so it costs neither a call nor a bound, and cannot answer an outage with the false `not in a GitHub repo` it once did inside a valid checkout. Where neither `timeout` nor `gtimeout` is on `PATH` the `gh` calls run unbounded and the probe both records `timeout_unavailable` and warns once on stderr, so on such a host still run it where a hang costs you a tick rather than a loop:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/probe-platform-health.sh --pr "$PR" --repo "$REPO"
```

It returns one of exactly **four** verdicts on stdout as JSON, and they are four distinct answers — collapsing any pair re-creates the bug:

| Verdict | What it means |
|---------|---------------|
| `healthy` | a first-party check actually ran, found nothing wrong, AND the status page is green |
| `degraded (attributed)` | the platform reports an open incident on a check-relevant component |
| `degraded (unattributed)` | first-party evidence of degradation the status page does not corroborate |
| `unknown` | nothing could be measured, or the status endpoint could not be read |

**A green status page is NOT evidence of health.** `githubstatus.com` lags real degradation by minutes to tens of minutes and routinely under-reports partial Actions failures. The asymmetry is the whole design: **`red` explains a stall; `green` explains nothing, and must be reported in those words.** Report the verdict as the probe returns it and never re-derive one. **Report the `explains` field, not the verdict alone.** A `healthy` or an `unknown` verdict explains nothing — and so does a `degraded (attributed)` verdict whose `self_measured` is not `anomaly`, which says an incident is open and that this PR showed no sign of it. None of the three is ever evidence the stall is a real defect: reading green as "so escalate" converts an unknown into a confident wrong answer, which is worse than having no probe at all.

**An unreachable status endpoint contributes `unknown`** — never `healthy`, and never `degraded` on its own. A verifier that degrades to "assume fine" is worth nothing on the day it matters. Where an unreadable page sits beside a first-party anomaly the verdict is `degraded (unattributed)`, because the degradation was measured first-party and only the attribution is missing — that is what the word "unattributed" already means, and a page you could not read adds exactly as much as a page that is green, which is nothing. The self-measured signal is the load-bearing half; the status page answers a different question — is it them or us — and answers it late.

`clean` additionally requires that the head clear the age floor and that the runs page was **not** truncated — on a branch with 100+ head-triggered runs the probe reports `unknown` rather than `healthy`, by design. **There are two doors into `healthy` — the first-party one and the attribution one — and the first-party one is the easier to leave open.** That is a taxonomy, not a count of bugs: **four** concrete paths through those two doors have now been found and closed, and every one of them reported `healthy` on a platform that was not. Three were first-party — an empty-string check name silently dropped, a truncated runs page earning `clean`, and an EMPTY rollup earning `clean` unopposed beside runs that did happen — and one was attribution, a `PLATFORM_STATUS_COMPONENTS` scope matching no component name and so classifying a live outage `operational`. Assume there is a fifth. `clean` means a check RAN and found nothing — never "nothing was looked at". **Only the run comparison earns it** ([#285](https://github.com/Sassy-Dog/skills/issues/285)): the empty-state check is a real signal, but it detects a *malformed* rollup entry and can never detect an *absent* one, so a rollup that simply lacks `ci` looks identical to a healthy one through it — accepting it as sufficient certified #285's own rollup shape as `healthy` on a single-commit branch. The run comparison itself needs a prior head *and* a non-empty intersection across prior heads; an empty one compared nothing. The probe reports `checks_run` so you can see which ran, and it preserves `self_measured_reason` when none did. Two consequences worth keeping: **attribution is scoped to check-relevant status components** (a Copilot or Codespaces blip explains nothing about a red `ci`, and letting it attribute invents an excuse for a genuine failure — the same confident wrong answer pointed the other way), and **a failed `gh` call is `not_measured`, never an anomaly** — an expired token, a rate limit or a closed laptop is not platform degradation, so it lands in `probe_errors` and the run reports `unknown` against a green or unreadable page. An open incident on a check-relevant component still attributes, because that is the page saying something rather than nothing.

**Never a gate.** The verdict changes what a tick *says*, not what it *does*: it appears in **no** merge, hold, block or redispatch decision, and every verdict exits `0` so it cannot become one through a `set -e` or an `if`. A PR missing a required check is held either way — the hold was already correct, the *attribution* was what was missing. The merge path is the least exposed surface for a reason worth recording: branch protection is enforced **server-side**, so a PR missing a required check is refused by GitHub itself and not by this loop's reading of it. The cost of degradation here is wasted work and wrong escalations, not bad merges. That exit-code contract is a deliberate asymmetry with `stack-probe.sh`, whose exit codes *are* a gate because gating is its job; aligning the two is exactly the tidy to refuse.

**ONE carve-out, and it is a decision to STOP rather than a decision to ACT** ([#286](https://github.com/Sassy-Dog/skills/issues/286)): `dispatch-ready` §7 may consult the verdict to reach its `DRAIN DEGRADED` terminal state and end the loop. That is not a loophole in the rule above, it is the line the rule is actually drawn on. Every decision listed there — merge, hold, block, redispatch — **acts on a PR or an issue**, so a wrong verdict turns an outage into a wrong write. Ending a loop writes nothing: the worst a false `degraded` can do is stop a drain early, which a human restarts, and that is strictly better than the measured alternative of ticking into a void for three hours and then proposing to close and reopen a PR mid-outage. **The direction is what makes it safe, and it does not generalise**: the verdict may stop work, never start or advance it. A future *the loop already trusts the probe, so let it hold this PR* reads like consistency and is the rule inverted — a hold is an act on a PR, and it is the first item on the forbidden list. `unknown` is not `degraded` on that path either, for the same reason it is not here.

### 3. Merge or enqueue greens

Merge only PRs with **all checks green AND `mergeable=MERGEABLE` AND `mergeStateStatus=CLEAN`**. The command differs by regime — read `references/merge-queue.md` before this step. Under a queue the primary enqueue is the GraphQL `enqueuePullRequest` mutation, not `gh pr merge`; on the manual/fallback CLI path the queue's `--auto` method-flag trap silently never-merges.

**"All checks green" is not the same as "no red checks" — an empty rollup satisfies the second and not the first.** `CLEAN` means *nothing blocks the merge*, and a base branch with no required checks blocks nothing, so a PR with **zero** checks reports `CLEAN` and zero pending — indistinguishable from a fully green one. Two ways to land there, both real: an intermediate chained or stacked PR (its base is a feature branch, which carries no protection), or CI that simply has not started yet. Observed live on 2026-08-06, when an Actions outage left three chained PRs reading `CLEAN` with no checks at all.

`merge-shepherd.sh` gates this and exits `21`. It refuses only where the repo **demonstrably runs CI on pull requests** (`actions/runs?event=pull_request` reports a non-zero `total_count`), so repos with no CI by design are unaffected; `--allow-no-checks` overrides. Checking by hand, confirm the rollup is non-empty before trusting `CLEAN`:

```bash
gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq '.statusCheckRollup | length'
```

**Preferred write path — the bundled step script.** `scripts/merge-shepherd.sh` drives one PR through the whole write step as a stateless, idempotent "advance one step" against live GitHub state: mergeable check → red/pending gate → enqueue via GraphQL `enqueuePullRequest` (or `--direct` squash-merge) → GraphQL `isInMergeQueue` confirmation → teardown + ff-only default-branch reconcile. Every invocation is short, so a session killed mid-merge (memory-pressured hosts reap idle long-lived loops) costs one re-run instead of an orphaned merge:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/merge-shepherd.sh "$PR" --repo "$REPO" [--direct] [--worktree "$WT"] [--watch 240]
```

Distinct exit codes let the caller loop "re-run until terminal" without parsing output: `0` merged (+teardown) · `10` enqueued · `11` waiting/in-flight, or a stale branch that was just updated (re-run) · `20` red checks · `21` no checks reported where this repo expects them (re-run) · `22` conflicting · `23` blocked by an open lower stack layer (re-run — it clears when the layer below lands) · `24` stack needs a human (a lower layer closed unmerged, or the repo runs a merge queue). Queue mode is the default: the enqueue primitive is the GraphQL `enqueuePullRequest` mutation (PR node id resolved in-script), which works on every queue variant — including queues that reject all `gh pr merge` flags, `--auto` included ("auto merge is not allowed") — with `gh pr merge --auto` (NO method flag) retained only as a fallback when the mutation errors, and a GraphQL-only enqueue confirm either way. Pass `--direct` for repos without a merge queue (`--squash --delete-branch`); the direct path additionally runs the staleness gate below. It already encodes the guardrails — never merges past red (advisory failures also stop it), never auto-rebases `CONFLICTING`, wraps every enqueue/merge call in `gh-retry.sh`.

**`CLEAN` is not evidence CI ran against the current base — the direct path gates on staleness.** `CLEAN` means "no textual conflict" and nothing more. A PR whose checks went green days ago still reports `CLEAN` while many merges stale, and merging it reddens the default branch on the spot. Branch protection does not save you: **"Require branches to be up to date before merging" is a separate setting from "require status checks" and is off by default**, so a repo can have required checks and still merge stale branches — and repos without protection at all have nothing. A merge queue *does* cover it (the queue rebuilds each entry against the current base), so this is a **direct-merge-only** concern: `merge-shepherd.sh` compares the PR head against the default branch (one compare call, no checkout), and on a non-zero behind-count it runs `gh pr update-branch` instead of merging and exits `11` — checks re-run against the new base and the next stateless invocation merges. Two deliberate behaviours: an **unknown** behind-count proceeds rather than stalling a healthy merge (the failure mode is a re-run, not a red default branch), and the gate is **skipped entirely under a queue**. A failed `update-branch` still exits `11` with "update it by hand" on stderr — never a merge. Merging by hand, check it yourself first:

```bash
gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid
# then: gh api "repos/$REPO/compare/<default-branch>...<head-sha>" --jq .behind_by   # 0 = current
```

**Stateless-eject caveat**: a stateless pass cannot distinguish "the queue ejected it" from "never enqueued" (head-commit checks stay green either way), so an ejected-but-`CLEAN` PR is simply re-enqueued on the next pass — the right recovery for transient ejects. A PR that keeps failing `merge_group` checks on the rebased ref will ping-pong enqueued→waiting; if repeated runs alternate like that, stop re-running, watch with `poll-queue.sh` (eject-aware), and follow "Eject recovery" in `references/merge-queue.md`.

Or drive the steps by hand:

- **Merge queue**: enqueue with the GraphQL `enqueuePullRequest` mutation — resolve the PR node id, then mutate (ready-made commands in `references/merge-queue.md`). Some queue configurations reject every `gh pr merge` flag including `--auto` ("auto merge is not allowed"), so the CLI is the fallback, not the primary: where you do use `gh pr merge "$PR" --auto`, pass NO method flag and NO `--delete-branch` (the method-flag trap — see `references/merge-queue.md`). Either way, confirm `isInMergeQueue:true` within ~30s (`isInMergeQueue` is GraphQL-only — `gh pr view --json isInMergeQueue` fails with `Unknown JSON field`; use the ready-made query in `references/merge-queue.md`, don't improvise). Then watch the queue with the bundled poller — read-only, terminal on `MERGED`, ejected, or closed-without-merge — instead of hand-rolling a loop (improvised loops miss the eject state):

  ```bash
  REPO="$REPO" bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/poll-queue.sh "$PR1" "$PR2"
  ```

- **Direct**: `gh pr merge "$PR" --squash --delete-branch`.

Wrap every mutating `gh` call in the retry helper (502s, stuck "Merge already in progress" locks, transient GraphQL):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/gh-retry.sh -- pr merge "$PR" --repo "$REPO" --auto
```

If the batch contains coupled PRs (same migrations/codegen directories), follow `references/serialization.md`: under a queue with a gating freshness check, enqueue all and let the queue eject stale ones; without one, merge coupled PRs one at a time with a mergeable re-check between each.

For red PRs: do not merge; pull the failing logs so the report names the failure — the bundled script handles run-id extraction and non-Actions checks (Vercel-style StatusContexts have no fetchable log; it prints their link instead of erroring):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/pr-failure-log.sh "$PR" --repo "$REPO"
```

**Stale pre-fix check trap — verify the head SHA before counting a redispatch failure.** After a fix has been *requested* (a redispatch or resume message to a fix agent) but before it has been *pushed*, the PR's head is still the failed commit, so `mergeStateStatus`/`statusCheckRollup` keep reporting the old failing run — the PR reads red even though the fix is in flight. A naive "PR is red → attempt N failed" read parks shippable work. Before treating a red read as a failed fix attempt:

1. Record the PR's `headRefOid` whenever a failure is observed (`poll-prs.sh` prints it per tick and includes it in the final JSON — no extra API call needed).
2. On a later red read, compare the current `headRefOid` (or the failing run's `headSha`) to the recorded failed SHA.
3. **Same SHA → the fix has not landed yet.** Report "fix pending / in flight" and keep waiting — do NOT increment the attempt count, escalate, or park the PR.
4. **New SHA and still red → the fix pushed and failed.** Only now count the attempt and apply the caller's escalation policy.

Callers doing redispatch bookkeeping (e.g. a generated dispatch-ready's "ONE redispatch with the failure context") must key attempt counts to head SHAs, never to bare "PR is red" reads.

### 4. Teardown and reconcile

After a batch with worktree-isolated sub-agents, read `references/worktree-teardown.md`, then:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/teardown.sh <wt_path...>            # the batch manifest
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/teardown.sh --sweep                 # everything stale
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/teardown.sh <wt_path...> --sweep    # both, one call
```

**Paths and `--sweep` combine** — "tear these down, then sweep" is one invocation, and the flag may sit anywhere in the argument list. The named paths go first, then the full sweep, then the shared prune/reconcile/residual tail. Any unrecognised `-`-prefixed argument is rejected with one usage error and a non-zero exit **before** anything is torn down, rather than being taken for a worktree path (issue #200). `--reconcile-only` is the one exclusive mode: it skips every worktree/branch phase, so combining it with paths or `--sweep` is rejected the same way.

Then reconcile the session (cwd back to repo root, switch to default branch, `git pull --ff-only`, delete local feature branches) — `teardown.sh --reconcile-only` runs exactly that reconcile (including clearing origin-identical untracked stragglers that block the ff) without touching any worktree or branch, and exits `1` when the ff fails so the caller sees it. Squash-merge repos: "remote branch gone" is the merged signal, never `git branch --merged`. Teardown also deletes each worktree's `worktree-agent-*` **isolation branch** — it never had an upstream, so it is never `[gone]` and would otherwise accumulate one orphan per merge (see the isolation-branch leak in `references/worktree-teardown.md`). `--sweep` additionally deletes **ordinary `[gone]` local branches** — feature branches from non-worktree flows (a plain send-it) whose upstream was deleted on merge, which neither worktree-scoped phase would otherwise ever enumerate. Guards: never the default branch, never a branch a live worktree has checked out, never the base of an open PR (deleting a base closes that PR), and a failed open-PR lookup skips deletion rather than proceeding unguarded — every held-back branch is reported, and the `== residual ==` footer counts swept vs held.

**Checkout guard.** Before its first local mutation `teardown.sh` runs `scripts/checkout-guard.sh check` (read-only; see the table). With no guard present, or a `held`/`completed` guard whose token matches `SASSY_DOG_CHECKOUT_TOKEN` in the environment, it proceeds exactly as above. Otherwise it makes **no** local mutation, prints the check's one JSON line (guard path and `ownership`) and exits **`7`** (new; `2` stays usage, `1` a failed `--reconcile-only` ff). A coordinator that holds the guard on a non-Claude harness passes `SASSY_DOG_CHECKOUT_TOKEN=<token>` as a per-call environment prefix on each pr-shepherd call, never exported for the session and never on argv. `merge-shepherd.sh` is server-side first: its post-merge local teardown makes the same check, reports a refusal as a skipped local teardown and never changes the merge or its exit code.

## Bundled scripts

| Script | Purpose |
|--------|---------|
| `scripts/poll-prs.sh` | Polls 1+ PRs every 60s until all terminal. Read-only. Surfaces `headRefOid` per tick and in the final JSON so callers can spot stale pre-fix runs before counting a redispatch failure. `--once` = single snapshot tick, no loop (zero PR args probes every open PR); exit 0 all-terminal / 11 pending. `REPO`, `POLL_INTERVAL`, `POLL_MAX_TICKS` env. Exit 124 on watch timeout. |
| `scripts/pr-failure-log.sh` | Names a red PR's failing checks and prints each one's `--log-failed` tail, labeled. Handles the run-id extraction from check links and prints non-Actions (StatusContext) checks as external links instead of erroring. Read-only. Exit 0 reported / 10 no failures / 1 a log fetch failed. |
| `scripts/merge-shepherd.sh` | The single WRITER: stateless, idempotent merge step for ONE PR — red/pending gate, empty-rollup gate (`CLEAN` + zero checks is not green; `--allow-no-checks` overrides), stacked-layer gate (never merges a layer with open lower layers), staleness gate on the `--direct` path only (`CLEAN` is not evidence CI ran against the current base — a behind-count over zero triggers `gh pr update-branch` and exit `11` instead of a merge; unknown proceeds, and a queue rebuilds its own entries so queue mode skips it), enqueue via GraphQL `enqueuePullRequest` (node id resolved in-script; `gh pr merge --auto` fallback only when the mutation errors) or `--direct` squash, GraphQL enqueue confirm, teardown + ff-only reconcile. Teardown also deletes the worktree's `worktree-agent-*` isolation branch (never the PR's own head branch — `--delete-branch`/`[gone]` owns that). Re-run after any kill; bounded `--watch N` mode. Exit codes 0/10/11/20/21/22/23/24; a checkout-guard refusal skips only the local teardown and never changes them. `DEFAULT_BRANCH` / `ISOLATION_BRANCH_PREFIX` env (same contract as `teardown.sh`). |
| `scripts/poll-queue.sh` | Queue-phase companion to `poll-prs.sh`: polls 1+ enqueued PRs' merge-queue state (GraphQL) until each is `MERGED`, ejected, or closed without merge. `OPEN` + `isInMergeQueue:false` is disambiguated via the last `RemovedFromMergeQueueEvent`: reason `merged` reports `merged` (the PR-state flip lags the queue-entry removal); any other reason reports `ejected`, loudly. **No removal event is not a verdict on its own** — the event lags too, so it means `ejected` (never enqueued) only for a PR never seen in the queue, and for one that WAS seen it stays non-terminal and re-reads next tick, bounded by `POLL_MAX_TICKS` alone (issue #234). Read-only — never re-enqueues or recovers. Same env/contract: `REPO`, `POLL_INTERVAL`, `POLL_MAX_TICKS`, exit 124 on timeout, final JSON on stdout. |
| `scripts/stack-probe.sh` | The single stacked-PR detection primitive: REST `GET /repos/{o}/{n}/stacks` for repo availability + GraphQL `PullRequest.stack` for membership (both are needed — GraphQL `null` cannot distinguish "repo not enabled" from "PR not stacked"). Emits `position`, `entries[]` bottom→top, and the derived `lower_open` / `lower_closed_unmerged` the merge gate reads. Read-only. Exit 0 in a stack / 10 not stacked / 11 stacks unavailable / 1 error. |
| `scripts/probe-platform-health.sh` | Degradation probe: distinguishes "GitHub told me the truth" from "GitHub told me a *degraded* truth" — a `gh` call that exits 0 carrying incomplete data. Compares this head's workflow runs against prior heads of the same branch (run-to-run, never rollup-to-run — rollup names are job names and differencing the two namespaces manufactures anomalies on a healthy repo; the baseline is the **intersection** over prior heads, head-triggered events only), flags rollup entries with no status/conclusion/state, and attributes only afterwards against the status page, scoped to check-relevant components. Returns one of `healthy` · `degraded (attributed)` · `degraded (unattributed)` · `unknown`, plus `checks_run` (which checks ran, and whether the runs page was truncated — **only the run comparison earns `clean`**, since the empty-state read cannot see an *absent* check) and `probe_errors` (scoped, over the closed set `first_party` · `attribution` · `probe`: a `first_party` transport failure makes a run `not_measured` and is never an anomaly, an `attribution` entry leaves the measurement alone but changes the verdict through the status-page axis, and a `probe` entry never feeds the first-party count at all — `timeout_unavailable` leaves the measurement and verdict intact — while a dead emitter bypasses the count altogether, emitting a hand-built four-key `unknown` carrying `verdict`, `self_measured_reason: verdict_emitter_failed`, `explains` and the digits-validated `pr`, never a same-shape copy of this object). `green` explains nothing and says so; an unreachable endpoint is `unknown`, never `healthy`. On an `unknown` the `explains` string carries the not-measured reason and any first-party detail behind it, so the human channels name the cause rather than repeating one sentence for every cause. Read-only, and **never a gate** — every verdict exits `0`. Exit `1` is reserved for the cases where no verdict exists at all: a usage error or a missing `jq` — and a verdict *always* exists otherwise, because an unresolvable repo now yields `unknown` with a reason and a failed emitter falls back to a hand-built `unknown` rather than exiting 0 with empty stdout. All three `gh` calls are bounded by `PLATFORM_GH_TIMEOUT` (default 20s, plus a fixed 5s kill grace, so 25s per call and 80s worst case end to end) via `timeout`/`gtimeout`; a fired bound — exit 124, or 137 when `gh` ignored TERM and the grace fired — is a `first_party` transport failure like any other (`not_measured`, never an anomaly). The repo comes from the checkout's `origin` remote read locally with `git`, never from `gh repo view`: a probe that runs during an outage must not ask GitHub where it is standing, and that call's empty-stdout exit 1 was indistinguishable from "not in a repo". A host with neither timeout binary runs unbounded, warns once on stderr and records a `probe`-scoped `timeout_unavailable`, leaving the verdict as measured. `--pr` / `--repo` / `--status-url` (https only) / `--min-age`; `PLATFORM_STATUS_URL` / `PLATFORM_STATUS_TIMEOUT` / `PLATFORM_GH_TIMEOUT` / `PLATFORM_PROBE_MIN_AGE` / `PLATFORM_STATUS_COMPONENTS` env. Requires `jq`; without `curl` it degrades to `unknown` attribution rather than failing. |
| `scripts/gh-retry.sh` | Exponential-backoff retry for mutating `gh` calls on transient failures (502/503/504, "Merge already in progress", transient GraphQL). Exit 124 on exhaustion so the caller decides best-effort vs escalate. |
| `scripts/checkout-guard.sh` | Durable, cooperative checkout ownership and foreground serial-worker runner (`acquire`, `status`, `run`, `verify`, `release`, operator-only `abandon`), moved here from `take-it` (#486) because pr-shepherd owns the post-merge local mutations it governs. Workflow contract and operator runbook: `skills/take-it/references/isolation-confirmation.md`. `check --repo PATH` is the read-only gate other mutators call: reads the caller's token from the `SASSY_DOG_CHECKOUT_TOKEN` environment variable (never argv; an argv `--token` is ignored), exits `0` for no guard or a matching `held`/`completed` guard, `3` for a live writer, `4` for a missing or wrong token or unresolved state, and emits one JSON line without writing anything. Needs Bash, Python 3, Git, POSIX `ps`. |
| `scripts/teardown.sh` | Batch worktree cleanup: force-removes locked agent worktrees, deletes local branches + their `worktree-agent-*` isolation branches, prunes, clears origin-identical stragglers, ff-reconciles the default branch. `--sweep` reclaims orphans whose remote branch is gone AND sweeps orphan isolation branches whose worktree is gone (ancestry OR merged-PR classification; unmerged ones surfaced, live ones untouched) AND deletes ordinary `[gone]` local branches — upstream deleted on merge, no worktree needed — guarded: never the default branch, a live-worktree checkout, or the base of an open PR, each held back loudly, and a failed open-PR lookup skips deletion rather than running unguarded. Explicit paths and `--sweep` **combine in one call, flags anywhere in the argument list** — paths are torn down first, then the sweep, then the shared tail; an unrecognised `-*` argument is rejected with a usage error and exit 2 before anything is torn down (issue #200). `--reconcile-only` runs just the default-branch reconcile + residual report (exit 1 if the ff fails) and is EXCLUSIVE — combining it with paths or `--sweep` is rejected. Residual report counts swept vs held-back `[gone]` branches. Never drops stashes. Runs `checkout-guard.sh check` before any local mutation and exits **`7`** with nothing touched while a guard it holds no token for exists (see the Checkout guard note above). `DEFAULT_BRANCH` / `ISOLATION_BRANCH_PREFIX` env override. |

## Guardrails

- **Single-writer**: only the coordinating session merges/enqueues; sub-agents never do. One owner per PR — never point `merge-shepherd.sh` and a watcher session (or two writers) at the same PR from different sessions.
- **Never merge past a red check**; never auto-rebase `CONFLICTING`.
- **Never read an empty check rollup as green.** `CLEAN` + zero pending is also what "no checks ran at all" looks like — count the rollup, don't just check for failures.
- **Never merge a stale branch on the direct path.** `CLEAN` means "no textual conflict", not "CI ran against the current base" — a green-days-ago PR reads `CLEAN` while many merges behind, and merging it reddens the default branch. "Require branches to be up to date" is a separate branch-protection setting that is off by default, so required checks do not cover this. Update the branch and let checks re-run (a merge queue rebuilds its own entries, so the gate is queue-exempt).
- **Never merge a stack layer while a lower layer is open.** Stacks merge bottom-up; `CLEAN` on a middle layer is truthful and says nothing about ordering. A stack under a merge queue is refused outright, not guessed at (`references/stacked-prs.md`).
- **Never treat an inconclusive stack probe as "not stacked."** Unknown means wait and re-run, not merge.
- **Never count a red PR as a failed fix attempt on a stale head** — confirm the failing run's head SHA is newer than the previously-failed one first (see the stale pre-fix check trap in §3).
- **Never let the platform-degradation verdict gate anything.** It changes what a tick *says*, not what it *does* — it belongs in no merge, hold, block or redispatch decision, with no exception for any verdict, and the probe's own `explains` field says what a verdict is worth: `healthy`, `unknown`, and a `degraded (attributed)` verdict with no first-party anomaly all explain nothing, and none of them ever licenses escalating a stall as a real defect (§2b).
- **Never force-push the default branch.**
- Draft PRs: watch only; the author flips to ready.
- Board claims and issue edits via `gh-retry.sh` are best-effort — exit 124 means log and continue, not abort.
