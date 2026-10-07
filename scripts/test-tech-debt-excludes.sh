#!/usr/bin/env bash
# test-tech-debt-excludes.sh — pins how pull-tech-debt.sh consumes
# EXCLUDE_PATHSPECS (issue #365).
#
# THE FAILURE. setup-config's contract shipped `exclude_pathspecs` values
# already carrying `:(exclude)`, while pull-tech-debt.sh supplies that magic
# itself. The two halves were each internally consistent and disagreed with
# each other, so every repo configured per the contract handed git
# `:(exclude):(exclude)<path>` — a VALID pathspec whose pattern happens to
# begin with `:(exclude)`, matching nothing. git excludes nothing and exits 0.
#
# It is invisible in three separate ways, and each one dictates something about
# this gate:
#
#   1. git returns 0 or 1 for the malformed pathspec, never 128. So NO
#      assertion here may key on an exit code — an exit-code check passes
#      against the broken script and proves nothing.
#   2. pull-tech-debt.sh wraps every git grep in `2>/dev/null | head -N ||
#      true`, so even a real error is swallowed before a caller could see it.
#      Only the emitted OUTPUT SET distinguishes a working exclusion from a
#      disabled one, so that is what every row below reads.
#   3. It only ADDS results. A scan that should report 4 markers reports 5 —
#      plausible either way, and the extra one sits in a directory the reader
#      was told is excluded. Nothing is red anywhere; the plate is just wrong.
#
# THE FIX BEING PINNED, and the part that reads like an inconsistency. The
# script strips AT MOST ONE leading `:(exclude)` before re-prefixing, so both
# spellings land on the same pathspec and every config already written keeps
# working with no migration. A GREEDY strip would also "work" and is the
# tempting simplification — it is refused on purpose, and row
# `doubled-stays-broken` is what refuses it: a genuinely doubled value is a
# different config error, and silently repairing it hides a mistake this gate
# would otherwise be the only thing able to see. So the doubled input is
# asserted to STILL LEAK. That row failing is the signal that someone widened
# the strip, not that the fix regressed.
#
# WHAT BOUNDS THE STRIP is the pattern, not the sigil. `${p#':(exclude)'}` is
# quoted, so it is a glob-free literal admitting exactly one match length;
# `${p##':(exclude)'}` yields the same result. Do not "harden" this by swapping
# sigils — the greedy shape that row `doubled-stays-broken` exists to refuse is
# a substitution like `${p//:(exclude)/}`, which is what the `greedy` mutant
# writes.
#
# AN UNUSABLE ELEMENT IS DROPPED, NOT PASSED THROUGH, and this is the half that
# fails toward suppression rather than noise. `:(exclude)` alone strips to the
# empty string, and re-prefixing that yields a bare `:(exclude)` — an empty
# pattern git honours as "exclude the ENTIRE tree". One stray token therefore
# reported zero tech debt at exit 0, which `survey-work` renders as "no debt".
# It is reachable without hostility: converting a prefixed value to bare by
# inserting a space rather than deleting the prefix yields two words, and the
# first blacks out the scan. A remainder still beginning with `:` is refused
# the same way, since `:!path` would re-prefix to a silent no-op. Rows
# `lone-prefix-token-ignored` and `doubled-stays-broken` are the pair: an
# unusable element must leave the scan EXACTLY as an unconfigured one does.
#
# VALUES REACH GIT LITERALLY, and the `set -f` fence around the loop is load-
# bearing rather than defensive. `for p in ${EXCLUDE_PATHSPECS:-}` both
# word-splits AND pathname-expands, so without the fence the two spellings
# genuinely diverge: bash expands the bare `generated/**` (skipping dotfiles,
# leaking `generated/.hidden.txt`) while it cannot expand
# `:(exclude)generated/**`, so git sees the literal. Row
# `glob-spellings-identical` carries a hidden file for exactly that reason.
#
# CANONICAL SPELLING is bare. Three tracked sites teach it and this gate pins
# two of them by content — config-contract.md's survey-work example, which is
# the one that carried the prefixed form, plus a tree-wide scan asserting NO
# tracked file teaches the prefixed spelling again. detection.md (the
# generation site) and repo-health/SKILL.md were also edited alongside, for
# prose the tree-wide scan covers rather than a spelling of their own.
# SCAN_PATHS is deliberately out of scope: the `**`-needs-`:(glob)` claim it
# would rest on did not reproduce when tested on 2026-09-07 or again on this
# branch, so it needs verification rather than a fix. Nothing here touches it,
# and the stale claim is annotated in place in the script header rather than
# silently left to contradict this one.
#
# THE BUILT-IN EXCLUDES ARE PINNED TOO, and the lockfile ones needed widening
# (issue #372). They shipped as `:(exclude)**/*.lock`, and a leading `**/`
# demands a literal `/` in the path — so the pattern matched `sub/bun.lock` and
# NEVER a root-level `bun.lock`, which is the location a lockfile actually
# occupies in the repos this scans. Every marker inside a root lockfile was
# reported as that repo's own tech debt, by the exclusion written to suppress
# exactly that. The fix is the BARE `*.lock`: without `:(glob)` magic a pathspec
# `*` matches `/` too, so the bare form is a strict SUPERSET of the `**/` one,
# covering root, nested, deep and dot-directory lockfiles alike. Two rows hold
# the two locations apart on purpose — `root-lockfiles-excluded` reads all three
# extensions at the root, and `builtins-hold` keeps the nested one, so a later
# "widening" that trades one location for the other reddens rather than passing.
# Both read the OUTPUT SET for the reason in point 1 above: git returns 0 or 1
# for these pathspecs, never 128, so an exit-code assertion would pass against
# the broken pattern and prove nothing.
#
# FIXTURES, both of them adequacy-checked rather than assumed:
#
#   * A scratch git repo under mktemp carries the behavioural matrix — small,
#     deterministic, and immune to this checkout's own contents changing.
#     Its markers are ASSEMBLED AT RUNTIME rather than written literally, so
#     this gate does not itself show up as debt in the scan it tests. It carries
#     lockfiles at BOTH the root and one directory down, because the two
#     locations are matched by different pathspec shapes (#372) and a fixture
#     holding only one of them cannot tell the two apart.
#   * The live checkout carries the issue's own reproduction. The excluded
#     directory is DERIVED from an unfiltered scan rather than hard-coded, so
#     the row can never go vacuous and no unrelated edit that removes markers
#     from one particular directory can redden it. If the tree carries no
#     markers under `skills/` at all, `live-baseline-has-markers` fails loudly
#     rather than passing over an empty set.
#
# MUTATION PROOF. The matrix is a function of the script path, so it is re-run
# against seven mutated copies and the reach is DERIVED from the verdicts rather
# than asserted in prose: no-strip (the pre-fix line), greedy-strip, a removed
# unusable-element guard, a removed `set -f` fence, a dropped built-in exclude,
# a disabled user-exclude loop, and the root-lockfile pattern reverted to the
# `**/` spelling that shipped. Every mutant must redden at least one row,
# and the rows no mutant reaches must equal the declared set — which holds
# exactly the two fixture-adequacy preconditions, since a precondition is by
# construction not sensitive to the excluding code.
#
# Copies and scratch repos only: no gh, no network, no mutation of this
# checkout. A LOCAL `git init` fixture built with GIT_CONFIG_GLOBAL=/dev/null,
# GIT_CONFIG_NOSYSTEM=1 and `add -A -f`, so a contributor's global
# `core.excludesFile` or `init.templateDir` cannot leave fixture files unstaged
# — which would make every row here vacuous locally while CI stayed green.
# `mktemp -d` is checked: `set -u` does not fire on empty-but-set, so an
# unchecked failure would point the fixture at the filesystem root.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-tech-debt-excludes.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-tech-debt-excludes: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SCRIPT="$REPO_ROOT/skills/repo-health/scripts/pull-tech-debt.sh"
CONTRACT="$REPO_ROOT/skills/setup-config/references/config-contract.md"
[ -f "$SCRIPT" ] || { echo "test-tech-debt-excludes: $SCRIPT not found" >&2; exit 1; }

