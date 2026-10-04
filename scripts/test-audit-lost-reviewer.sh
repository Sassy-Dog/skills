#!/usr/bin/env bash
# test-audit-lost-reviewer.sh — pins assess-it's audit-mode lost-reviewer
# backstop: the per-domain outcome ledger, the rule that a dark domain is never
# scored clean, the ledger's position BEFORE the approval prompt, and the fact
# that a dark domain is surfaced rather than turned into a veto.
#
# THE BUG. The nine `*-reviewer` agents serve TWO orchestrators, and only one of
# them scored a reviewer that came back with nothing. `agents/pr-review-
# orchestrator.md` Step 5 marks such a surface `!`, never a tick, and names it
# on every run. Audit mode had no equivalent, so a reviewer that returned
# nothing was indistinguishable from one that found nothing (issue #284).
#
# WHY AUDIT MODE IS THE WORSE PLACE FOR IT. A diff-scoped report is read
# in-session while the context is live, and a hole in it costs a re-run. Audit
# mode WRITES: its artefact is a filed Epic and its child issues, which becomes
# the durable record of what is wrong with the repo. A lost `security-reviewer`
# there yields a backlog that omits an entire domain and READS COMPLETE to
# everyone who finds it later. Nobody learns, because nothing about the artefact
# says a domain went dark.
#
# THE HARM LANDS AT THE PREVIEW, NOT AT THE REPORT, and that is what a later
# "just add the delivery rule to audit mode" sweep will get wrong. `assess-it`
# already never files silently — Phase 4 prints the full Epic + child-issue
# preview and files only on approval. The human was always the gate; they were
# simply not being told a domain went dark. So the requirement is POSITIONAL:
# the dark domains must be named IN the preview and BEFORE the approval prompt.
# A rule that lands after the ask does not prevent the bad outcome, and one that
# lands in Phase 5 documents a backlog that has already been filed.
#
# AND IT IS NOT A VETO. Filing still proceeds on approval. A rule that blocked
# filing on a dark domain would be the opposite failure — an audit that cannot
# deliver the findings it does hold because one agent timed out — and #284 rules
# it out in as many words. Both halves are pinned, because either one alone is
# wrong.
#
# THIS IS THE SIBLING OF THE DIFF-SCOPED RULE, NOT ITS SOURCE. #283 scoped the
# `!` consequence to diff-scoped mode DELIBERATELY and recorded the residue in
# `orchestration.md` rather than widening its own scope; this gate's subject is
# that residue being replaced by the real rule rather than left beside one.
# `agents/pr-review-orchestrator.md` is read for exactly ONE fact — that its own
# bullet survives — and nothing else about that file is pinned here.
# test-review-gate-decisions.sh owns it.
#
# HOW THIS GATE IS BOUND, AND WHY IT IS BOUND THE WAY test-drain-terminal-
# states.sh IS. That gate is the freshest precedent in this repo and it was
# defeated three times before it held: presence-only assertions lost to
# KEEP-THE-SENTENCE-AND-QUALIFY-IT; whole-paragraph equality lost to INSERTING A
# SIBLING PARAGRAPH beside a pinned one; a hand-picked SUBSET of paragraphs lost
# five review rounds running, each finding another unpinned paragraph that could
# invert a pinned one. THE SUBSET WAS THE DEFECT, NOT THE CHOICE OF SUBSET. So:
#
#   LAYER 1, CANON, AND IT COVERS BOTH FILES WHOLE. Every blank-line block of
#   each file is compared for equality after flattening — prose, list blocks and
#   table blocks alike, so a bullet body and a table cell are as pinned as a
#   paragraph — plus every FENCED block, with `#N` normalised so renumbering a
#   worked example cannot redden the gate. The fences are not inert here either:
#   Phase 4's ```text fence IS the coverage block the run prints, and a
#   parenthetical added inside it ("omit this block when every domain returned")
#   would restore #284 in full while every prose assertion stayed green. This
#   layer covered seven TARGETED windows for exactly one review round; see the
#   window registry below for the six measured green inversions that killed
#   that design.
#   LAYER 2, INVENTORY. The ordered lists of block openers, bullets, ordered-list
#   items, table rows and headings — for BOTH FILES WHOLE, not merely for the
#   pinned windows. Bounds INSERTION, DELETION and REORDERING, including the
#   four shapes that defeated the precedent's first inventory: a nested bullet,
#   an appended table row, a paragraph glued to a closing fence and a line glued
#   under a heading. Whole-file rather than per-section because these two files
#   are small and are entirely about this one flow: `## Core Principle`,
#   `## Workflow` and `## Reference Files` can each contradict Phase 4 from
#   outside it, which is the Guardrails hazard the precedent records. The
#   ORDERED-LIST inventory is the one that carries #284's own decision, Phase 4
#   being an ordered list whose ITEM ORDER is the fix.
#   LAYER 3, CONSUMPTION. Every canon key is consumed by exactly one assertion,
#   and every window's block and fence counts must equal its canon entry counts
#   — so deleting an assertion cannot pass by deleting its canon entry with it.
#
# THE COST IS STATED, in the precedent's idiom: this pins WORDING and STRUCTURE
# across two whole files, so a legitimate reword or a new bullet in either must
# be made in two places at once and reddens CI until it is. That is a loud false
# red, which this repo prefers to a gate reporting clean on an inverted source.
# `canon_table` is the one place to edit. "BYTE-IDENTICAL" WOULD OVERSTATE IT:
# the comparison runs after flattening, so it is identity up to whitespace — a
# re-wrap passes, a reword does not — and the inventories keep each opener's
# first words only.
#
# THERE IS DELIBERATELY NO PROSE VETO HERE, and that asymmetry with the sibling
# gates is what a later sweep will try to close. Two veto editions were built
# for test-review-gate-decisions.sh and BOTH reported clean on inverted sources:
# a polarity classifier that was inert by construction in the very windows it
# guarded, and a six-verb affirmative that reddened six correct edits while
# missing two natural rewords. A veto that works needs a forward segmentation
# pass, which is a different change. Canon plus inventory already answers the
# question a veto would ask — any rewrite changes a block, any addition changes
# an opener list — so a veto here would add risk and no coverage. The only
# must-not-exist checks are for the #283 residue note's own literals, which is a
# LITERAL DELETION being verified rather than a polarity judgement, and they run
# against flattened AND emphasis-stripped copies because this repo hard-wraps
# and `**Known gap**` is the same instruction as `Known gap`.
#
# THE PREMISE IS ASSERTED, NOT ASSUMED. The ledger says "every domain in the
# table above", so it is complete only if that table is the reviewers this
# plugin actually ships. If the map drifted from `agents/*-reviewer.md` the
# ledger would range over a stale set, and every prose assertion here would stay
# green while a whole domain had no row to be dark in. The map's rows are
# therefore compared to the shipped agent files as an EQUALITY, which is its own
# vacuity floor — a membership test cannot tell "nothing to report" from
# "nothing measured" — over a count floor beneath it. The map itself is NOT
# canon-pinned: it changes whenever a reviewer is added, the premise equality
# already reddens then, and pinning it twice would redden twice for one edit.
#
# THE VACUITY FLOOR IS A SECTION REGISTRY WITH PER-SECTION MINIMUMS, and it
# VALIDATES ITS OWN INPUTS BEFORE ANY ARITHMETIC TOUCHES THEM. A bare number was
# measured not binding three separate ways in the precedent. Worse, `set -u`
# inside `$(( ))` does not behave the same on bash 5 and on /bin/bash 3.2 — the
# shell CLAUDE.md tells developers to run preflight on — where a deleted digit
# aborts the summing loop and drops every later summand, and an unset floor
# exits 0 having run ZERO assertions, which a preflight-shaped wrapper reports
# as PASS. Every token is validated explicitly for that reason. The registry
# block's own minimum is held APART from the SECTIONS array, so deleting the
# block cannot also shrink the floor by exactly what the deletion removed.
#
# THE FLOOR EQUALS THE RUN, AND THAT IS THE STRICT SETTING RATHER THAN A
# COINCIDENCE TO LOOSEN. Headroom is the WEAK configuration: a floor beneath the
# count cannot tell "measuring everything" from "one assertion silently stopped
# running", which is the whole failure a floor exists to catch. At equality, one
# lost assertion drops the total below the floor AND drops its own section below
# its minimum, so it fails twice. The per-section minimums are hand-written
# constants, not derived from the files under test, so this is not the
# file-to-itself comparison the precedent rules out.
#   WHAT IT CATCHES UNIQUELY IS A RETIRED WINDOW, and that claim is narrower
# than the one this paragraph first made. Deleting a pinned PARAGRAPH together
# with its canon row does NOT need the floor: every block has an opener, so the
# inventory sees the deletion regardless — measured, three assertions fire, one
# of them `inventory orch_openers`. The floor is the sole layer for an edit that
# touches only THIS FILE: drop a window from `WINDOW_DEFS` and its canon rows
# with it, and the documents are untouched, so every surviving canon equality
# and every inventory passes and consumption is satisfied. Measured, that mutant
# produces ZERO failing assertions — the run is silent — and is caught only by
# the total falling short and by `windows` and `canon` missing their minimums.
# NO RESULTING TOTAL IS QUOTED HERE, deliberately: an earlier draft wrote "73",
# which was measured true only for the two smallest of the seven windows it then
# had and wrong for the window carrying #284's own fix. A number nobody can
# re-derive is exactly what the next editor trusts instead of re-measuring, and
# thirteen lines down this header already forbids transcribing one. A gate that
# stopped measuring a whole section is the vacuity here, and nothing above the
# floor can see it.
#   The stated cost is that a section which legitimately LOSES a block reddens
# until its minimum is updated too. Additions are free, since they only raise
# the count. Nudging a minimum downward to quiet a red is the one edit that
# retires this layer, and it should be read as such.
#
# NO `| grep -q` PIPELINE ANYWHERE: grep -q closes the pipe on its first match,
# the writer takes SIGPIPE, and pipefail promotes the 141 — turning a caught
# regression into a reported miss (the #172 shape, generalised by #256). Every
# string match here reads a herestring or a file directly.
#
# NO INVENTORY NUMBER IS TRANSCRIBED. The assertion count is PRINTED by the run;
# the section inventory is enumerated beside its own counts, which is the form
# CLAUDE.md sanctions for a count. The mutation battery lives in the PR that
# added this gate (issue #284).
#
# KNOWN LIMITS, stated rather than patched.
#   (1) `agents/pr-review-orchestrator.md` is read for ONE fact, and that read is
#       a DELIBERATE DOUBLE-PIN rather than an oversight. test-review-gate-
#       decisions.sh already holds that bullet, so softening it reddens two
#       gates with two different explanations — the very cost this limit exists
#       to name. It is kept because "the sibling survives untouched" is an
#       acceptance item of #284 in its own right, and a gate that assumes
#       another gate is still doing its job is how a two-orchestrator invariant
#       goes dark in the first place. Drop it only together with that argument.
#   (2) `references/github-issue-ops.md` and `assessment-rubric.md` ARE read,
#       and this limit is the record of why they were not at first. #284's
#       acceptance was preview-scoped and neither file was in its touch-set, so
#       its first edition pinned the PREVIEW half alone while both files still
#       disagreed with it — the Epic template had no coverage slot and the 1-10
#       score table had no abstain value, so a dark `security` domain had no
#       compliant score. Issue #294 closed both and the `durable` section pins
#       them here. WHAT IS STILL UNREAD IS THE REST OF EITHER FILE: this gate
#       holds the coverage contract in them and nothing else, so an unrelated
#       rewrite of either is invisible from here.
#   (6) TWO COORDINATED EDITS RETIRE A WHOLE LAYER AT EXIT 0. Deleting an
#       assertion section AND its `SECTIONS` entry together shrinks the floor by
#       exactly what the deletion removed — measured on the `residue` section,
#       which came back `74 assertions (floor 74), all green`. `REGISTRY_MIN` is
#       held apart precisely so the registry block cannot do this to itself, but
#       nothing protects the other six. The precedent states this same limit;
#       this gate's first edition omitted it, which is why it is written from
#       the measurement rather than from the intent.
#   (7) THE AWK EXTRACTORS RUN UNDER BSD AWK LOCALLY AND `mawk` IN CI, and the
#       two are verified to agree ON THIS CONTENT: the canon here was generated
#       by BSD awk and CI's preflight recomputes every block, fence and
#       inventory with mawk, so a divergence is a canon mismatch and the run is
#       green (first measured on PR #295). What is NOT claimed is that they
#       agree in general — a future extractor using a non-POSIX construct would
#       fail on CI and nowhere else, which is why every construct here is POSIX
#       and why `-v` carries only literal index() anchors.
#   (3) The canon values are regenerated by hand when these sections legitimately
#       change, and a regeneration that is not read is a rubber stamp. That is
#       the cost of pinning sections whole, and it is why a failure names the
#       block key and the first characters of what it found.
#   (4) A gate cannot verify its own guard from inside that guard. The derived
#       floor is the backstop under the registry block; there is no layer
#       beneath the floor.
#   (5) Markdownlint stays load-bearing for a malformed table (MD055/MD056),
#       which this gate reads as content rather than as structure.
#
# Five tracked files read — `skills/assess-it/SKILL.md`, its
# `orchestration.md`, `references/github-issue-ops.md` and
# `assessment-rubric.md`, plus `agents/pr-review-orchestrator.md` for its single
# fact — and a listing of `agents/`. No gh, no network, no repo mutation.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-audit-lost-reviewer.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-audit-lost-reviewer: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SKILL="skills/assess-it/SKILL.md"
ORCH="skills/assess-it/orchestration.md"
PRORCH="agents/pr-review-orchestrator.md"
OPENER_WORDS=6
NEVER=$'\001NEVER-MATCHES'

