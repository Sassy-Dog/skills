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
#     that starts with `!` and a backtick and names CONFIG_SOURCE; that one
#     pattern, CFG_RE, is the only definition of "config line" here, so an
#     unrelated `!` injection elsewhere in a carrier is not a config line and
#     passes, while the paragraph itself may start no line with `!` plus a
#     backtick). It must equal carriers + stoppers, so a ninth skill with such
#     a line fails here until it is classified. Nothing is assumed about which
#     skills those are.
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
#   3. No stopper carries the paragraph, keyed on the opener and on a
#      distinctive phrase from the body searched in whitespace-collapsed text,
#      so a copy with a reworded opener is seen even when the phrase is split
#      across a line break. A copy that rewords the phrase itself is NOT seen:
#      that is the accepted limit. Nothing else in a stopper's text matters.
#   4. The derived set equals carriers + stoppers.
#   5. Mutation proof against scratch fixtures scanned by the SAME functions
#      that scan the tree: an unmodified copy passes; each of removed, drifted
#      (one word), moved BELOW the CONFIG_SOURCE paragraph, moved ABOVE the
#      config line, duplicated, and the hygiene breaches (a line starting with
#      `!` plus a backtick, a bare positional token, the token) fails; a
#      paragraph added to a stopper fails, as does a reworded copy there (opener
#      changed, phrase split across lines); a reworded second copy in a carrier
#      fails; an unrelated extra `!` injection in a carrier still passes; a
#      further skill with a config line in neither list fails. The mutation
#      section is skipped, with a note, when the tree scan above already failed,
#      because its fixtures are copies of the live tree and would only blame the
#      checker for a defect in the tree. Every mutant must
#      differ from its source, so a mutation that matched nothing cannot read as
#      caught.
#   6. (issue #574) The config line keeps `git` out of any `$(...)` or backtick
#      substitution, because a worktree-isolated Claude Code session's guard
#      refuses that form at load, before the line or the fallback paragraph can
#      reach the agent. The cat is cwd-relative as a result, so all eight skills
#      carry the "unconfirmed until you have read the root's file" paragraph
#      (stoppers included: it is not the Unrun paragraph). Mutants: the old
#      substitution form, and the paragraph deleted.
#      (issue #576) Section 6 also pins, per line: the `2>/dev/null || echo
#      "NO_CONFIG"` ending (the paragraph and all four stoppers depend on that
#      exact string; preflight gate 18 checks only CONFIG_SOURCE), the file the
#      cat reads being the OWNING skill's (`take-it` for work-recommendations and
#      work-fire-watch, which read take-it.md; otherwise the skill's own name),
#      and the `printf 'CONFIG_CWD: '; pwd -P;` statement that makes a cwd/root
#      mismatch visible. `pwd -P` (the resolved path, which is what git prints,
#      so a root reached through a symlink compares equal) and not "$PWD" because a worktree-isolated
#      session refuses git beside expansions it cannot resolve (measured, #576; the repo bans all of them, see scripts/check-git-expansion.sh). The
#      paragraph, read to its own end rather than a fixed window, must name
#      CONFIG_CWD, state the "differs from" condition, and tell the agent to read
#      <CONFIG_SOURCE>'s file by absolute path. One mutant for each.
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
# The one definition of an injected config line.
CFG_RE='^!`.*CONFIG_SOURCE'

