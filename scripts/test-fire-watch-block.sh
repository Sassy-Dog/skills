#!/usr/bin/env bash
# test-fire-watch-block.sh — pins the contract between the daily-fire-watch
# routine's Slack post and its one automated consumer, `work-fire-watch`.
#
# Why this exists: the consumer was first written against THIS repo's
# `whats-on-fire` template and would have matched zero real posts — the routine
# runs the flattened copy in `routines`, whose delivered post is Slack
# mrkdwn that changes prose shape from day to day (bullets one morning, inline
# runs the next). Two reviews found it, one by fetching the producer and one by
# reading the channel. The fix was to stop parsing prose: the routine appends a
# fenced `fire-watch-v1` machine block and the consumer reads only that. What
# this gate pins is the part a later tidy would undo without anything failing:
#
#   1. THE SENTINELS ARE SPELLED THE SAME IN BOTH HOMES. The consumer
#      (`skills/work-fire-watch/SKILL.md`) and the contract table
#      (`docs/ROUTINES.md` "Consumers of the posted report") both carry the
#      block name, the channel id, the poster's Slack user id, and the
#      rendered first line `Daily Fire Watch (` — the one WITHOUT the leading
#      `#`, which is how Slack delivers it and how the routines repo's own
#      heartbeat greps for it. A "fix" that restores the Markdown `# ` in one
#      home turns every real post into a stop. The poster id is the security
#      half: the routine posts through a user-scoped connector, so a "bot only"
#      rule can never match and an agent rationalises past it on the forgeable
#      `Sent using` footer — which is exactly the member-authored post the rule
#      exists to exclude. The channel id is the anchor name resolution cannot
#      forge. Neither may be dropped from either home.
#
#   2. THE HANDLE GRAMMAR HAS ONE HOME AND ACCEPTS WHAT THE BLOCK CAN EMIT.
#      `work-recommendations` §3 carries the closed regex and the slug rule;
#      `work-fire-watch` cites it and carries NO second regex literal — the two
#      had already diverged (`|human-only`) inside one PR. The vectors below run
#      the real org's workflow names (`CI`, `Release`, `Routine Heartbeat`)
#      through the slug rule as the prose states it and assert the result
#      matches, because an unslugged `ci-red/CI` silently degrades a red default
#      branch — the one P0 the producer ranks on its own — into a report-only
#      row. Negative vectors pin that the class is closed (`human-only` was
#      removed; `issue:398` is not a handle).
#
#   3. THE NEGATIVE VECTORS ARE LOAD-BEARING. A flattened copy of the home
#      with the grammar widened (uppercase admitted in the slug class,
#      `|human-only` re-added) must accept vectors the real grammar rejects;
#      if the mutant `sed` no longer applies because the literal moved, the
#      gate says THAT rather than reporting the vectors dead.
#
#   4. THE SELECTION RULE THAT CLOSED A BLOCKING FINDING IS PINNED. The
#      consumer judges the pinned poster's NEWEST sentinel post and never
#      pages past it: "first message with a fence" skipped a could-not-run
#      post and dispatched yesterday's items. Both homes spell "never page
#      past", and the old shape must not exist.
#
#   5. THE ASSOCIATION READ GOES THROUGH REST. `gh issue view` and `gh pr view`
#      have no `authorAssociation` JSON field (`Unknown JSON field`), so a §3
#      that names it there turns its own "a read that fails is UNKNOWN -> HOLD"
#      rule against every `pr:#N` and, on a public repo, every `#N`. The gate
#      pins that §3 reads `gh api repos/<owner>/<name>/issues/<N>` and
#      `.../pulls/<N>` with `author_association`, and that no `gh issue view` /
#      `gh pr view` command anywhere under `skills/` requests `authorAssociation`
#      (checked on whitespace-flattened text, so a wrapped command is seen).
#      Scoping, enforced on the two §3 paragraphs (blank-line delimited,
#      flattened, backticks stripped): the ISSUE-read paragraph must carry the
#      `gh api .../issues/<N>` read with `author_association` and the
#      `OWNER`/`MEMBER`/`COLLABORATOR` allow-list; the PR-read paragraph must
#      carry the `gh api .../pulls/<N>` read with `author_association` and the
#      head/base fork comparison, and must NOT name the allow-list — a PR is
#      gated by the fork fact alone, because `dependabot[bot]` has association
#      `NONE` and an allow-list there would make every Dependabot PR
#      CONFIRM-EACH, against §3's own table. The tree-wide scan covers every
#      `*.md` and `*.sh` under `skills/` and flags `authorAssociation` anywhere
#      in the same paragraph as a `gh issue view` / `gh pr view`, which catches
#      the real pre-fix shape (command and field ~470 chars apart in separate
#      code spans, fixture transcribed from 5b024e6).
#      Mutants, all exercised below on scratch copies: the pre-fix paragraph
#      trips the tree-wide scan; dropping the issue-side allow-list, the pulls
#      `author_association`, or the fork comparison fails the positive pin;
#      re-adding the allow-list to the PR paragraph fails the negative pin.
#
# Source-level, no `gh`, no network, no Slack.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONSUMER="$ROOT/skills/work-fire-watch/SKILL.md"
DELEGATE="$ROOT/skills/work-recommendations/SKILL.md"
CONTRACT="$ROOT/docs/ROUTINES.md"

