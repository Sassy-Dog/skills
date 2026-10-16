#!/usr/bin/env bash
#
# Batch teardown — remove a batch's agent worktrees + local branches and
# reconcile the default branch, so a parallel-shipping run leaves NO debris.
# Run after the coordinator merge loop, every batch.
#
# Usage:
#   teardown.sh <worktree_path> [<worktree_path> ...]   # explicit, from the batch manifest
#   teardown.sh --sweep                                  # every .claude/worktrees/agent-*
#                                                        #   whose upstream is [gone], or that is detached
#                                                        #   with its HEAD on another ref (either way
#                                                        #   clean, idle, unlocked), PLUS
#                                                        #   orphan isolation branches whose
#                                                        #   worktree is already gone, PLUS
#                                                        #   ordinary [gone] local branches
#                                                        #   (upstream deleted — guarded, below)
#   teardown.sh <worktree_path> ... --sweep              # BOTH, one call: the named paths are torn
#                                                        #   down first, then the sweep, then the
#                                                        #   shared prune/reconcile/residual tail
#   teardown.sh --reconcile-only                         # skip all worktree/branch phases; just
#                                                        #   the default-branch reconcile (switch,
#                                                        #   fetch --prune, clear ff-blocking
#                                                        #   stragglers, pull --ff-only) + report.
#                                                        #   A failed ff exits 1 in this mode
#                                                        #   (other modes warn and continue).
#                                                        #   EXCLUSIVE: combining it with paths or
#                                                        #   --sweep is a contradiction, rejected.
#
# Arguments are PRE-SCANNED (issue #200): flags are recognised wherever they
# appear — `--sweep` may precede or follow the paths — and any unrecognised
# -prefixed argument is rejected with one usage error and a non-zero exit BEFORE
# anything is torn down, rather than being taken for a worktree path.
# Env:
#   DEFAULT_BRANCH            override the reconcile target (default: origin/HEAD, fallback "main")
#   ISOLATION_BRANCH_PREFIX   prefix of the Agent runtime's isolation branches
#                             (default "worktree-agent-")
#
# Why "upstream [gone]" (never mere "no remote branch" — see #546 below), not `git branch --merged`:
#   Squash-merged feature branches' tips are NOT ancestors of the default branch
#   — `git branch --merged` reports them UNMERGED (false negative). As long as
#   merges delete the remote branch (delete_branch_on_merge, or the merge queue's
#   own deletion), "origin no longer has this branch" is the reliable merged signal.
#
# Isolation branches (issue #26): the Agent runtime checks each agent worktree out
# on a worktree-agent-<id> branch. The PR merges from the agent's FEATURE branch,
# so the isolation branch never gets an upstream — never [gone], and once the
# worktree directory is torn down there is no path to sweep either; one orphan
# accumulates per merge. So: removing a worktree here ALSO deletes its isolation
# branch (prevention), and --sweep classifies leftover orphans (worktree gone) by
# default-branch ancestry OR a MERGED PR containing the tip (squash-merge
# false-negative safe); genuinely unmerged ones are surfaced, never auto-deleted.
# Isolation branches whose worktree is still present are not swept by inference
# ("no upstream" is their normal state, not a merged signal), but a branch is
# still JUDGED once its worktree has switched to a feature branch or detached: the
# orphan phase tests only branch_in_live_worktree. Judged by ancestry or merged PR;
# never deleted while unmerged. Sweep-driven worktree removals do not delete the
# isolation branch themselves (#557) — the orphan phase does, on that evidence.
#
# Ordinary [gone] branches (issue #85): a plain feature branch — an ordinary
# send-it flow — has no agent worktree and no isolation prefix, so neither sweep
# phase above ever enumerates it; five accumulated in this repo while the residual
# report read "clean". --sweep therefore also enumerates refs/heads for a bare
# [gone] in %(upstream:track). (NOT `git branch -vv`, whose rendering nests the
# token as `[origin/x: gone]` — grepping THAT output for '[gone]' matches nothing;
# the known trap.) Deletion is -D, not -d: squash-merged tips are not ancestors of
# the default branch (see above). Guards: never the default branch; never a branch
# a live worktree has checked out; never a branch that is the base of an OPEN PR
# (GitHub closes a PR outright when its base branch is deleted — a merged branch
# can still be a live base, e.g. a stack mid-landing); and if the open-PR lookup
# fails, deletion is SKIPPED rather than run unguarded (same stance as
# merge-shepherd.sh's inconclusive stack probe: unknown means wait, not act).
#
# Worktrees are removed with `-f -f`, which overrides a lock and a dirty tree. A
# lock is treated as a live agent, a conservative policy (an observation recorded
# on #546, 2026-10-16: a finished worker's worktree was unlocked while two running
# workers' worktrees stayed locked); a lock left behind by a crashed agent needs an
# explicit path. The override applies to
# EXPLICIT paths only; --sweep never infers it (#546): a feature-branch worktree
# is swept only if its upstream existed and is now [gone] AND its tree is clean AND
# no git operation (rebase, merge, cherry-pick, revert, bisect, sequencer) is under
# way AND it is not locked; a branch with no upstream (never pushed), a dirty
# tree, an operation in progress or a lock is KEPT and reported, because a live
# worker that switched branches but has not pushed looks exactly like a merged one
# otherwise. A detached worktree gets the same live-worker guards (a paused rebase
# is detached). Fail-closed KEEPs (unknown is not verified): an unreadable HEAD,
# status, git dir or worktree list, and a reachability query that returns nothing.
# A detached worktree is also swept only if its HEAD is reachable from a branch, tag
# or remote ref other than an isolation branch (removal deletes that one): commits
# made on a detached HEAD lose their only anchor (and the per-worktree reflog)
# when the worktree goes. Accepted, predating #546: a clean, unlocked [gone]
# branch worktree holding local commits made after the merge is still swept (-D).
# Stashes are reported but NEVER auto-dropped (destructive — human's call).
#
# Checkout guard (#486): every mode below mutates the local checkout (worktree
# removal, branch deletion, a switch, a fast-forward). A serial worker may be
# running under a checkout guard (checkout-guard.sh, beside this script), so
# BEFORE the first mutation this script runs `checkout-guard.sh check`. Exit 0
# (no guard, or the guard is held/completed and SASSY_DOG_CHECKOUT_TOKEN, read
# from the environment, matches it) proceeds exactly as before. Anything else
# performs NO local mutation, prints the check's one JSON line (guard path and
# ownership) and exits 7. A check that cannot run is a refusal too: unknown is
# not verified. Claude Code with no guard present behaves as it always did.
# Exit codes: 0 done · 1 not in a repo / failed --reconcile-only ff · 2 usage ·
#             7 refused by the checkout guard (nothing was touched).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$ROOT" ] && { echo "teardown: not in a git repo" >&2; exit 1; }
cd "$ROOT" || { echo "teardown: cannot cd to $ROOT" >&2; exit 1; }

