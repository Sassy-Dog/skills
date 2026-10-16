#!/usr/bin/env bash
# test-teardown-args.sh — pins teardown.sh's argument pre-scan (issue #200).
#
# Why this exists: the mode dispatch used to read `${1:-}` and then treat every
# remaining argument as a worktree path, so `teardown.sh <p1> <p2> --sweep` —
# the phrasing a caller naturally reaches for after a batch ("tear these down,
# then sweep") — tore the two worktrees down, handed `--sweep` to `basename` as
# a third path, and stopped there. The sweep never ran. What made it worth a
# gate rather than a memo is how it READS: the output is dominated by
# successful teardown lines, the complaint is a tool-level usage dump buried in
# the middle, and the phase that silently did nothing leaves nothing behind to
# notice. A caller sees the worktrees gone and moves on.
#
# Nine properties are asserted (7 was added by #486, 8 by #546, 9 by #557):
#
#   1. Combined form: paths + --sweep in ONE call tears the named paths down
#      first, then reaches all three sweep phases AND completes their work (an
#      unnamed stale worktree reclaimed, an orphan isolation branch deleted, a
#      [gone] branch deleted), then the shared reconcile/residual tail. The
#      pre-fix signature — a flag echoed back as a path — must be absent.
#   2. Flag position does not matter: `--sweep <p1>` behaves like `<p1>
#      --sweep`, and explicit teardown still precedes the sweep in both.
#   3. An unrecognised -prefixed argument is rejected with ONE clear error
#      naming it, a non-zero exit, and — the part that matters — ZERO mutation:
#      the rejection happens before any worktree or branch is touched.
#   4. --reconcile-only stays exclusive: combined with a path or with --sweep it
#      is rejected the same way, again before anything is torn down.
#   5. The three single-mode forms are unchanged: paths alone run no sweep,
#      --sweep alone runs no explicit phase, --reconcile-only alone runs
#      neither and still reconciles.
#   6. Source-level: the dispatch no longer keys on `${1:-}` — it pre-scans
#      "$@". Properties 1-5 exercise behaviour; this one fails the moment the
#      single-argument shape is reinstated, including in a path they miss.
#
#   7. The checkout guard (#486): while a guard is held, teardown refuses with
#      exit 7 BEFORE any local mutation (branches, HEAD and the worktree list
#      are unchanged), a wrong token refuses the same way, a matching
#      SASSY_DOG_CHECKOUT_TOKEN lets it proceed, and a copy with the `check`
#      call neutered (a mutant) tears the worktree down and so fails the
#      refusal assertion. On a host WITHOUT python3 (a PATH built to exclude it)
#      no guard still means exit 0 and unchanged behaviour, while a held guard
#      still refuses (fail closed). merge-shepherd.sh's post-merge teardown
#      carries the same call; it needs a live GitHub to run, so its function
#      body is pinned at source level: the check precedes the first mutation and
#      the refusal branch returns. Three mutants (check deleted, check moved
#      after the remove, `return` dropped) must each fail that pin.
#
#   8. The sweep keeps a live worker's worktree (#546): a feature-branch
#      worktree is swept only on POSITIVE evidence that it shipped. Four
#      worktrees must SURVIVE --sweep and say why (branch never pushed; tracked
#      change; untracked file; locked) while a clean, unlocked one whose branch
#      was pushed and then deleted on the remote IS still swept, and an explicit
#      path still removes the locked and the dirty one (the override is for
#      explicit paths only). A detached worktree gets the SAME guards: a
#      mid-rebase one (detached, and live) survives whether it is locked or
#      clean-and-unlocked, a truly detached clean one is swept, and a git error
#      reading HEAD is a KEEP rather than "detached". Each guard has its own
#      mutant that removes a live worktree and so reddens the survival
#      assertion: evidence (the no-upstream check, which also neuters the track
#      check since an unpushed branch trips both), track-only (agent-open),
#      readable status, untracked-files=all (agent-untracked, with
#      status.showUntrackedFiles=no in the fixture), operation in progress,
#      locked, readable HEAD, readable worktree list, readable git dir, the
#      sequencer sentinel (a clean tree with only <gitdir>/sequencer left), the
#      detached-HEAD reachability check (a detached commit no ref contains is
#      kept; a reachable one is swept), the isolation-branch filter (a worktree
#      detached at the tip of its OWN worktree-agent-* branch is kept and that
#      branch survives, since removal would delete the only ref holding the
#      commit) and the unguarded detached removal. The five fail-closed
#      branches are status, HEAD, git dir, worktree list and the reachability
#      query; each is exercised with a PATH-shimmed `git` that fails only that
#      call. Every mkscratch worktree is
#      a SHIPPED one (pushed, then deleted on origin), because properties 1-2
#      need the sweep to reclaim it.
#
#   9. The sweep never deletes an isolation branch whose tip is unmerged (#557).
#      The sweep's evidence vets a worktree's HEAD, never that branch's own tip,
#      so sweep-driven removals leave the isolation branch to the orphan phase
#      (ancestry or MERGED PR). Two shapes, each with one commit only the
#      isolation branch holds: a clean detached worktree at main, and a [gone]
#      feature-branch worktree. Both worktrees are swept, the branch survives and
#      the orphan phase says KEEP as possibly unmerged; a merged isolation branch
#      is still deleted, by the orphan phase; an explicit path still deletes it.
#      A mutant restoring the in-sweep deletion must lose the commit.
#      The merged-PR test is bound to the default branch: a tip in a PR merged
#      into a non-default (stacked) base is KEPT, one merged into the default
#      branch is deleted, and a mutant dropping the base check deletes the first.
#      The rows are walked, not just the first (#560): with the stacked-base PR
#      listed BEFORE the PR merged into main, the branch is deleted via the
#      second; a `head -1` mutant keeps it. gh exiting nonzero, an empty
#      listing and a null base.ref each KEEP. The hostile-name run also asserts
#      the KEEP line and that the --jq argument gh received is the script's
#      constant program; a mutant that re-interpolates $BRANCH but keeps the
#      shell comparison survives the branch assertion and is caught by that
#      argument check alone. The "(already gone)" sweep guard in teardown.sh is
#      unreachable from --sweep (see the comment there), so it has no fixture.
#
# Assertions read TEARDOWN'S OWN output (its phase headers, its rejection
# message) and never `basename`'s, whose wording differs between BSD and GNU —
# that difference is why this surfaced on macOS and not on a Linux runner.
#
# Network-free: scratch repos with a LOCAL bare origin, plus a PATH-shimmed
# mock `gh` covering teardown's three lookups, so a machine with a real
# authenticated gh behaves exactly like CI. Every scratch repo is verified to
# be its own git root before teardown runs in it — teardown resolves its target
# from `git rev-parse --show-toplevel`, and a half-built fixture must fail
# loudly rather than walk up into the checkout this test runs from.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-teardown-args.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-teardown-args: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

