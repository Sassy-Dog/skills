#!/usr/bin/env bash
# test-board-snapshot-calls.sh — every `board-snapshot.sh` command in tracked
# Markdown uses the script's one interface, the environment form (issue #448).
#
# Why this exists: `skills/github-issues/scripts/board-snapshot.sh` reads ONLY
# the environment variables PROJECT_NUMBER and OWNER. It parses no flags. Three
# SKILL.md snippets (dispatch-ready, groom-backlog, survey-work) were written as
# `board-snapshot.sh --number <n> --owner <o>`; with the variables unset the
# script prints its usage line and exits 64, ignoring the flags. Each snippet
# captures that output in `BOARD_SNAPSHOT=$(…)`, so the snapshot was empty,
# `--sites-of` then exited 64 on empty stdin, and board mode failed CLOSED on
# every card — nothing dispatched, nothing promoted, the site column went dark
# — for a reason that had nothing to do with sites. Failing closed bounded the
# harm and hid the cause. Nothing checked doc against script, so it drifted.
#
# The decision (2026-10-04) is to fix the docs, not teach the script flags: one
# interface, no second spelling to keep in sync. This gate keeps it one.
#
# What it asserts, precisely. A COMMAND is a `board-snapshot.sh` occurrence
# inside a fenced code block of a tracked `*.md` file (prose mentions in
# backticks are not commands, exactly as in test-plugin-root-in-references.sh).
# Fence tracking accepts a blockquote marker. Backslash continuations are joined
# into one logical line; comment lines (`#`) and a mention after a trailing `#` are skipped. The command ends at
# the first `)`, `|`, `;`, `&` or `#` after the script name, so a downstream
# `queue-snapshot.sh --sites-of` is never charged to board-snapshot.sh. Then:
#
#   1. NON-VACUOUS: at least one command is found in the tree, and the
#      documented form in skills/github-issues/SKILL.md is among them.
#   2. NO FLAG: no token starting with `-` follows the script name in that
#      command. "Any flag the script does not parse" is the whole set, because
#      the script parses none — that is the generalisation of --number/--owner,
#      and it stays correct only while the script stays flag-less (property 4
#      pins that, so teaching the script a flag fails here on purpose and
#      forces this header to be rewritten).
#   3. ENV FORM: the same logical command carries `PROJECT_NUMBER=` and
#      `OWNER=` assignments — the script exits 64 without both, so a bare call
#      is the same defect as a flag call.
#   4. THE SCRIPT STILL PARSES NO FLAGS: board-snapshot.sh has no getopts,
#      positional-argument read, shift, or `--flag)` case label. Source-level.
#   5. Mutation proof, against scratch fixtures scanned by the SAME function as
#      the tree: a flag-form call (the three original snippets' shape, as a
#      continuation, one-line and blockquoted) IS caught; a bare call with no
#      env IS caught; the corrected env form is NOT; a downstream `--sites-of`
#      on the same logical line is NOT; a trailing-comment mention is NOT; prose naming the script and a
#      flag is NOT.
#
# Source-level: no gh, no network, no repo mutation. No pipeline feeds
# `grep -q` (test-pipefail-grep.sh).
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-board-snapshot-calls.sh
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$REPO_ROOT" ] && { echo "test-board-snapshot-calls: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "board-snapshot-calls tests" >&2

