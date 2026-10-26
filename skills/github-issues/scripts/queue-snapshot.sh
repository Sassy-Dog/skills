#!/usr/bin/env bash
# queue-snapshot.sh — one-call read of the boardless fill/drain work queue.
#
# Replaces dispatch-ready's per-tick pair of ad-hoc `gh issue list` reads AND puts the
# parsing of the machine-readable body contracts in one place:
#   - `touches:` line   → the collision-avoidance file/dir set (issue #38)
#   - `Depends on #N`   → literal dependency lines
#   - `stack:` line     → a declared stacked-PR chain, bottom→top, carried on
#                         the BOTTOM issue and naming every member including
#                         itself. Distinct from `Depends on`: a dependency
#                         often means "later", a stack means "ship together".
#
# The execution site is read from LABELS, not from the body (issue #340, epic
# #322): a `site:<name>` label declares the workstation an issue can only be
# worked from, and no label means "any site".
#
# WHY A LABEL AND NOT A BODY LINE, which is the shape the three contracts above
# use. A body line can be QUOTED — an issue documenting the contract, or a
# template carrying an unfilled placeholder, would declare a site by accident.
# Preventing that means deciding what a fenced block, a code span, an HTML
# comment, an info string and their interactions mean, i.e. implementing a
# subset of CommonMark and discovering its edges one at a time. A label cannot
# be quoted in prose, so nothing needs masking and the whole class is gone. The
# three body contracts above are untouched by this and keep the raw-line parse
# they have always had.
#
# Site resolution, stated because a repo can carry more than one label and the
# answer must not depend on which:
#   * A label declares a site when its name starts with `site:`, matched
#     case-insensitively. Both halves of that carry weight and are pinned
#     separately: it is a PREFIX rather than a substring, so `offsite:x` and
#     `website` — which merely contain the text — declare nothing; and the
#     COLON is part of it, so `site-vdi` declares nothing either.
#   * The value is everything after that first colon, stripped and folded to
#     lowercase, so `Site: VDI` and `site:vdi` are one declaration and not two.
#   * A `site:` label with an EMPTY value declares nothing — there is no site
#     named "", and treating it as one would hold every issue carrying the bare
#     label.
#   * `sites` is the sorted set of declared values and is ALWAYS present. `[]`
#     means any site, one member means that site, and MORE THAN ONE IS A
#     CONFLICT this script does not resolve: it reports every declared value
#     and the reader's membership test settles it, so only a checkout NAMED
#     among them may take the issue. Never "any site" — narrowing, not
#     widening, is the whole point (issue #341).
#   * There is deliberately NO SCALAR beside it. A scalar is null both when
#     nothing is declared and when several things are, so its obvious reading —
#     `site is None or site == execution_site` — resolves a conflict to "any
#     site", which is the direction #322's originating bug ran: an unread
#     declaration letting the wrong loop claim the issue. The obvious reading
#     of the list, `not sites or execution_site.lower() in sites`, cannot
#     make that mistake. A shape that permits the wrong reading eventually
#     gets read that way, and prose spread across every consumer is not what
#     should be standing between a cold-worktree agent and that bug.
#   * THE READER FOLDS THE CONFIG SIDE. This script folds the label's value, so
#     the other half of the comparison is the consumer's and nothing here can
#     perform it: an `execution_site: VDI` matched raw against the folded `vdi`
#     holds the VDI loop's own work — the filter refusing exactly the checkout
#     it was written for. Write it `not sites or execution_site.lower() in
#     sites`, never plain equality against the raw config value (issue #341).
#   * THE RESOLUTION IS AVAILABLE TO CALLERS THAT ARE NOT READING A BUCKET:
#     `--sites-of` takes a JSON array of label names on stdin and prints the
#     resolved `sites` array, running no `gh` and touching no network. It exists
#     because the buckets are LABEL-SCOPED (`ready`, `in-progress`, `blocked`)
#     and two consumers legitimately hold labels from somewhere else — a board
#     card from `board-snapshot.sh`, and `take-it`'s `gh issue view` on an issue
#     nobody promoted (issue #341). Without it each of them writes its own
#     resolver, and the rules above stop having one answer; this is the
#     `taxonomy`-emitter shape AGENTS.md already requires of a consumer, applied
#     to a resolver rather than a table. One `sites_of`, three callers.
#   * No character grammar is applied to the value. A label is created through
#     the GitHub UI or API by somebody with triage, is visible on the issue,
#     and cannot be edited into an issue body unnoticed — so the body-contract
#     defence a free-text field needs is not the right cost here. The rule for
#     whoever reports the value is unchanged: treat it as data, never
#     interpolate it into a command or a URL.
#
# Buckets:
#   ready     open + `ready` label, ordered number-ascending (oldest first)
#   in_flight open + `in-progress` label; assignee filter is reported, not
#             silently applied — each item carries its assignees and a `mine`
#             flag (true when @me is among them) so a drain tick can count its
#             own claims while still seeing other loops' claims
#   blocked   open + `blocked` label (numbers only)
#
# Judgment stays in the calling skill: touches-set intersection, priority
# ordering beyond issue number, and the smell test are prose contracts — this
# script only reads and parses.
#
# Usage: queue-snapshot.sh [--repo owner/name] [--limit 200]
#        queue-snapshot.sh --sites-of   (JSON array of label names on stdin)
# Env:   REPO=owner/name (fallback when --repo absent; else inferred from cwd)
#
# Output: single JSON object on stdout:
#   {"repo":"...","me":"login-or-null",
#    "ready":[{number,title,labels,assignees,sites,touches,stack,depends_on,unannotated}...],
#    "in_flight":[{number,title,labels,assignees,mine,sites,touches,stack}...],
#    "blocked":[N...]}
#   `--sites-of` instead prints one JSON array: the resolved sites, e.g.
#   `["site:vdi","ready"]` on stdin gives `["vdi"]`.
#
# Exit codes: 0 ok; 10 skipped (gh/python3 missing or no repo); 64 usage.
# Read-only.
set -euo pipefail

