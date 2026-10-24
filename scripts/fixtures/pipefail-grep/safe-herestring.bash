#!/usr/bin/env bash
# The fix the guard prescribes, in every shape the #571 sweep produced. None may
# be flagged: a gate whose own recommended fix trips it is unusable, and an
# unusable gate is turned off — the same outcome as never having built it.
set -o pipefail

# bare
if grep -qi 'lifetime' <<<"$ROW"; then echo hit; fi

# guarded by &&
if [ -n "$ROW" ] && grep -q 'any tier' <<<"$ROW"; then echo hit; fi

# negated
if ! grep -qE "$CALVER_RE" <<<"$CANDIDATE"; then echo no; fi

# inside a case arm
case "$row" in
    *'sentry: none'*) grep -qi 'blind spot' <<<"$row" && n=1 ;;
esac

# an exact-line match against a multi-line list
if grep -qxF "$br" <<<"$OPEN_BASES"; then echo held; fi

# a fallback `||`, which was never a pipe
test -n "$X" || grep -q z <<<"$Y"