fails=0
asserts=0
ok()  { asserts=$((asserts + 1)); echo "  ok    $1"; }
bad() { asserts=$((asserts + 1)); echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# --- the section registry ----------------------------------------------------
# `name:minimum`. Members enumerated beside their counts, which is the form
# CLAUDE.md sanctions; ASSERT_FLOOR is their SUM, derived below rather than
# transcribed. A section that never runs, or that runs fewer assertions than it
# declares, FAILS — which a bare numeric floor cannot do.
SECTIONS=(windows:7 canon:59 inventory:10 residue:5 sibling:2 premise:3 durable:13)
# Held OUTSIDE the array on purpose: while the registry block's own minimum was
# a summand, deleting the block AND its entry shrank the floor by exactly what
# the deletion removed, so two edits retired layer 3 at exit 0.
REGISTRY_MIN=2
# EVERY token is validated before arithmetic touches it. On /bin/bash 3.2,
# deleting one digit from a minimum aborts the `for` inside `$(( ))`,
# silently drops every later summand and still exits 0; deleting REGISTRY_MIN is
# worse — exit 0 with ZERO assertions run. This is the last layer, so it
# validates rather than assumes.
SECTION_MIN_TOTAL=0
for _s in "${SECTIONS[@]}"; do
    case "$_s" in
        *:*) ;;
        *) echo "test-audit-lost-reviewer: SECTIONS member '$_s' has no ':' minimum" >&2; exit 1 ;;
    esac
    _min="${_s##*:}"
    case "$_min" in
        ''|*[!0-9]*) echo "test-audit-lost-reviewer: SECTIONS member '$_s' has a non-numeric minimum" >&2; exit 1 ;;
    esac
    SECTION_MIN_TOTAL=$((SECTION_MIN_TOTAL + _min))
