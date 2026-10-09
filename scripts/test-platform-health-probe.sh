#!/usr/bin/env bash
# test-platform-health-probe.sh — pr-shepherd's degradation probe returns FOUR
# distinct verdicts, and never gates anything (issue #285).
#
# WHY THIS EXISTS. The workflow skills could not distinguish "GitHub told me the
# truth" from "GitHub told me a DEGRADED truth". A hard `gh` error is handled
# everywhere; a call that exits 0 carrying incomplete data is read as live
# state. Measured 2026-08-26 on this repo's PR #283 during a platform outage:
# `gh pr view --json statusCheckRollup` exited 0 with two entries and no `ci`,
# no `CI` run existed for that head across ~40 minutes while two prior heads on
# the same branch each had one within minutes, and later `ci` appeared in the
# rollup with an EMPTY state and still no run behind it. Nothing errored; three
# hypotheses were produced and all three were wrong.
#
# WHAT MAKES IT WORTH A GATE. Every way of getting this wrong is silent, and
# they come in opposite pairs:
#
#   * Collapse a verdict toward `healthy` and the probe becomes WORSE than not
#     having one — it converts an unknown into a confident wrong answer, which
#     is this repo's dominant bug class. A green status page lags real
#     degradation by minutes to tens of minutes, so it can never be evidence of
#     health; an unreachable one certainly cannot.
#   * Let the verdict reach a DECISION and a platform outage starts changing
#     what the loop does, not just what it says. #285 is explicit that this is a
#     diagnostic: a PR missing a required check is held either way, and the hold
#     was already correct — the attribution was what was missing.
#   * Over-attribute, and the probe invents an EXCUSE for a real failure. That
#     is the same confident wrong answer pointed the other way, and it has its
#     own cases here (an irrelevant status component; an incident beside a clean
#     first-party read).
#
# THE FOUR VERDICTS ARE THE DESIGN. `healthy`, `degraded (attributed)`,
# `degraded (unattributed)` and `unknown` must stay four distinct answers, and
# both collapse directions are mutation-proved. Row 3 of the probe's table — a
# first-party anomaly beside an UNREADABLE status page — resolves to
# `degraded (unattributed)` rather than `unknown`, because the degradation was
# measured first-party and only the attribution is missing. That is deliberate
# and is pinned, alongside rows 6/8/9 which pin the other half of the same rule:
# an unreachable endpoint never manufactures a `healthy` and never manufactures
# a `degraded` on its own. Read those assertions together before "aligning"
# either one. EVERY row of the nine-row table has at least one case.
#
# THE TWO DOORS INTO `healthy`, BOTH GUARDED. The status-page door is the
# obvious one. The FIRST-PARTY door is the one an earlier edition left open: a
# single-commit PR branch has no prior head, so the run comparison had no
# baseline, found nothing, and reported `clean` -> `healthy` on a branch whose
# CI had never started — #285 one step earlier, on the dominant branch shape in
# this org. `clean` now requires that at least one first-party check actually
# RAN, and both the case and its mutation are here.
#
# FOUR SCOPING DECISIONS, each measured rather than assumed:
#
#   1. NEVER-A-GATE IS ASSERTED STRUCTURALLY, TWICE, because prose alone cannot
#      hold it. (a) Every verdict exits 0, so no `set -e`/`&&`/`if` can turn one
#      into a gate — the deliberate asymmetry with stack-probe.sh, whose exit
#      codes ARE a gate because gating is its job. (b) No sibling pr-shepherd
#      script and no OTHER skill doc names the probe at all, over a sibling
#      list held as an EQUALITY against `git ls-files` and a docs corpus that
#      is EVERY tracked `.md` under `skills/`, at any depth, minus the two
#      section-scoped files of decision 2 — so neither a new
#      script nor a new reference doc can ship unscanned. The docs half was a
#      hand-picked subset until #302: `skills/pr-shepherd/SKILL.md` was in no
#      corpus at all, and gates 32/33 had already recorded that the SUBSET is
#      the defect, not the choice of subset. Both halves are mutation-proved,
#      (b) by wiring the probe into merge-shepherd.sh and into pr-shepherd's
#      own §4.
#   2. THE SKILL.md CHECK IS SECTION-SCOPED, not file-scoped, AND THE SECTION
#      LIST IS AN EQUALITY over the file's own headings. A whole-file grep for
#      the probe's name is satisfied by its own §2b and by the bundled-script
#      table, so it would report a probe wired into the MERGE section as
#      clean; a by-name list of decision sections (§1, §1b, §3 — the earlier
#      edition) reports a probe wired into §2 or §4 as clean, and a hold rule
#      written into §4 Teardown was measured green. So every heading in
#      pr-shepherd's SKILL.md is enumerated by ordinal and scanned for the
#      filename AND the verdict vocabulary unless it is one of exactly two
#      carve-outs — §2b, pinned by canon in 22, and the script table, asserted
#      in 20 to name the probe — each asserted to exist exactly once so a
#      rename cannot retire it. Guardrails is NOT a carve-out: its one
#      legitimate mention is the canon-pinned never-a-gate bullet, stripped
#      before the scan so the rest of the list, where a gating exception gets
#      written, is held to the rule. dispatch-ready's SKILL.md is scanned the
#      same way with DRAIN DEGRADED as its one carve-out (#286). Mutation-
#      proved three ways: a mention in §3 (M17), the measured §4 hold rule
#      (M31), and a gating bullet appended beside the canon one (M32).
#   3. THE RUN COMPARISON IS RUN-TO-RUN, NOT ROLLUP-TO-RUN. `statusCheckRollup`
#      names checks (for Actions, JOB names) and `actions/runs` names WORKFLOWS;
#      differencing the two namespaces reports a missing check for every workflow
#      whose job names differ from its own name, on a healthy repo. The healthy
#      fixture's rollup names deliberately match no workflow name, so a fixture
#      where they lined up would make that case vacuous. The probe's derivation
#      jq is no longer even HANDED the rollup, which is the structural half.
#   4. THE BASELINE IS AN INTERSECTION AND THE EVENTS ARE WHITELISTED, both to
#      stop ordinary absence reading as degradation: a `paths:` filter, an `if:`,
#      a renamed workflow, or a one-off `workflow_dispatch` on a prior head. Each
#      has a case and a mutation, because the union reading and the
#      no-whitelist reading are both what a later simplification produces.
#
# THE AGE FLOOR IS CONTRACT, not an optimisation, and its SCOPE is contract too.
# A workflow that has not started yet is not missing, so the run-comparison
# signals are age-suppressed. The empty-state signal is NOT: it is a direct read
# of the rollup, and it is also the one signal that must survive the
# `actions/runs` call failing, since an outage degrades both calls together.
# Both halves have cases; suppressing the empty-state signal is mutated.
#
# A gh TRANSPORT FAILURE IS `not_measured`, NEVER AN ANOMALY, and that is a
# deliberate reading of #285 rather than a slip — see the probe's header. An
# expired token, a rate limit or a closed laptop is not platform degradation,
# and reporting one as such is the confident wrong answer this file exists to
# refuse. Cased and mutated in both directions.
#
# TWO WAYS THE PROBE CAN FAIL WITHOUT PRODUCING A WRONG VERDICT (issue #303),
# and both are cased here because both are SILENT — the class this whole file
# exists for, arriving through the probe's own machinery instead of through its
# reasoning.
#
#   * AN EMITTER THAT DIES HANDS THE CALLER EXIT 0 AND EMPTY STDOUT. The final
#     `jq -n` ran with no handler under a script with no `set -e` and an
#     unconditional `exit 0`, so `jq -r .verdict` yielded the EMPTY STRING —
#     not one of the four verdicts and not `unknown` either — while the stderr
#     summary still printed and looked entirely normal. The handler is now
#     mutation-proved by M25, which breaks the emitter (`--argjson anomalies ""`
#     exits 2 and prints nothing) and requires `unknown` back. Delete the
#     fallback and M25 reports the mutant as `«no output»`: UNDETECTED, red.
#     Its exit code is asserted too, by the rule below. THE FALLBACK IS FOUR
#     KEYS, and M25 asserts exactly those with the reason and the explains
#     canon: the first edition was a 16-key literal mirroring the emitter — a
#     second copy of the schema held in step by nothing, and renaming a key in
#     it was measured green (#302). It was THREE keys until #314, and the
#     fourth is `pr`, admitted under a narrower rule than the one it relaxes —
#     carry nothing that could be what broke the emitter — which `pr` alone
#     satisfies because it is validated as digits with no leading zero and is
#     therefore a bare JSON number by construction. Case 18 pins that premise
#     (`--pr 007` is refused), and it is the whole argument: relax the
#     validation and this literal stops being JSON on the one path that exists
#     to answer a run that produced none. The ledgers stay `--argjson` ON
#     PURPOSE, and M29 pins that: an empty `$ANOMALIES` already reads as zero
#     anomalies at the verdict, so an emitter that cannot fail on its inputs
#     (`--arg` plus `try fromjson catch []`) emits `healthy` beside an empty
#     list. The emitter dying is the fail-closed door, and M29 corrupts the
#     ledger and requires the fallback back.
#     THE STDERR LINE NAMES WHICH INPUT BROKE IT, and that is asserted rather
#     than assumed (#314). This failure is unreproducible after the fact — the
#     ledgers die with the process — so that line is the entire forensic
#     record, and it named the exit code alone. Every `fallback` mutant now
#     requires both ledgers reported with their byte lengths, and the
#     `fallback:<LEDGER>` form requires the named one reported as FAILED:
#     M29 corrupts `$ANOMALIES` and 27c reaches the same state through the
#     argv cap, while M25 is the contrasting shape where both ledgers parse
#     and the emitter itself is what died. Those two stories call for
#     different fixes and `jq exited 2` cannot tell them apart.
#   * A BOUND ON THE OPTIONAL CALL AND NONE ON THE LOAD-BEARING ONES. The
#     attribution fetch — the half the probe's header calls never load-bearing —
#     carried `--max-time`, while `gh pr view`, the commit read and the runs
#     read carried nothing, in a script whose entire trigger condition is
#     "GitHub may be degraded right now". Case 17b asserts all three run under
#     `PLATFORM_GH_TIMEOUT`, over the SHIM's ledger and never over MOCK_CALLS,
#     because the mock `gh` sees an identical argv either way — which is exactly
#     why nothing caught this. Case 17c asserts that a bound which FIRES lands
#     where every other non-zero gh exit lands: `not_measured`, reason
#     preserved, and NO anomaly — AT EVERY SITE. An empty `gh.timeout` fires
#     on the first bounded call, which absorbs it, so an edition of 17c
#     covered `gh pr view` alone while the commit and runs sites could report
#     their own cutoff as an anomaly with the gate green (measured, #302). The
#     shim now takes a selector; 17c loops over the three sites and asserts
#     the detail names the one under test. There is no fourth site any more —
#     see the repo-derivation paragraph. Reporting
#     our own cutoff as first-party evidence of degradation is the confident
#     wrong answer reached through the mitigation for a different one, so it
#     has its own mutant PER SITE (M9d, M9e, M9f) beside the
#     transport-failure one it mirrors — M9e and M9f in the exact shape that
#     keeps recording an error on every OTHER non-zero exit, so no
#     plain-failure case can see them.
#     17c also asserts that the fired bound reaches `explains` and the stderr
#     summary, not `probe_errors[].detail` alone — see the explains paragraph.
#
# BOUNDING A CALL CAN CREATE A NEW WRONG ANSWER, AND THE ANSWER TO THAT WAS TO
# STOP MAKING THE CALL (issue #314). The cwd repo lookup was `gh repo view`,
# ending in `|| true`, which discards the status — harmless while the call could
# only fail by erroring, and a lie the moment a bound could fire: 124 became
# indistinguishable from an empty result and was reported as `not in a GitHub
# repo and --repo not given`, exit 1 with empty stdout, INSIDE A VALID CHECKOUT.
# #312 taught the site 124 and 137 and left every OTHER non-zero exit — a 5xx,
# an expired token, a dead link — producing that same false cause, which is the
# whole class rather than two codes of it. The site was answering a LOCAL
# question through a REMOTE call, in the one script whose trigger condition is
# "GitHub may be failing right now", so it is now `git rev-parse` plus
# `git remote get-url origin` and the bounded `gh` sites are three.
#   17d is what that costs and what it buys. The cwd became an INPUT — the
#   derivation reads the working directory, not an argument — so the runner
#   grew `CWD_OVERRIDE` and this file builds real one-commit-less git repos
#   under `$WORK`: three URL forms git actually writes, a fourth carrying a
#   trailing slash, one with no `origin`, one with an unparsable remote, one
#   naming a DIFFERENT host in the path (`https://evil.example/path@github.com/
#   o/n`), one with THREE path segments, one carrying a character outside the
#   allowed set, one on ANOTHER FORGE (`https://gitlab.com/o/n`), one with an
#   EMPTY OWNER (`https://github.com//n`), one with a SINGLE segment
#   (`https://github.com/n`), a `.git` FILE pointing nowhere, a BARE REPOSITORY
#   (the one branch `rev-parse` separates by printing `false`), and a plain
#   directory outside any work tree (asserted to BE outside one, since a
#   `$TMPDIR` inside a checkout would make that case measure the opposite
#   branch).
#   SOME OF THEM PIN THE PARSER'S OWN STRICTNESS. NO COUNT HERE, DELIBERATELY:
#   four successive editions of this sentence carried one and every one was
#   wrong, most recently "SEVEN" over a list of eight. A count is a second
#   thing to keep in sync with the list beside it, and it is the half that rots
#   silently. Each name below says which loop it lives in, which is checkable
#   against the `for` statements rather than against this prose:
#     REFUSAL grounds, in the failure-shape loop — `badurl`, `hostpath`,
#       `threeseg`, `badchar`, `otherhost`, `emptyseg`, `oneseg`. Each must
#       yield exit 0, a verdict, and `repo_lookup_failed` — `badurl` included;
#       it satisfies THIS heading fully. What it excepts is the claim above
#       that these fixtures PIN the parser's strictness: rule (1) is MASKED, so
#       reverting it reddens nothing. It earns its place as the only fixture
#       reaching the credential-leak assertion — which covers ONE refusal
#       branch, not all of them.
#     A TRANSFORMATION, in the SUCCESS loop — `trailing`. It belongs there and
#       not here: the bug it pins is a WORKING remote being refused, so its
#       assertion is a correct `.repo`, not a refusal. Do not "align" it into
#       the failure list.
#   (Fixture insertion breaking this paragraph is not hypothetical; it has
#   happened THREE times, each time in the commit that added the fixtures:
#   `ed66e95` added `threeseg` and `badchar` without adding them to the
#   enumeration above; `7ed60c6` did the same with `otherhost` and `emptyseg`,
#   in the very paragraph recording the first occurrence; and `17cb16b` fixed
#   the enumeration while leaving the prose comment at the fixtures themselves
#   claiming "there are SIX". Adding a fixture means editing every site below —
#   no count, for the same reason the rule list carries none, and because the
#   edition that first wrote this list said FIVE while naming a sixth in its
#   own next sentence:
#     the `CWD_*` declaration · the `make_cwd` call · the header enumeration
#     above · the per-loop list below · the prose comment beside the fixtures ·
#     the built-message `ok` line · the `url_pin_bad` loop · whichever of the
#     two verdict loops it belongs to · bullet (7)'s two SPANNING exclusion
#     measurements, the scheme strip (probe:567) and the `github.com/` prefix
#     strip (:580), whose red counts move when a fixture lands in a family
#     they cross.
#   Bullet (7)'s THIRD exclusion measurement is not on that list and must not
#   be added to it: the scp normalization (:577) names `[ssh]` alone
#   (measured: 3 red, all on `[ssh]`), so it moves only for another
#   `git@github.com:` fixture.
#   THE LIST IS UNCHANGED BY #324 AND MUST STAY THAT WAY. Three of its members
#   — the built-message `ok` line, the `url_pin_bad` loop and the verdict loops
#   — are now checked mechanically (paragraph below), and the temptation is to
#   strike them from a list of things a human must remember. Do not: the list
#   is what a fixture insertion TOUCHES, never what CI catches, and the two
#   history says are ALWAYS missed sit in the half that is still prose. Which
#   half a member is in is stated below, once, rather than annotated here.
#   The built-message, the loops and the `url_pin_bad` read-back were never
#   the ones missed across the three rounds enumerated above — `ed66e95`,
#   `7ed60c6`, `17cb16b` — guard or no guard; the enumeration and the prose
#   comment always were, and still can be. The count is spelled with its
#   members beside it because an earlier revision said FOUR here with nothing
#   above enumerating four, in the one paragraph that explicitly refuses bare
#   counts. A four-round list does appear further down, under WHAT SHIPPED
#   UNCASED, but it counts CASING rounds — a different set. Cited by heading
#   rather than by offset: issue #324 records line refs in this file going
#   +10 stale within a day, and this very paragraph's own citation did.)
#   WHAT SHIPPED UNCASED. This sentence has now been wrong FOUR times, and NOT
#   all the same way — the shas and per-edition causes are below, because the
#   edition that wrote "each time by asserting a closed set nobody had
#   enumerated against the code" was itself wrong about its own fourth member.
#   DO NOT SHORTEN THAT QUOTATION. All four editions DID name members —
#   `ed66e95` in the red-set bullets under "refuses on four grounds",
#   `66e0147` inline, `7ed60c6` and `17cb16b` as explicit lists — so a form of
#   it ending at "enumerated" is false of ALL FOUR it indicts. The
#   three words "against the code" carry the whole claim: the split is WHERE
#   the members came from. The first three read them off recall rather than
#   off every `return 0`, so each came up short — the same defect the "first
#   three were SHORT" sentence below records, not a second one. The fourth
#   derived (1)-(6) off the source correctly and then mis-described the list
#   it had derived; that failure is spelled out below too.
#   It is written as a LIST rather than a count. Bullets (1)-(6) are DERIVED —
#   they are the `return 0` statements in `repo_from_remote`, read off the
#   source, not recalled from which ones have fixtures. Bullet (7) is NOT one
#   of them and is listed anyway: it is where the rewrites go, and it is here
#   because both of its members shipped uncased. Say that plainly rather than
#   implying one criterion produced the whole list — an earlier edition did
#   imply it, and used it to justify an exclusion it cannot actually justify.
#   The rules its own comments call load-bearing:
#     REFUSAL grounds        (1) an unrecognised URL form (the scheme `*)` arm)
#                            (2) a host that is not exactly `github.com`
#                            (3) the empty/leading segment arm `""|/*|*/`
#                            (4) NOT three-or-more segments, `*/*/*`
#                            (5) the segment-case `*)` fallback — anything that
#                                is not `owner/name` at all, e.g. ONE segment
#                            (6) the character set `*[!A-Za-z0-9._/-]*`
#     TRANSFORMATIONS        (7) the authority-only userinfo strip, and the
#                                trailing-slash-before-`.git` order — two
#                                rewrites, cased together as one bullet below.
#                                Other rewrites exist and are NOT here, each
#                                with its own measurement rather than an
#                                assertion — the scheme strip `${u#*://}`
#                                (probe:567) -> 9 red on `[https]`,
#                                `[sshproto]`, `[trailing]`; the scp
#                                normalization (:577) -> 3 red on `[ssh]`; the
#                                `github.com/` prefix strip (:580) -> 17 red,
#                                whose split matters: 12 across `[ssh]`,
#                                `[https]`, `[sshproto]`, `[trailing]` failing
#                                to derive, plus 5 on `[oneseg]` failing the
#                                OTHER way — deriving the wrong slug
#                                `github.com/mock-repo` and reporting verdict
#                                `healthy`, the outcome this header exists to
#                                refuse. TWO of these three span fixtures
#                                rather than naming one each — the scheme
#                                strip and the prefix strip — so a fixture
#                                landing in a family they cross moves them.
#                                The scp figure does NOT: it names `[ssh]`
#                                alone, like every count below, and moves only
#                                for another `git@github.com:` fixture.
#                                The criterion is NOT "refusal grounds":
#                                :577 and (7)'s userinfo strip are
#                                SIBLING ARMS OF ONE `case`, so that would not
#                                separate them. Nor does coverage — (7)'s
#                                rewrites are covered too. It is HISTORY: all
#                                three excluded rewrites were already cased at
#                                `f38f501` by the `[ssh]`/`[https]`/
#                                `[sshproto]` fixtures — the scheme strip in
#                                its two-arm predecessor form, `${u#https://}`
#                                / `${u#ssh://}` (`f38f501:553-554`), not the
#                                `${u#*://}` it is today — while (7)'s two
#                                were uncased until `2d40389`, which is why
#                                only those two are recorded here.
#   (1) is present as a fixture (`CWD_BADURL`, from the parser's first commit
#   `f38f501`) but is NOT independently mutation-detectable: deleting the
#   scheme `*)` arm also runs this gate to `all pass`, because `p` stays empty
#   and (2) refuses instead. It is masked, not uncased — say so rather than
#   letting the next round read it as a fourth wrong claim.
#   Every other rule shipped with no case at all, each found only by deleting
#   it and watching this gate stay green: (4) and (6) at `2d40389`
#   (`all pass`, 376); (2) and (3) at `ed66e95` (`all pass`, 390); (5) at
#   `7ed60c6` (`all pass`, 404).
#   FOUR prior editions of this sentence carried a count, derived by `git show`
#   rather than recalled: `ed66e95` "refuses on four grounds", `66e0147`
#   "carries four rules", `7ed60c6` "carries SIX rules", `17cb16b`/`7ed02bf`
#   "carries SEVEN rules". The first three were SHORT. The fourth was neither
#   short nor long in the same way, and saying "LONG" mischaracterised it:
#   `17cb16b` derived bullets (1)-(6) CORRECTLY — they are the six `return 0`
#   sites, read off the source, and this file's (1)-(6) are still that
#   derivation. Its defect was a COUNT-VS-DERIVATION MISMATCH: it wrote
#   "DERIVED by enumerating every `return 0`" of a list it then called
#   "carries SEVEN rules" — quoted as two clauses because intervening prose
#   separates them, and both are verbatim — when bullet (7) is a
#   transformations entry and not a `return 0` at all. So do not read (1)-(6)
#   as first written here — they were already right.
#   THE EDITION THAT WROTE "two prior editions" IS WHY THIS ONE CITES SHAS. It
#   dropped `66e0147`, and dropped its own predecessor's "SEVEN" — the entry
#   the round before had just disproved — because the qualifier "both were
#   short" excluded the long one silently. It did that on a review nit that was
#   itself wrong: the nit said an earlier tally had a false member, when that
#   tally's membership was right and only its ORDER was wrong. A correction was
#   applied without being re-derived, in the one paragraph of this file whose
#   whole subject is claims nobody re-derived.
#   AS OF `1e7b085` — the first edition carrying the userinfo strip and the
#   slash order at all; NOT `f38f501`, which predates both — reverting any one
#   of the four rules then cased ran this gate to `all pass (364 assertions)`,
#   exit 0. The anchor is load-bearing: by `2d40389` the two TRANSFORMATIONS
#   were cased, so reverting the userinfo strip THERE is 5 red, not a pass.
#   Every red set below was OBSERVED on the head that records it, not
#   predicted:
#     - userinfo stripped from the AUTHORITY alone, not `${p#*@}` over the whole
#       string -> reverting it goes 5 red on `hostpath`, and the one that
#       matters reads `.repo = mock-org/mock-repo`: a remote pointing at
#       `evil.example` resolving to a repo on THIS host, verdict `healthy`.
#     - the trailing slash stripped BEFORE `.git` -> reverting it goes 1 red on
#       `trailing`, reading `.repo = mock-org/mock-repo.git`. Note what that
#       measurement corrected: the parser comment used to say the other order
#       "fails the character check", and it does not — `.` is in the allowed set
#       and `o/n.git` is two clean segments, so the failure is a wrong slug that
#       404s every call under it, never a refusal.
#     - EXACTLY two segments (`*/*/*) return 0`) -> reverting it goes 5 red on
#       `threeseg`, reading `.repo = mock-org/mock-repo/extra`.
#     - the character set (`*[!A-Za-z0-9._/-]*`) -> reverting it goes 5 red on
#       `badchar`, reading `.repo = mock-org/mock~repo`. This is the one whose
#       absence was worst: the probe's comment calls the shape check spanning
#       BOTH it and the segment case "the sanitiser at this site", and `.repo`
#       is the one reported string whose ONLY guard is that check. Two others
#       skip `clean`: `.head` and `.merge_state`, each carrying its own `gsub`;
#       and `status_page_url`, which carries no sanitiser at all and is safe
#       for a different reason — it is operator-supplied, never fork-controlled.
#       So the file made a SECURITY claim about itself that no assertion
#       touched.
#     - the `github.com` host restriction (2) -> made permissive, 5 red on
#       `otherhost`, `.repo = mock-org/mock-repo` derived from a GITLAB remote.
#     - the empty/leading segment arm (3) -> deleted, 5 red on `emptyseg`,
#       `.repo = /mock-repo`.
#     - the segment-case `*)` fallback (5) -> deleted, 6 red on `oneseg`, and
#       the first of them is the one that matters: `a failed derivation exits
#       0` reads `exit 1, expected 0`, with `«no output»` for the verdict.
#       Not a wrong slug — no JSON at all.
#   THE STANDING RULE THIS COST US FOUR TIMES: a fixture family and a rule set
#   are not the same thing, and casing "the fix" means casing every rule the
#   fix introduced. Four rounds, each of which read as complete: `2d40389`
#   cased the two TRANSFORMATIONS — bullet (7), one entry, two rewrites;
#   `ed66e95` cased (4) and (6); `7ed60c6` cased (2) and (3); `17cb16b` cased
#   (5), alone. Every one was found by deleting a rule and watching the gate
#   stay green. Do that — delete each rule and observe — rather than reading
#   the diff and judging which look covered.
#
#   THE INVENTORY IS CHECKED MECHANICALLY NOW, AT THREE SITES AND NO MORE
#   (issue #324). Nine review rounds of prose did not hold the co-move list
#   above: three consecutive commits each added a fixture and missed at least
#   one site, and the paragraph recording those misses was itself one of the
#   sites missed, twice. So 17d derives the fixture set from the `CWD_*`
#   declarations — the one site a new fixture cannot skip — and requires each
#   member at the built-message `ok` line, at EXACTLY ONE of the two verdict
#   loops, and, for each fixture `make_cwd` hands an origin URL, in the
#   `url_pin_bad` read-back. What that cost, and the four things it must not
#   go back to being:
#     THE BUILT MESSAGE LOST ITS SECOND VOCABULARY. It named the same fourteen
#       fixtures in prose (`ssh://`, `no-origin`, `unparsable`,
#       `host-in-path`), and no mechanical rule maps `CWD_BADURL` to
#       "unparsable" — that second vocabulary is precisely why this site could
#       not be checked against any other. It names them by the tokens every
#       other site already uses. The prose is not lost; it is the comment
#       beside each fixture, which is where it belongs.
#     `badurl` JOINED THE READ-BACK LOOP, and the reason is narrower than the
#       one first written here. IT IS NOT that the credential-leak assertion
#       was vacuous: the hermetic pins — `GIT_CONFIG_GLOBAL=/dev/null` plus
#       `GIT_CONFIG_NOSYSTEM=1` — already sit at every site that reads a
#       fixture and cover every config layer an `insteadOf` can inhabit, and
#       this change touched none of them. Say that plainly, because the wrong
#       version of this sentence credits the READ-BACK with protection the PINS
#       provide, and the next editor then reads `run_probe`'s pin as redundant
#       — the one deletion that would make the leak assertion genuinely
#       vacuous, and the one the read-back cannot see, since it measures its
#       own subshell. The read-back is what PROVES the pins bind; `badurl` was
#       the one fixture with an origin URL outside it, and its literal is the
#       one the leak assertion depends on. Defence in depth, and the pins are
#       now a checked site of their own.
#     THE EXEMPTIONS ARE BY NAME, NOT BY SILENCE. `CWD_MISSING` must exist as
#       its own declaration and must NOT be a `"$WORK/` fixture; `CWD_NOREPO`
#       must be declared and must still be reached by the failure loop as
#       `notree`, which is the token its exemption is FROM — so exempting it
#       from the naming rule cannot quietly become exempting it from coverage.
#       Renaming either is red twice: the exemption stops resolving, and the
#       new name arrives as a fixture placed nowhere.
#     THE EXTRACTION LAYER IS THE PART THAT CAN UNDER-MEASURE, and every way it
#       does is this file's own defect one level up — a reassuring `ok` for a
#       fixture nobody checked. The first review of this block found six such
#       escapes, enumerated with their measurements below: five that were
#       SILENT GREENS and one that misdiagnosed instead. The answers are in the
#       block itself and are structural
#       rather than careful: continuations are joined before anything is read
#       (the wrapped `make_cwd` shape already exists in this file); the
#       declaration read allows leading whitespace and requires a `"$WORK/`
#       value; the set is cross-checked BOTH WAYS against the `CWD_MISSING`
#       ledger, which is a second derivation and not a second copy; the four
#       single-line sites are asserted to have matched EXACTLY ONE line and
#       are newline-normalised; and `SELF_ABS`'s placement before the
#       `cd "$REPO_ROOT"` is asserted at source, because preflight runs this
#       gate FROM the repo root, where the broken placement resolves fine — so
#       CI cannot see that regression at all, and it is the exact one #324
#       records as the reason a first attempt was reverted.
#   EVERY RED SET BELOW WAS OBSERVED, AND SO WAS EVERY "(was green)" — the
#   prior state is not recalled from a review comment, it is the same mutant
#   re-run against `1461b73`, the edition this one replaces, which reports
#   `all pass (416 assertions)` where it says so. Do the same rather than
#   reasoning about which reads look robust; four of these were argued safe and
#   were not.
#     - `badchar` dropped from the built message -> 1 red, site 1 of 3, naming
#       the fixture.
#     - `oneseg` dropped from the failure verdict loop -> 2 red: site 2 of 3
#       reading `[oneseg: in 0 of the 2 verdict loops]`, plus the assertion
#       equality at the bottom (a short count against the expected total; the
#       figures move with every case this file adds, so read them from the run
#       rather than from here).
#     - `emptyseg` dropped from the `url_pin_bad` loop -> 1 red, site 3 of 3.
#     - a fixture DECLARED and placed nowhere (`CWD_NEWFORM` plus its
#       `make_cwd` call, which is the historical shape) -> 3 red, one per
#       site, each naming `newform`.
#     - `CWD_NOREPO` renamed to `CWD_NOTREE` -> 3 red: the ledger disagreement,
#       the exemption no longer resolving, and `notree` missing from the built
#       message.
#     - `CWD_ONESEG` INDENTED by four spaces — still valid bash — with `oneseg`
#       dropped from the built message -> 1 red, site 1 of 3.
#       WAS GREEN: `all pass (416)`. The column-anchored read lost the fixture
#       entirely, so it was required at ZERO sites and four `ok` lines printed.
#     - `hostpath`'s `make_cwd` URL WRAPPED onto a continuation line, with
#       `hostpath` dropped from the read-back -> 1 red, site 3 of 3.
#       WAS GREEN: `all pass (416)`, printing `and every fixture given an
#       origin URL is read back in the url_pin_bad loop`.
#     - `run_probe`'s hermetic pins deleted -> 1 red, `run_probe: no
#       GIT_CONFIG_GLOBAL pin`.
#       WAS GREEN: `all pass (416)`. Nothing read those pins at all.
#     - `SELF_ABS` moved BELOW the `cd`, run FROM THE REPO ROOT — which is
#       preflight's own invocation -> 1 red naming both line numbers. From
#       `scripts/` the same mutant exits 1 at the precondition instead.
#       WAS GREEN: `all pass (416)` from the root, which is why CI could not
#       have caught it; it breaks only for a contributor running the gate from
#       `scripts/`, and it is the exact regression #324 records as the reason a
#       first attempt was reverted.
#     - a read-back token with NO case arm, placed MID-LIST (`zombie` after
#       `badurl`) -> named by the `*)` arm.
#       WAS GREEN: `all pass (416)` — the previous iteration's `pin_dir` and
#       `pin_want` were still set, so the token re-measured the PREVIOUS
#       fixture and `set -u` never saw it. First in the list it aborted on an
#       unbound variable instead, which is why the position is recorded.
#     - a SECOND column-0 `for form in …; do` -> 1 red, the success verdict
#       loop reading 2 lines, in both placements (before and after the real
#       loop).
#       WAS NOT GREEN, AND SAY SO: on `1461b73` the same mutant reported
#       `[ssh: in 0 of the 2 verdict loops]` — a FALSE RED against a fixture
#       plainly present, because the unnormalised capture left the token
#       newline-terminated. It is listed here with the escapes because it is
#       the same defect, but it misdiagnosed rather than passed, and calling it
#       an escape would be the fourth wrong claim in this header's history.
#       The false-GREEN direction is the same mechanism pointed the other way —
#       a token newline-terminated in ONE loop while genuinely in both reads as
#       "exactly one" — and it was not reproduced on that edition, because the
#       failure loop had no `*)` arm and aborted on an unbound variable first.
#       Recorded as unreproduced rather than asserted.
#   TWO MUTATIONS THAT MUST STAY GREEN, recorded because each looks like a
#   defect and is not: reordering the env prefixes so a `CWD_OVERRIDE=`
#   assignment lands at column 0 (the `"$WORK/` requirement is what stops a
#   phantom `override` fixture), and moving `BADURL_REMOTE`'s value (the
#   read-back's `pin_want` and the leak needle both derive from it, so the
#   coupling is real rather than three literals that happen to agree).
#
#   Running from `$REPO_ROOT` instead would derive whatever `origin` this
#   checkout has — a fork's slug on a fork PR, and this repo is PUBLIC — so an
#   equality there is vacuous or host-dependent. Each failure shape yields
#   exit 0, a verdict, and `first_party repo_lookup_failed` naming which
#   input broke; M9g is the mutation, turning that entry into an ANOMALY, which
#   would report a local fact about the operator's machine as evidence that
#   GitHub is degraded.
#   TWO MUST-NOT-EXIST HALVES, because either alone is weak. The mock `gh`'s
#   `repo` arm now FAILS LOUDLY rather than answering, so the call reddens
#   wherever it reappears; and 17d greps the call log for it by name, so the
#   failure says which regression rather than "unhandled invocation". `git` is
#   in the read-only corpus for the reason `gh repo view` used to be: a
#   `git fetch` or `git remote add` written into the derivation leaves no `gh`
#   line for case 17 to classify, and the two read subcommands are whitelisted
#   by their FULL form so a flag added to either is offending.
#   There were TWO wrong answers at that site, not one, and the second is now
#   unreachable rather than fixed: the status was tested AFTER the emptiness
#   check, so a call the bound cut off after `gh` had flushed a slug left a
#   real-looking fragment that passed the shape check. A local `git remote
#   get-url` cannot half-flush a slug to a bound that no longer exists, so the
#   `gh.timeout.late` shim arm that drove it is DELETED rather than kept — an
#   unreachable branch in a gate is the false impossibility this header calls
#   worse than a missing case.
# A fired bound is 124 OR 137: 137 is `timeout`'s
# kill-grace exit when `gh` ignored TERM — the very path `-k 5` exists for — so
# `bound_fired` accepts both, and 17c2 drives the 137 path at each of the three
# first-party sites through the same selector 17c uses — an edition of 17c2
# fired it at the first call alone, so a commit-site anomaly on 137 was green;
# M9h and M9i are the 137 siblings of M9e and M9f. An edition of the probe
# that tested `-eq 124` alone recognised the bound everywhere except there.
#
# THE WORST CASE IS A CONSTRAINT AND SECTION 23 RE-DERIVES IT (issue #314).
# Each bounded site can burn `PLATFORM_GH_TIMEOUT` plus the fixed kill grace and
# the `curl` runs after all of them, so the ceiling is
# `sites x (bound + grace) + status timeout`. At the previous 30s default with
# four sites that was 145s against the 120s default tool timeout of the harness
# the shipped callers run under — and a harness kill yields NO JSON AND NO
# STDERR, which is #303's shape one layer up and which the emitter fallback
# cannot answer because the script never reaches it. The default is 20s and the
# worst case 80s. Every term is READ FROM THE PROBE'S SOURCE and `sites` comes
# from 17b's MEASURED bound count, never from a transcription, so a fourth
# bounded call re-derives the sum instead of leaving a stale number in a
# comment; both the probe header and §2b are then required to state the same
# figure, because a ceiling nobody can read is one an operator raises by
# accident. `GH_TIMEOUT_PINNED` is the runner's single transcription of the
# bound, consumed by run_probe and by 17b's per-line check, and it tracks the
# SHIPPED default deliberately: pinning a value the probe never ships would
# measure a configuration nobody runs.
#
# THE UNMEASURED `unknown` CARRIES ITS REASON, AND THE CANON STOPS AT A MARKER.
# `unknown` spans "no `--pr` was given" and "GitHub hung for twenty seconds on
# `gh pr view`", and both rendered as one sentence in `explains` and in the
# stderr summary while the reason sat in `probe_errors[].detail`, which nothing
# renders (#314). The branch now appends `(not measured: <reason>; <details>)`,
# which is GENERATED text and cannot be a fixed checksum, so `explains_head`
# splits on that literal marker and the canon holds the sentence exactly as
# before. The suffix is asserted behaviourally instead — 17c requires the fired
# bound in it AND on stderr, 17d requires each derivation failure — and the
# interpolation is pinned at source in 23, since the canon can no longer see
# it. The residual gap is stated: a reword hidden AFTER the marker is unpinned,
# bounded only by the fact that nothing there is authored prose.
#
# THE BOUND HAS THREE BRANCHES AND ONLY ONE IS REACHABLE THROUGH $BIN, which is
# why 17e and 17f run under CURATED PATHS rather than a prepended shim
# directory. Do not delete them as redundant with the source-level assertions in
# section 23: those assertions exist because an earlier edition of this file
# declared these branches impossible to exercise, a claim that was simply false
# and that cost the file its only coverage of the `probe` scope. The scope is
# the point — `timeout_unavailable` must NOT make a run `not_measured`, or every
# host without coreutils reports `not_measured` on every run — and M27 mutates
# the filter that decides it, on the curated no-timeout PATH through the
# loop's PATH field, since no scenario on the shimmed PATH produces a
# `probe`-scoped entry at all. That filter counts by EXCLUSION now: naming
# `first_party` made the scope an open enum whose only reader failed OPEN, so a
# misspelt scope at a first-party site dropped out of the count and the run
# reached `healthy` with a failed read on the ledger (measured, #302). Section
# 23 holds every `add_error` site to the closed set, and M34 misspells one and
# requires both the census to flag it and the run to fail closed.
#   17e AND 17f ALSO BOUND THE STDERR WARNING, in opposite directions (#314).
#   The JSON ledger is not a channel a human reads: macOS ships no `timeout`, so
#   an operator running this by hand without coreutils saw `platform: healthy`
#   every time and learned the bound never applied on the day a `gh` call hung
#   the session — the one day there is no output to learn it from. 17e requires
#   the line, 17f requires its ABSENCE where a bound exists, because a warning
#   printed unconditionally is one an operator learns to skip.
#
# THE BOUND VALUE IS VALIDATED AND THE VALIDATION IS CASED (17g). The whole
# block was uncased: deleting it left this gate green. `00` is the shape that
# matters — all digits, not empty, not the literal `0`, so it passed the first
# spelling of the rule, and `timeout 00 …` means NO BOUND. Measured:
# `gtimeout 00 sleep 2` returns 0 after the full two seconds, with no
# `timeout_unavailable` recorded, so the ledger affirmatively implies a bound
# that never applied.
#
# THE GATE'S OWN REACH WAS THE NEXT DEFECT (issue #302). The review of #300 ran
# 31 mutations against the probe and 19 passed a gate whose header claimed to
# refuse vacuous greens; three were real wrong verdicts, fixed there, and the
# rest were holes HERE. Beyond the ones folded into the paragraphs above:
#
#   * `explains` IS PINNED BY CANON, PER BRANCH. The matcher accepted `nothing*`
#     plus EITHER "never licenses escalating" OR "not an explanation", for
#     every branch — the second needle existed for the clean-beside-incident
#     branch and was offered to `healthy` and `unknown` too — so that branch
#     rewritten to tell the caller "a stall that survives this verdict is a
#     real defect — escalate it" passed. `explains` is the field SKILL.md
#     orders callers to report instead of the verdict. All five reachable
#     "nothing" strings and the fallback's are checksummed, and M30 is the
#     measured inversion (the loop's `explains:` form).
#   * THE FAILED-GENERATOR DOOR IS CASED BEHAVIOURALLY (27b). It was pinned by
#     three source needles "because no fixture can make jq fail on a payload
#     the earlier guards accept" — false for the empty-state read (a rollup of
#     numbers does it) and true only for the missing-run read, whose input is
#     the probe's own derivation; each needle was defeated with the gate green,
#     one of them because it also matched the initialiser. A fixture drives the
#     first and a fault-injecting `jq` shim on a curated PATH drives the second
#     — the same answer the `timeout` shim gives for a bound that fires — and
#     M28, M28b and M28c are the three defeats, now red.
#   * THE NAME `gh` IS THE CHOKEPOINT. The probe's wrapper was a bound by
#     convention and the grep guarding it refused one spelling in ten; a bare
#     `gh api … >/dev/null` inserted into the probe ran unbounded with case 17
#     whitelisting it. The probe now shadows `gh` with a function whose only
#     reach to the binary is one `command gh`, asserted in 23 to occur exactly
#     once and inside it; 17b and 17d assert calls-vs-bounds PARITY over the
#     ledgers, and M33 inserts two bare calls in the shapes the grep missed and
#     requires both to run under the bound. `timeout` resolves `gh` by execvp,
#     so the mock is reached exactly the way the binary is.
#   * OUT-OF-LOOP MUTANTS CARRY A RAN-COUNTER. Their count was a hand
#     transcription checked only by the arithmetic at the bottom, whose message
#     blamed a case — a deleted block plus one added case was green. `oo_ran`
#     mirrors `mut_ran` and has its own ok/bad.
#   * THE REVIEW OF THAT FIX FOUND FIVE MORE, each measured green and now red.
#     `gh.killed` had no selector, so the 137 path was cased at the first call
#     alone while this header said "at the first-party sites" (17c2 loops per
#     site; M9h/M9i). The vocabulary had no bare form, so `on a degraded
#     verdict, hold the PR` — the phrasing given as the reason the scan exists
#     — passed (M31b). Heading lines were skipped by the section scan, so a
#     rule written as a heading over a bland body passed (M31c). The scope
#     census read an unquoted token only and floored below the site count, so
#     `add_error "firstparty"` passed (M34 is the quoted form now; the census
#     is an equality with the calling lines). And section 23 claimed no
#     fixture could kill the emitter, which a check name over the argv cap
#     does through the ledger builder (27c) — the same false-impossibility
#     shape, re-authored in the fix for it.
#
# NOT CLOSED BY #302, recorded rather than implied: the three STRUCTURAL
# sanitisers (`HEAD` hex-only, `MERGE_STATE`'s class, `BRANCH_ENC`'s `@uri`)
# sit outside section 26's census and each was measured removable with this
# gate green, and no fixture drives hostile text through `missing_out` or the
# status detail. That is the residual half of #302's original finding 4, out of
# its acceptance; a later editor should expect those mutations to still pass.
# #314 ADDS ONE TO THAT LIST, stated rather than left to be found. First-party
# `probe_errors[].detail` values now reach the STDERR summary too, through the
# `explains` tail, where before they reached the JSON alone. Every variable part
# of a detail is sanitised (`BRANCH_SAFE`) or structurally constrained (`$HEAD`
# hex-only, `$PR` digits, `$rc` a number, `$repo_why` a literal, a DERIVED
# `$REPO` from a safe character set) — with one exception that predates this and
# is unchanged by it: a `--repo` VALUE is only shape-checked `owner/name`, so a
# caller who passes hostile text there can put it in a reported field. It was
# already in the JSON details; it is now also on the stderr line. Section 26's
# fixtures do not drive it, because `--repo` is the coordinator's own argument
# rather than a fork-PR author's.
#
# THE EXIT CODE IS NOW ASSERTED ON EVERY VERDICT-FORM MUTANT, not only on M7's
# dedicated one. M7 proves the shipped `exit 0` is load-bearing; the per-mutant
# check proves no OTHER path can grow an exit code carrying a verdict. The
# emitter fallback is why that generalisation is worth having: it is the one
# path that produces a verdict having measured nothing, which makes it the
# obvious place for a later "surely THAT should fail loudly" to add a non-zero
# exit and turn the diagnostic into the gate it must never be.
#
# NO `| grep -q` PIPELINE ANYWHERE (gate 30's rule, issue #256): `grep -q`
# closes the pipe on its first match and `pipefail` promotes the writer's
# SIGPIPE 141, which reports a caught mutation as a miss. An earlier edition of
# THIS FILE shipped exactly that shape in `section_names_probe`, where it fails
# OPEN — the must-NOT-name assertions, the entire point of the file, would have
# read a SIGPIPE as "does not name it". Every check here captures first and then
# matches against a herestring or a file operand.
#
# Network-free: PATH-shimmed mock `gh` AND mock `curl`, both serving recorded
# payloads from a scenario directory and recording every invocation, so the
# read-only claim is measured rather than asserted, by METHOD and not merely by
# path prefix. `--repo` is passed everywhere EXCEPT the derivation cases in 17d,
# which drop it precisely to reach the local repo derivation; the mock `gh`'s
# `repo` arm now REFUSES rather than answering, so `gh repo view` reddens
# wherever it comes back. `git` is SHIMMED BUT NOT FAKED — every invocation is
# logged and then handed to the real binary, whose answers are what 17d's
# fixture repositories are for, since a stub would measure the stub's idea of a
# remote URL rather than git's. Every env knob the probe reads is pinned, so an
# operator's ambient PLATFORM_* setting cannot change what this measures.
# `timeout` is shimmed for the SAME reason the knobs are pinned rather than to
# fake anything: the host decides whether the real binary exists (macOS ships
# none; coreutils installs it as `gtimeout`), and a gate that measures a bounded
# probe on CI and an unbounded one on a laptop measures neither. The shim also
# makes a FIRING bound testable with no sleep at all, since 124 is exactly what
# the real binary reports and the probe's handling of 124 is the behaviour under
# test. Its ledger is a SEPARATE file: a `timeout …` line in MOCK_CALLS would be
# flagged by case 17 as a call outside the read-only contract. A third curated
# PATH carries a `jq` that dies on one named program (27b), with a ledger of
# its own for the same reason.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-platform-health-probe.sh
set -uo pipefail
export LC_ALL=C