# flat <file> — the file's text with every whitespace run collapsed to one space,
# so a phrase split across a line break still matches. Callers hold the result in
# a variable and search it with a here-string (a pipe into grep -q is banned
# under pipefail by test-pipefail-grep.sh).
flat() { tr '\n\t' '  ' < "$1" | tr -s ' '; }

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
    local f="$1" name="$2" expected cfg n_cfg n_para n_body block flat_text
    expected="${TEMPLATE//NAME/$name}"
    n_cfg="$(grep -c "$CFG_RE" "$f" || true)"
    if [ "$n_cfg" -ne 1 ]; then
        echo "has $n_cfg injected config lines, not exactly one"
        return
    fi
    flat_text="$(flat "$f")"
    n_para="$(grep -cF "$OPENER" "$f" || true)"
    n_body="$(grep -oF "$BODY_PHRASE" <<<"$flat_text" | grep -c . || true)"
    if [ "$n_para" -ne 1 ] || [ "$n_body" -ne 1 ]; then
        echo "carries the paragraph $n_para times by opener and $n_body by body phrase, not exactly once"
        return
    fi
    cfg="$(grep -n "$CFG_RE" "$f" | head -1 | cut -d: -f1)"
    block="$(sed -n "$((cfg + 2)),$((cfg + 6))p" "$f")"
    if ! blank_line "$f" "$((cfg + 1))" || [ "$block" != "$expected" ] || ! blank_line "$f" "$((cfg + 7))"; then
        echo "the paragraph is not the exact five lines directly under the config line at line $cfg (blank, paragraph, blank)"
    fi
    para_of "$f" | hygiene_text
}