WORK="$(mktemp -d)" || { echo "test-tech-debt-excludes: mktemp -d failed" >&2; exit 1; }
# Fail closed rather than continuing with an empty WORK: `set -u` does not fire
# on empty-but-set, and every path below would then resolve against `/`.
case "$WORK" in
    /*) : ;;
    *) echo "test-tech-debt-excludes: mktemp -d gave no absolute path ('$WORK')" >&2; exit 1 ;;
esac
[ -d "$WORK" ] || { echo "test-tech-debt-excludes: '$WORK' is not a directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "tech-debt exclude tests (work: $WORK)" >&2

# --- the scratch fixture ------------------------------------------------------
# Markers are assembled at runtime (see header). `git add` alone makes a file
# tracked as far as `git grep` is concerned, so no commit and no identity are
# needed. There is one lockfile ONE DIRECTORY DOWN and three AT THE ROOT, and
# the split is the point rather than duplication: the built-in exclude shipped
# as `:(exclude)**/*.lock`, which needs a literal `/` to match, so only the
# nested file was ever excluded and the root case — the common one in real repos
# — went untested (#372). Keep both locations: the nested file is what would
# catch a later "fix" that traded one for the other, and the three root files
# are one per lockfile pathspec, so the row below is sensitive to each of the
# three individually. `generated/.hidden.txt` is a DOTFILE on purpose: shell
# pathname expansion skips it while a git pathspec does not, which is the only
# thing that distinguishes a fenced loop from an unfenced one.
MARK="TO""DO"
FIXTURE="$WORK/fixture"
mkdir -p "$FIXTURE/src" "$FIXTURE/docs" "$FIXTURE/generated" \
         "$FIXTURE/.claude" "$FIXTURE/packages"
printf '%s: real work\n'       "$MARK" >"$FIXTURE/src/app.txt"
printf '%s: docs debt\n'       "$MARK" >"$FIXTURE/docs/notes.txt"
printf '%s: generated noise\n' "$MARK" >"$FIXTURE/generated/gen.txt"
printf '%s: generated hidden\n' "$MARK" >"$FIXTURE/generated/.hidden.txt"
printf '%s: agent noise\n'     "$MARK" >"$FIXTURE/.claude/agent.txt"
printf '%s: lockfile noise\n'  "$MARK" >"$FIXTURE/packages/bun.lock"
# The root lockfiles (#372). Their marker text is distinct from the nested
# file's, because the rows below read CONTENT: a path substring like `bun.lock`
# matches `packages/bun.lock` too, and a row that cannot tell the two apart is
# the one shape this fixture exists to refuse.
printf '%s: root lockfile noise\n'       "$MARK" >"$FIXTURE/bun.lock"
printf '%s: root lock-dot-json noise\n'  "$MARK" >"$FIXTURE/deps.lock.json"
printf '%s: root dash-lock-json noise\n' "$MARK" >"$FIXTURE/package-lock.json"
# The contributor's own git config must not reach this fixture: a global
# `core.excludesFile` leaves files unstaged, `git grep` then sees an empty tree,
# and every row below passes over nothing while CI stays green. Same trap the
# repo already pins in test-detect-capabilities.sh and test-platform-health-probe.sh.
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$FIXTURE" init -q >/dev/null 2>&1
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$FIXTURE" add -A -f >/dev/null 2>&1
staged="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$FIXTURE" ls-files | grep -c .)"
if [ "$staged" -ne 9 ]; then
    echo "  FAIL  fixture staged $staged of 9 files — the matrix below would be vacuous" >&2
    echo "test-tech-debt-excludes: FAILED" >&2
    exit 1
fi

# --- helpers ------------------------------------------------------------------
# Feed the value directly: even a materialized shell variable can exceed the
# pipe buffer, letting `grep -q` close early and turn `printf`'s SIGPIPE into a
# false miss under pipefail (main CI after PR #481).
has()   { grep -qF -- "$2" <<<"$1"; }
hasnt() { if has "$1" "$2"; then return 1; fi; return 0; }
same()  { [ "$1" = "$2" ]; }
verdict() { if "$@"; then echo pass; else echo fail; fi; }

run_fixture() {  # $1 = script path, $2 = EXCLUDE_PATHSPECS value
    ( cd "$FIXTURE" && SCAN_PATHS="." EXCLUDE_PATHSPECS="$2" bash "$1" 2>/dev/null )
}
run_live() {     # $1 = script path, $2 = EXCLUDE_PATHSPECS value
    ( cd "$REPO_ROOT" && SCAN_PATHS="skills" EXCLUDE_PATHSPECS="$2" bash "$1" 2>/dev/null )
}

# An early match in a value larger than a pipe buffer must stay a match. This
# catches the former printf pipeline without depending on the live doc's size
# or on the scheduler race that made the same checkout pass PR and queue CI.
printf -v match_fixture 'present\n%1048576s' ''
if has "$match_fixture" present; then
    ok "an early match in a large value is not lost under pipefail"
else
    bad "an early match in a large value became a false miss under pipefail"
fi
unset match_fixture

# --- derive the live fixture's excluded directory -----------------------------
# Taken from the REAL script's unfiltered scan, never from a mutant, so every
# matrix run scores the same subject. First marker path, first two components.
live_base="$(run_live "$SCRIPT" "")"
LIVE_DIR="$(printf '%s\n' "$live_base" \
    | awk -F: '/^skills\// { print $1; exit }' \
    | awk -F/ 'NF>=2 { print $1 "/" $2 }')"
if [ -z "$LIVE_DIR" ]; then
    echo "  FAIL  no markers found anywhere under skills/ — the live reproduction cannot run" >&2
    echo "test-tech-debt-excludes: FAILED (1)" >&2
    exit 1
fi
echo "  ..    live reproduction directory: $LIVE_DIR" >&2

# --- the matrix ---------------------------------------------------------------
# Emits one `<row-id><TAB>pass|fail` line per row. A function of the script
# path so the mutants below are scored by exactly this code.
matrix() {
    local s="$1"
    local base bare pref dbl mixed lone gbare gpref lbase lbare lpref
    base="$(run_fixture  "$s" "")"
    bare="$(run_fixture  "$s" "generated")"
    pref="$(run_fixture  "$s" ":(exclude)generated")"
    dbl="$(run_fixture   "$s" ":(exclude):(exclude)generated")"
    mixed="$(run_fixture "$s" "generated :(exclude)docs")"
    lone="$(run_fixture  "$s" ":(exclude)")"
    gbare="$(run_fixture "$s" "generated/**")"
    gpref="$(run_fixture "$s" ":(exclude)generated/**")"
    lbase="$live_base"
    lbare="$(run_live "$s" "$LIVE_DIR")"
    lpref="$(run_live "$s" ":(exclude)$LIVE_DIR")"

    # Fixture adequacy: with nothing excluded the marker under generated/ must
    # be visible, or every "absent" row below is trivially satisfiable.
    printf 'baseline-leaks\t%s\n' \
        "$(verdict has "$base" 'generated/gen.txt')"
    printf 'bare-excludes\t%s\n' \
        "$(verdict hasnt "$bare" 'generated/')"
    printf 'prefixed-excludes\t%s\n' \
        "$(verdict hasnt "$pref" 'generated/')"
    printf 'spellings-identical\t%s\n' \
        "$(verdict same "$bare" "$pref")"
    # The refusal to strip greedily: a doubled value stays visibly broken.
    printf 'doubled-stays-broken\t%s\n' \
        "$(verdict has "$dbl" 'generated/gen.txt')"
    # A lone `:(exclude)` strips to empty; re-prefixed it is an empty pattern
    # git reads as "exclude everything". It must be dropped, leaving the scan
    # byte-identical to an unconfigured one — NOT merely "non-empty", which a
    # partially-applied exclusion would also satisfy.
    printf 'lone-prefix-token-ignored\t%s\n' \
        "$(verdict same "$lone" "$base")"
    # The `set -f` fence: a `**` value must reach git literally, so the two
    # spellings agree even on the dotfile shell expansion would have skipped.
    if hasnt "$gbare" 'generated/' && same "$gbare" "$gpref"; then
        printf 'glob-spellings-identical\tpass\n'
    else
        printf 'glob-spellings-identical\tfail\n'
    fi
    # Per-item handling: one list may mix the two spellings.
    if hasnt "$mixed" 'generated/' && hasnt "$mixed" 'docs/' && has "$mixed" 'src/app.txt'; then
        printf 'mixed-list\tpass\n'
    else
        printf 'mixed-list\tfail\n'
    fi
    # The built-in excludes are not collateral damage of the user-exclude loop.
    # `packages/bun.lock` is the NESTED lockfile: this row is the no-regression
    # half of the pair `root-lockfiles-excluded` completes.
    if hasnt "$base" '.claude/agent.txt' && hasnt "$base" 'packages/bun.lock'; then
        printf 'builtins-hold\tpass\n'
    else
        printf 'builtins-hold\tfail\n'
    fi
    # The built-in lockfile excludes must reach the ROOT, not only one directory
    # down (#372). All three extensions, because each is its own pathspec and a
    # revert of any one of them must redden this row.
    if hasnt "$base" 'root lockfile noise' \
        && hasnt "$base" 'root lock-dot-json noise' \
        && hasnt "$base" 'root dash-lock-json noise'; then
        printf 'root-lockfiles-excluded\tpass\n'
    else
        printf 'root-lockfiles-excluded\tfail\n'
    fi
    # The issue's own reproduction, against this checkout.
    printf 'live-baseline-has-markers\t%s\n' \
        "$(verdict has "$lbase" "$LIVE_DIR/")"
    if hasnt "$lbare" "$LIVE_DIR/" && hasnt "$lpref" "$LIVE_DIR/" && same "$lbare" "$lpref"; then
        printf 'live-both-spellings-clean\tpass\n'
    else
        printf 'live-both-spellings-clean\tfail\n'
    fi
}

# --- 1. the real script: every row green --------------------------------------
echo "1. behaviour (scripts/../pull-tech-debt.sh)" >&2
BASELINE="$(matrix "$SCRIPT")"
while IFS="$(printf '\t')" read -r row res; do
    [ -z "$row" ] && continue
    if [ "$res" = "pass" ]; then ok "$row"; else bad "$row"; fi
done <<EOF
$BASELINE
EOF

# --- 2. mutation proof --------------------------------------------------------
# Each mutant rewrites ONE line of a copy. Reach is derived from re-running the
# same matrix, never asserted in prose.
echo "2. mutation proof" >&2

STRIP_LINE='q="${p#'
GUARD_LINE='if [ -z "$q" ] || [ "${q#:}" != "$q" ]; then'
APPEND_LINE='EXCLUDES+=(":(exclude)$q")'
BUILTIN_LINE=':(exclude).claude/**'
FENCE_LINE='set -f'
ROOTLOCK_LINE="  ':(exclude)*.lock'"

mutate() {  # $1 = out path, $2 = match substring, $3 = replacement line
    awk -v m="$2" -v r="$3" 'index($0, m) { print r; next } { print }' "$SCRIPT" >"$1"
}
mutate_exact() {  # $1 = out path, $2 = WHOLE line to match, $3 = replacement
    awk -v m="$2" -v r="$3" '$0 == m { print r; next } { print }' "$SCRIPT" >"$1"
}

# no-strip: the pre-fix behaviour, which double-prefixes every configured value.
mutate "$WORK/m-nostrip.sh" "$STRIP_LINE" '  q="$p"'
# greedy-strip: `//` removes EVERY occurrence, silently repairing a doubled value.
mutate "$WORK/m-greedy.sh" "$STRIP_LINE" '  q="${p//:(exclude)/}"'
# no-guard: an unusable element is passed to git instead of being dropped, so a
# lone `:(exclude)` becomes an empty pattern and blacks out the whole scan.
mutate "$WORK/m-noguard.sh" "$GUARD_LINE" '  if false; then'
# no-loop: the user-exclude loop stops appending anything.
mutate "$WORK/m-noloop.sh" "$APPEND_LINE" '  :'
# no-builtin: one of the always-on excludes is dropped from the array.
mutate "$WORK/m-nobuiltin.sh" "$BUILTIN_LINE" '  # built-in removed by mutant'
# no-fence: the loop pathname-expands again, so bare and prefixed globs diverge.
# Anchored on the WHOLE line: the header prose quotes `set -f` too.
mutate_exact "$WORK/m-nofence.sh" "$FENCE_LINE" ':'
# no-rootlock: the pre-fix `**/` spelling of the built-in `*.lock` exclude, which
# only ever matched a lockfile one directory down (#372). Anchored on the WHOLE
# line, because `':(exclude)*.lock.json'` is a different pattern on the next one.
mutate_exact "$WORK/m-norootlock.sh" "$ROOTLOCK_LINE" "  ':(exclude)**/*.lock'"