TEARDOWN="$REPO_ROOT/skills/pr-shepherd/scripts/teardown.sh"
[ -f "$TEARDOWN" ] || { echo "test-teardown-args: $TEARDOWN not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

export GIT_AUTHOR_NAME=teardown-test GIT_AUTHOR_EMAIL=teardown@example.invalid
export GIT_COMMITTER_NAME=teardown-test GIT_COMMITTER_EMAIL=teardown@example.invalid
export GIT_CONFIG_NOSYSTEM=1

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "teardown-args tests (work: $WORK)" >&2

# --- the mock gh --------------------------------------------------------------
# teardown makes exactly three kinds of gh lookup, all in --sweep: the repo
# slug, a merged-PR-contains-tip probe, and the open-PR base list. None may
# reach a network here, and none may vary with the operator's auth state.
cat >"$BIN/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    repo) echo "mock-org/mock-repo" ;;   # repo view --json nameWithOwner
    api)  # commits/<tip>/pulls -> no merged PR, unless MOCK_PULLS names a JSON file of PRs;
          # then the caller's own --jq filter runs over it (so the real filter is tested)
          [ "${MOCK_GH_FAIL:-}" = "1" ] && exit 1   # gh api exits nonzero (rate limit, auth, network)
          [ -f "${MOCK_PULLS:-}" ] || exit 0
          expr=""; prev=""
          for a in "$@"; do [ "$prev" = "--jq" ] && expr="$a"; prev="$a"; done
          [ -n "${MOCK_JQ_LOG:-}" ] && printf '%s\n' "$expr" >>"$MOCK_JQ_LOG"
          jq -r "$expr" "$MOCK_PULLS" ;;
    pr)   : ;;                           # pr list --state open -> no open PRs
    *) echo "mock gh: unhandled invocation: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$BIN/gh"

# --- fixture builder ----------------------------------------------------------
# A scratch repo shaped like a repo mid-batch: N agent worktrees created on
# worktree-agent-* isolation branches and switched to feature branches (what the
# Agent runtime leaves), one orphan isolation branch whose worktree is already
# gone, and one ordinary [gone] branch whose upstream was deleted on "merge".
# Those last two are what sweep phases 2 and 3 exist for, so their disappearance
# is the evidence that the sweep really ran rather than only printing a header.
mkscratch() { # <name> <n_worktrees> -> echoes the repo dir
    local name="$1" n="$2"
    local dir="$WORK/$name" origin="$WORK/$name-origin.git"
    local i id wt
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" symbolic-ref HEAD refs/heads/main
    echo seed >"$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -qm seed
    git init -q --bare "$origin"
    git -C "$dir" remote add origin "$origin"
    git -C "$dir" push -q -u origin main
    git -C "$dir" remote set-head origin main      # so origin/HEAD resolves
    for ((i = 1; i <= n; i++)); do
        id="$(printf 'agent-a%02d' "$i")"
        wt="$dir/.claude/worktrees/$id"
        git -C "$dir" worktree add -q -b "worktree-$id" "$wt" main
        git -C "$wt" switch -q -c "feat/issue-$i"
        # Shipped: pushed, then deleted on origin at merge, so the upstream is
        # [gone] (#546: the sweep reclaims only on that positive evidence).
        git -C "$wt" push -q -u origin "feat/issue-$i"
        git -C "$dir" push -q origin --delete "feat/issue-$i"
    done
    # Orphan isolation branch (worktree already gone) — sweep phase 2.
    git -C "$dir" branch worktree-agent-orphan main
    # Ordinary [gone] branch: pushed, then deleted on origin — sweep phase 3.
    git -C "$dir" branch feat/shipped main
    git -C "$dir" push -q -u origin feat/shipped
    git -C "$dir" push -q origin --delete feat/shipped
    echo "$dir"
}

# --- runner + assertions ------------------------------------------------------
OUT=""
STATUS=0
run_teardown() { # <repo_dir> [args...]
    local dir="$1" top
    shift
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(cd "$dir" && pwd -P)" ]; then
        echo "test-teardown-args: refusing to run teardown — '$dir' is not its own git root (got '$top')" >&2
        exit 1
    fi
    OUT="$(cd "$dir" && PATH="$BIN:$PATH" bash "$TEARDOWN" "$@" 2>&1)"
    STATUS=$?
}

dump() { printf '%s\n' "$OUT" | sed 's/^/          | /' >&2; }

expect() { # <label> <needle>
    if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 — expected in output: $2"; dump; fi
}
expect_re() { # <label> <extended_regex> — for lines carrying an absolute path
    if grep -qE -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1 — expected a line matching: $2"; dump; fi
}
refute() { # <label> <needle>
    if grep -qF -- "$2" <<<"$OUT"; then bad "$1 — must NOT appear in output: $2"; dump; else ok "$1"; fi
}
expect_status() { # <label> <expected>
    if [ "$STATUS" = "$2" ]; then ok "$1 (exit $STATUS)"; else bad "$1 — exit $STATUS, expected $2"; dump; fi
}
# First matching line number, via awk rather than a `| head -1` pipeline (which
# under pipefail can answer with the writer's SIGPIPE — issue #172).
line_of() { awk -v pat="$1" 'index($0, pat) { print NR; exit }' <<<"$OUT"; }
expect_before() { # <label> <needle_first> <needle_second>
    local a b
    a="$(line_of "$2")"; b="$(line_of "$3")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
        ok "$1"
    else
        bad "$1 — '$2' (line ${a:-none}) must precede '$3' (line ${b:-none})"; dump
    fi
}
# Branches + worktrees, for the "rejected means nothing was touched" checks.
snapshot() { # <repo_dir>
    {
        git -C "$1" for-each-ref --format='branch %(refname:short)' refs/heads
        git -C "$1" worktree list --porcelain | awk '/^worktree /{print "worktree " $2}'
    } | sort
}

H_EXPLICIT='== explicit teardown of'
H_SWEEP1='== sweep: agent worktrees whose upstream was deleted'
H_SWEEP2='== sweep: orphan worktree-agent-* isolation branches'
H_SWEEP3='== sweep: ordinary [gone] local branches'
H_RECONCILE='== reconcile main =='

# --- 1. combined: paths + --sweep in one call ---------------------------------
echo "1. combined form (paths + --sweep)" >&2
D="$(mkscratch combined 3)"
run_teardown "$D" .claude/worktrees/agent-a01 .claude/worktrees/agent-a02 --sweep
expect_status "combined form succeeds" 0
expect "explicit phase ran over both named paths" "$H_EXPLICIT 2 worktree(s)"
expect "  named worktree a01 removed" "removed worktree .claude/worktrees/agent-a01"
expect "  named worktree a02 removed" "removed worktree .claude/worktrees/agent-a02"
expect "sweep phase 1 header reached" "$H_SWEEP1"
expect "sweep phase 2 header reached" "$H_SWEEP2"
expect "sweep phase 3 header reached" "$H_SWEEP3"
expect_re "  sweep reclaimed the unnamed stale worktree" 'gone/merged: .*/\.claude/worktrees/agent-a03 \[feat/issue-3\]' 
expect "  sweep deleted the orphan isolation branch" "deleted worktree-agent-orphan"
expect "  sweep deleted the [gone] branch" "deleted feat/shipped (upstream gone)"
expect "shared reconcile tail ran" "$H_RECONCILE"
expect "residual report shows nothing left" "agent worktrees remaining: 0"
expect_before "explicit teardown precedes the sweep" "$H_EXPLICIT" "$H_SWEEP1"
# The pre-fix signature: the flag consumed as a worktree path. teardown's own
# wording, not basename's — BSD and GNU differ there, which is the whole reason
# this reached macOS only.
refute "--sweep is never echoed back as a worktree path" "(already gone) --sweep"
if [ -d "$D/.claude/worktrees/agent-a03" ]; then
    bad "the swept worktree agent-a03 is still on disk — the sweep printed its header but did no work"
