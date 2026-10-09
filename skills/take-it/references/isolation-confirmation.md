# Isolation confirmation before a parallel dispatch

Both `take-it` and `dispatch-ready` read this file before claims and local mutations on a
non-Claude harness. dispatch-ready re-derives isolation each tick; unavailable parallel isolation
can use the same supervised serial contract as take-it. Parallel workers still require separate
branches and trees, commit/push capability, no coordinator checkout changes and removable artifacts.
The underlying parallel contract is in `docs/HARNESS-PORTABILITY.md`.

**Path resolution.** Set `PLUGIN_ROOT` to the already-resolved absolute plugin root from the
calling SKILL.md. Never infer it from the consumer checkout. All commands below use an absolute
`CHECKOUT` for the consumer repo; keep the returned ownership token private to this coordinator.

## Checkout ownership

Claude Code's `Agent` worktree path is unchanged and skips this guard. Every other coordinator,
even one expecting confirmed parallel isolation, must acquire BEFORE reconciliation, fetch,
branch switches, merge/fast-forward or teardown. This prevents a new tick from mutating beneath
an earlier serial worker before it reaches the isolation check.
This is cooperative exclusion between callers using this contract, not a Git filesystem fence:
arbitrary human commands, older plugin coordinators and processes deliberately escaping the
supervised session can bypass it. Do not run such writers concurrently or claim they are fenced.

```bash
bash "$PLUGIN_ROOT/skills/take-it/scripts/checkout-guard.sh" acquire \
  --repo "$CHECKOUT" --owner "$COORDINATOR_ID"
```

Use a unique invocation/session identity. Capture the returned JSON token as `TOKEN` and guard
path for reporting. Acquisition is atomic in the Git common directory, conservative across
linked worktrees. It refuses an existing owner, dirty tree, unnamed branch, unpublished local
commits or unverifiable state. The current tip must equal or be an ancestor of a freshly read
upstream tip (origin same-name fallback). A behind default can therefore fast-forward under
ownership; an object-only fetch may establish ancestry after durable acquisition. A clean
status or local remote-tracking ref alone proves nothing.
The JSON `result=acquired` includes `token` and `guard`; only exit 0 grants ownership.
Exit 3 is contention, 4 unresolved/auth/unsafe state, 5 dirty/unpushed work and 6 a probe failure.
Exit 64 is invalid usage, including a missing Python 3 (the guard needs Bash, Python 3, Git and
POSIX `ps`): report `checkout guard unavailable` and claim nothing.
Never infer success from empty stdout. `status` reports `ownership=free|held|active|unresolved`,
its phase and run records without revealing the token.
Acquisition writes only ownership metadata, never repairs a checkout. A refused acquisition
leaves no guard: one that fails its checks after publishing ownership archives itself before
exiting, since no token or worker exists yet. On refusal claim nothing, perform no reconciliation
mutations and report its actual reason.

```bash
bash "$PLUGIN_ROOT/skills/take-it/scripts/checkout-guard.sh" status --repo "$CHECKOUT"
```

This is read-only evidence, not permission to steal ownership. Only `ownership=active` (a live
supervisor running a worker) is `checkout active writer`, which is self-resolving. `held` with no
live worker, or `unresolved`, is `checkout ownership held` / `checkout ownership unresolved`: its
owner may be a coordinator that died holding the only token, which no later caller can tell apart
from one still working. Report its guard path, owner, phase and `age_seconds`, and name the
operator's next action; never wait it out. No timer, missing PR, blocked issue, terminal comment,
clean tree or copied token authorizes release. A coordinator never runs `abandon`, deletes the
guard, or invents an automatic force-unlock route.

**Operator-only abandonment**, after the operator confirms the owning session has ended:

```bash
bash "$PLUGIN_ROOT/skills/take-it/scripts/checkout-guard.sh" abandon \
  --repo "$CHECKOUT" --reason "<why the owner is known to be gone>"
```

It needs no token, only positive evidence. It accepts `held` or `completed`, or `uncertain` with
no runs (an acquisition that died before issuing a token), from the guard's own worktree. It
re-proves every recorded worker's termination, a clean tree and exact fresh pushed tips as
`verify` does, then archives the guard with the reason. It refuses `launching`, `running`,
`timed-out`, `interrupted` and any other uncertain guard: those need investigation of the recorded
process identities and retained work, and no command guesses termination. Abandoning a guard whose
coordinator is in fact alive removes that coordinator's exclusion, and its later `verify` or
`release` fails visibly; that is why this is the operator's decision and never a loop's.