# Anchor adequacy first: an anchor that has drifted makes its mutant a silent
# no-op, which reads as "the matrix does not reach it" rather than as a stale
# gate. Checked per anchor rather than for the strip line alone.
for a in "$STRIP_LINE" "$GUARD_LINE" "$APPEND_LINE" "$BUILTIN_LINE" "$FENCE_LINE" \
         "$ROOTLOCK_LINE"; do
    if ! grep -qF -- "$a" "$SCRIPT"; then
        bad "mutation anchor no longer present in the script: $a"
    fi
done

reached=""
for m in nostrip greedy noguard noloop nobuiltin nofence norootlock; do
    mfile="$WORK/m-$m.sh"
    if diff -q "$mfile" "$SCRIPT" >/dev/null 2>&1; then
        bad "mutant '$m' is byte-identical to the script — its anchor no longer matches"
        continue
    fi
    got="$(matrix "$mfile")"
    reddened="$(printf '%s\n' "$got" | awk -F'\t' '$2 == "fail" { print $1 }' | tr '\n' ' ')"
    if [ -z "$reddened" ]; then
        bad "mutant '$m' reddened NOTHING — the matrix does not reach it"
    else
        ok "mutant '$m' reddened: ${reddened% }"
        reached="$reached $reddened"
    fi
