#!/usr/bin/env bash
# test-plugin-root-paragraph.sh — every SKILL.md that carries the plugin-root
# token also carries the root-resolution paragraph, and no paragraph spells the
# token (issue #454, design in docs/HARNESS-PORTABILITY.md "Design for rows 5
# and 6 (#425)").
#
# Why this exists: omp does not substitute the plugin-root token in a skill body
# and does not export it to the shell. Measured on the shipped github-issues
# skill (#425): unchanged, 2 of 2 runs searched with `find` and 1 of 2 first ran
# the literal token (exit 127). With the paragraph this gate pins, the first
# command succeeded with no token run and no search (#454's runs, in the design
# doc). Nothing fails when a new SKILL.md adds a token command and forgets the
# paragraph, so the harness that needs it silently regresses to the search.
#
# The one trap, and the reason the paragraph is checked for the token as well as
# for its presence: Claude Code substitutes the token ANYWHERE in a SKILL.md,
# including inside the paragraph that explains it, so a paragraph that spells
# the token is rewritten into a path in the middle of its own sentence and
# reads as nonsense. The paragraph refers to "the plugin-root placeholder"
# instead. Tested wording only: the text below is the text that passed on omp,
# so an "improvement" is a change to be re-run, not a tidy-up.
#
# Properties asserted:
#
#   1. The template itself spells no token.
#   2. Every tracked skills/*/SKILL.md that contains the token carries the
#      template, with its own directory name filled in, as exactly one line
#      (leading indentation allowed, for a paragraph inside a list item). The
#      set is derived, never a fixed 15: a sixteenth skill that adds the token
#      fails here until it carries the paragraph.
#   3. Placement: the next non-blank line after the paragraph is where the first
#      command begins, i.e. the opening fence of the first fenced block that
#      uses the token, or, for a file whose only uses are prose (send-it), the
#      start of the block holding the first use. A paragraph moved away from its
#      command is the untested distance the design flagged.
#   4. No line that opens `**Plugin root.**` in any SKILL.md spells the token,
#      so a drifted variant is caught even when it no longer matches the
#      template.
#   5. Mutation proof against scratch fixtures scanned by the SAME function that
#      scans the tree, on a fenced-anchor skill (github-issues) AND the
#      prose-anchored one (send-it): an unmodified copy passes; removing the
#      paragraph, spelling the token inside it, moving it to the end and moving
#      it ONE block up (the near miss) each fail; every mutant must differ from
#      its source, so a mutation that matched nothing cannot read as caught.
#      The derived set is proved too: a scratch tree with a further SKILL.md
#      that carries the token but no paragraph must fail. Without this a checker that matched nothing would sit
#      green forever.
#
# Accepted limit: placement is keyed on the first FENCED command that uses the token
# (or, for a file with no fenced use, the block holding the first use). A prose
# load of a token path that precedes that fence is not covered. `dispatch-ready`
# section 2 is the known case; `send-it` is the prose-anchored exception the
# gate does handle.
#
# The paragraph remains immediately before the first fenced token command.
# assess-it's audit gate also inventories its placement. dispatch-ready's former
# terminal-state prose inventory was retired in #484; this gate owns placement.
#
# Source-level only: no gh, no network, no mutation of the tree.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-plugin-root-paragraph.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-plugin-root-paragraph: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "plugin-root-paragraph tests" >&2

TOKEN='CLAUDE_PLUGIN_ROOT'
# The shipped paragraph, one line, NAME filled in per skill.
TEMPLATE='**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/NAME`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.'