else
    ok "swept worktree really is gone from disk"
fi

# --- 2. flag first ------------------------------------------------------------
echo "2. flag-first form (--sweep before the path)" >&2
D="$(mkscratch flagfirst 2)"
run_teardown "$D" --sweep .claude/worktrees/agent-a01
expect_status "flag-first form succeeds" 0
expect "explicit phase ran over the named path" "$H_EXPLICIT 1 worktree(s)"
expect "sweep phase 1 header reached" "$H_SWEEP1"
expect "sweep phase 3 header reached" "$H_SWEEP3"
expect_re "  sweep reclaimed the unnamed stale worktree" 'gone/merged: .*/\.claude/worktrees/agent-a02 \[feat/issue-2\]' 
expect_before "explicit teardown still precedes the sweep" "$H_EXPLICIT" "$H_SWEEP1"
refute "--sweep is never echoed back as a worktree path" "(already gone) --sweep"

# --- 3. unrecognised -prefixed arguments --------------------------------------
# Rejection cases share one fixture precisely because a rejection must leave it
# untouched: each case re-checks the snapshot, so a leak would fail here.
echo "3. unrecognised options are rejected before anything is torn down" >&2
D="$(mkscratch reject 2)"
BEFORE="$(snapshot "$D")"
for bogus in -bogus --swep; do
    run_teardown "$D" .claude/worktrees/agent-a01 "$bogus" --sweep
    expect_status "'$bogus' rejected" 2
    expect "  the error names '$bogus'" "unrecognised option '$bogus'"
    refute "  no explicit teardown ran" "$H_EXPLICIT"
    refute "  no sweep ran" "$H_SWEEP1"
    refute "  no reconcile ran" "$H_RECONCILE"
    if [ "$(snapshot "$D")" = "$BEFORE" ]; then
        ok "  branches and worktrees untouched"
    else
        bad "  '$bogus' was rejected but the repo changed — the check must precede every mutation"
        diff <(printf '%s\n' "$BEFORE") <(snapshot "$D") >&2
    fi
done

# --- 4. --reconcile-only stays exclusive --------------------------------------
echo "4. --reconcile-only is exclusive" >&2
for combo in "--reconcile-only --sweep" "--reconcile-only .claude/worktrees/agent-a01"; do
    # shellcheck disable=SC2086  # deliberate word split: the combo IS the arg list
    run_teardown "$D" $combo
    expect_status "'$combo' rejected" 2
    expect "  the error names --reconcile-only" "--reconcile-only"
    refute "  no explicit teardown ran" "$H_EXPLICIT"
    refute "  no sweep ran" "$H_SWEEP1"
    refute "  no reconcile ran" "$H_RECONCILE"
    if [ "$(snapshot "$D")" = "$BEFORE" ]; then
        ok "  branches and worktrees untouched"
    else
        bad "  '$combo' was rejected but the repo changed"
    fi
done

# No arguments at all: unchanged, still a usage error.
run_teardown "$D"
expect_status "no arguments still a usage error" 2
expect "  the usage error names all three forms" "pass worktree path(s), --sweep, or --reconcile-only"

# --- 5. the single-mode forms are unchanged -----------------------------------
echo "5. single-mode forms behave exactly as before" >&2
D="$(mkscratch pathsonly 2)"
run_teardown "$D" .claude/worktrees/agent-a01
expect_status "paths alone succeed" 0
expect "  explicit phase ran" "$H_EXPLICIT 1 worktree(s)"
refute "  no sweep phase 1" "$H_SWEEP1"
refute "  no sweep phase 3" "$H_SWEEP3"
expect "  reconcile tail still ran" "$H_RECONCILE"
if [ -d "$D/.claude/worktrees/agent-a02" ]; then
    ok "  the unnamed worktree was left alone (no implicit sweep)"
else
    bad "  paths-only removed an unnamed worktree — it swept without being asked"
fi

D="$(mkscratch sweeponly 2)"
run_teardown "$D" --sweep
expect_status "--sweep alone succeeds" 0
refute "  no explicit phase" "$H_EXPLICIT"
expect "  sweep phase 1 ran" "$H_SWEEP1"
expect "  sweep phase 2 ran" "$H_SWEEP2"
expect "  sweep phase 3 ran" "$H_SWEEP3"
expect "  reconcile tail still ran" "$H_RECONCILE"
expect "  residual report shows nothing left" "agent worktrees remaining: 0"

D="$(mkscratch reconcileonly 2)"
BEFORE="$(snapshot "$D")"
run_teardown "$D" --reconcile-only
expect_status "--reconcile-only alone succeeds (ff clean)" 0
refute "  no explicit phase" "$H_EXPLICIT"
refute "  no sweep phase" "$H_SWEEP1"
expect "  reconcile ran" "$H_RECONCILE"
if [ "$(snapshot "$D")" = "$BEFORE" ]; then
    ok "  worktrees and branches untouched"
else
    bad "  --reconcile-only touched a worktree or branch"
fi

# --- 6. source-level: the dispatch pre-scans "$@" -----------------------------
echo "6. source-level shape guard" >&2
if grep -q 'for arg in "\$@"' "$TEARDOWN"; then
    ok "the dispatch pre-scans the whole argument list"
else
    bad "no pre-scan over the full argument list found in $TEARDOWN — flags parsed at one fixed position is the shape issue #200 removed"
fi
if grep -qF '${1:-}' "$TEARDOWN"; then
    bad "$TEARDOWN keys a mode on \${1:-} again — that shape only sees the FIRST argument, so a flag anywhere else falls through to the path loop (issue #200)"
else
    ok "no mode is keyed on the first argument alone"
fi

# --- 7. the checkout guard (#486) ---------------------------------------------
echo "7. checkout guard" >&2
GUARD_SH="$REPO_ROOT/skills/pr-shepherd/scripts/checkout-guard.sh"
unset SASSY_DOG_CHECKOUT_TOKEN
D="$(mkscratch guarded 2)"
printf '.claude/\n' >>"$D/.git/info/exclude"
ACQ="$(bash "$GUARD_SH" acquire --repo "$D" --owner teardown-test 2>&1)"
TOKEN="$(python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["token"])' <<<"$ACQ" 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
    bad "could not acquire a guard for the fixture: $ACQ"
