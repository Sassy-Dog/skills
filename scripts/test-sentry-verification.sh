#!/usr/bin/env bash
# test-sentry-verification.sh — pins setup-config's Sentry project VERIFICATION
# decision and the `sentry: none` contract exception (issue #213).
#
# Why a source-level guard and not a render test. Nothing here is executed by a
# script: `setup-config` is a generator whose Sentry rule is prose an agent
# follows, so the artifact under test is the instruction itself — the same shape
# as test-visibility-preconditions.sh (setup-deps' two preconditions) and
# test-label-migrate.sh (align-labels.sh's single-call-site invariant).
#
# The bug it guards. A Sentry project slug and a GitHub repo can share a name and
# belong to DIFFERENT codebases — a marketing-site repo `<product>-web` beside a
# Sentry project `<product>-web` fed by a member-app frontend living elsewhere.
# The old rule ("list projects for the org to propose {{SENTRY_PROJECTS}}") made
# name similarity the only evidence, which is also the evidence an agent reaches
# for first. Every consequence is invisible after the fact: the wrong repo claims
# another codebase's P0s, two repos double-report the same issues, `take-it` is
# dispatched at a repo holding no such route — and BOTH plates still render
# complete, so nothing signals the error.
#
# Four decisions are pinned, and the last three are the fragile ones:
#
#   A. Verification is by CULPRIT, not by name, and a failed verification writes
#      `sentry: none` rather than a guessed block.
#   B. `sentry: none` is the config contract's FIRST documented exception to
#      "presence is the toggle". That exception is exactly the kind of prose a
#      later "align with the governing principle" sweep deletes as an
#      inconsistency — it reads like drift and is in fact the decision.
#   C. The `none` form now spans FOUR keys and is deliberately ASYMMETRIC across
#      them (issue #261): `sentry: none` keeps its blind-spot row, while
#      `testflight: none`, `posthog: none` and `mobile: none` render one `(n/a)`
#      token on the clean line and no row at all.
#   D. The CARRY-FORWARD carve-out covers those same three and NOT `sentry:`
#      (issue #268). `setup-config` writes `sentry: none` when the culprit check
#      merely COULD NOT RUN — no MCP server, no issues to sample — so freezing it
#      lets one unlucky session permanently retire the plate's highest-signal
#      surface, the only contradicting evidence being the check the carve-out
#      just skipped. The three/four split is asserted on all four sites that
#      state it: `SKILL.md`'s Guardrails list (which AGENTS.md names as the copy
#      to trust), `SKILL.md` Phase 4, `config-contract.md`, and `update-mode.md`.
#      #267 added `sentry:` to the guardrail list while removing it from the
#      other two, so the same file contradicted itself forty lines apart and
#      nothing here noticed.
#
# Why C needs a gate rather than a paragraph. A four-key form where one key
# behaves differently reads as a plain inconsistency, so it is precisely what a
# tidying sweep "fixes" — in either direction, and both directions are silent.
# Collapsing `sentry: none` onto the clean line restores the gap #213 opened the
# form to close: a repo with no error monitoring stops being told so. Promoting
# the other three back into rows restores #261: an infra repo with no app carried
# three permanently unclearable rows on every plate, two of them in the loudest
# position the section has, which is how a reader learns to skim the heading that
# a genuinely dark Sentry lives under.
#
# The four-key table is checked by COUNTING its rows, not by looking up the four
# names — a lookup passes just as happily on a table that grew a fifth key or
# lost one, and "how many keys behave which way" is the whole decision.
#
# SIX ways this gate was MEASURED reporting a clean tree on a source stating the
# inverse. Every one is a scoping error, and every fix is the same shape:
#
#   * §6's Confirmed-N/A rule stated BOTH outcomes inside ONE window, so neither
#     was pinned (issue #268). Replacing "**`sentry: none` is the deliberate
#     exception and keeps its blind-spot row**" with "…is aligned with the other
#     three and takes the clean line too" left this gate GREEN — deleting
#     sentry's affirmation made the three-key row veto MORE likely to pass, not
#     less. #213's gap restored in the one section an agent follows when
#     rendering, and §3A was already carrying the identical lesson. The block is
#     now cut at the key literal, sentry's half carrying the INVERTED
#     expectations, and that half must never be folded back into the loop.
#   * The `### Blind spots` rules were checked by CO-OCCURRENCE — `sentry: none`
#     anywhere in the subsection AND `produces a row` anywhere in it — so
#     swapping which key gets the row satisfied both halves and stayed GREEN.
#     Split per key, same shape as §6.
#   * §3A's `sentry:` rule was covered by nothing, because the per-key loop runs
#     over the three clean-line keys only. Rewriting §3A to put `sentry: none` on
#     the clean line left this gate GREEN — the headline decision unpinned in the
#     one section the loop calls authoritative. It now has its own block with the
#     expectations INVERTED, and the loop must never be widened to swallow it.
#   * The per-key windows read the whole flattened file, so they landed on §6's
#     prose and a reverted §3 probe rule read as covered. Windows are scoped to
#     §3.
#   * `update-mode.md`'s rule was checked file-wide for 'stop and surface', which
#     step 1's unrelated rename-collision rule already satisfies. Inverting the
#     rule to "always silently rewrite a `none`" left it printing ok. Windowed.
#   * §2c's per-key check was a bare `grep -q "$key"`, which its own rationale
#     sentence satisfies ("an absent mobile app is a product fact"). It now
#     requires the literal `<key>: none` the question actually writes.
#
# HOW THIS GATE WAS MEASURED, and the methodology lesson, which is the part worth
# keeping. FOUR review rounds have each found assertions here passing on sources
# that state the inverse, and the reason the author's own mutation set kept
# reporting "all detected" is that every mutation was written by deleting the
# exact literal its assertion greps for. Such a set is tautologically caught: it
# proves `grep` works, not that the assertion pins a decision. A mutation must
# invert the MEANING and be worded the way a tidying editor would word it —
# different verb, different emphasis, different sentence shape.
#
# **NO INVENTORY NUMBER IS CARRIED HERE, DELIBERATELY.** This header used to
# claim a mutation count and an assertion count; both were wrong, and AGENTS.md
# repeated one of them into the one place a future editor trusts instead of
# re-measuring (issue #268). A number nobody can re-derive from the tree is not
# worth carrying. The run prints its own assertion count, and the mutation
# batteries live in the PR that added them — re-measure rather than transcribe.
#
# The failure family is always the same:
#
#   * NEGATION-BLINDNESS, and the two failed attempts at fixing it. `grep -qi
#     'blind-spot row'` matches inside "**no** blind-spot row". Vetoing the word
#     `no` anywhere in the window was tried three times and defeated each time,
#     because it vetoed a negator that merely SHARED the window rather than one
#     GOVERNING the mention. The six-verb affirmative that replaced it enumerated
#     an OPEN class, so `plus a blind-spot row in §6` and `also produces` evaded
#     it while the correct rewords `keeps a blind-spot row` and `gets its own
#     blind-spot row` reddened the gate on prose that was RIGHT — measured, six
#     correct edits turned `main` red. Destinations are now matched
#     verb-independently and each mention is classified against its own bounded
#     left context, against a negator set whose CORE is a closed grammatical
#     class, resolved by polarity rather than by list length. See `dest_tally`.
#   * A MARKER IS NOT A DESTINATION. `\(n/a\)` sat inside the clean-line
#     vocabulary, so "they appear under Blind spots with an explicit `(n/a)`
#     marker" satisfied a clean-line assertion, and §3A's Sentry rule reddened
#     the moment it named the marker it must not use. Separate constants now.
#   * POLARITY, NOT A LONGER LIST. `is not exempt from a blind-spot row` AFFIRMS
#     the row, and `exempt`/`excluded`/`omitted` are words this file's own header
#     cites as natural here — so reading them as negations put the inverse of
#     #261 past both the `'0'` and the stricter `'-'` veto at every call site.
#     The fix is `cancelled()`: a second negator governing the first flips the
#     polarity back. Adding words to the negator list is the move that feels
#     like the fix and is not — that is what the six-verb `BLIND_AFFIRM` did.
#   * SILENCE IS NOT A NEGATION. `'0'` tested only "nothing affirmed", so a rule
#     whose negative clause drifted out of its window scored 0/0 and the veto
#     printed `ok` while measuring nothing. Rules that STATE a negative now use
#     `'-'`, which requires the negation to be present and measured.
#   * WINDOW SIZING, wrong in both directions: 460 bytes read half of a ~930-byte
#     rule and a must-not-exist slipped past; 400 bytes let one key's assertions
#     be satisfied by the next key's rule, ~158 bytes away. Hence `window_between`
#     and the structural `No key at all` bound. And a cap that binds BEFORE its
#     stop marker is the same defect wearing the other face — `carry_win`'s last
#     asserted phrase ended at byte 933 of a 937-byte window — so
#     `window_is_bounded` now asserts every such window ends where it says it
#     does.
#   * A WINDOW THAT IS RIGHT FOR ONE CHECK IS WRONG FOR ANOTHER. The `none`
#     clause is the right scope for "does it keep its row"; it is the wrong scope
#     for "does this rule ever mention the clean line", because a contradictory
#     clause appended to the rule's absent-key half lands outside it. Both scopes
#     are asserted.
#   * TALLYING IS NOT CLASSIFYING. Counting two patterns left a fifth key whose
#     behaviour column matched neither invisible — and the row filter keyed on a
#     backtick, so a row a human hand-adds without code formatting was invisible
#     too. Every row must be ACCOUNTED FOR.
#   * PREFIX ANCHORS. `grep -qi 'cannot re-derive is the'` is satisfied by
#     "…is the **surface**", the exact inversion of "…is the **confirmation**".
#   * A MENTION IS NOT A COMMITMENT. `grep -qi 'migrate mode'` was satisfied by a
#     sentence *demoting* migrate mode, so the check now requires the list entry.
#   * EMPHASIS. `The exception is scoped to **`sentry:`** alone.` slipped past a
#     check on the plain flatten, so must-not-exist checks also run against an
#     emphasis-stripped copy.
#
# Two more traps worth naming. The example-block must-not-exist check reads a
# FLATTENED copy: markdownlint's MD013 is off here, so a hard-wrapped row is
# invisible to a line-scoped grep — measured both ways. And a `\`` inside a
# double-quoted `ok`/`bad` message is COMMAND SUBSTITUTION, not a literal: three
# messages in this file ran `sentry: none` as a command before they were escaped.
#
# The prior-claim sibling scan is pinned as SECONDARY on purpose: promoting it to
# the guard would re-open the hole in every cloud session, which has no sibling
# checkouts on disk and so finds nothing while reporting nothing.
#
# Must-not-exist assertions run against a WHITESPACE-FLATTENED copy of the file.
# This repo hard-wraps prose, so forbidden wording routinely straddles two lines
# and a line-scoped grep reports a FALSE PASS. (Must-exist checks may stay
# line-scoped: a wrap there fails loudly, which is safe.)
#
# Every `grep -q` here reads a here-string, never a pipe — the shape
# scripts/test-pipefail-grep.sh requires since issue #571. Before that each was
# fed by a single-argument `printf`, and it was safe HERE for a MEASURED reason
# (an earlier version of this file asserted a size limit that does not exist):
# `printf '%s' "$one_unterminated_line" | grep -q` returns 0 at 64KB, 256KB, 1MB
# and 4MB on both bash 3.2.57 and 5.3.15, because `grep -q` cannot exit early on
# a line whose terminator it has not seen — and `tr '\n' ' '` makes every
# haystack here exactly one unterminated line. A COMMAND writer emitting many
# lines returns 141 at 64KB, and a builtin writing two or more lines can at any
# size (#571); the guard sees neither size nor line count, which is why its rule
# is syntactic and why the safety of this file's old shape could not be checked.
#
# No gh, no network, no repo mutation — it reads eight tracked files.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-sentry-verification.sh
set -uo pipefail
export LC_ALL=C

# This file reads ITSELF for one assertion — the structural subset check beside
# the classifier battery. It must be the RUNNING script, not the tracked path:
# a literal `scripts/test-sentry-verification.sh` here reads the file on disk
# whatever copy is executing, so every mutant of that check passed while
# measuring the unmutated source — the vacuity this whole file is written
# against. Resolved before the `cd`, since `$0` may be relative to the caller.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-sentry-verification: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

DETECTION="skills/setup-config/references/detection.md"
CONTRACT="skills/setup-config/references/config-contract.md"
SKILL="skills/setup-config/SKILL.md"
TEMPLATE="skills/setup-config/references/templates/survey-work.config.md"
INTERVIEW="skills/setup-config/references/interview.md"
UPDATE="skills/setup-config/references/update-mode.md"
MIGRATE="skills/setup-config/references/migrate-mode.md"
PLATE="skills/survey-work/SKILL.md"

fails=0
asserts=0
ok()  { asserts=$((asserts + 1)); echo "  ok    $1"; }
bad() { asserts=$((asserts + 1)); echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "Sentry verification + the four-key \`none\` form (issues #213, #261)"

# THE READ SET IS AN ARRAY, and that is the whole of #278. It was eight
# variables iterated as literals, so its length existed nowhere and the count
# was restated across three files with nothing recomputing it. Adding a file
# here now moves every restatement, because the counts section below derives
# from `${#READS[@]}` and reddens each site that disagrees.
READS=("$DETECTION" "$CONTRACT" "$SKILL" "$TEMPLATE" "$INTERVIEW" "$UPDATE" "$MIGRATE" "$PLATE")
for f in "${READS[@]}"; do
    [ -r "$f" ] || bad "missing file: $f — if a document was renamed, move READS with it, then the tracked-file count and each of its restatement sites"
done
[ "$fails" -eq 0 ] || { echo "test-sentry-verification: FAILED" >&2; exit 1; }

# Re-join each hand-check bullet into ONE record, so "same bullet" is the unit of
# every check below. Flattening the whole section instead would let 'culprit' in
# one bullet satisfy a claim about another.
handchecks="$(awk '/^## Hand checks the script/{f=1; next} /^## /{f=0} f' "$DETECTION")"
[ -n "$handchecks" ] || bad "cannot locate detection.md's '## Hand checks' section"
bullets="$(printf '%s\n' "$handchecks" |
    awk '/^- /{if (b != "") print b; b=$0; next} {b = b " " $0} END{if (b != "") print b}')"
# `tr -s ' '` because the join preserves each continuation line's indentation,
# so a phrase that wrapped mid-sentence carries a run of spaces inside it.
culprit_bullet="$(printf '%s\n' "$bullets" | grep -i 'Sentry project' | tr -s ' ')"
claim_bullet="$(printf '%s\n' "$bullets" | grep -i 'prior-claim' | tr -s ' ')"

# --- A. Verification is by culprit, against THIS repo -------------------------

if [ -n "$culprit_bullet" ]; then
    ok "detection.md carries a Sentry project hand-check"
else
    bad "detection.md has no Sentry project hand-check bullet"
fi

if grep -qi 'culprit' <<<"$culprit_bullet"; then
    ok "the Sentry hand-check verifies by culprit"
else
    bad "the Sentry hand-check does not mention culprit — name match is back"
fi

# The culprit has to be resolved against the repo being configured. A rule that
# samples culprits and never checks them against this tree proves nothing.
if grep -qiE 'resolve in the repo being configured|resolve in this repo' <<<"$culprit_bullet"; then
    ok "culprits must resolve in the repo being configured"
else
    bad "the hand-check never requires culprits to resolve in THIS repo"
fi

if grep -qi 'name similarity is not evidence' <<<"$culprit_bullet"; then
    ok "the rule states name similarity is not evidence"
else
    bad "the rule no longer states that name similarity is not evidence"
fi

if grep -qiE 'regardless of what it is called|regardless of (its|the) name' <<<"$culprit_bullet"; then
    ok "a non-matching project is wrong regardless of its name"
else
    bad "the rule lost the 'wrong project regardless of its name' clause"
fi

# Mutation proof: the pre-#213 rule, flattened so a re-wrap cannot hide it.
detection_flat="$(tr '\n' ' ' < "$DETECTION" | tr -s ' ')"
if grep -qi 'list projects for the org to propose' <<<"$detection_flat"; then
    bad "detection.md reverted to the name-match rule (list projects to propose)"
else
    ok "detection.md carries no name-match propose rule"
fi

# --- B. A failed verification writes `sentry: none` ---------------------------

if grep -q 'sentry: none' <<<"$culprit_bullet"; then
    ok "failed verification is routed to \`sentry: none\`"
else
    bad "the hand-check never names \`sentry: none\` as the failure outcome"
fi

if grep -qiE 'never a guessed block|not a guessed block' <<<"$culprit_bullet"; then
    ok "the hand-check forbids a guessed block"
else
    bad "the hand-check no longer forbids writing a guessed block"
fi

# --- C. The prior-claim scan is secondary and non-blocking -------------------

if [ -n "$claim_bullet" ]; then
    ok "detection.md carries the prior-claim sibling scan"
else
    bad "detection.md has no prior-claim sibling scan"
fi

if grep -qi 'secondary' <<<"$claim_bullet"; then
    ok "the prior-claim scan is marked secondary"
else
    bad "the prior-claim scan is no longer marked secondary"
fi

if grep -qiE 'never block|never blocks|non-blocking|never fatal' <<<"$claim_bullet"; then
    ok "the prior-claim scan is non-blocking"
else
    bad "the prior-claim scan no longer states that a miss does not block"
fi

# The REASON is the part a later edit trims as redundant, and losing it is what
# lets someone promote the scan to the guard: it finds nothing in a cloud session
# and says nothing about having found nothing.
if grep -qi 'cloud session' <<<"$claim_bullet" &&
   grep -qi 'sibling' <<<"$claim_bullet"; then
    ok "the scan's secondary status carries its reason (no siblings in a cloud session)"
else
    bad "the prior-claim scan states no reason for being secondary"
fi

if grep -qi 'never be the only guard' <<<"$detection_flat"; then
    ok "the scan is explicitly never the only guard"
else
    bad "detection.md lost the 'never the only guard' rule"
fi

if grep -qi 'already owned' <<<"$claim_bullet" &&
   grep -qi 'confirm' <<<"$claim_bullet"; then
    ok "a prior claim defaults to already-owned and needs explicit confirmation"
else
    bad "a prior claim no longer defaults to owned / requires confirmation"
fi

# --- D. The contract exception ------------------------------------------------

presence_section="$(awk '/^## Governing principle: presence is the toggle/{f=1; next} /^## /{f=0} f' "$CONTRACT")"
[ -n "$presence_section" ] || bad "cannot locate the presence-is-the-toggle section"

exception_section="$(printf '%s\n' "$presence_section" |
    awk '/^### The one exception/{f=1; next} /^## / || /^### /{f=0} f')"

if [ -n "$exception_section" ]; then
    ok "config-contract.md documents the \`sentry: none\` exception"
else
    bad "the \`sentry: none\` exception is gone from config-contract.md"
fi

# It must read AS an exception. Slipped in as though the principle never existed,
# it is indistinguishable from drift and gets 'corrected' away.
if grep -qiE 'first documented exception|one documented exception|first exception' <<<"$exception_section"; then
    ok "the exception is marked as an exception to the principle"
else
    bad "the exception no longer identifies itself as the first exception"
fi

# ...with its reason attached, which is what makes it survive a consistency sweep.
if grep -qi 'verified by culprit' <<<"$exception_section"; then
    ok "the exception carries its reason (culprit verification can fail)"
else
    bad "the exception no longer explains why it exists"
fi

# The three states must stay distinct. Collapsing 'confirmed absent' into
# 'never configured' is the whole thing this form buys.
row_verified=0 row_none=0 row_absent=0
while IFS= read -r row; do
    case "$row" in
        *'block with'*) grep -qi 'surface runs' <<<"$row" && row_verified=1 ;;
        *'sentry: none'*) grep -qi 'blind spot' <<<"$row" && row_none=1 ;;
        *'key absent'*) grep -qi 'blind spot' <<<"$row" && row_absent=1 ;;
    esac
done < <(printf '%s\n' "$exception_section" | grep '^|')
if [ "$row_verified" = 1 ] && [ "$row_none" = 1 ] && [ "$row_absent" = 1 ]; then
    ok "the three-state table distinguishes verified / confirmed-absent / unknown"
else
    bad "the three-state table is incomplete (verified=$row_verified none=$row_none absent=$row_absent)"
fi

# The bare claim a reader meets first must point at the exception, or the section
# contradicts itself for anyone who stops reading at the paragraph.
contract_flat="$(tr '\n' ' ' < "$CONTRACT" | tr -s ' ')"
if grep -qiE 'exception to this principle is `sentry: none`' <<<"$contract_flat"; then
    ok "the 'no \`sentry: false\`' paragraph points forward to the exception"
else
    bad "the 'no \`sentry: false\`' claim stands bare, with no pointer to \`sentry: none\`"
fi

# --- E. The rendered template's header comment --------------------------------

template_header="$(awk '/^<!--/{f=1} f{print} /-->/{if (f) exit}' "$TEMPLATE")"
header_flat="$(printf '%s' "$template_header" | tr '\n' ' ' | tr -s ' ')"

if grep -q 'sentry: none' <<<"$header_flat"; then
    ok "the template header names the \`sentry: none\` form"
else
    bad "the template header asserts presence-is-the-toggle without naming \`sentry: none\`"
fi

# Mutation proof: the pre-#213 sentence, which asserted the bare rule.
if grep -qi 'toggle; there is no `sentry: false`' <<<"$header_flat"; then
    bad "the template header reverted to the bare 'there is no \`sentry: false\`' claim"
else
    ok "the template header carries no bare no-false assertion"
fi

# --- F. SKILL.md agrees with the rule ----------------------------------------

