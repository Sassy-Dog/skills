#!/usr/bin/env bash
# board-drift.sh — reconcile a ProjectV2 board against live issue state. READ-ONLY.
#
# `board-snapshot.sh` reports what the board SAYS. This reports where the board
# is WRONG: cards whose column contradicts the issue's actual state. The snapshot
# carries a card's status but not its issue's state, assignees or linked PRs, so
# the comparison is a join, and groom-backlog's reconcile pass used to describe
# that join in prose for the agent to perform by hand. It lives here now, once.
#
# Four drift classes. Fixing any of them is the caller's decision; this is a read.
#   closed_not_done    CLOSED issue, card in any column but Done. GitHub's built-in
#                      project workflow moves a card only when a merged PR closes the
#                      issue with a closing keyword, so an issue closed BY HAND (an
#                      epic, a duplicate, a won't-fix) strands its card for good.
#   open_in_done       OPEN issue, card in Done. A reopened issue drops out of
#                      planning, because Done is the column nobody reads.
#   stale_claim        OPEN issue, card in an active column (ACTIVE_STATUSES), no
#                      assignee AND no open linked PR in this repo. The claim looks
#                      abandoned. `closedByPullRequestsReferences` sees only PRs that
#                      carry a closing keyword, so a branch in flight under a PR
#                      without one also lands here: a question for a human, not a
#                      verdict.
#   absent_from_board  OPEN issue in this repo with no card on the board.
#
# A card this script cannot classify goes to `unresolved`, with a `reason`, and
# never into a drift class: its issue is outside the fetched window (the issue
# read was truncated), or it is an active-column card with no assignee whose only
# linked PRs are in another repo, whose state was not read. Guessing either one
# is the failure this script exists to remove.
#
# Env only. The script refuses every argument, because a flag a script does not
# parse is silently ignored (board-snapshot.sh, #448), and a refusal is louder:
#   PROJECT_NUMBER, OWNER   the board (required; board.number and board.owner)
#   REPO                    owner/name (default: resolved from the cwd with gh)
#   PROJECT_LIMIT=2000 ISSUE_LIMIT=1000 PR_LIMIT=500   read ceilings
#   DONE_OPTION_ID READY_OPTION_ID BACKLOG_OPTION_ID IN_PROGRESS_OPTION_ID
#   IN_REVIEW_OPTION_ID     the board config's option ids (board.done_option_id,
#                           ready_option_id, backlog_option_id, in_progress_option_id,
#                           in_review_option_id), each optional
#   DONE_STATUS=Done READY_STATUS=Ready BACKLOG_STATUS=Backlog
#   ACTIVE_STATUSES="In progress,In review"   (comma-separated)
# Column names match case-insensitively. READY_STATUS and BACKLOG_STATUS classify
# nothing: they are the columns a caller's fixes move cards INTO, so they are
# checked against the board and a miss is a warning.
#
# A role is keyed on its option id when one is given: the id is resolved to a
# column name through `column_ids` (the Status field's options, read already), so
# a renamed column keeps working. A role with no id uses its *_STATUS name, so a
# hand run by name is unchanged. A given id that the Status options do not hold is
# a warning naming its key, and the role then matches NO column: it never falls
# back to the default name, because that would act on a column the config did not
# name. The active set resolves member by member: In progress from
# IN_PROGRESS_OPTION_ID, In review from IN_REVIEW_OPTION_ID, each else its default
# name. With neither id given, ACTIVE_STATUSES is used as written; with either, the
# two roles REPLACE it entirely (a hand-set ACTIVE_STATUSES is ignored, silently),
# and the inert-set warning then names the id keys rather than ACTIVE_STATUSES.
#
# Output: one JSON object on stdout —
#   {repo, board:{number,owner}, columns:{done,ready,backlog,active},
#    board_columns:[...], column_ids:{name:option_id},
#    truncated:{board,issues,prs}, counts:{...},
#    drift:{closed_not_done:[],open_in_done:[],stale_claim:[],absent_from_board:[]},
#    unresolved:[], warnings:[]}
# Every entry with a card carries `item_id`, and `column_ids` holds every Status
# option's id, Done's included (no config key holds that one), so a caller can
# move a card with no second lookup. `board_columns` is the Status field's option
# list, not the statuses in use: an empty Done column is still a column.
#
# `columns.<role>` carries the board's own spelling of the column (a configured name
# that differs only by case is reported as the board spells it, and an exact match is
# never swapped for a case-variant), so `column_ids[columns.<role>]` is the option id
# a card-move recipe needs.
#
# TRUNCATION IS UNKNOWN, NOT CLEAN. A truncated read can make any class wrong in
# either direction: a dropped card makes its issue read as absent_from_board, and
# a dropped open PR makes a live claim read as stale. So a caller treats a run
# with any `truncated.*` true as unknown and re-runs with that ceiling raised.
# Each one is also a `warnings` entry and a stderr line. The board's flag is
# exact (gh reports totalCount). The issue and PR flags fire on a result AT the
# ceiling, which can be a false alarm but never a missed truncation.
#
# Exit: 0  every read completed (read `truncated` and `warnings` before acting)
#       10 SKIPPED or UNKNOWN: gh or python3 missing, the repo unresolvable, or
#          one of the four reads failed, printed nothing, or was not the JSON
#          shape expected. Nothing is printed on stdout. Never read 10 as "no
#          drift": every class answers a healthy board with an empty list, so a
#          degraded read that printed empty classes would look exactly like a
#          clean one.
#       64 usage
#
# Read-only with respect to the repo, the board and GitHub. The four reads land
# in a temp dir it removes on exit, and reach python as file paths, never argv,
# because a board read carries every card's body (ARG_MAX; see stale-issues.sh).
set -euo pipefail

