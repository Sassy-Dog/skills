#!/usr/bin/env bash
# test-review-gate-decisions.sh — pins the SEVEN decisions settled about the
# review gate: three from #237 (PR #243, issue #247), two more from #248
# (PR #250, issue #255) covering the gate's two DISPATCHING paths, one from
# #273 covering how a report is DELIVERED once the gate has run, and one from
# #280 binding that same delivery one hop DOWN, at the nine reviewers the
# orchestrator fans out to.
#
# All seven decisions are prose, none of them derivable from anything a script
# can run, and every one of them reads to a future "align with the governing
# principle" sweep like drift that ought to be tidied away:
#
#   1. THE REVIEW GATE IS UNCONDITIONAL. `review_agent:` resolves to the shipped
#      `sassy-dog:pr-review-orchestrator` when the key is absent, so the gate has
#      an outcome on every PR and an unconfigured repo can no longer ship
#      unreviewed. #235's verbatim
#      `review: SKIPPED — no review_agent resolved (lint/type/test only)` line
#      SURVIVES the default as the backstop for *resolution* failure — the agent
#      does not exist, the plugin did not load, the dispatch errored. Deleting it
#      as unreachable re-creates the original silent-no-review bug wearing a
#      default: the run that printed nothing would be indistinguishable from the
#      run that reviewed cleanly. To a reader who sees only "there is always a
#      default", the line looks like dead code.
#      The COORDINATOR-site gates carve out the explicit opt-out too (#409):
#      under `review_agent: skip` + `review_site: coordinator` no agent resolves,
#      and without a carve-out the "no agent resolved" bullet holds every PR —
#      the blanket merge freeze the either-site carve-outs exist to prevent.
#      The carve-out is pinned in take-it's coordinator subsection and in
#      dispatch-ready's not-yet-reviewed bullet, with the resolution-failure
#      hold pinned beside it. Mutants, each measured to FAIL: deleting the
#      take-it carve-out bullet; deleting the dispatch-ready carve-out sentence.
#
#   2. `review_agent` IS DELIBERATELY NOT PRESENCE-IS-THE-TOGGLE. The config
#      contract's governing principle is that the presence of a block enables the
#      feature; `review_agent` has a DEFAULT, so presence is not its toggle at
#      all. #243 moved it OUT of that key list on purpose and added
#      `review_surfaces` (no default) to it in the same edit. In the key list this
#      reads as a plain inconsistency, and "restoring" it would silently turn the
#      absent key back into an off switch for every consumer repo at once.
#
#   3. THE OPT-OUT IS `review_agent: skip`, NOT `none`. The contract's
#      `sentry: none` section — itself pinned by test-sentry-verification.sh —
#      states that it is the FIRST documented exception to presence-is-the-toggle
#      and that a key joining that form needs the same justification: a value
#      recording that somebody went and CHECKED for a confirmed absence.
#      `review_agent`'s opt-out overrides a default instead, so that
#      justification does not apply, and `skip` is also the word the gate's own
#      output uses. The missing symmetry is exactly what a tidying sweep would
#      "fix" — and issue #261 raised that pressure rather than lowering it, by
#      growing the `none` form from one key to FOUR (`sentry`, `testflight`,
#      `posthog`, `mobile`). The contract now names `review_agent:` and
#      `review_site:` in that section's exclusion list, with the reason; this
#      gate is what keeps `skip` from being "aligned" to `none` anyway.
#
#   4. `review_site` IS CONFIGURED, NOT DERIVED — DELIBERATELY. The contract's
#      governing principle is *configure only what cannot be derived*, and repo
#      visibility IS derivable: `gh repo view --json visibility` answers it on
#      any run. So a literal reading of that principle deletes the key. Do not.
#      Deriving it live means a visibility change silently rewrites a repo's
#      review architecture — taking a repo private downgrades it from pre-PR
#      review to after-the-fact review with no config diff, no prompt, and no
#      line in any run's output. That is the #187 failure class: a visibility
#      transition silently disabling a protection the repo was relying on.
#      `setup-config` therefore seeds it ONCE from visibility at setup and
#      records the resolved value. The half that a REFRESH would undo lives in
#      a different file: Phase 4 of `setup-config/SKILL.md` carves `review_site`
#      out of update mode's "re-verify every fact against live state" rule, and
#      that carve-out is what stops the first refresh after a visibility change
#      from re-creating the silent flip. Both halves are pinned here — the
#      contract entry AND the Phase 4 exception, scoped to the phase it governs.
#
#   5. A BLOCKING FINDING BLOCKS THE MERGE, WITH EXACTLY ONE REDISPATCH.
#      `dispatch-ready` surfaces the finding named, comments it on the issue,
#      allows ONE redispatch carrying the finding as context, then demotes to
#      `blocked` on a second failure. Never merge past it; never park it back
#      in Ready, which must stay synonymous with dispatchable. The number is
#      the part that rots: on its own "one" reads as an arbitrary retry count,
#      so the rationale — it is the SAME single-redispatch budget a failed
#      check already gets — is pinned alongside it. `take-it` states the same
#      rule for its own coordinator site, and both guardrail lists repeat it,
#      because these two skills dispatch sub-agents that open PRs from a cold
#      worktree and never see an interactive session's instructions.
#      #385 extends that same allowance to parent fan-out; #386 uses it for
#      one same-agent report-only recovery. Both preserve durable
#      recovery_used accounting across a new head, agent or tick. This extends
#      decision 5 rather than inventing a second budget.
#
#   6. THE REPORT IS RETURNED, AND A LOST ONE IS ITS OWN OUTCOME. A review
#      report is delivered as the reviewing agent's FINAL TEXT — its return
#      value — and `SendMessage` is not a delivery mechanism for it, because
#      sending needs an address the reviewer cannot reliably resolve. Measured
#      on 2026-08-25: five occurrences across three issues, not one of them
#      reaching the session that dispatched it. THREE landed in a coordinator's
#      session instead, one round lost 2 of 5 dispatches that never returned at
#      all, and one was addressed to an agent TYPE rather than an address
#      (#273). Every report that arrived at all did so because a human
#      coordinator relayed it by hand, which is exactly what an unattended
#      `dispatch-ready` loop does not have. The DISPATCHING half cost the most:
#      no shipping path may tell an agent to block, poll or idle while a review
#      it dispatched is outstanding — one implementing agent that did deadlocked
#      and lost a completed review cycle — and a dispatch that SUCCEEDED whose
#      report never arrived is a THIRD outcome carrying its own reported
#      wording, the verbatim `review: NO REPORT` line. Folding it into decision
#      1's `review: SKIPPED — no review_agent resolved` line is the tidy that
#      re-creates the very ambiguity that line was added to remove: SKIPPED says
#      NO AGENT RAN, and here one ran. Decision 1 pins that the line survives;
#      this one pins that it is not stretched to cover a different fact. THREE
#      parts, separable, each pinned on its own: the report is RETURNED, no
#      dispatcher BLOCKS on one, and a PR whose review reached nobody is HELD
#      rather than merged. A repo could adopt the first and still ship a
#      dispatcher that waits forever; it could adopt the first two and still
#      merge the PR the third exists to stop — which is the harm itself, so the
#      hold is the part that must never be left to a guardrail list alone.
#      #385 adds a CONTROL return when nested dispatch cannot complete, not a
#      fourth review outcome. #386 allows one report-only resume to the same
#      actual returned agent when a correction, tally or partial text omitted
#      the complete report. Normal and compact clean reports need no recovery;
#      changed input, an expired handle, a spent allowance or an incomplete
#      resumed return remains NO REPORT, never clean or SKIPPED. The request
#      returns the already-completed full report, never re-analysis, fan-out,
#      relay or a file pointer. These boundaries are checked in their owning
#      regions and at every cold/coordinator caller, not by finding protocol
#      tokens somewhere in a file.
#      Known limit: source checks cannot prove agent obedience or catch arbitrary
#      additive contradictions. Runtime scenarios and representative deletion/
#      qualification/relocation mutations remain separate validation duties.
#
#   7. THE REVIEWERS DELIVER THE SAME WAY, AND THE BRIEF HAS A SLOT FOR IT.
#      Decision 6 bound the orchestrator -> dispatcher hop. The hop below it —
#      reviewer -> orchestrator — carries far more traffic, since every
#      diff-scoped review fans out to as many as nine of them, and it was
#      UNBINDABLE rather than merely unbound (#280). Two halves, and each is
#      useless without the other. (a) Each of the nine states that its findings
#      envelope is its RETURNED FINAL TEXT, that the message tool is not a
#      delivery mechanism for it, and that an unresolvable dispatcher changes
#      nothing — the same rule decision 6 gives the orchestrator, worded for a
#      reviewer. #384 changes the container to a JSON object, preserving the
#      return-only delivery channel and every finding field in both modes.
#      (b) The orchestrator's fan-out brief says it 'contains, and contains
#      only' an enumerated set, so an orchestrator following it LITERALLY
#      could not pass the contract down. The list stays CLOSED — closedness is
#      what stops a brief re-authoring a reviewer's checklist, which the
#      paragraph under it forbids in as many words — and the delivery rule
#      joins it as a member instead. 'Open the list' is the tempting fix and
#      the one that quietly costs the other rule.
#      The lost-reviewer REPORTING bullet is NOT retired by any of this and is
#      pinned here as such: it is the backstop that made this gap visible at
#      all, on #273's own PR, where round 4 lost three of four surfaces and two
#      of the three carried Blocking findings. Folding a delivery rule and a
#      reporting rule together is the specific tidy #280 refuses — a rule that
#      makes reviewers come back and a rule that scores the ones that did not
#      answer different questions, and only the second one is honest when the
#      first fails.
#
# Why source-level. There is no renderer and no runtime to test: the artifact IS
# the instruction an agent follows. Same shape as test-visibility-preconditions.sh
# (the credential's two preconditions), test-sentry-verification.sh (verify-by-
# culprit and the `sentry: none` exception), test-sentry-counts.sh,
# test-security-listing.sh, test-doc-reconciliation.sh, and test-label-migrate.sh's
# single-call-site invariant.
#
# WHITESPACE FLATTENING. Every MUST-NOT-EXIST assertion runs against a flattened
# copy of its file, never against raw lines. This repo hard-wraps prose, so a
# forbidden phrase routinely straddles a line break — and for a negative check
# that miss is a FALSE PASS: the wording is present, merely wrapped. Prose
# MUST-EXIST checks run flattened too (a wrap there is a loud failure, not a
# silent one, so flattening is merely kinder); structural must-exist checks —
# table rows, the verbatim SKIPPED line, a bullet's opening — stay line-scoped
# on purpose, because their shape IS the thing under test.
#
# The flatten also strips leading blockquote markers, for the reason
# test-doc-reconciliation.sh does: `take-it`'s step-6 review gate lives inside a
# `>` sub-agent prompt template, so a phrase wrapped across two quoted lines
# joins as `… fix them > and re-review …` and reads as ABSENT. Measured, not
# assumed — decision 5's "Blocking findings → fix them and re-review before you
# commit" is a miss under a marker-preserving flatten and a hit under this one.
# Stripping can only join text that was already adjacent, so it never hides a
# forbidden phrase from a must-not-exist check.
#
# No `| grep -q` pipelines anywhere: `grep -q` closes the pipe on its first match,
# the writer takes SIGPIPE, and `pipefail` promotes 141 — turning a caught
# regression into a reported miss (the #172 shape). Every string match here reads
# a file directly or a herestring. The two pipelines that do exist — `flatten`
# and the Phase 4 section slice — end in `tr`, which drains its input and never
# closes early.
#
# THE TWO SUMMARY COUNTS IN THIS HEADER ARE RE-DERIVED, NEVER TRANSCRIBED
# (issue #276). The decision count and the tracked-file count are restated in
# this header, in scripts/preflight.sh's gate list and in CLAUDE.md, and until
# section 9 existed nothing recomputed either of them — while the recent edits
# to this gate have each moved one. Section 9 derives both from this file and
# fails when any of those sites disagrees, so a new decision reddens CI until
# every restatement is updated instead of leaving stale sentences behind.
#
# THE DISCRIMINATOR IS THE PART TO GET RIGHT, and it is deliberate rather than
# obvious. Counting the numbered section banners does NOT answer "how many
# decisions": the banners run past the decisions into the must-not-exist sweep
# and into section 9 itself, so a bare count answers a different question, and
# answers it high enough to redden against every site on its first run. A
# decision section is one whose banner CARRIES ITS OWN NUMBER BACK as a
# `(decision N)` suffix; the two trailing sections carry none, which is exactly
# what excludes them. The opposite failure is the quiet one: a discriminator
# that silently stops matching re-derives 0 and passes every count vacuously.
# So the count is taken TWICE, from two independent places — the header's
# enumerated list above and the body's banners — and the two must agree and be
# numbered 1..N with no gap. A discriminator gone blind disagrees and reddens.
#
# The file count is the length of the READS array, which is also what the
# existence loop iterates, so a document cannot join the read set without
# moving the number. A tracked path read WITHOUT joining that array is caught
# separately, by a scan of this source that spans every tracked shape the gate
# could read rather than skills/ alone — #273 has since made agents/ a member,
# the very entry #276 anticipated, and a scan narrowed to today's read set
# would not have seen it arrive. That
# scan reads CODE LINES ONLY, so a header comment citing a path it does not
# read stays a cross-reference rather than becoming a count.
#
# The mutation battery for section 9 lives in the PR that added it (issue
# #276), not in-script: the bare banner count, a discriminator matching
# nothing, one more decision, one more document, a document read outside the
# read set, a fourth file restating the summary phrase, a wrapped count, a
# bolded count, and a stale count at each of the sites above. The battery
# mutates the tracked file in place and restores it, which is what the
# running-from-a-copy precondition in section 9 exists to insist on.
#
# No gh, no network, no repo mutation. It reads the documents the decisions
# live in, plus the three files that restate this gate's two summary counts —
# its own source, scripts/preflight.sh and CLAUDE.md — which section 9 checks
# against the numbers it re-derives: twenty tracked files, and separately a sweep
# of every tracked Markdown and shell file asking which of them carry the
# summary phrase. The twenty are the ASSERTED read set; the sweep opens far more
# and asserts nothing about their content beyond that one phrase, so it is named
# apart from the count, the way preflight.sh's own entry for this script names
# its read set and its tracked-source sweep separately rather than adding them
# together. (That
# entry's own wording is deliberately not quoted here: it carries a spelled
# count, and quoting it would put a competing one inside this very window —
# measured, it reddened this gate on the first run.)
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-review-gate-decisions.sh
set -uo pipefail
export LC_ALL=C

# Resolved BEFORE the `cd` below, because the caller's path is relative to the
# caller's cwd: comparing it afterwards false-fails from every directory but the
# repo root, including `cd scripts && bash test-review-gate-decisions.sh` — the
# most natural invocation there is, given every gate script lives there. Same
# idiom, and the same reason, as scripts/test-sentry-verification.sh.
SELF_ABS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-review-gate-decisions: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SKILL="skills/send-it/SKILL.md"
CONTRACT="skills/setup-config/references/config-contract.md"
# The rendered artifact. Decisions 2 and 3 are restated here because this is the
# file that actually lands in a consumer repo's .claude/sassy-dog/send-it.md, so
# a sweep that only reached the template would ship the reverted decision.
TEMPLATE="skills/setup-config/references/templates/send-it.config.md"
# Decisions 4 and 5 (#248/PR #250). `review_site` is live prose in four files;
# the generator owns the seeding half of decision 4, and the two dispatching
# skills own decision 5 — one for each site the key can name.
SETUP="skills/setup-config/SKILL.md"
TAKEIT="skills/take-it/SKILL.md"
DISPATCH="skills/dispatch-ready/SKILL.md"
# Decision 6 (#273). The reviewing agent's own delivery contract lives here, and
# it is the read set's first entry under agents/. Section 9's stray-path scan
# already spanned every tracked shape BEFORE this entry existed — the breadth is
# not a consequence of it, so narrowing back to skills/ would not become safe if
# this entry ever left.
ORCH="agents/pr-review-orchestrator.md"
# README carries a COPY of the contract line, so it is read here too — and a
# copy nothing compares is a copy free to drift, which is what the sweep below
# exists to refuse.
READMEMD="README.md"
# The documents the decisions live in. Section 9 derives the tracked-file count
# from the arrays below, so a further document cannot join the read set without
# moving every restatement of that number with it.
# Decision 7 (#280). The delivery contract one hop DOWN. Nine paths spelled out
# rather than a glob, for two reasons that pull the same way: the file count is
# the read set's own length, so a glob would let the set change size without
# moving any restatement of it; and section 9's stray-path scan matches path
# LITERALS, so a glob read is invisible to it in both directions. The list is
# checked against the tree below rather than trusted — a tenth reviewer shipped
# without joining it would be pinned by nothing and reported by nobody.
REVIEWERS=(
    "agents/architecture-reviewer.md"
    "agents/cicd-release-reviewer.md"
    "agents/code-quality-reviewer.md"
    "agents/dependency-supply-chain-reviewer.md"
    "agents/dx-docs-reviewer.md"
    "agents/infra-platform-reviewer.md"
    "agents/observability-ops-reviewer.md"
    "agents/security-reviewer.md"
    "agents/testing-reviewer.md"
)
DOCS=("$SKILL" "$CONTRACT" "$TEMPLATE" "$SETUP" "$TAKEIT" "$DISPATCH" "$ORCH" "$READMEMD"
      "${REVIEWERS[@]}")
# Read for their restated counts alone, never for a decision's prose: this
# file's own header, preflight's gate list, and CLAUDE.md's gate description.
SELF="scripts/test-review-gate-decisions.sh"
PREFLIGHT="scripts/preflight.sh"
CLAUDEMD="CLAUDE.md"
COUNT_SITES=("$SELF" "$PREFLIGHT" "$CLAUDEMD")
READS=("${DOCS[@]}" "${COUNT_SITES[@]}")