skill_flat="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
if grep -qi 'Sentry slugs via MCP' <<<"$skill_flat"; then
    bad "setup-config/SKILL.md still summarises the check as 'Sentry slugs via MCP'"
else
    ok "setup-config/SKILL.md carries no 'Sentry slugs via MCP' summary"
fi

if grep -qi 'culprit' <<<"$skill_flat" &&
   grep -q 'sentry: none' <<<"$skill_flat"; then
    ok "setup-config/SKILL.md names both the culprit check and \`sentry: none\`"
else
    bad "setup-config/SKILL.md does not agree with the culprit rule"
fi

if grep -qi 'name similarity is not evidence' <<<"$skill_flat"; then
    ok "setup-config/SKILL.md repeats that name similarity is not evidence"
else
    bad "setup-config/SKILL.md dropped the name-similarity warning"
fi

# --- G. The interview's confirm-on-prior-claim prompt -------------------------

q2b="$(awk '/^### 2b\./{f=1; next} /^### /{f=0} f' "$INTERVIEW")"
q2b_flat="$(printf '%s' "$q2b" | tr '\n' ' ' | tr -s ' ')"

if [ -n "$q2b" ]; then
    ok "interview.md carries the prior-claim question"
else
    bad "interview.md has no prior-claim question"
fi

if grep -qi 'already owned' <<<"$q2b_flat" &&
   grep -qi 'confirm' <<<"$q2b_flat"; then
    ok "the prompt defaults to already-owned and requires explicit confirmation"
else
    bad "the prompt no longer defaults to owned / requires confirmation"
fi

# The question must not become "which project is this repo's?" — that is the name
# match wearing a question mark.
if grep -qi 'never ask' <<<"$q2b_flat"; then
    ok "the interview forbids asking the user to pick a project by name"
else
    bad "the interview lost its 'never ask which project' instruction"
fi

# --- H. survey-work renders confirmed-absent distinctly -----------------------

plate_blind="$(awk '/^## ⚠️ Blind spots/{f=1; next} /^## /{f=0} f' "$PLATE")"
# Each `- ` row re-joined into ONE record before it is matched, the same unit
# detection.md's hand-check bullets get above. A line-scoped `grep` over this
# block was a false PASS waiting to happen: MD013 is off in this repo and the
# `sentry: none` row is 261 characters, so rewrapping it across the phrase an
# assertion greps for reports the row as compliant when it no longer is.
# ...and EMPHASIS-STRIPPED, like `contract_bare` and `template_bare`. The two
# must-not-exist vetoes below are defeated by bold otherwise: `has **no** error
# monitoring` passes where the plain spelling fails. Measured both ways.
blind_rows="$(printf '%s\n' "$plate_blind" |
    awk '/^- /{if (b != "") print b; b=$0; next} {b = b " " $0} END{if (b != "") print b}' |
    tr -s ' ' | tr -d '*_')"
none_row="$(printf '%s\n' "$blind_rows" | grep 'sentry: none')"
absent_row="$(printf '%s\n' "$blind_rows" | grep 'no `sentry:` block')"

if [ -n "$none_row" ]; then
    ok "survey-work renders a \`sentry: none\` blind-spot row"
else
    bad "survey-work has no \`sentry: none\` blind-spot row"
fi

if [ -n "$none_row" ] && [ -n "$absent_row" ] && [ "$none_row" != "$absent_row" ]; then
    ok "the confirmed-absent row is separate from the unconfigured row"
else
    bad "the confirmed-absent and unconfigured rows are not distinct"
fi

# Distinct in WORDING, not just in the key it quotes: a confirmed-absent surface
# was not 'NOT checked', and saying so is the collapse this row exists to stop.
if grep -qi 'confirmed' <<<"$none_row" &&
   ! grep -q 'NOT checked' <<<"$none_row"; then
    ok "the confirmed-absent row reads as confirmed, not as unchecked"
else
    bad "the \`sentry: none\` row is worded as an unchecked surface"
fi

# ...and confirmed of the RIGHT thing. `sentry: none` covers a genuine absence
# AND a culprit check that could not run, so the row may claim no *verified*
# project and must not claim the repo has none — a distinction nothing downstream
# can recover once the row has asserted it.
if grep -qi 'verified' <<<"$none_row"; then
    ok "the \`sentry: none\` row claims no VERIFIED project, not an absent one"
else
    bad "the \`sentry: none\` row no longer scopes its claim to verification"
fi

if grep -qiE '(repo|this repo) has no error monitoring' <<<"$none_row"; then
    bad "the \`sentry: none\` row over-claims: it covers a check that could not run too"
else
    ok "the \`sentry: none\` row makes no bare no-error-monitoring claim"
fi

# The same over-claim in detection.md, which is where the value is written.
if grep -qi 'must never be glossed as' <<<"$detection_flat"; then
    ok "detection.md forbids glossing \`sentry: none\` as a plain absence"
else
    bad "detection.md no longer distinguishes an absence from a check that could not run"
fi

# --- I. `none` is ASYMMETRIC across the four keys (issue #261) -----------------
#
# `sentry: none` keeps its blind-spot row; `testflight: none`, `posthog: none`
# and `mobile: none` render one `(n/a)` token on the clean line and no row. Both
# halves are load-bearing and a sweep can break either one silently, so both are
# asserted — never "the three behave alike" on its own, which a table that also
# moved `sentry` onto the clean line would satisfy.
#
# HOW THE ASYMMETRY IS TESTED (issue #268 rewrote this; read before changing it).
#
# A rule is classified by the DESTINATION it sends a key to — the blind-spot row
# or the clean line — and each destination is a noun phrase naming a place. Two
# earlier designs are recorded here because both are tempting and both failed.
#
#   1. "Assert the phrase, then veto the word `no`", tried three times, defeated
#      each time by a rewording: `**no** blind-spot row`, `never`, `does not`,
#      `no such`, `aligned with the other three`. It vetoed a negator ANYWHERE in
#      the window rather than one GOVERNING the mention, so it was wrong in both
#      directions at once.
#   2. The six-verb affirmative `(gets|keeps|renders|carries|receives|earns)…`
#      that replaced it. Verbs are an OPEN class, so `plus a blind-spot row in
#      §6`, `also produces a blind-spot row`, `they get a blind-spot row` and
#      `are given a blind-spot row` all evade it — every one of them correct
#      English — while the two natural rewords `keeps a blind-spot row` and
#      `gets its own blind-spot row` reddened the gate on prose that was RIGHT.
#      A gate that fails on a correct edit teaches the next author to loosen it.
#
# So: the destination is matched verb-independently, and each occurrence is then
# classified AFFIRMED or NEGATED against its own bounded left context. Requiring
# a negator to GOVERN the mention is what the three earlier attempts lacked.
#
# BE PRECISE ABOUT WHY THIS ENUMERATION IS ALLOWED WHEN THE VERB LIST WAS NOT,
# because "the list works after all" is the reading that walks straight back into
# `BLIND_AFFIRM`. The negator set has two parts. Its CORE — no / not / never /
# neither / nor / without / nothing — is a closed GRAMMATICAL class: English does
# not coin new ones, so enumerating it terminates. The rest — exempt / excluded /
# omitted / instead / rather — are lexical, chosen because this repo's prose
# actually uses them, and that half is NOT closed. It is kept short on purpose,
# every addition has to be justified by prose in the tree, and it is never the
# thing doing the work: POLARITY is, which is what resolves `not exempt` and what
# no list of any length can do. Growing the lexical half in place of fixing
# polarity is the failure mode to refuse.
#
# `none` is deliberately NOT a negator. The literal key value sits immediately
# before its own destination in the one rule this gate exists for (``sentry: none`
# … keeps its blind-spot row``), so reading it as a negation inverts that rule.
# Contractions are left out for the same reason: `n.t` also matches `net`, and
# "the net effect is a blind-spot row" would classify as negated. This repo's
# rules are written without contractions; `does not` is covered by `not`.
#
# The marker is NOT a destination. `\(n/a\)` used to sit inside the clean-line
# vocabulary, which let "they appear under Blind spots with an explicit `(n/a)`
# marker" satisfy a clean-line assertion, and made §3A's Sentry rule redden the
# moment it mentioned the marker it must NOT use. It is its own constant now.
ROW_DEST='blind[- ]spot row'
CLEAN_DEST='clean[- ]line|clean today'
NA_MARKER='(n/a)'