# Resolved BEFORE the `cd` below, because 17d's inventory guard reads THIS
# file's own source and the caller's path is relative to the CALLER's cwd: a
# first attempt at that guard resolved it afterwards, so every extraction came
# back empty from `cd scripts && bash test-platform-health-probe.sh` — the most
# natural invocation there is, given every gate script lives there — and an
# empty extraction is a guard that passes without measuring anything (#324).
# Same idiom, and the same reason, as scripts/test-review-gate-decisions.sh.
SELF_ABS="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-platform-health-probe: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SCRIPTS_DIR="$REPO_ROOT/skills/pr-shepherd/scripts"
PROBE="$SCRIPTS_DIR/probe-platform-health.sh"
SKILL="$REPO_ROOT/skills/pr-shepherd/SKILL.md"
PROBE_BASENAME="probe-platform-health.sh"

[ -f "$PROBE" ] || { echo "test-platform-health-probe: $PROBE not found" >&2; exit 1; }
[ -f "$SKILL" ] || { echo "test-platform-health-probe: $SKILL not found" >&2; exit 1; }
# A precondition rather than an assertion: 17d's inventory guard reads this file
# back, and a path that does not resolve makes every one of its extractions
# empty — which reads as `all pass`, the exact vacuity the guard exists to stop.
[ -f "$SELF_ABS" ] || { echo "test-platform-health-probe: cannot resolve own source ($SELF_ABS)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test-platform-health-probe: jq is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

fail=0
asserts=0
ok() { asserts=$((asserts + 1)); echo "  ok    $1" >&2; }
bad() { asserts=$((asserts + 1)); fail=1; echo "  FAIL  $1" >&2; }

echo "platform-health-probe tests (work: $WORK)" >&2

# --- the mocks ----------------------------------------------------------------
cat >"$BIN/gh" <<'MOCK'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$MOCK_CALLS"
case "${1:-}" in
    repo)
        # A MUST-NOT-EXIST ARM (issue #314). The cwd repo lookup used to be
        # `gh repo view` and this arm answered it; the probe now derives the slug
        # from the `origin` remote with `git`, so reaching this at all means the
        # remote call is back. Failing loudly rather than deleting the arm is
        # deliberate: a deleted arm falls through to the catch-all, which says
        # `unhandled invocation` and reads like a fixture problem, while 17d's
        # explicit "no `gh repo view` in the call log" assertion names the
        # regression. Both are wanted — this one fires wherever the probe runs.
        echo "mock gh: the probe must not call 'gh repo view' — the repo is derived locally (#314): $*" >&2
        exit 1
        ;;
    pr)
        if [ "${2:-}" != "view" ]; then
            echo "mock gh: unhandled pr subcommand: $*" >&2; exit 1
        fi
        if [ -f "$SCENARIO_DIR/pr.fail" ]; then exit 4; fi
        cat "$SCENARIO_DIR/pr.json"
        ;;
    api)
        case "${2:-}" in
            repos/*/commits/*)
                if [ -f "$SCENARIO_DIR/commit.fail" ]; then exit 5; fi
                cat "$SCENARIO_DIR/commit.json" ;;
            *actions/runs*)
                if [ -f "$SCENARIO_DIR/runs.fail" ]; then exit 6; fi
                cat "$SCENARIO_DIR/runs.json" ;;
            *) echo "mock gh: unhandled api path: $*" >&2; exit 1 ;;
        esac
        ;;
    *) echo "mock gh: unhandled invocation: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$BIN/gh"

cat >"$BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$MOCK_CALLS"
if [ -f "$SCENARIO_DIR/status.unreachable" ]; then exit 7; fi
cat "$SCENARIO_DIR/status.json"
MOCK
chmod +x "$BIN/curl"

# `git` is LOGGED, NEVER FAKED (issue #314). The repo derivation replaced a `gh`
# call with two local git reads, and a local command that the read-only scan
# cannot see is exactly the hole the `gh` chokepoint closed one layer up: a
# `git fetch`, a `git remote add` or a `git config --global` written here would
# leave no trace in MOCK_CALLS and case 17 would report the run clean. So every
# invocation is recorded and then handed to the REAL binary, whose answers are
# what the fixture repositories below are for — a stub would measure the stub's
# idea of a remote URL rather than git's.
{
    echo '#!/usr/bin/env bash'
    printf "GIT_REAL='%s'\n" "$(command -v git)"
    cat <<'MOCK'
printf 'git %s\n' "$*" >>"${MOCK_CALLS:-/dev/null}"
exec "$GIT_REAL" "$@"
MOCK
} >"$BIN/git"
chmod +x "$BIN/git"

# `timeout` is SHIMMED for the same reason every PLATFORM_* knob is pinned: the
# host decides whether the real binary exists (macOS ships none; coreutils
# installs it as `gtimeout`), and a gate that measures a bounded probe on CI and
# an unbounded one on a laptop measures neither. The shim also makes the bound
# FIRING testable without a sleep, which is what `gh.timeout` does: 124 is the
# code the real `timeout` reports for exactly that, and the probe's handling of
# it is the behaviour under test. `gh.killed` is its sibling for 137, the code
# reported when TERM was ignored and the kill grace fired — the path `-k`
# exists for, and the one an edition of the probe could not recognise.
#
# It records to MOCK_BOUNDS and NEVER to MOCK_CALLS: case 17 classifies every
# line of MOCK_CALLS as a read or a write, and a `timeout …` line there would be
# flagged as a call outside the read-only contract by the scan that exists to
# catch a real one.
#
# `gh.timeout` CARRIES A SELECTOR. An empty file fires on every bounded call,
# which means the FIRST call always absorbs it and the later sites are never
# reached: an edition of this gate had exactly that, so the fired-bound rule
# was cased and mutated at `gh pr view` alone while the commit read and the
# runs read — two of the four sites — could report their own cutoff as an
# anomaly with the gate green. The file's content, when non-empty, is a
# substring matched against the shim's argv, so a case can fire the bound at
# the site it means to test (`commits/`, `actions/runs`) and let the earlier
# calls succeed.
cat >"$BIN/timeout" <<'MOCK'
#!/usr/bin/env bash
printf 'timeout %s\n' "$*" >>"${MOCK_BOUNDS:-/dev/null}"
if [ -f "$SCENARIO_DIR/gh.timeout" ]; then
    sel="$(cat "$SCENARIO_DIR/gh.timeout")"
    case "$*" in *"$sel"*) exit 124 ;; esac
fi
# 137 is what the real binary reports when the child ignored TERM and the
# kill grace had to fire — 128 + KILL, preserved after escalation. Measured on
# coreutils 9.11: `timeout -k 1 1 bash -c 'trap "" TERM; sleep 10'` -> 137,
# `timeout -k 1 1 sleep 10` -> 124. It is the path `-k` exists for.
# Same selector as `gh.timeout`, for the same reason: an empty file fires on
# the first call, which absorbs it, and a commit-site `-eq 137` anomaly was
# measured green while this shim had no selector (review of #315).
if [ -f "$SCENARIO_DIR/gh.killed" ]; then
    sel="$(cat "$SCENARIO_DIR/gh.killed")"
    case "$*" in *"$sel"*) exit 137 ;; esac
fi
# `-k <grace>` is stripped the way the real binary parses it. Shifting a fixed
# number of arguments instead would exec `5 30 gh …` the moment the probe
# gained a kill-after, i.e. the shim would break on the change it exists to
# measure, and every bounded call would fail for a reason unrelated to the test.
if [ "${1:-}" = "-k" ]; then shift 2; fi
shift
# A `gh.timeout.late` arm lived here until #314: the bound firing AFTER the child
# had flushed stdout, so a real-looking fragment survived a call we cut off. It
# existed for ONE site, the `gh repo view` repo lookup, which is now a local git
# read and can neither be bounded nor half-flush a slug, so the arm went with it
# rather than being kept unreachable.
#   STATE THE TRUE MECHANISM, because the first version of this note gave the
#   wrong one (review of #321). It said the three surviving `gh` sites are safe
#   because "jq rejects a truncated payload" — a COMPLETE late flush parses
#   perfectly well, so that is not what protects them. What does is that each
#   site tests `rc` BEFORE it looks at the output and takes the
#   `gh_call_failed` path on a fired bound whatever was flushed. That is a
#   structural property of three call sites, not a payload property, and it is
#   NOT cased here: no scenario drives "output present AND rc 124", and a
#   mutant that trusts the payload when one arrived passes this file. Recorded
#   as a known hole rather than implied away — the shape this file's own header
#   calls worse than a missing case is a claim that it cannot happen.
exec "$@"
MOCK
chmod +x "$BIN/timeout"

# TWO MORE PATHS, because the probe's bound has three branches and only one of
# them was reachable through $BIN. An earlier edition of this file asserted the
# other two "cannot be exercised at all" and pinned them at source level on that
# basis; both returning reviewers of #312 disproved it by construction in
# minutes, and the claim was the durable half of the defect — CLAUDE.md tells
# the next editor to trust a gate header. A curated PATH carrying everything the
# probe needs EXCEPT a timeout binary runs it perfectly well.
#
# BIN_NT: neither binary — the absent-bound branch.
# BIN_GT: `gtimeout` only — the macOS spelling, and the `elif` no host with a
#         plain `timeout` first on PATH can ever reach.
#
# BIN_NG: a THIRD curated PATH, carrying `timeout` and NOT `git`, for the
# derivation's `command -v git` branch (#314's own list, cased in 17d). It is
# the same answer the two above give — hide a binary by REPLACING the PATH, not
# by prepending to it — and it exists because that branch was reachable only on
# a host with no git at all, which is precisely the shape a gate must not leave
# to the host.
BIN_NT="$WORK/bin-no-timeout"
BIN_GT="$WORK/bin-gtimeout"
BIN_NG="$WORK/bin-no-git"
mkdir -p "$BIN_NT" "$BIN_GT" "$BIN_NG"
cp "$BIN/gh" "$BIN/curl" "$BIN/git" "$BIN_NT/"
cp "$BIN/gh" "$BIN/curl" "$BIN/git" "$BIN_GT/"
cp "$BIN/gh" "$BIN/curl" "$BIN/timeout" "$BIN_NG/"
cp "$BIN/timeout" "$BIN_GT/gtimeout"
# Everything else the probe and the mocks reach for, resolved ONCE from the real
# PATH and symlinked in. `bash` and `env` are here because the mocks carry a
# `#!/usr/bin/env bash` shebang, and `env` searches the restricted PATH.
NT_MISSING=""
for t in bash env jq tr cat sed; do
    t_path="$(command -v "$t" 2>/dev/null)"
    if [ -n "$t_path" ]; then
        ln -sf "$t_path" "$BIN_NT/$t"
        ln -sf "$t_path" "$BIN_GT/$t"
        ln -sf "$t_path" "$BIN_NG/$t"
    else
        NT_MISSING="$NT_MISSING $t"
    fi
done
BASH_BIN="$(command -v bash)"

# --- the cwd fixtures ---------------------------------------------------------
# REAL git repositories, because the probe's repo derivation is now a LOCAL read
# (issue #314) and its subject is the working directory rather than an argv
# value. Every case before this one ran from `$REPO_ROOT`, where `origin` is
# whatever the developer or the CI checkout happens to point at — a fork's slug
# on a fork PR — so an assertion on the DERIVED value taken there would either be
# vacuous or host-dependent. A fixture repo with a remote this file chose makes
# `.repo` an equality.
#
# ONE PER BRANCH OF THE DERIVATION, enumerated rather than counted: the three
# URL forms git writes, a checkout with no `origin`, one whose `origin` this
# parser refuses, one whose `.git` file points nowhere so `rev-parse` ERRORS,
# one that is a BARE repository (`false`, exit 0 — the only shape `rev-parse`
# separates by itself), and a bare directory that is no checkout at all. The
# remaining branch, `command -v git` failing, has no cwd of its own — it is
# `BIN_NG`, a curated PATH with no git on it.
# `not-a-repo` is a bare directory under `$WORK`, which `mktemp -d` puts
# outside any checkout — assert that, rather than assuming it, because a `$TMPDIR`
# inside a repo would make the "not in a work tree" case silently measure the
# opposite branch.
#
# HERMETIC AGAINST THE DEVELOPER'S OWN GIT CONFIG, which is the same rule the
# PLATFORM_* pins follow one layer up (review of #321). `git remote get-url`
# applies `url.<base>.insteadOf`, and chezmoi-synced dotfiles in this org set
# exactly that: a laptop with an ssh rewrite would never exercise the `https://`
# arm, and one with a mirror rewrite would redden 17d for a reason that has
# nothing to do with the probe. `GIT_CONFIG_GLOBAL=/dev/null` plus
# `GIT_CONFIG_NOSYSTEM=1` are exported around every git call this file makes —
# fixture construction AND `run_probe`'s subshell — and 17d asserts that what
# `get-url` hands back is the literal the fixture wrote, so a rewrite that
# escapes the pins is a named failure rather than a silent change of subject.
GIT_HERMETIC_GLOBAL=/dev/null
GIT_HERMETIC_NOSYSTEM=1
# STRUCTURALLY UNREASSIGNABLE. A source-text count cannot express "nothing
# rebinds these": the first attempt grepped `^NAME=` and therefore saw only a
# bare column-0 duplicate, while an indented line, an `export`, a `local` inside
# a function, or an assignment inside an `if` all rebound every site with the
# census still printing ok. `readonly` refuses them all at RUNTIME, whatever the
# spelling, and with the original value intact.
readonly GIT_HERMETIC_GLOBAL GIT_HERMETIC_NOSYSTEM
CWD_SSH="$WORK/cwd-ssh"
CWD_HTTPS="$WORK/cwd-https"
CWD_SSHPROTO="$WORK/cwd-sshproto"
CWD_NOORIGIN="$WORK/cwd-noorigin"
CWD_BADURL="$WORK/cwd-badurl"
CWD_HOSTPATH="$WORK/cwd-hostpath"
CWD_TRAILING="$WORK/cwd-trailing"
CWD_THREESEG="$WORK/cwd-threeseg"
CWD_BADCHAR="$WORK/cwd-badchar"
CWD_OTHERHOST="$WORK/cwd-otherhost"
CWD_EMPTYSEG="$WORK/cwd-emptyseg"
CWD_ONESEG="$WORK/cwd-oneseg"
CWD_BROKEN="$WORK/cwd-broken-gitdir"
CWD_BARE="$WORK/cwd-bare"
CWD_NOREPO="$WORK/cwd-not-a-repo"
mkdir -p "$CWD_NOREPO"
make_cwd() { # <dir> [origin url]
    mkdir -p "$1"
    ( cd "$1" || exit 1
      export GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_HERMETIC_NOSYSTEM"
      git init -q . >/dev/null 2>&1 && \
      { [ -z "${2:-}" ] || git remote add origin "$2"; } ) || return 1
}
CWD_MISSING=""
make_cwd "$CWD_SSH"       "git@github.com:mock-org/mock-repo.git"       || CWD_MISSING="$CWD_MISSING ssh"
make_cwd "$CWD_HTTPS"     "https://github.com/mock-org/mock-repo.git"   || CWD_MISSING="$CWD_MISSING https"
make_cwd "$CWD_SSHPROTO"  "ssh://git@github.com/mock-org/mock-repo"     || CWD_MISSING="$CWD_MISSING sshproto"
make_cwd "$CWD_NOORIGIN"                                                || CWD_MISSING="$CWD_MISSING noorigin"
# A local-path remote is what a clone of a sibling checkout carries, so the
# unparsable case is a real shape rather than a contrived string.
#
# ONE LITERAL, THREE READERS (review of #324). This value was four uncoupled
# copies — here, the read-back's `pin_want`, the credential-leak needle at the
# end of 17d, and the header's prose — of which the read-back coupled two. The
# leak assertion is a MUST-NOT-APPEAR, so a copy that drifts does not redden it:
# it passes, having looked for a string this fixture never carried. The needle
# is now `${BADURL_REMOTE%/*}`, derived rather than retyped. THE PROSE COPIES
# ARE GONE, not kept: the path literal appears exactly once in this file, in the
# assignment immediately below, and every reader derives from it. An earlier
# revision of this paragraph said the prose stays a copy on purpose — true when
# written, and made false by the same commit that wrote it, since the header and
# the comment beside the read-back both lost their copy to the coupling. Naming
# the variable rather than quoting the value is less illustrative and cannot
# drift; that is the trade, taken deliberately. This sentence spells no path,
# for the same reason: a prose copy here would make its own claim false.
BADURL_REMOTE="/some/local/path/mock-repo.git"
make_cwd "$CWD_BADURL"    "$BADURL_REMOTE"                             || CWD_MISSING="$CWD_MISSING badurl"
# THE TWO PARSER FIXES, EACH WITH A FIXTURE THAT DIES WITHOUT IT. Both landed in
# #321's fix round and neither was cased: reverting BOTH ran this gate to `all
# pass`, so the strictness the parser's own comments call load-bearing was
# pinned by nothing (review of #321).
#
# `hostpath` is the wrong-slug shape. Userinfo must be stripped from the
# AUTHORITY alone — `${p#*@}` over the whole string strips to the first `@`
# ANYWHERE, so this URL, which points at `evil.example`, derived `mock-org/
# mock-repo` on THIS host. A remote naming another host must be refused, not
# resolved.
make_cwd "$CWD_HOSTPATH"  "https://evil.example/path@github.com/mock-org/mock-repo" \
                                                                   || CWD_MISSING="$CWD_MISSING hostpath"
# `trailing` is the opposite error: an ORDINARY remote sent down the failure
# path. The trailing slash must come off before `.git`, or `o/n.git/` strips to
# `o/n.git` — which passes the two-segment and character checks intact, since
# `.` is in the allowed set — and the probe reports a slug with `.git` glued on.
make_cwd "$CWD_TRAILING"  "https://github.com/mock-org/mock-repo.git/"  || CWD_MISSING="$CWD_MISSING trailing"
# TWO MORE GROUNDS OF REFUSAL. `2d40389` cased the two transformations
# (`hostpath`, `trailing`) and left these, so these exist for the same reason
# those do: measured on `2d40389`, deleting EITHER
# the `*/*/*` arm or the character-set check ran this gate to
# `all pass (376 assertions)`, exit 0. The character-set check is the one that
# matters most — the probe's comment calls the shape check spanning both it and
# the segment case "the sanitiser at this site", and `.repo` is the one
# reported string whose ONLY guard is that check, so that was a SECURITY claim
# the file makes about itself with nothing behind it.
make_cwd "$CWD_THREESEG"  "https://github.com/mock-org/mock-repo/extra"   || CWD_MISSING="$CWD_MISSING threeseg"
make_cwd "$CWD_BADCHAR"   "https://github.com/mock-org/mock~repo"         || CWD_MISSING="$CWD_MISSING badchar"
# TWO MORE RULES, found by the round that checked whether `66e0147`'s "four
# rules" was a closed set. It was not — the header lists more, and a later
# round found one of those still uncased below. These
# two were uncased with the gate at `all pass (390 assertions)`, exit 0, on
# either revert:
#   - the empty/leading segment arm. "The segment shape" is TWO rules, and
#     `threeseg` pins only `*/*/*`; dropping `""|/*|*/` derives the slug
#     `/mock-repo` — an empty owner — which `gh` then queries.
#   - the `github.com` host restriction. Making it permissive derives `o/n` from
#     `https://gitlab.com/o/n`, and `gh` then queries github.com regardless of
#     what the remote said — the same wrong-slug hazard `hostpath` exists for,
#     reached through a plainer input. `hostpath` does NOT cover it: with the
#     host check gone, its URL still refuses on the three-segment arm.
#     MEASURED CORRECTION: this hazard is real but NOT reachable via
#     `https://github.com/o/`, the input first proposed for it. `p="${p%/}"`
#     runs BEFORE the shape check, so that collapses to the single segment `o`
#     and the `*)` fallback refuses it with or without the arm — a fixture
#     built on it measures nothing and passes. The reachable form needs a slash
#     the trailing-strip does not consume: an EMPTY OWNER,
#     `https://github.com//mock-repo`, which reaches the check as `/mock-repo`.
make_cwd "$CWD_OTHERHOST" "https://gitlab.com/mock-org/mock-repo"          || CWD_MISSING="$CWD_MISSING otherhost"
make_cwd "$CWD_EMPTYSEG"  "https://github.com//mock-repo"                  || CWD_MISSING="$CWD_MISSING emptyseg"
# RULE (5) — the `*)` fallback of the segment case, and the one whose
# absence is worst. Uncased at `7ed60c6`: deleting it ran THAT gate to
# `all pass (404 assertions)`, exit 0. Cased since `17cb16b`: deleting it now
# goes 6 red on `oneseg`. The sha is not decoration — the unanchored form of
# this sentence outlived the fix that falsified it. Its consequence is not a
# wrong slug: it is the EXIT-1-WITH-NO-VERDICT path #314 exists to abolish.
# Measured on a checkout whose origin is `https://github.com/mock-repo` —
# stock: exit 0, verdict `unknown`, detail naming the input; arm deleted:
# exit 1, EMPTY stdout, `error: repo must be owner/name, got: mock-repo`.
# The probe says as much about itself at `:644-645` — "a derived slug already
# satisfies this BY CONSTRUCTION" — and this arm IS that construction.
make_cwd "$CWD_ONESEG"    "https://github.com/mock-repo"                    || CWD_MISSING="$CWD_MISSING oneseg"
# `git rev-parse` ERRORING inside a directory that IS a checkout: a `.git` FILE
# pointing at a directory that is not there is what a moved worktree or a
# half-deleted submodule leaves behind, and `safe.directory` produces the same
# shape. Without it the probe reported "not inside a git work tree" from inside
# a checkout that plainly is one. Measured: rc 128 with empty stdout — the SAME
# pair a bare directory gives, which is why the probe's detail names both
# possibilities instead of choosing (review of #321).
mkdir -p "$CWD_BROKEN" && printf 'gitdir: %s\n' "$WORK/no-such-gitdir" >"$CWD_BROKEN/.git" \
    || CWD_MISSING="$CWD_MISSING broken"