# check_stopper <file> — one problem when the paragraph is present.
check_stopper() {
    local f="$1" flat_text
    flat_text="$(flat "$f")"
    if grep -qF "$OPENER" "$f" || grep -qF "$BODY_PHRASE" <<<"$flat_text"; then
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
        if grep -qE "$CFG_RE" "$f"; then
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
if [ "$fail" -ne 0 ]; then
    echo "5. mutation proof SKIPPED: the tree scan above already failed, and these fixtures are copies of the live tree, so they would blame the checker for a defect in the tree. Fix the tree failure first." >&2
    echo "config-fallback-paragraph tests: FAILURES above" >&2
    exit 1
fi
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
# An unrelated `!` injection elsewhere in a carrier: still a clean carrier.
mut_extra_inject() { { cat "$1"; printf '\n!`echo unrelated`\n'; } > "$2"; }
# A second, reworded copy of the paragraph appended to a carrier, phrase split.
mut_reworded_dup() { { cat "$1"; printf '\nConfig was not run. Never read an unrun line\nas "no config exists".\n'; } > "$2"; }
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
    awk -v O="$OPENER" -v CFG="$CFG_RE" '
        { lines[NR] = $0 }
        $0 ~ CFG && !c { c = NR }
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
    # An extra non-config injection is not a config line and must still pass.
    mut_extra_inject "$src" "$WORK/extra.md"
    if differs "$src" "$WORK/extra.md" "extra non-config injection"; then
        if [ -z "$(check_carrier "$WORK/extra.md" "$name")" ]; then ok "an extra non-config '!' injection still passes"; else bad "an extra non-config '!' injection was wrongly flagged: $(check_carrier "$WORK/extra.md" "$name")"; fi
    fi
    mut_reworded_dup "$src" "$WORK/rdup.md"
    if differs "$src" "$WORK/rdup.md" "reworded second copy"; then
        if [ -n "$(check_carrier "$WORK/rdup.md" "$name")" ]; then ok "mutant 'reworded second copy in a carrier' is caught"; else bad "mutant 'reworded second copy in a carrier' was NOT caught"; fi
    fi
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
    awk -v PF="$WORK/stop-para.txt" -v CFG="$CFG_RE" '{ print } $0 ~ CFG && !d { d = 1; print ""; while ((getline l < PF) > 0) print l }' skills/take-it/SKILL.md > "$WORK/stop-added.md"
    if differs skills/take-it/SKILL.md "$WORK/stop-added.md" "added to a stopper"; then
        if [ -n "$(check_stopper "$WORK/stop-added.md")" ]; then ok "mutant 'added to a stopper' is caught"; else bad "mutant 'added to a stopper' was NOT caught"; fi
    fi
    # A copy with the opener reworded AND the phrase split across a line break.
    awk '{ gsub(/\*\*Unrun config line\.\*\*/, "**Config not run.**"); gsub(/unrun line as/, "unrun line\nas"); print }' "$WORK/stop-added.md" > "$WORK/stop-reworded.md"
    if differs "$WORK/stop-added.md" "$WORK/stop-reworded.md" "reworded copy in a stopper"; then
        if [ -n "$(check_stopper "$WORK/stop-reworded.md")" ]; then ok "mutant 'reworded opener, phrase split across lines, in a stopper' is caught"; else bad "mutant 'reworded opener, phrase split across lines, in a stopper' was NOT caught"; fi
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
printf -- '---\nname: ninth-skill\ndescription: x\n---\n\n!`printf '"'"'CONFIG_SOURCE: '"'"'; git rev-parse --show-toplevel`\n' > "$fx/skills/ninth-skill/SKILL.md"
extra_out="$(cd "$fx" && find skills -name SKILL.md | sort | scan_tree)"
if [ -n "$(derived_set_problem "$(sed -n 's/^DERIVED//p' <<<"$extra_out")")" ]; then
    ok "derived set: a ninth skill with a config line in neither list is caught"
else
    bad "derived set: a ninth skill with a config line in neither list was NOT caught"
fi

# --- 6. the line's form, and the subdirectory rule (issue #574) ----------------
echo "6. the config line keeps git out of a substitution, and every skill confirms NO_CONFIG at the root" >&2

# line_problems <file> — one problem per line, nothing when clean. The form is
# what a worktree-isolated Claude Code session's guard accepts: `git` as its own
# statement, never inside $(...) or backticks (measured, #574). The cat is
# cwd-relative, so a miss from below the root is possible and the paragraph that
# says what to do about it must be present exactly once.
line_problems() {
    local f="$1" want="$2" line inner n_conf para
    line="$(grep "$CFG_RE" "$f" | head -n 1)"
    # strip the injection's own delimiters before looking for a nested substitution
    inner="${line#!\`}"; inner="${inner%\`}"
    case "$inner" in *'$('*|*'`'*) echo "config line holds a command substitution (a worktree-isolated session refuses git inside one)" ;; esac
    case "$inner" in *'$root'*|*'${root'*) echo "config line still joins a captured root into the path" ;; esac
    case "$inner" in *"cat .claude/sassy-dog/"*) : ;; *) echo "config line does not read the cwd-relative .claude/sassy-dog path" ;; esac
    case "$inner" in *"cat .claude/sassy-dog/${want}.md 2>/dev/null || echo \"NO_CONFIG\"") : ;; *) echo "config line does not read .claude/sassy-dog/${want}.md and end in 2>/dev/null || echo \"NO_CONFIG\"" ;; esac
    case "$inner" in "printf 'CONFIG_CWD: '; pwd -P; printf 'CONFIG_SOURCE: '; "*) : ;; *) echo "config line does not open with the CONFIG_CWD pwd -P statement" ;; esac
    case "$inner" in *'$PWD'*|*'${PWD'*) echo "config line expands a shell variable (a worktree-isolated session refuses git beside one)" ;; esac
    # the paragraph, from its opener to the next blank line, whitespace-collapsed
    para="$(awk '/unconfirmed until you have read the root/ {on=1} on && /^$/ {exit} on {print}' "$f" | tr '\n' ' ' | tr -s ' ')"
    case "$para" in *CONFIG_CWD*) : ;; *) echo "subdirectory-rule paragraph does not name CONFIG_CWD" ;; esac
    case "$para" in *"differs from"*) : ;; *) echo "subdirectory-rule paragraph does not state the differs-from condition" ;; esac
    case "$para" in *"by absolute path"*) : ;; *) echo "subdirectory-rule paragraph does not say to read the root's file by absolute path" ;; esac
    case "$inner" in *"git rev-parse --show-toplevel"*) : ;; *) echo "config line does not print the repo root" ;; esac
    n_conf="$(grep -c 'unconfirmed until you have read the root' "$f" || true)"
    [ "$n_conf" -eq 1 ] || echo "has $n_conf subdirectory-rule paragraphs, not exactly one"
    return 0
}

six_bad=0
owner_of() { case "$1" in work-recommendations|work-fire-watch) echo take-it ;; *) echo "$1" ;; esac; }
for n in $CARRIERS $STOPPERS; do
    p="$(line_problems "skills/$n/SKILL.md" "$(owner_of "$n")")"
    if [ -n "$p" ]; then bad "$n: $p"; six_bad=1; fi
