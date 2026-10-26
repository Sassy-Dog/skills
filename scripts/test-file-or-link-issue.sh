#!/usr/bin/env bash
# test-file-or-link-issue.sh — the ONE write-capable issue path is idempotent
# ACROSS THE SEARCH INDEX'S LAG, and still discriminates (issue #339).
#
# WHAT THE DEFECT WAS. `file-or-link-issue.sh` is this repo's only issue-creation
# path, and docs/ARCHITECTURE.md names marker-keyed idempotency as the reason it exists.
# That idempotency was a read-after-write against GitHub's issue search index,
# which is ASYNCHRONOUS. Measured 2026-09-04 against this repo: #337 filed at
# 21:05:37Z carrying marker `stale-issues-title-only-shipped-detector`; the SAME
# marker re-run at 21:05:44Z searched, got `[]`, and filed the duplicate #338.
# Seven seconds. The identical search four minutes later returned both. The
# marker footer was in #337's body the whole time and the query was correct —
# only the freshness assumption was wrong, and the script reported
# `{"action":"filed"}` both times, which every caller reads as success.
#
# AND NOTHING COVERED THIS SCRIPT AT ALL. `grep -l file-or-link-issue
# scripts/test-*.sh` returned nothing before this file: the property docs/ARCHITECTURE.md
# calls the script's defining one was enforced by prose alone, in a tree whose
# own convention is that a rule with no gate rots silently.
#
# WHY THE FIX IS TWO STAGES AND NOT ONE. `gh issue list` WITHOUT `--search` is a
# direct object read rather than a query against the index, so it returns an
# issue the instant it exists — but it is bounded to the newest N issues. The
# search is the mirror image: unbounded in age, not fresh. Neither alone is
# sufficient, which is why sections 4 and 5 exist as a pair with section 2:
# deleting the scan re-opens #339 (M1, M2), and deleting the search loses every
# marker older than the window (M6). This gate refuses to let a later
# "one lookup is enough, simplify" sweep drop either half.
#
# THE PREMISE IS ASSERTED, NEVER ASSUMED (section 1). #339's own point is that
# an unverified freshness assumption is the bug; replacing it with a second one
# would be the same bug wearing the fix's clothes. So before any verdict is
# trusted, the fixture proves ITSELF: the mock's `--search` path must NOT return
# a just-created issue (the lag, modelled directly, as an index-visibility set
# an issue joins only when the fixture says so) and the mock's DIRECT listing
# MUST return that same issue. Without both, every green below could come from a
# mock that simply answers "already-linked" to everything.
#
# EVERY BEHAVIOURAL VERDICT IS MEASURED AS A WRITE, not as a literal an
# assertion greps for: the harm is a duplicate ISSUE, so what gets counted is
# `gh issue create` calls in the mock's write log. That is also what keeps the
# mutation battery honest — no mutant here can be caught by a string that only
# happens to be present.
#
# THE DISCRIMINATION HALF IS LOAD-BEARING (section 3). A dedupe that answers
# `already-linked` to everything satisfies the reproduction and is useless, so a
# genuinely new marker must still file. Its sharp case is the PREFIX COLLISION,
# and the collision arrives by TWO ROUTES that need the same delimited footer
# `<!-- <marker> -->` for DIFFERENT reasons — which is exactly why applying it to
# one stage is not enough:
#   - stage 2's `contains()` is a plain substring test, so a bare match reports
#     `epic-split: #207/alpha` as already-linked against `#207/alpha-two`;
#   - stage 1's GitHub phrase search matches a token SUBSEQUENCE, verified
#     read-only on 2026-09-04 (`"stale-issues-title-only" in:body` returns
#     #339/#337/#338, whose marker is `stale-issues-title-only-shipped-detector`;
#     a superstring control returns `[]`).
# The first version of this gate seeded the collision sibling as `unindexed`, and
# that ONE WORD was the only reason the case reached stage 2 — with the sibling
# `indexed`, which is the state of any sibling more than a few minutes old, the
# shipped script answered `already-linked` from stage 1 on the bare marker. So
# the stage-1 route is the LIKELIER one, and its harm is quieter than #339's own:
# #339 filed a visible duplicate, this swallows a real `groom-backlog` epic child
# that is never filed. Both routes now have a fixture; M3, M7 and M8 are the
# mutations. Do not "align" either stage back onto the bare marker, and do not
# let the one predicate become two copies again.
#
# UNKNOWN IS NOT VERIFIED (section 6). A scan that could not be PERFORMED is not
# a scan that found nothing, so the script exits 2 rather than filing blind —
# the same shape `align-labels.sh`'s delete gate takes, applied to the write
# that #339 is about. Three fixtures, because the failure gets quieter each
# time: a non-zero exit, a zero exit with a non-JSON payload, and a zero exit
# with NO payload — the last of which no exit code reports and `jq` reads as no
# output and status 0, so a scan validated by jq's status alone files blind. The
# tolerant `|| echo "[]"` form is what M4 restores. Note the asymmetry, which is
# deliberate and not an oversight: stage 1 KEEPS its `|| echo "[]"` degradation,
# because stage 2 below it is the authority; the refusal belongs to the stage
# that is load-bearing for freshness. Section 6b EXECUTES that tolerant branch,
# since a degradation nothing runs is a decision a symmetry sweep deletes while
# staying green.
#
# THE WRITE'S OWN EXIT CODE IS PART OF THE CONTRACT (section 8b). Exit 1 means
# "you called me wrong" and a caller may treat it as permanent; exit 2 means
# retry. Measured: with the create failing under `set -euo pipefail`, errexit
# aborted the `created_url=$(gh issue create … | tail -n1)` assignment on gh's
# status, so the script's own `exit 2` and diagnostic never ran and a transient
# 5xx surfaced as exit 1 with empty stdout AND empty stderr. Both halves are
# asserted, because a bare exit-code check also passes on a run that said
# nothing.
#
# NOT COVERED, and deliberately so. A marker whose issue is BOTH older than the
# `--recent-scan` window AND not yet indexed is invisible to both stages —
# section 5 asserts that limitation rather than hiding it, and pairs it with the
# same input at a raised window, which is what proves the miss is the BOUND
# rather than a broken scan. Reaching it needs a repo to file more than N issues
# inside the index window, which the skill's burst rail already refuses. Also
# uncovered: GitHub's real index TTL, which is GitHub's and not worth pinning —
# the fixture models lag as visibility, not as time.
#
# NO REAL ISSUE IS EVER FILED, AND THAT IS GATED STRUCTURALLY. The reproduction
# in #339 was obtained against the live repo and cost a real duplicate;
# repeating it as a test would be the same mistake with a scripted trigger.
# Everything here runs against a PATH-shimmed mock `gh` under one `mktemp -d`:
# no repo, no network, no live issue read or written.
#
# The shim check therefore lives immediately after `chmod +x` and EXITS, rather
# than being section 1's counted assertion alone. Ordering was not a guarantee:
# section 1 makes five live `gh` calls — one of them `gh issue create` — before
# it asserts anything, this file runs `set -uo pipefail` with no `-e`, and
# `bad()` records without exiting, so a failed `chmod` or a noexec $TMPDIR would
# send a WRITE at api.github.com with the operator's credentials. AGENTS.md is
# verbatim on the shape: irreversible actions are gated structurally, not by
# ordering. For the same reason `$MOCK_REPO` sits in `.invalid` (RFC 2606,
# unregistrable) — the earlier `mock-org` is a REAL GitHub Organization, one
# repo creation away from being a live target.
#
# Mutants are applied by EXACT WHOLE-LINE match through awk, which exits
# non-zero unless the target matched exactly ONCE — a mutation that drifted onto
# no line, or onto two, reports as stale rather than passing against a file that
# was never run. The inventory is the MUTANTS array; the run asserts every
# member ran, so no count here can go stale (#276).
#
# The cells reach awk through $ENVIRON rather than `-v`, and the transport is
# ROUND-TRIPPED and asserted before the battery runs, with an adequacy conjunct
# so a table that lost its last backslash-bearing target cannot make the check
# vacuous. `-v` performs escape processing; with it, this file passed on macOS's
# BWK awk and failed on CI's gawk claiming M2, M3 and M5 were stale mutations —
# a diagnostic that sends the reader to edit target lines that were correct. See
# apply_mutation.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-file-or-link-issue.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-file-or-link-issue: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

