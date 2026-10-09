#!/usr/bin/env bash
# merge-shepherd.sh — stateless, idempotent single-writer merge step for ONE PR.
#
# Why this exists: the bundled pollers (poll-prs.sh, poll-queue.sh) are
# read-only WATCHERS — all writes stay with the coordinating session. But the
# write step is where long-lived sessions die: on a memory-pressured host,
# macOS memorystatus/jetsam reaps idle long-lived loops at aperiodic intervals,
# and a babysitting session dies mid-merge needing manual re-launch. This
# script inverts that: every run is a SHORT, STATELESS "advance one step"
# against live GitHub state, so a kill mid-run costs nothing — just run it
# again. Under a merge queue, the enqueue keeps the merge itself server-side
# and kill-proof; this adds resilient enqueue + confirmation + teardown.
#
# One step per run: mergeable check → red/pending gate → staleness gate
# (`--direct` only) → enqueue via GraphQL enqueuePullRequest (or `--direct`
# squash-merge) → GraphQL isInMergeQueue confirmation → teardown + ff-only
# default-branch reconcile.
#
# Usage:
#   merge-shepherd.sh <pr> [--repo owner/name] [--worktree <path>] [--direct]
#                     [--watch <secs>] [--poll <secs>] [--allow-no-checks]
#   Single-shot by default (advances one step, exits). --watch N polls up to N
#   seconds (keep N under the host's kill window, e.g. 240) then exits cleanly.
#   --direct: for repos WITHOUT a merge queue — squash-merge + --delete-branch
#   instead of enqueueing. Default is queue mode (GraphQL enqueuePullRequest;
#   `gh pr merge --auto` only as a fallback when the mutation errors).
#   --allow-no-checks: merge even when the PR reports ZERO checks in a repo that
#   demonstrably runs CI on pull requests (see the empty-rollup trap below).
#   Repo defaults to the cwd checkout (gh repo view); --repo overrides.
#
# Env:
#   DEFAULT_BRANCH   reconcile target (default: origin/HEAD, fallback "main")
#                    — same contract as teardown.sh
#   ISOLATION_BRANCH_PREFIX   prefix of the Agent runtime's isolation branches
#                    (default "worktree-agent-") — same contract as teardown.sh
#
# Exit codes: 0 merged(+teardown) · 10 enqueued · 11 waiting/in-flight, or a
#             stale branch that was just updated (re-run)
#             · 20 red checks · 21 no checks reported where CI is expected
#             (re-run) · 22 conflicting · 23 blocked by a lower stack layer
#             (re-run) · 24 stacked under a merge queue (needs a human)
#             · 1 usage/error/closed
#   The post-merge local teardown first runs checkout-guard.sh `check` (#486): a
#   refusal skips the local mutations, is reported, and never changes these codes.
#
# ENQUEUE PRIMITIVE: the GraphQL `enqueuePullRequest` mutation (PR node id
# resolved in-script), NOT `gh pr merge --auto`. Some queue configurations
# reject EVERY `gh pr merge` flag including `--auto` ("auto merge is not
# allowed") — on such repos the CLI call can never enqueue, the isInMergeQueue
# confirm reads false, and every pass exits 11 forever. The mutation sidesteps
# the flag matrix entirely (schema-verified: EnqueuePullRequestInput's only
# required field is pullRequestId). `gh pr merge --auto` (NO method flag) is
# retained only as a fallback when the mutation itself errors. The stateless
# eject re-enqueue path (see the queue-ejects note below) reuses the same
# primitive.
#
# EMPTY-ROLLUP TRAP: the merge condition is `mergeStateStatus == CLEAN AND no
# pending checks` — and BOTH are satisfied when there are no checks at all.
# GitHub reports CLEAN whenever nothing blocks the merge, and a base branch
# with no required checks blocks nothing. So a PR targeting an unprotected
# branch (any intermediate chained/stacked PR) reads exactly like a fully green
# one. "No checks reported" and "CI has not started yet" are also
# indistinguishable from the rollup alone. Observed live 2026-08-06: during an
# Actions outage three chained PRs reported CLEAN with zero checks.
#
# A blanket "refuse on zero checks" would break every repo that legitimately
# has no CI, so the gate asks whether THIS repo runs CI on pull requests at all
# (`actions/runs?event=pull_request` total_count) and only refuses when it
# does. Override with --allow-no-checks.
#
# STALE-BRANCH TRAP (--direct only): CLEAN means "no textual conflict" and
# nothing more — it is NOT evidence CI ran against the current base. A PR whose
# checks went green days ago still reports CLEAN while many merges stale, and
# merging it reddens the default branch on the spot. "Require branches to be up
# to date before merging" is a SEPARATE branch-protection setting from "require
# status checks" and is off by default, so required checks alone do not cover
# this; repos without protection at all have nothing. A merge queue DOES cover
# it (the queue rebuilds each entry against the current base), so the gate runs
# on the direct path only. behind_by() answers it with one compare call — no
# checkout, stateless. Behind the base -> `gh pr update-branch` + exit 11: the
# checks re-run against the new base and the next invocation merges. An UNKNOWN
# behind-count proceeds rather than stalling a healthy merge — unlike the
# empty-rollup and stack gates, the failure mode here is a re-run, and the
# update-branch write is the recovery, so a probe outage must not wedge it.
#
# STACKED PRs: a middle layer of a stack reads green + MERGEABLE + CLEAN
# exactly like an ordinary PR, so without a gate this writer would merge layer
# 3 into layer 2's branch while layer 1 is still open. sibling stack-probe.sh
# supplies `lower_open`; a non-empty one stops the merge with exit 23. Stacks
# merge bottom-up, one layer per run — that is already this script's contract.
#
# SINGLE-WRITER CONTRACT: one owner per PR. Never point this writer and a
# watcher session — or two writers — at the same PR from different sessions.
#
# NOTE on queue ejects: a stateless run cannot distinguish "ejected from the
# queue" from "never enqueued" (head-commit checks stay green either way), so
# an ejected-but-CLEAN PR is simply re-enqueued on the next pass — the right
# recovery for transient/false ejects. A PR that keeps failing merge_group
# checks on the rebased ref will ping-pong; that needs a human (rebase +
# regenerate — see references/merge-queue.md "Eject recovery", and
# poll-queue.sh for eject-aware watching).
#
# Requires the sibling gh-retry.sh (transient/non-transient retry split) —
# copy both files together if lifting this script out of the plugin.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_RETRY="$SCRIPT_DIR/gh-retry.sh"
STACK_PROBE="$SCRIPT_DIR/stack-probe.sh"

