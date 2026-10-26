#!/usr/bin/env bash
# probe-platform-health.sh — "is the platform degraded right now, or is this a
# real defect?", answered as a structured verdict a caller REPORTS.
#
# WHY THIS EXISTS. A hard `gh` error is already handled everywhere — an
# API-failure tick proves nothing and the callers know it. What was not handled
# is a `gh` call that SUCCEEDS and returns incomplete data, which the caller
# then reads as live state. Measured 2026-08-26 on this repo's PR #283 during a
# platform outage: `gh pr view 283 --json statusCheckRollup` exited 0 with two
# entries and no `ci`; `gh run list` for that head returned no `CI` run at all
# across ~40 minutes while the two PRIOR heads on the same branch had one within
# minutes; `mergeStateStatus` read `BLOCKED`; later `ci` appeared in the rollup
# with an EMPTY state and still no run behind it. Nothing errored. The
# coordinator produced three hypotheses — Actions queueing, a path filter, a
# transient miss — all three wrong, and proposed closing and reopening the PR,
# which during an outage could have made it worse. The real cause was known only
# because the operator said so.
#
# THE ASYMMETRY IS THE WHOLE DESIGN, and it is the part a later "simplify the
# verdicts" sweep will flatten:
#
#     red explains a stall. GREEN EXPLAINS NOTHING, and says so in those words.
#
# A green status page is NOT evidence of health. githubstatus.com lags real
# degradation by minutes to tens of minutes and routinely under-reports partial
# Actions failures. So the probe may only ever ADD an explanation. If a caller
# reads green and concludes "so this is a real defect — escalate", the probe is
# WORSE than not having one: it converts an unknown into a confident wrong
# answer. The self-measured signal is what is load-bearing; the status page
# answers a different question — is it them or us — and answers it late.
#
# NEVER A GATE. This changes what a tick SAYS, not what it DOES. The verdict
# must appear in no merge, hold, block or redispatch decision. A PR missing a
# required check is held either way — the hold was already correct, the
# ATTRIBUTION was what was missing. Worth recording why the merge path is the
# least exposed surface: branch protection is enforced SERVER-SIDE, so a PR
# missing a required check is refused by GitHub itself and not by this loop's
# reading of it. The cost of degradation here is wasted work and wrong
# escalations, not bad merges.
#
# THE EXIT CODE CARRIES NO VERDICT, DELIBERATELY. Every one of the four verdicts
# exits 0; only a usage error exits non-zero. This is a deliberate ASYMMETRY
# with stack-probe.sh, whose exit codes ARE a gate (23/24 in merge-shepherd.sh)
# because that is its job — and aligning the two is exactly the tidy to refuse.
# A verdict in an exit code is one `set -e`, one `&&`, or one `if` away from
# being the gate this must never be, and that wiring would be invisible in
# review. Structure it out instead of forbidding it in prose.
#
# Usage:
#   probe-platform-health.sh [--pr <n>] [--repo owner/name]
#                            [--status-url <url>] [--min-age <secs>]
#   Repo defaults to the cwd checkout's `origin` remote, read LOCALLY with git
#   and never through `gh` — see the derivation's own paragraph; --repo overrides.
#   With no --pr there is NO first-party measurement, so a green page yields
#   `unknown` rather than `healthy` — see the table below.
#
# Env:
#   PLATFORM_STATUS_URL        attribution endpoint
#                              (default https://www.githubstatus.com/api/v2/summary.json)
#   PLATFORM_STATUS_TIMEOUT    seconds for that fetch (default 5)
#   PLATFORM_GH_TIMEOUT        seconds before any ONE `gh` call is sent TERM
#                              (default 20), applied with `timeout`/`gtimeout`
#                              when either is on PATH. The true per-call ceiling
#                              is this PLUS a fixed 5s kill grace — 25s at the
#                              default, and 80s worst case for the whole run;
#                              see THE WORST CASE below the env list.
#   PLATFORM_PROBE_MIN_AGE     head-age floor in seconds (default 300) — below it
#                              the run-COMPARISON signals are SUPPRESSED, because
#                              a workflow that has not started yet is not
#                              missing, and firing on a fresh push manufactures
#                              exactly the confident wrong answer this exists to
#                              prevent.
#   PLATFORM_STATUS_COMPONENTS comma-separated, lower-cased substrings of the
#                              status-page components that can plausibly explain
#                              missing CHECK data (default below). Scoping is not
#                              optional: githubstatus.com carries a dozen
#                              components, and treating a Copilot or Codespaces
#                              blip as an explanation for a red `ci` invents an
#                              excuse for a genuine failure — the same
#                              confident-wrong-answer this file exists to refuse,
#                              pointed the other way.
#
# THE WORST CASE IS 80 SECONDS, AND THAT NUMBER IS A CONSTRAINT RATHER THAN A
# STATISTIC (issue #314). Three bounded `gh` sites at 25s each plus the 5s
# `curl` is 3 x (20 + 5) + 5 = 80s, against the 120s default tool timeout of the
# harness the shipped callers run under. That harness kills a run past its
# timeout, and a killed run yields NO JSON AND NO STDERR — #303's shape one
# layer up, which the emitter fallback cannot answer because the script never
# reaches it. So the arithmetic has to fit with room, and the gate re-derives it
# from these defaults rather than trusting this sentence. Raising
# PLATFORM_GH_TIMEOUT past ~33 spends that room: the caller raising it owns the
# tool timeout too. The earlier default was 30, which put the no-`--repo` path at
# 145s — over the limit, in the header's own documented invocation.
#
# THE FOUR VERDICTS. They are four distinct answers and collapsing any pair
# re-creates the bug:
#
#   first-party      status page     verdict
#   -----------      -----------     -------
#   anomaly          incident        degraded (attributed)
#   anomaly          operational     degraded (unattributed)   <- never healthy
#   anomaly          unknown         degraded (unattributed)   <- never healthy
#   clean            incident        degraded (attributed)
#   clean            operational     healthy
#   clean            unknown         unknown                   <- never healthy
#   not measured     incident        degraded (attributed)
#   not measured     operational     unknown                   <- never healthy
#   not measured     unknown         unknown
#
# AN UNREACHABLE STATUS ENDPOINT NEVER MANUFACTURES A VERDICT OF ITS OWN. It
# contributes `unknown` and nothing else: it can never produce `healthy` (a
# verifier that degrades to "assume fine" is worth nothing on the day it
# matters — the verify-gotcha-claims.sh rule) and it can never on its own
# produce `degraded` (rows 6, 8 and 9 above). Where it appears beside a
# first-party anomaly (row 3) the DEGRADATION was measured first-party and only
# the attribution is missing, which is what the word "unattributed" means — the
# vocabulary has no fifth value for it, and a page you could not read adds
# exactly as much as a page that is green, which is nothing. Read row 3 and row
# 6 together before "aligning" either one.
#
# `clean` MEANS SOMETHING WAS MEASURED AND CAME BACK CLEAN — NEVER "NOTHING WAS
# LOOKED AT". This is the FIRST-PARTY door into `healthy`, and it is the one an
# earlier edition of this script left open: a single-commit PR branch has no
# prior head to compare against, so the run comparison had no baseline, found
# nothing, and reported `clean` -> `healthy` on a branch whose CI had never
# started. That is #285 one step EARLIER than the incident it was written for,
# and the dominant branch shape in this org. So each first-party check reports
# whether it could RUN. ONLY THE RUN COMPARISON EARNS `clean` -- the sentence
# that used to stand here said `clean` requires that "at least one of them did"
# and then listed BOTH checks, which is the exact inverse of the rule four lines
# below it, in the same paragraph. A reader who stopped at the list concluded
# the empty-state check could earn `clean`, which is the door the rule exists to
# nail shut. `ROLLUP_CHECK` is REPORTED in `checks_run` and contributes
# anomalies; it is consulted by no verdict path at all.
# The run comparison earns `clean` only with at least one prior head on the
# branch, a non-empty intersection across them (an empty one compared nothing),
# a head past the age floor, an untruncated runs page, and a rollup that is not
# empty while runs exist on this head. The empty-state check is a real signal
# but it detects a MALFORMED rollup entry and can never detect an ABSENT one —
# which is #285's headline signal — so a rollup that simply lacks `ci` looks
# identical to a healthy one through it. Accepting it as sufficient left this
# door open on the exact shape the probe was written for: measured, #285's own
# rollup on a single-commit branch reported `healthy`.
# Not earned -> `not_measured`, whose green-page row is `unknown`, and the
# REASON is preserved rather than blanked — `no_prior_heads`,
# `no_required_baseline`, `head_too_fresh`, `runs_page_truncated`,
# `rollup_empty_with_runs`, `head_age_unknown`, `run_comparison_failed`,
# `pr_read_failed`, `probe_errors_present`, `verdict_emitter_failed`,
# `repo_lookup_failed`, `no_pr_given` and `nothing_measurable` are precisely
# why the verdict is not a measurement. That list is the full set the code
# emits; if you add a reason, add it here.
#
# A gh TRANSPORT FAILURE IS `not_measured`, NOT AN ANOMALY, and this is a
# deliberate reading of #285 rather than a slip. #285 lists "gh calls erroring
# or returning structurally incomplete payloads" among the first-party signals,
# and a *semantically* incomplete payload — a rollup missing a check, an entry
# with no state — is exactly that and is treated as an anomaly below. But a call
# that FAILS, or comes back unparsable, or omits the key it was asked for,
# cannot distinguish a platform fault from an expired token, a rate limit or a
# closed laptop. Reporting a local auth failure as "the platform is degraded" is
# the confident wrong answer this file exists to refuse, so a transport failure
# records itself in `probe_errors`, makes the run `not_measured`, and lets the
# status page decide the row. The cost is stated: during a real outage that also
# breaks gh, a green page yields `unknown` rather than `degraded`. `unknown`
# explains nothing, which is the truth — we do not know.
#
# EVERY `gh` CALL IS BOUNDED, AND A TIMED-OUT CALL IS A TRANSPORT FAILURE. The
# probe's entire trigger condition is "GitHub may be degraded right now", and
# an edition of this file left the three LOAD-BEARING calls (`gh pr view`, the
# commit read, the `actions/runs` read) unbounded while bounding the OPTIONAL
# attribution fetch — the one its own header calls never load-bearing. A hang
# there costs the caller its whole tick, and the caller is a loop. So the NAME
# `gh` is the bound: a shell function shadows the binary and prefixes
# `timeout`/`gtimeout` when either is on PATH, and the only reach to the binary
# is one `command gh`, inside that function. A wrapper under its own name
# (`gh_bounded`) came first and is exactly the shape to refuse — a chokepoint
# by CONVENTION, where the next reader written as `gh api … | jq` is unbounded
# and looks entirely normal, and the gate's grep for it refused one spelling
# out of ten. Shadowing the name makes it structural: a call written by an
# author who never heard of a wrapper runs under the bound all the same. In the
# bounded branch `timeout` resolves `gh` through execvp, which sees no shell
# function, so the real binary and the gate's mock are reached the same way.
# `timeout` reports a fired bound as exit 124 — or as 137
# when the child ignored TERM and the 5s kill grace had to fire (128 + KILL,
# preserved after escalation; measured on coreutils 9.11). BOTH are the bound
# firing, and `bound_fired` is the ONE predicate that says so: an edition of
# this file recognised 124 alone, which meant the exact path `-k 5` exists for
# was the one path it could not name. Either code lands
# in the SAME `gh_call_failed` path as any other non-zero exit: `not_measured`,
# NEVER an anomaly. That is not a shortcut — it is the transport-failure rule
# above applied unchanged, and it is the reading to keep: a call we cut off
# ourselves tells us even less about the platform than one that errored.
# Where NEITHER binary is on PATH the calls run exactly as they did before and
# the probe records `timeout_unavailable` in `probe_errors`, because a bound
# that silently did not apply is the same "silence read as an answer" this file
# exists to refuse. That entry is scoped `probe`, not `first_party`: the calls
# still ran and their results are as trustworthy as they ever were, so folding
# it in would turn every run on a host without coreutils into `not_measured`.
#
# THE EMITTER CANNOT EXIT 0 WITH EMPTY STDOUT. The final `jq -n` used to run
# with no handler under a script with no `set -e` and an unconditional
# `exit 0`, so a dead emitter handed the caller exit 0 and NO output —
# `jq -r .verdict` then yields the empty string, which is not one of the four
# verdicts and is not `unknown` either, while the stderr summary line still
# printed and looked normal. Measured: `jq -n --argjson a "" '$a'` exits 2 and
# prints nothing, and `$ANOMALIES`/`$PROBE_ERRORS` are the only two emitter
# inputs nothing validates before use (the counts derived from them ARE
# defended, so the file already treats them as possibly unusable). The status
# is now captured and the output re-parsed before it is printed; on any failure
# a minimal HAND-BUILT `unknown` object is emitted instead.
# THAT OBJECT IS FOUR KEYS — `verdict`, `self_measured_reason`
# (`verdict_emitter_failed`), `explains` and `pr` — and deliberately NOT the
# emitter's shape. The first edition was a 16-key literal mirroring the
# emitter: a second copy of the output schema, held in step by nothing.
# Measured, renaming a key in it left the gate green, and the next key added
# to the emitter would have drifted out of it silently — #167's rule (never
# transcribe the table), inside this file. The rule that replaced it is not
# "carry nothing" but "carry nothing that could be what broke it", and exactly
# one measured value clears that bar: `pr` is validated at parse time as digits
# with no leading zero, so it is a bare JSON number BY CONSTRUCTION and cannot
# malform the literal, and it is the one fact a coordinator holding several PRs
# needs to attribute a dead run to any of them (#314). An edition of this
# paragraph refused it on the general principle and was right about every
# OTHER field: `repo` is shape-checked and never sanitised, a wider grammar
# than this literal can safely take, and the rest are precisely what could not
# be serialised — re-interpolating one re-runs the failure inside its own
# handler, since whatever killed the emitter (a ledger builder dying on the
# argv cap, or jq itself) is what a richer object would have to re-run.
# THE TWO LEDGERS STAY `--argjson`, ON PURPOSE. `--arg` plus `try fromjson
# catch []` would make the emitter unable to fail on inputs at all — and
# measured, an empty `$ANOMALIES` already reads as ZERO anomalies at the
# verdict (`length` over empty input is empty, and the guard turns that into
# 0), so that edition emits `healthy` beside an empty anomalies list after a
# jq failure inside `add_anomaly`. A ledger that cannot be parsed is a run
# whose verdict cannot be trusted; the emitter dying is the fail-closed door
# that lands it in `unknown`, and the gate mutation-proves the door by
# corrupting the ledger.
# It still exits 0: the no-verdict case is what a non-zero exit is reserved for,
# and this path HAS a verdict. Turning it into a non-zero exit would put a
# verdict in an exit code, which the paragraph above forbids.
#
# FIRST-PARTY SIGNALS (the load-bearing half; all are read-only):
#   missing_workflow_run  a (workflow, event) pair that ran on EVERY prior head
#                         of this branch has no run on the current head
#   no_run_for_head       prior heads carried runs; this head carries none
#   empty_state_check     a rollup entry with no status, no conclusion and no
#                         state — a CheckRun always has a status and a
#                         StatusContext always has a state, so all-three-empty
#                         is a placeholder, not a check that is running. It is
#                         a DIRECT read of the rollup, so it is neither
#                         age-suppressed nor conditional on the runs call —
#                         during an outage those are exactly what fail together.
#
# THE RUN COMPARISON IS RUN-TO-RUN, NOT ROLLUP-TO-RUN, AND THAT IS DELIBERATE.
# `statusCheckRollup` names CHECKS (for Actions, JOB names — "Analyze
# (actions)"), while `actions/runs` names WORKFLOWS ("CI"). They are different
# namespaces, so differencing one against the other reports a missing check for
# every workflow whose job names differ from its own name, on a perfectly
# healthy repo. Both sides of the difference therefore come from the SAME
# `actions/runs` payload, which is also exactly the comparison that was measured
# during the outage. The rollup is used only for the empty-state signal, which
# needs no cross-namespace comparison at all.
#
# THE BASELINE IS AN INTERSECTION, NOT A UNION, and the whitelist beside it is
# the other half of the same guard. A workflow legitimately absent from one head
# is ordinary: `paths:`/`paths-ignore:` filters (the norm in the monorepos this
# ships to), an `if:` condition. So
# a workflow counts as missing only if it ran on EVERY prior head examined and
# on none of the current one. And only head-triggered events are compared at
# all — a `workflow_dispatch` or `schedule` run on a prior head can never recur
# on this one, so a union-and-blacklist reading reports it missing forever.
# KNOWN LIMIT, stated rather than patched, and it has TWO shapes rather than
# one. (a) A path filter that matched every prior head and not this one still
# reports a missing run. (b) A workflow THIS VERY PR renames or deletes does
# too, and that shape was wrongly listed above as covered — the intersection
# guard makes a workflow ordinary when it is absent from SOME PRIOR head, and a
# deletion is absent from the CURRENT one, which is the opposite arrangement.
# Measured: prior heads running CI+Docs and a current head running CI only
# returns `degraded (unattributed)` naming `Docs`, i.e. the probe attributes the
# PR-s own change to the platform. Listing it as handled was worse than not
# mentioning it, because the next maintainer would not add it here. That is why this
# verdict is `unattributed` and why the probe gates nothing — a false positive
# costs an explanation, never a decision.
#
# PAGINATION IS A KNOWN LIMIT AND IT CUTS BOTH WAYS. One page of 100 runs,
# newest first, and BOTH directions are measured — an edition of this comment
# claimed each of them was the only one, so neither half may be deleted.
#   OVER-detect: dropping a whole prior head takes `required` from ["CI"] to
#     ["CI","Docs"] on a branch where a path filter had skipped that head, and
#     fabricates a missing-run anomaly.
#   UNDER-detect, and this WAS the direction that reached `healthy`: the page
#     boundary lands INSIDE the oldest included head's run set, so that head
#     contributes a TRUNCATED set, the intersection shrinks, and a genuinely
#     missing workflow drops out of `required`. Measured on two fixtures
#     differing ONLY in truncation, same underlying reality: the full page gave
#     `degraded (unattributed)` and the 100-run page gave `healthy`.
# That is now CLOSED. `truncated` was computed, reported, and then ignored by
# the one decision that consumes it, which is why recording it as a known limit
# was not enough. A truncated page no longer earns `clean`: it yields
# `not_measured` with reason `runs_page_truncated`. The test is `!= "no"` and
# not `= "yes"`, because `unknown` means the flag itself could not be read and
# certifies nothing either.
# `truncated` is still emitted, since suppressing the claim to completeness is
# not the same as hiding why. The ACCEPTED COST is real and is not a defect:
# on a branch with >= 100 head-triggered runs the probe can no longer emit
# `healthy` at all, only `unknown`. Over-detection is unchanged and still
# possible. Note also that `>= 100` against `per_page=100` cannot distinguish a
# complete 100-run page from a truncated one, so a branch sitting at exactly
# 100 is treated as truncated -- fail-closed, and deliberate.
#
# Read-only. Never merges, enqueues, re-runs, closes, reopens or comments.
#
# Emits one JSON object on stdout and a one-line human summary on stderr.
# Exit codes: 0 for EVERY verdict (see above) · 1 usage error.
set -uo pipefail