# Tally the destination mentions matching ERE $2 in text $1, split into AFFIRMED
# and NEGATED. Prints "<affirmed> <negated>". Emphasis and backticks are stripped
# so `**no**` reads as `no`, and the haystack is lower-cased because awk's ERE
# has no case-insensitive flag.
#
# A negator GOVERNS a mention when it stands in the SAME CLAUSE as it and is not
# itself the head of a prepositional phrase about some other noun. Every clause
# of that rule was forced by a measured counterexample, so none of it is
# decoration:
#
#   * THE BOUND IS THE CLAUSE, NEVER A COUNT (issue #271). All three scans once
#     stopped after four content words — four POSITIONS in `cancelled` — and the
#     unit was wrong in BOTH DIRECTIONS AT ONCE, which is why no value of it
#     works and why this was never a constant to nudge. TOO SHORT: `The three
#     keys do not, in current practice, ever actually produce a blind-spot row`
#     put `not` past the budget and returned 1/0, a QUIET miss on the `'+'`
#     direction that matters. TOO LONG: raising the bounds from four to six
#     reddened the pre-#271 gate, because a wider window starts reaching
#     negators that belong to OTHER clauses — which is why PR #272 recorded the
#     limit in the source instead of tuning it away.
#     NO COUNT OF REDDENED ASSERTIONS IS QUOTED HERE, and the draft that quoted
#     one is why the rule is stated. The number depends on WHICH bounds you
#     raise (the two content-word ones alone give a different answer from all
#     three), one of the assertions it counted is renamed by this very change,
#     and after merge there is no bound left to raise, so nobody can re-derive
#     any of it. What holds the decision up instead is live and one edit away:
#     restoring a count bound to ANY of the three scans reddens the case named
#     for that scan below. So each scan runs until `clause_break` fires or the
#     text runs out, and #270 is SUBSUMED rather than kept beside this: it added
#     a boundary CHECK inside a count, and that check is now the entire bound.
#   * The PREPOSITION test is what an unbounded in-clause scan costs, and it
#     carries more weight now than it did under a budget. `a repo with no Sentry
#     keeps a blind-spot row` is an affirmation — the negator negates `Sentry`,
#     not the row — and it sits in the SAME clause, so no bound of any kind
#     excludes it and only this test does. A negator headed by
#     `with`/`in`/`of`/`for`/… is skipped. It was comment-only until #271 widened
#     the scan past it; the case named for it below asserts it now.
#   * CLAUSE BOUNDARIES, but only strong ones. `render \`skipped — not
#     configured\` **and a blind-spot row in §6**` is the LIVE §3A absent-key
#     rule and is an affirmation; `and` ends the search so it reads that way.
#     `,` and `or` are deliberately NOT boundaries — `does not get, or need, a
#     blind-spot row` is one negation, and treating either as a boundary stops
#     the scan inside the clause it belongs to. ALL THREE scans stop at the same
#     boundary, through one shared `clause_break` (issue #270). Two of them did
#     and `cancelled` did not, which reads as deliberate to a later reader
#     and was not: `that is not so. sentry is exempt from a blind-spot row` let
#     the PREVIOUS clause's `not` cancel a real negation, so the sentence read
#     AFFIRMED and could satisfy the very `'+'` veto that exists to catch it.
#   * PARENTHETICAL INSERTIONS are skipped whole, reading right-to-left: the
#     token bearing the closing comma opens the skip and the token bearing the
#     opening comma closes it. Both look-around scans carry it — `governed`
#     always did, `cancelled` gained it in #271 — and it is tested BEFORE the
#     clause boundary on purpose, because a bracketed region suppresses
#     boundaries and negators alike; testing the boundary first is what put a
#     config-key literal (`sentry:`) back in the way and made the `:` arm cost
#     what #272 measured. `post_negated` has none and needs none: nothing
#     measured asks it to read past an aside.
#     BUT A SKIP NEVER OUTLIVES ITS SENTENCE, and that half is not optional.
#     A comma is not always paired, so an unpaired one opens a region that
#     suppresses everything to its left — including a full stop — and the scan
#     then runs into the PREVIOUS clause, which is #270 wearing the skip as a
#     disguise. It is not hypothetical and it bit in both scans: measured, `it
#     is not, as a rule. for these keys, sentry is exempt from a blind-spot row`
#     read 1/0 (a real negation cancelled by a previous sentence, the QUIET
#     direction) and `sentry is not, as a rule. for these keys, the blind-spot
#     row is kept` read 0/1 (a false negation, the LOUD one) — the second of
#     those on MAIN as well, a defect older than #271, since that scan has
#     always had the skip. So a skip region still honours `hard_break`, the
#     subset of the boundary set an aside cannot contain: a full stop and a
#     semicolon, but NOT the comma, dash, conjunction or config-key colon that
#     asides are made of. `clause_break` is defined in terms of `hard_break`
#     rather than beside it, so the subset cannot silently stop being one.
#     ITS COUNTEREXAMPLES MOVED WHEN THE COUNTS CAME OUT, which is worth knowing
#     before deciding this bullet is over-explained. Under a budget the skip was
#     what kept a negator IN it, so `is not, as of #261, given a blind-spot row`
#     and `never, in ordinary practice, renders a blind-spot row` were the
#     strings that broke without it. There is no budget now and both classify
#     correctly with the skip removed — measured, not assumed. What breaks
#     without it is a negator that genuinely belongs to the aside:
#     `sentry, which has no posthog target, keeps a blind-spot row` and
#     `testflight: none is not, like sentry: none, exempt from a blind-spot row`
#     each invert, one per scan, and each is asserted below.
#   * `instead`/`rather`/`excluded`/`omitted` count as negators, because
#     `instead of a blind-spot row` and `rather than a blind-spot row` are how
#     this repo actually writes the negative half, and reading them as
#     affirmations turned correct prose RED.
#
# BOTH tallies are printed, and every caller accounts for both, because a probe
# for one of them is the "tallying is not classifying" failure this file already
# learned once on the four-key table. This is not the place to grow a parser:
# the aim is that where the rule is wrong it is wrong in the LOUD direction, and
# `assert_dest`'s `'-'` want exists so a rule that states a negative must be
# measurably negated rather than merely silent. AN AIM IS NOT A GUARANTEE, and
# the block below exists because the previous wording read as one.
#
# KNOWN LIMIT: COMMA PARITY IS A GUESS, and where the guess is wrong a scan
# reaches into the neighbouring clause. This is ONE limit with two faces, both
# measured, and it is stated rather than fixed because no rule over commas
# resolves it -- a comma is sometimes an aside delimiter and sometimes a clause
# separator, and nothing local to the token distinguishes them. The file already
# says `,` is deliberately not a boundary; this is the cost of that, now visible
# because #271 removed the count that had been capping how far it could reach.
#
#   1. A COMMA-JOINED SUBORDINATE CLAUSE is not bounded. `when the key is not
#      derived, as of #261, sentry is exempt from a blind-spot row` returns 1/0
#      and is a negation; so does the `because` form. The cancellation scan
#      crosses the aside `, as of #261,` and finds the `not` belonging to the
#      SUBORDINATE clause. QUIET, on a `+` check. NOTE THE FIX THAT DOES NOT
#      WORK, since it is the first thing anyone will reach for and it was
#      measured: adding `if|when|because|while|although|unless|since|where` to
#      `clause_break` changes NEITHER string, because the subordinator sits to
#      the LEFT of the negator and a backward scan meets the negator first. The
#      boundary that would work is the comma CLOSING a clause-initial
#      subordinate clause, which a token-local predicate cannot see -- it needs
#      a forward segmentation pass over the token array, which is a different
#      change from this one.
#   2. THREE COMMAS INVERT THE PAIRING. Right-to-left parity binds the first
#      comma-bearing token it meets to the second, so with three asides the real
#      one is left exposed: `sentry, which has no posthog target, as of #261,
#      keeps a blind-spot row` returns 0/1 and is an affirmation, the `no`
#      belonging to the aside. The `closed` guard is what makes the two-comma
#      form right, and the same guard is what makes this one wrong -- a token
#      here must both CLOSE one aside and OPEN the next, which the guard exists
#      to forbid because forbidding it is what fixed the two-comma case.
#
# The MITIGATION, which is why this is a limit and not a hole: `hard_break`
# stops every one of these at a sentence, so a mis-reach is bounded by the
# nearest `.` or `;` rather than by the file. NEITHER FACE IS A REASON TO
# RESTORE THE COUNT: the count bounded the damage without bounding the scan
# correctly, which is what issue #271 exists to say.
#
# A THIRD SHAPE OF THE SAME FAMILY IS FIXED HERE, and is recorded because a
# reader meeting the two above will assume it is not: `even though its absence
# does render a blind-spot row, that key is excluded` returns 0/1 on main and
# 1/0 here, correctly. Nothing about commas fixed it -- the relativizer stop in
# `post_negated` did, `that` handing the predicate to `key`. Where a rule other
# than comma parity can see the clause boundary, the boundary gets seen.
dest_tally() {
    printf '%s' "$1" | tr -d '*_`' | tr '[:upper:]' '[:lower:]' |
        awk -v dest="$2" '
        function bare(t) { gsub(/^[^a-z]+|[^a-z]+$/, "", t); return t }
        # ONE clause boundary, shared by all three scans (issue #270).
        # `governed` and `post_negated` carried this expression verbatim while
        # `cancelled` had NO boundary check at all, so a negator in a PREVIOUS
        # clause cancelled a real negation and the sentence then read AFFIRMED —
        # a must-affirm veto passing on prose that states the inverse, which is
        # the direction of issue #268, again. Measured on main: `that is not so.
        # sentry is exempt from a blind-spot row` returned 1/0.
        #
        # It takes BOTH the raw token and its bare form because `bare()` strips
        # the trailing terminator. That is what made the boundary invisible to
        # `cancelled` rather than merely unchecked: a scan holding only bare
        # words cannot see a boundary at all, so passing `b2` twice here would
        # reproduce the bug while looking like the fix.
        #
        # THE DASH ARMS ARE LIVE NOW, and #271 is what made them have to be.
        # Until here they were EQUALITY tests reached only AFTER each caller had
        # skipped any token baring to the empty string, so they were dead in
        # every form: an attached dash never satisfied one (`special-` is not
        # `-`) and a standalone dash was skipped before the call. PR #272
        # measured exactly that and left them, because reviving an arm moves a
        # COUNT-bounded scan stops. Under a CLAUSE bound the calculus inverts. An
        # em-dash is a clause separator this repo writes constantly, and a
        # boundary that fails to fire no longer costs a word or two of window —
        # it lets the scan run on into the previous clause, which is #270 again.
        # So the arms now match a TRAILING dash rather than a whole token, which
        # takes in the attached form, and every caller tests the boundary BEFORE
        # the empty-bare skip each caller USED to run first. (That skip is gone
        # now -- an empty bare matches no negator arm, so nothing needed it --
        # but the ORDER it forced is the whole reason the arms were dead, which
        # is why it is described here in the past tense rather than deleted.)
        # Counted across the eight files this gate reads,
        # the tokens ending in an ASCII dash are the bare bullet `-` (74), the
        # table rule `---` (51) and the comment opener `<!--` (7) — so the arm
        # that changed behaviour most is the LIST BULLET, from inert to clause
        # boundary. That is the direction wanted (a new bullet is a new clause)
        # and no prose token was caught by it, but it is the part a reader
        # picturing an em dash will not have pictured. Measured per arm, and the ASCII pair was wrong in
        # BOTH directions before: `nothing - sentry keeps a blind-spot row` goes
        # 0/1 to 1/0 and `the key is not special- mobile is exempt from a
        # blind-spot row` goes 1/0 to 0/1. The unicode pair is subtler and the
        # cases below say so — a STANDALONE em or en dash already read correctly
        # on main, by the accident of a POSITION budget the same change deletes,
        # so only the ATTACHED form shows the arm was dead. The em-dash arm now
        # reddens two live-text assertions as well as both of its own cases.
        #
        # THE `:` ARM COST DISSOLVED, which is the outcome #272 guessed a real
        # clause bound might reach. The cost was never the arm: it was that
        # `cancelled` had no parenthetical skip, so an aside carrying a config-key
        # literal ended the scan early. `cancelled` has the skip now, and
        # measured, `testflight: none is not, like sentry: none, exempt from a
        # blind-spot row` goes 0/1 back to 1/0 while its colon-free control stays
        # 1/0 — the two AGREE again, which is the whole of it. The arm itself
        # stays and is not decoration: neutering `:` alone reddens three
        # live-text assertions plus the case named for it below.
        #
        # ONE HELPER, ONE EDIT — and it is now the only BOUND as well as the only
        # BOUNDARY, so the shared-helper risk #270 introduced is strictly larger
        # here than it was there. Adding `,` to this set rewrites all three scans
        # at once, and measured before the comma pair below existed that left the
        # ENTIRE gate green. Every arm of the set therefore carries a
        # fixed-string case of its own.
        #
        # NO APOSTROPHE may appear in any comment in this awk program: it is a
        # single-quoted shell word, so one closes the program and the next `{`
        # is a bash syntax error. Measured here while writing this block.
        function tail(t, suf,   n) {
            n = length(suf)
            return (length(t) >= n && substr(t, length(t) - n + 1) == suf)
        }
        # A SENTENCE terminator: the subset of the boundary set that cannot
        # occur inside a parenthetical aside, and therefore the one a skip
        # region must still honour. An aside carries commas, conjunctions,
        # dashes and config-key colons; it does not carry a full stop or a
        # semicolon. This is deliberately a SUBSET EXPRESSION of the set below
        # and not a second list — `clause_break` calls it, so the two cannot
        # drift apart the way two transcriptions of one table always do.
        function hard_break(t) { return (t ~ /[;.]$/) }
        # THE NEGATOR SETS, factored the same way `hard_break` is: the CORE is a
        # closed grammatical class, the full set is an EXPRESSION of it plus the
        # short lexical half, and neither is ever transcribed twice. What the
        # split buys beyond tidiness is the comma rule below — see `governed`.
        function core_negator(b) {
            return (b ~ /^(no|not|never|neither|nor|without|nothing)$/)
        }
        function negator(b) {
            return (core_negator(b) ||
                    b ~ /^(exempt|instead|rather|excluded|omitted)$/)
        }
        function clause_break(t, b) {
            return (hard_break(t) || t ~ /[:|-]$/ || tail(t, "\342\200\224") ||
                    tail(t, "\342\200\223") || tail(t, "\342\206\222") ||
                    b == "and" || b == "but" || b == "so" || b == "then")
        }

        # Is there a SECOND negator governing the one at position `at`? Double
        # negation cancels, and the cancelling word is not always adjacent:
        # `none of them is exempt from a blind-spot row` puts it four back.
        # `none` counts here ONLY as `none of` — bare `none` is the config value
        # this whole file is about and sits beside its own destination
        # constantly.
        function cancelled(w, at,   j, t2, b2, skipping, closed) {
            skipping = 0
            for (j = at - 1; j >= 1; j--) {
                t2 = w[j]
                if (t2 == "") continue
                closed = 0
                # The PARENTHETICAL SKIP, mirroring `governed` — the work #272
                # named and deferred to #271. It is what makes the `:` arm free
                # rather than costly: an aside like `, like sentry: none,` is
                # skipped whole, so the config-key literal inside it never reaches
                # the boundary test at all. It is also why the boundary is tested
                # AFTER the skip rather than before. A bracketed region suppresses
                # boundaries and negators alike, and testing first puts the arm
                # cost straight back — measured both ways.
                if (skipping) {
                    # A SKIP NEVER OUTLIVES ITS SENTENCE. An unpaired comma
                    # otherwise opens a region that swallows a full stop and
                    # runs on into the previous clause, where a comma-terminated
                    # negator cancels a real negation — #270 exactly, wearing
                    # the skip as a disguise. Measured on the way in: `it is
                    # not, as a rule. for these keys, sentry is exempt from a
                    # blind-spot row` classified 1/0 with this arm absent, the
                    # QUIET direction, against 0/1 on main.
                    if (hard_break(t2)) return 0
                    if (t2 ~ /,$/) { skipping = 0; closed = 1 }
                    else continue
                }
                b2 = bare(t2)
                # Same clause only, and checked BEFORE the negator arms so a
                # sentence-final `not.` BOUNDS rather than cancels — the sibling
                # shape, and the reason `sentry is not. mobile is exempt from a
                # blind-spot row` is a negation. Placed where the empty-bare
                # skip USED to sit, so a standalone dash bounds rather than
                # being skipped past before the test. There is
                # no lookback budget left: the clause IS the bound, and a second
                # negator anywhere inside it cancels (issue #271).
                if (clause_break(t2, b2)) return 0
                if (core_negator(b2)) return 1
                if (b2 == "none" && j < at && bare(w[j + 1]) == "of") return 1
                # THE TOKEN BEARING THE COMMA OPENS THE SKIP, and it is tested
                # FIRST — which is the half a mirror of `governed` used to get
                # wrong, because there the comma check came before everything.
                # A comma is not reliably paired, and an odd one lands on the
                # negator itself: measured, `mobile: none is never, in this repo
                # exempt from a blind-spot row` read 0/1 when `never,` merely
                # opened a skip, against 1/0 on main, which is a real double
                # negation reported as a negation. `closed` stops a token that
                # just ENDED a skip from immediately opening another.
                if (!closed && t2 ~ /,$/) skipping = 1
            }
            return 0
        }
        function governed(ctx,   nw, w, i, t, b, p, skipping, closed, prepositional, opens) {
            nw = split(ctx, w, / +/)
            skipping = 0
            for (i = nw; i >= 1; i--) {
                t = w[i]
                if (t == "") continue
                closed = 0
                if (skipping) {
                    # Same two rules as `cancelled`, and here both close defects
                    # OLDER than #271: this scan has always had the skip, so an
                    # unpaired comma has always been able to swallow a full stop
                    # AND to consume the negator bearing it. Measured on main and
                    # on this branch alike, `sentry is not, as a rule. for these
                    # keys, the blind-spot row is kept` read 0/1 (a false
                    # NEGATION, the loud direction, on a sentence that plainly
                    # affirms) and `sentry: none is never, in this repo given a
                    # blind-spot row` read 1/0 (a real negation reported as an
                    # affirmation, the quiet one).
                    if (hard_break(t)) return 0
                    if (t ~ /,$/) { skipping = 0; closed = 1 }
                    else continue
                }
                b = bare(t)
                # The boundary is tested where the empty-bare `continue` used
                # to sit. A standalone dash bares to nothing, so skipping first
                # is what left all three dash arms dead until #271. That
                # `continue` is now GONE rather than merely reordered: an empty
                # bare matches no negator arm, so it guarded nothing, and
                # keeping it here would skip the comma bookkeeping below for a
                # token like `#261,` that bares to nothing and IS an aside
                # delimiter.
                if (clause_break(t, b)) return 0
                # A COMMA-BEARING TOKEN IS TESTED AGAINST THE CORE SET ONLY, and
                # the distinction is grammatical rather than a fitted exception.
                # `not`/`never` are adverbs scoping over the predicate that
                # FOLLOWS them, so `is never, in this repo given a blind-spot
                # row` is a real negation and consuming `never,` as an aside
                # delimiter loses it. `excluded`/`exempt` are participles
                # predicating on the subject to their LEFT, so a comma after one
                # closes its own clause: measured on the live contract,
                # `ci_workflow: is excluded, even though its absence does render
                # a blind-spot row` is an AFFIRMATION, and testing `excluded,`
                # here read it as a negation — a whole-file tally hid that,
                # because a second mention flipped the other way and the two
                # cancelled out. Both strings are cases below.
                opens = (!closed && t ~ /,$/)
                if (opens ? core_negator(b) : negator(b)) {
                    p = (i > 1) ? bare(w[i - 1]) : ""
                    # A negator inside a prepositional phrase negates that
                    # phrase, not the destination: `a repo with no Sentry keeps
                    # a blind-spot row` is an affirmation.
                    #
                    # PREPOSITIONS ONLY. `has`/`have`/`having` were here once and
                    # are VERBS, and `X has no Y` is the most ordinary way English
                    # writes this negation — so `` `sentry: none` has no
                    # blind-spot row `` read as AFFIRMED and defeated every
                    # must-affirm site at once (§3A, §6 and the Blind spots
                    # bullet) — the #213 gap restored three times over through
                    # one word. It also reddened the correct three-key half the
                    # moment it said `have no` instead of `get no`. The case
                    # they appeared to protect is already carried by the real
                    # prepositions:
                    # `a repo with no Sentry keeps a blind-spot row` classifies
                    # AFFIRMED on `with` alone. Measured both ways.
                    #
                    # KNOWN LIMIT: THE TEST CANNOT REACH A CLAUSE-INITIAL
                    # NEGATOR, and it is filed here rather than with the
                    # comma-parity limits because the cause is POSITIONAL and
                    # filing it there would misattribute it. `p` is the token
                    # BEFORE the negator; at clause-initial position there is
                    # none, `p` is the empty string, and no preposition can
                    # match it. This is structural -- no addition to the list
                    # above can reach a negator with nothing in front of it.
                    #
                    # Measured, all three AFFIRMED on main and NEGATED here:
                    #
                    #   no config key is read before survey-work renders a
                    #     blind-spot row
                    #   nothing in the contract prevents survey-work from
                    #     rendering a blind-spot row
                    #   never mind the four keys sentry still renders a
                    #     blind-spot row
                    #
                    # DIRECTION: AFFIRMED -> NEGATED, which is LOUD on a `+`
                    # want and QUIET on a `-` one. It moves none of the 77 live
                    # call sites.
                    #
                    # IT IS STATED RATHER THAN FIXED, and the header at the top
                    # of this file credits the preposition test with carrying
                    # this whole class -- which is exactly why it cannot stay
                    # unstated. The canonical case that sentence cites (`a repo
                    # with no Sentry keeps a blind-spot row`) works; the
                    # clause-initial variant of the same class does not. No
                    # bounded arm reaches it: `nothing in the contract prevents
                    # X from rendering Y` is a double negation over a control
                    # verb, and any rule that resolves it is a new inference
                    # layer rather than a longer list.
                    prepositional = (p ~ /^(with|in|of|for|on|at|by|from|under|inside|despite)$/)
                    # POLARITY FLIP. A second negator governing the first cancels
                    # it: `is not exempt from a blind-spot row` and `is never
                    # excluded from a blind-spot row` AFFIRM the row, and
                    # `exempt`/`excluded` are exactly the words this repo reaches
                    # for — its own header cites `is exempt from`. Read as
                    # negations they satisfied the plain veto AND the stricter
                    # must-be-negated one, so
                    # the inverse of #261 passed every veto meant to catch it.
                    #
                    # Deliberately a polarity rule and NOT a longer negator list
                    # or a wider budget: enumerating negations is what the
                    # six-verb `BLIND_AFFIRM` already failed at, and #268 exists
                    # because that approach does not converge.
                    if (!prepositional) {
                        if (cancelled(w, i))
                            return 0
                        return 1
                    }
                }
                if (opens) skipping = 1
            }
            return 0
        }
        # English negates a noun phrase from the RIGHT too, in the passive: `the
        # blind-spot row is dropped`. A look-left-only classifier read those as
        # AFFIRMED, so `**for `sentry: none` the blind-spot row is dropped**`
        # passed every must-affirm site silently — the quiet direction, on the
        # one decision this gate exists for.
        #
        # This set is its own, and NARROWER than the left one on purpose. The
        # left-side `rather` would fire on the live Blind-spots clause
        # (`produces a row, worded as confirmed rather than unchecked`), and
        # `absent` would fire on the live §6 text `keeps its blind-spot row —
        # absent error monitoring…`, both reddening correct prose. Only
        # post-positional participles count, and the scan stops at the same
        # clause boundaries.
        # THE APPOSITIVE REGION, and the discipline INSIDE it. Opening on
        # position alone was not enough: the first version tested the participle
        # and returned unconditionally, so nothing inside the region consulted
        # the copula rule, the preposition rule or the relativizer stop -- and
        # `the blind-spot row, with the mobile lane skipped, is fine` read 0/1
        # against main 1/0. That is the SAME reduced relative the copula gate
        # exists to reject, admitted through a door that never asked.
        #
        # WHAT SEPARATES THEM IS A SUBJECT. A participial appositive has none of
        # its own -- it is the participle, optionally behind adverbs, predicated
        # on the noun it abuts. The moment a NEW SUBJECT appears inside the
        # region (a relativizer, a preposition heading a fresh noun phrase, or a
        # determiner opening one) it is a clause with its own subject, and the
        # whole region becomes an ASIDE to be skipped rather than an appositive
        # to be read. `appos == 2` is that degraded state; it runs to the
        # closing delimiter and resumes after it, which is why `— the mobile
        # lane was skipped — is fine` reaches `is fine` and finds nothing.
        #
        # Relativizers and prepositions are the sets this file already carries.
        # ADVERBS are deliberately not enumerated -- an open class -- which is
        # why the rule tests for what DISQUALIFIES an appositive rather than for
        # what an adverb is, and why `, deliberately dropped —` and `, never
        # dropped,` still read.
        #
        # A COORDINATED adverb pair does NOT read, and that is stated rather
        # than fixed: `, quietly and deliberately dropped,` returns 1/0,
        # because `and` is a clause boundary and terminates the scan before the
        # participle. It is the natural extension of the two adverb examples
        # just cited, so a reader will expect it to work. It is not a
        # regression -- main returns 1/0 too -- and the fix would be to teach
        # the scan that a conjunction inside a bracketed region is not a clause
        # boundary, which is a change to `clause_break` and not to this block.
        #
        # KNOWN LIMIT, and it replaces a CLAIM THAT WAS FALSE. This block used
        # to say "determiners are a closed grammatical class", offered as the
        # licence for enumerating them. The class is closed; the ENUMERATION
        # below is not the class, and saying otherwise is the exact shape this
        # file diagnoses 750 lines further down about a different list -- "a
        # closed noun list is also an open class in disguise". The claim is
        # gone rather than the list being lengthened, because a longer list
        # under the same false claim is no better.
        #
        # Measured, these determiners are absent and each one leaves a
        # participle admitted that should not be: `each`, `every`, `both`,
        # `either`, `neither`, `some`, `any`, `no`, `all`, `another`, `such`,
        # `several`, and possessive noun phrases (`sentry-s target dropped`).
        # `much`, `many`, `enough` and `whichever` are the obvious remainder of
        # that list and are CONSIDERED AND DECLINED for the same reason as the
        # twelve: NOT REGRESSIONS, and adding them would lengthen a list whose
        # false closure claim is the thing that was actually wrong.
        # NONE OF THEM IS A REGRESSION -- main reads them the same way, because
        # main had no appositive path at all -- so they are completeness gaps
        # in a new feature rather than something this change broke. They are
        # STATED here in the idiom `am`, `looks`/`appears` and `why`/`whereupon`
        # already use in this file, and the fix for any one of them is to add
        # the word WITH its case when prose in the tree needs it, not to
        # pre-enumerate the class.
        # THE EDGE IS A COMMA OR A DASH, ATTACHED OR STANDALONE -- said
        # precisely, because the block above used to say "a comma or a dash"
        # while the code also accepted any token ending in a hyphen. They now
        # agree, and the ATTACHED form is deliberate rather than an accident:
        # it is the same trailing-dash treatment `clause_break` carries, for
        # the same reason (`special-` ends a clause), and narrowing it here
        # would leave the two disagreeing in the other direction. The cost is
        # that a token merely ending in a hyphen opens or closes a region;
        # nothing in the tree does, and the dash cases below pin the forms that
        # matter.
        function appos_edge(t) {
            return (t == "," || t ~ /,$/ || t == "-" || t ~ /-$/ ||
                    tail(t, "\342\200\224") || tail(t, "\342\200\223"))
        }
        function new_subject(b, nxt) {
            # THE DETERMINER ARM HAS ONE EXEMPTION, and it is a coreference
            # rather than a longer list. A determiner opens a new subject
            # UNLESS what it determines is the pro-form `one`/`ones`, which
            # corefers with the noun already named: `the blind-spot row, the
            # one dropped in #261, is gone` is a real negation about the ROW,
            # while `the blind-spot row, the mobile lane dropped, is fine` is
            # not. That distinction is the whole of the exemption -- one arm,
            # not a widening -- and without it the first string read 1/0
            # against main 0/1, quietly.
            #
            # CONSIDERED AND DECLINED: it over-fires on the NUMERAL `one`, so
            # `the one lane dropped` is exempted too and the participle is
            # admitted. NOT A REGRESSION -- main reads that string the same
            # way -- and separating the numeral from the pro-form needs to know
            # whether a noun follows, which is an inference layer rather than an
            # arm. Recorded so the next reader does not re-derive it.
            if (b ~ /^(the|a|an|this|these|those|its|his|her|their|our|my|your)$/ &&
                nxt ~ /^(one|ones)$/) return 0
            return (b ~ /^(which|that|who|whom|whose|where|whereby|wherein|when)$/ ||
                    b ~ /^(with|in|of|for|on|at|by|from|under|inside|despite)$/ ||
                    b ~ /^(the|a|an|this|these|those|its|his|her|their|our|my|your)$/)
        }
        function first_i(w, nw,   k) {
            for (k = 1; k <= nw; k++) if (w[k] != "") return k
            return 0
        }
        function post_negated(rest,   nw, w, i, t, b, seen, copula, appos) {
            nw = split(rest, w, / +/)
            seen = 0; copula = 0; appos = 0
            for (i = 1; i <= nw; i++) {
                t = w[i]
                if (t == "") continue
                b = bare(t)
                # THE COPULA GATE HAS A SECOND AXIS, and the known-limit block
                # above is thorough about WHICH VERBS count while saying nothing
                # about a participle that has NONE. A comma- or dash-set-off
                # participial APPOSITIVE is predicated of the destination with
                # no auxiliary at all: `the blind-spot row, dropped from §6, is
                # gone` is a negation, and it read 1/0 here against 0/1 on main
                # until this block existed. Four shapes, all quiet, all on a
                # `+` veto.
                #
                # IT OPENS ONLY AS THE FIRST TOKEN AFTER THE DESTINATION, which
                # is the whole of what keeps it from re-opening the defect the
                # copula gate exists to close. An appositive attaches to the
                # noun it abuts; a participle further right does not, and the
                # narrow rule is what separates them. Measured, the two shapes
                # differ by nothing but that position: `the blind-spot row, with
                # its posthog target dropped, is kept` and `keeps a blind-spot
                # row with the mobile lane skipped` are REDUCED RELATIVES
                # modifying the nearer noun, both stay 1/0, and a rule keyed on
                # "a comma appears somewhere to the left" flips the first of
                # them. Do NOT widen this to a participle anywhere.
                #
                # SHIPPED RATHER THAN STATED BECAUSE IT MEASURED CLEAN: the
                # decision rule was that the fix ships only if it moves none of
                # the live call sites, and instrumenting `dest_tally` over a
                # full run put it at 0 of 77 shared (haystack, dest) pairs. The
                # trigger it forecloses is already one row away from live --
                # `skills/survey-work/SKILL.md:237` is a table cell reading
                # `Deliberately dropped — not a plate item`, a bare participle
                # in a cell the four-key loop classifies per cell through
                # `dest_affirmed`, wanting only a destination in the same cell.
                if (i == first_i(w, nw) && appos_edge(t)) {
                    appos = 1
                    continue
                }
                # KNOWN LIMIT: the degraded region does NOT consult
                # `clause_break`, so a `.` or `;` inside it does not stop the
                # scan -- it runs to the closing delimiter regardless. That is
                # the same shape `hard_break` exists for one function over,
                # which is the reason to write it down rather than assume it is
                # fine. It is tolerated here because the region is bounded by a
                # delimiter that in practice arrives well before a sentence
                # end, nothing in the tree triggers it, and no live call site
                # moves. If it ever bites, the fix is a `hard_break` check in
                # this branch -- not a wider `appos_edge`.
                if (appos == 2) {
                    if (appos_edge(t)) appos = 0
                    continue
                }
                if (appos == 1) {
                    if (new_subject(b, (i < nw) ? bare(w[i + 1]) : "")) {
                        if (appos_edge(t)) appos = 0; else appos = 2
                        continue
                    }
                    if (b ~ /^(dropped|omitted|suppressed|excluded|removed|withheld|skipped|retired)$/) {
                        if (cancelled(w, i)) return 0
                        return 1
                    }
                    if (appos_edge(t)) { appos = 0; continue }
                }
                if (clause_break(t, b)) return 0
                # A NEW SUBJECT ends this scan. `whose` is the one relativizer
                # that always introduces one, so a participle past it predicates
                # on that noun and not on the destination. `which`/`that` are
                # deliberately absent: they carry the SAME subject forward, and
                # `the blind-spot row that is dropped` is a real negation.
                #
                # A PREPOSITION IS DELIBERATELY NOT A STOP HERE, which is the
                # trap, because it IS one on the other side and the symmetry is
                # inviting. Read backwards a preposition hands the negator to
                # another noun; read FORWARDS it merely qualifies the
                # destination and the predicate still belongs to it. Measured
                # both ways: stopping at one turns `the blind-spot row for these
                # three keys is deliberately dropped` from 0/1 into 1/0 — a real
                # negation lost — while the four cases below need polarity and
                # `whose`, not prepositions, and each was measured 1/0 on main
                # and 0/1 with both of these absent. Every one is the QUIET
                # direction, and the first is the #261 rule written INVERTED,
                # which a `-` want then passed: `... a blind-spot row for the
                # keys whose token was dropped onto the clean line`, `the
                # blind-spot row for these three keys is never omitted`, `the
                # blind-spot row in section 6 is not, as of #261, dropped`, and
                # `the blind-spot row for sentry, whose posthog target was
                # dropped, is kept`.
                # A RELATIVIZER hands the predicate to a NEW SUBJECT, and the
                # whole class does it, not just the possessive one: `for sentry,
                # which has a target that was dropped, is kept` and `uses the
                # token that was dropped` are affirmations.
                #
                # THE CLASS SPLITS IN TWO, and the split is grammatical. A
                # POSSESSIVE (`whose`), a LOCATIVE (`where`) and a TEMPORAL
                # (`when`) each name a new subject in their OWN right -- `whose
                # target`, `where the key`, `when the key` -- so they stop
                # unconditionally. The SUBJECT relatives carry the antecedent
                # forward instead, so when one heads the destination directly
                # its subject IS the destination and `the blind-spot row that is
                # dropped` is a real negation.
                #
                # THE SPLIT WAS WRONG TWICE BEFORE IT WAS RIGHT, which is the
                # reason to distrust a shorter version of it. It began as
                # `whose` alone, then as one whole-class first-word exemption --
                # each time the members that name their own subject were sorted
                # by how the rule READ rather than by what they DO. `when`
                # travelled with the subject relatives for exactly that reason
                # and was the last one out: measured, `a blind-spot row when the
                # key is dropped` read 0/1 against 1/0 on main.
                #
                # THE CLASS IS ENUMERATED WHOLE, INCLUDING MEMBERS THAT CANNOT
                # FIRE, and the reason is a defect this split already shipped:
                # `whereby` and `wherein` are `where` with a preposition baked
                # in, they introduce a new subject exactly as it does, and they
                # were simply MISSING -- measured, both read 0/1 against 1/0 on
                # main. Meanwhile `who|whom` were being kept for completeness
                # though neither can ever fire here, a blind-spot row not being
                # a person. Keeping the unfireable members while omitting two
                # that fire AND regress is the inconsistency to refuse: a class
                # is enumerated by what it IS, and then behaviour follows.
                # `who` stays in the exempt half as a subject relative and
                # nothing pins it; `whom` is an OBJECT relative, so the split
                # own principle puts it with the unconditional group even
                # though it cannot fire either. Do not read the unfireable
                # members as evidence the exemption generalises -- the five
                # above are the test of that.
                #
                # KNOWN LIMIT, worded the way `am` is, so the next reader does
                # not re-run the probe and reach a different answer. `why` and
                # `whereupon` DO regress -- measured, both 1/0 on main and 0/1
                # here -- and are deliberately absent anyway: neither can take
                # the destination as antecedent, `why` requiring a reason head
                # (`the reason why`, never `the row why`) and `whereupon` being
                # archaic in this register. Adding them would enumerate members
                # the construction cannot produce, which is the fitted reading.
                # `in which` and `for which` need nothing: the `seen` rule
                # already handles them, since the preposition is a content word
                # and `which` is therefore not first. Measured, both 1/0 in
                # both editions.
                #
                # A SINGLE FIRST-WORD EXEMPTION OVER THE WHOLE CLASS IS WRONG,
                # and wrong exactly where a restrictive relative is most
                # natural: measured, `the blind-spot row whose posthog target
                # was dropped is kept` and its `where` variant both read 0/1
                # under it, against 1/0 on main. Nothing in the non-first cases
                # above can see that, which is why each half has its own case.
                if (b ~ /^(whose|where|whereby|wherein|when|whom)$/) return 0
                if (seen && b ~ /^(which|that|who)$/) return 0
                # ONLY A REAL WORD COUNTS AS HAVING BEEN SEEN. A token baring to
                # nothing spent the exemption once: measured, `the blind-spot
                # row #261 that is dropped` read 1/0, because `#261` is not a
                # word and `that` was treated as a new subject. Same empty-bare
                # trap as the dash arms, one function along.
                if (b != "") seen = 1
                # A PASSIVE AUXILIARY is what re-attaches a participle to the
                # destination across an intervening phrase. Without one the
                # participle is a reduced clause modifying the NEARER noun:
                # `with its posthog target dropped, is kept` and `keeps a
                # blind-spot row with the mobile lane skipped` are affirmations,
                # while `for these three keys is deliberately dropped` is a
                # negation and differs only by the `is`. This is why a
                # PREPOSITION is not the stop here -- it is the auxiliary after
                # it that decides, not the preposition.
                #
                # THE LICENCE IS TWO-TIER, and collapsing it into one is how
                # this set goes wrong in either direction. The file already
                # runs exactly this split on the NEGATOR set, whose core is a
                # closed grammatical class and whose remainder is a short
                # tree-justified lexical half; the same two arguments apply
                # here and neither covers the other.
                #
                # TIER 1, the two PASSIVE AUXILIARIES: `be` and the get-passive.
                # Both paradigms are closed -- English does not coin a third --
                # so enumerating them terminates, which is the same argument
                # the header makes for `no/not/never/...` and NOT the argument
                # it refuses for a verb list.
                #
                # TIER 2, COPULAR AND ASPECTUAL verbs, admitted on the OTHER
                # rule: a lexical addition justified by prose in the tree. They
                # are not auxiliaries and the closed-paradigm argument does not
                # reach them -- `seem`, `appear`, `look`, `prove`, `grow`,
                # `turn` all qualify grammatically, so claiming closure here
                # would be the fitted reading this file refuses. They are needed
                # because `post_negated` asks whether a participle is PREDICATED
                # of the destination, and a copular verb takes a participial
                # complement predicated of its subject just as `be` does:
                # measured, `the blind-spot row remains dropped`, `stays
                # dropped` and `becomes dropped` each read 1/0 against 0/1 on
                # main. Quiet, on a `+` veto. Only forms the TREE WRITES are
                # enumerated -- 20 occurrences of this family across the eight
                # files, one of them fifteen words from a blind-spot mention in
                # survey-work.
                #
                # THE LIST BELOW IS ILLUSTRATIVE, NOT EXHAUSTIVE, which matters
                # for the phrasal aspectuals: `end up dropped` is inside this
                # limit general sentence and absent from its examples.
                # CONSIDERED AND DECLINED as an addition -- NOT A REGRESSION,
                # main reads it identically -- because enumerating phrasal verbs
                # is the open class this limit exists to refuse.
                #
                # KNOWN LIMIT, worded the way `am` is: the wider copular class
                # is NOT covered. `seem|appear|look|prove|grow|turn|sound|feel`
                # are absent because the tree does not write them in this
                # construction -- `looks` and `appears` occur, but as `look for`
                # and `appears in`, never with a participial complement -- and
                # admitting them would be enumeration without justification,
                # which is the move tier 2 exists to avoid. Unattested
                # INFLECTIONS of the tier-2 verbs (`remained`, `stayed`) are out
                # for the same reason. Each is a quiet miss if the prose ever
                # changes, and the fix is to add the form WITH its case once the
                # tree writes it, not to pre-enumerate the class. BOTH PARADIGMS MUST BE COMPLETE FOR THAT LICENCE TO
                # HOLD, and the first draft honoured it for one and not the
                # other: `be` was 7 of 8 with `am` named as a deliberate
                # absence, while the get-passive shipped as 3 of 5 with
                # `getting` and `gotten` missing and NOTHING said about them --
                # a stated omission and an unstated one, side by side. The gap
                # bites exactly where the missing member is the only auxiliary
                # present, which `has gotten dropped` and `keeps getting
                # dropped` produce: both read 1/0 against 0/1 on main, quietly.
                # (`is getting dropped` and `has been dropped` were fine, since
                # `is` and `been` carry them -- which is why the omission was
                # invisible from the cases that existed.) First-person `am`
                # remains the ONE member deliberately absent, rule prose having
                # no first person and a case for it being invented rather than
                # measured.
                #
                # TRIMMING IS NOT THE SAFE DIRECTION HERE, which is worth saying
                # because most of these were once pinned by nothing and looked
                # like padding -- a reading that has since been closed, since
                # every member carries a case now. Measured one member at a
                # time: removing ANY member flips its own ordinary sentence
                # from 0/1 to 1/0 -- `the blind-spot rows are dropped`, `has
                # been dropped`, `gets dropped` -- and that is the QUIET
                # direction on a rule that STATES a negative.
                if (b ~ /^(is|was|are|were|be|been|being|gets|get|got|getting|gotten)$/ ||
                    b ~ /^(remains|remain|stays|stay|becomes|become|became)$/)
                    copula = 1
                if (b ~ /^(dropped|omitted|suppressed|excluded|removed|withheld|skipped|retired)$/) {
                    if (!copula) continue
                    # THE SAME POLARITY FLIP `governed` performs, run on this
                    # side for the first time. `is never omitted` and `is not,
                    # as of #261, dropped` AFFIRM the destination, and reading
                    # them as negations satisfied the stricter must-be-negated
                    # veto with the inverse of the rule it guards. `cancelled`
                    # scans only within `rest`, which is exactly right here: the
                    # negator that cancels a post-positional participle always
                    # sits between the destination and the participle.
                    if (cancelled(w, i)) return 0
                    return 1
                }
            }
            return 0
        }
        {
            s = $0
            while (match(s, dest)) {
                ctx = substr(s, 1, RSTART - 1)
                rest = substr(s, RSTART + RLENGTH)
                if (governed(ctx) || post_negated(rest)) n++; else a++
                s = rest
            }
        }
        END { printf "%d %d", a + 0, n + 0 }'
}
dest_affirmed() { local t; t="$(dest_tally "$1" "$2")"; printf '%s' "${t%% *}"; }