done
case "${REGISTRY_MIN:-}" in
    ''|*[!0-9]*) echo "test-audit-lost-reviewer: REGISTRY_MIN must be a number" >&2; exit 1 ;;
esac
ASSERT_FLOOR=$((SECTION_MIN_TOTAL + REGISTRY_MIN))

ran_names=()
ran_counts=()
cur_sec=""
sec_start=0
consumed=""

_close_section() {
    if [ -n "$cur_sec" ]; then
        ran_names+=("$cur_sec")
        ran_counts+=("$((asserts - sec_start))")
    fi
}
section() {
    _close_section
    # `registry` is legal without being a SECTIONS member: its minimum is held
    # in REGISTRY_MIN so that deleting the block cannot also shrink the floor.
    case " ${SECTIONS[*]} " in
        *" $1:"*) ;;
        *) [ "$1" = "registry" ] || bad "section '$1' is not in the declared SECTIONS inventory" ;;
    esac
    cur_sec="$1"
    sec_start=$asserts
    echo "-- $1: $2"
}
note_consumed() { consumed="$consumed $1 "; }

# --- assertion helpers -------------------------------------------------------
# assert_has <haystack> <FIXED string> <label> — for a literal carrying regex
# metacharacters.
assert_has() {
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3"; fi
}
# assert_absent <haystack> <ERE> <label> — MUST-NOT-EXIST, tested against the
# text AND an emphasis-stripped copy, and FAILING CLOSED on a malformed pattern:
# grep exits 2 on an invalid ERE and an `if grep … || grep …` reads that as
# "not found", which is a veto failing open — the one direction a veto must
# never fail.
assert_absent() {
    local rc_plain rc_stripped
    grep -qE -- "$2" <<<"$1"; rc_plain=$?
    grep -qE -- "$2" <<<"$(emph_strip "$1")"; rc_stripped=$?
    if [ "$rc_plain" -ge 2 ] || [ "$rc_stripped" -ge 2 ]; then
        bad "$3 — the pattern is not a valid ERE, so this check measured nothing"
    elif [ "$rc_plain" -eq 0 ] || [ "$rc_stripped" -eq 0 ]; then
        bad "$3"
    else
        ok "$3"
    fi
}
# assert_eq <got> <want> <label> — on mismatch, quotes a WINDOW OF WHOLE WORDS
# around the first divergence rather than the head of each string. Two defects
# were measured here, in order.
#   Head truncation said nothing: a canon block is a whole paragraph, and for
# most of them the first 140 bytes of got and want are byte-identical, so the
# failure printed the same line twice.
#   Slicing at the divergence OFFSET then emitted invalid UTF-8. `LC_ALL=C` is
# set at the top of this file — deliberately, so awk counts bytes consistently —
# which also makes bash substring expansion byte-based, so `${s:$i:1}` can cut an
# em dash or an arrow in half. Measured: the mutation harness reading this
# output died with `UnicodeDecodeError: invalid continuation byte`, and CI logs
# would have shown mojibake. Words are whole characters by construction, so the
# window is cut on word boundaries and the byte offset is reported rather than
# used as a slice point.
_word_window() { # <text> <first word> <count>
    awk -v a="$2" -v n="$3" '{ for (i = a; i < a + n && i <= NF; i++)
                                   printf "%s%s", (i > a ? " " : ""), $i }' <<<"$1"
}
assert_eq() {
    if [ "$1" = "$2" ]; then
        ok "$3"
        return
    fi
    local i=0 n=${#1} m=${#2} lim w from
    lim=$n
    [ "$m" -lt "$lim" ] && lim=$m
    while [ "$i" -lt "$lim" ] && [ "${1:$i:1}" = "${2:$i:1}" ]; do i=$((i + 1)); done
    w="$(awk '{print NF}' <<<"${1:0:$i}")"
    case "$w" in ''|*[!0-9]*) w=0 ;; esac
    from=$((w - 5))
    [ "$from" -lt 1 ] && from=1
    bad "$3
        diverges near word $((w + 1)) (got $n bytes, want $m bytes)
        got : $(_word_window "$1" "$from" 16)
        want: $(_word_window "$2" "$from" 16)"
}
assert_nonempty() {
    if [ -n "$1" ]; then ok "$2"; else bad "$2 — empty"; fi
}

# --- extractors --------------------------------------------------------------
# raw_region <file> <start prefix> <stop prefix> — from the first line STARTING
# WITH start (inclusive) to the line before the next line starting with stop; an
# empty stop means "the next blank line". The start line is consumed with
# `next`, so a start that also matches its own stop cannot terminate itself on
# line one.
#
# LITERAL PREFIXES, NEVER REGEXES: awk expands backslash escapes inside a `-v`
# assignment, so a pattern arrives mangled and can silently match something
# else. The anchors are index() comparisons for that reason.
raw_region() {
    awk -v s="$2" -v stop="$3" '
        !f && index($0, s) == 1 { f = 1; print; next }
        f && stop == "" && $0 == "" { exit }
        f && stop != "" && index($0, stop) == 1 { exit }
        f { print }' "$1"
}
# region_stop_line <file> <start prefix> <stop prefix> — the first line AFTER the
# region. A window that runs silently to EOF prints nothing here, which is how
# "stops where it claims to" is measured rather than assumed.
region_stop_line() {
    awk -v s="$2" -v stop="$3" '
        !f && index($0, s) == 1 { f = 1; next }
        f && stop == "" && $0 == "" { print "<blank>"; exit }
        f && stop != "" && index($0, stop) == 1 { print; exit }' "$1"
}
# flat <text> — join wrapped lines, strip blockquote markers, squeeze runs, trim.
# `[[:space:]]`, never `[ \t]`: BSD sed reads the latter as a literal-t class.
flat() {
    sed -E 's/^[[:space:]]*(> ?)+//' <<<"$1" | tr '\n' ' ' | tr -s ' ' \
        | sed -E 's/^ +//; s/ +$//'
}
# emph_strip <text> — Markdown emphasis and code ticks removed, so a veto cannot
# be walked past by bolding the forbidden phrase.
emph_strip() { tr -d '*_`' <<<"$1"; }

