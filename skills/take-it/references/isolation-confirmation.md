# Isolation confirmation before a parallel dispatch

`take-it` §5 reads this file on any harness that is not Claude Code, before it creates an attempt record or issues a single worker call; `dispatch-ready` §5 reads it every tick, before it claims anything, and re-derives the outcome rather than reusing a recorded `confirmed`, and stops on an unconfirmed outcome instead of going serial (its tick-shaped differences are stated there). It implements the contract in the plugin's `docs/HARNESS-PORTABILITY.md`, "Isolation contract (#426)" and "Isolation settings sources (#453)". Four requirements make parallel workers safe: each worker has its own branch and working tree; it can commit and push; nothing it does moves the coordinator's checkout; and its tree is removable. A harness that cannot show all four runs no parallel batch.

Nothing in this file runs a bundled script, so it needs no plugin-root preamble. Every command below runs from inside the repo being worked.

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

A caller without a serial mode, such as `dispatch-ready`, takes **Stop** only and unwinds nothing it has not claimed; the serial and unwind wording below is `take-it`'s.

**Where isolation is unconfirmed, never dispatch parallel workers on a shared tree.** Take the first outcome that applies:

- **Serial.** Allowed only for a plain list of independent issues, never a stacked chain, a concurrent-claim hold or a worker that needs a clean parent. Say in the §7 report that the run was **serial and not isolated**. Before each dispatch, `git fetch origin --quiet`, return to the default branch fast-forwarded, and confirm `git status --porcelain` is empty; if it is not, **Stop**. Dispatch one worker at a time, each to completion (PR opened, or a recorded terminal failure) before the next. §5's Serial variant (its step 1) makes each worker start its branch from `origin/<default>` rather than from the previous worker's `HEAD`.
- **Stop.** Where serial cannot be made safe, report `isolation unconfirmed` with the setting or probe that failed, unwind this invocation's §4 claims the way §7's closing lists them (assignments, board cards, `in-progress` labels; nothing was dispatched), and dispatch nothing. The existing `NO_CONFIG` stop is the model: an unknown is never read as fine.

An unrecognised harness takes **Stop** unless the plain-list serial conditions hold. A skill never degrades silently from parallel to a shared tree: say which outcome was taken.

## `review_site` on omp

Under `review_site: agent` a worker sits at `task` depth 1 and `pr-review-orchestrator` at 2, and an agent at the maximum recursion depth (default 2) has no `task` tool, so the orchestrator cannot dispatch the reviewers. On omp, treat a configured `review_site: agent` as unsatisfied, run with `coordinator` for this invocation, and **report the override in §7** (`review_site: agent overridden to coordinator on omp`). Do not edit the config: the override is per run, and a silent change is the failure this report exists to prevent.