BRANCH="${DEFAULT_BRANCH:-$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}"
[ -z "$BRANCH" ] && BRANCH=main

ISO_PREFIX="${ISOLATION_BRANCH_PREFIX:-worktree-agent-}"

branch_in_live_worktree() {  # $1 = branch — true if ANY worktree has it checked out
  # Captured first, never piped into `grep -q`: under this script's pipefail,
  # grep -q closes the pipe on its first match, git takes SIGPIPE and pipefail
  # promotes the 141 — so a MATCH would read as a MISS (issue #172 / #256) and
  # this guard would clear a branch a live worktree still has checked out. An
  # unreadable worktree list still answers "no" here, as the pipeline did.
  local wts
  wts="$(git worktree list --porcelain)"
  grep -qxF "branch refs/heads/$1" <<<"$wts"
}

worktree_locked() {  # $1 = worktree path — true if `git worktree list --porcelain` marks it locked
  # Captured first (never a pipe into grep -q; see branch_in_live_worktree). An
  # unreadable list answers "locked": unknown is not verified, so the sweep keeps it.
  local wts
  wts="$(git worktree list --porcelain)" || return 0
  awk -v p="$1" '
    /^worktree / { cur = substr($0, 10); next }
    /^locked/    { if (cur == p) found = 1 }
    END          { exit !found }' <<<"$wts"
}

worktree_op_in_progress() {  # $1 = worktree path — true if a rebase/merge/cherry-pick/revert/bisect is under way
  # An unreadable git dir answers "in progress": unknown is not verified.
  local gd
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  [ -n "$gd" ] || return 0
  local f
  # sequencer outlives CHERRY_PICK_HEAD: a multi-commit pick/revert stopped on a
  # conflict and then committed by hand leaves a clean tree with only this behind.
  for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    [ -e "$gd/$f" ] && return 0
  done
  return 1
}