else
    BEFORE="$(snapshot "$D")"; HEAD_BEFORE="$(git -C "$D" rev-parse HEAD)"
    run_teardown "$D" .claude/worktrees/agent-a01
    expect_status "held guard, no token: teardown refuses" 7
    expect "  refusal names the guard path" "sassy-dog-checkout-guard"
    expect "  refusal names the ownership" '"ownership": "held"'
    refute "  no explicit phase ran" "$H_EXPLICIT"
    if [ "$(snapshot "$D")" = "$BEFORE" ] && [ "$(git -C "$D" rev-parse HEAD)" = "$HEAD_BEFORE" ]; then
        ok "  branches, worktrees and HEAD unchanged"
    else
        bad "  teardown mutated the checkout while a guard was held"
    fi
    SASSY_DOG_CHECKOUT_TOKEN="not-the-owner" run_teardown "$D" --sweep
    expect_status "held guard, wrong token: teardown refuses" 7
    if [ "$(snapshot "$D")" = "$BEFORE" ]; then ok "  checkout unchanged"; else bad "  wrong token still mutated the checkout"; fi
    # Mutant: the check call neutered. It must tear the worktree down, which is
    # exactly what the refusal assertions above would then catch.
    MUT="$WORK/mutant"; mkdir -p "$MUT"; cp "$TEARDOWN" "$GUARD_SH" "$MUT/"
    sed -i.bak 's/" check --repo/" status --repo/' "$MUT/teardown.sh"
    if cmp -s "$MUT/teardown.sh" "$TEARDOWN"; then
        bad "  mutant anchor drifted: the check call was not found in teardown.sh"
    else
        OUT="$(cd "$D" && PATH="$BIN:$PATH" bash "$MUT/teardown.sh" .claude/worktrees/agent-a02 2>&1)"; STATUS=$?
        if [ "$STATUS" != "7" ] && [ ! -d "$D/.claude/worktrees/agent-a02" ]; then
            ok "  mutant without the check call mutates under a guard (the gate bites)"
        else
            bad "  mutant did not mutate (exit $STATUS) — the refusal assertions would pass without the check"; dump
        fi
    fi
    SASSY_DOG_CHECKOUT_TOKEN="$TOKEN" run_teardown "$D" .claude/worktrees/agent-a01
    expect_status "held guard, matching token: teardown proceeds" 0
    expect "  explicit phase ran" "$H_EXPLICIT 1 worktree(s)"
    if [ ! -d "$D/.claude/worktrees/agent-a01" ]; then ok "  named worktree removed"; else bad "  matching token did not tear the worktree down"; fi
    run_teardown "$D" --reconcile-only
    expect_status "still held, no token: --reconcile-only refuses too" 7
fi
D="$(mkscratch unguarded 1)"
run_teardown "$D" .claude/worktrees/agent-a01
expect_status "no guard present: teardown behaves as before" 0
expect "  explicit phase ran" "$H_EXPLICIT 1 worktree(s)"


# No python3 on PATH (a symlink farm of every PATH executable except python*):
# the host a guard cannot be READ on. No guard must behave as it always did; a
# held guard must still refuse, never fail open.
NOPY="$WORK/nopy"
mkdir -p "$NOPY"
IFS=: read -r -a pathdirs <<<"$PATH"
for dir in "${pathdirs[@]}"; do
    [ -d "$dir" ] || continue
    for exe in "$dir"/*; do
        name="${exe##*/}"
        case "$name" in python*|pypy*) continue ;; esac
        [ -x "$exe" ] && [ ! -d "$exe" ] && [ ! -e "$NOPY/$name" ] && ln -s "$exe" "$NOPY/$name"
    done
done
if PATH="$NOPY" command -v python3 >/dev/null 2>&1; then
    bad "the no-python PATH still resolves python3 — the next assertions would prove nothing"
fi
D="$(mkscratch nopy-free 1)"
OUT="$(cd "$D" && PATH="$BIN:$NOPY" bash "$TEARDOWN" .claude/worktrees/agent-a01 2>&1)"; STATUS=$?
expect_status "no python3, no guard: teardown behaves as before" 0
expect "  explicit phase ran" "$H_EXPLICIT 1 worktree(s)"
OUT="$(cd "$D" && PATH="$BIN:$NOPY" bash "$TEARDOWN" --reconcile-only 2>&1)"; STATUS=$?
expect_status "no python3, no guard: --reconcile-only behaves as before" 0
D="$(mkscratch nopy-held 1)"
printf '.claude/\n' >>"$D/.git/info/exclude"
bash "$GUARD_SH" acquire --repo "$D" --owner teardown-test >/dev/null 2>&1 || bad "could not acquire a guard for the no-python fixture"
BEFORE="$(snapshot "$D")"
OUT="$(cd "$D" && PATH="$BIN:$NOPY" bash "$TEARDOWN" .claude/worktrees/agent-a01 2>&1)"; STATUS=$?
expect_status "no python3, guard held: teardown still refuses (fails closed)" 7
expect "  the refusal names the missing Python" "Python 3 is required"
if [ "$(snapshot "$D")" = "$BEFORE" ]; then ok "  checkout unchanged"; else bad "  teardown mutated the checkout with a guard it could not read"; fi

# merge-shepherd.sh's teardown(): source-level pin on the function body only.
MERGE_SHEPHERD="$REPO_ROOT/skills/pr-shepherd/scripts/merge-shepherd.sh"
MS_PIN="$WORK/ms_pin.py"
cat >"$MS_PIN" <<'PIN'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^teardown\(\) \{.*?^\}$', text, re.S | re.M)
if not m:
    sys.exit("no teardown() body")
body = m.group(0)
check = body.find('"$GUARD_SCRIPT" check')
remove = body.find('worktree remove')
refusal = re.search(r'if ! guard_json=.*?\n  fi\n', body, re.S)
if check < 0 or remove < 0 or not check < remove:
    sys.exit("the guard check does not precede the first mutation")
if not refusal or "return 0" not in refusal.group(0):
    sys.exit("the refusal branch does not return")
PIN
MS_MUT="$WORK/ms_mut.py"
cat >"$MS_MUT" <<'PIN'
import re, sys
src, kind, out = sys.argv[1:4]
text = open(src).read()
block = re.search(r'  local guard_json\n  if ! guard_json=.*?\n  fi\n', text, re.S).group(0)
if kind == "deleted":
    text = text.replace(block, "", 1)
elif kind == "moved":
    text = text.replace(block, "", 1)
    anchor = '  git -C "$MAIN_WT" worktree prune'
    assert anchor in text
    text = text.replace(anchor, block + anchor, 1)
elif kind == "noreturn":
    text = text.replace(block, block.replace("    return 0\n", "", 1), 1)
open(out, "w").write(text)
PIN
if python3 -I "$MS_PIN" "$MERGE_SHEPHERD"; then
    ok "merge-shepherd.sh's teardown() checks the guard before its first mutation and returns on refusal"
else
    bad "merge-shepherd.sh's teardown() lost its checkout-guard check or its early return (#486)"
fi
for kind in deleted moved noreturn; do
    python3 -I "$MS_MUT" "$MERGE_SHEPHERD" "$kind" "$WORK/ms_$kind.sh" || bad "merge-shepherd mutant $kind did not build"
    if cmp -s "$WORK/ms_$kind.sh" "$MERGE_SHEPHERD"; then
        bad "merge-shepherd mutant $kind equals its source"
    elif python3 -I "$MS_PIN" "$WORK/ms_$kind.sh" 2>/dev/null; then
        bad "merge-shepherd mutant '$kind' passes the pin — the pin is vacuous"
    else
        ok "merge-shepherd mutant '$kind' fails the pin"
    fi
