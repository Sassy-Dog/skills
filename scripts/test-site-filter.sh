#!/usr/bin/env bash
# test-site-filter.sh — the two CONSUMERS of the execution-site declaration:
# dispatch-ready §4's Site filter and take-it's refusal before the claim
# (issue #341, epic #322). #340 put the declaration on the issue — a
# `site:<name>` label, resolved by `queue-snapshot.sh` into a per-issue `sites`
# array — and gated that. Nothing read it. This gate is the other half.
#
# WHY THE CONSUMER IS THE HALF THAT MATTERS, and why it is a HOLD rather than a
# recovery. The costs are asymmetric: a mis-groom is recoverable, a human sees
# the wrong column and moves the card. A wrong dispatch is not. The laptop loop
# claims the issue, moves it to In progress, spends a worktree agent that cannot
# reach the VDI's artifacts or clusters, records `attempt 1 failed`, and on the
# next tick lands the issue in `blocked` under a comment naming the wrong cause.
# So the mismatch is stepped around BEFORE the claim, never discovered after an
# agent has burned an attempt on it.
#
# WATCHDOG KILLS THE SUBJECT'S WHOLE PROCESS GROUP (R32, issue #535). A probe
# that can hang is backgrounded DIRECTLY (not as `( cmd; echo $? >rc ) &`, whose
# `$!` is the wrapper subshell) under `set -m`, so it leads its own process
# group, and the kill is `kill -9 -- -PID`, the group. Killing the PID alone is
# not enough: under M35 the process that actually blocks is the `cat` inside the
# resolver's `$(cat)` command substitution, a grandchild of the probe, and
# `kill -9 PID` reaches only the bash and orphans that `cat` to PID 1 forever,
# one per hanging mutant per preflight run. Take the status from `wait`.
#
# THE FIVE DECISIONS PINNED HERE, each of which reads to a later sweep like
# something to tidy:
#
#   1. THE MATCH IS THE ARRAY FORM, FOLDED ON BOTH SIDES:
#      `not sites or execution_site.lower() in sites`. The array read is the
#      only one that cannot resolve an ambiguous declaration to "any site" — a
#      scalar is null both for "nothing declared" and for "several declared",
#      so `site is None or site == execution_site` widens a conflict into the
#      unconstrained case, which is the direction #322's originating bug ran.
#      The FOLD is two-sided and only one side is somebody else's: the snapshot
#      folds the label's value, and folding the configured value is the reading
#      skill's half. Written as raw equality, a repo configured
#      `execution_site: VDI` holds the VDI loop's own work — the filter
#      refusing precisely the checkout it was written for. EVERY subject is held
#      to one spelling, and the subjects are the `SUBJECTS` list below. Before
#      #341 the three that existed disagreed — `queue-snapshot.sh`'s header and
#      `config-contract.md` unfolded, `github-issues/SKILL.md` folded — which is
#      how a two-sided rule rots into a one-sided one with nothing failing.
#
#   2. THE DISCRIMINATION HALF IS LOAD-BEARING. A filter that holds everything
#      satisfies "site-mismatched work is held" and is useless. So `sites == []`
#      proceeding exactly as today, and a `sites` CONTAINING this checkout's
#      site proceeding however many members it carries, are pinned as their own
#      rows in BOTH consumers. Membership narrows; it never widens. take-it's
#      membership bullet is the one a reader adds LAST and the one whose absence
#      is quietest: with only the empty-case bullet beside it, "several labels
#      are a conflict, so refuse" reads as the obvious completion and
#      contradicts the folded membership match stated two paragraphs above it.
#
#   3. AN UNNAMED CHECKOUT IS FAIL-OPEN, AND IT IS A DIFFERENT QUESTION FROM AN
#      UNLABELLED ISSUE. With no `execution_site` configured the filter does not
#      run at all — an absent key means the repo has not adopted sites, and
#      holding every site-labelled issue in a repo that never opted in breaks
#      drains that work today. The two directions fail opposite ways on purpose
#      (an unnamed checkout ignores every declaration; a declaration-free issue
#      is taken by every checkout), so each gets its own row. Collapsing them
#      into one "absent means unconstrained" sentence is the tidy to refuse:
#      whichever half is dropped goes dark, and neither is evidence for the
#      other.
#
#   4. A SITE HOLD IS NOT A FAILURE. It costs NO redispatch budget, triggers NO
#      demotion, and writes no `attempt 1 failed` comment. Spending the budget
#      on it is exactly how the issue arrives at `blocked` under a comment
#      naming the wrong cause — the bug this filter exists to prevent, wearing
#      the filter's own face. take-it's mirror of that is ORDER: the refusal is
#      raised before §4 runs, so no assignee and no `in-progress` label is ever
#      written for work this checkout cannot do. Order is not assertable from
#      prose alone, so it is checked as a line-number comparison against the
#      claim step's own heading.
#
#   5. ONE RESOLVER, AND EVERY CONSUMER RUNS IT. `queue-snapshot.sh`'s buckets
#      are LABEL-SCOPED, so two legitimate callers hold labels the buckets never
#      saw: dispatch-ready's `board:` path, whose `board-snapshot.sh` emits
#      `labels` and no `sites` at all, and take-it on an issue nobody promoted to
#      Ready. Left with a ban on re-deriving and no emitter to call, each writes
#      its own resolver or skips the filter — and skipping it is a SILENT
#      FAIL-OPEN in a repo that explicitly opted in, which is #322's bug under
#      prose that reads as protected. `--sites-of` is the answer, and it is the
#      `taxonomy`-emitter shape CLAUDE.md already requires of a consumer applied
#      to a resolver: rows here run it rather than describing it, because the
#      paraphrase that preceded it dropped `.strip()` and answered `" vdi"` for
#      a label the header calls legal.
#
# WHAT THIS GATE DELIBERATELY DOES NOT DO. It does not re-check #340's
# resolution rules (prefix, colon, folding, empty value, conflict) — those are
# `scripts/test-queue-snapshot-site.sh`'s, measured against the emitter with a
# mock `gh`. Duplicating them here would be the third-copy shape this repo
# refuses; the two behavioural rows below check that `--sites-of` REACHES that
# resolver and reaches nothing else, never what the resolver decides. It also
# asserts nothing about §7's terminal states beyond the pointer §4 owes an
# operator: a drain whose only remaining Ready items are site holds now ends at
# DRAIN DEFERRED rather than STALLED (#342), and
# `scripts/test-drain-terminal-states.sh` owns that state, its discrimination
# from STALLED and its stop path. R30 reads §4's POINTER at it and nothing more,
# so the two gates meet at that one sentence and neither transcribes the other's
# subject. IT RUNS TO THAT SENTENCE'S OWN TERMINATOR — the `(#342)` citation
# closing it — because a needle stopping at `cannot` is satisfied by a qualifier
# inserted between the clause and the citation, phrase intact, which is what
# M30q writes. The first edition stopped at `cannot` and its M30q got there by
# REPLACING text inside the needle, making it a deletion mutant wearing a
# qualification's label: `flips: R30` was true and proved the wrong thing.
#
# NEEDLES ARE PINNED THROUGH THEIR TERMINATOR, NOT AS BARE SUBSTRINGS. A
# must-exist row matching `costs no redispatch budget` is satisfied by
# `costs no redispatch budget ON THE FIRST HOLD AND ONE ATTEMPT ON EVERY LATER
# ONE` — measured, that inversion passed every row while decision 4 was gone.
# Deletion mutants cannot see it either, because the phrase they delete is still
# there. So the rows carrying a decision match the whole clause up to its
# terminator, and each has a QUALIFICATION mutant beside its deletion one.
#
# THE MUTANTS' REACH IS DERIVED, NEVER WRITTEN DOWN. This is the lesson
# test-queue-snapshot-site.sh paid for three review rounds running: a
# hand-written roster claiming which mutant reddens which row is a claim
# nothing re-computes, and three of its rows went vacuous under one. So the
# gate RUNS ITSELF against each mutated tree, diffs the failing-row set against
# a baseline that must be empty, and checks two things against that derived
# flip set — that the row a mutant names is a MEMBER of it, and that the rows
# NO mutant flips are exactly the declared `UNPINNED_ROWS`. A row nothing can
# redden proves nothing, and this makes that state impossible to add quietly.
#
# A VETO NEEDS A MUTANT THAT ONLY IT CAN CATCH. The two whole-subject vetoes
# were reachable at first only as COLLATERAL of mutants that wrote the offending
# text inside a window some must-exist row already covered — so narrowing either
# veto's haystack back to one window left the gate green with an empty unpinned
# set. Each now has a mutant writing the text OUTSIDE every window a `row_has`
# reads, which is the only edit that distinguishes a whole-subject veto from a
# windowed one.
#
# HOW THE SELF-RUN IS BOUND, because a child that measured the wrong tree would
# report an empty flip set for every mutant and the roster would fail loudly
# rather than pass — but only if the child ran at all. `SITE_FILTER_SRC` moves
# every subject path and nothing else; the child is run FIRST against the
# tracked tree and must exit 0 having emitted every declared row, which is what
# proves the harness before any verdict is read from it. `SITE_FILTER_CHILD`
# suppresses the mutation section so the recursion is exactly one level deep.
# Mutating COPIES rather than the tracked files is deliberate here and is not
# the #262 trap: the trap is a harness that mutates a copy while the assertions
# read the tracked file, and here the child reads the copies by construction.
# Nothing under the tracked tree is written at any point.
#
# THE WINDOW GUARD IS A SEPARATE READ FROM THE WINDOW. `raw_region` stops
# BEFORE printing its stop line, so grepping the window for that stop line can
# never fail — the first edition did exactly that and called it an overrun
# guard. Reproduced: renaming `## 5. Dispatch` grew §4 to EOF and the run still
# exited 0 with every row green. The stop is now proved present in the FILE
# after the start line, and a guard mutant renames one and requires the child to
# abort loudly rather than to flip a row.
#
# Source-level plus two behavioural rows against `--sites-of`; seven tracked
# files (the `SUBJECTS` list), copies only, no `gh` and no network.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-site-filter.sh
set -uo pipefail
export LC_ALL=C