detached_head_reachable() {  # $1 = worktree path — true if a branch, tag or remote ref OTHER than an isolation branch contains its HEAD
  # Isolation branches (refs/heads/$ISO_PREFIX*) never count: removing the worktree
  # deletes its own isolation branch (remove_worktree -> delete_isolation_branch),
  # so that ref cannot vouch for commits it is about to lose. Their lifecycle
  # belongs to the orphan phase. A failed query prints nothing, and empty output
  # is "not reachable" below: that is the only fail-closed signal here.
  local refs r
  refs="$(git -C "$1" for-each-ref --contains HEAD --format='%(refname)' refs/heads refs/remotes refs/tags 2>/dev/null)"
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$r" in "refs/heads/$ISO_PREFIX"*) continue ;; esac
    return 0
  done <<<"$refs"
  return 1  # no other ref contains HEAD, or the query failed
}

# The shared "is a live worker in here" guards for --sweep: returns 0 only when
# the worktree may be swept. Prints the KEEP line and returns 1 otherwise.
sweep_live_guard() {  # $1 = path  $2 = label for the KEEP line
  local path="$1" label="$2" dirty
  # --untracked-files=all / --ignore-submodules=none: a repo's own
  # status.showUntrackedFiles=no or diff.ignoreSubmodules must not hide work.
  if ! dirty="$(git -C "$path" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)"; then
    echo "  KEEP (could not read the worktree status — unknown is not clean; pass its path explicitly if debris): $path $label"
    return 1
  fi
  if [ -n "$dirty" ]; then
    echo "  KEEP (uncommitted changes or untracked files — pass its path explicitly if debris): $path $label"
    return 1
  fi
  if worktree_op_in_progress "$path"; then
    echo "  KEEP (a git operation (rebase, merge, cherry-pick, revert, bisect) is in progress — a live worker; pass its path explicitly if debris): $path $label"
    return 1
  fi
  if worktree_locked "$path"; then
    echo "  KEEP (worktree is locked — a live agent holds it; pass its path explicitly if debris): $path $label"
    return 1
  fi
  return 0
}

# Delete an isolation branch left behind by its worktree. No-op unless the name
# matches the isolation prefix; never the default branch; never a branch a live
# worktree has checked out.
delete_isolation_branch() {  # $1 = candidate branch name (may be empty / non-isolation)
  local br="$1"
  [ -n "$br" ] || return 0
  case "$br" in "$ISO_PREFIX"*) : ;; *) return 0 ;; esac
  [ "$br" = "$BRANCH" ] && return 0
  git show-ref --verify --quiet "refs/heads/$br" || return 0
  if branch_in_live_worktree "$br"; then
    echo "    KEEP isolation branch $br (checked out by a live worktree)"; return 0
  fi
  git branch -D "$br" >/dev/null 2>&1 && echo "    deleted isolation branch $br" \
    || echo "    ⚠ could not delete isolation branch $br"
}

remove_worktree() {  # $1 = worktree path  $2 = "sweep" when the removal is sweep-driven
  # Sweep-driven removals NEVER delete the isolation branch (#557): the sweep's
  # evidence vets the worktree's HEAD, not that branch's own tip, which may hold
  # the only copy of unmerged commits. The orphan phase, right after the worktree
  # loop in the same call, judges it by ancestry or a MERGED PR. Explicit-path
  # teardown (no $2) keeps deleting it: the caller named the path as debris.
  local path="$1" br iso from_sweep=0
  [ "${2:-}" = "sweep" ] && from_sweep=1
  # The isolation branch the runtime created this worktree on (worktree-<dirname>).
  # Derived from the PATH, not the checkout: if the agent switched to a feature
  # branch, `branch --show-current` no longer names it — yet it still exists and
  # would otherwise be orphaned (issue #26).
  iso="worktree-$(basename "$path")"
  if [ ! -d "$path" ]; then
    echo "  (already gone) $path"
    [ "$from_sweep" = "1" ] || delete_isolation_branch "$iso"
    return
  fi
  br="$(git -C "$path" branch --show-current 2>/dev/null || true)"
  if git worktree remove -f -f "$path" 2>/dev/null; then
    echo "  removed worktree $path${br:+ [$br]}"
  else
    echo "  ⚠ could not remove $path (still locked / dirty?)"; return
  fi
  if [ -n "$br" ]; then
    git branch -D "$br" >/dev/null 2>&1 && echo "    deleted local branch $br" || true
  fi
  if [ "$from_sweep" = "1" ]; then
    echo "    isolation branch $iso left to the orphan phase (sweep never deletes it unjudged)"
  elif [ "$iso" != "$br" ]; then
    delete_isolation_branch "$iso"
  fi
}