fails=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# assert_in <haystack> <ERE> <label>      — herestring, never a pipeline
assert_in() {
    if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3"; fi
}
# assert_not_in <haystack> <ERE> <label>
assert_not_in() {
    if grep -qE -- "$2" <<<"$1"; then bad "$3"; else ok "$3"; fi
}
# assert_has <haystack> <FIXED string> <label> — fixed-string, for a literal
# carrying regex metacharacters. The NO REPORT line ends in
# `(lint/type/test only)`, whose parentheses are an ERE group: matched as a
# pattern it silently tests something else entirely, so the contract line is
# compared as bytes.
assert_has() {
    if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3"; fi
}
# assert_line <file> <ERE> <label>        — line-scoped; file input, no pipe
assert_line() {
    if grep -qE -- "$2" "$1"; then ok "$3"; else bad "$3"; fi
}

echo "review-gate decisions from #237/PR #243 (issue #247), #248/PR #250 (issue #255), #273 and #280"

for f in "${READS[@]}"; do
    [ -r "$f" ] && continue
    # A reviewer path is the one that gets RENAMED rather than deleted, and it
    # dies here — before the completeness check below, whose message is the one
    # that actually says what to do. Say it here too rather than reordering the
    # loop, since the existence floor has to stay first.
    case "$f" in
        agents/*-reviewer.md)
            bad "missing file: $f — if a reviewer was renamed, move REVIEWERS with it, then the tracked-file count and each of its three restatement sites" ;;
        *)
            bad "missing file: $f" ;;
    esac
done
[ "$fails" -eq 0 ] || { echo "test-review-gate-decisions: FAILED" >&2; exit 1; }

# Blockquote markers are stripped first — see the header note. `[[:space:]]`,
# never `[ \t]`: BSD sed reads the latter as a literal-t class and eats every t.
flatten() { sed -E 's/^[[:space:]]*(> ?)+//' "$1" | tr '\n' ' ' | tr -s ' '; }
skill_flat="$(flatten "$SKILL")"
contract_flat="$(flatten "$CONTRACT")"
template_flat="$(flatten "$TEMPLATE")"
setup_flat="$(flatten "$SETUP")"
takeit_flat="$(flatten "$TAKEIT")"
dispatch_flat="$(flatten "$DISPATCH")"
orch_flat="$(flatten "$ORCH")"

# ---------------------------------------------------------------------------
# Decision 6's negatives are checked by ACCOUNTING and by PAIRED MUST-EXISTS,
# never by a prose veto. That is a deliberate reversal, and the reason is
# measured rather than stylistic.
#
# The first two editions of this gate tried a veto — an enumerated ERE for the
# forbidden instruction shape, then the same thing with a polarity classifier
# in front of it. Both were wrong in BOTH directions at once, which is the
# family `scripts/test-sentry-verification.sh` documents at length in its own
# header:
#
#   * INERT WHERE IT MATTERS. The polarity edition suppressed any mention with
#     a negator to its left in the same clause — and `no` is a negator, while
#     every window it guarded is REQUIRED by the must-exists below to contain
#     the literal `no report returned`. Measured minimal pair through the
#     shipped code: `Print the NO REPORT line, then merge it.` scored ZERO
#     hits; the identical sentence with the literal swapped for `FOO BAR`
#     scored one. The veto could not fire in the only place it was aimed.
#   * UNBOUNDED. With no boundary at `,`, `:` or a coordinating conjunction,
#     one leading negator shielded every later mention in the sentence:
#     `Never fold that into the SKIPPED line: merge it as usual.` scored zero
#     on all four arms.
#   * NARROW. It was an enumeration with no stated limit, so the natural
#     reword walked past it — `Pause until the report arrives`, `SendMessage
#     the report to the session that dispatched you`, `Ask the coordinator to
#     pass it along` all scored zero.
#   * LEFT-ONLY, so correct DESCRIPTIVE prose reddened: these four files
#     describe the incident at length, and `a tick that waits for the review is
#     a loop that stopped` had to have its object deleted to keep the gate
#     green. Prose contorted around a gate is the anti-pattern, not the fix.
#
# A veto that is right needs the forward segmentation pass
# `scripts/test-sentry-verification.sh` describes in its comma-parity
# known-limit block, well below its header (one over the token array, since the
# boundary that would work is a comma a backward token-local scan never
# reaches), and a battery that exercises SUPPRESSION rather than only clean
# strings —
# a dedicated issue, not a helper smuggled into this one. What replaces it is
# what decision 5 already uses successfully two sections up, plus counting:
#
#   * The PROHIBITION IS ASSERTED BY ITS OWN LITERAL, region-scoped. Softening
#     `**hold the PR** — never merge it, and never hand it to pr-shepherd` into
#     `hold it one tick, then merge it as usual` DELETES that literal, so a
#     must-exist catches the softening a veto could not. No polarity is
#     involved, because the asserted string carries its own negation.
#   * TOKENS ARE COUNTED, not pattern-matched. `SendMessage` and `relay` may
#     each appear EXACTLY ONCE in the orchestrator — inside the sentence that
#     forbids them. A readmitting fallback (`If you truly cannot end on it,
#     SendMessage the report to the dispatcher instead`) ADDS an occurrence and
#     is caught by arithmetic, which has no vocabulary to walk past and no
#     polarity to be shielded by. COUNTING ALONE IS NOT ENOUGH, and an earlier
#     draft of this header claimed it was: a fallback that writes the report to
#     a file and returns a pointer names NEITHER counted token, and was measured
#     leaving this gate exit 0. The counts bound the two channels #273 measured;
#     the open class is bounded by the prohibition's own literal beside them.
#
#     KNOWN LIMIT, stated rather than patched, in the idiom the sibling gates
#     use for `am` and for `why`/`whereupon`: an ADDITIVE channel that deletes
#     no literal and names neither counted token is invisible to both halves.
#     Measured — appending `If ending on it is not practical in your harness,
#     ask the coordinator to pass it along instead.` keeps SendMessage:1 and
#     relay:1, deletes nothing, and leaves this gate green. (That reword is one
#     of the shapes the discarded veto walked past, which is why removing the
#     veto did not cost coverage here: nothing ever covered it.) Closing it
#     needs a rule about what the bullet may CONTAIN rather than what it must
#     say — a different change, and a real one. A clean run of this gate is
#     therefore not proof that the delivery contract is unweakened; it is proof
#     that the two measured channels and the stated prohibitions are intact.
#
# Since #280 this limit governs the NINE REVIEWERS too, on the identical
# arithmetic and the identical compensating prohibitions. The bound there is
# the CANONICAL LITERAL `RV_DELIVERY`, not the counts and — read this before
# "simplifying" it — not a cross-file comparison either: an earlier edition
# compared the nine to each other, which bounds DIVERGENCE rather than CONTENT
# and passes any edit applied uniformly to all nine. What that literal bounds
# is the delivery PARAGRAPH, in both directions: measured, deleting its closing
# sentence from one file reddens, and from all nine reddens too.
#
# What remains unbounded one hop down is text OUTSIDE that paragraph, and the
# two tokens answer it differently on purpose — `SendMessage` is counted
# file-wide, so a fallback readmitting it anywhere in a reviewer reddens;
# `relay` is counted over `## Output` PLUS `## Diff-scoped mode` — the two
# sections a dispatched reviewer reads as binding — because it is the one token
# that could legitimately appear as domain vocabulary, and a file-wide bound
# would redden on such a calibration bullet. A weakening clause that names
# neither token and sits outside BOTH of those sections is still not caught,
# exactly as it is not caught one level up.
#
# The known limit is stated rather than patched, in the idiom the sibling gates
# use: this pins the WORDING of each prohibition, so a legitimate reword of one
# reddens the gate and must be made in every copy at once — two places for the
# orchestrator's own rule, and ten for the reviewers' (the nine files plus
# `RV_DELIVERY`). That is the trade
# decision 5 already accepts, it fails LOUDLY, and a loud false red is the
# direction this repo prefers over a veto that reports clean on an inverted
# source — which is exactly what the two previous editions did.

# Region helpers. flatten() strips `>` markers, which is right for reading the
# text but blind to WHERE it sits: measured, lifting the whole delivery rule
# out of take-it's §5 blockquote and into its coordinator section left this
# gate green — and dispatch-ready reuses that prompt VERBATIM, so one such edit
# strips the rule from both dispatching paths' sub-agents at once.
# quoted_prompt <file> <exact heading line> — the `>` lines of ONE section.
# Scoped to a section rather than the whole file: take-it carries a second
# blockquote for the stacked variant, so a file-wide sweep would let an
# assertion labelled "dispatched prompt" be satisfied by the other one.
quoted_prompt() {
    awk -v h="$2" '
        $0 == h { f = 1; next }
        f && /^#+ / { exit }
        f && /^[[:space:]]*>/ { sub(/^[[:space:]]*(> ?)+/, ""); print }' "$1" \
        | tr '\n' ' ' | tr -s ' '
}
# section_slice <file> <exact heading line> [<literal stop line>] — to the next
# heading of any level, or to an earlier explicit stop. The stop exists because
# take-it's coordinator section runs on into its pr-shepherd hand-off block,
# which legitimately talks about merging: a window that swallows it makes any
# merge-related assertion answer a question about the wrong text.
section_slice() {
    awk -v h="$2" -v stop="${3:-}" '
        $0 == h { f = 1; next }
        f && /^#+ / { exit }
        f && stop != "" && index($0, stop) == 1 { exit }
        f { print }' "$1" | tr '\n' ' ' | tr -s ' '
}
# bullet_slice <file> <literal bullet opening> — to the next top-level bullet.
bullet_slice() {
    awk -v b="$2" 'index($0, b) == 1 { f = 1; print; next } f && /^- / { exit } f { print }' "$1" \
        | tr '\n' ' ' | tr -s ' '
}

# ---------------------------------------------------------------------------
# 1. The review gate is unconditional (decision 1)
# ---------------------------------------------------------------------------
echo "-- decision 1: the gate runs on every PR"

assert_in "$skill_flat" \
    'The gate always runs; config only chooses the agent' \
    "send-it states the gate always runs"
assert_in "$skill_flat" \
    'heading is deliberately not' \
    "send-it keeps the 'not if set' note on the section heading"
assert_in "$skill_flat" \
    'Absence is a default, not an off switch' \
    "send-it states absence is a default, not an off switch"
# The resolution table is what a reader consults to answer "does this run?".
assert_line "$SKILL" \
    '^\| key absent \|.*sassy-dog:pr-review-orchestrator' \
    "send-it resolution table maps an absent key to the shipped orchestrator"
# §3's presence-gated rule must keep excluding this gate. Without the exclusion,
# the "run each gate only if its block is present" rule swallows the review gate.
assert_in "$skill_flat" \
    'does .*not.* extend to the review gate' \
    "send-it §3 exempts the review gate from the presence-gated rule"
assert_in "$skill_flat" \
    'runs on every PR' \
    "send-it §3 states the review gate runs on every PR"

# The SKIPPED line and its survival rationale. This is the half of decision 1
# that a "the default made this unreachable" sweep deletes.
assert_line "$SKILL" \
    '^review: SKIPPED — no review_agent resolved \(lint/type/test only\)$' \
    "send-it still prints the verbatim SKIPPED line"
assert_in "$skill_flat" \
    'The default agent does not retire it' \
    "send-it states the default does not retire the SKIPPED line"
assert_in "$skill_flat" \
    'backstop against .*resolution.* failure' \
    "send-it keeps the SKIPPED line as a resolution-failure backstop"
assert_in "$skill_flat" \
    'The line is .*unconditional.*' \
    "send-it keeps the SKIPPED line unconditional"
# Both producers must stay named, or a deliberate opt-out and a plugin that
# failed to load render identically while meaning opposite things.
assert_in "$skill_flat" \
    'name which of the two produced it' \
    "send-it names which of the two produced the SKIPPED line"

assert_in "$contract_flat" \
    'review gate resolves an agent on .*every.* run' \
    "contract states the gate resolves an agent on every run"
assert_line "$CONTRACT" \
    '^\| key absent \| dispatches `sassy-dog:pr-review-orchestrator`' \
    "contract table maps an absent key to the shipped orchestrator"
assert_line "$CONTRACT" \
    '^\| `review_agent: skip` \|.*review: SKIPPED — no review_agent resolved' \
    "contract table keeps the SKIPPED line on the opt-out row"
assert_in "$contract_flat" \
    'No .send-it. run can therefore silently ship unreviewed' \
    "contract states no send-it run silently ships unreviewed"

# ---------------------------------------------------------------------------
# 2. `review_agent` is NOT presence-is-the-toggle (decision 2)
# ---------------------------------------------------------------------------
echo "-- decision 2: review_agent has a default, so presence is not its toggle"

assert_in "$contract_flat" \
    'This key is not governed by presence-is-the-toggle at all: it has a default' \
    "contract states review_agent is not governed by presence-is-the-toggle"
# The scalar bullet itself: `review_agent` must live in the scalars list, which
# is where #243 moved it.
assert_line "$CONTRACT" \
    '^- `review_agent: <agent>\|skip` — which agent' \
    "contract carries review_agent as a scalar key, not a presence-toggled block"
assert_in "$contract_flat" \
    'the difference is the point: one chooses .*whether.* a review happens' \
    "contract keeps the whether-vs-where contrast with review_surfaces"

# The presence-is-the-toggle key list, isolated. Scoped rather than file-wide so
# that a mention of `review_agent` anywhere else cannot satisfy or break it.
toggle_list="$(grep -oE 'The same holds for [^.]*\.' <<<"$contract_flat")"
if [ -z "$toggle_list" ]; then
    bad "cannot locate the presence-is-the-toggle key list ('The same holds for …')"
else
    ok "located the presence-is-the-toggle key list"
    assert_not_in "$toggle_list" 'review_agent' \
        "presence-is-the-toggle key list does NOT list review_agent"
    assert_in "$toggle_list" 'review_surfaces' \
        "presence-is-the-toggle key list DOES list review_surfaces"
    # #250's key lands in the same trap: it has a default too, so listing it
    # here would turn its absence into an off switch for the dispatching paths.
    assert_not_in "$toggle_list" 'review_site' \
        "presence-is-the-toggle key list does NOT list review_site"
fi

# The same decision, stated one more time where a reader looks for it: the
# worked example's closing "omit what you don't use" line must carry the
# exception, or the example itself teaches that omitting turns the gate off.
omit_rule="$(grep -oE "Omit any block the repo doesn't use[^.]*\." <<<"$contract_flat")"
if [ -z "$omit_rule" ]; then
    bad "cannot locate the 'Omit any block the repo doesn't use' rule"
else
    ok "located the omit-any-block rule"
    assert_in "$omit_rule" 'review_agent' \
        "omit-any-block rule names review_agent as an exception"
    assert_in "$omit_rule" 'selects a default' \
        "omit-any-block rule states omitting selects a default"
    # #250 made it TWO exceptions. Dropping the second one back out teaches the
    # example that omitting `review_site:` disables something, which it does not.
    assert_in "$omit_rule" 'review_site' \
        "omit-any-block rule names review_site as an exception too"
fi

# send-it's own frontmatter inventory. #243 pulled `review_agent` out of the
# "optional blocks" list and gave it its own sentence for exactly this reason.
supplies="$(grep -oE 'Frontmatter supplies [^.]*\.' <<<"$skill_flat")"
if [ -z "$supplies" ]; then
    bad "cannot locate send-it's 'Frontmatter supplies …' inventory"
else
    ok "located send-it's frontmatter inventory"
    assert_not_in "$supplies" 'review_agent' \
        "send-it does NOT list review_agent among the optional blocks"
fi
assert_in "$skill_flat" \
    'its absence is .*not.* an off switch' \
    "send-it states an absent review_agent is not an off switch"

# The rendered template teaches the same thing to every consumer repo.
assert_in "$template_flat" \
    'review_agent is the one key presence does NOT toggle' \
    "send-it config template states review_agent is not presence-toggled"

# ---------------------------------------------------------------------------
# 3. The opt-out is `review_agent: skip`, not `none` (decision 3)
# ---------------------------------------------------------------------------
echo "-- decision 3: the opt-out is spelled skip, not none"

assert_in "$contract_flat" \
    'The opt-out is spelled .*skip.*, not .*none' \
    "contract states the opt-out is spelled skip, not none"
# The justification, not just the verdict. Without it the rule reads as an
# arbitrary spelling choice and the missing symmetry with `sentry: none` looks
# like an oversight worth closing.
assert_in "$contract_flat" \
    'none. belongs to the presence-is-the-toggle exception above' \
    "contract explains why none belongs to the presence-toggle exception"
assert_in "$contract_flat" \
    'records a confirmed absence somebody went and checked for' \
    "contract keeps the confirmed-absence justification for none"
assert_in "$contract_flat" \
    'not a presence-toggle key at all, so its opt-out overrides a default' \
    "contract states review_agent's opt-out overrides a default"
# The referent. Decision 3 cites this section; if it disappears the citation
# dangles and the rule loses its reason. (Its own contents are pinned by
# scripts/test-sentry-verification.sh — this is a link check, not a second copy.)
assert_line "$CONTRACT" \
    '^### The one exception: `sentry: none`$' \
    "the sentry: none exception section decision 3 cites still exists"

assert_line "$SKILL" \
    '^\| `review_agent: skip` \| none — the explicit opt-out' \
    "send-it resolution table spells the opt-out skip"
assert_in "$template_flat" \
    '`review_agent: skip` is the explicit opt-out' \
    "send-it config template spells the opt-out skip"

# ---------------------------------------------------------------------------
# 4. `review_site` is CONFIGURED, not derived (decision 4, #248/PR #250)
# ---------------------------------------------------------------------------
echo "-- decision 4: review_site is seeded once from visibility, then frozen"

# The ABSENT default is `coordinator`, and it is pinned in all three places
# that state it. It was `agent`, called the fail-safe site. It was flipped for
# cost: under `agent` every worker ran the full reviewer fan-out itself, once
# per fix round, and review agents outnumbered workers roughly 11:1 in a
# measured 14-day window, nearly all on Opus. Every PR is still reviewed before
# it merges; the site only moves the review after the PR opens. The seed rule
# is untouched and still writes PUBLIC -> `agent` explicitly, so only a
# config that predates the key, or a hand-written one, reaches this default.
# Unpinned, a later "restore the fail-safe default" sweep would silently put
# every such repo's workers back on self-review.
assert_line "$CONTRACT" \
    '^\| key absent \| `coordinator`, for cost\.' \
    "contract table maps an absent review_site to coordinator"
assert_has "$takeit_flat" \
    '**Absent selects `coordinator`.**' \
    "take-it states the absent review_site default is coordinator"
assert_has "$dispatch_flat" \
    '**Absent selects `coordinator`.**' \
    "dispatch-ready states the absent review_site default is coordinator"
# The other three copies of the default, pinned too. A "restore the fail-safe
# default" sweep that edited only these would otherwise pass while the tree
# states two contradictory defaults.
readme_flat="$(flatten "$READMEMD")"
assert_has "$contract_flat" \
    'switch (absent selects `coordinator`)' \
    "contract's scalar-key bullet states the coordinator default"
assert_has "$setup_flat" \
    'until then the reading skills default it to `coordinator`.' \
    "setup-config's Phase 4 states the coordinator default"
assert_has "$readme_flat" \
    'An absent key selects `coordinator`.' \
    "README states the coordinator default"
assert_not_in "$takeit_flat $dispatch_flat $contract_flat $setup_flat $readme_flat" \
    'Absent selects `agent`|absent selects `agent`|absent key selects `agent`|default it to `agent`|key absent \| `agent`' \
    "no copy of the absent default still states agent"

assert_line "$CONTRACT" \
    '^#### Why this key is CONFIGURED and not DERIVED$' \
    "contract keeps the CONFIGURED-and-not-DERIVED section"
assert_in "$contract_flat" \
    'deliberate exception to \*configure only what cannot be derived\*' \
    "contract names review_site an exception to the governing principle"
# The concession is the load-bearing half. A reader who learns only that the key
# is configured, and separately that visibility is derivable, closes the gap.
assert_in "$contract_flat" \
    'Visibility \*\*is\*\* derivable — `gh repo view --json visibility`' \
    "contract concedes visibility is derivable via gh repo view"
assert_in "$contract_flat" \
    'Deriving it live means a visibility change silently rewrites the repo.s review architecture' \
    "contract states deriving it live silently rewrites the review architecture"
assert_in "$contract_flat" \
    'downgrade it from pre-PR review to after-the-fact review with nothing announcing the change' \
    "contract names the silent pre-PR to after-the-fact downgrade"
assert_in "$contract_flat" \
    'issues/187' \
    "contract cites #187 as the failure class this exception avoids"
assert_in "$contract_flat" \
    'reads visibility \*\*once\*\*, at setup, and writes the resolved value explicitly' \
    "contract states setup-config reads visibility once and records the value"
assert_in "$contract_flat" \
    'seeded from a derived fact and then frozen' \
    "contract's scalar-key bullet marks review_site seeded-then-frozen"
assert_line "$CONTRACT" \
    '^- `review_site: agent[|]coordinator` — \*\*where\*\*' \
    "contract carries review_site as a scalar key"
# Both seed rows, in both files that carry the table. A one-row table is a rule
# with no alternative, and PUBLIC -> agent is the counter-intuitive row.
for pair in "contract:$CONTRACT" "setup-config:$SETUP"; do
    assert_line "${pair#*:}" '^\| `PUBLIC` \| `agent` \|$' \
        "${pair%%:*} seed table maps PUBLIC to agent"
    assert_line "${pair#*:}" '^\| `INTERNAL` / `PRIVATE` \| `coordinator` \|$' \
        "${pair%%:*} seed table maps INTERNAL/PRIVATE to coordinator"
done

assert_line "$SETUP" \
    '^### Seed `review_site` — once, from visibility, then never again$' \
    "setup-config keeps the seed-once-then-never-again heading"
assert_in "$setup_flat" \
    'read exactly once: it seeds `review_site:`' \
    "setup-config Phase 0 reads visibility exactly once"
assert_in "$setup_flat" \
    'never re-read it on a refresh' \
    "setup-config Phase 0 forbids re-reading visibility on a refresh"
assert_in "$setup_flat" \
    'Write the resolved value, never the rule that produced it' \
    "setup-config writes the resolved value, never the rule"
assert_in "$setup_flat" \
    'A derived `review_site` means a later visibility change silently rewrites' \
    "setup-config states a derived review_site rewrites the architecture silently"
assert_in "$setup_flat" \
    'the failure class issue #187 documents' \
    "setup-config cites #187 as the failure class"

# The Phase 4 carve-out — the half of decision 4 that survives a REFRESH, and
# the half that lives in a different file from the contract entry. Scoped to the
# phase: update mode's "re-verify every fact against live state" rule and its one
# exception must sit in the same section, or the rule reads absolute where it
# runs. (awk into tr: tr drains its input, so no SIGPIPE under pipefail.)
phase4="$(awk '/^## Phase 4 /{f=1} /^## Phase 5 /{f=0} f' "$SETUP" | tr '\n' ' ' | tr -s ' ')"
if [ -z "$phase4" ]; then
    bad "cannot locate setup-config Phase 4 (update mode)"
else
    ok "located setup-config Phase 4 (update mode)"
    assert_in "$phase4" 're-verify every fact against live state' \
        "Phase 4 still states update mode's re-verify-every-fact rule"
    # "the one fact" was dropped, deliberately: issue #261 added THREE more
    # non-re-derived frontmatter values (`testflight: none`, `posthog: none`,
    # `mobile: none`), and the same file's guardrail list already named them
    # beside `review_site`, so the uniqueness claim was false nine lines from
    # where it was made. The DECISION this pins is that Phase 4 exempts
    # `review_site` — not that it is the only exemption.
    #
    # Three, not four: `sentry: none` is NOT in that carve-out and is re-derived
    # on every refresh, because it is also written when the culprit check merely
    # could not run (issue #268; `scripts/test-sentry-verification.sh` decision
    # D owns that split and asserts it at all four sites). #267 briefly wrote
    # `sentry:` into the guardrail list while removing it everywhere else, and
    # this comment repeated the wrong count.
    assert_in "$phase4" '`review_site:` is a fact this phase must NOT re-derive' \
        "Phase 4 exempts review_site from the re-verify rule"
    assert_in "$phase4" 'stop and surface both sides' \
        "Phase 4 surfaces a visibility mismatch rather than rewriting the value"
fi

# The same carve-out in the guardrail list, where the rule is stated absolutely.
never_copy="$(grep -oE 'Never copy a fact forward without re-verifying it against live state[^.]*\.' <<<"$setup_flat")"
if [ -z "$never_copy" ]; then
    bad "cannot locate setup-config's never-copy-a-fact-forward guardrail"
else
    ok "located the never-copy-a-fact-forward guardrail"
    assert_in "$never_copy" 'review_site' \
        "the never-copy guardrail names review_site as its exception"
    assert_in "$never_copy" 'seeded once and carried forward by design' \
        "the never-copy guardrail states review_site is seeded once by design"
fi

# ---------------------------------------------------------------------------
# 5. A Blocking finding blocks the merge, with ONE redispatch (decision 5)
# ---------------------------------------------------------------------------
echo "-- decision 5: never merge past a Blocking finding; one redispatch, then blocked"

assert_in "$contract_flat" \
    'A Blocking finding is never merged past' \
    "contract states a Blocking finding is never merged past"
assert_in "$contract_flat" \
    'one redispatch carrying the finding as context' \
    "contract states one redispatch carrying the finding"
assert_in "$contract_flat" \
    'never parks it back in Ready' \
    "contract states the finding is never parked back in Ready"
# The contract points at the owner instead of restating the path — the same
# write-it-once posture it takes for `review_agent`'s resolution order.
assert_in "$contract_flat" \
    'That path lives in `dispatch-ready` §2' \
    "contract defers the path itself to dispatch-ready §2"

assert_in "$dispatch_flat" \
    '\*\*never merge past one\.\*\*' \
    "dispatch-ready never merges past a Blocking finding"
assert_in "$dispatch_flat" \
    'allow ONE redispatch carrying that finding as context on a later tick' \
    "dispatch-ready allows exactly one redispatch carrying the finding"
# The rationale for the number. Without it "one" is an arbitrary retry count,
# and an arbitrary number is the kind a later edit rounds up.
assert_in "$dispatch_flat" \
    'the same single-redispatch budget a failed check gets' \
    "dispatch-ready justifies the number as parity with a failed check"
assert_in "$dispatch_flat" \
    'A second failure demotes to `blocked` the same way' \
    "dispatch-ready demotes to blocked on a second failure"
assert_in "$dispatch_flat" \
    '\*\*Never park it back in Ready\*\*' \
    "dispatch-ready never parks a Blocking finding back in Ready"
assert_in "$dispatch_flat" \
    'max one redispatch per issue without a human' \
    "dispatch-ready guardrails cap redispatches at one without a human"
assert_in "$dispatch_flat" \
    'never park one back in Ready — one redispatch carrying the finding, then `blocked`' \
    "dispatch-ready guardrails repeat the one-redispatch-then-blocked rule"
# The reported shape. A budget nobody prints is a budget nobody can audit.
assert_line "$DISPATCH" \
    '^review: #[0-9]+ BLOCKING .*redispatch 1 of 1$' \
    "dispatch-ready tick report shows the 1-of-1 redispatch budget"
assert_in "$dispatch_flat" \
    'never drop a Blocking finding or a `review: SKIPPED` from it' \
    "dispatch-ready never drops a Blocking finding from the tick report"
# The `agent`-site case that looks dead and is not: a sub-agent that could not
# resolve a reviewer produces a PR the coordinator must still stop.
assert_in "$dispatch_flat" \
    'it still fires when a sub-agent could not resolve a reviewer at all' \
    "dispatch-ready keeps the Blocking path live on the agent site"

assert_line "$TAKEIT" \
    '^### Review gate on the coordinator site \(ONLY when `review_site: coordinator`\)$' \
    "take-it keeps its coordinator-site review section"
assert_in "$takeit_flat" \
    'hold the PR; \*\*never merge past it\*\*' \
    "take-it holds the PR and never merges past a Blocking finding"
assert_in "$takeit_flat" \
    'allow ONE redispatch carrying it as context' \
    "take-it allows exactly one redispatch carrying the finding"
assert_in "$takeit_flat" \
    'A second failure gets the `blocked` label' \
    "take-it labels blocked on a second failure"
assert_in "$takeit_flat" \
    'Never merge past a Blocking review finding\*\*, on either `review_site`' \
    "take-it guardrails apply the rule on either review_site"
# Inside the `>` sub-agent prompt, and wrapped — only visible to a flatten that
# strips blockquote markers. This is the assertion that proves the flatten.
assert_in "$takeit_flat" \
    '\*\*Blocking findings → fix them and re-review before you commit\*\*' \
    "take-it's dispatched prompt fixes Blocking findings before committing"

# ---------------------------------------------------------------------------
# 6. The report is RETURNED; a lost one is its own outcome (decision 6, #273)
# ---------------------------------------------------------------------------
echo "-- decision 6: the report is a return value; a lost one is not a skip"

NOREPORT='review: NO REPORT — <agent> dispatched, no report returned (lint/type/test only)'

# --- PART ONE: the reviewing agent's delivery contract ----------------------
# `return` was already the verb on the bullet below this one, and it was
# already correct for an Agent; what was missing is that it is the ONLY verb,
# so the contract could be satisfied by a mechanism whose addressing the
# reviewer cannot resolve.
assert_in "$orch_flat" \
    'Your report is your RETURN VALUE' \
    "orchestrator states the report is its return value"
assert_in "$orch_flat" \
    'SendMessage. is not a delivery mechanism' \
    "orchestrator states the message tool is not how a report is delivered"
# The case-3 shape: an address the reviewer cannot resolve must not become a
# reason to stop, to ask for a relay, or to park the report somewhere else.
assert_in "$orch_flat" \
    'an unresolvable dispatcher changes nothing' \
    "orchestrator returns the report even with no resolvable dispatcher"
# Paired with its IMPERATIVE. The antecedent alone is satisfied by a clause
# whose consequent tells the agent to ask how to proceed — case 3 is the half
# of #273 that actually failed in production, and it is the half a "be
# pragmatic when you cannot reach your dispatcher" edit rewrites.
assert_in "$orch_flat" \
    'return the report in full anyway, as your final text' \
    "orchestrator is told to return the report in full when it cannot resolve a dispatcher"
assert_in "$orch_flat" \
    'the return \*\*is\*\* the delivery' \
    "orchestrator states the return is the delivery"
# Strengthened, never replaced: the pre-#273 verb has to survive, or the fix
# reads as a swap of one delivery mechanism for another.
assert_line "$ORCH" \
    '^- Return \*\*exactly one\*\* report:' \
    "orchestrator still returns exactly one report"

# --- PART TWO: no dispatcher blocks, in all three shipping paths ------------
# A rule living only in send-it never runs for take-it or dispatch-ready, which
# carry most of this repo's PR volume and dispatch from a cold worktree that
# never sees an interactive session's instructions (#220 and #248 closed gaps
# of exactly this shape).
assert_in "$skill_flat" \
    'The gate has THREE outcomes, not two' \
    "send-it states the gate has three outcomes"
assert_in "$skill_flat" \
    'Read the report yourself; never wait to be told' \
    "send-it has the dispatcher read the report itself"
assert_line "$SKILL" \
    "^review: NO REPORT — <agent> dispatched, no report returned \(lint/type/test only\)\$" \
    "send-it prints the verbatim NO REPORT line"
assert_in "$skill_flat" \
    'It is not the SKIPPED line and must never be folded into it' \
    "send-it keeps the third outcome out of the SKIPPED line"

# send-it's OUTCOME TABLE is what an agent reads when rendering, so it is
# accounted for rather than spot-checked: pinning the row on its first cell
# alone let the third cell be rewritten to the SKIPPED line, leaving the table
# ordering the exact fold the prose two paragraphs below forbids — and every
# other send-it assertion green.
outcome_rows="$(awk '/^\| Outcome \|/ { f = 1; next } f && !/^\|/ { exit } f && !/^\| *-+ *\|/ { print }' "$SKILL")"
n_rows="$(grep -c . <<<"$outcome_rows")"
if [ "$n_rows" -eq 3 ]; then
    ok "send-it's outcome table carries exactly 3 rows, matching its THREE-outcomes prose"
else
    bad "send-it's outcome table carries $n_rows rows but the prose states three outcomes"
fi
nr_row="$(grep -F 'dispatched, no report returned |' <<<"$outcome_rows")"
if [ -z "$nr_row" ]; then
    bad "send-it's outcome table has no dispatched-but-no-report row"
else
    ok "located send-it's dispatched-but-no-report row"
    # The row's RENDERED value — the cell that says what the agent prints.
    assert_in "$nr_row" 'NO REPORT line' \
        "send-it's no-report row renders the NO REPORT line"
    assert_not_in "$nr_row" 'SKIPPED' \
        "send-it's no-report row does not route to the SKIPPED line"
fi
# One row per destination, so a table that grew a second SKIPPED row — the fold
# wearing an extra line — is caught by counting rather than by lookup.
n_nr="$(grep -cF 'NO REPORT line' <<<"$outcome_rows")"
n_sk="$(grep -cF 'SKIPPED line' <<<"$outcome_rows")"
if [ "$n_nr" -eq 1 ] && [ "$n_sk" -eq 1 ]; then
    ok "send-it's outcome table routes exactly one row to each of the two lines"
else
    bad "send-it's outcome table routes $n_nr rows to NO REPORT and $n_sk to SKIPPED — expected one each"
fi

# take-it carries the rule in BOTH sites `review_site:` can select, and the
# prompt half must be pinned INSIDE the blockquote it is handed in.
takeit_prompt="$(quoted_prompt "$TAKEIT" "## 5. Dispatch sub-agents in parallel")"
if [ -z "$takeit_prompt" ]; then
    bad "take-it's blockquote prompt region is empty — every prompt assertion below would pass vacuously"
else
    ok "located take-it's blockquote prompt region"
    assert_in "$takeit_prompt" \
        'Read the review.s final text yourself, and never block on it' \
        "take-it's DISPATCHED PROMPT reads the final text and never blocks on it"
    assert_has "$takeit_prompt" "$NOREPORT" \
        "take-it's DISPATCHED PROMPT carries the verbatim NO REPORT line"
    # The DESTINATION, not merely the presence. dispatch-ready reads the PR body
    # and states flatly that it reads no RESULT lines, so a line written only to
    # the RESULT line reaches that loop nowhere — measured green before this
    # assertion existed, which is a contract satisfied on paper and broken in
    # the one consumer that has to read it.
    assert_in "$takeit_prompt" \
        'in the PR body and `review=no-report` on your RESULT line' \
        "take-it's PROMPT writes the NO REPORT line to the PR BODY, not only the RESULT line"
    assert_in "$takeit_prompt" \
        'review=no-report' \
        "take-it's DISPATCHED PROMPT reports no-report on its RESULT line"
fi

takeit_coord="$(section_slice "$TAKEIT" '### Review gate on the coordinator site (ONLY when `review_site: coordinator`)' 'Use the capability skill for ALL polling')"
if [ -z "$takeit_coord" ]; then
    bad "take-it's coordinator-site section did not slice — its assertions below would pass vacuously"
else
    ok "located take-it's coordinator-site section"
    assert_in "$takeit_coord" \
        '\*\*Dispatched, but no report came back\*\*' \
        "take-it's COORDINATOR SITE has its own dispatched-but-no-report outcome"
    assert_has "$takeit_coord" "$NOREPORT" \
        "take-it's COORDINATOR SITE prints the verbatim NO REPORT line"
    # The HOLD is the part that prevents the harm, and it was pinned by nothing
    # in the first edition: rewriting it to `merge it as usual` left every
    # decision-6 assertion and all three vetoes green.
    assert_in "$takeit_coord" '\*\*hold the PR\*\*' \
        "take-it's COORDINATOR SITE holds the PR on a lost report"
    # The PROHIBITION's own literal, not a veto. Softening the hold to `hold it
    # one tick, then merge it as usual` deletes this string, which a must-exist
    # sees and a polarity veto provably could not — the `no report returned`
    # literal these windows must contain carries a negator that suppressed it.
    assert_in "$takeit_coord" 'never merge it, and never hand it to' \
        "take-it's COORDINATOR SITE forbids merging and handing on a lost report"
    # Decision 3's producer count must stay at two here, or the third outcome
    # has been absorbed into the SKIPPED line. Paired with the veto below.
    assert_in "$takeit_coord" 'name which of the two it' \
        "take-it's COORDINATOR SITE still names TWO producers of the SKIPPED line"
    # The opt-out carve-out (#409): without it the bullet above holds every PR
    # under `review_agent: skip` on this site. Pinned with its CONSEQUENCE
    # (not held, goes to the shepherd) and the failure hold beside it.
    assert_in "$takeit_coord" \
        '\*\*`review_agent: skip`, the explicit opt-out\*\* → no review is owed' \
        "take-it's COORDINATOR SITE carves out review_agent: skip"
    assert_in "$takeit_coord" \
        'not held on review grounds\*\* and goes to `sassy-dog:pr-shepherd`' \
        "take-it's COORDINATOR SITE states the opt-out PR is not held"
    assert_in "$takeit_coord" \
        '\*\*No agent resolved, or the dispatch failed\*\* \(anything other than that explicit opt-out\)' \
        "take-it's COORDINATOR SITE still holds a genuine resolution failure"
fi

# The `agent` site, where the coordinator section never runs at all,
# so a hold stated only inside it leaves the agent site merging PRs whose review
# reached nobody. That rule has to live outside the coordinator-only section.
# Asserted against the COMPLEMENT of the coordinator-only subsection, never the
# whole file: the first edition stated this rule "outside the coordinator-only
# section" while sitting INSIDE it, and a whole-file assertion under a label
# naming the placement could not tell the difference. The complement is what
# an agent reads under `review_site: agent`, where that subsection is
# explicitly skipped.
takeit_outside="$(awk '
    /^### Review gate on the coordinator site/ { skip = 1; next }
    skip && /^#+ / { skip = 0 }
    !skip { print }' "$TAKEIT" | sed -E 's/^[[:space:]]*(> ?)+//' | tr '\n' ' ' | tr -s ' ')"
if [ -z "$takeit_outside" ]; then
    bad "take-it's non-coordinator region did not slice — the placement checks would pass vacuously"
else
    ok "located take-it's region OUTSIDE the coordinator-only subsection"
    # BOTH outcomes, because neither PR's diff was read by anybody and the
    # sibling rule in dispatch-ready §2 withholds the same two. A path holding
    # only one of them reaches the opposite conclusion about the very same
    # sub-agent's output — and dispatch-ready dispatches take-it's prompt
    # verbatim, so that is one sub-agent, judged two ways.
    # The SCOPE CLAUSE is part of the rule, not preamble. Measured: rewriting
    # `on EITHER site` to `when review_site: coordinator` leaves the paragraph
    # physically outside the coordinator subsection — so a placement-only check
    # still passes — while scoping the rule away from the agent site, which
    # is the entire reason the placement check exists. Decision 5's assertion
    # already carries its scope clause for the same reason.
    assert_in "$takeit_outside" \
        'on EITHER site: a sub-agent whose RESULT line reported' \
        "take-it's agent-site hold keeps its EITHER-site scope clause"
    assert_in "$takeit_outside" \
        '`review=no-report` OR `review=skipped` is held, never merged' \
        "take-it holds BOTH unreviewed outcomes OUTSIDE the coordinator-only subsection"
    assert_in "$dispatch_flat" \
        'reported `NO REPORT` or `SKIPPED`, or carries a Blocking finding, is withheld' \
        "dispatch-ready withholds the same two outcomes, so the paths agree"
    assert_in "$takeit_outside" \
        'keep the PR out of the list you hand to `sassy-dog:pr-shepherd`' \
        "take-it keeps a no-report PR out of the shepherd hand-off, outside that subsection"
fi
# Every NO REPORT site accounted for, never looked up: take-it carries the line
# twice — prompt and coordinator — so a presence check is satisfied by either,
# and reverting just ONE was measured undetected. Same defect the RESULT enum
# had, one layer over.
n_takeit_nr="$(grep -cF "$NOREPORT" "$TAKEIT")"
if [ "$n_takeit_nr" -ge 2 ]; then
    ok "take-it carries the verbatim NO REPORT line at all $n_takeit_nr of its sites"
else
    bad "take-it carries the NO REPORT line at only $n_takeit_nr site(s) — the prompt and the coordinator each need one"
fi
# The reported enum, accounted for the same way: take-it has TWO RESULT lines,
# the single-issue one and the stacked variant, and a lookup passes on either.
takeit_enums="$(grep -oE 'review=<[a-z|-]+>' "$TAKEIT" | sort)"
n_takeit_enums="$(grep -c . <<<"$takeit_enums")"
if [ "$n_takeit_enums" -ge 2 ]; then
    stale_enums="$(grep -vF 'no-report' <<<"$takeit_enums" | tr '\n' ' ')"
    if [ -n "$stale_enums" ]; then
        bad "a take-it RESULT enum omits the no-report value: $stale_enums"
    else
        ok "all $n_takeit_enums take-it RESULT review enums carry the no-report value"
    fi
else
    bad "take-it exposes only $n_takeit_enums RESULT review enum(s) — expected the single-issue one and the stacked variant"
fi

# `review=deferred` — the coordinator site's worker outcome — is the same
# two-copy shape as `no-report`, and pinned the same way. Before it existed the
# coordinator-site prompt merely OMITTED the review step: nothing forbade a
# worker from running its own reviewer fan-out, and the honest RESULT fit was
# `skipped`, which the EITHER-site hold above holds. Each pin names what
# unpinning would let a later edit revert green: the enum dropping `deferred`,
# the forbidding step decaying back into a bare omission, and the per-site split
# flipping so that `deferred` releases a PR on the agent site, where nothing
# will ever review it.
if [ "$n_takeit_enums" -ge 2 ]; then
    no_deferred="$(grep -vF 'deferred' <<<"$takeit_enums" | tr '\n' ' ')"
    if [ -n "$no_deferred" ]; then
        bad "a take-it RESULT enum omits the deferred value: $no_deferred"
    else
        ok "all $n_takeit_enums take-it RESULT review enums carry the deferred value"
    fi
fi
assert_has "$takeit_flat" \
    '**Do not review.** Dispatch no review agent, reviewer or code-review skill' \
    "take-it's coordinator-site step 6 FORBIDS reviewing rather than omitting the step"
assert_has "$takeit_flat" \
    'on `agent` it deletes this block. A worker must never receive both.' \
    "take-it's worker never receives both step 6 variants"
assert_has "$takeit_outside" \
    '**`review=deferred` is legitimate on exactly one site.**' \
    "take-it's deferred rule sits OUTSIDE the coordinator-only subsection, so it governs the agent site"
assert_has "$takeit_outside" \
    'a `deferred` means a worker skipped the review it was told to run. It is held exactly like `skipped`' \
    "take-it holds deferred on the agent site exactly like skipped"

# dispatch-ready: the unattended loop, where no human coordinator is reading
# along to relay anything — the case that turns a lost report into a merged
# unreviewed PR, and a waiting agent into a stopped loop.
disp_nr="$(bullet_slice "$DISPATCH" '- **A review dispatched that never came back')"
if [ -z "$disp_nr" ]; then
    bad "dispatch-ready's lost-report bullet did not slice — its assertions below would pass vacuously"
else
    ok "located dispatch-ready's lost-report bullet"
    assert_in "$disp_nr" 'A tick never blocks, polls or idles' \
        "dispatch-ready never blocks a tick on a review report"
    assert_in "$disp_nr" 'a tick that waits is a loop that stopped' \
        "dispatch-ready states why a waiting tick is the worse failure"
    assert_has "$disp_nr" "$NOREPORT" \
        "dispatch-ready reports the verbatim NO REPORT line"
    assert_in "$disp_nr" '\*\*hold the PR\*\*' \
        "dispatch-ready holds the PR on a lost report"
    assert_in "$disp_nr" 'never merge it, and never hand it to' \
        "dispatch-ready forbids merging and handing on a lost report"
    assert_in "$disp_nr" '\*\*Never fold that into the SKIPPED line\*\*' \
        "dispatch-ready keeps the third outcome out of the SKIPPED line"
fi
# ORDERING. §2's first bullet is the one that merges, and it is reached ~18
# lines before the lost-report bullet and ~33 before the agent-site hold. A
# corrective a reader meets only after the merge has been ordered is one that
# never runs, so the exception has to live in the merging bullet itself.
disp_merge="$(bullet_slice "$DISPATCH" '- **Open PRs from those branches**')"
if [ -z "$disp_merge" ]; then
    bad "dispatch-ready's merging bullet did not slice — the ordering check would pass vacuously"
else
    ok "located dispatch-ready's merging bullet"
    assert_in "$disp_merge" \
        'Hand it only the PRs the review bullets below have cleared' \
        "dispatch-ready's MERGING bullet withholds PRs the review has not cleared"
    assert_in "$disp_merge" \
        'is withheld from this hand-off, on either `review_site`' \
        "dispatch-ready's withhold keeps its either-site scope clause"
fi

# The COMPLEMENT of dispatch-ready's coordinator-scoped bullets, mirroring
# `takeit_outside` above and for the identical reason. Measured: both default-
# site rules were asserted against the WHOLE flattened file, so relocating them
# verbatim into a `when review_site: coordinator` bullet — the natural
# "consolidate the NO REPORT handling" tidy — kept both literals present and
# left this gate at exit 0 with zero FAILs; combined with narrowing the merging
# bullet, dispatch-ready lost EVERY agent-site hold and `preflight.sh` still
# exited 0. That is decision 6's third part deleted from the unattended loop on
# the agent site, with CI green — the identical defect this file
# already records catching in take-it's first edition. A whole-file assertion
# cannot tell prose that governs the agent site from prose that excludes it.
#
# The bullets to exclude are found by their own `when review_site: coordinator`
# marker rather than by a transcribed list, so a new coordinator-scoped bullet
# joins the exclusion automatically and a bullet that LOSES its marker is not
# silently excluded.
dispatch_outside="$(awk '
    /^- / { skip = (index($0, "when `review_site: coordinator`") > 0) }
    !skip { print }' "$DISPATCH" | sed -E 's/^[[:space:]]*(> ?)+//' | tr '\n' ' ' | tr -s ' ')"
n_coord_bullets="$(grep -cE '^- .*when `review_site: coordinator`' "$DISPATCH")"
if [ "$n_coord_bullets" -ge 2 ]; then
    ok "dispatch-ready marks $n_coord_bullets bullets coordinator-only, so the complement is real"
else
    bad "dispatch-ready marks only $n_coord_bullets bullets coordinator-only — the complement below is the whole file and measures nothing"
fi
# deferred's dispatch-ready half — placed after `dispatch_outside` exists,
# because under `set -u` an unbound slice aborts this whole gate rather than
# failing one assertion.
assert_has "$dispatch_outside" \
    '**A PR body reading `review: deferred to coordinator` is withheld too, until a review outcome replaces it.**' \
    "dispatch-ready withholds a deferred PR outside its coordinator-only bullets, so the paths agree"
assert_has "$dispatch_flat" \
    "with take-it's **coordinator-site step 6**, which forbids the worker any review" \
    "dispatch-ready's prompt carries the forbidding step, not a bare omission"
if [ -z "$dispatch_outside" ]; then
    bad "dispatch-ready's non-coordinator region did not slice — the agent-site checks would pass vacuously"
else
    ok "located dispatch-ready's region OUTSIDE its coordinator-only bullets"
fi

# The `agent` site again: there this loop never dispatches a review of its
# own, so the only way an outcome reaches it is a sub-agent's RESULT line.
assert_in "$dispatch_outside" \
    'equally when its PR body carries the `NO REPORT` line' \
    "dispatch-ready holds a no-report PR on the agent site too"
# The TRIGGER above is not the rule; the CONSEQUENCE is. Measured: rewriting the
# clause that follows it to `the agent ran, which is what the gate asks, so the
# PR is merged as usual once its checks are green` left this gate exit 0 and
# ALL GREEN — the unattended loop, on the agent site, ordered to merge a PR
# whose review reached nobody, which is the entire harm of #273 surviving in
# the path carrying the most PR volume. Both sibling sites were already pinned
# on their consequence; this one was pinned on its trigger alone.
assert_in "$dispatch_outside" \
    'held and never merged on it' \
    "dispatch-ready's agent-site rule states the CONSEQUENCE, not only its trigger"
# EVERY copy of the contract line, tree-wide, must be byte-identical. README
# and the config contract carry it too and neither is in the read set for it, so
# a drift in one of those copies is invisible to a per-file lookup — the same
# reason section 9 SWEEPS for its summary phrase rather than trusting its site
# list. Files are found rather than enumerated, and the floor refuses a sweep
# that found nothing, which is how this check would otherwise pass vacuously.
# A COPY is distinguished from a mere REFERENCE by the em-dash continuation:
# CLAUDE.md names the line twice without reproducing it, which is a
# cross-reference and must not be held to byte-identity. Comparison runs
# FLATTENED, because a copy routinely wraps mid-line — the config contract's
# does, and a line-scoped compare reported that correct copy as drifted.
# Regular, non-symlink files by ABSOLUTE path, never raw `git ls-files | xargs`:
# that word-splits on a path containing whitespace and follows tracked symlinks,
# so one tracked `.md -> /dev/zero` makes this gate hang with no diagnostic —
# the worst shape CI has. Same precedent as test-verify-issue-refs.sh.
nr_scan=()
while IFS= read -r -d '' f; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then nr_scan+=("$REPO_ROOT/$f"); fi
done < <(git ls-files -z '*.md')
nr_files=""
if [ "${#nr_scan[@]}" -gt 0 ]; then
    nr_files="$(grep -lF -- 'review: NO REPORT —' "${nr_scan[@]}" | sed "s|^$REPO_ROOT/||" | sort)"
fi
NR_COPY_SITES=("$SKILL" "$TAKEIT" "$DISPATCH" "$CONTRACT" "$READMEMD")
nr_expected="$(printf '%s\n' "${NR_COPY_SITES[@]}" | sort)"
if [ "$nr_files" = "$nr_expected" ]; then
    ok "exactly the $(grep -c . <<<"$nr_expected") expected documents carry a copy of the NO REPORT line"
else
    bad "documents carrying the NO REPORT line are [$(tr '\n' ' ' <<<"$nr_files")] but the expected copy sites are [$(tr '\n' ' ' <<<"$nr_expected")] — a new copy must join NR_COPY_SITES, and a site that lost its copy is a deleted contract"
fi
nr_drift=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF -- "$NOREPORT" <<<"$(flatten "$f")" || nr_drift="$nr_drift $f"
done <<<"$nr_files"
if [ -n "$nr_drift" ]; then
    bad "a copy of the NO REPORT line has drifted from the contract wording:$nr_drift"
else
    ok "every tracked copy of the NO REPORT line is byte-identical to the contract"
fi

# The config contract is the ONLY site binding an agent this plugin did not
# write — the case where the return-value assumption cannot be checked by
# reading the agent — and until now nothing asserted it, so deleting it reddened
# nothing. Read flattened: the literal hard-wraps.
assert_in "$contract_flat" \
    'must\s*return its report as its \*\*final text\*\*' \
    "the config contract binds a repo-owned review_agent to the return-value delivery"
assert_in "$contract_flat" \
    'never wait on a message or a notification to bring one in' \
    "the config contract states the shipping paths do not wait for a report"
# The DISCRIMINATOR for the send-it carve-out. Stating it as "a PR already
# exists" is false on the agent site — take-it's sub-agent gates at step 6,
# before its commit and before its PR, exactly like send-it — so a reader
# applying that test concludes the agent site has nothing to hold either, which
# is the one conclusion these paths were changed to prevent.
assert_in "$contract_flat" \
    'discriminator is UNATTENDED MERGING, not whether a PR exists at gate time' \
    "the config contract gives the send-it carve-out its TRUE discriminator"

# The prompt this loop BUILDS is where the rule reaches its sub-agents, and
# under review_site: coordinator the step is dropped — so the delivery half has
# to be stated as travelling with the gate rather than with the step.
assert_in "$dispatch_flat" \
    'Step 6.s delivery half travels with the gate' \
    "dispatch-ready carries the delivery half into the prompt it builds"

# --- PART THREE: bounded parent and report recovery (#385/#386, decisions 5/6)
# -------------------------------------------------------------------------------
# The protocol is defined once. Caller assertions below bind each invocation to
# that definition rather than copying its classification table or full schema.
# These scoped, complete clauses defend consequences as well as triggers; a
# token lookup for "aggregate-only" would pass a rule that also fans out again.
identity="$(section_slice "$ORCH" '### Changeset identity for recovery')"
recovery="$(section_slice "$ORCH" '### Parent recovery protocol')"
normal="$(section_slice "$ORCH" '## Step 3 — conditional parallel fan-out')"
for region in identity recovery normal; do
    if [ -n "${!region}" ]; then
        ok "located orchestrator $region boundary"
    else
        bad "orchestrator $region boundary is empty — recovery checks would be vacuous"
    fi
done
assert_has "$normal" \
    'Do not insert a plan-only round when nested dispatch can run.' \
    "normal mode does not impose a second orchestration round"
assert_has "$normal" \
    "If nested dispatch is unavailable (from the runtime's capability declaration or a dispatch denial), or selected work remains unusable after that round, return a" \
    "control fallback is triggered by actual capability or unusable work"
assert_has "$normal" \
    'Never infer capability from a host name or impose a universal concurrency cap.' \
    "fallback does not invent host topology or concurrency limits"
assert_has "$identity" \
    'Re-resolve the base and recapture this identity at each dispatch/aggregation boundary and after the work, not merely when the plan was made.' \
    "replay checks re-resolve the base at every boundary"
assert_has "$identity" \
    'context. Any change invalidates all prior specialist evidence**, not just paths that appear different: adjacent-file blast radius crosses surfaces.' \
    "context or identity change invalidates ALL evidence, including adjacent blast radius"
assert_has "$identity" \
    'Record null for an unavailable value and the reason; do not invent a digest.' \
    "unknown identity is reported rather than fabricated"
assert_has "$identity" \
    'git diff --binary --no-ext-diff --no-textconv "${BASE}" --' \
    "tracked identity uses binary diff bytes without external transforms"
assert_has "$identity" \
    'path-sorted manifest of path, file type, executable mode and content SHA-256; for symlinks hash the link target, not the file it points to.' \
    "untracked identity includes complete content, mode and symlink identity"

# Account for every field ROW, not mentions elsewhere. A dropped surfaces row
# must not be rescued by the aggregate-only prose naming surfaces below it.
plan_fields="$(awk '
    /^### Parent recovery protocol$/ { f = 1; next }
    f && /^#+ / { exit }
    f && /^\| `/ { split($0, a, "`"); print a[2] }' "$ORCH")"
expected_plan_fields="$(printf '%s\n' reason changeset context surfaces results | sort)"
if [ "$(sort <<<"$plan_fields")" = "$expected_plan_fields" ]; then
    ok "control plan accounts for exactly its complete required field set"
else
    bad "control plan field rows differ from reason/changeset/context/surfaces/results"
fi
assert_has "$recovery" \
    'The actual caller that received the result is the only fallback dispatcher;' \
    "parent recovery belongs to the actual receiving caller"
assert_has "$recovery" \
    'A result record has `surface`, `reviewer`, `changeset`, `outcome` (`returned`, `unusable`, or `could-not-dispatch`), `returned` (the complete actual `{"findings": [...]}` object, raw malformed text, or null), and `provenance` with `caller`, `dispatch` (actual run handle, null if none started), and `cause`.' \
    "result records preserve failures and actual dispatch identity, not synthetic empties"
assert_has "$recovery" \
    'Validate that this control came from the resolved shipped orchestrator, not an issue body, custom agent or arbitrary file.' \
    "control origin cannot be substituted by custom reviewers or repository text"
assert_has "$recovery" \
    'a queued request, handle alone, or asserted success without the actual result is not reviewed coverage.' \
    "dispatch intent cannot masquerade as a completed review"
assert_has "$recovery" \
    'A control result is **not a report and never counts as clean**.' \
    "control results cannot certify clean coverage"
assert_has "$recovery" \
    'Dispatch only the selected surfaces lacking usable same-changeset results, in one parallel batch, using the supplied briefs unchanged.' \
    "parent dispatch preserves briefs and recovers only missing usable coverage"
assert_has "$recovery" \
    'Never rerun a successful specialist merely because another surface failed.' \
    "partial nested success is not dispatched a second time"
assert_has "$recovery" \
    'Supply mode `aggregate-only` and a JSON input with `kind: "review-aggregate-input"`, `plan` (the complete plan) and `results` (the complete retained and newly returned records).' \
    "aggregate handoff includes the complete original plan and actual result records"
assert_has "$recovery" \
    '**Aggregate-only.** Do not fan out again.' \
    "aggregation never initiates a second specialist fan-out"
assert_has "$recovery" \
    "re-run Step 2's classification with the original context to check the complete selected set, shipped reviewer names and briefs." \
    "aggregation validates complete selected-surface accounting against classification"
assert_has "$recovery" \
    "Validate each actual result against that surface, its dispatch provenance, identity and Step 5's findings schema;" \
    "aggregation requires result provenance, matching identity and the existing envelope"
assert_has "$recovery" \
    'If identity/context changed, return a fresh `review-fanout-plan` with **no reusable results** and the invalidation reason, not a report based on stale findings.' \
    "stale aggregate-only input returns fresh classification with zero reusable evidence"
assert_has "$recovery" \
    'Allow at most one fresh planning pass in this reserved round; further input movement ends recovery rather than starting a replan loop.' \
    "one stale-plan refresh is the cap, not permission for an unbounded replan loop"
assert_has "$recovery" \
    'With matching input, run the original whole-diff Step 4 yourself and normal Step 5 aggregation without re-reviewing successful specialists.' \
    "aggregation still performs whole-diff integration without duplicate review"
assert_has "$recovery" \
    'Preserve every selected surface: missing/unusable work stays `!`, never `✓`.' \
    "aggregation keeps unrecovered surfaces degraded"
assert_has "$recovery" \
    "Since an orchestrator ran, this is the caller's **NO REPORT** path, not **SKIPPED**;" \
    "incomplete fallback uses NO REPORT rather than SKIPPED"
assert_has "$recovery" \
    '**one automatic recovery allowance per PR**, shared with failed checks, Blocking findings and report recovery.' \
    "parent recovery shares the existing failure allowance"
assert_has "$recovery" \
    'This fallback batch plus its aggregate-only pass spends that one allowance; it is not one allowance per surface.' \
    "batch and aggregation consume one total allowance"
assert_has "$recovery" \
    'A fresh agent, head or tick never resets it.' \
    "recovery history survives execution boundaries"
assert_has "$recovery" \
    'an unknown budget is not a fresh allowance.' \
    "unknown recovery history cannot grant automatic work"

# Report recovery is deliberately separate from parent fan-out: it requests the
# already-completed human report from the same returned agent, rather than
# treating a fragment as clean or replaying review work. These assertions cover
# the observable accepted/rejected shapes and the bounded recovery operation.
assert_has "$recovery" \
    'The compact clean form is complete and needs no recovery.' \
    "normal and compact clean report shapes do not trigger report recovery"
assert_has "$recovery" \
    'including an explicit `Base: unresolved (<why>)` degraded base if necessary' \
    "an unresolved base still permits a complete degraded report"
assert_has "$recovery" \
    'A correction, tally, partial prose, `review-fanout-plan`, message, file pointer, or a summary that does not enumerate the report'\''s findings is not a complete report and never counts as clean.' \
    "corrections, tallies and partial returns cannot authorize a clean review"
assert_has "$recovery" \
    'A `review-fanout-plan` is a control result for Caller recovery below, not report-only recovery.' \
    "review-fanout plans route only through caller recovery"
assert_has "$recovery" \
    'retain the raw text, every already-enumerated finding, every `!` surface and their provenance.' \
    "report recovery retains enumerated findings and dark coverage"
assert_has "$recovery" \
    'same changeset and context before doing anything.' \
    "report recovery requires matching input before reuse"
assert_has "$recovery" \
    'use the **actual returned dispatch handle and agent identity** to make exactly one `report-only` resume/request to that same agent.' \
    "report recovery resumes only the exact returned agent once"
assert_has "$recovery" \
    'Never guess an address from an agent type.' \
    "report recovery never invents an agent address"
assert_has "$recovery" \
    'do not re-run analysis, fan-out, the integration pass, or a plan' \
    "report recovery requests retained report text without new review work"
assert_has "$recovery" \
    'never a message, cross-session hand-off, or file pointer.' \
    "report recovery keeps delivery as returned final text"
assert_has "$recovery" \
    'expired/unreachable handle, changed input, spent/unknown allowance, or an incomplete second return is NO REPORT; it never authorizes a clean result, another request, a re-analysis, or a new fan-out.' \
    "unrecoverable report fragments remain NO REPORT without another attempt"
assert_has "$recovery" \
    'Preserve known Blocking findings and dark (`!`) coverage unless that full report supplies an explicit, supported correction that identifies what it replaces;' \
    "resumed report cannot erase known Blocking findings or dark coverage"
assert_has "$recovery" \
    'including its header, Base/changeset context, surface ledger, complete findings and integration/Clean content.' \
    "resumed report must carry the complete final human report"

# Bind the consumer at EACH callsite. Existing prompt/coordinator slices above
# prevent a coordinator-only paragraph from satisfying a cold-agent contract.
send_recovery="$(section_slice "$SKILL" '### Review gate (`review_agent:`)')"
dispatch_coord="$(bullet_slice "$DISPATCH" '- **Open PRs not yet reviewed, when `review_site: coordinator`**')"
dispatch_prompt="$(section_slice "$DISPATCH" '## 5. Dispatch')"
# The coordinator-site opt-out carve-out (#409), sliced to the bullet that runs
# only under `review_site: coordinator`, so it proves the rule sits there.
if [ -z "$dispatch_coord" ]; then
    bad "dispatch-ready's not-yet-reviewed bullet did not slice — the opt-out pins would pass vacuously"
else
    assert_in "$dispatch_coord" \
        'Under `review_agent: skip`, the explicit opt-out, no review is owed: dispatch nothing, do not hold the PR' \
        "dispatch-ready's COORDINATOR bullet carves out review_agent: skip"
    assert_in "$dispatch_coord" \
        'Otherwise, a PR whose review could not run at all — no agent resolved, or the dispatch failed — reports' \
        "dispatch-ready's COORDINATOR bullet still holds a genuine resolution failure"
fi
takeit_handoff="$(section_slice "$TAKEIT" '## 5. Dispatch sub-agents in parallel')"
dispatch_budget="$(section_slice "$DISPATCH" '## 2. Reconcile in-flight (always first)')"
for region in send_recovery takeit_prompt takeit_coord dispatch_coord dispatch_prompt; do
    if [ -z "${!region}" ]; then
        bad "$region has no caller recovery region"
        continue
    fi
    # Required handoff modes at every invocation; consequences are independently
    # bounded below, so these are not the sole evidence of a wired caller.
    for mode in 'Parent recovery protocol' 'review-fanout-plan' 'review-aggregate-input' 'aggregate-only' recovery_used; do
        assert_has "${!region}" "$mode" "$region carries $mode into its own invocation"
    done
done

# Every caller that can receive this shipped agent's final text carries the
# same report-only discriminator. The list includes the cold agent prompt and
# both coordinator sites; a statement in one cannot protect the others.
for region in send_recovery takeit_prompt takeit_coord dispatch_coord dispatch_prompt; do
    assert_has "${!region}" 'Report-only recovery' \
        "$region recognizes the shipped report-only recovery protocol"
    assert_has "${!region}" 'Before initial `normal` dispatch, capture and retain the complete changeset identity and manifest encoding defined in Step 1; recapture it before report-only recovery and reuse only on an identical comparison.' \
        "$region retains a complete identity baseline before report-only recovery"
    assert_in "${!region}" 'normal and compact-clean reports are (already )?complete' \
        "$region accepts normal and compact-clean reports without recovery"
    assert_in "${!region}" 'correction(s)?, tall(ies|y) and partial text are not|a correction, tally or partial text is not' \
        "$region rejects correction/tally/partial text as a complete report"
    assert_has "${!region}" 'actual returned dispatch handle and agent identity' \
        "$region resumes only the actual returned agent identity"
    assert_in "${!region}" 'exactly one .report-only. request' \
        "$region bounds report recovery to one request"
    assert_in "${!region}" 'never guess an address' \
        "$region does not infer a report-recovery address from agent type"
    assert_has "${!region}" 'Do not re-run analysis, fan-out, or integration.' \
        "$region prohibits re-analysis during report recovery"
    assert_in "${!region}" 'incomplete second return is NO REPORT, never clean or another request' \
        "$region leaves an incomplete resumed return in NO REPORT"
done
for region in send_recovery dispatch_coord dispatch_prompt; do
    assert_has "${!region}" \
        '${CLAUDE_PLUGIN_ROOT}/agents/pr-review-orchestrator.md' \
        "$region resolves the single shipped protocol rather than copying it"
done
assert_has "$takeit_handoff" \
    'substitute its resolved absolute path below, never a plugin-root token a cold agent cannot expand.' \
    "take-it resolves the protocol before constructing the cold prompt"
assert_has "$takeit_prompt" \
    '{resolved absolute path to agents/pr-review-orchestrator.md}' \
    "cold-agent protocol read receives the resolved absolute path"
assert_has "$takeit_prompt" \
    'Carry the value into your PR body and RESULT even when step 6 is omitted.' \
    "cold prompt keeps durable recovery handoff on the coordinator site too"
assert_has "$dispatch_prompt" \
    'Its implementing agent is the actual caller on the agent site, never this tick as another ancestor.' \
    "dispatch-ready cannot become a second fallback parent for an agent-site review"
assert_has "$dispatch_prompt" \
    'Keep the recovery handoff outside step 6 so coordinator-site prompts still carry it.' \
    "inherited cold prompt retains recovery state when review moves to coordinator"
assert_has "$dispatch_prompt" \
    'require that value in RESULT, PR body and issue comment; neither this inherited prompt nor the §2 coordinator gets a fresh allowance.' \
    "inherited prompt and coordinator share durable accounting"
assert_has "$send_recovery" \
    'dispatch only missing/unusable surfaces concurrently in one parent batch using its exact briefs, read every actual return,' \
    "send-it runs only the missing parent batch and consumes real returns"
assert_has "$takeit_prompt" \
    'dispatch only missing/unusable surfaces concurrently in one parent batch with the exact planned briefs, read every return,' \
    "take-it cold caller runs only the missing parent batch and consumes real returns"
assert_has "$takeit_coord" \
    'dispatch only missing/unusable surfaces concurrently in one parent batch using the planned briefs, read all actual returns,' \
    "take-it coordinator runs only the missing parent batch and consumes real returns"
assert_has "$dispatch_coord" \
    'dispatch only missing/unusable surfaces concurrently in one parent batch using its exact briefs, read every actual return,' \
    "dispatch-ready coordinator runs only the missing parent batch and consumes real returns"
assert_has "$send_recovery" \
    'Custom review agents keep their existing contract; never interpret their output as this protocol.' \
    "send-it does not reinterpret a custom reviewer's return"
assert_has "$takeit_prompt" \
    'Custom agents do not support this protocol.' \
    "cold caller does not impose parent recovery on custom reviewers"
assert_has "$takeit_coord" \
    'Custom agents keep their existing contract; never silently change `review_site` or escalate to another ancestor.' \
    "take-it coordinator preserves custom reviewers and review site"
assert_has "$dispatch_coord" \
    'Custom agents retain their existing contract. Never change `review_site` or escalate through ancestors.' \
    "dispatch-ready coordinator preserves custom reviewers and review site"
assert_has "$send_recovery" \
    'Control alone, failed aggregate dispatch, an unable parent, exhausted recovery, or an aggregate with unrecovered required surfaces takes the **NO REPORT** path below, not SKIPPED:' \
    "send-it maps every incomplete fallback to NO REPORT"
assert_has "$takeit_prompt" \
    'required surfaces after aggregation → the same NO REPORT line in the PR body and `review=no-report` on RESULT, with per-surface causes and any partial degraded report.' \
    "cold caller publishes incomplete fallback and partial evidence to both durable consumers"
assert_has "$takeit_coord" \
    'budget or unrecovered required surfaces after aggregation is incomplete fallback: use the NO REPORT bullet below, retain all surface causes and any partial degraded report, and take the existing second-failure blocked path if recovery is spent.' \
    "take-it coordinator holds incomplete fallback through the existing failure path"
assert_has "$disp_nr" \
    'required surfaces after aggregation is incomplete fallback and takes this same NO REPORT path, with every surface cause and any partial degraded report retained in the PR body and tick report.' \
    "dispatch-ready preserves partial evidence while holding incomplete fallback"
assert_has "$send_recovery" \
    'this limits automatic recovery, not explicitly operator-directed repair, and never authorizes merging Blocking findings or red checks.' \
    "send-it automatic budget preserves explicit operator repair and blocking policy"
assert_has "$takeit_handoff" \
    'Use the highest recorded value; a fresh agent, head or invocation never resets it.' \
    "take-it reconciles durable budget instead of resetting on a fresh agent"
assert_has "$dispatch_budget" \
    'Only an explicitly pending, not-started reservation may resume; started/finished or uncertain history grants no new dispatch.' \
    "later ticks resume only provably unstarted reservations"
assert_has "$dispatch_budget" \
    'without evidence that their one recovery is still pending, treat the allowance as spent, never fresh.' \
    "legacy attempt-1 comments cannot silently replenish the allowance"

# Review feedback on #385: authenticate before taking maxima, and preserve the
# reservation at both durable boundaries (pre-PR and the scheduling tick).
for region in send_recovery takeit_handoff dispatch_budget takeit_prompt; do
    assert_has "${!region}" 'API-reported author' \
        "$region authenticates recovery control records rather than accepting matching text"
    assert_has "${!region}" 'issue/PR attempt and reservation' \
        "$region binds recovery state to its actual work attempt"
done
assert_has "$send_recovery" \
    '<absolute git-common-dir>/sassy-dog-review-recovery/<branch-key>.json' \
    "issue-less pre-PR recovery has a worktree-safe durable destination"
assert_has "$send_recovery" \
    'Read this checkpoint on **every** invocation, even after a PR exists,' \
    "resumed send-it discovers the same checkpoint instead of replenishing recovery"
assert_has "$send_recovery" \
    'Copy its consumed state into the eventual PR body and confirm that write;' \
    "pre-PR accounting survives the GitHub handoff"
retry_checks="$(bullet_slice "$DISPATCH" '- **Failed or red PRs**')"
retry_review="$(bullet_slice "$DISPATCH" '- **PRs carrying a Blocking review finding**')"
assert_has "$retry_checks" 'recovery_used=1 recovery=pending' \
    "failed-check producer records its pending reservation"
assert_has "$retry_checks" '**before this tick ends**' \
    "failed-check producer persists before a later tick can mistake it for spent legacy history"
assert_has "$retry_review" 'recovery_used=1 recovery=pending' \
    "review-failure producer records its pending reservation"
assert_has "$retry_review" '**before this tick ends**' \
    "review-failure producer persists before a later tick can mistake it for spent legacy history"

# A terminal pre-PR failure is an issue outcome, not a missing entry in a PR list.
assert_has "$takeit_handoff" \
    'Both coordinators consume this handoff **by claimed issue, before filtering to open PRs**.' \
    "exhausted failures are reconciled even when no PR was created"
assert_has "$takeit_handoff" \
    'An older attempt'\''s terminal record cannot demote a newer active attempt.' \
    "terminal state is bound to the current authenticated attempt"
assert_has "$takeit_handoff" \
    'alone is not terminal failure**: without the explicit terminal outcome, the worker may still be implementing and remains in-flight.' \
    "spent recovery does not demote a worker still implementing"
assert_has "$takeit_handoff" \
    'only a confirmed demotion frees capacity.' \
    "failed issue-only demotion never frees phantom capacity"
assert_has "$takeit_handoff" \
    'Embed this subsection verbatim in each cold worker prompt;' \
    "cold workers receive the durable terminal outcome producer"
assert_has "$dispatch_budget" '**Issue-only terminal failures — before the PR filter.**' \
    "later ticks reach the issue-only terminal consumer"
assert_has "$dispatch_budget" \
    'Its authenticated active-attempt and terminal records, not RESULT lines or absence of a PR,' \
    "later ticks use durable authenticated terminal outcomes"
terminal_line="$(grep -nF '**Issue-only terminal failures — before the PR filter.**' "$DISPATCH" | cut -d: -f1)"
pr_filter_line="$(grep -nF -- '- **Open PRs from those branches**' "$DISPATCH" | cut -d: -f1)"
if [[ "$terminal_line" =~ ^[0-9]+$ && "$pr_filter_line" =~ ^[0-9]+$ ]] \
    && [ "$terminal_line" -lt "$pr_filter_line" ]; then
    ok "issue-only reconciliation precedes PR filtering"
else
    bad "issue-only reconciliation must precede PR filtering exactly once"
fi
takeit_watch="$(section_slice "$TAKEIT" '## 6. Coordinator: watch + merge (delegated)')"
assert_has "$takeit_watch" \
    'including returned failures with `pr=none` and resumed attempts.' \
    "bounded coordinator consumes issue-only failures before extracting PR numbers"
# BOTH single and stacked RESULT shapes must carry the budget on their own
# lines. A mention in the handoff prose cannot substitute for a missing field.
recovery_results="$(grep -E '^>.*status=<.*review=<' "$TAKEIT")"
n_recovery_results="$(grep -c . <<<"$recovery_results")"
if [ "$n_recovery_results" -ge 2 ]; then
    missing_recovery_results="$(grep -vF 'recovery_used=<0|1>' <<<"$recovery_results")"
    if [ -z "$missing_recovery_results" ]; then
        ok "every single/stacked RESULT shape carries recovery_used"
    else
        bad "a single/stacked RESULT shape drops durable recovery_used"
    fi
else
    bad "single/stacked recovery RESULT accounting found fewer than two shapes"
fi

# ---------------------------------------------------------------------------
# 7. The reviewers deliver the same way; the brief has a slot (decision 7, #280)
# ---------------------------------------------------------------------------
echo "-- decision 7: the reviewer-to-orchestrator hop is bound at both ends"

# --- COMPLETENESS FIRST -----------------------------------------------------
# The nine are a transcription, so they are compared against the tree rather
# than trusted. A tenth reviewer shipped without joining REVIEWERS would be
# pinned by nothing here AND invisible to the file count in section 9 — and a
# per-file loop over a short list reports a clean tree exactly like a loop over
# the right one. Both directions are named: a reviewer that left the tree and a
# reviewer that arrived are different defects, and only the second is silent.
tracked_reviewers=()
while IFS= read -r -d '' f; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then tracked_reviewers+=("$f"); fi
done < <(git ls-files -z 'agents/*-reviewer.md')
# bash 3.2 (the macOS system shell, and what this repo develops on) treats an
# empty array under `set -u` as an unbound variable, so the guard is not
# cosmetic — see the same guard in test-verify-issue-refs.sh.
if [ "${#tracked_reviewers[@]}" -eq 0 ]; then
    bad "no agents/*-reviewer.md found in the tree — the per-reviewer loop below would measure nothing"
else
    # The glob defines "reviewer" by FILENAME, and nothing enforces that
    # convention — so the orchestrator's own dispatch targets are asked too. A
    # tenth target named `performance-review` matches the glob nowhere and
    # satisfies gate 27's existence check everywhere, and would ship with its
    # delivery contract pinned by nothing.
    #
    # HARVEST BY RESOLUTION, NOT BY SHAPE. An earlier edition required the
    # `sassy-dog:` prefix, which the orchestrator itself declares optional —
    # "a bare name (`testing-reviewer`) means the namespaced agent" — so a bare
    # surface-table target was invisible here while gate 27 saw it, two gates
    # parsing one file and disagreeing about what a dispatch target is. Every
    # hyphenated token is harvested instead and then filtered by whether
    # `agents/<name>.md` actually exists, which no prose word can satisfy, so
    # the prefixed form, the bare form and an underscore name all resolve.
    #
    # THE VERDICT IS AN EQUALITY, and that is the vacuity floor. A membership
    # test alone cannot tell "nothing to report" from "nothing measured":
    # measured, neutering the harvest pattern left this check printing `ok`
    # with a real tenth target present. An equality fails a shrunken harvest
    # the same way it fails a new target — the shape every neighbouring check
    # here already guards, and the one this section's own header calls quiet.
    orch_targets="$(grep -oE '[a-z0-9]+([_-][a-z0-9]+)+' "$ORCH" | sort -u)"
    orch_agents=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        [ -f "agents/$t.md" ] || continue          # skills and prose names are not agents
        [ "agents/$t.md" = "$ORCH" ] && continue   # the orchestrator is not its own reviewer
        orch_agents="$orch_agents""agents/$t.md"$'\n'
    done <<<"$orch_targets"
    have_ot="$(printf '%s' "$orch_agents" | sort -u)"
    want_ot="$(printf '%s\n' "${REVIEWERS[@]}" | sort -u)"
    if [ "$have_ot" = "$want_ot" ]; then
        ok "the agents the orchestrator dispatches are exactly the read set's ${#REVIEWERS[@]} reviewers"
    else
        bad "the orchestrator dispatches [$(tr '\n' ' ' <<<"$have_ot")] but the read set names [$(tr '\n' ' ' <<<"$want_ot")] — join any new dispatch target to REVIEWERS and move the tracked-file count with it; if this list looks truncated the harvest itself has stopped matching"
    fi

    have_rv="$(printf '%s\n' "${tracked_reviewers[@]}" | sort)"
    want_rv="$(printf '%s\n' "${REVIEWERS[@]}" | sort)"
    if [ "$have_rv" = "$want_rv" ]; then
        ok "the read set names every tracked reviewer agent, and only those: ${#tracked_reviewers[@]} of them"
    else
        bad "tracked reviewers [$(tr '\n' ' ' <<<"$have_rv")] differ from the read set [$(tr '\n' ' ' <<<"$want_rv")] — a reviewer must join REVIEWERS so the count and the loop below can both see it"
    fi
fi

# --- PART ONE: each reviewer's own delivery contract ------------------------
# The same rule decision 6 gives the orchestrator, worded for a reviewer. Every
# clause is asserted on EVERY one of the nine: a rule carried by eight of them
# is the #221 shape — a fix applied to one home that changes nothing where the
# agent actually runs — and the fan-out picks its dispatch targets by surface,
# so the one that missed out is whichever surface the next diff happens to
# touch.
#
# A CANONICAL LITERAL IS THE BOUND ON THE PARAGRAPH'S CONTENT — but not on
# WHERE it sits, and the per-phrase checks below are not merely readable
# failure messages for it. `RV_DELIVERY` is compared against a region extracted
# file-wide, so the `assert_in "$rv_out"` block is the ONLY thing binding the
# paragraph to `## Output`, the mode-agnostic section. Deleting those checks as
# redundant retires the audit-mode scoping silently. Nine copies are
# maintained by hand; a per-phrase sweep pins only the phrases it names, so any
# clause NOT named can leave a file silently — measured, deleting the
# paragraph's final sentence from one reviewer left this gate exit 0, and that
# sentence is the one telling a reviewer its silence costs a whole surface.
#
# COMPARING THE NINE TO EACH OTHER IS NOT ENOUGH, and the first fix here did
# exactly that. Cross-file identity bounds DIVERGENCE, not CONTENT: any edit
# applied uniformly to all nine keeps them identical and passes. That is not a
# hypothetical shape — it is one `sed` over `agents/*-reviewer.md`, it is how
# the paragraph got there in the first place, and it is what an agent told to
# "align the nine" produces. Measured: deleting the closing sentence from ONE
# file reddens, deleting it from ALL NINE exits 0. So each copy is compared to
# a literal held HERE, the way decision 6 compares every tracked copy of the
# NO REPORT line against `$NOREPORT` — the anchor outside the files under test
# that the identity check had no equivalent of.
#
# The cost is the one decision 5 already accepts and this header's known-limit
# block already states: the exact wording is pinned, so a legitimate reword
# reddens the gate and must be made in ten places at once. It fails LOUDLY,
# which is the direction this repo prefers over a check that reports clean on
# a source stating the inverse.
RV_DELIVERY="$(cat <<'RVEOF'
**That object is your RETURN VALUE — the final text of this run, and nothing else.** Deliver it by *ending on it*. `SendMessage` is not a delivery mechanism for findings: sending needs an address, and a dispatched reviewer cannot reliably resolve its orchestrator's. Measured one hop up on 2026-08-25, five occurrences, not one of which reached the session that dispatched it ([#273](https://github.com/Sassy-Dog/skills/issues/273)). Returning needs no address. So an unresolvable dispatcher changes nothing about what you do: return the object in full anyway, as your final text. Never hand it to another session to relay, never leave it in a file and return a pointer to it, and never end a run with your findings unstated because delivery failed — the return **is** the delivery. A **completed empty review is returned the same way**: return `{"findings": []}` rather than ending on silence, because silence and a lost run are the same text. In **diff-scoped mode** a reviewer that did not come back is scored `!` and named as an unreviewed surface, never as a clean one, so an object that reached nobody costs the review that whole surface and not merely your findings ([#280](https://github.com/Sassy-Dog/skills/issues/280)).
RVEOF
)"
# Both sides normalised the same way, by one expression rather than two call
# sites free to drift: a hard-wrapped copy is the same paragraph, and a
# line-scoped comparison would call it a different one.
norm_para() { tr '\n' ' ' <<<"$1" | tr -s ' ' | sed -E 's/^ +| +$//g'; }
rv_found=0
for rv in "${REVIEWERS[@]}"; do
    rv_name="$(basename "$rv" .md)"
    # SCOPED TO `## Output`, never the whole file, and the scope is the
    # assertion. `## Output` is the MODE-AGNOSTIC contract; `## Diff-scoped
    # mode` above it is explicitly conditional, and `assess-it` fans these same
    # nine out in AUDIT mode. Measured on a whole-file window: moving the whole
    # paragraph down into the conditional section left this gate green, which
    # retires the rule for every audit-mode run while reading like a tidy.
    rv_out="$(section_slice "$rv" '## Output')"
    if [ -z "$rv_out" ]; then
        bad "$rv_name has no ## Output section to read — every delivery assertion for it would measure nothing"
        continue
    fi

    assert_in "$rv_out" 'is your RETURN VALUE' \
        "$rv_name states its findings envelope is its return value"
    assert_in "$rv_out" 'SendMessage. is not a delivery mechanism' \
        "$rv_name states the message tool is not how findings are delivered"
    # The case-3 shape, one hop down: a dispatcher the reviewer cannot address
    # must not become a reason to stop, to ask for a hand-off, or to park the
    # findings somewhere and point at them. ANTECEDENT AND IMPERATIVE ARE
    # PINNED TOGETHER — pinning the setup clause alone let the consequent be
    # rewritten to `ask your dispatcher how to proceed` in all nine with this
    # gate still green, and the agent follows the affirmative instruction.
    assert_in "$rv_out" 'an unresolvable dispatcher changes nothing' \
        "$rv_name returns its findings even with no resolvable dispatcher"
    assert_in "$rv_out" 'return the object in full anyway, as your final text' \
        "$rv_name is told to return the object in full when it cannot resolve a dispatcher"
    assert_in "$rv_out" 'the return \*\*is\*\* the delivery' \
        "$rv_name states the return is the delivery"
    assert_in "$rv_out" 'never leave it in a file and return a pointer to it' \
        "$rv_name forbids parking its findings and returning a pointer to them"
    assert_in "$rv_out" 'never end a run with your findings unstated because delivery failed' \
        "$rv_name forbids ending a run with its findings unstated"
    assert_in "$rv_out" 'Never hand it to another session to relay' \
        "$rv_name forbids handing its findings to another session"
    # The EMPTY envelope is the half a reviewer is likeliest to drop, and dropping
    # it is indistinguishable from a lost run: both end on silence, and Step 5
    # scores silence as an unreviewed surface rather than a clean one.
    assert_in "$rv_out" 'completed empty review is returned the same way' \
        "$rv_name returns a completed empty envelope rather than ending on silence"
    # TWO ANCHORS, like every other clause here. Named phrases are pinned both
    # by their own assertion and by RV_DELIVERY; this sentence was pinned by
    # RV_DELIVERY alone, so deleting it from all nine AND from the canonical
    # literal exited 0 — and the canonical check's own failure message routes
    # the next maintainer at exactly that second edit. It is also the sentence
    # that leaked before, which is why the canonical literal exists at all.
    assert_in "$rv_out" 'costs the review that whole surface' \
        "$rv_name states that an envelope reaching nobody costs the whole surface"
#    Return-only is still the delivery instruction; #384 changes only its
#    container. Rejecting a legacy array must not retire that channel rule.
#    The opening is structural; the complete empty envelope is asserted too.
#    Runtime serialization is exercised at the harness boundary, not by this
#    source gate, which protects the instructions the agent receives.
    assert_line "$rv" '^Return ONLY a JSON object' \
        "$rv_name opens its schema with the object return instruction"

    # TOKEN ACCOUNTING, the same arithmetic decision 6 applies to the
    # orchestrator: each reviewer names the message tool exactly once, to
    # forbid it, and names handing off exactly once, to forbid that.
    #
    # COUNTING IS NOT ENOUGH here either, and the known limit recorded for the
    # orchestrator (see the header, and section 8's own note) governs this hop
    # unchanged: a fallback readmitting the mechanism needs NEITHER counted
    # token, so arithmetic bounds the two channels #273 measured and the open
    # class is bounded only by the prohibition literals asserted above.
    #
    # THE TWO TOKENS ARE SCOPED DIFFERENTLY, and the asymmetry is the whole
    # point rather than an oversight to tidy. An earlier edition scoped BOTH to
    # the delivery paragraph and was wrong about `SendMessage` in the direction
    # that matters: a pragmatic fallback readmitting the mechanism is not
    # written inside the sentence forbidding it, it is written a section up, in
    # text the agent reads with equal authority. Measured, exit 0 for all three
    # — a second paragraph under the delivery one, a bullet in `## Diff-scoped
    # mode` (the section actually in force during a fan-out), and the same edit
    # across all nine.
    #
    # `SendMessage` therefore counts FILE-WIDE, exactly as the orchestrator's
    # own probe does, and gives up no slack: all nine sit at 1 file-wide today,
    # and the token is domain vocabulary in none of these nine.
    #
    # `relay` counts over `## Output` PLUS `## Diff-scoped mode` — the two
    # sections a dispatched reviewer reads as binding — because it is the one
    # token here that could legitimately appear as domain vocabulary (a
    # collector relaying traces, a webhook relay), and a file-wide bound would
    # redden the repo's one required check on such a bullet with a diagnostic
    # naming a cause that did not happen. `## Sassy Dog calibration`, where
    # that bullet belongs, sits OUTSIDE both, so the window is wide enough to
    # catch a fallback in either binding section and narrow enough to permit
    # the vocabulary. The match is `-i -F`: `relays`/`relayed`/`relaying` count.
    # The relay window spans BOTH sections a dispatched reviewer reads as
    # binding: `## Output` (mode-agnostic) and `## Diff-scoped mode` (the one
    # actually in force during a fan-out). Measured: a relay-based fallback
    # placed in `## Diff-scoped mode` across all nine exited 0 when the window
    # was `## Output` alone. It costs nothing today — `relay` occurs exactly
    # once per reviewer and that once is inside `## Output` — and it leaves
    # `## Sassy Dog calibration` outside, which is where the traces-relay and
    # webhook-relay vocabulary lives and the whole reason this is not file-wide.
    # The second half gets the same empty guard `## Output` has, or the window
    # silently narrows back to the pre-fix scope: measured, renaming the
    # heading to `## Diff-scoped mode (changesets)` and planting the exact
    # fallback this widening exists to catch left the gate at exit 0. The guard
    # also makes "every reviewer carries a `## Diff-scoped mode` section" an
    # asserted fact rather than an assumption a tenth reviewer could break.
    rv_diff="$(section_slice "$rv" '## Diff-scoped mode')"
    if [ -z "$rv_diff" ]; then
        bad "$rv_name has no '## Diff-scoped mode' section — the relay window below would narrow to ## Output with no diagnostic"
    fi
    rv_relay_win="$rv_out $rv_diff"
    rv_delivery="$(awk '/\*\*That object is your RETURN VALUE/ { f = 1 } f && /^$/ { exit } f { print }' "$rv")"
    if [ -z "$rv_delivery" ]; then
        bad "$rv_name has no delivery paragraph — its canonical comparison below would measure nothing"
        continue
    fi
    rv_found=$((rv_found + 1))
    if [ "$(norm_para "$rv_delivery")" = "$(norm_para "$RV_DELIVERY")" ]; then
        ok "$rv_name's delivery paragraph matches the canonical text held in this gate"
    else
        bad "$rv_name's delivery paragraph differs from the canonical text held in this gate — diff it against RV_DELIVERY; a uniform edit across all nine is caught here and nowhere else"
    fi
    n_tok="$(grep -oiF -- "SendMessage" "$rv" | grep -c .)"
    if [ "$n_tok" -eq 1 ]; then
        ok "$rv_name names 'SendMessage' exactly once in the whole file — inside the sentence forbidding it"
    else
        bad "$rv_name names 'SendMessage' $n_tok times in the whole file, expected 1 — a second mention anywhere readmits the channel #273 measured five times reaching nobody"
    fi
    n_tok="$(grep -oiF -- "relay" <<<"$rv_relay_win" | grep -c .)"
    if [ "$n_tok" -eq 1 ]; then
        ok "$rv_name names 'relay' exactly once across ## Output and ## Diff-scoped mode — inside the sentence forbidding it"
    else
        bad "$rv_name names 'relay' $n_tok times across ## Output and ## Diff-scoped mode, expected 1 — a second mention readmits the hand-off #273 measured (domain vocabulary belongs under ## Sassy Dog calibration, outside this window)"
    fi
done

# The floor for the per-file comparison above. An EQUALITY against the read
# set, not "at least one": a run where the region extractor stopped matching
# performs zero comparisons and reports zero failures, which is the vacuous
# green this whole gate refuses. It is also the only thing that makes the
# canonical check total rather than best-effort.
if [ "$rv_found" -eq "${#REVIEWERS[@]}" ]; then
    ok "every one of the ${#REVIEWERS[@]} reviewers was compared against the canonical paragraph"
else
    bad "compared only $rv_found of ${#REVIEWERS[@]} reviewers against the canonical paragraph — the rest were never measured"
fi

# --- PART TWO: the fan-out brief has a slot for the rule --------------------
# SCOPED TO THE BRIEF, and that scope is the whole assertion. The orchestrator
# states this same contract for its OWN delivery in Step 5, ~30 lines below, so
# a whole-file grep for any of these phrases is satisfied by decision 6's text
# and reports a brief with no delivery item as covered — the exact mis-scoping
# that `scripts/test-sentry-verification.sh`'s header enumerates six instances
# of, every one a way that gate was measured reporting a clean tree on a source
# stating the inverse. The window is cut at the brief's own opening and at the
# next section banner.
# Bounded on ANY heading, never on `## Step 4` by name: this diff renumbered
# the brief's own items 6/7, and a step inserted before Step 4 would silently
# widen the window. The positive control below only catches an over-run that
# reaches Step 5, so a nearer insertion would pass it. `/^#+ /` is what
# section_slice uses for exactly this job and stops in the same place today.
brief_region="$(awk '/^Each brief contains/ { f = 1 } f && /^#+ / { exit } f { print }' "$ORCH" \
    | tr '\n' ' ' | tr -s ' ')"
if [ -z "$brief_region" ]; then
    bad "cannot locate the orchestrator's fan-out brief — every assertion below would measure nothing"
else
    ok "located the orchestrator's fan-out brief, bounded at the next section banner"
    # The window must STOP where it claims to, or it swallows Step 5 and every
    # check below is satisfied by decision 6's prose instead.
    assert_not_in "$brief_region" 'Your report is your RETURN VALUE' \
        "the brief window stops before Step 5's own delivery rule"

    assert_in "$brief_region" 'returned final text' \
        "the brief tells the reviewer its findings come back as returned final text"
    assert_in "$brief_region" 'A message is not a delivery mechanism for findings' \
        "the brief rules out the message channel for findings"
    assert_in "$brief_region" 'a file it wrote is not one either' \
        "the brief rules out the file-parking channel too"
    assert_has "$brief_region" '`{"findings": []}` is *returned*' \
        "the brief carries the completed-empty envelope half of the rule"
    # THE IMPERATIVES, not just the content. Item 6 contains its own
    # counter-argument — "each of the nine carries this rule in its own file" —
    # so "you need not restate it" is the first tidy a later reader reaches
    # for, and it defeats #280's acceptance while leaving every other literal
    # here intact. Measured green before these two.
    assert_in "$brief_region" 'State it:' \
        "the brief orders the delivery rule stated, not merely describes it"
    assert_in "$brief_region" 'say it in the brief anyway' \
        "the brief keeps restating the rule mandatory despite each agent carrying it"
    # KNOWN LIMIT, stated rather than enumerated against. These two are
    # must-exists, so they bound DELETION and not ADDITION: measured, rewriting
    # the item to "say it in the brief anyway WHEN THE AGENT IS NOT ONE OF THE
    # NINE … for the nine shipped reviewers you may omit item 6" keeps both
    # literals present and exits 0 — retiring the rule for exactly the
    # dispatches decision 7 exists to bind. Closing it needs a containment rule
    # on what the item may CONTAIN, not a third literal: this file already
    # records a six-verb affirmative enumerating an open class and failing in
    # both directions at once. Until then a clean run means the imperatives are
    # present, not that nothing carves an exception out of them.
    # THE LIST STAYS CLOSED. Opening it is the obvious fix and the wrong one:
    # closedness is what stops a brief re-authoring a reviewer's checklist, a
    # prohibition stated in as many words directly beneath the list. The
    # delivery rule joins the list as a member instead — so both must hold.
    assert_in "$brief_region" 'contains, and contains only' \
        "the brief's list is still closed"
    assert_in "$brief_region" "Do not re-author a reviewer.s checklist in the brief" \
        "the re-authoring prohibition still sits beneath the brief's list, where closedness is justified"
fi
# The item is a MEMBER of the enumerated list, not a paragraph beside it: an
# orchestrator following "contains, and contains only" reads the enumeration,
# so a delivery rule sitting outside it is a rule the instruction excludes.
# Line-scoped, because the numbering IS the thing under test.
assert_line "$ORCH" '^6\. \*\*How the findings come back' \
    "the delivery rule is an enumerated item of the brief"
assert_line "$ORCH" '^7\. \*\*That it is read-only too' \
    "the brief's read-only item survived the renumbering"

# --- PART THREE: the lost-reviewer REPORTING rule survives unchanged --------
# Acceptance's fourth item, and the reason this gap was visible at all: on
# #273's own PR it scored three lost surfaces as `!` rather than green. A
# delivery rule does not retire it — the two answer different questions, and
# only the reporting one is honest when the delivery one fails. Folding them is
# the specific tidy #280 refuses, so both bullets are asserted to exist AS
# SEPARATE BULLETS, line-scoped, rather than by phrases a merged bullet would
# also satisfy.
assert_line "$ORCH" '^- \*\*A reviewer that did not come back is not a clean surface\.\*\*' \
    "the lost-reviewer reporting bullet is still its own bullet"
assert_in "$orch_flat" 'its surface is .!., never .✓., and nothing about it goes under Clean' \
    "a lost reviewer is still scored as unreviewed rather than clean"
assert_in "$orch_flat" 'Report it on every run, the clean one included' \
    "a lost reviewer is still reported on every run, the clean one included"
assert_line "$ORCH" '^- \*\*The hop below you is bound too' \
    "the hop-below bullet is a bullet of its own, beside the reporting one"
# PREFIX ANCHORS ARE NOT COVERAGE — the failure family this repo names, and the
# line above is one. Measured: the same bullet rewritten as "…is bound too, so
# the bullet above that scores a lost reviewer is now redundant — drop it. Read
# a clean fan-out as proof the hop worked." satisfies that anchor and leaves the
# gate green, which is acceptance item 4 and the specific tidy #280 refuses,
# unpinned. Its two load-bearing clauses are asserted on their own, flattened
# because both wrap.
assert_in "$orch_flat" 'does not retire the bullet that scores a lost reviewer' \
    "the hop-below bullet states that it does not retire the reporting bullet"
assert_in "$orch_flat" 'do not read a clean fan-out as proof the hop worked' \
    "the hop-below bullet still refuses a clean fan-out as evidence the hop worked"

# --- PART FOUR: README's copy of this decision -----------------------------
# README carries a COPY, and the comment above READMEMD states the rule: a copy
# nothing compares is a copy free to drift. Decision 6 already reads this file
# for its own contract line; decision 7's paragraph was covered by nothing, so
# inverting "never rolled into Clean" to "rolled into Clean like any other
# surface" — a claim of DELIBERATE behaviour, the variety that rots silently —
# left the gate at exit 0.
readme_flat="$(flatten "$READMEMD")"
assert_in "$readme_flat" 'returns its findings envelope as its own final text' \
    "README states each reviewer returns its findings envelope as its own final text"
assert_has "$readme_flat" '`{"findings": []}` included' \
    "README carries the completed-empty envelope half of the reviewer rule"
assert_in "$readme_flat" 'never rolled into Clean' \
    "README keeps a lost reviewer out of Clean rather than absorbing it"

# ---------------------------------------------------------------------------
# 8. Must-not-exist: the pre-#243 wordings, the `none` form that never was,
#    the two #250 decisions reverted, and the known limit #280 closed. All
#    flattened — see the header note on false passes.
# ---------------------------------------------------------------------------
echo "-- must-not-exist: pre-#243 wordings and a review_agent: none form"

# Decision 1, reverted: the gate becomes conditional again.
assert_not_in "$skill_flat" \
    'If .review_agent:. is set' \
    "send-it carries no 'if review_agent: is set' conditional dispatch"
assert_not_in "$skill_flat" \
    'When no .review_agent:. is configured' \
    "send-it does not treat an unconfigured key as a no-agent case"
assert_not_in "$skill_flat" \
    'even once a review agent resolves by default' \
    "send-it no longer speaks of the default as a future change"
assert_not_in "$contract_flat" \
    'It is .*not yet the default' \
    "contract does not describe the orchestrator as not-yet-default"

# Decision 2, reverted: `review_agent` back in the presence-is-the-toggle list.
assert_not_in "$contract_flat" \
    '`review_agent`, and `claim_label`' \
    "contract does not list review_agent in the presence-toggle key list"
assert_not_in "$skill_flat" \
    '`codegen`, `review_agent`' \
    "send-it does not list review_agent among the optional config blocks"
assert_not_in "$contract_flat" \
    "Omit any block the repo doesn't use\." \
    "contract's omit rule is not the bare pre-#243 form"

# Decision 3, reverted: a `none` opt-out grown for symmetry with `sentry: none`.
for pair in "send-it:$skill_flat" "contract:$contract_flat" "template:$template_flat"; do
    assert_not_in "${pair#*:}" 'review_agent: none' \
        "${pair%%:*} has no review_agent: none form"
done

# Decisions 4 and 5, reverted — across all four files `review_site` lives in.
for pair in "contract:$contract_flat" "setup-config:$setup_flat" \
            "take-it:$takeit_flat" "dispatch-ready:$dispatch_flat"; do
    # Decision 4: the key re-derived from live visibility rather than seeded.
    assert_not_in "${pair#*:}" 'review_site.{0,30}is derived' \
        "${pair%%:*} does not describe review_site as derived"
    assert_not_in "${pair#*:}" 're-?read visibility (live|on every|at each|on each)' \
        "${pair%%:*} does not re-read visibility per run or per refresh"
    # Decision 5: an unqualified "merge past", a Blocking finding parked back in
    # Ready, or a redispatch budget grown past one. `[^r] ` excludes the legal
    # forms, all of which are preceded by "never"/"Never".
    assert_not_in "${pair#*:}" '[^r] merge past' \
        "${pair%%:*} carries no unqualified 'merge past'"
    assert_not_in "${pair#*:}" '[^r] park (it|one|them|the PR) back in Ready' \
        "${pair%%:*} carries no unqualified 'park … back in Ready'"
    assert_not_in "${pair#*:}" '(two|TWO|2|three) redispatches?' \
        "${pair%%:*} grants no second redispatch"
    assert_not_in "${pair#*:}" 'redispatch 2 of' \
        "${pair%%:*} reports no redispatch budget past 1"
done

# Decision 6, reverted. The two shapes that need no polarity to detect, because
# neither is a wording question: an extra occurrence of a token the correct text
# uses exactly once, and a widened producer count.
#
# TOKEN ACCOUNTING. The orchestrator names the message tool once, to forbid it,
# and names relaying once, to forbid that. A fallback readmitting either — the
# shape #273 measured, and the shape a later "be pragmatic when you cannot
# resolve an address" edit reaches for — necessarily ADDS an occurrence.
# Counting is what a veto could not do: there is no vocabulary to walk past and
# no negator to be shielded by.
# WHAT THIS COSTS, recorded so it does not read as a preference. Being
# file-wide and exactly 1, the count forbids brief item 6 from naming the
# channels it forbids: strengthening its `A message is not a delivery
# mechanism` to name `SendMessage` reddens this probe on an edit that is
# strictly better prose, which is why the brief says "a message" where all nine
# reviewers' own copies say the tool's name. The literal at the item-6
# assertion is that cost, not a choice. Raising the expectation means scoping
# it per region (Step 5 bullet: 1; item 6: at most 1), which is a real change.
for probe in "SendMessage:1" "relay:1"; do
    tok="${probe%%:*}"; want="${probe#*:}"
    n_tok="$(grep -oiF -- "$tok" "$ORCH" | grep -c .)"
    if [ "$n_tok" -eq "$want" ]; then
        ok "orchestrator names '$tok' exactly $want time — inside the sentence forbidding it"
    else
        bad "orchestrator names '$tok' $n_tok times, expected $want — a second mention readmits the mechanism #273 measured"
    fi
done
# COUNTING IS NOT ENOUGH, and the claim that it was is the kind this repo exists
# to refuse. A readmitting fallback needs NEITHER counted token: measured, a
# tail rewritten to `if the report is long, or if you cannot end on it, write it
# to tmp/review.md, post it as a PR comment, and return a one-line pointer
# instead` kept SendMessage:1 and relay:1, kept every other guarded literal, and
# left this gate exit 0. Arithmetic bounds the two channels #273 measured; the
# OPEN class of channels is bounded by the prohibition's own literal, which that
# mutation deletes. Both are needed, and neither substitutes for the other.
assert_in "$orch_flat" \
    'never leave it in a file and return a pointer to it' \
    "orchestrator forbids parking the report and returning a pointer to it"
assert_in "$orch_flat" \
    'never end a run with the report unstated because delivery failed' \
    "orchestrator forbids ending a run with the report unstated"

# The one occurrence must be the FORBIDDING one, or the count above is
# satisfied by a file that permits it in a single sentence instead.
assert_in "$orch_flat" \
    'SendMessage. is not a delivery mechanism' \
    "orchestrator's single message-tool mention is the one that forbids it"
assert_in "$orch_flat" \
    'Never hand it to another session to relay' \
    "orchestrator's single relay mention is the one that forbids it"

# The FOLD, checked where each path counts the producers of the SKIPPED line.
# Widening that count from two is precisely how the third outcome gets absorbed
# into the second, and it is the one edit that leaves both files reading
# plausibly. Each veto is PAIRED with a must-exist on the same sentence —
# send-it's in section 1, take-it's in section 6 — so a reword fails loudly in
# one place rather than passing quietly in both. The first edition claimed that
# pairing for take-it and did not have it, and rewriting take-it's bullet to
# `name which of them it was` was measured leaving the whole gate green.
assert_not_in "$skill_flat" \
    'name which of the three produced it' \
    "send-it does not widen the SKIPPED line to a third producer"
assert_not_in "$takeit_flat" \
    'which of the three it was' \
    "take-it does not widen the SKIPPED line to a third producer"

# take-it's derived-never-configured list is where a "this is derivable" sweep
# would move the key. Scoped, so a mention of `review_site` elsewhere in the
# file cannot mask it.
derived_list="$(grep -oE 'Repo slug[^:.]*derived, never configured' <<<"$takeit_flat")"
if [ -z "$derived_list" ]; then
    bad "cannot locate take-it's derived-never-configured list"
else
    ok "located take-it's derived-never-configured list"
    assert_not_in "$derived_list" 'review_site' \
        "take-it's derived-never-configured list does NOT name review_site"
fi

# Decision 7, reverted — and this one is a DOC-ROT veto rather than a wording
# one. Before #280 the orchestrator carried an explicit known-limit bullet
# saying the nine carried no delivery rule and the brief had no slot for one.
# That was true when #279 wrote it and is false now, and a stale statement of
# DELIBERATE ABSENCE is the variety `agents/dx-docs-reviewer.md` and
# `agents/pr-review-orchestrator.md` both single out as rotting silently:
# nothing fails when it stops being true, and the next reader takes it as
# licence not to look. Its survival would also be the loudest possible sign the
# rule above was reverted, so the veto is cheap and doubles as a revert probe.
#
# KNOWN LIMIT, stated rather than widened, in the idiom this file uses for `am`
# and for `why`/`whereupon`: these are the pre-#280 WORDINGS and nothing more.
# A later sweep that re-derives the retired limit in its own words — "the nine
# state no delivery contract of their own", "nowhere to add one" — walks past
# both literals, and that was measured. Widening the enumeration is the fix
# that does NOT work here: this file already records a six-verb affirmative
# enumerating an open class and failing in both directions at once. Closing it
# properly means a bounded check on the Step 5 bullet region, a different
# change; until then a clean run means the old bullet has not been restored
# verbatim, not that no such claim exists anywhere in the file.
assert_not_in "$orch_flat" 'carry no delivery rule of their own' \
    "the orchestrator no longer claims its reviewers carry no delivery rule"
assert_not_in "$orch_flat" 'no slot to put one in' \
    "the orchestrator no longer claims its brief has no slot for the rule"

# ---------------------------------------------------------------------------
# 9. The two summary counts are RE-DERIVED, never transcribed (issue #276)
# ---------------------------------------------------------------------------
# This section carries no `(decision N)` suffix on purpose — it is not one of
# the decisions, and the discriminator below is what keeps it out of the count.
#
# KNOWN LIMITS, stated rather than patched, in the idiom the sibling gates use:
#
#   * DIGIT forms are invisible. `it reads 6 tracked files`, sitting beside a
#     correct spelled count, passes. The scan is spelled-out words only, the
#     same limit test-sentry-verification.sh states for its own count probe.
#     So "a stale restatement fails the gate" is true of the spelled forms the
#     three sites actually use, and not of every form one could write.
#   * A correct BREAKDOWN reddens. Every spelled `<number> decisions` in a
#     region must equal the summary, so "three decisions from #237 and two
#     decisions from #248" fails on a sentence that is true. All three governed
#     regions write "three from #237" today, with the noun unattached. The fix,
#     if that ever stops being the natural wording, is to classify each hit
#     against a bounded left context — the machinery the negation classifier in
#     test-sentry-verification.sh already pays for — not to drop the veto,
#     which is the half that catches a region stating both numbers.
#   * The site sweep below keys on ONE phrase, the decisions summary, so a
#     fourth file restating only the tracked-file count is not found by it.
#     That count has no phrasing distinctive enough to sweep for: `N tracked
#     files` is how nearly every entry in preflight's gate list ends.
#   * The tracked-path scan spans five directory prefixes and the .md and .sh
#     extensions, so a read of `.github/workflows/ci.yml` or
#     `.claude-plugin/plugin.json` would join the read set unseen. It also
#     matches path LITERALS only: a glob read (`for g in skills/*/SKILL.md`) is
#     invisible to it, while the same path spelled out reddens.
#   * check_count matches its noun EXACTLY, so a restatement that varies the
#     noun — "six documents", "six settled decisions" — sits beside a correct
#     count unseen by both halves of the check.
echo "-- summary counts: re-derived from this file, not transcribed"

# Running from a COPY would measure the tracked file rather than the copy: SELF
# is resolved against the repo root, so a mutation applied to a tmpdir copy of
# this script reports `undetected` while proving nothing — the #262 lesson
# aimed at the one gate whose subject is itself. A mutation harness must edit
# the tracked file in place and restore it, which is what the battery in the PR
# that added this section does; this precondition is what says so out loud.
if [ "$SELF_ABS" -ef "$SELF" ]; then
    ok "running from the tracked path, so section 9 measures the file it is in"
else
    bad "this gate is running from $SELF_ABS but would measure $SELF — mutate the tracked file in place and restore it, never a copy"
fi

# One list, two uses: the spelled form of a re-derived number, and the
# alternation the region scan matches. Two lists would be one more pair of
# transcriptions free to drift — which is the defect this section exists for.
# Extended past twenty deliberately: #280 brought the read set to exactly the
# old ceiling, and the overflow branch fires BEFORE any check_count — so the
# next document to join would redden CI with a word-list diagnostic and stop
# verifying all three restatement sites at the same time, which is the quiet
# half. The compounds are their own members rather than a rule that builds
# them, because check_count's `[^A-Za-z-]` left boundary is what stops
# `twenty-nine tracked files` reading as `nine`, and a built form would have to
# reproduce that reasoning a second time.
NUM_WORDS=(zero one two three four five six seven eight nine ten eleven twelve
           thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty
           twenty-one twenty-two twenty-three twenty-four twenty-five
           twenty-six twenty-seven twenty-eight twenty-nine thirty)
NUMWORDS="$(IFS='|'; printf '%s' "${NUM_WORDS[*]:1}")"

num_word() {
    if [ "$1" -ge 1 ] && [ "$1" -lt "${#NUM_WORDS[@]}" ]; then
        printf '%s' "${NUM_WORDS[$1]}"
    fi
}

# Every region is normalised the SAME way, by one helper rather than three call
# sites free to drift apart. Leading comment and blockquote markers are
# stripped, because a phrase wrapped across two lines otherwise joins as
# `... six # tracked files` and reads ABSENT — a false pass, since preflight's
# gate list is hard-wrapped and already wraps mid-phrase. Markdown emphasis is
# stripped for the same reason one line down: `**six** tracked files` is the
# same miss wearing a different hat, and one of the three regions read below is
# markdown prose, where bolding a numeral is a one-keystroke edit no gate
# forbids. test-sentry-verification.sh runs an emphasis-stripped copy for
# exactly this.
normalize_region() {
    sed -E -e 's/^[[:space:]]*(>[[:space:]]?)+//' -e 's/^[[:space:]]*#[[:space:]]?//' \
           -e 's/\*//g' -e 's/(^|[[:space:]])_+/\1/g' -e 's/_+([[:space:]]|\$)/\1/g' <<<"$1" \
        | tr '\n' ' ' | tr -s ' '
}

