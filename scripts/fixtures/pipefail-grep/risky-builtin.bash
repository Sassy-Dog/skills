#!/usr/bin/env bash
# Every builtin writer shape the tree used while #256's printf/echo allowlist
# stood — SEVEN pipelines, each of which MUST be flagged (issue #571). A builtin
# flushes to a pipe line by line, so a match on any line before the last lets
# `grep -q` exit between writes and pipefail turn the match into a miss, at any
# size. The self-check counts seven findings, so a scanner that quietly
# re-allows one shape fails rather than passing on the other six.
set -o pipefail

# bare printf
if printf '%s' "$ROW" | grep -qi 'lifetime'; then echo hit; fi

# guarded by &&
if [ -n "$ROW" ] && printf '%s' "$ROW" | grep -q 'any tier'; then echo hit; fi

# negated, and behind `if !`
if ! echo "$CANDIDATE" | grep -qE "$CALVER_RE"; then echo no; fi

# inside a case arm, where the label's `)` is not a command separator
case "$row" in
    *'sentry: none'*) printf '%s' "$row" | grep -qi 'blind spot' && n=1 ;;
esac

# after a `||`, which is a fallback and not a pipe
test -n "$X" || echo "$Y" | grep -q z

# a quoted `|` inside the printf payload
printf '%s|%s\n' "$A" "$B" | grep -q sep

# the writer on the line ABOVE, across a `\` continuation — joined into one
# logical line, so it is reported once with its writer named.
if printf '%s' "$ROW" \
     | grep -q 'continued'; then
    echo hit
fi