RECONCILE_ONLY=0
SWEEP_MODE=0        # set by --sweep; gates the [gone]-phase counts in the residual report
GONE_SWEPT=0        # [gone] branches deleted by the sweep
GONE_HELD=0         # [gone] branches held back by a guard (reported, never silent)
PATHS=()

usage() {
  cat >&2 <<'EOF'
usage: teardown.sh [<worktree_path> ...] [--sweep]
       teardown.sh --reconcile-only

  <worktree_path> ...  tear these worktrees down explicitly (the batch manifest)
  --sweep              reclaim every agent worktree that is clean, unlocked and mid no git
                       operation AND either has an upstream that is [gone] or is detached
                       with its HEAD reachable from a non-isolation ref (others are KEPT),
                       orphan isolation branches, and ordinary [gone] branches
  --reconcile-only     ONLY reconcile the default branch — exclusive, never
                       combined with paths or --sweep

Paths and --sweep combine in a single call, in any order: the named paths are
torn down first, then the sweep, then the shared prune/reconcile/residual tail.
EOF
}

# Pre-scan EVERY argument before anything is torn down. Flags are positional-
# agnostic, and an unrecognised -prefixed argument stops the run here instead of
# being taken for a worktree path (issue #200: `--sweep` trailing two paths was
# handed to `basename`, which rejected the leading `-` with its own usage dump
# — mid-run, after both worktrees were gone, and before the sweep that then
# never ran at all).
for arg in "$@"; do
  case "$arg" in
    --sweep)          SWEEP_MODE=1 ;;
    --reconcile-only) RECONCILE_ONLY=1 ;;
    -*) echo "teardown: unrecognised option '$arg' (nothing was torn down)" >&2; usage; exit 2 ;;
    *)  PATHS+=("$arg") ;;
  esac
done

if [ "$RECONCILE_ONLY" = "1" ] && { [ "$SWEEP_MODE" = "1" ] || [ "${#PATHS[@]}" -gt 0 ]; }; then
  echo "teardown: --reconcile-only skips every worktree/branch phase, so it cannot be combined with worktree paths or --sweep (nothing was torn down); run them as separate invocations" >&2
  exit 2
fi

if [ "$RECONCILE_ONLY" = "0" ] && [ "$SWEEP_MODE" = "0" ] && [ "${#PATHS[@]}" -eq 0 ]; then
  echo "teardown: pass worktree path(s), --sweep, or --reconcile-only" >&2; usage; exit 2
fi

GUARD_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checkout-guard.sh"
if ! GUARD_JSON="$(bash "$GUARD_SCRIPT" check --repo "$ROOT" 2>&1)"; then
  echo "teardown: refused by the checkout guard — no local mutation was made" >&2
  echo "  $GUARD_JSON" >&2
  echo "  where the guard could be read the JSON names its path and ownership; the holder scopes SASSY_DOG_CHECKOUT_TOKEN to this call, anyone else follows skills/take-it/references/isolation-confirmation.md" >&2
  exit 7
fi

if [ "${#PATHS[@]}" -gt 0 ]; then
  echo "== explicit teardown of ${#PATHS[@]} worktree(s) =="
  for path in "${PATHS[@]}"; do remove_worktree "$path"; done
fi