# check_file <file> <skill-name> — prints one problem per line, nothing when clean.
check_file() {
    local f="$1" name="$2" expected n_para para_line anchor next
    expected="${TEMPLATE//NAME/$name}"
    n_para="$(awk -v E="$expected" '{ l = $0; sub(/^[ \t]+/, "", l); if (l == E) c++ } END { print c + 0 }' "$f")"
    if [ "$n_para" -ne 1 ]; then
        echo "carries the paragraph $n_para times, not exactly once"
        return
    fi
    # Line of the paragraph, and the line where the first command begins.
    para_line="$(awk -v E="$expected" '{ l = $0; sub(/^[ \t]+/, "", l); if (l == E) { print NR; exit } }' "$f")"
    anchor="$(awk -v T="$TOKEN" '
        { lines[NR] = $0 }
        /^[ \t]*(>[ \t]*)?```/ { if (!infence) { infence = 1; start = NR } else { infence = 0 } ; next }
        index($0, T) {
            if (infence) { print start; found = 1; exit }
            if (!first) first = NR
        }
        END {
            if (!found && first) {
                a = first
                while (a > 1 && lines[a - 1] ~ /[^ \t]/) a--
                print a
            }
        }' "$f")"
    if [ -z "$anchor" ]; then
        echo "no use of the token found (the file should not be in the checked set)"
        return
    fi
    next="$(awk -v P="$para_line" 'NR > P && $0 ~ /[^ \t]/ { print NR; exit }' "$f")"
    if [ "$next" != "$anchor" ]; then
        echo "paragraph at line $para_line is not immediately before the first command (next content line $next, command begins line $anchor)"
    fi
}

# --- 1. the template spells no token -------------------------------------------
echo "1. the template spells no token" >&2
case "$TEMPLATE" in
    *"$TOKEN"*) bad "the template spells the token — Claude Code substitutes it inside a SKILL.md, garbling the paragraph; refer to 'the plugin-root placeholder'" ;;
    *) ok "template is token-free" ;;
esac

# scan_files — reads SKILL.md paths (relative to the cwd) on stdin, keeps those
# that carry the token, and prints `<path>: <problem>` per defect. Prints
# `CHECKED <n>` last. The real tree and every fixture go through this ONE
# function, so the derived set (property 2) is itself under mutation proof.
scan_files() {
    local f name problems n=0
    while IFS= read -r f; do
        grep -qF "$TOKEN" "$f" || continue
        n=$((n + 1))
        name="$(basename "$(dirname "$f")")"
        problems="$(check_file "$f" "$name")"
        [ -z "$problems" ] && continue
        while IFS= read -r p; do
            echo "$f: $p"
        done <<<"$problems"
    done
    echo "CHECKED $n"
}

# --- 2 and 3. every token-carrying SKILL.md has the paragraph, well placed -----
echo "2. every SKILL.md that carries the token carries the paragraph, placed before its first command" >&2
tree_out="$(git ls-files 'skills/*/SKILL.md' | scan_files)"
n_checked="$(sed -n 's/^CHECKED //p' <<<"$tree_out")"
if [ "${n_checked:-0}" -eq 0 ]; then
    bad "no tracked skills/*/SKILL.md carries the token — the pathspec or the grep matches nothing, so this gate would pass vacuously"
    echo "plugin-root-paragraph tests: FAILURES above" >&2
    exit 1
fi
problems_out="$(grep -v '^CHECKED ' <<<"$tree_out" || true)"
if [ -z "$problems_out" ]; then
    ok "all $n_checked token-carrying SKILL.md files carry the paragraph, placed before their first command"
else
    while IFS= read -r p; do
        bad "  $p"
    done <<<"$problems_out"
fi

# --- 4. no paragraph, in any form, spells the token ----------------------------
echo "4. no **Plugin root.** line spells the token" >&2
drift=0
while IFS= read -r f; do
    lines="$(grep -E '^[[:space:]]*\*\*Plugin root\.\*\*' "$f" || true)"
    if grep -qF "$TOKEN" <<<"$lines"; then
        bad "  $f has a **Plugin root.** line that spells the token — Claude Code would substitute it into the paragraph itself"
        drift=1
    fi
done < <(git ls-files 'skills/*/SKILL.md')
[ "$drift" -eq 0 ] && ok "no paragraph spells the token"

# --- 5. mutation proof, against scratch fixtures --------------------------------
echo "5. mutation proof" >&2

# differs <source> <mutant> <label> — a mutant identical to its source proves
# nothing (a sed that matches nothing used to look like a caught mutation).
differs() {
    if cmp -s "$1" "$2"; then
        bad "mutant '$3' is identical to its source — the mutation did nothing, so its result proves nothing"
        return 1
    fi
    return 0
}

# Mutators. Each reads a SKILL.md on $1 and writes the mutant to $2.
mut_remove() { grep -vF '**Plugin root.**' "$1" > "$2"; }
mut_spell() { sed "s|If the plugin-root placeholder|If \${${TOKEN}}|" "$1" > "$2"; }
mut_move_end() {
    awk '
        /^[ \t]*\*\*Plugin root\.\*\*/ { held = $0; skip_blank = 1; next }
        skip_blank && $0 !~ /[^ \t]/ { skip_blank = 0; next }
        { print }
        END { print ""; print held }
    ' "$1" > "$2"
}
# One block up: the paragraph swaps places with the block directly above it, so
# it is a near miss, adjacent to its command but not immediately before it.
mut_move_up() {
    awk '
        { lines[NR] = $0 }
        /^[ \t]*\*\*Plugin root\.\*\*/ { p = NR }
        END {
            s = p - 2
            while (s > 1 && lines[s - 1] ~ /[^ \t]/) s--
            for (i = 1; i < s; i++) print lines[i]
            print lines[p]; print ""
            for (i = s; i < p - 1; i++) print lines[i]
            print ""
            for (i = p + 2; i <= NR; i++) print lines[i]
        }
    ' "$1" > "$2"
}

# expect_caught <fixture> <name> <label>
expect_caught() {
    if [ -n "$(check_file "$1" "$2")" ]; then
        ok "$3 is caught"
    else
        bad "$3 was NOT caught"
    fi
}

run_mutants() { # <source SKILL.md> <skill name> <tag>
    local src="$1" name="$2" tag="$3" m
    if [ ! -f "$src" ]; then
        bad "$src is missing, so the $tag fixtures cannot be built"
        return
    fi
    cp "$src" "$WORK/$tag-clean.md"
    if [ -z "$(check_file "$WORK/$tag-clean.md" "$name")" ]; then
        ok "$tag: an unmodified copy passes"
    else
        bad "$tag: an unmodified copy of $src fails — the checker is broken"
    fi
    for m in remove spell move_end move_up; do
        "mut_$m" "$src" "$WORK/$tag-$m.md"
        differs "$src" "$WORK/$tag-$m.md" "$tag $m" || continue
        case "$m" in
            spell)
                local sl
                sl="$(grep -E '^[[:space:]]*\*\*Plugin root\.\*\*' "$WORK/$tag-$m.md" || true)"
                if [ -n "$(check_file "$WORK/$tag-$m.md" "$name")" ] && grep -qF "$TOKEN" <<<"$sl"; then
                    ok "$tag: spelling the token inside the paragraph is caught (properties 2 and 4)"
                else
                    bad "$tag: spelling the token inside the paragraph was NOT caught"
                fi ;;
            *) expect_caught "$WORK/$tag-$m.md" "$name" "$tag: mutant '$m'" ;;
        esac
    done
}

# A fenced-anchor skill and the prose-anchored one (no fenced use of the token).
run_mutants skills/github-issues/SKILL.md github-issues fenced
run_mutants skills/send-it/SKILL.md send-it prose

# The derived set: a clean tree passes, and a further SKILL.md that carries the
# token but no paragraph fails. A fixed-list gate would stay green on it.
fx="$WORK/tree"
mkdir -p "$fx/skills/github-issues" "$fx/skills/extra-skill"
cp skills/github-issues/SKILL.md "$fx/skills/github-issues/SKILL.md"
clean_tree="$(cd "$fx" && find skills -name SKILL.md | sort | scan_files)"
if [ "$(grep -vc '^CHECKED ' <<<"$clean_tree" || true)" -eq 0 ] && grep -q '^CHECKED 1$' <<<"$clean_tree"; then
    ok "derived set: a one-skill scratch tree passes"
else
    bad "derived set: a clean one-skill scratch tree did not pass"
fi
printf -- '---\nname: extra-skill\ndescription: x\n---\n\n```bash\nbash ${%s}/skills/extra-skill/scripts/x.sh\n```\n' "$TOKEN" > "$fx/skills/extra-skill/SKILL.md"
extra_out="$(cd "$fx" && find skills -name SKILL.md | sort | scan_files)"
if grep -q '^skills/extra-skill/SKILL.md: ' <<<"$extra_out" && grep -q '^CHECKED 2$' <<<"$extra_out"; then
    ok "derived set: an added token-carrying SKILL.md with no paragraph is caught"
else
    bad "derived set: an added token-carrying SKILL.md with no paragraph was NOT caught"
fi

if [ "$fail" -eq 0 ]; then
    echo "plugin-root-paragraph tests: all green" >&2
    exit 0
else
    echo "plugin-root-paragraph tests: FAILURES above" >&2
    exit 1
fi
