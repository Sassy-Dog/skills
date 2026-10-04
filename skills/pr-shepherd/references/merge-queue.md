# Merge mechanics: queue vs direct

Two merge regimes exist across Sassy Dog repos. Detect which one applies before merging anything — a wrong guess either bypasses required serialization or silently never merges.

> **Path resolution.** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at load time only — **not** into this file (reference docs are read raw), and it is **not** an environment variable in the shell. Before running anything below, set `PLUGIN_ROOT` to the plugin root's absolute path: where it comes from depends on the harness. On Claude Code the invoking `SKILL.md`'s command lines carry the root already substituted; on a harness that leaves the plugin-root placeholder unexpanded (omp), use the root that `SKILL.md`'s **Plugin root.** paragraph resolves, which is the `[Skill file: ...]` or `[Skill directory: ...]` path cut at `/skills/<skill-name>`. Do not search for it. Every command below quotes `"$PLUGIN_ROOT/..."`, so an unset value fails loudly with a 127 rather than resolving against `/`.

## Detecting the regime

Ask the repo, don't assume:

```bash
# Direct-merge settings (autoMergeAllowed is REST-only, not a gh-repo-view field)
gh repo view --json deleteBranchOnMerge,squashMergeAllowed
gh api "repos/$REPO" --jq '{allow_auto_merge}'

# Merge queue: no clean REST field — probe the branch protection rule
gh api graphql -f query='{repository(owner:"OWNER",name:"NAME"){
  defaultBranchRef{ branchProtectionRule{ requiresStatusChecks } } 
  mergeQueue(branch:"main"){ id } }}' 2>/dev/null
```

If GraphQL probing is inconclusive (scope limits are common), the caller's instructions win: project skills state their merge policy explicitly. When neither tells you, ask the user — never guess a merge policy.

## Regime A — merge queue

The repo's default branch is gated by a GitHub merge queue. **You never merge; you enqueue.**

**The primary enqueue is the GraphQL `enqueuePullRequest` mutation, not `gh pr merge`.** Some queue configurations reject *every* `gh pr merge` flag, `--auto` included ("auto merge is not allowed" — observed live; the CLI path can never enqueue on such repos), so only the mutation is portable across queue variants. Resolve the PR's node id, then mutate (schema-verified: `pullRequestId: ID!` is `EnqueuePullRequestInput`'s only required field):

```bash
PRID=$(gh api graphql \
  -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){id}}}' \
  -f o="${REPO%%/*}" -f n="${REPO##*/}" -F p="$PR" --jq '.data.repository.pullRequest.id')
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/gh-retry.sh" -- api graphql \
  -f query='mutation($prid:ID!){enqueuePullRequest(input:{pullRequestId:$prid}){mergeQueueEntry{position state}}}' \
  -f prid="$PRID"
```

(`scripts/merge-shepherd.sh` scripts this whole regime — gate, enqueue via the mutation, confirm, teardown — as one stateless, re-runnable step, dropping to `gh pr merge --auto` only when the mutation errors; the commands here are the underlying mechanics and the one-off/manual path.)

### The manual/fallback CLI path and its method-flag trap (cost a stuck canary in production use)

Where the queue accepts auto-merge, `gh pr merge "$PR" --repo "$REPO" --auto` also enqueues — it is the fallback when the mutation is unavailable (e.g. an older GHES schema). On this path, **use `--auto` with NO merge-method flag and NO `--delete-branch`.**

- Passing `--squash`/`--merge`/`--rebase` sets a *conflicting* auto-merge method and the PR silently **never enters the queue** — it sits `CLEAN` with auto-merge enabled but `isInMergeQueue:false` forever. Recovery: `gh pr merge "$PR" --disable-auto`, then re-run `--auto` with no method.
- `--delete-branch` is rejected outright under a queue ("Cannot use `--delete-branch` when merge queue enabled") — the queue deletes via `delete_branch_on_merge`.
- The repo setting `allow_auto_merge` must be on — and some queue setups reject `--auto` regardless ("auto merge is not allowed"); those repos have no working CLI path at all, only the mutation.

### Confirm the enqueue took

Enqueue returns immediately; the merge happens later when the queue's `merge_group` checks pass on the rebased ref. **Poll the queue entry, not the merge call:**

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"NAME"){
  pullRequest(number:'"$PR"'){ state isInMergeQueue mergeQueueEntry{ state position } }}}' \
  --jq '.data.repository.pullRequest | "\(.state) inQueue=\(.isInMergeQueue) \(.mergeQueueEntry.state // "-")"'