FILER="skills/github-issues/scripts/file-or-link-issue.sh"
DOC="skills/github-issues/references/dedupe-and-file.md"

for f in "$FILER" "$DOC"; do
    [ -f "$f" ] || { echo "test-file-or-link-issue: $f missing" >&2; exit 1; }
done

# A missing jq is a courtesy skip locally and a HARD FAILURE in CI: the mock IS
# jq, so a skipped run measures nothing at all, and preflight renders a skip that
# exits 0 as PASS. Same split as test-claim-lifecycle.sh.
if ! command -v jq >/dev/null 2>&1; then
    if [ "${CI:-}" = "true" ]; then
        echo "test-file-or-link-issue: jq is REQUIRED in CI — this gate cannot run without it" >&2
        exit 1
    fi
    echo "test-file-or-link-issue: SKIP (jq not installed — CI still enforces)" >&2
    exit 0
fi

WORK="$(mktemp -d)"
# FAIL CLOSED, STRUCTURALLY. There is no `set -e` here (see the options line
# above), so a failed `mktemp -d` leaves $WORK EMPTY and execution continues
# into `mkdir -p "$WORK/bin"` — that is `mkdir -p /bin`, `cat > /bin/gh`,
# `chmod +x /bin/gh`. The shim guard further down cannot catch it: with $WORK
# empty, BOTH of its operands collapse to `/bin/gh` and the comparison passes.
# Non-root hosts fail the write and the guard fires correctly; as root
# (devcontainer, docker CI image, `act`, a root self-hosted runner) it succeeds
# and leaves a fake `gh` on PATH permanently, while `rm -rf ""` cleans nothing.
# This is the one $TMPDIR failure the guard's own header names as its threat.
if [ -z "$WORK" ] || [ ! -d "$WORK" ] || [ "$WORK" = "/" ]; then
    echo "mktemp -d did not produce a usable scratch directory (got '${WORK:-}'); refusing to run" >&2
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT

fail=0
asserts=0
ok()  { asserts=$((asserts + 1)); echo "  ok    $1" >&2; }
bad() { asserts=$((asserts + 1)); fail=1; echo "  FAIL  $1" >&2; }

echo "file-or-link-issue tests (work: $WORK)" >&2

# --- the mock gh -------------------------------------------------------------
# Three stores, and the middle one IS the defect being modelled:
#   $MOCK_ISSUES   number<TAB>state<TAB>body   (body flattened to one line)
#   $MOCK_INDEXED  the issue numbers the SEARCH index has caught up to
#   $MOCK_WRITES   append-only log of every mutating call
#
# An issue joins $MOCK_ISSUES the moment it is created and joins $MOCK_INDEXED
# only when a fixture says so, so "filed but not yet searchable" is a state the
# fixture can express rather than a timing window a test would have to race.
#
# The `--json` field list is HONOURED rather than ignored: a script that stopped
# asking for `body` would get nulls and match nothing, so the mock cannot paper
# over that. MOCK_FAIL_LIST is scoped to the DIRECT listing alone — if it failed
# the search too, stage 1's `|| echo "[]"` would absorb it and section 6 would be
# measuring the wrong call.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

emit_rows() {  # rows on stdin -> JSON array restricted to $1 (comma-separated)
    jq -R -s --arg repo "$MOCK_REPO" --arg fields "$1" '
        split("\n") | map(select(length > 0)) | map(split("\t"))
        | map({ number: (.[0] | tonumber),
                state:  .[1],
                body:   .[2],
                url:    ("https://github.com/" + $repo + "/issues/" + .[0]) })
        | map(with_entries(select(.key as $k | ($fields | split(",")) | index($k))))'
}

