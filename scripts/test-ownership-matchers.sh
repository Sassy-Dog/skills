#!/usr/bin/env bash
# test-ownership-matchers.sh — proves the setup-hooks / setup-deps ownership
# matchers against REAL pre-rename artifacts, not synthetic patterns (issue
# #133, epic #120), and that setup-config's two producer-name lists (SKILL.md's
# marker-recognition paragraph and update-mode.md's "Recognising prior
# producers" list) each still name every producer once (issue #612; see the
# last section below).
#
# Why this exists: the ownership contract is report-and-skip, not error. A
# marker the matcher fails to recognise makes the file "hand-written", so a
# narrowed matcher does not throw, does not fail CI, and prints no warning —
# it silently stops reconciling generated files in every consumer repo, and
# the first symptom is a repo that quietly stopped receiving updates.
#
# Two properties are asserted, and both are load-bearing:
#
#   1. The regexes are EXTRACTED from the shipped SKILL.md files at run time.
#      A test carrying its own transcription would prove only that the copy
#      agrees with itself, and would keep passing after the shipped matcher
#      was narrowed — which is exactly the regression this guards.
#   2. Each fixture's body is byte-verbatim upstream, proven by hashing it and
#      comparing against the source blob SHA recorded in its provenance
#      header. That is what makes these real artifacts rather than fixtures
#      someone hand-tuned until the test went green.
#
# Fixtures live in scripts/fixtures/legacy-markers/ as a provenance header
# (source repo, path, fetch date, blob SHA, expected classification) followed
# by a delimiter and the verbatim upstream bytes. They are deliberately NOT
# named *.sh — preflight's shellcheck gate globs `git ls-files '*.sh'`, and
# linting a snapshot of a consumer's file would couple this repo's CI to it.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-ownership-matchers.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-ownership-matchers: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

FIXTURE_DIR="scripts/fixtures/legacy-markers"
HOOKS_SKILL="skills/setup-hooks/SKILL.md"
DEPS_SKILL="skills/setup-deps/SKILL.md"
DELIMITER='^# ---8<---'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "ownership-matcher tests (work: $WORK)" >&2

# --- extract the shipped matchers -------------------------------------------
# The regex is documented as a lone fenced line in each SKILL.md. Match on its
# SHAPE (`generated-by: (...)`) rather than its contents, so widening or
# reordering the alternation is picked up automatically and only a structural
# rewrite of the skill needs a change here.
extract_matcher() { # extract_matcher <skill-md>
    sed -n 's/^[[:space:]]*\(generated-by: (.*)\)[[:space:]]*$/\1/p' "$1"
}

load_matcher() { # load_matcher <label> <skill-md>  -> prints the regex, or fails
    local label="$1" skill="$2" found count
    found=$(extract_matcher "$skill")
    count=$(printf '%s' "$found" | grep -c . )
    if [ "$count" -ne 1 ]; then
        bad "$label matcher extraction — expected exactly 1 'generated-by: (...)' line in $skill, found $count"
        return 1
    fi
    ok "$label matcher extracted from $skill"
    printf '%s' "$found"
}

HOOKS_PAT=$(load_matcher "setup-hooks" "$HOOKS_SKILL") || HOOKS_PAT=''
DEPS_PAT=$(load_matcher "setup-deps" "$DEPS_SKILL") || DEPS_PAT=''
if [ -z "$HOOKS_PAT" ] || [ -z "$DEPS_PAT" ]; then
    echo "ownership-matcher tests: cannot run without both matchers" >&2
    exit 1
fi

# --- fixtures ----------------------------------------------------------------
# Assert the fixture set is non-empty FIRST. A glob that matches nothing would
# otherwise walk zero fixtures and report all-green while covering nothing —
# the same silent-pass trap the positional-token guard hit in preflight.sh.
fixtures=$(git ls-files "$FIXTURE_DIR/*.fixture")
if [ -z "$fixtures" ]; then
    bad "fixture set — no tracked *.fixture files under $FIXTURE_DIR (moved or renamed? the run would pass while covering nothing)"
    echo "ownership-matcher tests: FAILURES above" >&2
    exit 1
fi

# classify <regex> <file>  -> owned | hand-written
classify() {
    if grep -qE "$1" "$2"; then echo "owned"; else echo "hand-written"; fi
}

owned_count=0
control_count=0