# Resolved BEFORE the `cd`, because `$0` is caller-relative and the mutation
# section re-invokes this file by absolute path.
SELF_ABS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-site-filter: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1
command -v python3 >/dev/null 2>&1 || { echo "test-site-filter: python3 is required" >&2; exit 1; }

# The subject tree. Only the mutation section ever sets this, and it sets it to
# a directory holding copies of the subjects below.
SRC="${SITE_FILTER_SRC:-$REPO_ROOT}"
CHILD="${SITE_FILTER_CHILD:-0}"

REL_DISPATCH="skills/dispatch-ready/SKILL.md"
REL_TAKE="skills/take-it/SKILL.md"
REL_SNAP="skills/github-issues/scripts/queue-snapshot.sh"
REL_GHISSUES="skills/github-issues/SKILL.md"
REL_CONTRACT="skills/setup-config/references/config-contract.md"
# CLAUDE.md and preflight.sh carry the match form in their gate descriptions, so
# they are subjects of the VETO rows even though no must-exist row reads them: a
# whole-text veto costs nothing to widen, and "every subject spells one form" is
# only true if the places that describe the rule are subjects too.
REL_CLAUDEMD="CLAUDE.md"
REL_PREFLIGHT="scripts/preflight.sh"
SUBJECTS="$REL_DISPATCH $REL_TAKE $REL_SNAP $REL_GHISSUES $REL_CONTRACT $REL_CLAUDEMD $REL_PREFLIGHT"

D="$SRC/$REL_DISPATCH"
T="$SRC/$REL_TAKE"
Q="$SRC/$REL_SNAP"
G="$SRC/$REL_GHISSUES"
C="$SRC/$REL_CONTRACT"

for rel in $SUBJECTS; do
    [ -r "$SRC/$rel" ] || { echo "test-site-filter: missing subject $SRC/$rel" >&2; exit 1; }
done

# --- rows ---------------------------------------------------------------------
# Every row this gate can emit, enumerated beside the checks that emit them.
# The consumption check at the bottom compares this list to what actually ran,
# so deleting an assertion fails even if its row id goes with it, and the
# mutation matrix derives its "no mutant reaches this" set from the same list.
ROW_IDS="R01 R02 R03 R04 R05 R06 R07 R08 R09 R10 \
R11 R12 R13 R14 R15 R16 R17 R18 R19 R20 \
R21 R22 R23 R24 R25 R26 R27 R28 R29 R30 \
R31 R32 R33 R34 R35 R36"

fail=0
asserts=0
seen=""
row() { # <id> <0 ok | 1 bad> <label>
    seen="$seen $1"
    asserts=$((asserts + 1))
    if [ "$2" = "0" ]; then
        echo "  ok    $1 $3"
    else
        fail=1
        echo "  FAIL  $1 $3"
    fi
}
row_has() { # <id> <haystack> <needle> <label>
    if grep -qF -- "$3" <<<"$2"; then row "$1" 0 "$4"; else row "$1" 1 "$4"; fi
}
row_absent() { # <id> <haystack> <needle> <label>
    if grep -qF -- "$3" <<<"$2"; then row "$1" 1 "$4"; else row "$1" 0 "$4"; fi
}
note() { [ "$CHILD" = "1" ] || echo "$1" >&2; }

# --- scratch ------------------------------------------------------------------
# FAIL CLOSED, STRUCTURALLY. There is no `set -e` here, so an empty $WORK would
# carry on into `mkdir -p "$WORK/bin"` — that is `mkdir -p /bin`, `cat > /bin/gh`
# on a root host (devcontainer, `act`, a root self-hosted runner), leaving a fake
# `gh` on PATH permanently while `rm -rf ""` cleans nothing. Same guard, same
# reason, as test-queue-snapshot-site.sh.
WORK="$(mktemp -d)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ] || [ "$WORK" = "/" ]; then
    echo "mktemp -d did not produce a usable scratch directory (got '${WORK:-}'); refusing to run" >&2
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT

# --- text helpers -------------------------------------------------------------
# raw_region <file> <start-prefix> <stop-prefix> — the lines from the first line
# STARTING WITH <start-prefix> up to (not including) the next line starting with
# <stop-prefix>. index()==1 rather than a regex: several anchors here open with
# `**` or `|`, which an ERE reads as a quantifier or an alternation.
raw_region() {
    awk -v s="$2" -v stop="$3" '
        !f && index($0, s) == 1 { f = 1; print; next }
        f && index($0, stop) == 1 { exit }
        f { print }' "$1"
}
# stop_present <file> <start-prefix> <stop-prefix> — is the stop line actually
# THERE, after the start line? This is the overrun guard, and it has to be its
# own read of the FILE: `raw_region` exits before printing the stop, so the stop
# is by construction absent from the window and grepping the window for it can
# never fail. Measured — renaming `## 5. Dispatch` grew §4 to EOF with every row
# still green and no complaint.
stop_present() {
    awk -v s="$2" -v stop="$3" '
        !f && index($0, s) == 1 { f = 1; next }
        f && index($0, stop) == 1 { found = 1; exit }
        END { exit(found ? 0 : 1) }' "$1"
}
# plain <text> — one line, blockquote markers, `*` emphasis and code ticks
# removed. BOTH normalisations are load-bearing and both have already produced
# false passes in this repo: prose here hard-wraps, so a needle spanning a wrap
# is absent to a line-scoped grep, and `**not** the same question` is the same
# instruction as `not the same question` while defeating a plain match.
# UNDERSCORE IS NOT STRIPPED, unlike the sibling gates', and that is not an
# oversight: every needle in this file spells `execution_site` or
# `not sites or execution_site.lower() in sites`, and stripping `_` folds those
# to `executionsite` — measured, it reddened seven rows against a correct tree.
# Underscore emphasis appears in no subject; `*` is what this repo bolds with,
# and that arm is the one the veto rows need.
plain() {
    sed -E 's/^[[:space:]]*(> ?)+//; s/^[[:space:]]+//' <<<"$1" \
        | tr '\n' ' ' | tr -s ' ' | tr -d '*`' | sed -E 's/^ +//; s/ +$//'
}
# hdr_plain <shell-file> — the LEADING comment block only, `#` stripped, then
# flattened. Scoped the way test-queue-snapshot-site.sh scopes its own header
# check: flattening the whole file would let a needle satisfied by a python
# comment further down pass a check named "the header states X".
hdr_plain() {
    awk '/^#/ { print; next } /^[[:space:]]*$/ { next } { exit }' "$1" \
        | sed -e 's/^[[:space:]]*#[[:space:]]\{0,1\}//' -e 's/^[[:space:]]*//' \
        | tr '\n' ' ' | tr -s ' ' | tr -d '*`' | sed -E 's/^ +//; s/ +$//'
}

# --- windows, proved non-empty AND proved to stop where they claim ------------
# A window that silently ran to EOF would make every check below measure the
# whole file, which is the shape that let an earlier gate in this repo pass
# while its subject was inverted two sections away.
window_ok=1
check_window() { # <name> <file> <start> <stop>
    local body
    body="$(raw_region "$2" "$3" "$4")"
    [ -n "$body" ] || { echo "test-site-filter: window $1 is EMPTY — '$3' not found in $2" >&2; window_ok=0; }
    stop_present "$2" "$3" "$4" || {
        echo "test-site-filter: window $1 has no stop line — '$4' does not follow '$3' in $2, so the window runs to EOF" >&2
        window_ok=0
    }
}
check_window sec4  "$D" '## 4. Select from Ready'    '## 5. Dispatch'
check_window sec2  "$D" '## 2. Reconcile in-flight'  '## 3. Compute capacity'
check_window sec3t "$T" '## 3. Pre-flight per issue' '## 4. Claim each issue'
if [ "$window_ok" != "1" ]; then
    echo "test-site-filter: a section window is unusable — every check below would measure the wrong text" >&2
    exit 1
fi

sec4_raw="$(raw_region "$D" '## 4. Select from Ready' '## 5. Dispatch')"
sec2_raw="$(raw_region "$D" '## 2. Reconcile in-flight' '## 3. Compute capacity')"
sec3t_raw="$(raw_region "$T" '## 3. Pre-flight per issue' '## 4. Claim each issue')"

sec4="$(plain "$sec4_raw")"
sec2="$(plain "$sec2_raw")"
sec3t="$(plain "$sec3t_raw")"
qhdr="$(hdr_plain "$Q")"
if grep -qF -- 'def parse_body' <<<"$qhdr"; then
    echo "test-site-filter: the queue-snapshot header flatten reached past the comment block" >&2
    exit 1
fi
contract="$(plain "$(cat "$C")")"
ghissues="$(plain "$(cat "$G")")"
# The two VETO rows span each subject WHOLE, never the windows the must-exist
# rows use. A window is the right scope for "§4 says X" and the wrong one for
# "no copy says Y": the unfolded spelling written into §7, or into
# queue-snapshot's python region rather than its header, is the same defect
# somewhere the windows cannot see.
# ONE flatten over all seven, not one `plain` per subject: `plain` is a 5-process
# pipeline and this loop ran it per subject per CHILD, which the mutation matrix
# then multiplies by every mutant. `@@SUBJECT-BOUNDARY@@` keeps the one guarantee
# the loop gave for free — no veto needle may match across the junction between
# two subjects — and it survives the flatten untouched, carrying neither `*` nor
# a backtick (issue #351).
all_copies="$(
    for rel in $SUBJECTS; do
        printf '\n@@SUBJECT-BOUNDARY@@\n'
        cat "$SRC/$rel"
    done | sed -E 's/^[[:space:]]*(> ?)+//; s/^[[:space:]]+//' \
         | tr '\n' ' ' | tr -s ' ' | tr -d '*`' | sed -E 's/^ +//; s/ +$//'
)"

note "site filter consumers (issue #341) — subjects under $SRC"

# --- 1. dispatch-ready §4's Site filter ---------------------------------------
note "1. dispatch-ready §4"

# The row is line-anchored and carries the form itself: a table row indented by
# ONE space renders identically and passes markdownlint, which is why the anchor
# allows leading whitespace rather than pinning column 1.
if grep -qE '^[[:space:]]*\| Site \|.*execution_site\.lower\(\) in sites' <<<"$sec4_raw"; then
    row R01 0 "§4's filter table carries a Site row, spelling the folded match"
else
    row R01 1 "§4's filter table has no Site row spelling the folded match"
fi
row_has R02 "$sec4" \
    'The match is not sites or execution_site.lower() in sites, and it folds case on BOTH sides.' \
    "§4 states the array match, folded on both sides"
# Pinned through the clause's end, not as the bare phrase: "dispatch, exactly as
# today WHEN THE REPO HAS OPTED OUT" satisfies a substring check while deleting
# the discrimination half. THROUGH THE SENTENCE TERMINATOR, not to a convenient
# mid-sentence word: this needle used to stop at "stopped queue", so a qualifier
# APPENDED after that point left the row green while M03q proved only the
# inside-clause insertion (issue #351). Same correction on R07 below.
row_has R03 "$sec4" \
    'sites empty → dispatch, exactly as today. Most issues carry no site: label at all, and a filter that also holds them is not a filter, it is a stopped queue — it satisfies "site-mismatched work is held" while being useless, which is the half a check for the hold alone cannot see.' \
    "§4 keeps the discrimination half: an unlabelled issue dispatches as today"
row_has R04 "$sec4" \
    "sites containing this checkout's site → dispatch, however many members it carries." \
    "§4 dispatches on membership, however many members sites carries"
row_has R05 "$sec4" \
    'No execution_site configured → the filter DOES NOT RUN and everything dispatches.' \
    "§4 is fail-open in an unnamed checkout"
row_has R06 "$sec4" \
    'It is not the same question as an issue with no label, and the two fail in opposite directions on purpose' \
    "§4 keeps the two fail-open directions apart"
# The whole clause, through its terminator. A qualifier inserted anywhere inside
# it — "no redispatch budget ON THE FIRST HOLD" — breaks the match, which a
# substring check on either half cannot do.
row_has R07 "$sec4" \
    "It costs no redispatch budget, triggers no demotion, and writes no dispatch-ready: attempt 1 failed comment: the issue is dispatchable, just not from here, and the machine that can take it is not this tick's to find." \
    "§4's site hold spends no budget and never demotes, unqualified"
row_has R08 "$sec4" 'A site hold is not a failure.' \
    "§4 states outright that a site hold is not a failure"
