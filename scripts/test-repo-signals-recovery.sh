#!/usr/bin/env bash
# test-repo-signals-recovery.sh — pins how pull-repo-signals.sh answers
# `default_branch_ci`, what a SURVIVING null is allowed to mean, and what the
# recovered verdict must carry with it (issue #367).
#
# THE FAILURE. The puller took ONE unfiltered sample of the newest RUN_LIMIT
# workflow runs across ALL branches and derived a per-branch, per-event verdict
# from whatever happened to be in it. When that page held no push-class run on
# the default branch the verdict was null and the sweep had nothing to rank —
# velovate, brewslate, tailoredtip, what2wear and td3000, 5 of 15 org repos on
# 2026-09-06, tabulated in issue #367. It is silent in the way that matters
# most: null is well-formed JSON carrying no outcome, so a reader with no rule
# for it treats the repo as fine.
#
# THE RECOVERY, and the three filters a later simplification will drop. When the
# first derivation yields null the puller issues ONE narrow re-query,
# `--branch <default_branch> --event push --status completed --limit 1`. Each
# filter looks droppable for a DIFFERENT reason:
#
#   1. `--event` is the one that does the work, and a larger RUN_LIMIT is not a
#      substitute — velovate had ZERO push-on-main runs in its newest 100, so no
#      page size reaches it. The mock answers a branch-only query with the
#      `schedule` run that actually crowds a default branch, so dropping
#      `--event` reproduces the live null instead of being waved through.
#   2. `--status completed` is the one a reader assumes the derivation already
#      handles. It does — for the SAMPLE, which fetches RUN_LIMIT rows and can
#      walk past in-flight runs to the newest concluded one. This query fetches
#      exactly ONE row and has nothing to walk past, so without the filter a
#      single in-flight run re-creates the null the recovery exists to remove.
#      Row `recovery-skips-in-flight` runs against a pool whose NEWEST row is in
#      flight, which is the only shape that can tell the two apart.
#   3. `push` alone, never `push,merge_group`. A merge_group run's head branch
#      is `gh-readonly-queue/<branch>/pr-<N>`, so it can never satisfy
#      `--branch <default_branch>`; adding it widens the query and recovers
#      nothing. `merge-group-cannot-satisfy-branch` proves that premise against
#      the derivation rather than restating it.
#
#   routines#46 shipped this with branch and status only and recovered
#   one repo of the two sampled; #47 added the event filter.
#
# THE OTHER TWO FLAGS ARE NOT DECORATION, and this gate pins all five because
# three of five left two ordinary edits green. A `--repo`-less `gh run list`
# resolves against the CWD repo, handing every repo in the org this repo's own
# verdict on the key `whats-on-fire` ranks and routes by — so the mock answers a
# `--repo`-less call the way `gh` would, as a different repository. Trimming
# `--json` to a shorter list makes the derivation reject every recovered run and
# silently reverts #367 — so the mock PROJECTS its answer through the requested
# field list rather than ignoring it, the same fidelity property
# test-queue-snapshot-site.sh treats as first-class.
#
# ONE DEFINITION IS NOT ONE ANSWER. The rule lives in
# derive_default_branch_ci() and is applied to both queries. The property is
# pinned behaviourally: mutant `ignoreevent` changes the shared rule and must
# redden a SAMPLE-path row and a RECOVERY-path row together. Nothing downstream
# can tell which query answered, which is why the two must not be able to
# disagree.
#
# THE STILL-NULL PATH IS THE POINT OF THE GATE. A recovery that works is easy to
# see; a null that survives it is not, and it is what `scoring.md`'s unknown
# state is built on. `default_branch_runs_seen` is THREE-STATE for the same
# reason `dependabot.enabled` is, and every state has its own row:
#
#   * `0` — READ, and there is no such run (`still-null-empty`). This is a
#     positive claim and may only come from a recovery that actually answered.
#   * non-zero with a null verdict — they are all still in flight
#     (`still-null-all-in-flight`, and `failed-recovery-keeps-probe` for the
#     case where the recovery could not confirm it).
#   * `null` — the recovery could not be read (`unreadable-recovery-is-unknown`)
#     or came back in a shape the derivation cannot reduce
#     (`underivable-recovery-is-unknown`). Collapsing either into `0` re-creates
#     the original defect one level up: `scoring.md` renders `0` as the sentence
#     "there is no default-branch run", which would then be asserted about a 503.
#
#   A sample count of ZERO is not evidence and contributes nothing to the merge;
#   a sample that DID see runs bounds the count from below, so a one-row recovery
#   cannot shrink it (`still-null-all-in-flight`).
#
# THE VERDICT SHIPS ITS AGE. The recovery is unbounded by RUN_LIMIT — in #367's
# own table it reached back to 2026-08-09 for two of five repos, measured
# 2026-09-06 — so a verdict rendered without its age turns five `CI unknown`
# repos into `✓ Clean today` on a month-old run, which is quieter than the
# missing verdict it replaced. `default_branch_ci_age_days` and
# `default_branch_ci_url` therefore travel with the verdict from the SAME run,
# on both paths (`sample-verdict-age`, `recovered-verdict-age`,
# `recovered-verdict-url`). The url matters on its own: `last_failure` is
# derived from the sample, so a recovered failure has none beside it.
#
# AN UNKNOWN AGE IS NOT A MISSING VERDICT (issue #375). A completed run can
# retain its success or failure conclusion without a usable creation time.
# `sample-undated-success` and `recovered-undated-failure` omit createdAt;
# `sample-undated-failure` and `recovered-undated-success` carry an explicit
# null. Each row requires the conclusion AND a present, null age field, on the
# intended query path. Mutant `zeroage` must redden all these rows: guessing
# zero days would make undated evidence look current to every consumer.
#
# These fixtures cover the puller's evidence, not the report's rendering or
# ranking. Those are prose instructions and must be exercised with report
# scenarios; searching for their wording does not prove their behaviour.
#
# MUTATION PROOF, with the MEMBERSHIP half. The matrix is a function of the
# script path, so it is re-run against the mutants enumerated below. Reach is
# DERIVED from the verdicts, and each mutant additionally declares the rows it MUST
# redden — because reddened sets overlap, and without membership "the recovery
# does not exist" and "`--event` is not load-bearing" produce indistinguishable
# red builds. Same shape as test-site-filter.sh and test-queue-snapshot-site.sh.
# The rows no mutant reaches must equal the declared set, which holds exactly
# the two fixture-adequacy preconditions.
#
# NO NETWORK, STRUCTURALLY. The shim's resolution is verified immediately after
# `chmod` and EXITS if PATH did not pick it up — a failed chmod or a noexec
# $TMPDIR otherwise sends every read to the operator's real, authenticated `gh`,
# and `mock-org` is a real GitHub organization (issue #348). The mock honouring
# `--json` is a FIDELITY property and is not a second guard.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-repo-signals-recovery.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-repo-signals-recovery: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SCRIPT="$REPO_ROOT/skills/whats-on-fire/scripts/pull-repo-signals.sh"
[ -f "$SCRIPT" ] || { echo "test-repo-signals-recovery: $SCRIPT not found" >&2; exit 1; }

