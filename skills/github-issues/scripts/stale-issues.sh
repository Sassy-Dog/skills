#!/usr/bin/env bash
# Detect issues whose state is stale relative to recent ship history.
#
# Three detectors:
#   1. shipped-but-still-open — an open issue named by a merged PR that never
#      closed it. TWO arms, and every finding records which one fired
#      (`matched_via`: "title", "body", or "title+body"):
#        - title — a "(#N)" parenthetical in the PR title. A conventional-commit
#          title parenthetical is a hyperlink, NOT a Closes-keyword.
#        - body  — an "#N" in the PR body carrying NO closing keyword. This is
#          where the reference nearly always lives: GitHub appends "(#N)" to the
#          SQUASH-MERGE COMMIT title, not to the PR title, and the number it
#          appends is the PR's OWN (issue #337).
#      Either way the issue never auto-closed — needs manual review-and-close,
#      or a status comment if only half-shipped.
#   2. stub-body — open issue with a body shorter than 80 chars or that's just
#      a one-line placeholder. Almost certainly needs scoping before tackle.
#      IMPORTANT for consumers: before declaring a stub, check the issue's
#      COMMENTS (gh issue view N --comments) — some repos put scope in a
#      follow-up comment, not the OP body. This script only sees the body.
#   3. tracking-parent-complete — an OPEN issue with >= 1 child (any issue whose
#      body carries the literal `Part of #<N>` line groom-backlog's epic split
#      writes) where EVERY child is CLOSED. Nothing upstream can catch this:
#      GitHub moves a card only when a merged PR closes the issue via a
#      keyword, and a tracking parent is definitionally the issue no PR ever
#      names, so it can never self-close. Its children close one by one under
#      their own PRs and the parent sits open forever, counted as pending work
#      by every read of the backlog (issue #198 — three of eight open issues in
#      one repo were finished work). REPORT ONLY: a human closes, never this.
#
# Env: REPO=owner/name (default: inferred from cwd via gh)
#      ALL_LIMIT=<n> (default 500) — ceiling on detector 3's all-state pull. A
#        pull that comes back AT the ceiling is reported `truncated: true`;
#        that result is UNKNOWN, not clean. Re-run with a higher ALL_LIMIT.
#
# Exit: 0 the three sections were computed over complete pulls
#       10 SKIPPED or UNKNOWN — gh missing, no repo, or a pull that failed.
#          Never confuse it with 0: every detector here answers a healthy repo
#          with an empty list, so a degraded run that exits 0 is indistinguishable
#          from a clean one. That is the whole failure class this script exists
#          to close, so it must not reproduce it on its own inputs.
#
# Read-only with respect to the repo, GitHub and the network; it stages its
# three pulls in a temp dir it removes on exit.
set -euo pipefail

ALL_LIMIT="${ALL_LIMIT:-500}"

if ! command -v gh >/dev/null 2>&1; then
  echo "skipped: gh not installed" >&2
  exit 10
fi
# python3 is as load-bearing as gh here — the three detectors are one embedded
# program — and without this guard its absence exits 127 with no message, which
# is outside the exit contract above and outside the four values groom-backlog
# is told to choose from.
if ! command -v python3 >/dev/null 2>&1; then
  echo "skipped: python3 not installed" >&2
  exit 10
fi

