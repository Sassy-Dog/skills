#!/usr/bin/env bash
# test-plugin-root-in-references.sh — bans `${CLAUDE_PLUGIN_ROOT}` from commands
# in reference docs, and requires the variable that replaces it to be resolvable
# (issue #329).
#
# Why this exists: `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at
# load time and NOWHERE else. A reference doc is read raw, and the token is not
# an environment variable, so a command line carrying it runs against `/`:
#
#     $ bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/teardown.sh --sweep
#     bash: /skills/pr-shepherd/scripts/teardown.sh: No such file or directory
#
# That fails loudly (127), which bounds the severity — but the cost is an agent
# hitting a dead end in a document it was told to follow, whose likeliest
# recovery is improvising a path. Thirteen such lines accumulated across six
# docs, nine of them in `pr-shepherd`, the capability skill `send-it`,
# `take-it` and `dispatch-ready` all delegate merge mechanics to.
#
# Why a gate rather than a memo: NOTHING fails when a reference doc writes the
# token raw. AGENTS.md already documented the rule in prose and the tree
# drifted to thirteen violations anyway — the repo's own convention ("a rule
# stated in prose with no gate rots silently") applied to itself.
#
# The whole difficulty is the exception. `skills/assess-it/references/
# github-issue-ops.md` names the token in PROSE to document this exact trap and
# its remedy; that line is correct and load-bearing. A guard keyed on mere
# presence deletes the one doc that explains the bug. The distinction encoded
# here is COMMAND USAGE vs prose, and it maps exactly onto fenced code blocks:
# at the time of writing all 13 offending sites were inside ```fences``` and the
# prose exception was not. That is why property 2 exists as a fixture — it
# fails the moment the scanner degrades into matching everything.
#
# Four properties are asserted:
#
#   1. Tree-level: no `${CLAUDE_PLUGIN_ROOT}` appears inside a fenced code
#      block in any `skills/*/references/*.md`.
#   2. The prose exception is still present AND still unflagged. Both halves
#      matter: presence keeps the remedy documented, unflagged proves the
#      scanner discriminates rather than matching every occurrence.
#   3. Any reference doc whose commands use `$PLUGIN_ROOT` carries the
#      path-resolution preamble that tells the reader to set it. This is the
#      property with teeth — swapping an unresolvable token for an unset
#      variable is the SAME bug wearing a different name, and it is the shape a
#      later cleanup will reach for. A doc that uses the variable without
#      defining where it comes from fails here.
#   4. Mutation proof, both directions, against scratch fixtures: a newly-added
#      raw command-usage site IS caught, and a prose mention is NOT. Without
#      this a scanner that silently matched nothing would sit green forever.
#
# Source-level only: no gh, no network, no repo mutation. Fixtures are scratch
# files under mktemp, scanned by the SAME function that scans the tree — a
# second implementation would let the two drift.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-plugin-root-in-references.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-plugin-root-in-references: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "plugin-root-in-references tests" >&2