# --- The classifier's own clause bound (issues #270, #271) --------------------
#
# Every veto below that reads a DESTINATION — `assert_dest`, the sentence scans,
# and the four-key row classification, though not the plain `grep` assertions
# beside them — is only as good as this classifier, and nothing in this file
# tested the classifier itself — its behaviour was measured out of band and
# written into a comment. A comment does not redden. So the boundary #270 closed
# is pinned here, in both directions, against fixed strings that owe nothing to
# what any tracked file happens to say today. #271 then made `clause_break` the
# ONLY bound as well as the only boundary, which is why every arm of it now
# carries a case rather than only the arms #270 happened to exercise.
#
# SCOPE, stated so this is not read as coverage of the whole classifier, and
# re-derived rather than carried: what is pinned is every arm of the boundary
# set, `hard_break` in both directions, each scan's bound and its boundary
# check, the parenthetical skip in each scan that has one — its existence, the
# `hard_break` it still honours, the testing of the token bearing the comma, and
# the `closed` guard — `post_negated`s two guards and the preposition stop it
# must NOT acquire, `governed`s preposition test, and the CORE-versus-full
# negator split at the two places it decides something. Issue #268 and PR #269
# settled what the scan LOOKS FOR and this battery is not about that; it is
# about what BOUNDS the scan, plus the guards the bound turned out to have been
# supplying by accident.
#
# TWO PROPERTIES ARE ASSERTED AT SOURCE LEVEL because nothing behavioural can
# see them: `clause_break` must be an EXPRESSION of `hard_break`, and `negator`
# of `core_negator`. A copy that transcribes the subset instead classifies every
# string here identically — today — and then the two drift.
#
# Each case asserts the WHOLE `<affirmed> <negated>` tally, never one half of it.
# Probing one number is the "tallying is not classifying" failure this file
# already learned on the four-key table, and here it is worse: a case that
# stopped classifying altogether returns `0 0`, which satisfies every
# "nothing affirmed" probe while measuring nothing.
#
# WHICH CASE MEASURES WHAT has to stay straight, and #271 moved several of them.
# Under the old count bound a case could pass on the BROKEN classifier for a
# reason that had nothing to do with the boundary — the four-position lookback
# in `cancelled` stopped the scan before the boundary was ever reached — so this
# paragraph used to spend itself scoping a quantifier around that. The count is
# gone, and with it the whole class of accidental passes: nothing here stops
# short of a clause any more, so every case below fails for the reason its own
# heading names. Two cases kept their verdict and changed their JOB — the
# standalone em and en dashes, which read `0 1` in both editions for opposite
# reasons — and the dash block below says so where they sit. The standalone
# ASCII dash is NOT one of them: it changed verdict, `0 1` to `1 0`.
#
# `... and sentry is exempt ...` was deliberately ABSENT for that same reason
# and stays absent: it pins nothing either edition does not already do.
#
# COVERAGE IS DERIVED BY MEASUREMENT, never asserted, and no tally of it is
# written down here — a number nobody can re-derive is what a future editor
# trusts instead of re-measuring, which is this file's own rule. Every case in
# this battery was proved load-bearing by at least one mutation of the
# classifier that it, and for most of them only it, reddens. Two blocks are
# there because a mutation found NOTHING: the comma pair, because adding `,` to
# `clause_break` once left the ENTIRE gate green, and the per-arm block, because
# after #271 dropped the counts, neutering the ASCII-dash, en-dash, `but`, `so`
# and `then` arms each did the same. One shared helper is exactly what makes
# every one of those a single edit.
dest_case() {
    local label="$1" text="$2" want="$3" got
    got="$(dest_tally "$text" "$ROW_DEST")"
    if [ "$got" = "$want" ]; then ok "$label"
    else bad "$label (want '$want' affirmed/negated, got '$got')"; fi
}

echo "-- the destination classifier's clause bound (#270, #271)"

# The control. With no earlier negator the classifier was always right here, so
# it is what makes the `Direction 1` cases evidence of a BOUNDARY rather than of
# a classifier that has simply stopped cancelling. It used to carry a scope
# sentence saying `Direction 1` was the only block differing between the pre- and
# post-#270 editions; that was true of #270 and is not of #271, which moved most
# of the blocks below, so the sentence is gone rather than re-scoped. Each block
# states its own edition delta where it has one.
dest_case "a lone negation is NEGATED" \
    'sentry: none is exempt from a blind-spot row' '0 1'

# Direction 1: a negator in a PREVIOUS clause must not cancel this one.
dest_case "a negator across a period does not cancel" \
    'that is not so. sentry is exempt from a blind-spot row' '0 1'
dest_case "a negator across a semicolon does not cancel" \
    'it is never so; posthog is exempt from a blind-spot row' '0 1'
# `not so.` and `never so;` carry a conjunction (`so`) as well as a terminator,
# so on their own they cannot say WHICH arm fired. This one bares to `special`
# and isolates the terminator.
dest_case "a negator across a period alone does not cancel" \
    'the key is not special. mobile is exempt from a blind-spot row' '0 1'
# And this one isolates the conjunction: no terminator anywhere in the window.
dest_case "a negator across a conjunction does not cancel" \
    'sentry is not, and mobile is exempt from a blind-spot row' '0 1'
# ORDER, not just presence. Here the boundary and the negator are the SAME token
# (`not.`), so a `clause_break` call moved below the negator arms — the ordinary
# "test the cheap comparisons first" tidy — cancels and inverts the sentence.
dest_case "a sentence-final negator bounds rather than cancels" \
    'sentry is not. mobile is exempt from a blind-spot row' '0 1'

# What is NOT a boundary, and this pair is here because of THIS change. The set
# used to be written out twice; one shared helper makes it a single edit, so
# "a comma ends a clause too" now silently rewrites all three scans at once.
# Measured: adding `,` to `clause_break` left the whole gate green before these
# two cases existed. Both counterexamples are the file header's own — `,` and
# `or` are deliberately not boundaries, and a parenthetical is skipped whole
# rather than treated as one.
dest_case "a comma is not a clause boundary" \
    'sentry: none does not get, or need, a blind-spot row' '0 1'
dest_case "a parenthetical insertion is skipped, not bounded" \
    'sentry: none is not, as of #261, given a blind-spot row' '0 1'

# THE BOUND IS THE CLAUSE (issue #271). One case per scan, each a string whose
# governing word sits FURTHER than the four-content-word budget the scans used
# to carry and INSIDE the same clause, so each one flips exactly when its scan
# stops counting and starts reading to the clause edge. The first is the
# counterexample #272 wrote into the source as a known limit it could not fix by
# widening — lower-cased like every string here, which costs nothing since
# `dest_tally` lower-cases its haystack anyway.
dest_case "governed reads to the clause edge, not four words back" \
    'the three keys do not, in current practice, ever actually produce a blind-spot row' '0 1'
dest_case "cancelled reads to the clause edge, not four positions back" \
    'nothing about these three keys is exempt from a blind-spot row' '1 0'
dest_case "post_negated reads to the clause edge, not four words on" \
    'the blind-spot row for these three keys is deliberately dropped' '0 1'
# ...and it stops AT that edge. This pair reads the boundary itself rather than
# the bound, and it exists because the relativizer and copula guards added later
# turned out to cover every live-text assertion the boundary had been covering:
# removing `clause_break` from this scan alone left the whole gate green, which
# is the shape of a check that has quietly stopped being tested.
dest_case "post_negated stops at a full stop" \
    'sentry: none keeps a blind-spot row. the marker is dropped' '1 0'
dest_case "post_negated stops at a conjunction" \
    'sentry: none keeps a blind-spot row and the marker is dropped' '1 0'

# EVERY ARM OF `clause_break`, isolated. The helper is now the only bound the
# three scans have, so an arm that silently stops working widens all three at
# once. Measured once the counts came out, six arms were pinned by nothing at
# all — the ASCII dash, the en dash, and every one of `and`, `but`, `so` and
# `then` — which is named rather than counted because a tally of a state that no
# longer exists is what a later editor trusts instead of re-deriving. Of the
# four that were reddening something, only `.` and the em dash reddened a case
# in this battery; `:` and `;` reddened LIVE-TEXT assertions alone, which a
# reword can take away. Each string below carries exactly ONE boundary
# candidate:
# the `.` arm is already isolated by `not special.` above, and the four
# conjunctions are separated from each other because `never so;` would let `;`
# and `so` cover for one another.
dest_case "a semicolon alone bounds the scan" \
    'it is never true; posthog is exempt from a blind-spot row' '0 1'
dest_case "a colon alone bounds the scan" \
    'it is never true: posthog is exempt from a blind-spot row' '0 1'
dest_case "\`and\` alone bounds the scan" \
    'there is no mobile target and sentry keeps a blind-spot row' '1 0'
dest_case "\`but\` alone bounds the scan" \
    'it is never true but mobile keeps a blind-spot row' '1 0'
dest_case "\`so\` alone bounds the scan" \
    'it is never true so sentry keeps a blind-spot row' '1 0'
dest_case "\`then\` alone bounds the scan" \
    'that is not true then sentry keeps a blind-spot row' '1 0'

# THE DASHES, three arms times two forms, because the two forms fail for
# DIFFERENT reasons and a set covering one of them reads complete. A STANDALONE
# dash bares to the empty string, so it is caught only if the boundary is tested
# where each scan USED to skip an empty bare — that `continue` guarded nothing
# and is gone now, but the ordering it forced is what left all three arms dead
# before #271. An ATTACHED dash is caught only if the arm matches a
# TRAILING dash rather than a whole token. For the two MULTI-BYTE dashes that
# is what `tail()` is for and what an *equality* test cannot do: measured,
# rewriting `tail()` back to `t == suf` — the tidy a reader who has only seen
# the spaced form would make — leaves all three standalone cases green and
# reddens the em- and en-dash attached ones, and ONLY those. The ASCII attached
# case survives that mutation, because the ASCII arm is the `[;:.-]$` regex
# rather than a `tail()` call; it is pinned instead by dropping `-` from that
# class (`[:|-]$` today -- the `;` and `.` moved into `hard_break`). Two mechanisms, one behaviour, and a fixture set covering either one
# alone reads complete. FOUR of the six
# read WRONG on main, in both directions. The other two — the standalone em and
# en dashes — read RIGHT there, and that is the trap in this block rather than a
# reason to drop them: they were right by an accident the next paragraph
# records, on a classifier where the arm itself never fired at all.
#
# The em-dash pair carries one more thing worth not losing. Its standalone
# string used to sit up beside `Direction 1` under a heading about the LOOKBACK:
# a standalone dash cost a POSITION-counted window a step and a
# content-word-counted one nothing, so it pushed `not` out of `cancelled`s
# four-position window while the dash itself was inert. Same verdict here, the
# opposite reason — the arm fires and the scan stops — which is why it is filed
# with the dashes now instead of reading as a case about a bound that no longer
# exists.
dest_case "a standalone ASCII dash bounds the scan" \
    'nothing - sentry keeps a blind-spot row' '1 0'
dest_case "an ASCII dash attached to a word bounds the scan" \
    'the key is not special- mobile is exempt from a blind-spot row' '0 1'
dest_case "a standalone em dash bounds the scan" \
    'it is not true — sentry is exempt from a blind-spot row' '0 1'
dest_case "an em dash attached to a word bounds the scan" \
    'the key is not special— mobile is exempt from a blind-spot row' '0 1'
dest_case "a standalone en dash bounds the scan" \
    'it is not true – sentry is exempt from a blind-spot row' '0 1'
dest_case "an en dash attached to a word bounds the scan" \
    'the key is not special– mobile is exempt from a blind-spot row' '0 1'

# THE TWO SEPARATORS THIS REPO ACTUALLY WRITES, and the reason they are here at
# all: an unbounded scan crosses whatever the boundary set does not name, and
# these two carry live tracked text. `→` is the rule separator in survey-work
# (`No key at all → a blind-spot row in §6`), and `|` is a markdown cell wall.
# Measured whole-file, with each arm removed one at a time: survey-work ROW goes
# 9/4 to 8/5 without the arrow, because `governed` reaches the `no` in `No key
# at all`, which negates the KEY and not the row and sits clause-initial where
# the preposition test cannot see it; config-contract CLEAN goes 6/0 to 3/3
# without the pipe, flipping all three clean-line rows of the #261 table because
# a `no` in one cell governs a destination in the next.
#
# NEITHER ARM REDDENS A LIVE-TEXT ASSERTION — both drifts are invisible to the
# gate, since the row loop reads one cell rather than the row — so these two
# fixed strings are the whole of their coverage.
dest_case "an arrow bounds the scan" \
    'no key at all → sentry keeps a blind-spot row' '1 0'
dest_case "a table cell wall bounds the scan" \
    '| sentry: none | confirmed: no beta channel | keeps a blind-spot row |' '1 0'

# THE PARENTHETICAL SKIP, one case per scan that has one. `governed` has had it
# all along and nothing asserted it; `cancelled` gained it in #271, and gaining
# it is what dissolved the `:` arm cost #272 measured and accepted. The pair
# below is the whole of that measurement: on main the two sentences DISAGREE
# (0/1 against 1/0) because the aside carrying `sentry:` ended the cancellation
# scan early, and here they agree. A control that matches its subject is the
# point of this one — it is what says the arm has stopped costing anything.
dest_case "governed skips a parenthetical rather than reading its negator" \
    'sentry, which has no posthog target, keeps a blind-spot row' '1 0'
dest_case "cancelled skips an aside carrying a config key" \
    'testflight: none is not, like sentry: none, exempt from a blind-spot row' '1 0'
dest_case "the same aside without a colon classifies identically" \
    'testflight: none is not, like posthog none, exempt from a blind-spot row' '1 0'