```

Confirm `isInMergeQueue:true` within ~30s of enqueuing — whichever primitive did the enqueuing. If it stays `false` while the PR is `CLEAN` after a mutation enqueue, the mutation errored (its stderr says why); after a CLI enqueue, you likely hit the method-flag trap above.

**This query is the only way to read the field.** `isInMergeQueue` and `mergeQueueEntry` are GraphQL-only — `gh pr view --json isInMergeQueue` fails with `Unknown JSON field` (it is not in `gh pr view`'s field set). Don't substitute a `gh pr view` call here.

Terminal states: `MERGED` (success), or the entry leaves the queue with the PR still `OPEN` and a failing `merge_group` run — **the queue ejected it**.

### Watch the queue with the bundled poller

Once the enqueue is confirmed, **the canonical queue watch is `scripts/poll-queue.sh`** — it loops the query above every `POLL_INTERVAL` (default 60s; queue cycles are slow) and covers the full terminal matrix per PR: `MERGED` (success), `OPEN` + `isInMergeQueue:false` (disambiguated — see below), `CLOSED` without merge. GitHub removes the queue entry a beat before flipping the PR to `MERGED`, so a tick can catch a just-merged PR at `OPEN` + `isInMergeQueue:false`; the poller reads the last `RemovedFromMergeQueueEvent` in the same query and allowlists the benign: reason `merged` reports **merged**, while any other reason reports **ejected**, loudly. **An absent removal event is not evidence of an eject** — that event lags too, and an empty timeline cannot tell "never enqueued" from "not visible yet". The poller settles it with the queue-entry state it has already seen: never seen in the queue means it never enqueued and reports **ejected**; seen in the queue means the event is merely late, so the tick stays non-terminal and re-reads (issue #234). That wait is bounded by `POLL_MAX_TICKS` alone — exit 124, i.e. *undetermined*, which is the honest answer where `ejected` would be a claim the poller cannot support. Transient GraphQL failures log and retry; they never kill the watch. Exits 124 on `POLL_MAX_TICKS` timeout and emits final JSON (`{pr, result, queueEntryState}` per PR) for the caller's decision:

```bash
REPO="$REPO" bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/poll-queue.sh" "$PR1" "$PR2"
```

Don't hand-roll the loop — improvised versions tend to poll only for `MERGED` and sit silent through an eject. Keep the raw query above for one-off checks (e.g. the ~30s enqueue confirmation). The script is read-only: it never merges, re-enqueues, or recovers — that stays with the coordinating session (single-writer guardrail). On `ejected`, go to Eject recovery below.

### Eject recovery

The queue rebuilds each queued PR onto the real tip (main + earlier-queued entries) and re-runs required checks there. A PR that was green standalone can fail on the rebased ref (stale codegen, migration ordering — see `serialization.md`). Recovery: rebase the PR onto the new main, re-run the repo's regeneration step so generated artifacts reflect the *union* state, `git push --force-with-lease`, re-enqueue. If a sub-agent still holds the PR's worktree and context, delegate the recovery to it.

### Stuck-lock note

A `gh pr merge` that hits a 502 can leave the PR locked with `Merge already in progress` while the request silently drops. `gh-retry.sh` treats that string as transient and re-drives the call. Under a queue the equivalent failure is "enqueue 502'd but didn't take" — same retry handles it; verify via the `isInMergeQueue` check, not by waiting passively.

## Regime B — direct merge (no queue)

```bash
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/gh-retry.sh" -- \
  pr merge "$PR" --repo "$REPO" --squash --delete-branch
```

- `--delete-branch` is required here (belt-and-suspenders even when `delete_branch_on_merge` is on) — teardown's "remote branch gone == merged" signal depends on the branch disappearing.
- Without a queue, *you* are the serializer: coupled PRs (migrations, codegen) must be merged one at a time with a mergeable re-check between each — see `serialization.md`.

## Either regime: the mergeable check comes first

`CONFLICTING` silently blocks CI from firing — `gh pr checks` returns "no checks reported" indistinguishably from "CI hasn't started yet." Check `mergeable` immediately after push/create; it turns a 30-minute wait-on-CI-that-never-starts into 30 seconds:

```bash
gh pr view "$PR" --json mergeable,mergeStateStatus --jq '"\(.mergeable) \(.mergeStateStatus)"'
```

Merge/enqueue only when: all checks green AND `mergeable=MERGEABLE` AND `mergeStateStatus=CLEAN`. **Never auto-rebase a `CONFLICTING` PR** — conflict classes have different recipes (generated files vs source vs lockfiles); surface it and let the human pick.

## Naming the failure

For any PR with a failing check, pull the log so the final report names the failure instead of saying "CI red":

```bash
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/pr-failure-log.sh" "$PR" --repo "$REPO"
```

The script selects every FAILURE/ERROR check, extracts each Actions run id from the check's link, and prints a labeled `--log-failed` tail per failure. Checks that are not Actions runs (Vercel-style StatusContexts) have no fetchable log — it prints their link as "external check" instead of erroring, which is exactly where the old hand-rolled `grep`-the-run-id-out-of-the-link pipeline broke. Exit `10` = nothing failing.
