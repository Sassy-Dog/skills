#!/usr/bin/env bash
# test-template-action-pins.sh — every action pinned in a setup-deps workflow
# template must equal the pin of the same action in
# .github/workflows/template-action-pins.yml, SHA and version comment both
# (issue #564).
#
# THE FAILURE. Dependabot's github-actions ecosystem scans only
# .github/workflows/, never skills/setup-deps/references/templates/. The
# templates therefore drifted behind every consumer repo's Dependabot
# (create-github-app-token v3.2.0 vs v3.3.0, flutter-action v2.21.0 vs
# v2.23.0), and each re-render handed a worker a silent downgrade of a
# security-relevant action: still a valid 40-hex SHA pin, so nothing flagged it.
#
# THE MECHANISM (option (a) on #564, chosen over a network gate against the
# latest release, which would fail on someone else's release schedule, and
# over teaching --compare-to to keep a newer pin, which fixes the symptom and
# leaves the templates stale). template-action-pins.yml is a never-run
# workflow whose only job is to hold one `uses:` line per template action, so
# this repo's own Dependabot bumps it. This gate then fails until the
# templates follow, in the same PR. Source-level: no gh, no network.
#
# DECISIONS THAT READ LIKE DRIFT AND ARE DELIBERATE.
#   * dtolnay/rust-toolchain is EXEMPT. Its pin comment is `# stable`, a
#     branch-style ref with no release version for Dependabot to compare, so it
#     cannot be tracked by the workflow. EXEMPT_ACTIONS below is the only place
#     that says so; the exempt action must still be a 40-hex SHA pin in the
#     templates, and must NOT appear in the workflow (an entry in both would be
#     a second, unenforced source of truth).
#   * The comment is compared, not only the SHA: Dependabot rewrites the
#     trailing `# vX.Y.Z` with the SHA, so a template whose SHA matches and
#     whose comment lags is a hand edit that lied about the version.
#   * The workflow's own safety shape is pinned too (manual trigger only, empty
#     permissions, a job `if:`, no `run:`, no secrets), because this repo is
#     PUBLIC and a later edit that "makes it do something" would run on fork
#     input. actionlint rejects a literal `if: false`, so the guard is an
#     event name that can never be true.
#
# VACUOUS-GREEN GUARDS. At least one template is found; at least one pin is
# read overall (deps-cadence.template.yml legitimately has none: it only calls a
# local reusable workflow); every workflow action is used by some template (a stale entry
# is not tracking anything); every template action is in the workflow or the
# exemption list.
#
# MUTATION PROOF. Each mutant below is applied to a scratch copy and must make
# the gate FAIL with its own reason: a bumped workflow SHA, a lagging comment, a
# downgraded template, an action missing from the workflow, a stale workflow
# entry, an unpinned template use, a new action the workflow lacks, each
# vacuous-green guard (no templates, no workflow pins, no template pin read), the
# exempt-action rule (an exempt action added to the workflow), and each unsafe
# workflow shape (a second trigger, workflow or job permissions, a run step, a
# secret, no job guard, a guard that can fire, a second unguarded job). The
# job guard must equal the literal never-true expression, not merely exist.
# 21 checks in all: the baseline plus 20 mutants.
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }
TEMPLATES_REL="skills/setup-deps/references/templates"
WORKFLOW_REL=".github/workflows/template-action-pins.yml"

# Space-separated; see the header for why each is here.
EXEMPT_ACTIONS="dtolnay/rust-toolchain"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }

# pins <file...> : one "action sha comment" line per remote `uses:`
pins() {
    sed -nE 's/^[[:space:]-]*(name:.*)?uses:[[:space:]]*([^@[:space:]]+)@([^[:space:]#]+)[[:space:]]*(#[[:space:]]*(.*))?$/\2 \3 \5/p' "$@" || true
}