# check_count <label> <region> <noun> <expected word> — every spelled count of
# <noun> inside the region must be the re-derived one, and at least one must be
# stated. Every hit is ACCOUNTED FOR rather than looked up: a grep for the right
# number passes just as happily on a region carrying the right number AND the
# wrong one, which is the shape a bare must-exist check cannot see. The left
# boundary keeps `twenty-nine tracked files` from reading as `nine`.
check_count() {
    local label="$1" text="$2" noun="$3" want="$4"
    local hits wrong
    hits="$(grep -oiE "(^|[^A-Za-z-])($NUMWORDS) $noun" <<<"$text" \
        | tr 'A-Z' 'a-z' | sed -E 's/^[^a-z]+//' | sort -u)"
    if [ -z "$hits" ]; then
        bad "$label states no $noun count at all — re-derived: $want $noun"
        return
    fi
    wrong="$(grep -vxF "$want $noun" <<<"$hits" | tr '\n' ' ')"
    if [ -n "$wrong" ]; then
        bad "$label states ${wrong}— re-derived from this file: $want $noun"
    else
        ok "$label states $want $noun"
    fi
}

# Derivation A — the header's enumerated list, read from the leading comment
# block alone, which ends at the first line that is not a comment.
head_dec="$(awk '
    /^#/ { if ($0 ~ /^#   [0-9]+\. /) { n = $2; sub(/\.$/, "", n); print n }; next }
    { exit }' "$SELF" | sort -n)"