WORK="$(mktemp -d)" || { echo "test-repo-signals-recovery: mktemp -d failed" >&2; exit 1; }
# Fail closed rather than continuing with an empty WORK: set -u does not fire on
# empty-but-set, and every path below would then resolve against /.
case "$WORK" in
    /*) : ;;
    *) echo "test-repo-signals-recovery: mktemp -d gave no absolute path ('$WORK')" >&2; exit 1 ;;
esac
[ -d "$WORK" ] || { echo "test-repo-signals-recovery: '$WORK' is not a directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
CALL_LOG="$WORK/calls.log"

fail=0
ok()  { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "repo-signals recovery tests (work: $WORK)" >&2

# --- the mock gh --------------------------------------------------------------
# It models `gh run list` rather than pattern-matching it: the recovery's flags
# are the finding, so every one of them has to be able to change the answer.
# --status filters, --limit truncates AFTER that filter (which is what makes the
# in-flight row reachable), --json projects, and a missing --repo answers as a
# different repository. Every invocation is appended to CALL_LOG.
mkdir -p "$BIN"
cat >"$BIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

printf '%s\n' "$*" >>"$CALL_LOG"

# Ages are relative to the run so the age rows stay stable without depending on
# GNU vs BSD date. Fields: event|branch|status|conclusion|ageDays|urlToken.
# "-" means a JSON null conclusion; ageDays accepts "missing" (omit createdAt)
# and "null" (explicitly unavailable timestamp) as well as numeric ages.
mkruns() {
    local acc='[]' a ev br st co ag ur
    for a in "$@"; do
        IFS='|' read -r ev br st co ag ur <<<"$a"
        acc="$(jq -c -n --argjson acc "$acc" --arg ev "$ev" --arg br "$br" \
              --arg st "$st" --arg co "$co" --arg ag "$ag" --arg ur "$ur" \
              '$acc + [{conclusion: (if $co == "-" then null else $co end),
                        status: $st, workflowName: "CI", headBranch: $br,
                        url: ("https://example.invalid/run/" + $ur),
                        createdAt: (if $ag == "missing" or $ag == "null" then null
                                    else ((now - (($ag | tonumber) * 86400)) | todate) end),
                        event: $ev}
                       | if $ag == "missing" then del(.createdAt) else . end]')"
    done
    printf '%s' "$acc"
}

case "$MOCK_MODE" in
    trunk) DB=trunk ;;
    *)     DB=main ;;
esac

cmd="${1:-}"; shift

case "$cmd" in
  auth) exit 0 ;;
  repo)
    jq -c -n --arg db "$DB" '[{name:"mock-repo",isArchived:false,defaultBranchRef:{name:$db}}]'
    exit 0 ;;
  api)
    # Every security surface degrades to "disabled" so this gate scores the CI
    # verdict alone. None of them reach a run list.
    path="${1:-}"
    case "$path" in
      */dependabot/alerts*)
        echo '{"message":"Dependabot alerts are disabled for this repository."}' >&2; exit 1 ;;
      */code-scanning/alerts*)
        echo '{"message":"Advanced Security must be enabled for this repository to use code scanning."}' >&2; exit 1 ;;
      */secret-scanning/alerts*)
        echo '{"message":"Secret scanning is disabled on this repository."}' >&2; exit 1 ;;
      *) echo "mock gh: unhandled api path: $path" >&2; exit 1 ;;
    esac ;;
  run) : ;;
  *) echo "mock gh: unhandled command: $cmd" >&2; exit 1 ;;