Hold ownership through local coordinator work. No coordinator mutation while the serial child
is live or uncertain. Before continuing after a child, use `verify` below; after all local work
use `release`. Every normal early exit, including capacity/no-eligible exits, takes this release
path. On failed verification stop, preserve everything and report the guard and artifact paths.

## 0. Which harness

- **Claude Code** (the worker dispatch tool is `Agent`, which takes `isolation: "worktree"`): that parameter is the confirmation. **Stop reading: nothing below applies and the dispatch is unchanged.**
- **omp** (the worker dispatch tool is `task`): continue.
- **Anything else:** isolation is **unconfirmed**. Go to "Fail closed" below.

## 1. Read the three settings (omp)

```bash
omp config get task.isolation.enabled
omp config get task.isolation.apply
omp config get task.isolation.merge
```

They must read `true`, `false` and `patch`. An unset `merge` reads `patch`. Anything else, or a command that fails, is **unconfirmed**; the first failure stops the sequence.

- `apply: false` keeps the worker's change out of the parent checkout. `apply: true` patches the parent, so a worker that already pushed leaves the same change twice.
- `merge: patch` is pinned because `merge: branch` with `apply: false` leaves a local `omp/task/<Name>` ref in the parent that nothing removes, and the branch/`HEAD`/status comparison in step 4 does not see it.
- `omp config get` reflects the profile, `PI_CONFIG_FILES`, and a project `.omp/config.yml`, `.omp/settings.json` or `.claude/settings.json`. It does **not** reflect a `--config` overlay, so settings supplied only that way never pass this step. A committed project `.omp/config.yml` is the route that needs no profile write.
- Never run `omp config set`, and never change the operator's profile to make this step pass. Report what failed and what a consumer repo could commit instead.

## 2. Probe one worker (omp)

A passing read can still be overridden at run time (for example by a `--config` flag the read cannot see), so test requirement 1 once, before the first batch of the invocation. Record the coordinator's own values first:

```bash
pwd -P
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --porcelain
```