fail=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

for f in "$CONSUMER" "$DELEGATE" "$CONTRACT"; do
    [ -r "$f" ] || { echo "test-fire-watch-block: missing $f" >&2; exit 1; }
done

# --- 1. sentinels in both homes ------------------------------------------------
for needle in 'fire-watch-v1' 'C0BNNEE59PX' 'U0AAJ2WGMTQ' 'Daily Fire Watch (' 'daily-fire-watch could not run.' 'item|<repo>|<kind>|<id>|<tier>|<labels>|<title>' 'top|<rank>|<repo>|<kind>:<id>' 'page past'; do
    for home in "$CONSUMER" "$CONTRACT"; do
        flat="$(tr '\n' ' ' <"$home" | sed 's/  */ /g')"
        if grep -qF -- "$needle" <<<"$flat"; then
            ok "sentinel '$needle' present in ${home#"$ROOT"/}"
        else
            bad "sentinel '$needle' missing from ${home#"$ROOT"/}"
        fi
    done
done
# --- 1b. the block's home is the thread reply (since 2026-09-21) -------------
# Both homes say the block is the pinned poster's FIRST thread reply; the
# consumer pairs that with "never another id's", still states the legacy
# body form for older reports, and no longer says "one message per run".
for needle in 'first reply' 'first line' ; do
    for home in "$CONSUMER" "$CONTRACT"; do
        flat="$(tr '\n' ' ' <"$home" | sed 's/  */ /g')"
        if grep -qF -- "$needle" <<<"$flat"; then
            ok "thread sentinel '$needle' present in ${home#"$ROOT"/}"
        else
            bad "thread sentinel '$needle' missing from ${home#"$ROOT"/}"
        fi
    done
done
flat_consumer="$(tr '\n' ' ' <"$CONSUMER" | sed 's/  */ /g')"
if grep -qF -- 'from the same pinned poster id' <<<"$flat_consumer" && grep -qF -- 'never take a reply from any other id — a thread' <<<"$flat_consumer"; then
    ok "consumer binds the thread reply to the pinned poster id"
else
    bad "consumer no longer binds the thread reply to the pinned poster id"
fi
if grep -qF -- 'carried the block at the end of the message body' <<<"$flat_consumer"; then
    ok "consumer still states the pre-cutover in-body form"
else
    bad "consumer lost the pre-cutover in-body form"
fi
if grep -qF -- 'one message per run' <<<"$flat_consumer"; then
    bad "consumer still says one message per run; the block is a thread reply"
else
    ok "the 'one message per run' shape is absent"
fi
flat_contract="$(tr '\n' ' ' <"$CONTRACT" | sed 's/  */ /g')"
if grep -qF -- 'first reply in every report' <<<"$flat_contract" && grep -qF -- 'never another id' <<<"$flat_contract"; then
    ok "contract doc names the thread reply and the pinned poster's authority over it"
else
    bad "contract doc no longer names the thread reply as the block's home"
fi
# The poster id must sit on the RULE, not only inside the block example.
if grep -qE -- 'select the.*newest message from that user id|from that user id whose first line' "$CONSUMER" && grep -qF -- '`U0AAJ2WGMTQ`, pinned' "$CONSUMER"; then
    ok "consumer's selection rule names the pinned poster id"
else
    bad "consumer's selection rule no longer names the pinned poster id"
fi
if grep -qE -- 'first message from that user id whose text contains' "$CONSUMER"; then
    bad "consumer still carries the 'first message with a fence' selection shape"