cmd="${1:-}"; shift
case "$cmd" in
    repo) echo "$MOCK_REPO" ;;
    label) echo "label $*" >>"$MOCK_WRITES" ;;
    issue)
        sub="${1:-}"; shift
        case "$sub" in
            list)
                search=""; state="OPEN"; limit="30"; fields="number"
                prev=""
                for a in "$@"; do
                    case "$prev" in
                        --search) search="$a" ;;
                        --state)  state="$a" ;;
                        --limit)  limit="$a" ;;
                        --json)   fields="$a" ;;
                    esac
                    prev="$a"
                done
                if [ -n "$search" ] && [ "${MOCK_FAIL_SEARCH:-0}" = "1" ]; then
                    # Stage 1's `|| echo "[]"` degradation, which nothing else
                    # executes — so without this knob a later symmetry sweep
                    # could delete the tolerance and stay green.
                    echo "gh: HTTP 503 Service Unavailable (search)" >&2
                    exit 1
                fi
                if [ -n "$search" ]; then
                    # THE INDEX. Only issues listed in $MOCK_INDEXED are visible,
                    # which is the lag. The phrase is unwrapped from
                    # `"<marker>" in:body` and matched as a bare substring —
                    # deliberately LOOSER than the delimited footer the script's
                    # own stages use, because this arm models GitHub's search,
                    # not the script's matching.
                    #
                    # Real GitHub is looser still: phrase search matches a token
                    # SUBSEQUENCE, verified read-only on 2026-09-04 —
                    # `"stale-issues-title-only" in:body` returns #339/#337/#338
                    # whose marker is `stale-issues-title-only-shipped-detector`,
                    # while a superstring control returns `[]`. Substring is the
                    # CONSERVATIVE model: it reproduces the prefix collision this
                    # fixture is about without inventing hits elsewhere, so a row
                    # that passes here would also pass against the real index.
                    phrase="${search#\"}"; phrase="${phrase%%\"*}"
                    rows=$(awk -F'\t' -v phrase="$phrase" -v idx="$MOCK_INDEXED" '
                        BEGIN { while ((getline n < idx) > 0) seen[n] = 1 }
                        seen[$1] && index($3, phrase) { print }' "$MOCK_ISSUES")
                    # STATE AND LIMIT ARE HONOURED HERE TOO. Both were parsed
                    # above and then read by this arm not at all, so deleting
                    # `--state all` or `--limit` from stage 1 left all 49
                    # assertions green while production changed underneath:
                    # `gh issue list --state` defaults to OPEN, so without it an
                    # INDEXED marker on a CLOSED issue older than the recent-scan
                    # window is invisible to BOTH stages and the run re-files a
                    # duplicate. The script's comment beside stage 2 declares the
                    # property on both stages; only one of them was pinned.
                    #
                    # `awk NF` rather than the direct arm's bare `printf`: a
                    # search legitimately matching nothing must emit no rows, not
                    # one blank one. The direct read is never empty by
                    # construction, which is why only this arm needs it.
                    if [ "$state" != "all" ]; then
                        rows=$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "OPEN"')
                    fi
                    printf '%s\n' "$rows" | awk 'NF' | head -n "$limit" | emit_rows "$fields"
                    exit 0
                fi
                if [ "${MOCK_FAIL_LIST:-0}" = "1" ]; then
                    echo "gh: HTTP 502 Bad Gateway (api.github.com)" >&2
                    exit 1
                fi
                if [ "${MOCK_BAD_JSON:-0}" = "1" ]; then
                    # A SUCCESSFUL call whose payload is not JSON. Distinct from
                    # MOCK_FAIL_LIST: no exit code reports this one.
                    echo "<!DOCTYPE html><html>rate limited</html>"
                    exit 0
                fi
                if [ "${MOCK_EMPTY_LIST:-0}" = "1" ]; then
                    # A SUCCESSFUL call that printed NOTHING — the quietest of
                    # the three, and the one an exit code and a JSON parse both
                    # miss: `jq` reads empty input as no output and exits 0, so
                    # a scan validated only by jq's status falls through and
                    # files blind.
                    exit 0
                fi
                # The DIRECT read: newest-first by number, state-filtered, then
                # bounded by --limit. Fresh by construction — $MOCK_INDEXED is
                # not consulted at all on this path.
                rows=$(sort -t"$(printf '\t')" -k1,1nr "$MOCK_ISSUES")
                if [ "$state" != "all" ]; then
                    rows=$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "OPEN"')
                fi
                printf '%s\n' "$rows" | head -n "$limit" | emit_rows "$fields"
                exit 0 ;;
            create)
                if [ "${MOCK_FAIL_CREATE:-0}" = "1" ]; then
                    # The most likely write failure — a transient 5xx. gh writes
                    # its own diagnostic to stderr; the point of the row that
                    # uses this knob is which EXIT CODE the caller sees.
                    echo "gh: HTTP 502 Bad Gateway (api.github.com)" >&2
                    exit 1
                fi
                if [ "${MOCK_BAD_CREATE_URL:-0}" = "1" ]; then
                    # gh exits 0 having printed something that is not an issue
                    # URL on its last line. Nothing was necessarily created, so
                    # the number cannot be parsed and the run must not claim one.
                    echo "Creating issue in $MOCK_REPO"
                    exit 0
                fi
                title=""; body_file=""
                prev=""
                for a in "$@"; do
                    case "$prev" in
                        --title)     title="$a" ;;
                        --body-file) body_file="$a" ;;
                    esac
                    prev="$a"
                done
                next=$(awk -F'\t' 'BEGIN { m = 0 } $1 + 0 > m { m = $1 + 0 } END { print m + 1 }' "$MOCK_ISSUES")
                body=$(tr '\n\t' '  ' <"$body_file")
                printf '%s\t%s\t%s\n' "$next" "OPEN" "$body" >>"$MOCK_ISSUES"
                # NOT added to $MOCK_INDEXED. That omission is the whole fixture:
                # a freshly created issue is real and unsearchable, exactly as
                # #337 was for at least seven seconds.
                echo "create $next $title" >>"$MOCK_WRITES"
                echo "https://github.com/$MOCK_REPO/issues/$next"
                exit 0 ;;
            *) echo "mock gh: unhandled issue subcommand: $sub" >&2; exit 1 ;;
        esac ;;
    *) echo "mock gh: unhandled command: $cmd" >&2; exit 1 ;;
esac
MOCK
chmod +x "$WORK/bin/gh"

# THE SHIM IS GATED STRUCTURALLY, NOT BY ORDERING, AND THIS IS THE GATE. Below,
# section 1 makes five live `gh` calls — one of them `gh issue create` — before
# it asserts anything, and this file runs `set -uo pipefail` with NO `-e` while
# `bad()` records without exiting. So an ordering-based guarantee is no
# guarantee: a failed `chmod`, a noexec or unwritable $TMPDIR, and the probe
# reaches api.github.com with the operator's credentials and attempts a WRITE.
# AGENTS.md is verbatim on the shape — "irreversible actions are gated
# structurally, not by ordering… one call site, its own fresh verification in
# the same body" — so the check lives HERE, immediately after chmod, and it
# EXITS rather than recording. The counted assertion in section 1 stays where it
# is; it reports the property, this refuses to proceed without it.
if [ "$(PATH="$WORK/bin:$PATH" command -v gh)" != "$WORK/bin/gh" ]; then
    echo "test-file-or-link-issue: the mock gh shim did not install at $WORK/bin/gh — refusing to run, because every probe below would reach the real GitHub API with write intent" >&2
    exit 1
fi

# `.invalid` is reserved by RFC 2606 and can never be registered, so no owner
# segment here can resolve to a real account. The previous value was
# `mock-org/mock-repo`, and `mock-org` is a REAL GitHub Organization — only the
# repo 404s, which is one repo creation away from being a live write target.
export MOCK_REPO="mock-org.invalid/mock-repo"
export MOCK_ISSUES="$WORK/issues.tsv"
export MOCK_INDEXED="$WORK/indexed.txt"
export MOCK_WRITES="$WORK/writes.log"
BODY="$WORK/body.md"
printf 'A body a caller supplied.\n' >"$BODY"