REPO="${REPO:-}"
LIMIT=200
MODE=queue

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)  REPO="$2";  shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --sites-of) MODE=sites; shift ;;
        *) echo "usage: queue-snapshot.sh [--repo owner/name] [--limit N] | --sites-of" >&2; exit 64 ;;
    esac
done
case "$LIMIT" in ''|*[!0-9]*) echo "queue-snapshot: --limit must be a number" >&2; exit 64 ;; esac

command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 not installed" >&2; exit 10; }

# `--sites-of` resolves labels a caller already holds, so it needs no repo, no
# `gh` and no network — and the guards above must not demand any. The buckets
# and the resolver share ONE python program below rather than one each: a second
# copy of `sites_of` is a second answer, which is the whole thing the emitter
# exists to prevent.
READY_JSON="[]"; INPROG_JSON="[]"; BLOCKED_JSON="[]"; ME=""; LABELS_JSON="[]"
if [[ "$MODE" == "sites" ]]; then
    # THE SHELL reads stdin, not python: the python program arrives on python's
    # stdin as a heredoc, so `json.load(sys.stdin)` there reads an already
    # exhausted stream. Measured — every call answered "stdin is not JSON".
    # THREE stdin states, not two, and the third one HANGS. `-t 0` catches a
    # terminal; a CLOSED fd 0 (`--sites-of <&-`) is neither a terminal nor
    # readable, and a bare `$(cat)` then inherits the read end of its OWN
    # command-substitution pipe as fd 0 and blocks forever — reproduced, the
    # probe had to be killed. Duplicating fd 0 is what separates "closed" from
    # "empty": the dup fails on a closed descriptor, while `</dev/null`
    # succeeds and reaches python's exit-64 branch, which is the right answer
    # for it. Do not "simplify" this to `{ : <&0; }` — that reports a closed
    # fd 0 as open (measured), so the guard reads correct and catches nothing.
    SITES_USAGE="usage: <json-array-of-label-names> | queue-snapshot.sh --sites-of"
    [[ -t 0 ]] && { echo "$SITES_USAGE" >&2; exit 64; }
    { exec 3<&0; } 2>/dev/null || { echo "$SITES_USAGE" >&2; exit 64; }
    LABELS_JSON=$(cat <&3)
fi
if [[ "$MODE" == "queue" ]]; then
    command -v gh >/dev/null 2>&1 || { echo "skipped: gh not installed" >&2; exit 10; }
    [[ -z "$REPO" ]] && REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [[ -z "$REPO" ]] && { echo "skipped: not in a GitHub repo and REPO not set" >&2; exit 10; }

    ME=$(gh api user --jq .login 2>/dev/null || true)

    # gh label filters AND together, so each bucket is its own list call.
    FIELDS="number,title,labels,assignees,body"
    READY_JSON=$(gh issue list --repo "$REPO" --state open --label ready \
        --limit "$LIMIT" --json "$FIELDS" 2>/dev/null || echo "[]")
    INPROG_JSON=$(gh issue list --repo "$REPO" --state open --label in-progress \
        --limit "$LIMIT" --json "$FIELDS" 2>/dev/null || echo "[]")
    BLOCKED_JSON=$(gh issue list --repo "$REPO" --state open --label blocked \
        --limit "$LIMIT" --json number 2>/dev/null || echo "[]")