done

# The rows no mutant reaches must be exactly the declared fixture-adequacy
# preconditions. A precondition asserts the fixture is capable of showing the
# bug, so by construction the excluding code cannot change its verdict.
DECLARED_UNREACHED="baseline-leaks live-baseline-has-markers"
all_rows="$(printf '%s\n' "$BASELINE" | awk -F'\t' '{ print $1 }' | sort)"
reached_sorted="$(printf '%s\n' $reached | sort -u | grep -v '^$')"
unreached="$(comm -23 <(printf '%s\n' "$all_rows") <(printf '%s\n' "$reached_sorted") | tr '\n' ' ')"
declared_sorted="$(printf '%s\n' $DECLARED_UNREACHED | sort | tr '\n' ' ')"
if [ "${unreached% }" = "${declared_sorted% }" ]; then
    ok "rows no mutant reaches == declared preconditions (${declared_sorted% })"
else
    bad "unreached rows '${unreached% }' != declared '${declared_sorted% }'"
fi

# --- 3. source and docs -------------------------------------------------------
echo "3. source and docs" >&2

header="$(sed -n '1,45p' "$SCRIPT")"
if has "$header" 'canonical spelling is BARE' && has "$header" 'ALSO accepted'; then
    ok "the script header names bare as canonical and records that both spellings are accepted"