esac

[ "${1:-}" = "list" ] || { echo "mock gh: unhandled run subcommand: ${1:-}" >&2; exit 1; }
shift

repo=""; branch=""; event=""; status=""; limit="20"; fields=""; prev=""
for a in "$@"; do
    case "$prev" in
        --repo|-R)   repo="$a" ;;
        --branch|-b) branch="$a" ;;
        --event|-e)  event="$a" ;;
        --status|-s) status="$a" ;;
        --limit|-L)  limit="$a" ;;
        --json)      fields="$a" ;;
    esac
    prev="$a"
done

# gh refuses a --json with no field list; so must the mock, or a trimmed-to-
# nothing list would read as "all fields".
[ -n "$fields" ] || { echo "mock gh: specify one or more comma-separated fields for --json" >&2; exit 1; }

emit() {
    jq -c --arg st "$status" --argjson lim "$limit" --arg f "$fields" '
        [ .[] | select($st == "" or .status == $st) ]
        | .[0:$lim]
        | [ .[] | with_entries(select(.key as $k | ($f | split(",")) | index($k))) ]' <<<"$1"
}

if [ -z "$branch" ]; then
    case "$MOCK_MODE" in
      # The newest push here is a FAILING one on a feature branch, so a
      # derivation that forgets the branch check reports a different verdict
      # rather than the same one.
      clean) emit "$(mkruns 'push|feature/x|completed|failure|1|u1' \
                            'push|main|completed|success|2|u2' \
                            'schedule|main|completed|failure|1|u3')" ;;
      samplemissing) emit "$(mkruns 'push|main|completed|success|missing|s-missing')" ;;
      samplenull)    emit "$(mkruns 'push|main|completed|failure|null|s-null')" ;;
      # The crowding rows carry events that NEITHER the real push-class rule NOR
      # the `ignoreevent` mutation (`.event == "schedule"`) matches. That is a
      # requirement, not a taste: with `schedule|main` here the mutant made the
      # SAMPLE answer, the recovery gate never opened, and the one-answer
      # property the header claims to pin behaviourally was pinned by nothing.
      # Any replacement must stay null under both rules.
      recoverable|empty|unreadable|underivable|inflightnewest|recoverymissing|recoverynull)
             emit "$(mkruns 'workflow_dispatch|main|completed|failure|1|u1' \
                            'pull_request|feature/y|completed|success|1|u2' \
                            'workflow_dispatch|main|completed|success|2|u3')" ;;
      mergegroup)
             emit "$(mkruns 'merge_group|gh-readonly-queue/main/pr-7|completed|success|1|u1')" ;;
      recoveryfails)
             emit "$(mkruns 'push|main|in_progress|-|0|u1' \
                            'schedule|main|completed|success|1|u2')" ;;
      inflightsample)
             emit "$(mkruns 'push|main|in_progress|-|0|u1' \
                            'push|main|in_progress|-|0|u2' \
                            'push|main|in_progress|-|0|u3')" ;;
      trunk) emit "$(mkruns 'schedule|trunk|completed|failure|1|u1' \
                            'pull_request|feature/z|completed|success|1|u2')" ;;
      *) echo "mock gh: unknown MOCK_MODE: $MOCK_MODE" >&2; exit 1 ;;
    esac
    exit 0