add_issue() {  # <number> <state> <one-line body> <indexed|unindexed>
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$MOCK_ISSUES"
    [ "$4" = "indexed" ] && printf '%s\n' "$1" >>"$MOCK_INDEXED"
    return 0
}

# The seed. Numbers ascend with age, as GitHub's do, so "outside the newest N"
# is expressible. Markers are carried in the SCRIPT-OWNED footer form, because
# that is what every issue this script filed actually looks like.
seed_store() {
    : >"$MOCK_ISSUES"; : >"$MOCK_INDEXED"; : >"$MOCK_WRITES"
    # #1 is CLOSED, INDEXED and older than any window used here — so ONLY stage 1
    # can answer it, and only while stage 1 passes `--state all`. `gh issue list
    # --state` defaults to OPEN, so dropping that flag makes this marker
    # invisible to both stages and the run re-files a duplicate. Nothing pinned
    # that before: the mock parsed `--state` on the search arm and read it on
    # neither, so the flag was deletable with all 49 assertions green.
    add_issue 1 CLOSED "Closed, indexed, older than any window <!-- closed-deep-marker -->" indexed
    add_issue 2 OPEN   "Old and indexed <!-- deep-marker -->"                       indexed
    add_issue 3 OPEN   "Old and never indexed <!-- outside-window -->"              unindexed
    add_issue 4 CLOSED "Closed, never indexed <!-- closed-marker -->"               unindexed
    add_issue 5 OPEN   "Collision sibling <!-- epic-split: #207/alpha-two -->"      unindexed
    add_issue 6 OPEN   "Recent and indexed <!-- warm-marker -->"                    indexed
    # THE SAME COLLISION ON THE OTHER ROUTE, and the more likely one. #4 is
    # unindexed, so `epic-split: #207/alpha` reaches stage 2 — which is the only
    # reason the first version of this fixture exercised the footer predicate at
    # all. A sibling more than a few minutes old IS indexed, so it is answered by
    # stage 1, and the review that found this flipped exactly this word to prove
    # it. Distinct parent so the two rows cannot mask each other.
    add_issue 7 OPEN   "Collision sibling, INDEXED <!-- epic-split: #311/beta-two -->" indexed
}

run_file() {  # <script> [args...]
    local script="$1"; shift
    RC=0
    OUT=$(PATH="$WORK/bin:$PATH" bash "$script" --repo "$MOCK_REPO" "$@" 2>"$WORK/stderr") || RC=$?
    ERR=$(cat "$WORK/stderr")
}
file_it() { run_file "$FILER" "$@"; }

action_of() { jq -r '.action // empty' <<<"$OUT" 2>/dev/null; }
via_of()    { jq -r '.via    // empty' <<<"$OUT" 2>/dev/null; }
number_of() { jq -r '.number // empty' <<<"$OUT" 2>/dev/null; }
creates()   { awk 'BEGIN { n = 0 } /^create /{ n++ } END { print n }' "$MOCK_WRITES"; }

# --- 1. the fixture proves itself before any verdict is trusted --------------
seed_store
mock_search=$(PATH="$WORK/bin:$PATH" gh issue list --repo "$MOCK_REPO" --state all \
    --search '"fresh-probe" in:body' --json number,url --limit 5)
mock_direct=$(PATH="$WORK/bin:$PATH" gh issue list --repo "$MOCK_REPO" --state all \
    --json number,url,body --limit 100)
# A create through the mock, then the two reads again — the lag, demonstrated.
PATH="$WORK/bin:$PATH" gh issue create --repo "$MOCK_REPO" --title "probe" \
    --body-file <(printf 'probe <!-- fresh-probe -->\n') >/dev/null
after_search=$(PATH="$WORK/bin:$PATH" gh issue list --repo "$MOCK_REPO" --state all \
    --search '"fresh-probe" in:body' --json number,url --limit 5)
after_direct=$(PATH="$WORK/bin:$PATH" gh issue list --repo "$MOCK_REPO" --state all \
    --json number,url,body --limit 100)

if [ "$(jq 'length' <<<"$mock_search")" = "0" ] && [ "$(jq 'length' <<<"$after_search")" = "0" ]; then
    ok "the mock's search index does NOT see a just-created issue — the #339 lag is modelled, not assumed"
else
    bad "the mock's search returned the just-created issue, so no case below is exercising index lag at all"
fi
if [ "$(jq --arg m "fresh-probe" 'map(select(.body | contains($m))) | length' <<<"$after_direct")" = "1" ] \
   && [ "$(jq --arg m "fresh-probe" 'map(select(.body | contains($m))) | length' <<<"$mock_direct")" = "0" ]; then
    ok "the mock's DIRECT listing sees that same issue immediately — read-after-write consistency is demonstrated by the fixture"
else
    bad "the mock's direct listing did not go from 0 to 1 across the create — the fixture cannot demonstrate the property the fix rests on"
fi
resolved_gh=$(PATH="$WORK/bin:$PATH" command -v gh)
if [ "$resolved_gh" = "$WORK/bin/gh" ]; then
    ok "the PATH shim resolves gh to the mock ($resolved_gh) — no run below can reach the network"
else
    bad "gh resolves to '$resolved_gh', not the mock — this gate would file REAL issues; refusing to trust anything below"
fi

# --- 2. the #339 reproduction, inverted --------------------------------------
# The acceptance criterion verbatim: file marker M, immediately re-file M, get
# already-linked with the FIRST issue's number and no second issue.
seed_store
file_it --marker "sentry-source: MOCK-1" --title "First" --body-file "$BODY"
first_action=$(action_of); first_number=$(number_of); first_creates=$(creates)
file_it --marker "sentry-source: MOCK-1" --title "Second" --body-file "$BODY"

if [ "$first_action" = "filed" ] && [ "$first_creates" = "1" ]; then
    ok "the first call files the issue (action=filed, 1 create)"
else
    bad "the first call reported '$first_action' with $first_creates creates — the reproduction's premise is broken"
fi
if [ "$(action_of)" = "already-linked" ]; then
    ok "re-filing the SAME marker seconds later returns already-linked (#339's reproduction, inverted)"
else
    bad "re-filing the same marker returned '$(action_of)' (rc=$RC) — #339 is not fixed: $ERR"
fi
if [ "$(number_of)" = "$first_number" ]; then
    ok "already-linked names the FIRST issue's number (#$first_number)"
else
    bad "already-linked named #$(number_of), not the first issue's #$first_number"
fi
if [ "$(via_of)" = "recent-scan" ]; then
    ok "it answered via the recent-scan, not the search — the direct read is what closed the window"
else
    bad "already-linked reported via='$(via_of)'; under index lag only the recent-scan can answer, so this verdict came from somewhere unexpected"