# AND THE SKIP IS ITSELF BOUNDED, by `hard_break`. An unpaired comma opens a
# region that would otherwise swallow a full stop and let the scan read the
# PREVIOUS sentence — #270 again, reached through the very mechanism added to
# dissolve the `:` cost. These three are the shapes that found it, one per scan
# and one per terminator, and each was measured wrong before `hard_break`
# existed: the first two are the QUIET direction (a real negation cancelled by a
# previous sentence) and the third is the LOUD one, which read 0/1 on MAIN too —
# `governed` has always had the skip, so that case is a defect older than #271
# and is fixed here rather than carried.
#
# Their counterweight is the `:` pair above: widen `hard_break` to the whole
# boundary set — the tidy that makes the two look consistent — and the aside
# carrying `sentry:` ends the scan early again, exactly as it did before this
# change. Both directions are asserted, so neither repair can be made alone.
dest_case "a skip does not swallow a full stop (cancelled)" \
    'it is not, as a rule. for these keys, sentry is exempt from a blind-spot row' '0 1'
dest_case "a skip does not swallow a semicolon (cancelled)" \
    'it is not, as a rule; for these keys, sentry is exempt from a blind-spot row' '0 1'
dest_case "a skip does not swallow a full stop (governed)" \
    'sentry is not, as a rule. for these keys, the blind-spot row is kept' '1 0'

# AND THE TOKEN BEARING THE COMMA IS TESTED BEFORE IT OPENS THE SKIP. A comma is
# not reliably paired, and an odd one lands on the negator itself, where merely
# opening a skip consumes it. Both scans had this wrong: `cancelled` acquired it
# with the skip, and `governed` has carried it since long before #271 — its case
# below reads WRONG on main as well as on the first draft of this branch, which
# is what says the rule is not an artefact of the rework.
dest_case "an odd comma does not consume the negator bearing it (cancelled)" \
    'mobile: none is never, in this repo exempt from a blind-spot row' '1 0'
dest_case "an odd comma does not consume the negator bearing it (governed)" \
    'sentry: none is never, in this repo given a blind-spot row' '0 1'
# ...but a comma-bearing token is tested against the CORE set ONLY, and this is
# the counterweight to the case above rather than an exception to it. `never` is
# an adverb scoping over what FOLLOWS, so consuming `never,` loses a real
# negation; `excluded` is a participle predicating on the subject to its LEFT,
# so a comma after it closes its own clause. Testing both alike read the live
# contract line below — an AFFIRMATION — as a negation. A WHOLE-FILE TALLY HID
# THAT: a second mention in the same file flipped the other way and the two
# cancelled out, which is why the verification for this change compares
# per-MENTION verdicts and not per-file counts.
dest_case "a comma-bearing lexical negator closes its own clause" \
    'ci_workflow: is excluded, even though its absence does render a blind-spot row' '1 0'
# The cancellation scan uses the CORE set alone, and that predates #271 — it is
# named here only because factoring the two sets into `core_negator`/`negator`
# makes the asymmetry visible and therefore tempting to "align". Widening it
# lets one lexical negator cancel another, and `is excluded rather than given a
# blind-spot row` is a single negation, not a double one.
dest_case "one lexical negator does not cancel another" \
    'sentry: none is excluded rather than given a blind-spot row' '0 1'
# ...and a token that just CLOSED a skip does not immediately open another. That
# is what `closed` is for, and it is the one line here whose absence nothing else
# notices: an aside followed by a second one re-opens on the closing comma, so
# every remaining token — the real negator among them — is suppressed to the
# start of the clause. Measured, this reads 0/1 without the guard (and on main,
# for the older reason) against the 1/0 it should have.
dest_case "a closing comma does not open a second skip" \
    'sentry: none is not in fact, like sentry, exempt from a blind-spot row' '1 0'

# THE SUBSET IS STRUCTURAL, and this is the one property in this section that
# NOTHING BEHAVIOURAL CAN SEE. A `clause_break` that transcribed `[;.]` inline
# instead of calling `hard_break` classifies every string in this battery
# identically, today — and then the two drift, which is the whole failure mode
# a third copy of the label taxonomy taught this repo once already. So it is
# asserted at SOURCE level, the same shape as `align-labels.sh`s single-call-site
# invariant: the subset must be an EXPRESSION of the set, never a second list
# that happens to agree.
for pair in "clause_break(t, b)|hard_break(|the skip-region subset" \
            "negator(b)|core_negator(|the core negator set"; do
    outer="${pair%%|*}"; rest="${pair#*|}"; inner="${rest%%|*}"; what="${rest#*|}"
    body="$(sed -n "/^        function ${outer%%(*}(/,/^        }\$/p" "$SELF")"
    if [ -z "$body" ]; then
        bad "${outer%%(*} could not be located in this file — the source check is measuring nothing"
    elif grep -q "$inner" <<<"$body"; then
        ok "${outer%%(*} is an expression of ${inner%(}, not a second transcription of it"
    else
        bad "${outer%%(*} no longer calls ${inner%(} — $what is now a separate list that can drift"
    fi
done

# THE PREPOSITION TEST, asserted here for the first time. It was comment-only
# while a four-word budget shared the work of keeping a prepositional negator
# out of range; #271 removed the budget, so this test is now the ONLY thing
# standing between `with no Sentry` and a false negation, and leaving the file
# single protection unpinned in the change that widened the scan is the shape
# this gate exists to refuse.
dest_case "a negator inside a prepositional phrase does not negate the row" \
    'a repo with no Sentry keeps a blind-spot row' '1 0'

# POST_NEGATED'S OWN GUARDS, which #271 made necessary: with the four-word
# ceiling gone this scan reaches any participle in its clause, and it had NO
# polarity check and NO new-subject test to stop it. All three below read 1/0 on
# main and 0/1 with the guards absent — every one the QUIET direction, and the
# first is the #261 rule written INVERTED, which the `-` want then passed while
# the genuine rule passed too, so the gate could not tell them apart.
#
# THE COUNTERWEIGHT IS ALREADY ABOVE, and it is what stops this being repaired
# with a preposition test — the obvious symmetry, since `governed` has one.
# `the blind-spot row for these three keys is deliberately dropped` (the
# clause-edge case) is a REAL negation reached through `for`: read backwards a
# preposition hands the negator to another noun, read forwards it merely
# qualifies the destination and the predicate still belongs to it. A preposition
# stop turns that case 0/1 into 1/0 — measured, and it is why `whose` is the one
# relativizer named here and `which`/`that` are not.
dest_case "a participle past a new subject does not negate the row" \
    'a blind-spot row for the keys whose token was dropped onto the clean line' '1 0'
# The new subject arrives by any relativizer, not only the possessive one, and
# `whose` alone was measured leaving all four siblings inverted against main.
dest_case "a \`which\` clause carries the predicate away from the row" \
    'the blind-spot row for sentry, which has a target that was dropped, is kept' '1 0'
dest_case "a \`that\` clause carries the predicate away from the row" \
    'the blind-spot row uses the token that was dropped from the clean line' '1 0'
dest_case "a \`where\` clause carries the predicate away from the row" \
    'the blind-spot row for the repo where the key was dropped is kept' '1 0'
# ...but a SUBJECT relative that is the FIRST content word after the destination
# carries the antecedent forward, so its subject IS the destination and this is
# a real negation. Without the exemption the rule above swallows it, which is
# how a stop-list this short goes wrong in the loud direction.
dest_case "a subject relative heading the destination itself still negates" \
    'the blind-spot row that is dropped' '0 1'
dest_case "the same, through \`which\`" \
    'the blind-spot row which is dropped' '0 1'
# AND THE EXEMPTION DOES NOT REACH THE WHOLE CLASS, which is the half the three
# cases above cannot see: they all put the relativizer in non-first position,
# where both readings agree. A POSSESSIVE and a LOCATIVE name a new subject in
# their own right -- `whose target`, `where the key` -- so a first-position one
# is still a new subject. Measured, these two read 0/1 under a single
# whole-class exemption, against 1/0 on main, and they sit exactly where a
# restrictive relative is most natural: immediately after the destination.
dest_case "a first-position possessive relative is still a new subject" \
    'the blind-spot row whose posthog target was dropped is kept' '1 0'
dest_case "a first-position locative relative is still a new subject" \
    'the blind-spot row where the key was dropped is kept' '1 0'
# `when` is the THIRD member of this defect, and it travelled with the subject
# relatives through two earlier versions of the split because it reads like one.
# It is a temporal subordinator: `when the key` names its own subject exactly as
# `where the key` does. Measured 0/1 against main`s 1/0 while it sat in the
# exempt half, and neither case above can see it.
dest_case "a first-position temporal relative is still a new subject" \
    'a blind-spot row when the key is dropped' '1 0'
# `whereby` and `wherein` are `where` with a preposition baked in. They were
# simply MISSING from the class rather than mis-placed in it, which is the
# harder omission to see: the split was three-way and correct for the members
# present, so nothing about its SHAPE was wrong. Both regressed against main.
dest_case "a first-position \`whereby\` is still a new subject" \
    'the blind-spot row whereby the key was dropped is kept' '1 0'
dest_case "a first-position \`wherein\` is still a new subject" \
    'the blind-spot row wherein the key was dropped is kept' '1 0'
# ...and a token baring to NOTHING does not spend the exemption either. Same
# empty-bare trap as the dash arms, one function along: `#261` is not a word, so
# `that` is still the first one.
dest_case "an empty bare does not spend the first-word exemption" \
    'the blind-spot row #261 that is dropped' '0 1'
# THE COPULA is what re-attaches a participle to the destination across an
# intervening phrase, and it is why a PREPOSITION is not the stop here. These
# two differ from the clause-edge case above only by the missing `is`, and both
# read inverted against main without the rule.
dest_case "a reduced clause modifies the nearer noun, not the row" \
    'the blind-spot row for sentry, with its posthog target dropped, is kept' '1 0'
dest_case "a trailing reduced clause does not negate the row" \
    'sentry keeps a blind-spot row with the mobile lane skipped' '1 0'
# THE OTHER AXIS OF THE COPULA GATE: a participle with NO auxiliary at all. A
# comma- or dash-set-off APPOSITIVE is predicated of the destination, and all
# four of these read 1/0 against main 0/1 until the gate grew that case --
# quiet, on a `+` veto, and invisible from every case above, which all vary the
# VERB rather than remove it.
dest_case "a comma-set-off appositive negates the row" \
    'the blind-spot row, dropped from §6, is gone' '0 1'
dest_case "an appositive with an adverb still negates" \
    'a blind-spot row, deliberately dropped — not a plate item' '0 1'
dest_case "a dash-set-off appositive negates the row" \
    'the blind-spot row — dropped in #261 — is gone' '0 1'
dest_case "an appositive closing on its own comma negates" \
    'the blind-spot row, omitted on refresh, no longer renders' '0 1'
# ...and the appositive runs the SAME polarity flip the auxiliary path does, so
# a negated appositive affirms. It has its own `cancelled` call and therefore
# its own way to lose it: a mutation of the auxiliary path alone leaves this
# one standing, which is exactly how the polarity mutant went undetected once
# the second call site existed. Better than main here, which reads 0/1.
dest_case "a negated appositive affirms the row" \
    'the blind-spot row, never dropped, is kept' '1 0'
# ...and the pair that keeps it narrow. These are REDUCED RELATIVES modifying
# the nearer noun, not appositives on the destination, and they differ from the
# four above by POSITION alone -- the set-off does not abut the destination. A
# rule keyed on "a comma somewhere to the left" flips the first of them, which
# is how this fix would have re-opened what the copula gate closed.
dest_case "a reduced relative after an intervening phrase does not negate" \
    'the blind-spot row for sentry, with its posthog target dropped, is kept' '1 0'
# ...and these four are the discipline INSIDE the region, which the pair above
# cannot see: both of them sit where the appositive never opens, so position was
# carrying the entire separation and nothing tested the interior. Each reads 1/0
# on main. The third is the one that decides it -- the same construction as the
# counter-case above with the comma moved to abut the destination, which is what
# proves position alone is not a rule.
dest_case "a clause with its own subject is an aside, not an appositive" \
    'the blind-spot row — the mobile lane was skipped — is fine' '1 0'
dest_case "a determiner inside the region opens a new subject" \
    'the blind-spot row, the mobile lane having been skipped, is fine' '1 0'
dest_case "a preposition inside the region opens a new subject" \
    'the blind-spot row, with the mobile lane skipped, is fine' '1 0'
dest_case "a relativizer inside the region opens a new subject" \
    'the blind-spot row, which sentry has dropped, is kept' '1 0'
# The preposition arm needs a string with NO determiner in it, or the determiner
# arm covers for it and the two cannot be told apart -- measured, dropping the
# preposition arm alone left the whole gate green while `with the mobile lane`
# still fired on `the`.
dest_case "a preposition alone opens a new subject" \
    'the blind-spot row, with sentry dropped, is fine' '1 0'
# ...and the degraded aside RESUMES at its closing delimiter rather than
# swallowing the rest. Without that, a real negation after the aside is lost --
# and the loss is invisible from every case above, since they all want AFFIRMED
# and a scan that gives up returns exactly that.
dest_case "a degraded aside resumes and still finds a real negation" \
    'the blind-spot row, with the mobile lane skipped, is dropped' '0 1'
# ...and the determiner arm has ONE exemption, which is a coreference rather
# than a longer list: the pro-form `one`/`ones` corefers with the noun already
# named, so `the one dropped` still predicates on the row while `the mobile
# lane dropped` does not. The pair is the whole of it -- the same determiner,
# opposite verdicts, decided by the word after it.
dest_case "a determiner before a pro-form does not open a new subject" \
    'the blind-spot row, the one dropped in #261, is gone' '0 1'
dest_case "a determiner before a real noun still opens one" \
    'the blind-spot row, the mobile lane dropped, is fine' '1 0'
# ONE CASE PER MEMBER, for both tiers, and NO BARE COUNT IS WRITTEN DOWN -- the
# cases ARE the inventory, and `grep -c '^dest_case "passive auxiliary:'` plus
# its `copular verb:` sibling re-derives it from the tree. A number here would
# be the thing the next editor trusts instead of re-measuring, which is why
# #268 stripped one from AGENTS.md; this set has now changed size THREE times
# under review, and every time the prose stating its old size survived the
# change and contradicted the code beside it.
#
# THE RULE IS SHARPER THAN "NO NUMBERS", because a blanket ban would strip
# counts that are perfectly safe. A count is safe when its MEMBERS ARE
# ENUMERATED BESIDE IT, or when A GATE RE-DERIVES IT -- `AGENTS.md`s
# tracked-file count for `scripts/test-review-gate-decisions.sh` floats free of
# any list and is safe anyway, because that gate re-derives it from its own read
# set and reddens every site restating it, `AGENTS.md` included -- measured,
# rewriting that number reddens the gate and names the site. Cite the gate by
# filename when relying on that, so a later sweep does not rewrite a count
# something is already holding.
#
# AND READ THE GATE BEFORE CITING IT, because holding the SET a number counts is
# not holding the NUMBER. This bullet cited the `review_surfaces` transcription
# in `config-contract.md` as an instance of this branch and it is NOT one:
# `scripts/test-review-orchestrator-allowlist.sh` resolves the names it finds
# there against `agents/`, but states in as many words that this transcription
# is deliberately not floored -- and the nine names sit enumerated in that same
# sentence anyway, which makes it the FIRST branch. Measured: deleting all nine
# names while keeping the word `nine` leaves `bash scripts/preflight.sh` at
# rc=0. `six arms ... the ASCII dash, the en dash and all
# four of and/but/so/then` cannot go stale silently, because the list is right
# there to check against. A count with no enumeration beside it is the unsafe
# shape, and both stale ones were exactly that: `removing ANY of the ten` and
# `eight of the ten are pinned by nothing`, each floating free four lines from
# a set that had grown.
#
# AND THE PROBE FOR THEM MUST SEARCH THE CONCEPT, NOT THE PHRASING. Two
# separate checks reported this file clean while both stale counts sat in it,
# because both greps looked for `ten-member` and `any of the ten` -- the
# wordings we remembered writing. That is negation-blindness one level up: a
# probe shaped by what the author expected to have written cannot find what the
# author actually wrote.
#
# THE FIRST REPLACEMENT WAS THE SAME MISTAKE ONE GENERATION DOWN, which is why
# this paragraph is long. It swept for a number ADJACENT to a counted noun,
# from a closed list -- `member|set|list|paradigm|arm|case|entr` -- and so it
# could only ever find counts of the SAFE shape, since the rule above defines
# the unsafe one as a count floating FREE of its noun. Measured against the two
# wordings it was written for, it found nothing on one and, on the other, only
# the safe `one member` earlier in the same sentence: a decoy that a reader
# obeying READ THEM would read, judge safe, and move past with `the ten` four
# words away. A closed noun list is also an open class in disguise -- `face`,
# `guard`, `verb`, `form`, `word`, `string`, `fixture`, `scan`, `rule` are all
# counted things this file writes today and none was in it. That is the
# six-verb `BLIND_AFFIRM` lesson, committed inside the probe enforcing the rule
# against it.
#
# THE PROBE THAT WORKS CARRIES NO NOUN LIST AND NO VERB LIST. It sweeps for the
# number used AS the noun -- a partitive, which is the surface form of a count
# floating free of its set:
#
#   grep -oniE "\\b(of|among|across) (the |these |those |them )?(one|two| \
#     three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen| \
#     fourteen|fifteen|twenty)\\b" scripts/test-sentry-verification.sh \
#     scripts/preflight.sh AGENTS.md
#
# It finds BOTH original wordings (`ANY of the ten`, `eight of the ten`) and
# returns a couple of dozen hits across the three files -- few enough to READ,
# which is the point and the instruction. Counting them, or grepping for the
# phrasing you think you used, is how this was missed twice.
#
# WHAT IT CANNOT SEE, stated rather than fixed, because widening a probe until
# the next reader finds the next surface form is the loop that produced the two
# before it. Keying on the PARTITIVE narrows it to one surface form, and the
# two wordings it was validated against both happened to share that form --
# which is exactly how each earlier probe was built, and the reason to write
# the blind spot down instead of adding an alternation. It misses:
#
#   * NON-PARTITIVE free-floating counts -- the number sits beside a noun, so
#     it reads safe by shape while the SET it counts may be elsewhere entirely.
#     THE INSTANCE THIS BULLET NAMED IS NOW HISTORICAL TOO, and it was in this
#     very file: the tracked-file count, which used to stand here as an
#     illustration of the SHAPE and was in fact an instance of it. The read set
#     was variables iterated as literals in a `for` loop, its length existed
#     nowhere, and the count was restated across this file, `scripts/preflight.sh`
#     and `AGENTS.md` with no member list beside any of them. Issue #278 closed
#     it the way #276 closed the one before: the read set is an array, the
#     counts section below derives from its length, and every restatement site
#     is accounted for rather than looked up. `the four names` genuinely is
#     pinned, by a row count in this file; `the six-verb affirmative`
#     enumerates its members beside it.
#
#     SO THIS BULLET NOW NAMES NO LIVE INSTANCE, and that is stated rather than
#     left to be inferred from an empty space. It is NOT evidence the tree is
#     clean: the probe below cannot see this shape at all -- that is the point
#     of the bullet -- so an absence here means nobody has found one since, not
#     that none exists. Both instances it has carried were found by a READER,
#     never by the probe, which is the instruction this block closes with.
#
#     THE INSTANCE PREVIOUSLY NAMED HERE IS NOW HISTORICAL, and how it was
#     cited is worth more than the citation was. It was the closing summary of
#     the review-gate decision gate -- "the five decisions, six tracked files",
#     restated in that gate header, in `scripts/preflight.sh` and in
#     `AGENTS.md`, re-derived by nothing. Issue #276 moved it onto the OTHER
#     safe form named above: the counts section of
#     `scripts/test-review-gate-decisions.sh` re-derives both numbers from its
#     own source and reddens every site that disagrees. Two things outlive it.
#     First, this bullet cited it as gate 26 while the gate was numbered 29 in
#     the very commit that wrote the citation -- measured, not inferred: it was
#     never 26, so the number was unverifiable AT THE POINT OF WRITING rather
#     than rotted, which is the stronger argument for the content handle the
#     quoted wording gives. Second, the probe never found that instance; a
#     reader did, which is the instruction this block closes with.
#   * DIGIT forms -- `all 12 are pinned`. The sweep is spelled-out words only.
#
# A probe with a stated blind spot is honest about what a clean run means. The
# instruction stands: READ the hits, and do not assume a clean sweep is a clean
# tree.
#
# TIER 1 IS COMPLETE PARADIGMS. `be` and the get-passive are closed, so
# enumerating them terminates -- but the licence only holds if each is WHOLE,
# and the first draft shipped `be` missing only `am` (named as a deliberate
# absence) beside a get-passive missing `getting` and `gotten` with nothing
# said. Those two cost quiet misses wherever they were the only auxiliary
# present. TIER 2 IS TREE-JUSTIFIED, so it is enumerated by what the prose
# writes and its residual gap is stated at the call site instead. The cases exist
# because the alternative reading of an enumerated set is that it was fitted,
# and because TRIMMING is the unsafe direction: measured one member at a time,
# removing ANY member flips its own ordinary sentence to AFFIRMED, quietly, on
# a rule that states a negative.
dest_case "passive auxiliary: is" \
    'the blind-spot row is dropped' '0 1'
dest_case "passive auxiliary: are" \
    'the blind-spot rows are dropped' '0 1'
dest_case "passive auxiliary: was" \
    'the blind-spot row was dropped' '0 1'
dest_case "passive auxiliary: were" \
    'the blind-spot rows were dropped' '0 1'
dest_case "passive auxiliary: be" \
    'the blind-spot row will be dropped' '0 1'
dest_case "passive auxiliary: been" \
    'the blind-spot row has been dropped' '0 1'
dest_case "passive auxiliary: being" \
    'the blind-spot row risks being dropped' '0 1'
dest_case "passive auxiliary: gets" \
    'the blind-spot row gets dropped' '0 1'
dest_case "passive auxiliary: get" \
    'the blind-spot row will get dropped' '0 1'
dest_case "passive auxiliary: got" \
    'the blind-spot row got dropped' '0 1'
dest_case "passive auxiliary: getting" \
    'the blind-spot row keeps getting dropped' '0 1'
dest_case "passive auxiliary: gotten" \
    'the blind-spot row has gotten dropped' '0 1'
# TIER 2, the copular and aspectual verbs, admitted on the OTHER rule -- prose
# in the tree, not a closed paradigm. They matter because this scan asks whether
# a participle is PREDICATED of the destination, and a copular verb takes a
# participial complement predicated of its subject exactly as `be` does. Each
# read 1/0 here against 0/1 on main while the set was auxiliaries-only: the
# auxiliary ceiling that fixed one class of quiet miss opened another.
dest_case "copular verb: remains" \
    'the blind-spot row remains dropped' '0 1'
dest_case "copular verb: remain" \
    'the blind-spot rows remain dropped' '0 1'
dest_case "copular verb: stays" \
    'the blind-spot row stays dropped' '0 1'
dest_case "copular verb: stay" \
    'the blind-spot rows stay dropped' '0 1'
dest_case "copular verb: becomes" \
    'the blind-spot row becomes dropped' '0 1'
dest_case "copular verb: become" \
    'the blind-spot rows become dropped' '0 1'
dest_case "copular verb: became" \
    'the blind-spot row became dropped' '0 1'
dest_case "a negated participle affirms the row (never/omitted)" \
    'the blind-spot row for these three keys is never omitted' '1 0'
dest_case "a negated participle affirms the row (across an aside)" \
    'the blind-spot row in section 6 is not, as of #261, dropped' '1 0'

# Direction 2: a genuine double negation INSIDE one clause still cancels. These
# are what a boundary check bolted on carelessly breaks, and each is prose this
# repo actually writes — the file header cites `is exempt from` as its own.
dest_case "an adjacent second negator still cancels" \
    'sentry: none is not exempt from a blind-spot row' '1 0'
dest_case "a second negator four back still cancels" \
    'none of them is exempt from a blind-spot row' '1 0'
# The lexical half of the negator set, cancelled by the core half: the boundary
# check now sits above both arms, so a fix that returned early on the wrong
# token would take this one out with it.
dest_case "a never/excluded pair still cancels" \
    'sentry: none is never excluded from a blind-spot row' '1 0'

# The other pair of mutually exclusive outcomes in this file: a refresh either
# RE-DERIVES a value or CARRIES it forward. Same classifier, same reason.
#
# `carve-out` on its own is deliberately NOT a carry-forward token. It is the
# ordinary noun both rules use to talk ABOUT the carve-out — "the culprit check
# that the carve-out just excluded" is the sentence arguing sentry stays out of
# it — so a bare `carve-out` veto reddens the correct source. Only membership
# phrasings count.
REDERIVE_VOCAB='re-derived|re-derive|re-run it'
CARRY_VOCAB='carried forward|carry (it|them|these) forward|not re-asked|never re-ask|(in|into|joins) (that|the) carve-out'

# Sentences of $1 that mention the literal $2, one per line. The boundary is
# `. `, which is crude — but the alternative is a window keyed on the rule's own
# wording, and that is what reddens the gate on a correct reword. A sentence is
# the unit here because "is NOT re-derived" and "is re-derived" differ by one
# word that a file-wide `grep -qi 're-derived'` cannot see: that check is what
# stood at both sites before issue #268.
sentences_about() {
    printf '%s' "$1" | awk -v key="$2" '
        {
            n = split($0, parts, /\. /)
            for (i = 1; i <= n; i++) if (index(parts[i], key) > 0) print parts[i]
        }'
}

# At least one sentence about $2 must AFFIRM vocabulary $3.
assert_sentence_affirms() {
    local label="$1" hay="$2" key="$3" vocab="$4" hits found=0 s
    hits="$(sentences_about "$hay" "$key")"
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        [ "$(dest_affirmed "$s" "$vocab")" -gt 0 ] && found=1
    done <<EOF
$hits
EOF
    if [ "$found" = 1 ]; then ok "$label"; else bad "$label"; fi
}

# NO sentence about $2 may AFFIRM vocabulary $3.
#
# ZERO sentences is a FAILURE, not a pass. A veto over an empty set is satisfied
# by nothing at all, so a key that stopped being mentioned — a rename, a section
# lost to an extractor change — would report every rule about it as clean. Its
# sibling above fails on an empty set for free (nothing affirms), which is why
# only this one needs the guard stated.
assert_no_sentence_affirms() {
    local label="$1" hay="$2" key="$3" vocab="$4" hits offender="" seen=0 s
    hits="$(sentences_about "$hay" "$key")"
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        seen=$((seen + 1))
        [ "$(dest_affirmed "$s" "$vocab")" -gt 0 ] && offender="$s"
    done <<EOF
$hits
EOF
    if [ "$seen" -eq 0 ]; then
        bad "$label: no sentence mentions \`$key\` at all — the veto would pass vacuously"
    elif [ -z "$offender" ]; then ok "$label ($seen sentence(s) checked)"
    else bad "$label (offending sentence: ${offender:0:120})"; fi
}

# Assert a window's destination profile.
#
#   '+'  at least one AFFIRMED mention.
#   '-'  at least one NEGATED mention and no affirmed one. For a rule that
#        STATES the negative ("get **no** blind-spot row"). This is the want
#        that `'0'` alone could not express, and the gap was measurable: `'0'`
#        tests only `a -eq 0`, so a rule whose negative clause moved out of the
#        window scored 0/0 and the veto printed `ok` while measuring nothing.
#        Every `'0'` veto in this file was convertible that way by a cosmetic
#        edit that shifted a window boundary.
#   '0'  no affirmed mention, and silence is legitimate. Only for whole-rule
#        scopes where the destination may simply never come up — §6's sentry
#        half never mentions the clean line at all, and must not be forced to.
#
# An EMPTY haystack is a failure in every mode: a window whose marker stopped
# matching would otherwise report each veto over it as clean.
assert_dest() {
    local label="$1" hay="$2" dest="$3" want="$4" t a n
    if [ -z "$hay" ]; then
        bad "$label: the text under test is EMPTY — an extractor is matching nothing"
        return
    fi
    t="$(dest_tally "$hay" "$dest")"; a="${t%% *}"; n="${t##* }"
    case "$want" in
        '+') if [ "$a" -gt 0 ]; then ok "$label"
             else bad "$label (affirmed=$a negated=$n)"; fi ;;
        '-') if [ "$a" -eq 0 ] && [ "$n" -gt 0 ]; then ok "$label"
             else bad "$label (affirmed=$a negated=$n; the rule must STATE the negative, not omit it)"; fi ;;
        '0') if [ "$a" -eq 0 ]; then ok "$label"
             else bad "$label (affirmed=$a negated=$n)"; fi ;;
        *) bad "assert_dest: bad want '$want'" ;;
    esac
}