else
    bad "the script header no longer states the two-spelling contract — a reader cannot tell which form to write"
fi
if has "$header" 'At most ONE prefix is stripped'; then
    ok "the header records that the strip is bounded, not greedy"
else
    bad "the header lost the at-most-one rule that doubled-stays-broken enforces"
fi
# The drop rule is the half that fails toward suppression, so the header must
# say the element is dropped AND why: a bare `:(exclude)` excludes everything.
if has "$header" 'is DROPPED' && has "$header" 'exclude the entire tree'; then
    ok "the header records that an unusable element is dropped, and what it would otherwise do"
else
    bad "the header lost the drop rule or its consequence — the reason lone-prefix-token-ignored exists"
fi
# The `**`/`:(glob)` claim contradicted this gate's own finding. It must stay
# annotated in place rather than being left to read as fact.
if has "$header" 'NOTE, unverified' && has "$header" 'did not reproduce'; then
    ok "the stale :(glob) claim is annotated in place rather than contradicting this gate"
else
    bad "the script header asserts the :(glob) claim as fact again — it did not reproduce"
fi

# The doc site that carried the prefixed form. Searched tree-wide, not at a line number: the
# point is that NO tracked file teaches the prefixed spelling again. THIS FILE
# is in that corpus, so the pattern is assembled from two pieces rather than
# written out — the alternative is exempting this path, which would leave the
# gate blind to the one file most likely to grow a copy of the bad spelling.
prefixed_form='exclude_pathspecs: ":'"(exclude)"
# Point it at a known positive first: an assembled pattern that quietly stops
# matching would report a clean tree forever.
printf '%s%s\n' "$prefixed_form" 'packages/db/src/migrations"' >"$WORK/badspelling.txt"
if grep -qF -e "$prefixed_form" "$WORK/badspelling.txt"; then
    ok "the prefixed-form pattern matches a line that carries it"