while IFS= read -r fixture; do
    name="${fixture##*/}"

    delim=$(grep -n "$DELIMITER" "$fixture" | head -n1 | cut -d: -f1)
    if [ -z "$delim" ]; then
        bad "$name — no verbatim-bytes delimiter; cannot separate provenance header from upstream body"
        continue
    fi

    head -n "$delim" "$fixture" > "$WORK/header"
    tail -n +"$((delim + 1))" "$fixture" > "$WORK/body"

    field() { sed -n "s/^# fixture-$1: //p" "$WORK/header" | head -n1; }
    repo=$(field "source-repo")
    path=$(field "source-path")
    blob=$(field "blob-sha")
    matcher=$(field "matcher")
    expect=$(field "expect")

    if [ -z "$repo" ] || [ -z "$path" ] || [ -z "$blob" ] || [ -z "$matcher" ] || [ -z "$expect" ]; then
        bad "$name — incomplete provenance header (need source-repo, source-path, blob-sha, matcher, expect)"
        continue
    fi

    # Byte fidelity: the body must still hash to the upstream blob it was
    # fetched from, so nobody can quietly edit a fixture into passing.
    actual=$(git hash-object "$WORK/body")
    if [ "$actual" = "$blob" ]; then
        ok "$name — body is byte-verbatim $repo:$path ($blob)"
    else
        bad "$name — body no longer hashes to the recorded upstream blob (expected $blob, got $actual)"
    fi

    case "$matcher" in
        hooks) own_pat="$HOOKS_PAT"; other_pat="$DEPS_PAT"; other_label="setup-deps" ;;
        deps)  own_pat="$DEPS_PAT";  other_pat="$HOOKS_PAT"; other_label="setup-hooks" ;;
        *) bad "$name — unknown fixture-matcher '$matcher' (expected 'hooks' or 'deps')"; continue ;;
    esac

    got=$(classify "$own_pat" "$WORK/body")
    if [ "$got" = "$expect" ]; then
        ok "$name — classified $got by the shipped setup-$matcher matcher"
    else
        bad "$name — shipped setup-$matcher matcher classified it '$got', expected '$expect' (a report-and-skip contract makes this failure silent in production)"
    fi

    # Cross-family: one generator must never claim the other's artifacts.
    cross=$(classify "$other_pat" "$WORK/body")
    if [ "$cross" = "hand-written" ]; then
        ok "$name — not claimed by the $other_label matcher"
    else
        bad "$name — the $other_label matcher also claims it; the two ownership patterns overlap"
    fi

    if [ "$expect" = "owned" ]; then
        owned_count=$((owned_count + 1))
    else
        control_count=$((control_count + 1))
    fi
done <<< "$fixtures"

# --- corpus coverage ---------------------------------------------------------
# Count DISTINCT marker strings the shipped patterns match across the fixture
# bodies. Derived from the fixtures rather than listed here, so this count stays
# honest without a transcription (the setup-config section below is the one place
# that carries a producer set, because that set is the contract it tests).
distinct=$(git ls-files "$FIXTURE_DIR/*.fixture" \
    | xargs grep -hoE "$HOOKS_PAT|$DEPS_PAT" \
    | sort -u | grep -c .)
if [ "$distinct" -ge 3 ]; then
    ok "corpus coverage — $distinct distinct real marker forms exercised"
else
    bad "corpus coverage — only $distinct distinct marker forms; the live corpus has 3 (issue #133)"
fi

if [ "$owned_count" -ge 3 ]; then
    ok "owned fixtures — $owned_count"
else
    bad "owned fixtures — $owned_count, expected at least 3"
fi

if [ "$control_count" -ge 1 ]; then
    ok "negative controls — $control_count real unmarked artifact(s)"
else
    bad "negative controls — none; at least one real unmarked artifact is required"
fi

# --- setup-config's recognizer lists (issue #612) ------------------------------
# setup-config names the producers it still recognises in TWO places, and the
# recognition is report-and-skip like the matchers above: a repo stamped by a
# producer the lists no longer name falls through to adopt or create mode and its
# config is silently lost. #414's mechanical rename turned one producer name into
# another in BOTH lists, so each then named the same producer twice and the
# original not at all, and CI stayed green for months.
#
# Each list is EXTRACTED from the shipped file at run time by its SHAPE, so
# reordering or rewording it needs no change here:
#   - SKILL.md: the paragraph headed "Marker recognition accepts every producer
#     name." (a name is a backticked token followed by " ("), and
#   - update-mode.md: the bullet list under "## Recognising prior producers"
#     (a name is the backticked token opening a "- " bullet).
# What this file DOES carry is the producer set itself (REQUIRED_PRODUCERS): that
# is the contract under test, a fixed history that `generated-by:` markers
# committed in consumer repos already depend on, and the producer names are
# sanctioned in this file by scripts/check-legacy-names.sh for that reason. Each
# list must name each required producer EXACTLY once. A name missing, a name
# twice and a list that extracts empty are three separate failures in the code;
# the mutants below prove each list goes red on a rewrite (a name both lost and
# doubled), on a drop, and on an empty extraction, by red/green and not by message.
# NOT checked: that the surrounding prose is accurate, or that setup-config
# stays absent from the lists (its own paragraph states that; no gate pins it).
REQUIRED_PRODUCERS="refresh-skills refresh-sassydog-skills create-dev-workflows"
CONFIG_SKILL="skills/setup-config/SKILL.md"
CONFIG_UPDATE="skills/setup-config/references/update-mode.md"

