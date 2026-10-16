#!/usr/bin/env bash
# test-auto-merge-policy.sh — pins the FAIL-CLOSED merge policy of setup-deps'
# dependabot-auto-merge template (template version 4, runner hardened in 5).
#
# Version 5 (#527, part of #515) adds a third property that is not a merge
# condition: the job runs on `ubuntu-latest`, hard-coded. It hands the org-wide
# App token to the runner's local `gh`, and a persistent shared self-hosted
# runner can carry a PATH-shadowing `gh` or a modified tool cache from any
# earlier job, in any repo. Modelled on test-deps-cadence-policy.sh property 9;
# `{{RUNNER}}` is refused as well as any self-hosted label, because a render
# fact would let a consumer re-open the hole.
#
# Versions 1-3 shipped two fail-open conditions to every consumer, found by a
# security review on 2026-10-11 while francisco rendered the template:
#
#   1. The merge step ran on `update-type != 'version-update:semver-major'`.
#      fetch-metadata emits an EMPTY update-type when it cannot classify a bump,
#      and `'' != 'version-update:semver-major'` is true — so an unclassified
#      bump was enqueued exactly as if it were a patch.
#   2. The job gated only on the PR AUTHOR being dependabot[bot]. A `synchronize`
#      run triggered by a human or agent pushing to a Dependabot branch passed
#      that gate, minted the write-capable App token, and enqueued their
#      unreviewed commit.
#
# Both are the kind of defect actionlint cannot see: the expressions are valid,
# just permissive. So this gate asserts the policy itself, on the template
# source (not a render — the conditions are identical in both merge arms, and
# test-template-actionlint.sh already proves the renders lint):
#
#   - the job `if:` requires the author AND github.actor to be dependabot[bot]
#   - every step that runs `gh pr merge` matches semver-minor / semver-patch
#     with `==` only — no `!=` anywhere in its condition
#   - the hold step is the exact complement (`!=` minor `&&` `!=` patch), so
#     every PR either merges or is held with a comment, never neither
#
# Vacuous-green guard: zero merge steps found is a FAILURE (a renamed command
# or reflowed step would otherwise check nothing). Mutation-proof: five
# mutants are applied to a copy and each must fail the check: the three
# regressions above plus the two runner mutants (a render-fact runner and a
# self-hosted runs-on; the runner is hard-coded ubuntu-latest).
#
# Reads one tracked file. No gh, no network, no actionlint; perl for the
# literal-string mutations.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/skills/setup-deps/references/templates/dependabot-auto-merge.template.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

MINOR="steps.meta.outputs.update-type == 'version-update:semver-minor'"
PATCH="steps.meta.outputs.update-type == 'version-update:semver-patch'"
NOT_MINOR="steps.meta.outputs.update-type != 'version-update:semver-minor'"
NOT_PATCH="steps.meta.outputs.update-type != 'version-update:semver-patch'"
AUTHOR="github.event.pull_request.user.login == 'dependabot[bot]'"
ACTOR="github.actor == 'dependabot[bot]'"

# step_ifs <file> <pattern> — prints the `if:` line of every step whose body
# contains <pattern> (fixed string), one per line. Steps start at
# `      - name:` (6-space indent) — the template's only step indent.
step_ifs() {
    awk -v pat="$2" '
        function flush() { if (has && cond != "") print cond; else if (has) print "<no if>"; has = 0; cond = "" }
        /^      - name:/ { flush(); instep = 1; next }
        /^    [a-z]/     { flush(); instep = 0 }
        instep && /^        if:/ { cond = $0 }
        instep && index($0, pat) { has = 1 }
        END { flush() }
    ' "$1"
}

# check <file> — 0 when the policy holds, 1 (with reasons on stdout) otherwise.
check() {
    local f="$1" rc=0 job runs merges holds line

    job="$(grep -E '^    if:' "$f")"
    if [[ "$job" != *"$AUTHOR"* || "$job" != *"$ACTOR"* || "$job" != *"&&"* ]]; then
        echo "job if: must require author AND actor == dependabot[bot]: ${job:-<none>}"; rc=1
    fi

    runs="$(grep -E '^    runs-on:' "$f")"
    if [ "$runs" != "    runs-on: ubuntu-latest" ]; then
        echo "the job must hard-code runs-on: ubuntu-latest (no render fact, no self-hosted label): ${runs:-<none>}"; rc=1
    fi

    merges="$(step_ifs "$f" 'gh pr merge')"
    if [ -z "$merges" ]; then
        echo "no step runs 'gh pr merge' — the check would cover nothing"; rc=1
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" != *"$MINOR"* || "$line" != *"$PATCH"* || "$line" == *"!="* ]]; then
            echo "merge step must match minor/patch explicitly with == only: $line"; rc=1
        fi
    done <<<"$merges"

    holds="$(step_ifs "$f" 'held for a human')"
    if [ -z "$holds" ]; then
        echo "no hold step found"; rc=1
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" != *"$NOT_MINOR"* || "$line" != *"$NOT_PATCH"* || "$line" != *"&&"* || "$line" == *"=="* ]]; then
            echo "hold step must be the exact complement (!= minor && != patch): $line"; rc=1
        fi
    done <<<"$holds"
    return "$rc"
}

echo "auto-merge policy:"

if out="$(check "$TEMPLATE")"; then
    ok "template fails closed (explicit minor/patch, author+actor gate, complementary hold)"
    n="$(step_ifs "$TEMPLATE" 'gh pr merge' | wc -l | tr -d ' ')"
    ok "covered $n merge step(s)"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# --- mutations: each historical regression must fail the check ---------------
# mutate <name> <from> <to> — LITERAL replacement (perl \Q…\E): the patterns
# carry `[bot]`, `$`, `{` and `|`, which sed would read as regex syntax.
mutate() {
    local name="$1" m="$WORK/mutant.yml"
    FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$TEMPLATE" > "$m"
    if cmp -s "$m" "$TEMPLATE"; then
        bad "mutation ($name) changed nothing, so it proves nothing (template reworded?)"
    elif check "$m" >/dev/null; then
        bad "mutation ($name) PASSED the check — the gate cannot catch it"
    else
        ok "mutation ($name) fails the check"
    fi
}

MAJOR_NE="steps.meta.outputs.update-type != 'version-update:semver-major'"
MAJOR_EQ="steps.meta.outputs.update-type == 'version-update:semver-major'"
mutate "merge on != semver-major" "$MINOR || $PATCH" "$MAJOR_NE"
mutate "author-only job gate"     " && $ACTOR"        ""
mutate "hold only semver-major"   "$NOT_MINOR && $NOT_PATCH" "$MAJOR_EQ"
mutate "runner as a render fact"  'runs-on: ubuntu-latest' 'runs-on: {{RUNNER}}'
mutate "self-hosted runs-on"      'runs-on: ubuntu-latest' 'runs-on: [self-hosted, linux, sassy-dog]'

exit "$fail"
