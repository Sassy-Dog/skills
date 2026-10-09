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
# Seven properties are asserted (7 was added by #486):
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
    api)  : ;;                           # commits/<tip>/pulls -> no merged PR
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
H_SWEEP1='== sweep: agent worktrees whose remote branch is gone'
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

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "teardown-args tests: all green" >&2
    exit 0
else
    echo "teardown-args tests: FAILURES above" >&2
    exit 1
fi