REPO=""; PR=""; WT=""; WATCH=0; POLL=30; DIRECT=0; ALLOW_NO_CHECKS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --worktree) WT="$2"; shift 2 ;;
    --watch) WATCH="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --direct) DIRECT=1; shift ;;
    --allow-no-checks) ALLOW_NO_CHECKS=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [ -z "$PR" ]; then PR="$1"; shift; else echo "unexpected arg: $1" >&2; exit 1; fi ;;
  esac
done
[ -n "$PR" ] || { echo "usage: merge-shepherd.sh <pr> [--repo o/n] [--worktree p] [--direct] [--watch s] [--poll s] [--allow-no-checks]" >&2; exit 1; }
case "$PR" in *[!0-9]*|'') echo "PR must be numeric, got: $PR" >&2; exit 1 ;; esac
case "$WATCH" in *[!0-9]*|'') echo "--watch must be numeric, got: $WATCH" >&2; exit 1 ;; esac
case "$POLL" in *[!0-9]*|'') echo "--poll must be numeric, got: $POLL" >&2; exit 1 ;; esac

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  [ -n "$REPO" ] || { echo "error: not in a GitHub repo and --repo not given" >&2; exit 1; }
fi
case "$REPO" in */*) : ;; *) echo "error: repo must be owner/name, got: $REPO" >&2; exit 1 ;; esac
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

# The MAIN worktree is the first entry of `git worktree list` — NOT
# --show-toplevel, which returns the linked worktree when invoked from inside
# one (teardown would then no-op against the dir it's removing).
MAIN_WT="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
BRANCH="${DEFAULT_BRANCH:-$(git -C "${MAIN_WT:-.}" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')}"
[ -z "$BRANCH" ] && BRANCH=main

ISO_PREFIX="${ISOLATION_BRANCH_PREFIX:-worktree-agent-}"
GUARD_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checkout-guard.sh"

# Retry transient git network failures (the pressure-induced gh-credential
# subprocess 401, plus 5xx and ref-lock contention). Backs off, then gives up.
git_retry() {
  local n=0 max=5
  until git "$@"; do
    n=$((n+1)); [ "$n" -ge "$max" ] && { echo "  git $1 failed after $max tries" >&2; return 1; }
    echo "  git $1 transient failure — retry $n/$max" >&2; sleep $((n*3))
  done
}

# isInMergeQueue is GraphQL-only (`gh pr view --json isInMergeQueue` fails
# with `Unknown JSON field`) — same query as poll-queue.sh.
pr_state() { # -> "STATE MERGESTATE INQUEUE"
  gh api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){
            pullRequest(number:$pr){ state mergeStateStatus isInMergeQueue }}}' \
    -f owner="$OWNER" -f name="$NAME" -F pr="$PR" \
    --jq '.data.repository.pullRequest | "\(.state) \(.mergeStateStatus) \(.isInMergeQueue)"' 2>/dev/null
}

# The enqueue primitive (see ENQUEUE PRIMITIVE in the header): resolve the PR
# node id, then GraphQL enqueuePullRequest — wrapped in gh-retry.sh exactly
# like the old CLI enqueue. Falls back to `gh pr merge --auto` (NO method
# flag) only when the node id cannot be resolved or the mutation errors.
# Success here is advisory either way — the caller confirms via the
# isInMergeQueue read, never via this function's exit code.
enqueue() {
  local prid
  prid="$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){ pullRequest(number:$pr){ id }}}' \
    -f owner="$OWNER" -f name="$NAME" -F pr="$PR" \
    --jq '.data.repository.pullRequest.id' 2>/dev/null)"
  if [ -n "$prid" ]; then
    if bash "$GH_RETRY" -- api graphql \
         -f query='mutation($prid:ID!){
             enqueuePullRequest(input:{pullRequestId:$prid}){
                 mergeQueueEntry{ position state }}}' \
         -f prid="$prid" >/dev/null; then
      return 0
    fi
    echo "  enqueue mutation failed — falling back to gh pr merge --auto" >&2
  else
    echo "  PR node id unresolved — falling back to gh pr merge --auto" >&2
  fi
  bash "$GH_RETRY" -- pr merge "$PR" --repo "$REPO" --auto >/dev/null
}

checks() { # -> "FAILS PENDING TOTAL"
  # Handles both rollup node types (issue #17): CheckRun (.status/.conclusion)
  # and legacy StatusContext (.state only — a bare `.status!="COMPLETED"` or
  # `.conclusion==null` would count every StatusContext as forever-pending and
  # silently block the merge). EXPECTED counts as pending, matching
  # poll-prs.sh's PENDING_FILTER.
  gh pr view "$PR" --repo "$REPO" --json statusCheckRollup --jq \
    '"\([.statusCheckRollup[]?|select((.conclusion=="FAILURE"or .conclusion=="CANCELLED"or .conclusion=="TIMED_OUT") or (.state=="FAILURE"or .state=="ERROR"))]|length) \([.statusCheckRollup[]?|select((.status!=null and .status!="COMPLETED") or .state=="PENDING" or .state=="EXPECTED")]|length) \([.statusCheckRollup[]?]|length)"' 2>/dev/null
}

# Does this repo run CI on pull requests AT ALL? One cheap call; total_count>0
# means an empty rollup is anomalous rather than normal. Without this a blanket
# zero-checks refusal would wedge every repo that has no CI by design.
# Unknown (call failed) is treated as "yes, expect checks" — consistent with
# the rest of this script: not knowing is never a licence to merge.
repo_runs_pr_ci() {
  local n
  n="$(gh api "repos/$REPO/actions/runs?event=pull_request&per_page=1" --jq '.total_count' 2>/dev/null)"
  case "$n" in
    ''|*[!0-9]*) return 0 ;;   # probe failed -> assume CI is expected
    0) return 1 ;;             # this repo genuinely never runs PR CI
    *) return 0 ;;
  esac
}

# How far behind the base is this PR's head? (see STALE-BRANCH TRAP above)
# Prints the commit count, or NOTHING when the answer is unknown — a failed
# GraphQL/compare call is never an error here, because the caller proceeds on
# unknown rather than stalling a healthy merge. Deliberately the opposite
# default from repo_runs_pr_ci: there, unknown blocks; here, unknown proceeds.
behind_by() { # -> commits the PR head is behind the base, "" if unknown
  local sha
  sha=$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
        repository(owner:$owner,name:$name){pullRequest(number:$pr){headRefOid}}}' \
    -f owner="$OWNER" -f name="$NAME" -F pr="$PR" \
    --jq '.data.repository.pullRequest.headRefOid' 2>/dev/null) || return 0
  [ -z "$sha" ] && return 0
  gh api "repos/$OWNER/$NAME/compare/$BRANCH...$sha" --jq '.behind_by' 2>/dev/null || true
}

# Prevention (issue #26): the Agent runtime checks each worktree out on a
# worktree-agent-<id> isolation branch. The PR merges from the agent's FEATURE
# branch, so the isolation branch never gets an upstream — never [gone], never
# swept — and one orphan accumulates per merge. Delete it here, at the same time
# the worktree is removed. Guards: isolation prefix only; never the default
# branch; never the PR's own head branch (--delete-branch / the [gone] sweep owns
# that); never a branch some live worktree has checked out.
drop_isolation_branch() { # $1 = candidate branch name (may be empty / non-isolation)
  local br="$1" head_ref wts
  [ -n "$br" ] || return 0
  case "$br" in "$ISO_PREFIX"*) : ;; *) return 0 ;; esac
  [ "$br" = "$BRANCH" ] && return 0
  git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$br" || return 0
  head_ref="$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq .headRefName 2>/dev/null || true)"
  if [ -z "$head_ref" ]; then
    echo "  (PR head ref unavailable — leaving $br for teardown.sh --sweep)"; return 0
  fi
  [ "$br" = "$head_ref" ] && return 0
  # Captured first, never piped into `grep -q` — see teardown.sh's
  # branch_in_live_worktree: pipefail turns grep -q's early close into a 141,
  # and a match read as a miss deletes a branch a live worktree is using.
  wts="$(git -C "$MAIN_WT" worktree list --porcelain)"
  if grep -qxF "branch refs/heads/$br" <<<"$wts"; then
    echo "  KEEP isolation branch $br (checked out by a live worktree)"; return 0
  fi
  git -C "$MAIN_WT" branch -D "$br" >/dev/null 2>&1 && echo "  deleted isolation branch $br" \
    || echo "  ⚠ could not delete isolation branch $br"
}

teardown() { # idempotent: safe whether or not the worktree/branch still exist
  [ -z "$MAIN_WT" ] && { echo "  (no local checkout — skipping teardown)"; return 0; }
  # Checkout guard (#486): a serial worker may own this checkout. A refusal (or a
  # check that cannot run) skips every local mutation below and is reported; it
  # never fails the merge, which already happened server-side.
  local guard_json
  if ! guard_json="$(bash "$GUARD_SCRIPT" check --repo "$MAIN_WT" 2>&1)"; then
    echo "  ⚠ local teardown skipped — refused by the checkout guard (the merge is unaffected): $guard_json"
    return 0
  fi
  local wt_br="" wt_iso=""
  if [ -n "$WT" ]; then
    # Isolation branch the runtime created the worktree on (worktree-<dirname>) —
    # derived from the PATH so idempotent re-runs still delete it after the
    # directory is already gone.
    wt_iso="worktree-$(basename "$WT")"
    if [ -e "$WT" ]; then
      # Capture the checked-out branch BEFORE removal (gone after).
      wt_br="$(git -C "$WT" branch --show-current 2>/dev/null || true)"
      git -C "$MAIN_WT" worktree remove --force "$WT" 2>/dev/null && echo "  worktree removed" \
        || echo "  ⚠ worktree not removed (locked/dirty?) — teardown.sh --sweep mops up later"
    fi
  fi
  git -C "$MAIN_WT" worktree prune 2>/dev/null || true
  drop_isolation_branch "$wt_br"
  if [ "$wt_iso" != "$wt_br" ]; then drop_isolation_branch "$wt_iso"; fi
  git -C "$MAIN_WT" switch "$BRANCH" >/dev/null 2>&1 || true
  git_retry -C "$MAIN_WT" fetch origin "$BRANCH" --quiet || true
  git -C "$MAIN_WT" merge --ff-only "origin/$BRANCH" >/dev/null 2>&1 \
    || echo "  ff reconcile skipped (residual local state — check by hand)"
  echo "  $BRANCH @ $(git -C "$MAIN_WT" log --oneline -1 2>/dev/null)"
}

# Stacked-PR gate. Returns 0 proceed · 23 blocked by a lower layer ·
# 24 stacked under a merge queue · 11 unknown (probe failed — wait, re-run).
#
# "Unknown" deliberately WAITS rather than merging: a probe that could not
# answer "is this PR stacked?" is not evidence that it isn't, and the failure
# mode of guessing wrong is an out-of-order merge. Transient failures clear on
# the next run, so waiting costs a re-run and never wedges permanently.
#
# A repo not enabled for stacks (probe exit 11) is a CLEAN answer, not an
# error — it proceeds untouched, which is every repo today.
stack_gate() {
  local sj rc lower broken
  [ -x "$STACK_PROBE" ] || [ -f "$STACK_PROBE" ] || return 0
  sj="$(bash "$STACK_PROBE" "$PR" --repo "$REPO" 2>/dev/null)"; rc=$?
  case "$rc" in
    10|11) return 0 ;;                 # not stacked, or stacks unavailable here
    0) : ;;                            # in a stack — inspect below
    *) echo "  stack probe inconclusive — not merging this pass"; return 11 ;;
  esac
  broken="$(printf '%s' "$sj" | jq -r '.lower_closed_unmerged | join(" ")' 2>/dev/null)"
  if [ -n "$broken" ]; then
    echo "STACK BROKEN — lower layer(s) closed without merging: $broken (needs a human)"
    return 24
  fi
  lower="$(printf '%s' "$sj" | jq -r '.lower_open | join(" ")' 2>/dev/null)"
  if [ -n "$lower" ]; then
    echo "STACKED layer $(printf '%s' "$sj" | jq -r '.position')/$(printf '%s' "$sj" | jq -r '.size') — blocked by open lower layer(s): $lower"
    return 23
  fi
  if [ "$DIRECT" != 1 ]; then
    echo "STACKED under a merge queue — interaction unverified upstream (needs a human)"
    return 24
  fi
  echo "  stacked: bottom-most open layer — clear to merge"
  return 0
}

advance() { # one idempotent step against live state
  local st ms inq fails pend total grc bb
  read -r st ms inq <<<"$(pr_state)"
  [ -z "$st" ] && { echo "state unavailable (transient) — retry later"; return 11; }
  case "$st" in
    MERGED) echo "MERGED — tearing down"; teardown; return 0 ;;
    CLOSED) echo "CLOSED (not merged)"; return 1 ;;
  esac
  # OPEN:
  read -r fails pend total <<<"$(checks)"
  [ "$ms" = CONFLICTING ] && { echo "CONFLICTING — needs human/rebase (do NOT auto-rebase)"; return 22; }
  if [ "$inq" = "true" ]; then echo "IN_QUEUE (waiting)"; return 11; fi
  # Stack gate BEFORE the red gate: on a blocked upper layer, "merge the layer
  # below first" is the actionable report, and its checks re-run on the
  # retargeted ref anyway once the lower layer lands.
  stack_gate; grc=$?
  [ "$grc" -ne 0 ] && return "$grc"
  # Empty rollup: CLEAN + 0 pending is ALSO true when there are no checks at
  # all. Refuse only where this repo demonstrably runs PR CI, so repos without
  # any CI are unaffected.
  if [ "${total:-0}" -eq 0 ] && [ "$ALLOW_NO_CHECKS" != 1 ] && repo_runs_pr_ci; then
    echo "NO CHECKS — this repo runs CI on pull requests, but this PR reports none."
    echo "  Either CI has not started yet, or the base branch has no required checks"
    echo "  (an intermediate chained/stacked PR). Not merging — re-run once checks"
    echo "  appear, or pass --allow-no-checks if this PR genuinely has no CI."
    return 21
  fi
  # Deliberately conservative: counts ADVISORY failures too (e.g. a
  # non-blocking dependency scan), so a PR the queue would accept can still
  # report RED here. Fail-safe by design — a human decides, not the script.
  if [ "${fails:-0}" -gt 0 ] && [ "${pend:-0}" -eq 0 ] && [ "$ms" != CLEAN ]; then
    echo "RED — failing checks (do NOT merge):"
    gh pr checks "$PR" --repo "$REPO" 2>/dev/null | grep -i fail || true
    return 20
  fi
  if [ "$ms" = CLEAN ] && [ "${pend:-1}" -eq 0 ]; then
    if [ "$DIRECT" = 1 ]; then
      # Staleness gate — DIRECT ONLY. A merge queue rebuilds each entry against
      # the current base, so queue mode reaches enqueue untouched. Unknown
      # (empty) proceeds; only a known non-zero behind-count stops the merge.
      bb="$(behind_by)"
      if [ -n "$bb" ] && [ "$bb" -gt 0 ] 2>/dev/null; then
        echo "STALE — $bb commit(s) behind $BRANCH (CLEAN only means no textual conflict)"
        if bash "$GH_RETRY" -- pr update-branch "$PR" --repo "$REPO" >/dev/null 2>&1; then
          echo "  branch updated — checks re-run against $BRANCH; re-run to merge"
        else
          echo "  update-branch failed — update it by hand, then re-run" >&2
        fi
        return 11
      fi
      echo "CLEAN — direct merge (--squash --delete-branch)"
      bash "$GH_RETRY" -- pr merge "$PR" --repo "$REPO" --squash --delete-branch >/dev/null \
        || echo "  merge call failed (checking whether it took anyway)" >&2
      sleep 5
      read -r st _ _ <<<"$(pr_state)"
      if [ "$st" = MERGED ]; then echo "  MERGED — tearing down"; teardown; return 0; fi
      echo "  merge not confirmed — re-run"; return 11
    fi
    echo "CLEAN — enqueuing (GraphQL enqueuePullRequest)"
    enqueue \
      || echo "  enqueue call failed (checking whether it took anyway)" >&2
    sleep 8
    read -r _ _ inq <<<"$(pr_state)"
    if [ "$inq" = "true" ]; then
      echo "  enqueued (isInMergeQueue=true)"; return 10
    else
      echo "  enqueue not confirmed — re-run"; return 11
    fi
  fi
  echo "WAITING (checks pending: ${pend:-?}, fails: ${fails:-0})"; return 11
}

# Single-shot, or bounded watch (exits cleanly within the host's kill window).
deadline=$((SECONDS + WATCH))
while :; do
  out="$(advance)"; rc=$?
  printf '[%ds] %s\n' "$SECONDS" "$out"
  # 23 (blocked by a lower stack layer) is deliberately NOT terminal — it
  # clears on its own once the layer below merges. 24 needs a human, so it stops.
  case "$rc" in 0|1|20|22|24) exit "$rc" ;; esac    # terminal — stop
  [ "$WATCH" -le 0 ] && exit "$rc"               # single-shot
  [ "$SECONDS" -ge "$deadline" ] && { echo "[bounded-exit] still in-flight — re-run to resume"; exit "$rc"; }
  sleep "$POLL"
done
