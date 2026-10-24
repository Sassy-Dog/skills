#!/usr/bin/env bash
# test-artifact-guard.sh — pins the stray-artifact guard template's behaviour.
#
# Why this exists: this hook's failure mode is SILENCE. Every degraded input is
# deliberately fail-open (exit 0), which is correct — a guard that breaks a
# session is worse than a stray PNG — but it means a guard that has stopped
# working looks exactly like a guard with nothing to report. Nothing goes red,
# no output appears, and the artifacts quietly resume piling up in the repo
# root. So the loud cases are asserted as hard as the quiet ones.
#
# Seven properties:
#
#   1. PostToolUse fires on an artifact written directly to the repo root:
#      exit 2 (the harness feeds stderr back for immediate self-correction) and
#      the message names the file.
#   2. It stays silent for the cases that are NOT strays — a file already in
#      tmp/, a nested path, a non-artifact extension. A guard that nags about
#      legitimate writes gets ignored, which is the same as being absent.
#   3. It reads all three path parameter spellings. `file_path` is Write's;
#      `path` and `filename` are the browser-automation screenshot tools'. The
#      confirmed real-world cause of this whole feature was a screenshot tool,
#      so missing one spelling misses the case that matters.
#   4. `.svg` is excluded on purpose — legitimate committed source in several
#      repos, and a false positive there trains people to ignore the hook.
#   5. Stop emits `{"decision":"block"}` naming the strays, as valid JSON.
#   6. Stop honours `stop_hook_active`. This is the one that wedges a session
#      if it regresses: Claude Code sets the flag session-wide while a stop
#      continuation is in flight, so re-blocking loops forever.
#   7. Every degraded input fails OPEN at exit 0 — empty stdin, malformed JSON,
#      an unknown event, a missing cwd, and running outside a git repo.
#
# Network-free and binary-free: scratch git repos and empty files. The template
# is exercised directly, so this gate fails on the template rather than on some
# rendered copy that may not exist yet in any consumer repo.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT/skills/setup-hooks/references/templates/sassydog-artifact-guard.template.sh"

FAILED=0
ok() { echo "  ok    $1" >&2; }
bad() {
    echo "  FAIL  $1" >&2
    FAILED=1
}

[ -f "$GUARD" ] || {
    echo "artifact-guard tests: template not found at $GUARD" >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/tmp" "$REPO/docs"
git -C "$REPO" init -q
printf '/tmp/\n' >"$REPO/.gitignore"
: >"$REPO/docs/legit.png"
: >"$REPO/tmp/inside.png"
: >"$REPO/notes.md"
: >"$REPO/logo.svg"

OUT=""
ERR=""
STATUS=0
fire() {
    OUT=$(printf '%s' "$1" | bash "$GUARD" 2>"$WORK/err")
    STATUS=$?
    ERR=$(cat "$WORK/err")
}

post() { printf '{"hook_event_name":"PostToolUse","cwd":"%s","tool_input":{"%s":"%s"}}' "$REPO" "$1" "$2"; }
stop() { printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":%s}' "$REPO" "$1"; }

# --- 1 + 3. the loud case, via every path spelling --------------------------
for key in file_path path filename; do
    : >"$REPO/stray.png"
    fire "$(post "$key" stray.png)"
    if [ "$STATUS" = 2 ] && grep -q 'stray.png' <<<"$ERR"; then
        ok "PostToolUse .$key: root artifact -> exit 2, names the file"
    else
        bad "PostToolUse .$key: expected exit 2 naming stray.png (exit $STATUS)"
    fi
    rm -f "$REPO/stray.png"
done

# The nudge has to be actionable, not just present.
: >"$REPO/stray.png"
fire "$(post file_path stray.png)"
grep -q 'tmp/' <<<"$ERR" &&
    ok "the nudge names tmp/ as the destination" ||
    bad "the nudge never mentions tmp/ — it says something is wrong but not what to do"
rm -f "$REPO/stray.png"

# --- 2 + 4. the quiet cases -------------------------------------------------
quiet() {
    fire "$2"
    if [ "$STATUS" = 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
        ok "$1"
    else
        bad "$1 — expected silent exit 0, got exit $STATUS out='$OUT' err='$ERR'"
    fi
}
quiet "PostToolUse: a file already in tmp/ is not a stray" "$(post path tmp/inside.png)"
quiet "PostToolUse: a nested path is a deliberate asset" "$(post filename docs/legit.png)"
quiet "PostToolUse: a non-artifact extension is ignored" "$(post file_path notes.md)"
quiet "PostToolUse: .svg is deliberately excluded" "$(post file_path logo.svg)"
quiet "PostToolUse: a path that does not exist is ignored" "$(post file_path ghost.png)"

# --- 5. Stop blocks and names the strays ------------------------------------
: >"$REPO/left-behind.png"
fire "$(stop false)"
if [ "$STATUS" = 0 ] &&
    printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 &&
    printf '%s' "$OUT" | jq -e '.reason | test("left-behind.png")' >/dev/null 2>&1; then
    ok "Stop: emits valid block JSON naming the stray"
else
    bad "Stop: expected block JSON naming left-behind.png (exit $STATUS, out='$OUT')"
fi

# --- 6. the recursion guard — the session-wedging regression ----------------
fire "$(stop true)"
if [ "$STATUS" = 0 ] && [ -z "$OUT" ]; then
    ok "Stop: stop_hook_active=true short-circuits (no re-block loop)"
else
    bad "Stop: stop_hook_active=true must produce nothing — this wedges sessions (out='$OUT')"
fi

rm -f "$REPO/left-behind.png"
quiet "Stop: silent when the root is clean" "$(stop false)"

# --- 7. fail-open on every degraded input -----------------------------------
quiet "fail-open: empty stdin" ""
quiet "fail-open: malformed JSON" "not json at all"
quiet "fail-open: unknown hook event" "$(printf '{"hook_event_name":"PreCompact","cwd":"%s"}' "$REPO")"
quiet "fail-open: missing cwd key" '{"hook_event_name":"Stop","stop_hook_active":false}'

BARE="$WORK/not-a-repo"
mkdir -p "$BARE"
quiet "fail-open: outside a git repo" "$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$BARE")"

if [ "$FAILED" = 0 ]; then
    echo "artifact-guard tests: all green" >&2
    exit 0
else
    echo "artifact-guard tests: FAILURES above" >&2
    exit 1
fi