echo "-- the four-key \`none\` form, and its deliberate asymmetry (#261)"

# Window of flattened text from a literal marker, ALSO cut at the first of any
# number of stop markers. Pure parameter expansion — no awk, no regex — because
# the markers carry backticks and colons, the haystacks are single ~40KB lines,
# and `#*` takes the SHORTEST match, i.e. the FIRST occurrence. Verified under
# bash 3.2 (macOS /bin/bash) as well as 5.x, so no awk-dialect or long-line
# buffer question arises between a local run and CI's.
#
# (A stop-marker-less `window_after` used to sit here; it had no call sites and
# a nine-line rationale that read as load-bearing. Every window in this file is
# structurally bounded, which is the rule — see `window_is_bounded`.)
#
# A constant
# length is wrong in both directions, and both were measured on this file: too
# short turns a must-not-exist into a false pass (§3A's Sentry rule is ~930B and
# a 460B window read half of it, so appending a clean-line clause passed), too
# long lets one key's assertions be satisfied by the NEXT key's rule — or, for
# the last key in a section, by whatever section follows it. Every §3 window
# therefore stops at `No key at all`, the phrase each of the four rules uses to
# hand over to its own absent-key case: that bounds the window to the `none`
# clause itself rather than to a byte count, and it is what keeps the adjacent
# `… **and a blind-spot row in §6**` (a statement about the ABSENT key) out of
# the `none` rule's window. `%%` cuts at the FIRST occurrence of the stop.
window_between() {
    local hay="$1" mark="$2" n="$3" rest cut stop
    shift 3
    rest="${hay#*"$mark"}"
    [ "$rest" = "$hay" ] && return 0
    cut="${rest:0:n}"
    for stop in "$@"; do
        [ -n "$stop" ] || continue
        case "$cut" in *"$stop"*) cut="${cut%%"$stop"*}" ;; esac
    done
    printf '%s' "$mark$cut"
}

# A window must end at its STOP MARKER, never at its byte cap — the cap is a
# backstop against a missing stop marker running the window to EOF, not the bound
# itself. Measured (#268): `carry_win`'s last asserted phrase ended at byte 933
# of a 937-byte window, so one sentence inserted above it would have carried the
# phrase out of scope and reddened the gate on an edit that changed nothing.
# Structural bounds are the file's own rule; this asserts the rule was kept.
window_is_bounded() {
    local label="$1" hay="$2" mark="$3" n="$4"; shift 4
    local capped uncapped
    capped="$(window_between "$hay" "$mark" "$n" "$@")"
    uncapped="$(window_between "$hay" "$mark" 999999 "$@")"
    if [ -z "$capped" ]; then
        bad "$label: window marker not found"
    elif [ "${#capped}" -lt "${#uncapped}" ]; then
        bad "$label: the $n-byte cap binds $(( ${#uncapped} - ${#capped} )) bytes before the stop marker"
    else
        ok "$label: window ends at its stop marker, not at a byte cap"
    fi
}

# Data rows of a markdown table: leading `|`, minus the header and the `---`
# separator. Deliberately NOT keyed on a backtick — a row a human hand-adds
# without code formatting is exactly the fifth key this must catch, and an
# earlier `awk '/^| `/'` filter counted a five-row table as four.
table_rows() {
    printf '%s\n' "$1" | awk '
        /^\|/ {
            if ($0 ~ /^\|[ :|-]*$/) next
            if ($0 ~ /\|[ ]*Config[ ]*\|/) next
            print
        }'
}
cell() { printf '%s' "$1" | awk -F'|' -v n="$2" '{gsub(/^[ `*]+|[ `*]+$/, "", $n); print $n}'; }

# --- I1. The four-key table -----------------------------------------------------

asym_section="$(printf '%s\n' "$exception_section" | awk '/^#### The four keys/{f=1; next} /^#/{f=0} f')"

if [ -n "$asym_section" ]; then
    ok "config-contract.md carries the four-key asymmetry subsection"
else
    bad "the four-key \`none\` asymmetry subsection is gone from config-contract.md"
fi

# Every row is CLASSIFIED and the classification must be exhaustive. Tallying two
# patterns is not enough: a fifth key whose behaviour column matches neither is
# invisible to a tally, which falsified this gate's own claim that counting
# catches a grown table.
asym_keys="" n_rows=0 n_blind=0 n_clean=0 n_other=0
while IFS= read -r row; do
    [ -n "$row" ] || continue
    n_rows=$((n_rows + 1))
    k="$(cell "$row" 2)"
    b="$(cell "$row" 4)"
    asym_keys="${asym_keys}[$k]"
    # A cell is classified by which destination it AFFIRMS, exactly as a prose
    # rule is. The `kept` literal this replaced was the same closed-verb-list
    # mistake one layer down: a cell reading `blind-spot row — retained` was a
    # correct edit that reddened the gate. A negated cell ("**no** blind-spot row
    # (aligned with the other three)") affirms neither and lands in `n_other`.
    if [ "$(dest_affirmed "$b" "$ROW_DEST")" -gt 0 ] &&
       [ "$(dest_affirmed "$b" "$CLEAN_DEST")" -eq 0 ]; then
        n_blind=$((n_blind + 1))
        blind_key="$k"
    elif [ "$(dest_affirmed "$b" "$CLEAN_DEST")" -gt 0 ] &&
         [ "$(dest_affirmed "$b" "$ROW_DEST")" -eq 0 ]; then
        n_clean=$((n_clean + 1))
    else
        n_other=$((n_other + 1))
        other_desc="${other_desc:-}[$k -> $b]"
    fi
done <<EOF
$(table_rows "$asym_section")
EOF

if [ "$n_rows" = 4 ]; then
    ok "the four-key table has exactly four rows"
else
    bad "the four-key table has $n_rows rows, not four — a key was added or lost"
fi

if [ "$n_other" = 0 ]; then
    ok "every row speaks exactly one of the two outcome vocabularies"
else
    bad "$n_other row(s) match neither outcome cleanly: ${other_desc:-}"
fi

if [ "$n_blind" = 1 ] && [ "${blind_key:-}" = "sentry: none" ]; then
    ok "exactly one key keeps a blind-spot row, and it is \`sentry: none\`"
else
    bad "the blind-spot row is not \`sentry: none\` alone (n=$n_blind, key=${blind_key:-none})"
fi

if [ "$n_clean" = 3 ]; then
    ok "exactly three keys render on the clean line"
else
    bad "$n_clean keys render on the clean line, not three"
fi

for k in 'sentry: none' 'testflight: none' 'posthog: none' 'mobile: none'; do
    case "$asym_keys" in
        *"[$k]"*) ok "the table still carries \`$k\`" ;;
        *) bad "the table no longer carries \`$k\`" ;;
    esac
done

# --- I2. The three-state table (#213), cut by its OWN bounds -------------------
#
# The four-key table now nests inside `exception_section`, so the #213 loop above
# sees two tables and only the accidental "blind spot"/"blind-spot" spelling
# difference keeps them apart. This slices the #213 table alone and requires it
# to hold exactly its three states.
three_state="$(printf '%s\n' "$exception_section" | awk '/^Three states, all distinct:/{f=1; next} /^####/{f=0} f')"
ts_rows="$(table_rows "$three_state" | awk 'END{print NR}')"
if [ "$ts_rows" = 3 ]; then
    ok "the three-state table holds exactly three states"
else
    bad "the three-state table holds $ts_rows rows, not three"
fi

# ...and its `sentry: none` MEANING cell must not make the over-claim. The row
# loop in section D reads only the key and behaviour columns, so before this the
# defining site could revert to "this repo has no error monitoring" untouched.
ts_meaning=""
while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(cell "$row" 2)" = "sentry: none" ] && ts_meaning="$(cell "$row" 3)"
done <<EOF
$(table_rows "$three_state")
EOF
if grep -qi 'verified' <<<"$ts_meaning"; then
    ok "the three-state table scopes \`sentry: none\` to verification"
else
    bad "the three-state table's \`sentry: none\` meaning is not scoped to verification (got: ${ts_meaning:-<none>})"
fi

# --- I3. The contract's rationales and exclusions ------------------------------

if grep -qi 'error monitoring is a gap somebody could close; an absent mobile app is a product fact' <<<"$contract_flat"; then
    ok "the contract keeps the gap-versus-product-fact rationale"
else
    bad "the contract lost the rationale for the asymmetry (gap vs product fact)"
fi

if grep -qi 'Do not "align the .none. forms' <<<"$contract_flat"; then
    ok "the contract warns against aligning the \`none\` forms"
else
    bad "the contract no longer warns a sweep off aligning the \`none\` forms"
fi

if grep -qiE 'A second reason, and it applies to .sentry:. alone' <<<"$contract_flat"; then
    ok "the contract carries the second reason (\`sentry: none\` means two things)"
else
    bad "the contract lost the two-outcomes reason for keeping sentry's row"
fi

if grep -qi 'unfinished verification wearing the same value' <<<"$contract_flat"; then
    ok "the contract names the unverifiable outcome as not a confirmed absence"
else
    bad "the contract no longer distinguishes confirmed-absent from could-not-verify"
fi

# The contract must agree with `update-mode.md` about what a REFRESH does with
# each `none`. It did not: the contract said "A refresh carries all four forward
# rather than re-asking (`references/update-mode.md`)" while the cited document
# says the opposite for `sentry:` (#268). Hard-wrapped across the line break, so
# a line-scoped grep could not see it — and nothing checked it either way.
assert_sentence_affirms "the contract says \`sentry: none\` is re-derived on a refresh" \
    "$contract_flat" 'sentry: none' "$REDERIVE_VOCAB"
assert_no_sentence_affirms "the contract never carries \`sentry: none\` forward" \
    "$contract_flat" 'sentry: none' "$CARRY_VOCAB"

if grep -qi 'Why this section is still headed' <<<"$contract_flat"; then
    ok "the contract records why the heading still names \`sentry: none\` alone"
else
    bad "the contract no longer explains its heading/body mismatch"
fi

if grep -qi '.posthog: false. is not one of the forms' <<<"$contract_flat"; then
    ok "the contract rules \`posthog: false\` out as a config form"
else
    bad "the contract no longer rules out \`posthog: false\`"
fi

for excl in '`board:` is excluded' '`stacked_prs:` is excluded' \
            '`review_agent:` and `review_site:` are excluded' \
            'None of them render a blind-spot row' \
            '`ci_workflow:` is excluded'; do
    if grep -qiF "$excl" <<<"$contract_flat"; then
        ok "exclusion stated: $excl"
    else
        bad "the contract lost an exclusion: $excl"
    fi
done

if grep -qi 'boardless form' <<<"$contract_flat"; then
    ok "the \`board:\` exclusion carries its reason (§3B's boardless form)"
else
    bad "the \`board:\` exclusion lost its reason"
fi

# The four-key claim, at the three sites that state it in prose rather than in the
# table. Each could be reverted to one key while the table still claims four.
if grep -qiE 'scoped to the four keys whose absence' <<<"$contract_flat"; then
    ok "the contract's scope sentence still names four keys"
else
    bad "the contract's scope sentence no longer names four keys"
fi

if grep -qiE 'Four of these keys .{0,80}additionally accept the scalar' <<<"$contract_flat"; then
    ok "the shared-blocks note still names four keys accepting \`none\`"
else
    bad "the shared-blocks note no longer names the four keys accepting \`none\`"
fi

# Mutation proofs: the pre-#261 sentences. Run against an EMPHASIS-STRIPPED
# flatten as well as the plain one — this repo bolds contract claims constantly,
# and `The exception is scoped to **\`sentry:\`** alone.` slipped past a check on
# the plain flatten alone.
contract_bare="$(printf '%s' "$contract_flat" | tr -d '*_')"
if grep -qi 'The exception is scoped to .sentry:. alone' <<<"$contract_bare"; then
    bad "the contract reverted to scoping the exception to \`sentry:\` alone"
else
    ok "the contract no longer scopes the exception to \`sentry:\` alone"
fi

if grep -qi 'No other key has a .none. form' <<<"$contract_bare"; then
    bad "the contract still claims no other key has a \`none\` form"
else
    ok "the contract carries no 'no other key has a \`none\` form' claim"
fi

# The banned gloss, everywhere it can be written — not just in the plate's row.
# Measured: the contract's own YAML sample and the rendered template both carried
# `# or \`sentry: none\` — confirmed: no error monitoring`, the exact wording
# detection.md forbids, in the same diff that added the ban.
template_bare="$(tr '\n' ' ' < "$TEMPLATE" | tr -s ' ' | tr -d '*_')"
# The banned LABEL forms only. The contract legitimately *enumerates* the two
# meanings ("means two: this repo has no error monitoring, or the culprit check
# could not run"), which is the explanation rather than the gloss. A function
# rather than a loop over "$name:$hay" pairs: the `${pair#*:}` split put a `#`
# inside the pipeline, and scripts/test-pipefail-grep.sh — deliberately syntactic
# — read the writer stage as a bare quote and flagged it.
GLOSS='confirmed: no error monitoring|confirmed( at setup)?( that)? this repo has no error monitoring'
check_gloss() {
    local where="$1" hay="$2"
    if grep -qiE "$GLOSS" <<<"$hay"; then
        bad "$where glosses \`sentry: none\` as a plain absence — detection.md forbids exactly this"
    else
        ok "$where makes no bare no-error-monitoring claim"
    fi
}
check_gloss "config-contract.md" "$contract_bare"
check_gloss "the rendered template" "$template_bare"

# --- I4. survey-work's §3 pull rules ------------------------------------------

plate_flat="$(tr '\n' ' ' < "$PLATE" | tr -s ' ')"

# Scoped to the PULL section (§3), where each surface's probe rule lives — not to
# the whole file. A whole-file window lands on §6's prose instead, so a probe rule
# that lost its `none` clause reads as covered while §3 still routes a confirmed
# absence to "no block -> blind-spot row". Measured: that mutation came back
# UNDETECTED against the unscoped window.
plate_pulls="$(awk '/^## 3\. /{f=1; next} /^## 4\./{f=0} f' "$PLATE" | tr '\n' ' ' | tr -s ' ')"
if [ -n "$plate_pulls" ]; then
    ok "located survey-work's §3 surface pulls"
else
    bad "cannot locate survey-work's '## 3.' surface-pull section"
fi

K_SENTRY='`sentry: none`' K_TF='`testflight: none`'
K_PH='`posthog: none`' K_MO='`mobile: none`'
# Every rule hands over to its absent-key case with this phrase, so it is the
# structural end of the `none` clause — a better bound than any byte count, and
# the thing that keeps the absent-key case's own "and a blind-spot row in §6"
# out of the `none` rule's window.
K_END='No key at all'