else
    ok "the 'first message with a fence' shape is absent"
fi
# The final-segment handle rule is spelled in both the consumer and the delegate.
for home in "$CONSUMER" "$DELEGATE"; do
    if grep -qF -- 'final ` · ` segment' "$home"; then ok "${home#"$ROOT"/} states the final-segment handle rule"; else bad "${home#"$ROOT"/} lost the final-segment handle rule"; fi
done
# The rendered first line has no leading `# ` in either home's sentinel table.
for home in "$CONSUMER" "$CONTRACT"; do
    if grep -qF -- '`# Daily Fire Watch (' "$home" || grep -qE -- '^# Daily Fire Watch \(' "$home"; then
        bad "${home#"$ROOT"/} spells the first-line sentinel with a Markdown '# ' — Slack delivers it without one"
    else
        ok "${home#"$ROOT"/} spells the first-line sentinel as Slack renders it"
    fi
done

# --- 2. one grammar home, and it accepts the block's output -------------------
extract_regex() {  # prints every backticked literal that starts with ^( and ends with )$
    grep -o '`\^([^`]*)\$`' "$1" | sed 's/^`//; s/`$//'
}
n_home="$(extract_regex "$DELEGATE" | wc -l | tr -d ' ')"
n_consumer="$(extract_regex "$CONSUMER" | wc -l | tr -d ' ')"
if [ "$n_home" = "1" ]; then
    ok "work-recommendations carries exactly one handle regex"
else
    bad "work-recommendations carries $n_home handle regex literals (want 1)"
fi
if [ "$n_consumer" = "0" ]; then
    ok "work-fire-watch carries no handle regex literal of its own"
else
    bad "work-fire-watch carries $n_consumer handle regex literal(s) — the grammar has one home"
fi
if grep -qF -- 'work-recommendations` §3' "$CONSUMER"; then
    ok "work-fire-watch cites work-recommendations §3 as the grammar's home"
else
    bad "work-fire-watch does not cite work-recommendations §3"
fi

RE="$(extract_regex "$DELEGATE" | head -n1)"
if [ -z "$RE" ]; then bad "no handle regex extracted — the vector rows below cannot run"; fi

# The five kinds the consumer emits are the five the block defines, and the
# delegate writes exactly three marker prefixes. Bare counts elsewhere in prose
# are safe only while these re-derive them.
for kind in issue pr sentry cron ci-red; do
    if grep -qE -- "^\| \`$kind\` \| " "$CONSUMER"; then ok "consumer emits kind '$kind'"; else bad "consumer's handle table lacks kind '$kind'"; fi
done
# Markers as WRITTEN (`marker \`x-source: …`) must equal the closed set the
# Guardrails sentence names (bare `\`x-source:\``); a fourth prefix at a usage
# site with no Guardrails edit is the drift this catches.
used="$(grep -oE -- 'marker `[a-z-]+-source:' "$DELEGATE" | sed 's/.*`//' | sort -u | tr '\n' ' ')"
named="$(grep -oE -- '`[a-z-]+-source:`' "$DELEGATE" | tr -d '`' | sort -u | tr '\n' ' ')"
if [ "$used" = "fire-watch-source: plate-source: sentry-source: " ] && [ "$used" = "$named" ]; then
    ok "markers written ($used) equal the closed set named"
else
    bad "markers written ('$used') vs named ('$named') — want exactly fire-watch-source: plate-source: sentry-source:"
fi
tiers_row="$(grep -E -- '^\| `tier` \|' "$CONSUMER" | cut -d'|' -f3 | grep -oE -- '`[A-Za-z0-9]+`' | tr -d '`' | sort | tr '\n' ' ')"
flat_consumer="$(tr '\n' ' ' <"$CONSUMER")"
tiers_order="$(grep -oE -- 'by tier — [^.]*' <<<"$flat_consumer" | head -n1 | grep -oE -- '`[A-Za-z0-9]+`' | tr -d '`' | sort | tr '\n' ' ')"
if [ -n "$tiers_row" ] && [ "$tiers_row" = "$tiers_order" ]; then
    ok "tier value set equals the tier order list: $tiers_row"
else
    bad "tier values ('$tiers_row') and the order list ('$tiers_order') disagree"
fi