fi

# --- the recovery -------------------------------------------------------------
# A --repo-less run list resolves against the CWD repo, so it answers as a
# DIFFERENT repository — which is the whole hazard, and it must be visible in
# the verdict rather than only in the flag string.
if [ -z "$repo" ]; then
    emit "$(mkruns "push|$DB|completed|failure|1|cwd")"
    exit 0
fi

# Without a push event filter this is the routines#46 shape, and what
# it gets back is what a default branch is actually crowded with.
case "$event" in
    *push*) : ;;
    *) emit "$(mkruns "schedule|$DB|completed|failure|1|crowd")"; exit 0 ;;
esac

case "$MOCK_MODE" in
  # clean must never reach here. An empty answer keeps the call-count row the
  # only one that reddens, so the finding is not smeared across the matrix.
  clean|samplemissing|samplenull|empty|mergegroup|inflightsample) printf '%s\n' '[]' ;;
  recoverable)   emit "$(mkruns "push|$DB|completed|success|30|r1")" ;;
  recoverymissing) emit "$(mkruns "push|$DB|completed|failure|missing|r-missing")" ;;
  recoverynull)    emit "$(mkruns "push|$DB|completed|success|null|r-null")" ;;
  # The NEWEST row is in flight. With --status completed the concluded one
  # answers; without it, --limit 1 takes the in-flight row and the null returns.
  inflightnewest) emit "$(mkruns "push|$DB|in_progress|-|0|r0" \
                                 "push|$DB|completed|success|30|r1")" ;;
  # Rows come back that the derivation drops (wrong branch): the query asserts
  # such runs exist and we cannot reduce them. Unknown, never "none".
  underivable)   emit "$(mkruns 'push|some-other-branch|completed|success|3|r9')" ;;
  trunk)         emit "$(mkruns "push|$DB|completed|success|5|t1")" ;;
  unreadable|recoveryfails) echo '{"message":"HTTP 503"}' >&2; exit 1 ;;
  *) echo "mock gh: unknown MOCK_MODE: $MOCK_MODE" >&2; exit 1 ;;
esac
MOCK
chmod +x "$BIN/gh"

# STRUCTURAL, not ordering. A failed `chmod`, or a noexec `$TMPDIR`, means PATH
# search skips the shim and the puller reaches the operator's REAL `gh` — nine
# authenticated requests per mode, against `mock-org`, which is a real GitHub
# organization. Same shape and same reason as test-queue-snapshot-site.sh and
# test-file-or-link-issue.sh: the check sits immediately after the chmod and
# EXITS rather than recording a failed assertion.
if [ "$(PATH="$BIN:$PATH" command -v gh)" != "$BIN/gh" ]; then
    echo "test-repo-signals-recovery: the mock gh shim did not install at $BIN/gh — refusing to run, because every read below would reach the real GitHub API" >&2
    exit 1
fi

# --- helpers ------------------------------------------------------------------
OUT=""
LOG=""

run_case() {  # 1: script path  2: MOCK_MODE  -> sets OUT (the repo object) and LOG
    : >"$CALL_LOG"
    OUT="$(MOCK_MODE="$2" CALL_LOG="$CALL_LOG" PATH="$BIN:$PATH" ORG="mock-org" \
        bash "$1" 2>/dev/null | jq -c '.repos[0]' 2>/dev/null)"
    LOG="$(cat "$CALL_LOG" 2>/dev/null)"
}

# `field` pipes `printf` into jq, which reads to end of input, so its writer
# always finishes; `has` matches with a here-string, never a pipe into
# `grep -q` (test-pipefail-grep.sh, issue #571).
field() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }
is()    { [ "$(field "$1")" = "$2" ]; }
has()   { grep -qF -- "$2" <<<"$1"; }
hasnt() { if has "$1" "$2"; then return 1; fi; return 0; }
verdict() { if "$@"; then echo pass; else echo fail; fi; }