fi

python3 - "$MODE" "$REPO" "$ME" "$READY_JSON" "$INPROG_JSON" "$BLOCKED_JSON" "$LABELS_JSON" <<'PY'
import json, re, sys

mode = sys.argv[1]
repo, me = sys.argv[2], sys.argv[3] or None
ready_raw = json.loads(sys.argv[4])
inprog_raw = json.loads(sys.argv[5])
blocked_raw = json.loads(sys.argv[6])

# `touches:` line — first matching line wins; entries split on commas and/or
# whitespace. Backticks tolerated (`touches: `a/b`, `c/d``).
touches_re = re.compile(r'^\s*touches:\s*(.+)$', re.IGNORECASE)
# `Depends on #N` lines — every #N on a line that starts with "Depends on"
# (compound "Depends on #12 and #13" yields both).
depends_re = re.compile(r'^\s*depends\s+on\b(.*)$', re.IGNORECASE)
# `stack:` line — a declared stacked-PR chain, bottom→top. Order is MEANINGFUL
# (it is the merge order), so unlike depends_on this is never sorted or
# de-duplicated into a set. First matching line wins.
stack_re = re.compile(r'^\s*stack:\s*(.+)$', re.IGNORECASE)
ref_re = re.compile(r'#(\d+)')

def parse_body(body):
    touches, depends, stack = [], [], []
    for line in (body or "").splitlines():
        m = touches_re.match(line)
        if m and not touches:
            raw = m.group(1).replace('`', ' ')
            touches = [t for t in re.split(r'[,\s]+', raw.strip()) if t]
            continue
        m = stack_re.match(line)
        if m and not stack:
            seen = set()
            for x in ref_re.findall(m.group(1)):
                n = int(x)
                if n not in seen:      # drop repeats, keep first-seen order
                    seen.add(n)
                    stack.append(n)
            continue
        m = depends_re.match(line)
        if m:
            depends += [int(x) for x in ref_re.findall(m.group(1))]
    return touches, sorted(set(depends)), stack

SITE_PREFIX = "site:"


def sites_of(labels):
    """The sorted set of sites declared by `site:<name>` labels.

    A PREFIX test, not a substring one: `offsite:x` and `website` declare
    nothing. The value is folded, so `Site: VDI` and `site:vdi` are one
    declaration; an empty value declares nothing at all.
    """
    found = set()
    for name in labels:
        if name[:len(SITE_PREFIX)].lower() == SITE_PREFIX:
            value = name[len(SITE_PREFIX):].strip().lower()
            if value:
                found.add(value)
    return sorted(found)


if mode == "sites":
    # The emitter. It dispatches HERE, below sites_of and above everything that
    # touches a bucket, so the resolution a caller gets is the same function
    # object the buckets use — not a copy that can drift from it.
    try:
        labels = json.loads(sys.argv[7])
    except Exception as exc:
        sys.stderr.write("queue-snapshot --sites-of: stdin is not JSON: %s\n" % exc)
        sys.exit(64)
    if not isinstance(labels, list) or not all(isinstance(x, str) for x in labels):
        sys.stderr.write("queue-snapshot --sites-of: expected a JSON array of label names\n")
        sys.exit(64)
    print(json.dumps(sites_of(labels)))
    sys.exit(0)


def slim(issue, with_deps):
    touches, depends, stack = parse_body(issue.get("body"))
    labels = sorted(l["name"] for l in issue.get("labels", []))
    out = {
        "number": issue["number"],
        "title": issue.get("title", ""),
        "labels": labels,
        "assignees": sorted(a["login"] for a in issue.get("assignees", [])),
        # A list, never a scalar: see the header for why a scalar's obvious
        # reading turns a conflict into "any site".
        "sites": sites_of(labels),
        "touches": touches,
        "stack": stack,
    }
    if with_deps:
        out["depends_on"] = depends
        out["unannotated"] = not touches
    return out

ready = sorted((slim(i, True) for i in ready_raw), key=lambda x: x["number"])
in_flight = []
for i in sorted(inprog_raw, key=lambda x: x["number"]):
    item = slim(i, False)
    item["mine"] = bool(me) and me in item["assignees"]
    in_flight.append(item)

print(json.dumps({
    "repo": repo,
    "me": me,
    "ready": ready,
    "in_flight": in_flight,
    "blocked": sorted(i["number"] for i in blocked_raw),
}, indent=2))
PY
