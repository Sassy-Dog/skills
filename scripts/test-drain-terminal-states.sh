#!/usr/bin/env bash
# test-drain-terminal-states.sh — worker termination is not an issue/PR state.
#
# #282/#290's terminal-state rules still live in dispatch-ready §7: Ready-empty
# alone is not COMPLETE; held PRs must be enumerated; blocked/conflicting PRs
# cannot merge; pending/recoverable work is not STALLED; site-only is DEFERRED.
# The former gate compared whole paragraphs and their inventory to a second
# prose copy. That froze #452's stop-only policy while proving no execution.
# #484 intentionally removes those wording assertions rather than re-pinning
# the new prose. This gate now exercises the local lifecycle that §7 consumes.
# It does NOT claim to execute the model's terminal-state judgement; the scratch
# dispatcher invocation and its limits are recorded in HARNESS-PORTABILITY.md.
#
# Real worker processes prove: a clean tree plus a terminal-failure comment is
# not exit evidence; a concurrent tick cannot acquire; a killed supervisor or
# timeout cannot release; two runners cannot share one token; a verified normal
# completion releases rather than leaving the drain deadlocked. All repositories
# and remotes are temporary. No GitHub, model, or operator-profile mutations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/fixtures/checkout-guard.py" Lifecycle -v