else
    bad "the prefixed-form pattern matches nothing — the tree-wide scan below is vacuous"
fi
prefixed_docs="$(git -C "$REPO_ROOT" grep -lIF -e "$prefixed_form" || true)"
if [ -z "$prefixed_docs" ]; then
    ok "no tracked file writes exclude_pathspecs in the prefixed form"
else
    bad "prefixed exclude_pathspecs still taught in: $(printf '%s' "$prefixed_docs" | tr '\n' ' ')"
fi
if has "$(cat "$CONTRACT")" 'exclude_pathspecs: "packages/db/src/migrations"'; then
    ok "config-contract.md's survey-work example spells the bare form"
else
    bad "config-contract.md's survey-work exclude_pathspecs example is gone or changed shape"
fi

# The built-in lockfile spelling (#372) and the reason beside it. The
# behavioural row reddens on a reverted pattern; these two rows are what stop
# the REASON being deleted as noise, which is how the `**/` form comes back —
# it reads as the more thorough spelling to anyone who has not measured it. The
# negative half is a WHOLE-FILE scan, so the old spelling must not be quoted
# anywhere in the script, its own prose included; that history lives in this
# gate's header instead, which is not in the scanned corpus.
script_all="$(cat "$SCRIPT")"
if has "$script_all" "':(exclude)*.lock'" && hasnt "$script_all" "':(exclude)**/*.lock'"; then
    ok "the built-in lockfile excludes are spelled bare, so they reach a root lockfile"
else
    bad "a built-in lockfile exclude is back to the '**/' form, which never matches a root lockfile (#372)"
fi
if has "$script_all" 'requires a literal `/`' && has "$script_all" 'issue #372'; then
    ok "the script records why the lockfile excludes are bare rather than '**/'-prefixed"
else
    bad "the script lost the note explaining why the lockfile excludes are bare — the '**/' form reads as more thorough"
fi

# SCAN_PATHS is out of scope for issue #365 and must stay that way: the
# `:(glob)` claim it would rest on did not reproduce. This row fails if a later
# change quietly rewrites SCAN_PATHS while "fixing excludes".
if grep -qF -- 'SCAN=(${SCAN_PATHS:-.})' "$SCRIPT"; then
    ok "SCAN_PATHS handling is unchanged (out of scope, deliberately)"
else
    bad "SCAN_PATHS handling changed — #365 decided that needs verification, not a fix"
fi

if [ "$fail" -ne 0 ]; then
    echo "test-tech-debt-excludes: FAILED" >&2
    exit 1
fi
echo "Tech-debt exclude tests: all green"
