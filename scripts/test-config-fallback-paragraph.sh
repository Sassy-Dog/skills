#!/usr/bin/env bash
# test-config-fallback-paragraph.sh — the "Unrun config line" paragraph is in the
# four conservative-mode skills, exactly, directly under their injected config
# line, and in none of the four NO_CONFIG stoppers (issue #463, following #455;
# decision and measurements in docs/HARNESS-PORTABILITY.md "Config-fallback
# paragraph (#455)").
#
# Why this exists: omp renders the `!` config line as text instead of running it.
# `send-it`, `survey-work`, `groom-backlog` and `tidy-repo` degrade SILENTLY on a
# missed config (they run on, conservatively), so each carries one paragraph
# telling the agent to read the config by absolute path and never to read an
# unrun line as "no config exists". The four skills that stop on NO_CONFIG
# (`take-it`, `dispatch-ready`, `work-recommendations`, `work-fire-watch`) do not
# carry it: that was measured for the first two and is #455's decision rule for
# the other two. Nothing failed when one copy drifted, was deleted, moved below
# the CONFIG_SOURCE paragraph (the text says "the line above") or was added to a
# stopper by a later "every skill gets it" sweep.
#
# Derived vs pinned, stated once so a later edit knows which is which:
#   - DERIVED: the set of skills with an injected config line (a SKILL.md line
#     that starts with `!` and a backtick and names CONFIG_SOURCE). It must equal
#     carriers + stoppers, so a ninth skill with such a line fails here until it
#     is classified. Nothing is assumed about which skills those are.
#   - PINNED BY NAME: the four carriers and the four stoppers below. The
#     classification is a decision, not a property of the text, so it is
#     written down rather than inferred; changing it is a deliberate edit here.
#
# Properties asserted:
#
#   1. The template spells no plugin-root token, starts no line with `!` plus a
#      backtick, and has no bare positional token ($1-$9, $@, $*). The same
#      hygiene is applied to every `**Unrun config line.**` paragraph found in
#      any non-carrier SKILL.md and to each carrier's paragraph, so a drifted
#      variant is flagged even where it no longer matches the template.
#   2. Each carrier has exactly one injected config line and exactly one
#      paragraph, with its own name filled in, as the five lines at +2..+6 after
#      a blank line that follows the config line, then a blank line. Directly
#      under the config line is what makes "the line above" true; it also puts
#      the paragraph above the CONFIG_SOURCE paragraph.
#   3. No stopper carries the paragraph (keyed on the opener and on a
#      distinctive phrase from the body, so a reworded copy is still seen). This
#      depends on nothing else in a stopper's text.
#   4. The derived set equals carriers + stoppers.
#   5. Mutation proof against scratch fixtures scanned by the SAME functions
#      that scan the tree: an unmodified copy passes; each of removed, drifted
#      (one word), moved BELOW the CONFIG_SOURCE paragraph, moved ABOVE the
#      config line, duplicated, and the hygiene breaches (a line starting with
#      `!` plus a backtick, a bare positional token, the token) fails; a
#      paragraph added to a stopper fails, as does a reworded copy there; a
#      further skill with a config line in neither list fails. Every mutant must
#      differ from its source, so a mutation that matched nothing cannot read as
#      caught.
#
# config-contract.md ("Where the harness never runs the line") DESCRIBES the
# paragraph in prose and is deliberately not pinned: it paraphrases rather than
# copying, and a text pin on a paraphrase would break on every rewording.
# docs/HARNESS-PORTABILITY.md holds a verbatim `text` block for send-it; it is
# also not pinned here, because that doc is edited by unrelated work and its copy
# is a record of what was measured, not a shipped surface.
#
# Source-level only: no gh, no network, no mutation of the tree.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-config-fallback-paragraph.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-config-fallback-paragraph: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "config-fallback-paragraph tests" >&2

TOKEN='CLAUDE_PLUGIN_ROOT'
CARRIERS="send-it survey-work groom-backlog tidy-repo"
STOPPERS="take-it dispatch-ready work-recommendations work-fire-watch"
OPENER='**Unrun config line.**'
# A phrase from the body that survives a reworded opener.
BODY_PHRASE='an unrun line as "no config exists"'