# The one branch `rev-parse` DOES separate: a bare repository prints `false` and
# exits 0. It has no work tree and so no worktree remote, and it is the reason
# the output is still read after the status.
mkdir -p "$CWD_BARE" && \
    ( cd "$CWD_BARE" || exit 1
      export GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_HERMETIC_NOSYSTEM"
      git init -q --bare . >/dev/null 2>&1 ) || CWD_MISSING="$CWD_MISSING bare"

# A THIRD PATH, carrying a `jq` that can be told to DIE on one program. The
# missing-run generator cannot be killed by any payload: its input is the
# probe's own derivation, every `.missing` element is produced by string
# interpolation (`"\(.name) (\(.event))"`, a string whatever `.name` is), and
# `clean` is total over strings. Measured over null, object, number, array and
# U+10FFFF names — all stringified, generator exit 0 — and a lone surrogate,
# which never reaches the generator AS a surrogate: this host's jq
# (1.7.1-apple) rejects it in the DERIVATION's parser, where DERIVED_OK catches
# it, while other 1.7 builds replace it with U+FFFD and the derivation
# succeeds — a plain string either way, and the generator survives either way.
# So the guard behind that generator had no behavioural
# case, and its three source-level pins were each defeatable (one needle also
# matched the initialiser). Fault injection is the same answer the `timeout`
# shim already gives for a bound that fires: `jq.fail` in the scenario names a
# substring of the program text, and the ONE call carrying it exits 5 with
# nothing on stdout, which is exactly what a jq that died mid-read looks like
# to the probe. Every other call reaches the real binary. Kept OUT of $BIN so
# the ~15 jq calls per run pay the extra process only in the cases that ask
# for it, and it appends to MOCK_JQFAULTS when it fires so a case can prove
# the fault was injected rather than passing on a fixture that never reached
# it.
BIN_JQ="$WORK/bin-jqfault"
mkdir -p "$BIN_JQ"
cp "$BIN/gh" "$BIN/curl" "$BIN/timeout" "$BIN/git" "$BIN_JQ/"
JQ_REAL="$(command -v jq)"
{
    echo '#!/usr/bin/env bash'
    printf "JQ_REAL='%s'\n" "$JQ_REAL"
    cat <<'MOCK'
if [ -f "${SCENARIO_DIR:-/nonexistent}/jq.fail" ]; then
    needle="$(cat "$SCENARIO_DIR/jq.fail")"
    case "$*" in *"$needle"*)
        printf 'jq %s\n' "$needle" >>"${MOCK_JQFAULTS:-/dev/null}"
        exit 5 ;;
    esac
fi
exec "$JQ_REAL" "$@"
MOCK
} >"$BIN_JQ/jq"
chmod +x "$BIN_JQ/jq"

# --- recorded payloads --------------------------------------------------------
# The outage shape from #285: the rollup carries an empty-state `ci`, the head
# has one unrelated run, and BOTH prior heads carried `CI`.
PR_ANOMALY='{"number":283,"headRefOid":"5a8f58b","headRefName":"feat/probe",
  "mergeStateStatus":"BLOCKED",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"CodeQL","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"ci","status":"","conclusion":"","state":""}]}'
RUNS_ANOMALY='{"workflow_runs":[
  {"name":"CodeQL","event":"pull_request","head_sha":"5a8f58b"},
  {"name":"CI","event":"pull_request","head_sha":"6255349"},
  {"name":"CodeQL","event":"pull_request","head_sha":"6255349"},
  {"name":"CI","event":"pull_request","head_sha":"8c44c7f"},
  {"name":"CodeQL","event":"pull_request","head_sha":"8c44c7f"}]}'

# The healthy shape. Its rollup names are JOB names that deliberately match no
# workflow name — that mismatch is what makes the cross-namespace question
# answerable, and a fixture whose names lined up would make it vacuous. It also
# carries a StatusContext (Vercel-style: `context`/`state`, and NO
# `status`/`conclusion`), which is the only fixture that can tell the
# empty-state predicate's `.state` conjunct from a healthy external check.
PR_CLEAN='{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean",
  "mergeStateStatus":"CLEAN",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"build (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"StatusContext","context":"vercel","state":"SUCCESS"}]}'
RUNS_CLEAN='{"workflow_runs":[
  {"name":"CI","event":"pull_request","head_sha":"aa11bb2"},
  {"name":"CodeQL","event":"pull_request","head_sha":"aa11bb2"},
  {"name":"CI","event":"pull_request","head_sha":"9900aab"},
  {"name":"CodeQL","event":"pull_request","head_sha":"9900aab"}]}'

# #285's OWN rollup shape: entries present, all well-formed, and `ci` simply
# ABSENT. Nothing here is malformed, so the empty-state check finds nothing —
# which is the point: it cannot see an absent check, so it must not be able to
# earn `clean` by itself.
PR_ABSENT_CHECK='{"number":501,"headRefOid":"ee55ff6","headRefName":"feat/absent",
  "mergeStateStatus":"BLOCKED",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"CodeQL","status":"COMPLETED","conclusion":"SUCCESS"}]}'

# No runs at all on the branch, so there is no prior head to compare against.
# Paired with a POPULATED rollup in case 8, because an empty one would let that
# case pass for the wrong reason.
RUNS_EMPTY='{"workflow_runs":[]}'

# Prior heads ran CI; the current head has NO run at all — #285's headline shape.
RUNS_NO_HEAD='{"workflow_runs":[
  {"name":"CI","event":"pull_request","head_sha":"9900aab"},
  {"name":"CI","event":"pull_request","head_sha":"7711ccd"}]}'

# Same head as PR_CLEAN but an EMPTY rollup, so the rollup check cannot run and
# the age floor alone decides. With PR_CLEAN's populated rollup the empty-state
# check runs, earns `clean` on its own, and the age case would measure nothing —
# which is exactly how a first draft of that case passed while proving nothing.
PR_EMPTY_ROLLUP='{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean",
  "mergeStateStatus":"BLOCKED","statusCheckRollup":[]}'

# Two prior heads with DISJOINT workflow sets, and no run on the current head.
# The intersection is empty, so nothing was ever required of this head and its
# having no run is ordinary — the guard that applies to missing_workflow_run has
# to apply to no_run_for_head too, or the "under-detects rather than
# over-detects" claim in the probe's header is false for half the signals.
RUNS_DISJOINT='{"workflow_runs":[
  {"name":"CI","event":"pull_request","head_sha":"9900aab"},
  {"name":"Docs","event":"pull_request","head_sha":"7711ccd"}]}'

# "Docs" ran on ONE prior head only, so it is not required of the current head.
# The union reading calls that degradation; the intersection reading does not.
RUNS_PARTIAL='{"workflow_runs":[
  {"name":"CI","event":"pull_request","head_sha":"aa11bb2"},
  {"name":"CI","event":"pull_request","head_sha":"9900aab"},
  {"name":"Docs","event":"pull_request","head_sha":"9900aab"},
  {"name":"CI","event":"pull_request","head_sha":"7711ccd"}]}'

# A one-off manual run on the only prior head. It can never recur on this head,
# so a no-whitelist reading reports it missing forever.
RUNS_DISPATCH='{"workflow_runs":[
  {"name":"CI","event":"pull_request","head_sha":"aa11bb2"},
  {"name":"CI","event":"pull_request","head_sha":"9900aab"},
  {"name":"Release","event":"workflow_dispatch","head_sha":"9900aab"}]}'

# An empty-state entry whose `name` is the EMPTY STRING, and one whose
# `context` is. jq's `//` falls back only on null/false, so both used to
# survive the generator as "" and then vanish at the shell guard - found,
# emitted, silently discarded, verdict `healthy`. Head and runs are
# PR_CLEAN's, so the run comparison resolves clean and the empty-state entry
# is the ONLY signal in play; without that pairing the case could pass for
# the wrong reason.
PR_EMPTY_NAME='{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean",
  "mergeStateStatus":"BLOCKED",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"","status":"","conclusion":"","state":""}]}'
PR_EMPTY_CONTEXT='{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean",
  "mergeStateStatus":"BLOCKED",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"StatusContext","context":"","state":""}]}'

# The two conjuncts M15 never reached. A check still RUNNING (status
# IN_PROGRESS, conclusion null) is the most common PR state in this org, so a
# regression dropping the `.status` conjunct fabricates `degraded` on every PR
# with CI mid-flight; the second entry is the mirror for `.conclusion`.
# NEITHER matches the shipped predicate, so the unmutated run is healthy and
# each mutant has somewhere to move.
PR_MIDFLIGHT='{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean",
  "mergeStateStatus":"BLOCKED",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"CI / build","status":"IN_PROGRESS","conclusion":null},
    {"__typename":"CheckRun","name":"CI / lint","status":"","conclusion":"SUCCESS"}]}'

# A rollup whose entries are NUMBERS. It passes every earlier guard — parsable,
# both requested keys present, head and branch non-empty, rollup_n = 2 — and
# then kills the empty-state generator for real (`.status` on a number is a jq
# error, exit 5). This is the fixture an earlier header said could not exist
# ("no fixture can make jq fail on a payload the earlier guards accept"), and
# it is what gives the failed-generator door into `healthy` a behavioural case
# instead of three defeatable source pins. Head and runs are PR_CLEAN's, so
# the run comparison resolves clean and the dead generator is the ONLY thing
# standing between this run and `healthy`.
PR_BAD_ROLLUP='{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean",
  "mergeStateStatus":"CLEAN","statusCheckRollup":[1,2]}'

# A FULL page (100 runs) is what the probe reads as truncated. Its comparison
# is RUNS_CLEAN's and resolves clean, so the only difference between this
# fixture and RUNS_CLEAN is that the page is full - which is the whole point:
# same underlying reality, and before the fix the pair gave `healthy` and
# `degraded`. The padding repeats a workflow already on a prior head, so it
# adds no name to any set and cannot change the intersection.
RUNS_TRUNCATED_FULL="$(jq -cn '{workflow_runs:
  ([{name:"CI",event:"pull_request",head_sha:"aa11bb2"},
    {name:"CodeQL",event:"pull_request",head_sha:"aa11bb2"},
    {name:"CI",event:"pull_request",head_sha:"9900aab"},
    {name:"CodeQL",event:"pull_request",head_sha:"9900aab"}]
   + [range(96) | {name:"CI",event:"pull_request",head_sha:"9900aab"}])}')"

# Hostile first-party text. A fork-PR author controls BOTH the branch name and
# the job name, and both reach reported fields. Built with jq rather than typed
# so the bytes are unambiguous. Every other fixture in this file is clean
# ASCII, which is exactly why all six sanitisers were removable with the gate
# green before this existed.
BIDI_RLO="$(jq -rn '"\u202e"')"
BIDI_LRM="$(jq -rn '"\u200e"')"
# U+E0041, in the Unicode TAG BLOCK — non-BMP, so it is written as a surrogate
# pair. This is the character a regex class could not express at all, which is
# why the shared class is codepoint arithmetic; without it in the fixture the
# tag-block mutant has nothing to leak and its proof is vacuous.
TAG_CHR="$(jq -rn '"\udb40\udc41"')"
PR_HOSTILE="$(jq -cn --arg rlo "$BIDI_RLO" --arg lrm "$BIDI_LRM" --arg tag "$TAG_CHR" '{
  number:301, headRefOid:"aa11bb2",
  headRefName:("feat/x" + $rlo + "y" + $lrm + "z"),
  mergeStateStatus:"BLOCKED",
  statusCheckRollup:[
    {__typename:"CheckRun", name:"Analyze (actions)", status:"COMPLETED", conclusion:"SUCCESS"},
    {__typename:"CheckRun", name:("CI" + $rlo + "job" + $lrm + "k" + $tag + "z"),
     status:"", conclusion:"", state:""}]}')"

STATUS_GREEN='{"status":{"indicator":"none","description":"All Systems Operational"},
  "components":[{"name":"Actions","status":"operational"},
                {"name":"API Requests","status":"operational"},
                {"name":"Copilot","status":"operational"}],
  "incidents":[]}'
STATUS_INCIDENT='{"status":{"indicator":"major","description":"Partial System Outage"},
  "components":[{"name":"Actions","status":"partial_outage"},
                {"name":"API Requests","status":"operational"}],
  "incidents":[{"name":"Incident with Actions","status":"investigating",
                "components":[{"name":"Actions"}]}]}'
# Real githubstatus.com carries a dozen components. A Copilot blip raises the
# global indicator but explains nothing about a check.
STATUS_IRRELEVANT='{"status":{"indicator":"minor","description":"Partially Degraded Service"},
  "components":[{"name":"Actions","status":"operational"},
                {"name":"API Requests","status":"operational"},
                {"name":"Copilot","status":"degraded_performance"}],
  "incidents":[{"name":"Incident with Copilot","status":"investigating",
                "components":[{"name":"Copilot"}]}]}'
# Reachable, 200, parsable JSON — and not a statuspage summary at all. This is
# deliberately the shape that DEFEATED a key-presence gate: it carries a
# `status` key, so `has("status")` passed and the payload classified
# `operational` — a non-2xx body manufacturing a green platform. An
# `{"error":...}` body happened to be caught by that gate, which would have made
# this case vacuous.
STATUS_GARBAGE='{"status":"Service Unavailable","code":503}'

scenario() { # <name> <pr_json> <runs_json> <head_age_secs> <status kind>
    local d="$WORK/sc-$1"
    mkdir -p "$d"
    printf '%s\n' "$2" >"$d/pr.json"
    printf '%s\n' "$3" >"$d/runs.json"
    jq -n --argjson age "$4" '{commit:{committer:{date:((now - $age)|floor|todateiso8601)}}}' >"$d/commit.json"
    case "$5" in
        green)       printf '%s\n' "$STATUS_GREEN" >"$d/status.json" ;;
        incident)    printf '%s\n' "$STATUS_INCIDENT" >"$d/status.json" ;;
        irrelevant)  printf '%s\n' "$STATUS_IRRELEVANT" >"$d/status.json" ;;
        garbage)     printf '%s\n' "$STATUS_GARBAGE" >"$d/status.json" ;;
        unreachable) : >"$d/status.unreachable"; printf '{}\n' >"$d/status.json" ;;
        *) echo "scenario: bad status kind '$5'" >&2; exit 1 ;;
    esac
    echo "$d"
}

# --- runner -------------------------------------------------------------------
STDOUT=""; STDERR=""; STATUS=0; VERDICT=""
# ONE transcription of the bound the runner pins, consumed by run_probe below and
# by 17b's per-line assertion. It tracks the SHIPPED default deliberately — the
# knob is pinned so an operator's ambient value cannot change what this gate
# measures, and pinning a value the probe never ships would measure a
# configuration nobody runs. Section 23 is what holds the source line to it.
GH_TIMEOUT_PINNED=20
run_probe() { # <script> <scenario_dir> [extra probe args...]
    local script="$1" dir="$2"
    shift 2
    : >"$WORK/calls"
    : >"$WORK/bounds"
    : >"$WORK/jqfaults"
    # FOUR OPTIONAL OVERRIDES, each defaulting to the pinned value so a case
    # that does not set one measures exactly what it used to.
    #   PATH_OVERRIDE       a curated PATH, for the two bound branches $BIN
    #                       cannot reach (no timeout at all; gtimeout only),
    #                       or $BIN_JQ, the fault-injecting jq.
    #   REPO_ARG_OVERRIDE   "none" drops --repo, which is what reaches the repo
    #                       derivation — suppressed by every other case here and
    #                       therefore unexercised until one asked for it.
    #   CWD_OVERRIDE        the directory the probe RUNS IN. Only the derivation
    #                       reads it, and only when --repo is absent, but the two
    #                       travel together: dropping --repo without choosing a
    #                       cwd measures whatever `origin` this checkout has,
    #                       which on a fork PR is not this repo at all (#314).
    #   GH_TIMEOUT_OVERRIDE a bad bound value, for the validation cases.
    # `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM` are pinned below for the reason
    # every PLATFORM_* knob is: `url.<base>.insteadOf` in a developer's own
    # config rewrites what `git remote get-url` returns, so an ssh rewrite would
    # skip the `https://` arm entirely and a mirror rewrite would redden 17d.
    local run_path="${PATH_OVERRIDE:-$BIN:$PATH}"
    local run_cwd="${CWD_OVERRIDE:-$REPO_ROOT}"
    local repo_arg="--repo mock-org/mock-repo"
    [ "${REPO_ARG_OVERRIDE:-}" = "none" ] && repo_arg=""
    # `$BASH_BIN` and not a bare `bash`: a curated PATH_OVERRIDE has to carry
    # every binary the probe reaches, and the interpreter is resolved through
    # the SAME assignment, so a bare `bash` is looked up in the restricted PATH.
    # Every PLATFORM_* knob the probe reads is pinned: an operator's ambient
    # setting must not change what this gate measures.
    # A SUBSHELL, because the cwd is now an input: `cd` has to be undone before
    # the next case, and every path this function touches is already absolute.
    # shellcheck disable=SC2086
    (
        cd "$run_cwd" || exit 99
        PATH="$run_path" SCENARIO_DIR="$dir" MOCK_CALLS="$WORK/calls" \
        GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL" GIT_CONFIG_NOSYSTEM="$GIT_HERMETIC_NOSYSTEM" \
        MOCK_BOUNDS="$WORK/bounds" MOCK_JQFAULTS="$WORK/jqfaults" \
        PLATFORM_STATUS_URL="https://status.example.invalid/api/v2/summary.json" \
        PLATFORM_STATUS_TIMEOUT=5 \
        PLATFORM_GH_TIMEOUT="${GH_TIMEOUT_OVERRIDE:-$GH_TIMEOUT_PINNED}" \
        PLATFORM_PROBE_MIN_AGE=300 \
        PLATFORM_STATUS_COMPONENTS="${SCOPE_OVERRIDE:-actions,api requests,webhooks,pull requests,git operations}" \
            "$BASH_BIN" "$script" $repo_arg "$@"
    ) >"$WORK/stdout" 2>"$WORK/stderr"
    STATUS=$?
    STDOUT="$(cat "$WORK/stdout")"
    STDERR="$(cat "$WORK/stderr")"
    if [ -n "$STDOUT" ]; then
        VERDICT="$(jq -r '.verdict // "«no verdict»"' <<<"$STDOUT" 2>/dev/null)"
        [ -n "$VERDICT" ] || VERDICT="«unparsable»"
    else
        VERDICT="«no output»"
    fi
}

field() { jq -r "$1 // \"\"" <<<"$STDOUT" 2>/dev/null; }
kinds() { jq -r '[.anomalies[].kind] | sort | join(",")' <<<"$STDOUT" 2>/dev/null; }
errkinds() { jq -r '[.probe_errors[].kind] | sort | join(",")' <<<"$STDOUT" 2>/dev/null; }

# Does any REPORTED VALUE carry a character the sanitisers must strip?
#
# Scoped to scalar VALUES, never to the serialized document: the class includes
# U+0000-U+001F, the pretty-printed JSON is full of newlines, and a whole-text
# test therefore answers "yes" for every run including the clean ones. Measured
# - it made the unmutated baseline look unsafe and the mutant indistinguishable
# from it, so the proof reported UNDETECTED while the probe was behaving.
#
# Written as CODEPOINT arithmetic rather than a character class so this file
# states the spec in a form that cannot be silently mangled by a copy: the
# class is U+0000-U+001F, U+007F, U+0085, U+061C, U+200E/U+200F,
# U+2028/U+2029, U+202A-U+202E, U+2066-U+2069 and the U+E0000-U+E007F tag block.
# It is deliberately NOT harvested from the probe - that would let a probe which
# narrowed its class narrow the assertion with it. Section 26's source-level
# check is what compares the probe's own sites to each other.
UNSAFE_JQ='def is_unsafe: explode | any(
  . < 32 or . == 127 or . == 133 or . == 1564
  or (. >= 8206 and . <= 8207) or (. >= 8232 and . <= 8233)
  or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297)
  or (. >= 917504 and . <= 917631));'

json_has_unsafe() { # <json text> -> yes|no
    local r
    r="$(jq -r "$UNSAFE_JQ"' [paths(scalars) as $p | getpath($p) | tostring | select(is_unsafe)] | length > 0' <<<"$1" 2>/dev/null)"
    if [ "$r" = "true" ]; then echo yes; else echo no; fi
}

# The stderr line is plain text, so its own line structure is legitimate: TAB
# and NEWLINE are excluded, everything else in the class is not.
text_has_unsafe() { # <text> -> yes|no
    local r
    r="$(jq -rn --arg t "$1" '$t | explode | any(
            (. < 32 and . != 9 and . != 10 and . != 13) or . == 127
            or . == 133 or . == 1564
            or (. >= 8206 and . <= 8207) or (. >= 8232 and . <= 8233)
            or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297)
            or (. >= 917504 and . <= 917631))' 2>/dev/null)"
    if [ "$r" = "true" ]; then echo yes; else echo no; fi
}

dump() {
    printf '%s\n' "$STDERR" | sed 's/^/          | E /' >&2
    printf '%s\n' "$STDOUT" | sed 's/^/          | O /' >&2
}

expect_verdict() { # <label> <expected>
    if [ "$VERDICT" = "$2" ]; then ok "$1 (verdict: $VERDICT)"; else bad "$1 — verdict '$VERDICT', expected '$2'"; dump; fi
}
expect_field() { # <label> <jq-path> <expected>
    local got; got="$(field "$2")"
    if [ "$got" = "$3" ]; then ok "$1 ($2 = $got)"; else bad "$1 — $2 = '$got', expected '$3'"; dump; fi
}
expect_status() { # <label> <expected>
    if [ "$STATUS" = "$2" ]; then ok "$1 (exit $STATUS)"; else bad "$1 — exit $STATUS, expected $2"; dump; fi
}
expect_kind() { # <label> <kind>
    local k; k="$(kinds)"
    if grep -qF -- "$2" <<<"$k"; then ok "$1"; else bad "$1 — anomalies were '$k', expected to include $2"; dump; fi
}
expect_errkind() { # <label> <kind>
    local k; k="$(errkinds)"
    if grep -qF -- "$2" <<<"$k"; then ok "$1"; else bad "$1 — probe_errors were '$k', expected to include $2"; dump; fi
}
# All eight `explains` strings — the six that say nothing and the two that
# explain a stall — are pinned by CANON, per branch, the way §2b is. A needle
# cannot hold this field: a bare `nothing*` glob is satisfied
# by "nothing prevents escalating this stall as a real defect", and the
# two-needle disjunction that replaced it accepted EITHER needle for EVERY
# branch — so the `clean`-beside-incident branch rewritten as "nothing here is
# unexplained: a green page is not an explanation, so a stall that survives
# this verdict is a real defect — escalate it" passed, measured, gate green.
# `explains` is the field SKILL.md orders callers to report INSTEAD OF the
# verdict, and "a healthy verdict confirms the stall is a real defect" is the
# exact harm this file's header names. Canon is exact by construction: the
# accepted cost is a checksum to regenerate on a deliberate reword, a loud
# false red, which this repo prefers to a matcher that can be inverted.
# Regenerate with: printf '%s' "<string>" | cksum | cut -d' ' -f1
explains_canon() { # <branch> -> the pinned cksum
    case "$1" in
        healthy)               echo "51897600" ;;   # nothing — a green status page is not evidence of health…
        unknown-clean)         echo "1308946592" ;;   # nothing — this PR's own check data was read and was complete…
        unknown-unmeasured)    echo "3415400899" ;;   # nothing — the probe could not measure…
        attributed-clean)      echo "779948060" ;;   # nothing about this PR — a platform incident is open, but…
        attributed-unmeasured) echo "3045748376" ;;   # nothing measured here — a platform incident is open, and…
        emitter-failed)        echo "3809799310" ;;   # nothing — the verdict emitter failed… (the fallback literal)
        attributed-anomaly)    echo "1059178065" ;;   # a stall — an open platform incident on a check-relevant component…
        unattributed)          echo "4169396744" ;;   # a stall — first-party evidence of degradation…
        *) echo "«no canon recorded for branch $1»" ;;
    esac
}
# THE CANON HOLDS THE HEAD, AND THE MARKER IS WHAT MAKES THAT SAFE (issue #314).
# The unmeasured-`unknown` branch now appends `(not measured: <reason>; <first-
# party details>)`, which is GENERATED text — reason and ledger detail — and so
# cannot be a fixed checksum. Splitting on the literal marker keeps the
# canonical sentence exactly as checksummable as it was, and confines what the
# canon cannot see to a suffix whose own content is asserted behaviourally in
# 17c, 17d and 13, and whose marker is pinned at source level in 23. A reword
# hidden AFTER the marker is the residual gap; it is bounded by the fact that
# nothing between `(not measured: ` and the closing paren is authored prose.
EXPLAINS_TAIL_MARK=' (not measured: '
explains_head() { # <explains string> — the canonical half, with any generated tail removed
    printf '%s' "${1%%"$EXPLAINS_TAIL_MARK"*}"
}
explains_on_canon() { # <branch> [json] -> yes|no: the emitted `explains` matches the branch's canon
    local e sum
    e="$(jq -r '.explains // ""' <<<"${2:-$STDOUT}" 2>/dev/null)"
    sum="$(explains_head "$e" | cksum | cut -d' ' -f1)"
    if [ "$sum" = "$(explains_canon "$1")" ]; then echo yes; else echo no; fi
}
explains_ok() { # <branch> [json] -> yes|no: opens with `nothing` AND is on canon
    local e
    e="$(jq -r '.explains // ""' <<<"${2:-$STDOUT}" 2>/dev/null)"
    case "$e" in nothing*) explains_on_canon "$1" "${2:-$STDOUT}" ;; *) echo no ;; esac
}
explains_drift() { # <branch> — the got/want checksums for a failure message
    local e; e="$(field .explains)"
    printf 'got %s want %s: %s' "$(printf '%s' "$e" | cksum | cut -d' ' -f1)" "$(explains_canon "$1")" "$e"
}
expect_explains_nothing() { # <label> <branch>
    if [ "$(explains_ok "$2")" = "yes" ]; then
        ok "$1"
    else
        bad "$1 — explains for the '$2' branch is off canon ($(explains_drift "$2"))"; dump
    fi
}
# THE GENERATED TAIL, asserted where the canon stops (issue #314). The reason an
# `unknown` could not measure is the probe's most useful output during an outage
# and reached NO human channel: `explains` and the stderr summary rendered "the
# probe could not measure" for a `gh pr view` GitHub hung on for twenty seconds
# and for "no --pr was given" alike. Both channels are checked, because the
# summary interpolates `explains` — a rewrite that stops doing so would leave
# the JSON right and the operator's line wrong.
expect_explains_names() { # <label> <needle> — the tail, in the JSON AND on stderr
    local e tail
    e="$(field .explains)"
    tail="${e#*"$EXPLAINS_TAIL_MARK"}"
    if [ "$tail" = "$e" ]; then
        bad "$1 — explains carries no '$EXPLAINS_TAIL_MARK' tail at all: '$e'"; dump
    elif ! grep -qF -- "$2" <<<"$tail"; then
        bad "$1 — the tail does not name '$2': '$tail'"; dump
    elif ! grep -qF -- "$2" <<<"$STDERR"; then
        bad "$1 — the JSON names '$2' but the stderr summary does not: '$(printf '%.200s' "$STDERR")'"; dump
    else
        ok "$1"
    fi
}
expect_explains_stall() { # <label> <branch> — a degraded verdict explains a STALL, in the pinned words
    # Both halves: it must NOT open by saying it explains nothing, and it must
    # be the pinned string. The anomaly branches were held by the prefix alone
    # until the review of #315 pointed out that a reword there was free.
    local e; e="$(field .explains)"
    case "$e" in
        nothing*) bad "$1 — a degraded verdict reported that it explains nothing: '$e'"; dump ;;
        *) if [ "$(explains_on_canon "$2")" = "yes" ]; then
               ok "$1"
           else
               bad "$1 — explains for the '$2' branch is off canon ($(explains_drift "$2"))"; dump
           fi ;;
    esac
}

# ==============================================================================
echo "1. clean first-party + green page = healthy (table row 5)" >&2
D="$(scenario healthy "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "clean + operational resolves healthy" "healthy"
expect_status "  and exits 0, like every other verdict" 0
expect_field "  first-party measurement is recorded as clean" .self_measured "clean"
expect_field "  and it says which check earned that (the run comparison ran)" \
    .checks_run.run_comparison "ran"
expect_field "  the page is recorded as operational" .status_page "operational"
expect_field "  no anomaly from job names, and none from the StatusContext entry" \
    '(.anomalies | length | tostring)' "0"
expect_explains_nothing "  and healthy is reported as explaining nothing, in the pinned words" healthy

echo "2. first-party anomaly + relevant incident = degraded (attributed) (row 1)" >&2
D="$(scenario attributed "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 incident)"
run_probe "$PROBE" "$D" --pr 283
expect_verdict "anomaly + incident resolves degraded (attributed)" "degraded (attributed)"
expect_status "  and exits 0" 0
expect_field "  first-party measurement is recorded as an anomaly" .self_measured "anomaly"
expect_kind "  the missing CI workflow run is named" "missing_workflow_run"
expect_kind "  the empty-state rollup entry is named" "empty_state_check"
expect_explains_stall "  a degraded verdict does NOT report that it explains nothing, and its words are pinned" attributed-anomaly

echo "3. first-party anomaly + GREEN page = degraded (unattributed), never healthy (row 2)" >&2
D="$(scenario unattributed "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 green)"
run_probe "$PROBE" "$D" --pr 283
expect_verdict "a green page does not refute a first-party anomaly" "degraded (unattributed)"
expect_field "  the page really was read as green (so this is not passing by accident)" \
    .status_page "operational"
expect_status "  and exits 0" 0
expect_explains_stall "  the verdict explains the stall rather than explaining nothing, in the pinned words" unattributed

echo "4. clean first-party + UNREACHABLE endpoint = unknown (row 6)" >&2
D="$(scenario unknown-clean "$PR_CLEAN" "$RUNS_CLEAN" 3600 unreachable)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "an unreadable status page degrades to unknown, not to health" "unknown"
expect_field "  the page is recorded as unknown, never operational" .status_page "unknown"
expect_field "  first-party measurement really was clean, so the verdict came from the page" \
    .self_measured "clean"
expect_status "  and exits 0" 0
expect_explains_nothing "  and unknown is reported as explaining nothing, in the pinned words" unknown-clean

echo "5. first-party anomaly + UNREACHABLE endpoint = degraded (unattributed) (row 3)" >&2
D="$(scenario unattributed-dark "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 unreachable)"
run_probe "$PROBE" "$D" --pr 283
expect_verdict "an unreadable page adds exactly as much as a green one: nothing" \
    "degraded (unattributed)"
expect_field "  the page is recorded as unknown" .status_page "unknown"
expect_status "  and exits 0" 0