done
[ "$six_bad" -eq 0 ] && ok "all eight skills: git is a plain statement and the NO_CONFIG-at-root rule is present once"

p="$(line_problems skills/setup-config/references/config-contract.md '<skill>' | grep -v 'subdirectory-rule' || true)"
if [ -z "$p" ]; then ok "config-contract.md: the canonical line has the same form"; else bad "config-contract.md: $p"; fi

# mutants: the old substitution form, and a deleted rule paragraph, are caught.
old_form="$WORK/old-form.md"
sed 's|^!`printf .CONFIG_CWD: .; pwd -P; printf .CONFIG_SOURCE: .; git rev-parse --show-toplevel 2>/dev/null .. echo "<not a git repo>"; cat .claude/sassy-dog/send-it.md|!`root="$(git rev-parse --show-toplevel)"; echo "CONFIG_SOURCE: ${root}"; cat "$root/.claude/sassy-dog/send-it.md"|' skills/send-it/SKILL.md > "$old_form"
if cmp -s "$old_form" skills/send-it/SKILL.md; then bad "mutant old-form: the mutation matched nothing"
elif [ -n "$(line_problems "$old_form" send-it)" ]; then ok "mutant: the old substitution line is caught"
else bad "mutant: the old substitution line was NOT caught"; fi
no_rule="$WORK/no-rule.md"
grep -v 'unconfirmed until you have read the root' skills/send-it/SKILL.md > "$no_rule"
if cmp -s "$no_rule" skills/send-it/SKILL.md; then bad "mutant no-rule: the mutation matched nothing"
elif [ -n "$(line_problems "$no_rule" send-it)" ]; then ok "mutant: a skill missing the rule paragraph is caught"
else bad "mutant: a skill missing the rule paragraph was NOT caught"; fi

# issue #576 mutants: each asserts that line_problems fails on a copy of send-it
# with exactly one property removed, and that the mutation changed the file.
six_mutant() { # <label> <sed expr> [<want>]
    local label="$1" expr="$2" want="${3:-send-it}" m="$WORK/m6.md"
    sed "$expr" skills/send-it/SKILL.md > "$m"
    if cmp -s "$m" skills/send-it/SKILL.md; then bad "mutant $label: the mutation matched nothing"
    elif [ -n "$(line_problems "$m" "$want")" ]; then ok "mutant: $label is caught"
    else bad "mutant: $label was NOT caught"; fi
}
six_mutant "a line without the NO_CONFIG ending" '/^!`printf/s/ 2>\/dev\/null || echo "NO_CONFIG"//'
six_mutant "a line that reads another skill's config" '/^!`printf/s|cat .claude/sassy-dog/send-it.md|cat .claude/sassy-dog/groom-backlog.md|'
six_mutant "a line without the CONFIG_CWD statement" "/^!\`printf/s|printf 'CONFIG_CWD: '; pwd -P; ||"
six_mutant "a CONFIG_CWD taken from a variable" "/^!\`printf/s|pwd -P;|\"\$PWD\";|"
six_mutant "a line using plain pwd instead of pwd -P" "/^!\`printf/s|pwd -P;|pwd;|"
six_mutant "a paragraph without the differs-from condition" '/unconfirmed until you have read the root/,/stands\./s/differs from/equals/'
six_mutant "a paragraph without the read-by-absolute-path sentence" '/unconfirmed until you have read the root/,/stands\./{/by absolute path/d;}'
six_mutant "a paragraph that never names CONFIG_CWD" '/unconfirmed until you have read the root/,/stands\./s/CONFIG_CWD/CONFIG_DIR/g'
# the ownership table itself: work-recommendations must be held to take-it.md.
if [ -n "$(line_problems skills/work-recommendations/SKILL.md work-recommendations)" ]; then ok "mutant: work-recommendations held to its own name instead of take-it is caught"; else bad "mutant: work-recommendations held to the wrong basename was NOT caught"; fi

if [ "$fail" -eq 0 ]; then
    echo "config-fallback-paragraph tests: all green" >&2
    exit 0
else
    echo "config-fallback-paragraph tests: FAILURES above" >&2
    exit 1
fi