# Derivation B — the body banners that carry their own number back as a
# `(decision N)` suffix. Section 8 (the must-not-exist sweep) and section 9
# (this one) carry none, which is what keeps a bare banner count — a different
# question, answered too high — out of this one.
body_dec="$(awk '
    /^# [0-9]+\./ {
        n = $2; sub(/\.$/, "", n)
        if ($0 ~ ("\\(decision " n "[,)]")) print n
    }' "$SELF" | sort -n)"

n_head="$(grep -c . <<<"$head_dec")"
n_body="$(grep -c . <<<"$body_dec")"
head_flat="$(tr '\n' ' ' <<<"$head_dec")"
body_flat="$(tr '\n' ' ' <<<"$body_dec")"

# Vacuity first, in both directions: a derivation that matches nothing scores 0,
# agrees with nothing, and would otherwise let every count below pass silently.
if [ "$n_head" -gt 0 ]; then
    ok "the header enumerates $n_head decisions"
else
    bad "the header enumeration matched nothing — the counts below would re-derive 0 and pass vacuously"
fi
if [ "$n_body" -gt 0 ]; then
    ok "the decision-N discriminator matched $n_body section banners"
else
    bad "the decision-N discriminator matched no section banner — it re-derives 0 and passes every count vacuously"
fi
if [ "$head_dec" = "$body_dec" ]; then
    ok "both derivations name the same decisions"
