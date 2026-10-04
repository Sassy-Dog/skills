#!/usr/bin/env bash
# test-drain-terminal-states.sh — pins dispatch-ready §7's terminal-state
# coverage: the uncovered state #282 found, the enumeration the fix depends on,
# the discriminator that makes it safe, and the four things the fix must NOT
# have moved — plus the §2 bullet that has to demote a `CONFLICTING` PR for
# that coverage to be reachable at all (#290).
#
# THE BUG. §7 defined exactly two terminal states and between them they did not
# cover "Ready empty, in-flight zero, and an open unmerged PR this loop is not
# permitted to advance". COMPLETE was vetoed by the open PR; STALLED required
# Ready non-empty. Neither branch was reachable, so the loop ticked forever —
# reporting the state accurately and doing nothing, with no way to self-cancel.
# The stall record could not help either: it was written only INSIDE the STALLED
# branch, so the two-tick confirmation clock never started.
#
# THE ACTION THAT CREATES THE STATE IS THE ACTION THAT HIDES IT. `issue-claim.sh
# block` strips `ready` and `in-progress` together — correct, a blocked issue is
# neither dispatchable nor in flight — which also removes it from `ready[]`, the
# one set the old conjunct consulted. Recording "a human must decide this" was
# precisely what blinded the stall detector to it. Observed 2026-08-26 on #273 /
# PR #279; the loop was cancelled by hand (issue #282).
#
# THE ENUMERATION IS PART OF THE FIX, NOT A DETAIL OF IT, and this gate exists
# in its current shape because the first edition of the fix omitted it and was
# WORSE THAN THE BUG. §2's only PR discovery was "open PRs from those branches" —
# the branches of IN-FLIGHT issues — and `block` strips `in-progress`, so in
# #282's own state the tick enumerated zero PRs. A held set that is empty
# because nothing was looked at is indistinguishable from one that is empty
# because nothing is held: STALLED is then forbidden by the non-empty rule while
# COMPLETE is admitted, and the loop announces DRAIN COMPLETE and self-cancels
# with a human-gated PR still open. The forever-tick at least never claimed to
# be finished.
#
# THE SET HAS TO BE ONE SET, and that is the second thing a reader will try to
# simplify apart. COMPLETE's veto and §7's held set must range over the SAME
# PRs: any PR that can veto COMPLETE but can never enter the held set gives
# Ready-empty + in-flight-zero + held-empty, which is #282 one shape over — and
# an unqualified "any open PR vetoes COMPLETE" produces exactly that the moment
# a Dependabot PR, a hand-opened PR or another session's PR is sitting there.
# BOTH HALVES ALSO HAVE TO SPAN BOTH PATHS: the blocked set is `blocked[]` only
# on the boardless path, and a bullet written for one path is invisible on the
# other, which is how a board repo would have kept the bug with every assertion
# here green.
#
# WHY THE FIX IS A DISCRIMINATOR AND NOT A DELETED CONJUNCT. Simply dropping
# "Ready non-empty" is the obvious fix and it is wrong — it is also the shape a
# later "this conjunct does nothing" sweep re-derives, which is why the rejected
# option is pinned here as a NEGATIVE rather than merely described. An open PR
# is not automatically a human gate: one whose checks are still running or red
# can advance on its own, and firing STALLED there cancels a loop that was about
# to make progress. So the third conjunct is "nothing this loop is permitted to
# advance", and a table decides which side of that an open PR falls on.
#
# THE TABLE'S LAST ROW IS A DEFAULT AND THE GATE PINS IT AS ONE. §2 holds a PR
# for more reasons than the rows enumerate — `CONFLICTING`, a held `SKIPPED`, a
# held `NO REPORT` — and a table that silently answers "alive" for a shape it
# does not know re-creates #282 one shape at a time. `CONFLICTING` is the
# measured case: a conflicted PR stops CI firing at all and `no checks reported`
# reads exactly like `CI hasn't started`, so without its own row ABOVE the
# checks rows it matches "checks still running" and is answered with something
# that can never happen. Rows 2 to 6 cannot fire at the moment STALLED is
# decided — in-flight zero empties the branch half of the union, so row 1
# matches first — and §7 states that rather than leaving it to be re-derived;
# the gate pins the statement, because a reader who works it out will otherwise
# either trust the rows as live or delete them as dead.
#
# #385 changes durable budget reads and reservation writes, not terminal rows. A PR-body handoff
# can already carry recovery spent by an implementing agent, so absence of a
# coordinator attempt comment no longer proves an unused allowance. Reconcile
# both durable sources and legacy history; only an explicit pending/not-started
# reservation resumes. The b042 canon and discriminator assertion bind this
# conservative read. The new §2 accounting paragraphs join its opener inventory,
# including the issue-only terminal handoff before PR filtering: an exhausted
# pre-PR failure must demote without mistaking a still-working agent for terminal.
# The shared producer/consumer guards live in test-review-gate-decisions.sh.
# No failure row, terminal condition or assertion floor is relaxed.
#
# THE SAME FOREVER-TICK IS REACHABLE ONE BULLET EARLIER, AND #282 DOES NOT
# CLOSE IT (issue #290). Every §2 failure path had a demotion route except one:
# a `CONFLICTING` PR was surfaced and HELD, with no comment, no counter and no
# exit. The hold left the issue `in-progress`, so in-flight never reached zero —
# COMPLETE vetoed by the open PR, STALLED forbidden by in-flight — and the loop
# ticked forever. The discriminator above classifies such a PR correctly the
# moment it is enumerable, and on the in-flight path it never became so, which
# is why #282's fix is untouched here and does not reach this.
#
# IT CANNOT ARRIVE AT A DEMOTION BY ANY OTHER ROUTE, which is why the fix has to
# be written into that bullet rather than left to the failed-check one. A
# conflicted PR stops CI firing at all — `pr-shepherd` records that
# `no checks reported` is indistinguishable from `CI hasn't started` — so the
# attempt counter that eventually demotes a red PR never starts.
#
# THE DECISION IS DEMOTE ON SIGHT, and the rejected alternative is RECORDED in
# the bullet — recorded, not pinned as a negative; see the limit below for what
# that is worth. It is the one a later "make these bullets symmetric" sweep
# reaches for. Mirroring the failed-check bullet's ONE redispatch means
# dispatching a sub-agent to rebase, which IS this loop advancing that PR —
# exactly what §7's `CONFLICTING` row forbids in as many words — so that option
# costs a §7 row as well, re-opening a decision the canon here holds. §7's table
# is UNTOUCHED by #290: once the issue carries `blocked`, §7's FIRST row matches
# it before the `CONFLICTING` row is reached, and in-flight drops so #282's own
# discriminator can finally fire. The demotion also does not change the union —
# §2's first bullet already resolved that PR from the in-flight branch this
# tick, and both rows answer held — so COMPLETE stays vetoed and the held set
# stays non-empty across the write, which is the one-set identity below.
#
# A FOURTH TERMINAL STATE, AND IT IS NOT A STALLED VARIANT (issue #342, epic
# #322). #341 gave §4 a Site filter that steps around an issue whose `site:`
# labels name another machine. That hold reaches §7 like any other, and §7 had
# nowhere to put it: in-flight zero, Ready non-empty and every remaining Ready
# item site-held satisfies STALLED's every conjunct, so the loop ended by telling
# the operator to resolve the gate and restart the drain on a checkout that never
# could. A site hold is neither self-resolving — this checkout will never satisfy
# it, so a confirmation clock would count forever — nor a human gate: nobody has
# to decide anything, the work is already dispatchable, somewhere else. DRAIN
# DEFERRED names the site and takes COMPLETE's stop path, cron self-cancel
# included.
#
# THE DISCRIMINATION IS THE WHOLE OF IT, and it is where a later "these are the
# same state" sweep does the damage. DEFERRED is STALLED plus ONE test — the held
# set holds NOTHING but site holds — so it must be evaluated FIRST or it is
# unreachable, and a held set carrying one dependency hold, one `blocked` label
# or one held PR is STALLED with the site holds listed among its reasons. Both
# directions are pinned, because both are harmful: a site-only set reported as
# STALLED sends the reader after a blocker that does not exist, and a genuine
# gate reported as a deferral hides one that does. DEGRADED cannot compete for
# the state at all — it requires in-flight non-zero and this one requires
# in-flight zero — so #286's "evaluated first" rule is untouched and needed no
# widening.
#
# NO CONFIRMATION TICK, DELIBERATELY, and that is the asymmetry a later "make the
# terminal states symmetric" sweep will flatten. STALLED and DEGRADED confirm
# across two ticks because what they read can change underneath them; a site
# declaration cannot change what this checkout IS, so a second tick re-reads the
# same labels against the same `execution_site` and reaches the same answer.
# COMPLETE takes no confirmation tick for the same reason, which is why DEFERRED
# is modelled on it rather than on the state it sits beside.
#
# AN ISOLATION-UNCONFIRMED STOP IS STALLED, NOT A FIFTH STATE (issue #452).
# dispatch-ready §5's isolation check (take-it's contract, re-derived every tick)
# can leave a tick with candidates it will not claim: on omp with isolation off
# (there is no serial mode; an unconfirmed tick stops). With nothing in flight that is #282's shape
# again - claim nothing, report the same sentence, never self-cancel. The
# decision, made by the route this header names (extend an existing state's
# conjunct rather than add one): those candidates are held by the check with the
# hold root `isolation unconfirmed`, so STALLED's third conjunct reads "every
# Ready item held by a §4 filter or by §5's isolation check" and nothing else in
# §7 moved. Not DEFERRED, whose conjunct 3 is a hold this checkout can NEVER
# clear (an operator can clear this one by committing a `.omp/config.yml`); not
# a fifth state, which would be STALLED under another noun with one more count
# site and canon entry to keep honest. The two-tick confirmation is wanted here,
# not tolerated: it keeps a transient probe failure from ending a healthy loop.
# The edit is one phrase in b027 below and in §7; §5's prose is where the rest
# lives and is pinned by scripts/test-isolation-contract.sh (property 14), since
# §5 is not read by this gate (limit 5).
#
# THE ENUMERATIONS THAT HAD TO MOVE WITH IT, since CLAUDE.md's rule — a count
# stated in prose is safe only when its members are enumerated beside it, or when
# a gate re-derives it — is what makes a fourth state cheap to add and expensive
# to add badly. §7's heading; its "exactly N states" sentence, whose number this
# gate re-derives from the `### DRAIN ` headings beside it; the stop path's own
# heading, which said "both terminal states" while already serving three; the
# cron self-cancel's per-state report lines; the safety rails' per-state clause;
# and §4's pointer at the state a site hold ends in — that last one belongs to
# `scripts/test-site-filter.sh` (row R30) and is deliberately NOT duplicated
# here, the two gates meeting at that sentence and neither transcribing it.
#
# DEFERRED'S FIRST CONJUNCT SPELLS STALLED'S OPENING WORDS VERBATIM, AND THAT
# COST TWO SEPARATE FIXES — the second of which a review had to find, because the
# first LOOKED like the whole of it. (a) #286's "COMPLETE's conjuncts are
# unchanged" and "STALLED's conjuncts are unchanged" both read `sec7_flat`, so
# the second could be satisfied by the NEW section while STALLED's own opening
# said anything at all; they now read `complete_flat` and `opening_flat`.
# (b) THE RESCOPE ALONE WAS NOT ENOUGH, and an earlier edition of this paragraph
# claimed it was. `opening_raw` was itself anchored on the phrase
# `In-flight zero AND dispatched zero`, and `raw_region` binds to the FIRST line
# in the FILE starting with its prefix — of which there are now two, DEFERRED's
# conjunct being the EARLIER, kept out of reach only by its `1. **` list marker.
# Measured, by two readers independently: hoist that conjunct into a bare
# paragraph AND rewrite STALLED's opening to `Ready non-empty AND in-flight zero
# AND …` — #282's bug back verbatim — and only the canon reddens, so a
# regenerated canon ships it at exit 0 with both `Ready non-empty` vetoes and the
# conjunct must-exist printing `ok` off the wrong paragraph. A window anchored on
# words a mutant may write ELSEWHERE is not a window. `opening_raw` is DERIVED
# now — the first block of the STALLED section, which no wording can move — and
# the phrase it used to bind on is asserted ABOUT that block instead. Single-edit
# mutants always reddened; it was the two-edit path that was silent, which is
# what a structural anchor removes rather than makes less likely.
#
# HOW THIS GATE IS BOUND, AND WHY IT IS BOUND IN THREE LAYERS. Its first edition
# asserted presence only, and a review measured meaning-inverting rewrites
# passing it at exit 0 — writing the bug back as `Ready **non-empty**`, which a
# plain flatten cannot see; appending a table row licensing a merge past a
# `blocked` issue; inverting the safety rails; and deleting assertion blocks
# under a floor that did not bind. Every one KEPT the sentence an assertion
# greps for and QUALIFIED it. The second edition pinned whole paragraphs by
# equality against canonical literals — and a second review defeated THAT by
# INSERTING A SIBLING PARAGRAPH beside a pinned one, writing #282's bug back
# four lines under the canon forbidding it. Equality bounds the paragraph it
# holds and says nothing about the one next to it. So:
#
#   LAYER 1, CANON — AND IT COVERS §7 WHOLE, FENCES INCLUDED. Every blank-line
#   block of §7 is compared for equality after flattening — prose, list blocks
#   and table blocks alike, so a bullet body and a table cell are as pinned as a
#   paragraph — and every FENCED block is compared too, with `#N` normalised so
#   renumbering a worked example still cannot redden the gate. The fences were
#   excluded once, on the theory that they were inert examples; they are not,
#   they are the text the loop PRINTS, and a parenthetical added inside the
#   DRAIN COMPLETE fence ("a blocked issue's open PR never vetoes this state")
#   was measured restoring #282 at exit 0 with markdownlint clean. The
#   hand-picked-subset approach that preceded all of this lost FIVE review
#   rounds in a row, each one finding another paragraph no key held that could
#   invert one a key did — including the API-failure rule a pinned paragraph
#   merely DELEGATES to. The subset was the defect, not the choice of subset.
#   LAYER 2, INVENTORY. The ordered list of block openers, list markers, table
#   rows and headings — for §7, and for §2, §6 and the top-level Guardrails
#   list, the three places outside §7 that can override a §7 decision.
#   Guardrails is not decorative here: it ALREADY restates a §7-adjacent rule,
#   so "hoist the terminal-state condition up there" has precedent in this very
#   file, and one bullet doing it was measured passing at exit 0. Bounds
#   INSERTION, DELETION and REORDERING. Its own first edition claimed to bound
#   "a new paragraph anywhere, whatever it says" and did not: a two-space NESTED
#   bullet, a row appended to the STOP-PATH table, a paragraph GLUED TO A
#   CLOSING FENCE and a line GLUED UNDER A HEADING were each measured writing
#   #282's bug back at exit 0. All four are covered now, which is why the claim
#   is worded from the measurement rather than from the intent.
#   LAYER 3, CONSUMPTION. Every key in `canon_table` must be consumed by exactly
#   one assertion, so deleting an assertion block fails even if its section
#   registration goes with it.
#
#   THE COST IS STATED, in the idiom test-review-gate-decisions.sh uses for its
#   own canonical literal: this pins WORDING and STRUCTURE, so a legitimate
#   reword or a new paragraph in §7 must be made in two places at once and
#   reddens CI until it is. That is a loud false red, which this repo prefers to
#   a gate that reports clean on an inverted source. `canon_table` is the one
#   place to edit, and re-deriving its inventory entries is mechanical.
#
#   "BYTE-IDENTICAL" WOULD OVERSTATE IT. The comparison runs after `flat()`, so
#   it is identity up to whitespace: a re-wrap passes, a reword does not. The
#   inventory keeps each opener's first words only, so it is identity up to
#   those. Both claims are stated that way here and in preflight's gate list,
#   because the weaker true claim is worth more than the stronger false one.
#
#   KNOWN LIMITS, stated rather than patched, and each one measured.
#   (1) §2's AND §4's REMAINING BULLETS, §6 AND GUARDRAILS ARE INVENTORIED,
#       NOT CONTENT-PINNED — both of the first two carry text-pinned
#       exceptions, enumerated below, so naming either one alone is what let
#       this limit's three copies disagree — the header named §4 while
#       preflight.sh and CLAUDE.md both named §2 (#290).
#       Rewriting the
#       BODY of an existing bullet or paragraph there — not merely appending a
#       sentence to it — changes no opener and no marker list, and was measured
#       inverting §7 from outside it ("the blocked-PR bullet is a reporting
#       convenience, not an input to §7" is enough). What IS pinned by text:
#       §7 and §3 wholesale (§3 being the file's only "in-flight is" sentence,
#       which §2, §4 and §7 all read), §2's five operative regions (the
#       blocked-PR enumeration, the board-path in-flight definition, the merge
#       hand-off, the ONE-redispatch budget and the CONFLICTING demotion), and
#       §4's Collision row plus the paragraph keeping a blocked PR inside it.
#       The rest is inventoried
#       because pinning sections this change did not write would redden on every
#       unrelated edit: that is the trade, stated, not an oversight.
#   (2) Deleting a section, its registry entry AND its canon entries together is
#       THREE coordinated edits on HEAD. It was measured at TWO while the
#       registry's own minimum sat inside `SECTIONS`, which is why
#       `REGISTRY_MIN` is held apart from that array now; the earlier "two to
#       three" reading describes the shape before that split.
#   (3) The canon and inventory values are regenerated by hand when §7
#       legitimately changes, and a regeneration that is not read is a rubber
#       stamp. This is the cost of pinning a whole section, and it is why a
#       failure names the block key and its first characters.
#   (4) A gate cannot verify its own guard from inside that guard. The derived
#       floor is the backstop under the registry block; there is no layer
#       beneath the floor.
#   (5) §3 and §4 are read now, but §5 is not, and no window reaches the config
#       block in §1. A rule hoisted into either could contradict §7 unseen —
#       the same shape Guardrails had until it was inventoried.
#   (6) Markdownlint remains load-bearing for a malformed table (MD055/MD056),
#       which this gate reads as content rather than as structure. Eight rules
#       are already disabled in `.markdownlint-cli2.jsonc`; disabling those
#       would remove a backstop nothing here replaces. The heading and fence
#       shapes it used to backstop are covered directly now.
#
# MUST-NOT-EXIST CHECKS RUN AGAINST TWO COPIES, flattened and emphasis-stripped.
# This repo hard-wraps, so a forbidden phrase routinely straddles a line break
# and a line-scoped grep reads it as absent — a FALSE PASS. Emphasis is the same
# defect one layer in: `Ready **non-empty**` is the same instruction as `Ready
# non-empty` and was measured passing the plain-flatten veto.
# `scripts/test-sentry-verification.sh`'s header records this repo paying for
# exactly that once already, on `**`sentry:`**`.
#   The stripping is applied to the HAYSTACK only, so the second arm is inert
#   whenever the PATTERN itself contains `*`, `_` or a backtick — which is
#   correct rather than a gap (a pattern that spells emphasis is asking about
#   emphasis), but it means "two copies" is true of the pattern's plain form
#   alone. No live veto here depends on that arm; every one of them binds
#   through the plain copy today.
#
# STRUCTURAL ASSERTIONS ARE WINDOW-SCOPED, NEVER FILE-WIDE. An earlier edition
# grepped the whole tracked file for COMPLETE's condition line, so the condition
# could be CANCELLED by a clause added inside COMPLETE's own section while the
# assertion stayed green. Every line-scoped check now runs against an already
# resolved window; every window is proved non-empty AND proved to stop where it
# claims to, including `sec7`, whose stop is a heading somebody may rename.
# TABLE-ROW PATTERNS ARE ANCHORED `^[[:space:]]*\|`, because a row indented by
# ONE SPACE renders identically, passes markdownlint, and was measured slipping
# past a `^\|` filter while licensing a merge past a `blocked` issue.
#
# EXAMPLE IDENTIFIERS ARE MATCHED BY SHAPE, not by literal. `PR #279 (#273)` is
# a worked example; renumbering it changes no decision, and a gate that reddens
# on it teaches the next author that this gate cries wolf. The exact-literal
# treatment is reserved for `canon_table`.
#
# THE VACUITY FLOOR IS A SECTION REGISTRY WITH PER-SECTION MINIMUMS. A bare
# number was measured not binding twice over: deleting five assertion blocks
# left 46 of the 80 assertions then running, under a floor of 45, and deleting
# 14 assertions from the largest section left the total higher still — both
# runs printed "all green". A THIRD measurement is why the prologue and this
# file's own registry block are declared members rather than preamble: their
# assertions used to run with `cur_sec` empty, so no minimum covered them, and
# deleting the entire window-STOP block — the one added after a review made
# `sec7` run silently to EOF — left the gate at exit 0.
# `SECTIONS` declares each section beside the count it must reach, which is the
# form CLAUDE.md sanctions for a count (members enumerated beside it), and
# `ASSERT_FLOOR` is DERIVED as their sum rather than transcribed. An earlier
# edition also compared the declared count to this file's own `section` call
# sites; that was a file-to-itself comparison of the kind this header rules out
# for the canon, one `sed` updated both sides, and it is gone.
#
# THE PREMISE IS ASSERTED, NOT ASSUMED, AND IT IS NOW TWO FACTS IN TWO WINDOWS.
# (a) `block` strips BOTH labels; if it ever stripped only `ready`, the blocked
# issue would stay in-flight, §2's branch query would find its PR, and this
# gate's whole account of the bug would be wrong while every prose assertion
# stayed green. (b) `block` REFUSES TO RUN WITHOUT `--comment`, and exits rather
# than warning, which is what the CONFLICTING bullet's promise that a human
# learns why actually rests on (#290). The two live in different places — (a) in
# the `block)` case, (b) in argument parsing ABOVE it — so they need two windows,
# and a reader who trims "redundant" windows on the strength of an account that
# names only the `block)` case deletes the assertion (b) is. A third fact is
# read from `skills/pr-shepherd/scripts/merge-shepherd.sh`: it refuses a
# `CONFLICTING` PR ahead of every other gate, which is the ONLY thing withholding
# that PR from the merger on the demotion tick, the hand-off bullet's own
# `blocked` predicate reading state not yet written.
#
# NO `-ef` PRECONDITION, deliberately, and what follows is the reasoning
# test-review-gate-decisions.sh's section 9 paid for rather than its conclusion.
# That gate needs the precondition because its subject is its OWN source, so a
# copy measures the wrong file. This gate's subjects are other tracked files,
# resolved against `git rev-parse --show-toplevel`, so running it from a copy
# still measures them — which is what a mutation harness wants. The mirror
# hazard is real and belongs to the HARNESS: mutate the tracked file in place
# and restore it. Mutating a tmpdir copy leaves every assertion here measuring
# the unmutated tracked file and every mutant reading `undetected` while proving
# nothing (the #262 lesson).
#
# No `| grep -q` pipelines anywhere: grep -q closes the pipe on its first match,
# the writer takes SIGPIPE, and pipefail promotes the 141 — turning a caught
# regression into a reported miss (the #172 shape, generalised by #256). Every
# string match here reads a herestring or a file directly.
#
# NO INVENTORY NUMBER IS TRANSCRIBED. The assertion count is PRINTED by the run;
# the section inventory is enumerated beside its own counts, which is the form
# CLAUDE.md sanctions. Each mutation battery lives in the PR that added the
# section it proves (issues #282, #290 and #342).
#
# Three tracked files. No gh, no network, no repo mutation.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-drain-terminal-states.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-drain-terminal-states: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SKILL="skills/dispatch-ready/SKILL.md"
CLAIM="skills/github-issues/scripts/issue-claim.sh"
# The third premise file (#290): the CONFLICTING bullet's account of the
# demotion tick rests on this script refusing a conflicted PR before any other
# gate. Read for that one fact, like CLAIM.
SHEPHERD="skills/pr-shepherd/scripts/merge-shepherd.sh"
OPENER_WORDS=6