for key in testflight posthog mobile; do
    case "$key" in
        testflight) s1="$K_SENTRY" s2="$K_PH"  s3="$K_MO" ;;
        posthog)    s1="$K_SENTRY" s2="$K_TF"  s3="$K_MO" ;;
        mobile)     s1="$K_SENTRY" s2="$K_TF"  s3="$K_PH" ;;
    esac
    window_is_bounded "§3's \`$key: none\` window" \
        "$plate_pulls" "\`$key: none\`" 1200 "$K_END" "$s1" "$s2" "$s3"
    win="$(window_between "$plate_pulls" "\`$key: none\`" 1200 "$K_END" "$s1" "$s2" "$s3")"
    if [ -z "$win" ]; then
        bad "survey-work's §3 pull rule states nothing for \`$key: none\`"
        continue
    fi
    assert_dest "\`$key: none\` routes to the clean line" "$win" "$CLEAN_DEST" '+'
    if grep -qiF "$NA_MARKER" <<<"$win"; then
        ok "\`$key: none\` carries the \`(n/a)\` marker"
    else
        bad "\`$key: none\` lost the \`(n/a)\` marker that distinguishes it from empty"
    fi
    assert_dest "\`$key: none\` states it takes no blind-spot row" "$win" "$ROW_DEST" '-'
    # The collapse this whole form exists to prevent, in the other direction: a
    # confirmed absence described as something the plate failed to look at.
    if grep -qi 'not checked' <<<"$win"; then
        bad "\`$key: none\` is worded as an unchecked surface"
    else
        ok "\`$key: none\` is not worded as an unchecked surface"
    fi
done

# §3A's Sentry rule is the INVERSE of those three, and the loop above must never
# be widened to cover it. Measured: with `sentry` outside the loop, rewriting §3A
# to render `sentry: none` on the clean line left this gate GREEN — the headline
# decision unpinned in the very section the loop declares authoritative. The two
# vetoes below are the exclusive-vocabulary test, not a negation check; the
# affirmative pattern is what a table cell's `kept` is for prose.
window_is_bounded "§3's \`sentry: none\` window" \
    "$plate_pulls" "$K_SENTRY" 1600 "$K_END" "$K_TF" "$K_PH" "$K_MO"
sentry_win="$(window_between "$plate_pulls" "$K_SENTRY" 1600 "$K_END" "$K_TF" "$K_PH" "$K_MO")"
if [ -z "$sentry_win" ]; then
    bad "survey-work's §3 pull rule states nothing for \`sentry: none\` — it reads as unconfigured"
else
    ok "survey-work's §3 pull rule states the \`sentry: none\` case"
    assert_dest "\`sentry: none\` affirmatively keeps its blind-spot row in §3" \
        "$sentry_win" "$ROW_DEST" '+'
    assert_dest "\`sentry: none\` states it is not a clean-line token in §3" \
        "$sentry_win" "$CLEAN_DEST" '-'
    # Anchored to the phrase, not to the bare word `confirmed`, which the
    # neighbouring "§6's *Confirmed N/A* rule" reference supplies for free.
    if grep -qi 'worded as confirmed' <<<"$sentry_win"; then
        ok "\`sentry: none\` is worded as confirmed in §3, not as unconfigured"
    else
        bad "\`sentry: none\` is no longer explicitly worded as confirmed in §3"
    fi
fi

# The veto again, over the WHOLE Sentry rule rather than the `none` clause. The
# `none` window stops at `No key at all`, which is correct for the affirmative
# checks — but it means a contradictory clean-line instruction appended to the
# rule's *absent-key* half sits outside it, and §3A would then say both things.
# Measured: that mutation was undetected against the windowed veto alone. Sentry
# never reaches the clean line in EITHER state, so the whole rule may not speak
# that vocabulary.
window_is_bounded "§3A's whole-Sentry-rule window" \
    "$plate_pulls" '**Sentry** —' 2200 '**GitHub bugs**'
sentry_rule="$(window_between "$plate_pulls" '**Sentry** —' 2200 '**GitHub bugs**')"
if [ -z "$sentry_rule" ]; then
    bad "cannot locate survey-work's §3A Sentry rule"
else
    ok "located survey-work's §3A Sentry rule"
    assert_dest "§3A's Sentry rule states Sentry is not a clean-line token, in either state" \
        "$sentry_rule" "$CLEAN_DEST" '-'
fi

# --- I5. survey-work's §6 render rules ----------------------------------------

if grep -qiE 'Four of those keys also accept the scalar .none.' <<<"$plate_flat"; then
    ok "survey-work §1 states the four-key form itself"
else
    bad "survey-work §1 no longer states which keys accept \`none\`"
fi

if grep -qiE 'Confirmed N/A is a[n]? (THIRD|3rd) state' <<<"$plate_flat"; then
    ok "survey-work §6 names confirmed-N/A as a third state, distinct from empty"
else
    bad "survey-work §6 no longer distinguishes confirmed-N/A from checked-and-empty"
fi

# The RENDER RULE itself, which an agent follows — not merely the sentence that
# announces it. Measured: rewriting this to "get a blind-spot row like any other
# dark surface" left every other §6 assertion satisfied.
#
# AND IT MUST BE CUT IN TWO. §6's Confirmed-N/A block states BOTH outcomes — the
# three keys' clean line, then sentry's surviving row — so one window over the
# whole block pins neither. Measured on `main` (issue #268): replacing
# "**`sentry: none` is the deliberate exception and keeps its blind-spot row**"
# with "**`sentry: none` is aligned with the other three and takes the clean line
# too**" left this gate GREEN. The three-key assertions were satisfied by the
# three-key half, and deleting sentry's affirmation made the row veto MORE likely
# to pass, not less. That is #213's gap restored in the one section an agent
# follows when rendering, and §3A was already carrying the same lesson two
# hundred lines up.
#
# The cut is at the KEY LITERAL, which is structural — the key name, not the
# decision — so a rewrite of the decision cannot move it. If the literal is gone
# the sentry half is empty and its must-exist assertion fails loudly.
#
# WHY THIS SPLIT IS NOT THE ONE `b_clause` USES, and why that is deliberate. This
# is a PARTITION: `na_three` is the prefix and `na_sentry` the suffix, so every
# byte of the rule lands in exactly one half and nothing is discarded. The
# `### Blind spots` bullet needed `sentences_about` instead because its old cut
# took the text up to the first `. ` and THREW THE REST AWAY, so re-punctuating
# "`sentry: none` is the exception. It produces a row…" moved the row clause into
# the discarded tail and reddened the gate on correct prose. Different failure
# modes, not one shape implemented twice — do not "align" them. A partition has
# no discarded tail to lose a clause into, and every perturbation tried against
# it fails through the empty-haystack guard rather than silently.
plate_out="$(awk '/^## 6\. Output format/{f=1; next} /^## 🔥/{f=0} f' "$PLATE" | tr '\n' ' ' | tr -s ' ')"
if [ -z "$plate_out" ]; then
    bad "cannot locate survey-work's '## 6. Output format' section"
fi
window_is_bounded "§6's Confirmed-N/A window" \
    "$plate_out" 'Confirmed N/A is a THIRD state' 1800 'Skip empty P-buckets'
na_rule="$(window_between "$plate_out" 'Confirmed N/A is a THIRD state' 1800 'Skip empty P-buckets')"
if [ -z "$na_rule" ]; then
    bad "cannot locate §6's Confirmed-N/A rule body"
else
    na_three="${na_rule%%'`sentry: none`'*}"
    na_sentry="${na_rule#"$na_three"}"

    if [ -n "$na_sentry" ]; then
        ok "§6's Confirmed-N/A rule states the \`sentry: none\` case"
    else
        bad "§6's Confirmed-N/A rule never names \`sentry: none\` — the exception is gone"
    fi

    # The three-key half.
    assert_dest "§6 routes the three keys to the clean line" "$na_three" "$CLEAN_DEST" '+'
    assert_dest "§6 states the three keys get no blind-spot row" "$na_three" "$ROW_DEST" '-'
    if grep -qiF "$NA_MARKER" <<<"$na_three"; then
        ok "§6's three-key rule carries the \`(n/a)\` marker"
    else
        bad "§6's three-key rule lost the \`(n/a)\` marker"
    fi
    for k in testflight posthog mobile; do
        if grep -qF "\`$k: none\`" <<<"$na_three"; then
            ok "§6's Confirmed-N/A rule names \`$k: none\`"
        else
            bad "§6's Confirmed-N/A rule no longer names \`$k: none\`"
        fi
    done

    # The sentry half, with the expectations INVERTED. This block must never be
    # folded back into the loop above: that is exactly the shape that let the
    # inversion through.
    assert_dest "§6's \`sentry: none\` rule affirmatively keeps its blind-spot row" \
        "$na_sentry" "$ROW_DEST" '+'
    assert_dest "§6's \`sentry: none\` rule affirms no clean-line destination" \
        "$na_sentry" "$CLEAN_DEST" '0'
    if grep -qiF "$NA_MARKER" <<<"$na_sentry"; then
        bad "§6 gives \`sentry: none\` the \`(n/a)\` marker — that is the three keys' form"
    else
        ok "§6 gives \`sentry: none\` no \`(n/a)\` marker"
    fi
fi

# The `✓ Clean today:` template line is the literal block a plate is copied from.
if grep -qi 'Clean today: <checked-and-empty surface>' <<<"$plate_flat"; then
    ok "§6's output template shows the confirmed-absent token on the clean line"
else
    bad "§6's output template no longer shows a confirmed-absent token"
fi

if grep -qiE '[*]{0,2}no[*]{0,2} .skipped [^ ]* token on the sources line' <<<"$plate_flat"; then
    ok "a confirmed-absent surface takes no \`skipped —\` token on the sources line"
else
    bad "survey-work does not exempt a confirmed-absent surface from the sources-line token"
fi

if grep -qiE 'Never widen it into a claim that the repo has no Sentry' <<<"$plate_flat"; then
    ok "survey-work forbids widening the row into a no-Sentry claim"
else
    bad "survey-work lost the ban on widening \`sentry: none\` into a no-Sentry claim"
fi

plate_rules="$(awk '/^### Blind spots/{f=1; next} /^# / || /^## / || /^### /{f=0} f' "$PLATE" | tr '\n' ' ' | tr -s ' ')"
if [ -n "$plate_rules" ]; then
    ok "located survey-work's Blind spots rules"
else
    bad "cannot locate survey-work's '### Blind spots' subsection"
fi

if grep -qi 'A confirmed absence is not a dark surface' <<<"$plate_rules"; then
    ok "the Blind spots rules exclude a confirmed absence from the section"
else
    bad "the Blind spots rules no longer exclude a confirmed absence"
fi

# The exception bullet, split at the key literal like §6's rule — and for the
# same reason. What stood here was a CO-OCCURRENCE check: `sentry: none` anywhere
# in the subsection AND `produces a row` anywhere in it. Swapping which key gets
# the row satisfies both halves, so the swap stayed GREEN (issue #268).
#
# Inside `### Blind spots` the destination is named `row`, not `blind-spot row` —
# the section IS the blind spots — so this one check widens the destination, and
# only here.
#
# It is the ONE destination pattern that needs word boundaries, and without them
# it is a false GREEN, not merely noise: `row` is a substring of `grow`, `throw`,
# `narrow` and `borrow`, so "`sentry: none` is aligned with the other three, so
# the section does not grow" would AFFIRM a row and pass the assertion that
# exists to catch exactly that sentence. Verified with awk before and after.
# `blind[- ]spot row` and `clean[- ]line` need no such guard — neither is a
# substring of an English word — and boundaries elsewhere would break the
# inflections the other vocabularies match on (`re-derives`, `re-asking`).
ROW_DEST_LOCAL='(^|[^a-z])(blind[- ]spot )?rows?([^a-z]|$)'
window_is_bounded "the Blind spots confirmed-absence bullet window" \
    "$plate_rules" 'A confirmed absence is not a dark surface' 1600 \
    'Order by what the darkness costs'
bullet="$(window_between "$plate_rules" 'A confirmed absence is not a dark surface' 1600 \
    'Order by what the darkness costs')"
if [ -z "$bullet" ]; then
    bad "cannot locate the Blind spots confirmed-absence bullet"
else
    b_three="${bullet%%'`sentry: none`'*}"
    b_sentry="${bullet#"$b_three"}"
    # Sentry's own CLAUSE, and separately the whole remainder. A window right for
    # "does it keep its row" is wrong for "does this bullet ever send sentry to
    # the clean line": a contradictory clause appended later lands outside the
    # clause and inside the remainder. Both scopes are asserted — the lesson this
    # file already recorded for §3A.
    #
    # The clause is every SENTENCE mentioning the key, not the text up to the
    # first `. `. That cut reddened the gate on a benign re-punctuation:
    # "`sentry: none` is the exception. It produces a row, worded as confirmed"
    # moves the row clause into a sentence the cut discarded, and the run failed
    # with `affirmed=0 negated=0` on correct prose.
    b_clause="$(sentences_about "$b_sentry" 'sentry: none')"

    if [ -n "$b_sentry" ]; then
        ok "the Blind spots bullet states the \`sentry: none\` case"
    else
        bad "the Blind spots bullet no longer names \`sentry: none\`"
    fi
    for k in testflight posthog mobile; do
        if grep -qF "\`$k: none\`" <<<"$b_three"; then
            ok "the Blind spots bullet names \`$k: none\` among the excluded"
        else
            bad "the Blind spots bullet no longer excludes \`$k: none\` from the section"
        fi
    done
    assert_dest "the Blind spots bullet sends the three keys to the clean line" \
        "$b_three" "$CLEAN_DEST" '+'
    assert_dest "the Blind spots bullet states the three keys get no row" \
        "$b_three" "$ROW_DEST_LOCAL" '-'
    assert_dest "the Blind spots bullet affirmatively keeps \`sentry: none\`'s row" \
        "$b_clause" "$ROW_DEST_LOCAL" '+'
    assert_dest "\`sentry: none\`'s clause affirms no clean-line destination" \
        "$b_clause" "$CLEAN_DEST" '0'
    assert_dest "nothing after \`sentry: none\` sends it to the clean line either" \
        "$b_sentry" "$CLEAN_DEST" '0'
fi

# The example block is what an agent copies. FLATTENED, per this script's own rule
# at the top: MD013 is off here, so a hard-wrapped row is invisible to a
# line-scoped grep and reports a FALSE PASS. Measured both ways.
plate_blind_flat="$(printf '%s\n' "$plate_blind" | tr '\n' ' ' | tr -s ' ')"
for key in testflight posthog mobile; do
    if grep -qi "$key: none" <<<"$plate_blind_flat"; then
        bad "survey-work's blind-spot example still renders a \`$key: none\` row"
    else
        ok "survey-work's blind-spot example renders no \`$key: none\` row"
    fi
done

# --- I6. The three `none` values are ASKED, never defaulted -------------------

q2c="$(awk '/^### 2c\./{f=1; next} /^### /{f=0} f' "$INTERVIEW" | tr '\n' ' ' | tr -s ' ')"

if [ -n "$q2c" ]; then
    ok "interview.md carries the confirmed-absent question (§2c)"
else
    bad "interview.md has no confirmed-absent question — the three keys cannot be set"
fi

for key in testflight posthog mobile; do
    if grep -qF "\`$key: none\`" <<<"$q2c"; then
        ok "§2c names the \`$key: none\` value it writes"
    else
        bad "§2c never names \`$key: none\` — the key it covers is unstated"
    fi
done

# The TRIGGER. "Keys detection could not establish" silently excluded `posthog`,
# whose detector always answers true/false — so the key that motivated the form
# was unreachable on the very path that writes it.
if grep -qi 'would otherwise leave' <<<"$q2c"; then
    ok "§2c triggers on a key being left absent, not on detection failing"
else
    bad "§2c's trigger is not the absent-key one — \`posthog\` may be unreachable again"
fi

if grep -qi 'always answers' <<<"$q2c"; then
    ok "§2c names why \`posthog\` needs the absent-key trigger"
else
    bad "§2c no longer explains why a detection-based trigger excluded \`posthog\`"
fi

# All FOUR generator modes must reach it — `setup-config` has create, update,
# migrate and adopt, and §2c claimed "all three" while omitting adopt (#268).
# Migrate and adopt are the two most likely to need it (neither a legacy render
# nor a hand-written skill can supply a `none`) and adopt reached it via nothing.
# Emphasis-stripped: the modes are named as **create** mode / **update** mode,
# so a plain-substring check for "create mode" misses them.
q2c_bare="$(printf '%s' "$q2c" | tr -d '*_')"
# A mode's BODY, not just its heading. `In **migrate** mode: **skip it**` keeps
# the list entry and passes a presence check — the heading survives while the
# rule under it is reversed.
#
# Each clause must AFFIRM that it asks. The first cut of this vetoed a
# skip/inherit vocabulary instead, which is the closed-enumeration mistake this
# same diff removed from `BLIND_AFFIRM` one section up: measured, rewriting
# adopt's clause to "the question is deferred to the next refresh" evaded every
# term and stayed GREEN. Ways of not asking are an open class; asking is a
# single act, so the affirmative is the half worth requiring. The veto is kept
# beside it — a clause that says both is a contradiction, not a pass.
ASK_VOCAB='ask|asks|asked|asking'
SKIP_VOCAB='skip it|skipped|does not apply|not applicable|exempt|inherits whatever|leave (it|them) alone|never asked|no need to ask|deferred|postponed'
Q2C_END='It is the only way'
for mode in create update migrate adopt; do
    # The LIST ENTRY, not a mention. A bare `grep "migrate mode"` is satisfied by
    # a sentence that demotes the mode ("Migrate mode inherits whatever the
    # legacy render supplied"), which is the inversion this must catch.
    if grep -qi "In $mode mode:" <<<"$q2c_bare"; then
        ok "§2c commits to asking in $mode mode"
    else
        bad "§2c does not commit to asking in $mode mode — that path leaves the keys absent"
        continue
    fi
    # Every mode marker is passed as a stop — the window's own mark is consumed
    # before the cut, so listing it here is harmless and keeps the call uniform.
    window_is_bounded "§2c's $mode-mode clause window" \
        "$q2c_bare" "In $mode mode:" 900 "$Q2C_END" \
        "In create mode:" "In update mode:" "In migrate mode:" "In adopt mode:"
    mode_win="$(window_between "$q2c_bare" "In $mode mode:" 900 "$Q2C_END" \
        "In create mode:" "In update mode:" "In migrate mode:" "In adopt mode:")"
    assert_dest "§2c's $mode-mode clause affirmatively asks" \
        "$mode_win" "$ASK_VOCAB" '+'
    assert_dest "§2c's $mode-mode clause does not exempt the mode from asking" \
        "$mode_win" "$SKIP_VOCAB" '0'
done

if grep -qi 'never default' <<<"$q2c"; then
    ok "§2c forbids defaulting a \`none\`"
else
    bad "§2c no longer forbids defaulting a \`none\`"
fi

if grep -qi 'Do not offer the same question for .sentry:.' <<<"$q2c"; then
    ok "§2c keeps \`sentry:\` out of the confirmed-absent question"
else
    bad "§2c no longer excludes \`sentry:\` from the confirmed-absent question"
fi

# A legacy `posthog: false` is neither absent nor a legal form, so an
# absent-only trigger drops it silently and the row survives.
# Three parts, because the trigger sentence and its explanation can be made to
# contradict each other: the rule itself, the explicit rejection of absent-only,
# and the value it exists for. Measured: narrowing only the explanation to "an
# absent key is the only case" left a two-part check green.
if grep -qi 'leave carrying a value the contract no longer defines' <<<"$q2c" &&
   grep -qi 'not "absent" alone' <<<"$q2c" &&
   grep -qi 'posthog: false' <<<"$q2c"; then
    ok "§2c's trigger covers a legacy \`posthog: false\`, not only an absent key"
else
    bad "§2c's trigger is absent-only — a legacy \`posthog: false\` is dropped and the row survives"
fi

# --- I7. A refresh carries a `none` forward, never re-asking ------------------

update_flat="$(tr '\n' ' ' < "$UPDATE" | tr -s ' ')"

window_is_bounded "update mode's carry-forward window" \
    "$update_flat" '**A `none` is an answer already given' 2400 '**Do not read that'
carry_win="$(window_between "$update_flat" '**A `none` is an answer already given' 2400 '**Do not read that')"
if [ -z "$carry_win" ]; then
    bad "update mode has no carry-a-\`none\`-forward rule"
else
    ok "update mode carries the carry-a-\`none\`-forward rule"
    if grep -qi 'never re-ask' <<<"$carry_win"; then
        ok "the rule forbids re-asking an existing \`none\`"
    else
        bad "the rule no longer forbids re-asking an existing \`none\`"
    fi
    # Anchored to the phrase. A bare `grep -qi confirmation` is satisfied by the
    # window's own opening sentence, which made this assertion unfailable.
    if grep -qiE 'cannot re-derive is the .{0,4}confirmation' <<<"$carry_win"; then
        ok "the rule names the CONFIRMATION as the thing that cannot be re-derived"
    else
        bad "the rule no longer says it is the confirmation that cannot be re-derived"
    fi
fi

# `sentry: none` must NOT be in that carve-out: detection.md writes it when there
# is no MCP server or no issues to sample, both transient session conditions, so
# freezing it would let one unlucky run permanently retire the highest-signal
# surface with no recovery path.
#
# Read from the WHOLE file by sentence, not from `carry_win`. Two defects were
# measured here (#268). The check was `carry_win | grep -qi 're-derived on every
# refresh'`, which is satisfied by "is NOT re-derived on every refresh" — the
# exact inversion it exists to catch. And the phrase sat at byte 933 of a
# 937-byte window, so one sentence inserted above it would have moved it out of
# scope and reddened the gate on an edit that changed nothing.
assert_sentence_affirms "update mode says \`sentry: none\` is re-derived, not frozen" \
    "$update_flat" 'sentry: none' "$REDERIVE_VOCAB"