fi
if [ "$(creates)" = "1" ]; then
    ok "no second issue was created (the write log still holds exactly 1 create)"
else
    bad "$(creates) creates recorded — the duplicate #339 describes was filed again"
fi

# --- 3. discrimination: a genuinely new marker still files -------------------
seed_store
file_it --marker "sentry-source: BRAND-NEW" --title "New" --body-file "$BODY"
if [ "$(action_of)" = "filed" ]; then
    ok "a marker no issue carries still FILES — the dedupe discriminates rather than answering already-linked to everything"
else
    bad "a genuinely new marker returned '$(action_of)' (rc=$RC) — the dedupe is useless: $ERR"
fi
if [ "$(creates)" = "1" ]; then
    ok "…and the create actually happened (1 in the write log)"
else
    bad "a new marker reported filed but the write log holds $(creates) creates"
fi

# The sharp case: #4 carries `epic-split: #207/alpha-two`, which CONTAINS
# `epic-split: #207/alpha` as a substring. A bare match reports already-linked
# and the child issue is silently never filed.
seed_store
file_it --marker "epic-split: #207/alpha" --title "Alpha" --body-file "$BODY"
if [ "$(action_of)" = "filed" ]; then
    ok "a marker that is a PREFIX of an existing one still files — the scan matches the delimited footer, not a bare substring"
else
    bad "'epic-split: #207/alpha' returned '$(action_of)' against an existing 'epic-split: #207/alpha-two' — a real groom-backlog marker shape is being swallowed"
fi
if [ "$(number_of)" != "5" ]; then
    ok "…and it is a new issue (#$(number_of)), not the colliding sibling #5"
else
    bad "the prefix-collision case returned the sibling issue #5 itself"
fi

# THE SAME COLLISION VIA STAGE 1, which is the likelier route and was the one
# left open when the footer predicate shipped on stage 2 alone. #7 is INDEXED,
# so the search answers first; the predicate must reject it and let the run fall
# through to the scan rather than short-circuiting on a sibling.
seed_store
file_it --marker "epic-split: #311/beta" --title "Beta" --body-file "$BODY"
if [ "$(action_of)" = "filed" ]; then
    ok "a prefix collision on an INDEXED sibling also files — stage 1 filters its rows rather than trusting the search"
else
    bad "'epic-split: #311/beta' returned '$(action_of)' #$(number_of) via='$(via_of)' against the indexed sibling #7 — a real epic child is being swallowed on the likelier of the two routes"
fi
if [ "$(number_of)" != "7" ]; then
    ok "…and it is a new issue (#$(number_of)), not the indexed sibling #7"
else
    bad "the stage-1 collision case returned the sibling issue #7 itself"
fi

# --- 4. the search stage still carries its own weight ------------------------
# #2 is INDEXED and OLD. With a window of 2 it is outside the scan entirely, so
# only the search can find it. This is the half M6 deletes.
seed_store
file_it --marker "deep-marker" --title "Deep" --body-file "$BODY" --recent-scan 2
if [ "$(action_of)" = "already-linked" ] && [ "$(number_of)" = "2" ]; then
    ok "a marker older than the scan window is still found — the search stage covers depth the listing cannot"
else
    bad "an indexed marker outside the scan window returned '$(action_of)' #$(number_of) (rc=$RC) — the search stage has stopped working: $ERR"
fi
if [ "$(via_of)" = "search" ]; then
    ok "…and it answered via='search', so stage 1 short-circuits before the scan runs"
else
    bad "the deep marker answered via='$(via_of)' — expected the search stage"
fi

# THE SAME DEPTH ROUTE ON A **CLOSED** ISSUE. #1 is closed, indexed and outside
# the window, so stage 1 is the only stage that can answer — and only while it
# passes `--state all`. Without that flag gh defaults to OPEN, the marker is
# invisible to BOTH stages, and the run files a duplicate of an issue that
# already exists. M9 is the mutation; this row is what M9 reddens.
seed_store
file_it --marker "closed-deep-marker" --title "ClosedDeep" --body-file "$BODY" --recent-scan 2
if [ "$(action_of)" = "already-linked" ] && [ "$(number_of)" = "1" ]; then
    ok "an indexed marker on a CLOSED issue outside the window is still found — stage 1 asks for --state all"
else
    bad "a closed, indexed marker outside the scan window returned '$(action_of)' #$(number_of) (rc=$RC) — stage 1 has stopped asking for every state, so it re-files an issue that exists: $ERR"
fi

# --- 5. the bound is REAL, and is the bound rather than a broken scan --------
# These two rows are a pair. The first alone would also pass against a scan that
# never matches anything; the second is what makes it a statement about N.
seed_store
file_it --marker "outside-window" --title "Outside" --body-file "$BODY" --recent-scan 2
if [ "$(action_of)" = "filed" ]; then
    ok "a marker that is BOTH unindexed and outside the window is missed and files — the documented limitation, asserted rather than hidden"
else
    bad "the out-of-window unindexed marker returned '$(action_of)' — the window is not bounded the way the script documents"
fi
seed_store
file_it --marker "outside-window" --title "Outside" --body-file "$BODY" --recent-scan 5
if [ "$(action_of)" = "already-linked" ] && [ "$(via_of)" = "recent-scan" ] && [ "$(creates)" = "0" ]; then
    ok "the SAME input at a raised --recent-scan is found via the scan — the miss above is the bound, not a scan that matches nothing"
else
    bad "raising --recent-scan did not find the marker (action='$(action_of)' via='$(via_of)' creates=$(creates)) — the previous row proves nothing"
fi

# --- 6. unknown is not verified ---------------------------------------------
seed_store
MOCK_FAIL_LIST=1 file_it --marker "scan-failed" --title "Unknown" --body-file "$BODY"
if [ "$RC" = "2" ]; then
    ok "a scan that could not be PERFORMED exits 2 — an unverified idempotency read never licenses a write"
else
    bad "a failed scan exited $RC reporting '$(action_of)' — the script filed on an answer it never got"
fi
if [ "$(creates)" = "0" ]; then
    ok "…and nothing was created"
else
    bad "$(creates) issues created after a failed idempotency scan"
fi
seed_store
MOCK_BAD_JSON=1 file_it --marker "scan-garbage" --title "Garbage" --body-file "$BODY"
if [ "$RC" = "2" ]; then
    ok "a scan that SUCCEEDED with an unparseable payload also exits 2 — no exit code reports that one, so it needs its own arm"
else
    bad "an unparseable scan payload exited $RC reporting '$(action_of)'"
fi
if [ "$(creates)" = "0" ]; then
    ok "…and nothing was created"
else
    bad "$(creates) issues created after an unparseable idempotency scan"