fails=0
asserts=0
ok()  { asserts=$((asserts + 1)); echo "  ok    $1"; }
bad() { asserts=$((asserts + 1)); echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# --- the section registry ----------------------------------------------------
# `name:minimum`. Members enumerated beside their counts, which is the form
# CLAUDE.md sanctions; ASSERT_FLOOR is their SUM, derived below rather than
# transcribed. A section that never runs, or that runs fewer assertions than it
# declares, FAILS — which is what a bare numeric floor could not do (measured
# twice: a whole section deleted, and 14 assertions deleted from the largest).
SECTIONS=(windows:46 canon7:27 conjunct:7 enumeration:13 conflicting:17
          discriminator:17 nonempty:3 carveouts:2 complete:5 record:3
          stoppath:8 premise:7 degraded:21 deferred:26)
# The registry block's own minimum is deliberately NOT a member of SECTIONS.
# Measured: while it was one, deleting the block AND its entry shrank the floor
# by exactly what the deletion removed, so two edits retired layer 3 and every
# per-section minimum at exit 0. Held separately, deleting the block alone
# leaves the floor where it was and the run fails.
#
# An earlier note here claimed that deleting this LINE "makes `$REGISTRY_MIN`
# unset under `set -u`, which fails louder still". That was measured true on
# bash 5 and FALSE on /bin/bash 3.2 — the shell CLAUDE.md tells developers to
# run preflight on — where the unset expansion inside `$(( ))` aborted the
# script at exit 0 having run ZERO assertions, which a preflight-shaped wrapper
# reports as PASS. Both tokens are validated explicitly below for that reason,
# and the sentence is now what was measured rather than what was assumed.
REGISTRY_MIN=14
# EVERY token is validated before any arithmetic touches it. Measured on
# /bin/bash 3.2 — the shell CLAUDE.md tells developers to run preflight on —
# deleting one digit (`discriminator:17` -> `discriminator:`) aborted the `for`
# inside `$(( ))`, silently dropped every later summand, left the floor at 80
# instead of 120 and that section's own minimum void, and still exited 0 with
# `all green`. Deleting `REGISTRY_MIN` was worse: exit 0 with ZERO assertions
# run, which a preflight-shaped wrapper reports as PASS. `set -u` in arithmetic
# context does not behave the same on bash 3.2 and bash 5, so the header's old
# claim that an unset REGISTRY_MIN "fails louder still" was true on one and
# false on the other. This is the last layer; it validates rather than assumes.
SECTION_MIN_TOTAL=0
for _s in "${SECTIONS[@]}"; do
    case "$_s" in
        *:*) ;;
        *) echo "test-drain-terminal-states: SECTIONS member '$_s' has no ':' minimum" >&2; exit 1 ;;
    esac
    _min="${_s##*:}"
    case "$_min" in
        ''|*[!0-9]*) echo "test-drain-terminal-states: SECTIONS member '$_s' has a non-numeric minimum" >&2; exit 1 ;;
    esac
    SECTION_MIN_TOTAL=$((SECTION_MIN_TOTAL + _min))
done
case "${REGISTRY_MIN:-}" in
    ''|*[!0-9]*) echo "test-drain-terminal-states: REGISTRY_MIN must be a number" >&2; exit 1 ;;
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
note_consumed() { consumed="$consumed $1"; }

# --- assertion helpers -------------------------------------------------------
# assert_in <haystack> <ERE> <label>   — herestring, never a pipeline
assert_in() {
    if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3"; fi
}
# assert_wline <RAW window> <ERE> <label> — line-scoped, and the window is the
# whole point: file-wide was measured letting a rule be cancelled inside its own
# section while its assertion stayed green.
assert_wline() {
    # A flattened blob has no newline in it, and handing one here turns every
    # `^…$` anchor into a pattern that can never match — a silent pass for a
    # must-exist. The contract was a comment; now it is a check.
    if [ "${1#*$'\n'}" = "$1" ]; then
        bad "$3 — assert_wline was handed a single-line blob; pass a RAW window"
        return
    fi
    if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3"; fi
}
# assert_has <haystack> <FIXED string> <label> — for a literal carrying regex
# metacharacters; `(in-flight until actually MERGED, per §3)` is an ERE group.
assert_has() {
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3"; fi
}
# assert_absent <haystack> <ERE> <label> — MUST-NOT-EXIST, tested against the
# text AND an emphasis-stripped copy. See the header: `Ready **non-empty**` was
# measured slipping past the plain copy.
assert_absent() {
    local rc_plain rc_stripped
    grep -qE -- "$2" <<<"$1"; rc_plain=$?
    grep -qE -- "$2" <<<"$(emph_strip "$1")"; rc_stripped=$?
    # grep exits 2 on an INVALID pattern, and an `if grep … || grep …` reads
    # that as "not found" and prints ok — a must-not-exist check failing OPEN,
    # which is the one direction a veto must never fail. Measured:
    # `grep -qE 'Ready non(-empty'` against text containing `Ready non-empty`
    # returns 2. Branch on the status explicitly.
    if [ "$rc_plain" -ge 2 ] || [ "$rc_stripped" -ge 2 ]; then
        bad "$3 — the pattern is not a valid ERE, so this check measured nothing"
    elif [ "$rc_plain" -eq 0 ] || [ "$rc_stripped" -eq 0 ]; then
        bad "$3"
    else
        ok "$3"
    fi
}
# assert_eq <got> <want> <label>
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — got [$1]"; fi
}

echo "dispatch-ready section 7 terminal states (issue #282)"

# The prologue is a REGISTRY MEMBER, not an unfloored preamble. Measured: its
# assertions ran while `cur_sec` was empty, so no per-section minimum covered
# them and deleting the whole window-stop block left the gate at exit 0 — the
# very block added after a review made `sec7` run silently to EOF.
section windows "every window resolves, and stops where it claims to"

for f in "$SKILL" "$CLAIM" "$SHEPHERD"; do
    if [ -r "$f" ]; then ok "read $f"; else bad "missing file: $f"; fi
done
[ "$fails" -eq 0 ] || { echo "test-drain-terminal-states: FAILED ($fails)" >&2; exit 1; }