row_has R09 "$sec4" \
    'Report it as #N (requires site <x>), listing all of sites when there is more than one' \
    "§4 reports the hold naming every site the issue declares"
if grep -qF -- 'Read sites off the §2 snapshot on the boardless path.' <<<"$sec4" &&
   grep -qF -- 'Never re-parse the issue body for a site' <<<"$sec4"; then
    row R10 0 "§4 reads sites off the snapshot and never re-parses the body"
else
    row R10 1 "§4 no longer sources sites from the snapshot, or has dropped the body-parse ban"
fi
# THE BOARD PATH. `board-snapshot.sh` emits labels and no `sites`, so a filter
# told only to read the snapshot has no input at all on a board repo — a silent
# fail-open in a repo that opted in, under prose that reads as protected.
if grep -qF -- 'On the board: path, run the resolver — the board snapshot has no sites.' <<<"$sec4" &&
   grep -qF -- 'queue-snapshot.sh --sites-of' <<<"$sec4"; then
    row R24 0 "§4 gives the board path an input: it runs the --sites-of emitter"
else
    row R24 1 "§4's board path has no site input — board repos fail open silently"
fi
row_has R25 "$sec4" 'This filter runs on both paths' \
    "§4 says the filter runs on BOTH paths, not just the one it was written for"
row_has R30 "$sec4" \
    'ends the loop at DRAIN DEFERRED, naming the site rather than telling the operator to resolve a gate this checkout cannot (#342).' \
    "§4 tells the operator where a site hold ends, and §7 now ends it at DRAIN DEFERRED"

# --- 2. take-it refuses BEFORE the claim --------------------------------------
note "2. take-it"

# ORDER, as line numbers. Prose cannot assert it: "refuse before claiming" reads
# identically wherever the paragraph sits, and the whole value of the rule is
# that §4 has not run yet.
t_site_line="$(grep -n '^### Site — refuse BEFORE the claim' "$T" | head -1 | cut -d: -f1)"
t_claim_line="$(grep -n '^## 4\. Claim each issue' "$T" | head -1 | cut -d: -f1)"
if [ -n "$t_site_line" ] && [ -n "$t_claim_line" ] && [ "$t_site_line" -lt "$t_claim_line" ]; then
    row R11 0 "take-it's site refusal is raised before the claim step (line $t_site_line < $t_claim_line)"
else
    row R11 1 "take-it's site refusal does not precede the claim step (site='${t_site_line:-none}' claim='${t_claim_line:-none}')"
fi
row_has R12 "$sec3t" \
    'announce #N requires site <x>, listing all of sites when the issue carries more than one — and go no further with it.' \
    "take-it names the refusal line, every declared site, and stops there"
row_has R13 "$sec3t" \
    'a claim writes an assignee and an in-progress label, which takes the issue off the queue every OTHER checkout reads while leaving it with the one machine that cannot do the work.' \
    "take-it states what the claim would write — the reason the refusal precedes it"
row_has R14 "$sec3t" \
    'The match is not sites or execution_site.lower() in sites, and it folds case on BOTH sides.' \
    "take-it states the array match, folded on both sides"
row_has R15 "$sec3t" \
    'No execution_site configured → this step DOES NOT RUN and every named issue proceeds.' \
    "take-it is fail-open in an unnamed checkout"
row_has R16 "$sec3t" \
    'sites empty → proceed exactly as today. No site: label is the ordinary case, and a step that holds those issues too is not a filter, it is a stopped queue.' \
    "take-it keeps the discrimination half: an unlabelled issue proceeds as today"
row_has R29 "$sec3t" \
    "sites containing this checkout's site → proceed, however many members it carries." \
    "take-it proceeds on membership too — the half whose absence reads as 'refuse a conflict'"
# The paraphrase this replaced dropped `.strip()`, so `site: VDI` resolved to
# " vdi" here and "vdi" in the script: two answers for one label.
if grep -qF -- 'never by paraphrasing the rules here' <<<"$sec3t" &&
   grep -qF -- 'queue-snapshot.sh --sites-of' <<<"$sec3t"; then
    row R28 0 "take-it runs the resolver rather than paraphrasing its rules"
else
    row R28 1 "take-it paraphrases the resolution rules instead of running the emitter"
fi

# --- 3. the emitter, run rather than described --------------------------------
note "3. --sites-of"

BIN="$WORK/bin"
mkdir -p "$BIN"
# A `gh` that cannot succeed and says so. `--sites-of` resolves labels the caller
# already holds, so reaching gh at all is the regression: it would make a
# board-path or take-it site read cost a network round trip per issue, and this
# file's header claims no network.
# IT LOGS TO A FILE, and the file is what R27 reads. stderr cannot carry this
# signal: `sites_of` below truncates `emit.err` on every call, and every `gh`
# call inside queue-snapshot.sh carries `2>/dev/null` anyway — so the mock's
# stderr never reached the assertion at all. R27 used to redden under M27 only
# because exit 10 emptied stdout, which is a different fact about a different
# failure. A durable append-only log is what makes "did not reach gh" the thing
# actually measured (issue #351).
cat >"$BIN/gh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "gh \$*" >>"$WORK/gh-calls.log"
echo "MOCK GH CALLED: \$*" >&2
exit 1
MOCK
chmod +x "$BIN/gh"
: >"$WORK/gh-calls.log"
if [ "$(PATH="$BIN:$PATH" command -v gh)" != "$BIN/gh" ]; then
    echo "test-site-filter: the mock gh shim did not install at $BIN/gh — refusing to run the emitter rows, because a real gh would answer them" >&2
    exit 1
fi
sites_of() { # <json-array-of-labels> — stdout of the emitter under test
    printf '%s' "$1" | PATH="$BIN:$PATH" bash "$Q" --sites-of 2>"$WORK/emit.err"
}
one="$(sites_of '["Site: VDI","ready","offsite:x","site:"]')"
two="$(sites_of '["site:mac","site:vdi"]')"
none="$(sites_of '["ready","bug"]')"
if [ "$one" = '["vdi"]' ] && [ "$two" = '["mac", "vdi"]' ] && [ "$none" = '[]' ]; then
    row R26 0 "--sites-of resolves labels through the same sites_of the buckets use"
else
    row R26 1 "--sites-of did not resolve through sites_of (got '$one' / '$two' / '$none')"
fi
if [ -n "$one" ] && [ ! -s "$WORK/gh-calls.log" ]; then
    row R27 0 "--sites-of answers without reaching gh — no repo, no network"
else
    row R27 1 "--sites-of reached gh, or produced nothing: calls=[$(tr '\n' ' ' <"$WORK/gh-calls.log")] err=[$(tr '\n' ' ' <"$WORK/emit.err")]"
fi

# THE INPUT CONTRACT, which belongs to #341's emitter and not to #340's
# resolution rules — every row above feeds a VALID array, so nothing here saw
# the refusal path until this row (issue #351). It matters for one reason:
# empty stdout is what a refusal AND an unlabelled issue both produce, so a
# caller reading output alone cannot tell them apart. That is precisely what the
# consumers' "UNKNOWN is a HOLD" rule (R33/R34) exists to stop, and this row is
# the half that proves the exit code it tells them to read is really there.
refuse_ok=1; refuse_saw=""
for bad in '' 'null' '[1]' '"vdi"' '{}'; do
    bad_out="$(printf '%s' "$bad" | PATH="$BIN:$PATH" bash "$Q" --sites-of 2>/dev/null)"
    bad_rc=$?
    refuse_saw="$refuse_saw [${bad}]=${bad_rc}/'${bad_out}'"
    [ "$bad_rc" = "64" ] && [ -z "$bad_out" ] || refuse_ok=0
