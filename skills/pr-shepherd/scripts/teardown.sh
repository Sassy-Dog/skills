#!/usr/bin/env bash
#
# Batch teardown — remove a batch's agent worktrees + local branches and
# reconcile the default branch, so a parallel-shipping run leaves NO debris.
# Run after the coordinator merge loop, every batch.
#
# Usage:
#   teardown.sh <worktree_path> [<worktree_path> ...]   # explicit, from the batch manifest
#   teardown.sh --sweep                                  # every .claude/worktrees/agent-*
#                                                        #   whose remote branch is gone, PLUS
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
# Why "remote branch gone", not `git branch --merged`:
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
# Isolation branches whose worktree is still present are LIVE agents — --sweep
# never touches them ("no upstream" is their normal state, not a merged signal).
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
# Worktrees are removed with `-f -f` because the Agent runtime leaves them locked.
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

remove_worktree() {  # $1 = worktree path
  local path="$1" br iso
  # The isolation branch the runtime created this worktree on (worktree-<dirname>).
  # Derived from the PATH, not the checkout: if the agent switched to a feature
  # branch, `branch --show-current` no longer names it — yet it still exists and
  # would otherwise be orphaned (issue #26).
  iso="worktree-$(basename "$path")"
  if [ ! -d "$path" ]; then
    echo "  (already gone) $path"
    delete_isolation_branch "$iso"
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
  if [ "$iso" != "$br" ]; then delete_isolation_branch "$iso"; fi
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
  --sweep              reclaim every agent worktree whose remote branch is gone,
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
  echo "  the JSON names the guard path and its ownership; the holder exports SASSY_DOG_CHECKOUT_TOKEN, anyone else follows skills/take-it/references/isolation-confirmation.md" >&2
  exit 7
fi

if [ "${#PATHS[@]}" -gt 0 ]; then
  echo "== explicit teardown of ${#PATHS[@]} worktree(s) =="
  for path in "${PATHS[@]}"; do remove_worktree "$path"; done
fi

if [ "$SWEEP_MODE" = "1" ]; then
  echo "== sweep: agent worktrees whose remote branch is gone (squash-merged + deleted) =="
  git fetch --prune --quiet origin 2>/dev/null || true
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    br="$(git -C "$path" branch --show-current 2>/dev/null || true)"
    if [ -z "$br" ]; then echo "  detached → removing: $path"; remove_worktree "$path"; continue; fi
    case "$br" in
      "$ISO_PREFIX"*)
        # Still checked out on its isolation branch: possibly a LIVE agent that has
        # not branched yet. "No remote" is this branch's NORMAL state — not a merged
        # signal — so never sweep it by inference; pass the path explicitly if it's
        # known debris (crashed run).
        echo "  KEEP (live isolation worktree — pass its path explicitly if debris): $path [$br]"
        continue ;;
    esac
    if git ls-remote --exit-code --heads origin "$br" >/dev/null 2>&1; then
      echo "  KEEP (remote branch still exists, PR likely open): $path [$br]"
    else
      echo "  gone/merged: $path [$br]"; remove_worktree "$path"
    fi
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