assert_no_sentence_affirms "update mode never carries \`sentry: none\` forward" \
    "$update_flat" 'sentry: none' "$CARRY_VOCAB"

window_is_bounded "update mode's positive-evidence window" \
    "$update_flat" '**Positive evidence against a `none`' 900 '**An ABSENT one'
pos_win="$(window_between "$update_flat" '**Positive evidence against a `none`' 900 '**An ABSENT one')"
if [ -z "$pos_win" ]; then
    bad "update mode has no rule for positive evidence against a \`none\`"
else
    ok "update mode carries the positive-evidence rule"
    if grep -qi 'stop and surface' <<<"$pos_win"; then
        ok "positive evidence against a \`none\` is a stop-and-surface"
    else
        bad "positive evidence against a \`none\` is no longer a stop-and-surface"
    fi
    if grep -qiE '[Nn]ever silently rewrite' <<<"$pos_win"; then
        ok "a contradicted \`none\` is never silently rewritten"
    else
        bad "update mode lost the never-silently-rewrite rule"
    fi
fi

window_is_bounded "update mode's absent-key window" \
    "$update_flat" '**An ABSENT one of these keys' 2400 '**Migrate mode inherits'
absent_win="$(window_between "$update_flat" '**An ABSENT one of these keys' 2400 '**Migrate mode inherits')"
if [ -z "$absent_win" ]; then
    bad "update mode has no path to WRITE a \`none\` — the rollout is a no-op"
else
    ok "update mode has a path to write a \`none\` for an absent key"
    if grep -q '§2c' <<<"$absent_win"; then
        ok "an absent key routes to interview §2c"
    else
        bad "the absent-key path names no question to ask"
    fi
    if grep -qi 'Do not gate that on the tree being quiet' <<<"$absent_win"; then
        ok "the absent-key path is not gated on a quiet tree"
    else
        bad "the absent-key path is gated on a quiet tree — a dismissed hit is skipped"
    fi
    if grep -qi 'posthog: false' <<<"$absent_win"; then
        ok "the absent-key path also covers a legacy \`posthog: false\`"
    else
        bad "the absent-key path ignores a legacy \`posthog: false\`"
    fi
    if grep -qi 'Not sure' <<<"$absent_win"; then
        ok "the absent-key path keeps an answer that leaves the key absent"
    else
        bad "the absent-key path no longer offers an answer that leaves the key absent"
    fi
fi

# Mutation proof: the claim this rule shipped with and which is FALSE —
# `detect-capabilities.sh` derives `posthog` outright, and detection proposes all
# three. An agent that believes it never runs the tree check the rule depends on.
if grep -qi 'None of the four is re-derivable' <<<"$(tr -d '*_' <<<"$update_flat")"; then
    bad "update mode reasserts that none of the four is re-derivable (posthog is)"
else
    ok "update mode makes no blanket not-re-derivable claim"
fi

# Migrate mode reaches the same absent-key state, and its own doc is a different
# file. A note here is not enough on its own, so both are required.
if grep -qi 'Migrate mode inherits' <<<"$update_flat"; then
    ok "update-mode.md hands the rule to migrate mode"
else
    bad "update-mode.md says nothing about migrate mode, which needs this most"
fi

migrate_flat="$(tr '\n' ' ' < "$MIGRATE" | tr -s ' ')"
if grep -qi 'ask §2c for the three confirmed-absent keys' <<<"$migrate_flat" &&
   grep -qi 'extraction can never produce one' <<<"$migrate_flat"; then
    ok "migrate-mode.md has its own step asking §2c for the three keys"
else
    bad "migrate-mode.md has no §2c step — every migrated repo keeps the rows"
fi

# ADOPT mode needs the identical step, and for a reason that is easy to miss:
# `SKILL.md` Phase 5 routes adopt through this file, but this file's Adopt mode
# step 2 says "Run create mode's detect + interview", and create mode's §2c
# trigger is CONDITIONAL ("every key with no positive evidence"). So the routing
# is real and the always-ask is not inherited — the gap migrate closed with its
# own Step 2b. Without this, `interview.md` §2c's "always" for adopt is prose no
# instruction implements, which is the shape this file exists to refuse.
adopt_sec="$(awk '/^## Adopt mode/{f=1; next} /^## /{f=0} f' "$UPDATE" | tr '\n' ' ' | tr -s ' ')"
if [ -z "$adopt_sec" ]; then
    bad "cannot locate update-mode.md's Adopt mode section"
else
    ok "located update-mode.md's Adopt mode section"
    if grep -q '§2c' <<<"$adopt_sec"; then
        ok "adopt mode names interview §2c"
    else
        bad "adopt mode names no §2c step — every adopted repo keeps the three rows"
    fi
    assert_dest "adopt mode's §2c step affirmatively asks" "$adopt_sec" "$ASK_VOCAB" '+'
    if grep -qi 'always' <<<"$adopt_sec"; then
        ok "adopt mode's §2c step is unconditional"
    else
        bad "adopt mode's §2c step is conditional — create mode's trigger does not reach it"
    fi
    # Emphasis-stripped: the source writes `**not** part of this question`, and a
    # plain-substring check for the phrase misses it — the trap already recorded
    # for §2c's mode names.
    adopt_bare="$(printf '%s' "$adopt_sec" | tr -d '*_')"
    if grep -qi 'sentry' <<<"$adopt_bare" &&
       grep -qi 'not part of this question' <<<"$adopt_bare"; then
        ok "adopt mode keeps \`sentry:\` out of the confirmed-absent question"
    else
        bad "adopt mode does not exclude \`sentry:\` from the §2c question"
    fi
fi

# --- I8. setup-config/SKILL.md carries the three rules too --------------------
#
# SKILL.md is loaded on EVERY invocation while `references/` are read on demand,
# and AGENTS.md's "SKILL.md stays thin" rule is an active reason a later sweep
# deletes these. Measured: inverting all three left this gate green, because §F
# above greps `skill_flat` only for #213's strings.

window_is_bounded "Phase 2's never-default window" \
    "$skill_flat" '**Never default a confirmed-absent `none`.**' 900 '## Phase 3'
nodefault_win="$(window_between "$skill_flat" '**Never default a confirmed-absent `none`.**' 900 '## Phase 3')"
if [ -z "$nodefault_win" ]; then
    bad "setup-config/SKILL.md has no never-default-a-\`none\` rule"
else
    ok "setup-config/SKILL.md forbids defaulting a \`none\`"
    if grep -q '§2c' <<<"$nodefault_win"; then
        ok "Phase 2 routes the three keys to interview §2c"
    else
        bad "Phase 2 no longer names §2c as the only writer of the three keys"
    fi
    if grep -qi 'quiet tree' <<<"$nodefault_win"; then
        ok "Phase 2 names the trap (a quiet tree is not a confirmation)"
    else
        bad "Phase 2 no longer explains why detection alone cannot write a \`none\`"
    fi
fi

window_is_bounded "setup-config Phase 4's \`none\` window" \
    "$skill_flat" '**The three `none` answers are carried forward' 1600 'Apply per file'
phase4_win="$(window_between "$skill_flat" '**The three `none` answers are carried forward' 1600 'Apply per file')"
if [ -z "$phase4_win" ]; then
    bad "setup-config/SKILL.md Phase 4 states nothing about the \`none\` answers"
else
    ok "setup-config/SKILL.md Phase 4 covers the \`none\` answers"
    if grep -qi 'not re-asked' <<<"$phase4_win"; then
        ok "Phase 4 carries an existing \`none\` forward"
    else
        bad "Phase 4 no longer carries an existing \`none\` forward"
    fi
    if grep -q '§2c' <<<"$phase4_win"; then
        ok "Phase 4 asks §2c where one of the three keys is missing entirely"
    else
        bad "Phase 4 has no path to write a \`none\` for a missing key"
    fi
    # Per SENTENCE, not per window. What stood here was `grep -qi 'sentry'` AND
    # `grep -qi 're-derived'` over the whole window — two independent substring
    # hits that "`sentry: none` is **not** re-derived on every refresh" satisfies
    # exactly as well as the rule it inverts (#268).
    assert_sentence_affirms "Phase 4 says \`sentry: none\` is re-derived, not carried forward" \
        "$phase4_win" 'sentry: none' "$REDERIVE_VOCAB"
    # ...AND the veto. Without it Phase 4 could state decision D and its inverse
    # at once — measured: appending "In practice a refresh keeps whatever
    # `sentry: none` the previous run recorded and never re-asks it." left the
    # gate GREEN. That is #267's shape exactly, in the file AGENTS.md names as
    # the copy to trust and the one loaded on every `setup-config` run.
    assert_no_sentence_affirms "Phase 4 never carries \`sentry: none\` forward" \
        "$phase4_win" 'sentry: none' "$CARRY_VOCAB"
fi

# The guardrail list, which AGENTS.md names as the copy to trust. Its carve-out
# is read as a MEMBER LIST and every member is accounted for, because the check
# that stood here was `grep -q '\`none\`'` — satisfied by any mention of the word
# — and #267 had quietly added `sentry:` to the list, contradicting the same
# file two paragraphs up and `update-mode.md` outright (#268). Freezing
# `sentry: none` lets one session with no MCP server retire the plate's
# highest-signal surface permanently, since the only evidence that could
# contradict the value is the check the carve-out skips.
skill_guard="$(awk '/^## Guardrails/{f=1; next} /^## /{f=0} f' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
[ -n "$skill_guard" ] || bad "cannot locate setup-config/SKILL.md's Guardrails section"
nevercopy="$(printf '%s' "$skill_flat" |
    grep -oE 'Never copy a fact forward without re-verifying it against live state[^.]*\.')"
if [ -z "$nevercopy" ]; then
    bad "cannot locate setup-config's never-copy-a-fact-forward guardrail"
else
    ok "located the never-copy-a-fact-forward guardrail"
    if grep -q '`none`' <<<"$nevercopy"; then
        ok "the never-copy guardrail names the \`none\` answers as an exception"
    else
        bad "the never-copy guardrail no longer excepts the \`none\` answers"
    fi
    carveout_list="$(printf '%s' "$nevercopy" | grep -oE '\(`[^)]*`\)' | tail -1)"
    if [ -z "$carveout_list" ]; then
        bad "the never-copy guardrail no longer enumerates which \`none\` forms it excepts"
    else
        cm_n=0 cm_sentry=0
        for cm in $(printf '%s' "$carveout_list" | tr -d '()`' | tr ',' ' '); do
            cm_n=$((cm_n + 1))
            case "$cm" in sentry*) cm_sentry=1 ;; esac
        done
        if [ "$cm_n" = 3 ]; then
            ok "the guardrail's carve-out names exactly three \`none\` forms"
        else
            bad "the guardrail's carve-out names $cm_n \`none\` forms, not three: $carveout_list"
        fi
        if [ "$cm_sentry" = 0 ]; then
            ok "the guardrail's carve-out excludes \`sentry:\`"
        else
            bad "the guardrail's carve-out includes \`sentry:\` — one bad session retires Sentry forever"
        fi
    fi
    # ...and the exclusion is stated INLINE, beside the list. A reader who stops
    # at the guardrail must not have to reach Phase 4 to learn sentry is out.
    # Both halves, for the reason given at the Phase 4 site: a must-exist alone
    # lets the same list state the rule and its inverse.
    assert_sentence_affirms "the guardrail says \`sentry: none\` is re-derived, inline" \
        "$skill_guard" 'sentry: none' "$REDERIVE_VOCAB"
    assert_no_sentence_affirms "the guardrail never carries \`sentry: none\` forward" \
        "$skill_guard" 'sentry: none' "$CARRY_VOCAB"
fi

# --- I9. The rendered template names the form and its asymmetry --------------

if grep -qi 'FOUR keys carry it' <<<"$header_flat"; then
    ok "the template header names all four keys carrying the \`none\` form"
else
    bad "the template header no longer names the four-key \`none\` form"
fi

if grep -qi 'only .sentry: none. still renders a blind-spot' <<<"$header_flat"; then
    ok "the template header states the asymmetry"
else
    bad "the template header no longer states which key keeps its blind-spot row"
fi

# A VACUITY FLOOR, and it is worth being exact about what it does and does not
# catch. A broken EXTRACTOR already fails loudly here: every window has a `-z`
# guard, and `assert_dest` refuses an empty haystack outright. What nothing else
# sees is a whole assertion BLOCK deleted in a refactor — the count drops and the
# run still says "all green". So the floor is coarse on purpose, set well below
# today's total: it catches a collapse, not a trim, and a floor tuned to today's
# exact number is one more inventory that rots.
#
# The count itself is PRINTED, never transcribed. That is issue #268's sixth
# acceptance item taken literally: a number nobody can re-derive from the tree is
# not worth carrying, and AGENTS.md carried a wrong one ("39 semantic mutations,
# 0 stale and 0 undetected, 59 assertions measured load-bearing") for exactly
# that reason, in the one place a future editor trusts instead of re-measuring.
# ---------------------------------------------------------------------------
# The tracked-file count is RE-DERIVED, never transcribed (issue #278)
# ---------------------------------------------------------------------------
# The same defect #276 closed for test-review-gate-decisions.sh, and this file's
# own free-floating-count bullet had been naming it as the live instance since
# then. The read set is `READS` now, so the count is its length; every place
# that restates it is compared against that, and every spelled hit in a governed
# region is ACCOUNTED FOR rather than looked up — a region carrying the right
# number AND a wrong one must fail, which a bare must-exist check cannot see.
#
# KNOWN LIMITS, in the idiom the sibling gates use:
#
#   * DIGIT forms are invisible: `it reads 8 tracked files` beside a correct
#     spelled count passes. Spelled words only, the same limit this file already
#     states for its own partitive probe.
#   * The regions are anchored on the SCRIPT NAME, never on a gate number or a
#     line number — both rot, and this file has already been cited as "gate 26"
#     while it was numbered 29.
#   * A restatement varying the noun ("eight documents", "eight sources") sits
#     outside `check_files` and is unseen. The noun is matched exactly, for the
#     reason #276 records: a looser match starts colliding with other gates'
#     counts in preflight's list, where `N tracked files` is how nearly every
#     entry ends.
echo "-- the tracked-file count is re-derived from READS, not transcribed"

# Running from a COPY would measure the tracked file rather than the copy, so a
# mutation applied to a tmpdir copy reports `undetected` while proving nothing
# (#262). A mutation harness must edit the tracked file in place and restore it.
SELF_278="scripts/test-sentry-verification.sh"
if [ -r "$SELF_278" ]; then
    ok "the counts section can read its own tracked path"
else
    bad "cannot read $SELF_278 — every count check below would be vacuous"
fi

NUM_WORDS_278=(zero one two three four five six seven eight nine ten eleven
               twelve thirteen fourteen fifteen sixteen seventeen eighteen
               nineteen twenty)
NUMWORDS_278="$(IFS='|'; printf '%s' "${NUM_WORDS_278[*]:1}")"

# One normaliser, three call sites. Leading comment and blockquote markers are
# stripped, because a phrase wrapped across two comment lines otherwise joins as
# `... eight # tracked files` and reads ABSENT — a false pass, and preflight's
# gate list is hard-wrapped and already wraps mid-phrase. Emphasis is stripped
# for the same reason: `**eight** tracked files` is the same miss in a hat, and
# site 4 is markdown prose, where bolding a numeral is a one-keystroke edit no
# gate forbids.
normalize_278() {
    sed -E -e 's/^[[:space:]]*(>[[:space:]]?)+//' -e 's/^[[:space:]]*#[[:space:]]?//' \
           -e 's/\*//g' <<<"$1" | tr '\n' ' ' | tr -s ' '
}

# check_files <label> <region> <noun> <expected word> — every spelled count of
# <noun> in the region must be the re-derived one, and at least one must be
# stated. The left boundary stops `twenty-eight files` reading as `eight`.
check_files() {
    local label="$1" text="$2" noun="$3" want="$4" hits wrong
    hits="$(grep -oiE "(^|[^A-Za-z-])($NUMWORDS_278) $noun" <<<"$text" \
        | tr 'A-Z' 'a-z' | sed -E 's/^[^a-z]+//' | sort -u)"
    if [ -z "$hits" ]; then
        bad "$label states no '$noun' count at all — re-derived: $want $noun"
        return
    fi
    wrong="$(grep -vxF "$want $noun" <<<"$hits" | tr '\n' ' ')"
    if [ -n "$wrong" ]; then
        bad "$label states ${wrong}— re-derived from READS: $want $noun"
    else
        ok "$label states $want $noun"
    fi
}

n_files_278="${#READS[@]}"
want_278=""
[ "$n_files_278" -lt "${#NUM_WORDS_278[@]}" ] && want_278="${NUM_WORDS_278[$n_files_278]}"
if [ -n "$want_278" ]; then
    ok "the read set has $n_files_278 members, spelled '$want_278'"
else
    bad "the read set has $n_files_278 members, past the spelled-number table — extend NUM_WORDS_278"
fi

# VACUITY FLOOR on the derivation itself: a READS that matched nothing would
# re-derive 0 and let every site below pass against a number nobody uses.
if [ "$n_files_278" -ge 2 ]; then
    ok "and that derivation is live ($n_files_278 members, floor 2)"
else
    bad "READS has $n_files_278 members — the derivation is broken, not the sites clean"
fi

# --- site 1: this file itself ------------------------------------------------
# MINUS the free-floating-count bullet, and that exclusion is principled rather
# than convenient: that bullet's whole job is to discuss counts in OTHER files,
# so it QUOTES them, including one that spells out a DIFFERENT gate's read-set
# size — a correct statement about test-review-gate-decisions.sh and a wrong one
# about this file. (This comment deliberately describes that quotation instead
# of repeating it: the first draft quoted it verbatim and thereby re-created the
# very collision it is explaining, one level up, outside the window it defines.)
# Including the bullet made the check fail on true prose, which
# is the loud-false-red this repo prefers to avoid when the fix is a window
# rather than a weaker rule. The window is anchored on the bullet's own text.
self_full="$(cat "$SELF_278")"
self_trimmed="$(awk '
    /NON-PARTITIVE free-floating counts/ { skip = 1 }
    skip && /^# A probe with a stated blind spot is honest/ { skip = 0 }
    !skip { print }' <<<"$self_full")"
# The exclusion must actually REMOVE something, or site 1 silently becomes the
# whole file again and the reason for the window is lost with it.
if [ "$(printf '%s' "$self_trimmed" | wc -l)" -lt "$(printf '%s' "$self_full" | wc -l)" ]; then
    ok "the free-floating-count bullet is excluded from this file's own count scan"
else
    bad "the blind-spot bullet window matched nothing — site 1 is scanning the whole file, quotations included"
fi
self_278="$(normalize_278 "$self_trimmed")"
check_files "this gate's own header and body" "$self_278" "tracked files" "$want_278"
check_files "and its 'files this gate reads' phrasing" "$self_278" "files this gate reads" "$want_278"

# --- site 2: preflight's gate description, anchored on the SCRIPT NAME --------
# From the entry naming this script to the start of the next numbered entry.
pf_desc="$(awk '
    /scripts\/test-sentry-verification\.sh\)/ { inseg = 1 }
    inseg && /^#  [0-9]+\. / && !/test-sentry-verification/ { exit }
    inseg { print }' scripts/preflight.sh)"
if [ -n "$pf_desc" ]; then
    ok "preflight's gate description for this script resolves"
    check_files "preflight's gate description" "$(normalize_278 "$pf_desc")" "files" "$want_278"
else
    bad "preflight's gate description for this script did not resolve — the check over it would be vacuous"
fi

# --- site 3: preflight's inline comment at the invocation --------------------
# ONLY the contiguous comment block directly above THIS script's invocation.
# A file-wide sweep for the phrase matched another gate's identical comment —
# `Reads two tracked files: no gh, no network.` — and reported this site as
# stating two. Every gate in preflight ends its entry the same way, so the
# anchor has to be the invocation, not the phrase.
pf_inv="$(awk '
    /^if pg_gate scripts\/test-sentry-verification\.sh; then/ { for (i = 1; i < n; i++) print buf[i]; exit }
    /^#/ { buf[n++] = $0; next }
    { n = 1 }' scripts/preflight.sh)"
if [ -n "$pf_inv" ]; then
    ok "preflight's invocation-site comment resolves"
    check_files "preflight's invocation-site comment" "$(normalize_278 "$pf_inv")" "tracked files" "$want_278"
else
    bad "preflight's invocation-site comment did not resolve — the check over it would be vacuous"
fi

# --- site 4: AGENTS.md's gate paragraph --------------------------------------
# Bounded by the NEXT gate's opener, since AGENTS.md's gate list is one line.
am_desc="$(awk -v RS='\n' '
    { i = index($0, "scripts/test-sentry-verification.sh")
      if (i > 0) { rest = substr($0, i)
                   j = index(rest, "the sentry-counts tests")
                   print (j > 0 ? substr(rest, 1, j) : rest) } }' AGENTS.md)"
if [ -n "$am_desc" ]; then
    ok "AGENTS.md's paragraph for this gate resolves"
    check_files "AGENTS.md's gate paragraph" "$(normalize_278 "$am_desc")" "tracked files" "$want_278"
else
    bad "AGENTS.md's paragraph for this gate did not resolve — the check over it would be vacuous"
fi

ASSERT_FLOOR=130
if [ "$asserts" -lt "$ASSERT_FLOOR" ]; then
    echo "test-sentry-verification: only $asserts assertions ran (floor $ASSERT_FLOOR) — an extractor is silently matching nothing" >&2
    exit 1
fi

if [ "$fails" -ne 0 ]; then
    echo "test-sentry-verification: FAILED ($fails of $asserts assertions)" >&2
    exit 1
fi
echo "Sentry verification tests: all green ($asserts assertions)"