STATUS_URL="${PLATFORM_STATUS_URL:-https://www.githubstatus.com/api/v2/summary.json}"
STATUS_TIMEOUT="${PLATFORM_STATUS_TIMEOUT:-5}"
GH_TIMEOUT="${PLATFORM_GH_TIMEOUT:-20}"
MIN_AGE="${PLATFORM_PROBE_MIN_AGE:-300}"
STATUS_COMPONENTS="${PLATFORM_STATUS_COMPONENTS:-actions,api requests,webhooks,pull requests,git operations}"
REPO=""
PR=""

need_value() { # <flag> <remaining argc>
  # `shift 2` on a lone trailing flag shifts NOTHING (shift fails when it would
  # go past the end), so the while loop spins forever on `--status-url` with no
  # value. The caller here is an agent composing a command line inside a loop
  # tick, which makes a truncated flag realistic and a hang the worst possible
  # outcome for a diagnostic.
  if [ "$2" -lt 2 ]; then echo "error: $1 requires a value" >&2; exit 1; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)        need_value "$1" $#
                   [ -n "$2" ] || { echo "error: --repo requires owner/name" >&2; exit 1; }
                   REPO="$2"; shift 2 ;;
    --pr)          need_value "$1" $#
                   [ -n "$2" ] || { echo "error: --pr requires a PR number" >&2; exit 1; }
                   PR="$2"; shift 2 ;;
    --status-url)  need_value "$1" $#; STATUS_URL="$2"; shift 2 ;;
    --min-age)     need_value "$1" $#; MIN_AGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
    *) echo "unexpected arg: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