echo "6. clean first-party + relevant incident = degraded (attributed) (row 4)" >&2
D="$(scenario clean-incident "$PR_CLEAN" "$RUNS_CLEAN" 3600 incident)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "an open incident on a check-relevant component still attributes" \
    "degraded (attributed)"
expect_field "  but the first-party read is still reported as clean" .self_measured "clean"
expect_explains_nothing "  and it must NOT claim to explain check data the same payload shows is complete" attributed-clean

echo "7. nothing measured first-party (no --pr): rows 7, 8 and 9" >&2
D="$(scenario nomeasure-green "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D"
expect_verdict "row 8: unmeasured over a green page is unknown, never healthy" "unknown"
expect_field "  and says so" .self_measured "not_measured"
expect_field "  naming why it could not measure" .self_measured_reason "no_pr_given"
expect_explains_nothing "  and an unmeasured unknown explains nothing, in the pinned words" unknown-unmeasured
D="$(scenario nomeasure-incident "$PR_CLEAN" "$RUNS_CLEAN" 3600 incident)"
run_probe "$PROBE" "$D"
expect_verdict "row 7: an open incident still attributes without a first-party signal" \
    "degraded (attributed)"
expect_explains_nothing "  but explains nothing about THIS PR, since nothing first-party was measured" attributed-unmeasured
D="$(scenario nomeasure-dark "$PR_CLEAN" "$RUNS_CLEAN" 3600 unreachable)"
run_probe "$PROBE" "$D"
expect_verdict "row 9: nothing measured and an unreadable page is unknown" "unknown"

# ==============================================================================
echo "8. the FIRST-PARTY door into healthy: no baseline is not 'clean'" >&2
# The fixture is PR_CLEAN — a POPULATED rollup — deliberately. With an empty
# rollup neither check can run and the case passes for the wrong reason: the
# door that was still open is the one where the rollup check runs, finds no
# malformed entry, and earns `clean` on a branch whose runs were never compared.
# Measured on the pre-fix source, this exact fixture returned `healthy` and made
# M8 report UNDETECTED.
D="$(scenario no-baseline "$PR_CLEAN" "$RUNS_EMPTY" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a single-commit branch is unknown even when its rollup is populated and clean" "unknown"
expect_field "  nothing was measured" .self_measured "not_measured"
expect_field "  and it names the missing baseline" .self_measured_reason "no_prior_heads"
expect_field "  the run comparison is reported as not having run" \
    .checks_run.run_comparison "not_run"
expect_field "  while the rollup check DID run — and is not sufficient on its own" \
    .checks_run.rollup_empty_state "ran"

# #285's own rollup shape on a single-commit branch: entries present, no `ci`,
# and no malformed entry to find. The empty-state check cannot see an ABSENT
# check, so this is the shape that must never read `healthy`.
D="$(scenario absent-check "$PR_ABSENT_CHECK" "$RUNS_EMPTY" 4000 green)"
run_probe "$PROBE" "$D" --pr 501
expect_verdict "#285's own rollup shape is never certified healthy" "unknown"
expect_field "  because a missing check is invisible to the empty-state read" \
    .self_measured "not_measured"

echo "9. no_run_for_head — #285's headline signal, and its intersection guard" >&2
D="$(scenario no-run-head "$PR_CLEAN" "$RUNS_NO_HEAD" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_kind "a head carrying no run at all, where every prior head ran one, is named" "no_run_for_head"
expect_verdict "  and a green page does not refute it" "degraded (unattributed)"
D="$(scenario no-run-disjoint "$PR_CLEAN" "$RUNS_DISJOINT" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_field "  but with DISJOINT prior heads nothing was required, so no anomaly is invented" \
    '(.anomalies | length | tostring)' "0"
expect_verdict "  and an empty intersection compared nothing, so it is unknown rather than healthy" "unknown"
expect_field "  which it says in as many words" .self_measured_reason "no_required_baseline"

# ==============================================================================
echo "10. ordinary absence is not degradation (intersection + event whitelist)" >&2
D="$(scenario partial-baseline "$PR_CLEAN" "$RUNS_PARTIAL" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a workflow that ran on only ONE prior head is not required of this one" "healthy"
expect_field "  with no anomaly invented from a path filter or a rename" \
    '(.anomalies | length | tostring)' "0"
D="$(scenario dispatch-baseline "$PR_CLEAN" "$RUNS_DISPATCH" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a one-off workflow_dispatch run on a prior head is never 'missing' here" "healthy"

# ==============================================================================
echo "11. the age floor, and the signal it must NOT suppress" >&2
D="$(scenario fresh "$PR_EMPTY_ROLLUP" "$RUNS_NO_HEAD" 60 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a head younger than the floor suppresses the run signals" "unknown"
expect_field "  and says why" .self_measured_reason "head_too_fresh"
expect_field "  with no anomaly manufactured from a workflow that has not started" \
    '(.anomalies | length | tostring)' "0"
D="$(scenario fresh-empty-state "$PR_ANOMALY" "$RUNS_ANOMALY" 60 green)"
run_probe "$PROBE" "$D" --pr 283
expect_kind "the empty-state read is NOT age-suppressed — it is a direct rollup read" "empty_state_check"
expect_verdict "  so the #285 fingerprint survives on a fresh head" "degraded (unattributed)"

echo "12. the empty-state read survives the runs call failing" >&2
D="$(scenario runs-down "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 green)"
: >"$D/runs.fail"
run_probe "$PROBE" "$D" --pr 283
expect_kind "an outage that breaks actions/runs does not take the rollup signal with it" \
    "empty_state_check"
expect_verdict "  and the verdict still reports degradation" "degraded (unattributed)"
expect_errkind "  with the failed call recorded separately" "gh_call_failed"

# ==============================================================================
echo "13. a gh TRANSPORT failure is not_measured, never an anomaly" >&2
D="$(scenario ghfail "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 green)"
: >"$D/pr.fail"
run_probe "$PROBE" "$D" --pr 283
expect_errkind "the failed call is recorded as a probe error" "gh_call_failed"
expect_field "  it is NOT an anomaly (an expired token is not platform degradation)" \
    '(.anomalies | length | tostring)' "0"
expect_verdict "  so the run is unknown, not a confident claim about the platform" "unknown"
expect_status "  and it still exits 0" 0

echo "12b. a FUTURE-dated head is an invalid measurement, not a fresh one" >&2
# `GIT_COMMITTER_DATE` is author-settable and GitHub preserves it, so an
# unclamped age makes a fork-PR author able to suppress the load-bearing signal
# on their own PR forever, under a reason (`head_too_fresh`) that is false on its
# face. A negative age is routed to `head_age_unknown` instead.
# PR_CLEAN, not PR_ANOMALY: an anomaly wins the SELF decision and blanks the
# reason, so the age routing would be invisible.
D="$(scenario future-head "$PR_CLEAN" "$RUNS_CLEAN" -86400 green)"
run_probe "$PROBE" "$D" --pr 301
expect_field "a negative age is not read as a fresh head" .self_measured_reason "head_age_unknown"
expect_field "  and the age is not reported as a number" .head_age_seconds ""

echo "12c. a payload missing a key the call ASKED FOR is a transport failure" >&2
# The call requests statusCheckRollup and mergeStateStatus; validating only
# headRefOid let an absent rollup default to `[]` and the run reach `healthy`
# with an empty error ledger — which this file's own header forbids in as many
# words.
D="$(scenario missing-keys "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
printf '%s\n' '{"number":301,"headRefOid":"aa11bb2","headRefName":"feat/clean"}' >"$D/pr.json"
run_probe "$PROBE" "$D" --pr 301
expect_errkind "the omitted keys are recorded" "incomplete_payload"
expect_field "  and the run is not clean" .self_measured "not_measured"
expect_verdict "  so it is unknown, never healthy" "unknown"

echo "13b. a first-party error is not a clean read either — the ledger is consulted" >&2
# Both gh api calls fail while the ROLLUP is present and clean. The rollup check
# runs and finds nothing, so `clean` is reachable — and reporting it would
# certify a platform the probe half failed to read. Measured on the first
# edition: `{"verdict":"healthy","probe_errors":[…,…]}`, contradicting this
# file and `skills/pr-shepherd/SKILL.md` at once.
D="$(scenario errors-but-clean-rollup "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
: >"$D/commit.fail"
: >"$D/runs.fail"
run_probe "$PROBE" "$D" --pr 301
expect_errkind "the failed calls are on the ledger" "gh_call_failed"
expect_field "  the rollup check really did run, so a clean verdict was reachable" \
    .checks_run.rollup_empty_state "ran"
expect_field "  and it is still not called clean" .self_measured "not_measured"
expect_field "  naming the failed calls as why it could not measure" \
    .self_measured_reason "probe_errors_present"
expect_verdict "  so a half-read platform is unknown, never healthy" "unknown"

echo "14. a structurally incomplete payload is a transport failure too" >&2
D="$(scenario shortpayload "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 green)"
printf '{"number":283}\n' >"$D/pr.json"
run_probe "$PROBE" "$D" --pr 283
expect_errkind "a 0-exit payload missing headRefOid is recorded" "incomplete_payload"
expect_verdict "  and resolves unknown, never healthy" "unknown"

# ==============================================================================
echo "15. attribution is SCOPED — an unrelated component invents no excuse" >&2
D="$(scenario irrelevant "$PR_CLEAN" "$RUNS_CLEAN" 3600 irrelevant)"
run_probe "$PROBE" "$D" --pr 301
expect_field "a Copilot blip is not a check-relevant component" .status_page "operational"
expect_verdict "  so it never manufactures an excuse for a red check" "healthy"

echo "16. a reachable but unrecognisable status payload is unknown, never healthy" >&2
D="$(scenario garbage "$PR_CLEAN" "$RUNS_CLEAN" 3600 garbage)"
run_probe "$PROBE" "$D" --pr 301
expect_field "a 200 carrying non-statuspage JSON is not 'operational'" .status_page "unknown"
expect_verdict "  and the verdict degrades to unknown" "unknown"

# ==============================================================================
echo "16b. a degenerate component scope cannot answer, so it must not say 'operational'" >&2
# `${VAR:-default}` restores the default for an EMPTY value, so the dangerous
# inputs are the non-empty degenerate ones: `,` and `   ` both parse to an empty
# scope, match nothing, and a scope that matches nothing looks exactly like a
# platform with nothing wrong. Measured through the shipped script against a
# major Actions outage, both returned `healthy`.
D="$(scenario degenerate-scope "$PR_CLEAN" "$RUNS_CLEAN" 3600 incident)"
for scope in "," "   "; do
    : >"$WORK/calls"
    PATH="$BIN:$PATH" SCENARIO_DIR="$D" MOCK_CALLS="$WORK/calls" \
    PLATFORM_STATUS_URL="https://status.example.invalid/api/v2/summary.json" \
    PLATFORM_STATUS_COMPONENTS="$scope" \
        bash "$PROBE" --repo mock-org/mock-repo --pr 301 >"$WORK/stdout" 2>"$WORK/stderr"
    STDOUT="$(cat "$WORK/stdout")"
    VERDICT="$(jq -r '.verdict // "«no verdict»"' <<<"$STDOUT" 2>/dev/null)"
    expect_field "a scope of '$scope' matches nothing, so attribution is unknown" \
        .status_page "unknown"
    expect_verdict "  and an open Actions outage is never reported as healthy" "unknown"
done

echo "16c. the status URL is validated before it reaches curl" >&2
# Unvalidated, a value starting `-K` is read by curl as `--config`, which can set
# `output` (arbitrary file write), `upload-file`, `header` or `proxy`; and
# `file://`/`http://` put attacker-chosen text into a field the caller is told to
# report, in a repo that is PUBLIC by exception.
for badurl in "http://status.example.invalid/s.json" "file:///etc/passwd" "-K/tmp/curlrc"; do
    run_probe "$PROBE" "$D" --pr 301 --status-url "$badurl"
    expect_status "a non-https status URL ('$badurl') is refused" 1
done

echo "16d. the runs page reports whether it was truncated" >&2
# Pagination cuts BOTH ways and the under-detect direction reaches `healthy`, so
# the caller is told when the page was full rather than left to assume it was not.
D="$(scenario untruncated "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_field "a short page is reported as not truncated" .checks_run.runs_page_truncated "no"
BIG_RUNS="$(jq -nc '{workflow_runs: ([range(0;100) | {name:"CI", event:"pull_request", head_sha:("h" + (. | tostring))}] + [{name:"CI",event:"pull_request",head_sha:"aa11bb2"}])}')"
D="$(scenario truncated "$PR_CLEAN" "$BIG_RUNS" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_field "a full page is reported as truncated, so the caller can see the limit" \
    .checks_run.runs_page_truncated "yes"

echo "17. the probe never writes" >&2
D="$(scenario readonly "$PR_ANOMALY" "$RUNS_ANOMALY" 3600 incident)"
run_probe "$PROBE" "$D" --pr 283
call_count="$(grep -c . "$WORK/calls")"
if [ "$call_count" -ge 4 ]; then
    ok "the degraded run actually reached the mocks ($call_count calls)"
else
    bad "only $call_count mock calls recorded — the read-only claim below would be vacuous"
fi
# Classified by METHOD, not by path prefix: `gh api repos/o/n/pulls/1/merge -X PUT`
# is a write whose path starts exactly like a read. The scan is per TOKEN and
# matches PREFIXES, because the attached forms are what `gh` documents and what
# people type — `-XPUT`, `-fbody=x`, `--field=body=x` and `--input=-` all slipped
# past a space-padded substring test, and `gh api` becomes a POST the moment any
# `-f` is present. A FUNCTION, because 17d runs it too, and `git` is in the
# corpus for the reason `gh repo view` used to be: the repo derivation is a
# LOCAL command now (#314), and a local write — `git fetch`, `git remote add`,
# `git config --global` — leaves no `gh` line to classify. The two read
# subcommands are whitelisted by their full form, so `git remote add` and
# `git rev-parse HEAD --write-something` are both offending; `gh repo view` is
# NOT whitelisted any more, because the probe must not make that call at all.
offending_calls() { # <calls file> — echoes every recorded call outside the read-only contract
    local line tok
    while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                -X*|--method*|-f*|-F*|--field*|--raw-field*|--input*)
                    printf '%s\n' "$line"; continue 2 ;;
            esac
        done
        case "$line" in
            "gh pr view "*|"gh api repos/"*|"curl "*) : ;;
            "git rev-parse --is-inside-work-tree"|"git remote get-url origin") : ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$1"
}
offending="$(offending_calls "$WORK/calls")"
if [ -z "$offending" ]; then
    ok "every recorded call is a read: no method flag, no field flag, no write verb"
else
    bad "the probe made a call outside its read-only contract:"$'\n'"$offending"
fi

echo "17b. every gh call is bounded, and the OPTIONAL fetch is not the only one" >&2
# The probe's whole trigger condition is "GitHub may be degraded right now", and
# an edition of it bounded the ATTRIBUTION fetch — the half its own header calls
# never load-bearing — while `gh pr view`, the commit read and the runs read ran
# unbounded. A hang there costs the caller its tick, and the caller is a loop.
# Asserted over the SHIM's own ledger rather than over MOCK_CALLS, because the
# bound is invisible from inside the mock `gh`: it sees an identical argv either
# way, which is exactly why nothing caught this.
D_BOUND="$(scenario bounded "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D_BOUND" --pr 301
bound_n="$(grep -c . "$WORK/bounds")"
if [ "$bound_n" -eq 3 ]; then
    ok "all three load-bearing gh calls ran under the bound ($bound_n)"
else
    bad "$bound_n bounded calls recorded, expected 3 (pr view, the commit read, the runs read)"
    sed 's/^/          | B /' <"$WORK/bounds" >&2
fi
# MEASURED HERE, CONSUMED IN 23. The worst-case arithmetic §2b and the probe
# header both state is `sites x (bound + grace) + status timeout`, and `sites`
# is the one term a source-level assertion cannot read off a line. Taking it
# from this run rather than transcribing `3` is CLAUDE.md's rule about counts:
# add a fourth bounded call and the ceiling assertion re-derives itself instead
# of going quietly stale. 17d proves the no---repo path adds none.
BOUNDED_SITES="$bound_n"
unbounded=""
while IFS= read -r line; do
    # `-k 5` is asserted here too: without a kill-after, `timeout` sends TERM
    # and then WAITS for the child, so a `gh` ignoring TERM leaves the bound
    # bounding nothing — this wrapper's own failure mode, surviving inside it.
    case "$line" in "timeout -k 5 $GH_TIMEOUT_PINNED gh "*) : ;; *) unbounded="$unbounded$line"$'\n' ;; esac
done <"$WORK/bounds"
if [ -z "$unbounded" ]; then
    ok "  and each carried the configured PLATFORM_GH_TIMEOUT plus a kill-after"
else
    bad "  a recorded bound did not carry PLATFORM_GH_TIMEOUT and -k:"$'\n'"$unbounded"
fi
# PARITY, beside the count. The count says the three expected calls ran under
# the bound; parity says NO call did not: every `gh` line in the call log has
# a `timeout … gh` line in the shim's ledger. A new reader written as
# `gh api … | jq` or `if gh api …; then` lands in MOCK_CALLS whatever its
# shape, and if it bypassed the bound it is absent from MOCK_BOUNDS. Measured
# before the probe shadowed `gh`: a bare `gh api … >/dev/null` inserted after
# the repo lookup ran unbounded, case 17 whitelisted it as a read, and the
# source grep for `$(gh ` refused one spelling in ten — gate green.
gh_calls="$(grep -c '^gh ' "$WORK/calls")"
if [ "$gh_calls" -eq "$bound_n" ]; then
    ok "  and every gh call in the log has a bound in the ledger ($gh_calls = $bound_n)"
else
    bad "  $gh_calls gh calls were logged but $bound_n ran under the bound — a reader bypasses the shadow"
    sed 's/^/          | C /' <"$WORK/calls" >&2
fi

echo "17c. a bound that FIRES is a transport failure, never an anomaly — at EVERY site" >&2
# 124 is how `timeout` reports a fired bound. It must land where every other
# non-zero gh exit lands — `not_measured`, reason preserved — and NOT in
# `anomalies`, because a call we cut off ourselves tells us even less about the
# platform than one that errored. Getting this wrong reports our own timeout as
# evidence of degradation, which is the confident wrong answer this file exists
# to refuse, reached through the mitigation for a different one.
# PER SITE, because an empty `gh.timeout` fires on the FIRST bounded call and
# the first call absorbs it: an edition of this case covered `gh pr view`
# alone, and rewriting either later site to raise an anomaly on 124 — while
# still recording an error on every OTHER non-zero exit, so no plain-failure
# case could see it — left the gate green. The selector fires the bound at
# the site under test and lets the earlier calls succeed; the detail is then
# asserted to name that site, so the loop cannot pass three times on the
# first call. There is no fourth site: the repo derivation is local now (#314),
# which is what 17d measures instead.
for site in "pr view" "commits/" "actions/runs"; do
    case "$site" in
        "pr view")      tmo_sc=ghtimeout;        tmo_sel="";             tmo_reason="pr_read_failed" ;;
        "commits/")     tmo_sc=ghtimeout-commit; tmo_sel="commits/";     tmo_reason="" ;;
        "actions/runs") tmo_sc=ghtimeout-runs;   tmo_sel="actions/runs"; tmo_reason="" ;;
    esac
    D_TMO="$(scenario "$tmo_sc" "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
    printf '%s' "$tmo_sel" >"$D_TMO/gh.timeout"
    run_probe "$PROBE" "$D_TMO" --pr 301
    expect_verdict "[$site] a timed-out gh call resolves unknown, never degraded" "unknown"
    expect_status "  and still exits 0" 0
    expect_field "  the run is not_measured" .self_measured "not_measured"
    [ -z "$tmo_reason" ] || expect_field "  and says which read it could not make" .self_measured_reason "$tmo_reason"
    expect_errkind "  the ledger records it as a transport failure" "gh_call_failed"
    expect_field "  and it raised NO anomaly" '(.anomalies | length | tostring)' "0"
    tmo_detail="$(jq -r '[.probe_errors[] | select(.kind == "gh_call_failed") | .detail] | join(" ")' <<<"$STDOUT" 2>/dev/null)"
    if grep -qF -- "PLATFORM_GH_TIMEOUT bound fired" <<<"$tmo_detail"; then
        ok "  and the detail names OUR bound rather than leaving a bare 'exited 124'"
    else
        bad "  the detail does not name the bound that fired: '$tmo_detail'"; dump
    fi
    case "$tmo_detail" in
        *"$site"*) ok "  and it fired at the site under test, not at the first call" ;;
        *) bad "  the bound fired somewhere other than '$site': '$tmo_detail'"; dump ;;
    esac
    # THE REASON REACHES THE HUMAN CHANNELS (issue #314). This detail lived in
    # `probe_errors[].detail`, which nothing renders — so `explains` and the
    # stderr summary said "the probe could not measure" for a GitHub call the
    # probe itself cut off after twenty seconds and for `no --pr was given`
    # alike, on the one verdict an operator reads during the incident this
    # probe was written for.
    expect_explains_names "  and explains — the field callers report — names the fired bound" \
        "PLATFORM_GH_TIMEOUT bound fired"
done

echo "17c2. the KILL GRACE firing is the same bound firing, on the path -k exists for" >&2
# `timeout -k 5 30 gh …` reports 124 when TERM sufficed and 137 when it did not
# and the grace had to fire. An edition of the probe recognised 124 alone, so
# the one path `-k 5` was added for — a `gh` ignoring TERM — was the one path
# it could not name: a bare `exited 137` at the three first-party sites, and
# at the lookup the 137 fell through control flow into `not in a GitHub repo`.
# PER SITE, like 17c: an empty `gh.killed` is absorbed by the first call, and
# a commit-site `-eq 137` anomaly was measured green while only that call was
# covered. The detail is asserted to name the site under test.
for site in "pr view" "commits/" "actions/runs"; do
    case "$site" in
        "pr view")      kill_sc=ghkilled;        kill_sel="" ;;
        "commits/")     kill_sc=ghkilled-commit; kill_sel="commits/" ;;
        "actions/runs") kill_sc=ghkilled-runs;   kill_sel="actions/runs" ;;
    esac
    D_KILL="$(scenario "$kill_sc" "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
    printf '%s' "$kill_sel" >"$D_KILL/gh.killed"
    run_probe "$PROBE" "$D_KILL" --pr 301
    expect_verdict "[$site] a kill-grace exit resolves unknown, never degraded" "unknown"
    expect_status "  and still exits 0" 0
    expect_errkind "  the ledger records it as a transport failure" "gh_call_failed"
    expect_field "  and it raised NO anomaly" '(.anomalies | length | tostring)' "0"
    kill_detail="$(jq -r '[.probe_errors[] | select(.kind == "gh_call_failed") | .detail] | join(" ")' <<<"$STDOUT" 2>/dev/null)"
    if grep -qF -- "PLATFORM_GH_TIMEOUT bound fired" <<<"$kill_detail" && grep -qF -- "kill grace" <<<"$kill_detail"; then
        ok "  and the detail names the bound AND the grace, not a bare 'exited 137'"
    else
        bad "  the detail does not name the bound and the grace: '$kill_detail'"; dump
    fi
    case "$kill_detail" in
        *"$site"*) ok "  and it fired at the site under test, not at the first call" ;;
        *) bad "  the grace fired somewhere other than '$site': '$kill_detail'"; dump ;;
    esac
done

echo "17d. the repo is derived LOCALLY, and a failed derivation still reaches a verdict" >&2
# THIS SITE WAS THE FOURTH `gh` CALL AND IS NOW NONE (issue #314). `gh repo view`
# answers "which repo is this checkout" through the network, and on a 5xx, an
# expired token or a dead link it exits 1 with EMPTY STDOUT — indistinguishable
# from "not in a repo", which is what the probe then printed, inside a valid
# checkout, while GitHub was failing. #312 bounded the call and taught it 124 and
# 137; every other non-zero exit still produced the false cause. So the slug now
# comes from the `origin` remote via git, and this case measures three things
# nothing else can: the call is GONE, the derivation is correct across the URL
# forms git writes, and every way it can fail still yields a verdict.
#
# The cwd is an INPUT here, which is why these runs carry CWD_OVERRIDE. Running
# from `$REPO_ROOT` would derive whatever `origin` this checkout has — a fork's
# slug on a fork PR, and this repo is PUBLIC so fork PRs are ordinary — and an
# equality against that is either vacuous or host-dependent.
#
# THE PARENTHETICAL NAMES FIXTURES BY TOKEN, NOT BY PROSE (issue #324). It used
# to read `ssh://, no-origin, unparsable, host-in-path, …` — a SECOND vocabulary
# for the same fourteen fixtures, and the reason this site could not be checked
# against any other: no mechanical rule maps `CWD_BADURL` to "unparsable". The
# tokens are what every other site already uses — the `CWD_MISSING` suffixes,
# both verdict loops, the read-back loop — so one vocabulary is what makes the
# inventory guard below possible. The prose those names carried is not lost; it
# is the comment beside each fixture, which is where it belongs.
if [ -z "$CWD_MISSING" ]; then
    ok "the cwd fixtures were built (ssh, https, sshproto, noorigin, badurl, hostpath, trailing, threeseg, badchar, otherhost, emptyseg, oneseg, broken, bare)"
else
    bad "the cwd fixtures could not be built; missing:$CWD_MISSING"
fi
# THE PINS ARE PROVED TO BIND, not assumed to. `url.<base>.insteadOf` in the
# developer's own config rewrites what `get-url` returns, and this org's dotfiles
# set exactly that — so a laptop with an ssh rewrite would run the `https://` arm
# against an ssh URL and report a pass for a form it never exercised. Reading the
# literal back under the same pins `run_probe` uses turns that into a named
# failure (review of #321).
#
# `badurl` JOINED THIS LOOP WITH THE INVENTORY GUARD (issue #324). Be exact
# about why, because the first version of this comment was not. This loop is NOT
# what stops an `insteadOf` rewrite — the hermetic pins are, at every site
# that read a fixture, and they were all in place before this change and are
# untouched by it. The loop PROVES the pins bind, over the literal each fixture
# stored. `badurl` was the one fixture given an origin URL and left out of that
# proof, and its literal is the one the credential-leak assertion at the end of
# 17d depends on — a MUST-NOT-APPEAR, so a fixture whose remote had changed
# under it would pass having looked for a string nothing carried. Defence in
# depth over the pins, never a replacement for them: if you are about to read
# `run_probe`'s pin as redundant with this loop, that is the deletion this
# comment exists to refuse, and the census in the guard below now refuses it too.
#
# The set is derived from the BUILT TREE (`git remote get-url origin` per
# fixture), with the `make_cwd` read kept only as a cross-check, so a
# twelfth URL-carrying fixture cannot be added without landing here.
url_pin_bad=""
for pin_form in ssh https sshproto badurl hostpath trailing threeseg badchar otherhost emptyseg oneseg; do
    # RESET PER ITERATION, AND A `*)` ARM BELOW. Without both, a token with no
    # arm behind it silently re-measures the PREVIOUS fixture and reports a pass
    # for a form nothing exercised — the vacuity this loop exists to refuse,
    # reached through the loop's own control flow (review of #324).
    pin_dir=""
    pin_want=""
    case "$pin_form" in
        ssh)      pin_dir="$CWD_SSH";      pin_want="git@github.com:mock-org/mock-repo.git" ;;
        https)    pin_dir="$CWD_HTTPS";    pin_want="https://github.com/mock-org/mock-repo.git" ;;
        sshproto) pin_dir="$CWD_SSHPROTO"; pin_want="ssh://git@github.com/mock-org/mock-repo" ;;
        # ONE literal for this remote, shared with the credential-leak assertion
        # at the end of 17d, whose needle is DERIVED from it. Four uncoupled
        # copies used to exist and this loop coupled only two of them.
        badurl)   pin_dir="$CWD_BADURL";   pin_want="$BADURL_REMOTE" ;;
        # These two ARE the input under test, so a rewrite would not merely
        # exercise the wrong form — it would delete the case.
        hostpath) pin_dir="$CWD_HOSTPATH"; pin_want="https://evil.example/path@github.com/mock-org/mock-repo" ;;
        trailing) pin_dir="$CWD_TRAILING"; pin_want="https://github.com/mock-org/mock-repo.git/" ;;
        threeseg) pin_dir="$CWD_THREESEG"; pin_want="https://github.com/mock-org/mock-repo/extra" ;;
        badchar)  pin_dir="$CWD_BADCHAR";  pin_want="https://github.com/mock-org/mock~repo" ;;
        otherhost) pin_dir="$CWD_OTHERHOST"; pin_want="https://gitlab.com/mock-org/mock-repo" ;;
        emptyseg)  pin_dir="$CWD_EMPTYSEG";  pin_want="https://github.com//mock-repo" ;;
        oneseg)    pin_dir="$CWD_ONESEG";    pin_want="https://github.com/mock-repo" ;;
        *) url_pin_bad="$url_pin_bad [$pin_form: no arm in this case — the loop list and the arms disagree]"; continue ;;
    esac
    pin_got="$( cd "$pin_dir" && GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL" \
        GIT_CONFIG_NOSYSTEM="$GIT_HERMETIC_NOSYSTEM" git remote get-url origin 2>/dev/null )"
    [ "$pin_got" = "$pin_want" ] || url_pin_bad="$url_pin_bad [$pin_form: got '$pin_got' want '$pin_want']"
done
if [ -z "$url_pin_bad" ]; then
    ok "  and each fixture's origin reads back as the literal written, so no insteadOf rewrite is in play"
else
    bad "  a fixture's origin URL was rewritten before the probe saw it:$url_pin_bad"
fi
# The bare-directory fixture must really be outside a checkout, or the
# "not in a work tree" case below silently measures the opposite branch.
if [ "$( cd "$CWD_NOREPO" && git rev-parse --is-inside-work-tree 2>/dev/null )" = "true" ]; then
    bad "the not-a-repo fixture IS inside a work tree — \$TMPDIR sits in a checkout on this host"
else
    ok "  and the not-a-repo fixture really is outside any work tree"
fi