Then dispatch **one** worker at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`), with `isolated: true` on its `task` entry. **A `task` entry without `isolated: true` runs on the shared tree whatever the settings read**, so a probe without it measures nothing (#452's runs 3 and 4 probed the coordinator's own tree that way). Its prompt, self-contained:

> Read-only probe. Run `pwd -P` and `git rev-parse --show-toplevel`, then `git branch --show-current`. Change nothing, create no branch, commit nothing and push nothing. Reply with exactly those three outputs.

**Every worker dispatched after a confirmed outcome carries `isolated: true` on its `task` entry as well**, for the same reason: the settings make isolation available, and only the parameter requests it.

Compare. **The same `pwd -P` or the same top-level path as the coordinator's means isolation is off: unconfirmed.** A reply that is missing, or that is not the three outputs, is unconfirmed too. Then re-run the coordinator's `HEAD`, branch and `git status --porcelain` and require them unchanged from the values just recorded. The probe tests requirement 1 only; requirement 3 rests on the `apply` read and on step 4.

## 3. Record the outcome

Write it to the batch manifest `$(git rev-parse --git-path take-it-batch.json)` (`.git/take-it-batch.json` in an ordinary checkout), beside the §5 `{issue, pr, worktreePath, worktreeBranch}` records, so a resumed coordinator does not start from nothing:

```json
{"isolation": {"harness": "omp", "outcome": "confirmed|serial|stop", "enabled": "true", "apply": "false", "merge": "patch", "probe": "isolated|shared|no-reply", "reason": "<what failed, or empty>"}}
```

A resumed run re-reads the settings; it never reuses `confirmed` from a previous process.

## 4. After each parallel batch (omp)

1. Compare the coordinator's branch and `HEAD` with the values from before the batch, and `git status --porcelain`. `merge: branch` leaves the tree clean with `HEAD` moved, so a clean tree is not enough. A moved branch or `HEAD`, or a dirty tree, means **unconfirmed**: dispatch no further batch and report it.
2. For each worker that reported a pushed branch, run a **fresh** `git ls-remote origin <branch>` yourself. Never take the worker's own report of the push as the check.
3. Under `apply: false` omp leaves `<tmp>/omp-task-<id>/` (a patch plus a `.json`, `.jsonl` and `.md`) holding the **only** copy of a change a worker did not push. The worker's result text names the directory. Remove **only that directory, only after step 2 showed the branch on the remote in the same step**, and only your own. If the push is not verified, leave the directory, name its path in the §7 report, and treat the issue as unshipped. Never sweep other `omp-task-*` directories: they belong to other sessions.

## Fail closed

**Where isolation is unconfirmed, never dispatch parallel workers on a shared tree.** Take the
first outcome that applies, before claiming anything:

- **Serial.** Only a plain independent issue/list, never a stacked chain, concurrent-claim hold
  or worker requiring a private parent. Checkout ownership, a clean/pushed starting checkout,
  and a real supervised foreground runner must be available. Say **serial and not isolated**.
  Apply the synchronous contract below. take-it can complete an independent list one by one;
  dispatch-ready launches at most one issue total per tick, including §2 recovery.
- **Stop dispatch.** Name the failed isolation setting/probe AND the specific unsafe serial
  prerequisite. No new claim, no invented launch, no dirty-work cleanup and no profile changes.
  A resumed invocation preserves existing claims and work; do not unwind a launched worker's
  claim merely to make capacity appear free. Unlaunched claims from this invocation are reported
  for the usual explicit unwind only.

An unrecognised harness cannot assume it has omp's runner. Without a demonstrably equivalent
foreground supervision mechanism, stop with `serial runner unavailable`.

## Synchronous serial execution

This is the shared serial lifecycle; callers reuse it rather than inventing branch or cleanup
rules. Check runner availability and resolve its model before claiming. omp 18.8.5's CLI
does not accept `@task` as `--model` (it reports `Model "@task" not found`). Read
`omp config get modelRoles --json`: use the configured `value.task`, or the configured
`value.default` when task has no override, and retain that concrete selector as `TASK_MODEL`.
Report the default-role fallback explicitly; never invent a provider/model or write settings.
A missing/non-string selector is `serial runner model unresolved`, before any claim.
Use the foreground CLI below, not an asynchronous `task` or detached shell. This remains the
caller's terra implementation worker binding; the concrete selector is its CLI transport.

1. Hold the acquired token. Before each launch confirm `git status --porcelain` is empty;
   never stash, reset or discard work. For a later worker in take-it's list, first verify the
   previous launch and push as below. dispatch-ready never launches a second issue this tick.
2. Write a complete self-contained worker prompt to an absolute file in the Git metadata
   directory, outside tracked files. Build it from take-it §5's template: actual repo slug and
   checkout path, default/assigned branch, issue number/title/body/comments needed for scope,
   config stack summary, implementation rules, preflight commands and PR sections; authenticated
   `attempt_id`, recovery allowance/reservation and existing PR for a recovery. Embed the
   Issue-only terminal handoff, doc reconciliation, conventional commit, push and RESULT rules.
   Replace step 1 with the **Serial variant** verbatim. Replace step 6 with the coordinator-site
   prohibition on worker review (or explicit skip), never both. Make initial-versus-recovery
   explicit: initial branches from freshly fetched origin/default; recovery resumes its exact
   existing branch by that variant, never replaces it. Tell the worker to implement inline,
   run the supplied preflight, commit, push and open/update the real PR. It must never launch
   subagents, detach jobs/services or background any subprocess, review, merge, enqueue, switch
   back to default or release the guard. Do not pass the ownership token to it.
   No nested worker/reviewer, detached tool job or pending command may survive its return;
   await every command it starts before producing the final result. The CLI's tool allowlist
   deliberately excludes `task`. Even with `--no-pty`, omp shell tools can create separate
   process groups; the guard records observed groups and requires all of them to terminate.
   For an assigned serial recovery, override the template's reservation-write instructions:
   the coordinator alone marks that existing reservation started/finished, the worker carries
   `recovery_used=1` unchanged and returns its outcome without posting duplicate transitions.
   A worker's required issue-only terminal comment remains an application failure record, never
   proof that the supervisor observed exit; it cannot authorize checkout reuse.
3. For recovery, confirm the existing reservation's `started` durable write immediately before
   this one launch, with `recovery_used=1` unchanged. The launcher records ownership before
   child mutation and supervises the actual process group. Use the foreground command and wait
   for its actual return; do not impose a shorter outer tool timeout or background it:

   ```bash
   bash "$PLUGIN_ROOT/skills/take-it/scripts/checkout-guard.sh" run \
     --repo "$CHECKOUT" --token "$TOKEN" --branch "$BRANCH" -- \
     omp --print --no-session --no-pty --tools read,write,edit,grep,glob,bash \
       --model "$TASK_MODEL" --cwd "$CHECKOUT" "@$WORKER_PROMPT"
   ```

   `run` may take `--timeout <seconds>` before `--`; timeout is a retained safety hold, not
   successful worker completion. If the harness returns a running tool handle, await that same
   foreground supervisor's completion, launch nothing else and keep ownership. If it cannot be
   awaited, report unresolved ownership; never substitute a task dispatch.

   `run` emits one JSON result on stdout; worker output streams to stderr. Only
   `result=completed|worker-failed` with `termination_verified=true` proves a stopped worker;
   `worker_exit` is its actual exit status (guard exit 20 represents a proven nonzero worker).
   Exit 21/22 reports timeout/interruption and retains the guard; an uncertain `result=refused`
   is not a terminal worker return. `verify` returns `result=verified` and `verified_branches`;
   `release` returns `result=released`, its receipt and runs. Require the command's success exit
   as well as its expected result before acting.
4. A RESULT, PR or terminal comment is only application output. Read the runner's durable
   process outcome to establish that the supervisor reaped the worker and no live descendant/
   process group remains. A timeout, interruption, unresolved launch or uncertain termination
   retains ownership even if the issue was demoted. Never close recovery as finished based only
   on that comment; after verified process termination close the reservation once with its real
   success/failure outcome. Nonzero worker exit remains a reported failure.
5. Before branch switching, coordinator review/merge/teardown or a later take-it worker:

   ```bash
   bash "$PLUGIN_ROOT/skills/take-it/scripts/checkout-guard.sh" verify \
     --repo "$CHECKOUT" --token "$TOKEN"
   ```

   Require success. The guard checks real termination, clean tree and every run branch's LOCAL
   committed tip against fresh `git ls-remote origin refs/heads/<branch>` evidence. A reported
   push, remote branch existence or stale tracking ref is insufficient. Failure preserves the
   original checkout, dirty/unpushed changes, prompt and artifacts and retains ownership;
   do not switch to default, delete a branch or hand those artifacts to cleanup. Worker nonzero
   alone need not hold forever if exit, clean tree and exact pushed tips are proved, but never
   rewrite it as a successful implementation.
6. After verification, return to the derived default branch and fast-forward only; refuse a
   dirty, ahead/diverged or unpublished default rather than repairing it. **Do not leave a
   serial run branch checked out at release:** a later server-side merge may auto-delete its
   remote ref and make the next acquisition unverifiable. Preserve every run branch locally
   and remotely until its ownership epoch has been released and archived.

   dispatch-ready defers this tick's new/recovered PR's merge to a later tick. For take-it's
   existing reviewed-PR merge path, first finish the worker epoch with the release below, then
   immediately acquire a fresh guard before ANY further local mutation or merge. Acquisition
   contention stops this coordinator; never act using the released token. The fresh epoch has
   no worker runs whose remote evidence GitHub's `delete_branch_on_merge` could erase. Omitting
   `--delete-branch` alone does not disable that server setting. Keep the fresh ownership through
   merge/teardown, then release it too. This changes ownership/cleanup timing, not review or
   merge policy, and grants no additional worker or recovery allowance.
7. At the end of ALL local work, before returning:

   ```bash
   bash "$PLUGIN_ROOT/skills/take-it/scripts/checkout-guard.sh" release \
     --repo "$CHECKOUT" --token "$TOKEN"
   ```

   This re-proves termination, clean tree and fresh exact pushed tips before releasing ownership.
   Zero-worker normal completion can release. Failure retains the guard and artifacts and is a
   visible hold. After successful release do not mutate this checkout without acquiring again.
   Report actual runner exit, pushed tip and released/retained status, never merely an intended
   dispatch. No automatic reclamation is authorized by elapsed time.

## `review_site` on omp

Under `review_site: agent` a worker sits at `task` depth 1 and `pr-review-orchestrator` at 2, and an agent at the maximum recursion depth (default 2) has no `task` tool, so the orchestrator cannot dispatch the reviewers. On omp, treat a configured `review_site: agent` as unsatisfied, run with `coordinator` for this invocation, and **report the override in §7** (`review_site: agent overridden to coordinator on omp`). Do not edit the config: the override is per run, and a silent change is the failure this report exists to prevent.