# Emits `<file>:<line>:<kind>:<command>` per command. kind: ok | flag | noenv.
# Awk only, so nothing pipes into grep -q.
scan_calls() { # <file>...
    local f
    for f in "$@"; do
        awk -v F="$f" '
            function judge(cmd, start,   rest, cut, n, i, parts, kind) {
                if (substr(cmd, 1, index(cmd, "board-snapshot.sh") - 1) ~ /#/) return
                rest = substr(cmd, index(cmd, "board-snapshot.sh") + length("board-snapshot.sh"))
                cut = match(rest, /[)|;&#]/)
                if (cut > 0) rest = substr(rest, 1, cut - 1)
                kind = "ok"
                n = split(rest, parts, /[[:space:]]+/)
                for (i = 1; i <= n; i++) if (parts[i] ~ /^-/) kind = "flag"
                if (kind == "ok" && (cmd !~ /PROJECT_NUMBER=/ || cmd !~ /OWNER=/)) kind = "noenv"
                printf "%s:%d:%s:%s\n", F, start, kind, cmd
            }
            /^[[:space:]]*(>[[:space:]]*)?```/ { infence = !infence; acc = ""; next }
            !infence { next }
            {
                line = $0
                sub(/^[[:space:]]*(>[[:space:]]?)?/, "", line)
                if (acc == "") {
                    if (line ~ /^#/) next
                    start = NR
                }
                if (line ~ /\\[[:space:]]*$/) {
                    sub(/\\[[:space:]]*$/, "", line)
                    acc = acc line " "
                    next
                }
                acc = acc line
                if (index(acc, "board-snapshot.sh") > 0) judge(acc, start)
                acc = ""
            }
        ' "$f"
    done
}

mapfile -t MD_FILES < <(git ls-files '*.md')
if [ "${#MD_FILES[@]}" -eq 0 ]; then
    bad "no tracked *.md files found — every property below would pass vacuously"
    echo "board-snapshot-calls tests: FAILURES above" >&2
    exit 1
fi

calls="$(scan_calls "${MD_FILES[@]}")"

echo "1. commands found in the tree" >&2
n_calls=0
[ -n "$calls" ] && n_calls="$(awk 'END { print NR }' <<<"$calls")"
if [ "$n_calls" -ge 1 ]; then
    ok "$n_calls board-snapshot.sh command(s) scanned across ${#MD_FILES[@]} tracked *.md files"
else
    bad "no board-snapshot.sh command found in any fenced block — the scanner matches nothing, so the properties below are vacuous"
fi
documented="$(awk -F: '$1 == "skills/github-issues/SKILL.md"' <<<"$calls")"
if [ -n "$documented" ]; then
    ok "the documented form in skills/github-issues/SKILL.md is scanned"
else
    bad "skills/github-issues/SKILL.md carries no scanned board-snapshot.sh command — the interface's written home moved or the scanner stopped seeing it"
fi

echo "2. no flag on any command" >&2
flagged="$(awk -F: '$3 == "flag"' <<<"$calls")"
if [ -z "$flagged" ]; then
    ok "no board-snapshot.sh command passes a flag"
else
    while IFS= read -r h; do
        bad "${h%%:flag:*} passes a flag to board-snapshot.sh, which parses none and exits 64 (issue #448); use PROJECT_NUMBER=<n> OWNER=<org> bash …/board-snapshot.sh"
    done <<<"$flagged"
fi

echo "3. env form on every command" >&2
noenv="$(awk -F: '$3 == "noenv"' <<<"$calls")"
if [ -z "$noenv" ]; then
    ok "every board-snapshot.sh command sets PROJECT_NUMBER and OWNER"
else
    while IFS= read -r h; do
        bad "${h%%:noenv:*} runs board-snapshot.sh without both PROJECT_NUMBER= and OWNER= — the script exits 64 (issue #448)"
    done <<<"$noenv"
fi

echo "4. the script still parses no flags" >&2
SCRIPT="skills/github-issues/scripts/board-snapshot.sh"
if grep -Eq 'getopts|"?\$\{?[1-9@*]|^[[:space:]]*shift|^[[:space:]]*--[a-z-]+\)' "$SCRIPT"; then
    bad "$SCRIPT now appears to parse arguments — if it gained flags, rewrite this gate's header and property 2 deliberately rather than letting the docs and script diverge again"
else
    ok "$SCRIPT reads only PROJECT_NUMBER / OWNER / PROJECT_LIMIT from the environment"
fi

echo "5. mutation proof" >&2
expect() { # <label> <want-kind|none> <fixture body>
    local label="$1" want="$2" body="$3" out
    printf '%s\n' "$body" >"$WORK/fx.md"
    out="$(scan_calls "$WORK/fx.md")"
    if [ "$want" = none ]; then
        if [ -z "$(awk -F: '$3 != "ok"' <<<"$out")" ]; then ok "$label"; else bad "$label — flagged: $out"; fi
    elif [ -n "$(awk -F: -v w="$want" '$3 == w' <<<"$out")" ]; then
        ok "$label"
    else
        bad "$label — scanner did NOT report '$want' (got: ${out:-nothing}); this gate is vacuous"
    fi
}
expect "continuation flag form (the #448 shape) is caught" flag '```bash
BOARD_SNAPSHOT=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/board-snapshot.sh \
  --number <board.number> --owner <board.owner>)
```'
expect "one-line flag form is caught" flag '```bash
bash board-snapshot.sh --number 4 --owner Sassy-Dog
```'
expect "blockquoted flag form is caught" flag '> ```bash
> bash board-snapshot.sh --owner x
> ```'
expect "a bare call with no env is caught" noenv '```bash
bash board-snapshot.sh
```'
expect "the corrected env form is not flagged" none '```bash
BOARD_SNAPSHOT=$(PROJECT_NUMBER=<board.number> OWNER=<board.owner> \
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/board-snapshot.sh)
```'
expect "a downstream --sites-of on the same logical line is not charged" none '```bash
PROJECT_NUMBER=4 OWNER=o bash board-snapshot.sh | bash queue-snapshot.sh --sites-of
```'
expect "a mention in a trailing comment is not a command" none '```yaml
project_id: PVT_x   # GraphQL node IDs, from board-snapshot.sh
```'
expect "prose naming the script and a flag is not a command" none '`board-snapshot.sh --number` is wrong prose, not a command.

```bash
echo hi
```'

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "board-snapshot-calls tests: all green" >&2
    exit 0
else
    echo "board-snapshot-calls tests: FAILURES above" >&2
    exit 1
fi
