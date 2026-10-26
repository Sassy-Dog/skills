#!/usr/bin/env bash
# test-poll-queue-eject.sh — pins poll-queue.sh's OPEN/isInMergeQueue:false
# disambiguation (issue #234).
#
# Why this exists: the race guard added in #60 anticipates the PR-STATE flip
# lagging the queue-entry removal, and disambiguates on the last
# RemovedFromMergeQueueEvent's reason. But the removal EVENT can lag too. On
# qr-ninja#847 a tick landed in the sub-second window where GraphQL answered
# `isInMergeQueue:false` with an EMPTY timeline for a PR that had merged
# cleanly that same second, and the fallback called it `ejected` — a terminal,
# loud verdict whose attached guidance points at eject recovery, i.e. at
# re-enqueueing something that has already landed.
#
# What makes it worth a gate rather than a memo is that it is wrong in BOTH
# directions at once: the human-facing line shouts EJECTED about a merge, and
# the final JSON says `"result":"ejected"` with no warning at all, so a
# coordinator branching on that JSON takes the recovery path silently. An empty
# timeline simply does not distinguish "never enqueued" from "the removal event
# has not materialised yet" — and the script already holds the disproof in
# QSTATES, which it was printing in the very line that got it wrong.
#
# Six properties are asserted about poll-queue.sh (part 7 below adds merge-shepherd.sh's
# --expected-head cases, #585, against a second stubbed `gh` beside this one):
#
#   1. The lag case is NOT terminal: seen in the queue on an earlier tick, then
#      isInMergeQueue:false with an empty timeline, re-reads instead of
#      emitting a verdict — and keeps re-reading until the GLOBAL
#      POLL_MAX_TICKS ceiling stops it with exit 124 (undetermined). That
#      "runs to the ceiling" assertion is also how "no per-PR counter was
#      added" is enforced behaviourally: any per-PR fall-through would resolve
#      `ejected` before the ceiling and fail here.
#   2. The lag RESOLVES: once the removal event materialises with reason
#      "merged", the same PR terminates as `merged`. A non-terminal branch that
#      could never converge would be a hang, not a fix.
#   3. A genuine eject stays terminal and immediate: a removal event whose
#      reason is not "merged" still resolves `ejected` on the tick it appears.
#   4. A PR that truly never enqueued stays terminal and immediate: empty
#      QSTATES plus an empty timeline is still `ejected` — the --auto
#      method-flag trap must not be swallowed by the new branch.
#   5. #60's own case is untouched: reason "merged" resolves `merged`.
#   6. Source-level: exactly ONE assignment of `ejected` exists (a second one
#      is what a per-PR bounding counter would look like), and the two prose
#      call sites that documented the old two-way split — the header contract
#      and the operator guidance under EJECTED — no longer state it. Those
#      must-not-exist checks run against a WHITESPACE-FLATTENED copy of the
#      script, because both call sites are hard-wrapped comment/echo blocks and
#      a line-scoped grep for stale wording turns a re-wrap into a false PASS.
#
# Network-free: a PATH-shimmed mock `gh` serving recorded GraphQL payloads, one
# per call, from a scenario directory. poll-queue.sh's only other gh use is the
# repo lookup, which REPO= suppresses — so a machine with a real authenticated
# gh behaves exactly like CI, and any unexpected invocation makes the mock exit
# non-zero, which surfaces as a WARN line the passing scenarios refute.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-poll-queue-eject.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-poll-queue-eject: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

POLL="$REPO_ROOT/skills/pr-shepherd/scripts/poll-queue.sh"
[ -f "$POLL" ] || { echo "test-poll-queue-eject: $POLL not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test-poll-queue-eject: jq is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "poll-queue-eject tests (work: $WORK)" >&2

# --- the mock gh --------------------------------------------------------------
# poll-queue.sh makes exactly one kind of gh call per PR per tick: `gh api
# graphql … --jq .data.repository.pullRequest`, i.e. it expects the pullRequest
# object itself on stdout. The mock serves the Nth call from <scenario>/N.json,
# falling back to <scenario>/repeat.json once the recorded ticks run out.
cat >"$BIN/gh" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    api)
        n=$(( $(cat "$MOCK_COUNTER") + 1 ))
        echo "$n" >"$MOCK_COUNTER"
        echo "graphql" >>"$MOCK_CALLS"
        f="$SCENARIO_DIR/$n.json"
        [ -f "$f" ] || f="$SCENARIO_DIR/repeat.json"
        [ -f "$f" ] || { echo "mock gh: no payload for call $n in $SCENARIO_DIR" >&2; exit 1; }
        cat "$f"
        ;;
    *) echo "mock gh: unhandled invocation: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$BIN/gh"