# check <templates_dir> <workflow_file> : prints one reason per violation;
# empty output means clean.
check() {
    local tdir="$1" wf="$2" t n=0 tpins wpins action sha comment line
    local templates
    templates="$(ls "$tdir"/*.template.yml 2>/dev/null)"
    [ -n "$templates" ] || { echo "no templates found under $tdir"; return; }
    wpins="$(pins "$wf")"
    [ -n "$wpins" ] || echo "workflow pins no action"

    for t in $templates; do
        tpins="$(pins "$t")"
        while read -r action sha comment; do
            [ -n "$action" ] || continue
            n=$((n + 1))
            if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
                echo "$(basename "$t"): $action is not pinned to a 40-hex SHA"
                continue
            fi
            if [[ " $EXEMPT_ACTIONS " == *" $action "* ]]; then
                if grep -q "^$action " <<<"$wpins"; then
                    echo "exempt action $action appears in the workflow"
                fi
                continue
            fi
            line="$(grep "^$action " <<<"$wpins" | head -1)"
            if [ -z "$line" ]; then
                echo "$(basename "$t"): $action is missing from the workflow"
            elif [ "$line" != "$action $sha $comment" ]; then
                echo "$(basename "$t"): $action pin differs from the workflow (template '$sha $comment', workflow '${line#"$action "}')"
            fi
        done <<<"$tpins"
    done
    [ "$n" -gt 0 ] || echo "no template pin was read"

    # every workflow action is used by some template
    while read -r action sha comment; do
        [ -n "$action" ] || continue
        # shellcheck disable=SC2086
        if ! grep -qE "uses:[[:space:]]*$action@" $templates; then
            echo "workflow entry $action is used by no template"
        fi
    done <<<"$wpins"

    # the workflow's own safety shape
    if [ "$(sed -n '/^on:/,/^[a-z]/p' "$wf" | grep -cE '^  [a-z_]+:')" != "1" ] || ! grep -qE '^  workflow_dispatch:' "$wf"; then
        echo "workflow has a trigger besides workflow_dispatch"
    fi
    grep -qE '^permissions:[[:space:]]*\{\}[[:space:]]*$' "$wf" || echo "workflow permissions are not {}"
    if [ "$(sed -n '/^jobs:/,$p' "$wf" | grep -cE '^  [A-Za-z0-9_-]+:')" != "1" ]; then
        echo "workflow does not have exactly one job"
    fi
    guard="$(sed -nE 's/^    if:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$wf")"
    if [ -z "$guard" ]; then
        echo "workflow job has no if: guard"
    elif [ "$guard" != "github.event_name == 'never-fires'" ]; then
        echo "workflow job if: is not the never-true guard (got '$guard')"
    fi
    if grep -qE '^[[:space:]]+permissions:' "$wf"; then echo "workflow has a job-level permissions: block"; fi
    if grep -qE '^[[:space:]]*(-[[:space:]]*)?run:' "$wf"; then echo "workflow has a run: step"; fi
    if grep -qE 'secrets|GITHUB_TOKEN' "$wf"; then echo "workflow references a secret or token"; fi
}

echo "template-action-pins"
out="$(check "$REPO_ROOT/$TEMPLATES_REL" "$REPO_ROOT/$WORKFLOW_REL")"
if [ -z "$out" ]; then
    ok "every template pin equals the workflow pin (SHA and comment); exempt: $EXEMPT_ACTIONS"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# --- mutation proof -----------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
TARGET_TPL="lockfile-sync-bun.template.yml"