if [ -n "$PR" ]; then
  # `0*` for the SAME reason PLATFORM_GH_TIMEOUT rejects it, arriving by a
  # different route: this value is interpolated into JSON as a bare number, both
  # by the emitter's `--argjson pr` and by the hand-built fallback literal, and
  # `007` is not JSON. Digits-only alone therefore left a `--pr` shape that
  # killed the emitter on its way in — the #303 door, reached through an
  # argument rather than through a ledger. There is no PR 0 either.
  case "$PR" in *[!0-9]*|""|0*) echo "error: --pr must be a positive whole number with no leading zero, got: $PR" >&2; exit 1 ;; esac
fi
case "$MIN_AGE" in *[!0-9]*|"") echo "error: --min-age must be numeric seconds, got: $MIN_AGE" >&2; exit 1 ;; esac
case "$STATUS_TIMEOUT" in
  *[!0-9]*|""|0) echo "error: PLATFORM_STATUS_TIMEOUT must be a positive number of seconds, got: $STATUS_TIMEOUT" >&2; exit 1 ;;
esac
# Validated like every other knob, and for a sharper reason than tidiness: this
# value is the FIRST argument to `timeout`, so an unvalidated one is an argument
# injection into a command prefix. `0` is rejected rather than read as "no
# bound" — a bound that silently means unbounded is the shape this whole file
# refuses; drop `timeout` from PATH to get the unbounded behaviour, and the
# probe will say so in `probe_errors`.
#
# `0*` AND NOT `0`, because rejecting the single character was not the same
# rule. `00` is all digits, is not the empty string and is not the literal `0`,
# so it passed — and `timeout 00 …` is `timeout 0 …`, which means NO BOUND.
# Measured: `gtimeout 00 sleep 2` returns 0 after the full two seconds. That is
# strictly worse than an unbounded run, because no `timeout_unavailable` is
# recorded either, so the ledger affirmatively implies a bound that was never
# applied — the exact shape the paragraph above says this file refuses, reached
# through the validation written to enforce it. Leading zeros are therefore
# rejected outright rather than stripped: a caller who wrote `00` meant
# something, and guessing which thing is how this class of bug survives.
#
# STATUS_TIMEOUT above has the same hole and is deliberately NOT changed here —
# it is pre-existing, out of this issue's scope, and reaches `curl --max-time`
# rather than a command prefix. Do not "align" the two by loosening THIS one.
case "$GH_TIMEOUT" in
  ""|*[!0-9]*|0*) echo "error: PLATFORM_GH_TIMEOUT must be a positive whole number of seconds with no leading zero, got: $GH_TIMEOUT" >&2; exit 1 ;;
esac
# The status URL reaches curl, so it is validated like any other argument. A
# value starting `-K` is read by curl as `--config` and can set `output`,
# `upload-file`, `header` or `proxy`; `file://` and `http://` are enabled by
# default and would put attacker-chosen text into a field the caller is told to
# report, in a repo that is PUBLIC by exception.
case "$STATUS_URL" in
  https://?*) : ;;
  *) echo "error: the status URL must be https://, got: $STATUS_URL" >&2; exit 1 ;;
esac

# Resolved before any `gh` call, since a hang in the first one is a hang.
# `timeout` first, `gtimeout` second: on macOS the GNU binary installs under the
# `g` prefix, and a probe that is bounded on CI and unbounded on every developer
# laptop is the worse half of both worlds.
GH_TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then GH_TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then GH_TIMEOUT_CMD="gtimeout"
fi
gh() { # <gh args...> — shadows the binary, so EVERY `gh` in this file is bounded
  # The name is the chokepoint. `command gh` below is the one reach to the
  # binary, and the gate asserts it occurs exactly once, here; in the bounded
  # branch the `gh` handed to `timeout` is resolved by execvp, which knows
  # nothing of shell functions, so it is the binary too and not a recursion.
  # PURE, deliberately: every call site runs this inside `$( )`, so an
  # `add_error` here would mutate PROBE_ERRORS in a SUBSHELL and the entry
  # would be silently discarded. The ledger is written by the callers.
  # `-k 5` is not belt-and-braces. Without it `timeout` sends SIGTERM and then
  # WAITS for the child, so a `gh` that ignores TERM makes the bound bound
  # nothing at all — the precise failure this wrapper exists to prevent,
  # surviving inside its own fix. `gh` is Go and honours TERM today, which
  # makes this cheap insurance rather than a live bug, and the 5s grace is
  # deliberately fixed: it is a kill delay, not a second knob for a caller to
  # get wrong.
  if [ -n "$GH_TIMEOUT_CMD" ]; then
    "$GH_TIMEOUT_CMD" -k 5 "$GH_TIMEOUT" gh "$@"
  else
    command gh "$@"
  fi
}
bound_fired() { # <rc> — did OUR bound end this call?
  # THE ONE PREDICATE, consulted by every site that cares. 124 is `timeout`'s
  # "TERM sufficed" code; 137 is "TERM was ignored and the kill grace fired"
  # (128 + KILL, which `timeout` preserves after it escalates). An edition of
  # this file tested for the single code 124 at two sites independently and so recognised
  # the bound firing everywhere EXCEPT on the path `-k 5` was added for — a
  # TERM-ignoring `gh` produced a bare `exited 137` at the three first-party
  # sites, and at the repo lookup that was then a `gh` call it fell through to
  # the false `not in a GitHub repo`. Neither code is ours when no bound was
  # applied, so both are gated on it.
  [ -n "$GH_TIMEOUT_CMD" ] || return 1
  case "$1" in 124|137) return 0 ;; *) return 1 ;; esac
}
gh_rc_note() { # <rc> — names the bound when IT is what fired, and nothing otherwise
  # Naming it matters because `gh` has no such exit code of its own, so an
  # unannotated "exited 124" or "exited 137" in the ledger reads as an
  # unexplained gh failure rather than as our own cutoff.
  bound_fired "$1" || return 0
  if [ "$1" -eq 137 ]; then
    printf ' — the %ss PLATFORM_GH_TIMEOUT bound fired, gh ignored TERM, and the 5s kill grace fired too' "$GH_TIMEOUT"
  else
    printf ' — the %ss PLATFORM_GH_TIMEOUT bound fired' "$GH_TIMEOUT"
  fi
  return 0
}