done

# --- 8. the sweep keeps live workers' worktrees (#546) --------------------------
echo "8. sweep keeps unpushed, dirty and locked worktrees" >&2
mkguards() { # <name> -> repo with one worktree per case; echoes the repo dir
    local d id wt
    d="$(mkscratch "$1" 0)"
    # Never pushed: a live worker that switched to its feature branch.
    wt="$d/.claude/worktrees/agent-unpushed"
    git -C "$d" worktree add -q -b worktree-agent-unpushed "$wt" main
    git -C "$wt" switch -q -c feat/unpushed
    echo work >"$wt/work.txt"; git -C "$wt" add work.txt; git -C "$wt" commit -qm work
    # Shipped (pushed, then deleted on origin): dirty-tracked, untracked file,
    # locked, and the clean unlocked one that must still be swept.
    for id in dirtytracked untracked locked merged; do
        wt="$d/.claude/worktrees/agent-$id"
        git -C "$d" worktree add -q -b "worktree-agent-$id" "$wt" main
        git -C "$wt" switch -q -c "feat/$id"
        git -C "$wt" push -q -u origin "feat/$id"
        git -C "$d" push -q origin --delete "feat/$id"
    done
    echo edit >>"$d/.claude/worktrees/agent-dirtytracked/README.md"
    echo scratch >"$d/.claude/worktrees/agent-untracked/new.txt"
    git -C "$d" worktree lock --reason "agent running" "$d/.claude/worktrees/agent-locked"
    # Branch still on origin (PR open): the pre-existing KEEP.
    wt="$d/.claude/worktrees/agent-open"
    git -C "$d" worktree add -q -b worktree-agent-open "$wt" main
    git -C "$wt" switch -q -c feat/open
    git -C "$wt" push -q -u origin feat/open
    # A repo that hides untracked files from `git status` must not hide a
    # finished worker's never-added files from the sweep.
    git -C "$d" config status.showUntrackedFiles no
    # Detached worktrees. rb-clean / rb-locked are PAUSED MID-REBASE (HEAD is
    # detached, tree clean): a live worker. plain-detached is truly detached,
    # clean, unlocked, finished: the one detached case that IS swept.
    for id in rb-clean rb-locked; do
        wt="$d/.claude/worktrees/agent-$id"
        git -C "$d" worktree add -q -b "worktree-agent-$id" "$wt" main
        git -C "$wt" switch -q -c "feat/$id"
        echo one >"$wt/one.txt"; git -C "$wt" add one.txt; git -C "$wt" commit -qm one
        echo two >"$wt/two.txt"; git -C "$wt" add two.txt; git -C "$wt" commit -qm two
        GIT_SEQUENCE_EDITOR="sed -i.bak s/^pick/edit/" git -C "$wt" rebase -q -i main >/dev/null 2>&1
    done
    git -C "$d" worktree lock --reason "agent running" "$d/.claude/worktrees/agent-rb-locked"
    git -C "$d" worktree add -q --detach "$d/.claude/worktrees/agent-plain-detached" main
    # Detached with a commit no ref contains: clean and unlocked, but removing it
    # would lose the commit (and the per-worktree reflog that anchors it).
    wt="$d/.claude/worktrees/agent-unreachable"
    git -C "$d" worktree add -q --detach "$wt" main
    echo lost >"$wt/lost.txt"; git -C "$wt" add lost.txt; git -C "$wt" commit -qm lost
    # Detached at the tip of its OWN isolation branch: the only ref holding the
    # commit is one the removal itself would delete, so it must not vouch for it.
    wt="$d/.claude/worktrees/agent-isotip"
    git -C "$d" worktree add -q -b worktree-agent-isotip "$wt" main
    echo iso >"$wt/iso.txt"; git -C "$wt" add iso.txt; git -C "$wt" commit -qm iso
    git -C "$wt" checkout -q --detach
    # A shipped branch whose multi-commit cherry-pick stopped on a conflict and
    # was then committed by hand: clean tree, no CHERRY_PICK_HEAD, but the
    # sequencer directory is still there.
    git -C "$d" branch side main
    git -C "$d" worktree add -q -b worktree-agent-seq "$d/.claude/worktrees/agent-seq" main
    wt="$d/.claude/worktrees/agent-seq"
    git -C "$wt" switch -q -c feat/seq
    echo mine >>"$wt/README.md"; git -C "$wt" commit -qam mine
    git -C "$wt" push -q -u origin feat/seq
    git -C "$d" push -q origin --delete feat/seq
    git -C "$d" worktree add -q "$d/.claude/worktrees/agent-sidework" side
    echo side1 >>"$d/.claude/worktrees/agent-sidework/README.md"; git -C "$d/.claude/worktrees/agent-sidework" commit -qam side1
    echo side2 >"$d/.claude/worktrees/agent-sidework/side2.txt"; git -C "$d/.claude/worktrees/agent-sidework" add side2.txt
    git -C "$d/.claude/worktrees/agent-sidework" commit -qm side2
    git -C "$d" worktree remove -f "$d/.claude/worktrees/agent-sidework"
    git -C "$wt" cherry-pick side~1 side >/dev/null 2>&1
    git -C "$wt" checkout -q --theirs README.md
    git -C "$wt" add README.md
    git -C "$wt" commit -qm resolved
    if [ ! -d "$(git -C "$wt" rev-parse --absolute-git-dir)/sequencer" ] \
        || [ -n "$(git -C "$wt" status --porcelain)" ]; then
        echo "test-teardown-args: sequencer fixture did not reach a clean tree with sequencer present" >&2; exit 1
    fi
    echo "$d"
}
# A repo with one clean, unlocked, shipped worktree: the only thing a fail-closed
# branch stands between the sweep and.
mkshipped() { # <name> -> repo dir
    local d wt
    d="$(mkscratch "$1" 0)"
    wt="$d/.claude/worktrees/agent-s"
    git -C "$d" worktree add -q -b worktree-agent-s "$wt" main
    git -C "$wt" switch -q -c feat/s
    git -C "$wt" push -q -u origin feat/s
    git -C "$d" push -q origin --delete feat/s
    echo "$d"
}
# A git that fails (exit 128) exactly one kind of call: calls whose argv contains
# FAIL_PAT, on the FAIL_NTH-th match only (0 = every match). Everything else is
# the real git.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
cat >"$SHIM/git" <<SHIMEOF
#!/usr/bin/env bash
case "\$*" in
    *"\$FAIL_PAT"*)
        n=\$(( \$(cat "\$COUNT_FILE" 2>/dev/null || echo 0) + 1 )); echo \$n >"\$COUNT_FILE"
        if [ "\${FAIL_NTH:-0}" = 0 ] || [ "\$n" = "\$FAIL_NTH" ]; then exit 128; fi ;;