# mutate <label> <reason-substring> <tpl|wf> <perl -0 substitution>
mutate() {
    local label="$1" reason="$2" which="$3" sub="$4" out orig f
    rm -rf "$SCRATCH/t" "$SCRATCH/wf.yml"
    mkdir "$SCRATCH/t"
    cp "$REPO_ROOT/$TEMPLATES_REL"/*.template.yml "$SCRATCH/t/"
    cp "$REPO_ROOT/$WORKFLOW_REL" "$SCRATCH/wf.yml"
    if [ "$which" = empty ]; then
        rm -f "$SCRATCH/t"/*.template.yml
    elif [ "$which" = alltpl ]; then
        for f in "$SCRATCH/t"/*.template.yml; do perl -0pi -e "$sub" "$f"; done
    elif [ "$which" = wf ]; then
        orig="$REPO_ROOT/$WORKFLOW_REL"
        perl -0pi -e "$sub" "$SCRATCH/wf.yml"
        cmp -s "$SCRATCH/wf.yml" "$orig" && { bad "mutant '$label' did not apply"; return; }
    elif [ "$which" = tpl ]; then
        orig="$REPO_ROOT/$TEMPLATES_REL/$TARGET_TPL"
        perl -0pi -e "$sub" "$SCRATCH/t/$TARGET_TPL"
        cmp -s "$SCRATCH/t/$TARGET_TPL" "$orig" && { bad "mutant '$label' did not apply"; return; }
    fi
    out="$(check "$SCRATCH/t" "$SCRATCH/wf.yml")"
    if grep -qF -- "$reason" <<<"$out"; then
        ok "mutant caught: $label"
    else
        bad "mutant '$label' not caught for its own reason ('$reason'); got: ${out:-<clean>}"
    fi
}

mutate "workflow SHA bumped alone" "pin differs from the workflow" wf 's/(create-github-app-token@)[0-9a-f]{40}/${1}0000000000000000000000000000000000000000/'
mutate "workflow comment lags" "pin differs from the workflow" wf 's/# v2\.23\.0/# v2.21.0/'
mutate "template downgraded" "pin differs from the workflow" tpl 's/(oven-sh\/setup-bun@)[0-9a-f]{40} # v2\.2\.0/${1}1111111111111111111111111111111111111111 # v2.1.0/'
mutate "template action missing from workflow" "is missing from the workflow" wf 's/[^\n]*dependabot\/fetch-metadata[^\n]*\n//'
mutate "stale workflow entry" "is used by no template" wf 's/(      - uses: actions\/checkout[^\n]*\n)/$1      - uses: example\/unused\@2222222222222222222222222222222222222222 # v1.0.0\n/'
mutate "template use unpinned" "is not pinned to a 40-hex SHA" tpl 's/(oven-sh\/setup-bun@)[0-9a-f]{40}/${1}v2/'
mutate "template adopts an action the workflow lacks" "is missing from the workflow" tpl 's/(      - uses: oven-sh\/setup-bun[^\n]*\n)/$1      - uses: example\/new-action\@3333333333333333333333333333333333333333 # v1.0.0\n/'
mutate "workflow gains a second trigger" "besides workflow_dispatch" wf 's/(\n  workflow_dispatch:\n)/$1  pull_request:\n/'
mutate "workflow gains permissions" "permissions are not {}" wf 's/\npermissions: \{\}\n/\npermissions:\n  contents: write\n/'
mutate "workflow loses its job guard" "has no if: guard" wf 's/\n    if: [^\n]*//'
mutate "workflow job guard can fire" "is not the never-true guard" wf 's/(\n    if: )[^\n]*/$1github.event_name == \x27workflow_dispatch\x27/'
mutate "workflow gains an unguarded second job" "does not have exactly one job" wf 's/\z/\n  second:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions\/checkout\@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n/'
mutate "workflow job gains permissions" "job-level permissions: block" wf 's/(\n    runs-on: [^\n]*\n)/$1    permissions:\n      contents: write\n/'
mutate "workflow inherits secrets" "references a secret or token" wf 's/(\n    runs-on: [^\n]*\n)/$1    secrets: inherit\n/'
mutate "no templates found" "no templates found" empty ''
mutate "workflow pins no action" "workflow pins no action" wf 's/[^\n]*- uses: [^\n]*\n//g'
mutate "no template pin read" "no template pin was read" alltpl 's/uses:/used:/g'
mutate "exempt action added to workflow" "appears in the workflow" wf 's/(      - uses: actions\/checkout[^\n]*\n)/$1      - uses: dtolnay\/rust-toolchain\@4be7066ada62dd38de10e7b70166bc74ed198c30 # stable\n/'
mutate "workflow gains a run step" "has a run: step" wf 's/(\n    steps:\n)/$1      - run: echo hi\n/'
mutate "workflow references a secret" "references a secret or token" wf 's/(\n    runs-on: [^\n]*\n)/$1    env:\n      X: \${{ secrets.X }}\n/'

echo "template-action-pins: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