else
    bad "header list [$head_flat] and section banners [$body_flat] disagree on which sections are decisions"
fi
# Guarded on a non-empty derivation: `numbered 1..0 with no gap` is an `ok`
# printed while measuring nothing, which this repo treats as worse than none.
if [ "$n_head" -gt 0 ]; then
    expected_dec="$(i=1; while [ "$i" -le "$n_head" ]; do printf '%s\n' "$i"; i=$((i + 1)); done)"
    if [ "$head_dec" = "$expected_dec" ]; then
        ok "the decisions are numbered 1..$n_head with no gap and no duplicate"
    else
        bad "the decision numbers are not 1..$n_head contiguous: [$head_flat]"
    fi
fi
n_dec="$n_head"

# The tracked-file count is the read set's own length, never a transcription.
n_files="${#READS[@]}"

# A document read WITHOUT joining READS is a document the count cannot see, and
# the read set is no longer `skills/` alone — #273 made `agents/` a member,
# which is the entry #276 anticipated. So the scan spans every shape it reads
# and compares against READS, not DOCS. It reads CODE LINES ONLY: a header
# comment citing a path it does not read is a cross-reference, not a read, and
# failing on one would push the next editor to "fix" it by inflating the count.
code_lines="$(grep -vE '^[[:space:]]*#' "$SELF")"
lits="$(grep -oE '(skills|agents|docs|scripts|references)/[A-Za-z0-9_./-]+\.(md|sh)|(CLAUDE|README)\.md' <<<"$code_lines" | sort -u)"
n_lits="$(grep -c . <<<"$lits")"
if [ "$n_lits" -ge "$n_files" ]; then
    ok "the path scan is live: $n_lits distinct tracked paths in this source, for $n_files reads"