esac
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$SHIM/git"
shim_sweep() { # <repo> <teardown.sh> <fail_pat> <nth> — OUT/STATUS as run_teardown
    rm -f "$WORK/shim.count"
    OUT="$(cd "$1" && PATH="$SHIM:$BIN:$PATH" FAIL_PAT="$3" FAIL_NTH="$4" COUNT_FILE="$WORK/shim.count" bash "$2" --sweep 2>&1)"; STATUS=$?
}
survives() { [ -d "$1/.claude/worktrees/agent-$2" ]; }  # <repo> <id>

D="$(mkguards sweepguards)"
run_teardown "$D" --sweep
expect_status "sweep over the guard fixture succeeds" 0
expect_re "  unpushed worktree kept, with the never-pushed reason" 'KEEP \(branch has no upstream.*agent-unpushed \[feat/unpushed\]'
expect_re "  tracked-change worktree kept, with the dirty reason" 'KEEP \(uncommitted changes or untracked files.*agent-dirtytracked'
expect_re "  untracked-file worktree kept, with the dirty reason" 'KEEP \(uncommitted changes or untracked files.*agent-untracked'
expect_re "  locked worktree kept, with the locked reason" 'KEEP \(worktree is locked.*agent-locked \[feat/locked\]'
expect_re "  open-PR worktree kept (remote branch still exists)" 'KEEP \(remote branch still exists.*agent-open'
expect_re "  clean, unlocked, [gone] worktree is still swept" 'gone/merged: .*/agent-merged \[feat/merged\]'
# Detached and mid-rebase worktrees go through the same guards (the Blocking
# finding on the first revision: the detached branch removed with -f -f before any
# guard ran). Mid-rebase ones survive, the finished detached one is swept.
expect_re "  mid-rebase clean unlocked worktree kept (operation in progress)" 'KEEP \(a git operation .*in progress.*agent-rb-clean'
expect_re "  mid-rebase locked worktree kept" 'KEEP \(.*agent-rb-locked'
expect_re "  finished, clean, unlocked detached worktree is still swept" 'detached → removing: .*agent-plain-detached'
for w in rb-clean rb-locked; do
    if survives "$D" "$w"; then ok "  mid-rebase worktree agent-$w survived the sweep"; else bad "  mid-rebase worktree agent-$w was swept"; fi
done
expect_re "  detached worktree with an unreachable commit kept" 'KEEP \(detached HEAD is not reachable.*agent-unreachable'
expect_re "  clean worktree with only a sequencer dir left behind kept" 'KEEP \(a git operation .*in progress.*agent-seq'
expect_re "  detached at its own isolation-branch tip kept (the isolation ref cannot vouch)" 'KEEP \(detached HEAD is not reachable.*agent-isotip'
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-isotip; then ok "  its isolation branch survived"; else bad "  the isolation branch was deleted, dangling the commit"; fi
for w in unreachable seq isotip; do
    if survives "$D" "$w"; then ok "  worktree agent-$w survived the sweep"; else bad "  worktree agent-$w was swept"; fi
done
if survives "$D" plain-detached; then bad "  the finished detached worktree is still on disk"; else ok "  the finished detached worktree is gone"; fi
for w in unpushed dirtytracked untracked locked open; do
    if survives "$D" "$w"; then ok "  worktree agent-$w survived the sweep"; else bad "  worktree agent-$w was swept — a live worker lost its tree"; fi
done
if survives "$D" merged; then bad "  the merged worktree is still on disk"; else ok "  the merged worktree is gone"; fi
if git -C "$D" show-ref --verify --quiet refs/heads/feat/unpushed; then ok "  the unpushed branch (and its commit) survived"; else bad "  the unpushed branch was deleted"; fi
# The override stays available to an explicit path, locked or dirty.
run_teardown "$D" .claude/worktrees/agent-locked .claude/worktrees/agent-dirtytracked
expect_status "explicit paths still remove a locked and a dirty worktree" 0
if survives "$D" locked || survives "$D" dirtytracked; then bad "  explicit teardown no longer overrides lock/dirt"; else ok "  both explicit paths removed"; fi

# One mutant per guard: each must remove a live worktree, proving the matching
# survival assertion above is not vacuously green.
mutant_bites() { # <label> <sed_expr> <id_that_must_now_be_swept>
    local mut="$WORK/mut-$1" md
    mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
    sed -i.bak "$2" "$mut/teardown.sh"
    if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  mutant '$1' anchor drifted: nothing changed"; return; fi
    md="$(mkguards "mutrepo-$1")"
    OUT="$(cd "$md" && PATH="$BIN:$PATH" bash "$mut/teardown.sh" --sweep 2>&1)"; STATUS=$?
    if survives "$md" "$3"; then bad "  mutant '$1' still kept agent-$3 — the guard is not what protects it"; dump
    else ok "  mutant '$1' sweeps agent-$3 (the gate bites)"; fi
}
mutant_bites evidence 's/^    if \[ -z "\$upstream" \]; then/    upstream=x; track="[gone]"; if [ -z "$upstream" ]; then/' unpushed
mutant_bites track-only 's/^    if \[ "\$track" != "\[gone\]" \]; then/    if false; then/' open
mutant_bites clean-tree 's/^  if \[ -n "\$dirty" \]; then/  if false; then/' dirtytracked
mutant_bites untracked-all 's/--untracked-files=all/--untracked-files=no/' untracked
mutant_bites in-progress 's/^  if worktree_op_in_progress "\$path"; then/  if false; then/' rb-clean
mutant_bites unlocked 's/^  if worktree_locked "\$path"; then/  if false; then/' locked
mutant_bites reachability 's/^      if ! detached_head_reachable "\$path"; then/      if false; then/' unreachable
mutant_bites iso-filter '/^    case "\$r" in "refs\/heads\/\$ISO_PREFIX"\*) continue ;; esac/d' isotip
mutant_bites sequencer 's/ BISECT_LOG sequencer; do/ BISECT_LOG; do/' seq
mutant_bites detached-unguarded 's/^      sweep_live_guard "\$path" "(detached)" || continue/      :/' rb-locked

# Fail-closed branches, each exercised by a git that fails only that call and
# each with its own mutant: unknown is a KEEP.
mkdetached() { # <name> -> repo with one clean, unlocked, detached-at-main worktree agent-s
    local d
    d="$(mkscratch "$1" 0)"
    git -C "$d" worktree add -q --detach "$d/.claude/worktrees/agent-s" main
    echo "$d"
}
shim_case() { # <label> <fail_pat> <nth> <keep_message> <mutant_sed_expr> [fixture_fn]
    local d mut="$WORK/mut-$1" mk="${6:-mkshipped}"
    d="$($mk "shim-$1")"
    shim_sweep "$d" "$TEARDOWN" "$2" "$3"
    expect "  $1: a failed call is a KEEP, with its reason" "$4"
    if survives "$d" s; then ok "  $1: the worktree survived"; else bad "  $1: the worktree was swept on an unreadable answer"; fi
    mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
    sed -i.bak "$5" "$mut/teardown.sh"
    if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  $1: mutant anchor drifted"; return; fi
    d="$($mk "shimmut-$1")"
    shim_sweep "$d" "$mut/teardown.sh" "$2" "$3"
    if survives "$d" s; then bad "  $1: mutant without the fail-closed branch still kept the worktree"; dump
    else ok "  $1: mutant without the fail-closed branch sweeps it (the gate bites)"; fi
}
# A clean control: with nothing failing the shipped worktree IS swept.
D="$(mkshipped shim-control)"
shim_sweep "$D" "$TEARDOWN" "no-such-call" 0
if survives "$D" s; then bad "  control: the shipped worktree survived with nothing failing"; dump; else ok "  control: the shipped worktree is swept when nothing fails"; fi
shim_case status "status --porcelain" 0 "could not read the worktree status" 's/if ! dirty=/dirty=""; if false \&\& ! dirty=/'
shim_case head "symbolic-ref -q HEAD" 0 "could not read the worktree HEAD" 's/^    if \[ "\$ref_rc" -ne 0 \] \&\& \[ "\$ref_rc" -ne 1 \]; then/    if false; then/'
shim_case reachability "--contains HEAD" 0 "detached HEAD is not reachable" 's/^  return 1  # no other ref contains HEAD/  return 0  # no other ref contains HEAD/' mkdetached
shim_case git-dir "rev-parse --absolute-git-dir" 0 "git operation" '/--absolute-git-dir/s/ || return 0//;/^  \[ -n "\$gd" \] || return 0/d'
shim_case worktree-list "worktree list --porcelain" 2 "worktree is locked" 's/wts="\$(git worktree list --porcelain)" || return 0/wts="$(git worktree list --porcelain)"/'