# RESOLVED AFTER the tooling check, with its status captured. The previous form
# was `REPO="${REPO:-$(gh repo view ...)}"` placed ABOVE it, under `set -e`: an
# assignment adopts its command substitution's status, so the script aborted
# before either guard could speak. Measured: REPO unset and not a GitHub repo
# exited 1 with no message; REPO unset with gh off PATH exited 127 with no
# message. Only a preset REPO ever reached the 10 this header promises — and a
# caller told "10 is not a clean result" saw neither 10 nor a reason.
if [[ -z "${REPO:-}" ]]; then
  repo_rc=0
  # Stderr goes to a FILE, never `2>&1` into the value. gh writes to stderr on
  # success too — `GH_DEBUG=1` emits six lines, `GH_DEBUG=api` fifty-six — and
  # folding those into $REPO produces a slug that is not a slug. It fails closed
  # (the first pull rejects it) but blames the pull rather than the resolution,
  # which is the wrong cause in the one message a degraded run gets to print.
  repo_err=$(mktemp) || { echo "skipped: could not create a scratch file" >&2; exit 10; }
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$repo_err") || repo_rc=$?
  if [[ "$repo_rc" -ne 0 || -z "$REPO" ]]; then
    echo "skipped: could not resolve the repo and REPO not set. gh said: $(tr '\n' ' ' <"$repo_err")" >&2
    rm -f "$repo_err"
    exit 10
  fi
  rm -f "$repo_err"
  # A resolved slug is `owner/name`. Anything else means something other than a
  # slug arrived, and guessing with it is worse than refusing.
  if [[ ! "$REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    echo "skipped: resolved repo slug is not owner/name: '$REPO'" >&2
    exit 10
  fi
fi

# Each pull lands in a FILE and python is handed the path, never the payload.
# These three documents carry every issue body, plus (since #337) every recent
# PR body, and passing that on argv blows ARG_MAX on any real repo — measured
# here as `python3: Argument list too long`, exit 126, with the detector's whole
# output gone. The all-state pull was already near the limit at ALL_LIMIT=500;
# adding PR bodies pushed it over. Keep the payload off the command line.
PULL_DIR="$(mktemp -d)"
trap 'rm -rf "$PULL_DIR"' EXIT

# pull <label> <destination-file> <gh args...>
#
# A FAILED pull exits 10, loudly. It must never degrade to `[]`: an expired
# token, a rate limit or a network blip would otherwise print three empty
# sections and exit 0, which is byte-identical to a clean repo — the same
# "unknown rendered as clean" this script already refuses for detector 3's
# truncated pull. gh's own stderr is relayed, because "it failed" without the
# reason sends the reader back to guessing.
pull() {
  local label="$1" dest="$2"; shift 2
  if ! gh "$@" >"$dest" 2>"$PULL_DIR/$label.err"; then
    echo "FAILED: the $label pull did not complete — this run is UNKNOWN, not clean." >&2
    sed 's/^/  gh: /' "$PULL_DIR/$label.err" >&2
    exit 10
  fi
  if [ ! -s "$dest" ]; then
    echo "FAILED: the $label pull returned no output at all — UNKNOWN, not clean." >&2
    exit 10
  fi
}

pull open-issues "$PULL_DIR/open-issues.json" \
  issue list --repo "$REPO" --state open --limit 100 \
  --json number,title,body,createdAt,updatedAt

# Pull recent merged PRs (last 60 days is plenty — older sheds happen rarely).
# `body` is load-bearing rather than convenience: it is where the issue
# reference actually lives (detector 1, arm 2). Drop it from this field list and
# detector 1 silently collapses back to its near-vacuous title arm.
pull merged-prs "$PULL_DIR/merged-prs.json" \
  pr list --repo "$REPO" --state merged --limit 100 \
  --search "merged:>=$(date -v-60d +%Y-%m-%d 2>/dev/null || date -d '60 days ago' +%Y-%m-%d)" \
  --json number,title,body,mergedAt

# Detector 3 needs the CLOSED issues too — a completed epic's children are
# closed by definition — so it takes its own all-state pull rather than reusing
# the open-only one above.
pull all-issues "$PULL_DIR/all-issues.json" \
  issue list --repo "$REPO" --state all --limit "$ALL_LIMIT" \
  --json number,title,state,body

python3 - "$PULL_DIR/open-issues.json" "$PULL_DIR/merged-prs.json" \
  "$PULL_DIR/all-issues.json" "$ALL_LIMIT" <<'PY'
import json, re, sys

# Paths, not payloads — see the ARG_MAX note beside the pulls.
with open(sys.argv[1]) as fh:
    issues = json.load(fh)
with open(sys.argv[2]) as fh:
    prs = json.load(fh)
with open(sys.argv[3]) as fh:
    all_issues = json.load(fh)
all_limit = int(sys.argv[4])

# --- detector 1: shipped-but-still-open --------------------------------------
# Build map: issue_number -> [matching merged PRs]. TWO arms, and each finding
# records which one fired, because the arms carry very different weight and a
# reader has to be able to tell a title hit from a body hit.
#
# ARM 1 — the TITLE parenthetical. Scan EVERY parenthetical group in each title
# and pull all `#N` refs from inside. This catches:
#   - simple   "(#419)"           -> 419
#   - compound "(#419 + #421)"    -> 419, 421         (missed by the naive regex)
#   - csv      "(#419, #421)"     -> 419, 421
#   - trailing "(#458)" PR self-ref -> 458 (harmless: GitHub numbers issues and
#                                     PRs from ONE sequence, so a PR's own
#                                     number can never also be an open issue)
# The naive `\(#(\d+)\)` regex only matches the simple form — compound refs
# slipped through it in production and left shipped issues flagged-but-open.
#
# ARM 2 — the PR BODY. The title arm ALONE is near-vacuous wherever GitHub's
# squash-merge autotitle is the convention, because GitHub appends "(#N)" to the
# MERGE COMMIT title rather than the PR title, and the number it appends is the
# PR's OWN. Measured for issue #337: of the last 100 merged PRs in this repo
# only 3 titles carried any parenthetical, while 35 of the last 40 PR BODIES
# named an issue — the detector's sole input was present in 3% of PRs. A live
# miss followed: #316 was fixed by #328, which named it in the body with no
# closing keyword; #316 stayed open AND labelled `ready`, and this detector
# reported `[]`, which reads as a verified answer rather than as a blind spot.
#
# Arm 2 is deliberately BROAD — any `#N` in the body counts, not only refs under
# a fix-shaped phrase — because the miss it exists to catch is exactly the author
# who described the work without wording it as a close. That makes a body hit a
# REVIEW PROMPT rather than a verdict: a PR citing an issue for background is
# reported too, and `matched_via` is what lets the reader weigh it. Two
# exclusions keep that breadth from collapsing into "fires on everything":
#
#   - A ref governed by a CLOSING KEYWORD is not a finding. GitHub auto-closes
#     on those, so an open issue named that way is a cross-repo ref or a genuine
#     anomaly, not the omission this detector reports.
#   - HTML COMMENTS are stripped first. PR templates carry example refs inside
#     `<!-- -->` (this repo's own template carries `Closes #123`), authors leave
#     the comment in the body, and it is boilerplate rather than anyone's
#     reference — unstripped, the same template numbers would flag on EVERY PR.
#
# THOSE TWO EXCLUSIONS ARE THE ONLY THING BETWEEN UNTRUSTED PR TEXT AND A
# DETECTOR WHOSE ENTIRE PURPOSE IS TO STOP REPORTING A FALSE CLEAN, and each is
# a way to make it print `[]` again. Both are therefore built to fail toward
# REPORTING, never toward silence:
#
#   1. Suppression is POSITIONAL, never a body-global number set. The keyword
#      suppresses the one ref it governs, at that offset — not every later
#      mention of the same number. A set let one `Closes #316` anywhere in the
#      body silence every occurrence of 316 in it.
#   2. A keyword is read only from PROSE. Code fences, code spans and
#      quotations are blanked first, because none of them is GitHub asking to
#      close anything — and the backticked `Closes #N` is the form this repo's
#      own docs and PR template model, so without this a PR that merely
#      DOCUMENTS the convention silences the issue it names.
#   3. The keyword must sit on the SAME LINE as its ref. The separator is
#      `[ \t]*:?[ \t]*`, never `\s`, which spans newlines: `## Resolved` two
#      lines above a bare `#451` is not a close and must not read as one.
#   4. A comment strip that would swallow the body is REFUSED AND ANNOUNCED. A
#      stray `<!--` plus the template's trailing `-->` used to delete everything
#      between them, silencing every issue a PR named at once and leaving no
#      trace, since HTML comments render as nothing. Now the pattern refuses to
#      span a nested `<!--`, spans over COMMENT_MAX_SPAN are left in place, and
#      the finding carries `comment_strip_refused` with a stderr warning beside
#      it — a refusal a reader cannot see is the same false clean by a longer
#      route.
#
# Every one of those trades the same way on purpose: an over-broad suppression
# is a SILENT FALSE NEGATIVE — the exact failure this detector exists to end —
# while a missed suppression is a false positive a human dismisses in a second.
#
# The two arms keep SEPARATE ref regexes. Do not fold them into one: each arm
# has to be neuterable on its own for `scripts/test-stale-issues.sh` to
# mutation-prove it independently, and they are genuinely different questions —
# a title ref is already narrowed by `group_re`, while a body ref needs its own
# boundaries so `owner/repo#123` is not read as this repo's #123 and the hex
# colour `#7A3FE4` is not read as issue #7.
group_re = re.compile(r'\(([^)]*)\)')
issue_in_group_re = re.compile(r'#(\d+)')
BODY_REF_RE = re.compile(r'(?<![\w/])#(\d+)(?![0-9A-Za-z])')
# GitHub's documented closing keywords, same-line-adjacent to the ref.
# The separator is its own constant so the gate can swap it for the
# newline-spanning `\s` form and prove the same-line rule is load-bearing.
# The colon branch owns its own trailing run, so there is only ONE way to split
# the whitespace before the `#`. The previous `[ \t]*:?[ \t]*` put two
# variable-length runs side by side and backtracked quadratically: measured
# 8000 -> 0.086s, 16000 -> 0.347s, 32000 -> 1.394s, 4x per doubling. Same
# language, same seven keyword forms verified identical; 0.0026s at 65536.
KEYWORD_SEP = r'[ \t]*(?::[ \t]*)?'
CLOSING_KEYWORD_RE = re.compile(
    r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)' + KEYWORD_SEP + r'#(\d+)(?![0-9A-Za-z])',
    re.IGNORECASE,
)
# Non-prose spans, blanked before the keyword scan only. Refs stay readable
# everywhere, because reporting one too many is the harmless direction.
# Fenced blocks and code spans are found by LINE/RUN SCANNERS, not regexes.
# Both regex forms backtracked super-linearly on untrusted bodies, and the first
# attempt to fix the fence was MEASURED WRONG. The original
# `(?P<fence>```+|~~~+).*?(?P=fence)` is O(n^3); the anchored replacement was
# still 5.227s on 13107 unclosed openers at GitHub's 65536-char cap, run twice
# per body across a `--limit 100` pull. The "0.0008s at 65536" recorded for it
# came from a newline-free backtick run — an input an anchored pattern rejects
# at the first character. That number described the INPUT, not the improvement.
# These scanners are 0.0115s on the same shape and linear on every shape tried.
#
# Anchoring had also narrowed the language: a CRLF closer and a closer longer
# than its opener (both CommonMark-legal, both handled by the ORIGINAL regex)
# stopped being masked, so a `Closes #N` inside such a block silently began
# suppressing again. The scanner handles both.
#
# The span scanner fixes a correctness hole the regex had all along:
# `` `[^`\n]*` `` pairs a DOUBLE backtick as an empty span, leaving the content
# of a ``like this`` span unmasked. The comment probe then read a `<!--` inside
# one as a real opener and swallowed the body. CommonMark 6.1 is the rule
# implemented here: an opening run of n backticks closes at the next run of
# EXACTLY n on the same line, and an unclosed run is literal text.
FENCE_OPEN_RE = re.compile(r'(`{3,}|~{3,})')


def mask_fences(text):
    """Blank fenced code blocks. An unclosed fence runs to end of document."""
    out, fence = [], None
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip(' \t')
        indent = len(line) - len(stripped)
        m = FENCE_OPEN_RE.match(stripped) if indent <= 3 else None
        if fence is None:
            # A backtick fence's info string may not contain a backtick.
            if m and (m.group(1)[0] != '`' or '`' not in stripped[m.end(1):]):
                fence = m.group(1)
                out.append(blank(line))
                continue
            out.append(line)
        else:
            out.append(blank(line))
            # Same character, at least as long, nothing after it. `.strip()`
            # absorbs a trailing CR, so a CRLF closer still closes.
            if (m and m.group(1)[0] == fence[0]
                    and len(m.group(1)) >= len(fence)
                    and stripped[m.end(1):].strip() == ''):
                fence = None
    return "".join(out)


def mask_code_spans(text):
    """Blank inline code spans, pairing runs by exact length (CommonMark 6.1)."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text[i] != '`':
            i += 1
            continue
        j = i
        while j < n and text[j] == '`':
            j += 1
        run, k, closed = j - i, j, -1
        while k < n and text[k] != '\n':
            if text[k] == '`':
                m = k
                while m < n and text[m] == '`':
                    m += 1
                if m - k == run:
                    closed = m
                    break
                k = m
            else:
                k += 1
        if closed < 0:            # an unclosed run is literal text, not a span
            i = j
            continue
        for p in range(i, closed):
            if out[p] != '\n':
                out[p] = ' '
        i = closed
    return "".join(out)


def mask_code(text):
    """Fences first, then spans — a span inside a fence is already blanked."""
    return mask_code_spans(mask_fences(text))


BLOCKQUOTE_RE = re.compile(r'^[ \t]{0,3}>[^\n]*$', re.MULTILINE)
# `(?:(?!<!--).)*?` is what stops a stray opener from pairing with a distant
# `-->`: a span containing another `<!--` is not a comment, so the engine falls
# through to the real block instead of eating everything in between.
HTML_COMMENT_RE = re.compile(r'<!--(?:(?!<!--).)*?-->', re.DOTALL)
COMMENT_MAX_SPAN = 2000


def blank(text):
    """Replace every non-newline character with a space.

    Masking rather than deleting is load-bearing: length and line structure are
    preserved, so an offset computed on a masked copy still indexes the
    original. That is what lets suppression be positional across two scans.
    """
    return re.sub(r'[^\n]', ' ', text)


def strip_html_comments(text):
    """Blank bounded HTML comments. Returns (masked_text, refused_count).

    Comments are LOCATED on a copy with code fences and spans blanked, and then
    blanked out of the ORIGINAL at those offsets. Running the search over the
    raw body was a third silent-swallow shape, in the same class as the two the
    nested-opener guard and COMMENT_MAX_SPAN close: a backticked `<!--` in
    prose is literal text, not an opener, but the raw scan paired it with any
    later plain `-->` and blanked everything between. Measured: a body reading
    "We use `<!--` rule markers here." then "Fixed in #451 and #452." then
    "flow: A --> B" reported NO refs, with comment_strip_refused 0 and nothing
    on stderr — under 2000 chars and free of a nested opener, so neither
    existing guard fires. Both ingredients are ordinary here: AGENTS.md
    documents `<!-- rule: <id> -->` parity markers, and `-->` is a mermaid
    arrow. blank() is length-preserving, which is what makes the offsets from
    the probe index the original exactly.

    The example above uses SINGLE backticks deliberately. The first version of
    this docstring wrote it with double ones, and the span regex of the day
    paired `` as an empty span — so the very body this text offered as fixed
    still swallowed, silently.
    """
    probe = mask_code(text)
    out, pos, refused = [], 0, 0
    for m in HTML_COMMENT_RE.finditer(probe):
        if m.end() - m.start() > COMMENT_MAX_SPAN:
            refused += 1          # left in place: refs inside stay visible
            continue
        out.append(text[pos:m.start()])
        out.append(blank(text[m.start():m.end()]))
        pos = m.end()
    out.append(text[pos:])
    return "".join(out), refused


def mask(text, *patterns):
    for pattern in patterns:
        text = pattern.sub(lambda m: blank(m.group(0)), text)
    return text


issue_to_prs = {}
comment_refusal_prs = []
for pr in prs:
    title = pr.get("title", "")
    body, comment_refusals = strip_html_comments(pr.get("body") or "")
    if comment_refusals:
        comment_refusal_prs.append(pr["number"])

    # issue number -> the arms that fired, recorded in title-then-body order.
    arms = {}
    for group in group_re.findall(title):
        for m in issue_in_group_re.finditer(group):
            arms.setdefault(int(m.group(1)), ["title"])

    # Keywords come from prose only; refs come from everywhere. Same length,
    # so the offsets below index both strings interchangeably.
    keyword_text = mask(mask_code(body), BLOCKQUOTE_RE)
    governed = {m.start(1) for m in CLOSING_KEYWORD_RE.finditer(keyword_text)}

    for m in BODY_REF_RE.finditer(body):
        if m.start(1) in governed:
            continue
        fired = arms.setdefault(int(m.group(1)), [])
        if "body" not in fired:
            fired.append("body")

    for n, fired in arms.items():
        finding = {
            "pr_number": pr["number"],
            "pr_title": pr["title"],
            "mergedAt": pr.get("mergedAt"),
            "matched_via": "+".join(fired),
        }
        if comment_refusals:
            finding["comment_strip_refused"] = comment_refusals
        issue_to_prs.setdefault(n, []).append(finding)

shipped_but_open = []
stub_body = []

for issue in issues:
    n = issue["number"]
    body = (issue.get("body") or "").strip()
    title = issue.get("title", "")

    matching_prs = issue_to_prs.get(n, [])
    if matching_prs:
        shipped_but_open.append({
            "issue": n,
            "title": title,
            "merged_prs": matching_prs,
        })

    if len(body) < 80 or body.lower() in ("tbd", "todo", "..."):
        stub_body.append({
            "issue": n,
            "title": title,
            "body_length": len(body),
            "body_preview": body[:120] if body else "",
        })

# --- detector 3: tracking-parent-complete ------------------------------------
# groom-backlog's epic split gives every child a literal `Part of #<parent>`
# line and gives the parent nothing, so the link is one-directional and only the
# children can be read for it. Build parent -> children from every issue in the
# repo, then report the OPEN parents whose children have ALL closed.
#
# The trailing (?![0-9]) is the PREFIX GUARD. Without a "the next character is
# not a digit" requirement, a match for parent #28 also claims every child of
# #283, and #28 gets reported complete on somebody else's finished work.
# GitHub's own text search has exactly that hole — it will not anchor `#28`
# against `#283` — which is why this is a body scan here and not a
# `--search "Part of #28"` query per candidate.
PART_OF_RE = re.compile(r'Part of #(\d+)(?![0-9])', re.IGNORECASE)

by_number = {i["number"]: i for i in all_issues}
parent_to_children = {}
for issue in all_issues:
    seen_parents = set()
    for m in PART_OF_RE.finditer(issue.get("body") or ""):
        parent_n = int(m.group(1))
        if parent_n == issue["number"] or parent_n in seen_parents:
            continue
        seen_parents.add(parent_n)
        parent_to_children.setdefault(parent_n, []).append(issue)

tracking_parent_complete = []
for parent_n, children in sorted(parent_to_children.items()):
    parent = by_number.get(parent_n)
    # An unknown parent number is a cross-repo or malformed reference, not a
    # finding. A closed parent is already reconciled.
    if parent is None or parent.get("state") != "OPEN":
        continue
    if not all(c.get("state") == "CLOSED" for c in children):
        continue
    tracking_parent_complete.append({
        "issue": parent_n,
        "title": parent.get("title", ""),
        "child_count": len(children),
        "children": sorted(c["number"] for c in children),
    })

# A pull that came back AT the ceiling saw an unknown slice of the repo, so an
# empty result means "found nothing in what I could see", not "clean". Say so
# in the payload rather than letting a consumer read silence as a pass.
truncated = len(all_issues) >= all_limit

print("=== shipped-but-still-open ===")
print(json.dumps(shipped_but_open, indent=2))
print("=== stub-body ===")
print(json.dumps(stub_body, indent=2))
print("=== tracking-parent-complete ===")
print(json.dumps({
    "truncated": truncated,
    "limit": all_limit,
    "scanned": len(all_issues),
    "parents": tracking_parent_complete,
}, indent=2))

if truncated:
    print(
        "WARNING: the all-state issue pull returned %d == ALL_LIMIT (%d), so the "
        "parent->child map is TRUNCATED. Treat tracking-parent-complete as "
        "UNKNOWN, not clean, and re-run with a higher ALL_LIMIT."
        % (len(all_issues), all_limit),
        file=sys.stderr,
    )

if comment_refusal_prs:
    # Same rule as truncation: the refusal has to reach a reader. An HTML
    # comment renders as nothing, so a body the strip declined to touch looks
    # identical to one that had no comment at all.
    print(
        "WARNING: refused to strip an HTML comment longer than %d chars in PR(s) "
        "%s — a stray `<!--` can otherwise swallow the whole body. Refs inside "
        "those comments are INCLUDED below and may be template boilerplate; the "
        "findings carry `comment_strip_refused`."
        % (COMMENT_MAX_SPAN, ", ".join("#%d" % n for n in comment_refusal_prs)),
        file=sys.stderr,
    )
PY