# The shipped paragraph, five lines, NAME filled in per skill.
TEMPLATE='**Unrun config line.** If the line above reached you as text (it starts with `!` and shows a
command, with no `CONFIG_SOURCE:` output beneath it), nothing ran it. Take the repo root from
`git rev-parse --show-toplevel` and read `<repo root>/.claude/sassy-dog/NAME.md` by absolute path.
If that file does not exist the config is `NO_CONFIG`, handled as that state already is. Never read
an unrun line as "no config exists".'

# blank_line <file> <n> — succeeds when line n exists and is blank.
blank_line() { awk -v N="$2" 'NR == N { found = 1; if ($0 ~ /[^ \t]/) r = 1 } END { exit (found && !r) ? 0 : 1 }' "$1"; }

# hygiene_text — reads paragraph text on stdin, prints one problem per line.
hygiene_text() {
    local t
    t="$(cat)"
    grep -qE '^!`' <<<"$t" && echo "a line starts with ! plus a backtick (the injected-line grep would count it)"
    grep -qE '\$[1-9@*]' <<<"$t" && echo "has a bare positional token (a SKILL.md body is an arg-substitution surface)"
    grep -qF "$TOKEN" <<<"$t" && echo "spells the plugin-root token (Claude Code substitutes it inside the paragraph)"
    return 0
}

# para_of <file> — every paragraph that opens with the opener, to its blank line.
para_of() {
    awk -v O="$OPENER" 'index($0, O) == 1 { on = 1 } on && $0 !~ /[^ \t]/ { on = 0 } on { print }' "$1"
}

# check_carrier <file> <name> — one problem per line, nothing when clean.
check_carrier() {
    local f="$1" name="$2" expected cfg n_cfg n_para block
    expected="${TEMPLATE//NAME/$name}"
    n_cfg="$(grep -c '^!`' "$f" || true)"
    if [ "$n_cfg" -ne 1 ]; then
        echo "has $n_cfg injected config lines, not exactly one"
        return
    fi
    n_para="$(grep -cF "$OPENER" "$f" || true)"
    if [ "$n_para" -ne 1 ]; then
        echo "carries the paragraph $n_para times, not exactly once"
        return
    fi
    cfg="$(grep -n '^!`' "$f" | head -1 | cut -d: -f1)"
    block="$(sed -n "$((cfg + 2)),$((cfg + 6))p" "$f")"
    if ! blank_line "$f" "$((cfg + 1))" || [ "$block" != "$expected" ] || ! blank_line "$f" "$((cfg + 7))"; then
        echo "the paragraph is not the exact five lines directly under the config line at line $cfg (blank, paragraph, blank)"
    fi
    para_of "$f" | hygiene_text
}

# check_stopper <file> — one problem when the paragraph is present.
check_stopper() {
    local f="$1"
    if grep -qF "$OPENER" "$f" || grep -qF "$BODY_PHRASE" "$f"; then
        echo "carries the unrun-config paragraph, which a NO_CONFIG stopper must not"
    fi
}

# --- 1. the template ------------------------------------------------------------
echo "1. the template is clean" >&2
tp="$(hygiene_text <<<"$TEMPLATE")"
if [ -z "$tp" ]; then ok "template: no line-start bang, no positional token, no plugin-root token"; else bad "template: $tp"; fi

# prefix_problems <path> — turns problem lines on stdin into `<path>: <problem>`.
prefix_problems() {
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && echo "$1: $p"
    done
    return 0
}

# scan_tree — reads SKILL.md paths on stdin (relative to the cwd), prints
# `<path>: <problem>` per defect, then `DERIVED <names>` (space separated).
scan_tree() {
    local f name derived=""
    while IFS= read -r f; do
        name="$(basename "$(dirname "$f")")"
        if grep -qE '^!`.*CONFIG_SOURCE' "$f"; then
            derived="$derived $name"
        fi
        case " $CARRIERS " in
            *" $name "*) check_carrier "$f" "$name" | prefix_problems "$f" ;;
            *) check_stopper "$f" | prefix_problems "$f"
               para_of "$f" | hygiene_text | prefix_problems "$f" ;;
        esac
    done
    echo "DERIVED$derived"
}