done
if [ "$refuse_ok" = "1" ]; then
    row R31 0 "--sites-of refuses non-array stdin with exit 64 and empty stdout"
else
    row R31 1 "--sites-of did not refuse bad stdin as documented:$refuse_saw"
fi

# A CLOSED fd 0 is a THIRD state, and it used to HANG rather than refuse.
# `-t 0` is false for it, so a bare `$(cat)` inherited the read end of its own
# command-substitution pipe and blocked forever — reproduced, the probe had to
# be killed. This row is therefore watchdogged: a regression must REDDEN, never
# wedge the suite, so a child that has not exited within ~5s is killed and
# scored as the failure it is.
# The kill must reach the subject's WHOLE process tree, not just its PID (issue
# #535). Two earlier shapes leaked: `( cmd; echo $? >rc ) &` made `$!` the
# wrapper subshell, so the kill orphaned the resolver; and backgrounding the
# probe directly still left the `cat` of M35's `$(cat)` grandchild blocked on
# its own pipe. `set -m` makes the background job a process-group leader, and
# the HUNG path kills the group, grandchildren included. Status comes from
# `wait`.
set -m
PATH="$BIN:$PATH" bash "$Q" --sites-of <&- >"$WORK/closed.out" 2>/dev/null &
closed_pid=$!
set +m
closed_rc="HUNG"
# Polled FINELY, not in half-seconds: this loop runs in every child, and the
# mutation matrix multiplies it by every mutant, a 0.5s first sleep cost the
# suite ~20s of pure waiting. 100 x 0.05s keeps the same ~5s ceiling.
closed_wait=0
while [ "$closed_wait" -lt 100 ]; do
    kill -0 "$closed_pid" 2>/dev/null || { wait "$closed_pid" 2>/dev/null; closed_rc=$?; break; }
    sleep 0.05
    closed_wait=$((closed_wait + 1))
done
if [ "$closed_rc" = "HUNG" ]; then
    kill -9 -- "-$closed_pid" 2>/dev/null
    wait "$closed_pid" 2>/dev/null
fi
if [ "$closed_rc" = "64" ] && [ ! -s "$WORK/closed.out" ]; then
    row R32 0 "--sites-of refuses a CLOSED fd 0 with exit 64 instead of hanging"
else
    row R32 1 "--sites-of mishandled a closed fd 0 (rc=$closed_rc, stdout=$(tr '\n' ' ' <"$WORK/closed.out" 2>/dev/null))"
fi

# THE CONSUMERS' HALF. The emitter refusing is worth nothing if the two callers
# read stdout and not the exit code: empty stdout is byte-for-byte what an
# unlabelled issue produces, so a failed resolve would dispatch/claim exactly
# the work the filter exists to hold — #322's originating bug reached through a
# failure rather than a parse. Both files carry the rule; neither may lose it.
row_has R33 "$sec4" 'Read the exit status, not the output.' \
    "dispatch-ready reads the resolver's exit status rather than its stdout"
row_has R34 "$sec3t" 'Read the exit status, not the output.' \
    "take-it reads the resolver's exit status rather than its stdout"
row_has R35 "$sec4" 'On anything but 0 the filter did not run for that issue: hold it' \
    "and an unresolved read is a HOLD, never a dispatch"

# --- 4. the match form, across every subject ----------------------------------
note "4. the match form"

row_has R17 "$qhdr" 'THE READER FOLDS THE CONFIG SIDE' \
    "queue-snapshot's header says the fold on the config side is the reader's"
row_has R18 "$qhdr" \
    'The obvious reading of the list, not sites or execution_site.lower() in sites, cannot' \
    "queue-snapshot's header writes the folded form"
row_has R19 "$contract" 'so write it not sites or execution_site.lower() in sites' \
    "the config contract writes the folded form"
row_has R20 "$ghissues" 'Match it as not sites or execution_site.lower() in sites' \
    "github-issues' SKILL.md writes the folded form"
# The veto that made #341 necessary: the same rule spelled two ways, and the
# unfolded spelling is the one that holds a VDI loop's own work.
row_absent R21 "$all_copies" 'not sites or execution_site in sites' \
    "no subject writes the unfolded form, anywhere in its text"
# Falsified by the membership match this ships: `sites` of [mac, vdi] matches
# BOTH a mac and a vdi checkout. The declaration is a conflict the snapshot does
# not resolve, not one nothing can satisfy.
row_absent R22 "$all_copies" 'matches no checkout' \
    "no subject claims a conflicting declaration matches no checkout"

# --- 5. the doc claim this change falsified -----------------------------------
note "5. doc reconciliation"

if grep -qF -- 'all three body contracts — touches:, Depends on #N and stack: — already' <<<"$sec2" &&
   grep -qF -- 'resolved into a sites list' <<<"$sec2"; then
    row R23 0 "§2 names all three body contracts and the resolved sites list"
else
    row R23 1 "§2's snapshot sentence undercounts the body contracts, or drops sites"
fi

# blocked[] IS BARE NUMBERS, and the §2 sentence used to attach the contracts and
# the resolved sites to all three buckets alike (issue #351). It is not a
# cosmetic overclaim: a reader who believes `blocked[]` carries `sites` writes a
# site filter over a bucket that has no labels in it, and gets `[]` for every
# entry — the fail-open direction again, this time invented by the prose.
row_has R36 "$sec2" 'blocked[] is bare issue numbers' \
    "§2 keeps blocked[] apart from the two buckets that carry the contracts"

# --- consumption --------------------------------------------------------------
# Every declared row ran, and nothing ran that is not declared. This is the
# vacuity floor: deleting an assertion block fails here even when its row id is
# deleted with it, and the mutation matrix below derives its unpinned set from
# the same declaration.
declared_sorted="$(tr ' ' '\n' <<<"$ROW_IDS" | grep -v '^$' | sort)"
seen_sorted="$(tr ' ' '\n' <<<"$seen" | grep -v '^$' | sort)"
if [ "$declared_sorted" = "$seen_sorted" ]; then
    asserts=$((asserts + 1))
    echo "  ok    ROWS every declared row ran, and only declared rows ran ($(grep -c . <<<"$seen_sorted"))"
else
    fail=1
    asserts=$((asserts + 1))
    echo "  FAIL  ROWS the rows that ran differ from ROW_IDS — a row was added or deleted without its declaration"
    diff <(echo "$declared_sorted") <(echo "$seen_sorted") | sed 's/^/          | /' >&2
fi

if [ "$CHILD" = "1" ]; then
    exit "$fail"
fi

# --- 6. mutation proofs, and the matrix derived from them ---------------------
echo "6. mutation proofs" >&2

MDIR="$WORK/m"

run_self() { # <src-dir> <out-file>
    SITE_FILTER_SRC="$1" SITE_FILTER_CHILD=1 bash "$SELF_ABS" >"$2" 2>&1
}
fails_in() { # <out-file> — the failing row ids, one per line, sorted
    grep -oE '^  FAIL +R[0-9]+' "$1" | awk '{ print $2 }' | sort -u
}
# `+`, never a literal pair of spaces: `ok` and `FAIL` are padded to the same
# column, so a two-space pattern counts the FAILING rows only — measured, that
# made every mutant report "emitted 8 of 23 rows" and prove nothing while
# looking like a subject regression.
rows_in() { # <out-file> — how many rows the run emitted
    grep -cE '^  (ok|FAIL) +R[0-9]+' "$1"
}