fi
# The quietest of the three: gh exits 0 having printed nothing. No exit code
# reports it, and `jq` reads empty input as no output and exits 0 — so a scan
# validated by jq's status alone falls through and files blind.
seed_store
MOCK_EMPTY_LIST=1 file_it --marker "scan-empty" --title "Empty" --body-file "$BODY"
if [ "$RC" = "2" ] && [ "$(creates)" = "0" ]; then
    ok "a scan that exits 0 printing NOTHING is refused too — jq's exit status alone cannot tell that apart from a clean empty repo"
else
    bad "an empty scan payload exited $RC with $(creates) creates — the last blind-file path is open"
fi

# --- 6b. the search stage's degradation is executed, not merely written -------
# Stage 1 keeps `|| echo "[]"` while stage 2 refuses; that asymmetry is a
# decision, and nothing else in this file runs the tolerant branch. Without this
# row a symmetry sweep could delete it and stay green.
seed_store
file_it --marker "degrade-me" --title "Real" --body-file "$BODY"
: >"$MOCK_WRITES"
MOCK_FAIL_SEARCH=1 file_it --marker "degrade-me" --title "Again" --body-file "$BODY"
if [ "$(action_of)" = "already-linked" ] && [ "$(via_of)" = "recent-scan" ] && [ "$(creates)" = "0" ]; then
    ok "a FAILED search degrades to no-hit and stage 2 still answers — the asymmetry with stage 2's refusal is exercised, not just asserted"
else
    bad "with the search failing, the run reported '$(action_of)' via='$(via_of)' rc=$RC with $(creates) creates — stage 1's degradation or stage 2's authority is broken"
fi

# --- 6c. a full window is never a silent clean read --------------------------
# `--recent-scan 2` against a 6-issue store comes back full, so a marker one row
# past the edge is invisible. Paired with a window that has headroom, or the
# field would be indistinguishable from a constant.
seed_store
file_it --marker "truncation-probe" --title "Full" --body-file "$BODY" --recent-scan 2
# Read with a bare `.scan_truncated`, never `// empty`: jq's alternative
# operator treats `false` as absent, so the false half of this pair would read
# as a missing field and the row would fail for the wrong reason.
full_flag=$(jq -r '.scan_truncated' <<<"$OUT" 2>/dev/null)
seed_store
file_it --marker "truncation-probe" --title "Roomy" --body-file "$BODY" --recent-scan 50
roomy_flag=$(jq -r '.scan_truncated' <<<"$OUT" 2>/dev/null)
if [ "$full_flag" = "true" ] && [ "$roomy_flag" = "false" ]; then
    ok "a filing run reports scan_truncated=true on a full window and false on one with headroom — the blind spot is surfaced, not assumed away"
else
    bad "scan_truncated was '$full_flag' on a full window and '$roomy_flag' on a roomy one — a constant, or absent, either way measuring nothing"
fi

# --- 7. --dry-run is unaffected, in both directions --------------------------
seed_store
file_it --marker "preview-only" --title "Preview" --body-file "$BODY" --dry-run
if [ "$(action_of)" = "would-file" ]; then
    ok "--dry-run on a new marker still returns would-file"
else
    bad "--dry-run on a new marker returned '$(action_of)' (rc=$RC): $ERR"
fi
if [ "$(creates)" = "0" ]; then
    ok "…and wrote nothing"
else
    bad "--dry-run created $(creates) issues"
fi
seed_store
file_it --marker "dry-existing" --title "Real" --body-file "$BODY"
: >"$MOCK_WRITES"
file_it --marker "dry-existing" --title "Preview" --body-file "$BODY" --dry-run
if [ "$(action_of)" = "already-linked" ]; then
    ok "--dry-run on a marker filed seconds ago reports already-linked, not would-file — a preview that lies is how a batch gets filed twice"
else
    bad "--dry-run on a just-filed marker returned '$(action_of)' — the preview would have told a caller to file a duplicate"
fi
if [ "$(creates)" = "0" ]; then
    ok "…and still wrote nothing"
else
    bad "--dry-run created $(creates) issues on the already-linked path"
fi

# --- 8. --state all: a CLOSED issue's marker still counts --------------------
seed_store
file_it --marker "closed-marker" --title "Closed" --body-file "$BODY"
if [ "$(action_of)" = "already-linked" ] && [ "$(via_of)" = "recent-scan" ]; then
    ok "a marker on a CLOSED, unindexed issue is found by the scan — dropping --state all would re-file every closed signal"
else
    bad "the closed-issue marker returned '$(action_of)' via='$(via_of)' (rc=$RC): $ERR"
fi

# --- 8b. the WRITE's own failure is exit 2, not exit 1 -----------------------
# Exit 1 is this script's "you called me wrong" code and a caller may treat it as
# permanent. Measured before the fix: with the create failing, `set -euo
# pipefail` aborted the `created_url=$(gh issue create … | tail -n1)` assignment
# on gh's status, so the script's own `exit 2` and its diagnostic never ran and a
# transient 5xx surfaced as exit 1 with EMPTY stdout and EMPTY stderr — the most
# likely failure this path sees, reported as the one code that must not be
# retried, silently. Both halves are asserted, because a bare exit-code check
# would also pass on a run that said nothing.
seed_store
MOCK_FAIL_CREATE=1 file_it --marker "create-fails" --title "Doomed" --body-file "$BODY"
if [ "$RC" = "2" ] && [ -n "$ERR" ]; then
    ok "a failed \`gh issue create\` exits 2 WITH a diagnostic — a retryable transport failure is never reported as a usage error"
else
    bad "a failed create exited $RC with stderr '$ERR' — exit 1 tells a caller the filing is permanently rejected, and an empty stderr tells it nothing at all"
fi
if [ "$(action_of)" = "" ]; then
    ok "…and it claims no issue number, since none was created"
else
    bad "a failed create still reported '$(action_of)' #$(number_of)"
fi
# gh exits 0 having printed something that is not a URL: nothing was necessarily
# created, so the number cannot be parsed and the run must not invent one.
seed_store
MOCK_BAD_CREATE_URL=1 file_it --marker "create-garbage" --title "Odd" --body-file "$BODY"
if [ "$RC" = "2" ] && [ "$(action_of)" = "" ]; then
    ok "a create that exits 0 without printing an issue URL is exit 2 too — a successful call is not a parsed result"
else
    bad "a non-URL create result exited $RC reporting '$(action_of)'"
fi

# --- 9. the window is an argument, and a bad one is refused ------------------
seed_store
file_it --marker "bad-window" --title "Bad" --body-file "$BODY" --recent-scan 0
if [ "$RC" = "1" ] && [ "$(creates)" = "0" ]; then
    ok "--recent-scan 0 is a usage error (exit 1) and files nothing — a zero window is an idempotency check that never runs"