# --- recorded payloads --------------------------------------------------------
# The three shapes the OPEN/false guard has to tell apart, plus the in-queue
# tick that is what populates QSTATES in the first place.
IN_QUEUE='{"state":"OPEN","isInMergeQueue":true,"mergeQueueEntry":{"state":"AWAITING_CHECKS","position":1},"timelineItems":{"nodes":[]}}'
GONE_NO_EVENT='{"state":"OPEN","isInMergeQueue":false,"mergeQueueEntry":null,"timelineItems":{"nodes":[]}}'
GONE_MERGED='{"state":"OPEN","isInMergeQueue":false,"mergeQueueEntry":null,"timelineItems":{"nodes":[{"reason":"merged"}]}}'
GONE_DEQUEUED='{"state":"OPEN","isInMergeQueue":false,"mergeQueueEntry":null,"timelineItems":{"nodes":[{"reason":"dequeued"}]}}'

scenario() { # <name> <payload> [payload ...]  — the last one also becomes repeat.json
    local dir="$WORK/scenario-$1" n=0 p=""
    shift
    mkdir -p "$dir"
    for p in "$@"; do
        n=$((n + 1))
        printf '%s\n' "$p" >"$dir/$n.json"
    done
    printf '%s\n' "$p" >"$dir/repeat.json"
    echo "$dir"
}

# --- runner + assertions ------------------------------------------------------
STDOUT=""
STDERR=""
STATUS=0
CALLS=0
run_poll() { # <scenario_dir> <max_ticks>
    local dir="$1" max="$2"
    echo 0 >"$WORK/counter"
    : >"$WORK/calls"
    PATH="$BIN:$PATH" \
    SCENARIO_DIR="$dir" MOCK_COUNTER="$WORK/counter" MOCK_CALLS="$WORK/calls" \
    REPO=mock-org/mock-repo POLL_INTERVAL=0 POLL_MAX_TICKS="$max" \
        bash "$POLL" 847 >"$WORK/stdout" 2>"$WORK/stderr"
    STATUS=$?
    STDOUT="$(cat "$WORK/stdout")"
    STDERR="$(cat "$WORK/stderr")"
    CALLS="$(grep -c . "$WORK/calls")"
}

dump() {
    printf '%s\n' "$STDERR" | sed 's/^/          | E /' >&2
    printf '%s\n' "$STDOUT" | sed 's/^/          | O /' >&2
}

expect_err() { # <label> <needle>
    if grep -qF -- "$2" <<<"$STDERR"; then ok "$1"; else bad "$1 — expected on stderr: $2"; dump; fi
}
refute_err() { # <label> <needle>
    if grep -qF -- "$2" <<<"$STDERR"; then bad "$1 — must NOT appear on stderr: $2"; dump; else ok "$1"; fi
}
expect_out() { # <label> <needle>
    if grep -qF -- "$2" <<<"$STDOUT"; then ok "$1"; else bad "$1 — expected on stdout: $2"; dump; fi
}
refute_out() { # <label> <needle>
    if grep -qF -- "$2" <<<"$STDOUT"; then bad "$1 — must NOT appear on stdout: $2"; dump; else ok "$1"; fi
}
expect_status() { # <label> <expected>
    if [ "$STATUS" = "$2" ]; then ok "$1 (exit $STATUS)"; else bad "$1 — exit $STATUS, expected $2"; dump; fi
}

# --- 1. the lag case is non-terminal and runs to the global ceiling -----------
# Tick 1 sees the PR in the queue (this is what fills QSTATES); every tick after
# that is the failing shape from #234 — entry gone, timeline still empty.
echo "1. removal-event lag stays non-terminal (issue #234)" >&2
D="$(scenario lag "$IN_QUEUE" "$GONE_NO_EVENT")"
run_poll "$D" 4
expect_status "unresolved run ends at the POLL_MAX_TICKS ceiling, not with a verdict" 124
expect_err "the lag is reported as a re-read" "queue entry gone, removal event not yet visible"
expect_err "  and it names the queue-entry state that disproves 'never enqueued'" "AWAITING_CHECKS"
refute_err "no EJECTED verdict for a PR that was seen in the queue" "EJECTED"
refute_out "no final JSON verdict either" '"result":"ejected"'
# The ceiling is the ONLY thing that stopped it: a per-PR counter with a
# fall-through would have resolved `ejected` before tick 4 (issue #234 decision).
expect_err "it kept re-reading all the way to the ceiling" "--- tick 4 / 4"
if [ "$CALLS" = "4" ]; then
    ok "one GraphQL read per tick, four ticks (no extra calls)"
else
    bad "expected 4 GraphQL reads, got $CALLS"
    dump
fi
refute_err "no gh call fell outside the mock's contract" "WARN:"