if [ "$SWEEP_MODE" = "1" ]; then
  echo "== sweep: agent worktrees whose upstream was deleted ([gone]; squash-merged + deleted), clean, idle, unlocked; or detached with a reachable HEAD =="
  git fetch --prune --quiet origin 2>/dev/null || true
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    # symbolic-ref tells a real detached HEAD (exit 1) from a git error (anything
    # else), which `branch --show-current || true` could not: both read as an
    # empty name. An error is unknown, and unknown is KEPT, never swept (#546).
    ref="$(git -C "$path" symbolic-ref -q HEAD 2>/dev/null)"; ref_rc=$?
    if [ "$ref_rc" -ne 0 ] && [ "$ref_rc" -ne 1 ]; then
      echo "  KEEP (could not read the worktree HEAD — unknown is not detached; pass its path explicitly if debris): $path"
      continue
    fi
    br="${ref#refs/heads/}"
    if [ -z "$br" ]; then
      # Detached HEAD: no branch evidence to weigh, so only the live-worker guards
      # apply (readable+clean tree, no rebase/merge/cherry-pick/revert/bisect/sequencer, unlocked)
      # plus a HEAD reachable from a non-isolation ref.
      # A paused rebase is detached too, and is exactly a live worker.
      sweep_live_guard "$path" "(detached)" || continue
      if ! detached_head_reachable "$path"; then
        echo "  KEEP (detached HEAD is not reachable from any branch, tag or remote ref — removing it would lose its commits; pass its path explicitly if debris): $path (detached)"
        continue
      fi
      echo "  detached → removing: $path"; remove_worktree "$path" sweep; continue
    fi
    case "$br" in
      "$ISO_PREFIX"*)
        # Still checked out on its isolation branch: possibly a LIVE agent that has
        # not branched yet. "No remote" is this branch's NORMAL state — not a merged
        # signal — so never sweep it by inference; pass the path explicitly if it's
        # known debris (crashed run).
        echo "  KEEP (live isolation worktree — pass its path explicitly if debris): $path [$br]"
        continue ;;
    esac
    # A feature branch is "merged" only on POSITIVE evidence (#546): it had an
    # upstream and that upstream is now [gone]. "No remote branch" is also the
    # state of a live worker that switched to its feature branch and has not
    # pushed yet, so it proves nothing. Each of these is sufficient to KEEP:
    # never pushed, upstream not [gone], and (in sweep_live_guard) unreadable or
    # dirty tree, an operation in progress, a locked worktree.
    upstream="$(git for-each-ref --format='%(upstream)' "refs/heads/$br" 2>/dev/null || true)"
    track="$(git for-each-ref --format='%(upstream:track)' "refs/heads/$br" 2>/dev/null || true)"
    if [ -z "$upstream" ]; then
      echo "  KEEP (branch has no upstream — never pushed, a live worker's normal state; pass its path explicitly if debris): $path [$br]"
      continue
    fi
    if [ "$track" != "[gone]" ]; then
      echo "  KEEP (remote branch still exists, PR likely open): $path [$br]"
      continue
    fi
    sweep_live_guard "$path" "[$br]" || continue
    echo "  gone/merged: $path [$br]"; remove_worktree "$path" sweep
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}' | grep "/.claude/worktrees/" || true)

  echo "== sweep: orphan ${ISO_PREFIX}* isolation branches (worktree gone — never [gone]) =="
  # Left behind when a per-merge teardown removed the worktree but not the branch
  # (pre-#26 flows, crashed runs). Ancestry alone is NOT enough: a squash-merge
  # leaves the pre-squash tip dangling (same false negative as feature branches),
  # so a non-ancestor tip is checked against MERGED PRs before deciding.
  REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  while read -r br tip; do
    [ -z "$br" ] && continue
    [ "$br" = "$BRANCH" ] && continue
    if branch_in_live_worktree "$br"; then
      echo "  KEEP $br (worktree still present — live)"; continue
    fi
    if git merge-base --is-ancestor "$tip" "origin/$BRANCH" 2>/dev/null; then
      git branch -D "$br" >/dev/null 2>&1 && echo "  deleted $br (tip already in origin/$BRANCH)"
      continue
    fi
    merged_pr=""
    [ -n "$REPO_SLUG" ] && merged_pr="$(gh api "repos/$REPO_SLUG/commits/$tip/pulls" \
      --jq '[.[] | select(.merged_at != null)][0].number // empty' 2>/dev/null || true)"
    if [ -n "$merged_pr" ]; then
      git branch -D "$br" >/dev/null 2>&1 && echo "  deleted $br (shipped via merged PR #$merged_pr)"
    else
      echo "  ⚠ KEEP $br — tip ${tip:0:7} not in origin/$BRANCH and no merged PR contains it; possibly unmerged work — review by hand"
    fi
  done < <(git for-each-ref --format='%(refname:short) %(objectname)' "refs/heads/${ISO_PREFIX}*" || true)

  echo "== sweep: ordinary [gone] local branches (upstream deleted — no worktree needed) =="
  # Feature branches from non-worktree flows (send-it): upstream deleted on merge,
  # never seen by either phase above. Enumerated via %(upstream:track)'s bare
  # [gone] — not `git branch -vv`'s nested rendering (see header).
  GONE_LIST="$(git for-each-ref --format='%(refname:short)%09%(upstream:track)' refs/heads \
    | grep -F '[gone]' | cut -f1 || true)"
  if [ -z "$GONE_LIST" ]; then
    echo "  (none)"
  else
    # Guard 3 input (one call for the whole phase): branches that are the BASE of
    # an open PR. Deleting a base branch closes its PR outright, and "merged"
    # does not protect against it — the branch really did merge; something else
    # still points at it (stack mid-landing, or any hand-based PR).
    BASES_OK=0
    if OPEN_BASES="$(gh pr list --state open --limit 200 --json baseRefName \
        --jq '.[].baseRefName' 2>/dev/null)"; then
      BASES_OK=1
    fi
    while IFS= read -r br; do
      [ -z "$br" ] && continue
      # Isolation-prefix branches belong to the orphan phase above — its verdict
      # (including "surfaced, review by hand") stands; never re-judged here.
      case "$br" in "$ISO_PREFIX"*) continue ;; esac
      if [ "$br" = "$BRANCH" ]; then
        echo "  KEEP $br (default branch — never deleted)"; GONE_HELD=$((GONE_HELD+1)); continue
      fi
      if branch_in_live_worktree "$br"; then
        echo "  KEEP $br (checked out by a live worktree)"; GONE_HELD=$((GONE_HELD+1)); continue
      fi
      if [ "$BASES_OK" != "1" ]; then
        echo "  ⚠ KEEP $br — open-PR base lookup failed (gh offline?); skipping deletion rather than deleting unguarded — re-run when gh works"
        GONE_HELD=$((GONE_HELD+1)); continue
      fi
      if printf '%s\n' "$OPEN_BASES" | grep -qxF "$br"; then
        echo "  KEEP $br (base of an OPEN PR — deleting it would close that PR)"; GONE_HELD=$((GONE_HELD+1)); continue
      fi
      if git branch -D "$br" >/dev/null 2>&1; then
        echo "  deleted $br (upstream gone)"; GONE_SWEPT=$((GONE_SWEPT+1))
      else
        echo "  ⚠ could not delete $br"; GONE_HELD=$((GONE_HELD+1))
      fi
    done <<< "$GONE_LIST"
  fi