# THE FIXTURE INVENTORY IS CHECKED MECHANICALLY, NOT IN PROSE (issue #324). Nine
# review rounds of prose did not hold it: three consecutive commits each added a
# fixture and missed at least one site, and the header paragraph recording those
# misses was itself one of the sites missed, twice. A missing entry is SILENT —
# the fixture is built and simply never asserted.
#
# The set is DERIVED, and each member is required at three sites this file
# hand-maintains. Only those three: the header enumeration and the prose comment
# beside the fixtures — the two ALWAYS missed — stay unchecked, so closing #324
# did not make them checked, and the co-move list in the header still names all
# of them.
#
# THE EXTRACTION LAYER IS THE PART TO GET RIGHT, because every way it can
# under-read is the defect this block exists to stop, one level up: a guard that
# silently measures one fixture fewer prints a reassuring `ok` for a fixture
# nobody checked. The first review of this block found six such escapes — five
# silent greens and one that misdiagnosed rather than passed, each re-measured
# against the edition it escaped and recorded in this file's header (#324). The
# answers to them are structural rather than careful:
#
#   * CONTINUATIONS ARE JOINED FIRST. A `make_cwd` whose URL wraps onto the next
#     physical line left the URL-carrying set — and that wrapped shape ALREADY
#     EXISTS in this file, at `hostpath`'s `||`. Every read below runs against a
#     copy with backslash-continuations joined, so a rewrap cannot change what is
#     measured. Joining merges lines and never reorders them, which is what makes
#     the line-number comparison at the end of this block valid on the copy.
#   * THE DECLARATION READ IS NOT COLUMN-ANCHORED, AND IS CROSS-CHECKED BY A
#     SECOND DERIVATION. Indenting a `CWD_*=` line by four spaces is still valid
#     bash and used to drop the fixture out of the set entirely — required at
#     zero sites, four `ok` lines, nothing red. Leading whitespace is now
#     allowed, and the value must be a `"$WORK/` path, which also stops
#     `CWD_OVERRIDE` from injecting a phantom `override` fixture the day its env
#     prefixes are reordered. Independently, the set is compared BOTH WAYS
#     against the `CWD_MISSING` ledger — unanchored, and the one site that
#     already names every non-exempt fixture including `broken` and `bare`, which
#     have no `make_cwd` call at all. Two derivations that must agree; no count.
#   * THE FOUR SINGLE-LINE SITES ARE ASSERTED TO HAVE MATCHED EXACTLY ONE LINE,
#     and their reads are newline-normalised. All four were neither. The
#     directions this was measured in are recorded ONCE, in the header
#     paragraph that begins "the second column-0 `for form in`" — including
#     which direction was NOT reproduced and why. Stating it twice is how the
#     two records came to disagree about the token and about what was measured;
#     this one cites, it does not restate: a second column-0 `for form in …`
#     (this file already carries two identical `for site in …` headers, so the
#     shape is established practice) made `trailing` present in BOTH verdict
#     loops read as a pass, while `sshproto` — plainly present — read as "in 0 of
#     the 2 verdict loops". An unnormalised multi-line capture breaks membership
#     in whichever direction the newline lands. Exactly-once is the idiom the
#     rest of this file already uses where it reads its own or the probe's
#     source — the `command gh` chokepoint, the unsafe-class definition, the jq
#     fault injection, the carve-out headings and `apply_mutation`'s own
#     stale-target check all assert it; this block settled for a floor and was
#     the odd one out.
#   * THE `SELF_ABS` PLACEMENT IS PINNED, NOT MERELY DOCUMENTED. It must be
#     assigned BEFORE the `cd "$REPO_ROOT"`, and CI cannot see it if it moves:
#     preflight runs this gate FROM the repo root, where post-`cd` resolution
#     happens to succeed. The failure only reaches a contributor running
#     `cd scripts && bash test-platform-health-probe.sh` — and it is the exact
#     regression #324 records as the reason a first attempt was reverted, so it
#     would have shipped green. Both anchors are asserted unique and then
#     ordered.
#
# TWO EXEMPTIONS, BY NAME RATHER THAN BY SILENCE. `CWD_MISSING` is the
# accumulator, not a fixture: it is required to exist as its own declaration and
# required NOT to be a `"$WORK/` fixture. `CWD_NOREPO` is the bare `mkdir` —
# outside the ledger and outside the built message, with its own work-tree
# assertion above — and it is exempt from the TOKEN rule alone, because the
# failure loop reaches it as `notree`; that token is asserted present, so its
# exemption cannot quietly become an exemption from coverage. Renaming either is
# red twice over: the exemption stops resolving, and the new name arrives as a
# fixture required at all three sites.
#
# THE HERMETIC PINS ARE PART OF THE SAME CENSUS, and they are what actually
# suppresses an `insteadOf` rewrite — the read-back loop only PROVES they bind.
# They live at four sites and none was pinned by anything, so deleting the
# `run_probe` one reddened nothing while being the deletion the read-back cannot
# see: the read-back measures its own subshell, not the probe's.
# The joiner honours the two continuation rules that bite here — it is NOT a
# shell parser. `awk '{ while (line ~ /\\$/) ... }'` treated any
# trailing backslash as a continuation, which shell does not: a `\` ending a
# COMMENT is comment text, and an EVEN run of backslashes is an escaped
# backslash. The first case is a new absorption class this very block created —
# appending one ` \` to a comment made it swallow the `make_cwd` call beneath
# it, dropping that fixture out of `fixt_url` and letting it be deleted from the
# read-back list with every assertion still green. Joining removed the wrapped
# `make_cwd` escape and introduced its inverse.
#
# Residual, stated rather than implied: it still honours a trailing backslash on
# a comment line REACHED BY A JOIN (the `#` test sees the joined line's start),
# and it joins a backslash inside single quotes, where bash would not. Neither
# shape exists at head — no comment line ends in a backslash, and the one
# in-quotes backslash is not at end of line — and both fail in the SAFE
# direction here, producing a false red rather than a silent absorption.
FIXT_SRC="$WORK/self-joined.sh"
awk '
function odd_trailing_backslashes(s,   n) {
    n = 0
    while (n < length(s) && substr(s, length(s) - n, 1) == "\\") n++
    return n % 2
}
{
    line = $0
    while (line !~ /^[[:space:]]*#/ && odd_trailing_backslashes(line)) {
        sub(/\\$/, "", line)
        if ((getline nxt) <= 0) break
        sub(/^[[:space:]]+/, " ", nxt)
        line = line nxt
    }
    print line
}' "$SELF_ABS" >"$FIXT_SRC"
# ONE COMMENT-STRIPPED COPY, built once. The source reads below ran over the
# raw joined file, so a commented-out fixture line still counted — yielding two
# reds naming causes that do not exist (a declared fixture "missing" from loops
# it was never in). Commenting a fixture out is how you disable one; it must
# read as absent, not as broken.
FIXT_LIVE="$WORK/self-joined-live.sh"
sed 's/^[[:space:]]*#.*$//' "$FIXT_SRC" >"$FIXT_LIVE"
fixt_exempt="norepo"
fixt_all="$(sed -n 's/^[[:space:]]*CWD_\([A-Z][A-Z0-9_]*\)="\$WORK\/.*/\1/p' "$FIXT_LIVE" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
fixt_acc="$(sed -n 's/.*CWD_MISSING="\$CWD_MISSING \([a-z][a-z0-9]*\)".*/\1/p' "$FIXT_LIVE" | tr '\n' ' ')"
fixt_url="$(sed -n 's/^[[:space:]]*make_cwd  *"\$CWD_\([A-Z][A-Z0-9_]*\)" *"[^"]*".*/\1/p' "$FIXT_LIVE" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
# THE URL-CARRYING SET IS DERIVED FROM WHAT WAS BUILT, not from source text.
# The first attempt at a second derivation shared the first read's anchor: both
# required the literal `"$CWD_` for the first argument, so `"${CWD_HOSTPATH}"`
# and an unquoted origin missed BOTH reads and the two agreed by MISSING
# TOGETHER — which is the one way two derivations are worse than one, because
# agreement then looks like confirmation. It closed the four shapes it named and
# not the class, while its own prose claimed to be "anchored nowhere".
#
# A fixture that answers `git remote get-url origin` HAS an origin, whatever the
# call that built it looked like: brace-, quote-, spacing- and joiner-
# independent by construction, because it reads the built tree rather than the
# text that built it. `fixt_url` stays as the source read and is cross-checked
# against this one, so a source read that drifts is reported rather than
# silently agreeing.
fixt_url_built=""
for fx in $fixt_all; do
    case " $fixt_exempt " in *" $fx "*) continue ;; esac
    fx_upper="$(printf '%s' "$fx" | tr '[:lower:]' '[:upper:]')"
    eval "fx_dir=\${CWD_$fx_upper:-}"
    [ -n "$fx_dir" ] && [ -d "$fx_dir" ] || continue
    if ( cd "$fx_dir" \
         && GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL" \
            GIT_CONFIG_NOSYSTEM="$GIT_HERMETIC_NOSYSTEM" \
            git remote get-url origin >/dev/null 2>&1 ); then
        fixt_url_built="$fixt_url_built $fx"
    fi
done
fixt_url_built="${fixt_url_built# }"
fixt_built_raw="$(sed -n 's/^[[:space:]]*ok "the cwd fixtures were built (\([^)]*\))".*/\1/p' "$FIXT_SRC")"
fixt_pin_raw="$(sed -n 's/^for pin_form in \(.*\); do$/\1/p' "$FIXT_SRC")"
fixt_succ_raw="$(sed -n 's/^for form in \(.*\); do$/\1/p' "$FIXT_SRC")"
fixt_fail_raw="$(sed -n 's/^for shape in \(.*\); do$/\1/p' "$FIXT_SRC")"
fixt_n_built="$(grep -c . <<<"$fixt_built_raw")"
fixt_n_pin="$(grep -c . <<<"$fixt_pin_raw")"
fixt_n_succ="$(grep -c . <<<"$fixt_succ_raw")"
fixt_n_fail="$(grep -c . <<<"$fixt_fail_raw")"
fixt_site_bad=""
[ "$fixt_n_built" -eq 1 ] || fixt_site_bad="$fixt_site_bad [the built message: $fixt_n_built lines]"
[ "$fixt_n_pin"   -eq 1 ] || fixt_site_bad="$fixt_site_bad [the url_pin_bad loop: $fixt_n_pin lines]"
[ "$fixt_n_succ"  -eq 1 ] || fixt_site_bad="$fixt_site_bad [the success verdict loop: $fixt_n_succ lines]"
[ "$fixt_n_fail"  -eq 1 ] || fixt_site_bad="$fixt_site_bad [the failure verdict loop: $fixt_n_fail lines]"
if [ -z "$fixt_site_bad" ]; then
    ok "  and each of the four single-line sites was read from EXACTLY one line, so no read is empty or doubled"
else
    bad "  a single-line site did not match exactly one line, so its membership tests are wrong in one direction or the other:$fixt_site_bad"
fi
fixt_built="$(tr ',\n' '  ' <<<"$fixt_built_raw")"
fixt_pin="$(tr '\n' ' ' <<<"$fixt_pin_raw")"
fixt_succ="$(tr '\n' ' ' <<<"$fixt_succ_raw")"
fixt_fail="$(tr '\n' ' ' <<<"$fixt_fail_raw")"
fixt_derived_bad=""
[ -n "$fixt_all" ] || fixt_derived_bad="$fixt_derived_bad [the CWD_* declarations: empty]"
[ -n "$fixt_acc" ] || fixt_derived_bad="$fixt_derived_bad [the CWD_MISSING ledger: empty]"
[ -n "$fixt_url" ] || fixt_derived_bad="$fixt_derived_bad [the make_cwd URL arguments: empty]"
[ -n "$fixt_url_built" ] || fixt_derived_bad="$fixt_derived_bad [no fixture answered git remote get-url: the built set is empty]"
# THE TWO READS MUST AGREE, both directions. Non-emptiness alone was the whole
# guard on this set, and it holds while a fixture silently leaves it.
for fx in $fixt_url; do
    case " $fixt_url_built " in *" $fx "*) : ;;
        *) fixt_derived_bad="$fixt_derived_bad [$fx: the source read calls it URL-carrying but the built tree has no origin for it]" ;;
    esac
done
for fx in $fixt_url_built; do
    case " $fixt_url " in *" $fx "*) : ;;
        *) fixt_derived_bad="$fixt_derived_bad [$fx: HAS an origin in the built tree but the source read missed it — position or quoting, not absence]" ;;
    esac
done
for fx in $fixt_url; do
    case " $fixt_all " in *" $fx "*) ;; *) fixt_derived_bad="$fixt_derived_bad [$fx: given an origin URL but not declared]" ;; esac
done
if [ -z "$fixt_derived_bad" ]; then
    ok "  and the four derived sets are non-empty, with every URL-carrying fixture among the declared ones"
else
    bad "  a derivation came back empty or disagreed with the declarations, so the parity checks are vacuous:$fixt_derived_bad"
fi
fixt_ledger_bad=""
for fx in $fixt_all; do
    case " $fixt_exempt " in *" $fx "*) continue ;; esac
    case " $fixt_acc " in *" $fx "*) ;; *) fixt_ledger_bad="$fixt_ledger_bad [$fx: declared, absent from the CWD_MISSING ledger]" ;; esac
done
for fx in $fixt_acc; do
    case " $fixt_all " in *" $fx "*) ;; *) fixt_ledger_bad="$fixt_ledger_bad [$fx: in the CWD_MISSING ledger, not declared]" ;; esac
done
if [ -z "$fixt_ledger_bad" ]; then
    ok "  and the declarations and the CWD_MISSING ledger name the same fixtures, both directions"
else
    bad "  the two derivations disagree, so one of them is reading past a fixture:$fixt_ledger_bad"
fi
fixt_exempt_bad=""
fixt_n_acc_decl="$(grep -c '^CWD_MISSING=""$' "$FIXT_SRC")"
[ "$fixt_n_acc_decl" -eq 1 ] || fixt_exempt_bad="$fixt_exempt_bad [CWD_MISSING: $fixt_n_acc_decl accumulator declarations, want 1]"
case " $fixt_all " in *" missing "*) fixt_exempt_bad="$fixt_exempt_bad [CWD_MISSING: declared as a \$WORK fixture — it is the accumulator, not one]" ;; esac
case " $fixt_all " in *" norepo "*) ;; *) fixt_exempt_bad="$fixt_exempt_bad [CWD_NOREPO: not declared, so exempting it exempts nothing]" ;; esac
case " $fixt_fail " in *" notree "*) ;; *) fixt_exempt_bad="$fixt_exempt_bad [CWD_NOREPO: the failure loop no longer reaches it as 'notree']" ;; esac
if [ -z "$fixt_exempt_bad" ]; then
    ok "  and both exemptions hold by name: CWD_MISSING is the accumulator, CWD_NOREPO runs as 'notree'"
else
    bad "  an exemption no longer resolves, so it exempts nothing:$fixt_exempt_bad"
fi
fixt_msg_bad=""
fixt_loop_bad=""
fixt_pin_bad=""
for fx in $fixt_all; do
    case " $fixt_exempt " in *" $fx "*) continue ;; esac
    case " $fixt_built " in *" $fx "*) ;; *) fixt_msg_bad="$fixt_msg_bad $fx" ;; esac
    fixt_n=0
    case " $fixt_succ " in *" $fx "*) fixt_n=$((fixt_n + 1)) ;; esac
    case " $fixt_fail " in *" $fx "*) fixt_n=$((fixt_n + 1)) ;; esac
    [ "$fixt_n" -eq 1 ] || fixt_loop_bad="$fixt_loop_bad [$fx: in $fixt_n of the 2 verdict loops]"
done
for fx in $fixt_url_built; do
    case " $fixt_exempt " in *" $fx "*) continue ;; esac
    case " $fixt_pin " in *" $fx "*) ;; *) fixt_pin_bad="$fixt_pin_bad $fx" ;; esac
done
# THE REVERSE DIRECTION. Everything above walks declarations -> loops, so a
# token that appears in a verdict loop WITH an arm but has no CWD_* declaration
# behind it is required nowhere and checked by nothing — the inventory gap
# pointing the other way. Exemptions are by name, like the others.
fixt_loop_exempt="notree nogit"
fixt_rev_bad=""
# The exemptions are asserted to be LIVE, the same way CWD_MISSING and
# CWD_NOREPO are: an exemption naming a token no loop runs any more exempts
# nothing and hides the next real one behind a stale name.
for fx in $fixt_loop_exempt; do
    case " $fixt_succ $fixt_fail " in *" $fx "*) ;;
        *) fixt_rev_bad="$fixt_rev_bad [$fx: exempted from the reverse check but no verdict loop runs it]" ;;
    esac
done
for fx in $fixt_succ $fixt_fail; do
    case " $fixt_all " in *" $fx "*) continue ;; esac
    case " $fixt_loop_exempt " in *" $fx "*) continue ;; esac
    fixt_rev_bad="$fixt_rev_bad [$fx: run by a verdict loop but declared by no CWD_* fixture]"
done
if [ -z "$fixt_msg_bad" ]; then
    ok "  and every declared fixture is named in the built message"
else
    bad "  a declared fixture is missing from the built message (site 1 of 3):$fixt_msg_bad"
fi
if [ -z "$fixt_loop_bad" ]; then
    ok "  and every declared fixture runs the probe in exactly one verdict loop"
else
    bad "  a declared fixture is in neither or both verdict loops (site 2 of 3):$fixt_loop_bad"
fi
if [ -z "$fixt_rev_bad" ]; then
    ok "  and every verdict-loop token resolves to a declared fixture (or a named exemption)"
else
    bad "  a verdict loop runs a token no declaration backs, so nothing requires it anywhere:$fixt_rev_bad"
fi
if [ -z "$fixt_pin_bad" ]; then
    ok "  and every fixture given an origin URL is read back in the url_pin_bad loop"
else
    bad "  a URL-carrying fixture is missing from the url_pin_bad read-back (site 3 of 3):$fixt_pin_bad"
fi
fixt_order_bad=""
# Read from the REAL file, not the joined copy: the message prints LINE
# NUMBERS, and joined-copy numbers coincide with the source only while no
# continuation precedes the anchors. They would silently start pointing at the
# wrong lines in the one message that fires for a regression CI cannot see.
fixt_n_self="$(grep -c '^SELF_ABS=' "$SELF_ABS")"
fixt_n_cd="$(grep -c '^cd "\$REPO_ROOT" || exit 1$' "$SELF_ABS")"
if [ "$fixt_n_self" -ne 1 ] || [ "$fixt_n_cd" -ne 1 ]; then
    fixt_order_bad="the anchors are not unique (SELF_ABS= x$fixt_n_self, cd \"\$REPO_ROOT\" x$fixt_n_cd)"
else
    fixt_at_self="$(grep -n '^SELF_ABS=' "$SELF_ABS" | cut -d: -f1)"
    fixt_at_cd="$(grep -n '^cd "\$REPO_ROOT" || exit 1$' "$SELF_ABS" | cut -d: -f1)"
    [ "$fixt_at_self" -lt "$fixt_at_cd" ] || \
        fixt_order_bad="SELF_ABS is assigned at line $fixt_at_self, AFTER the cd at line $fixt_at_cd — every read above resolves against the wrong cwd from any directory but the repo root"
fi
if [ -z "$fixt_order_bad" ]; then
    ok "  and SELF_ABS is still assigned BEFORE the cd, which is the placement CI cannot observe"
else
    bad "  the SELF_ABS placement regressed: $fixt_order_bad"
fi
fixt_pins_bad=""
# THE PINNED VALUES, NOT JUST THE NAMES. The census used to grep for
# `GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL"` — the variable NAME — so rewriting
# the declarations to `GIT_HERMETIC_GLOBAL="${HOME}/.gitconfig"` and
# `GIT_HERMETIC_NOSYSTEM=0` kept every site "pinned" while reverting all four to
# the developer's real config, still printing the four-sites ok. The reviewing
# machine's own ~/.gitconfig carries a Sassy-Dog insteadOf, which is why these
# pins exist at all.
# THE VALUES ARE ASSERTED AT RUNTIME, not read out of the source. A source read
# is shape-bound by construction, and the shape it misses is the one an editor
# reaches for: `^NAME=` saw a bare column-0 duplicate and NOT an indented line,
# an `export`, a `local` inside a function, or an assignment inside an `if` —
# all four rebound every pinned site while the census printed ok, measured. This
# is the same move the URL derivation made: ask the running program what it has,
# rather than parsing the text that set it.
[ "$GIT_HERMETIC_GLOBAL" = "/dev/null" ] || \
    fixt_pins_bad="$fixt_pins_bad [GIT_HERMETIC_GLOBAL is '$GIT_HERMETIC_GLOBAL', not /dev/null]"
[ "$GIT_HERMETIC_NOSYSTEM" = "1" ] || \
    fixt_pins_bad="$fixt_pins_bad [GIT_HERMETIC_NOSYSTEM is '$GIT_HERMETIC_NOSYSTEM', not 1]"
# And the `readonly` that makes a later rebinding fail loudly must still be
# there: without this, deleting it reddens nothing and the runtime check above
# only proves nothing rebound them BEFORE this line.
# Captured, not piped: `readonly -p` is an unbounded writer and `grep -q` exits
# at its first match, which is the SIGPIPE-under-pipefail shape this repo's own
# gate refuses (issue #256). It caught this line when it was written.
fixt_readonly="$(readonly -p 2>/dev/null)"
for hv in GIT_HERMETIC_GLOBAL GIT_HERMETIC_NOSYSTEM; do
    case "$fixt_readonly" in
        *"$hv="*) : ;;
        *) fixt_pins_bad="$fixt_pins_bad [$hv is not readonly — a later assignment of any shape would rebind every site silently]" ;;
    esac
done
# The source count stays as an ORDERING guard only, widened to the shapes a
# reader might use and read from the comment-stripped copy. It cannot see
# `: "${X:=…}"`, `printf -v` or `read`, which is why it is no longer what the
# guarantee rests on.
for hv in GIT_HERMETIC_GLOBAL GIT_HERMETIC_NOSYSTEM; do
    hn=$(grep -cE "^[[:space:]]*(export|local|declare|readonly|typeset)?[[:space:]]*$hv=" "$FIXT_LIVE")
    [ "$hn" -eq 1 ] || fixt_pins_bad="$fixt_pins_bad [$hv: $hn assignments in source, want exactly one]"
done

# A COMMENT-STRIPPED COPY. `grep -qF` over the raw region is satisfied by the
# pin appearing in a comment — and the paragraph beginning "THE PROSE COPIES
# ARE GONE" explicitly predicts an editor
# reading run_probe's pin as redundant, which is exactly the editor who leaves
# the note behind. Deleting the live pin and leaving the commented one was
# `all pass (420)`; under a global url.insteadOf rewrite the same tree went red
# with six failures, proving the deleted line was load-bearing.
# Comments stripped, AND this census's own pattern declarations removed — they
# are literals describing a pin, not a site that applies one, and counting them
# would make the census claim one more site than exists. Renaming PIN_G/PIN_N
# breaks this deletion visibly rather than silently, because the count then
# disagrees with the regions walked.
fixt_live="$(sed '/^PIN_[GN]=/d' "$FIXT_LIVE")"
PIN_G='GIT_CONFIG_GLOBAL="$GIT_HERMETIC_GLOBAL"'
PIN_N='GIT_CONFIG_NOSYSTEM="$GIT_HERMETIC_NOSYSTEM"'
fixt_pin_sites=$(grep -cF -- "$PIN_G" <<<"$fixt_live")

pin_regions="make_cwd bare-repo run_probe read-back url-derive"
fixt_regions_seen=0
for pin_region in $pin_regions; do
    fixt_region=""
    case "$pin_region" in
        make_cwd)  fixt_region="$(sed -n '/^make_cwd() {/,/^}/p' "$FIXT_SRC")" ;;
        # STRUCTURAL terminator. `git init -q --bare` matched a flag ORDER, not
        # a structure, so reordering it to `git init --bare -q .` — semantically
        # identical — or reflowing the block with backslash continuations left
        # the sed range UNTERMINATED, running to EOF — measured on two editions
        # of this file at 1183 and 2734 lines from a 3-line region,
        # swallowing two unrelated pin occurrences and passing. The `-z` guard
        # below cannot see that, because an unterminated range is not empty, it
        # is maximal; the length bound is what catches it.
        bare-repo) fixt_region="$(sed -n '/^mkdir -p "\$CWD_BARE"/,/^[[:space:]]*git init .*--bare/p' "$FIXT_SRC")" ;;
        run_probe) fixt_region="$(sed -n '/^run_probe() {/,/^}/p' "$FIXT_SRC")" ;;
        read-back) fixt_region="$(sed -n '/^for pin_form in /,/^done$/p' "$FIXT_SRC")" ;;
        # The runtime URL derivation is itself a site that reads a fixture under
        # the pins, so it is a census region. The count check found it the
        # moment it was written — 5 live pin sites against 4 regions walked —
        # which is the census doing exactly its job on code added after it.
        url-derive) fixt_region="$(sed -n '/^fixt_url_built=""$/,/^fixt_url_built="\${fixt_url_built# }"$/p' "$FIXT_SRC")" ;;
        *) fixt_pins_bad="$fixt_pins_bad [$pin_region: no region arm]"; continue ;;
    esac
    fixt_regions_seen=$((fixt_regions_seen + 1))
    fixt_region="$(sed 's/^[[:space:]]*#.*$//' <<<"$fixt_region")"
    region_lines=$(printf '%s\n' "$fixt_region" | wc -l | tr -d ' ')
    if [ -z "${fixt_region//[[:space:]]/}" ]; then
        fixt_pins_bad="$fixt_pins_bad [$pin_region: region not found]"
    elif [ "$region_lines" -gt 200 ]; then
        fixt_pins_bad="$fixt_pins_bad [$pin_region: region is $region_lines lines — its end anchor did not match, so the range ran past its block]"
    elif ! grep -qF -- "$PIN_G" <<<"$fixt_region"; then
        fixt_pins_bad="$fixt_pins_bad [$pin_region: no live GIT_CONFIG_GLOBAL pin]"
    elif ! grep -qF -- "$PIN_N" <<<"$fixt_region"; then
        fixt_pins_bad="$fixt_pins_bad [$pin_region: no live GIT_CONFIG_NOSYSTEM pin]"
    fi
done

# EVERY LIVE PIN MUST BE INSIDE A VISITED REGION. Without this the region list
# is a hand-maintained inventory certifying itself: deleting run_probe's pin AND
# its entry from the list left the census green while it printed a message
# naming run_probe as checked. That is the defect #324 exists to close, one
# level up, so the count is derived from the source and the message below names
# the regions actually walked rather than a frozen four.
# WHAT THIS EQUALITY DOES AND DOES NOT CATCH. It pins MEMBERSHIP — a pin
# deleted while its region stays reddens, which is the realistic single edit and
# the one the prose two screens up predicts. It does NOT catch deleting a pin
# AND its region entry together: the count and the regions fall by one each and
# still balance. What that can no longer do is
# LIE, because the ok line below names the regions actually walked rather than a
# frozen four, so the double deletion changes the printed list. Closing it
# properly needs "sites that read a fixture" derived from the code, which is not
# mechanically available here.
if [ "$fixt_pin_sites" -ne "$fixt_regions_seen" ]; then
    fixt_pins_bad="$fixt_pins_bad [$fixt_pin_sites live pin sites in the source but $fixt_regions_seen regions walked — a pinned site is outside the census, or a region lost its pin]"
fi
if [ -z "$fixt_pins_bad" ]; then
    ok "  and the hermetic git pins are live at every site the census walks ($pin_regions), with $fixt_pin_sites live pin sites in the source"
else
    bad "  a site that reads a fixture lost its hermetic pins, so the developer's own insteadOf reaches it:$fixt_pins_bad"
fi

D_LOOKUP="$(scenario lookup "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
for form in ssh https sshproto trailing; do
    # Reset plus a `*)` arm, for the reason the read-back loop above carries
    # them: a token with no arm re-runs the PREVIOUS fixture and passes.
    lookup_cwd=""
    case "$form" in
        ssh)      lookup_cwd="$CWD_SSH" ;;
        https)    lookup_cwd="$CWD_HTTPS" ;;
        sshproto) lookup_cwd="$CWD_SSHPROTO" ;;
        # `https://github.com/o/n.git/` — a form git writes and humans paste. It
        # belongs in the SUCCESS loop, not the failure one: the bug it pins is a
        # working remote being refused, so `.repo` must be the clean slug with no
        # `.git` glued on.
        trailing) lookup_cwd="$CWD_TRAILING" ;;
        *) bad "[$form] no arm in the success loop's case — the loop list and the arms disagree"; continue ;;
    esac
    REPO_ARG_OVERRIDE=none CWD_OVERRIDE="$lookup_cwd" run_probe "$PROBE" "$D_LOOKUP" --pr 301
    expect_field "[$form] the slug is derived from the origin remote" .repo "mock-org/mock-repo"
    expect_verdict "  and the run resolves normally on it" "healthy"
    # THE MUST-NOT-EXIST HALF. The mock `gh` refuses `repo view` outright, so a
    # regression also reddens the verdict — but a call log naming it says WHICH
    # regression, and a later mock that grew the arm back would still be caught.
    if grep -q '^gh repo view' "$WORK/calls"; then
        bad "  the probe called 'gh repo view' — the derivation is remote again"
        sed 's/^/          | C /' <"$WORK/calls" >&2
    else
        ok "  and no 'gh repo view' appears in the call log at all"
    fi
    lookup_n="$(grep -c . "$WORK/bounds")"
    if [ "$lookup_n" -eq "$BOUNDED_SITES" ]; then
        ok "  with no --repo the bounded-call count is UNCHANGED ($lookup_n) — the fourth site is gone"
    else
        bad "  $lookup_n bounded calls with no --repo, expected $BOUNDED_SITES (17b's measured count)"
        sed 's/^/          | B /' <"$WORK/bounds" >&2
    fi
    # The git reads enter the read-only corpus HERE, for the reason the fourth
    # `gh` call used to: every other case passes --repo, so nothing else in this
    # file exercises them, and a `git fetch` or a `git remote add` written into
    # the derivation would leave no `gh` line for case 17 to classify.
    lookup_offending="$(offending_calls "$WORK/calls")"
    if [ -z "$lookup_offending" ]; then
        ok "  and its git reads are classified read-only by the same scan as the gh calls"
    else
        bad "  the derivation made a call outside the read-only contract:"$'\n'"$lookup_offending"
    fi
done

# EVERY FAILURE SHAPE, ENUMERATED. Each one used to be, or would have been,
# exit 1 with no verdict at all; each is now `first_party repo_lookup_failed`, a
# real verdict, and a reason that names which input broke. Two of them are here
# because the first edition left them uncased while the probe's header counted
# them (review of #321): `rev-parse` ERRORING is a different branch from it
# printing `false`, and it is the ordinary `safe.directory` shape — reading the
# output alone reported "not inside a git work tree" from inside a checkout that
# plainly is one; and `nogit` is the branch that exists so a host with no git
# does not get that same false cause, which is untestable only on a host that
# happens to have no git, i.e. exactly what a curated PATH is for.
for shape in noorigin badurl hostpath threeseg badchar otherhost emptyseg oneseg notree broken bare nogit; do
    # `fail_path` was already reset per iteration; the other two were not, so a
    # token with no arm re-ran the PREVIOUS fixture's cwd against this token's
    # label and passed. Reset all three, and refuse the token outright below.
    fail_path=""
    fail_cwd=""
    fail_why=""
    case "$shape" in
        noorigin) fail_cwd="$CWD_NOORIGIN"; fail_why="no 'origin' remote" ;;
        badurl)   fail_cwd="$CWD_BADURL";   fail_why="not a github.com owner/name URL" ;;
        # Same detail as `badurl` and a DIFFERENT branch reaching it: this URL
        # parses as far as an authority and is refused because the authority is
        # not github.com. Sharing the detail is correct — the caller is told the
        # remote is unusable, never its value — but the case must exist, or the
        # authority-only strip is unpinned.
        hostpath) fail_cwd="$CWD_HOSTPATH"; fail_why="not a github.com owner/name URL" ;;
        # EXACTLY two segments, and from a character set that cannot inject.
        # Same shared detail again, two more distinct branches reaching it.
        threeseg) fail_cwd="$CWD_THREESEG"; fail_why="not a github.com owner/name URL" ;;
        badchar)  fail_cwd="$CWD_BADCHAR";  fail_why="not a github.com owner/name URL" ;;
        # A well-formed remote on ANOTHER FORGE, and an empty second segment.
        # Same shared detail, two more distinct branches reaching it.
        otherhost) fail_cwd="$CWD_OTHERHOST"; fail_why="not a github.com owner/name URL" ;;
        emptyseg)  fail_cwd="$CWD_EMPTYSEG";  fail_why="not a github.com owner/name URL" ;;
        # ONE segment. Without the `*)` arm this is not a wrong slug — it is
        # exit 1 with no verdict at all, from `:648`.
        oneseg)   fail_cwd="$CWD_ONESEG";   fail_why="not a github.com owner/name URL" ;;
        # `notree` and `broken` share a detail ON PURPOSE: both are rc 128 with
        # empty stdout, and `git rev-parse` separates them only in
        # locale-dependent stderr, so the probe names both possibilities rather
        # than picking one. Two fixtures for one detail is the point — the
        # earlier edition answered `broken` with "not inside a git work tree",
        # which is false of it.
        notree)   fail_cwd="$CWD_NOREPO";   fail_why="not inside a readable git work tree — git rev-parse exited" ;;
        broken)   fail_cwd="$CWD_BROKEN";   fail_why="not inside a readable git work tree — git rev-parse exited" ;;
        bare)     fail_cwd="$CWD_BARE";     fail_why="inside a bare git repository" ;;
        nogit)    fail_cwd="$CWD_SSH";      fail_why="git is not installed"; fail_path="$BIN_NG" ;;
        *) bad "[$shape] no arm in the failure loop's case — the loop list and the arms disagree"; continue ;;
    esac
    REPO_ARG_OVERRIDE=none CWD_OVERRIDE="$fail_cwd" PATH_OVERRIDE="$fail_path" \
        run_probe "$PROBE" "$D_LOOKUP" --pr 301
    expect_status "[$shape] a failed derivation exits 0 — it is a symptom, not a usage error" 0
    expect_verdict "  and emits a VERDICT rather than dying with no output" "unknown"
    expect_field "  naming the derivation, not the PR it never got to read" \
        .self_measured_reason "repo_lookup_failed"
    expect_errkind "  on the first-party ledger, so the run cannot read as measured" \
        "repo_lookup_failed"
    expect_field "  and .repo is null rather than a half-derived slug" '(.repo // "null")' "null"
    expect_explains_names "  with the reason on the field callers report" "$fail_why"
    if grep -qF -- "not in a GitHub repo" <<<"$STDERR"; then
        bad "  the old false cause is still printed: '$STDERR'"
    else
        ok "  and the old 'not in a GitHub repo' exit is gone entirely"
    fi
done
# THE REMOTE URL IS NEVER REPORTED. An https remote can carry a token in its
# userinfo, `probe_errors[].detail` is a field SKILL.md orders the coordinator to
# REPORT, and this repo is PUBLIC — so the unparsable case, the one branch that
# has a URL in hand and nothing to say about it, must name the input and not its
# value. Asserted over the WHOLE object and the stderr line, not just the detail.
REPO_ARG_OVERRIDE=none CWD_OVERRIDE="$CWD_BADURL" run_probe "$PROBE" "$D_LOOKUP" --pr 301
if grep -qF -- "${BADURL_REMOTE%/*}" <<<"$STDOUT$STDERR"; then
    bad "the unparsable origin URL was echoed into a reported field: a credential in one would leak"
    dump
else
    ok "an unparsable origin URL is named as an input and never quoted back"
fi

echo "17e. a host with NO timeout binary still measures, and says the bound did not apply" >&2
# The branch an earlier edition of this file called impossible to exercise. It
# is not: a curated PATH carrying everything the probe needs EXCEPT timeout runs
# it fine. The claim mattered because it was load-bearing — it was the stated
# reason this branch had no case, and CLAUDE.md tells the next editor to trust a
# gate header. The behaviour under test is the SCOPE: `timeout_unavailable` is
# `probe`-scoped, so it must NOT make the run not_measured. Scope it
# `first_party` and every coreutils-less host reports `not_measured` on every
# run, which is the whole reason the third scope exists.
if [ -n "$NT_MISSING" ]; then
    bad "the curated PATH could not be built; missing:$NT_MISSING"
