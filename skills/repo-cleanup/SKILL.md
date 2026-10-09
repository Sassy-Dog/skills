---
name: repo-cleanup
description: >
  Post-shipping git working-state reconciliation mechanics: fast-forward + prune the default
  branch, sweep `[gone]` and squash-merged local branches, remove stale/detached agent
  worktrees, sweep orphan `worktree-agent-*` isolation branches, triage orphan stashes by
  closedByPullRequestsReferences (not bare issue state), sweep untracked-file noise against an
  allowlist, mop up stale remote branches, and clear orphan claim labels. Use when the user asks
  "delete the [gone] branches", "why won't this squash-merged branch delete", "triage these orphan
  stashes", "remove stale agent worktrees", "why are there worktree-agent branches left over",
  "is this stash safe to drop", or any low-level branch/worktree/stash reconciliation mechanic.
  Also triggers when a project workflow skill (a generated tidy-repo) invokes
  sassy-dog:repo-cleanup by name. The repo's own generated tidy-repo owns the top-level
  post-shipping cleanup request and delegates the mechanics here.
---

# Repo Cleanup

The shared mechanics behind a repo's `tidy-repo`. A generated `tidy-repo` is thin: it holds project
facts and delegates the actual reconciliation here, so the tricky git plumbing (the `[gone]` grep
trap, squash-merge `-D`, stash triage by PR linkage) lives in exactly one place.

This skill does **not** own the top-level cleanup request — the per-repo generated `tidy-repo` does,
and calls this skill by name. It also pairs with the read-only `sassy-dog:repo-health` (health
= read scan; cleanup = write reconcile) and with the built-in `commit-commands:clean_gone` (a
narrower `[gone]`-only sweep — this skill supersedes it with stash/untracked/label handling).

## Inputs to establish first

The caller (a generated `tidy-repo`, or the user directly) supplies these. Resolve any that are
missing before acting:

1. **Repo** — `owner/name`. If not given, resolve dynamically (don't hardcode):
   `REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)`.
2. **Default branch** — defaults to `main`. Used as the reconcile target and the "never delete" guard.
3. **Dep/version-file globs** — files whose presence in a stash blocks small-content auto-drop
   (e.g. `package.json`, `bun.lock`, `pubspec.yaml`, `*.csproj`, migration dirs). Stack-specific.
4. **Noise allowlist** — extra auto-discard patterns beyond the universal defaults (build/output
   dirs like `**/node_modules/`, `**/.dart_tool/`, `**/build/`).
5. **Never-discard list** — gitignored-but-precious files to leave untouched (e.g. `.env.local`).
6. **`delete_branch_on_merge`** — whether GitHub auto-deletes the head branch on merge (makes step 7
   normally a no-op). Read from repo settings if unknown.
7. **Claim label** (optional) — a take-it-style in-progress label (e.g. `status:in-progress`) to
   clear on issues whose work already merged. Omit if the repo has no claim-label convention.

**Acting principle (steps 3–4 and 8):** ASSESS first, act on what you're confident about, escalate
only on mixed signal — substantive WIP, dep-file touches, abandoned-but-non-trivial work. Asking on
every `.DS_Store` defeats the purpose; never confirming on a 600-line orphan stash loses real work.

## 0. Stop on a checkout guard (before any local mutation)

A serial worker may own this checkout under the durable checkout guard that `take-it` and
`dispatch-ready` acquire. Every step below that changes the local checkout (the default-branch
switch and fast-forward, stash drops, untracked-file discards, worktree removal, local-branch
deletion) must wait for the guard. Read it first:

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/repo-cleanup`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/checkout-guard.sh status --repo "$(git rev-parse --show-toplevel)"
```

`ownership=free` proceeds. Any other `ownership` (`held`, `active`, `unresolved`) stops all local
mutation: report the guard path, owner, phase and `age_seconds`, and point at the per-phase next
action in `${CLAUDE_PLUGIN_ROOT}/skills/take-it/references/isolation-confirmation.md` (read it for
the operator's `abandon` route). This skill never holds a guard, never passes
`SASSY_DOG_CHECKOUT_TOKEN`, and never runs `abandon`; `pr-shepherd`'s `teardown.sh` also refuses
(exit `7`) without the holder's token, so step 5 would stop there anyway. Read-only inventory
(step 2's listings, `gh` reads) may still run and be reported.

## 1. Sync the default branch and prune

```bash
git fetch --prune
git switch "$DEFAULT_BRANCH" 2>/dev/null && git pull --ff-only || true
```

After this, `git branch -vv` marks stale locals `[gone]` for every remote branch that was deleted
(the common case once a PR merges with auto-delete).

**Pattern trap:** in `git branch -vv` output the literal text is `[origin/<branch>: gone]` — the
`gone` token sits *inside* the upstream-tracking annotation, so grepping that output for `\[gone\]`
matches **zero** lines (the inner pattern `: gone\]` is what hits). Sidestep the trap entirely by
asking git for the tracking state directly:

```bash
git for-each-ref --format='%(refname:short)%09%(upstream:track)' refs/heads \
  | grep -F '[gone]' | cut -f1
```

`%(upstream:track)` renders a bare `[gone]` for a deleted upstream — no annotation nesting, no
color/format caveats — and `cut -f1` (tab-delimited by default) extracts the branch name without
awk positional tokens, which Skill-args substitution corrupts when this skill is invoked with args.

## 2. Inventory what's stale

```bash
echo "--- branches ---"; git branch -vv
echo "--- worktrees ---"; git worktree list
echo "--- remote branches ---"; gh api "repos/$REPO/branches" --paginate --jq '.[].name' | sort
```

For each non-default branch and each non-root worktree:

| Signal | Verdict |
|---|---|
| Local branch marked `[gone]` | Stale — remote deleted, safe to delete locally |
| Local `worktree-agent-*` isolation branch whose worktree is gone (no upstream, so never `[gone]`) | Orphan — a per-merge teardown removed only the worktree. `-D` if its tip is an ancestor of `origin/$DEFAULT_BRANCH` **or** a MERGED PR contains the tip (`gh api "repos/$REPO/commits/<tip>/pulls"`); neither → STOP and ask (possibly unmerged work) |
| Local branch tracks a remote that still exists | `gh pr list --repo "$REPO" --state all --search "head:<branch>"` → MERGED / CLOSED-not-merged = stale; OPEN = leave |
| Worktree SHA where `git merge-base --is-ancestor <sha> origin/$DEFAULT_BRANCH` is true | Stale — work is in the default branch |
| Worktree SHA NOT in the default branch | Investigate — possibly in-flight; do not remove without confirmation |
| Remote branch + merged PR | Stale — delete |
| Remote branch + CLOSED-not-merged PR | Stale — abandoned (often superseded). Delete local + remote |
| Remote branch + open PR | Leave alone |

**Squash-merge gotcha:** after a squash merge the feature-branch tip is *not* an ancestor of the
default branch — `git merge-base` reports it unmerged (false negative). Verify "shipped" via
`gh pr list ... MERGED`, which is why step 6 uses `-D`, not `-d`.

**Detached agent worktrees:** the Agent runtime's `isolation: "worktree"` checkouts (under
`.claude/worktrees/agent-*`) and Warp's agent worktrees are detached-HEAD (no branch) — they never
appear in `git branch -v` and never get `[gone]`. Remove them by path from `git worktree list`. (A
take-it run normally tears down its own; this catches crashed-coordinator orphans.)

**Orphan isolation branches:** newer Agent runtimes check each agent worktree out on a
`worktree-agent-<id>` **isolation branch** instead of detached HEAD. The agent's PR merges from its
feature branch, so the isolation branch never gets an upstream — when a per-merge teardown removes
the worktree directory, the leftover branch is neither sweepable by path (no worktree entry) nor
marked `[gone]` (no upstream to lose), and one orphan accumulates per merge (a 35-issue drain left
36 of them). Enumerate them explicitly — `git for-each-ref --format='%(refname:short)'
'refs/heads/worktree-agent-*'` — and classify each per the table row above. The ancestry check
alone is NOT enough: a tip at the pre-squash feature commit, or an orphan salvage commit superseded
by the PR that actually merged, is shipped yet not an ancestor — confirm via the MERGED-PR lookup
before `-D`, exactly like the squash-merge gotcha. Never touch one whose worktree is still present:
that is a live agent, and "no upstream" is its normal state, not a merged signal.

## 3. Triage stashes

Stashes survive branch deletion — `git stash` is independent of branch lifecycle, so today's stash
list is yesterday's WIP whose branch step 5/6 will nuke. Most are droppable; some are the only
artifact of a real implementation attempt.

```bash
git stash list
```

For each stash, gather signals first:

```bash
git stash show stash@{N} --stat          # files + line counts
git stash list --format='%gs' stash@{N}  # subject ("WIP on <branch>: <commit>")

# Extract any issue number from the subject / branch name (e.g. "issue-825-…"), then look it up.
# GitHub issues are OPEN or CLOSED, never "MERGED" — the "work shipped" signal lives on
# closedByPullRequestsReferences:
gh issue view <N> --repo "$REPO" --json number,state,title,closedByPullRequestsReferences 2>/dev/null
```

**Why `closedByPullRequestsReferences` is load-bearing:** an issue closes via `Closes #N` on a
*merged* PR — and that successor PR often has a different number than the branch that pre-stashed the
WIP. The PR linkage, not the issue's CLOSED state, tells you whether the work shipped (superseded —
drop) or was hand-closed as abandoned (the attempt may be the only artifact — ask).

### Auto-drop (no confirmation)

Drop if **any** is true:

- Subject references an issue whose `closedByPullRequestsReferences` contains a **MERGED** PR — work
  shipped via that successor; the stash is the superseded attempt. Strongest signal; don't
  second-guess on size.
- Stash content is empty (aborted `git stash push`).

OR if **all** are true (small-content fallback):

- < 5 lines changed (per `--stat`), AND
- the base branch in the subject is gone (no local match in `git branch --list`, no matching remote
  in `git ls-remote --heads`), AND
- no touched file matches the **dep/version-file globs** input.

Drop with `git stash drop stash@{N}` and announce: `dropped stash@{N} — <reason, e.g. "shipped via PR #830">`.

### Auto-keep (no confirmation)

- Subject references an **OPEN** issue (work likely still in flight on another branch).

### Ask (mixed signal)

After the auto checks clear the easy cases:

- CLOSED issue with **empty** `closedByPullRequestsReferences` (hand-closed = abandoned, not superseded).
- No extractable issue reference and content > 5 lines (orphan WIP worth a glance).
- Touches a dep/version/migration file AND the issue is CLOSED-with-empty-PR-references.

Present each as:

```
stash@{N} — taken on <branch> (gone) · <K> files / <L> lines · ref #<issue> (CLOSED-not-merged)
   touches: <top 3 paths>
   assessment: <one-line best guess>
   options: [d]rop · [s]how full diff · [k]eep · [a]pply to a new branch
```

Recover (option `a`) converts an orphan stash into a normal in-flight branch future runs track:

```bash
git stash branch wip/recover-stash-N stash@{N}   # creates branch + pops stash
git push -u origin wip/recover-stash-N            # surface as a draft PR if useful
```

## 4. Sweep untracked-file noise

Untracked (`??`) **and gitignored (`!!`)** files have NO git history — once `rm`'d they're gone.
Conservative defaults. Enumerate with `git clean`'s dry run in the root checkout AND each remaining
worktree:

```bash
git clean -ndx    # -n dry run, -d include directories, -x include gitignored
```

Each line reads `Would remove <path>`. **`-x` is the whole point** — `git ls-files --others
--exclude-standard` cannot see gitignored paths, so it structurally never returns `node_modules/`,
`tmp/`, or `scratch/`, and a sweep built on it announces success having removed nothing.

`-d` collapses each fully-untracked directory to its **outermost** entry: `node_modules/` rather
than every file under it, but also `e2e/` rather than the `e2e/out/results/` you cared about. A
collapsed entry can therefore bundle mixed contents — re-run `git clean -ndx` inside it to expand,
and never auto-discard a directory just because something under it matches the allowlist.

**Enumerate with `git clean -ndx`; remove with specific-path `rm`.** Do **not** "simplify" this to
`git clean -fdx -e <pattern>`: `-e` takes gitignore-style patterns, so an unanchored `-e results/`
matches `results/` at *every* depth — including `e2e/out/results/` — which shields the child and
therefore silently spares a parent that is on the discard list. (Anchored `-e /results/` protects
only the root copy, but the removal step here stays explicit `rm` per path so nothing hinges on
getting that anchoring right.)

### Auto-discard (no confirmation)

Universal noise allowlist, plus the caller's **noise allowlist** input:

- `.DS_Store`, `Thumbs.db`
- `*.swp`, `*.swo`, `*~`, `*.bak` (editor backups)
- `**/tmp/`, `**/scratch/`, `**/.tmp/`, `**/node_modules/`

Before removing any enumerated path, apply these two gates in order:

1. **Never-discard list wins over every allowlist entry.** With `-x` in play this guard is
   load-bearing rather than theoretical: the old enumeration could not see gitignored files, so
   nothing it returned could have been on the list. Now `.env.local` and friends — gitignored but
   precious (Neon branch URL, Vercel Blob token, OIDC) — really do show up. Skip them and say so:
   `kept <path> — never-discard`.
2. **An unlisted file is not an allowlisted one.** Only paths matching a pattern above (or the
   caller's noise allowlist) may go without confirmation; everything else `-x` newly surfaced —
   build output, caches, local tool state — gets enumerated and taken to the Ask prompt, not
   discarded by analogy. A live worktree checkout sitting under a gitignored path (e.g.
   `.claude/worktrees/`) is never sweep material either; step 5 owns those.

Then remove with `rm` and announce: `discarded <path> — <pattern>`.

### Ask

Everything else — untracked source files, markdown drafts, JSON exports, screenshots:

> **A screenshot reaching this bucket means something bypassed the sanctioned destination.**
> `tmp/` is where throwaway artifacts belong — it is in the universal allowlist above, so anything
> there is already swept without reaching a prompt, and `sassy-dog:setup-hooks` generates a guard
> that nudges Claude when one lands in the repo root instead. Treat a root-level screenshot here as
> the fallback path, not the normal one, and prefer `[g]itignore it` only after checking whether
> `tmp/` was the intended home.

```
<path> — <size> · <file type or first-line snippet>
   assessment: <best guess>
   options: [d]iscard · [s]tage as a separate PR · [g]itignore it · [k]eep untracked
```

`g` appends the path to `.gitignore` and stages it; `s` branches off, commits just that file, opens
a PR, then returns here.

## 5. Remove worktrees + 6. delete local branches + reconcile (delegated)

The agent-worktree teardown, squash-merge-aware local-branch deletion, ff-reconcile, and
origin-identical straggler clearing are exactly what `pr-shepherd`'s bundled `teardown.sh --sweep`
does (it encodes the same "remote branch gone = merged" rule). Reuse it rather than re-implementing:

```bash
DEFAULT_BRANCH="$DEFAULT_BRANCH" \
  bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/teardown.sh --sweep
```

`--sweep` removes every detached or remote-branch-gone agent worktree under `.claude/worktrees/`,
deletes their local branches **and** their `worktree-agent-*` isolation branches, sweeps orphan
isolation branches whose worktree is already gone (ancestor-of-default OR merged-PR classification;
genuinely unmerged ones are surfaced, never auto-deleted — and live ones, worktree still present,
are never touched), **and deletes ordinary `[gone]` local branches** — regular feature branches
with no checkout whose upstream was deleted on merge. That last phase used to be a hand-run
follow-up here, and its grep was a known silent-under-deletion trap (step 1's `: gone]` rendering);
now the script owns it, with the same guards the prose demands: never the default branch, never a
branch checked out in a live worktree, never a branch that is the base of an open PR (step 7's
base-branch guard — deleting a base closes its PR), and a failed open-PR lookup skips deletion
rather than proceeding unguarded. Everything held back is reported, and the `== residual ==` footer
counts swept vs held so "clean" means clean. The sweep also prunes, ff-reconciles the default
branch, and reports stashes but **never** drops them (step 3 owns that).

The one branch case `--sweep` does not cover: **squash-merged branches whose remote still exists**
(auto-delete off, or an API/web merge that skipped it). "Remote still there" reads as "PR likely
open", so the sweep rightly keeps them — that call needs a per-branch MERGED check
(`gh pr list --repo "$REPO" --state all --search "head:<branch>"`), a judgement, not a sweep:

```bash
# squash-merged but remote still exists — verify MERGED first, then -D (not -d):
git branch -D <branch>
```

For any stale worktree whose SHA you could **not** verify is in the default branch, STOP and ask —
that's potentially in-flight work, not debris. `cd` to the repo root before removing a worktree you
are standing in.

## 7. Delete stale remote branches

Normally a no-op when `delete_branch_on_merge=true`. When it isn't (API/web merge that skipped
auto-delete, or the setting was toggled off — investigate before mass-deleting):

```bash
gh pr list --repo "$REPO" --state merged --limit 50 --json headRefName --jq '.[].headRefName' \
  | sort -u > /tmp/merged-heads.txt
gh api "repos/$REPO/branches" --paginate --jq '.[].name' \
  | grep -v "^${DEFAULT_BRANCH}\$" | sort -u > /tmp/remote-branches.txt
comm -12 /tmp/remote-branches.txt /tmp/merged-heads.txt   # candidates
git push origin --delete <branch1> <branch2> ...
git fetch --prune
```

### Base-branch guard — subtract before deleting

**A branch that is the base of an OPEN PR must never be deleted, however merged it looks.** GitHub
closes a pull request outright when its base branch is deleted, so this turns a tidy-up into
destroying someone's open PR — and the "merged PR" signal above does not protect against it, because
the branch really did merge; something else is still pointing at it.

Stacked PRs make this routine rather than exotic: layer 1 merges, and until GitHub finishes
retargeting layer 2, layer 1's branch is still layer 2's base. But the guard is not stack-specific —
any hand-based PR (`gh pr create --base some-feature-branch`) has the same exposure.

Subtract the live bases from the candidate set:

```bash
gh pr list --repo "$REPO" --state open --limit 200 --json baseRefName \
  --jq '.[].baseRefName' | sort -u > /tmp/open-bases.txt
comm -12 /tmp/remote-branches.txt /tmp/merged-heads.txt \
  | comm -23 - /tmp/open-bases.txt          # candidates MINUS anything still a base

comm -12 /tmp/remote-branches.txt /tmp/merged-heads.txt \
  | comm -12 - /tmp/open-bases.txt          # what the guard held back — report these
```

Report anything the guard held back rather than dropping it silently — a merged branch that is still
a base means a stack is mid-landing, and that is worth seeing.

## 8. Clear orphan claim labels (only if a claim label was supplied)

A take-it-style claim label (e.g. `status:in-progress`) can be left behind when a coordinator crashes
after the work merged. For each open issue carrying the label:

```bash
gh issue list --repo "$REPO" --label "$CLAIM_LABEL" --state open --json number,closedByPullRequestsReferences
```

If its work already merged (`closedByPullRequestsReferences` has a MERGED PR) → remove the label.
When the repo uses the standard boardless taxonomy (`in-progress` from take-it/dispatch-ready), route the
removal through github-issues' claim script — it already wraps the mutation in `gh-retry.sh`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/issue-claim.sh release <N> --repo "$REPO"
```

For a non-standard claim label (e.g. `status:in-progress`), edit directly:

```bash
gh issue edit <N> --repo "$REPO" --remove-label "$CLAIM_LABEL"
```

Ask if the issue is genuinely open with no merged PR (work may truly be in-flight). Use the caller's
`gh-retry` wrapper for the direct mutation if one was supplied (GraphQL flakes).

## 9. Final verification

```bash
git branch -vv        # only the default branch
git worktree list     # only the root worktree
git stash list        # empty OR only kept "ask" stashes
git clean -ndx        # same enumeration step 4 used — see expected residue below
```

Verify with the **same `-ndx` enumeration step 4 swept with**, never
`git ls-files --others --exclude-standard`: a sweep that removed nothing verifies clean under the
blind command, which is exactly the failure this step exists to catch.

Expected residue from `git clean -ndx`: the never-discard entries, files kept at the Ask prompt, and
live worktree checkouts under gitignored paths. Anything else is either in-flight (intentional) or
got missed — re-run from step 2.

## Guardrails

- **Never delete a branch with an OPEN PR.** Check `gh pr list --repo "$REPO" --state all --search "head:<branch>"` when in doubt.
- **Never delete a branch that is the BASE of an open PR** — distinct from the rule above, and not covered by it. Deleting a base branch makes GitHub close the PR pointing at it, and a merged branch can still be a live base (a stack mid-landing, or any hand-based PR). Subtract the open-PR `baseRefName` set before deleting, and report what the guard held back.
- **Never delete a `worktree-agent-*` isolation branch whose worktree is still present** — that's a live agent checkout, not debris. Only isolation branches whose worktree is gone are sweep candidates, and unclassifiable ones (not an ancestor, no merged PR) are surfaced, not deleted.
- **Never `git worktree remove --force` a worktree at a SHA that isn't in the default branch** without confirming — potentially in-flight work.
- **Never auto-drop a stash referencing an OPEN issue.** Auto-drop is for confidently-shipped or confidently-abandoned work only.
- **Never auto-discard untracked or gitignored files outside the allowlist, and never anything in the never-discard list.** Neither has git history; asking too often costs a few prompts, auto-discarding wrong is unrecoverable. Enumerate with `git clean -ndx` and remove with specific-path `rm` — never `git clean -fdx -e <pattern>`, whose gitignore-style unanchored patterns match at every depth and silently spare on-list parents.
- **Issue state alone is not the "work shipped" signal — `closedByPullRequestsReferences` is.** CLOSED + merged PR → shipped (auto-drop). CLOSED + empty PR refs → hand-closed as abandoned (ask if non-trivial).
- **Dep/version/migration-file stashes only need confirmation when the issue was hand-closed** (no merged closer PR). A merged successor PR means the work shipped — auto-drop is correct.
- **Never delete the default branch (local or remote).**
- **Don't disable `delete_branch_on_merge`.** If lingering merged-PR branches appear on the remote, the setting may have been toggled off — re-enable it; the "remote branch gone = merged" logic depends on it.
- **Don't run inside a worktree you're about to remove** — `cd` to the repo root first.