# openers <text> — the first OPENER_WORDS words of each blank-line-delimited
# block opener, joined by ` ~ `. Fenced blocks collapse to their fences. WORDS,
# not characters: awk under LC_ALL=C counts BYTES and an em dash is multi-byte.
# BOTH fence delimiters are emitted, because text appended to a CLOSING fence
# was invisible to the precedent's first inventory. A HEADING closes the block
# it opens, so the next line starts a new one — the identical root cause,
# measured there as a line glued under a heading escaping all four inventories.
openers() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                printf "%s%s", (c++ ? " ~ " : ""), s }
        BEGIN { prev = 1 }
        /^[ \t]*```/ { emit()
                       if (!fence) { fence = 1; prev = 0 } else { fence = 0; prev = 1 }
                       next }
        fence { next }
        $0 == "" { prev = 1; next }
        { if (prev) emit()
          prev = ($0 ~ /^#+ /) }' <<<"$1"
}
# bullet_openers <text> — same idea for bullets at any indent, which an opener
# list cannot see: bullets in one list are adjacent, so an inserted one adds no
# block. The INDENT is part of the key, so a nested bullet is visible too.
bullet_openers() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s, ind) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                ind = match($0, /[^ \t]/) - 1
                                printf "%s%d:%s", (c++ ? " ~ " : ""), ind, s }
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^[ \t]*[-*+] / { emit() }' <<<"$1"
}
# ordered_openers <text> — the same for ordered-list items. Phase 4 IS an
# ordered list and its item ORDER is the decision this gate exists for: the
# ledger before the approval ask, never after it.
ordered_openers() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s, ind) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                ind = match($0, /[^ \t]/) - 1
                                printf "%s%d:%s", (c++ ? " ~ " : ""), ind, s }
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^[ \t]*[0-9]+\. / { emit() }' <<<"$1"
}
# table_rows <text> — every table row in the window. Anchored `^[[:space:]]*\|`,
# because a row indented by ONE SPACE renders identically, passes markdownlint,
# and was measured slipping past a `^\|` filter.
#
# THE PATTERN IS INLINE, NEVER PASSED THROUGH `-v`: awk expands escapes in a
# `-v` assignment, so `\|` arrives as a bare `|` and the ERE becomes an
# alternation with an empty branch that matches every line.
table_rows() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s, ind) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                ind = match($0, /[^ \t]/) - 1
                                printf "%s%d:%s", (c++ ? " ~ " : ""), ind, s }
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^[ \t]*\|/ { emit() }' <<<"$1"
}
# heading_list <text> — every heading line. `^#+ ` and not `^#`: a wrapped line
# beginning `#284 changed …` is not a heading. Fence-aware, or the first `#`
# comment inside a ```bash block reads as one.
heading_list() {
    awk '
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^#+ / { printf "%s%s", (c++ ? " ~ " : ""), $0 }' <<<"$1"
}
# section_blocks <text> — one flattened block per line, fences EXCLUDED.
section_blocks() {
    awk '
        function flush(  t) { if (n) { t = buf
                                       gsub(/[ \t]+/, " ", t); sub(/^ +/, "", t); sub(/ +$/, "", t)
                                       print t; buf = ""; n = 0 } }
        /^[ \t]*```/ { flush(); fence = !fence; next }
        fence { next }
        $0 == "" { flush(); next }
        { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
          buf = (n ? buf " " line : line); n = 1 }
        END { flush() }' <<<"$1"
}
# section_fences <text> — one flattened FENCE BODY per line, with issue and PR
# numbers normalised to `#N`. The fences are not inert worked examples here:
# Phase 4's ```text fence is the coverage block the run prints, so excluding it
# would leave the one artefact #284 is about writable.
section_fences() {
    awk '
        function flush(  t) { if (n) { t = buf
                                       gsub(/[ \t]+/, " ", t); sub(/^ +/, "", t); sub(/ +$/, "", t)
                                       gsub(/#[0-9]+/, "#N", t)
                                       print t; buf = ""; n = 0 } }
        /^[ \t]*```/ { if (fence) flush(); fence = !fence; next }
        !fence { next }
        { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line)
          buf = (n ? buf " " line : line); n = 1 }
        END { flush() }' <<<"$1"
}
# reviewer_rows <text> — the `sassy-dog:<name>-reviewer` in each map row's FIRST
# cell, sorted. First cell only, so a reviewer merely mentioned in a
# "Dispatch when" cell cannot forge a row.
reviewer_rows() {
    awk -F'|' '
        /^[ \t]*\|/ {
            cell = $2
            if (match(cell, /sassy-dog:[a-z0-9-]+-reviewer/))
                print substr(cell, RSTART + 10, RLENGTH - 10)
        }' <<<"$1" | sort
}
# --- end extractors ----------------------------------------------------------

# --- the canon ---------------------------------------------------------------
# The decision surface AND the structure, held HERE rather than derived from the
# files under test. A quoted heredoc, so nothing expands and no quote needs
# escaping; key and value are TAB-separated. This is the ONE place to edit when
# these sections legitimately change — see the cost note in the header.
canon_table() {
    cat <<'CANON'
orch#b1	# Orchestration
orch#b2	How the main agent dispatches review agents, what each returns, and how findings become issues.
orch#b3	## Agent → domain map
orch#b4	Dispatch only the agents with signal for the detected stack. All ship with this plugin and namespace as `sassy-dog:<name>`.
orch#b5	| Agent (`subagent_type`) | Owns rubric areas | Dispatch when | |---|---|---| | `sassy-dog:architecture-reviewer` | 2 structure, 3 architecture, 13 team/scaling | always | | `sassy-dog:code-quality-reviewer` | 4 code quality, 12 tech debt | always | | `sassy-dog:security-reviewer` | 5 security (app + supply chain + pipeline + ops) | always | | `sassy-dog:testing-reviewer` | 7 testing | always | | `sassy-dog:cicd-release-reviewer` | 8 CI/CD & release | `.github/workflows/` or other CI config present | | `sassy-dog:infra-platform-reviewer` | 9 infrastructure & platform | `*.tf`/`*.bicep`/`Dockerfile`/k8s manifests present | | `sassy-dog:observability-ops-reviewer` | 10 observability & operations | always (light if app is tiny) | | `sassy-dog:dx-docs-reviewer` | 6 DX, 11 docs | always | | `sassy-dog:dependency-supply-chain-reviewer` | 5 supply-chain slice, 12 dep debt | a lockfile/manifest is present |
orch#b6	**Dispatch rule:** issue all selected agents in **one message, multiple Agent calls** (concurrent), each at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`). Give each: the absolute repo path, the detected stack summary, the dedupe index is *not* needed by agents (you dedupe centrally), and an instruction to return **only** the JSON object `{"findings": [...]}` in the schema below as its final text, with no Markdown fences or surrounding prose. Tell each agent it is in **audit mode**: find what's wrong, cite evidence, do not propose to write code.
orch#b7	## Dispatch outcomes (Phase 1)
orch#b8	Every domain in the table above gets an **outcome**, recorded as the fan-out returns. Together they are the run's **ledger**: built in Phase 1, carried through Phases 2 and 3 unchanged, and printed in Phase 4's preview before the approval prompt.
orch#b9	Three outcomes belong to the fan-out itself:
orch#b10	| Outcome | What it means | Reviewed | |---|---|---| | `returned` | The agent came back with a JSON object containing a `findings` array in the schema below — empty or not | yes | | `no report` | The dispatch succeeded but returned no usable envelope (bare JSON object, or exactly one fenced block holding it with only whitespace outside): prose before or after the object (fenced or not), two or more fences, a fence that does not close, missing final text, malformed JSON, JSON `null`, missing `findings`, null/non-array `findings`, a legacy bare array, or invalid finding entries | **no** | | `could not dispatch` | The Agent call errored, timed out, or the agent could not be resolved | **no** |
orch#b11	A fourth records a decision taken *before* the fan-out: `not dispatched`, for a domain the Phase-0 stack detection found no signal for. Record it with the reason that skipped it.
orch#b12	**A domain whose outcome is not `returned` is DARK, and a dark domain is never scored as clean and never reported as "no findings".** Those are the two claims this audit is not entitled to make about a domain nobody reviewed. Name it, name its outcome, and say that this run does not cover it. Keep `not dispatched` visibly apart from the two dark outcomes: a domain skipped for cause and a domain that went dark are indistinguishable once both are merely missing from the Epic, and only one of them is a decision somebody made.
orch#b13	**This is the sibling of the diff-scoped rule, not a copy of it and not derived from it.** `agents/pr-review-orchestrator.md`, Step 5, scores a lost reviewer's surface `!` in a report a human reads while the context is still live; a hole there costs a re-run. This path **writes**. Its artefact is a filed Epic and its child issues, which becomes the durable record of what is wrong with the repo — so a lost `security-reviewer` here yields a backlog that omits an entire domain and **reads complete** to everyone who finds it later. Same question, different consequence: neither rule is evidence about the other, and changing one does not license changing the other ([#280](https://github.com/Sassy-Dog/skills/issues/280), [#284](https://github.com/Sassy-Dog/skills/issues/284)).
orch#b14	**A dark domain is surfaced, not a veto.** It never stops the run and never blocks filing: findings that did come back are still verified, grouped, previewed and — on approval — filed. The human was always the gate here; what was missing is that they were not told a domain went dark. Re-dispatching a dark domain is allowed **while Phase 1 is still running**, and the ledger then records the outcome of the last attempt — a domain that comes back on a retry is `returned`. Once Phase 2 begins the ledger is fixed: Phases 2 and 3 never add a domain, clear one, or re-open the fan-out.
orch#b15	## Finding output schema
orch#b16	Each agent returns a JSON object `{"findings": [...]}` in both audit and diff-scoped mode. A returned final text is a **usable envelope** only when, after trimming surrounding whitespace, it is either (1) a bare JSON object, or (2) exactly one fenced block (` ```json ` or a bare ` ``` `) with only whitespace outside it whose contents are a JSON object. A fence is a line that begins with three backticks, outside any JSON string value; a triple backtick inside a string value is neither a fence nor prose. Anything else is unusable and the cause is named: prose before or after the object (fenced or not), two or more fences, a fence that does not close, or JSON that fails the schema. Reviewers must still return a bare object; consumers accept one fence only so a completed review is not discarded, never as licence for reviewers to fence. Accept the object only when `findings` is an array and every entry satisfies the existing finding schema; never coerce an unusable result to empty findings or salvage a partial array. Unwrap usable `findings` into Phase 2 verification without changing its fields. Each finding:
orch#b17	Agents that find nothing in their domain return `{"findings": []}` — that is a valid, useful result, **and it is a result only once you have received it**. A completed empty envelope that arrived is a clean domain; missing or unusable output is a dark one. The ledger above is the only thing that tells them apart, which is why it is recorded rather than inferred from what the Epic ended up containing.
orch#b18	## Adversarial review (Phase 2)
orch#b19	For each finding, in order of severity:
orch#b20	1. **Verify evidence** — open the cited `file:line`. If it doesn't say what the finding claims → drop. 2. **Genuine vs. preference** — is this a real risk, or a style opinion / valid convention? Drop preferences. 3. **Recalibrate** — adjust severity/likelihood to reality; downgrade theoretical threats. 4. **Dedupe vs. existing issues** — compare against the Phase-0 GitHub index (title + body similarity, same file/area). If already tracked → mark `duplicate-of #N` (comment later, don't refile). 5. **Dedupe vs. siblings** — merge near-identical findings from different agents. 6. **Refute pass (high-impact only)** — for `critical`/`high`, optionally dispatch 1–3 skeptic subagents at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`), each told to *try to prove the finding wrong* (distinct lenses: exploitability, does-it-reproduce, is-it-already-mitigated). Keep the finding only if it survives a majority.
orch#b21	Survivors carry a final `confidence`. Drop anything below ~0.6 unless severity is `critical`.
orch#b22	## Grouping into PR-sized issues (Phase 3)
orch#b23	- Cluster survivors that a single PR would naturally fix together (same subsystem, same kind of change). Each cluster → one child issue; list its findings as a checklist in the body. - A single `l`/`xl` finding may be its own issue with a "split into N PRs" note. - Keep clusters cohesive: don't bundle unrelated areas just to reduce issue count. - Order issues by ROI (severity × likelihood ÷ effort) for the Epic's top-10.
orch#b24	Then proceed to `references/github-issue-ops.md` for filing.
orch#f1	- title: imperative, PR-sized ("Pin GitHub Actions to commit SHAs") area: one of the 15 rubric areas severity: critical | high | medium | low likelihood: high | medium | low evidence: one or more "path/to/file.ext:LINE" with a 1-line quote/why why_it_matters: concrete consequence in THIS repo (not generic) proposed_fix: what a PR would do acceptance: how we'd know it's fixed pr_size: xs | s | m | l (l = consider splitting) labels: suggested labels from the taxonomy confidence: 0.0–1.0 (agent's own confidence the finding is real)
skill#b1	# Assess-It
skill#b2	Turn a whole repository into a deduped, evidence-backed, PR-sized GitHub Issue backlog under one tracking **Epic** — by fanning out specialized review agents, adversarially verifying their findings, and filing only what survives.
skill#b3	**Repo-agnostic.** Works on any GitHub repo. Operates on **one repo per run** (the current working dir unless a target is given). A periodic routine loops multiple repos — that lives outside this skill.
skill#b4	**Default = preview, not file.** Filing issues is outward-facing and hard to undo. Always present the proposed Epic + child issues for approval and file only after the user confirms. Never create issues silently.
skill#b5	## Core Principle
skill#b6	A finding only earns an issue if it has **concrete `file:line` evidence**, survives an **adversarial second look**, and is **not already tracked** by an existing issue. Everything else is noise — drop it. One issue = one coherent PR's worth of work.
skill#b7	## Workflow
skill#b8	Follow the five phases. Full dispatch details, the finding schema, and exact `gh` commands live in the reference files — read them when you reach that phase.
skill#b9	### Phase 0 — Scope & detect (you, the main agent)
skill#b10	1. Resolve the target repo (cwd or the path/arg given). Confirm a GitHub remote: `gh repo view --json nameWithOwner,defaultBranchRef`. 2. Detect stack(s) by globbing manifests: `package.json`, `*.csproj`, `Cargo.toml`, `pubspec.yaml`, `*.tf`/`*.bicep`, `Dockerfile`, `.github/workflows/`, Nx/Bun/tRPC config. This decides which review agents to dispatch. 3. **Build the dedupe index** (used in Phase 2 and Phase 4): `gh issue list --state open --limit 500 --json number,title,labels,body` (also pull recently-closed for context). Keep it in memory for the whole run.
skill#b11	### Phase 1 — Fan out (parallel review agents)
skill#b12	Dispatch the relevant `sassy-dog:*-reviewer` agents **in a single message with multiple Agent tool calls** so they run concurrently, each at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`) — the tier the nine reviewers run at in both review modes. Skip domains with no signal (no IaC → skip `infra-platform-reviewer`). Give each agent the repo path, the detected stack, and its scope. Each returns only the JSON object `{"findings": [...]}` as final text, with findings in the shared schema and mandatory `file:line` evidence. Accept `returned` only for a usable envelope per `orchestration.md`; `{"findings": []}` is completed-empty, while missing or malformed results are `no report`, never clean. Unwrap usable `findings` for Phase 2 verification.
skill#b13	**Record an outcome for every domain as the fan-out returns** — `returned`, `no report`, or `could not dispatch` — plus `not dispatched`, with its reason, for a domain the Phase-0 stack detection skipped. That ledger is Phase 4's input **and the Epic body's** (#294): a domain whose outcome is not `returned` is **dark**, and a dark domain is never scored as clean and never reported as "no findings". In the executive summary its rubric dimension scores `n/a — not measured (dark)`, never a number — the table and this rule otherwise leave no compliant answer, and an agent facing that invents a score, which is worse than a missing one because it is quantitative. A reviewer that came back with nothing looks exactly like one that found nothing, and writing down which happened is the only thing that separates them. Carry the ledger through Phases 2 and 3 unchanged — nothing there adds a domain or clears one.
skill#b14	See **`orchestration.md`** for the agent→domain map, the four outcomes and what each one means, and the finding schema.
skill#b15	### Phase 2 — Adversarial review (you)
skill#b16	For every finding: open the cited `file:line` and confirm the evidence is real and the problem genuine (not mere preference/convention); sanity-check severity, likelihood, and blast radius. Dedupe findings against each other **and against the Phase-0 GitHub index**. For high-impact findings, optionally dispatch perspective-diverse skeptic subagents prompted to *refute* — keep only survivors. Be skeptical by default; a false issue costs more than a missed one.
skill#b17	### Phase 3 — Group into PR-sized work items
skill#b18	Cluster surviving findings so each cluster is one coherent PR (e.g. "harden GitHub Actions workflows" may bundle 3 findings). Each cluster becomes one child issue.
skill#b19	### Phase 4 — Preview, then file
skill#b20	1. **Print the full preview**: the Epic (exec summary + scores) and every child issue (title, body, labels, and its dedupe decision). 2. **Print the Phase-1 ledger in that preview, before you ask for approval.** Every domain, with its outcome, rendered so a reader sees the coverage without opening anything:
skill#b21	Print this block on **every** run, the all-clear included. A coverage line that shows up only when something went wrong teaches the reader that its absence means nothing, which is the habit that made a dark domain invisible in the first place (issue [#284](https://github.com/Sassy-Dog/skills/issues/284)). 3. Now ask the user to approve, edit, or cancel. **File nothing yet.** A dark domain is surfaced, not a veto: it does not stop the run and does not block filing, and on approval everything that did come back is filed as normal. 4. On approval, **align the target repo's labels first** — the engineering-dimension + severity taxonomy is owned by one script in this plugin, and this skill invokes it rather than carrying a copy (issue #167). The path below is resolved when this skill loads; pass it on as `ALIGN=<that path>` to anything that needs it, because `references/*.md` are read raw and never get the substitution:
skill#b22	**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/assess-it`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.
skill#b23	5. Then follow **`references/github-issue-ops.md`**: re-check dedupe per issue right before creation (comment on a match instead of duplicating), create child issues, create the Epic **with the coverage block in its body**, then attach each child as a **native sub-issue** (`gh api`), with a task-list fallback.
skill#b24	### Phase 5 — Report
skill#b25	Print the Epic URL, the child issue list, the executive summary, and the same coverage block Phase 4 previewed. **The Epic body now carries that coverage block too** ([#294](https://github.com/Sassy-Dog/skills/issues/294)) — see `references/github-issue-ops.md` §4 — so the durable artefact records what was and was not audited, and a later reader of a backlog missing a whole domain is told so instead of finding a set that reads complete. This reprint is for the operator who just approved the filing; the Epic's copy is for everyone after them, and the two are not interchangeable: session output reaches one person once.
skill#b26	## Reference Files
skill#b27	- **`assessment-rubric.md`** — the 15 assessment areas, scoring (1–10 health/security/DX/maintainability), severity & likelihood definitions, and the executive-summary format. Review agents consult their section; you use it for the Epic summary. - **`orchestration.md`** — agent→domain map, per-agent scope, the four dispatch outcomes and the dark-domain rule, the finding output schema, and the adversarial-review / dedupe / grouping logic. - **`references/github-issue-ops.md`** — label *routing* (which dimension label a finding gets; the taxonomy itself is owned by `scripts/align-labels.sh`, never copied), child-issue & Epic body templates, and exact `gh`/`gh api` commands for dedupe, issue creation, and native sub-issue linking.
skill#b28	## Red Flags — STOP
skill#b29	- About to file an issue with no `file:line` evidence → drop it or downgrade to the Epic's "watch list". - About to create issues without showing the preview first → STOP, preview and get approval. - A finding that's "best practice" with no concrete harm in *this* repo → that's cargo-cult; drop it. - Skipped the dedupe index fetch → you will create duplicates. Fetch it in Phase 0. - About to call a domain clean, or write "no findings" for it, when its reviewer did not come back → STOP. That is the one claim this audit cannot make. Report it dark, with its outcome, and file the rest. - About to show the preview with a domain missing from the coverage block → STOP, add it with its outcome, then show the preview and carry on. A domain absent from the ledger is one the reader cannot tell apart from a clean one, and this preview is the last moment before the backlog becomes the record. This is a missing line to add, never a reason to abandon the run. - About to type a `gh label create` with a colour in it → STOP. Run `align-labels.sh` (Phase 4). A hardcoded hex here is a second copy of the taxonomy, and the last one silently painted stale colours into every repo this skill audited.
skill#f1	Domain coverage — 9 dispatched, 7 returned, 2 dark (+0 not dispatched) returned: architecture, code-quality, testing, dx-docs, observability-ops, cicd-release, dependency-supply-chain no report: infra-platform — came back with prose, not a findings envelope could not dispatch: security — Agent call errored (agent not resolved) not dispatched: (none) 2 domains are DARK. This audit does not cover them, and nothing above is evidence that they are clean. `dispatched` counts the fan-out only, so a `not dispatched` domain is never one of it and is carried in its own tally.
skill#f2	bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo "$REPO" --dry-run # preview drift, writes nothing bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo "$REPO" # create missing + correct drifted
inv#orch_headings	# Orchestration ~ ## Agent → domain map ~ ## Dispatch outcomes (Phase 1) ~ ## Finding output schema ~ ## Adversarial review (Phase 2) ~ ## Grouping into PR-sized issues (Phase 3)
inv#orch_openers	# Orchestration ~ How the main agent dispatches review ~ ## Agent → domain map ~ Dispatch only the agents with signal ~ | Agent (`subagent_type`) | Owns rubric ~ **Dispatch rule:** issue all selected agents ~ ## Dispatch outcomes (Phase 1) ~ Every domain in the table above ~ Three outcomes belong to the fan-out ~ | Outcome | What it means ~ A fourth records a decision taken ~ **A domain whose outcome is not ~ **This is the sibling of the ~ **A dark domain is surfaced, not ~ ## Finding output schema ~ Each agent returns a JSON object ~ ``` ~ ``` ~ Agents that find nothing in their ~ ## Adversarial review (Phase 2) ~ For each finding, in order of ~ 1. **Verify evidence** — open the ~ Survivors carry a final `confidence`. Drop ~ ## Grouping into PR-sized issues (Phase ~ - Cluster survivors that a single ~ Then proceed to `references/github-issue-ops.md` for filing.
inv#orch_bullets	0:- Cluster survivors that a single ~ 0:- A single `l`/`xl` finding may ~ 0:- Keep clusters cohesive: don't bundle ~ 0:- Order issues by ROI (severity
inv#orch_ordered	0:1. **Verify evidence** — open the ~ 0:2. **Genuine vs. preference** — is ~ 0:3. **Recalibrate** — adjust severity/likelihood to ~ 0:4. **Dedupe vs. existing issues** — ~ 0:5. **Dedupe vs. siblings** — merge ~ 0:6. **Refute pass (high-impact only)** —
inv#orch_rows	0:| Agent (`subagent_type`) | Owns rubric ~ 0:|---|---|---| ~ 0:| `sassy-dog:architecture-reviewer` | 2 structure, 3 ~ 0:| `sassy-dog:code-quality-reviewer` | 4 code quality, ~ 0:| `sassy-dog:security-reviewer` | 5 security (app ~ 0:| `sassy-dog:testing-reviewer` | 7 testing | ~ 0:| `sassy-dog:cicd-release-reviewer` | 8 CI/CD & ~ 0:| `sassy-dog:infra-platform-reviewer` | 9 infrastructure & ~ 0:| `sassy-dog:observability-ops-reviewer` | 10 observability & ~ 0:| `sassy-dog:dx-docs-reviewer` | 6 DX, 11 ~ 0:| `sassy-dog:dependency-supply-chain-reviewer` | 5 supply-chain slice, ~ 0:| Outcome | What it means ~ 0:|---|---|---| ~ 0:| `returned` | The agent came ~ 0:| `no report` | The dispatch ~ 0:| `could not dispatch` | The
inv#skill_headings	# Assess-It ~ ## Core Principle ~ ## Workflow ~ ### Phase 0 — Scope & detect (you, the main agent) ~ ### Phase 1 — Fan out (parallel review agents) ~ ### Phase 2 — Adversarial review (you) ~ ### Phase 3 — Group into PR-sized work items ~ ### Phase 4 — Preview, then file ~ ### Phase 5 — Report ~ ## Reference Files ~ ## Red Flags — STOP
inv#skill_openers	--- ~ # Assess-It ~ Turn a whole repository into a ~ **Repo-agnostic.** Works on any GitHub repo. ~ **Default = preview, not file.** Filing ~ ## Core Principle ~ A finding only earns an issue ~ ## Workflow ~ Follow the five phases. Full dispatch ~ ### Phase 0 — Scope & ~ 1. Resolve the target repo (cwd ~ ### Phase 1 — Fan out ~ Dispatch the relevant `sassy-dog:*-reviewer` agents **in ~ **Record an outcome for every domain ~ See **`orchestration.md`** for the agent→domain map, ~ ### Phase 2 — Adversarial review ~ For every finding: open the cited ~ ### Phase 3 — Group into ~ Cluster surviving findings so each cluster ~ ### Phase 4 — Preview, then ~ 1. **Print the full preview**: the ~ ```text ~ ``` ~ Print this block on **every** run, ~ **Plugin root.** If the plugin-root placeholder ~ ```bash ~ ``` ~ 5. Then follow **`references/github-issue-ops.md`**: re-check dedupe ~ ### Phase 5 — Report ~ Print the Epic URL, the child ~ ## Reference Files ~ - **`assessment-rubric.md`** — the 15 assessment ~ ## Red Flags — STOP ~ - About to file an issue
inv#skill_bullets	0:- **`assessment-rubric.md`** — the 15 assessment ~ 0:- **`orchestration.md`** — agent→domain map, per-agent ~ 0:- **`references/github-issue-ops.md`** — label *routing* (which ~ 0:- About to file an issue ~ 0:- About to create issues without ~ 0:- A finding that's "best practice" ~ 0:- Skipped the dedupe index fetch ~ 0:- About to call a domain ~ 0:- About to show the preview ~ 0:- About to type a `gh
inv#skill_ordered	0:1. Resolve the target repo (cwd ~ 0:2. Detect stack(s) by globbing manifests: ~ 0:3. **Build the dedupe index** (used ~ 0:1. **Print the full preview**: the ~ 0:2. **Print the Phase-1 ledger in ~ 0:3. Now ask the user to ~ 0:4. On approval, **align the target ~ 0:5. Then follow **`references/github-issue-ops.md`**: re-check dedupe
inv#skill_rows	
CANON
}

CANON_KEYS=()
CANON_VALS=()
while IFS=$'\t' read -r _ck _cv; do
    [ -z "$_ck" ] && continue
    CANON_KEYS+=("$_ck")
    CANON_VALS+=("$_cv")
done < <(canon_table)

canon_get() {
    local i
    for ((i = 0; i < ${#CANON_KEYS[@]}; i++)); do
        if [ "${CANON_KEYS[$i]}" = "$1" ]; then printf '%s' "${CANON_VALS[$i]}"; return 0; fi
    done
    return 1
}
canon_count_prefix() {
    local i c=0
    for ((i = 0; i < ${#CANON_KEYS[@]}; i++)); do
        case "${CANON_KEYS[$i]}" in "$1"*) c=$((c + 1)) ;; esac
    done
    printf '%s' "$c"
}

# --- the pinned windows ------------------------------------------------------
# `name|file|start prefix|stop prefix`. `|` is safe as the delimiter: no anchor
# here contains one. A stop of NEVER means "runs to EOF" and is asserted as such.
#
# BOTH WINDOWS ARE WHOLE FILES, and the seven targeted windows this replaced are
# the reason. A review measured six meaning-inverting rewrites passing at 79/79:
# a sentence appended to `## Core Principle` ("do not file it until every
# reviewer has returned" — the veto #284 forbids), one appended to the
# `**Dispatch rule:**` paragraph ("An agent that does not answer has nothing to
# report: score its domain clean" — the headline rule, verbatim inverse), and
# four more. Every one of them lived in a block OUTSIDE the seven windows, where
# the inventories bound insertion, deletion and reordering and nothing at all
# bound the BODY of an existing block. Worse, `orchestration.md`'s six-item
# Phase-2 ordered list sat outside every window on contiguous lines, so
# `openers()` saw only item 1 and an inserted seventh item — "Drop dark domains
# … remove it from the ledger before Phase 3" — was invisible to every layer.
# THE SUBSET WAS THE DEFECT, NOT THE CHOICE OF SUBSET; that is the precedent's
# own lesson and this gate had to learn it a second time. Both files are small
# and are entirely about this one flow, so canon = the whole file is tractable
# here in a way it was not for the precedent.
#
# The SKILL window starts at `# Assess-It` rather than line 1: the frontmatter
# is a trigger spec that `scripts/check-frontmatter.sh` already gates, and
# pinning it would redden on every legitimate trigger-phrase edit for no gain.
# That is the one deliberate hole in "whole file", and it is another gate's job.
WINDOW_DEFS=(
"orch|$ORCH|# Orchestration|$NEVER"
"skill|$SKILL|# Assess-It|$NEVER"
)

echo "assess-it audit-mode lost-reviewer backstop (issue #284)"

section windows "every window resolves, and stops where it claims to"

for f in "$SKILL" "$ORCH" "$PRORCH"; do
    if [ -r "$f" ]; then ok "read $f"; else bad "missing file: $f"; fi
done
[ "$fails" -eq 0 ] || { echo "test-audit-lost-reviewer: FAILED ($fails)" >&2; exit 1; }

WIN_NAMES=()
WIN_TEXT=()
for _def in "${WINDOW_DEFS[@]}"; do
    _wname="${_def%%|*}"; _rest="${_def#*|}"
    _wfile="${_rest%%|*}"; _rest="${_rest#*|}"
    _wstart="${_rest%%|*}"; _wstop="${_rest#*|}"
    _wtext="$(raw_region "$_wfile" "$_wstart" "$_wstop")"
    assert_nonempty "$_wtext" "window $_wname resolves"
    if [ "$_wstop" = "$NEVER" ]; then
        _wlast="$(printf '%s\n' "$_wtext" | tail -n 1)"
        _flast="$(tail -n 1 "$_wfile")"
        assert_eq "$_wlast" "$_flast" "window $_wname runs to EOF as declared"
    else
        _sline="$(region_stop_line "$_wfile" "$_wstart" "$_wstop")"
        if [ -z "$_sline" ]; then
            bad "window $_wname does not stop where it claims — the stop marker never appears after it"
        elif [ -z "$_wstop" ]; then
            assert_eq "$_sline" "<blank>" "window $_wname stops at the next blank line"
        else
            case "$_sline" in
                "$_wstop"*) ok "window $_wname stops at '$_wstop'" ;;
                *) bad "window $_wname stops at an unexpected line: ${_sline:0:80}" ;;
            esac
        fi
    fi
    WIN_NAMES+=("$_wname")
    WIN_TEXT+=("$_wtext")
done

section canon "every block and every fence of every pinned window, by equality after flattening"

for ((_wi = 0; _wi < ${#WIN_NAMES[@]}; _wi++)); do
    _wname="${WIN_NAMES[$_wi]}"
    _wtext="${WIN_TEXT[$_wi]}"

    _nb=0
    while IFS= read -r _bline; do
        _nb=$((_nb + 1))
        _key="${_wname}#b${_nb}"
        _want="$(canon_get "$_key")" || _want=""
        assert_eq "$_bline" "$_want" "canon $_key"
        note_consumed "$_key"
    done < <(section_blocks "$_wtext")
    assert_eq "$_nb" "$(canon_count_prefix "${_wname}#b")" "canon $_wname block count"

    _nf=0
    while IFS= read -r _fline; do
        _nf=$((_nf + 1))
        _key="${_wname}#f${_nf}"
        _want="$(canon_get "$_key")" || _want=""
        assert_eq "$_fline" "$_want" "canon $_key"
        note_consumed "$_key"
    done < <(section_fences "$_wtext")
    assert_eq "$_nf" "$(canon_count_prefix "${_wname}#f")" "canon $_wname fence count"
done

section inventory "openers, bullets, ordered items, table rows and headings — both files whole"

_orch_all="$(cat "$ORCH")"
_skill_all="$(cat "$SKILL")"

for _inv in \
    "inv#orch_headings|$(heading_list "$_orch_all")" \
    "inv#orch_openers|$(openers "$_orch_all")" \
    "inv#orch_bullets|$(bullet_openers "$_orch_all")" \
    "inv#orch_ordered|$(ordered_openers "$_orch_all")" \
    "inv#orch_rows|$(table_rows "$_orch_all")" \
    "inv#skill_headings|$(heading_list "$_skill_all")" \
    "inv#skill_openers|$(openers "$_skill_all")" \
    "inv#skill_bullets|$(bullet_openers "$_skill_all")" \
    "inv#skill_ordered|$(ordered_openers "$_skill_all")" \
    "inv#skill_rows|$(table_rows "$_skill_all")" ; do
    _ikey="${_inv%%|*}"
    _igot="${_inv#*|}"
    _iwant="$(canon_get "$_ikey")" || _iwant=""
    assert_eq "$_igot" "$_iwant" "inventory ${_ikey#inv#}"
    note_consumed "$_ikey"
done

section residue "the #283 residue note is REPLACED by the rule, not left beside it"

_orch_flat="$(flat "$_orch_all")"
assert_absent "$_orch_flat" "Known gap" "residue: the 'Known gap' callout is gone"
assert_absent "$_orch_flat" "lost-agent scoring" "residue: 'lost-agent scoring' is gone"
assert_absent "$_orch_flat" "unfixed, not overlooked" "residue: 'unfixed, not overlooked' is gone"
assert_absent "$_orch_flat" "Recorded here so the absence" "residue: the 'recorded here' hedge is gone"
assert_absent "$_orch_flat" "deliberately kept out of the prose-gate work" "residue: the deferral clause is gone"

section durable "the coverage record reaches the FILED Epic, not only the session (issue #294)"

# #284 closed the half that lands at the PREVIEW. This is the durable half, and
# it is the one #284's own problem statement was about: Phase 4's preview and
# Phase 5's report are session output, so a backlog missing a whole domain still
# READS COMPLETE to whoever finds the Epic three weeks later.
OPS="skills/assess-it/references/github-issue-ops.md"
RUBRIC="skills/assess-it/assessment-rubric.md"
for f in "$OPS" "$RUBRIC"; do
    if [ -r "$f" ]; then ok "durable: read $f"; else bad "durable: missing file: $f"; fi
done
_ops_flat="$(flat "$(cat "$OPS")")"
_rub_flat="$(flat "$(cat "$RUBRIC")")"

# The Epic BODY, not the preview.
assert_has "$_ops_flat" "then **the coverage block**, then the child list" \
    "durable: the Epic body definition names the coverage block"
assert_has "$_ops_flat" "## Audit coverage" \
    "durable: the Epic body template carries the coverage heading"
assert_has "$_ops_flat" "was NOT audited" \
    "durable: the block states that a non-returned domain was not audited"

# Every domain, not only the dark ones — a block that appears only on failure is
# one whose ABSENCE a later reader cannot interpret.
assert_has "$_ops_flat" "List every domain, never only the dark ones" \
    "durable: the block lists every domain, so its absence is never ambiguous"

# The LAST instruction an agent reads must not be a subset of the first. It
# already omitted the executive summary once, which is how this gap survived.
assert_has "$_ops_flat" "Create the Epic with the executive report + **the coverage block** + child list." \
    "durable: the order of operations names the coverage block too"
assert_has "$_ops_flat" "must not be a subset of the first" \
    "durable: and says why that list must not drift from the section above it"

# THE VETO. The old claim was that nothing writes coverage into the Epic; if it
# comes back, the durable half has been reverted while every must-exist above
# could still pass on a document that contains both.
assert_absent "$(flat "$(cat "$SKILL")")" "Nothing in this skill writes the coverage into the Epic body" \
    "durable: the 'nothing writes it to the Epic' claim is gone from SKILL.md"
assert_absent "$_ops_flat" "Body = the executive report from .assessment-rubric.md. .scores[^)]*), followed by the child list" \
    "durable: the Epic body definition no longer ends at the child list"

# The rubric had NO abstain value, so a dark domain had no compliant score: the
# table demanded a number and Phase 1 forbade scoring it clean. An agent facing
# that invents one, and an invented score is worse than a missing one because it
# is quantitative.
assert_has "$_rub_flat" "not measured (dark)" \
    "durable: the rubric carries an abstain value for a dark dimension"
assert_has "$_rub_flat" "never a number" \
    "durable: and forbids a number for a dark dimension"
assert_has "$_rub_flat" "NOT a low score and NOT a clean one" \
    "durable: the abstain row says it is neither a low score nor a clean one"

section sibling "the diff-scoped rule survives untouched — this file is read for one fact"

_pr_flat="$(flat "$(cat "$PRORCH")")"
assert_has "$_pr_flat" "A reviewer that did not come back is not a clean surface." \
    "sibling: pr-review-orchestrator still scores a lost reviewer"
assert_has "$_pr_flat" "its surface is \`!\`, never" \
    "sibling: the \`!\` consequence survives in the diff-scoped orchestrator"

section premise "the ledger ranges over the reviewers this plugin actually ships"

_map_text="$(raw_region "$ORCH" "## Agent → domain map" "## Dispatch outcomes (Phase 1)")"
assert_nonempty "$_map_text" "premise: the agent → domain map window resolves"
_mapped="$(reviewer_rows "$_map_text")"
_shipped="$(for _f in agents/*-reviewer.md; do _b="${_f##*/}"; printf '%s\n' "${_b%.md}"; done | sort)"
assert_eq "$_mapped" "$_shipped" "premise: the map's rows are exactly the shipped *-reviewer agents"
_nmapped=0
if [ -n "$_mapped" ]; then _nmapped="$(printf '%s\n' "$_mapped" | wc -l | tr -d ' ')"; fi
if [ "$_nmapped" -ge 9 ]; then
    ok "premise: the map carries at least the nine reviewers ($_nmapped)"
else
    bad "premise: the map carries only $_nmapped reviewers — the equality above may be vacuous"
fi

section registry "the floor binds: the canon is non-empty and every key was consumed"

if [ "${#CANON_KEYS[@]}" -gt 0 ]; then
    ok "the canon table is non-empty (${#CANON_KEYS[@]} entries)"
else
    bad "the canon table is empty — every equality above compared nothing to nothing"
fi
_unconsumed=""
for ((_i = 0; _i < ${#CANON_KEYS[@]}; _i++)); do
    case "$consumed" in
        *" ${CANON_KEYS[$_i]} "*) ;;
        *) _unconsumed="$_unconsumed ${CANON_KEYS[$_i]}" ;;
    esac
done
assert_eq "$_unconsumed" "" "every canon key is consumed by an assertion"

_close_section

echo
echo "assertions: $asserts (floor $ASSERT_FLOOR)"
if [ "$asserts" -lt "$ASSERT_FLOOR" ]; then
    echo "test-audit-lost-reviewer: only $asserts assertions ran, floor is $ASSERT_FLOOR" >&2
    fails=$((fails + 1))
fi
for _s in "${SECTIONS[@]}"; do
    _name="${_s%%:*}"; _min="${_s##*:}"
    _got=""
    for ((_i = 0; _i < ${#ran_names[@]}; _i++)); do
        [ "${ran_names[$_i]}" = "$_name" ] && _got="${ran_counts[$_i]}"
    done
    if [ -z "$_got" ]; then
        echo "test-audit-lost-reviewer: section '$_name' never ran" >&2
        fails=$((fails + 1))
    elif [ "$_got" -lt "$_min" ]; then
        echo "test-audit-lost-reviewer: section '$_name' ran $_got assertions, minimum $_min" >&2
        fails=$((fails + 1))
    fi
done
_got=""
for ((_i = 0; _i < ${#ran_names[@]}; _i++)); do
    [ "${ran_names[$_i]}" = "registry" ] && _got="${ran_counts[$_i]}"
done
if [ -z "$_got" ] || [ "$_got" -lt "$REGISTRY_MIN" ]; then
    echo "test-audit-lost-reviewer: the registry section did not reach REGISTRY_MIN=$REGISTRY_MIN" >&2
    fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
    echo "test-audit-lost-reviewer: all green ($asserts assertions)"
    exit 0
fi
echo "test-audit-lost-reviewer: FAILED ($fails)" >&2
exit 1