else
    ok "the curated no-timeout PATH was built from the real one"
fi
D_NT="$(scenario notimeout "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
PATH_OVERRIDE="$BIN_NT" run_probe "$PROBE" "$D_NT" --pr 301
expect_verdict "with no timeout binary the probe still measures and resolves" "healthy"
expect_status "  and exits 0" 0
expect_field "  the measurement is unaffected — NOT not_measured" .self_measured "clean"
expect_errkind "  and the ledger says the bound never applied" "timeout_unavailable"
nt_scope="$(jq -r '[.probe_errors[] | select(.kind == "timeout_unavailable") | .scope] | join(",")' <<<"$STDOUT" 2>/dev/null)"
if [ "$nt_scope" = "probe" ]; then
    ok "  scoped 'probe', so it cannot make a coreutils-less host unmeasured"
else
    bad "  timeout_unavailable is scoped '$nt_scope', expected 'probe'"; dump
fi
nt_bounds="$(grep -c . "$WORK/bounds")"
if [ "$nt_bounds" -eq 0 ]; then
    ok "  and no bound was recorded, so the case is not passing through the shim"
else
    bad "  $nt_bounds bounds recorded on a PATH with no timeout — the shim leaked in"
fi
# AND IT SAYS SO ON STDERR (issue #314). The ledger is JSON; macOS ships no
# `timeout`, so an operator running this by hand on a laptop without coreutils
# reads `platform: healthy` every time and learns the bound never applied on the
# day a `gh` call hangs the session — the one day there is no output to learn it
# from. 17f is the other half: the line must be ABSENT when a bound exists, or
# it is a warning nobody will read twice.
if grep -qF -- "neither timeout nor gtimeout on PATH" <<<"$STDERR"; then
    ok "  and it warns once on stderr, the channel a hand invocation actually reads"
else
    bad "  nothing on stderr says the bound never applied: '$(printf '%.200s' "$STDERR")'"; dump
fi
# THE `explains` TAIL EXCLUDES THE `probe` SCOPE, and until now nothing observed
# that (review of #321): `fp_details` filters by exclusion exactly as the
# first-party COUNT does, and widening it to include `probe` was a green
# mutation. It has to stay excluded for the same reason the count does — a
# coreutils-less host would otherwise read "not measured: … neither timeout nor
# gtimeout is on PATH" on every run, offering the operator a cause that had no
# bearing on the measurement. This run carries BOTH kinds at once, which is the
# only arrangement that can tell inclusion from exclusion apart.
D_NT_FP="$(scenario notimeout-fp "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
: >"$D_NT_FP/pr.fail"
PATH_OVERRIDE="$BIN_NT" run_probe "$PROBE" "$D_NT_FP" --pr 301
expect_verdict "with a failed read beside it the run is unknown" "unknown"
expect_errkind "  and both ledger kinds are present" "timeout_unavailable"
expect_explains_names "  the tail names the FIRST-PARTY failure" "gh pr view 301 exited 4"
nt_tail="$(field .explains)"
if grep -qF -- "neither timeout nor gtimeout is on PATH" <<<"${nt_tail#*"$EXPLAINS_TAIL_MARK"}"; then
    bad "  the probe-scoped entry leaked into explains — a coreutils-less host would read it as the cause"
    dump
else
    ok "  and omits the probe-scoped one, which had no bearing on the measurement"
fi

echo "17f. gtimeout — the macOS spelling, and the elif no shimmed PATH reaches" >&2
# `timeout` is shimmed ahead of it everywhere else, so this branch was the OTHER
# half of the same false impossibility claim. A PATH carrying gtimeout alone is
# what a coreutils-on-macOS host actually looks like.
D_GT="$(scenario gtimeout "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
PATH_OVERRIDE="$BIN_GT" run_probe "$PROBE" "$D_GT" --pr 301
expect_verdict "a gtimeout-only host resolves normally" "healthy"
gt_bounds="$(grep -c . "$WORK/bounds")"
if [ "$gt_bounds" -eq 3 ]; then
    ok "  and its three load-bearing calls really did run under gtimeout ($gt_bounds)"
else
    bad "  $gt_bounds bounded calls under a gtimeout-only PATH, expected 3"
fi
gt_err="$(errkinds)"
if grep -qF -- "timeout_unavailable" <<<"$gt_err"; then
    bad "  gtimeout was present but the probe reported the bound unavailable"
else
    ok "  and nothing claims the bound was unavailable"
fi
# The negative half of 17e's stderr warning. A warning printed unconditionally
# is one an operator learns to skip, so it is worth an assertion of its own.
if grep -qF -- "neither timeout nor gtimeout on PATH" <<<"$STDERR"; then
    bad "  and yet it warned about a missing bound on a host that has one: '$(printf '%.200s' "$STDERR")'"
else
    ok "  and it does NOT print the missing-bound warning where a bound exists"
fi

echo "17g. the bound value is validated, including the shapes that mean 'unbounded'" >&2
# The whole validation block was UNCASED: deleting it left the gate green. `00`
# is the one that matters — all digits, not empty, not the literal `0`, so it
# passed, and `timeout 00 …` is `timeout 0 …`, which is NO BOUND. Measured:
# `gtimeout 00 sleep 2` returns 0 after the full two seconds. Worse than an
# unbounded run, because no `timeout_unavailable` is recorded either, so the
# ledger affirmatively implies a bound that never applied.
D_VAL="$(scenario badbound "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
GH_TIMEOUT_OVERRIDE=abc run_probe "$PROBE" "$D_VAL" --pr 301
expect_status "a non-numeric bound is a usage error" 1
GH_TIMEOUT_OVERRIDE=0 run_probe "$PROBE" "$D_VAL" --pr 301
expect_status "  a zero bound is refused rather than read as 'no bound'" 1
GH_TIMEOUT_OVERRIDE=00 run_probe "$PROBE" "$D_VAL" --pr 301
expect_status "  and so is 00, which is all digits and still means no bound" 1
unset GH_TIMEOUT_OVERRIDE

echo "18. exit codes carry no verdict, but still carry usage errors" >&2
run_probe "$PROBE" "$D" --pr not-a-number
expect_status "a usage error is the one non-zero exit" 1
# A lone trailing flag must not spin: `shift 2` with one arg left shifts nothing.
run_probe "$PROBE" "$D" --pr 283 --min-age
expect_status "a value-less trailing flag is rejected rather than looping forever" 1
# `007` IS THE SHAPE THAT MATTERS, and it is `00`'s sibling one argument over
# (issue #314). This value is interpolated into JSON as a BARE NUMBER — by the
# emitter's `--argjson pr` and, since the fallback started carrying `pr`, by the
# hand-built literal too — and `007` is not JSON. Digits-only alone therefore
# left an argument that killed the emitter on its way in: the #303 door reached
# through a flag rather than through a ledger, and the one input that could
# malform the fallback written to answer it.
run_probe "$PROBE" "$D" --pr 007
expect_status "a leading-zero PR is refused: it would not be JSON in the emitter or the fallback" 1
run_probe "$PROBE" "$D" --pr 0
expect_status "  and so is 0, which is no PR at all" 1

# ==============================================================================
echo "19. no sibling script and no other skill consults the probe" >&2
section_of() { # <file> <heading prefix>
    awk -v h="$2" '
        substr($0, 1, length(h)) == h { inseg = 1; next }
        inseg && /^##+ / { exit }
        inseg { print }
    ' "$1"
}
# CAPTURE, then match against a herestring. The earlier edition of this function
# piped awk into `grep -qF` under pipefail, where a SIGPIPE 141 on a MATCH reads
# as "not found" — so every must-NOT-name assertion below failed OPEN, which is
# gate 30's whole subject (#256) landing on the gate that exists to refuse
# exactly this class of silent pass.
# region_text <file> <start heading prefix> <end heading prefix> — `section_of`
# stops at the NEXT `##+ ` line, which truncates any section that has
# subheadings: §7 ends at `### DRAIN DEGRADED` and §4 at `### Collision`, so a
# scan over either measured a fraction of it and reported clean. This one is
# bounded by an explicit end heading instead.
region_text() {
    awk -v h="$2" -v e="$3" '
        substr($0, 1, length(h)) == h { inseg = 1; next }
        inseg && substr($0, 1, length(e)) == e { exit }
        inseg { print }
    ' "$1" | tr '\n' ' ' | tr -s ' \t'
}
section_text() { # <file> <heading prefix>
    local s
    s="$(section_of "$1" "$2")"
    printf '%s' "$s" | tr '\n' ' ' | tr -s ' \t'
}
section_names_probe() { # <file> <heading prefix>
    local t
    t="$(section_text "$1" "$2")"
    grep -qF -- "$PROBE_BASENAME" <<<"$t"
}
SIBLINGS=(checkout-guard.sh gh-retry.sh merge-shepherd.sh poll-prs.sh poll-queue.sh pr-failure-log.sh stack-probe.sh teardown.sh)
# EQUALITY against the TRACKED listing (git ls-files, like every other corpus in
# this repo), so a new script cannot ship unscanned and an untracked scratch
# file cannot redden the gate with a message that blames the list.
listed="$(printf '%s\n' "${SIBLINGS[@]}" | sort | tr '\n' ' ')"
tracked="$(git ls-files 'skills/pr-shepherd/scripts/*.sh')"
actual="$(printf '%s\n' "$tracked" | sed 's|.*/||' | grep -v -x -F "$PROBE_BASENAME" | sort | tr '\n' ' ')"
if [ "$listed" = "$actual" ]; then
    ok "the scanned sibling list equals the tracked scripts (${#SIBLINGS[@]} files)"
else
    bad "sibling list drift — scanning [$listed] but the tree tracks [$actual]"
fi

scan_for_probe() { # <file...>  — echoes each file that names the probe
    local f
    for f in "$@"; do
        if [ ! -f "$f" ]; then printf 'MISSING:%s\n' "$f"; continue; fi
        if grep -qF -- "$PROBE_BASENAME" "$f"; then printf '%s\n' "$f"; fi
    done
}
# The FILENAME is not the only way to wire the verdict in. #285's own follow-up
# work will be written in verdict VOCABULARY — "on a degraded verdict, hold the
# PR" names no script — and a filename-only scan reports that as clean; measured,
# a section doing exactly that left this gate at exit 0. The two `degraded (…)`
# literals are distinctive enough to scan for, and so is the BARE form the rule
# will actually be written in: `on a degraded verdict, hold the PR` names
# neither the script nor a parenthetical, and was measured green against the
# two literals alone (review of #315) — the exact phrasing this comment gives
# as the reason the scan exists. `healthy` and `unknown` are ordinary English
# and are deliberately NOT in the set, and neither is a bare `degraded`, which
# false-positives on the routines' `Load: fallback (degraded)` field.
VERDICT_VOCAB=('degraded (attributed)' 'degraded (unattributed)' 'degraded (' 'degraded verdict' '`degraded` verdict' 'platform-degradation verdict')
scan_for_verdict() { # <file...>  — echoes "<file>: <literal>" per hit
    local f lit
    for f in "$@"; do
        [ -f "$f" ] || continue
        for lit in "${VERDICT_VOCAB[@]}"; do
            if grep -qF -- "$lit" "$f"; then printf '%s: %s\n' "$f" "$lit"; fi
        done
    done
}
sibling_paths=()
for s in "${SIBLINGS[@]}"; do sibling_paths+=("$SCRIPTS_DIR/$s"); done
hits="$(scan_for_probe "${sibling_paths[@]}")"
if [ -z "$hits" ]; then
    ok "no merge, poll, retry or teardown script consults the platform verdict"
else
    bad "the probe is referenced by a decision-making script, which makes it a gate: $hits"
fi

# THE DOCS CORPUS IS AN EQUALITY TOO. Every tracked `.md` under `skills/`, at
# any depth — SKILL.md, references, and the assess-it orchestration docs that
# sit beside their SKILL.md (a `SKILL.md` + `references/*.md` glob left those
# two outside while this comment said "every") — is scanned WHOLE,
# except the two files that legitimately name the probe, which are scanned
# section by section below. An earlier edition listed take-it, send-it and
# pr-shepherd's own references by hand, so `skills/pr-shepherd/SKILL.md` was in
# no corpus at all — a hold rule written into its §4 Teardown or its §2 Watch
# checks was invisible (measured, gate green) — and a new
# `skills/*/references/*.md` shipped unscanned. Gates 32/33 recorded the same
# lesson: the SUBSET was the defect, not the choice of subset. The rule says
# "no merge, HOLD, BLOCK or REDISPATCH decision", and those sites do not all
# live in pr-shepherd; #285's scope note is explicit that ACTING on the verdict
# is separate work, so naming the probe in any skill doc is a deliberate change
# that must come back through this gate. `dispatch-ready/SKILL.md` is one of
# the two section-scoped files, and that is a scoped decision rather than an
# exemption (#286): its DRAIN DEGRADED legitimately consults the verdict to
# reach a decision to STOP, which writes nothing, while every other section —
# §2 and §4 in particular, the hold/merge/redispatch and selection surfaces —
# must not. The section scan carries a POSITIVE control so the carve-out
# cannot silently widen from "DRAIN DEGRADED may" to "the file may".
SECTION_SCOPED_DOCS="skills/pr-shepherd/SKILL.md skills/dispatch-ready/SKILL.md"
DECISION_DOCS=()
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case " $SECTION_SCOPED_DOCS " in *" $ref "*) continue ;; esac
    DECISION_DOCS+=("$REPO_ROOT/$ref")
done < <(git ls-files 'skills/*.md')   # a git pathspec `*` crosses `/`, so this is every depth
# Membership controls, so a listing that silently narrowed cannot report a
# clean corpus: the files the hand-picked list used to name must still be in
# it, and so must one of the beside-SKILL.md docs the narrower glob missed.
corpus_missing=""
for must in skills/take-it/SKILL.md skills/send-it/SKILL.md skills/pr-shepherd/references/merge-queue.md skills/assess-it/orchestration.md; do
    case " ${DECISION_DOCS[*]} " in *" $REPO_ROOT/$must "*) : ;; *) corpus_missing="$corpus_missing $must" ;; esac
done
if [ -z "$corpus_missing" ]; then
    ok "the docs corpus is every tracked skill doc minus the two section-scoped files (${#DECISION_DOCS[@]} docs)"
else
    bad "the docs corpus lost a file the old hand-picked list carried:$corpus_missing"
fi

# SECTION EQUALITY for the two files that may name the probe. Every heading in
# the file is enumerated; each section is either on the file's short allowlist
# — asserted to exist, so a rename cannot retire the carve-out — or scanned for
# the filename AND the vocabulary. The preamble before the first heading is
# section 0 and is scanned too. An earlier edition scanned §1, §1b and §3 of
# pr-shepherd and §2 and §4 of dispatch-ready BY NAME, leaving pr-shepherd's
# §2, §4 and Guardrails, and dispatch-ready's §1, §3, §5, §6 and the rest of
# §7, unscanned — measured: a hold rule in §4 Teardown and a gating bullet
# appended to Guardrails both left this gate green. Guardrails is NOT
# allowlisted: its one legitimate mention is the canon-pinned never-a-gate
# bullet, which is stripped before the scan so the REST of the list — exactly
# where a gating exception gets written — is held to the same rule.
section_by_ordinal() { # <file> <n> — the n-th section flattened, HEADING INCLUDED (0 = preamble)
    # The heading line is part of what is scanned: a rule written as a heading
    # over a bland body (`#### On a degraded (attributed) verdict, hold the PR`)
    # was measured green while only bodies were read (review of #315; M31c).
    awk -v n="$2" '/^##+ /{c++; if (c == n) print; next} c==n {print}' "$1" | tr '\n' ' ' | tr -s ' \t'
}
scan_sections() { # <file> <allowlist, one heading per line> — echoes "<heading>: <hit>" per hit
    local f="$1" allow="$2" nheads i h body lit
    nheads="$(grep -c '^##\{1,\} ' "$f")"
    i=0
    while [ "$i" -le "$nheads" ]; do
        if [ "$i" -eq 0 ]; then h="(preamble)"; else h="$(grep '^##\{1,\} ' "$f" | sed -n "${i}p")"; fi
        body="$(section_by_ordinal "$f" "$i")"
        i=$((i + 1))
        if grep -qxF -- "$h" <<<"$allow"; then
            # An allowlisted section that is EMPTY is a renamed carve-out.
            [ -n "$body" ] || printf '%s: EMPTY ALLOWLISTED SECTION\n' "$h"
            continue
        fi
        if grep -qF -- "$PROBE_BASENAME" <<<"$body"; then printf '%s: names %s\n' "$h" "$PROBE_BASENAME"; fi
        for lit in "${VERDICT_VOCAB[@]}"; do
            if grep -qF -- "$lit" <<<"$body"; then printf '%s: %s\n' "$h" "$lit"; fi
        done
    done
}
GR_BULLET_LIT='- **Never let the platform-degradation verdict gate anything.**'
PS_ALLOW="### 2b. Platform degradation probe — when a watch goes nowhere"$'\n'"## Bundled scripts"
scan_skill_sections() { # <pr-shepherd SKILL.md, or a mutant of it> — the canon bullet stripped first
    grep -vF -- "$GR_BULLET_LIT" "$1" >"$WORK/skill.nobullet"
    scan_sections "$WORK/skill.nobullet" "$PS_ALLOW"
}

doc_hits="$(scan_for_probe "${DECISION_DOCS[@]}")"
if [ -z "$doc_hits" ]; then
    ok "no skill doc outside the two section-scoped files names the probe"
else
    # A MISSING: line fails here too: a renamed path that silently drops out of
    # the corpus leaves the ok-line reporting a doc count it never read.
    bad "the verdict reached a hold/block/redispatch surface (or a scanned path vanished), which #285 scopes out: $doc_hits"
fi
vocab_hits="$(scan_for_verdict "${sibling_paths[@]}" "${DECISION_DOCS[@]}")"
if [ -z "$vocab_hits" ]; then
    ok "and none of them is wired to the verdict VOCABULARY either"
else
    bad "a decision surface consults the platform verdict by name rather than by filename: $vocab_hits"
fi
# dispatch-ready, by section equality. DRAIN DEGRADED may name the probe
# (#286); EVERY other section — §2 and §4, where a PR is held, merged,
# redispatched or an issue selected, and the ones the by-name scan never read
# — may not. #285's never-a-gate rule is drawn on exactly that act-vs-stop line.
DR_SKILL="$REPO_ROOT/skills/dispatch-ready/SKILL.md"
DR_ALLOW="### DRAIN DEGRADED"
dr_hits="$(scan_sections "$DR_SKILL" "$DR_ALLOW")"
dr_n="$(grep -c '^##\{1,\} ' "$DR_SKILL")"
if [ -z "$dr_hits" ]; then
    ok "every section of dispatch-ready outside DRAIN DEGRADED consults neither the probe nor its vocabulary ($dr_n headings + preamble)"
else
    bad "dispatch-ready wired the verdict into a section #286 does not license: $dr_hits"
fi

# POSITIVE CONTROL. The carve-out is "DRAIN DEGRADED may", and a scan that finds
# the verdict nowhere in dispatch-ready would report the assertion above as
# clean while measuring a file in which #286 was reverted. So that section must
# actually name it.
dr_s7="$(region_text "$DR_SKILL" "### DRAIN DEGRADED" "### DRAIN COMPLETE")"
if grep -qF -- "probe-platform-health" <<<"$dr_s7" && grep -qF -- "degraded (attributed)" <<<"$dr_s7"; then
    ok "and DRAIN DEGRADED DOES name the probe and its vocabulary, so the carve-out is live rather than vacuous"
else
    bad "DRAIN DEGRADED no longer consults the probe — #286's terminal state is gone, and the scan above proves nothing"
fi

# pr-shepherd's OWN sections are the nearest surface of all. Section equality:
# every heading except §2b (canon-pinned in 22) and the script table (asserted
# to name the probe in 20) is scanned, Guardrails with its canon bullet removed.
# The filename is not how a gating rule gets written, so this scans the
# vocabulary too.
ps_hits="$(scan_skill_sections "$SKILL")"
ps_n="$(grep -c '^##\{1,\} ' "$SKILL")"
if [ -z "$ps_hits" ]; then
    ok "every section of pr-shepherd's SKILL.md outside §2b and the script table is clean of the probe and its vocabulary ($ps_n headings + preamble)"
else
    bad "the verdict reached a pr-shepherd section outside its carve-outs: $ps_hits"
fi
ps_allow_bad=""
while IFS= read -r h; do
    [ "$(grep -cxF -- "$h" "$SKILL")" = "1" ] || ps_allow_bad="$ps_allow_bad [$h]"
done <<<"$PS_ALLOW"
if [ -z "$ps_allow_bad" ]; then
    ok "and both carve-out headings exist exactly once, so the allowlist names live sections"
else
    bad "a carve-out heading is missing or duplicated, so the scan around it is vacuous:$ps_allow_bad"
fi

# ==============================================================================
echo "20. the probe is named in its own section, not in the decision sections" >&2
for heading in "### 2b. Platform degradation probe" "## Bundled scripts"; do
    if section_names_probe "$SKILL" "$heading"; then
        ok "'$heading' names the probe"
    else
        bad "'$heading' does not name $PROBE_BASENAME — the section is missing or renamed"
    fi
done
# The must-NOT-name half is section 19's equality scan: every heading that is
# not one of the two above is scanned by ordinal, so a renamed §1 cannot retire
# its own scan the way a by-name window could (the `window_is_bounded` lesson —
# measured, renaming §1 and wiring a hold decision into it left an earlier
# edition green).
GUARDRAILS="$(section_text "$SKILL" "## Guardrails")"
if grep -qF -- "Never let the platform-degradation verdict gate anything." <<<"$GUARDRAILS"; then
    ok "Guardrails carries the never-a-gate rule"
else
    bad "Guardrails no longer carries the never-a-gate rule"
fi
# …and by CANON, for the same reason §2b is. Presence keeps the sentence and
# permits "…except on a `degraded (attributed)` verdict, where the PR is held"
# appended to it — and Guardrails is exactly where a gating exception gets
# written. Canon is on the BULLET, so the rest of the list stays free to change.
GR_BULLET="$(grep -F -- '- **Never let the platform-degradation verdict gate anything.**' "$SKILL" | tr -s ' ')"
GR_SUM="$(printf '%s' "$GR_BULLET" | cksum | cut -d' ' -f1)"
GR_CANON="65229782"
if [ "$GR_SUM" = "$GR_CANON" ]; then
    ok "Guardrails bullet canon matches (an appended exception fails here)"
else
    bad "Guardrails bullet drift — got $GR_SUM want $GR_CANON :: $(printf '%.90s' "$GR_BULLET")"
fi

# ==============================================================================
echo "21. SKILL.md states the contract the probe implements" >&2
SKILL_FLAT="$WORK/skill.flat"
tr '\n' ' ' <"$SKILL" | tr -s ' \t' >"$SKILL_FLAT"
expect_prose() { # <label> <needle>
    if grep -qF -- "$2" "$SKILL_FLAT"; then ok "$1"; else bad "$1 — missing from $SKILL: $2"; fi
}
expect_prose "the healthy row is documented" \
    '| `healthy` | a first-party check actually ran, found nothing wrong, AND the status page is green |'
expect_prose "the attributed row is documented" \
    '| `degraded (attributed)` | the platform reports an open incident on a check-relevant component |'
expect_prose "the unattributed row is documented" \
    '| `degraded (unattributed)` | first-party evidence of degradation the status page does not corroborate |'
expect_prose "the unknown row is documented" \
    '| `unknown` | nothing could be measured, or the status endpoint could not be read |'
expect_prose "green is stated NOT to be evidence of health" \
    '**A green status page is NOT evidence of health.**'
expect_prose "the asymmetry is stated in the words the issue requires" \
    '`red` explains a stall; `green` explains nothing, and must be reported in those words.'
expect_prose "callers are told to report the explains field, not the verdict alone" \
    '**Report the `explains` field, not the verdict alone.**'
expect_prose "and that three verdicts explain nothing, not two" \
    'A `healthy` or an `unknown` verdict explains nothing — and so does a `degraded (attributed)` verdict whose `self_measured` is not `anomaly`'
expect_prose "an unreachable endpoint is neither healthy nor degraded on its own" \
    '**An unreachable status endpoint contributes `unknown`** — never `healthy`, and never `degraded` on its own.'
expect_prose "the never-a-gate rule names all four decisions it stays out of" \
    'it appears in **no** merge, hold, block or redispatch decision'
expect_prose "the exit-code contract is stated as what makes never-a-gate structural" \
    'every verdict exits `0` so it cannot become one through a `set -e` or an `if`'
expect_prose "the first-party door into healthy is documented as closed" \
    '`clean` means a check RAN and found nothing'
expect_prose "the transport-failure reading is documented rather than left implicit" \
    'a failed `gh` call is `not_measured`, never an anomaly'
expect_prose "attribution is documented as scoped to check-relevant components" \
    '**attribution is scoped to check-relevant status components**'

# ==============================================================================
echo "22. §2b is pinned by CANON, not by presence alone" >&2
# Presence-only needles are satisfied by a document that still CONTAINS every
# sentence they grep for and now also contains its INVERSE. Measured twice on
# this very section, both at exit 0: a paragraph telling the caller to hold a PR
# on a degraded verdict, and one telling it a `healthy` verdict confirms the
# stall is a real defect — precisely the two harms this gate's own header names.
# preflight.sh's entries for test-review-gate-decisions.sh,
# test-drain-terminal-states.sh and test-audit-lost-reviewer.sh record the same
# defeat, which is why those moved to canon. Canon compares every blank-line
# block of §2b for equality after flattening, so ADDING prose fails as loudly
# as removing it. The accepted cost
# is that a legitimate reword must update a checksum here: a loud false red,
# which this repo prefers to a needle that can be satisfied and inverted at once.
canon_blocks() { # <file> <heading> — one flattened block per line
    section_of "$1" "$2" | awk '
        BEGIN { RS = "" }
        { gsub(/[ \t\n]+/, " "); sub(/^ /, ""); sub(/ $/, ""); if (length($0)) print }
    '
}
# Regenerate after a deliberate §2b edit; the trailing comment is the block's
# opening words, so a drifted row says which paragraph moved.
CANON_2B=(
    "1622634225"   # A `gh` call that *errors*…
    "1892531078"   # Run the probe when a watch has gone nowhere…
    "2635286258"   # | rollup entry | probe | poll-prs | merge-shepherd
    "2899291126"   # So "the poller went quiet"… (ends on the bound, its 25s ceiling and the 80s worst case)
    "3301345540"   # ```bash … probe-platform-health.sh --pr …
    "1562190426"   # It returns one of exactly **four** verdicts…
    "3181854606"   # | Verdict | What it means | … the four rows
    "409465134"   # **A green status page is NOT evidence of health.**…
    "2796344907"   # **An unreachable status endpoint contributes `unknown`**…
    "2507554027"   # `clean` also needs the age floor + untruncated page; **two doors**…
    "1955687869"   # **Never a gate.**…
    "3930670869"   # **ONE carve-out** — a decision to STOP, #286
)
canon_i=0
canon_bad=""
while IFS= read -r blk; do
    blk_sum="$(printf '%s' "$blk" | cksum | cut -d' ' -f1)"
    blk_want="${CANON_2B[$canon_i]:-«unrecorded»}"
    if [ "$blk_sum" != "$blk_want" ]; then
        canon_bad="$canon_bad    block $((canon_i + 1)): got $blk_sum want $blk_want :: $(printf '%.72s' "$blk")"$'\n'
    fi
    canon_i=$((canon_i + 1))
done < <(canon_blocks "$SKILL" "### 2b. Platform degradation probe")
if [ "$canon_i" -eq "${#CANON_2B[@]}" ] && [ -z "$canon_bad" ]; then
    ok "§2b canon: all ${#CANON_2B[@]} blocks match byte-for-byte after flattening"
else
    bad "§2b canon drift — $canon_i blocks present, ${#CANON_2B[@]} recorded:"$'\n'"$canon_bad"
fi

# ==============================================================================
echo "23. the shipped DEFAULTS are asserted, since every run above overrides them" >&2
# Pinning all four PLATFORM_* knobs in run_probe is right — an operator's
# ambient value must not change what this gate measures — but it left the `:-`
# defaults dead code under test, and the defaults are the only values that ever
# ship: every documented invocation runs with no PLATFORM_* set. Measured:
# emptying the component default left this gate green while the real probe went
# from `degraded (attributed)` to `healthy` during an open Actions incident,
# which is M13's declared harm reached through the default instead of the line
# M13 mutates.
expect_default() { # <label> <exact source line>
    if grep -qF -- "$2" "$PROBE"; then ok "$1"; else bad "$1 — not found in $PROBE: $2"; fi
}
expect_default "the status endpoint defaults to githubstatus.com over https" \
    'STATUS_URL="${PLATFORM_STATUS_URL:-https://www.githubstatus.com/api/v2/summary.json}"'
expect_default "the fetch timeout defaults to 5s" \
    'STATUS_TIMEOUT="${PLATFORM_STATUS_TIMEOUT:-5}"'
expect_default "the per-call gh bound defaults to 20s" \
    'GH_TIMEOUT="${PLATFORM_GH_TIMEOUT:-20}"'
expect_default "the head-age floor defaults to 300s" \
    'MIN_AGE="${PLATFORM_PROBE_MIN_AGE:-300}"'
