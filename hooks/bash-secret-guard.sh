#!/usr/bin/env bash
# bash-secret-guard.sh — PreToolUse(Bash) entry point. Reads the harness's JSON event on
# stdin, hands it to bash-secret-guard.py, and passes that verdict through:
#   0  allow            2  deny (reason on stderr, shown to the model)
#   1  the guard could not classify the event: FAILS OPEN, and says so on stderr.
# Claude Code treats any exit other than 0 and 2 as a non-blocking error and shows stderr
# to the user, so "fail open, loudly" is exit 1. This wrapper exists so that every way the
# classifier can fail to produce a verdict is reported by name and exits 1:
#   - this directory cannot be resolved, or python3 is not on PATH (otherwise a bare 127)
#   - bash-secret-guard.py missing or unreadable (a partial plugin-cache sync; otherwise
#     python3 itself exits 2, which the harness reads as a DENY of every Bash call)
#   - stdin closed (the capture below would otherwise feed the classifier its own pipe and it
#     would block until the harness timeout)
#   - the classifier crashing (an import or syntax error, a signal; otherwise a raw
#     traceback). Only a 0, or a 2 that carries the classifier's own BLOCKED banner, is a
#     verdict; a stray exit 2 is a crash and fails open, not a deny.
# A harness timeout is not visible here: the harness kills the hook and, on PreToolUse, lets
# the call through, so it fails open without a word (hooks.json sets no timeout; see README).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "bash-secret-guard: cannot resolve its own directory; command NOT checked (fail open)" >&2
    exit 1
}
if ! command -v python3 >/dev/null 2>&1; then
    echo "bash-secret-guard: python3 not found on PATH; command NOT checked (fail open)" >&2
    exit 1
fi
py="$here/bash-secret-guard.py"
if [ ! -f "$py" ] || [ ! -r "$py" ]; then
    echo "bash-secret-guard: classifier bash-secret-guard.py is missing or unreadable; command NOT checked (fail open)" >&2
    exit 1
fi
# stdin passes through; the classifier's stderr is captured and its stdout (always empty) is
# dropped, so a closed stdout cannot stop it running. `-X utf8` makes stdin decoding independent
# of the host locale: without it an older Python under en_US.UTF-8 raises on one stray non-UTF-8
# byte and the guard fails open for a printing command.
# With fd 0 closed the capture below would hand the classifier its own pipe as stdin and it would
# block until the harness timeout, so a closed stdin is reported here instead.
{ exec 3<&0; } 2>/dev/null || {
    echo "bash-secret-guard: stdin is closed; command NOT checked (fail open)" >&2
    exit 1
}
exec 3<&-
err="$(python3 -I -X utf8 "$py" 2>&1 >/dev/null)"
rc=$?
case "$rc" in
    0) exit 0 ;;
    2)
        case "$err" in
            # The banner is written first, by the classifier's one exit-2 path; command text
            # cannot forge it (notices are constants plus exception class names). It is also
            # accepted at the start of a later line, so an interpreter warning printed before it
            # cannot turn every deny into a fail open.
            "bash-secret-guard: BLOCKED."* | *$'\n'"bash-secret-guard: BLOCKED."*)
                # The verdict is the exit code: with stderr closed the write fails and the exit
                # stays 2. (Running python under exec exited 120 there, which reads as fail open.)
                printf '%s\n' "$err" >&2
                exit 2 ;;
        esac ;;
    1)
        case "$err" in
            "bash-secret-guard: "*"(fail open)"*)
                printf '%s\n' "$err" >&2
                exit 1 ;;
        esac ;;
esac
{
    echo "bash-secret-guard: classifier crashed (exit $rc); command NOT checked (fail open)"
    printf '%s\n' "$err" | tail -n 5
} >&2
exit 1