ANOMALIES='[]'
PROBE_ERRORS='[]'
add_anomaly() { # <kind> <detail>
  ANOMALIES="$(jq -c --arg k "$1" --arg d "$2" '. + [{kind:$k, detail:$d}]' <<<"$ANOMALIES")"
}
add_error() { # <scope: first_party|attribution|probe> <kind> <detail>
  # SCOPE matters: only a FIRST-PARTY failure can make the run unmeasured. A
  # failed status fetch is an attribution failure, and folding it in would turn
  # every unreachable-endpoint run into `not_measured`, erasing the difference
  # between "I read your PR and it was clean" and "I read nothing".
  # `probe` is the third value and is neither. Its ONE invariant is that it
  # never feeds the first-party count below — that is the whole definition.
  # Its one kind today is `timeout_unavailable`: the measurement is intact and
  # the verdict is whatever it would have been; the entry only records that
  # the bound never applied. An earlier edition defined the scope as "where
  # the measurement itself is unaffected" and then listed the emitter fallback
  # as a second example, which was its own counter-example (the fallback
  # DISCARDS the measurement). That entry lived only inside the hand-built
  # fallback object, which never passed through this count at all, and the
  # fallback no longer carries a ledger — see the emitter. Do not restate the
  # definition in terms of the verdict.
  # THE SET IS CLOSED — first_party, attribution, probe — and the count below
  # is taken by EXCLUSION rather than by naming `first_party`. Counting by name
  # made the scope an open enum whose only reader failed OPEN: a fourth value,
  # or a misspelling at a first-party site, dropped out of the count silently
  # and the run reached `clean` -> `healthy` with a failed call sitting in the
  # ledger — the decorative-ledger defect one more time. Unrecognised now
  # COUNTS, so it fails closed to `not_measured`, and the gate scans every
  # call site in this file against the set so a misspelling is a red build
  # rather than a quietly-counted oddity.
  PROBE_ERRORS="$(jq -c --arg s "$1" --arg k "$2" --arg d "$3" \
    '. + [{scope:$s, kind:$k, detail:$d}]' <<<"$PROBE_ERRORS")"
}
fp_details() { # — the first-party details, joined, prefixed `; `; nothing when there are none
  # BY EXCLUSION, exactly like `n_fp_errors` below, and for the same reason: an
  # unrecognised scope is first-party here too, so a misspelling at a
  # first-party site cannot make its detail vanish from the one field a caller
  # is told to read. Every detail on that ledger is already either a literal or
  # a sanitised value, which is what makes this safe to append to a reported
  # string.
  local d
  d="$(jq -r '[.[] | select(.scope != "attribution" and .scope != "probe") | .detail] | join("; ")' \
      <<<"$PROBE_ERRORS" 2>/dev/null)"
  [ -n "$d" ] || return 0
  printf '; %s' "$d"
}
[ -n "$GH_TIMEOUT_CMD" ] || add_error probe timeout_unavailable \
  "neither timeout nor gtimeout is on PATH, so every gh call ran unbounded; PLATFORM_GH_TIMEOUT=$GH_TIMEOUT was not applied"
# AND ONCE ON STDERR, because the JSON ledger is not a channel a human reads
# (issue #314). macOS ships no `timeout`, so an operator running this by hand on
# a laptop without coreutils sees `platform: healthy` every time and learns the
# bound never applied on the day a `gh` call hangs their session — the one day
# there is no output to learn it from. Two guarded lines rather than one `if`
# block: the JSON entry keeps the exact shape the gate pins at source level.
[ -n "$GH_TIMEOUT_CMD" ] || \
  echo "warning: neither timeout nor gtimeout on PATH — gh calls run unbounded; install coreutils" >&2

# THE REPO IS DERIVED LOCALLY, AND THIS IS THE ONE PLACE THIS PROBE DEPARTS FROM
# ITS SIBLINGS (issue #314). `gh repo view --json nameWithOwner` answers a LOCAL
# question — which repo is this checkout — through a REMOTE call, and on a
# network failure, an expired token or a 5xx it exits 1 with empty stdout,
# INDISTINGUISHABLE from "not in a repo at all". That is this file's dominant bug
# class again: an unknown converted into a confident wrong answer, at the one
# site whose trigger condition is "GitHub may be failing right now". Bounding the
# call (#312) taught it 124 and 137 and nothing else, so every OTHER non-zero
# exit inside a valid checkout still printed `not in a GitHub repo and --repo not
# given` and exited 1 with no verdict. A probe that exists to run during an
# outage must not need GitHub to work out where it is standing.
#
# So the slug comes from the `origin` remote. `git rev-parse` and
# `git remote get-url` read the local checkout and touch no network, which is why
# neither needs the bound the `gh` sites carry — the bounded sites drop from four
# to three, the worst-case runtime with them, and the exit-code special case
# disappears entirely. The OTHER plugin scripts keep `gh repo view`: this one is
# the deliberate exception, not a new convention, and the exception is earned by
# what the probe is for rather than by tidiness.
#
# THE REMOTE URL IS NEVER REPORTED, and that is a security decision rather than
# terseness. An https remote can carry credentials in its userinfo
# (`https://x-access-token:ghs_...@github.com/o/n`), `probe_errors[].detail` is a
# field SKILL.md orders the coordinator to REPORT, and this repo is PUBLIC by
# exception. So a detail names WHICH input broke and never its value — the same
# shape the emitter fallback's stderr line uses, and the reason no sanitiser is
# needed at this site at all.
#
# THE FAILURE SHAPES ARE ENUMERATED RATHER THAN COUNTED, which is AGENTS.md's
# own rule about a number in prose: (a) no `git` on PATH, (b) `git rev-parse`
# exiting non-zero — no repository here, OR one git refused to read, which that
# command does not separate except in locale-dependent stderr — (c) a bare
# repository, which has no work tree, (d) no `origin` remote, and (e) an
# `origin` URL this parser does not accept. Each records its OWN detail
# under one `first_party repo_lookup_failed`, sets REPO_OK=0, and the run CARRIES
# ON to a real verdict — `not_measured`, which the status page can still
# attribute. NO USAGE ERROR AMONG THEM: a caller standing outside a checkout now
# gets `unknown` with a reason instead of exit 1 and no verdict at all, and exit
# 1 stays what it always was, a malformed argument, where no verdict exists.
repo_from_remote() { # <remote url> — owner/name, or nothing
  # DELIBERATELY STRICT, over exactly the three forms git writes for a github.com
  # remote. A permissive parser's failure mode is a WRONG slug, which the probe
  # would then measure a different repo through and report as this one; a strict
  # parser's failure mode is `--repo`, which every shipped caller already passes.
  # A host that is not exactly `github.com` is refused for the same reason: `gh`
  # would query github.com regardless of what the remote said.
  #
  # `origin` AND ONLY `origin`, which is deliberately NARROWER than the `gh`
  # call this replaced: `gh` resolves `upstream` ahead of `origin`, so on a fork
  # checkout configured that way the two answer different repos. Narrower is the
  # safe direction here — the probe measures the repo whose PRs the caller is
  # watching, `--repo` is how a caller says otherwise, and every shipped caller
  # passes it — but it is a difference rather than an oversight, so it is
  # recorded beside the forms refused by design.
  local u="$1" p="" auth="" rest=""
  case "$u" in
    https://*|ssh://*)
      p="${u#*://}"
      # USERINFO IS STRIPPED FROM THE AUTHORITY ALONE. `${p#*@}` over the whole
      # string strips to the first `@` ANYWHERE, so
      # `https://evil.example/path@github.com/o/n` derived `o/n` — a remote
      # pointing at another host resolving to a repo on this one, which is the
      # WRONG-slug failure this parser's strictness exists to refuse.
      auth="${p%%/*}"
      rest="${p#"$auth"}"
      p="${auth##*@}$rest"
      ;;
    git@github.com:*) p="github.com/${u#git@github.com:}" ;;
    *) return 0 ;;
  esac
  case "$p" in github.com/*) p="${p#github.com/}" ;; *) return 0 ;; esac
  # TRAILING SLASH FIRST, THEN `.git`: the other order leaves `o/n.git` for
  # `https://github.com/o/n.git/`, and that string is NOT refused — `.` is in the
  # allowed set and `o/n.git` is two clean segments — so the probe reports a slug
  # with `.git` glued on and every `gh` call under it 404s against a repo that
  # does not exist. Measured, not predicted: reverting this order runs the
  # trailing-slash fixture to `.repo = mock-org/mock-repo.git`.
  p="${p%/}"
  p="${p%.git}"
  # EXACTLY two non-empty segments, from a character set that cannot inject. The
  # value is interpolated into `gh` arguments and into reported details, so this
  # shape check IS the sanitiser at this site — which is what lets the derived
  # slug skip the class every other reported string is cleaned against.
  case "$p" in ""|/*|*/) return 0 ;; */*/*) return 0 ;; */*) : ;; *) return 0 ;; esac
  case "$p" in *[!A-Za-z0-9._/-]*) return 0 ;; esac
  printf '%s' "$p"
}
REPO_OK=1
if [ -z "$REPO" ]; then
  repo_why=""
  if ! command -v git >/dev/null 2>&1; then
    # Its own shape, because falling through to the work-tree branch would report
    # "not inside a git work tree" on a host that simply has no git — the second
    # false cause in a row, which is what this whole block was rewritten to stop.
    repo_why="git is not installed, so the repo could not be derived from the checkout"
  else
    # THE STATUS AND THE OUTPUT ARE DIFFERENT QUESTIONS, and reading only the
    # second answered the wrong one: `git rev-parse` ERRORING — a
    # `safe.directory` refusal, a `.git` file pointing at a directory that is
    # gone, an unreadable object store — prints nothing, which looked exactly
    # like `false` and was reported as "not inside a git work tree" from inside
    # a checkout that plainly is one. That is this block's own dominant bug
    # class, the second false cause in a row.
    #
    # AND THE FIX IS NOT TO SWAP ONE CERTAINTY FOR ANOTHER. Exit 128 is BOTH
    # "there is no repository here" and "there is one and git refused to read
    # it"; `git rev-parse` distinguishes them only in its English stderr, which
    # is locale-dependent, so this detail names BOTH and carries the code. An
    # unknown stated as a certainty is exactly what reading the output alone was
    # already doing, pointed the other way.
    tree_rc=0
    in_tree="$(git rev-parse --is-inside-work-tree 2>/dev/null)" || tree_rc=$?
    if [ "$tree_rc" -ne 0 ]; then
      repo_why="not inside a readable git work tree — git rev-parse exited $tree_rc (no repository here, or git refused to read this one)"
    elif [ "$in_tree" != "true" ]; then
      # Exit 0 with `false` IS distinguishable, and it is the bare-repo case:
      # there is no work tree, so there is no worktree remote to read either.
      repo_why="the working directory is inside a bare git repository, which has no work tree"
    else
      origin_url="$(git remote get-url origin 2>/dev/null)" || origin_url=""
      if [ -z "$origin_url" ]; then
        repo_why="the checkout has no 'origin' remote"
      else
        REPO="$(repo_from_remote "$origin_url")"
        [ -n "$REPO" ] || repo_why="the 'origin' remote is not a github.com owner/name URL this probe parses"
      fi
    fi
  fi
  if [ -n "$repo_why" ]; then
    add_error first_party repo_lookup_failed "$repo_why; pass --repo owner/name"
    REPO=""
    REPO_OK=0
  fi