DECLARED_ROWS="$(grep -c . <<<"$declared_sorted")"

# THE HARNESS PROVES ITSELF FIRST. A child that measured the wrong tree, or did
# not run at all, would report an empty flip set for every mutant below; that
# fails loudly rather than passing, but only once this run has shown the child
# works at all against the tracked tree.
BASE="$WORK/baseline.out"
run_self "$REPO_ROOT" "$BASE"
base_rc=$?
base_fails="$(fails_in "$BASE")"
if [ "$base_rc" = "0" ] && [ -z "$base_fails" ] && [ "$(rows_in "$BASE")" = "$DECLARED_ROWS" ]; then
    asserts=$((asserts + 1))
    echo "  ok    the self-run reproduces a clean baseline over all $DECLARED_ROWS rows"
else
    fail=1
    asserts=$((asserts + 1))
    echo "  FAIL  the self-run baseline is not clean (exit $base_rc, $(rows_in "$BASE") rows) — every flip set below would be measured against the wrong thing"
    sed 's/^/          | /' "$BASE" >&2
fi

reset_mutant() {
    rm -rf "$MDIR"
    local rel
    for rel in $SUBJECTS; do
        mkdir -p "$MDIR/$(dirname "$rel")"
        cp "$REPO_ROOT/$rel" "$MDIR/$rel"
    done
}
EDIT_OK=1
edit() { # <relpath> <from> <to> — exact, and it must match exactly once
    if ! python3 - "$MDIR/$1" "$2" "$3" <<'PY'
import io, sys
path, frm, to = sys.argv[1:4]
s = io.open(path, encoding="utf-8").read()
n = s.count(frm)
if n != 1:
    sys.stderr.write("occurrences=%d\n" % n)
    sys.exit(1)
io.open(path, "w", encoding="utf-8").write(s.replace(frm, to))
PY
    then
        EDIT_OK=0
    fi
}

mutants_run=0
MUTANT_LABELS="$WORK/mutants.txt"
: >"$MUTANT_LABELS"
FLIPPED="$WORK/flipped.txt"
: >"$FLIPPED"

start_mutant() { EDIT_OK=1; reset_mutant; }

staged_ok() { # <label> — the edits applied, and the tree really did change
    local label="$1" rel changed=0
    if [ "$EDIT_OK" != "1" ]; then
        fail=1; asserts=$((asserts + 1))
        echo "  FAIL  $label — a mutation target did not match exactly once (stale mutant)"
        return 1
    fi
    for rel in $SUBJECTS; do
        cmp -s "$REPO_ROOT/$rel" "$MDIR/$rel" || changed=1
    done
    if [ "$changed" = "0" ]; then
        fail=1; asserts=$((asserts + 1))
        echo "  FAIL  $label — the mutant tree is identical to the source"
        return 1
    fi
    return 0
}

mutate() { # <label> <named-row>; the caller has already staged the edits
    local label="$1" named="$2" out="$WORK/mut.out" flips
    printf '%s\n' "$label" >>"$MUTANT_LABELS"
    staged_ok "$label" || return
    run_self "$MDIR" "$out"
    if [ "$(rows_in "$out")" != "$DECLARED_ROWS" ]; then
        fail=1; asserts=$((asserts + 1))
        echo "  FAIL  $label — the mutant run emitted $(rows_in "$out") of $DECLARED_ROWS rows, so its verdict proves nothing"
        return
    fi
    mutants_run=$((mutants_run + 1))
    flips="$(fails_in "$out" | tr '\n' ' ')"
    printf '%s\n' "$flips" | tr ' ' '\n' | grep -v '^$' >>"$FLIPPED"
    asserts=$((asserts + 1))
    case " $flips " in
        *" $named "*) echo "  ok    $label reddens $named as declared (flips: ${flips% })" ;;
        *) fail=1
           echo "  FAIL  $label does NOT redden $named — it flips '${flips% }'. Either the roster names the wrong row or the decision has stopped being load-bearing" ;;
    esac
}

# A guard mutant breaks the gate's own PRECONDITIONS rather than a decision, so
# it is verified the other way round: the child must ABORT, emitting no rows and
# saying why. Counted separately from `mutate`, since a run that emits no rows is
# a failure there.
guards_run=0
guard_mutate() { # <label> <expected-stderr-needle>
    local label="$1" needle="$2" out="$WORK/guard.out" n
    staged_ok "$label" || return
    run_self "$MDIR" "$out"
    n="$(rows_in "$out")"
    asserts=$((asserts + 1))
    if [ "$n" = "0" ] && grep -qF -- "$needle" "$out"; then
        guards_run=$((guards_run + 1))
        echo "  ok    $label aborts the run loudly, emitting no verdict at all"
    else
        fail=1
        echo "  FAIL  $label did not abort: $n rows emitted, guard message '$needle' $(grep -qF -- "$needle" "$out" && echo present || echo absent)"
    fi
}

# --- dispatch-ready §4 --------------------------------------------------------
start_mutant
edit "$REL_DISPATCH" \
    '| Site | Skip if the issue' \
    '| Site-DELETED | Skip if the issue'
mutate "M01: §4 loses its Site filter row" R01

start_mutant
edit "$REL_DISPATCH" \
    '**The match is `not sites or execution_site.lower() in sites`, and it folds case on BOTH sides.**
`queue-snapshot.sh` folds' \
    '**The match is `not sites or execution_site in sites`.**
`queue-snapshot.sh` folds'
mutate "M02: §4 drops the config-side fold" R02

start_mutant
edit "$REL_DISPATCH" \
    '- **`sites` empty → dispatch, exactly as today.**' \
    '- **`sites` empty → hold, like any other undeclared fact.**'
mutate "M03: §4 holds unlabelled issues too — the filter that filters everything" R03

start_mutant
edit "$REL_DISPATCH" \
    '- **`sites` empty → dispatch, exactly as today.** Most issues' \
    '- **`sites` empty → dispatch, exactly as today** unless the repo has adopted sites, in which case hold. Most issues'
mutate "M03q: the discrimination half is QUALIFIED away rather than deleted" R03

start_mutant
edit "$REL_DISPATCH" \
    '- **`sites` containing this checkout'"'"'s site → dispatch, however many members it carries.**' \
    '- **`sites` with exactly one member, this checkout'"'"'s, dispatches.**'
mutate "M04: §4 stops dispatching on membership when sites has several members" R04

start_mutant
edit "$REL_DISPATCH" \
    '- **No `execution_site` configured → the filter DOES NOT RUN and everything dispatches.**' \
    '- **No `execution_site` configured → hold every site-labelled issue.**'
mutate "M05: §4 fails CLOSED in an unnamed checkout" R05

start_mutant
edit "$REL_DISPATCH" \
    'Fail-open, deliberately: an absent key means this repo has not adopted sites, and holding every
  site-labelled issue in a repo that never opted in breaks drains that work today. **It is not the
  same question as an issue with no label**, and the two fail in opposite directions on purpose —
  an unnamed checkout ignores every declaration, a declaration-free issue is taken by every
  checkout. Neither is evidence for the other.' \
    'Fail-open, deliberately: an absent key means this repo has not adopted sites.'
mutate "M06: §4 collapses the two fail-open directions into one" R06

start_mutant
edit "$REL_DISPATCH" \
    'It costs **no redispatch budget**, triggers **no demotion**, and' \
    'It triggers **no demotion**, and'
mutate "M07: a site hold starts spending the redispatch budget" R07

