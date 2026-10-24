#!/usr/bin/env bash
# test-security-listing.sh — pins the rule that a security-labelled issue is
# never collapsed into a bare count (issue #219).
#
# Why a source-level guard. whats-on-fire's ranking is prose an agent follows,
# so the artifact under test is the instruction — the same shape as
# test-sentry-counts.sh, test-sentry-verification.sh and
# test-visibility-preconditions.sh.
#
# The bug it guards. The label map reached security ONLY through
# (`bug` AND `security`|`area:security`), so a security issue's visibility
# depended on whether it happened to be phrased as a defect. Most real security
# work is not: hardening, a missing control, an unmodelled sanitizer, a policy
# decision. Measured on velovate, two security issues filed the same day at the
# same severity: #2181 (`bug`, `security`, `sev:medium`) normalized to P1 and was
# listed; #2186 (`security`, `observability`, `sev:medium`) normalized to P2 and
# was absorbed into a bare integer. #2186 covers 72 open CodeQL alerts including
# 10 sites logging raw rider coordinates on a product live with real users'
# location history, and it was invisible in every daily-fire-watch post since it
# was filed.
#
# Four decisions are pinned, and 2 is the fragile one:
#
#   1. The `bug` conjunction is GONE from the P1 row. `bug` is a type, not a
#      severity multiplier.
#   2. The fix is a LISTING rule, not a promotion. #219 itself proposed
#      promoting `security` to P1 unconditionally, so a future reader arrives
#      pre-loaded with the rejected option — and promotion re-derives a priority
#      the maintainer already assigned, which this same file forbids two
#      paragraphs earlier. The gate asserts the tier is explicitly untouched.
#   3. `unranked` is covered, not just P2. An unlabelled security issue is the
#      most likely to be new and the least likely to have been triaged.
#   4. The "never re-derive a priority" principle SURVIVES. A listing rule that
#      quietly deleted the principle it was designed to respect would look like
#      a fix and be a regression.
#
# Must-not-exist assertions run against a WHITESPACE-FLATTENED copy, because
# this repo hard-wraps prose and a line-scoped grep turns a wrap into a false
# PASS. Must-exist checks may stay line-scoped: a wrap there fails loudly.
#
# No gh, no network: two tracked files.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-security-listing.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-security-listing: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SCORING="skills/whats-on-fire/references/scoring.md"
SKILL="skills/whats-on-fire/SKILL.md"

fails=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "Security issues are never counted-not-listed (issue #219)"

for f in "$SCORING" "$SKILL"; do
    [ -r "$f" ] || bad "missing file: $f"
done
[ "$fails" -eq 0 ] || { echo "test-security-listing: FAILED" >&2; exit 1; }

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
scoring_flat="$(flat "$SCORING")"
skill_flat="$(flat "$SKILL")"

# --- 1. The bug conjunction is gone from the priority map --------------------

p1_row="$(grep '^| P1 |' "$SCORING")"

if [ -n "$p1_row" ]; then
    ok "the map still has a P1 row"
else
    bad "the P1 row is missing from the map"
fi

# Mutation proof: the pre-#219 row. Scoped to the ROW, not the file — the
# historical wording is quoted in the rationale below and must stay quotable.
if grep -qi 'security' <<<"$p1_row"; then
    bad "the P1 row promotes on security again — the conjunction is back"
else
    ok "the P1 row no longer reaches security at all"
fi

if grep -qi 'bug' <<<"$p1_row"; then
    bad "\`bug\` is back in the priority map as a severity multiplier"
else
    ok "\`bug\` is not a priority-map term"
fi

# --- 2. It is a LISTING rule, not a promotion --------------------------------

if grep -qi 'ALWAYS listed by number' <<<"$scoring_flat"; then
    ok "scoring.md states security issues are always listed"
else
    bad "scoring.md lost the always-listed rule"
fi

if grep -qi 'always listed by number' <<<"$skill_flat"; then
    ok "SKILL.md carries the always-listed rule"
else
    bad "SKILL.md lost the always-listed rule"
fi

# The distinction that keeps this from drifting into the rejected option.
if grep -qiE 'tier is not adjusted' <<<"$scoring_flat"; then
    ok "the rule states the tier is not adjusted"
else
    bad "the rule no longer says the tier is left alone — promotion has crept back in"
fi

if grep -qiE 'rendering. rule|a \*rendering\* rule' <<<"$scoring_flat"; then
    ok "the rule identifies itself as a rendering rule"
else
    bad "the rule no longer identifies itself as a rendering rather than ranking change"
fi

# Its reason, which is what survives a consistency sweep.
if grep -qi 're-deriving priority' <<<"$scoring_flat"; then
    ok "the rule explains why promotion was rejected"
else
    bad "the rule no longer explains why it is not a promotion"
fi

# --- 3. unranked is covered, not just P2 -------------------------------------

if grep -qi 'including .unranked' <<<"$scoring_flat"; then
    ok "scoring.md covers the unranked case"
else
    bad "scoring.md no longer covers unranked security issues"
fi

if grep -qi 'unranked. included' <<<"$skill_flat"; then
    ok "SKILL.md covers the unranked case"
else
    bad "SKILL.md no longer covers unranked security issues"
fi

heat_row="$(grep -i 'Security-labelled backlog issues' "$SCORING")"
if [ -n "$heat_row" ] && grep -qi 'any tier' <<<"$heat_row"; then
    ok "the P2 heat table routes security issues at any tier"
else
    bad "the P2 heat table has no any-tier security row"
fi

# --- 4. The principle the rule works around still stands ---------------------

if grep -qi 're-derive a priority a maintainer already assigned' <<<"$scoring_flat"; then
    ok "the 'never re-derive a priority' principle survives"
else
    bad "the re-derive principle was deleted — the rule now contradicts nothing"
fi

# --- 5. The worked example pins the exact regressed combination --------------

example="$(awk '/^#### Worked example/{f=1; next} /^#{1,4} /{f=0} f' "$SCORING" | grep '^|')"

if [ -n "$example" ]; then
    ok "scoring.md carries the worked example"
else
    bad "the worked example is gone"
fi

# security + sev:medium + NO bug is the combination that regressed silently.
nobug_row="$(printf '%s\n' "$example" | grep '#2186')"
if [ -n "$nobug_row" ] && grep -qi 'listed' <<<"$nobug_row"; then
    ok "the no-\`bug\` security row is shown as listed"
else
    bad "the worked example no longer pins the no-\`bug\` case as listed"
fi

# Both velovate issues must land on the SAME tier now; that equality is the
# whole point, and an example showing them split would mean the fix regressed.
bug_row="$(printf '%s\n' "$example" | grep '#2181')"
tier_of() { printf '%s' "$1" | awk -F'|' '{gsub(/ /,"",$4); print $4}'; }
if [ -n "$bug_row" ] && [ -n "$nobug_row" ] &&
   [ "$(tier_of "$bug_row")" = "$(tier_of "$nobug_row")" ]; then
    ok "the two same-severity security issues now share a tier"
else
    bad "the worked example still splits two same-severity security issues"
fi

if [ "$fails" -ne 0 ]; then
    echo "test-security-listing: FAILED ($fails)" >&2
    exit 1
fi
echo "Security listing tests: all green"
