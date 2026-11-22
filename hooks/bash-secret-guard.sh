#!/usr/bin/env bash
# bash-secret-guard.sh — PreToolUse(Bash) entry point. Reads the harness's JSON event on
# stdin, hands it to bash-secret-guard.py, and passes that exit code through:
#   0  allow            2  deny (reason on stderr, shown to the model)
#   1  the guard could not classify the event: FAILS OPEN, and says so on stderr.
# Claude Code treats any exit other than 0 and 2 as a non-blocking error and shows stderr
# to the user, so "fail open, loudly" is exit 1. This wrapper exists so a missing python3
# is reported by name rather than as a bare 127.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "bash-secret-guard: cannot resolve its own directory; command NOT checked (fail open)" >&2
    exit 1
}
if ! command -v python3 >/dev/null 2>&1; then
    echo "bash-secret-guard: python3 not found on PATH; command NOT checked (fail open)" >&2
    exit 1
fi
exec python3 -I "$here/bash-secret-guard.py"