start_mutant
edit "$REL_DISPATCH" \
    'It costs **no redispatch budget**, triggers **no demotion**, and' \
    'It costs **no redispatch budget** on the first hold and one attempt on every later one, triggers **no demotion** until the third hold, and'
mutate "M07q: decision 4 is QUALIFIED away while every phrase survives" R07

start_mutant
edit "$REL_DISPATCH" \
    '**A site hold is not a failure.**' \
    '**A site hold is a failed attempt like any other.**'
mutate "M08: §4 stops calling a site hold something other than a failure" R08

start_mutant
edit "$REL_DISPATCH" \
    'Report it as
`#N (requires site <x>)`, listing **all** of `sites` when there is more than one, so the operator' \
    'Report it as
`#N (site mismatch)`, so the operator'
mutate "M09: §4 stops naming the site(s) in the hold" R09

start_mutant
edit "$REL_DISPATCH" \
    '**Read `sites` off the §2 snapshot on the boardless path.**' \
    '**Resolve `sites` yourself from the issue.**'
mutate "M10: §4 stops sourcing sites from the snapshot" R10

start_mutant
edit "$REL_DISPATCH" \
    '**On the `board:` path, run the resolver — the board snapshot has no `sites`.**' \
    '**On the `board:` path the same snapshot answers.**'
mutate "M24: the board path loses its site input — the silent fail-open" R24

start_mutant
edit "$REL_DISPATCH" \
    'One resolver, two callers, one answer. **This filter runs on both paths**' \
    'One resolver, two callers, one answer. **This filter runs on the boardless path**'
mutate "M25: the filter stops claiming both paths" R25

start_mutant
edit "$REL_DISPATCH" \
    'so a Ready column
holding nothing else ends the loop at DRAIN DEFERRED, naming the site rather than telling the
operator to resolve a gate this checkout cannot' \
    'so a Ready column
holding nothing else resolves on its own'
mutate "M30: §4 stops telling the operator where a site hold ends" R30

# THE QUALIFICATION MUTANT beside the deletion one, the shape this gate's header
# names: a needle that stops mid-sentence is satisfied by a clause that inverts
# the rule after it. This one INSERTS between the clause and its citation and
# deletes nothing — every word M30 removes is still here — so it reddens R30 only
# because R30 runs to the citation. Narrow R30 back to `cannot` and this mutant
# goes green, which is the measurement the first edition of this pair could not
# make.
start_mutant
edit "$REL_DISPATCH" \
    'operator to resolve a gate this checkout cannot