else
    bad "--recent-scan 0 exited $RC with $(creates) creates"
fi

# --- 10. the docs say what the script does -----------------------------------
# The #339 assumption was RECORDED in dedupe-and-file.md as though the index were
# synchronous, so the doc is where a later reader re-derives the deleted stage.
# Flattened, because this repo hard-wraps prose.
doc_flat=$(tr '\n' ' ' <"$DOC" | tr -s ' ')
doc_has() { case "$doc_flat" in *"$1"*) return 0 ;; esac; return 1; }
if doc_has "asynchronous"; then
    ok "$DOC names the search index as asynchronous — the caveat #339 says was missing"
else
    bad "$DOC still describes the search index without saying it is asynchronous, which is the sentence that shipped the bug"
fi
if doc_has "--json number,url,body"; then
    ok "$DOC names the direct read that closes the lag window, not just the search"
else
    bad "$DOC does not name the direct listing read — a reader has only the search stage to go on, as before"
fi
if doc_has "--recent-scan"; then
    ok "$DOC names the bound (--recent-scan), so the scan's limitation is documented where callers read"
else
    bad "$DOC describes the scan without its bound"
fi
if doc_has "#338"; then
    ok "$DOC cites the duplicate the lag actually produced — evidence, so the caveat is not re-deleted as speculation"
else
    bad "$DOC states the lag with no measurement behind it; the next tidy-up sweep deletes an unsupported caveat"
fi
filer_flat=$(tr '\n' ' ' <"$FILER" | tr -s ' ')
case "$filer_flat" in
    *"[--recent-scan"*) ok "$FILER's usage block documents --recent-scan" ;;
    *) bad "$FILER accepts --recent-scan but its usage block does not list it" ;;
esac

# --- 11. mutation proofs ------------------------------------------------------
# Each mutant neuters ONE decision and is proved by the WRITE it causes (or by a
# false already-linked), never by a literal an assertion greps for. Every
# scenario below is asserted CLEAN on the unmutated script in the sections
# above, which is what stops a row passing on the ordinary path.
MUTANT="$WORK/mutant.sh"

# THE MUTATION VALUES REACH awk THROUGH $ENVIRON, NOT THROUGH `-v`, AND THAT IS
# NOT A STYLE CHOICE. `awk -v var=value` performs ESCAPE-SEQUENCE PROCESSING on
# the value, and several cells below carry a backslash — a shell
# line-continuation for M2 and M5, an escaped quote for M2. Measured 2026-09-04:
# with `-v`, every mutant applied cleanly on macOS's BWK awk while M2, M3 and M5
# (M3's target then ended in a continuation too) reported "the
# mutation is stale, repoint it" on CI's gawk — a green local run, a red CI, and
# a diagnostic pointing at the wrong file. $ENVIRON is defined to carry the
# environment byte-for-byte, so it is the transport with no escape layer at all.
# `test-claim-lifecycle.sh` uses `-v` safely only because no line it targets
# contains a backslash; do not read that as licence to switch back here.
apply_mutation() {  # <label> <exact source line> <replacement line>
    local label="$1" from="$2" to="$3" rc=0
    MUT_FROM="$from" MUT_TO="$to" awk '
        BEGIN { n = 0; from = ENVIRON["MUT_FROM"]; to = ENVIRON["MUT_TO"] }
        $0 == from { print to; n++; next }
        { print }
        END { if (n != 1) exit 3 }
    ' "$FILER" >"$MUTANT" || rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "$label — the target line did not match exactly once (awk rc=$rc); the mutation is stale, repoint it"
        return 1
    fi
    if cmp -s "$FILER" "$MUTANT"; then
        bad "$label — the mutation changed nothing, the proof would be vacuous"
        return 1
    fi
    return 0
}

# Scenarios are named rather than inlined, because two of them need a run PAIR
# (file, then re-file) and the write log has to be cleared between the halves.
run_scenario() {  # <script> <scenario>
    local script="$1" sc="$2"
    seed_store
    case "$sc" in
        repro)
            run_file "$script" --marker "mut-repro" --title "First" --body-file "$BODY"
            : >"$MOCK_WRITES"
            run_file "$script" --marker "mut-repro" --title "Second" --body-file "$BODY" ;;
        collision)
            run_file "$script" --marker "epic-split: #207/alpha" --title "Alpha" --body-file "$BODY" ;;
        collision-indexed)
            run_file "$script" --marker "epic-split: #311/beta" --title "Beta" --body-file "$BODY" ;;
        scanfail)
            MOCK_FAIL_LIST=1 run_file "$script" --marker "mut-scanfail" --title "Unknown" --body-file "$BODY" ;;
        closed)
            run_file "$script" --marker "closed-marker" --title "Closed" --body-file "$BODY" ;;
        deep)
            run_file "$script" --marker "deep-marker" --title "Deep" --body-file "$BODY" --recent-scan 2 ;;
        closed-deep)
            run_file "$script" --marker "closed-deep-marker" --title "ClosedDeep" --body-file "$BODY" --recent-scan 2 ;;
        *) return 1 ;;
    esac
    return 0
}