# --- the scanner --------------------------------------------------------------
# Emits `<file>:<line>` for every CLAUDE_PLUGIN_ROOT occurrence inside a fenced
# code block. Fence tracking accepts an optional blockquote marker so a fence
# nested in a `>` callout still counts as code, not prose.
scan_fenced() { # <file>...
    local f
    for f in "$@"; do
        awk -v F="$f" '
            /^[[:space:]]*(>[[:space:]]*)?```/ { infence = !infence; next }
            infence && /CLAUDE_PLUGIN_ROOT/ { printf "%s:%d\n", F, NR }
        ' "$f"
    done
}

# The prose exception, as a path this test states once.
EXCEPTION="skills/assess-it/references/github-issue-ops.md"

mapfile -t REF_DOCS < <(git ls-files 'skills/*/references/*.md')
if [ "${#REF_DOCS[@]}" -eq 0 ]; then
    bad "no tracked skills/*/references/*.md files found — the pathspec matches nothing, so every property below would pass vacuously"
    echo "plugin-root-in-references tests: FAILURES above" >&2
    exit 1
fi
ok "scanning ${#REF_DOCS[@]} tracked reference docs"

# --- 1. no token in any fenced command ----------------------------------------
echo "1. no \${CLAUDE_PLUGIN_ROOT} in fenced commands" >&2
hits="$(scan_fenced "${REF_DOCS[@]}")"
if [ -z "$hits" ]; then
    ok "no reference doc writes the token in a command"
else
    while IFS= read -r h; do
        bad "$h writes \${CLAUDE_PLUGIN_ROOT} in a command — it is NOT substituted in reference docs and is NOT a shell variable, so this resolves against / (issue #329). Set PLUGIN_ROOT in a path-resolution preamble and quote \"\$PLUGIN_ROOT/...\" instead."
    done <<<"$hits"
fi

# --- 2. the prose exception: present, and unflagged ---------------------------
echo "2. prose exception discriminated, not deleted" >&2
if [ -f "$EXCEPTION" ] && grep -qF 'CLAUDE_PLUGIN_ROOT' "$EXCEPTION"; then
    ok "$EXCEPTION still documents the token in prose"
else
    bad "$EXCEPTION no longer mentions \${CLAUDE_PLUGIN_ROOT} — that line is the remedy's only written home AND this guard's discrimination fixture; restore it rather than deleting it"
fi
if [ -n "$(scan_fenced "$EXCEPTION")" ]; then
    bad "the prose exception is being flagged — the scanner has stopped discriminating command usage from prose, which is the one thing it must do"
else
    ok "the prose exception is not flagged"
fi

# --- 3. every $PLUGIN_ROOT user defines where it comes from -------------------
# Swapping an unresolvable token for an undefined variable is the same defect.
echo "3. \$PLUGIN_ROOT users carry the path-resolution preamble" >&2
users=0
for f in "${REF_DOCS[@]}"; do
    grep -qF '$PLUGIN_ROOT' "$f" || continue
    users=$((users + 1))
    if grep -qF 'Path resolution' "$f"; then
        ok "  $f defines PLUGIN_ROOT"
    else
        bad "  $f runs commands against \$PLUGIN_ROOT but carries no 'Path resolution' preamble saying where to set it — an unset variable resolves against / exactly like the token it replaced (issue #329)"
    fi
done
if [ "$users" -eq 0 ]; then
    bad "no reference doc uses \$PLUGIN_ROOT — this property just passed vacuously; if the convention changed, change this gate deliberately"
else
    ok "$users reference docs use \$PLUGIN_ROOT, all with a preamble"
fi

# --- 4. mutation proof, both directions ---------------------------------------
echo "4. mutation proof" >&2
cat >"$WORK/violation.md" <<'FIX'
# Scratch doc

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/teardown.sh --sweep
```
FIX
if [ -n "$(scan_fenced "$WORK/violation.md")" ]; then
    ok "a newly-added raw command-usage site is caught"
else
    bad "scanner did NOT catch a raw \${CLAUDE_PLUGIN_ROOT} command inside a fence — this guard is vacuous"
fi

cat >"$WORK/prose.md" <<'FIX'
# Scratch doc

`${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` only, never into this file.

```bash
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/teardown.sh" --sweep
```
FIX
if [ -n "$(scan_fenced "$WORK/prose.md")" ]; then
    bad "scanner flagged a prose mention — it must ban command usage, not the word"
else
    ok "a prose mention beside a corrected command is not flagged"
fi

# A blockquoted fence is still code, not prose.
cat >"$WORK/quoted-fence.md" <<'FIX'
# Scratch doc

> ```bash
> bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-config/scripts/detect-capabilities.sh
> ```
FIX
if [ -n "$(scan_fenced "$WORK/quoted-fence.md")" ]; then
    ok "a fence nested in a blockquote is scanned as code"
else
    bad "scanner treated a blockquoted fence as prose — a command hidden one '>' deep would ship unflagged"
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "plugin-root-in-references tests: all green" >&2
    exit 0
else
    echo "plugin-root-in-references tests: FAILURES above" >&2
    exit 1
fi
