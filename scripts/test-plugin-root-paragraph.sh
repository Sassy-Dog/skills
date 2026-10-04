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
#      scans the tree: removing the paragraph fails, spelling the token inside
#      it fails, moving it away from its command fails, and an unmodified
#      fixture passes. Without this a checker that matched nothing would sit
#      green forever.
#
# Neighbouring pins: the paragraph is a new block in `skills/assess-it/SKILL.md`
# and in `skills/dispatch-ready/SKILL.md` §4, whose paragraph inventories
# `test-audit-lost-reviewer.sh` and `test-drain-terminal-states.sh` pin on
# purpose. Both canon tables carry it (as `skill#b22` and in `sec4_openers`);
# a new paragraph in either file is a deliberate edit to those tables too.
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

# --- 2 and 3. every token-carrying SKILL.md has the paragraph, well placed -----
echo "2. every SKILL.md that carries the token carries the paragraph, placed before its first command" >&2
mapfile -t TOKEN_FILES < <(git ls-files 'skills/*/SKILL.md' | while IFS= read -r f; do grep -qF "$TOKEN" "$f" && echo "$f"; done)
if [ "${#TOKEN_FILES[@]}" -eq 0 ]; then
    bad "no tracked skills/*/SKILL.md carries the token — the pathspec or the grep matches nothing, so this gate would pass vacuously"
    echo "plugin-root-paragraph tests: FAILURES above" >&2
    exit 1
fi
for f in "${TOKEN_FILES[@]}"; do
    name="$(basename "$(dirname "$f")")"
    problems="$(check_file "$f" "$name")"
    if [ -z "$problems" ]; then
        ok "  $f"
    else
        while IFS= read -r p; do
            bad "  $f: $p"
        done <<<"$problems"
    fi
done
ok "checked ${#TOKEN_FILES[@]} token-carrying SKILL.md files"

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
SRC="skills/github-issues/SKILL.md"
if [ ! -f "$SRC" ]; then
    bad "$SRC is missing, so the mutation fixtures cannot be built"
else
    clean="$WORK/clean.md"
    cp "$SRC" "$clean"
    if [ -z "$(check_file "$clean" github-issues)" ]; then
        ok "an unmodified copy passes"
    else
        bad "an unmodified copy of $SRC fails — the checker is broken"
    fi

    removed="$WORK/removed.md"
    grep -vF '**Plugin root.**' "$SRC" > "$removed"
    if [ -n "$(check_file "$removed" github-issues)" ]; then
        ok "removing the paragraph is caught"
    else
        bad "removing the paragraph was NOT caught"
    fi

    spelled="$WORK/spelled.md"
    sed "s|in the plugin-root placeholder|in the \${${TOKEN}} placeholder|; s|If the plugin-root placeholder|If \${${TOKEN}}|" "$SRC" > "$spelled"
    spelled_lines="$(grep -E '^[[:space:]]*\*\*Plugin root\.\*\*' "$spelled" || true)"
    if [ -n "$(check_file "$spelled" github-issues)" ] && grep -qF "$TOKEN" <<<"$spelled_lines"; then
        ok "spelling the token inside the paragraph is caught (properties 2 and 4)"
    else
        bad "spelling the token inside the paragraph was NOT caught"
    fi

    moved="$WORK/moved.md"
    awk '
        /^\*\*Plugin root\.\*\*/ { held = $0; skip_blank = 1; next }
        skip_blank && $0 !~ /[^ \t]/ { skip_blank = 0; next }
        { print }
        END { print ""; print held }
    ' "$SRC" > "$moved"
    if [ -n "$(check_file "$moved" github-issues)" ]; then
        ok "moving the paragraph away from its command is caught"
    else
        bad "moving the paragraph away from its command was NOT caught"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "plugin-root-paragraph tests: all green" >&2
    exit 0
else
    echo "plugin-root-paragraph tests: FAILURES above" >&2
    exit 1
fi
