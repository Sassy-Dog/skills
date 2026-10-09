#!/usr/bin/env bash
# test-checkout-guard.sh — the shipped checkout guard, executed for real (#484).
#
# skills/pr-shepherd/scripts/checkout-guard.sh is what `take-it` and `dispatch-ready`
# call before they touch a shared checkout, and what supervises the foreground
# serial worker; since #486 it lives in pr-shepherd, which owns the post-merge
# local mutations it governs. This gate runs scripts/fixtures/checkout-guard.py,
# whose three suites drive that script with real processes, scratch Git repositories and
# local bare remotes:
#
#   Ownership  — acquisition excludes a second owner (including from another
#                worktree) BEFORE any reconciliation; a dirty or unpushed
#                checkout is never acquired, repaired or reset; a copied token is
#                rejected; a behind-default checkout may fast-forward under
#                ownership; verification compares the LOCAL tip to a FRESH
#                ls-remote, so a pushed-looking branch, a stale tracking ref or a
#                worker's own report proves nothing; a failed acquire rolls its
#                guard back; concurrent acquires admit exactly one owner; and the
#                operator-only `abandon` demands positive evidence.
#   Check      — the read-only gate teardown.sh and merge-shepherd.sh call (#486):
#                no guard passes; a matching SASSY_DOG_CHECKOUT_TOKEN in the
#                environment passes; a missing or wrong token is exit 4; a live
#                writer is exit 3 even for the holder; unresolved or unreadable
#                state is exit 4; a token for a sibling worktree's guard is
#                exit 4; a non-ASCII token is a refusal, not a crash; a --token
#                on argv is ignored; `run` hides the check token from its worker;
#                with python3 off PATH a free checkout passes and a present guard
#                fails closed; nothing is written. A mutant copy with the check
#                removed is proved to fail for exactly these: the token
#                comparison, the live-writer refusal (it falls back to exit 4,
#                ownership=active), the phase gate, the other-worktree refusal
#                and the argv rule. The unreadable-state refusal has no mutant.
#                teardown.sh's behaviour under a held guard is executed by
#                test-teardown-args.sh (property 7).
#   Lifecycle  — a clean tree plus a terminal-failure comment is not exit
#                evidence; a live worker excludes release and a concurrent tick; a
#                killed supervisor, an elapsed timeout or a timeout signal cannot
#                release; two runners cannot share one token; a foreground tool
#                process group that exits is verified, and one that survives keeps
#                the checkout owned; `abandon` cannot reach a live or timed-out
#                worker; a verified normal completion releases rather than
#                deadlocking the drain.
#
# WHAT THIS GATE IS NOT. It reads no SKILL.md and no prose, so it cannot notice a
# dispatcher that stops calling the guard, a Serial variant that regained
# `git stash`, or §7 wording that re-licenses a forever-tick. Those are pinned by
# test-isolation-contract.sh (what the skills tell a model to do) and
# test-drain-terminal-states.sh (§7's terminal-state canon). #484's first edition
# replaced both with a one-line wrapper over this fixture; that deleted the pins
# for decisions #484 did not change, and the three gates are complementary, not
# interchangeable. Likewise this gate does not run a model: the scratch
# dispatcher runs and their limits are recorded in docs/HARNESS-PORTABILITY.md
# ("Safe serial runtime checks (#484)").
#
# HERMETIC. Every repository and remote lives in a temporary directory removed on
# exit; no GitHub, network, operator profile or model. Needs bash, python3 (stdlib
# unittest), git and POSIX `ps`, the same prerequisites the guard itself reports.
# `-B` and PYTHONDONTWRITEBYTECODE keep Python from writing `__pycache__` into the
# tree, which is what a gate that runs on every preflight must not leave behind.
#
# Wired into scripts/preflight.sh (entry 54); run directly:
#   bash scripts/test-checkout-guard.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || {
    echo "checkout-guard tests: python3 not found" >&2
    exit 1
}
export PYTHONDONTWRITEBYTECODE=1
exec python3 -B "$ROOT/scripts/fixtures/checkout-guard.py" -v