if [ "$#" -gt 0 ]; then
  echo "usage: PROJECT_NUMBER=<n> OWNER=<org> [REPO=<owner/name>] board-drift.sh — it takes no arguments; configure it through the environment" >&2
  exit 64
fi

PROJECT_NUMBER="${PROJECT_NUMBER:-}"
OWNER="${OWNER:-}"
PROJECT_LIMIT="${PROJECT_LIMIT:-2000}"
ISSUE_LIMIT="${ISSUE_LIMIT:-1000}"
PR_LIMIT="${PR_LIMIT:-500}"
DONE_OPTION_ID="${DONE_OPTION_ID:-}"
READY_OPTION_ID="${READY_OPTION_ID:-}"
BACKLOG_OPTION_ID="${BACKLOG_OPTION_ID:-}"
IN_PROGRESS_OPTION_ID="${IN_PROGRESS_OPTION_ID:-}"
IN_REVIEW_OPTION_ID="${IN_REVIEW_OPTION_ID:-}"
DONE_STATUS="${DONE_STATUS:-Done}"
READY_STATUS="${READY_STATUS:-Ready}"
BACKLOG_STATUS="${BACKLOG_STATUS:-Backlog}"
ACTIVE_STATUSES="${ACTIVE_STATUSES:-In progress,In review}"

if [ -z "$PROJECT_NUMBER" ] || [ -z "$OWNER" ]; then
  echo "usage: PROJECT_NUMBER and OWNER are required (board.number and board.owner)" >&2
  exit 64
fi
for v in PROJECT_NUMBER PROJECT_LIMIT ISSUE_LIMIT PR_LIMIT; do
  case "${!v}" in
    '' | *[!0-9]* | 0) echo "usage: $v must be a positive integer, got '${!v}'" >&2; exit 64 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "skipped: gh not installed" >&2
  exit 10
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "skipped: python3 not installed" >&2
  exit 10
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# Resolved after the tooling check, with its status captured and gh's stderr
# kept out of the value (stale-issues.sh records why both matter).
if [ -z "${REPO:-}" ]; then
  if ! REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$DIR/repo.err")" || [ -z "$REPO" ]; then
    echo "skipped: could not resolve the repo and REPO not set. gh said: $(tr '\n' ' ' <"$DIR/repo.err")" >&2
    exit 10
  fi
