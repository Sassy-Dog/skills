#!/usr/bin/env bash
# session-path.sh — SessionStart hook (#670): puts hooks/shim/ FIRST on the agent's Bash PATH.
#
# Claude Code gives a SessionStart hook CLAUDE_ENV_FILE, a file it sources before every Bash command the
# session's agent runs. Writing `export PATH=...` there changes the agent's shell and nothing else: a user's
# own terminal, other sessions and every process outside the Bash tool keep their PATH.
#
# It prepends the shim only when a real CLI exists further down PATH. With none installed the shim would turn
# `command -v doppler` into a false "installed" and could only answer 127, so PATH is left alone and the hook
# exits 0 silently. Everything else that stops it doing its job exits 1 with a message, which Claude Code shows
# as a non-blocking error: the second layer is then absent for the session, and it says so.
#
# Exit codes: 0 done or nothing to do; 1 could not do it (said on stderr). It reads no stdin and prints nothing
# on stdout.
set -u
set -f

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
    echo "session-path: cannot resolve its own directory; the Bash PATH is NOT guarded by the wrapper" >&2
    exit 1
}
shim="$here/shim"
if [ ! -x "$shim/doppler" ]; then
    echo "session-path: $shim/doppler is missing or not executable; the Bash PATH is NOT guarded by the wrapper" >&2
    exit 1
fi
if [ -z "${CLAUDE_ENV_FILE:-}" ]; then
    echo "session-path: CLAUDE_ENV_FILE is not set (this harness gives a SessionStart hook no env file); the Bash PATH is NOT guarded by the wrapper" >&2
    exit 1
fi

# Is there a real CLI behind the shim? The same walk the shim does: skip empty entries, this directory, and
# anything that is the shim file.
found=""
IFS=:
for d in $PATH; do
    [ -n "$d" ] || continue
    [ -f "$d/doppler" ] && [ -x "$d/doppler" ] || continue
    [ "$d/doppler" -ef "$shim/doppler" ] && continue
    found=1
    break
done
unset IFS
[ -n "$found" ] || exit 0

sq="'$(printf '%s' "$shim" | sed "s/'/'\\\\''/g")'"
# Skip when the shim is already first, so a second SessionStart (resume, clear, compact) adds no copy.
line="[ \"\${PATH%%:*}\" = $sq ] || export PATH=$sq:\"\$PATH\""
if ! printf '%s\n' "$line" >>"$CLAUDE_ENV_FILE" 2>/dev/null; then
    echo "session-path: cannot write CLAUDE_ENV_FILE ($CLAUDE_ENV_FILE); the Bash PATH is NOT guarded by the wrapper" >&2
    exit 1
fi
exit 0