# --- 2. the lag resolves rather than hanging ---------------------------------
echo "2. once the removal event lands, the same PR terminates" >&2
D="$(scenario lag-resolves "$IN_QUEUE" "$GONE_NO_EVENT" "$GONE_MERGED")"
run_poll "$D" 8
expect_status "run completes normally" 0
expect_err "the intermediate tick re-read" "queue entry gone, removal event not yet visible"
expect_err "the PR resolves merged once the event materialises" 'removal reason "merged"'
expect_err "  terminal on the tick the event appeared" "--- all PRs terminal at tick 3 ---"
expect_out "final JSON reports merged" '"result":"merged"'
refute_out "final JSON never says ejected" '"result":"ejected"'

# --- 3. a genuine eject is still terminal and immediate ----------------------
echo "3. a real eject (removal event, reason not 'merged') still fires" >&2
D="$(scenario real-eject "$IN_QUEUE" "$GONE_DEQUEUED")"
run_poll "$D" 8
expect_status "run completes normally" 0
expect_err "EJECTED is reported" "EJECTED"
expect_err "  the reason is carried through" "removal reason: dequeued"
expect_err "  terminal on the tick the event appeared" "--- all PRs terminal at tick 2 ---"
expect_out "final JSON reports ejected" '"result":"ejected"'
expect_out "  and carries the last queue-entry state" '"queueEntryState":"AWAITING_CHECKS"'
refute_err "the eject is not softened into a re-read" "removal event not yet visible"

# --- 4. never enqueued is still terminal and immediate -----------------------
# The --auto method-flag trap: the enqueue never took, so the PR is OPEN,
# isInMergeQueue:false, timeline empty AND QSTATES empty. The new branch must
# not swallow this one — it is the case the loud verdict exists for.
echo "4. a PR that never enqueued is still called immediately" >&2
D="$(scenario never-enqueued "$GONE_NO_EVENT")"
run_poll "$D" 8
expect_status "run completes normally" 0
expect_err "EJECTED is reported" "EJECTED"
expect_err "  and says the PR was never seen in the queue" "never seen in queue"
expect_err "  terminal on the very first tick" "--- all PRs terminal at tick 1 ---"
expect_out "final JSON reports ejected" '"result":"ejected"'
expect_out "  with a null queue-entry state" '"queueEntryState":null'
refute_err "not softened into a re-read" "removal event not yet visible"

# --- 5. #60's case is untouched ----------------------------------------------
echo "5. the #60 merged-but-state-not-flipped race still resolves merged" >&2
D="$(scenario merged-race "$IN_QUEUE" "$GONE_MERGED")"
run_poll "$D" 8
expect_status "run completes normally" 0
expect_err "MERGED is reported with the lagging-flip note" 'removal reason "merged"; PR-state flip lagging'
expect_out "final JSON reports merged" '"result":"merged"'
refute_err "no eject" "EJECTED"

# --- 6. source-level guards ---------------------------------------------------
echo "6. source-level shape and prose guards" >&2
ejected_sites="$(grep -c 'RESULTS\[\$i\]="ejected"' "$POLL")"
if [ "$ejected_sites" = "1" ]; then
    ok "'ejected' is assigned at exactly one site"
else
    bad "'ejected' is assigned at $ejected_sites sites in $POLL — a second one is what a per-PR bounding counter looks like, and its fall-through verdict re-creates issue #234 on a merely slow timeline"
fi

# Both prose call sites are hard-wrapped, so a line-scoped grep would read a
# re-wrap as a removal. Flatten first: the question is whether the wording is
# still in the file at all, not which line it sits on.
FLAT="$WORK/poll-queue.flat"
tr '\n' ' ' <"$POLL" | tr -s ' \t' ' ' >"$FLAT"
refute_flat() { # <label> <needle>
    if grep -qF -- "$2" "$FLAT"; then
        bad "$1 — still present in $POLL: $2"
    else
        ok "$1"
    fi
}
expect_flat() { # <label> <needle>
    if grep -qF -- "$2" "$FLAT"; then ok "$1"; else bad "$1 — missing from $POLL: $2"; fi
}
refute_flat "header contract no longer collapses 'no event' into ejected" \
    'any other reason, or no event -> result "ejected"'
expect_flat "header contract documents the non-terminal third branch" \
    'no event, but seen in queue -> NOT terminal'
refute_flat "operator guidance no longer enumerates only two cases" \
    'Either the queue ejected it (merge_group failed on the rebased ref)'
expect_flat "operator guidance names the re-read case it no longer covers" \
    'stays non-terminal and re-reads (#234)'
expect_flat "the eject guidance still warns against blind re-enqueue" \
    'Do NOT blindly'