runlist_calls() { printf '%s\n' "$LOG" | grep -c '^run list'; }
recovery_call() { printf '%s\n' "$LOG" | awk '/^run list/ && /--branch/ { line = $0 } END { print line }'; }
# Exact value, never a substring: `--event push,merge_group` must not satisfy a
# check for `--event push`.
flag_of() { printf '%s\n' "$1" | awk -v f="$2" '{ for (i = 1; i < NF; i++) if ($i == f) { print $(i + 1); exit } }'; }

# --- the matrix ---------------------------------------------------------------
# Emits one `<row-id><TAB>pass|fail` line per row. A function of the script path
# so the mutants below are scored by exactly this code.
matrix() {
    local s="$1"
    local rec j miss f

    run_case "$s" clean
    printf 'sample-verdict\t%s\n'     "$(verdict is '.default_branch_ci' success)"
    printf 'sample-verdict-age\t%s\n' "$(verdict is '.default_branch_ci_age_days' 2)"
    printf 'sample-runs-seen\t%s\n'   "$(verdict is '.default_branch_runs_seen' 1)"
    printf 'no-redundant-call\t%s\n'  "$(verdict test "$(runlist_calls)" = 1)"

    run_case "$s" samplemissing
    if [ "$(runlist_calls)" = 1 ] && is '.default_branch_ci' success \
       && is 'has("default_branch_ci_age_days") and .default_branch_ci_age_days == null' true; then
        printf 'sample-undated-success\tpass\n'
    else
        printf 'sample-undated-success\tfail\n'
    fi

    run_case "$s" samplenull
    if [ "$(runlist_calls)" = 1 ] && is '.default_branch_ci' failure \
       && is 'has("default_branch_ci_age_days") and .default_branch_ci_age_days == null' true; then
        printf 'sample-undated-failure\tpass\n'
    else
        printf 'sample-undated-failure\tfail\n'
    fi

    run_case "$s" recoverymissing
    if [ "$(runlist_calls)" = 2 ] && is '.default_branch_ci' failure \
       && is 'has("default_branch_ci_age_days") and .default_branch_ci_age_days == null' true; then
        printf 'recovered-undated-failure\tpass\n'
    else
        printf 'recovered-undated-failure\tfail\n'
    fi

    run_case "$s" recoverynull
    if [ "$(runlist_calls)" = 2 ] && is '.default_branch_ci' success \
       && is 'has("default_branch_ci_age_days") and .default_branch_ci_age_days == null' true; then
        printf 'recovered-undated-success\tpass\n'
    else
        printf 'recovered-undated-success\tfail\n'
    fi

    run_case "$s" recoverable
    # Fixture adequacy: the null must come from the FILTER, not from an empty
    # page — otherwise every recovery row below is trivially satisfiable.
    printf 'sample-adequate\t%s\n'         "$(verdict is '.runs_sampled' 3)"
    printf 'recovery-fires-on-null\t%s\n'  "$(verdict test "$(runlist_calls)" = 2)"
    # The recovery-path half of the one-answer property carries the two-call
    # proof INSIDE its own row: a verdict of `success` reached without a second
    # query is the sample answering, not the recovery, and a later fixture
    # change must not be able to re-collapse the two silently.
    if [ "$(runlist_calls)" = 2 ] && is '.default_branch_ci' success; then
        printf 'recovered-verdict\tpass\n'
    else
        printf 'recovered-verdict\tfail\n'
    fi
    printf 'recovered-runs-seen\t%s\n'     "$(verdict is '.default_branch_runs_seen' 1)"
    printf 'recovered-verdict-age\t%s\n'   "$(verdict is '.default_branch_ci_age_days' 30)"
    printf 'recovered-verdict-url\t%s\n'   "$(verdict is '.default_branch_ci_url' 'https://example.invalid/run/r1')"
    rec="$(recovery_call)"
    if [ "$(flag_of "$rec" --repo)"   = "mock-org/mock-repo" ] \
    && [ "$(flag_of "$rec" --branch)" = "main" ] \
    && [ "$(flag_of "$rec" --event)"  = "push" ] \
    && [ "$(flag_of "$rec" --status)" = "completed" ] \
    && [ "$(flag_of "$rec" --limit)"  = "1" ]; then
        printf 'recovery-query-shape\tpass\n'
    else
        printf 'recovery-query-shape\tfail\n'
    fi
    # Every field the derivation and the age/url projection read must be asked
    # for; a trimmed list is valid JSON that reduces to nothing.
    j="$(flag_of "$rec" --json)"; miss=""
    for f in conclusion status headBranch event createdAt url; do
        case ",$j," in *",$f,"*) ;; *) miss="$miss $f" ;; esac
    done
    printf 'recovery-json-fidelity\t%s\n' "$(verdict test -z "$miss")"
    printf 'recovery-never-merge-group\t%s\n' "$(verdict hasnt "$LOG" 'merge_group')"

    run_case "$s" inflightnewest
    if is '.default_branch_ci' success && is '.default_branch_ci_age_days' 30; then
        printf 'recovery-skips-in-flight\tpass\n'
    else
        printf 'recovery-skips-in-flight\tfail\n'
    fi

    run_case "$s" empty
    if is '.default_branch_ci' null && is '.default_branch_runs_seen' 0; then
        printf 'still-null-empty\tpass\n'
    else
        printf 'still-null-empty\tfail\n'
    fi

    run_case "$s" unreadable
    if is '.default_branch_ci' null && is '.default_branch_runs_seen' null; then
        printf 'unreadable-recovery-is-unknown\tpass\n'
    else
        printf 'unreadable-recovery-is-unknown\tfail\n'
    fi

    run_case "$s" underivable
    if is '.default_branch_ci' null && is '.default_branch_runs_seen' null; then
        printf 'underivable-recovery-is-unknown\tpass\n'
    else
        printf 'underivable-recovery-is-unknown\tfail\n'
    fi

    run_case "$s" inflightsample
    if is '.default_branch_ci' null && is '.default_branch_runs_seen' 3; then
        printf 'still-null-all-in-flight\tpass\n'
    else
        printf 'still-null-all-in-flight\tfail\n'
    fi

    run_case "$s" recoveryfails
    if is '.default_branch_ci' null && is '.default_branch_runs_seen' 1; then
        printf 'failed-recovery-keeps-probe\tpass\n'
    else
        printf 'failed-recovery-keeps-probe\tfail\n'
    fi

    run_case "$s" mergegroup
    # Fixture adequacy: an EMPTY sample also yields null + 0, so without this the
    # row below passes against a fixture that shows nothing.
    printf 'mergegroup-sample-adequate\t%s\n' "$(verdict is '.runs_sampled' 1)"
    if is '.default_branch_ci' null && is '.default_branch_runs_seen' 0; then
        printf 'merge-group-cannot-satisfy-branch\tpass\n'
    else
        printf 'merge-group-cannot-satisfy-branch\tfail\n'
    fi

    run_case "$s" trunk
    # Nothing else in the matrix would notice a hardcoded "main": the recovery
    # must be scoped to the branch it derived against, which is what the
    # provenance note in the script rests on.
    if [ "$(flag_of "$(recovery_call)" --branch)" = "trunk" ] && is '.default_branch_ci' success; then
        printf 'recovery-branch-follows-default\tpass\n'
    else
        printf 'recovery-branch-follows-default\tfail\n'
    fi
}