else
    bad "the path scan found only $n_lits literals for $n_files reads — the scan is broken, not the source clean"
fi
stray=""
while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    known=0
    for d in "${READS[@]}"; do
        [ "$lit" = "$d" ] && known=1
    done
    [ "$known" -eq 1 ] || stray="$stray $lit"
done <<<"$lits"
if [ -n "$stray" ]; then
    bad "tracked path read outside the read set:$stray — join it to DOCS or COUNT_SITES so the count can see it"
else
    ok "every tracked path read by this source is a member of the read set"
fi

# The site list is a transcription too, so it is swept for rather than trusted:
# any tracked document carrying this gate's own summary phrase must be one of
# the sites checked below. One awk pass, flattening per file as it goes, so a
# wrapped or bolded restatement in a fourth file cannot hide from it.
sweep_phrase="decisions settled about the review gate"
# Regular, non-symlink files handed to awk directly, never raw git pathspec
# output: `skills/github-issues/scripts/verify-issue-refs.sh` records the #263
# measurement that a tracked symlink to /dev/zero satisfies a readability test
# and awk reading it never returns, which in a required gate is a hang with no
# diagnostic — the worst shape CI has.
sweep_files=()
while IFS= read -r -d '' f; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then sweep_files+=("$f"); fi
done < <(git ls-files -z '*.md' '*.sh')
sweep_hits=""
if [ "${#sweep_files[@]}" -gt 0 ]; then
    sweep_hits="$(awk -v phrase="$sweep_phrase" '
        /sweep_phrase=/ { next }
        { s = $0
          sub(/^[[:space:]]*(> ?)+/, "", s); sub(/^[[:space:]]*#[ ]?/, "", s)
          gsub(/\*/, "", s)
          buf[FILENAME] = buf[FILENAME] " " s }
        END { for (f in buf) { t = tolower(buf[f]); gsub(/  +/, " ", t)
                               if (index(t, phrase)) print f } }' "${sweep_files[@]}" | sort)"
fi
# The line DEFINING the phrase is skipped, and that skip is what keeps this
# file's own membership honest: without it the sweep matched its own assignment,
# so this file was found whatever the marker-stripping did — a mutation
# neutering that stripping was measured UNDETECTED. With the skip, this file
# matches only through its header prose, where the phrase wraps across two
# comment lines and only the stripping can join it.
#
# The floor is set EQUALITY against COUNT_SITES, not "no extras". Every one of
# the checked sites carries the phrase today, so a sweep that finds NOTHING — a
# reworded phrase, a pathspec matching nothing, an awk that never ran — is the
# vacuous green this whole section exists to refuse, and a no-extras test
# reports it as success. Both directions are named, since a site that stopped
# carrying the phrase and a file that started are different defects.
sweep_expected="$(printf '%s\n' "${COUNT_SITES[@]}" | sort)"
if [ "$sweep_hits" = "$sweep_expected" ]; then
    ok "the site sweep finds exactly the $(grep -c . <<<"$sweep_expected") checked sites, across ${#sweep_files[@]} tracked files"
else
    bad "the site sweep found [$(tr '\n' ' ' <<<"$sweep_hits")] but the checked sites are [$(tr '\n' ' ' <<<"$sweep_expected")] — a file restating the phrase must join COUNT_SITES, and a sweep finding nothing is measuring nothing"
fi

dec_word="$(num_word "$n_dec")"
file_word="$(num_word "$n_files")"

# The three windows are located unconditionally: a ceiling failure below must
# cost one assertion, not nine, and the locators are what say WHERE a later
# rewording moved a site to.
self_head="$(normalize_region "$(awk '/^#/{print; next} {exit}' "$SELF")")"
assert_in "$self_head" "$sweep_phrase" \
    "this file's header carries the phrase the site sweep keys on"

# preflight's gate entry, anchored on the SCRIPT NAME and never on the gate
# number, which is unverifiable where it is written — measured, the bullet in
# test-sentry-verification.sh cited a number this gate has never had. Bounded
# by the next gate's banner or by the end of the comment block, whichever comes
# first, so being the last gate in the list does not run the window into code.
n_pf_entry="$(grep -cE '^#[ ]+[0-9]+\. .*test-review-gate-decisions\.sh' "$PREFLIGHT")"
if [ "$n_pf_entry" -eq 1 ]; then
    ok "preflight's gate list introduces this gate exactly once"
else
    bad "preflight's gate list introduces this gate $n_pf_entry times — the window cannot be anchored"
fi
pf_region="$(normalize_region "$(awk '
    /^#[ ]+[0-9]+\. / { if (f) exit; if (index($0, "test-review-gate-decisions.sh")) f = 1 }
    !/^#/ { if (f) exit }
    f { print }' "$PREFLIGHT")")"
# Every entry in that list introduces its gate as an open paren before the
# script path, so a window holding more than one has overrun — the same guard
# the CLAUDE.md window carries, and an asymmetry that would otherwise read as
# deliberate. It fires if preflight's next banner ever stops matching.
n_pf_intro="$(grep -oF -- '(scripts/test-' <<<"$pf_region" | grep -c .)"
if [ "$n_pf_intro" -eq 1 ]; then
    ok "preflight window stops before the next gate is introduced"
else
    bad "preflight window holds $n_pf_intro gate introductions — it has overrun its entry"
fi

# CLAUDE.md's gate description. One enormous line, so the window is cut in awk
# rather than by prefix-stripping a 96KB string, which costs seconds. It is
# anchored on the INTRODUCTION form — an open paren before the backticked path
# — so a later cross-reference to this gate elsewhere in the file cannot
# relocate the window, and the anchor must be unique. The window ends at this
# gate's own no-network terminator; losing that runs it into the next gate,
# which the overrun guard below catches.
claude_anchor='(`scripts/test-review-gate-decisions.sh'
n_claude_anchor="$(grep -oF -- "$claude_anchor" "$CLAUDEMD" | grep -c .)"
if [ "$n_claude_anchor" -eq 1 ]; then
    ok "CLAUDE.md introduces this gate exactly once"
else
    bad "CLAUDE.md introduces this gate $n_claude_anchor times — the window cannot be anchored"
fi
claude_region="$(normalize_region "$(awk -v a="$claude_anchor" -v t="no network)" '
    { i = index($0, a)
      if (i > 0) {
          rest = substr($0, i + length(a))
          j = index(rest, t)
          if (j > 0) print substr(rest, 1, j - 1)
          exit
      } }' "$CLAUDEMD")")"
if [ -n "$claude_region" ]; then
    ok "located CLAUDE.md's gate description, bounded at its own terminator"
    # A terminator that merely MOVED is the mis-scoping boundedness cannot see:
    # the window then runs to the next gate's terminator and measures that
    # gate's counts. Every gate in that sentence is introduced as an open paren
    # before its script path, so a window holding one has overrun.
    assert_not_in "$claude_region" '\(`scripts/' \
        "CLAUDE.md window stops before the next gate is introduced"
else
    bad "CLAUDE.md's gate description did not resolve: either its no-network terminator is gone, or the description now spans more than one line and the cut is line-scoped"
fi

if [ -z "$dec_word" ] || [ -z "$file_word" ]; then
    bad "no spelled form for $n_dec decisions / $n_files tracked files — extend NUM_WORDS; a digit restatement is invisible to the scan and cannot stand in"
else
    check_count "this file's header" "$self_head" "decisions" "$dec_word"
    check_count "this file's header" "$self_head" "tracked files" "$file_word"
    check_count "preflight's gate entry" "$pf_region" "decisions" "$dec_word"
    check_count "preflight's gate entry" "$pf_region" "tracked files" "$file_word"
    check_count "CLAUDE.md's gate description" "$claude_region" "decisions" "$dec_word"
    check_count "CLAUDE.md's gate description" "$claude_region" "tracked files" "$file_word"
fi

if [ "$fails" -ne 0 ]; then
    echo "test-review-gate-decisions: FAILED ($fails)" >&2
    exit 1
fi
echo "review-gate decision tests: all green"