# raw_region <file> <start prefix> <stop prefix> — from the first line STARTING
# WITH start (inclusive) to the line before the next line starting with stop; an
# empty stop means "the next blank line". The start line is consumed with
# `next`, so a start that also matches its own stop — every heading region here
# does — cannot terminate itself on line one.
#
# LITERAL PREFIXES, NEVER REGEXES, and that is not a style choice: awk expands
# backslash escapes inside a `-v` assignment, so `\*\*Self-resolving` arrives as
# `**Self-resolving` and the leading `*` is a quantifier with nothing to repeat.
# Measured — both carve-out windows came back EMPTY, which their non-empty
# guards caught. A pattern that silently matched something ELSE would not have
# been caught, which is why the anchors are index() comparisons.
raw_region() {
    awk -v s="$2" -v stop="$3" '
        !f && index($0, s) == 1 { f = 1; print; next }
        f && stop == "" && $0 == "" { exit }
        f && stop != "" && index($0, stop) == 1 { exit }
        f { print }' "$1"
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

# first_block <section text> — the first blank-line-delimited block after the
# section's own heading line. STRUCTURAL, and that is the whole point: an anchor
# made of words can be aimed at a different paragraph by writing those words
# somewhere earlier, which is exactly what DEFERRED's first conjunct does to
# STALLED's opening. See the header's (b).
first_block() {
    awk 'NR == 1 && /^#+ / { next }
         /^[[:space:]]*$/ { if (started) exit; next }
         { started = 1; print }' <<<"$1"
}

# openers <text> — the first OPENER_WORDS words of each blank-line-delimited
# block opener, joined by ` ~ `. Fenced blocks collapse to their opening fence.
# WORDS, not characters: awk under LC_ALL=C counts BYTES while the canon was
# generated counting CHARACTERS, and `§` is two bytes — measured, the two
# disagreed on every line carrying one. Words also survive a re-wrap, which
# changes where a line ENDS, not the words it starts with.
# This is layer 2: an inserted paragraph changes the list whatever it says.
openers() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                printf "%s%s", (c++ ? " ~ " : ""), s }
        BEGIN { prev = 1 }
        # BOTH delimiters are emitted: the closing one used to be skipped, so
        # text appended to it was invisible to every inventory — measured with
        # the header'"'"'s own named attack on the DRAIN COMPLETE fence.
        /^[ \t]*```/ { emit()
                       if (!fence) { fence = 1; prev = 0 } else { fence = 0; prev = 1 }
                       next }
        fence { next }
        $0 == "" { prev = 1; next }
        { if (prev) emit()
          # A HEADING closes the block it opens, so the NEXT line starts a new
          # one — the identical root cause fixed for closing fences above, and
          # measured: a line glued under `### DRAIN STALLED` was invisible to
          # all four inventories, caught only by markdownlint MD022.
          prev = ($0 ~ /^#+ /) }' <<<"$1"
}
# bullet_openers <text> — same idea for top-level bullets, which an opener list
# cannot see: bullets in one list are adjacent, so an inserted one adds no block.
bullet_openers() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s, ind) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                ind = match($0, /[^ \t]/) - 1
                                printf "%s%d:%s", (c++ ? " ~ " : ""), ind, s }
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^[ \t]*[-*+] / { emit() }' <<<"$1"
}
# table_rows <text> — the same idea for table rows, in EVERY table in the
# window. The `^[[:space:]]*\|` anchoring lesson had been applied to the
# discriminator table and to nothing else, so a row appended to §7's stop-path
# table — "Announce and finish — do not cancel" — was measured invisible.
#
# THE PATTERN IS INLINE IN EACH OF THESE, NEVER PASSED THROUGH `-v`: awk expands
# escapes in a `-v` assignment, so `\|` arrives as a bare `|` and the ERE becomes
# an alternation with an empty branch. Measured — a shared helper taking the
# pattern that way emitted nothing at all, and its canon comparison failed
# loudly rather than passing, which is the only reason it was cheap. Same trap
# as raw_region's, one layer over; the duplication here is the fix.
table_rows() {
    awk -v n="$OPENER_WORDS" '
        function emit(  i, s, ind) { s = ""
                                for (i = 1; i <= n && i <= NF; i++) s = s (i > 1 ? " " : "") $i
                                ind = match($0, /[^ \t]/) - 1
                                printf "%s%d:%s", (c++ ? " ~ " : ""), ind, s }
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^[ \t]*\|/ { emit() }' <<<"$1"
}
# section_blocks <text> — one flattened block per line, fences EXCLUDED.
# Mirrors the generator's blocks(): strip each line, join with one space,
# collapse runs, trim. Fences are excluded so renumbering a worked example
# cannot redden the gate; their shape is asserted separately.
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
# numbers normalised to `#N`.
#
# The fences are not inert worked examples: they are the text the loop PRINTS
# and acts on. Excluding them from the canon AND from every inventory left them
# writable — measured, a parenthetical added inside the DRAIN COMPLETE fence
# ("a blocked issue's open PR never vetoes this state — announce COMPLETE") left
# the gate at exit 0 and markdownlint clean, restoring #282 four lines under the
# block that forbids it. Numbers are normalised so renumbering a worked example
# still cannot redden the gate, which is why the exclusion existed at all.
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
# heading_list <text> — every heading line, joined. A third terminal state added
# as a `###` subsection changes this while "exactly two states" still reads true.
# `^#+ ` and not `^#`: a wrapped line beginning `#282 changed is only where …` is
# not a heading, and an earlier canon baked exactly that in as one — caught by
# markdownlint's MD018, which is the only reason it did not become the shape the
# inventory defends.
heading_list() {
    # Fence-aware like its three siblings: the first ```bash block whose opening
    # line is a `#` comment would otherwise redden `sec7_headings` and point the
    # next author at a third terminal state that does not exist.
    awk '
        /^[ \t]*```/ { fence = !fence; next }
        !fence && /^#+ / { printf "%s%s", (c++ ? " ~ " : ""), $0 }' <<<"$1"
}

# --- the canon ---------------------------------------------------------------
# The decision surface AND the structure, held HERE rather than derived from the
# file under test. A quoted heredoc, so nothing expands and no quote needs
# escaping; key and value are TAB-separated. This is the ONE place to edit when
# §7 legitimately changes — see the cost note in the header.
canon_table() {
    cat <<'CANON'
blocked_prs	- **Open PRs on blocked issues** → resolve these too, and hand them to nobody. **With `board:`** the blocked set is the board's items carrying the `blocked` label, **plus any `blocked`-labelled issue the board does not carry at all** — `issue-claim.sh block` writes labels and never cards, so an issue blocked by hand, archived, or past the board query's own limit is on no card. Read that second half with `gh issue list --repo "$REPO" --state open --label blocked --limit 200 --json number`; without a named command this half is an instruction nobody can execute, and it is the half #282's own state consists of. Take the union: an issue the board cannot see is precisely the one whose PR would otherwise veto nothing and never reach the held set. **Without a board** it is `blocked[]` from the snapshot above. Both paths, like every other rule in this section and in §4 — a bullet written for one path only is invisible on the other, and the half it omits is the half that goes dark. `issue-claim.sh block` strips `in-progress`, so a blocked issue is not in-flight and the branch query above cannot see its PR at all; `gh issue view <N> --repo "$REPO" --json closedByPullRequestsReferences` names it (an OPEN entry only), the same lookup §4 already sanctions. **Known limit — and it bites hardest exactly here:** that field sees only PRs carrying a closing keyword, and this population (a redispatch PR, one opened by hand) is the likeliest to lack one, so fall back to the `*/issue-N-*` branch and never read an empty result as "no PR" — an unenumerated PR is silent and terminal. **Bounded** like §4's sibling lookup, and stated honestly: up to TWO calls per blocked issue per tick where the branch fallback is needed; the snapshot's `--limit` bounds the boardless path, and the board path is bounded by the board query's own limit plus the `--limit` on the label query named above. The set grows monotonically — nothing removes `blocked` but a human, and `promote` never does — so a repo that accumulates blocked issues pays for all of them every tick; if that cost ever bites under `/loop`, it degrades into "live state could not be verified", which is this fix's own failure mode wearing the bug's face. This loop may not advance these PRs, so they are never handed to `sassy-dog:pr-shepherd` — they are read so **§7 can see them**. A human-gated PR that nobody enumerated is not a smaller version of the §7 gap, it is a worse one: it leaves §7's held set empty, and an empty held set admits DRAIN COMPLETE, so the loop self-cancels with the PR still open (#282).
board_inflight	**With `board:`** — the board snapshot is the source of truth: cards in **In progress** / **In review** with assignee @me **and not carrying `blocked`**, per §3's definition, are in-flight. `board-snapshot.sh` returns `labels` per item, so the exclusion is computable here; where it is not — a snapshot with no labels — treat the issue as blocked rather than as in-flight, since failing the other way fails open into the bug the exclusion exists to prevent.
handoff_bullet	- **Open PRs from those branches** → delegate to `sassy-dog:pr-shepherd`: mergeable check, merge greens per the configured merge policy, tear down worktrees for merged PRs, reconcile the local default branch. **Hand it only the PRs the review bullets below have cleared, and never one whose issue carries `blocked`** — a human's demotion is not a merge instruction, and §4's `blocked` filter governs Ready SELECTION rather than this hand-off, so it does not cover this. A PR whose review reported `NO REPORT` or `SKIPPED`, or carries a Blocking finding, is withheld from this hand-off, on either `review_site` — with one carve-out, `review_agent: skip`, whose every run legitimately reports `SKIPPED`, so holding on it would turn the documented opt-out into a blanket merge freeze. `take-it` draws the same line for the same reason. **A PR body reading `review: deferred to coordinator` is withheld too, until a review outcome replaces it.** On `review_site: coordinator` that outcome comes from the not-yet-reviewed bullet below. On `agent` nothing will ever review it, so it stays held, exactly as a `SKIPPED` would be — which is also what keeps a PR in flight safe when a repo switches from `coordinator` to `agent`. `take-it` splits `review=deferred` the same way. This exception is stated here rather than three bullets down because this is the bullet that merges: a corrective a reader reaches only after the merge has been ordered is a corrective that never runs. **How a tick learns the outcome: read the PR body**, where take-it's step 6 requires the sub-agent to have written the verbatim line — this loop reads no RESULT lines, and a later tick is a different session from the one that dispatched. **Keep the issue → open-PR mapping this step produces** — §4's Collision filter reads those PRs' actual changed files, and re-deriving the mapping there costs a second round of lookups.
redispatch_bullet	- **Failed or red PRs** → surface in the tick report with the failing check named, and comment `dispatch-ready: attempt 1 failed — <check>: <one-line cause>` on the issue. ONE redispatch with the failure context appended is allowed on a later tick. A second failure demotes to blocked — via the board plus a `blocked` label, or `issue-claim.sh block N --comment "dispatch-ready: 2 failed attempts — <cause>"` — and a human decides next. **Never park failures in Ready**: Ready must stay synonymous with dispatchable. When scheduling that first retry, persist `recovery_used=1 recovery=pending` in the same verified attempt comment and mirror it in the PR body **before this tick ends**, not on the later dispatch tick. A failed reservation write holds this scheduling attempt; it never turns an unrecorded retry into spent legacy history or permits an unaccounted dispatch.
conflicting_bullet	- **`CONFLICTING` PRs** → never auto-rebase; **demote on sight.** Surface it in the tick report naming the PR *and the conflict*: §6's `holds:` line classifies by §7's table, which answers row 1 (`blocked`) once this bullet has written, so the word `CONFLICTING` reaches the operator only if this bullet puts it there. Demote the issue in the same tick — via the board plus a `blocked` label, or `issue-claim.sh block N --comment "dispatch-ready: PR #<pr> is CONFLICTING — needs a rebase this loop may not perform, then clear the blocked label to resume the drain"`, that subcommand requiring a comment — so a human resolves the conflict. Name the label in it: `promote` never strips `blocked`, so a rebase alone no longer returns the issue to the queue. **Demote ONCE**: skip an issue that already carries `blocked` and write nothing, leaving it to the blocked-PR bullet above. That is an idempotency predicate, not an attempt counter — it asks whether the demotion has been *written*, never how many times the PR has failed — and without it this bullet re-fires every tick against a PR that stays `CONFLICTING` until a human rebases, posting a fresh comment each time, since `issue-claim.sh` makes the label edits idempotent and the comment not. The Guardrails' **idempotent ticks** rule forbids exactly that. **If the demotion write fails**, say so in the tick report and treat the issue as still in-flight this tick: a tick that believes it demoted and did not is #282 again wearing this fix. **Read that from live state, never from the exit code alone** — `issue-claim.sh` reports `ok` and exits 0 when the label edit lands and only the *comment* fails, saying so on stderr, so a demotion can be real while the reason nobody posted is not. `Demote ONCE` then never retries it, which is the trade: re-comment nothing, and report the missing reason instead. **No redispatch, and no attempt counter** — this is deliberately NOT the shape the failed-check bullet above has, and aligning the two is the tidy to refuse: a sub-agent sent to rebase the branch IS this loop advancing that PR, which §7's discriminator table forbids for `CONFLICTING` in as many words, so that option costs a §7 row as well and re-opens a decision already settled there. `take-it` keeps the bare surface-and-hold form for the mirror-image reason and must not be aligned to this one: it is a bounded batch with no §7 and no forever-tick, so a hold there ends when the batch does. **A bare surface-and-hold is what this replaces, and it was the defect**: nothing cleared the claim, so the issue stayed `in-progress`, in-flight never reached zero, and with COMPLETE vetoed by the open PR and STALLED forbidden by in-flight, the loop ticked forever — #282's class one bullet over, and not covered by it (#290). No other route reaches a demotion either: a conflicted PR stops CI firing at all, `sassy-dog:pr-shepherd` recording that `no checks reported` reads identically to `CI hasn't started`, so the failed-check bullet's counter never starts. **A stacked upper layer demotes like any other**, and that cost is accepted rather than carved out: a layer goes `CONFLICTING` the moment the layer below squash-merges, which `sassy-dog:pr-shepherd`'s stacked-PR reference calls the expected shape rather than a fault — but this loop may not rebase it either, so it is a human gate like the rest. Say which it is in the comment. **The demotion changes which §7 row matches, never whether the PR is enumerated** — the first bullet above already resolved it from the in-flight branch this tick, and both rows answer held, `CONFLICTING` (row 2) before and `blocked` (row 1) after — so COMPLETE stays vetoed and the held set stays non-empty across the write. **Carry that PR into §4's collision sources and the migration slot for this tick**, from the issue → open-PR mapping the first bullet already keeps: §4 draws its blocked half from the blocked-PR bullet's enumeration, taken *before* this write, so a PR demoted here sits in neither half until the next tick — while §3 frees its slot in this one, which is exactly the state where §4 would dispatch a Ready issue into a still-open human-gated PR. From the next tick on the blocked-PR bullet enumerates it and the hand-off bullet's own `blocked` predicate withholds it from `sassy-dog:pr-shepherd`; on the demotion tick that predicate reads state not yet written, and what withholds it instead is `merge-shepherd.sh` refusing a `CONFLICTING` PR ahead of every other check. **Never park it back in Ready**: Ready must stay synonymous with dispatchable.
collision_row	| Collision | Skip if the issue's `touches:` set intersects the **effective file set** of anything §2 resolved a PR for — in-flight issues **and blocked issues with an open PR** — same repo-relative path, or a glob on one side matching a path on the other. The effective set is the in-flight issue's open PR's *actual changed files* where it has a PR, and its declared `touches:` where it does not (next section). Defer to a later tick; re-eligible once the overlapping issue merges. An issue with **no** `touches:` line intersects nothing, but is flagged `unannotated` in the tick report so the coupling gap is visible rather than silently risky. **Exempt: overlap between members of the same stack** (below). |
collision_blocked	**A blocked issue's open PR counts here even though it is not in-flight.** §3 excludes it from in-flight so the terminal states can be reached; that exclusion must not also remove its files from this filter, or the loop dispatches a Ready issue straight into a still-open human-gated PR — the class §4's own 2026-08-24 incident records. §2 resolved that PR one bullet above; reuse it. The same applies to the migration slot below: a blocked migration PR still holds it.
b001	## 7. Terminal states — drain complete, drain deferred, drain stalled, drain degraded
b002	A drain loop ends itself in exactly four states. All must be **confirmed from live GitHub state read this tick** — the §2 reconcile plus the §4 read, never a stale or transient one. If live state could not be verified this tick — an API failure mid-tick — the tick proves nothing: leave the loop alone, write no stall or degraded record, and let the next tick re-check.
b003	### DRAIN DEGRADED
b004	**Evaluated BEFORE COMPLETE and STALLED, and that order is the rule rather than a presentation choice.** §7 already refuses to act on a tick whose live state could not be verified — *the tick proves nothing*. A degraded platform is that same condition arriving **without an error**: the reads succeed, return incomplete data, and COMPLETE and STALLED consume them as fact. Measured 2026-08-26 — PR #283's required `ci` never fired during an outage, two consecutive ticks reported the state accurately and did nothing, and the coordinator then proposed closing and reopening the PR, which during an outage could leave it worse than doing nothing. Evaluating this state after COMPLETE or STALLED lets a degraded read produce a confident terminal verdict first.
b005	This state **consumes** `pr-shepherd`'s probe and never re-derives platform health itself:
b006	Run it against **ONE** in-flight PR, not each: the verdict is about the platform, not the PR, and a per-PR fan-out multiplies calls into a service already struggling.
b007	Three conjuncts, and each excludes a normal state the loop already handles:
b008	1. **In-flight is non-zero and nothing moved this tick** — no dispatch, no merge, no tracked PR changing state. In-flight zero belongs to COMPLETE, DEFERRED and STALLED; this state exists for the case none of them can see, where work EXISTS and cannot progress. 2. **Nothing this loop is permitted to advance** — §2's discriminator, reused and unchanged. A **red** check is a failure with its own redispatch path, so the loop still has an action and this conjunct is false. A **pending** check that is genuinely queued is the loop waiting, not the loop stuck. An active **foreign** claim resolves without a human. 3. **The probe returns a `degraded` verdict** — `degraded (attributed)` or `degraded (unattributed)`, and nothing else. **`unknown` is NOT degraded**, and it is the one a later *these both mean trouble* sweep will fold in: `unknown` means the probe could not measure, which is precisely the state that must not stop a loop. `healthy` is not degraded either — if the platform is fine and work is stuck, that is STALLED's question or a real defect, and stopping the loop would hide it.
b009	**Report WHY an `unknown` could not measure, and treat a probe that says nothing as one.** On an `unknown` whose `self_measured` is `not_measured`, the probe's `explains` field carries the reason and the first-party detail behind it — including its own `PLATFORM_GH_TIMEOUT` bound firing, which is the single most useful fact this loop can print during the outage this state exists for, and which the bare verdict flattens into the same sentence as "no `--pr` was given". So render the reason, not the word: `probe: unknown — not measured: pr_read_failed; gh pr view 305 exited 124 — the PLATFORM_GH_TIMEOUT bound fired`. The OTHER `unknown` — a clean first-party read beside a status page that could not be read — carries no such tail, and its cause is in `status_page_detail` instead; report that field there rather than an empty reason. A run that returns **no stdout at all** — killed by a tool timeout before it could emit, or exiting non-zero on a usage error such as a missing `jq` — is `unknown` by the same rule and is reported as `probe: no verdict — exit <rc>: <first stderr line>`, because "the harness killed it" and "this VM has no `jq`" are different problems and the exit code is what separates them. None of these forms is `degraded`, none stops the loop, and none is `healthy`: a probe that did not speak is not a platform that is fine.
b010	**Two-tick confirmation, the same shape as STALLED and for the same reason**: a flaky call is not an outage. The record is `.git/dispatch-ready-degraded.json` — its **own** file, not the stall record. They answer different questions, a tick can legitimately be mid-confirmation on neither, one, or both, and sharing one file would let either confirmation clear the other's clock.
b011	- **No record** → write this tick's verdict and finish normally, appending to the tick report: `degraded: suspected — <verdict>; a second degraded tick ends the loop`. - **Record present** → DEGRADED is confirmed. Delete the record and announce loudly:
b012	Then take the **same stop path as DRAIN COMPLETE** below — one path, never a parallel one.
b013	Any tick that dispatches, merges, or reads a `healthy` verdict deletes a leftover `.git/dispatch-ready-degraded.json`: recovery resets the confirmation clock exactly as progress resets the stall clock. An `unknown` verdict **leaves the record alone** — it is neither progress nor degradation, and clearing on it would let one unreadable status page reset a genuine two-tick outage count indefinitely. A `no verdict` run leaves it alone for the same reason — it is an `unknown` that could not even say so.
b014	### DRAIN COMPLETE
b015	Ready empty AND in-flight zero AND nothing still claimed AND **no open PR this loop tracks** → announce loudly and take the stop path below immediately — an empty queue needs no confirmation tick. **"Nothing still claimed" means no in-flight issue per §3 and no active FOREIGN claim** — an item §4's Claimed filter skipped because another session holds it. It is not implied by in-flight zero, which counts `mine: true` only. It deliberately does NOT mean "no assignee anywhere": `issue-claim.sh block` leaves the assignee on purpose and only `promote` clears it, so a blocked issue's leftover assignee is residue rather than a claim — reading it as one would make COMPLETE unreachable on any repo that has ever blocked an issue, which is this bug wearing the other face:
b016	**COMPLETE is unchanged, veto included** — the fourth conjunct above IS the veto, stated where the instruction is rather than three paragraphs below it. An open PR this loop tracks still means the drain is not complete, in-flight until actually MERGED per §3, exactly as the safety rails restate it. A veto a reader reaches only after "announce loudly and take the stop path immediately" is the corrective §2 warns about: one that never runs. In #282's own state both of the old conjuncts were true, so the rule as written told the loop to self-cancel. What #282 changed is only where that veto leads. A PR this loop may not advance used to veto COMPLETE and reach no other state either; it now joins STALLED's held set, and the veto ranges over exactly the set that held set is drawn from.
b017	### DRAIN DEFERRED
b018	**Evaluated BEFORE STALLED, and the order is the rule rather than a presentation choice.** Every conjunct STALLED tests is satisfied here too — in-flight zero, nothing this loop may advance, a non-empty held set — so this state is STALLED plus one further test, and evaluating STALLED first leaves it unreachable. DEGRADED cannot compete for it: that state requires in-flight non-zero and this one requires in-flight zero, so the two are disjoint by construction and the order between them decides nothing.
b019	Four conjuncts, and the fourth is the one that separates this state from STALLED:
b020	1. **In-flight zero AND dispatched zero this tick** — STALLED's own first two, unchanged. 2. **Ready is non-empty.** An empty Ready column is never this state — COMPLETE when nothing is held, STALLED when something is. 3. **Every remaining Ready item is held by §4's Site filter** — its `sites` is non-empty and does not contain this checkout's `execution_site`. 4. **The held set holds nothing else.** No held PR, no dependency hold, no `blocked` label, no collision or migration hold. One hold of any other kind and the state is STALLED, with the site holds listed among its reasons. **An active foreign claim is not such a hold** — it is another session's in-flight, it resolves when that session merges, and STALLED's own carve-out already keeps the loop alive on it, so a tick holding one reaches no terminal state at all, this one included.
b021	**Conjunct 4 speaks of the holds this tick RECORDED, never of every hold an item might carry.** §4's filters run in order and each one skips, so a site-mismatched item never reaches the Dependencies or Collision rows and its own dependency hold is never recorded. That is the right answer for this checkout — it could not take the item on either ground — and it is why the promise below is that the item becomes dispatchable again on the checkout it names, never that it merges there.
b022	**A site hold is neither self-resolving nor a human gate for THIS loop, which is why it is a state of its own rather than a STALLED variant.** It is not self-resolving: this checkout will never satisfy it, so a confirmation clock would count forever. It is not a human gate either — nobody has to decide anything, and the issue is already dispatchable, from a machine that is not this one. So reporting it as STALLED is not merely imprecise: it sends the reader hunting for a blocker that does not exist, and then tells them to resolve the gate and restart the drain on a checkout that cannot. **Never report this state as STALLED.**
b023	**No confirmation tick, exactly as COMPLETE takes none.** STALLED and DEGRADED confirm across two ticks because what they read can change underneath them — a racing session closes a dependency, a flaky call clears. A site declaration cannot change what this checkout IS: a second tick re-reads the same `sites` against the same `execution_site` and reaches the same answer. Write no stall record and no degraded record from here — both clocks belong to states that are still moving.
b024	Announce loudly, naming the site each remaining item requires — **all** of an item's `sites` when it declares more than one, so the operator can see which checkout to run the drain from:
b025	Then take the **same stop path as DRAIN COMPLETE** below — one path, never a parallel one, and the cron self-cancel is not optional on it. Nothing here is a failure and nothing needs undoing: no redispatch budget is spent, no issue is demoted, and every deferred item is dispatchable again the moment the checkout it names ticks — subject there to the §4 filters this tick never reached.
b026	### DRAIN STALLED
b027	In-flight zero AND dispatched zero this tick AND **nothing this loop is permitted to advance**, over a **non-empty** held set — every Ready item held by a §4 filter or by §5's isolation check, and every open PR held by the discriminator below. All four conjuncts are stated here rather than corrected further down, for the reason COMPLETE's condition now states all of its own. Nothing this loop controls can change GitHub state before the next tick: no PRs it may merge, no agents working, and dependency holds only resolve when a dep closes — with nothing in flight, only external or human action closes one. The loop is stalled, not idle; "Ready isn't empty" alone must never keep it alive.
b028	**The third conjunct is "nothing to advance", and it replaced "Ready non-empty"** — that difference is the whole of #282. Ready empty, in-flight zero and an open unmerged PR was covered by NEITHER terminal state: COMPLETE is vetoed by the open PR, and STALLED could not fire on an empty queue. The loop ticked forever, reporting the state accurately and doing nothing (observed 2026-08-26 on #273 / PR #279; cancelled by hand). The action that creates the state is the action that hides it — `issue-claim.sh block` strips `ready` and `in-progress` together, so recording "a human must decide this" is precisely what removes the issue from the one set the old conjunct consulted.
b029	**Deleting that conjunct outright would have been the wrong fix**, and re-deriving it that way is the tempting simplification here: an open PR is not automatically a human gate. One whose checks are still running or red can advance on its own, and firing STALLED there cancels a loop that was about to make progress.
b030	**The held set must be non-empty.** Nothing held, nothing in flight and no open PR is COMPLETE, which fires first and needs no confirmation tick. "Nothing to advance" satisfied vacuously — by a queue that simply finished — must never announce STALLED.
b031	**A held set of nothing but site holds is DEFERRED, not STALLED**, and that state is evaluated first. STALLED's conjuncts match it exactly, so the discrimination is one extra test rather than a different one: does the held set contain anything a human could clear? A dependency hold, a `blocked` label, a held PR, a collision or migration hold, an `isolation unconfirmed` hold — any one of them and this is STALLED, with the site holds listed among its reasons. Nothing but site holds, and the loop is on the wrong machine rather than blocked, which is a different sentence to print and a different thing to do about it.
b032	#### The discriminator — may this loop advance it?
b033	**"Every open PR this tick sees" is the union §2 resolves** — open PRs on in-flight branches, and open PRs on blocked issues. Both halves are load-bearing: a PR nobody enumerated cannot be held, and the second half is precisely the one #282's own state consists of. Their state comes from `sassy-dog:pr-shepherd`'s `poll-prs.sh --once <PR>…`, which returns `mergeable`, `mergeStateStatus` and the check counts in one pass; the judgement below stays here, the way §4 keeps its intersection judgement while borrowing `gh pr view`. **Both halves of that invocation are load-bearing.** Without `--once` it is watch mode, which blocks for up to an hour — the "a tick that waits is a loop that stopped" rule two sections up. Without the explicit PR numbers `--once` falls back to whatever fifty open PRs `gh pr list` returns first — no sort is specified, so a long-lived held PR, which is exactly #282's shape, is as likely to fall outside the fifty as inside. That is both the widening the paragraph above forbids and a silently truncated read of it.
b034	**That union is also the set COMPLETE's veto ranges over, and the identity is the invariant.** A PR that can veto COMPLETE but can never enter the held set gives Ready empty, in-flight zero and a held set that is empty — COMPLETE vetoed, STALLED forbidden, ticking forever. That is #282 exactly, one shape over, and it is what an unqualified "any open PR vetoes COMPLETE" reading produces the moment a Dependabot PR, a hand-opened PR with no issue, or another session's PR is sitting there. So the veto is scoped to this union and never to every open PR in the repo. Widen one half without the other and the forever-tick comes back; narrow one without the other and the loop self-cancels on work it is still holding.
b035	**The blocked half is deliberately REPO-WIDE, and that is a decision rather than an oversight.** `queue-snapshot.sh` returns blocked issues as bare numbers — open, `blocked`-labelled, no assignee and no labels — so a tick genuinely cannot tell an issue this loop demoted from one a human blocked by hand, and `issue-claim.sh block` leaves the assignee rather than clearing it. Rather than filter on a signal neither section can read, take them all: over-including ends the loop LOUDLY, naming the PR and the gate holding it, and a human who disagrees restarts the drain. Under-including is the failure this whole section exists to close. The exclusion that matters is untouched — a Dependabot PR, or a hand-opened PR whose issue is neither in-flight nor blocked, is in neither half of the union and vetoes nothing.
b036	Ask it of every one of them, take the **first matching row**, and carry the answer per PR into the held set:
b037	| Open PR this tick | May this loop advance it? | Effect | | --- | --- | --- | | Its issue carries `blocked` | **No** — §2 already routed it to a human | held: joins the held set | | `CONFLICTING` | **No** — §2 never auto-rebases; a human resolves the conflict | held: joins the held set | | Held by a §2 review outcome — a Blocking finding, a `NO REPORT`, a held `SKIPPED`, or a `deferred` no review has replaced — with its ONE §2 redispatch spent | **No** — never merged past, and nothing left to redispatch | held: joins the held set | | Checks still running, and not `CONFLICTING` | **Yes** — a later tick merges it once it goes green | keeps the loop alive | | Checks red, its issue not `blocked`, and its ONE §2 redispatch unspent | **Yes** — that redispatch is still available | keeps the loop alive | | Anything else this loop is not permitted to merge this tick | **No** — held is the default | held: joins the held set |
b038	**Rows 2 to 6 cannot fire at the moment STALLED is decided, and that is by construction rather than by accident.** STALLED's first conjunct is in-flight zero, which empties the branch half of the union — so every PR still enumerable carries `blocked`, and row 1 matches it first. The argument is exhaustive over the union, so it reaches the default row too: at that instant nothing falls through to it. This is the same shape as the self-resolving carve-out below, and it is stated for the same reason: a reader who works it out later will otherwise read the rows below row 1 as live guarantees, or delete them as dead prose. They are neither. They classify held-versus-advanceable for the two OTHER consumers of this table — §6's `holds:` line, which renders on every tick including ticks with work in flight, and the safety rails' "an open PR this loop may still advance" — and they are what stops a later widening of §2's enumeration from silently answering "alive" for a shape nobody classified. Delete them and that widening becomes a silent #282; treat them as reachable at STALLED time and the reasoning above them is wrong.
b039	**The last row is a default, not a catch-all to delete.** §2 holds a PR for more reasons than the rows above enumerate and will not stay exhaustive, and a table that silently answers "alive" for a shape it does not know re-creates #282 one shape at a time. Held is the right default *here* because it is the answer §2 already gives: a PR this loop may not merge is a PR it cannot advance. The two defaults are not mirror images: held ends the loop and names the PR wherever it fires, alive ticks forever and reports nothing. (Which of them fires at STALLED-decision time is a separate question, answered by the paragraph above — there, row 1 has already matched.)
b040	**`CONFLICTING` needs its own row, above the checks rows, and the ordering is the point.** A conflicted PR stops CI firing at all, and `no checks reported` is indistinguishable from `CI hasn't started` — `sassy-dog:pr-shepherd` records exactly that. Without the row a conflicted PR matches "checks still running" and is answered with something that can never happen: §6's `holds:` line would report it as advancing on every tick, and the rails would read it as a PR this loop may still advance. It is NOT what lets a stalled queue confirm — at STALLED-decision time the paragraph above applies and row 1 has already matched — and saying so here would contradict it.
b041	**The redispatch budget is the hinge on both failure rows**, so read this before "simplifying" the rows into fewer. §2 grants exactly ONE redispatch per issue, taken on a later tick; while it is unspent this loop still has an action of its own, and a state it can still act on is not a stall. Once it is spent §2 demotes to `blocked`, which is why the label is the usual way a held PR presents — and why the review-outcome row is not redundant beside it: the label is a write this loop performs, the finding is a fact it reads, and a demotion not yet written must never read as advanceable. It is also why the red-checks row asks for the budget and not for the label alone: an unspent budget is what makes a red PR advanceable, while a spent one whose demotion has not been written yet matches no row above and falls to the default. Unknown is not clear.
b042	**Read the review outcome from the PR body**, exactly as §2 reads it — take-it's step 6 requires the sub-agent to have written the verbatim line. This loop reads no RESULT lines, and a later tick is a different session from the one that dispatched. **Read the redispatch budget from the issue** and reconcile it with the PR body's `recovery_used` per §2, never from this tick's memory. The `dispatch-ready: attempt 1 failed — <cause>` comment reserves the shared allowance; only its explicit pending/not-started reservation can advance once. Started/finished recovery, agent-spent recovery, or uncertain legacy history is not a new allowance. No comment alone does not prove unspent: inspect the PR handoff and prior failure/recovery history too.
b043	**A gate that could not be read is not a hold**, and this is not in tension with "unknown is not clear" two paragraphs up — the two answer different questions. An unknown *state that was read* (a shape no row names) is held: the loop has no action for it. State that *could not be read at all* is not a fact about the PR, it is a failed tick, and it falls under this section's opening rule: live state was not verified, so the tick proves nothing — leave the loop alone and write no stall record.
b044	Two carve-outs keep the state precise:
b045	- **Self-resolving holds can never trip it — but a hold against a BLOCKED PR is not one.** A collision or migration hold against in-flight work resolves when that work merges, and requires in-flight > 0, so the in-flight = 0 conjunct excludes it by construction. Since §4 now intersects against blocked issues' open PRs too, the same filters can also hold on a PR no one may advance: that hold survives in-flight = 0, and it is a human gate like any other, so it belongs in the held set rather than keeping the loop alive. - **A foreign claim is not a human gate.** An item skipped by the Claimed filter is another session's in-flight (`mine: false`) and resolves when that session merges, no human needed. A tick whose holds include an active foreign claim is idle, not stalled — keep looping.
b046	**Both carve-outs survive the new conjunct unchanged**, and PR rows weaken neither: a self-resolving hold still requires in-flight > 0, and another session's open PR is that session's in-flight, resolving when it merges. A foreign claim is therefore not a human gate, and the union above cannot turn one into a PR row either — a foreign in-flight issue is `mine: false` and not blocked, so neither half of the union reaches it. The safety rails carry the same rule for the tick as a whole.
b047	**Confirm across two consecutive ticks before stopping** — a single stalled tick may be racing another session that is about to close a dependency, unblock an issue, or merge a PR. Ticks share no memory, so persist the observation next to the §5 batch manifest, in `.git/dispatch-ready-stall.json`: the held set — held issue numbers AND held PR numbers — with each one's hold root (the open `Depends on #N` it chains to, the `blocked` label, the decision gate, `isolation unconfirmed`, the Blocking finding a held PR carries).
b048	**"Matches exactly" compares the identifiers and each one's hold ROOT, never the rendered sentence.** Two honest ticks word the same hold differently, and a comparison over free text never converges; a comparison over identifiers alone confirms a stall across two genuinely different states, since a PR whose gate changed between ticks is still the same number. A record written before this section grew PR rows carries issue numbers only: it cannot match a hold-set containing a PR, so it is discarded and rewritten, which costs one extra tick and never a false confirmation.
b049	**The record is written from the held set, never from `ready[]`**, which is what makes it reachable with Ready empty. Before #282 it was written only inside a branch that required Ready non-empty, so in the uncovered state the two-tick clock never started and there was nothing to confirm. A hold-set of nothing but PRs starts that clock exactly like any other.
b050	- **No record, or the recorded hold-set differs from this tick's** → write this tick's hold-set and finish normally, appending to the tick report: `stall: suspected — nothing in flight and nothing this loop may advance; an identical hold-set next tick ends the loop`. - **Record matches this tick's hold-set exactly** → STALLED is confirmed. Delete the record and announce loudly, naming the reason **per held item** so the human knows exactly what unlocks the queue — PR rows alongside issue rows, each naming the PR and the gate holding it:
b051	Then take the **same stop path as DRAIN COMPLETE** below — one path, never a parallel one. A held set of nothing but PRs takes that same path: it is a terminal state like any other, and the cron self-cancel below is not optional on it.
b052	Any tick that dispatches, merges, observes in-flight work, or sees an open PR it may still advance deletes a leftover `.git/dispatch-ready-stall.json`: progress resets the confirmation clock. **A tick that does both** — merges the last in-flight PR and still ends holding something — deletes the record first and then writes this tick's hold-set: progress wins, and the new hold-set starts a fresh two-tick count rather than inheriting the old one's.
b053	### Stop path — every terminal state
b054	Stop the loop yourself, according to how this tick was invoked:
b055	| Mode | Recognize it by | Stop path | | --- | --- | --- | | **Self-paced loop** (ScheduleWakeup) | This tick was woken by a wake-up the previous tick scheduled | Do not schedule another wake-up — the loop ends here | | **Cron / fixed interval** (CronCreate-backed) | A cron job fires the skill on a schedule | **Self-cancel the cron** — see below. Do not merely advise the user to cancel; act | | **Manual invocation** | No loop context | Nothing to cancel — announce and finish. A stalled manual tick announces STALLED immediately: the two-tick confirmation gates loop cancellation, and there is no loop |
b056	**Cron self-cancel.** Find the loop's job id yourself: run `CronList` and select the job whose prompt is this dispatch-ready invocation.
b057	- **Exactly one match** → `CronDelete <id>`, then append to the report — after COMPLETE: `Loop <id> cancelled — run groom-backlog to refill Ready and start a new drain when there's more to ship.`; after DEFERRED: `Loop <id> cancelled — run the drain from a checkout those items name.`; after STALLED: `Loop <id> cancelled — resolve the gate(s), then restart the drain.`; after DEGRADED: `Loop <id> cancelled — the platform recovers on its own; restart the drain once it has.` - **Zero, multiple, or ambiguous matches** → delete NOTHING. Announce the terminal state, list the candidate ids, and tell the user to `CronDelete` the right one. Deleting the wrong job is worse than a few extra no-op ticks.
b058	Safety rails: self-cancel ONLY on a terminal state confirmed above. For DEGRADED, a single degraded tick, a `healthy` verdict, an `unknown` verdict, a `no verdict` run, a red check, a genuinely pending check or an active foreign claim all mean the loop may still make progress — stay alive. For COMPLETE, anything still claimed or an open PR this loop tracks — the union §7's discriminator ranges over, in-flight until actually MERGED per §3 — means the drain is not complete; the veto and the held set must range over the same set, or the state they disagree about ticks forever. For DEFERRED, a Ready item this checkout may take, any dispatch, any in-flight work or an active foreign claim means the loop may still make progress — stay alive. A hold a human could clear is a different answer entirely: the tick is STALLED rather than deferred, which is a terminal state of its own reached by its own two-tick confirmation, and never a reason to keep looping. For STALLED, any dispatch, any in-flight work (mine or foreign), an open PR this loop may still advance, an empty held set, or a hold-set that changed since the recorded tick means the loop may still make progress — stay alive. An API-failure tick never self-cancels and never counts toward stall confirmation. Ticks that fire between confirmation and cancellation are no-ops, not errors: each re-runs this section and retries.
f001	bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/probe-platform-health.sh --pr "$PR" --repo "$REPO"
f002	DRAIN DEGRADED — the platform is degraded and nothing in flight can progress: probe: degraded (attributed) — Actions: major_outage in flight: #N (PR #N — required check `ci` has no run for the head) Loop <id> cancelled — the platform recovers on its own; restart the drain once it has.
f003	DRAIN COMPLETE — Ready is empty and nothing is in flight.
f004	DRAIN DEFERRED — remaining Ready items require a site this checkout does not hold #N #N → requires site vdi #N → requires site vdi or bench Loop <id> cancelled — run the drain from a checkout those items name.
f005	DRAIN STALLED — nothing dispatchable, nothing in flight, and nothing this loop may advance: #N #N #N #N #N → chain to #N (parked in Backlog: awaiting planning session) #N → blocked label (dispatch-ready: 2 failed attempts — CI check needs a human call) PR #N (#N) → open, issue blocked (3 Blocking review findings, redispatch spent) Loop <id> cancelled — resolve the gate(s), then restart the drain.
c001	## 3. Compute capacity
c002	In-flight is the set of issues claimed by this loop — assignee @me plus board status or the `in-progress` label — **and not carrying `blocked`**. That last clause is stated here because this is the file's only "in-flight is" sentence, and §2's board path, §4's filters and §7's first conjunct all read it: `issue-claim.sh block` writes labels and never moves a card, so without it a demoted issue stays in-flight on a board repo permanently and no terminal state can ever fire. Do NOT resolve the resulting asymmetry with §4's Claimed filter by aligning the two — §4 skips on a disjunction on purpose, and `issue-claim.sh` documents why. **Capacity = `max_in_flight` − in-flight.**
c003	A green PR sitting in the merge queue still counts as in-flight until it is actually MERGED. Compute capacity from post-reconcile live state and accept that a queue-pending slot frees up next tick, not this one. Capacity ≤ 0 → emit the tick report and stop; the next tick tops up.
g001	DRAIN TICK — in-flight 3/5 | merged this tick: #N | dispatched: #N #N | Ready remaining: 4 holds: #N (Depends on #N, still open) · #N (migration slot busy) · #N (overlaps in-flight #N) · PR #N (open, #N blocked) collision sources: #N pr · #N declared (no PR yet) · #N declared (PR read failed — narrower check) stacks: #N → #N → #N dispatched as 1 layer-stack (1 slot, 3 PRs) unannotated (dispatched without a touches set — coupling unchecked): #N review: #N BLOCKING (unvalidated path join in scripts/render.sh) — redispatch 1 of 1
sec7_openers	## 7. Terminal states — drain ~ A drain loop ends itself in ~ ### DRAIN DEGRADED ~ **Evaluated BEFORE COMPLETE and STALLED, and ~ This state **consumes** `pr-shepherd`'s probe and ~ ```bash ~ ``` ~ Run it against **ONE** in-flight PR, ~ Three conjuncts, and each excludes a ~ 1. **In-flight is non-zero and nothing ~ **Report WHY an `unknown` could not ~ **Two-tick confirmation, the same shape as ~ - **No record** → write this ~ ```text ~ ``` ~ Then take the **same stop path ~ Any tick that dispatches, merges, or ~ ### DRAIN COMPLETE ~ Ready empty AND in-flight zero AND ~ ```text ~ ``` ~ **COMPLETE is unchanged, veto included** — ~ ### DRAIN DEFERRED ~ **Evaluated BEFORE STALLED, and the order ~ Four conjuncts, and the fourth is ~ 1. **In-flight zero AND dispatched zero ~ **Conjunct 4 speaks of the holds ~ **A site hold is neither self-resolving ~ **No confirmation tick, exactly as COMPLETE ~ Announce loudly, naming the site each ~ ```text ~ ``` ~ Then take the **same stop path ~ ### DRAIN STALLED ~ In-flight zero AND dispatched zero this ~ **The third conjunct is "nothing to ~ **Deleting that conjunct outright would have ~ **The held set must be non-empty.** ~ **A held set of nothing but ~ #### The discriminator — may this ~ **"Every open PR this tick sees" ~ **That union is also the set ~ **The blocked half is deliberately REPO-WIDE, ~ Ask it of every one of ~ | Open PR this tick | ~ **Rows 2 to 6 cannot fire ~ **The last row is a default, ~ **`CONFLICTING` needs its own row, above ~ **The redispatch budget is the hinge ~ **Read the review outcome from the ~ **A gate that could not be ~ Two carve-outs keep the state precise: ~ - **Self-resolving holds can never trip ~ **Both carve-outs survive the new conjunct ~ **Confirm across two consecutive ticks before ~ **"Matches exactly" compares the identifiers and ~ **The record is written from the ~ - **No record, or the recorded ~ ```text ~ ``` ~ Then take the **same stop path ~ Any tick that dispatches, merges, observes ~ ### Stop path — every terminal ~ Stop the loop yourself, according to ~ | Mode | Recognize it by ~ **Cron self-cancel.** Find the loop's job ~ - **Exactly one match** → `CronDelete ~ Safety rails: self-cancel ONLY on a
sec7_bullets	0:- **No record** → write this ~ 0:- **Record present** → DEGRADED is ~ 0:- **Self-resolving holds can never trip ~ 0:- **A foreign claim is not ~ 0:- **No record, or the recorded ~ 0:- **Record matches this tick's hold-set ~ 0:- **Exactly one match** → `CronDelete ~ 0:- **Zero, multiple, or ambiguous matches**
sec7_tablerows	0:| Open PR this tick | ~ 0:| --- | --- | --- ~ 0:| Its issue carries `blocked` | ~ 0:| `CONFLICTING` | **No** — §2 ~ 0:| Held by a §2 review ~ 0:| Checks still running, and not ~ 0:| Checks red, its issue not ~ 0:| Anything else this loop is ~ 0:| Mode | Recognize it by ~ 0:| --- | --- | --- ~ 0:| **Self-paced loop** (ScheduleWakeup) | This ~ 0:| **Cron / fixed interval** (CronCreate-backed) ~ 0:| **Manual invocation** | No loop
sec7_headings	## 7. Terminal states — drain complete, drain deferred, drain stalled, drain degraded ~ ### DRAIN DEGRADED ~ ### DRAIN COMPLETE ~ ### DRAIN DEFERRED ~ ### DRAIN STALLED ~ #### The discriminator — may this loop advance it? ~ ### Stop path — every terminal state
sec2_openers	## 2. Reconcile in-flight (always first) ~ Find work this loop already started. ~ **Reconcile the shared recovery allowance before ~ For a later-tick recovery, append `recovery_used=1 ~ **With `board:`** — the board snapshot ~ **Without a board** — live issue ~ Either way, in-flight counts whether or ~ **Issue-only terminal failures — before the ~ - **Open PRs from those branches**
sec2_bullets	0:- **Open PRs from those branches** ~ 0:- **Open PRs on blocked issues** ~ 0:- **Failed or red PRs** → ~ 0:- **Open PRs not yet reviewed, ~ 0:- **A review dispatched that never ~ 0:- **PRs carrying a Blocking review ~ 0:- **`CONFLICTING` PRs** → never auto-rebase;
sec2_tablerows	
sec2_headings	## 2. Reconcile in-flight (always first)
sec4_openers	## 4. Select from Ready — ~ **With `board:`** — take the **Ready** ~ **Without a board** — take `ready[]` ~ Filter, in order: ~ | Filter | Rule | ~ ### Site — the array read, ~ Some work runs only from one ~ **Read `sites` off the §2 snapshot ~ **On the `board:` path, run the ~ **Plugin root.** If the plugin-root placeholder ~ ```bash ~ ``` ~ One resolver, two callers, one answer. ~ **A resolver that could not run ~ **The match is `not sites or ~ - **`sites` empty → dispatch, exactly ~ **A site hold is not a ~ ### Collision — an in-flight PR's ~ `touches:` is a **prediction**, written at ~ - **doc reconciliation** (`CLAUDE.md`, `README.md`, `docs/`) ~ **A blocked issue's open PR counts ~ So for an issue that **already ~ ```bash ~ ``` ~ §2 already resolved which in-flight issues ~ Resolve a source per in-flight issue, ~ | In-flight issue | Set used ~ **A failed read is never "no ~ **Known limitation: this narrows the gap, ~ **Do not "simplify" this back into ~ ### Stacks (ONLY if `stacked_prs:` is ~ **With no `stacked_prs:` block this section ~ When it IS configured, `queue-snapshot.sh` surfaces ~ - **Dependencies** — members may depend ~ **Capacity: a chain costs ONE `max_in_flight` ~ Verify the repo is actually enabled ~ ```bash ~ ``` ~ Exit `11` means the preview is ~ ### Reference decay — re-check at ~ groom-backlog resolves every reference before promoting, ~ ```bash ~ ``` ~ Exit `3` → **hold the issue ~ Exit `0` dispatches normally. Exit `10` ~ `likely-new` findings never hold an issue. ~ **If `migrations:` is configured** — additional ~ **If `codegen:` is configured** — additional ~ Take the first `capacity` survivors. The
sec4_bullets	0:- **`sites` empty → dispatch, exactly ~ 0:- **`sites` containing this checkout's site ~ 0:- **No `execution_site` configured → the ~ 0:- **doc reconciliation** (`CLAUDE.md`, `README.md`, `docs/`) ~ 0:- **CI wiring** (`scripts/preflight.sh` and the ~ 0:- **Dependencies** — members may depend ~ 0:- **Collision** — overlapping `touches:` sets
sec4_tablerows	0:| Filter | Rule | ~ 0:| --- | --- | ~ 0:| Claimed | Skip if assignee ~ 0:| Blocked | Skip the `blocked` ~ 0:| Site | Skip if the ~ 0:| Dependencies | Skip while any ~ 0:| Collision | Skip if the ~ 0:| In-flight issue | Set used ~ 0:| --- | --- | --- ~ 0:| Open PR, `gh pr view` ~ 0:| No PR yet — sub-agent ~ 0:| Open PR, but the read ~ 0:| Smell test | Run take-it's ~ 0:| Reference decay | Re-resolve the
sec4_headings	## 4. Select from Ready — and only Ready ~ ### Site — the array read, and an unnamed checkout is fail-open ~ ### Collision — an in-flight PR's real files beat the declaration ~ ### Stacks (ONLY if `stacked_prs:` is configured) ~ ### Reference decay — re-check at dispatch, not just at grooming
sec6_openers	## 6. Tick report ~ Terse — this prints every few ~ ```text ~ ``` ~ Plus one line per failure with
sec6_bullets	
sec6_tablerows	
sec6_headings	## 6. Tick report
guard_openers	## Guardrails ~ - **Ready only.** Everything else is ~ Apply any `## extra-sequencing` section from
guard_bullets	0:- **Ready only.** Everything else is ~ 0:- **Hard cap `max_in_flight`**, counting carry-over ~ 0:- **Never dispatch a partial chain**, ~ 0:- **Idempotent ticks**: every action re-checks ~ 0:- **Single-writer**: only the coordinator merges ~ 0:- **Never merge past a Blocking ~ 0:- If `sassy-dog:pr-shepherd` or take-it is
guard_headings	## Guardrails
CANON
}
canon() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' <<<"$(canon_table)"; }
# An empty VALUE is meaningful — §2 holds no tables and §6 no bullets, and
# "there are none" is exactly the fact worth pinning, since growing one is a
# structural change. So key PRESENCE is what is checked, never truthiness.
canon_has() { awk -F'\t' -v k="$1" 'BEGIN { r = 1 } $1 == k { r = 0 } END { exit r }' <<<"$(canon_table)"; }