# THE WORST CASE MUST FIT INSIDE THE HARNESS THAT RUNS THE SHIPPED CALLERS
# (issue #314). Every bounded site can burn `PLATFORM_GH_TIMEOUT` plus the fixed
# kill grace, and the `curl` runs after all of them, so the ceiling is
# `sites x (bound + grace) + status timeout`. At the previous 30s default with
# four sites that was 145s against a 120s default tool timeout — and a harness
# kill yields NO JSON AND NO STDERR, #303's shape one layer up, which the
# emitter fallback cannot answer because the script never reaches it. Every term
# is READ FROM THE SOURCE rather than transcribed, and `sites` comes from 17b's
# measured bound count, so adding a bounded call re-derives this instead of
# leaving a stale sum in a comment.
tool_timeout_ceiling=120
gh_default="$(sed -n 's/^GH_TIMEOUT="${PLATFORM_GH_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$PROBE")"
status_default="$(sed -n 's/^STATUS_TIMEOUT="${PLATFORM_STATUS_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$PROBE")"
kill_grace="$(sed -n 's/.*"\$GH_TIMEOUT_CMD" -k \([0-9][0-9]*\) .*/\1/p' "$PROBE")"
ceiling_ok=1
for v in "$gh_default" "$status_default" "$kill_grace" "$BOUNDED_SITES"; do
    case "$v" in ""|*[!0-9]*) ceiling_ok=0 ;; esac
done
# `-gt 0` on the site count, not merely "all digits": a `BOUNDED_SITES` that
# came back 0 — 17b's count broken, or the variable never set — passes the digit
# test and makes the arithmetic 5s, which clears any ceiling vacuously (review
# of #321).
[ "${BOUNDED_SITES:-0}" -gt 0 ] 2>/dev/null || ceiling_ok=0
if [ "$ceiling_ok" -ne 1 ]; then
    bad "the worst-case terms could not be read from the source (bound '$gh_default', grace '$kill_grace', status '$status_default', sites '$BOUNDED_SITES')"
else
    worst=$(( BOUNDED_SITES * (gh_default + kill_grace) + status_default ))
    if [ "$worst" -lt "$tool_timeout_ceiling" ]; then
        ok "the worst case fits the harness tool timeout: $BOUNDED_SITES x ($gh_default + $kill_grace) + $status_default = ${worst}s < ${tool_timeout_ceiling}s"
    else
        bad "the worst case is ${worst}s ($BOUNDED_SITES x ($gh_default + $kill_grace) + $status_default), at or past the ${tool_timeout_ceiling}s tool timeout — a killed run emits no JSON and no stderr"
    fi
fi
# And the two documents that state that number must state the SAME one. A
# ceiling nobody can read is a ceiling an operator raises by accident.
#
# SCOPED, AND ANCHORED ON THE `=` (review of #321). The first edition grepped
# each file whole for a bare `80s`, which the bundled-script table satisfies on
# its own — so §2b, the section where an operator actually decides tick
# placement, could lose the sentence entirely with this green. The probe side is
# anchored on the arithmetic that produces the number rather than on the number,
# so a header stating a total it does not derive is red too.
worst_2b="$(section_of "$SKILL" "### 2b. Platform degradation probe")"
worst_sum="= ${worst:-«unreadable»}s"
if grep -qF -- "$worst_sum" "$PROBE" && grep -qF -- "${worst:-«unreadable»}s" <<<"$worst_2b"; then
    ok "  and the probe header derives it ('$worst_sum') while §2b itself states it"
else
    bad "  the ${worst:-«unreadable»}s worst case is not derived in the probe header AND stated inside §2b"
fi
# Both anomaly generators must CAPTURE their exit status. A process
# substitution's failure is invisible to pipefail, and RUN_CHECK is already
# "ran" by the time the missing-run loop executes, so a dead generator would
# affirmatively certify a comparison whose result it discarded. These pins sit
# ALONGSIDE the behavioural pair in 27b and its mutants M28/M28b/M28c, never
# instead of them. An earlier edition pinned the guards HERE ALONE, "because
# no fixture can make jq fail on a payload the earlier guards accept" — false
# for the empty-state generator (a rollup of numbers does it), and every one of
# its needles was defeatable: `RUN_CHECK="not_run"` also matched the
# initialiser, so deleting the reset at the use site passed; `if false` in
# place of the guard passed; a guard body replaced with `ROLLUP_CHECK="ran"`
# passed. All three measured, gate green. Only the capture lines are pinned
# now; what the guards DO is measured.
expect_default "the empty-state generator captures its exit status" \
    'empty_out="$(jq -r '
expect_default "the missing-run generator captures its exit status" \
    'missing_out="$(jq -r '
expect_default "the component scope defaults to the check-relevant set" \
    'STATUS_COMPONENTS="${PLATFORM_STATUS_COMPONENTS:-actions,api requests,webhooks,pull requests,git operations}"'
# The bound's three branches, pinned at source level ALONGSIDE the behavioural
# cases in 17e and 17f — never instead of them.
#
# AN EARLIER EDITION OF THIS COMMENT CLAIMED THESE TWO BRANCHES "cannot be
# exercised at all", and that was FALSE. It reasoned that hiding a binary from a
# PATH the probe also needs jq on is not something a prepended shim directory
# can do — true, and irrelevant, because the answer is not to prepend but to
# REPLACE the PATH with a curated one. Both reviewers of #312 disproved it by
# construction in minutes. The claim did real damage while it stood: it was the
# stated reason these branches had no behavioural case, so nothing produced a
# `probe`-scoped entry and nothing mutated the scope filter the entry exists to
# stay out of — rewriting that filter to `select(.scope != "attribution")`, which
# makes EVERY coreutils-less host report `not_measured` on every run, left this
# gate fully green. A false impossibility in a gate header is worse than a
# missing case, because CLAUDE.md tells the next editor to trust the header.
# Note the shape of the error and not just the fact of it: it asserted what
# could not be done without trying, and nothing here could ever have failed.
expect_default "the bound prefers timeout" \
    'if command -v timeout >/dev/null 2>&1; then GH_TIMEOUT_CMD="timeout"'
expect_default "  and falls back to gtimeout, the macOS spelling" \
    'elif command -v gtimeout >/dev/null 2>&1; then GH_TIMEOUT_CMD="gtimeout"'
expect_default "  and with neither present, records that the bound never applied" \
    '|| add_error probe timeout_unavailable'
# TWO GUARDED LINES, NOT ONE `if` BLOCK, and the shape is the point: the ledger
# entry keeps the exact form pinned above while the stderr warning rides beside
# it. Behavioural coverage is 17e (present) and 17f (absent); this pins the
# channel, since a warning folded back into the JSON is invisible to a
# hand invocation and that is the whole finding (#314).
expect_default "  and warns once on stderr, which is where a hand invocation reads" \
    'echo "warning: neither timeout nor gtimeout on PATH — gh calls run unbounded; install coreutils" >&2'
# THE `explains` TAIL, at source level, beside the behavioural assertions in
# 17c and 17d. The canon in `explains_canon` deliberately stops at the marker,
# so the marker itself is the seam and nothing else holds it: delete this
# interpolation and every `unknown` goes back to one sentence for every cause,
# with the canon fully green because the head never changed.
expect_default "the unmeasured unknown carries its reason into explains" \
    'EXPLAINS="$EXPLAINS (not measured: ${SELF_REASON:-nothing_measurable}$(fp_details))"'
# The emitter's own failure. It IS reachable from a fixture, one way: its own
# inputs are built by the script, but the LEDGER BUILDERS pass fixture text on
# argv, so a check name over the argv cap kills `add_anomaly`'s `--arg d`
# (exit 126, empty output), the ledger is left empty, and the emitter then dies
# on `--argjson anomalies ""` — measured, and cased in 27c, which requires the
# fallback back. An edition of this comment said no fixture could reach it,
# the false-impossibility shape this file's own header calls worse than a
# missing case. The handler is pinned at source level here as well, and
# mutation-proved by M25 and M29 below, which also hold the fallback to its
# four keys (`pr` admitted under #314's narrower rule) and to the stderr line
# naming which ledger failed.
expect_default "the verdict emitter captures its exit status" \
    'emitted="$(jq -n'
expect_default "  and re-parses the output before printing it" \
    'if [ "$emit_rc" -ne 0 ] || [ -z "$emitted" ] || ! jq -e . >/dev/null 2>&1 <<<"$emitted"; then'
expect_default "  and falls back to a hand-built verdict rather than empty stdout" \
    '"self_measured_reason":"verdict_emitter_failed",'
# WHICH INPUT BROKE IT, on the one channel that will ever carry it. The emitter's
# death is unreproducible after the fact — the ledgers die with the process — so
# this stderr line is the whole forensic record, and until #314 it named the exit
# code and not the cause (#312's review). The `fallback` mutant arm asserts the
# behaviour; this pins the two ledgers being re-tested rather than described.
expect_default "the emitter fallback re-tests each ledger and reports which failed" \
    'emit_why="$emit_why; $(ledger_note ANOMALIES "$ANOMALIES"), $(ledger_note PROBE_ERRORS "$PROBE_ERRORS")"'
# THE NAME `gh` IS THE CHOKEPOINT. A wrapper under its own name was a bound by
# convention, and the grep that guarded it (`\$\(gh [a-z]`) refused exactly one
# spelling: `gh api … | jq`, `if gh …; then`, `< <(gh …)`, `$( gh`,
# `$(command gh` and a bare `gh api … >/dev/null` all passed — the last one
# measured, inserted after the repo lookup, with case 17 whitelisting the call
# and the gate green. The probe now shadows the binary with a function, so
# every spelling is bounded by construction. Pinned here is the SHAPE that
# makes that true — the shadow exists, and `command gh`, the one reach to the
# binary, occurs exactly once and inside it — while 17b's calls-vs-bounds
# parity is the behaviour and M33 adds two bare calls in the shapes the grep
# missed and requires both to run under the bound.
shadow_n="$(grep -c '^gh() {' "$PROBE")"
if [ "$shadow_n" -eq 1 ]; then
    ok "the probe shadows gh with a function, so the name is the chokepoint"
else
    bad "found $shadow_n definitions of gh() in the probe; the bound is a convention again"
fi
# Code lines only: the comment inside the shadow names `command gh` as well.
cmd_gh_lines="$(grep -n 'command gh' "$PROBE" | grep -v ':[[:space:]]*#')"
cmd_gh_n="$(printf '%s\n' "$cmd_gh_lines" | grep -c .)"
shadow_range="$(awk '/^gh\(\) \{/{s=NR} s && /^\}/{print s "-" NR; exit}' "$PROBE")"
cmd_gh_ln="${cmd_gh_lines%%:*}"
if [ "$cmd_gh_n" -eq 1 ] && [ -n "$shadow_range" ] \
   && [ "$cmd_gh_ln" -ge "${shadow_range%-*}" ] && [ "$cmd_gh_ln" -le "${shadow_range#*-}" ]; then
    ok "  and 'command gh' occurs exactly once, inside the shadow (line $cmd_gh_ln of $shadow_range)"
else
    bad "  'command gh' must occur exactly once and inside gh(): $cmd_gh_n occurrence(s) [$cmd_gh_lines], shadow spans '$shadow_range'"
fi
# EVERY add_error SCOPE IS FROM THE CLOSED SET. The count is by exclusion now,
# so a misspelt scope fails CLOSED at runtime (M34 proves it); this is the
# other half — a misspelling is a red build rather than a quietly-counted
# oddity in the ledger. Comment lines are excluded; the second token is read
# QUOTE-AGNOSTICALLY, since `add_error "firstparty"` passed a census that read
# an unquoted token only (review of #315); and the vacuity check is an
# EQUALITY between the tokens extracted and the code lines that call
# `add_error`, so a census that stopped matching a call shape is red rather
# than a clean set measured over fewer sites.
scope_tokens() { # <probe source> — the scope token of every add_error call on a code line, quotes stripped
    grep -v '^[[:space:]]*#' "$1" | grep -oE "add_error [\"']?[A-Za-z_]+" \
        | sed -e 's/^add_error //' -e "s/^[\"']//"
}
scope_violations() { # <probe source> — echoes every scope outside {first_party, attribution, probe}
    scope_tokens "$1" | sort -u | grep -v -x -e first_party -e attribution -e probe
}
scope_lines="$(grep -v '^[[:space:]]*#' "$PROBE" | grep -c 'add_error ')"
scope_n="$(scope_tokens "$PROBE" | grep -c .)"
scope_bad="$(scope_violations "$PROBE")"
if [ -z "$scope_bad" ] && [ "$scope_n" -gt 0 ] && [ "$scope_n" -eq "$scope_lines" ]; then
    ok "every add_error call site uses a scope from the closed set ($scope_n tokens over $scope_lines calling lines)"
else
    bad "add_error scope outside the closed set, or the census broke ($scope_n tokens over $scope_lines calling lines): $scope_bad"
fi
# And no other way to REACH the binary by name. `command -v gh`, `type gh`,
# `which gh` and `hash gh` each answer for the function or for whatever is on
# PATH, so after the shadow every one of them is vacuous — and a bound
# "verified" through one would be a convention again.
gh_lookup_n="$(grep -v '^[[:space:]]*#' "$PROBE" | grep -cE 'command -v gh|type gh|which gh|hash gh')"
if [ "$gh_lookup_n" -eq 0 ]; then
    ok "  and the probe never looks the binary up by name, which the shadow makes meaningless"
else
    bad "  the probe looks gh up by name on $gh_lookup_n code line(s); after the shadow that answers nothing"
fi
# And one BEHAVIOURAL run with the two behaviour-carrying knobs unset, so the
# defaults are exercised and not merely read. The URL stays pinned: unsetting it
# would reach the real network, which this gate must never do.
D="$(scenario defaults "$PR_CLEAN" "$RUNS_CLEAN" 3600 irrelevant)"
: >"$WORK/calls"
: >"$WORK/bounds"
PATH="$BIN:$PATH" SCENARIO_DIR="$D" MOCK_CALLS="$WORK/calls" \
MOCK_BOUNDS="$WORK/bounds" \
PLATFORM_STATUS_URL="https://status.example.invalid/api/v2/summary.json" \
    bash "$PROBE" --repo mock-org/mock-repo --pr 301 >"$WORK/stdout" 2>"$WORK/stderr"
STATUS=$?
STDOUT="$(cat "$WORK/stdout")"
VERDICT="$(jq -r '.verdict // "«no verdict»"' <<<"$STDOUT" 2>/dev/null)"
expect_verdict "with no PLATFORM_* set, the default component scope still excludes Copilot" "healthy"

# ==============================================================================
echo "24. an empty-string name is an ANOMALY, not a silently dropped entry" >&2
# jq's `//` falls back only on null/false. `.name // .context // "(unnamed)"`
# therefore KEEPS an empty-string name, the shell guard `[ -n "$ck" ]` drops the
# entry, and the probe answers `healthy` on a rollup it had already flagged.
# The `(unnamed)` fallback was dead code, which is the tell that coverage was
# intended and never landed.
D="$(scenario emptyname "$PR_EMPTY_NAME" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "an empty-string check name is degraded (unattributed), never healthy" "degraded (unattributed)"
expect_kind "and it is reported as an empty-state check" "empty_state_check"
expect_field "the fallback name reaches the detail, so the entry is nameable" \
    '.anomalies[0].detail' "(unnamed) is in the rollup with no status, conclusion or state"

D="$(scenario emptyctx "$PR_EMPTY_CONTEXT" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "an empty-string StatusContext context is degraded too, not dropped" "degraded (unattributed)"

# The predicate has THREE conjuncts and M15 mutated only `.state`, so dropping
# `.status` or `.conclusion` was undetected. This fixture is what gives those
# two mutants somewhere to move: a check still RUNNING and a concluded check
# with no status, NEITHER of which is an empty-state placeholder. It also
# creates the `midflight` scenario the mutants below reuse - a mutant naming a
# scenario no case builds runs against a missing directory and reports
# `unknown` for both arms, which reads as UNDETECTED for the wrong reason.
D="$(scenario midflight "$PR_MIDFLIGHT" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a check mid-flight is NOT an empty-state placeholder" "healthy"
expect_field "and nothing is reported against it" '.anomalies | length' "0"

# ==============================================================================
echo "25. a TRUNCATED runs page cannot earn clean" >&2
# `truncated` was computed, recorded and then ignored by the decision that
# consumes it. The header names under-detection as the direction that matters:
# a page boundary inside the oldest included head's run set shrinks the
# intersection, so the missing run is required of nobody and the comparison
# reaches `clean` -> `healthy`. That is #285's own acceptance criterion failing
# inside the file written to satisfy it.
D="$(scenario trunc "$PR_CLEAN" "$RUNS_TRUNCATED_FULL" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a full page resolves unknown, never healthy" "unknown"
expect_field "the probe says it did not measure" '.self_measured' "not_measured"
expect_field "and names truncation as the reason" '.self_measured_reason' "runs_page_truncated"
expect_field "while still REPORTING the flag, which is what a caller reads" \
    '.checks_run.runs_page_truncated' "yes"

# The control, and it is the half that makes the pair a measurement rather than
# an assertion: the SAME reality on a page that is not full is still healthy,
# so this section cannot pass by making the probe pessimistic about everything.
D="$(scenario notrunc "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "the same reality on a SHORT page is healthy" "healthy"

# ==============================================================================
echo "26. every string reaching a reported field is sanitised, bidi included" >&2
# A fork-PR author controls branch and job names; both land in reported fields
# and this repo is PUBLIC. The probe's own comment claimed the check-name
# sanitiser stopped the same injection BRANCH_SAFE does - it did not, stripping
# control characters only, so RLO/LRM passed through three of the five sites.
D="$(scenario hostile "$PR_HOSTILE" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
if [ "$(json_has_unsafe "$STDOUT")" = "no" ]; then
    ok "no control or bidi character survives into any reported JSON value"
else
    bad "a control or bidi character reached a reported JSON value"
fi
if [ "$(text_has_unsafe "$STDERR")" = "no" ]; then
    ok "nor into the human-readable stderr line"
else
    bad "a control or bidi character reached the probe's stderr line"
fi
# The fixture must actually CARRY the hostile characters, or both checks above
# pass by measuring nothing - which is the state every other fixture is in.
if [ "$(text_has_unsafe "$PR_HOSTILE")" = "yes" ]; then
    ok "and the fixture really does carry them, so the pair is not vacuous"
else
    bad "the hostile fixture carries no unsafe character; section 26 proves nothing"
fi

# Source-level, and it asks a question the behavioural pair cannot: do the
# probe's own sanitiser sites still agree with EACH OTHER? A site that drops
# back to the control-only class is the finding itself, and a fixture only ever
# covers the sites its own payload happens to reach.
# The class is no longer a regex literal repeated per site: it is ONE jq
# definition injected into every program that sanitises. That is forced, not
# stylistic — the Unicode tag block is outside the BMP and jq's `\uXXXX`
# escape cannot express it, so a regex class could not cover it at any number
# of sites. So the question changed from "do the classes agree" to "is there
# exactly one, and does every sanitising program get it".
sani_def="$(grep -c "^UNSAFE_JQ_DEF='" "$PROBE")"
sani_sites="$(grep -c '"\$UNSAFE_JQ_DEF"' "$PROBE")"
if [ "$sani_def" = "1" ]; then
    ok "there is exactly ONE definition of the unsafe class"
else
    bad "found $sani_def definitions of the unsafe class; there must be exactly one"
fi
if grep -q 'gsub("\[\\u0000' "$PROBE"; then
    bad "a per-site regex sanitiser class is back; it cannot express the non-BMP tag block"
else
    ok "no per-site regex class remains, so no site can silently lose the tag block"
fi
# Vacuity floor: a census that stopped matching would report "one class" while
# measuring nothing at all, which is how a clean tree and a broken extractor
# look identical.
if [ "${sani_sites:-0}" -ge 5 ]; then
    ok "and every sanitising program is injected with it ($sani_sites sites, floor 5)"
else
    bad "the sanitiser census found only $sani_sites sites (floor 5) - the extractor is broken, not the tree"
fi

# ==============================================================================
echo "27. the OTHER two doors into healthy, both found after the first three fixes" >&2
# The header's "two doors" is a TAXONOMY (first-party, attribution), not a count
# of bugs. These are two more concrete paths through it, and both reported
# `healthy` on a platform that was not.

# Door 3 (attribution). `relevant` asks whether a component NAME CONTAINS a
# scope token, so the MORE SPECIFIC `github actions` matches the component
# `Actions` not at all. An operator-settable value therefore silently disabled
# attribution AND manufactured `operational` through a live incident.
SCOPE_OVERRIDE="github actions"
D="$(scenario narrowscope "$PR_CLEAN" "$RUNS_CLEAN" 3600 incident)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a scope matching NO component is unknown, never healthy" "unknown"
expect_field "and the status page is unknown, not a manufactured operational" '.status_page' "unknown"
unset SCOPE_OVERRIDE
# The control: the SAME payload under a scope that does match still attributes.
D="$(scenario widescope "$PR_CLEAN" "$RUNS_CLEAN" 3600 incident)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "while a scope that DOES match still attributes the incident" "degraded (attributed)"

# Door 4 (first-party). An empty rollup skips the empty-state read entirely —
# there is nothing to iterate — so `ROLLUP_CHECK` stays `not_run`, no anomaly is
# raised, and the run comparison earns `clean` UNOPPOSED. That is #285's own
# shape at its most extreme: `gh pr view` exiting 0 with ALL checks missing.
# `merge-shepherd.sh` already refuses it; the probe held both halves of the
# contradiction and compared them nowhere.
D="$(scenario emptyrollup "$PR_EMPTY_ROLLUP" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "an empty rollup beside runs that DID happen is unknown, never healthy" "unknown"
expect_field "and the reason names the contradiction" '.self_measured_reason' "rollup_empty_with_runs"
# The control that keeps this from being blanket pessimism: a repo with no CI at
# all has an empty rollup AND no runs, which is ordinary.
D="$(scenario nocirepo "$PR_EMPTY_ROLLUP" "$RUNS_EMPTY" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_field "a repo with no CI at all is not blamed for it" '.self_measured_reason' "no_prior_heads"

# ==============================================================================
echo "27b. a generator that DIES is no read at all — both doors, behaviourally" >&2
# The failed-generator door into `healthy`, which the header enumerates and
# which had no behavioural case: three source-level pins, each defeatable. Two
# generators, two mechanisms. The empty-state read dies on a REAL fixture — a
# rollup whose entries are numbers passes every earlier guard and `.status` on
# a number is a jq error. The missing-run read cannot be killed by any payload
# (see BIN_JQ), so its guard is reached by fault injection instead, with the
# shim's own ledger proving the fault landed. Both guards must turn a dead read
# into "no read happened": not_measured, the check reported as not_run, an
# error on the ledger. Measured on the guard-less shape: `healthy`, `clean`,
# `probe_errors: []` — on a run whose read died.
D="$(scenario badrollup "$PR_BAD_ROLLUP" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a rollup of numbers kills the empty-state read, and the run is unknown, never healthy" "unknown"
expect_field "  the read is reported as not having run" .checks_run.rollup_empty_state "not_run"
expect_errkind "  and the dead generator is on the ledger" "incomplete_payload"
expect_field "  which is why the run is not measured" .self_measured_reason "probe_errors_present"
expect_field "  while the run comparison DID run, so clean was exactly one guard away" \
    .checks_run.run_comparison "ran"

D="$(scenario jqfault "$PR_CLEAN" "$RUNS_CLEAN" 3600 green)"
printf '%s' '.missing[] | clean' >"$D/jq.fail"
PATH_OVERRIDE="$BIN_JQ:$PATH" run_probe "$PROBE" "$D" --pr 301
jqf_n="$(grep -c . "$WORK/jqfaults")"
if [ "$jqf_n" -eq 1 ]; then
    ok "the fault was injected into the missing-run generator exactly once"
else
    bad "$jqf_n faults recorded, expected 1 — the case is not reaching the generator it exists to kill"
fi
expect_verdict "  and a dead missing-run read is unknown, never healthy" "unknown"
expect_field "  the comparison is UN-certified: RUN_CHECK was already ran, and is reset" \
    .checks_run.run_comparison "not_run"
expect_field "  naming the failed comparison" .self_measured_reason "run_comparison_failed"
expect_errkind "  and it is on the ledger" "incomplete_payload"

# ==============================================================================
echo "27c. the ONE fixture-reachable emitter death: a check name over the argv cap" >&2
# Section 23 used to say no fixture could kill the shipped `jq -n`. The
# emitter's own inputs are script-built, but the LEDGER BUILDERS put fixture
# text on argv — `add_anomaly … --arg d "<name> is in the rollup…"` — and the
# probe already documents the argv cap for the runs payload. A check name past
# it kills that jq at exec (E2BIG; bash reports 126 and no output), the ledger
# is assigned the empty string, `n_anomalies` reads it as 0, the verdict
# computes `healthy`, and the emitter dies on `--argjson anomalies ""` into the
# fallback. Measured on this host (ARG_MAX 1,048,576) and true on Linux at a
# lower cap (MAX_ARG_STRLEN 131,072), so 1.2 MB clears both. The probe FAILS
# CLOSED here — this is not a wrong verdict — but the false impossibility was
# the defect: CLAUDE.md tells the next editor to trust the header. The name is
# built through stdin, since building it with `--arg` would die of the same
# cap this case exists to cross.
PR_HUGE_NAME="$(head -c 1200000 /dev/zero | tr '\0' 'a' | jq -Rs '{number:301, headRefOid:"aa11bb2",
  headRefName:"feat/clean", mergeStateStatus:"BLOCKED",
  statusCheckRollup:[{__typename:"CheckRun", name:., status:"", conclusion:"", state:""}]}')"
D="$(scenario hugename "$PR_HUGE_NAME" "$RUNS_CLEAN" 3600 green)"
run_probe "$PROBE" "$D" --pr 301
expect_verdict "a check name over the argv cap kills the ledger builder, and the run lands in the fallback as unknown" "unknown"
expect_status "  and exits 0" 0
expect_field "  through the fallback, which says so" .self_measured_reason "verdict_emitter_failed"
huge_keys="$(jq -c 'keys' <<<"$STDOUT" 2>/dev/null)"
if [ "$huge_keys" = '["explains","pr","self_measured_reason","verdict"]' ]; then
    ok "  with exactly the fallback's four keys"
else
    bad "  the object is not the four-key fallback: keys $huge_keys"; dump
fi
# THE ONE MEASURED VALUE THE FALLBACK CARRIES. `pr` is validated digits-only
# with no leading zero, so it is a JSON number by construction and cannot be
# what broke the emitter — and it is what tells a coordinator holding several
# PRs which of them this dead run was about (#314). An edition of the fallback
# carried nothing at all and was right about every other field.
expect_field "  and the validated pr survives, so the dead run is attributable" .pr "301"
expect_explains_nothing "  in the fallback's pinned words" emitter-failed
case "$STDERR" in
    *"the verdict emitter failed (jq exited 2;"*) ok "  and the summary names the emitter dying on its input, which is the mechanism claimed" ;;
    *) bad "  the summary does not name the emitter dying on its input: '$(printf '%.200s' "$STDERR")'"; dump ;;
esac
# AND WHICH INPUT BROKE IT — the half `jq exited 2` cannot carry. This failure
# is unreproducible after the fact, so the stderr line is the entire forensic
# record, and here it tells the whole causal chain: `add_anomaly` died at exec
# on the argv cap, leaving `$ANOMALIES` the EMPTY STRING (0 bytes, unparsable),
# which is what the emitter then died on. Without the per-ledger report,
# `jq exited 2` is equally consistent with the emitter itself dying on a
# perfectly good pair of ledgers — M25's shape, where both report `parsed` —
# and the two call for different fixes.
case "$STDERR" in
    *'$ANOMALIES FAILED jq -e . (0 bytes)'*'$PROBE_ERRORS parsed'*)
        ok "  and names the dead ledger builder's empty \$ANOMALIES as what the emitter choked on" ;;
    *) bad "  the summary does not report each ledger and its byte length: '$(printf '%.300s' "$STDERR")'"; dump ;;
esac

# ==============================================================================
echo "28. mutations" >&2
MUTANT="$WORK/mutant.sh"
apply_mutation() { # <label> <exact from-line> <to-line> [source] [dest]
    local label="$1" from="$2" to="$3" src="${4:-$PROBE}" dst="${5:-$MUTANT}" rc=0
    # Operands travel through the ENVIRONMENT, never through `awk -v`, which
    # performs BACKSLASH-ESCAPE PROCESSING on its assignments: a `from` line
    # containing jq's `"\(.name)"` arrives as `"(.name)"` and matches nothing,
    # while a `to` value containing a newline is a hard awk syntax error. Both
    # were measured here. Exactly-one match is required — `cmp -s` alone cannot
    # carry that, since it exits 2 on a missing file, which an `if` reads as
    # "they differ", so a mutation that matched nothing would report as applied
    # and every negative assertion after it would pass against a file that was
    # never run (the #262 lesson).
    MUT_FROM="$from" MUT_TO="$to" awk '
        BEGIN { n = 0; from = ENVIRON["MUT_FROM"]; to = ENVIRON["MUT_TO"] }
        $0 == from { print to; n++; next }
        { print }
        END { if (n != 1) exit 3 }
    ' "$src" >"$dst" || rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "$label — the target line did not match exactly once (awk rc=$rc); the mutation is stale"
        return 1
    fi
    if [ ! -s "$dst" ]; then bad "$label — the mutant is empty"; return 1; fi
    if cmp -s "$src" "$dst"; then bad "$label — the mutation changed nothing; the proof would be vacuous"; return 1; fi
    return 0
}

# Rows are joined on US (0x1f), never on TAB. TAB is IFS *whitespace*, so a run
# of two tabs collapses and an EMPTY field shifts every field after it — the
# #281 transport trap, which silently mis-declared a mutant here before this was
# changed. US is not IFS whitespace, so empty fields survive.
US=$'\037'
row() { local IFS="$US"; printf '%s' "$*"; }

# Fields: label, from-line, to-line, scenario, probe args, THE WRONG VERDICT THE
# MUTANT PRODUCES, why it matters. The wrong verdict is checked against the
# UNMUTATED run of the same scenario as well, so a stale declaration that
# happens to equal the correct answer cannot report CAUGHT vacuously. Field 6
# takes seven FORMS, because not every harm is a verdict: a plain verdict;
# `«exit»` (the exit code carries one); `reason:<r>` (the reason field);
# `unsafe` (hostile text reaches a reported field); `field:<jq path>=<value>`
# (any other reported field — M28c's harm is a `checks_run` that certifies a
# comparison whose read died, while the ledger still holds the verdict);
# `explains:<branch>` (the mutant's `explains` falls off that branch's canon
# while the unmutated one is on it); and `fallback[:<LEDGER>]` (the emitter
# died, and the fallback that answered is `unknown`, exit 0, exactly the four
# keys, the reason `verdict_emitter_failed`, the fallback's own explains canon,
# and a stderr line naming BOTH ledgers with their byte lengths — so a key
# renamed or dropped in the literal is red, which the 16-key edition never was.
# The optional `:<LEDGER>` additionally requires that ledger to be reported as
# having FAILED `jq -e .`, which is what separates "the ledger was corrupt"
# from "the ledger was fine and jq itself died": both are real, they call for
# different fixes, and the stderr line is the only place either is ever
# recorded). FOUR OPTIONAL trailing fields follow, each applied to BOTH arms:
# a PLATFORM_STATUS_COMPONENTS scope, `none` to drop --repo, a PATH key (`nt`,
# `gt`, `jqfault`) for the runs the default shimmed PATH cannot reach, and a
# CWD key (`noorigin`) for a mutant whose harm only appears where the repo
# derivation FAILS — which, since #314, is a property of the working directory
# rather than of an argument, so it travels with `none` and never alone.
MUTANTS=(
"$(row "M1 green resolves to healthy" \
  '  anomaly/operational)    VERDICT="degraded (unattributed)" ;;' \
  '  anomaly/operational)    VERDICT="healthy" ;;' \
  unattributed '--pr 283' 'healthy' \
  'a green status page would refute a live first-party anomaly')"
"$(row "M2 an unreachable endpoint resolves to healthy" \
  '  clean/unknown)          VERDICT="unknown" ;;' \
  '  clean/unknown)          VERDICT="healthy" ;;' \
  unknown-clean '--pr 301' 'healthy' \
  'a status endpoint nobody could read would be treated as assume-fine')"
"$(row "M3 an anomaly beside a dark page loses its degradation" \
  '  anomaly/unknown)        VERDICT="degraded (unattributed)" ;;' \
  '  anomaly/unknown)        VERDICT="unknown" ;;' \
  unattributed-dark '--pr 283' 'unknown' \
  'measured first-party degradation would be discarded because attribution failed')"
"$(row "M4 an open incident stops attributing" \
  '  not_measured/incident)  VERDICT="degraded (attributed)" ;;' \
  '  not_measured/incident)  VERDICT="unknown" ;;' \
  nomeasure-incident '' 'unknown' \
  'a reported outage would explain nothing')"
"$(row "M5 row 4 collapses" \
  '  clean/incident)         VERDICT="degraded (attributed)" ;;' \
  '  clean/incident)         VERDICT="healthy" ;;' \
  clean-incident '--pr 301' 'healthy' \
  'an open Actions incident would be reported as a healthy platform')"
"$(row "M6 the age floor is neutered" \
  '    elif [ "$HEAD_AGE" -lt "$MIN_AGE" ]; then' \
  '    elif false; then' \
  fresh '--pr 301' 'degraded (unattributed)' \
  'a workflow that has not started yet would be reported as missing')"
"$(row "M7 the exit code carries the verdict" \
  'exit 0' 'exit 12' \
  unattributed '--pr 283' '«exit»' \
  'a verdict in the exit code is one set -e away from being the gate this must never be')"
"$(row "M8 the empty-state check is readmitted as sufficient for clean" \
  'elif [ "$RUN_CHECK" = "ran" ]; then' \
  'elif [ "$RUN_CHECK" = "ran" ] || [ "$ROLLUP_CHECK" = "ran" ]; then' \
  no-baseline '--pr 301' 'healthy' \
  'the empty-state read cannot see an ABSENT check, so accepting it as sufficient certifies a branch nothing compared')"
"$(row "M8b RUN_CHECK is set before the intersection is known non-empty" \
  '      if [ "$n_required" -eq 0 ]; then' \
  '      if false; then' \
  no-run-disjoint '--pr 301' 'healthy' \
  'an empty intersection would certify a comparison that had no subject')"
"$(row "M9 a transport failure becomes an anomaly" \
  '    add_error first_party gh_call_failed "gh pr view $PR exited $rc$(gh_rc_note "$rc")"' \
  '    add_anomaly gh_call_failed "gh pr view $PR exited $rc"' \
  ghfail '--pr 283' 'degraded (unattributed)' \
  'an expired token or a closed laptop would be reported as platform degradation')"
"$(row "M9d a FIRED BOUND becomes an anomaly" \
  '    add_error first_party gh_call_failed "gh pr view $PR exited $rc$(gh_rc_note "$rc")"' \
  '    add_anomaly gh_call_failed "gh pr view $PR exited $rc"' \
  ghtimeout '--pr 301' 'degraded (unattributed)' \
  'the probe would report its OWN timeout as first-party evidence that the platform is degraded')"
"$(row "M9b the error ledger is not consulted" \
  'elif [ "$n_fp_errors" -gt 0 ]; then' \
  'elif false; then' \
  errors-but-clean-rollup '--pr 301' 'reason:nothing_measurable' \
  'a half-read platform would stop naming the failed calls as the reason it could not measure')"
"$(row "M9c the run comparison result is not validated" \
  '          prior_heads: ($prior_heads | length),' \
  '          prior_heads: "x",' \
  healthy '--pr 301' 'unknown' \
  'an unusable derivation would fall through to the branch asserting the check RAN')"
"$(row "M10 the empty-state read is gated on the rollup being non-empty" \
  '  if [ "${rollup_n:-0}" -gt 0 ]; then' \
  '  if false; then' \
  fresh-empty-state '--pr 283' 'unknown' \
  'the #285 fingerprint would vanish on a fresh head, where the run signals are already suppressed')"
"$(row "M11 the baseline becomes a union" \
  '         else ($sets | reduce .[] as $s (null; if . == null then $s else (. - (. - $s)) end))' \
  '         else ($sets | reduce .[] as $s ([]; . + $s | unique))' \
  partial-baseline '--pr 301' 'degraded (unattributed)' \
  'a path filter or a rename on ONE prior head would read as degradation')"
"$(row "M12 the event whitelist is dropped" \
  '      | [ .workflow_runs[]? | select(.event as $e | $auto | index($e)) ] as $r' \
  '      | [ .workflow_runs[]? ] as $r' \
  dispatch-baseline '--pr 301' 'degraded (unattributed)' \
  'a one-off workflow_dispatch run on a prior head would be reported missing forever')"
"$(row "M12b the no-run signal stops consulting the intersection" \
  '        if [ "$n_required" -gt 0 ]; then' \
  '        if true; then' \
  no-run-disjoint '--pr 301' 'degraded (unattributed)' \
  'disjoint prior heads would make an ordinary push read as degradation')"
"$(row "M13 attribution stops being scoped to check-relevant components" \
  '          ([ .components[]? | select((.status // "") != "operational") | select(relevant(.name)) ]) as $comp' \
  '          ([ .components[]? | select((.status // "") != "operational") ]) as $comp' \
  irrelevant '--pr 301' 'degraded (attributed)' \
  'a Copilot blip would invent an excuse for a genuinely red check')"
"$(row "M14 an unrecognisable status payload reads as operational" \
  '        then "unknown"' \
  '        then "operational"' \
  garbage '--pr 301' 'healthy' \
  'a 200 carrying an error body would be read as a green platform')"
"$(row "M15 the empty-state predicate drops its .state conjunct" \
  '                  and ((.state // "") == "") )' \
  '                  and true )' \
  healthy '--pr 301' 'degraded (unattributed)' \
  'a healthy StatusContext (vercel: SUCCESS) would be read as an empty-state placeholder')"
"$(row "M15b the empty-state predicate drops its .status conjunct" \
  '        | select( ((.status // "") == "")' \
  '        | select( true' \
  midflight '--pr 301' 'degraded (unattributed)' \
  'a check still RUNNING would be read as an empty-state placeholder, fabricating degraded on every PR with CI mid-flight')"
"$(row "M15c the empty-state predicate drops its .conclusion conjunct" \
  '                  and ((.conclusion // "") == "")' \
  '                  and true' \
  midflight '--pr 301' 'degraded (unattributed)' \
  'a concluded check with no status would be read as an empty-state placeholder')"
"$(row "M20 absence is tested with // again instead of by length" \
  '        | (firstnonempty(((.name // "") | tostring); ((.context // "") | tostring)) | clean)' \
  '        | ((.name // .context // "(unnamed)") | clean)' \
  emptyname '--pr 301' 'healthy' \
  'an empty-string check name would be found, emitted and then silently discarded, and the probe would answer healthy')"
