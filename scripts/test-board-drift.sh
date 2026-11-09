#!/usr/bin/env bash
# test-board-drift.sh — pins github-issues/scripts/board-drift.sh, the join of a
# ProjectV2 board against live issue state that groom-backlog's reconcile pass
# runs.
#
# Why this exists: every drift class answers a healthy board with an empty list,
# so each way the join goes wrong is silent. A read that failed and was taken as
# `[]` leaves every card unresolved, or makes every unassigned claim stale. A
# repo compared case-sensitively drops this repo's own cards as foreign. A linked
# PR in another repo, read as closed, calls a live claim abandoned. None of those
# reddens anything downstream: the report reads "no drift", or proposes a wrong
# move to a human who trusts it. The script was ported from a sibling plugin
# whose copy turned a failed issue or PR read into `[]`; that is the first
# mutant below.
#
# Asserted, against a mock gh serving one fixture board:
#   - each class holds exactly its fixture issues, and every near miss (a CLOSED
#     issue in Done, an active card with an assignee, one with an open linked PR,
#     a Backlog and an unstatused open card, a closed issue off the board) is in
#     none of them
#   - entries with a card carry item_id; column_ids carries the Done option's id
#   - board_columns comes from the Status field's options, so the fixture's
#     empty Ready column draws no warning
#   - the repo match is case-insensitive; another repo's card is counted, not
#     classified, and does not hide this repo's issue of the same number
#   - unresolved carries a reason: an issue outside the fetched window, and an
#     unassigned active card whose only linked PR is in another repo, including
#     one whose foreign PR shares its number with an OPEN PR here; a card with an
#     open local PR beside a foreign one is covered, so in no list at all
#   - with no Status field, board_columns falls back to the statuses in use,
#     column_ids is empty, and both say so in a warning
#   - each of the four reads failing, printing nothing, or printing non-JSON
#     exits 10 with NOTHING on stdout; an issue read lacking `state` is 10 too
#   - each ceiling, when reached, sets its own truncated flag and a warning and
#     exits 0; the board's is exact (totalCount), so a board AT its ceiling is
#     not truncated
#   - a column mapping that matches nothing warns, by name, for each of
#     DONE_STATUS, READY_STATUS, BACKLOG_STATUS and ACTIVE_STATUSES
#   - roles keyed on option ids (DONE_OPTION_ID and the four others, #627): ids
#     that resolve to RENAMED columns (a second fixture, jq-derived: Done is
#     Shipped, In progress is Doing, In review is Reviewing, Ready is Queued,
#     Backlog is Icebox: all five, so a ready id crossed with a backlog id lands on
#     the wrong name and the ready-and-backlog-ids-crossed mutant fails) give no warning and
#     the baseline's drift buckets; an id the Status options lack warns naming its
#     key and the role matches no column, never the default name; a role with no
#     id falls back to its *_STATUS name; In review stays active when only
#     IN_PROGRESS_OPTION_ID is given; an unknown IN_REVIEW_OPTION_ID warns by its
#     key and In review stops being active; a hand-set ACTIVE_STATUSES is replaced
#     (not merged) once either active-role id is given, and the inert-set warning
#     then names the id keys; a board column that differs from its configured name
#     only by case matches with no warning and `columns.<role>` carries the board's
#     spelling, so column_ids[columns.<role>] resolves; the renamed fixture renames
#     all five columns, so a
#     ready id crossed with a backlog id is caught
#   - any argument at all is a usage error (64), as are a missing or
#     non-numeric PROJECT_NUMBER and a zero ceiling
#   - REPO unset resolves through gh, and a failed resolution is 10; a REPO
#     that is not owner/name is 10, by its own message; gh or python3 missing is
#     10, each by its own message (the two checks are adjacent, so an exit code
#     alone cannot tell which one fired)
#   - the run is READ-ONLY: the mock records every call it does not serve, and
#     the record must be empty
#   - mutation proof: each mutant below is one of those defects, applied to a
#     copy of the script, and every one must fail the suite. Each anchor must
#     occur exactly once and each mutated copy must parse (`bash -n`), so a
#     mutant can neither miss its target nor "fail" by being a syntax error.
#
# The mock projects to the requested --json fields, filters on --state and
# truncates to --limit, as gh does. A mock that hands back what the caller never
# asked for keeps a gate green while production reads nothing.
#
# Mock gh only: no repo, no network; scratch space is this run's own mktemp -d.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-board-drift.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-board-drift: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SCRIPT="skills/github-issues/scripts/board-drift.sh"

for tool in python3 jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "test-board-drift: SKIP ($tool not installed — CI still enforces)" >&2
        exit 0
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "board-drift tests (work: $WORK)" >&2

# --- the mock gh -------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/empty" "$WORK/gh-only"
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys

args = sys.argv[1:]


def refuse(why):
    with open(os.environ["MOCK_WRITES"], "a") as fh:
        fh.write("gh " + " ".join(args) + "\n")
    print(f"mock gh: refusing ({why}): gh " + " ".join(args), file=sys.stderr)
    sys.exit(1)


if len(args) < 2:
    refuse("no subcommand")
cmd, rest = f"{args[0]} {args[1]}", args[2:]


def opt(name, default=None):
    if name in rest:
        i = rest.index(name)
        return rest[i + 1] if i + 1 < len(rest) else default
    return default


# MOCK_FAIL / MOCK_EMPTY / MOCK_GARBAGE name one read ("issue list" etc.) and make
# it fail the way an expired token does, print nothing, or print a proxy's HTML.
if cmd == os.environ.get("MOCK_FAIL"):
    print("HTTP 401: Bad credentials", file=sys.stderr)
    sys.exit(1)
if cmd == os.environ.get("MOCK_EMPTY"):
    sys.exit(0)
if cmd == os.environ.get("MOCK_GARBAGE"):
    print("<html>502 Bad Gateway</html>")
    sys.exit(0)

fx = json.load(open(os.environ["MOCK_FIXTURE"]))
limit = int(opt("--limit", "30"))          # gh's own default page size


def need(cond, what):
    if not cond:
        refuse(what)


if cmd in ("project item-list", "project field-list"):
    need(rest[:1] == [os.environ["MOCK_PROJECT"]], f"project number {rest[:1]}")
    need(opt("--owner") == os.environ["MOCK_OWNER"], f"--owner {opt('--owner')}")
    need(opt("--format") == "json", "--format json")
    key = "items" if cmd == "project item-list" else "fields"
    rows = fx["board" if key == "items" else "fields"]
    if key == "fields" and os.environ.get("MOCK_NO_STATUS") == "1":
        rows = [f for f in rows if f.get("name") != "Status"]
    print(json.dumps({key: rows[:limit], "totalCount": len(rows)}))
elif cmd in ("issue list", "pr list"):
    need(opt("--repo") == os.environ["MOCK_REPO"], f"--repo {opt('--repo')}")
    state = opt("--state", "open")
    rows = fx["issues" if cmd == "issue list" else "prs"]
    if state != "all":
        rows = [r for r in rows if r["state"].lower() == state]
    want = [f for f in (opt("--json") or "").split(",") if f]
    need(want, "--json")
    drop = os.environ.get("MOCK_DROP_FIELD") if cmd == "issue list" else None
    rows = [{k: v for k, v in r.items() if k in want and k != drop} for r in rows]
    print(json.dumps(rows[:limit]))
elif cmd == "repo view":
    if os.environ.get("MOCK_FAIL_REPO_VIEW") == "1":
        print("HTTP 401: Bad credentials", file=sys.stderr)
        sys.exit(1)
    print(os.environ["MOCK_REPO"])
else:
    refuse("not a read this script makes")
MOCK
chmod +x "$WORK/bin/gh"
ln -s "$WORK/bin/gh" "$WORK/gh-only/gh"

export MOCK_REPO="mock-org/mock-repo"
export MOCK_PROJECT="7"
export MOCK_OWNER="mock-org"
export MOCK_FIXTURE="$WORK/fixture.json"
export MOCK_WRITES="$WORK/writes.log"
: >"$MOCK_WRITES"