slug() {  # the slug rule as work-recommendations §3 states it
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}
# The prose must still state the three steps the function above implements.
for phrase in 'lowercase the source' 'outside `[a-z0-9._-]`' 'trim `-`'; do
    if grep -qF -- "$phrase" "$DELEGATE"; then
        ok "slug rule states: $phrase"
    else
        bad "slug rule no longer states: $phrase"
    fi
done

positive=(
    '#398' 'pr:#427' 'sentry:5512345' 'sentry:PLATFORM-H' 'sentry:TAILOREDTIP-IOS-4K7'
    "fire-watch:ci-red/$(slug 'CI')" "fire-watch:ci-red/$(slug 'Release')"
    "fire-watch:ci-red/$(slug 'Routine Heartbeat')" "fire-watch:cron/$(slug 'nightly-export')"
    "fire-watch:cron/$(slug 'cron_ci-runner.cve.watch')"
)
negative=(
    'fire-watch:ci-red/CI' 'fire-watch:ci-red/Routine Heartbeat' 'fire-watch:ci-red/'
    'human-only' 'issue:398' '#abc' 'sentry:' 'pr:427' 'fire-watch:secret/x' '398'
)
if [ -n "$RE" ]; then
    for v in "${positive[@]}"; do
        if [[ "$v" =~ $RE ]]; then ok "accepts '$v'"; else bad "rejects '$v' — the block can emit this"; fi
    done
    for v in "${negative[@]}"; do
        if [[ "$v" =~ $RE ]]; then bad "accepts '$v' — the grammar is closed"; else ok "rejects '$v'"; fi
    done
fi

