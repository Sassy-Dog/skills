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
# Version 7 (#628) adds a fourth property: the DIRECT_MERGE arm chooses its merge
# method at run time. GitHub refuses a method the repo disallows, so the literal
# `--squash` it used to carry failed every Dependabot PR in a squash-disabled
# repo. Pinned source-level (no gh, no network): the direct arm's `gh pr merge`
# line is exactly `gh pr merge --auto "$method" --delete-branch "$PR_URL"` (so no
# literal method flag in any spelling, and "$method" is not dropped); the step reads
# squashMergeAllowed, mergeCommitAllowed and rebaseMergeAllowed; and it has an
# `exit 1` for an unreadable read and another for "no method allowed", each
# BEFORE the `gh pr merge` line. The merge-queue arm keeps plain `--auto`. These
# pins read the text, not the behaviour; the shell logic is shellchecked and
# actionlinted via test-template-actionlint.sh. The template's logic is NOT
# executed here. It shares with merge-shepherd.sh's merge_method() (whose
# behaviour test-poll-queue-eject.sh executes) the order squash, merge, rebase
# and failing closed on an unreadable or empty read. It does NOT share the
# multi-line-output rejection: merge_method() rejects it, the template's `read -r`
# takes the first line (`gh repo view` with that --jq always prints one line).
# Not pinned: the method ORDER and the malformed-output handling (text-level pins
# there would only restate the script).
#
# The #628 mutants: "hardcoded --squash restored", "short -s restored",
# 'dropped "$method"', "gh pr merge before the settings read", "no read of
# mergeCommitAllowed", "unreadable read does not exit", "no-method path falls
# through", "merge-queue arm gains a method flag". The "before the settings read"
# mutant also asserts that both its substitutions applied.
#
# Vacuous-green guard: zero merge steps found is a FAILURE (a renamed command
# or reflowed step would otherwise check nothing). Mutation-proof: every mutant
# is applied to a copy and must fail the check. They are: the three regressions
# above (merge on != semver-major, author-only job gate, hold only semver-major),
# the two runner mutants (a render-fact runner and a self-hosted runs-on; the
# runner is hard-coded ubuntu-latest), and the #628 mutants listed above.
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
    method_check "$f" || rc=1
    return "$rc"
}