skill_producers() { # skill_producers <SKILL.md> -> one producer name per line
    awk '
        /^\*\*Marker recognition accepts every producer name\.\*\*/ { inp = 1 }
        inp && /^[[:space:]]*$/ { exit }
        inp { print }
    ' "$1" | grep -oE '`[a-z][a-z0-9-]*` \(' | tr -d '` ('
}
update_producers() { # update_producers <update-mode.md> -> one producer name per line
    awk '
        /^## Recognising prior producers[[:space:]]*$/ { ins = 1; next }
        ins && /^## / { exit }
        ins { print }
    ' "$1" | sed -n 's/^- `\([a-z][a-z0-9-]*\)`.*/\1/p'
}

check_producer_list() { # check_producer_list <label> <names, one per line>  -> 0 when each required producer appears once
    local label="$1" names="$2" p n good=0
    if [ -z "$names" ]; then
        bad "$label — no producer list extracted (the section moved or changed shape; the check would otherwise cover nothing)"
        return 1
    fi
    for p in $REQUIRED_PRODUCERS; do
        n=$(printf '%s\n' "$names" | grep -cxF "$p")
        if [ "$n" -eq 0 ]; then
            bad "$label — does not name '$p' (a repo stamped by that producer would fall through to adopt/create and lose its config)"
            good=1
        elif [ "$n" -gt 1 ]; then
            bad "$label — names '$p' $n times (a mechanical rename collapsed two producers onto one name)"
            good=1
        fi
    done
    [ "$good" -eq 0 ] && ok "$label — names each required producer exactly once"
    return "$good"
}

check_producer_list "setup-config SKILL.md recognizer" "$(skill_producers "$CONFIG_SKILL")"
check_producer_list "setup-config update-mode.md list" "$(update_producers "$CONFIG_UPDATE")"

# Mutants: the gate must go red on each. Scratch copies of the shipped files with
# #414's exact rewrite (the middle producer rewritten onto the first), and a pure
# drop. A mutant that does not change its copy is itself a failure.
RENAMED_FROM="refresh-sassydog-skills"
RENAMED_TO="refresh-skills"
mutant_expect_red() { # mutant_expect_red <label> <extractor> <original> <sed script>
    local label="$1" extract="$2" orig="$3" script="$4" copy="$WORK/mutant-${5:-m}"
    sed "$script" "$orig" >"$copy"
    if cmp -s "$orig" "$copy"; then
        bad "mutant: $label — did not apply (the list's wording changed; update the mutant)"
    elif (check_producer_list "mutant $label" "$("$extract" "$copy")") >/dev/null 2>&1; then
        bad "mutant: $label — the gate stayed green on it"
    else
        ok "mutant: $label — caught"
    fi
}
mutant_expect_red "SKILL.md rewrite $RENAMED_FROM -> $RENAMED_TO (issue #414)" skill_producers "$CONFIG_SKILL" "s/\`$RENAMED_FROM\`/\`$RENAMED_TO\`/" skill-rewrite
mutant_expect_red "update-mode.md rewrite $RENAMED_FROM -> $RENAMED_TO (issue #414)" update_producers "$CONFIG_UPDATE" "s/^- \`$RENAMED_FROM\`/- \`$RENAMED_TO\`/" update-rewrite
mutant_expect_red "SKILL.md paragraph heading changes (empty extraction)" skill_producers "$CONFIG_SKILL" 's/^\*\*Marker recognition accepts/**Marker recognition takes/' skill-empty
mutant_expect_red "update-mode.md heading changes (empty extraction)" update_producers "$CONFIG_UPDATE" 's/^## Recognising prior producers/## Prior producers/' update-empty
mutant_expect_red "update-mode.md drops a producer" update_producers "$CONFIG_UPDATE" '/^- `create-dev-workflows`/d' update-drop

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "ownership-matcher tests: all green" >&2
    exit 0
else
    echo "ownership-matcher tests: FAILURES above" >&2
    exit 1
fi