# --- 1. behaviour -------------------------------------------------------------
echo "1. behaviour (skills/whats-on-fire/scripts/pull-repo-signals.sh)" >&2
BASELINE="$(matrix "$SCRIPT")"
while IFS="$(printf '\t')" read -r row res; do
    [ -z "$row" ] && continue
    if [ "$res" = "pass" ]; then ok "$row"; else bad "$row"; fi
done <<EOF
$BASELINE
EOF

# --- 2. mutation proof --------------------------------------------------------
# Reach is derived from re-running the matrix; MEMBERSHIP is declared, because
# reddened sets overlap and a shared red build cannot attribute the decision.
echo "2. mutation proof" >&2

GATE_LINE='if [[ "$(jq -r '"'"'.ci'"'"' <<<"$db_ci")" == "null" ]]; then'
REPO_LINE='if recovery=$(gh run list --repo "${ORG}/${repo}" --branch "$default_branch" \'
EVENT_LINE='--event push --status completed --limit 1 \'
JSON_LINE='        --json conclusion,status,workflowName,headBranch,url,createdAt,event 2>/dev/null) \'
KEY_LINE='          default_branch_runs_seen: $db_ci.runs_seen,'
AGE_LINE='          default_branch_ci_age_days: $db_ci.age_days,'
URL_LINE='          default_branch_ci_url: $db_ci.url,'
BRANCH_LINE='    map(select(.headBranch == $branch'
EVENT_RULE_LINE='               and (.event == "push" or .event == "merge_group"))) as $dbr'
DERIVE_CALL_LINE='        rec=$(derive_default_branch_ci "$recovery" "$default_branch")'
MERGE_ELSE_LINE='                      else $r.runs_seen end) }'"'"')'
NULL_AGE_LINE='        age_days: (if ($v.createdAt // null) == null then null'