# --- 3. the vectors have teeth: a widened grammar in a flattened copy flips one ---
tmp="$(mktemp)" || { echo "test-fire-watch-block: mktemp failed" >&2; exit 1; }
[ -n "$tmp" ] && [ -w "$tmp" ] || { echo "test-fire-watch-block: unusable temp file" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT
# Mutant: re-admit `human-only` as a handle kind (the divergence a prior review
# caught) and widen the slug class to accept uppercase.
sed -e 's/|fire-watch:(ci-red|cron)\/\[a-z0-9._-\]+)\$`/|fire-watch:(ci-red|cron)\/[A-Za-z0-9._-]+|human-only)$`/' "$DELEGATE" >"$tmp"
if cmp -s "$DELEGATE" "$tmp"; then
    bad "mutant did not apply — the regex literal moved; update the sed in this gate"
else
    MRE="$(extract_regex "$tmp" | head -n1)"
    if [ -n "$MRE" ] && [[ 'human-only' =~ $MRE ]] && [[ 'fire-watch:ci-red/CI' =~ $MRE ]]; then
        ok "mutant grammar accepts 'human-only' and 'ci-red/CI' — the negative vectors are load-bearing"
    else
        bad "mutant grammar did not flip the negative vectors — the vector rows are not pinning the class"
    fi
fi

# --- 5. the association read goes through REST, never gh issue/pr view -------------
paragraph() {  # $1 = file, $2 = fixed string opening the wanted paragraph; flattened, backticks stripped
    awk -v RS='' -v key="$2" 'index($0, key) == 1 { print; exit }' "$1" | tr '\n' ' ' | tr -d '`' | sed 's/  */ /g'
}
issue_para="$(paragraph "$DELEGATE" '**The label check')"
pr_para="$(paragraph "$DELEGATE" '**The held-PR check')"
issue_read_ok() {  # $1 = issue-read paragraph
    grep -qE -- 'gh api repos/<owner>/<name>/issues/<N> --jq [^}]*author_association}' <<<"$1" \
        && grep -qF -- 'OWNER, MEMBER and COLLABORATOR' <<<"$1"
}
pr_read_ok() {  # $1 = PR-read paragraph: fields present, and no allow-list gate
    grep -qE -- 'gh api repos/<owner>/<name>/pulls/<N> --jq .\{title,[^}]*author_association[^}]*\.head\.repo.*\.base\.repo' <<<"$1" \
        && ! grep -qE -- 'OWNER|COLLABORATOR' <<<"$1"
}
view_offenders() {  # files with authorAssociation in the same paragraph as a gh issue/pr view
    local f hit
    for f in "$@"; do
        hit="$(awk -v RS='' '{ gsub(/\n/, " "); gsub(/`/, ""); if ($0 ~ /gh (issue|pr) view/ && $0 ~ /authorAssociation/) { print "hit"; exit } }' "$f")"
        if [ -n "$hit" ]; then echo "${f#"$ROOT"/}"; fi
    done
    return 0
}
if issue_read_ok "$issue_para"; then
    ok "§3 issue read: gh api issues/<N> with author_association and the member allow-list"
else
    bad "§3 issue-read paragraph lost the gh api issues/<N> read, author_association or the OWNER/MEMBER/COLLABORATOR allow-list"
fi
if pr_read_ok "$pr_para"; then
    ok "§3 PR read: gh api pulls/<N> with title, author_association and the fork comparison, no allow-list gate"
else
    bad "§3 PR-read paragraph lost a pulls/<N> field or gates on the allow-list (Dependabot would be CONFIRM-EACH)"
fi
tree_files=()
while IFS= read -r f; do tree_files+=("$f"); done < <(find "$ROOT/skills" -type f \( -name '*.md' -o -name '*.sh' \))
if [ "${#tree_files[@]}" -eq 0 ]; then
    bad "no markdown or shell found under skills/ — the tree-wide check would be vacuous"
else
    off="$(view_offenders "${tree_files[@]}")"
    if [ -z "$off" ]; then
        ok "no gh issue view / gh pr view under skills/ requests authorAssociation"
    else
        bad "gh issue/pr view requests authorAssociation (no such field) in: $(echo "$off" | tr '\n' ' ')"
    fi
fi
# Mutants. The pre-fix paragraph is transcribed from 5b024e6 (git history is not read here).
printf '%s\n' \
    'from: `gh issue view <N> --json title,labels`. `auto-security-watch` → HUMAN-ONLY; `security` →' \
    'CONFIRM-EACH; **a read that fails or returns no labels field is UNKNOWN → HOLD**, never' \
    'DISPATCH — unknown is not verified, the same shape `take-it` and `file-or-link-issue.sh` use.' \
    'Labels carried on a plate or block line are display only; the live read decides. The live' \
    'title is printed beside each number in the §4 preview, so a steered id is visible before' \
    'approval. On a public repo, `author` and `authorAssociation` are read too and a non-member' \
    'author is CONFIRM-EACH — a cold worker with write access must not take an outsider body' \
    'verbatim on a batch approval.' >"$tmp"
if [ -n "$(view_offenders "$tmp")" ]; then
    ok "mutant: the real pre-fix paragraph (command and field in separate spans) trips the tree-wide scan"
else
    bad "mutant: the real pre-fix paragraph slipped past the tree-wide scan"
fi
printf '%s\n' 'read `gh pr view <N> --json title,author,authorAssociation,isCrossRepository,' 'body,comments` and HOLD' >"$tmp"
if [ -n "$(view_offenders "$tmp")" ]; then
    ok "mutant: wrapped 'gh pr view ... authorAssociation' trips the tree-wide scan"
else
    bad "mutant: wrapped 'gh pr view ... authorAssociation' slipped past the tree-wide scan"
fi
mutate() {  # $1 = sed script, $2 = paragraph key, $3 = checker, $4 = label
    local m
    sed "$1" "$DELEGATE" >"$tmp"
    m="$(paragraph "$tmp" "$2")"
    if cmp -s "$DELEGATE" "$tmp"; then
        bad "mutant '$4' did not apply — the §3 literal moved; update this gate"
    elif "$3" "$m"; then
        bad "mutant '$4' still satisfies the pin"
    else
        ok "mutant '$4' fails the pin"
    fi
}
mutate 's/`OWNER`, `MEMBER` and `COLLABORATOR`/members/' '**The label check' issue_read_ok 'issue-side allow-list dropped'
mutate 's/author_association}'"'"'`$/author}'"'"'/' '**The label check' issue_read_ok 'issue read drops author_association'
mutate 's/{title, author:/{author:/' '**The held-PR check' pr_read_ok 'pulls read drops the PR title'
mutate 's/author_association, fork:/fork:/' '**The held-PR check' pr_read_ok 'pulls read drops author_association'
mutate 's/\.head\.repo\.full_name/.head.x/' '**The held-PR check' pr_read_ok 'pulls read drops the fork comparison'
mutate 's/(fail closed)\./(fail closed) and an association outside `OWNER`, `MEMBER`, `COLLABORATOR` is CONFIRM-EACH./' '**The held-PR check' pr_read_ok 'allow-list gate re-added to the PR read'

if [ "$fail" -eq 0 ]; then
    echo "fire-watch block tests: all green"
    exit 0
fi
echo "fire-watch block tests: FAILURES above"
exit 1