fi
if [[ ! "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
  echo "skipped: REPO is not owner/name: '$REPO'" >&2
  exit 10
fi

# pull <label> <gh args...> — a failed read ends the run with 10, loudly, and
# never degrades to an empty list: an empty issue read would leave every card
# unresolved, and an empty PR read would make every unassigned claim stale.
pull() {
  local label="$1"
  shift
  if ! gh "$@" >"$DIR/$label.json" 2>"$DIR/$label.err"; then
    echo "FAILED: the $label read did not complete — this run is UNKNOWN, not clean." >&2
    sed 's/^/  gh: /' "$DIR/$label.err" >&2
    exit 10
  fi
}

pull board project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit "$PROJECT_LIMIT"
pull fields project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 100
# `--state all`: the point is finding CLOSED issues the board still calls open work.
pull issues issue list --repo "$REPO" --state all --limit "$ISSUE_LIMIT" \
  --json number,title,url,state,stateReason,assignees,closedByPullRequestsReferences
# `closedByPullRequestsReferences` names the linked PRs but not their state, so
# one list read resolves which of them are still open.
pull prs pr list --repo "$REPO" --state open --limit "$PR_LIMIT" --json number

python3 - "$DIR" "$REPO" "$PROJECT_NUMBER" "$OWNER" "$PROJECT_LIMIT" "$ISSUE_LIMIT" "$PR_LIMIT" \
  "$DONE_STATUS" "$READY_STATUS" "$BACKLOG_STATUS" "$ACTIVE_STATUSES" \
  "$DONE_OPTION_ID" "$READY_OPTION_ID" "$BACKLOG_OPTION_ID" "$IN_PROGRESS_OPTION_ID" "$IN_REVIEW_OPTION_ID" <<'PY'
import json, os, sys

(tmp, repo, project_number, owner, project_limit, issue_limit, pr_limit,
 done_s, ready_s, backlog_s, active_raw,
 done_id, ready_id, backlog_id, progress_id, review_id) = sys.argv[1:17]
project_limit, issue_limit, pr_limit = int(project_limit), int(issue_limit), int(pr_limit)
active_s = [s.strip() for s in active_raw.split(",") if s.strip()]


def unknown(why):
    print(f"FAILED: {why} — this run is UNKNOWN, not clean.", file=sys.stderr)
    sys.exit(10)


def load(label, key=None, required=()):
    """One read, parsed and shape-checked. Empty, non-JSON or misshapen is UNKNOWN."""
    try:
        with open(os.path.join(tmp, label + ".json")) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        unknown(f"the {label} read printed nothing, or not JSON")
    rows = (doc.get(key) if isinstance(doc, dict) else None) if key else doc
    if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
        unknown(f"the {label} read was not the shape expected")
    if any(f not in r for r in rows for f in required):
        unknown(f"the {label} read lacks one of {list(required)}")
    return doc, rows


def norm(s):
    return (s or "").strip().lower()


board_doc, items = load("board", "items")
_, fields = load("fields", "fields")
_, issues = load("issues", required=("number", "state"))
_, prs = load("prs", required=("number",))

repo_n = norm(repo)
open_prs = {p["number"] for p in prs}
issue_by_num = {i["number"]: i for i in issues}

status_field = next((f for f in fields if f.get("name") == "Status"), None)
column_ids = {o["name"]: o["id"] for o in (status_field or {}).get("options") or []
              if o.get("name") and o.get("id")}
observed = sorted({it.get("status") or "Unstatused" for it in items})
board_columns = list(column_ids) or observed
known = {norm(c) for c in board_columns}

# Option ids resolve to column names through column_ids. An id the board does not
# hold yields NO name (a sentinel that matches no column) and a warning naming its
# key; it never degrades to the default name.
id_warnings = []
id_roles = set()
name_by_id = {v: k for k, v in column_ids.items()}


def resolve(key, opt_id, default):
    if not opt_id:
        return default
    id_roles.add(key)
    name = name_by_id.get(opt_id)
    if name is None:
        id_warnings.append(f"{key}={opt_id!r} is not an option of this board's Status field "
                           f"{board_columns}; fix the key before acting on any drift")
        return f"<unknown option id {opt_id}>"
    return name


done_s = resolve("done_option_id", done_id, done_s)
ready_s = resolve("ready_option_id", ready_id, ready_s)
backlog_s = resolve("backlog_option_id", backlog_id, backlog_s)
active_from_ids = bool(progress_id or review_id)
if active_from_ids:
    active_s = [resolve("in_progress_option_id", progress_id, "In progress"),
                resolve("in_review_option_id", review_id, "In review")]
done_n = norm(done_s)
active_n = {norm(s) for s in active_s}

# Names match case-insensitively, but a caller looks a move target up in column_ids
# by exact key, so report the BOARD's spelling of a column matched by a differently
# cased name. A spelling that is already a column_ids key (an exact match, and every
# name an option id resolved to) is kept as it is: `canon` keeps only the last
# column for each lowercased name, so rewriting it could swap in a case-variant
# column and hand back the wrong option id. The unknown-id placeholder is no key
# either and passes through unchanged.
canon = {norm(c): c for c in board_columns}


def board_spelling(s):
    return s if s in column_ids else canon.get(norm(s), s)


done_s = board_spelling(done_s)
ready_s = board_spelling(ready_s)
backlog_s = board_spelling(backlog_s)
active_s = [board_spelling(s) for s in active_s]


def pr_repo(ref):
    r = ref.get("repository") or {}
    return norm(f"{(r.get('owner') or {}).get('login') or ''}/{r.get('name') or ''}")


drift = {k: [] for k in ("closed_not_done", "open_in_done", "stale_claim", "absent_from_board")}
unresolved, carded, cards, other_repo = [], set(), 0, 0

for it in items:
    c = it.get("content") or {}
    if c.get("type") != "Issue":
        continue
    # A board can span repos; only this repo's issues are ours to reconcile.
    if norm(c.get("repository")) != repo_n:
        other_repo += 1
        continue
    cards += 1
    number = c.get("number")
    carded.add(number)
    card = {"number": number, "title": c.get("title") or "", "url": c.get("url") or "",
            "status": it.get("status") or "Unstatused", "item_id": it.get("id")}
    issue = issue_by_num.get(number)
    if issue is None:
        unresolved.append(dict(card, reason="its issue is outside the fetched window; raise ISSUE_LIMIT"))
        continue
    status = norm(card["status"])
    entry = dict(card, state=issue["state"])
    if issue["state"] == "CLOSED":
        if status != done_n:
            drift["closed_not_done"].append(dict(entry, state_reason=issue.get("stateReason")))
        continue
    if status == done_n:
        drift["open_in_done"].append(entry)
        continue
    if status not in active_n:
        continue
    if issue.get("assignees"):
        continue
    refs = issue.get("closedByPullRequestsReferences") or []
    here = sorted(r.get("number") for r in refs if pr_repo(r) == repo_n)
    elsewhere = sorted(f"{pr_repo(r)}#{r.get('number')}" for r in refs if pr_repo(r) != repo_n)
    if any(n in open_prs for n in here):
        continue
    if elsewhere:
        unresolved.append(dict(entry, linked_prs=here, other_repo_prs=elsewhere,
                               reason="unassigned claim whose other linked PRs are in another repo; their state was not read"))
        continue
    drift["stale_claim"].append(dict(entry, linked_prs=here))

for i in issues:
    if i["state"] == "OPEN" and i["number"] not in carded:
        drift["absent_from_board"].append(
            {"number": i["number"], "title": i.get("title") or "", "url": i.get("url") or ""})

for bucket in drift.values():
    bucket.sort(key=lambda e: e["number"])
unresolved.sort(key=lambda e: e["number"])

total = board_doc.get("totalCount")
truncated = {
    "board": total > len(items) if isinstance(total, int) else len(items) >= project_limit,
    "issues": len(issues) >= issue_limit,
    "prs": len(prs) >= pr_limit,
}

warnings = list(id_warnings)
# A mapping that names no column means a fix would move cards to the wrong place.
for name, key, value in (("DONE_STATUS", "done_option_id", done_s), ("READY_STATUS", "ready_option_id", ready_s),
                         ("BACKLOG_STATUS", "backlog_option_id", backlog_s)):
    if key not in id_roles and norm(value) not in known:
        warnings.append(f"{name}={value!r} matches no column on this board {board_columns}; "
                        "fix the mapping before acting on any drift")
if not active_n & known:
    src = ("in_progress_option_id / in_review_option_id (add the missing one to the config)"
           if active_from_ids else "ACTIVE_STATUSES")
    warnings.append(f"the active set {active_s}, from {src}, matches no column on this board "
                    f"{board_columns}; stale_claim detection is inert")
if status_field is None:
    warnings.append("the board has no Status field; columns were taken from the statuses in use "
                    "and column_ids is empty")
for name, var, limit in (("board", "PROJECT_LIMIT", project_limit),
                         ("issues", "ISSUE_LIMIT", issue_limit), ("prs", "PR_LIMIT", pr_limit)):
    if truncated[name]:
        warnings.append(f"the {name} read reached {var}={limit}; this run is UNKNOWN, "
                        f"re-run with {var} raised")
for w in warnings:
    print(f"WARNING: {w}", file=sys.stderr)

print(json.dumps({
    "repo": repo,
    "board": {"number": int(project_number), "owner": owner},
    "columns": {"done": done_s, "ready": ready_s, "backlog": backlog_s, "active": active_s},
    "board_columns": board_columns,
    "column_ids": column_ids,
    "truncated": truncated,
    "counts": {**{k: len(v) for k, v in drift.items()},
               "unresolved": len(unresolved), "other_repo": other_repo, "cards": cards},
    "drift": drift,
    "unresolved": unresolved,
    "warnings": warnings,
}, indent=2))
PY