# assert_canon <key> <start prefix> <stop prefix> <label>
assert_canon() {
    local want got
    note_consumed "$1"
    want="$(canon "$1")"
    got="$(flat "$(raw_region "$SKILL" "$2" "$3")")"
    if [ -z "$want" ]; then bad "$4 — no canonical text under key '$1'"; return; fi
    if [ -z "$got" ]; then bad "$4 — the paragraph did not resolve; its opening has moved"; return; fi
    if [ "$got" = "$want" ]; then ok "$4"; else bad "$4 — canon key '$1' has moved; edit canon_table"; fi
}
# assert_canon_value <key> <got> <label>
assert_canon_value() {
    local want
    note_consumed "$1"
    if ! canon_has "$1"; then bad "$3 — no canonical entry under key '$1'"; return; fi
    want="$(canon "$1")"
    if [ "$2" = "$want" ]; then ok "$3"; else bad "$3 — canon key '$1' has moved; edit canon_table"; fi
}

# --- windows, each proved non-empty AND bounded ------------------------------
sec2="$(raw_region "$SKILL" '## 2. Reconcile in-flight' '## 3. Compute capacity')"
sec6="$(raw_region "$SKILL" '## 6. Tick report' '## 7. Terminal states')"
sec7="$(raw_region "$SKILL" '## 7. Terminal states' '## Guardrails')"
complete_raw="$(raw_region "$SKILL" '### DRAIN COMPLETE' '### ')"
deferred_raw="$(raw_region "$SKILL" '### DRAIN DEFERRED' '### DRAIN STALLED')"
stalled_raw="$(raw_region "$SKILL" '### DRAIN STALLED' '### ')"
gate_raw="$(raw_region "$SKILL" '### DRAIN STALLED' '#### ')"
disc_raw="$(raw_region "$SKILL" '#### The discriminator' 'Two carve-outs keep the state precise:')"
# NOT `raw_region "$SKILL" 'In-flight zero AND dispatched zero' ''` — that
# binds to the first such line in the FILE, and DEFERRED's conjunct 1 is one of
# them, above this. Derived from the STALLED window instead; the words are
# asserted below rather than trusted to aim the window.
opening_raw="$(first_block "$stalled_raw")"
record_raw="$(raw_region "$SKILL" '**Confirm across two consecutive ticks' '```')"
announce_raw="$(raw_region "$SKILL" 'DRAIN STALLED — nothing dispatchable' '```')"
rails_raw="$(raw_region "$SKILL" 'Safety rails:' '## ')"
carvelist_raw="$(raw_region "$SKILL" 'Two carve-outs keep the state precise:' '**Both carve-outs')"
# To EOF: Guardrails is the last section, and a stop that matched nothing would
# silently give an empty window — which its non-empty guard below catches.
sec3="$(raw_region "$SKILL" '## 3. Compute capacity' '## 4. Select from Ready')"
sec4="$(raw_region "$SKILL" '## 4. Select from Ready' '## 5. Dispatch')"
guard="$(raw_region "$SKILL" '## Guardrails' '## THIS-MARKER-MUST-NOT-EXIST')"
claim_block="$(raw_region "$CLAIM" '        block)' '        promote)')"
# The bullet also states that `block` REQUIRES a comment, which is the reason it
# can promise a human ever learns why. That check lives in argument parsing,
# above the `block)` case, so it needs its own window (#290).
claim_require="$(raw_region "$CLAIM" 'if [[ ("$SUB" == "block"' '')"
# The `mergeable` arm and everything below it, so "ahead of every other gate" is
# a question this window can answer rather than one it has to be told.
shepherd_open="$(raw_region "$SHEPHERD" '  # OPEN:' '}')"
# §2's LAST bullet, so its stop is §3's heading and NOT the empty stop marker,
# which `raw_region` implements as "the first blank line". Measured: with the
# empty stop, appending a blank line plus an indented continuation paragraph
# that re-admits a redispatch, parks the issue back in Ready and restores
# `surface and hold` left ALL of this section's assertions green — the window
# shrank and the canon shrank with it, so equality compared the surviving half
# against itself. Only `sec2_openers` moved, whose message says `edit
# canon_table`, which is precisely the rubber stamp limit (3) describes. An
# explicit stop makes an appended paragraph part of the compared text.
conflicting_raw="$(raw_region "$SKILL" '- **`CONFLICTING` PRs**' '## 3. Compute capacity')"