# Both the anchor and the replacement travel through the ENVIRONMENT, never
# `awk -v`. `-v` applies escape processing to its value, and several of the
# strings below END IN A BACKSLASH because they are shell line continuations:
# BSD awk keeps that trailing backslash, gawk and mawk consume it. Under `-v`
# the mutants were therefore syntactically broken ON LINUX ONLY — every row in
# every mutant run reddened, each mutant "reached" everything, and the only
# thing that noticed was the unreached-set assertion going empty. ENVIRON values
# are not escape-processed. The `bash -n` check below is the second half: a
# mutant that does not parse scores nothing, and must say so in those words
# rather than as a set mismatch fifty lines later.
mutate() {  # 1: out path  2: match substring  3: replacement line
    MUT_M="$2" MUT_R="$3" awk \
        'index($0, ENVIRON["MUT_M"]) { print ENVIRON["MUT_R"]; next } { print }' \
        "$SCRIPT" >"$1"
}

# Each entry: <name> <anchor-var-name> <declared row it must redden>
mutate "$WORK/m-norecover.sh"       "$GATE_LINE"        '  if false; then'
mutate "$WORK/m-alwaysrecover.sh"   "$GATE_LINE"        '  if true; then'
mutate "$WORK/m-norepo.sh"          "$REPO_LINE"        '    if recovery=$(gh run list --branch "$default_branch" \'
mutate "$WORK/m-noevent.sh"         "$EVENT_LINE"       '        --status completed --limit 1 \'
mutate "$WORK/m-nostatus.sh"        "$EVENT_LINE"       '        --event push --limit 1 \'
mutate "$WORK/m-mergegroupevent.sh" "$EVENT_LINE"       '        --event push,merge_group --status completed --limit 1 \'
mutate "$WORK/m-trimjson.sh"        "$JSON_LINE"        '        --json conclusion,status 2>/dev/null) \'
mutate "$WORK/m-norunsseen.sh"      "$KEY_LINE"         ''
mutate "$WORK/m-noage.sh"           "$AGE_LINE"         '          default_branch_ci_age_days: null,'
mutate "$WORK/m-nourl.sh"           "$URL_LINE"         '          default_branch_ci_url: null,'
mutate "$WORK/m-ignorebranch.sh"    "$BRANCH_LINE"      '    map(select(true'
mutate "$WORK/m-ignoreevent.sh"     "$EVENT_RULE_LINE"  '               and (.event == "schedule"))) as $dbr'
mutate "$WORK/m-hardcodemain.sh"    "$DERIVE_CALL_LINE" '        rec=$(derive_default_branch_ci "$recovery" "main")'
mutate "$WORK/m-zeroonunknown.sh"   "$MERGE_ELSE_LINE"  '                      else ($r.runs_seen // 0) end) }'"'"')'
mutate "$WORK/m-zeroage.sh"         "$NULL_AGE_LINE"    '        age_days: (if ($v.createdAt // null) == null then 0'
# takerecovery makes the merge ignore the sample entirely, so a one-row recovery
# shrinks a count the sample really saw. Written on the guard, not the else arm.
SAMPLE_BOUND_LINE='          runs_seen: (if $s.runs_seen > 0'
mutate "$WORK/m-takerecovery.sh"    "$SAMPLE_BOUND_LINE" '          runs_seen: (if false'

# Anchor adequacy first: a drifted anchor makes its mutant a silent no-op, which
# reads as "the matrix does not reach it" rather than as a stale gate.
for a in "$GATE_LINE" "$REPO_LINE" "$EVENT_LINE" "$JSON_LINE" "$KEY_LINE" "$AGE_LINE" \
         "$URL_LINE" "$BRANCH_LINE" "$EVENT_RULE_LINE" "$DERIVE_CALL_LINE" \
         "$MERGE_ELSE_LINE" "$SAMPLE_BOUND_LINE" "$NULL_AGE_LINE"; do
    if ! grep -qF -- "$a" "$SCRIPT"; then
        bad "mutation anchor no longer present in the script: $a"
    fi