# derived_set_problem <names> — prints a problem unless the derived set is
# exactly carriers + stoppers.
derived_set_problem() {
    local want got
    want="$(printf '%s\n' $CARRIERS $STOPPERS | sort | tr '\n' ' ')"
    got="$(printf '%s\n' $1 | sort | tr '\n' ' ')"
    [ "$want" = "$got" ] || echo "skills with an injected config line are [${got% }], expected exactly the eight pinned [${want% }]"
    return 0
}

# --- 2, 3, 4. the tree ----------------------------------------------------------
echo "2-4. carriers carry it exactly, stoppers do not, and the derived set is the pinned eight" >&2
tree_out="$(git ls-files 'skills/*/SKILL.md' | scan_tree)"
derived="$(sed -n 's/^DERIVED//p' <<<"$tree_out")"
problems="$(grep -v '^DERIVED' <<<"$tree_out" || true)"
if [ -z "${derived// /}" ]; then
    bad "no SKILL.md has an injected config line — the pathspec or the pattern matches nothing, so this gate would pass vacuously"
    echo "config-fallback-paragraph tests: FAILURES above" >&2
    exit 1
fi
if [ -z "$problems" ]; then
    ok "the four carriers carry the paragraph exactly, directly under the config line; the four stoppers do not"
else
    while IFS= read -r p; do bad "  $p"; done <<<"$problems"
fi
dp="$(derived_set_problem "$derived")"
if [ -z "$dp" ]; then ok "derived set of config-line skills equals the pinned carriers + stoppers"; else bad "$dp"; fi

# --- 5. mutation proof ----------------------------------------------------------
echo "5. mutation proof" >&2

# differs <source> <mutant> <label> — a mutant identical to its source proves nothing.
differs() {
    if cmp -s "$1" "$2"; then
        bad "mutant '$3' is identical to its source — the mutation did nothing, so its result proves nothing"
        return 1
    fi
    return 0
}