"$(row "M21 truncation stops being consulted by the verdict" \
  '      elif [ "$RUNS_TRUNCATED" != "no" ]; then' \
  '      elif false; then' \
  trunc '--pr 301' 'healthy' \
  'a truncated page would earn clean, so an under-detected missing run would resolve healthy')"
"$(row "M22 the unsafe class loses the Unicode TAG BLOCK" \
  '    or (. >= 917504 and . <= 917631);' \
  '    ;' \
  hostile '--pr 301' 'unsafe' \
  'the standard invisible ASCII-mirroring carrier for prompt injection would reach a reported field')"
"$(row "M22b the unsafe class loses the bidi overrides" \
  '    or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297)' \
  '    or false' \
  hostile '--pr 301' 'unsafe' \
  'an RLO in a fork-controlled job name would reach a reported field')"
"$(row "M23 the scope-matches-nothing guard is removed" \
  '        elif ((((.components // []) | length) > 0)' \
  '        elif (false and (((.components // []) | length) > 0)' \
  narrowscope '--pr 301' 'healthy' \
  'an operator-settable component scope matching nothing would classify a live outage operational' \
  'github actions')"
"$(row "M24 the empty-rollup contradiction guard is removed" \
  '      elif [ "${rollup_n:-0}" -eq 0 ] && [ "$n_cur" -gt 0 ]; then' \
  '      elif false; then' \
  emptyrollup '--pr 301' 'healthy' \
  'an empty rollup beside runs that did happen would let the run comparison earn clean unopposed')"
"$(row "M25 the verdict emitter dies" \
  '  --argjson anomalies "$ANOMALIES" \' \
  '  --argjson anomalies "" \' \
  healthy '--pr 301' 'fallback' \
  'a dead emitter would hand the caller exit 0 and EMPTY stdout, so jq -r .verdict yields the empty string — not one of the four verdicts, and not unknown either')"
"$(row "M26 the gh bound is not applied" \
  '    "$GH_TIMEOUT_CMD" -k 5 "$GH_TIMEOUT" gh "$@"' \
  '    command gh "$@"' \
  ghtimeout '--pr 301' 'healthy' \
  'the three load-bearing calls would run unbounded again, and a hang would cost the calling loop its tick')"
"$(row "M9e a FIRED BOUND at the commit read becomes an anomaly" \
  '    add_error first_party gh_call_failed "gh api repos/$REPO/commits/$HEAD exited $rc$(gh_rc_note "$rc")"' \
  '    if [ "$rc" -eq 124 ]; then add_anomaly gh_timeout "the commit read timed out"; else add_error first_party gh_call_failed "gh api repos/$REPO/commits/$HEAD exited $rc$(gh_rc_note "$rc")"; fi' \
  ghtimeout-commit '--pr 301' 'degraded (unattributed)' \
  'the commit read would report its OWN cutoff as degradation; every plain failure still records an error, so only a bound firing at THIS site can see it — measured undetected while only the pr view site had a case')"
"$(row "M9f a FIRED BOUND at the runs read becomes an anomaly" \
  '    add_error first_party gh_call_failed "gh api actions/runs for $BRANCH_SAFE exited $rc$(gh_rc_note "$rc")"' \
  '    if [ "$rc" -eq 124 ]; then add_anomaly gh_timeout "the runs read timed out"; else add_error first_party gh_call_failed "gh api actions/runs for $BRANCH_SAFE exited $rc$(gh_rc_note "$rc")"; fi' \
  ghtimeout-runs '--pr 301' 'degraded (unattributed)' \
  'the runs read would report its OWN cutoff as degradation, invisible to every plain-failure case for the same reason')"
"$(row "M9h the KILL GRACE at the commit read becomes an anomaly" \
  '    add_error first_party gh_call_failed "gh api repos/$REPO/commits/$HEAD exited $rc$(gh_rc_note "$rc")"' \
  '    if [ "$rc" -eq 137 ]; then add_anomaly gh_killed "the commit read was killed"; else add_error first_party gh_call_failed "gh api repos/$REPO/commits/$HEAD exited $rc$(gh_rc_note "$rc")"; fi' \
  ghkilled-commit '--pr 301' 'degraded (unattributed)' \
  'the 137 sibling of M9e — measured green while 17c2 fired the grace at the first call alone')"
"$(row "M9i the KILL GRACE at the runs read becomes an anomaly" \
  '    add_error first_party gh_call_failed "gh api actions/runs for $BRANCH_SAFE exited $rc$(gh_rc_note "$rc")"' \
  '    if [ "$rc" -eq 137 ]; then add_anomaly gh_killed "the runs read was killed"; else add_error first_party gh_call_failed "gh api actions/runs for $BRANCH_SAFE exited $rc$(gh_rc_note "$rc")"; fi' \
  ghkilled-runs '--pr 301' 'degraded (unattributed)' \
  'the 137 sibling of M9f')"
"$(row "M9g a FAILED REPO DERIVATION becomes an anomaly" \
  '    add_error first_party repo_lookup_failed "$repo_why; pass --repo owner/name"' \
  '    add_anomaly repo_lookup_failed "$repo_why"' \
  lookup '--pr 301' 'degraded (unattributed)' \
  'a checkout with no origin remote — a local fact about THIS machine — would be reported as first-party evidence that the PLATFORM is degraded; the site changed from a bounded gh call to a local git read in #314 and the rule did not' \
  '' none '' noorigin)"
"$(row "M27 the first-party scope filter is widened to count the probe scope" \
  "n_fp_errors=\"\$(jq -r '[.[] | select(.scope != \"attribution\" and .scope != \"probe\")] | length' <<<\"\$PROBE_ERRORS\" 2>/dev/null)\"" \
  "n_fp_errors=\"\$(jq -r '[.[] | select(.scope != \"attribution\")] | length' <<<\"\$PROBE_ERRORS\" 2>/dev/null)\"" \
  notimeout '--pr 301' 'unknown' \
  'every host without coreutils would report not_measured on every run, silently' \
  '' '' nt)"
"$(row "M28 the empty-state guard certifies a read that died" \
  '      add_error first_party incomplete_payload "the empty-state read over the rollup failed (jq exited $empty_rc)"' \
  '      ROLLUP_CHECK="ran"' \
  badrollup '--pr 301' 'healthy' \
  'a rollup the generator could not read would be certified as read, and the run comparison would earn clean unopposed — measured undetected under three source pins')"
"$(row "M28b the missing-run guard is neutered" \
  '        if [ "$missing_rc" -ne 0 ]; then' \
  '        if false; then' \
  jqfault '--pr 301' 'healthy' \
  'a dead missing-run read would leave RUN_CHECK=ran and the comparison it discarded would earn clean' \
  '' '' jqfault)"
"$(row "M28c the missing-run guard stops un-certifying the comparison" \
  '          RUN_CHECK="not_run"' \
  '          :' \
  jqfault '--pr 301' 'field:.checks_run.run_comparison=ran' \
  'the ledger still holds the verdict, but checks_run would certify a comparison whose read died; the needle for this line also matched the initialiser, so its source pin was vacuous' \
  '' '' jqfault)"
"$(row "M29 the anomaly ledger is unparsable at emit time" \
  "ANOMALIES='[]'" \
  "ANOMALIES=''" \
  healthy '--pr 301' 'fallback:ANOMALIES' \
  'a ledger that cannot be parsed already reads as ZERO anomalies at the verdict, so it must land in the fallback as unknown — an emitter that cannot fail on its inputs would emit healthy beside an empty list')"
"$(row "M30 the clean-beside-incident explains is inverted" \
  '      EXPLAINS="nothing about this PR — a platform incident is open, but this PR'"'"'s own check data was compared and came back complete, so the incident is context and not an explanation for anything observed here"' \
  '      EXPLAINS="nothing here is unexplained: a green page is not an explanation, so a stall that survives this verdict is a real defect — escalate it"' \
  clean-incident '--pr 301' 'explains:attributed-clean' \
  'the field SKILL.md orders callers to report INSTEAD OF the verdict would tell them a stall is a real defect — measured green under a matcher that accepted either needle for every branch')"
)

mut_ran=0
for r in "${MUTANTS[@]}"; do
    IFS="$US" read -r m_label m_from m_to m_dir m_args m_wrong m_why m_scope m_repoarg m_path m_cwd <<<"$r"
    # OPTIONAL trailing fields. A mutant whose harm only appears under a
    # particular PLATFORM_STATUS_COMPONENTS, without --repo, on a curated
    # PATH, or in a particular working directory must run that way for BOTH
    # arms — the baseline too, or the comparison is against a different
    # configuration than the mutant and the proof is meaningless. Measured:
    # without this, M23 ran both arms under the default scope, both returned
    # the same verdict, and the mutant reported UNDETECTED for a reason that
    # had nothing to do with the guard it removes.
    # Rows omitting a field leave it empty, and run_probe falls back to the
    # pinned default for it.
    SCOPE_OVERRIDE="$m_scope"
    REPO_ARG_OVERRIDE="$m_repoarg"
    case "$m_path" in
        "")      PATH_OVERRIDE="" ;;
        nt)      PATH_OVERRIDE="$BIN_NT" ;;
        gt)      PATH_OVERRIDE="$BIN_GT" ;;
        jqfault) PATH_OVERRIDE="$BIN_JQ:$PATH" ;;
        *) bad "$m_label — unknown PATH key '$m_path'"; continue ;;
    esac
    case "$m_cwd" in
        "")       CWD_OVERRIDE="" ;;
        noorigin) CWD_OVERRIDE="$CWD_NOORIGIN" ;;
        *) bad "$m_label — unknown CWD key '$m_cwd'"; continue ;;
    esac
    apply_mutation "$m_label" "$m_from" "$m_to" || continue
    mut_ran=$((mut_ran + 1))
    # Baseline first: the SHIPPED script on the very same scenario. Without it a
    # declared "wrong" verdict that happens to be the CORRECT one would report
    # CAUGHT while proving nothing.
    # shellcheck disable=SC2086
    run_probe "$PROBE" "$WORK/sc-$m_dir" $m_args
    good_verdict="$VERDICT"; good_status="$STATUS"; good_stdout="$STDOUT"
    # shellcheck disable=SC2086
    run_probe "$MUTANT" "$WORK/sc-$m_dir" $m_args
    if [ "${m_wrong#reason:}" != "$m_wrong" ]; then
        # The harm this mutant causes is a changed REASON, not a changed verdict:
        # once `clean` requires the run comparison, every first-party error path
        # already fails to set RUN_CHECK, so the ledger branch is defence in
        # depth and the reason field is where its removal shows.
        m_want="${m_wrong#reason:}"
        good_reason="$(jq -r '.self_measured_reason // ""' <<<"$good_stdout" 2>/dev/null)"
        mut_reason="$(field .self_measured_reason)"
        if [ "$mut_reason" = "$m_want" ] && [ "$mut_reason" != "$good_reason" ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label UNDETECTED: reason '$mut_reason' (unmutated: '$good_reason'); declared '$m_want'"
        fi
    elif [ "${m_wrong#field:}" != "$m_wrong" ]; then
        # Any other reported field: `field:<jq path>=<value>`. Both arms are
        # read, and the exit code is asserted as it is for a verdict.
        m_spec="${m_wrong#field:}"
        m_path_jq="${m_spec%%=*}"; m_want="${m_spec#*=}"
        good_val="$(jq -r "$m_path_jq // \"\"" <<<"$good_stdout" 2>/dev/null)"
        mut_val="$(field "$m_path_jq")"
        if [ "$mut_val" = "$m_want" ] && [ "$mut_val" != "$good_val" ] && [ "$STATUS" -eq 0 ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label UNDETECTED: $m_path_jq = '$mut_val' (unmutated: '$good_val'), exit $STATUS; declared '$m_want'"
        fi
    elif [ "${m_wrong#explains:}" != "$m_wrong" ]; then
        # The harm is an `explains` that has left its branch's canon while the
        # unmutated one is on it. Both arms, so a canon that no string matches
        # cannot report CAUGHT on a mutant that changed nothing relevant.
        m_branch="${m_wrong#explains:}"
        good_ex="$(explains_ok "$m_branch" "$good_stdout")"
        mut_ex="$(explains_ok "$m_branch")"
        if [ "$good_ex" = "yes" ] && [ "$mut_ex" = "no" ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label UNDETECTED: unmutated on canon=$good_ex, mutant on canon=$mut_ex — explains reads '$(field .explains)'"
        fi
    elif [ "${m_wrong%%:*}" = "fallback" ]; then
        # The emitter died and the FALLBACK answered. Everything about that
        # object is asserted, not only its verdict: exactly the four keys, the
        # reason, its explains canon, exit 0 — so a renamed or dropped key in
        # the literal is red. The 16-key edition of the literal was a second
        # copy of the schema held in step by nothing, and renaming a key in it
        # left this gate green; `pr` joined it in #314 under a narrower rule
        # (carry nothing that could be what broke it), which is exactly the
        # kind of relaxation that invites a second key with no such argument.
        # The stderr line is asserted too: it is the ONLY forensic record this
        # failure will ever leave, and naming both ledgers with their byte
        # lengths is what makes "the emitter itself died" distinguishable from
        # "an input was corrupt" after the fact.
        fb_keys="$(jq -c 'keys' <<<"$STDOUT" 2>/dev/null)"
        fb_reason="$(field .self_measured_reason)"
        fb_ex="$(explains_ok emitter-failed)"
        fb_note=no
        case "$STDERR" in
            *'$ANOMALIES'*' bytes)'*'$PROBE_ERRORS'*' bytes)'*) fb_note=yes ;;
        esac
        # `fallback:<LEDGER>` additionally requires that ledger to be reported
        # as having FAILED, which is the half a corruption mutant proves and an
        # emitter-death mutant cannot.
        fb_which="${m_wrong#fallback}"; fb_which="${fb_which#:}"
        fb_named=yes
        if [ -n "$fb_which" ]; then
            fb_named=no
            case "$STDERR" in *"\$$fb_which FAILED"*) fb_named=yes ;; esac
        fi
        if [ "$VERDICT" = "unknown" ] && [ "$good_verdict" != "unknown" ] && [ "$STATUS" -eq 0 ] \
           && [ "$fb_keys" = '["explains","pr","self_measured_reason","verdict"]' ] \
           && [ "$fb_reason" = "verdict_emitter_failed" ] && [ "$fb_ex" = "yes" ] \
           && [ "$fb_note" = "yes" ] && [ "$fb_named" = "yes" ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label UNDETECTED, or the fallback drifted: verdict '$VERDICT' (unmutated '$good_verdict'), exit $STATUS, keys $fb_keys, reason '$fb_reason', explains on canon=$fb_ex, ledger note=$fb_note, names ${fb_which:-«none»}=$fb_named"
        fi
    elif [ "$m_wrong" = "unsafe" ]; then
        # The harm is neither a verdict nor a reason: hostile text reaches a
        # REPORTED field unsanitised. BOTH sides are asserted - the unmutated
        # run must be clean and the mutant must not be - because checking only
        # the mutant passes just as happily on a fixture carrying no hostile
        # character at all, which is the state every fixture here was in.
        good_unsafe="$(json_has_unsafe "$good_stdout")"
        mut_unsafe="$(json_has_unsafe "$STDOUT")"
        if [ "$mut_unsafe" = "yes" ] && [ "$good_unsafe" = "no" ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label UNDETECTED: unmutated unsafe=$good_unsafe, mutant unsafe=$mut_unsafe"
        fi
    elif [ "$m_wrong" = "«exit»" ]; then
        if [ "$good_status" -eq 0 ] && [ "$STATUS" -ne 0 ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label UNDETECTED: unmutated exit $good_status, mutant exit $STATUS — the exit-code assertion proves nothing"
        fi
    elif [ "$VERDICT" = "$m_wrong" ] && [ "$VERDICT" != "$good_verdict" ]; then
        # The exit code is asserted on EVERY verdict-form mutant, not only on
        # M7's dedicated one. M7 proves the shipped `exit 0` is load-bearing;
        # this proves no OTHER path can grow an exit code that carries a
        # verdict — which is where the emitter fallback lands, since it is the
        # one path that produces a verdict without having measured anything and
        # is therefore the obvious place for a later "surely THAT should fail
        # loudly" to put a non-zero exit.
        if [ "$STATUS" -eq 0 ]; then
            ok "$m_label CAUGHT: $m_why"
        else
            bad "$m_label caught the verdict but exited $STATUS — a verdict must never travel in an exit code"
        fi
    else
        bad "$m_label UNDETECTED: the mutant returned '$VERDICT' (unmutated: '$good_verdict'); the declared wrong verdict was '$m_wrong'"
    fi
    unset SCOPE_OVERRIDE REPO_ARG_OVERRIDE PATH_OVERRIDE CWD_OVERRIDE
done
if [ "$mut_ran" -eq "${#MUTANTS[@]}" ]; then
    ok "every declared probe mutant ran (${#MUTANTS[@]} of ${#MUTANTS[@]})"
else
    bad "only $mut_ran of ${#MUTANTS[@]} declared probe mutants ran — the rest proved nothing"
fi

# The out-of-loop mutants below carry a RAN-COUNTER of their own, mirroring
# `mut_ran`. OUT_OF_LOOP_MUTANTS used to be a hand transcription that only the
# arithmetic at the bottom consulted, and its message blamed "a case was added
# or skipped" — so a deleted block plus one added case was green (measured).
# A block counts itself only after its mutation applied, exactly as the loop
# does, and the equality at the bottom has its own ok/bad.
oo_ran=0

# M16 — wire the probe into the merge writer. The scan in section 19 must flag it.
M16="$WORK/merge-shepherd-mutant.sh"
if apply_mutation "M16 the probe is wired into the merge writer" \
    'set -uo pipefail' \
    'set -uo pipefail; bash "$(dirname "$0")/probe-platform-health.sh" --pr "$PR" || exit 30' \
    "$SCRIPTS_DIR/merge-shepherd.sh" "$M16"; then
    oo_ran=$((oo_ran + 1))
    if [ -n "$(scan_for_probe "$M16")" ]; then
        ok "M16 CAUGHT: a merge writer consulting the platform verdict is flagged"
    else
        bad "M16 UNDETECTED: merge-shepherd.sh was wired to the probe and the scan stayed clean"
    fi
fi

# M17 — move a probe mention into the merge SECTION of SKILL.md. The section scan
# must flag it where a whole-file grep would not.
M17="$WORK/skill-mutant.md"
if apply_mutation "M17 the probe is named in the merge section" \
    '### 3. Merge or enqueue greens' \
    '### 3. Merge or enqueue greens'$'\n\n''Run `probe-platform-health.sh` and hold the merge on a degraded verdict.' \
    "$SKILL" "$M17"; then
    oo_ran=$((oo_ran + 1))
    m17_hits="$(scan_skill_sections "$M17")"
    case "$m17_hits" in
        *"### 3. Merge or enqueue greens: names"*)
            ok "M17 CAUGHT: a probe mention inside the merge section is flagged by the section scan" ;;
        *) bad "M17 UNDETECTED: the merge section was wired to the probe and the section scan reported '$m17_hits'" ;;
    esac
fi

# M18 — genuinely ADD a block to §2b, which is the mode canon exists to catch:
# every presence needle in section 21 still matches, because nothing was removed.
# Inserting before the NEXT heading appends to §2b, since section_of stops there.
M18="$WORK/skill-canon-mutant.md"
if apply_mutation "M18 §2b is inverted by ADDING a paragraph" \
    '### 3. Merge or enqueue greens' \
    '**Acting on the verdict.** When the probe returns `degraded`, hold the PR for this tick and skip the merge; a `healthy` verdict is the confirmation you want, and a stall that survives it is a real defect to escalate.'$'\n\n''### 3. Merge or enqueue greens' \
    "$SKILL" "$M18"; then
    oo_ran=$((oo_ran + 1))
    m18_i=0
    m18_bad=0
    while IFS= read -r blk; do
        blk_sum="$(printf '%s' "$blk" | cksum | cut -d' ' -f1)"
        [ "$blk_sum" = "${CANON_2B[$m18_i]:-«unrecorded»}" ] || m18_bad=1
        m18_i=$((m18_i + 1))
    done < <(canon_blocks "$M18" "### 2b. Platform degradation probe")
    if [ "$m18_bad" -eq 1 ] || [ "$m18_i" -ne "${#CANON_2B[@]}" ]; then
        ok "M18 CAUGHT: canon rejects an §2b that every presence needle still passes"
    else
        bad "M18 UNDETECTED: a paragraph was ADDED to §2b and canon reported no drift"
    fi
fi

# M19 — wire the verdict into a dispatching skill using VERDICT VOCABULARY, which
# names no filename. The filename scan alone reports this as clean.
M19="$WORK/dispatch-ready-mutant.md"
if apply_mutation "M19 a dispatcher acts on the verdict without naming the script" \
    '## Guardrails' \
    '## Guardrails'$'\n\n''On `degraded (attributed)`, hold the PR and do not redispatch; on `healthy`, the stall is a real defect, so escalate it.' \
    "$REPO_ROOT/skills/dispatch-ready/SKILL.md" "$M19"; then
    oo_ran=$((oo_ran + 1))
    m19_hits="$(scan_sections "$M19" "$DR_ALLOW")"
    case "$m19_hits" in
        *"## Guardrails: degraded (attributed)"*)
            ok "M19 CAUGHT: a decision surface consulting the verdict by name is flagged by the section scan" ;;
        *) bad "M19 UNDETECTED: dispatch-ready was wired to the verdict and the section scan reported '$m19_hits'" ;;
    esac
fi

# M31 — the measured hole: a hold rule written into §4 Teardown of pr-shepherd's
# own SKILL.md, naming the script AND the vocabulary, in the section where
# merge-vs-hold is acted on. The file was in no corpus and §4 in no section
# list, so this was green.
M31="$WORK/skill-teardown-mutant.md"
if apply_mutation "M31 a hold rule is written into pr-shepherd's §4 Teardown" \
    '### 4. Teardown and reconcile' \
    '### 4. Teardown and reconcile'$'\n\n''Run `probe-platform-health.sh`; on a `degraded (attributed)` verdict, HOLD the PR and do not merge it.' \
    "$SKILL" "$M31"; then
    oo_ran=$((oo_ran + 1))
    m31_hits="$(scan_skill_sections "$M31")"
    case "$m31_hits" in
        *"### 4. Teardown and reconcile: names"*)
            ok "M31 CAUGHT: a hold rule in §4 is flagged — the section list is an equality over the headings" ;;
        *) bad "M31 UNDETECTED: §4 was wired to the probe and the section scan reported '$m31_hits'" ;;
    esac
fi

# M31b — the same hold rule in the BARE wording the vocabulary scan exists for:
# no script name, no parenthetical. Measured green against the two `degraded (…)`
# literals alone (review of #315).
M31B="$WORK/skill-teardown-bare-mutant.md"
if apply_mutation "M31b a hold rule in bare 'degraded verdict' wording under §4" \
    '### 4. Teardown and reconcile' \
    '### 4. Teardown and reconcile'$'\n\n''On a degraded verdict, HOLD the PR and do not merge it this tick.' \
    "$SKILL" "$M31B"; then
    oo_ran=$((oo_ran + 1))
    m31b_hits="$(scan_skill_sections "$M31B")"
    case "$m31b_hits" in
        *"### 4. Teardown and reconcile: degraded verdict"*)
            ok "M31b CAUGHT: the bare wording is flagged, so the rule cannot be written around the literals" ;;
        *) bad "M31b UNDETECTED: a bare 'degraded verdict' hold rule in §4 and the section scan reported '$m31b_hits'" ;;
    esac
fi

# M31c — the rule written as a HEADING over a bland body. Only bodies were
# scanned once, and this was green (review of #315).
M31C="$WORK/skill-teardown-heading-mutant.md"
if apply_mutation "M31c a hold rule written as a heading under §4" \
    '### 4. Teardown and reconcile' \
    '### 4. Teardown and reconcile'$'\n\n''#### On a `degraded (attributed)` verdict, hold the PR'$'\n\n''Wait for the next tick before doing anything else.' \
    "$SKILL" "$M31C"; then
    oo_ran=$((oo_ran + 1))
    m31c_hits="$(scan_skill_sections "$M31C")"
    case "$m31c_hits" in
        *"#### On a \`degraded (attributed)\` verdict, hold the PR: degraded (attributed)"*)
            ok "M31c CAUGHT: heading text is scanned, so a rule cannot hide in a heading over a bland body" ;;
        *) bad "M31c UNDETECTED: a hold rule as a heading and the section scan reported '$m31c_hits'" ;;
    esac
fi

# M32 — a gating bullet APPENDED to Guardrails, beside the canon-pinned one.
# Canon is on that one bullet so the rest of the list stays free to change, and
# "free to change" is exactly where a gating exception gets written; the scan
# strips the canon bullet and holds the remainder to the rule.
M32="$WORK/skill-guardrails-mutant.md"
if apply_mutation "M32 a gating bullet is appended to Guardrails" \
    '- **Never force-push the default branch.**' \
    '- **Never force-push the default branch.**'$'\n''- On a `degraded (attributed)` verdict, hold every PR this tick.' \
    "$SKILL" "$M32"; then
    oo_ran=$((oo_ran + 1))
    m32_hits="$(scan_skill_sections "$M32")"
    case "$m32_hits" in
        *"## Guardrails: degraded (attributed)"*)
            ok "M32 CAUGHT: a gating bullet beside the canon one is flagged, so the carve-out is one bullet, not the list" ;;
        *) bad "M32 UNDETECTED: Guardrails grew a gating bullet and the section scan reported '$m32_hits'" ;;
    esac
fi

# M33 — two BARE gh calls, in the two shapes the old source grep missed (an
# `if gh …; then` and a `gh … | jq` pipeline), inserted after the repo lookup.
# This is not a regression to refuse; it is the structural claim being
# MEASURED: because the name `gh` is a function, both run under the bound
# without their author knowing a wrapper exists. The shim's ledger must grow by
# exactly the two calls, and parity must hold. Before the shadow, the same
# insertion ran unbounded with the gate green.
M33="$WORK/bare-gh-mutant.sh"
if apply_mutation "M33 two bare gh calls in the if- and pipeline forms" \
    'REPO_OK=1' \
    'REPO_OK=1'$'\n''if gh api "repos/mock-org/mock-repo/commits/probe" >/dev/null 2>&1; then :; fi'$'\n''gh api "repos/mock-org/mock-repo/actions/runs?probe=1" 2>/dev/null | jq . >/dev/null 2>&1' \
    "$PROBE" "$M33"; then
    oo_ran=$((oo_ran + 1))
    run_probe "$M33" "$WORK/sc-bounded" --pr 301
    m33_bounds="$(grep -c . "$WORK/bounds")"
    m33_calls="$(grep -c '^gh ' "$WORK/calls")"
    if [ "$m33_bounds" -eq 5 ] && [ "$m33_calls" -eq 5 ] && [ "$VERDICT" = "healthy" ]; then
        ok "M33 BOUNDED: both bare calls ran under the bound with parity intact ($m33_calls calls, $m33_bounds bounds)"
    elif [ "$m33_bounds" -ne "$m33_calls" ]; then
        # Parity broken: a call reached the binary without the shim seeing it.
        bad "M33 ESCAPED: $m33_calls gh calls but $m33_bounds bounds — a bare gh call bypassed the shadow"
        sed 's/^/          | B /' <"$WORK/bounds" >&2
    else
        # Parity holds, so the shadow did its job; the count or the verdict is
        # what moved, which is a stale mutation or a changed baseline, not an
        # escape — and saying "bypassed" here would blame the wrong thing.
        bad "M33 MISCOUNTED: $m33_calls gh calls and $m33_bounds bounds (expected 5 and 5), verdict '$VERDICT' — parity holds, so the baseline call count or the mutation changed, not the shadow"
    fi
fi

# M34 — a first-party site MIS-SCOPED (`firstparty`). Two halves in one
# assertion, both of which must hold: the source census flags the typo, and the
# run FAILS CLOSED — the entry still counts, so the badrollup scenario is still
# `unknown` rather than the `healthy` the by-name filter gave (measured: green,
# with a failed read sitting in the ledger).
M34="$WORK/scope-typo-mutant.sh"
if apply_mutation "M34 a first-party call site is mis-scoped" \
    '      add_error first_party incomplete_payload "the empty-state read over the rollup failed (jq exited $empty_rc)"' \
    '      add_error "firstparty" incomplete_payload "the empty-state read over the rollup failed (jq exited $empty_rc)"' \
    "$PROBE" "$M34"; then
    oo_ran=$((oo_ran + 1))
    m34_scan="$(scope_violations "$M34")"
    run_probe "$M34" "$WORK/sc-badrollup" --pr 301
    if [ "$m34_scan" = "firstparty" ] && [ "$VERDICT" = "unknown" ]; then
        ok "M34 CAUGHT: the census flags 'firstparty', and the run still fails closed to unknown"
    else
        bad "M34 UNDETECTED: census reported '$m34_scan', verdict '$VERDICT' (want firstparty / unknown)"
    fi
fi

# --- vacuity floor ------------------------------------------------------------
# An EQUALITY, not a floor: every case above runs a fixed number of assertions on
# every path (each helper ends in exactly one ok/bad, and each mutant contributes
# exactly one whether it is applied or refused). A floor beneath the true count
# cannot tell "measured everything" from "one case silently stopped running".
# ONE transcription, used in the arithmetic and in the message.
EXPECTED_CASES=368
# Mutants that cannot ride the loop above, because each mutates ANOTHER file
# (M16-M19, M31, M32) or asserts something other than a wrong verdict over the
# shim's ledgers (M33) or the source census (M34). The number is checked
# against the ran-counter, so a deleted block is red on its own.
OUT_OF_LOOP_MUTANTS=10        # M16, M17, M18, M19, M31, M31b, M31c, M32, M33, M34
if [ "$oo_ran" -eq "$OUT_OF_LOOP_MUTANTS" ]; then
    ok "every out-of-loop mutant ran ($oo_ran of $OUT_OF_LOOP_MUTANTS)"
else
    bad "only $oo_ran of $OUT_OF_LOOP_MUTANTS out-of-loop mutants ran — a block was deleted or its mutation went stale"
fi
EXPECTED_ASSERTS=$(( ${#MUTANTS[@]} + OUT_OF_LOOP_MUTANTS + 2 + EXPECTED_CASES ))  # +2: the two all-ran checks
if [ "$asserts" -ne "$EXPECTED_ASSERTS" ]; then
    bad "$asserts assertions ran, expected $EXPECTED_ASSERTS (${#MUTANTS[@]} probe mutants + $OUT_OF_LOOP_MUTANTS out-of-loop + 2 + $EXPECTED_CASES cases) — a case was added or skipped; if deliberate, bump EXPECTED_CASES"
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "platform-health-probe tests: all pass ($asserts assertions, ${#MUTANTS[@]} probe mutants + $OUT_OF_LOOP_MUTANTS out-of-loop)" >&2
    exit 0
fi
echo "platform-health-probe tests: FAILURES above ($asserts assertions)" >&2
exit 1