fi
# Guards the `--repo` VALUE alone now: a derived slug already satisfies this by
# construction, and a failed derivation has nothing to shape-check — the
# owner/name message there would be the second false cause in a row.
if [ "$REPO_OK" -eq 1 ]; then
  case "$REPO" in */*) : ;; *) echo "error: repo must be owner/name, got: $REPO" >&2; exit 1 ;; esac
fi

SELF="not_measured"
SELF_REASON="no_pr_given"
# Set BEFORE the first-party block, which is skipped without a repo: the reason
# a caller sees must name the lookup, not the PR it never got to read.
[ "$REPO_OK" -eq 1 ] || SELF_REASON="repo_lookup_failed"
HEAD=""
# ONE definition of what may not reach a reported field, injected into every jq
# program that sanitises one. Written as CODEPOINTS rather than a regex class,
# and that is forced rather than stylistic: the Unicode TAG BLOCK
# (U+E0000-U+E007F) is the standard invisible ASCII-mirroring carrier for
# prompt injection, it lives OUTSIDE the BMP, and jq's `\uXXXX` escape cannot
# express a non-BMP codepoint at all -- so the regex class this replaces was
# structurally incapable of covering the one carrier that matters most here,
# no matter how carefully it was transcribed.
#
# A fork-PR author controls branch and job names; those reach `anomalies[].detail`
# and `head_ref`; SKILL.md tells the coordinator -- which holds merge authority --
# to REPORT that field; and this repo is PUBLIC by exception. Bidi alone was the
# wrong threat model.
#
# Covered: C0 (<32), DEL, U+0085 NEL, U+061C ALM, U+200E/U+200F, U+2028/U+2029
# line+paragraph separators, U+202A-U+202E bidi embedding/override,
# U+2066-U+2069 bidi isolates, U+E0000-U+E007F tag block.
# Each is REPLACED by a space, never deleted, so a sanitised value can never
# become empty and re-enter the empty-name path this file already closed once.
UNSAFE_JQ_DEF='def unsafe_cp: . < 32 or . == 127 or . == 133 or . == 1564
    or (. >= 8206 and . <= 8207) or (. >= 8232 and . <= 8233)
    or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297)
    or (. >= 917504 and . <= 917631);
  def clean: explode | map(if unsafe_cp then 32 else . end) | implode;'

BRANCH=""
BRANCH_SAFE=""
HEAD_AGE=""
MERGE_STATE=""
pr_raw=""
# Did each first-party check actually get to run? `clean` requires at least one.
RUN_CHECK="not_run"
ROLLUP_CHECK="not_run"
RUNS_TRUNCATED="unknown"

# --- first-party measurement -------------------------------------------------
if [ -n "$PR" ] && [ "$REPO_OK" -eq 1 ]; then
  SELF_REASON=""
  rc=0
  pr_raw="$(gh pr view "$PR" --repo "$REPO" \
      --json number,headRefOid,headRefName,statusCheckRollup,mergeStateStatus 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    add_error first_party gh_call_failed "gh pr view $PR exited $rc$(gh_rc_note "$rc")"
    SELF_REASON="pr_read_failed"
  elif [ -z "$pr_raw" ] || ! jq -e . >/dev/null 2>&1 <<<"$pr_raw"; then
    add_error first_party incomplete_payload "gh pr view $PR exited 0 with no parsable JSON"
    SELF_REASON="pr_read_failed"
  else
    HEAD="$(jq -r '(.headRefOid // "") | gsub("[^0-9a-fA-F]"; "")' <<<"$pr_raw")"
    # BRANCH is used for TWO different things and needs both forms. The raw value
    # goes into the API query (URL-encoded at the call site); BRANCH_SAFE is what
    # reaches any reported string, because a fork-PR author controls it and a
    # bidi override or a newline in a reported field is the same injection the
    # check-name sanitiser exists to stop.
    #
    # THAT SENTENCE IS ONLY TRUE BECAUSE THE CLASSES WERE UNIFIED. It used to
    # assert a parity that did not exist: this site stripped control characters
    # AND bidi, while the check-name, missing-run and status-detail sanitisers
    # stripped control characters only, so a job name carrying RLO/LRM passed
    # through all three unchanged. Fork-PR authors control job names, those land
    # in `anomalies[].detail`, SKILL.md orders the coordinator to REPORT that
    # field, and this repo is PUBLIC. One class now covers every string that
    # reaches a reported field; a site that drops back to the control-only form
    # re-opens exactly that hole, so the gate compares the sites to each other.
    BRANCH="$(jq -r '.headRefName // ""' <<<"$pr_raw")"
    BRANCH_SAFE="$(jq -r "$UNSAFE_JQ_DEF"' (.headRefName // "") | clean' <<<"$pr_raw")"
    MERGE_STATE="$(jq -r '(.mergeStateStatus // "") | gsub("[^A-Z_]"; "")' <<<"$pr_raw")"
    if ! jq -e 'has("statusCheckRollup") and has("mergeStateStatus")' >/dev/null 2>&1 <<<"$pr_raw"; then
      HEAD=""
      add_error first_party incomplete_payload "gh pr view $PR omitted statusCheckRollup or mergeStateStatus, which the call requested"
      SELF_REASON="pr_read_failed"
    elif [ -z "$HEAD" ] || [ -z "$BRANCH" ]; then
      HEAD=""
      add_error first_party incomplete_payload "gh pr view $PR returned JSON without headRefOid/headRefName"
      SELF_REASON="pr_read_failed"
    fi
  fi
fi

# --- empty-state signal: a DIRECT rollup read ---------------------------------
# Deliberately outside both the age floor and the actions/runs call. It is not
# an inference, and an outage degrades those two together — gating this on
# either is what dropped the #285 fingerprint exactly when it mattered.
if [ -n "$pr_raw" ]; then
  rollup_n="$(jq -r '(.statusCheckRollup // []) | length' <<<"$pr_raw" 2>/dev/null || echo 0)"
  if [ "${rollup_n:-0}" -gt 0 ]; then
    empty_rc=0
    # A bash variable CANNOT hold a NUL byte, so capturing NUL-delimited
    # output into one silently loses every delimiter and the read loop runs
    # ZERO times — the very 'generator produced nothing' failure the capture
    # was added to detect, reintroduced by the fix for it. Newline delimiting
    # is safe here BECAUSE the sanitiser below strips control characters
    # first, so no emitted name can contain a newline; the capture is what
    # lets the exit status be checked at all.
    empty_out="$(jq -r "$UNSAFE_JQ_DEF"'
      # `//` falls back only on null/false, so `.name // .context` KEEPS an
      # empty-string name and the entry then vanishes at the `[ -n "$ck" ]`
      # guard below — found, emitted, silently discarded, verdict `healthy`.
      # That is the headline signal of this probe producing the confident
      # wrong answer its header calls worse than having no probe at all, so
      # absence is tested by LENGTH and never by `//`.
      def firstnonempty($a; $b): if (($a | length) > 0) then $a
                                 elif (($b | length) > 0) then $b
                                 else "(unnamed)" end;
      [ .statusCheckRollup[]?
        | select( ((.status // "") == "")
                  and ((.conclusion // "") == "")
                  and ((.state // "") == "") )
        | (firstnonempty(((.name // "") | tostring); ((.context // "") | tostring)) | clean)
      ] | unique | .[]
    ' <<<"$pr_raw")" || empty_rc=$?
    if [ "$empty_rc" -ne 0 ]; then
      # A generator that died is not "no anomalies found" — it is no read at all.
      add_error first_party incomplete_payload "the empty-state read over the rollup failed (jq exited $empty_rc)"
    else
      ROLLUP_CHECK="ran"
      while IFS= read -r ck; do
        # The generator now guarantees a non-empty token per matching entry
        # (`clean` only SUBSTITUTES characters, never deletes, and the
        # fallback is a literal), so this guard can only skip the single
        # empty line a here-string yields for empty input. It must never
        # again be the thing that decides whether an anomaly is reported.
        [ -n "$ck" ] && add_anomaly empty_state_check "$ck is in the rollup with no status, conclusion or state"
      done <<<"$empty_out"
    fi
  fi
fi

# --- run comparison -----------------------------------------------------------
if [ -n "$HEAD" ]; then
  # Head age, computed in jq (fromdateiso8601/now) rather than with `date`,
  # which takes incompatible flags on BSD and GNU.
  rc=0
  commit_raw="$(gh api "repos/$REPO/commits/$HEAD" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    add_error first_party gh_call_failed "gh api repos/$REPO/commits/$HEAD exited $rc$(gh_rc_note "$rc")"
  else
    HEAD_AGE="$(jq -r '
      (.commit.committer.date // .commit.author.date // "") as $d
      | if $d == "" then "" else
          ((($d | fromdateiso8601) | (now - .) | floor) as $age
           # A NEGATIVE age is an invalid measurement, not a fresh head.
           # `GIT_COMMITTER_DATE` is author-settable and GitHub preserves it, so a
           # future-dated commit is `-lt MIN_AGE` forever and would permanently
           # suppress the load-bearing signal under a reason (`head_too_fresh`)
           # that is false on its face. Empty routes it to `head_age_unknown`.
           | if $age < 0 then "" else ($age | tostring) end)
        end
    ' <<<"$commit_raw" 2>/dev/null)"
    [ -n "$HEAD_AGE" ] || add_error first_party incomplete_payload "commit $HEAD carried no committer date"
  fi

  # A branch name is not URL-safe: `#` is a legal git ref character and would
  # truncate the query string, dropping per_page; `+` would decode as a space.
  BRANCH_ENC="$(jq -rn --arg b "$BRANCH" '$b|@uri')"
  rc=0
  runs_raw="$(gh api "repos/$REPO/actions/runs?branch=$BRANCH_ENC&per_page=100" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    add_error first_party gh_call_failed "gh api actions/runs for $BRANCH_SAFE exited $rc$(gh_rc_note "$rc")"
  elif [ -z "$runs_raw" ] || ! jq -e 'has("workflow_runs")' >/dev/null 2>&1 <<<"$runs_raw"; then
    add_error first_party incomplete_payload "actions/runs for $BRANCH_SAFE exited 0 without a workflow_runs key"
  else
    # THE PAYLOAD TRAVELS ON STDIN, NEVER ON ARGV. Measured on this repo, one
    # page of 100 runs is ~1.6 MB (~16 KB per run); Linux caps a single argv
    # element at MAX_ARG_STRLEN = 131,072 bytes, so `jq -n --argjson runs
    # "$runs_raw"` died at roughly the EIGHTH run on the branch — the run
    # comparison was dead on every real repo, and dead hardest where the
    # intersection baseline is richest.
    # `skills/github-issues/scripts/verify-issue-refs.sh` records the same
    # lesson from #263: the cap existed for argv, so the payload travels by
    # file.
    rc=0
    derived="$(jq --arg head "$HEAD" '
      # Only HEAD-TRIGGERED events are comparable: a workflow_dispatch or
      # schedule run on a prior head can never recur on this one.
      ["pull_request","pull_request_target","push","merge_group"] as $auto
      | [ .workflow_runs[]? | select(.event as $e | $auto | index($e)) ] as $r
      | ([ $r[] | select(.head_sha == $head) | "\(.name) (\(.event))" ] | unique) as $cur
      | ([ $r[] | select(.head_sha != $head) | .head_sha ] | unique) as $prior_heads
      | ([ $prior_heads[] as $h
           | [ $r[] | select(.head_sha == $h) | "\(.name) (\(.event))" ] | unique ]) as $sets
      # INTERSECTION of every prior head, never the union: a workflow absent
      # from one prior head is ordinary (path filter, if:, a rename).
      | (if ($sets | length) == 0 then []
         else ($sets | reduce .[] as $s (null; if . == null then $s else (. - (. - $s)) end))
         end) as $required
      | { cur: $cur,
          prior_heads: ($prior_heads | length),
          required: $required,
          missing: ($required - $cur),
          truncated: ((.workflow_runs | length) >= 100) }
    ' <<<"$runs_raw")" || rc=$?

    n_prior_heads=""; n_cur=""; n_required=""; RUNS_TRUNCATED="unknown"
    if [ "$rc" -eq 0 ] && [ -n "$derived" ]; then
      n_prior_heads="$(jq -r '.prior_heads' <<<"$derived" 2>/dev/null)"
      n_cur="$(jq -r '.cur | length' <<<"$derived" 2>/dev/null)"
      n_required="$(jq -r '.required | length' <<<"$derived" 2>/dev/null)"
      RUNS_TRUNCATED="$(jq -r 'if .truncated then "yes" else "no" end' <<<"$derived" 2>/dev/null)"
      [ -n "$RUNS_TRUNCATED" ] || RUNS_TRUNCATED="unknown"
    fi
    # Each value is checked SEPARATELY. Concatenating them and testing once is
    # what it looks like, and it passes when one is empty and the others are
    # digits ("2" + "" + "0" is all digits).
    DERIVED_OK=1
    for v in "$n_prior_heads" "$n_cur" "$n_required"; do
      case "$v" in ""|*[!0-9]*) DERIVED_OK=0 ;; esac
    done

    if [ "$DERIVED_OK" -ne 1 ]; then
      # A derivation that produced nothing must NEVER reach the branch that
      # asserts the check ran. `[ "" -eq 0 ]` prints an error and is falsy, so
      # an unguarded fall-through lands in the `else` and certifies a
      # measurement that never happened — the `clean`-means-measured door, one
      # layer below where it was first closed.
      add_error first_party incomplete_payload "the run comparison for $BRANCH_SAFE produced no usable result (jq exited $rc)"
      [ -n "$SELF_REASON" ] || SELF_REASON="run_comparison_failed"
    elif [ -z "$HEAD_AGE" ]; then
      SELF_REASON="head_age_unknown"
    elif [ "$HEAD_AGE" -lt "$MIN_AGE" ]; then
      SELF_REASON="head_too_fresh"
    elif [ "$n_prior_heads" -eq 0 ]; then
      # No baseline exists, so nothing was compared. Saying `clean` here is the
      # first-party door into `healthy` that #285 walks through one step early.
      SELF_REASON="no_prior_heads"
    else
      if [ "$n_required" -eq 0 ]; then
        # An EMPTY intersection compared nothing: every prior head ran a
        # different set, so no workflow was ever required of this head. Setting
        # RUN_CHECK here would certify a comparison that had no subject, which
        # is the `clean`-means-measured door one more layer down.
        SELF_REASON="no_required_baseline"
      elif [ "${rollup_n:-0}" -eq 0 ] && [ "$n_cur" -gt 0 ]; then
        # An EMPTY rollup beside runs that DID happen on this head is two API
        # surfaces contradicting each other, which is #285 itself in its most
        # extreme form: `gh pr view --json statusCheckRollup` exiting 0 with
        # fewer checks than reality, here with ALL of them missing. The
        # empty-state read is skipped entirely when the rollup has no entries
        # (there is nothing to iterate), so `ROLLUP_CHECK` stays `not_run`, no
        # anomaly is raised, and the run comparison earned `clean` UNOPPOSED.
        # Measured: verdict `healthy`, zero anomalies, zero probe_errors.
        #
        # The sibling this file must agree with already refuses the same shape:
        # `merge-shepherd.sh` carries a dedicated empty-rollup gate on the
        # principle that `CLEAN` plus zero checks is not green. The probe held
        # both halves of the contradiction — `rollup_n` and `n_cur` — and
        # compared them nowhere.
        #
        # `n_cur > 0` is the whole guard: a repo with no CI at all has an empty
        # rollup AND no runs, which is ordinary and must stay `clean`. This
        # fires only when runs exist and the rollup denies them.
        SELF_REASON="rollup_empty_with_runs"
      elif [ "$RUNS_TRUNCATED" != "no" ]; then
        # A TRUNCATED page cannot certify completeness. The header states this
        # cuts both ways and names under-detection as the direction that
        # matters: a page boundary landing inside the oldest included head`s
        # run set shrinks the intersection, the missing run is not required of
        # anybody, and the comparison reaches `clean` -> `healthy`. Measured on
        # two fixtures differing ONLY in truncation, same underlying reality:
        # the full page gave `degraded (unattributed)` and the 100-run page
        # gave `healthy`. That is the acceptance criterion of #285 failing in
        # the file that exists to satisfy it, so truncation is consulted by the
        # verdict and not merely reported beside it.
        #
        # `!= "no"` and not `= "yes"`: `unknown` means the flag itself could
        # not be read, which certifies nothing either. Anomalies already found
        # are still reported - they are first-party measurements, and the
        # anomaly branch is ahead of this one - so this suppresses only the
        # claim to have looked EVERYWHERE, never a positive finding.
        SELF_REASON="runs_page_truncated"
      else
        RUN_CHECK="ran"
      fi
      if [ "$n_cur" -eq 0 ]; then
        # `$required` is consulted HERE TOO, not only for missing_workflow_run.
        # With disjoint per-head workflow sets the intersection is empty, so
        # nothing was ever required of this head and its having no run is
        # ordinary. Applying the intersection guard to one signal and not its
        # sibling is exactly the over-detection the header disclaims.
        if [ "$n_required" -gt 0 ]; then
          add_anomaly no_run_for_head "$HEAD has no workflow run; $n_required workflow(s) ran on every one of $n_prior_heads prior head(s) of $BRANCH_SAFE (page truncated: $RUNS_TRUNCATED)"
        fi
      else
        missing_rc=0
        missing_out="$(jq -r "$UNSAFE_JQ_DEF"' .missing[] | clean' <<<"$derived")" || missing_rc=$?
        if [ "$missing_rc" -ne 0 ]; then
          # Same rule as the rollup generator: RUN_CHECK was set above, so a
          # silent failure here would certify a comparison it discarded.
          RUN_CHECK="not_run"
          SELF_REASON="run_comparison_failed"
          add_error first_party incomplete_payload "the missing-run read failed (jq exited $missing_rc)"
        else
          while IFS= read -r wf; do
            [ -n "$wf" ] && add_anomaly missing_workflow_run "$wf ran on every one of $n_prior_heads prior head(s) of $BRANCH_SAFE, not on $HEAD (page truncated: $RUNS_TRUNCATED)"
          done <<<"$missing_out"
        fi
      fi
    fi
  fi
fi

n_anomalies="$(jq -r 'length' <<<"$ANOMALIES" 2>/dev/null)"
# By EXCLUSION: everything that is not the attribution scope and not the probe
# scope is first-party, INCLUDING a scope this file has never heard of. See
# add_error for why naming `first_party` here was the open door.
n_fp_errors="$(jq -r '[.[] | select(.scope != "attribution" and .scope != "probe")] | length' <<<"$PROBE_ERRORS" 2>/dev/null)"
case "$n_anomalies" in ""|*[!0-9]*) n_anomalies=0 ;; esac
case "$n_fp_errors" in ""|*[!0-9]*) n_fp_errors=0 ;; esac
if [ "$n_anomalies" -gt 0 ]; then
  SELF="anomaly"
  # The reason field describes why a measurement did NOT happen; carrying one
  # onto an anomaly re-applies a suppression the code deliberately refused.
  SELF_REASON=""
elif [ "$n_fp_errors" -gt 0 ]; then
  # A call that failed is not degradation — but it is not a clean read either:
  # the probe cannot certify what it could not fetch. Without this the ledger
  # was decorative, and a run with BOTH gh api calls failing and a clean rollup
  # reported `healthy`, which is what this file and SKILL.md both already said
  # it must not do.
  SELF="not_measured"
  [ -n "$SELF_REASON" ] || SELF_REASON="probe_errors_present"
elif [ "$RUN_CHECK" = "ran" ]; then
  # ONLY the run comparison earns `clean`. The empty-state check is a real
  # signal but it detects a MALFORMED entry and can never detect an ABSENT
  # one — which is #285's headline signal — so a rollup that simply lacks `ci`
  # looks identical to a healthy one through it. Accepting it as sufficient
  # left the first-party door into `healthy` open on exactly the shape this
  # probe was written for: measured, #285's own rollup on a single-commit
  # branch reported `healthy`.
  SELF="clean"
  SELF_REASON=""
else
  SELF="not_measured"
  # The reason is PRESERVED, never blanked: `no_prior_heads`, `head_too_fresh`
  # and `no_required_baseline` are exactly why the verdict is not a measurement,
  # so discarding them loses the only explanation the caller has.
  [ -n "$SELF_REASON" ] || SELF_REASON="nothing_measurable"
fi

# --- attribution (never load-bearing) ----------------------------------------
STATUS="unknown"
STATUS_DETAIL="status endpoint unreachable or unreadable"
if command -v curl >/dev/null 2>&1; then
  # `--fail` is what makes a non-2xx a FAILURE: without it curl exits 0 on a
  # 503 and hands over the error body, and an error body carrying a `status`
  # key satisfied the recognisability gate below and resolved `operational`.
  # `--proto '=https'`, `--max-redirs 0` and the `--` terminator are the other
  # half: without `--`, a URL beginning `-K` is read as curl's `--config`, so an
  # attacker-supplied value could set `output`, `upload-file`, `header` or
  # `proxy`. The https-only check sits with the other usage validation above.
  rc=0
  status_raw="$(curl -sS --fail --proto '=https' --max-redirs 0 \
      --max-time "$STATUS_TIMEOUT" -H 'Accept: application/json' -- "$STATUS_URL" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    add_error attribution status_fetch_failed "curl exited $rc fetching the status endpoint"
  elif [ -n "$status_raw" ] && jq -e . >/dev/null 2>&1 <<<"$status_raw"; then
    STATUS="$(jq -r --arg comps "$STATUS_COMPONENTS" '
      ($comps | ascii_downcase | split(",") | map(sub("^ +";"") | sub(" +$";"")) | map(select(length > 0))) as $rel
      | (if (.status | type) == "object" then (.status.indicator // "") else "" end) as $ind
      | (($ind == "major") or ($ind == "critical")) as $broad
      | def relevant($n): ($rel | any(. as $c | ($n // "" | ascii_downcase) | contains($c)));
        # An ARRAY is required, not merely a key. `{"status":"error","code":503}`
        # and `{"status":"Service Unavailable"}` both carry a `status` key, and
        # under a key-presence test they classified `operational` — a non-2xx
        # body manufacturing a green platform. A scope that filters to nothing
        # (`","`, `"   "`) is `unknown` for the same reason: it cannot answer.
        if (($rel | length) == 0) then "unknown"
        elif ((type == "object")
              and (((.components | type) == "array") or ((.incidents | type) == "array")) | not)
        then "unknown"
        # A payload carrying NEITHER a component nor an incident answers
        # nothing. It is not a green platform, it is a page with no content,
        # and reading it as `operational` resolves `healthy` through whatever
        # is actually happening.
        elif ((((.components // []) | length) == 0)
              and (((.incidents // []) | length) == 0)) then "unknown"
        # A scope matching NO component name cannot answer either, and this is
        # the door an OPERATOR opens by accident. `relevant` asks whether a
        # component NAME CONTAINS a scope token, so the MORE SPECIFIC value
        # `github actions` matches the component `Actions` not at all while
        # `actions` matches it: a plausible-looking PLATFORM_STATUS_COMPONENTS
        # override silently disables attribution AND manufactures `operational`
        # through a live outage. Measured, Actions in `major_outage`:
        # `actions,api requests` -> incident, `github actions` -> operational,
        # `zzz-nope` -> operational. An EMPTY scope was already `unknown` for
        # exactly this reason; a scope that filters to nothing is the same fact
        # arriving one step later, and it was the THIRD door into `healthy`.
        elif ((((.components // []) | length) > 0)
              and (([ .components[]? | select(relevant(.name)) ] | length) == 0)) then "unknown"
        else
          ([ .components[]? | select((.status // "") != "operational") | select(relevant(.name)) ]) as $comp
          | ([ .incidents[]?
               | select((.status // "") != "resolved" and (.status // "") != "postmortem")
               | select( ((.components // []) | any(relevant(.name)))
                         or (((.components // []) | length) == 0 and $broad) ) ]) as $inc
          | if (($comp | length) > 0) or (($inc | length) > 0) then "incident" else "operational" end
        end
    ' <<<"$status_raw" 2>/dev/null)"
    if [ -z "$STATUS" ]; then
      STATUS="unknown"
      add_error attribution status_unreadable "the status classifier failed on the fetched payload"
    fi
    case "$STATUS" in
      incident)
        STATUS_DETAIL="$(jq -r "$UNSAFE_JQ_DEF" --arg comps "$STATUS_COMPONENTS" '
          ($comps | ascii_downcase | split(",") | map(sub("^ +";"") | sub(" +$";"")) | map(select(length > 0))) as $rel
          | (if (.status | type) == "object" then (.status.indicator // "") else "" end) as $ind
          | (($ind == "major") or ($ind == "critical")) as $broad
          | def relevant($n): ($rel | any(. as $c | ($n // "" | ascii_downcase) | contains($c)));
            [ ( (if (.status | type) == "object" then (.status.description // "") else "" end)
                | if . == "" then "" else "page-wide: " + . end ),
              ( [ .incidents[]?
                  | select((.status // "") != "resolved" and (.status // "") != "postmortem")
                  | select( ((.components // []) | any(relevant(.name)))
                            or (((.components // []) | length) == 0 and $broad) )
                  | .name ] | join("; ") ),
              ( [ .components[]? | select((.status // "") != "operational")
                  | select(relevant(.name)) | "\(.name): \(.status)" ] | join("; ") )
            ] | map(select(. != "")) | join(" | ")
            | clean
        ' <<<"$status_raw" 2>/dev/null)"
        # The gsub above is what strips BIDI; `tr` is byte-oriented and cannot
        # match a multibyte RLO at all, so it is kept only as a belt-and-braces
        # pass over the shell-assembled result. Third-party text, but it reaches
        # the same reported field as the first-party strings.
        STATUS_DETAIL="$(printf '%s' "$STATUS_DETAIL" | tr -d '\000-\037\177')"
        [ -n "$STATUS_DETAIL" ] || STATUS_DETAIL="an incident is open on a check-relevant component" ;;
      operational)
        STATUS_DETAIL="no check-relevant component is impaired"
        page_desc="$(jq -r "$UNSAFE_JQ_DEF"' (if (.status | type) == "object" then (.status.description // "") else "" end) | clean' <<<"$status_raw" 2>/dev/null | tr -d '\000-\037\177')"
        [ -z "$page_desc" ] || STATUS_DETAIL="$STATUS_DETAIL (page-wide: $page_desc)" ;;
      *)
        # Covers THREE distinct ways attribution can fail, and must not assert
        # any one of them: an unrecognisable payload, a payload carrying no
        # components AND no incidents, and a configured scope that matched no
        # component name. Naming only the first was false for the other two.
        STATUS_DETAIL="the status page could not attribute: unrecognisable, empty, or no component matched the configured scope" ;;
    esac
  else
    add_error attribution status_unparsable "the status endpoint returned no parsable JSON"
  fi
else
  add_error attribution curl_missing "curl is not installed"
  STATUS_DETAIL="curl is not installed, so attribution could not be attempted"
fi

# --- verdict ------------------------------------------------------------------
# The separator is "/" and not "|" ON PURPOSE: `|` is case-pattern alternation,
# so `anomaly|incident)` would silently match the single word "anomaly" and the
# whole table would collapse to its first row.
case "$SELF/$STATUS" in
  anomaly/incident)       VERDICT="degraded (attributed)" ;;
  anomaly/operational)    VERDICT="degraded (unattributed)" ;;
  anomaly/unknown)        VERDICT="degraded (unattributed)" ;;
  clean/incident)         VERDICT="degraded (attributed)" ;;
  clean/operational)      VERDICT="healthy" ;;
  clean/unknown)          VERDICT="unknown" ;;
  not_measured/incident)  VERDICT="degraded (attributed)" ;;
  *)                      VERDICT="unknown" ;;
esac

# `explains` is keyed on BOTH axes, not on the verdict alone. An incident beside
# a first-party read that found nothing wrong explains nothing about THIS PR,
# and saying it does invents an excuse for a genuine red check.
case "$VERDICT" in
  "healthy")
    EXPLAINS="nothing — a green status page is not evidence of health, and this verdict never licenses escalating a stall as a real defect" ;;
  "unknown")
    if [ "$SELF" = "clean" ]; then
      EXPLAINS="nothing — this PR's own check data was read and was complete, but the status endpoint could not be, so nothing is attributed and this verdict never licenses escalating a stall as a real defect"
    else
      EXPLAINS="nothing — the probe could not measure; unknown is not health, and this verdict never licenses escalating a stall as a real defect"
      # WHY IT COULD NOT MEASURE IS THE MOST USEFUL FACT THIS PROBE HOLDS, and
      # until #314 it reached no human channel at all. `unknown` here spans
      # "no --pr was given" and "GitHub hung for 20 seconds on `gh pr view`",
      # and both rendered as the same sentence — the reason survived only in
      # `probe_errors[].detail`, which nothing renders. The tail is APPENDED
      # rather than woven in, so the canonical sentence above stays one
      # checksummable literal and the generated half is bounded by a marker the
      # gate can split on. `explains` is the field SKILL.md orders callers to
      # report INSTEAD OF the verdict, so this is where the fact belongs; the
      # stderr summary interpolates the same string and inherits it.
      EXPLAINS="$EXPLAINS (not measured: ${SELF_REASON:-nothing_measurable}$(fp_details))"
    fi ;;
  "degraded (attributed)")
    if [ "$SELF" = "anomaly" ]; then
      EXPLAINS="a stall — an open platform incident on a check-relevant component, alongside first-party evidence of missing or incomplete check data"
    elif [ "$SELF" = "clean" ]; then
      EXPLAINS="nothing about this PR — a platform incident is open, but this PR's own check data was compared and came back complete, so the incident is context and not an explanation for anything observed here"
    else
      EXPLAINS="nothing measured here — a platform incident is open, and this run measured nothing first-party, so the incident is context and not an explanation for anything observed on this PR"
    fi ;;
  "degraded (unattributed)")
    EXPLAINS="a stall — first-party evidence of degradation; the status page neither corroborates nor refutes it, and its silence is not a refutation" ;;
  *)
    EXPLAINS="nothing — this build emitted a verdict it has no explanation for, which is itself a defect; treat it as unknown" ;;
esac

# --- emit ---------------------------------------------------------------------
# CAPTURED, then RE-PARSED, then printed. The status alone is not enough: the
# contract is "one JSON object on stdout", and a partial write that exits
# non-zero would satisfy an exit-status check while handing the caller half an
# object. Both failures land on the same fallback.
emit_rc=0
emitted="$(jq -n \
  --arg repo "$REPO" \
  --arg verdict "$VERDICT" \
  --arg self "$SELF" \
  --arg self_reason "$SELF_REASON" \
  --arg run_check "$RUN_CHECK" \
  --arg runs_truncated "$RUNS_TRUNCATED" \
  --arg rollup_check "$ROLLUP_CHECK" \
  --arg status "$STATUS" \
  --arg status_detail "$STATUS_DETAIL" \
  --arg status_url "$STATUS_URL" \
  --arg head "$HEAD" \
  --arg branch "$BRANCH_SAFE" \
  --arg merge_state "$MERGE_STATE" \
  --arg head_age "$HEAD_AGE" \
  --arg explains "$EXPLAINS" \
  --argjson anomalies "$ANOMALIES" \
  --argjson probe_errors "$PROBE_ERRORS" \
  --argjson pr "${PR:-null}" \
  '{repo:(if $repo == "" then null else $repo end), pr:$pr, verdict:$verdict,
    self_measured:$self,
    self_measured_reason:(if $self_reason == "" then null else $self_reason end),
    checks_run:{run_comparison:$run_check, rollup_empty_state:$rollup_check,
                runs_page_truncated:$runs_truncated},
    anomalies:$anomalies,
    probe_errors:$probe_errors,
    status_page:$status, status_page_detail:$status_detail, status_page_url:$status_url,
    head_sha:(if $head == "" then null else $head end),
    head_ref:(if $branch == "" then null else $branch end),
    head_age_seconds:(if $head_age == "" then null else ($head_age|tonumber) end),
    merge_state_status:(if $merge_state == "" then null else $merge_state end),
    explains:$explains}')" || emit_rc=$?

if [ "$emit_rc" -ne 0 ] || [ -z "$emitted" ] || ! jq -e . >/dev/null 2>&1 <<<"$emitted"; then
  # FOUR KEYS, THREE OF THEM LITERALS AND THE FOURTH ONE THAT CANNOT FAIL — see
  # the header for why this is not the emitter's shape. The rule is not "carry
  # nothing"; it is "carry nothing that could be what broke it". `pr` qualifies
  # and no other field does: it is validated at parse time as digits with no
  # leading zero, so it is a bare JSON number by construction and cannot
  # malform this literal, and it is the one value that tells a caller reading a
  # fallback object WHICH PR the dead run was about — without it, a coordinator
  # holding several PRs cannot attribute the failure to any of them (#314).
  # `repo` stays out: it is shape-checked (`owner/name`) and never sanitised,
  # so it is a string with a wider grammar than this literal can safely take,
  # and unlike `pr` it is not what a caller is missing. Every OTHER measured
  # value stays out for the original reason — they are precisely what could not
  # be serialised, and re-interpolating one re-runs the failure inside its own
  # handler. `verdict` is `unknown` because that is the verdict for "nothing
  # could be measured", and `explains` says so in the same words every other
  # unknown does — a caller reporting this object must not read it as softer.
  emitted='{"verdict":"unknown","self_measured_reason":"verdict_emitter_failed","pr":'"${PR:-null}"',"explains":"nothing — the verdict emitter failed, so nothing that was measured survived; unknown is not health, and this verdict never licenses escalating a stall as a real defect"}'
  # The two failures are reported apart. Folding them together printed
  # `the verdict emitter failed (jq exited 0)` on the empty-stdout branch — a
  # diagnostic contradicting itself on the exact door this whole change closes.
  if [ "$emit_rc" -ne 0 ]; then
    emit_why="jq exited $emit_rc"
  else
    emit_why="jq exited 0 but produced no usable object"
  fi
  # AND WHICH INPUT BROKE IT. This failure is unreproducible after the fact —
  # the ledgers die with the process — so this stderr line is the only forensic
  # record there will ever be, and until #314 it named the exit code and not the
  # cause. `$ANOMALIES` and `$PROBE_ERRORS` are the only two emitter inputs
  # nothing validates before use, so each is re-tested here and reported with
  # its byte length: an empty one and a 40 KB unparsable one are different
  # stories, and "both parsed" is itself the answer that the emitter, not its
  # inputs, is what died.
  ledger_note() { # <name> <value>
    # `LC_ALL=C` so `${#2}` really is BYTES. Under a UTF-8 locale it counts
    # CHARACTERS, and a ledger full of multibyte branch names would be reported
    # smaller than the argv cap it just exceeded — a forensic line that reads
    # precise and is wrong about the one number it exists to give.
    local LC_ALL=C
    if jq -e . >/dev/null 2>&1 <<<"$2"; then
      printf '$%s parsed (%s bytes)' "$1" "${#2}"
    else
      printf '$%s FAILED jq -e . (%s bytes)' "$1" "${#2}"
    fi
  }
  emit_why="$emit_why; $(ledger_note ANOMALIES "$ANOMALIES"), $(ledger_note PROBE_ERRORS "$PROBE_ERRORS")"
  SUMMARY="platform: unknown — the verdict emitter failed ($emit_why); nothing that was measured survived"
else
  SUMMARY="platform: $VERDICT — explains $EXPLAINS"
fi

# `printf` is a bash BUILTIN, so the payload never becomes an argv element and
# the 131,072-byte MAX_ARG_STRLEN cap that killed `--argjson runs` cannot reach
# it. The single `exit 0` below is shared by both paths on purpose: a verdict
# never travels in an exit code, and the fallback carries a verdict.
printf '%s\n' "$emitted"
echo "$SUMMARY" >&2
exit 0