# method_check <file> — the direct arm picks its merge method at run time.
method_check() {
    local f="$1" rc=0 step lines mline lastexit k ctx
    step="$(awk '/^      - name:/ { on = ($0 ~ /Auto-merge minor\/patch once checks pass/) } on' "$f")"
    if [ -z "$step" ]; then
        echo "no direct-merge step ('Auto-merge minor/patch once checks pass') found"; return 1
    fi
    lines="$(grep -E '^[[:space:]]*gh pr merge' <<<"$step")"
    if [ "$(grep -c . <<<"$lines")" != 1 ]; then
        echo "the direct-merge step must run exactly one gh pr merge"; rc=1
    fi
    # Pin the exact line. A regex over long flags alone let `-s` (short squash)
    # and a dropped "$method" (which refuses in a non-interactive run) through.
    if [ "$(sed 's/^[[:space:]]*//' <<<"$lines")" != 'gh pr merge --auto "$method" --delete-branch "$PR_URL"' ]; then
        echo "the direct-merge gh pr merge must be exactly: gh pr merge --auto \"\$method\" --delete-branch \"\$PR_URL\" (got: $lines)"; rc=1
    fi
    for k in squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed; do
        grep -q "$k" <<<"$step" || { echo "the direct-merge step does not read $k"; rc=1; }
    done
    grep -q 'Could not read the merge methods' <<<"$step" || { echo "no fail-closed exit for an unreadable settings read"; rc=1; }
    grep -q 'allows no merge method' <<<"$step" || { echo "no fail-closed exit for a repo that allows no method"; rc=1; }
    # Each of those messages must be followed by an `exit 1` on the next line,
    # and every exit must precede the merge line.
    ctx="$(grep -A1 'Could not read the merge methods' <<<"$step")"
    if ! grep -q 'exit 1' <<<"$ctx"; then
        echo "the unreadable-read path does not exit 1"; rc=1
    fi
    ctx="$(grep -A1 'allows no merge method' <<<"$step")"
    if ! grep -q 'exit 1' <<<"$ctx"; then
        echo "the no-method-allowed path does not exit 1"; rc=1
    fi
    mline="$(grep -nE '^[[:space:]]*gh pr merge' <<<"$step" | head -1 | cut -d: -f1)"
    lastexit="$(grep -n 'exit 1' <<<"$step" | tail -1 | cut -d: -f1)"
    if [ -z "$mline" ] || [ -z "$lastexit" ] || [ "$lastexit" -ge "$mline" ]; then
        echo "the direct-merge step's failure exits must all precede gh pr merge"; rc=1
    fi
    # The merge-queue arm keeps plain --auto with no method flag.
    if ! grep -qE '^        run: gh pr merge --auto "\$PR_URL"$' "$f"; then
        echo "the merge-queue arm must stay plain: gh pr merge --auto \"\$PR_URL\""; rc=1
    fi
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
    FROM="$2" TO="$3" perl -0777 -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$TEMPLATE" > "$m"
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

mutate "hardcoded --squash restored" 'gh pr merge --auto "$method" --delete-branch' 'gh pr merge --auto --squash --delete-branch'
mutate "short -s restored" 'gh pr merge --auto "$method" --delete-branch' 'gh pr merge --auto -s --delete-branch'
mutate 'dropped "$method"' 'gh pr merge --auto "$method" --delete-branch' 'gh pr merge --auto --delete-branch'
# Moving the merge above the settings read: delete the final merge line and
# re-insert it before the read, so only the exit-before-merge pin can catch it.
m="$WORK/mutant.yml"
perl -0777 -pe 's/\n( *)gh pr merge --auto "\$method" --delete-branch "\$PR_URL"\n/\n/; s/( *)(if ! settings=)/$1gh pr merge --auto "\$method" --delete-branch "\$PR_URL"\n$1$2/' "$TEMPLATE" > "$m"
# Both substitutions must have applied, or the mutant could pass for the wrong
# reason (only the delete, or only the insert): the merge line must now occur
# exactly once, and on an earlier line than the settings read.
mline='gh pr merge --auto "$method" --delete-branch "$PR_URL"'
mcount="$(grep -cF -- "$mline" "$m")"
mfirst="$(grep -nF -- "$mline" "$m" | head -n1 | cut -d: -f1)"
rfirst="$(grep -n 'if ! settings=' "$m" | head -n1 | cut -d: -f1)"
if cmp -s "$m" "$TEMPLATE"; then
    bad "mutation (gh pr merge before the settings read) changed nothing"
elif [ "$mcount" != 1 ] || [ -z "$mfirst" ] || [ -z "$rfirst" ] || [ "$mfirst" -ge "$rfirst" ]; then
    bad "mutation (gh pr merge before the settings read) did not apply both substitutions (merge line count $mcount, at line ${mfirst:-none}, read at ${rfirst:-none})"
elif check "$m" >/dev/null; then
    bad "mutation (gh pr merge before the settings read) PASSED the check"
else
    ok "mutation (gh pr merge before the settings read) fails the check"
fi
mutate "no read of mergeCommitAllowed" 'mergeCommitAllowed' 'mergeX'
mutate "unreadable read does not exit" 'Could not read the merge methods allowed on $REPO; not merging."
            exit 1' 'Could not read the merge methods allowed on $REPO; not merging."
            true'
mutate "no-method path falls through" 'Not merging."
            exit 1
          fi
          gh pr merge' 'Not merging."
          fi
          gh pr merge'
mutate "merge-queue arm gains a method flag" 'run: gh pr merge --auto "$PR_URL"' 'run: gh pr merge --auto --squash "$PR_URL"'

exit "$fail"