# --- 7. merge-shepherd.sh --expected-head (issue #585) -----------------------
# The merge half of the same queue family. test-teardown-args.sh already pins
# merge-shepherd.sh's post-merge teardown() at source level; these cases are the
# first to EXECUTE the script, against a stubbed gh, and are scoped to
# --expected-head (the parse and validation, the head gate and exit 25, the
# bound writes and the re-read after a refused one, the bound --direct
# staleness update, --watch). They prove nothing about its other gates.
echo "7. merge-shepherd.sh --expected-head binds the merge to the reviewed commit (#585)" >&2
MS_SRC="$REPO_ROOT/skills/pr-shepherd/scripts"
H1="$(printf 'a%.0s' $(seq 1 40))"
H2="$(printf 'b%.0s' $(seq 1 40))"
H64="$(printf 'c%.0s' $(seq 1 64))"

MSBIN="$WORK/msbin"; mkdir -p "$MSBIN"
# A second mock gh, for the write path. It logs every argv to $MS_CALLS and
# answers by query text; `--jq` outputs are served already filtered. State
# transitions (enqueue -> in queue, squash merge -> MERGED) go through $MS_STATE
# so the script's own confirmation read agrees with what the mock was asked to do.
cat >"$MSBIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MS_CALLS"
all="$*"
case "$1" in
    api)
        case "$all" in
            *update-branch*)      [ "${MS_UPDATE_RC:-0}" = 0 ] && { echo '{}'; exit 0; }; echo "update refused" >&2; exit 1 ;;
            *enqueuePullRequest*)
                if [ "${MS_ENQUEUE_RC:-0}" = 0 ]; then echo "OPEN CLEAN true" >"$MS_STATE"; echo '{}'; exit 0; fi
                echo "enqueue refused" >&2; exit 1 ;;
            *isInMergeQueue*)     cat "$MS_STATE" ;;
            *headRefOid*)         [ "${MS_HEAD_RC:-0}" = 0 ] || exit 1
                                  n=$(( $(cat "$MS_HEADCNT") + 1 )); echo "$n" >"$MS_HEADCNT"
                                  # a read that fails from the Nth on (the gate's own read still works)
                                  if [ -n "${MS_HEAD_FAIL_AT:-}" ] && [ "$n" -ge "$MS_HEAD_FAIL_AT" ]; then exit 1; fi
                                  if [ -n "${MS_MOVE_AT:-}" ] && [ "$n" -ge "$MS_MOVE_AT" ]; then echo "$MS_HEAD_LATER"; else echo "$MS_HEAD"; fi ;;
            *"pullRequest(number:\$pr){ id }"*) [ -n "${MS_NOID:-}" ] || echo "PR_node_1" ;;
            */stacks*)            echo "HTTP/2.0 404 Not Found"; exit 1 ;;
            */compare/*)          echo "${MS_BEHIND:-0}" ;;
            *) echo "mock gh: unhandled api: $all" >&2; exit 1 ;;
        esac ;;
    pr)
        case "$2" in
            view)  echo "0 0 1" ;;
            update-branch) exit 0 ;;
            merge) if [ "${MS_MERGE_RC:-0}" = 0 ]; then
                       case "$all" in
                           *--squash*) echo "MERGED CLEAN false" >"$MS_STATE" ;;
                           *--auto*)   echo "OPEN CLEAN true" >"$MS_STATE" ;;
                       esac
                   fi
                   exit "${MS_MERGE_RC:-0}" ;;
            *) echo "mock gh: unhandled pr: $all" >&2; exit 1 ;;
        esac ;;
    *) echo "mock gh: unhandled: $all" >&2; exit 1 ;;
esac
MOCK
printf '#!/bin/sh\nexit 0\n' >"$MSBIN/sleep"
chmod +x "$MSBIN/gh" "$MSBIN/sleep"

MS_CALLS="$WORK/ms-calls"; MS_STATE="$WORK/ms-state"; MS_HEADCNT="$WORK/ms-headcnt"
MS_OUT=""; MS_RC=0
ms_run() { # <script> <head the PR reports> <args…>   (env MS_* passes through)
    local script="$1" head="$2"; shift 2
    : >"$MS_CALLS"; echo "OPEN CLEAN false" >"$MS_STATE"; echo 0 >"$MS_HEADCNT"
    # GIT_DIR points nowhere, so the script finds no local checkout and skips
    # its teardown instead of touching this repo's.
    MS_OUT="$(cd "$WORK" && PATH="$MSBIN:$PATH" MS_CALLS="$MS_CALLS" MS_STATE="$MS_STATE" MS_HEADCNT="$MS_HEADCNT" MS_HEAD="$head" \
        MERGE_SHEPHERD_UPDATE_WAIT="${MS_UPDATE_WAIT:-0}" MERGE_SHEPHERD_UPDATE_POLL="${MS_UPDATE_POLL:-0}" \
        GIT_DIR="$WORK/no-such-git-dir" bash "$script" 585 --repo mock-org/mock-repo "$@" 2>&1)"
    MS_RC=$?
}
ms_wrote() { grep -qE 'enqueuePullRequest|pr merge' "$MS_CALLS"; }
ms_any_call() { [ -s "$MS_CALLS" ]; }

# ms_suite <script> — appends a label to MS_FAILED for each case that does not hold.
MS_FAILED=""
ms_expect() { # <label> <condition rc: 0 holds>
    [ "$2" = 0 ] || MS_FAILED="$MS_FAILED|$1"
}
ms_rc() { # <label> <expected exit status of the last ms_run>
    [ "$MS_RC" = "$2" ] || MS_FAILED="$MS_FAILED|$1 (exit $MS_RC)"
}
ms_suite() {
    local sc="$1" r
    MS_FAILED=""
    # no flag: unchanged — no head read, no expectedHeadOid, no --match-head-commit
    ms_run "$sc" "$H1"
    ms_rc "no flag: queue enqueues (exit 10)" 10
    ms_expect "no flag: no expectedHeadOid and no head read" "$(! grep -qE 'expectedHeadOid|headRefOid' "$MS_CALLS"; echo $?)"
    ms_run "$sc" "$H1" --direct
    ms_rc "no flag: direct merges (exit 0)" 0
    ms_expect "no flag: direct merge carries no --match-head-commit" "$(! grep -q -- '--match-head-commit' "$MS_CALLS"; echo $?)"
    # match: queue
    ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "match: queue enqueues (exit 10)" 10
    ms_expect "match: a successful bound enqueue prints no BOUND ENQUEUE FAILED" "$(! grep -q 'BOUND ENQUEUE FAILED' <<<"$MS_OUT"; echo $?)"
    ms_expect "match: the mutation input carries expectedHeadOid" "$(grep -q 'expectedHeadOid:\$eho' "$MS_CALLS"; echo $?)"
    ms_expect "match: the mutation is given the reviewed id" "$(grep -q "eho=$H1" "$MS_CALLS"; echo $?)"
    ms_run "$sc" "$H64" --expected-head "$H64"
    ms_rc "match: a 64-hex id is accepted" 10
    # match: direct
    ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "match: direct merges (exit 0)" 0
    ms_expect "match: direct merge carries --match-head-commit" \
        "$(grep -qE "pr merge 585 .*--squash --delete-branch --match-head-commit $H1" "$MS_CALLS"; echo $?)"
    # mismatch: queue and direct — exit 25, nothing written
    ms_run "$sc" "$H2" --expected-head "$H1"
    ms_rc "mismatch queue: exit 25" 25
    ms_expect "mismatch queue: no enqueue or merge call" "$(! ms_wrote; echo $?)"
    ms_expect "mismatch queue: says the head moved" "$(grep -q 'HEAD MOVED' <<<"$MS_OUT"; echo $?)"
    ms_run "$sc" "$H2" --direct --expected-head "$H1"
    ms_rc "mismatch direct: exit 25" 25
    ms_expect "mismatch direct: no enqueue or merge call" "$(! ms_wrote; echo $?)"
    # an unreadable head is a wait, never a merge
    MS_HEAD_RC=1 ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "unreadable head: exit 11" 11
    ms_expect "unreadable head: no enqueue or merge call" "$(! ms_wrote; echo $?)"
    # no flag, the --auto fallback: unbound, exactly as before
    MS_ENQUEUE_RC=1 ms_run "$sc" "$H1"
    ms_rc "no flag: fallback enqueues (exit 10)" 10
    ms_expect "no flag: the unbound fallback prints no BOUND ENQUEUE FAILED" "$(! grep -q 'BOUND ENQUEUE FAILED' <<<"$MS_OUT"; echo $?)"
    MS_ENQUEUE_RC=1 MS_MERGE_RC=1 ms_run "$sc" "$H1"
    ms_rc "no flag: mutation and fallback both fail: exit 11" 11
    ms_expect "no flag: a failing unbound enqueue prints no BOUND ENQUEUE FAILED (the fallback owns it)" "$(! grep -q 'BOUND ENQUEUE FAILED' <<<"$MS_OUT"; echo $?)"
    ms_expect "no flag: fallback is a bare gh pr merge --auto" \
        "$(grep -qE 'pr merge 585 .*--auto( |$)' "$MS_CALLS" && ! grep -q -- '--match-head-commit' "$MS_CALLS"; echo $?)"
    # a failing merge call is not confirmed (also keeps MS_MERGE_RC honest)
    MS_MERGE_RC=1 ms_run "$sc" "$H1" --direct
    ms_rc "no flag: a failed direct merge is not confirmed (exit 11)" 11
    # a refused BOUND write: a moved head is 25 and the fallback is not tried
    MS_ENQUEUE_RC=1 MS_MOVE_AT=2 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "bound enqueue refused, head moved: exit 25" 25
    ms_expect "bound enqueue refused, head moved: the --auto fallback is not tried" "$(! grep -q 'pr merge' "$MS_CALLS"; echo $?)"
    # #587: no armed state outlives a bound run. --match-head-commit is checked only when
    # auto-merge is ARMED, so a bound run never arms the --auto fallback: the mutation failing
    # (or the node id unresolved) is exit 11, with no `pr merge` call at all.
    MS_ENQUEUE_RC=1 ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "bound enqueue refused, head unchanged: exit 11, retried next pass" 11
    # #590: that 11 is indistinguishable from "checks pending" without a stable stdout reason line
    ms_expect "bound enqueue refused, head unchanged: stdout names BOUND ENQUEUE FAILED and the cause" \
        "$(grep -q '^BOUND ENQUEUE FAILED — the enqueue mutation was refused' <<<"$MS_OUT"; echo $?)"
    ms_expect "bound enqueue refused, head unchanged: no auto-merge armed (no pr merge call)" "$(! grep -q 'pr merge' "$MS_CALLS"; echo $?)"
    MS_NOID=1 ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "bound, node id unresolved: exit 11" 11
    ms_expect "bound, node id unresolved: stdout names BOUND ENQUEUE FAILED and the cause" \
        "$(grep -q '^BOUND ENQUEUE FAILED — the PR node id did not resolve' <<<"$MS_OUT"; echo $?)"
    # a refused enqueue whose head re-read ALSO fails must not claim "unchanged" (#590 review)
    MS_ENQUEUE_RC=1 MS_HEAD_FAIL_AT=2 ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "bound enqueue refused, head re-read fails: exit 11" 11
    ms_expect "bound enqueue refused, head re-read fails: says the head could not be re-read" \
        "$(grep -q '^BOUND ENQUEUE FAILED — .*the head could not be re-read' <<<"$MS_OUT"; echo $?)"
    ms_expect "bound enqueue refused, head re-read fails: never claims the head is unchanged" \
        "$(! grep -q 'head is unchanged' <<<"$MS_OUT"; echo $?)"
    ms_expect "bound, node id unresolved: no auto-merge armed (no pr merge call)" "$(! grep -q 'pr merge' "$MS_CALLS"; echo $?)"
    # node id unresolved AND the head moves after the gate's read: no bound write was attempted, so this pass
    # does not re-read the head and answers 11; the NEXT pass's head gate (the PR now reports H2) answers 25.
    MS_NOID=1 MS_MOVE_AT=2 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --expected-head "$H1"
    ms_rc "bound, node id unresolved, head moved after the gate: exit 11 (no write was attempted)" 11
    ms_expect "bound, node id unresolved, head moved: no auto-merge armed" "$(! grep -q 'pr merge' "$MS_CALLS"; echo $?)"
    MS_NOID=1 ms_run "$sc" "$H2" --expected-head "$H1"
    ms_rc "bound, node id unresolved, next pass sees the moved head: exit 25" 25
    ms_expect "bound, next pass: nothing written" "$(! ms_wrote; echo $?)"
    MS_NOID=1 ms_run "$sc" "$H1"
    ms_rc "no flag, node id unresolved: the --auto fallback still enqueues (exit 10)" 10
    MS_MERGE_RC=1 MS_MOVE_AT=3 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "bound direct merge refused, head moved: exit 25" 25
    MS_MERGE_RC=1 ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "bound direct merge refused, head unchanged: exit 11 as before" 11
    # the bound --direct staleness update
    # #590: the REST update is asynchronous (202), so 25 only once the head has actually moved.
    MS_BEHIND=3 MS_MOVE_AT=2 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "stale + bound: update succeeds and the head moved, exit 25 (re-review the update; not 11, a re-run would only reach 25)" 25
    ms_expect "stale + bound: the 25 names the new head" "$(grep -q "to $H2" <<<"$MS_OUT"; echo $?)"
    MS_BEHIND=3 ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "stale + bound: update accepted but the head never moves within the bound, exit 11" 11
    ms_expect "stale + bound: never moved: says update requested, head not yet moved" \
        "$(grep -q 'update requested, head not yet moved — re-run' <<<"$MS_OUT"; echo $?)"
    ms_expect "stale + bound: never moved: no merge call" "$(! grep -qE '^pr merge' "$MS_CALLS"; echo $?)"
    # the wait env is validated before any PUT: a poll below 1 with a wait above 0 would spin
    MS_UPDATE_WAIT=5 MS_UPDATE_POLL=0 MS_BEHIND=3 ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "update wait above 0 with poll 0: refused, exit 1" 1
    ms_expect "update wait above 0 with poll 0: refused before ANY gh call (so before the PUT)" "$(! ms_any_call; echo $?)"
    MS_UPDATE_WAIT=0 MS_UPDATE_POLL=0 MS_BEHIND=3 MS_MOVE_AT=2 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "update wait 0 with poll 0 is allowed" 25
    MS_UPDATE_WAIT=x MS_UPDATE_POLL=1 ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "a non-numeric update wait: refused, exit 1" 1
    # "08" is invalid octal to bash arithmetic: it must read as 8
    MS_UPDATE_WAIT=08 MS_UPDATE_POLL=01 MS_BEHIND=3 MS_MOVE_AT=2 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "update wait 08 and poll 01 are read as decimal (accepted, head moved: exit 25)" 25
    # under --watch the wait is clamped to the watch budget: a 3 s wait inside a 1 s watch ends in ~1 s
    t0=$SECONDS
    MS_UPDATE_WAIT=3 MS_UPDATE_POLL=1 MS_BEHIND=3 ms_run "$sc" "$H1" --direct --expected-head "$H1" --watch 1 --poll 0
    ms_expect "watch: the update wait is clamped to the watch budget (finished in under 3 s)" "$(if [ $((SECONDS - t0)) -lt 3 ]; then echo 0; else echo 1; fi)"
    ms_expect "watch: an unmoved head under the clamp still exits through the bounded watch (11)" \
        "$([ "$MS_RC" = 11 ] && grep -q 'bounded-exit' <<<"$MS_OUT"; echo $?)"
    MS_UPDATE_WAIT=2 MS_UPDATE_POLL=1 MS_BEHIND=3 MS_MOVE_AT=4 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "stale + bound: the head moves on a later read within the bound: exit 25" 25
    MS_BEHIND=3 MS_MOVE_AT=2 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_expect "stale + bound: says the head moved by design" "$(grep -q 'moved by design' <<<"$MS_OUT"; echo $?)"
    ms_expect "stale + bound: REST update carries expected_head_sha" "$(grep -q "update-branch -f expected_head_sha=$H1" "$MS_CALLS"; echo $?)"
    ms_expect "stale + bound: no unbound gh pr update-branch and no merge" "$(! grep -qE '^pr (update-branch|merge)' "$MS_CALLS"; echo $?)"
    MS_BEHIND=3 MS_UPDATE_RC=1 MS_MOVE_AT=3 MS_HEAD_LATER="$H2" ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "stale + bound: update refused, head moved: exit 25" 25
    MS_BEHIND=3 MS_UPDATE_RC=1 ms_run "$sc" "$H1" --direct --expected-head "$H1"
    ms_rc "stale + bound: update refused, head unchanged: exit 11" 11
    ms_expect "stale + bound: update refused, head unchanged: update it by hand" "$(grep -q 'update it by hand' <<<"$MS_OUT"; echo $?)"
    MS_BEHIND=3 ms_run "$sc" "$H1" --direct
    ms_rc "stale + no flag: unchanged, exit 11" 11
    ms_expect "stale + no flag: uses gh pr update-branch, not the REST form" \
        "$(grep -q '^pr update-branch' "$MS_CALLS" && ! grep -q 'expected_head_sha' "$MS_CALLS"; echo $?)"
    # 25 is terminal under --watch (not re-polled)
    ms_run "$sc" "$H2" --expected-head "$H1" --watch 1 --poll 0
    ms_expect "watch: exit 25 ends the loop" "$([ "$MS_RC" = 25 ] && ! grep -q 'bounded-exit' <<<"$MS_OUT"; echo $?)"
    # malformed ids: exit 1 before ANY gh call
    for r in "" HEAD main abc123 "${H1}0" "${H1:0:39}" "$(printf 'A%.0s' $(seq 1 40))" "-x" "${H1:0:39}g"; do
        ms_run "$sc" "$H1" --expected-head "$r"
        ms_rc "malformed '$r': exit 1" 1
        ms_expect "malformed '$r': refused before any gh call" "$(! ms_any_call; echo $?)"
    done
    ms_run "$sc" "$H1" --expected-head
    ms_expect "missing value: exit 1 before any gh call" "$([ "$MS_RC" = 1 ] && ! ms_any_call; echo $?)"
}

ms_suite "$MS_SRC/merge-shepherd.sh"
if [ -z "$MS_FAILED" ]; then ok "merge-shepherd --expected-head: every committed case holds"
else bad "merge-shepherd --expected-head cases failed:$MS_FAILED"; fi

# Mutants: each changes one construct in a COPY (with its siblings) and the same
# suite must then fail. A mutant that does not apply, or that leaves the suite
# green, is a vacuous case.
MUT="$WORK/ms-mut"; mkdir -p "$MUT"
ms_mutant() { # <label> <old text, must occur once> <new text>
    local label="$1" d="$MUT/$1"
    rm -rf "$d"; mkdir -p "$d"; cp "$MS_SRC"/*.sh "$d/"
    if ! python3 -I -c '
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
' "$d/merge-shepherd.sh" "$2" "$3"; then
        bad "merge-shepherd mutant '$label' did not apply (its anchor moved)"; return
    fi
    ms_suite "$d/merge-shepherd.sh"
    if [ -n "$MS_FAILED" ]; then ok "merge-shepherd mutant '$label' fails the suite"
    else bad "merge-shepherd mutant '$label' passes the suite — its case is vacuous"; fi
}
ms_mutant no-mismatch-gate '[ "$live_head" != "$EXPECTED_HEAD" ]' 'false'
ms_mutant no-unreadable-gate 'if [ -z "$live_head" ]; then' 'if false; then'
ms_mutant no-expectedHeadOid-field 'enqueuePullRequest(input:{pullRequestId:$prid,expectedHeadOid:$eho})' 'enqueuePullRequest(input:{pullRequestId:$prid})'
ms_mutant empty-expectedHeadOid-value '-f eho="$EXPECTED_HEAD"' '-f eho=""'
ms_mutant bound-run-arms-auto-fallback 'under --expected-head; re-run" >&2
    return 1' 'under --expected-head; re-run" >&2
    bash "$GH_RETRY" -- pr merge "$PR" --repo "$REPO" --auto --match-head-commit "$EXPECTED_HEAD" >/dev/null && return 0
    return 1'
ms_mutant no-match-on-direct '          --match-head-commit "$EXPECTED_HEAD" >/dev/null \' '          >/dev/null \'
ms_mutant no-charset-check '*[!0-9a-f]*) echo' 'NEVER) echo'
ms_mutant no-length-check '40|64) : ;;' '*) : ;;'
ms_mutant 25-not-terminal '0|1|20|22|24|25) exit' '0|1|20|22|24) exit'
ms_mutant empty-value-runs-unbound 'EXPECTED_HEAD="$2"; EXPECTED_HEAD_SET=1; shift 2' '[ -n "$2" ] && EXPECTED_HEAD_SET=1; EXPECTED_HEAD="$2"; shift 2'
ms_mutant no-moved-check-after-bound-enqueue '      elif [ "$refused_head" != "$EXPECTED_HEAD" ]; then
        return 25' '      elif false; then
        return 25'
ms_mutant no-moved-check-after-bound-direct 'head_moved && { echo "HEAD MOVED — the bound merge' 'false && { echo "HEAD MOVED — the bound merge'
ms_mutant noid-path-rereads-head 'under --expected-head; re-run" >&2
    return 1' 'under --expected-head; re-run" >&2
    head_moved && return 25
    return 1'
ms_mutant bound-update-exits-11 'then re-run with the new head"
              return 25' 'then re-run with the new head"
              return 11'
ms_mutant no-expected-sha-on-update '-f expected_head_sha="$EXPECTED_HEAD"' '-f expected_head_sha=""'
ms_mutant no-moved-check-after-refused-update 'elif head_moved; then
            echo "HEAD MOVED — reviewed' 'elif false; then
            echo "HEAD MOVED — reviewed'
ms_mutant update-wait-loop-removed '              [ -n "$new_head" ] && [ "$new_head" != "$EXPECTED_HEAD" ] && break' '              break'
ms_mutant bound-failed-line-claims-unchanged-on-failed-read 'if [ -z "$refused_head" ]; then' 'if false; then'
ms_mutant no-poll-floor 'if [ "$UPDATE_WAIT" -gt 0 ] && [ "$UPDATE_POLL" -lt 1 ]; then' 'if false; then'
ms_mutant no-octal-normalisation 'UPDATE_WAIT=$((10#$UPDATE_WAIT)); UPDATE_POLL=$((10#$UPDATE_POLL))' 'UPDATE_WAIT=$((UPDATE_WAIT)); UPDATE_POLL=$((UPDATE_POLL))'
ms_mutant no-watch-clamp '[ "$WATCH" -gt 0 ] && [ "$upd_until" -gt "$deadline" ] && upd_until="$deadline"' ':'
ms_mutant update-25-without-waiting-for-the-head 'if [ -n "$new_head" ]; then' 'if true; then'
ms_mutant update-never-moved-exits-25 'echo "  update requested, head not yet moved — re-run"
            return 11' 'echo "  update requested, head not yet moved — re-run"
            return 25'
ms_mutant no-bound-enqueue-failed-line '      [ -n "$bound_cause" ] && echo "BOUND ENQUEUE FAILED' '      false && echo "BOUND ENQUEUE FAILED'
ms_mutant bound-failed-line-on-unbound-run '[ "$erc" -ne 0 ] && [ "$EXPECTED_HEAD_SET" = 1 ] && bound_cause="$ENQ_CAUSE"' '[ "$erc" -ne 0 ] && bound_cause="${ENQ_CAUSE:-x}"'
ms_mutant head-read-without-flag 'if [ "$EXPECTED_HEAD_SET" = 1 ]; then
    live_head' 'if true; then
    live_head'

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "poll-queue-eject tests: all green" >&2
    exit 0
else
    echo "poll-queue-eject tests: FAILURES above" >&2
    exit 1
fi