for w in sec2 sec3 sec4 sec6 sec7 guard complete_raw deferred_raw stalled_raw gate_raw disc_raw opening_raw \
         record_raw announce_raw rails_raw carvelist_raw claim_block claim_require \
         shepherd_open conflicting_raw; do
    if [ -n "${!w}" ]; then
        ok "window $w resolved"
    else
        bad "window $w is empty — every assertion scoped to it would pass vacuously"
    fi
done
[ "$fails" -eq 0 ] || { echo "test-drain-terminal-states: FAILED ($fails)" >&2; exit 1; }

sec2_flat="$(flat "$sec2")"
sec6_flat="$(flat "$sec6")"
sec7_flat="$(flat "$sec7")"
complete_flat="$(flat "$complete_raw")"
deferred_flat="$(flat "$deferred_raw")"
stalled_flat="$(flat "$stalled_raw")"
gate_flat="$(flat "$gate_raw")"
disc_flat="$(flat "$disc_raw")"
opening_flat="$(flat "$opening_raw")"
record_flat="$(flat "$record_raw")"
announce_flat="$(flat "$announce_raw")"
rails_flat="$(flat "$rails_raw")"
carvelist_flat="$(flat "$carvelist_raw")"
conflicting_flat="$(flat "$conflicting_raw")"

# Every window stops where it claims to. `sec7`, `announce_raw` and
# `carvelist_raw` had only a non-empty check until a review measured renaming
# `## Guardrails` making `sec7` run silently to EOF at exit 0.
assert_absent "$complete_flat" 'In-flight zero AND dispatched zero' \
    "COMPLETE window stops before the STALLED gate"
assert_absent "$gate_flat" 'May this loop advance it' \
    "STALLED gate window stops before the discriminator table"
assert_absent "$disc_flat" 'Self-resolving holds' \
    "discriminator window stops before the carve-outs"
assert_absent "$stalled_flat" 'Stop the loop yourself' \
    "STALLED window stops before the stop path"
# DEFERRED's stop is the STALLED HEADING, and a heading is what somebody renames.
# Its body is what survives a rename, so that is what proves the bound — the same
# reasoning `sec7`'s own stop check carries.
assert_absent "$deferred_flat" 'The held set must be non-empty' \
    "DEFERRED window stops before the STALLED gate, whatever that heading is called"
assert_absent "$opening_flat" 'The third conjunct' \
    "STALLED opening window is one paragraph, not the rationale below it"
# The START bound, and it is an ASSERTION rather than the anchor it used to be:
# the window is now STALLED's first block whatever it says, so this is what fails
# if that block stops being the conjunct sentence — loudly, instead of the window
# silently sliding onto DEFERRED's conjunct 1 (header (b)).
assert_wline "$opening_raw" '^In-flight zero AND dispatched zero this tick AND' \
    "the STALLED opening window is STALLED's own first block, and that block still opens the conjuncts"
assert_absent "$record_flat" 'DRAIN STALLED —' \
    "stall-record window stops before the announcement block"