# Mutators: read a SKILL.md on $1, write the mutant to $2.
mut_remove() {
    awk -v O="$OPENER" '
        index($0, O) == 1 { on = 1 }
        on { if ($0 !~ /[^ \t]/) on = 0; next }
        { print }' "$1" > "$2"
}
mut_drift() { sed 's|Never read|Do not read|' "$1" > "$2"; }
mut_bang() { sed 's|^command, with no|!`command, with no|' "$1" > "$2"; }
mut_positional() { sed 's|^command, with no|command $1, with no|' "$1" > "$2"; }
mut_token() { sed "s|^command, with no|command \${${TOKEN}}, with no|" "$1" > "$2"; }
mut_dup() { { cat "$1"; printf '\n%s\n' "$OPENER a second copy"; } > "$2"; }
# Below the CONFIG_SOURCE paragraph: swap with the block that follows.
mut_move_below() {
    awk -v O="$OPENER" '
        { lines[NR] = $0 }
        index($0, O) == 1 { p = NR }
        END {
            e = p; while (e <= NR && lines[e] ~ /[^ \t]/) e++
            n = e + 1; while (n <= NR && lines[n] ~ /[^ \t]/) n++
            for (i = 1; i < p; i++) print lines[i]
            for (i = e + 1; i < n; i++) print lines[i]
            print ""
            for (i = p; i < e; i++) print lines[i]
            for (i = n; i <= NR; i++) print lines[i]
        }' "$1" > "$2"
}
# Above the config line: swap with the config line.
mut_move_above() {
    awk -v O="$OPENER" '
        { lines[NR] = $0 }
        /^!`/ && !c { c = NR }
        index($0, O) == 1 { p = NR }
        END {
            e = p; while (e <= NR && lines[e] ~ /[^ \t]/) e++
            for (i = 1; i < c; i++) print lines[i]
            for (i = p; i < e; i++) print lines[i]
            print ""
            for (i = c; i < p - 1; i++) print lines[i]
            for (i = e; i <= NR; i++) print lines[i]
        }' "$1" > "$2"
}

run_carrier_mutants() { # <source SKILL.md> <skill name>
    local src="$1" name="$2" m
    if [ ! -f "$src" ]; then bad "$src is missing, so its fixtures cannot be built"; return; fi
    cp "$src" "$WORK/clean.md"
    if [ -z "$(check_carrier "$WORK/clean.md" "$name")" ]; then
        ok "an unmodified copy of $name passes"
    else
        bad "an unmodified copy of $src fails — the checker is broken"
    fi
    for m in remove drift bang positional token dup move_below move_above; do
        "mut_$m" "$src" "$WORK/$m.md"
        differs "$src" "$WORK/$m.md" "$m" || continue
        if [ -n "$(check_carrier "$WORK/$m.md" "$name")" ]; then ok "mutant '$m' is caught"; else bad "mutant '$m' was NOT caught"; fi
    done
    # The hygiene check must catch its three breaches on its own, not only
    # through the exact-text comparison that also fails them.
    for m in bang positional token; do
        if [ -n "$(para_of "$WORK/$m.md" | hygiene_text)" ]; then
            ok "hygiene alone catches '$m'"
        else
            bad "hygiene alone did NOT catch '$m'"
        fi
    done
}
run_carrier_mutants skills/send-it/SKILL.md send-it

# A paragraph added to a stopper, directly under its config line.
if [ -f skills/take-it/SKILL.md ]; then
    cp skills/take-it/SKILL.md "$WORK/stop-clean.md"
    if [ -z "$(check_stopper "$WORK/stop-clean.md")" ]; then ok "an unmodified stopper passes"; else bad "an unmodified take-it fails the stopper check"; fi
    printf '%s\n' "${TEMPLATE//NAME/take-it}" > "$WORK/stop-para.txt"
    awk -v PF="$WORK/stop-para.txt" '{ print } /^!`/ && !d { d = 1; print ""; while ((getline l < PF) > 0) print l }' skills/take-it/SKILL.md > "$WORK/stop-added.md"
    if differs skills/take-it/SKILL.md "$WORK/stop-added.md" "added to a stopper"; then
        if [ -n "$(check_stopper "$WORK/stop-added.md")" ]; then ok "mutant 'added to a stopper' is caught"; else bad "mutant 'added to a stopper' was NOT caught"; fi
    fi
    # A copy with the opener reworded is still seen through the body phrase.
    sed 's|\*\*Unrun config line\.\*\*|**Config not run.**|' "$WORK/stop-added.md" > "$WORK/stop-reworded.md"
    if differs "$WORK/stop-added.md" "$WORK/stop-reworded.md" "reworded copy in a stopper"; then
        if [ -n "$(check_stopper "$WORK/stop-reworded.md")" ]; then ok "mutant 'reworded copy in a stopper' is caught"; else bad "mutant 'reworded copy in a stopper' was NOT caught"; fi
    fi
else
    bad "skills/take-it/SKILL.md is missing, so the stopper fixtures cannot be built"
fi

# The derived set, through the SAME scan_tree: a mirror of the eight passes, and
# a further skill with a config line in neither list fails.
fx="$WORK/tree"
mkdir -p "$fx"
for n in $CARRIERS $STOPPERS; do
    mkdir -p "$fx/skills/$n"
    cp "skills/$n/SKILL.md" "$fx/skills/$n/SKILL.md"
done
clean_out="$(cd "$fx" && find skills -name SKILL.md | sort | scan_tree)"
if [ -z "$(grep -v '^DERIVED' <<<"$clean_out" || true)" ] && [ -z "$(derived_set_problem "$(sed -n 's/^DERIVED//p' <<<"$clean_out")")" ]; then
    ok "derived set: a scratch mirror of the eight passes"
else
    bad "derived set: a clean scratch mirror did not pass"
fi
mkdir -p "$fx/skills/ninth-skill"
printf -- '---\nname: ninth-skill\ndescription: x\n---\n\n!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root}"`\n' > "$fx/skills/ninth-skill/SKILL.md"
extra_out="$(cd "$fx" && find skills -name SKILL.md | sort | scan_tree)"
if [ -n "$(derived_set_problem "$(sed -n 's/^DERIVED//p' <<<"$extra_out")")" ]; then
    ok "derived set: a ninth skill with a config line in neither list is caught"
else
    bad "derived set: a ninth skill with a config line in neither list was NOT caught"
fi

if [ "$fail" -eq 0 ]; then
    echo "config-fallback-paragraph tests: all green" >&2
    exit 0
else
    echo "config-fallback-paragraph tests: FAILURES above" >&2
    exit 1
fi