# --- the fixture -------------------------------------------------------------
# Board cards (mock-org/mock-repo unless noted), and where each one must land:
#   #10 In progress  CLOSED              closed_not_done
#   #11 Done         CLOSED              none (the near miss for #10)
#   #12 Done         OPEN                open_in_done
#   #13 In progress  OPEN, unassigned, linked PR #90 is CLOSED     stale_claim
#   #14 In review    OPEN, unassigned, linked PR #91 is OPEN       none
#   #15 In progress  OPEN, assigned                                none
#   #16 Backlog      OPEN                none
#   #17 (no status)  OPEN                none
#   #18 Backlog      card is mock-org/OTHER's #18   other_repo; this repo's
#                    own open #18 has no card, so it is absent_from_board
#   #19 In progress  OPEN, unassigned, only linked PR is mock-org/other#5
#                                                                 unresolved
#   #900 Backlog     not in the issue read                        unresolved
#   #20 Backlog      repository spelled Mock-Org/Mock-Repo, CLOSED closed_not_done
#   #24 In review    OPEN, unassigned, no linked PR at all          stale_claim
#   #25 In progress  OPEN, unassigned, linked PRs: OPEN #91 here AND
#                    mock-org/other#7         none (covered locally; the foreign
#                                             PR must not make it unresolved)
#   #26 In review    OPEN, unassigned, only linked PR is mock-org/other#91,
#                    whose NUMBER matches an open PR here         unresolved
#   a PullRequest card and a DraftIssue card                      skipped
# Off the board: #21 OPEN (absent_from_board), #22 CLOSED (none).
# Issues are listed newest first, as gh lists them; the Ready column is empty.
cat >"$MOCK_FIXTURE" <<'JSON'
{
  "fields": [
    {"id": "F-title", "name": "Title", "type": "ProjectV2Field"},
    {"id": "F-status", "name": "Status", "type": "ProjectV2SingleSelectField",
     "options": [
       {"id": "opt-backlog", "name": "Backlog"}, {"id": "opt-ready", "name": "Ready"},
       {"id": "opt-progress", "name": "In progress"}, {"id": "opt-review", "name": "In review"},
       {"id": "opt-done", "name": "Done"}]}
  ],
  "board": [
    {"id": "PVTI_10", "status": "In progress", "content": {"type": "Issue", "number": 10, "title": "t10", "url": "u10", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_11", "status": "Done", "content": {"type": "Issue", "number": 11, "title": "t11", "url": "u11", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_12", "status": "Done", "content": {"type": "Issue", "number": 12, "title": "t12", "url": "u12", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_13", "status": "In progress", "content": {"type": "Issue", "number": 13, "title": "t13", "url": "u13", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_14", "status": "In review", "content": {"type": "Issue", "number": 14, "title": "t14", "url": "u14", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_15", "status": "In progress", "content": {"type": "Issue", "number": 15, "title": "t15", "url": "u15", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_16", "status": "Backlog", "content": {"type": "Issue", "number": 16, "title": "t16", "url": "u16", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_17", "content": {"type": "Issue", "number": 17, "title": "t17", "url": "u17", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_O18", "status": "Backlog", "content": {"type": "Issue", "number": 18, "title": "other", "url": "uo", "repository": "mock-org/other", "body": "b"}},
    {"id": "PVTI_19", "status": "In progress", "content": {"type": "Issue", "number": 19, "title": "t19", "url": "u19", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_900", "status": "Backlog", "content": {"type": "Issue", "number": 900, "title": "t900", "url": "u900", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_PR", "status": "In review", "content": {"type": "PullRequest", "number": 91, "title": "pr", "url": "up", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_DRAFT", "status": "Backlog", "content": {"type": "DraftIssue", "title": "draft", "body": "b"}},
    {"id": "PVTI_20", "status": "Backlog", "content": {"type": "Issue", "number": 20, "title": "t20", "url": "u20", "repository": "Mock-Org/Mock-Repo", "body": "b"}},
    {"id": "PVTI_24", "status": "In review", "content": {"type": "Issue", "number": 24, "title": "t24", "url": "u24", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_25", "status": "In progress", "content": {"type": "Issue", "number": 25, "title": "t25", "url": "u25", "repository": "mock-org/mock-repo", "body": "b"}},
    {"id": "PVTI_26", "status": "In review", "content": {"type": "Issue", "number": 26, "title": "t26", "url": "u26", "repository": "mock-org/mock-repo", "body": "b"}}
  ],
  "issues": [
    {"number": 26, "title": "t26", "url": "u26", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": [
      {"number": 91, "repository": {"name": "other", "owner": {"login": "mock-org"}}}]},
    {"number": 25, "title": "t25", "url": "u25", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": [
      {"number": 91, "repository": {"name": "mock-repo", "owner": {"login": "mock-org"}}},
      {"number": 7, "repository": {"name": "other", "owner": {"login": "mock-org"}}}]},
    {"number": 24, "title": "t24", "url": "u24", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 22, "title": "t22", "url": "u22", "state": "CLOSED", "stateReason": "COMPLETED", "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 21, "title": "t21", "url": "u21", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 20, "title": "t20", "url": "u20", "state": "CLOSED", "stateReason": "NOT_PLANNED", "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 19, "title": "t19", "url": "u19", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": [
      {"number": 5, "repository": {"name": "other", "owner": {"login": "mock-org"}}}]},
    {"number": 18, "title": "t18", "url": "u18", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 17, "title": "t17", "url": "u17", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 16, "title": "t16", "url": "u16", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 15, "title": "t15", "url": "u15", "state": "OPEN", "stateReason": null, "assignees": [{"login": "alice"}], "closedByPullRequestsReferences": []},
    {"number": 14, "title": "t14", "url": "u14", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": [
      {"number": 91, "repository": {"name": "mock-repo", "owner": {"login": "mock-org"}}}]},
    {"number": 13, "title": "t13", "url": "u13", "state": "OPEN", "stateReason": null, "assignees": [], "closedByPullRequestsReferences": [
      {"number": 90, "repository": {"name": "mock-repo", "owner": {"login": "mock-org"}}}]},
    {"number": 12, "title": "t12", "url": "u12", "state": "OPEN", "stateReason": "REOPENED", "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 11, "title": "t11", "url": "u11", "state": "CLOSED", "stateReason": "NOT_PLANNED", "assignees": [], "closedByPullRequestsReferences": []},
    {"number": 10, "title": "t10", "url": "u10", "state": "CLOSED", "stateReason": "COMPLETED", "assignees": [], "closedByPullRequestsReferences": []}
  ],
  "prs": [
    {"number": 93, "state": "OPEN"},
    {"number": 92, "state": "MERGED"},
    {"number": 91, "state": "OPEN"},
    {"number": 90, "state": "CLOSED"}
  ]
}
JSON

# The renamed board: the same cards and option ids, all five columns renamed (Ready
# and Backlog too, so a resolved ready/backlog id cannot land on the default name
# by accident).
jq 'def ren: (if . == "Done" then "Shipped" elif . == "In progress" then "Doing" elif . == "In review" then "Reviewing" elif . == "Ready" then "Queued" elif . == "Backlog" then "Icebox" else . end);
    (.fields[] | select(.name == "Status") | .options[]) |= (.name |= ren)
    | (.board[] | select(.status != null) | .status) |= ren' \
    "$MOCK_FIXTURE" >"$WORK/renamed.json"

# The case board: Done and Backlog differ from the default names by case only.
jq 'def ren: (if . == "Done" then "done" elif . == "Backlog" then "BACKLOG" else . end);
    (.fields[] | select(.name == "Status") | .options[]) |= (.name |= ren)
    | (.board[] | select(.status != null) | .status) |= ren' \
    "$MOCK_FIXTURE" >"$WORK/case.json"

# --- the harness ---------------------------------------------------------------
OUT="$WORK/out.json"
ERR="$WORK/err.txt"
RC=0

# bd <script> [VAR=value ...] [-- <script args...>] — the defaults name the
# fixture's board and repo; any VAR=value overrides them. Results: $OUT $ERR $RC.
bd() {
    local script="$1"; shift
    local -a envs=() argv=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then shift; argv=("$@"); break; fi
        envs+=("$1"); shift
    done
    RC=0
    # `${a[@]+"${a[@]}"}`: an empty array is "unbound" to bash 3.2 under set -u.
    env PATH="$WORK/bin:$PATH" PROJECT_NUMBER=7 OWNER=mock-org REPO=mock-org/mock-repo \
        ${envs[@]+"${envs[@]}"} bash "$script" ${argv[@]+"${argv[@]}"} >"$OUT" 2>"$ERR" || RC=$?
}

QUIET=0
SUITE_FAIL=0
check() {   # check <label> <command...>
    local label="$1"; shift
    if "$@"; then
        [ "$QUIET" = 1 ] || ok "$label"
    else
        SUITE_FAIL=$((SUITE_FAIL + 1))
        [ "$QUIET" = 1 ] || bad "$label"
    fi
}
# A mutant is killed by its first failed check; stop there rather than run the rest.
bail() { [ "$QUIET" = 1 ] && [ "$SUITE_FAIL" -gt 0 ]; }

rc_is() { [ "$RC" = "$1" ]; }
jq_is() { [ "$(jq -c "$1" "$OUT" 2>/dev/null)" = "$2" ]; }
stdout_empty() { [ ! -s "$OUT" ]; }
stderr_has() { grep -q -- "$1" "$ERR"; }

nums() { echo "[.drift.$1[].number]"; }

suite() {   # suite <script> — every case; 0 when all hold
    local s="$1"
    SUITE_FAIL=0
    : >"$MOCK_WRITES"

    # Baseline: one full run over the fixture.
    bd "$s"
    check "baseline exits 0" rc_is 0
    check "closed_not_done is #10 and the case-variant repo's #20" jq_is "$(nums closed_not_done)" '[10,20]'
    check "open_in_done is #12" jq_is "$(nums open_in_done)" '[12]'
    check "stale_claim is #13 (its linked PR is closed) and #24 (no PR at all)" jq_is "$(nums stale_claim)" '[13,24]'
    check "absent_from_board is #18 (another repo's #18 is carded) and #21" jq_is "$(nums absent_from_board)" '[18,21]'
    check "unresolved is #19 and #26 (other-repo PRs) and #900 (outside the window), each with a reason" \
        jq_is '[.unresolved[] | [.number, (.reason | length > 0)]]' '[[19,true],[26,true],[900,true]]'
    check "#26's foreign PR #91 is not taken for this repo's open #91" \
        jq_is '.unresolved[1].other_repo_prs' '["mock-org/other#91"]'
    check "#25 (an open PR here beside a foreign one) is in no list" \
        jq_is '[.drift[][], .unresolved[] | select(.number == 25)] | length' '0'
    check "#19 names its other-repo PR" jq_is '.unresolved[0].other_repo_prs' '["mock-org/other#5"]'
    check "counts: 14 cards of this repo, 1 of another" jq_is '[.counts.cards, .counts.other_repo]' '[14,1]'
    check "entries with a card carry item_id" jq_is '[.drift.closed_not_done[0].item_id, .drift.stale_claim[0].item_id]' '["PVTI_10","PVTI_13"]'
    check "closed_not_done carries state_reason" jq_is '.drift.closed_not_done[0].state_reason' '"COMPLETED"'
    check "stale_claim #13 lists its linked PR" jq_is '.drift.stale_claim[0].linked_prs' '[90]'
    check "column_ids carries the Done option" jq_is '.column_ids.Done' '"opt-done"'
    check "board_columns is the Status field's options (empty Ready included)" \
        jq_is '.board_columns' '["Backlog","Ready","In progress","In review","Done"]'
    check "nothing truncated" jq_is '.truncated' '{"board":false,"issues":false,"prs":false}'
    check "no warnings" jq_is '.warnings' '[]'
    bail && return 1

    # Each read failing, printing nothing, or printing non-JSON is UNKNOWN.
    local mode read
    for mode in MOCK_FAIL MOCK_EMPTY MOCK_GARBAGE; do
        for read in "project item-list" "project field-list" "issue list" "pr list"; do
            bd "$s" "$mode=$read"
            check "$mode on '$read' exits 10 with nothing on stdout" eval 'rc_is 10 && stdout_empty'
            bail && return 1
        done
    done
    bd "$s" MOCK_FAIL="issue list"
    check "a failed read relays gh's reason" stderr_has 'Bad credentials'
    bd "$s" MOCK_DROP_FIELD=state
    check "an issue read lacking state exits 10" eval 'rc_is 10 && stdout_empty'
    bail && return 1

    # Ceilings: each sets its own flag and warning, and the run still exits 0.
    bd "$s" PROJECT_LIMIT=17
    check "a board exactly AT PROJECT_LIMIT is not truncated (totalCount is exact)" jq_is '.truncated.board' 'false'
    bd "$s" PROJECT_LIMIT=16
    check "a board past PROJECT_LIMIT is truncated, with a warning" \
        eval 'rc_is 0 && jq_is ".truncated.board" true && jq_is "[.warnings[] | test(\"PROJECT_LIMIT\")] | any" true'
    bd "$s" ISSUE_LIMIT=5
    check "an issue read AT ISSUE_LIMIT is truncated, with a warning" \
        eval 'rc_is 0 && jq_is ".truncated.issues" true && jq_is "[.warnings[] | test(\"ISSUE_LIMIT\")] | any" true'
    bd "$s" PR_LIMIT=2
    check "a PR read AT PR_LIMIT is truncated, with a warning" \
        eval 'rc_is 0 && jq_is ".truncated.prs" true && jq_is "[.warnings[] | test(\"PR_LIMIT\")] | any" true'
    check "a truncation warning is on stderr too" stderr_has 'PR_LIMIT=2'
    bail && return 1

    # Column mapping.
    local col
    for col in DONE_STATUS READY_STATUS BACKLOG_STATUS; do
        bd "$s" "$col=Nowhere"
        check "a $col matching no column warns by name" jq_is "[.warnings[] | test(\"$col\")] | any" 'true'
    done
    bd "$s" MOCK_NO_STATUS=1
    check "no Status field: columns fall back to the statuses in use, column_ids is empty" \
        eval 'rc_is 0 && jq_is ".board_columns" "[\"Backlog\",\"Done\",\"In progress\",\"In review\",\"Unstatused\"]" && jq_is ".column_ids" "{}"'
    check "no Status field: a warning says so" jq_is '[.warnings[] | test("no Status field")] | any' 'true'
    # Option ids (#627). The renamed fixture is the baseline's board with its
    # five Status columns renamed (Done, In progress, In review, Ready, Backlog), ids
    # unchanged. Ready and Backlog are renamed too so that a correctly resolved ready or
    # backlog id cannot land on the default name by accident, which is what lets the
    # ready-and-backlog-ids-crossed mutant fail the suite.
    local ids=(DONE_OPTION_ID=opt-done READY_OPTION_ID=opt-ready BACKLOG_OPTION_ID=opt-backlog
               IN_PROGRESS_OPTION_ID=opt-progress IN_REVIEW_OPTION_ID=opt-review)
    bd "$s" MOCK_FIXTURE="$WORK/renamed.json"
    check "renamed columns, no ids: the name mapping warns" jq_is '[.warnings[] | test("DONE_STATUS")] | any' 'true'
    bd "$s" MOCK_FIXTURE="$WORK/renamed.json" "${ids[@]}"
    check "ids resolving to renamed columns: no warning, the baseline's buckets" \
        eval 'rc_is 0 && jq_is ".warnings" "[]" && jq_is "$(nums closed_not_done)" "[10,20]" && jq_is "$(nums open_in_done)" "[12]" && jq_is "$(nums stale_claim)" "[13,24]"'
    check "the resolved names are reported" jq_is '.columns' '{"done":"Shipped","ready":"Queued","backlog":"Icebox","active":["Doing","Reviewing"]}'
    bd "$s" DONE_OPTION_ID=opt-nowhere
    check "a done id the board lacks warns, naming its key" \
        eval 'jq_is "[.warnings[] | test(\"done_option_id\")] | any" true && stderr_has "done_option_id"'
    check "an unknown done id matches no column: no silent fallback to Done" \
        eval 'jq_is "$(nums closed_not_done)" "[10,11,20]" && jq_is "$(nums open_in_done)" "[]"'
    check "an unknown id is one warning, by its key, not a second one by the name variable" \
        jq_is '[.warnings[] | test("DONE_STATUS")] | any' 'false'
    bd "$s" IN_PROGRESS_OPTION_ID=opt-nowhere
    check "an unknown in-progress id warns by key and does not fall back to In progress" \
        eval 'jq_is "[.warnings[] | test(\"in_progress_option_id\")] | any" true && jq_is "$(nums stale_claim)" "[24]"'
    bd "$s" BACKLOG_OPTION_ID=opt-nowhere READY_OPTION_ID=opt-nowhere
    check "unknown ready and backlog ids each warn by key" \
        eval 'jq_is "[.warnings[] | test(\"ready_option_id\")] | any" true && jq_is "[.warnings[] | test(\"backlog_option_id\")] | any" true'
    bd "$s" MOCK_FIXTURE="$WORK/renamed.json" DONE_OPTION_ID=opt-done DONE_STATUS=Nowhere
    check "a role with an id ignores its name" jq_is '.warnings | map(select(test("DONE_STATUS"))) | length' '0'
    bd "$s" MOCK_FIXTURE="$WORK/renamed.json" DONE_STATUS=Shipped READY_STATUS=Queued BACKLOG_STATUS=Icebox ACTIVE_STATUSES=Doing,Reviewing
    check "a role with no id falls back to its name" \
        eval 'jq_is ".warnings" "[]" && jq_is "$(nums open_in_done)" "[12]"'
    bd "$s" IN_PROGRESS_OPTION_ID=opt-progress
    check "In review stays active when only the in-progress id is given" \
        eval 'jq_is ".columns.active" "[\"In progress\",\"In review\"]" && jq_is "$(nums stale_claim)" "[13,24]"'
    bd "$s" MOCK_FIXTURE="$WORK/case.json"
    check "a column differing from its name only by case: no warning, the board's spelling, and column_ids resolves" \
        eval 'jq_is ".warnings" "[]" && jq_is "[.columns.done, .columns.backlog]" "[\"done\",\"BACKLOG\"]" && jq_is "[.column_ids[.columns.done], .column_ids[.columns.backlog]]" "[\"opt-done\",\"opt-backlog\"]"'
    bd "$s" IN_REVIEW_OPTION_ID=opt-nowhere
    check "an unknown in-review id warns by key, and In review stops counting as active" \
        eval 'jq_is "[.warnings[] | test(\"in_review_option_id\")] | any" true && jq_is "$(nums stale_claim)" "[13]"'
    bd "$s" IN_PROGRESS_OPTION_ID=opt-progress ACTIVE_STATUSES=Backlog
    check "a hand-set ACTIVE_STATUSES is replaced, not merged, once an active-role id is given" \
        eval 'jq_is ".columns.active" "[\"In progress\",\"In review\"]" && jq_is "$(nums stale_claim)" "[13,24]"'
    bd "$s" IN_PROGRESS_OPTION_ID=opt-nowhere IN_REVIEW_OPTION_ID=opt-nowhere
    check "an inert active set that came from ids names the id keys, not ACTIVE_STATUSES" \
        eval 'jq_is "[.warnings[] | select(test(\"inert\")) | test(\"in_review_option_id\")] | any" true && jq_is "[.warnings[] | select(test(\"inert\")) | test(\"ACTIVE_STATUSES\")] | any" false'
    bail && return 1

    bd "$s" "ACTIVE_STATUSES=Doing"
    check "ACTIVE_STATUSES matching no column warns that stale_claim is inert" \
        eval 'jq_is "[.warnings[] | test(\"inert\")] | any" true && jq_is "$(nums stale_claim)" "[]"'
    bail && return 1

    # Usage.
    bd "$s" -- --project 7
    check "any argument is a usage error (64)" eval 'rc_is 64 && stdout_empty'
    bd "$s" PROJECT_NUMBER=
    check "a missing PROJECT_NUMBER is 64" rc_is 64
    bd "$s" PROJECT_NUMBER=seven
    check "a non-numeric PROJECT_NUMBER is 64" rc_is 64
    bd "$s" ISSUE_LIMIT=0
    check "a zero ceiling is 64" rc_is 64
    bail && return 1

    # Repo resolution and tooling.
    bd "$s" REPO=
    check "REPO unset resolves through gh" eval 'rc_is 0 && jq_is ".repo" "\"mock-org/mock-repo\""'
    bd "$s" REPO= MOCK_FAIL_REPO_VIEW=1
    check "a failed repo resolution is 10" eval 'rc_is 10 && stdout_empty'
    local bad_repo
    for bad_repo in noslash 'a b/c'; do
        bd "$s" "REPO=$bad_repo"
        check "REPO='$bad_repo' is not owner/name: 10, by its own message" \
            eval 'rc_is 10 && stdout_empty && stderr_has "not owner/name"'
    done
    RC=0; env PATH="$WORK/empty" PROJECT_NUMBER=7 OWNER=mock-org "$BASH" "$s" >"$OUT" 2>"$ERR" || RC=$?
    check "gh missing is 10, by its own message" eval 'rc_is 10 && stderr_has "gh not installed"'
    RC=0; env PATH="$WORK/gh-only" PROJECT_NUMBER=7 OWNER=mock-org REPO=mock-org/mock-repo "$BASH" "$s" >"$OUT" 2>"$ERR" || RC=$?
    check "python3 missing is 10, by its own message" eval 'rc_is 10 && stderr_has "python3 not installed"'
    bail && return 1

    check "read-only: the mock refused no call" eval '[ ! -s "$MOCK_WRITES" ]'
    [ "$SUITE_FAIL" -eq 0 ]
}

echo "-- the script as committed" >&2
if suite "$SCRIPT"; then
    ok "board-drift: every committed case holds"
else
    bad "board-drift: committed cases failed (above)"
    [ -s "$MOCK_WRITES" ] && sed 's/^/        refused: /' "$MOCK_WRITES" >&2
fi

# --- mutation proof ------------------------------------------------------------
# mutant <name> <anchor> <replacement> — the anchor must occur exactly once.
mutant() {
    local name="$1" old="$2" new="$3" copy="$WORK/mutant.sh"
    if ! python3 - "$SCRIPT" "$copy" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
if text.count(old) != 1:
    sys.exit(1)
open(dst, "w").write(text.replace(old, new))
PY
    then
        bad "mutant '$name' did not apply (its anchor does not occur exactly once)"
        return
    fi
    if ! bash -n "$copy" 2>/dev/null; then
        bad "mutant '$name' did not apply (the mutated copy does not parse)"
        return
    fi
    QUIET=1
    if suite "$copy"; then
        bad "mutant '$name' was NOT caught — the suite passed against it"
    else
        ok "mutant '$name' fails the suite"
    fi
    QUIET=0
}

echo "-- mutants" >&2
mutant failed-read-becomes-empty-list \
    '    exit 10
  fi
}' \
    "    echo '[]' >\"\$DIR/\$label.json\"
  fi
}"
mutant unparseable-read-is-clean \
    'unknown(f"the {label} read printed nothing, or not JSON")' \
    'doc = {key: []} if key else []'
mutant issue-state-not-required \
    'required=("number", "state")' \
    'required=("number",)'
mutant repo-match-case-sensitive \
    'if norm(c.get("repository")) != repo_n:' \
    'if (c.get("repository") or "") != repo:'
mutant foreign-card-hides-this-repos-issue \
    '    # A board can span repos; only this repo'"'"'s issues are ours to reconcile.' \
    '    carded.add(c.get("number"))'
mutant other-repo-pr-read-as-closed \
    '    if elsewhere:' \
    '    if False:'
mutant assignee-ignored \
    '    if issue.get("assignees"):' \
    '    if False:'
mutant open-pr-ignored \
    '    if any(n in open_prs for n in here):' \
    '    if False:'
mutant absent-includes-closed \
    'if i["state"] == "OPEN" and i["number"] not in carded:' \
    'if i["number"] not in carded:'
mutant board-truncation-by-ceiling \
    '"board": total > len(items) if isinstance(total, int) else len(items) >= project_limit,' \
    '"board": len(items) >= project_limit,'
mutant issue-truncation-unflagged \
    '"issues": len(issues) >= issue_limit,' \
    '"issues": False,'
mutant pr-truncation-unflagged \
    '"prs": len(prs) >= pr_limit,' \
    '"prs": False,'
mutant columns-from-statuses-in-use \
    'board_columns = list(column_ids) or observed' \
    'board_columns = observed'
mutant arguments-accepted \
    'if [ "$#" -gt 0 ]; then' \
    'if false; then'
mutant pr-read-all-states \
    '--state open --limit "$PR_LIMIT"' \
    '--state all --limit "$PR_LIMIT"'
mutant issue-read-open-only \
    '--state all --limit "$ISSUE_LIMIT"' \
    '--state open --limit "$ISSUE_LIMIT"'
mutant foreign-pr-number-taken-as-local \
    'here = sorted(r.get("number") for r in refs if pr_repo(r) == repo_n)' \
    'here = sorted(r.get("number") for r in refs)'
# The reorder: the foreign-PR branch runs first, so #25's open local PR is never
# consulted. Every other card's outcome is unchanged, so only #25 can catch it.
mutant foreign-pr-checked-before-local-open-pr \
    '    if any(n in open_prs for n in here):
        continue
    if elsewhere:
        unresolved.append(dict(entry, linked_prs=here, other_repo_prs=elsewhere,
                               reason="unassigned claim whose other linked PRs are in another repo; their state was not read"))
        continue
    drift["stale_claim"]' \
    '    if elsewhere:
        unresolved.append(dict(entry, linked_prs=here, other_repo_prs=elsewhere,
                               reason="unassigned claim whose other linked PRs are in another repo; their state was not read"))
        continue
    if any(n in open_prs for n in here):
        continue
    drift["stale_claim"]'
mutant ready-and-backlog-mapping-unchecked \
    '("DONE_STATUS", "done_option_id", done_s), ("READY_STATUS", "ready_option_id", ready_s),
                         ("BACKLOG_STATUS", "backlog_option_id", backlog_s)):' \
    '("DONE_STATUS", "done_option_id", done_s),):'
# Option ids (#627). One mutant per defect the new cases pin.
mutant id-ignored-default-name-used \
    'name = name_by_id.get(opt_id)' \
    'name = default'
mutant unknown-id-falls-back-silently \
    '        return f"<unknown option id {opt_id}>"' \
    '        return default'
mutant unknown-id-unwarned \
    '        id_warnings.append(f"{key}=' \
    '        (lambda *a: None)(f"{key}='
mutant in-review-dropped-when-only-progress-id \
    '    active_s = [resolve("in_progress_option_id", progress_id, "In progress"),
                resolve("in_review_option_id", review_id, "In review")]' \
    '    active_s = [resolve("in_progress_option_id", progress_id, "In progress")]'
mutant ready-and-backlog-ids-crossed \
    'ready_s = resolve("ready_option_id", ready_id, ready_s)
backlog_s = resolve("backlog_option_id", backlog_id, backlog_s)' \
    'ready_s = resolve("ready_option_id", backlog_id, ready_s)
backlog_s = resolve("backlog_option_id", ready_id, backlog_s)'
mutant in-review-id-ignored \
    'resolve("in_review_option_id", review_id, "In review")]' \
    'resolve("in_review_option_id", "", "In review")]'
mutant active-statuses-merged-with-ids \
    '    active_s = [resolve("in_progress_option_id"' \
    '    active_s = active_s + [resolve("in_progress_option_id"'
mutant inert-warning-always-names-active-statuses \
    'if active_from_ids else "ACTIVE_STATUSES")' \
    'if False else "ACTIVE_STATUSES")'
mutant name-path-reports-configured-spelling \
    'done_s = canon.get(norm(done_s), done_s)' \
    'done_s = done_s'
mutant role-with-id-also-name-checked \
    'if key not in id_roles and norm(value) not in known:' \
    'if norm(value) not in known:'
mutant no-status-field-no-fallback \
    'board_columns = list(column_ids) or observed' \
    'board_columns = list(column_ids)'
mutant no-status-field-unwarned \
    'if status_field is None:' \
    'if False:'
mutant repo-shape-unchecked \
    'if [[ ! "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then' \
    'if false; then'
mutant gh-check-dropped \
    'if ! command -v gh >/dev/null 2>&1; then' \
    'if false; then'
mutant python3-check-dropped \
    'if ! command -v python3 >/dev/null 2>&1; then' \
    'if false; then'
mutant board-limit-dropped \
    ' --format json --limit "$PROJECT_LIMIT"' \
    ' --format json'

if [ "$fail" -eq 0 ]; then
    echo "board-drift tests: all green" >&2
    exit 0
fi
echo "board-drift tests: FAILURES above" >&2
exit 1