(#342).' \
    'operator to resolve a gate this checkout cannot — unless the drain has been running long
enough to call it a stall, in which case it says that instead
(#342).'
mutate "M30q: a qualifier is INSERTED before the terminator, every phrase intact" R30

# --- take-it ------------------------------------------------------------------
# The MOVE, in two edits. A deletion would redden every take-it row at once and
# prove nothing about ORDER, which is the only thing R11 asserts.
start_mutant
edit "$REL_TAKE" \
    '### Site — refuse BEFORE the claim, never after it

`execution_site` in config' \
    '`execution_site` in config'
edit "$REL_TAKE" \
    '## 4. Claim each issue

Best-effort, so parallel sessions don'"'"'t double-pick.' \
    '## 4. Claim each issue

### Site — refuse BEFORE the claim, never after it

Best-effort, so parallel sessions don'"'"'t double-pick.'
mutate "M11: take-it's refusal moves BELOW the claim step" R11

start_mutant
edit "$REL_TAKE" \
    'announce `#N requires site <x>`, listing all of `sites` when the issue carries more than
one' \
    'announce a site mismatch'
mutate "M12: take-it stops naming the site(s) it refuses on" R12

start_mutant
edit "$REL_TAKE" \
    'one — and go no further with it.' \
    'one — and dispatch it anyway if the batch is otherwise empty.'
mutate "M12q: the refusal is QUALIFIED into an advisory while its phrase survives" R12

start_mutant
edit "$REL_TAKE" \
    '§4 must not run for that issue: a claim writes an assignee and an
`in-progress` label, which takes' \
    '§4 must not run for that issue, which takes'
mutate "M13: take-it drops what the claim would write" R13

start_mutant
edit "$REL_TAKE" \
    'a claim writes an assignee and an
`in-progress` label, which takes the issue off the queue' \
    'a claim writes an assignee and, on repos that use it, an
`in-progress` label, which takes the issue off the queue'
mutate "M13q: the claim's cost is QUALIFIED while every phrase survives" R13

start_mutant
edit "$REL_TAKE" \
    '**The match is `not sites or execution_site.lower() in sites`, and it folds case on BOTH sides.**' \
    '**The match is `not sites or execution_site in sites`.**'
mutate "M14: take-it drops the config-side fold" R14

start_mutant
edit "$REL_TAKE" \
    '- **No `execution_site` configured → this step DOES NOT RUN and every named issue proceeds.**' \
    '- **No `execution_site` configured → refuse every site-labelled issue.**'
mutate "M15: take-it fails CLOSED in an unnamed checkout" R15

start_mutant
edit "$REL_TAKE" \
    '- **`sites` empty → proceed exactly as today.**' \
    '- **`sites` empty → refuse, like any other unresolved declaration.**'
mutate "M16: take-it refuses unlabelled issues too" R16

start_mutant
edit "$REL_TAKE" \
    '- **`sites` containing this checkout'"'"'s site → proceed, however many members it carries.**' \
    '- **Several `site:` labels are a conflict — refuse; a conflict is nobody'"'"'s to take.**'
mutate "M29: take-it refuses a multi-member declaration that NAMES this checkout" R29

start_mutant
edit "$REL_TAKE" \
    'never by paraphrasing the
rules here.**' \
    'and the rules are: prefix including the colon, folded, an empty
value declares nothing.**'
mutate "M28: take-it goes back to paraphrasing the resolution rules" R28

# --- the emitter --------------------------------------------------------------
start_mutant
edit "$REL_SNAP" \
    'if mode == "sites":' \
    'if mode == "sites-disabled":'
mutate "M26: --sites-of stops reaching sites_of" R26

start_mutant
edit "$REL_SNAP" \
    'if [[ "$MODE" == "queue" ]]; then
    command -v gh' \
    'if true; then
    command -v gh'
mutate "M27: --sites-of starts reaching gh — a network round trip per issue" R27

start_mutant
edit "$REL_SNAP" \
    '    { exec 3<&0; } 2>/dev/null || { echo "$SITES_USAGE" >&2; exit 64; }
    LABELS_JSON=$(cat <&3)' \
    '    LABELS_JSON=$(cat)'
mutate "M35: the closed-fd guard is dropped — the resolver hangs instead of refusing" R32

start_mutant
edit "$REL_SNAP" \
    'if [[ "$MODE" == "queue" ]]; then
    command -v gh' \
    'ME=$(gh api user --jq .login 2>/dev/null || true)
if [[ "$MODE" == "queue" ]]; then
    command -v gh'
mutate "M36: the user lookup is hoisted above the MODE branch — a gh round trip per --sites-of call" R27

start_mutant
edit "$REL_DISPATCH" \
    '**Read the exit status, not the output.** On anything but 0 the filter did
not run for that issue: hold it, report `#N (site unresolved — <stderr>)`, and dispatch nothing on
the strength of a check that did not happen.' \
    'An empty answer means no site was declared, so dispatch as usual.'
mutate "M37: dispatch-ready reads the resolver's stdout instead of its exit status" R33

start_mutant
edit "$REL_TAKE" \
    '**Read the exit status, not the output.** On anything but
0, announce `#N (site unresolved — <stderr>)` and go no further with that issue' \
    'An empty answer means no site was declared, so proceed. On a hard error, announce it'
mutate "M38: take-it reads the resolver's stdout instead of its exit status" R34

start_mutant
edit "$REL_DISPATCH" \
    'On anything but 0 the filter did
not run for that issue: hold it, report' \
    'On anything but 0 the filter did
not run for that issue: dispatch it anyway, reporting'
mutate "M39: an unresolved site read dispatches instead of holding" R35

# --- the copies ---------------------------------------------------------------
start_mutant
edit "$REL_SNAP" \
    '#   * THE READER FOLDS THE CONFIG SIDE.' \
    '#   * The consumer decides how to compare.'
mutate "M17: queue-snapshot's header stops naming the config-side fold as the reader's" R17

start_mutant
edit "$REL_SNAP" \
    '#     of the list, `not sites or execution_site.lower() in sites`, cannot' \
    '#     of the list, `not sites or execution_site.lower() in sites` (or the
#     unfolded `not sites or execution_site in sites`), cannot'
mutate "M18: queue-snapshot's header re-admits the unfolded form beside the folded one" R18

start_mutant
edit "$REL_CONTRACT" \
    'so write it
  `not sites or execution_site.lower() in sites`' \
    'so write it
  `not sites or execution_site in sites`'
mutate "M19: the config contract reverts to the unfolded form" R19

start_mutant
edit "$REL_GHISSUES" \
    'Match it as `not sites or execution_site.lower() in sites`' \
    'Match it as `not sites or execution_site in sites`'
mutate "M20: github-issues' SKILL.md reverts to the unfolded form" R20

# THE VETO'S OWN MUTANT. Every other route to R21 writes the unfolded form inside
# a window some must-exist row already covers, so narrowing R21's haystack to one
# window would leave the gate green. This writes it into the Guardrails list,
# which no `row_has` reads — the only edit that tells a whole-subject veto apart
# from a windowed one.
start_mutant
edit "$REL_DISPATCH" \
    '- **Ready only.** Everything else is groom-backlog'"'"'s job' \
    '- **Site match** is `not sites or execution_site in sites`.
- **Ready only.** Everything else is groom-backlog'"'"'s job'
mutate "M21: the unfolded form appears where no must-exist row looks" R21

start_mutant
edit "$REL_GHISSUES" \
    'Emits `sites` as a sorted list with no scalar, so several labels are a conflict only a checkout named among them may take rather than "any site".' \
    'Emits `sites` as a sorted list with no scalar, so several labels are a conflict that matches no checkout.'
mutate "M22: a conflict is called unsatisfiable again, outside every header window" R22

start_mutant
edit "$REL_DISPATCH" \
    'The first two carry all three body contracts — `touches:`, `Depends on #N` and
`stack:` — already' \
    'The first two carry the `touches:` and `Depends on #N` body contracts already'
mutate "M23: §2 undercounts the body contracts again" R23

start_mutant
edit "$REL_DISPATCH" \
    'list; **`blocked[]` is bare issue numbers**, which is all the Blocked filter needs.' \
    'list.'
mutate "M40: §2 flattens the three buckets again, implying blocked[] carries sites" R36

start_mutant
edit "$REL_DISPATCH" \
    'which is the half a check for the hold alone cannot see.' \
    'which is the half a check for the hold alone cannot see — except in a repo that has adopted sites, where holding them is correct.'
mutate "M41: the discrimination half is qualified AFTER the old needle's end" R03

start_mutant
edit "$REL_DISPATCH" \
    "and the machine that can take it is not this tick's to find." \
    "and the machine that can take it is not this tick's to find — after the third such hold, demote it."
mutate "M42: decision 4 is qualified AFTER the old needle's end" R07

# --- the guard mutants --------------------------------------------------------
# These break a PRECONDITION, so the child must refuse to produce a verdict at
# all rather than flip a row. The first is the one that shipped broken: the
# original overrun guard grepped the window for a stop line `raw_region` had
# already excluded by construction, so renaming the stop grew §4 to EOF with
# every row green.
# The replacement must not START WITH the old heading: both `raw_region` and
# `stop_present` anchor with index()==1, so `## 5. Dispatch work` is still a
# match and the guard cannot fire on it — measured, both guards passed through
# with all 30 rows green.
start_mutant
edit "$REL_DISPATCH" '## 5. Dispatch' '## 5. Hand off to sub-agents'
guard_mutate "G1: §4's stop heading is renamed, so its window would run to EOF" \
    'window sec4 has no stop line'

start_mutant
edit "$REL_TAKE" '## 4. Claim each issue' '## 4. Take each issue'
guard_mutate "G2: take-it's §3 stop heading is renamed" \
    'window sec3t has no stop line'

# Every declared mutant ran. Derived from this file rather than transcribed, and
# WHITESPACE-TOLERANT: an indented or re-wrapped call used to fall out of a
# column-anchored count and report "only 22 of 21 declared mutants ran" — failing
# closed, with a message naming the wrong problem. The labels are collected as a
# list so the comparison is over members, not a number.
declared_mutants="$(grep -cE '^[[:space:]]*mutate[[:space:]]+"' "$SELF_ABS")"
declared_guards="$(grep -cE '^[[:space:]]*guard_mutate[[:space:]]+"' "$SELF_ABS")"
staged_mutants="$(grep -c . "$MUTANT_LABELS")"
asserts=$((asserts + 1))
if [ "$staged_mutants" -eq "$declared_mutants" ] && [ "$mutants_run" -eq "$declared_mutants" ]; then
    echo "  ok    every declared mutant ran ($mutants_run of $declared_mutants), plus $guards_run guard mutant(s)"
else
    fail=1
    echo "  FAIL  $mutants_run ran and $staged_mutants staged, against $declared_mutants declared — the rest proved nothing"
fi
asserts=$((asserts + 1))
if [ "$guards_run" -eq "$declared_guards" ]; then
    echo "  ok    every declared guard mutant aborted the run ($guards_run of $declared_guards)"
else
    fail=1
    echo "  FAIL  only $guards_run of $declared_guards guard mutants aborted — a precondition is not enforced"
fi

# --- the derived matrix: which rows NO mutant can redden ----------------------
# UNPINNED_ROWS is the only hand-written claim about reach left in this file, and
# the gate checks it. It is EMPTY, which is the goal state rather than a
# coincidence: every declared row is reachable by some mutant. Adding a row that
# nothing can redden fails HERE. Give it a mutant; if it genuinely cannot have
# one, declare it with a reason that is about REACH — not about which assertions
# happen to mention it.
UNPINNED_ROWS=""
flipped_set=" $(sort -u "$FLIPPED" | tr '\n' ' ') "
derived_unpinned=""
while read -r id; do
    [ -n "$id" ] || continue
    case "$flipped_set" in
        *" $id "*) ;;
        *) derived_unpinned="$derived_unpinned $id" ;;
    esac
done <<<"$declared_sorted"
derived_unpinned="${derived_unpinned# }"
asserts=$((asserts + 1))
if [ "$derived_unpinned" = "$UNPINNED_ROWS" ]; then
    echo "  ok    the rows no mutant reddens are exactly the declared set ('$UNPINNED_ROWS')"
else
    fail=1
    echo "  FAIL  rows no mutant reddens: '$derived_unpinned', declared: '$UNPINNED_ROWS' — a row nothing can redden proves nothing, so give it a mutant or declare it with a reason"
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "site filter tests: all green ($asserts assertions, $mutants_run mutants, $guards_run guards)" >&2
    exit 0
fi
echo "site filter tests: FAILURES above ($asserts assertions)" >&2
exit 1