# --- 9. an unmerged isolation branch survives the sweep (#557) ------------------
mkunmerged() { # <name> <detached|feature> -> repo whose agent-s worktree is swept, isolation branch one commit ahead
    local d wt
    d="$(mkscratch "$1" 0)"
    wt="$d/.claude/worktrees/agent-s"
    git -C "$d" worktree add -q -b worktree-agent-s "$wt" main
    echo only-copy >"$wt/only-copy.txt"
    git -C "$wt" add only-copy.txt
    git -C "$wt" commit -qm "unmerged work only the isolation branch holds"
    if [ "$2" = detached ]; then
        git -C "$wt" checkout -q --detach main
    else
        git -C "$wt" switch -q -c feat/s main
        git -C "$wt" push -q -u origin feat/s
        git -C "$d" push -q origin --delete feat/s
    fi
    echo "$d"
}
for shape in detached feature; do
    D="$(mkunmerged "unmerged-$shape" "$shape")"
    TIP="$(git -C "$D" rev-parse worktree-agent-s)"
    run_teardown "$D" --sweep
    expect_status "$shape: sweep succeeds" 0
    if survives "$D" s; then bad "  $shape: the worktree was not swept (fixture not exercising the sweep)"; else ok "  $shape: the worktree is swept"; fi
    if [ "$(git -C "$D" rev-parse -q --verify refs/heads/worktree-agent-s 2>/dev/null)" = "$TIP" ]; then ok "  $shape: the isolation branch and its commit survived"; else bad "  $shape: the unmerged isolation branch was deleted"; dump; fi
    expect_re "  $shape: the orphan phase KEPT it as unmerged" 'KEEP worktree-agent-s .*possibly unmerged'
    refute "  $shape: no in-sweep deletion of it" "deleted isolation branch worktree-agent-s"
done
# A merged isolation branch is still reclaimed, by the orphan phase.
D="$(mkscratch merged-iso 1)"
run_teardown "$D" --sweep
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-a01; then bad "  merged isolation branch worktree-agent-a01 survived the sweep"; dump; else ok "  merged isolation branch is deleted (orphan phase)"; fi
expect "  ...and says so from the orphan phase" "deleted worktree-agent-a01 (tip already in origin/main)"
# Explicit-path teardown keeps deleting it (the caller named the path as debris).
D="$(mkunmerged unmerged-explicit detached)"
run_teardown "$D" .claude/worktrees/agent-s
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-s; then bad "  explicit teardown left the isolation branch"; else ok "  explicit teardown still deletes the isolation branch"; fi
# Mutant: restore the in-sweep deletion; the commit must be lost.
mut="$WORK/mut-sweep-iso-delete"; mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
sed -i.bak 's/^  if \[ "\$from_sweep" = "1" \]; then/  if false; then/' "$mut/teardown.sh"
if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  mutant sweep-iso-delete anchor drifted"; else
    D="$(mkunmerged mutrepo-iso detached)"
    OUT="$(cd "$D" && PATH="$BIN:$PATH" bash "$mut/teardown.sh" --sweep 2>&1)"; STATUS=$?
    if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-s; then bad "  mutant sweep-iso-delete still kept the branch — the skip is not what protects it"; dump
    else ok "  mutant sweep-iso-delete loses the unmerged commit (the gate bites)"; fi
fi

# --- 9b. the merged-PR test is bound to the default branch (#557 review) --------
# An orphan isolation branch whose tip is not in origin/main but is contained in a
# merged PR: that PR counts only if it merged INTO main. One merged into a stacked
# base leaves the commits on that other branch alone, so the branch is KEPT.
mkorphanpr() { # <name> -> repo with an orphan isolation branch one commit ahead of main
    local d
    d="$(mkscratch "$1" 0)"
    git -C "$d" branch -D worktree-agent-orphan >/dev/null
    git -C "$d" switch -q -c worktree-agent-prtip main
    echo prwork >"$d/prwork.txt"
    git -C "$d" add prwork.txt
    git -C "$d" commit -qm "work shipped through a PR"
    git -C "$d" switch -q main
    echo "$d"
}
printf '%s\n' '[{"number":7,"merged_at":"2026-01-01T00:00:00Z","base":{"ref":"stack/parent"}}]' >"$WORK/pulls-stacked.json"
printf '%s\n' '[{"number":8,"merged_at":"2026-01-01T00:00:00Z","base":{"ref":"main"}}]' >"$WORK/pulls-main.json"
printf '%s\n' '[{"number":7,"merged_at":"2026-01-01T00:00:00Z","base":{"ref":"stack/parent"}},{"number":8,"merged_at":"2026-01-01T00:00:00Z","base":{"ref":"main"}}]' >"$WORK/pulls-two.json"
printf '%s\n' '[{"number":9,"merged_at":"2026-01-01T00:00:00Z","base":{"ref":null}}]' >"$WORK/pulls-nullbase.json"
printf '%s\n' '[]' >"$WORK/pulls-empty.json"
sweep_with_pulls() { # <repo> <pulls.json> <teardown.sh> — OUT/STATUS
    OUT="$(cd "$1" && MOCK_PULLS="$2" PATH="$BIN:$PATH" bash "$3" --sweep 2>&1)"; STATUS=$?
}
D="$(mkorphanpr pr-stacked)"
sweep_with_pulls "$D" "$WORK/pulls-stacked.json" "$TEARDOWN"
expect_status "PR merged into a stacked base: sweep succeeds" 0
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then ok "  a tip in a PR merged into a non-default base is KEPT"; else bad "  the isolation branch was deleted on a PR merged into a non-default base"; dump; fi
D="$(mkorphanpr pr-main)"
sweep_with_pulls "$D" "$WORK/pulls-main.json" "$TEARDOWN"
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then bad "  a tip in a PR merged into the default branch survived"; dump; else ok "  a tip in a PR merged into the default branch is deleted"; fi
expect "  ...as shipped via that merged PR" "shipped via merged PR #8"
mut="$WORK/mut-pr-base"; mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
sed -i.bak 's/ \&\& \[ "\$pr_base" = "\$BRANCH" \]//' "$mut/teardown.sh"
if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  mutant pr-base anchor drifted"; else
    D="$(mkorphanpr mutrepo-pr-base)"
    sweep_with_pulls "$D" "$WORK/pulls-stacked.json" "$mut/teardown.sh"
    if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then bad "  mutant pr-base still kept the branch — the base check is not what protects it"; dump
    else ok "  mutant pr-base deletes a tip merged only into a stacked base (the gate bites)"; fi