fi

[ "$RECONCILE_ONLY" = "1" ] || git worktree prune

echo "== reconcile $BRANCH =="
git switch "$BRANCH" >/dev/null 2>&1 || true
git fetch origin "$BRANCH" --prune --quiet
# Clear cwd-reset stragglers: untracked files that are now TRACKED on origin/<branch>
# AND byte-identical there (so nothing is lost) — these block the ff otherwise.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if git cat-file -e "origin/$BRANCH:$f" 2>/dev/null && git show "origin/$BRANCH:$f" 2>/dev/null | diff -q - "$f" >/dev/null 2>&1; then
    rm -f "$f" && echo "  cleared straggler (identical to origin/$BRANCH): $f"
  fi
done < <(git ls-files --others --exclude-standard || true)
if git pull --ff-only origin "$BRANCH" >/dev/null 2>&1; then
  echo "  $BRANCH @ $(git rev-parse --short HEAD)"
else
  echo "  ⚠ ff-only reconcile failed — residual local changes; clean up by hand"
  # In --reconcile-only mode the ff IS the job — surface the failure to the caller.
  # Explicit/sweep modes keep warn-and-continue: teardown already did its real work.
  [ "$RECONCILE_ONLY" = "1" ] && exit 1
fi

echo "== residual =="
RW=$(git worktree list | grep -c "/.claude/worktrees/" || true)
echo "  agent worktrees remaining: $RW"
[ "$SWEEP_MODE" = "1" ] && echo "  [gone] branches: swept $GONE_SWEPT, held back $GONE_HELD"
GB=$(git for-each-ref --format='%(upstream:track)' refs/heads | grep -cF '[gone]' || true)
[ "$GB" != "0" ] && echo "  ⚠ $GB [gone] branch(es) remaining — held back or unswept; see above (or run --sweep)"
IB=$(git for-each-ref --format='%(refname:short)' "refs/heads/${ISO_PREFIX}*" | wc -l | tr -d ' ')
[ "$IB" != "0" ] && echo "  ⚠ $IB isolation branch(es) (${ISO_PREFIX}*) remaining — live or unmerged; see above"
SL=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
[ "$SL" != "0" ] && echo "  ⚠ $SL stash(es) present — teardown does NOT auto-drop; review by hand"
exit 0
