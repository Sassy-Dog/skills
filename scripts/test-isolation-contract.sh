#!/usr/bin/env bash
# test-isolation-contract.sh — execute the shared-checkout safety boundary (#484).
#
# #451/#452 introduced parallel-isolation confirmation but source-text assertions
# could not prove that a serial worker ran, pushed, stopped, or preserved work.
# #484 replaces those wording/mutation pins with real subprocesses and temporary
# Git repositories. No model or GitHub calls run in CI. Full dispatcher model
# evidence and its limits are recorded in docs/HARNESS-PORTABILITY.md.
#
# The fixture exercises cross-worktree contention before reconciliation, owner
# token rejection, dirty acquisition, two sequential workers with independently
# read remote tips, an unpushed worker, remote-tip mismatch, and dirty failure.
# It does not claim to test Claude Code or model adherence to the skill prose.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/fixtures/checkout-guard.py" Ownership -v