fi

# The loop walks every merged row: stacked-base PR first, PR merged into main second.
D="$(mkorphanpr pr-two)"
sweep_with_pulls "$D" "$WORK/pulls-two.json" "$TEARDOWN"
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then bad "  a tip in a second-listed PR merged into the default branch survived"; dump; else ok "  a main-merged PR listed after a stacked-base PR still deletes the branch"; fi
expect "  ...as shipped via the main PR (#8), not the first row" "shipped via merged PR #8"
mut="$WORK/mut-pr-head1"; mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
sed -i.bak 's/^    done <<<"\$merged_list"/    done <<<"$(printf "%s\\n" "$merged_list" | head -1)"/' "$mut/teardown.sh"
if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  mutant pr-head1 anchor drifted"; else
    D="$(mkorphanpr mutrepo-pr-head1)"
    sweep_with_pulls "$D" "$WORK/pulls-two.json" "$mut/teardown.sh"
    if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then ok "  mutant pr-head1 (first row only) keeps the branch (the gate bites)"
    else bad "  mutant pr-head1 still deleted the branch — the multi-row walk is not pinned"; dump; fi
fi
# Degenerate gh answers all fail safe to KEEP.
D="$(mkorphanpr pr-nullbase)"
sweep_with_pulls "$D" "$WORK/pulls-nullbase.json" "$TEARDOWN"
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then ok "  a null base.ref is KEPT"; else bad "  a null base.ref deleted the branch"; dump; fi
D="$(mkorphanpr pr-empty)"
sweep_with_pulls "$D" "$WORK/pulls-empty.json" "$TEARDOWN"
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then ok "  an empty PR listing is KEPT"; else bad "  an empty PR listing deleted the branch"; dump; fi
D="$(mkorphanpr pr-ghfail)"
OUT="$(cd "$D" && MOCK_GH_FAIL=1 MOCK_PULLS="$WORK/pulls-main.json" PATH="$BIN:$PATH" bash "$TEARDOWN" --sweep 2>&1)"; STATUS=$?
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then ok "  gh api exiting nonzero is KEPT"; else bad "  gh api failing deleted the branch"; dump; fi
expect "  ...with the KEEP line" "KEEP worktree-agent-prtip"

# A hostile default-branch name must never reach the jq program (gh api --jq has no
# --arg, and a double quote is a legal refname character): `x"or(true)or"` would
# make an interpolated base check true for every merged PR. The base is compared
# in shell as an exact string, so a PR merged into another base is still not enough.
HOSTILE='x"or(true)or"'
hostile_sweep() { # <repo> <teardown.sh> — OUT/STATUS, DEFAULT_BRANCH set to the hostile name
    : >"$WORK/jq.log"
    OUT="$(cd "$1" && DEFAULT_BRANCH="$HOSTILE" MOCK_JQ_LOG="$WORK/jq.log" MOCK_PULLS="$WORK/pulls-stacked.json" PATH="$BIN:$PATH" bash "$2" --sweep 2>&1)"; STATUS=$?
}
D="$(mkorphanpr pr-hostile)"
hostile_sweep "$D" "$TEARDOWN"
if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then ok "  hostile default-branch name: a tip merged only into another base is KEPT"; else bad "  a hostile default-branch name made the base check true"; dump; fi
expect "  ...and the orphan phase says KEEP" "KEEP worktree-agent-prtip"
JQ_CONST='.[] | select(.merged_at != null) | "\(.number)\t\(.base.ref)"'
hostile_jq_pinned() { # the --jq argument gh received must be the constant on every lookup
    [ -s "$WORK/jq.log" ] && [ "$(sort -u "$WORK/jq.log")" = "$JQ_CONST" ]
}
if hostile_jq_pinned; then ok "  ...and the --jq program gh received is the constant"; else bad "  the --jq program varied with the default-branch name: $(cat "$WORK/jq.log")"; fi
mut="$WORK/mut-pr-interp"; mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
OLD_JQ='      --jq "[.[] | select(.merged_at != null and .base.ref == \"$BRANCH\")][0].number // empty" 2>/dev/null || true)"'
OLD_IF='      if [ -n "$pr_num" ]; then merged_pr="$pr_num"; break; fi'
OLD_JQ="$OLD_JQ" OLD_IF="$OLD_IF" awk '
    /--jq .\.\[\] \| select\(\.merged_at != null\)/ { print ENVIRON["OLD_JQ"]; next }
    /\[ "\$pr_base" = "\$BRANCH" \]/ { print ENVIRON["OLD_IF"]; next }
    { print }' "$TEARDOWN" >"$mut/teardown.sh"
if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  mutant pr-interp anchor drifted"; else
    D="$(mkorphanpr mutrepo-pr-interp)"
    hostile_sweep "$D" "$mut/teardown.sh"
    if git -C "$D" show-ref --verify --quiet refs/heads/worktree-agent-prtip; then bad "  mutant pr-interp still kept the branch — the shell comparison is not what protects it"; dump
    else ok "  mutant pr-interp (interpolated base) deletes under a hostile name (the gate bites)"; fi
fi

# Mutant: re-interpolate $BRANCH into the jq program but KEEP the shell comparison.
# The branch still survives, so only the recorded --jq argument can catch it.
mut="$WORK/mut-pr-interp-keepcmp"; mkdir -p "$mut"; cp "$TEARDOWN" "$GUARD_SH" "$mut/"
OLD_JQ2='      --jq ".[] | select(.merged_at != null and .base.ref == \"$BRANCH\") | \"\\(.number)\\t\\(.base.ref)\"" 2>/dev/null || true)"'
OLD_JQ2="$OLD_JQ2" awk '/--jq .\.\[\] \| select\(\.merged_at != null\) \|/ { print ENVIRON["OLD_JQ2"]; next } { print }' "$TEARDOWN" >"$mut/teardown.sh"
if cmp -s "$mut/teardown.sh" "$TEARDOWN"; then bad "  mutant pr-interp-keepcmp anchor drifted"; else
    D="$(mkorphanpr mutrepo-pr-interp-keepcmp)"
    hostile_sweep "$D" "$mut/teardown.sh"
    if hostile_jq_pinned; then bad "  mutant pr-interp-keepcmp passed the constant-program check"; dump
    else ok "  mutant pr-interp-keepcmp (interpolated jq, shell compare kept) is caught by the --jq assertion"; fi
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "teardown-args tests: all green" >&2
    exit 0
else
    echo "teardown-args tests: FAILURES above" >&2
    exit 1
fi