assert_absent "$rails_flat" 'Ready only' \
    "safety-rails window stops before the Guardrails list"
assert_absent "$sec2_flat" 'Capacity =' \
    "section 2 window stops before section 3"
assert_absent "$sec6_flat" 'DRAIN COMPLETE' \
    "section 6 window stops before section 7"
assert_absent "$sec7_flat" 'Hard cap .max_in_flight' \
    "section 7 window stops before the Guardrails list, whatever that heading is called"
assert_absent "$announce_flat" 'same stop path as DRAIN COMPLETE' \
    "announcement window stops at the closing fence"
assert_absent "$carvelist_flat" 'Both carve-outs survive' \
    "carve-out list window stops before the paragraph after it"
assert_absent "$claim_block" 'ensure_label "\$READY_LABEL"' \
    "issue-claim.sh block window stops before the promote case"
# `claim_require` is bounded by a BLANK LINE, so deleting the one at
# issue-claim.sh's guard grows it silently into whatever follows. This section
# claims every window stops where it says it does; that has to include the two
# this change added.
assert_absent "$claim_require" 'REPO=' \
    "the require-comment window stops at the guard, not at the rest of the preamble"
assert_absent "$shepherd_open" 'MERGED . tearing down' \
    "the merge-shepherd window starts at the OPEN arm, below the MERGED/CLOSED arms"
assert_absent "$shepherd_open" 'deadline=' \
    "the merge-shepherd window stops at the end of the function, not at the watch loop"
assert_absent "$conflicting_flat" 'Compute capacity' \
    "the CONFLICTING-bullet window stops at the end of section 2"
# The stop marker is a HEADING somebody may rename, and a renamed one runs this
# window to EOF while the check above still passes, the heading text having gone
# with it. §3's body is what survives a rename, so it is what proves the bound —
# the same reasoning `sec7`'s stop check carries.
assert_absent "$conflicting_flat" 'Capacity =' \
    "the CONFLICTING-bullet window stops before section 3's body, whatever its heading is called"
# The START bound, and deliberately NOT an `assert_wline` for the opening
# bullet: `raw_region` already anchors that with `index($0, s) == 1`, while
# `assert_wline`'s single-line-blob guard fires on a legitimately ONE-LINE
# bullet — measured, reverting this bullet to its pre-fix one-liner reported
# "assert_wline was handed a single-line blob" beside the real failures. This
# asks the same question in the direction that can actually drift: that the
# window has not started at a bullet ABOVE this one.
assert_absent "$conflicting_flat" 'PRs carrying a Blocking review' \
    "the CONFLICTING-bullet window starts at that bullet, not the one above it"
assert_wline "$guard" '^- \*\*Ready only\.\*\*' \
    "the Guardrails window starts at the Guardrails list"
assert_absent "$(flat "$guard")" 'DRAIN COMPLETE' \
    "the Guardrails window does not reach back into §7"

# --- canon: every §7 block, and the shape of §7, §2 and §6 -------------------
# §7 is pinned WHOLESALE rather than as a hand-picked subset. Five review rounds
# each found another paragraph no key held that could invert one a key did hold:
# the API-failure rule a pinned paragraph delegates to, the read-source
# instructions, a stop-path table cell, a §2 bullet body, a §6 paragraph. The
# subset was the defect, not the choice of subset.
section canon7 "every §7 block matches the canon, and §7/§2/§6 keep their shape"

blocks7="$(section_blocks "$sec7")"
n_canon_blocks="$(grep -c '^b[0-9]' <<<"$(canon_table)")"
n_blocks=0
n_block_moved=0
first_moved=""
while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    n_blocks=$((n_blocks + 1))
    blk_key="$(printf 'b%03d' "$n_blocks")"
    note_consumed "$blk_key"
    if [ "$blk" != "$(canon "$blk_key")" ]; then
        n_block_moved=$((n_block_moved + 1))
        [ -n "$first_moved" ] || first_moved="$blk_key: $(printf '%.70s' "$blk")"
    fi
done <<<"$blocks7"

assert_eq "$n_blocks" "$n_canon_blocks" \
    "§7 holds exactly the blocks the canon pins ($n_canon_blocks)"
if [ "$n_block_moved" -eq 0 ]; then
    ok "every §7 block matches its canonical text ($n_blocks blocks)"
else
    bad "$n_block_moved §7 block(s) have moved — first at $first_moved"
fi

# Structure, for all three sections this PR touches. An inventory bounds
# INSERTION, DELETION and REORDERING; the block canon above bounds CONTENT
# within §7. §2 and §6 get the inventory but not whole-section content pinning:
# this PR wrote one bullet in §2 and one paragraph in §6, and freezing two
# sections it did not write would redden on every unrelated edit. That is a
# STATED LIMIT below, not an oversight — an APPENDED sentence to an existing
# §2 or §6 paragraph is bound by neither, and was measured inverting §7.
assert_canon_value sec7_openers "$(openers "$sec7")" \
    "§7's paragraph inventory is unchanged"
assert_canon_value sec7_bullets "$(bullet_openers "$sec7")" \
    "§7's bullet inventory is unchanged"
assert_canon_value sec7_tablerows "$(table_rows "$sec7")" \
    "§7's table rows are unchanged, in EVERY table"
assert_canon_value sec7_headings "$(heading_list "$sec7")" \
    "§7's headings are unchanged — a third terminal state would be a new one"

# The fenced blocks §7 prints, by content rather than by shape alone.
fences7="$(section_fences "$sec7")"
n_canon_fences="$(grep -c '^f[0-9]' <<<"$(canon_table)")"
n_fences=0
n_fence_moved=0
first_fence=""
while IFS= read -r fnc; do
    [ -n "$fnc" ] || continue
    n_fences=$((n_fences + 1))
    fnc_key="$(printf 'f%03d' "$n_fences")"
    note_consumed "$fnc_key"
    if [ "$fnc" != "$(canon "$fnc_key")" ]; then
        n_fence_moved=$((n_fence_moved + 1))
        [ -n "$first_fence" ] || first_fence="$fnc_key: $(printf '%.70s' "$fnc")"
    fi
done <<<"$fences7"
assert_eq "$n_fences" "$n_canon_fences" \
    "§7 holds exactly the fenced blocks the canon pins ($n_canon_fences)"
if [ "$n_fence_moved" -eq 0 ]; then
    ok "every §7 fenced block matches its canonical text ($n_fences fences)"
else
    bad "$n_fence_moved §7 fence(s) have moved — first at $first_fence"
fi

# GUARDRAILS is outside every window above, and it is a TOP-LEVEL rail list
# that already restates a §7-adjacent rule today — so "hoist the terminal-state
# condition up here" has precedent in this very file. Measured: one bullet
# there ("a terminal state is decided by the queue, not by open PRs") cancels
# §7's veto at exit 0. Inventory-only, the treatment §2 and §6 get.
assert_canon_value guard_openers "$(openers "$guard")" \
    "the Guardrails list's paragraph inventory is unchanged"
assert_canon_value guard_bullets "$(bullet_openers "$guard")" \
    "the Guardrails list's bullets are unchanged — a rail there can cancel §7"
assert_canon_value guard_headings "$(heading_list "$guard")" \
    "the Guardrails list's headings are unchanged"

# §3 is the file's ONLY "in-flight is" sentence, and §7's first conjunct on both
# terminal states reads it. Measured: re-including `blocked` there, and
# inverting "a green PR in the merge queue still counts as in-flight", both
# exited 0 while §3 sat outside every window — the second producing the variant
# this header calls worse than the bug. Pinned block-by-block, like §7.
blocks3="$(section_blocks "$sec3")"
n_canon_c="$(grep -c '^c[0-9]' <<<"$(canon_table)")"
n_c=0; n_c_moved=0; first_c=""
while IFS= read -r blk; do
    [ -n "$blk" ] || continue
    n_c=$((n_c + 1))
    c_key="$(printf 'c%03d' "$n_c")"
    note_consumed "$c_key"
    if [ "$blk" != "$(canon "$c_key")" ]; then
        n_c_moved=$((n_c_moved + 1))
        [ -n "$first_c" ] || first_c="$c_key: $(printf '%.70s' "$blk")"
    fi
done <<<"$blocks3"
assert_eq "$n_c" "$n_canon_c" "§3 holds exactly the blocks the canon pins ($n_canon_c)"
if [ "$n_c_moved" -eq 0 ]; then
    ok "every §3 block matches its canonical text ($n_c blocks)"
else
    bad "$n_c_moved §3 block(s) have moved — first at $first_c"
fi

# §6's fenced tick report is the text the loop PRINTS, exactly as §7's are.
fences6="$(section_fences "$sec6")"
n_canon_g="$(grep -c '^g[0-9]' <<<"$(canon_table)")"
n_g=0; n_g_moved=0
while IFS= read -r fnc; do
    [ -n "$fnc" ] || continue
    n_g=$((n_g + 1))
    g_key="$(printf 'g%03d' "$n_g")"
    note_consumed "$g_key"
    [ "$fnc" = "$(canon "$g_key")" ] || n_g_moved=$((n_g_moved + 1))
done <<<"$fences6"
assert_eq "$n_g" "$n_canon_g" "§6 holds exactly the fenced blocks the canon pins ($n_canon_g)"
assert_eq "$n_g_moved" 0 "every §6 fenced block matches its canonical text"

assert_canon_value sec4_openers "$(openers "$sec4")" \
    "§4's paragraph inventory is unchanged"
assert_canon_value sec4_bullets "$(bullet_openers "$sec4")" \
    "§4's bullet inventory is unchanged"
assert_canon_value sec4_tablerows "$(table_rows "$sec4")" \
    "§4's table rows are unchanged"
assert_canon_value sec4_headings "$(heading_list "$sec4")" \
    "§4's headings are unchanged"
assert_canon_value sec2_openers "$(openers "$sec2")" \
    "§2's paragraph inventory is unchanged — a sibling paragraph there inverts §7"
assert_canon_value sec2_bullets "$(bullet_openers "$sec2")" \
    "§2's bullet inventory is unchanged"
assert_canon_value sec2_tablerows "$(table_rows "$sec2")" \
    "§2's table rows are unchanged"
assert_canon_value sec2_headings "$(heading_list "$sec2")" \
    "§2's headings are unchanged"
assert_canon_value sec6_openers "$(openers "$sec6")" \
    "§6's paragraph inventory is unchanged — a sibling paragraph there inverts §7"
assert_canon_value sec6_bullets "$(bullet_openers "$sec6")" \
    "§6's bullet inventory is unchanged"
assert_canon_value sec6_tablerows "$(table_rows "$sec6")" \
    "§6's table rows are unchanged"
assert_canon_value sec6_headings "$(heading_list "$sec6")" \
    "§6's headings are unchanged"

# --- 1. the third conjunct ---------------------------------------------------
section conjunct "the STALLED gate is 'nothing to advance', not 'Ready non-empty'"

assert_absent "$opening_flat" 'Ready non-empty' \
    "STALLED's gate no longer requires Ready non-empty, in any emphasis"
assert_absent "$opening_flat" 'Ready still' \
    "STALLED's gate has not re-acquired a Ready test under another wording"

assert_in "$gate_flat" 'covered by NEITHER terminal state' \
    "the gate names the state that neither terminal state covered"
assert_in "$gate_flat" 'COMPLETE is vetoed by the open PR, and STALLED could not fire on an empty queue' \
    "the gate names both halves of why it was uncovered"
assert_in "$gate_flat" 'Deleting that conjunct outright would have been the wrong fix' \
    "the gate pins the rejected fix — dropping the conjunct outright"
assert_in "$gate_flat" 'an open PR is not automatically a human gate' \
    "the gate states why dropping it outright is wrong"
assert_in "$gate_flat" 'strips .ready. and .in-progress. together' \
    "the gate records that blocking an issue is what hid the state"

# --- 2. the enumeration the held set depends on ------------------------------
section enumeration "section 2 resolves open PRs on blocked issues, on BOTH paths"

assert_canon blocked_prs '- **Open PRs on blocked issues**' '- **Failed or red PRs**' \
    "section 2's blocked-PR enumeration bullet is unchanged"
# Without the `blocked` exclusion here, a demoted issue stays in-flight on a
# board repo forever and STALLED's first conjunct is never satisfied — the whole
# fix is inert on exactly the repos §2 claims to cover. Measured undetected
# while §2 was inventory-only, which is why this paragraph is content-pinned.
assert_canon board_inflight '**With `board:`** — the board snapshot is the source of truth' '' \
    "section 2's board-path in-flight definition is unchanged"
assert_canon collision_row "| Collision | Skip if the issue's" '' \
    "section 4's Collision filter still reaches blocked issues' open PRs"
assert_canon collision_blocked "**A blocked issue's open PR counts here" '' \
    "section 4 states why a blocked PR stays in the collision set"
# Presence-only was measured invertible while keeping the exact literal:
# "…never one whose issue carries `blocked` — unless that PR is green…" exits 0.
# The bullet is compared whole, in the `blocked_prs` idiom.
assert_canon handoff_bullet '- **Open PRs from those branches**' '- **Open PRs on blocked issues**' \
    "section 2's merge hand-off bullet is unchanged, blocked predicate included"
assert_canon redispatch_bullet '- **Failed or red PRs**' '- **Open PRs not yet reviewed' \
    "section 2's ONE-redispatch budget bullet is unchanged — both failure rows hinge on it"
assert_wline "$sec2" '^- \*\*Open PRs on blocked issues\*\*' \
    "the enumeration is a top-level bullet of section 2, not a footnote elsewhere"
assert_has "$sec2_flat" 'closedByPullRequestsReferences' \
    "section 2 names the lookup that resolves a blocked issue's PR"
assert_in "$sec2_flat" 'the blocked set is the board.s items carrying the .blocked. label' \
    "the enumeration covers the board path, not the boardless one alone"
assert_in "$sec2_flat" 'plus any .blocked.-labelled issue the board does not carry at all' \
    "the board path also takes blocked issues the board never carded"
assert_in "$sec2_flat" 'Without a board.+ it is .blocked\[\]. from the snapshot' \
    "the enumeration covers the boardless path too"
assert_in "$sec2_flat" 'never handed to `sassy-dog:pr-shepherd`' \
    "an enumerated blocked PR is read, never handed to the merger"
assert_in "$sec2_flat" 'admits DRAIN COMPLETE, so the loop self-cancels with the PR still open' \
    "section 2 records the false-COMPLETE harm an unenumerated PR causes"

# --- 2b. the CONFLICTING demotion --------------------------------------------
# THE STATE ONE STEP EARLIER THAN #282's. Every §2 failure path had a demotion
# route except this one: a `CONFLICTING` PR was surfaced and HELD, and the hold
# left the issue `in-progress`, so in-flight never reached zero — COMPLETE
# vetoed by the open PR, STALLED forbidden by in-flight, and the loop ticked
# forever. #282's discriminator classifies such a PR correctly the moment it is
# enumerable, and on this path it never became so; that fix is untouched here
# and does not close this (issue #290).
#
# IT CANNOT REACH A DEMOTION BY ANY OTHER ROUTE, which is why the fix has to be
# written into this bullet rather than left to the failed-check one. A
# conflicted PR stops CI firing at all — `pr-shepherd` records that
# `no checks reported` is indistinguishable from `CI hasn't started` — so the
# attempt counter that eventually demotes a red PR never starts.
#
# DEMOTE ON SIGHT, and the REJECTED alternative is RECORDED in the bullet —
# recorded, not pinned as a negative; see the limit below for what that is
# worth. It is the one a later "make these bullets symmetric" sweep reaches for.
# Mirroring the failed-check bullet's ONE redispatch means dispatching a
# sub-agent to rebase, which IS this loop advancing that PR — precisely what
# §7's `CONFLICTING` row forbids in as many words. That option therefore costs
# a §7 row as well, re-opening a decision PR #291 settled and the canon here
# holds. Demote-on-sight needs no new policy: once the issue carries `blocked`,
# §7's FIRST row matches it before the `CONFLICTING` row is reached.
#
# HOW IT IS BOUND, AND WHAT THAT IS AND IS NOT WORTH. Canon equality is the
# only layer that bounds a REWORDED decision, exactly as it is for every other
# canon key here, and known limit (3) governs it: a hand regeneration is a
# rubber stamp, and a regeneration that is not read retires this section.
# WHAT THAT COSTS, MEASURED RATHER THAN GUESSED IN EITHER DIRECTION — an earlier
# draft of this comment claimed three meaning-inverting rewrites "each exit 0",
# and only ONE of them does; understating coverage invites the next sweep to
# delete these must-exists as dead weight, which is the same defect as
# overstating it. With `conflicting_bullet` regenerated the way the failure
# message instructs: an APPENDED sentence that contradicts a rule exits 0,
# because nothing here reads a rule's neighbourhood. INVERTING a pinned sentence
# is caught by that sentence's own must-exist — rewriting the headline to
# `**hold until a human rebases.**` fails `demote on sight`, and rewriting the
# tail to `**Park it back in Ready**` fails `Never park it back in Ready`. So
# these catch a literal DELETION and an inversion that DELETES the pinned form
# with it; each pins one surface form, so a contradiction added BESIDE the
# pinned form walks past (`ONE redispatch` is also case-sensitive).
# WIDENING THE GREPS IS THE FIX TO REFUSE — the header of
# `scripts/test-sentry-verification.sh` records this repo losing that argument
# every review round, three veto generations deep, and a veto that works needs
# the forward segmentation pass a different issue owns. The two must-not-exists
# are LITERAL-DELETION checks against the pre-fix wording, not polarity
# judgements, which is the posture test-audit-lost-reviewer.sh states. The
# `surface and hold` veto does not collide with this bullet's own "A bare
# surface-and-hold is what this replaces": that phrase is hyphenated, measured,
# and the hyphens survive `emph_strip`. Rewording it to the spaced form is a
# loud false red, which is the direction this repo prefers.
section conflicting "a CONFLICTING PR is demoted on sight, so it cannot hold in-flight open forever"