# Each row: label <TAB> from-line <TAB> to-line <TAB> scenario <TAB> expect <TAB> why
#   expect=duplicate  — the mutation must cause a `gh issue create`
#   expect=false-link — the mutation must cause a WRONG already-linked
MUTANTS=(
"M1 the recent-scan's hit is ignored	if [[ -n \"\$recent_hit\" ]]; then	if false; then	repro	duplicate	without stage 2 acting on its hit, re-filing a marker seconds later files the duplicate — #339 verbatim"
"M2 stage 2 asks the search index instead of reading directly	recent=\$(gh issue list --repo \"\$REPO\" --state all \\	recent=\$(gh issue list --repo \"\$REPO\" --state all --search \"\\\"\$marker\\\" in:body\" \\	repro	duplicate	a scan routed through the index inherits the lag it exists to defeat, and looks correct in review"
"M3 the shared footer predicate relaxed to a bare substring, seen from STAGE 2	footer_pick='map(select((.body // \"\") | contains(\"<!-- \" + \$m + \" -->\"))) | sort_by(.number) | first // empty'	footer_pick='map(select((.body // \"\") | contains(\$m))) | sort_by(.number) | first // empty'	collision	false-link	a bare match reports epic-split: #207/alpha as already-linked against the UNINDEXED sibling #207/alpha-two, so a real child issue is silently never filed"
"M4 a failed scan is tolerated as no-hit	if [[ \"\$scan_rc\" -ne 0 ]]; then	if [[ \"\$scan_rc\" -ne 0 ]]; then recent=\"[]\"; fi; if false; then	scanfail	duplicate	the pre-#339 tolerance files blind on exactly the input the guard exists for — unknown treated as verified"
"M5 --state all dropped from the scan	recent=\$(gh issue list --repo \"\$REPO\" --state all \\	recent=\$(gh issue list --repo \"\$REPO\" \\	closed	duplicate	an open-only scan re-files every marker whose issue was closed, which is most of a mature backlog"
"M6 the search stage stops short-circuiting	if [[ -n \"\$search_hit\" ]]; then	if false; then	deep	duplicate	deleting stage 1 as redundant loses every marker older than the scan window — the mirror-image defect"
"M7 the shared footer predicate relaxed, seen from STAGE 1	footer_pick='map(select((.body // \"\") | contains(\"<!-- \" + \$m + \" -->\"))) | sort_by(.number) | first // empty'	footer_pick='map(select((.body // \"\") | contains(\$m))) | sort_by(.number) | first // empty'	collision-indexed	false-link	the SAME widening reaches stage 1 too; this row is what proves both call sites depend on the one predicate rather than stage 2 alone carrying it"
"M9 stage 1 stops asking for every state	existing=\$(gh issue list --repo \"\$REPO\" --state all \\	existing=\$(gh issue list --repo \"\$REPO\" \\	closed-deep	duplicate	'gh issue list --state' defaults to OPEN, so an indexed marker on a CLOSED issue outside the scan window goes invisible to BOTH stages and the run re-files an issue that already exists"
"M8 stage 1 trusts the search result instead of filtering it	search_hit=\$(jq -c --arg m \"\$marker\" \"\$footer_pick\" <<<\"\$existing\" 2>/dev/null || true)	search_hit=\$(jq -c '.[0] // empty' <<<\"\$existing\" 2>/dev/null || true)	collision-indexed	false-link	the exact shape this PR shipped for review: the footer predicate applied to stage 2 while stage 1 short-circuits on a token-subsequence match, swallowing an epic child on the likelier route"
)

# THE TRANSPORT IS MEASURED, NOT TRUSTED. Every cell is round-tripped through
# the SAME awk that applies the mutations and must come back byte-identical.
# Without this the only symptom of a mangling awk is "the mutation is stale,
# repoint it" — which names the wrong file and invites someone to edit a target
# line that was correct all along. This assertion says the transport broke.
transport_bad=""
risky_cells=0
for row in "${MUTANTS[@]}"; do
    IFS=$'\t' read -r t_label t_from t_to _rest <<<"$row"
    for cell in "$t_from" "$t_to"; do
        case "$cell" in *\\*) risky_cells=$((risky_cells + 1)) ;; esac
        if ! printf '%s\n' "$cell" | MUT_FROM="$cell" awk '
            BEGIN { from = ENVIRON["MUT_FROM"]; n = 0 }
            $0 == from { n++ }
            END { if (n != 1) exit 3 }'; then
            transport_bad="$transport_bad $t_label"
        fi
    done
done
# ADEQUACY IS THE SECOND CONJUNCT. A round-trip over cells that carry no
# backslash at all cannot detect an escape-processing transport, so it would
# report a reassuring `ok` on precisely the awk this check exists for. The count
# is derived from the table, so a future row that drops the last backslash-
# bearing target reddens here rather than quietly making this vacuous.
if [ -n "$transport_bad" ]; then
    bad "this awk mangles the mutation cells for:$transport_bad — the battery below would report them as stale targets, which is the wrong diagnosis. The transport is \$ENVIRON precisely so escape processing cannot happen; something reintroduced it."
elif [ "$risky_cells" -lt 1 ]; then
    bad "no mutation cell contains a backslash, so this round-trip cannot detect an escape-processing transport — it would pass on the awk it exists to catch"
else
    ok "every mutation cell survives the awk transport byte-for-byte (${#MUTANTS[@]} rows, both cells; $risky_cells carry a backslash, so the check is not vacuous)"
fi

mut_ran=0
for row in "${MUTANTS[@]}"; do
    IFS=$'\t' read -r m_label m_from m_to m_scenario m_expect m_why <<<"$row"
    apply_mutation "$m_label" "$m_from" "$m_to" || continue
    if ! run_scenario "$MUTANT" "$m_scenario"; then
        bad "$m_label — unknown scenario '$m_scenario'"
        continue
    fi
    # The mutant must still RUN a decision, or its verdict proves nothing. A
    # mutation that broke the shell would otherwise read as "no duplicate filed".
    case "$(action_of)" in
        filed|already-linked|would-file) ;;
        *) bad "$m_label — the mutant produced no decision (rc=$RC, out='$OUT', err='$ERR'), so its verdict proves nothing"
           continue ;;
    esac
    mut_ran=$((mut_ran + 1))
    case "$m_expect" in
        duplicate)
            if [ "$(creates)" -ge 1 ]; then
                ok "$m_label CAUGHT: $m_why"
            else
                bad "$m_label UNDETECTED: the decision was neutered and nothing was filed — its case proves nothing"
            fi ;;
        false-link)
            if [ "$(action_of)" = "already-linked" ]; then
                ok "$m_label CAUGHT: $m_why"
            else
                bad "$m_label UNDETECTED: the match was widened and the run still filed — its case proves nothing"
            fi ;;
        *) bad "$m_label — unknown expectation '$m_expect'" ;;
    esac
done

if [ "$mut_ran" -eq "${#MUTANTS[@]}" ]; then
    ok "every declared mutant ran (${#MUTANTS[@]} of ${#MUTANTS[@]})"
else
    bad "only $mut_ran of ${#MUTANTS[@]} declared mutants ran — the rest proved nothing"
fi

# --- vacuity floor ------------------------------------------------------------
# A broken harness reports a clean tree exactly like a correct one, so the run
# states how much it measured. EQUALITY, not a floor: every case above runs
# exactly one assertion on every path, and each mutant contributes exactly one
# whether it is applied, run, or refused. A floor cannot catch a deleted case;
# an equality forces a deliberate bump here instead of a quiet drift.
EXPECTED_CASES=42
EXPECTED_ASSERTS=$(( ${#MUTANTS[@]} + EXPECTED_CASES ))
if [ "$asserts" -ne "$EXPECTED_ASSERTS" ]; then
    bad "$asserts assertions ran, expected $EXPECTED_ASSERTS (${#MUTANTS[@]} mutants + $EXPECTED_CASES cases) — a case was added or skipped; if deliberate, bump EXPECTED_CASES"
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "file-or-link-issue tests: all pass ($asserts assertions, ${#MUTANTS[@]} mutants)" >&2
    exit 0
fi
echo "file-or-link-issue tests: FAILURES above ($asserts assertions, ${#MUTANTS[@]} mutants)" >&2
exit 1
