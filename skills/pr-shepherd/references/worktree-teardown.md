# Worktree teardown & session reconcile

After a batch of parallel sub-agents merges (or fails), the coordinating session must clean its own trace inline — not defer to a future cleanup pass. End state to assert: `git worktree list` shows only the main checkout (plus any genuinely-open PR's worktree), local default branch == origin, no leftover feature branches, no leftover `worktree-agent-*` isolation branches.

> **Path resolution.** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at load time only — **not** into this file (reference docs are read raw), and it is **not** an environment variable in the shell. Before running anything below, set `PLUGIN_ROOT` to the plugin root's absolute path: where it comes from depends on the harness. On Claude Code the invoking `SKILL.md`'s command lines carry the root already substituted; on a harness that leaves the plugin-root placeholder unexpanded (omp), use the root that `SKILL.md`'s **Plugin root.** paragraph resolves, which is the `[Skill file: ...]` or `[Skill directory: ...]` path cut at `/skills/<skill-name>`. Do not search for it. Every command below quotes `"$PLUGIN_ROOT/..."`, so an unset value fails loudly with a 127 rather than resolving against `/`.

## The squash-ancestry trap

**`git branch --merged` is useless when the repo squash-merges.** A squash-merged branch's tip is NOT an ancestor of the default branch, so `--merged` reports it UNMERGED — a false negative that makes naive cleanup keep everything forever.

The reliable merged signal is **"remote branch gone"**: merges delete the remote branch (via `--delete-branch`, `delete_branch_on_merge`, or the merge queue's own deletion), so a local worktree branch with no `origin/<branch>` counterpart has been merged (or deliberately closed). `teardown.sh --sweep` keys off exactly this. Corollary: never disable remote-branch deletion on merge — the whole cleanup signal depends on it.

## The isolation-branch leak

The Agent runtime checks each agent worktree out on a `worktree-agent-<id>` **isolation branch**. The PR merges from the agent's *feature* branch, so the isolation branch never gets an upstream: after a per-merge teardown removes the worktree directory, the leftover branch is neither a `.claude/worktrees/` path to sweep nor `[gone]` — it just lingers, one per merge (a 35-issue drain left 36 of them). Two rules follow:

- **Prevention** — per-merge teardown (`merge-shepherd.sh`'s teardown step, and `teardown.sh`'s explicit mode) deletes the isolation branch at the same time it removes the worktree. Never the PR's own head branch (`--delete-branch` / the `[gone]` sweep owns that); never a branch another live worktree has checked out.
- **Sweep** — `teardown.sh --sweep` classifies leftover orphans (isolation-prefix branch, worktree gone): tip is an ancestor of the default branch OR a MERGED PR contains the tip (squash-merge false-negative safe, same gotcha as feature branches) → `-D`; neither → surfaced for a human, never auto-deleted. Isolation branches whose worktree is still present are **live agents** — `--sweep` never touches them, and never removes their worktrees by the "no remote" inference either ("no upstream" is an isolation branch's normal state, not a merged signal).

Prefix override: `ISOLATION_BRANCH_PREFIX` env (default `worktree-agent-`), honored by both scripts.

## Batch manifest

As each sub-agent returns, record `{issue, pr, worktreePath, worktreeBranch}`. Teardown consumes the `worktreePath`s to clean up *exactly* this batch instead of guessing. Write it somewhere durable (e.g. `.git/<batch-name>.json`) so a crashed coordinator's worktrees stay reclaimable via `--sweep` later.

```bash
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/teardown.sh" <wt_path_1> <wt_path_2> ...
# with no manifest (crashed coordinator, older sessions):
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/teardown.sh" --sweep
# this batch AND everything else stale, in one call — flags parse anywhere:
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/teardown.sh" <wt_path_1> <wt_path_2> --sweep
```

The manifest form and `--sweep` are **not** alternatives: pass both and the named paths are torn down first, then the sweep runs, then the shared prune/reconcile/residual tail — which is what "tear these down, then sweep" should mean in a single invocation. An argument starting with `-` that is neither flag is rejected with a usage error and exit 2 *before* any teardown, never taken for a path (issue #200). `--reconcile-only` is the exception: it skips every worktree/branch phase, so combining it with anything is rejected.

**Checkout guard (exit 7).** Before its first local mutation `teardown.sh` runs `checkout-guard.sh check`. With no guard it proceeds as always. If a serial worker's guard exists and the caller does not hold it, teardown touches nothing, prints the guard path and `ownership`, and exits `7`. The guard's holder passes its token for that call only: `SASSY_DOG_CHECKOUT_TOKEN=<token> bash …/teardown.sh …`, never on argv. Anyone else follows the operator next action in `skills/take-it/references/isolation-confirmation.md`; do not retry in a loop.

The script force-removes each worktree (the Agent runtime leaves them locked, hence `-f -f`), deletes the local branch, prunes, clears origin-identical stragglers, and ff-reconciles the default branch. It reports — but **never auto-drops** — stashes (destructive; human's call).

## Session drift: two failure modes after sub-agent merges

`isolation: "worktree"` shares the underlying `.git` with the main session, so sub-agent activity can corrupt the coordinator's state in two distinct ways:

**Drift A — HEAD on a feature branch.** A sub-agent's commit advanced the session HEAD onto its branch. `git pull --ff-only origin main` then fails with `fatal: Not possible to fast-forward` (the feature tip is the unsquashed commit, not an ancestor of the squash-merge).

**Drift B — cwd inside a sub-agent worktree.** The shell cwd silently became a `.claude/worktrees/agent-*` path. `git switch main` fails with `'main' is already used by worktree at '<main repo path>'`. Symptom: `pwd` shows the worktree path, not the project root.

Single ordered recovery that handles both — `cd` back to the main repo root first (Drift B), then run the scripted reconcile:

```bash
cd <main-repo-root>                         # snap cwd back (Drift B)
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/teardown.sh" --reconcile-only
git branch -D "<feature-branch>" 2>/dev/null || true
```

`--reconcile-only` is the script's reconcile tail with nothing else: `git switch <default-branch>` (snaps HEAD back, Drift A), `fetch --prune`, clears origin-identical untracked stragglers that would block the ff (see below), then `pull --ff-only` — and exits `1` when the ff still fails, because in this mode the ff *is* the job. Equivalent by hand, if the script is unavailable:

```bash
git switch <default-branch> 2>/dev/null || true   # snap HEAD back (Drift A)
git fetch origin <default-branch> --prune   # refresh + drop deleted-remote refs
git pull --ff-only origin <default-branch>  # advance to the squash-merge commit
```

## Straggler files

A sub-agent whose Bash cwd reset between calls may have written untracked files into the *main* checkout — these block the ff-reconcile. `teardown.sh` clears only the safe subset: untracked files that are now TRACKED on origin's default branch AND byte-identical there (nothing is lost by deleting). Anything else it leaves and reports.

## Rules for the sub-agents themselves (prevention beats cleanup)

Bake these into any dispatch prompt for worktree-isolated sub-agents:

- **Never `git stash`.** Worktrees share one `.git`; stash writes the *global* `refs/stash` — one agent's stash is visible to and collides with every other worktree. Commit WIP to the branch or discard explicitly.
- **`cd` into the assigned worktree on every Bash call** (cwd resets between invocations). Verify with `pwd && git rev-parse --show-toplevel && git branch --show-current` before the first edit.
- **Sub-agents never merge or enqueue.** Single-writer: only the coordinator talks to the merge layer.