# The stop literal is DUPLICATED from `conflicting_raw`'s declaration above, and
# the rationale for it being non-empty lives there. Changing this one back to ''
# surrenders the append protection and fails only into `sec2_openers`, whose
# message says `edit canon_table` — the rubber stamp. Change both or neither.
assert_canon conflicting_bullet '- **`CONFLICTING` PRs**' '## 3. Compute capacity' \
    "section 2's CONFLICTING bullet is unchanged, demotion included"
assert_wline "$sec2" '^- \*\*`CONFLICTING` PRs\*\*' \
    "the demotion is a top-level bullet of section 2, not a footnote elsewhere"
assert_in "$conflicting_flat" 'demote on sight' \
    "the bullet states the decision — demote on sight"
assert_has "$conflicting_flat" 'issue-claim.sh block N --comment' \
    "the bullet names the command that writes the demotion, comment included"
assert_has "$conflicting_flat" '**No redispatch, and no attempt counter**' \
    "the bullet refuses the redispatch shape the failed-check bullet has"
assert_in "$conflicting_flat" 'discriminator table forbids for `CONFLICTING`' \
    "the bullet gives its rationale — a redispatch contradicts section 7's own row"
assert_in "$conflicting_flat" 'in-flight never reached zero' \
    "the bullet records the harm a bare hold caused"
# The four rules this bullet added beyond the demotion itself. Each is pinned by
# its own literal for the DELETION case only — the limit above governs a reword
# — and each was measured undetected before these existed: dropping the
# idempotency predicate, the failed-write outcome, the §4 carry-forward or the
# stacked-layer case each left the gate at exit 0 once the canon was regenerated.
assert_in "$conflicting_flat" 'Demote ONCE' \
    "the bullet demotes once, so a tick cannot re-comment on a PR that stays CONFLICTING"
# THE TOKEN IS NOT THE RULE. The line above was measured passing on a bullet
# whose predicate had been replaced by "demote it every tick it is seen",
# because the failed-write sentence MENTIONS `Demote ONCE` a second time and
# satisfied it. Pin the operative clause, not the name of it.
assert_has "$conflicting_flat" 'skip an issue that already carries `blocked`' \
    "the demote-once rule keeps its predicate, not just its name"
# The failed-write rule has a second half nothing pinned: `issue-claim.sh`
# reports ok and exits 0 when only the COMMENT fails, so a tick reading the exit
# code alone concludes a human was told why when nobody was.
assert_in "$conflicting_flat" 'never from the exit code alone' \
    "the demotion is verified from live state, not from the exit code"
assert_in "$conflicting_flat" 'If the demotion write fails' \
    "the bullet gives the failed-write outcome, without which a tick believes it demoted"
# `assert_has`, not `assert_in`: under LC_ALL=C the section sign is TWO bytes,
# so a `.` wildcard standing in for it matches half of it and the check fails on
# a clean tree — measured, it reddened every mutation AND the restored run.
assert_has "$conflicting_flat" "Carry that PR into §4's collision sources" \
    "the demoted PR stays in section 4's collision sources for the tick that demotes it"
assert_in "$conflicting_flat" 'A stacked upper layer demotes like any other' \
    "the bullet answers the stacked-layer case the pr-shepherd reference calls expected"
assert_in "$conflicting_flat" 'COMPLETE stays vetoed and the held set stays non-empty' \
    "the bullet keeps section 7's one-set identity across the demotion write"
assert_in "$conflicting_flat" 'Never park it back in Ready' \
    "a demoted CONFLICTING issue is never parked back in Ready"
assert_absent "$conflicting_flat" 'surface and hold' \
    "the bullet no longer ends at surface-and-hold, the shape with no exit"
assert_absent "$conflicting_flat" 'ONE redispatch' \
    "the bullet has not acquired the sibling bullets' redispatch budget"

# --- 3. the discriminator ----------------------------------------------------
section discriminator "every row is pinned, classifies, and agrees with its own answer"

assert_wline "$disc_raw" '^[[:space:]]*\| Open PR this tick \| May this loop advance it\? \| Effect \|$' \
    "the discriminator table carries its header row"

# Anchored `^[[:space:]]*\|`: a row indented by ONE SPACE renders identically,
# passes markdownlint, and was measured slipping past a `^\|` filter.
# From the already-resolved, already-proved-bounded window rather than from the
# whole file: re-deriving a window beside a proved one is the shape this gate
# spends its prologue refusing.
rows="$(awk '
    /^[[:space:]]*\|/ && $0 !~ /^[[:space:]]*\| *-+ *\|/ && $0 !~ /\| Open PR this tick \|/ { print }' <<<"$disc_raw")"

n_rows=0; n_held=0; n_alive=0; n_unclassified=0; n_contradictory=0
while IFS= read -r row; do
    [ -n "$row" ] || continue
    n_rows=$((n_rows + 1))
    answer="$(cut -d'|' -f3 <<<"$row")"
    effect="$(cut -d'|' -f4 <<<"$row")"
    held=0; alive=0
    grep -qF -- 'held: joins the held set' <<<"$effect" && held=1
    grep -qF -- 'keeps the loop alive'     <<<"$effect" && alive=1
    if [ "$held" -eq 1 ] && [ "$alive" -eq 0 ]; then
        n_held=$((n_held + 1))
        grep -qF -- '**No**' <<<"$answer" || n_contradictory=$((n_contradictory + 1))
    elif [ "$alive" -eq 1 ] && [ "$held" -eq 0 ]; then
        n_alive=$((n_alive + 1))
        grep -qF -- '**Yes**' <<<"$answer" || n_contradictory=$((n_contradictory + 1))
    else
        n_unclassified=$((n_unclassified + 1))
    fi
done <<<"$rows"

# Row TEXT and row COUNT are pinned by the §7 block canon, which holds the
# whole table as one block. What it cannot express is the classification below.
assert_eq "$n_unclassified" 0 \
    "every row classifies as held or alive ($n_rows rows read)"
assert_eq "$n_contradictory" 0 \
    "every row's answer cell agrees with its effect cell"
assert_eq "$((n_held + n_alive))" "$n_rows" \
    "held + alive accounts for every row (held $n_held, alive $n_alive)"
if [ "$n_held" -ge 2 ] && [ "$n_alive" -ge 2 ]; then
    ok "both sides of the discriminator are populated (held $n_held, alive $n_alive)"
else
    bad "the discriminator has collapsed to one side (held $n_held, alive $n_alive)"
fi

assert_wline "$disc_raw" '^[[:space:]]*\| Its issue carries `blocked` \| \*\*No\*\*.*held: joins the held set \|$' \
    "a blocked issue's open PR is HELD (acceptance 1)"
assert_wline "$disc_raw" '^[[:space:]]*\| `CONFLICTING` \| \*\*No\*\*.*held: joins the held set \|$' \
    "a CONFLICTING PR is HELD, and above the checks rows"
assert_wline "$disc_raw" '^[[:space:]]*\| Checks still running.*\| \*\*Yes\*\*.*keeps the loop alive \|$' \
    "a PR whose checks are still running keeps the loop alive (acceptance 2)"
assert_wline "$disc_raw" '^[[:space:]]*\| Checks red.*not `blocked`.*\| \*\*Yes\*\*.*keeps the loop alive \|$' \
    "a red PR whose issue is not blocked keeps the loop alive (acceptance 3)"
assert_wline "$disc_raw" '^[[:space:]]*\| Anything else this loop is not permitted to merge this tick \| \*\*No\*\*.*held: joins the held set \|$' \
    "the table ends in a default, and the default is held"


assert_in "$disc_flat" 'redispatch budget is the hinge on both failure rows' \
    "the discriminator names the redispatch budget as the hinge"
assert_in "$disc_flat" 'grants exactly ONE redispatch per issue' \
    "the discriminator states the budget is exactly one redispatch"
assert_in "$disc_flat" 'a state it can still act on is not a stall' \
    "the discriminator states an actionable state is not a stall"
assert_in "$disc_flat" 'Read the redispatch budget from the issue' \
    "the discriminator says where the budget is read from"
assert_in "$disc_flat" 'No comment alone does not prove unspent: inspect the PR handoff and prior failure/recovery history too\.' \
    "the discriminator refuses to infer unused recovery from a missing comment"
assert_in "$disc_flat" 'Read the review outcome from the PR body' \
    "the discriminator reads the review outcome from the PR body, as section 2 does"
assert_in "$disc_flat" 'poll-prs.sh' \
    "the discriminator names where a PR's state comes from"

# --- 4. the held set must be non-empty ---------------------------------------
section nonempty "'nothing to advance' cannot be satisfied vacuously"

assert_in "$gate_flat" 'The held set must be non-empty' \
    "STALLED requires a non-empty held set"
assert_in "$gate_flat" 'Nothing held, nothing in flight and no open PR is COMPLETE' \
    "an empty held set with nothing in flight is COMPLETE, not STALLED"
assert_in "$gate_flat" 'must never announce STALLED' \
    "a vacuously satisfied conjunct must never announce STALLED"

# --- 5. both carve-outs, unchanged -------------------------------------------
section carveouts "both carve-outs survive, and the list cannot grow a third"


# Counted on `^- `, not on the bold prefix: an unbolded third bullet was
# measured slipping past `^- \*\*` — and a verbatim restatement of the #282 bug
# is exactly what such a bullet would say.
n_carve="$(grep -c '^- ' <<<"$carvelist_raw")"
assert_eq "$n_carve" 2 \
    "the carve-out list holds exactly two bullets — a third would weaken them unseen"
assert_in "$carvelist_flat" 'Two carve-outs keep the state precise' \
    "the carve-out list still introduces itself as two"

# --- 6. COMPLETE is unchanged, veto included ---------------------------------
section complete "COMPLETE keeps its condition, its announcement and its open-PR veto"

assert_wline "$complete_raw" '^DRAIN COMPLETE — Ready is empty and nothing is in flight\.$' \
    "COMPLETE's verbatim announcement is unchanged"
assert_has "$rails_flat" \
    'anything still claimed or an open PR this loop tracks' \
    "the safety rail still vetoes COMPLETE on an open PR this loop tracks"
assert_has "$rails_flat" \
    'the veto and the held set must range over the same set' \
    "the rails carry the one-set invariant"
assert_has "$rails_flat" \
    'an open PR this loop may still advance, an empty held set, or a hold-set that changed since the recorded tick means the loop may still make progress — stay alive.' \
    "the rails' STALLED clause still ENDS in stay-alive, with all three conditions inside it"
assert_in "$complete_flat" 'open PR this loop tracks still means the drain is not complete' \
    "COMPLETE's note keeps the veto, scoped to the tracked set"

# --- 7. the record is written from the held set ------------------------------
section record "the two-tick clock is reachable, and still two ticks"

assert_in "$record_flat" 'held issue numbers AND held PR numbers' \
    "the stall record persists held PR numbers alongside held issue numbers"
assert_wline "$record_raw" '^  `stall: suspected — nothing in flight and nothing this loop may advance; an identical hold-set next tick ends the loop`\.$' \
    "the suspected-stall line no longer claims Ready is non-empty"
assert_in "$record_flat" 'PR rows alongside issue rows, each naming the PR and the gate holding it' \
    "the confirmed announcement names each held PR and its gate"

# --- 7b. DRAIN DEGRADED (issue #286) ------------------------------------------
section degraded "a degraded platform is a terminal state, and unknown is not degraded"

sec7_degraded="$(raw_region "$SKILL" '### DRAIN DEGRADED' '### DRAIN COMPLETE')"
deg_flat="$(flat "$sec7_degraded")"

if [ -n "$sec7_degraded" ]; then
    ok "the DRAIN DEGRADED window resolves"
else
    bad "the DRAIN DEGRADED window is empty — every assertion below would be vacuous"
fi

# ORDER is the decision, not presentation. A degraded platform is the condition
# under which COMPLETE's and STALLED's live reads stop being trustworthy, so
# evaluating it after them lets a degraded read produce a confident terminal
# verdict first. Pinned two ways: the prose rule, and the physical position of
# the heading, because either alone can drift away from the other.
assert_in "$deg_flat" 'Evaluated BEFORE COMPLETE and STALLED' \
    "DEGRADED is evaluated before the other two, and says so"
deg_line="$(grep -n '^### DRAIN DEGRADED' "$SKILL" | cut -d: -f1)"
cmp_line="$(grep -n '^### DRAIN COMPLETE' "$SKILL" | cut -d: -f1)"
if [ -n "$deg_line" ] && [ -n "$cmp_line" ] && [ "$deg_line" -lt "$cmp_line" ]; then
    ok "and it physically precedes DRAIN COMPLETE, so a reader meets it first"
else
    bad "DRAIN DEGRADED does not precede DRAIN COMPLETE (deg=$deg_line cmp=$cmp_line)"
fi

# It CONSUMES the probe. Re-deriving platform health here would be a second
# implementation of a thing that already exists and is gated elsewhere.
assert_in "$deg_flat" 'probe-platform-health.sh' \
    "it invokes pr-shepherd's probe by name rather than re-deriving health"
assert_in "$deg_flat" 'never re-derives platform health itself' \
    "and says so, so a later edition cannot quietly inline the logic"
assert_in "$deg_flat" 'ONE[*][*] in-flight PR, not each' \
    "the probe runs against ONE in-flight PR, not one per PR"

# THE headline decision, and the one a later "these both mean trouble" sweep
# will collapse: `unknown` is not `degraded`. Both halves are pinned — the
# must-exist AND the veto — because a rule stating a negative that is checked
# only by presence passes on a document that also states its inverse.
assert_in "$deg_flat" 'unknown` is NOT degraded' \
    "unknown is explicitly NOT degraded"
if printf '%s' "$deg_flat" | grep -qi 'unknown[^.]\{0,80\}counts as degraded'; then
    bad "the file now says unknown counts as degraded — that stops a loop that could not measure"
else
    ok "and nothing readmits unknown as a degraded verdict"
fi
assert_in "$deg_flat" 'healthy` is not degraded either' \
    "healthy is not degraded either, so a stuck-but-healthy repo stays STALLED's question"

# The three shapes the issue names as MUST-NOT-TRIGGER. Each is a normal state
# the loop already handles, and firing on any of them stops a loop that was
# about to make progress.
assert_in "$deg_flat" 'red' \
    "a red check is named as not-degraded — it has its own redispatch path"
assert_in "$deg_flat" 'pending' \
    "a genuinely pending check is named as not-degraded"
assert_in "$deg_flat" 'foreign' \
    "an active foreign claim is named as not-degraded"

# Two-tick confirmation, and its OWN record file. Sharing the stall record would
# let either confirmation clear the other's clock.
assert_in "$deg_flat" 'dispatch-ready-degraded.json' \
    "the degraded record is its own file, not the stall record"
if printf '%s' "$deg_flat" | grep -q 'dispatch-ready-stall.json'; then
    bad "DEGRADED writes the STALL record — the two clocks would clear each other"
else
    ok "and it never writes dispatch-ready-stall.json"
fi
assert_in "$deg_flat" 'second degraded tick ends the loop' \
    "a single degraded tick does not stop the loop (acceptance 2)"

# ONE stop path. A second cancel implementation is the defect, not the feature.
assert_in "$deg_flat" 'same stop path as DRAIN COMPLETE' \
    "it reaches the EXISTING stop path — one path, never a parallel one"
if printf '%s' "$deg_flat" | grep -qi 'CronDelete'; then
    bad "DEGRADED carries its own cron-cancel logic — that is a parallel stop path"
else
    ok "and carries no cancel logic of its own"
fi

# Recovery resets the clock; `unknown` must NOT, or one unreadable status page
# resets a genuine outage count indefinitely.
assert_in "$deg_flat" 'reads a `healthy` verdict deletes a leftover' \
    "a healthy verdict clears the degraded record"
assert_in "$deg_flat" 'unknown` verdict [*][*]leaves the record alone[*][*]' \
    "an unknown verdict does NOT clear it, so it cannot reset the count forever"

# COMPLETE and STALLED are untouched (acceptance 5). Their conjunct sentences
# are pinned by canon above; this asserts the CONJUNCTS themselves still read
# as they did, which is the half a reader checks.
# SCOPED TO THEIR OWN WINDOWS, not to `sec7_flat`, since #342: DEFERRED's first
# conjunct spells STALLED's opening words verbatim, so a section-wide read of the
# second would be satisfied by the new section while STALLED's own opening said
# anything at all.
assert_in "$complete_flat" 'Ready empty AND in-flight zero AND nothing still claimed' \
    "COMPLETE's conjuncts are unchanged"
assert_in "$opening_flat" 'In-flight zero AND dispatched zero this tick' \
    "STALLED's conjuncts are unchanged"

# --- 7c. DRAIN DEFERRED (issue #342) ------------------------------------------
# THE STATE #341 MADE REACHABLE. A `site:` label that names another machine holds
# a Ready item here, and that hold reaches §7 like any other — but it is neither
# self-resolving nor a human gate, so both of the states it could have landed in
# are wrong about it. STALLED is the one it landed in, and its announcement tells
# the operator to resolve a gate this checkout cannot.
#
# THE ROWS BELOW ARE IN TWO HALVES, and the second is the one a "these are the
# same state" sweep deletes: the DEFERRED half (this state exists, names the
# site, takes COMPLETE's stop path and is never STALLED) and the DISCRIMINATION
# half (a held set carrying anything else is STILL STALLED). A gate that pins
# only the first is satisfied by a §7 that answers DEFERRED for every stall.
#
# NEEDLES ARE PINNED THROUGH THEIR TERMINATOR, the lesson test-site-filter.sh's
# header records: a needle that stops mid-sentence is satisfied by a qualifying
# clause that inverts the rule, and the deletion mutant cannot see it because the
# phrase it deletes is still there. THIS PARAGRAPH SHIPPED BEFORE IT WAS TRUE —
# nine of these rows stopped mid-sentence in the first edition, and a review
# measured each one passing a qualifier that inverted it, the stop-path row's
# ("but skip the cron self-cancel on it") leaving a cron drain ticking forever on
# a site-held column. Every fixed-string needle now runs to its `.`, `.**` or
# `:`, and every one carries a QUALIFICATION mutant beside its deletion mutant in
# the battery, which is the only measurement that tells the two apart.
section deferred "a site-held Ready column ends the loop by name, and never as a stall"