done

# name -> the row that mutant MUST redden. A mutant may redden more; it may
# never redden a different row INSTEAD, which is what makes a red build
# attributable to a decision.
declared_row() {
    case "$1" in
        norecover)       echo 'recovery-fires-on-null' ;;
        alwaysrecover)   echo 'no-redundant-call' ;;
        norepo)          echo 'recovery-query-shape' ;;
        noevent)         echo 'recovered-verdict' ;;
        nostatus)        echo 'recovery-skips-in-flight' ;;
        mergegroupevent) echo 'recovery-never-merge-group' ;;
        trimjson)        echo 'recovery-json-fidelity' ;;
        norunsseen)      echo 'still-null-empty' ;;
        noage)           echo 'recovered-verdict-age' ;;
        nourl)           echo 'recovered-verdict-url' ;;
        ignorebranch)    echo 'merge-group-cannot-satisfy-branch' ;;
        # The one-answer property: ONE rule change must reach BOTH paths.
        ignoreevent)     echo 'sample-verdict recovered-verdict' ;;
        hardcodemain)    echo 'recovery-branch-follows-default' ;;
        takerecovery)    echo 'still-null-all-in-flight' ;;
        zeroonunknown)   echo 'unreadable-recovery-is-unknown' ;;
        zeroage)         echo 'sample-undated-success sample-undated-failure recovered-undated-success recovered-undated-failure' ;;
    esac
}

reached=""
for m in norecover alwaysrecover norepo noevent nostatus mergegroupevent trimjson \
         norunsseen noage nourl ignorebranch ignoreevent hardcodemain takerecovery \
         zeroonunknown zeroage; do
    mfile="$WORK/m-$m.sh"
    if diff -q "$mfile" "$SCRIPT" >/dev/null 2>&1; then
        bad "mutant '$m' is byte-identical to the script — its anchor no longer matches"
        continue
    fi
    if ! bash -n "$mfile" 2>/dev/null; then
        bad "mutant '$m' does not parse — it scores nothing, and every row it reddens is an artefact of the broken copy"
        continue
    fi
    got="$(matrix "$mfile")"
    reddened="$(printf '%s\n' "$got" | awk -F'\t' '$2 == "fail" { print $1 }' | tr '\n' ' ')"
    if [ -z "$reddened" ]; then
        bad "mutant '$m' reddened NOTHING — the matrix does not reach it"
        continue
    fi
    reached="$reached $reddened"
    missing=""
    for want in $(declared_row "$m"); do
        case " $reddened " in
            *" $want "*) ;;
            *) missing="$missing $want" ;;
        esac
    done
    if [ -z "$missing" ]; then
        ok "mutant '$m' reddens $(declared_row "$m") as declared (flips: ${reddened% })"
    else
        bad "mutant '$m' does NOT redden$missing — it flips '${reddened% }'. Either the roster names the wrong row or the decision has stopped being load-bearing"
    fi
done

# The rows no mutant reaches must be exactly the declared fixture-adequacy
# preconditions. A precondition asserts the fixture can show the bug at all, so
# by construction the recovering code cannot change its verdict.
DECLARED_UNREACHED="mergegroup-sample-adequate sample-adequate"
all_rows="$(printf '%s\n' "$BASELINE" | awk -F'\t' '{ print $1 }' | sort)"
# shellcheck disable=SC2086  # deliberate word splitting: the accumulator is a space-separated list
reached_sorted="$(printf '%s\n' $reached | sort -u | grep -v '^$')"
unreached="$(comm -23 <(printf '%s\n' "$all_rows") <(printf '%s\n' "$reached_sorted") | tr '\n' ' ')"
# shellcheck disable=SC2086  # same
declared_sorted="$(printf '%s\n' $DECLARED_UNREACHED | sort | tr '\n' ' ')"
if [ "${unreached% }" = "${declared_sorted% }" ]; then
    ok "rows no mutant reaches == declared preconditions (${declared_sorted% })"
else
    bad "unreached rows '${unreached% }' != declared '${declared_sorted% }'"
fi

if [ "$fail" -ne 0 ]; then
    echo "test-repo-signals-recovery: FAILED" >&2
    exit 1
fi
echo "Repo-signals recovery tests: all green"