# ORDER is the decision, not presentation: DEFERRED is STALLED plus one test, so
# evaluating STALLED first leaves it unreachable. Pinned two ways — the prose
# rule and the physical position of the heading — because either alone drifts
# away from the other, which is #286's own reasoning one state over.
assert_has "$deferred_flat" \
    '**Evaluated BEFORE STALLED, and the order is the rule rather than a presentation choice.**' \
    "DEFERRED is evaluated before STALLED, and says so"
def_line="$(grep -n '^### DRAIN DEFERRED' "$SKILL" | cut -d: -f1)"
cmp2_line="$(grep -n '^### DRAIN COMPLETE' "$SKILL" | cut -d: -f1)"
stl_line="$(grep -n '^### DRAIN STALLED' "$SKILL" | cut -d: -f1)"
if [ -n "$def_line" ] && [ -n "$cmp2_line" ] && [ -n "$stl_line" ] &&
   [ "$cmp2_line" -lt "$def_line" ] && [ "$def_line" -lt "$stl_line" ]; then
    ok "and it physically sits between COMPLETE and STALLED, so a reader meets it first"
else
    bad "DRAIN DEFERRED is not between COMPLETE and STALLED (cmp=$cmp2_line def=$def_line stl=$stl_line)"
fi
# DEGRADED needs no ordering against this one, and saying why is what stops a
# later sweep widening #286's "evaluated first" rule to cover a state it cannot
# reach: the two disagree on in-flight, so they are disjoint by construction.
assert_has "$deferred_flat" \
    'DEGRADED cannot compete for it: that state requires in-flight non-zero and this one requires in-flight zero, so the two are disjoint by construction and the order between them decides nothing.' \
    "and the disjointness from DEGRADED is stated rather than left to be re-derived"

# THE FOUR CONJUNCTS, each through its terminator. The fourth is the whole state.
assert_has "$deferred_flat" \
    '**Ready is non-empty.** An empty Ready column is never this state — COMPLETE when nothing is held, STALLED when something is.' \
    "DEFERRED requires a non-empty Ready column, and routes an empty one by what is held"
assert_has "$deferred_flat" \
    '**Every remaining Ready item is held by §4'"'"'s Site filter** — its `sites` is non-empty and does not contain this checkout'"'"'s `execution_site`.' \
    "every remaining Ready item must be site-held — one dispatchable item and this is not the state"
assert_has "$deferred_flat" \
    '**The held set holds nothing else.** No held PR, no dependency hold, no `blocked` label, no collision or migration hold.' \
    "the held set must hold nothing but site holds (the fourth conjunct)"
assert_has "$deferred_flat" \
    'One hold of any other kind and the state is STALLED, with the site holds listed among its reasons.' \
    "and one hold of any other kind hands the tick back to STALLED — the discrimination half"
# A FOREIGN CLAIM IS NOT ONE OF THOSE HOLDS, and the file used to say both things
# at once: conjunct 4 counted it among the holds that force STALLED, while
# STALLED's own carve-out keeps the loop ALIVE on it. The shape that reaches the
# disagreement is this feature's own — two checkouts draining one repo, Ready
# holding a site-held item and a foreign-claimed one, which §4's Claimed filter
# separates before Site ever runs. Both sentences being canon-pinned, the gate
# would otherwise freeze the contradiction rather than catch it.
assert_has "$deferred_flat" \
    '**An active foreign claim is not such a hold** — it is another session'"'"'s in-flight, it resolves when that session merges, and STALLED'"'"'s own carve-out already keeps the loop alive on it, so a tick holding one reaches no terminal state at all, this one included.' \
    "an active foreign claim routes to keep-looping, never to this state or to STALLED"
# WHAT CONJUNCT 4 CAN SEE. §4's filters run in order and each SKIPS, so a
# site-mismatched item never reaches Dependencies or Collision and its own
# dependency hold is never recorded. Stated rather than left implicit, because
# the closing promise below is bounded by it.
assert_has "$deferred_flat" \
    '**Conjunct 4 speaks of the holds this tick RECORDED, never of every hold an item might carry.**' \
    "and conjunct 4 is scoped to the holds this tick actually recorded"

# WHY IT IS ITS OWN STATE. Both halves of the reason are pinned: a later sweep
# that folds this back into STALLED has to delete a sentence saying it cannot.
assert_has "$deferred_flat" \
    'A site hold is neither self-resolving nor a human gate for THIS loop, which is why it is a state of its own rather than a STALLED variant.**' \
    "the state names both reasons it is not a STALLED variant"
assert_has "$deferred_flat" \
    'It is not self-resolving: this checkout will never satisfy it, so a confirmation clock would count forever.' \
    "and says why it is not self-resolving, which is also why it takes no confirmation tick"
assert_has "$deferred_flat" '**Never report this state as STALLED.**' \
    "reporting it as STALLED is refused in as many words"
# The measured harm is STALLED's own cancel line arriving here — an operator told
# to resolve a gate on a checkout that cannot. The DEFERRED window may describe
# that harm; it may not instruct it. This is a LITERAL check against STALLED's
# wording, not a polarity judgement.
assert_absent "$deferred_flat" 'resolve the gate\(s\), then restart the drain' \
    "DEFERRED never issues STALLED's cancel instruction"
assert_absent "$deferred_flat" 'dispatch-ready-stall\.json' \
    "and never writes the stall record by name"
# THE VETO ABOVE PINS A FILENAME, WHICH IS NOT THE RULE: "write the stall record
# from here too" satisfies it while inverting it. The instruction itself is the
# must-exist, and it runs to its terminator.
assert_has "$deferred_flat" \
    'Write no stall record and no degraded record from here — both clocks belong to states that are still moving.' \
    "and says so as an instruction, not only by the filename it must not name"

# NO CONFIRMATION TICK, modelled on COMPLETE rather than on the state beside it.
assert_has "$deferred_flat" '**No confirmation tick, exactly as COMPLETE takes none.**' \
    "DEFERRED announces on the tick that reaches it, as COMPLETE does"
assert_has "$deferred_flat" \
    'A site declaration cannot change what this checkout IS: a second tick re-reads the same `sites` against the same `execution_site` and reaches the same answer.' \
    "and states why a second tick would measure nothing new"

# THE ANNOUNCEMENT the loop prints, verbatim, and the site it must name.
assert_wline "$deferred_raw" '^DRAIN DEFERRED — remaining Ready items require a site this checkout does not hold$' \
    "the verbatim DEFERRED announcement is present (acceptance 1)"
assert_has "$deferred_flat" \
    'naming the site each remaining item requires — **all** of an item'"'"'s `sites` when it declares more than one, so the operator can see which checkout to run the drain from:' \
    "and it names every site an item declares, so the operator knows which checkout to run"

# ONE stop path, and the cron self-cancel is part of it (acceptance 2). A second
# cancel implementation is the defect, not the feature — #286's rule, reused.
# THROUGH THE TERMINATOR, and this is the row where that matters most: with the
# needle stopping at `DRAIN COMPLETE`, "but skip the cron self-cancel on it"
# passes this row, the CronDelete-absent veto and the report-line row — and a
# cron drain then ticks forever on a site-held column, which is the failure this
# whole gate family exists for. Measured.
assert_has "$deferred_flat" \
    'Then take the **same stop path as DRAIN COMPLETE** below — one path, never a parallel one, and the cron self-cancel is not optional on it.' \
    "it reaches the EXISTING stop path — one path, never a parallel one, cron self-cancel included"
if printf '%s' "$deferred_flat" | grep -qi 'CronDelete'; then
    bad "DEFERRED carries its own cron-cancel logic — that is a parallel stop path"
else
    ok "and carries no cancel logic of its own"
fi
assert_has "$sec7_flat" \
    'after DEFERRED: `Loop <id> cancelled — run the drain from a checkout those items name.`' \
    "the stop path's cron branch carries DEFERRED's own report line"

# THE DISCRIMINATION HALF, from STALLED's side. Written only here, it would be a
# rule the state it constrains never states; written only there, DEFERRED would
# be a state nothing routes to. Both windows carry it.
assert_has "$gate_flat" \
    '**A held set of nothing but site holds is DEFERRED, not STALLED**, and that state is evaluated first.' \
    "STALLED hands a site-only held set to DEFERRED, and says so in its own window"
assert_has "$gate_flat" \
    'A dependency hold, a `blocked` label, a held PR, a collision or migration hold, an `isolation unconfirmed` hold — any one of them and this is STALLED, with the site holds listed among its reasons.' \
    "and STALLED keeps every other held set, site holds included among its reasons"

# The rails are the file's last word on self-cancelling, and they enumerate per
# state. A state missing from them is a state the rails silently permit.
# THE RAIL'S TWO ANSWERS ARE SEPARATE, and its first edition ran them together:
# "one hold of any other kind … or an active foreign claim … stay alive" put a
# human-clearable hold — which routes to a state that SELF-CANCELS — on the same
# side as a foreign claim, which must keep the loop going. Split, and both
# terminators pinned.
assert_has "$rails_flat" \
    'For DEFERRED, a Ready item this checkout may take, any dispatch, any in-flight work or an active foreign claim means the loop may still make progress — stay alive.' \
    "the safety rails' DEFERRED clause ENDS in stay-alive for everything that can still move"
assert_has "$rails_flat" \
    'A hold a human could clear is a different answer entirely: the tick is STALLED rather than deferred, which is a terminal state of its own reached by its own two-tick confirmation, and never a reason to keep looping.' \
    "and routes a human-clearable hold to STALLED rather than to stay-alive"


# --- 8. structure: four terminal states, one stop path, and the inventories ---
section stoppath "the shape of section 7 is itself canonical"

# #282 added coverage, not a state; #286 added the third deliberately and #342
# the fourth. The assertion is rewritten rather than deleted, because its job was
# never "two" — it was that the count cannot move without somebody saying so. It
# is tied to the headings, so a fifth state, or a lost one, fails HERE as well as
# in the heading inventory: a prose count and a structural count that can
# disagree is exactly the free-floating number this repo keeps being bitten by.
assert_in "$sec7_flat" 'A drain loop ends itself in exactly four states' \
    "the prose states the terminal-state count, and #342 made it four"
n_drain_headings="$(printf '%s\n' "$sec7" | grep -c '^### DRAIN ')"
assert_eq "$n_drain_headings" "4" \
    "and §7 holds exactly four DRAIN headings, so prose and structure agree"

# LAYER 2. An inserted paragraph writes #282's bug back four lines under the
# canon forbidding it and every equality check still passes — measured. These
# three lists are what make insertion, deletion and reordering visible.

# Example identifiers by SHAPE: renumbering a worked example changes no decision.
assert_wline "$announce_raw" '^DRAIN STALLED — nothing dispatchable, nothing in flight, and nothing this loop may advance:$' \
    "the STALLED announcement's headline covers a PR-only held set"
assert_wline "$announce_raw" '^  PR #[0-9]+ \(#[0-9]+\) → open, issue blocked \(.*redispatch spent\)$' \
    "the announcement carries a PR row naming the PR and its gate (acceptance 1)"
assert_absent "$announce_flat" 'all Ready items gate on human action' \
    "the announcement no longer asserts Ready holds the held set"
assert_wline "$sec6" '^holds:.*· PR #[0-9]+ \(open, #[0-9]+ blocked\)$' \
    "the tick report's holds line carries held PRs, not issues alone"
assert_in "$sec6_flat" 'carries \*\*held PRs alongside held issues\*\*' \
    "section 6 states that held PRs render on the holds line"
assert_in "$sec6_flat" 'drawn from §2.s enumeration' \
    "section 6 sources held PRs from section 2, which runs on every tick"

# --- 9. the premise -----------------------------------------------------------
section premise "the three cross-file facts the whole account rests on"

assert_has "$claim_block" '--remove-label "$READY_LABEL"' \
    "issue-claim.sh block strips ready"
assert_has "$claim_block" '--remove-label "$INPROG_LABEL"' \
    "issue-claim.sh block strips in-progress — the half that empties in-flight"
assert_has "$claim_block" '--add-label "$BLOCKED_LABEL"' \
    "issue-claim.sh block adds blocked"
# The bullet promises a human learns WHY, which rests on `block` refusing to run
# without a comment — a second cross-file fact, and one that lives in argument
# parsing rather than in the `block)` case the window above reads (#290).
assert_in "$claim_require" 'requires --comment' \
    "issue-claim.sh block refuses to strip a claim silently, which the CONFLICTING bullet relies on"
# THE ECHO IS NOT THE GUARD. The line above pins the message; this one pins the
# `exit 64` that makes it binding, and the split is the whole assertion.
# Measured: deleting the exit alone — so `block` PRINTS the warning and then
# strips `ready`+`in-progress` and adds `blocked` with no comment — left the run
# at all green. An assertion written by grepping the literal a mutation deletes
# is the tautology `scripts/test-sentry-verification.sh`'s header records this
# repo losing to every round, and it was reintroduced here in the assertion
# added to close exactly that (#290).
assert_has "$claim_require" 'exit 64' \
    "the require-comment guard EXITS, rather than printing and continuing"
# The third fact, and the only thing withholding a just-demoted PR from the
# merger on the tick that demotes it: the hand-off bullet's `blocked` predicate
# reads state this bullet has not written yet, so `merge-shepherd.sh` refusing a
# conflicted PR AHEAD of the queue, stack, no-checks and red gates is what
# actually holds it. Position is the assertion — the arm alone would still pass
# if it moved below the merge.
assert_has "$shepherd_open" 'CONFLICTING' \
    "merge-shepherd refuses a CONFLICTING PR, which is what withholds it on the demotion tick"
sh_conf="$(grep -n 'CONFLICTING' <<<"$shepherd_open" | head -1 | cut -d: -f1)"
sh_queue="$(grep -n 'IN_QUEUE' <<<"$shepherd_open" | head -1 | cut -d: -f1)"
if [ -n "$sh_conf" ] && [ -n "$sh_queue" ] && [ "$sh_conf" -lt "$sh_queue" ]; then
    ok "merge-shepherd's CONFLICTING arm sits ahead of the other OPEN gates"
else
    bad "merge-shepherd's CONFLICTING arm no longer precedes the other OPEN gates"
fi

# --- the registry, the consumption check, and the floor ----------------------
# `registry` is itself a declared member, so this block's own assertions sit
# UNDER the derived floor: deleting it drops the run below `ASSERT_FLOOR` even
# though the loop that would have reported the deletion is what was deleted.
# The per-section loop skips `registry`, whose count is not closed until after
# it runs.
section registry "the canon is fully consumed and every declared section ran"
# `registry` is not in SECTIONS, so the loop below cannot check it; its own
# minimum is verified after `_close_section`, against REGISTRY_MIN.

# LAYER 3. Every canonical entry must be consumed by exactly one assertion, so
# deleting an assertion block fails even if its section registration goes with
# it — its canon entries go unconsumed.
canon_keys="$(awk -F'\t' 'NF { print $1 }' <<<"$(canon_table)" | sort)"
used_all="$(tr ' ' '\n' <<<"$consumed" | sed '/^$/d' | sort)"
used_uniq="$(tr ' ' '\n' <<<"$consumed" | sed '/^$/d' | sort -u)"
assert_eq "$used_all" "$used_uniq" \
    "every canonical entry is consumed at most once"
assert_eq "$used_uniq" "$canon_keys" \
    "every canonical entry is consumed by an assertion"

for entry in "${SECTIONS[@]}"; do
    want="${entry%%:*}"
    min="${entry##*:}"
    found=0
    count=0
    i=0
    while [ "$i" -lt "${#ran_names[@]}" ]; do
        if [ "${ran_names[$i]}" = "$want" ]; then
            found=1
            count="${ran_counts[$i]}"
        fi
        i=$((i + 1))
    done
    case "$min" in
        ''|*[!0-9]*) bad "section '$want' declares a non-numeric minimum '$min'"; continue ;;
    esac
    if [ "$found" -eq 0 ]; then
        bad "declared section '$want' never ran — its block has been deleted"
    elif [ "$count" -lt "$min" ]; then
        bad "section '$want' ran $count assertions, below its declared $min — it has been trimmed"
    else
        ok "section '$want' ran $count assertions (declared $min)"
    fi
done

_close_section
i=0
while [ "$i" -lt "${#ran_names[@]}" ]; do
    if [ "${ran_names[$i]}" = "registry" ] && [ "${ran_counts[$i]}" -lt "$REGISTRY_MIN" ]; then
        echo "test-drain-terminal-states: the registry block ran ${ran_counts[$i]} assertions, below its declared $REGISTRY_MIN" >&2
        fails=$((fails + 1))
    fi
    i=$((i + 1))
done

# Derived from the per-section minimums above, never transcribed.
if [ "$asserts" -lt "$ASSERT_FLOOR" ]; then
    echo "test-drain-terminal-states: only $asserts assertions ran (derived floor $ASSERT_FLOOR) — a window or a block is silently matching nothing" >&2
    exit 1
fi

if [ "$fails" -ne 0 ]; then
    echo "test-drain-terminal-states: FAILED ($fails of $asserts assertions)" >&2
    exit 1
fi
echo "drain terminal-state tests: all green ($asserts assertions)"
