#!/usr/bin/env bash
# test-lockfile-sync-policy.sh — pins the CREDENTIAL POLICY of setup-deps'
# lockfile-sync templates (issue #528 for bun, part of #515; #529 extends it to
# the pod template).
#
# The shape these templates had: a job on the persistent shared self-hosted
# fleet ({{RUNNER}}) that minted the org-wide platform-writer App token BEFORE
# checkout, ran the image's own bun on PR-authored manifests, and pushed with the
# token in the remote URL (argv). `--ignore-scripts` blocks lifecycle scripts,
# not a poisoned binary, so any earlier job on that machine, in any repo, could
# shadow bun or git, leave a global gitconfig hook or credential helper, or
# modify the tool cache, and capture the token. Every defect passes actionlint
# (the YAML and the shell are valid, just permissive), so this gate asserts the
# policy on the template source. It is modelled on test-deps-cadence-policy.sh
# property 9 and test-auto-merge-policy.sh, and reads no render: the properties
# are identical in every render arm (test-template-actionlint.sh proves the
# renders lint).
#
# Properties, per template (`check_common`, then the template's own toolchain
# check):
#
#   1. RUNNER. `runs-on: ubuntu-latest`, hard-coded: no `{{RUNNER}}` fact, no
#      `self-hosted` anywhere outside a comment. A fact would let a consumer
#      re-open the hole at render time.
#   2. MINT ORDER. The App token is minted after checkout and after EVERY
#      package-manager step, with the `Require the app credentials` presence
#      step immediately before the mint (test-visibility-preconditions.sh slices
#      both by name), and the push after the mint. Nothing before the mint
#      mentions the token action, steps.app_token, or the App secrets (the
#      presence step reads the secrets for its test only).
#   3. CHECKOUT carries `persist-credentials: false` and no `token:`.
#   4. NO TOKEN IN A URL OR ARGV. Every line that mentions GH_TOKEN is either
#      the one step-env binding to the minted token or the single-quoted
#      credential helper git's own shell expands; the empty helper
#      (`-c credential.helper=`) clears any other first; no URL carries
#      userinfo. Whole-file rather than push-step-only, so a token moved into a
#      continuation line, an http.extraheader or a second push is also caught.
#   5. GIT HARDENED. GIT_CONFIG_NOSYSTEM and GIT_CONFIG_GLOBAL=/dev/null are in
#      the job env (before the first step), and every git call other than
#      `git config` passes `"${nohooks[@]}"` with that array defined, with both
#      core.hooksPath=/dev/null and core.fsmonitor=false, in the same step.
#      A hook or fsmonitor program would inherit the push step's environment.
#   6. BUN (the bun template only). bun comes from oven-sh/setup-bun, SHA-pinned
#      with a version comment, in both render arms (BUN_PIN_FILE and
#      BUN_PIN_LITERAL), never the image's; an actions/cache step, SHA-pinned,
#      caches bun's install cache keyed on hashFiles of the install root's
#      bun.lock and runs before the first install (a miss is a cold install);
#      every `bun install` passes --ignore-scripts.
#
# Vacuous-green guards: the step table must find the checkout, the mint, the
# presence step, the push and at least two installs, or the check fails rather
# than covering nothing.
#
# Mutation-proof (a gate that cannot fail is decorative): one mutation per
# property is applied to a copy of the bun template and each must FAIL the
# check, and a mutation that changes nothing fails the gate (template reworded).
#   runner: a self-hosted label, and `{{RUNNER}}` back as a fact;
#   mint order: the mint moved before checkout, and between the two installs;
#   presence step: an interloper step between it and the mint;
#   token scope: persist-credentials true, and the token in an install's env;
#   URL/argv: the token in the push URL, in an extraheader, and the empty
#     helper dropped;
#   git: GIT_CONFIG_GLOBAL dropped, GIT_CONFIG_NOSYSTEM dropped, one git call
#     without nohooks, fsmonitor left on;
#   bun: setup-bun removed, setup-bun unpinned, cache removed, cache key not
#     tied to bun.lock, --ignore-scripts dropped.
#
# To extend to the pod template (#529): add `check_pod` (check_common with the
# pod template's package-manager pattern plus its toolchain check), call it on
# the pod template, and give it its own mutants.
#
# Reads one tracked file. No gh, no network, no actionlint; perl for the
# mutations. Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-lockfile-sync-policy.sh
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL_DIR="$ROOT/skills/setup-deps/references/templates"
BUN_TEMPLATE="$TPL_DIR/lockfile-sync-bun.template.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# load_steps <file> — fills STEP_BODY[0..N] (0 = everything before the first
# step) from the file with whole-line comments removed, and NSTEPS = N. A step
# starts at a 6-space `- ` list item (the templates' only step indent).
declare -a STEP_BODY
NSTEPS=0
load_steps() {
    local line idx=0 insteps=0
    STEP_BODY=("")
    NSTEPS=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *[![:space:]]*) ;;
            *) continue ;;
        esac
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [ "$line" = "    steps:" ] && insteps=1
        if [ "$insteps" -eq 1 ] && [[ "$line" =~ ^\ \ \ \ \ \ -\  ]]; then
            idx=$((idx + 1)); NSTEPS=$idx; STEP_BODY[$idx]=""
        fi
        STEP_BODY[$idx]+="$line"$'\n'
    done < "$1"
}

# find_step <glob-or-pattern> — prints the index of the first step whose body
# matches the fixed string, or nothing.
find_step() {
    local i
    for ((i = 1; i <= NSTEPS; i++)); do
        [[ "${STEP_BODY[$i]}" == *"$1"* ]] && { echo "$i"; return 0; }
    done
    return 1
}

# check_common <file> <package-manager-regex> — properties 1-5. 0 when the
# policy holds, 1 (reasons on stdout) otherwise.
check_common() {
    local f="$1" pm="$2" rc=0 i line body
    local checkout mint gate push installs=() nonc runs

    load_steps "$f"
    nonc="$(grep -Ev '^[[:space:]]*#' "$f")"

    # 1. runner
    runs="$(grep -E '^    runs-on:' "$f")"
    if [ "$runs" != "    runs-on: ubuntu-latest" ]; then
        echo "the job must hard-code runs-on: ubuntu-latest (no render fact, no self-hosted label): ${runs:-<none>}"; rc=1
    fi
    if grep -qF '{{RUNNER}}' <<<"$nonc" || grep -qi 'self-hosted' <<<"$nonc"; then
        echo "a {{RUNNER}} fact or a self-hosted label survives outside a comment"; rc=1
    fi

    # step table (vacuous-green guard)
    checkout="$(find_step 'actions/checkout@')" || checkout=""
    mint="$(find_step 'actions/create-github-app-token@')" || mint=""
    gate="$(find_step 'name: Require the app credentials')" || gate=""
    push="$(find_step ' push ')" || push=""
    for ((i = 1; i <= NSTEPS; i++)); do
        if grep -Eq "$pm" <<<"${STEP_BODY[$i]}"; then installs+=("$i"); fi
    done
    if [ -z "$checkout" ] || [ -z "$mint" ] || [ -z "$gate" ] || [ -z "$push" ] || [ "${#installs[@]}" -lt 2 ]; then
        echo "step table incomplete (checkout=${checkout:-?} mint=${mint:-?} gate=${gate:-?} push=${push:-?} installs=${#installs[@]}) — the check would cover nothing"
        return 1
    fi

    # 2. mint order
    if [ "$mint" -le "$checkout" ]; then
        echo "the App token is minted (step $mint) at or before checkout (step $checkout)"; rc=1
    fi
    for i in "${installs[@]}"; do
        if [ "$mint" -le "$i" ]; then
            echo "the App token is minted (step $mint) at or before a package-manager step (step $i)"; rc=1
        fi
    done
    if [ "$gate" -ne $((mint - 1)) ]; then
        echo "the 'Require the app credentials' step ($gate) is not immediately before the mint ($mint)"; rc=1
    fi
    if [ "$push" -le "$mint" ]; then
        echo "the push (step $push) is not after the mint (step $mint)"; rc=1
    fi
    for ((i = 0; i < mint; i++)); do
        body="${STEP_BODY[$i]}"
        if [[ "$body" == *'app_token'* || "$body" == *'create-github-app-token'* ]]; then
            echo "step $i (before the mint) mentions the token or the mint action"; rc=1
        fi
        if [ "$i" -ne "$gate" ] && [[ "$body" == *'PLATFORM_WRITER_APP'* ]]; then
            echo "step $i (before the mint) reads the App secrets"; rc=1
        fi
    done

    # 3. checkout
    body="${STEP_BODY[$checkout]}"
    if [[ "$body" != *'persist-credentials: false'* ]]; then
        echo "checkout does not set persist-credentials: false"; rc=1
    fi
    if grep -Eq '^[[:space:]]+token:' <<<"$body"; then
        echo "checkout passes a token:"; rc=1
    fi

    # 4. no token in a URL or argv
    while IFS= read -r line; do
        [[ "$line" == *GH_TOKEN* ]] || continue
        if [[ "$line" =~ ^[[:space:]]+GH_TOKEN:\ \$\{\{\ steps\.app_token\.outputs\.token\ \}\}$ ]]; then continue; fi
        if [[ "$line" == *"'credential.helper=!f()"* && "$line" == *'password=$GH_TOKEN'* ]]; then continue; fi
        echo "GH_TOKEN reaches somewhere other than the step env binding or the single-quoted credential helper: ${line# }"; rc=1
    done <<<"$nonc"
    if grep -Eq 'x-access-token:|://[^[:space:]"'"'"']*@' <<<"$nonc"; then
        echo "a URL carries userinfo (a token in the remote URL lands in argv)"; rc=1
    fi
    body="${STEP_BODY[$push]}"
    if ! grep -Eq -- '-c credential\.helper= ' <<<"$body"; then
        echo "the push does not clear other credential helpers first (-c credential.helper=)"; rc=1
    fi
    if [[ "$body" != *"'credential.helper=!f()"* ]]; then
        echo "the push does not use the env-reading credential helper"; rc=1
    fi
    if [[ "${STEP_BODY[$push]}" != *'GH_TOKEN: ${{ steps.app_token.outputs.token }}'* ]]; then
        echo "the push step does not bind GH_TOKEN to the minted token"; rc=1
    fi

    # 5. git hardened
    if [[ "${STEP_BODY[0]}" != *'GIT_CONFIG_NOSYSTEM: "1"'* ]]; then
        echo "GIT_CONFIG_NOSYSTEM=1 is not in the job env"; rc=1
    fi
    if [[ "${STEP_BODY[0]}" != *'GIT_CONFIG_GLOBAL: /dev/null'* ]]; then
        echo "GIT_CONFIG_GLOBAL=/dev/null is not in the job env"; rc=1
    fi
    for ((i = 1; i <= NSTEPS; i++)); do
        body="${STEP_BODY[$i]}"
        local uses_git=0
        while IFS= read -r line; do
            [[ "$line" =~ (^|[[:space:]])git[[:space:]] ]] || continue
            [[ "$line" =~ git[[:space:]]+config[[:space:]] ]] && continue
            uses_git=1
            if [[ "$line" != *'"${nohooks[@]}"'* ]]; then
                echo "step $i runs a git call without \"\${nohooks[@]}\": ${line# }"; rc=1
            fi
        done <<<"$body"
        if [ "$uses_git" -eq 1 ]; then
            if ! grep -Eq 'nohooks=\(-c core\.hooksPath=/dev/null -c core\.fsmonitor=false\)' <<<"$body"; then
                echo "step $i calls git but does not define nohooks with core.hooksPath=/dev/null and core.fsmonitor=false"; rc=1
            fi
        fi
    done
    return "$rc"
}

# check_bun <file> — the bun template: check_common plus property 6.
check_bun() {
    local f="$1" rc=0 nonc uses n cache first_install bodyfile i
    check_common "$f" 'bun install' || rc=1

    nonc="$(grep -Ev '^[[:space:]]*#' "$f")"
    uses="$(grep -E 'uses: oven-sh/setup-bun@' <<<"$nonc")"
    n="$(grep -c . <<<"$uses")"
    if [ -z "$uses" ] || [ "$n" -ne 2 ]; then
        echo "expected two setup-bun uses (the BUN_PIN_FILE and BUN_PIN_LITERAL arms), found $n"; rc=1
    elif grep -Evq '@[0-9a-f]{40} # v[0-9]' <<<"$uses"; then
        echo "a setup-bun use is not pinned to a 40-hex SHA with a version comment"; rc=1
    fi
    if ! grep -q 'bun-version-file:' <<<"$nonc" || ! grep -qE "bun-version: '" <<<"$nonc"; then
        echo "setup-bun does not take the repo's pin in both arms (bun-version-file / bun-version)"; rc=1
    fi
    if [ -z "$(grep -E '^[[:space:]]*#[[:space:]]*\{\{IF:BUN_PIN_FILE\}\}' "$f")" ] \
        || [ -z "$(grep -E '^[[:space:]]*#[[:space:]]*\{\{IF:BUN_PIN_LITERAL\}\}' "$f")" ]; then
        echo "the BUN_PIN_FILE / BUN_PIN_LITERAL render arms are missing"; rc=1
    fi

    cache="$(grep -E 'uses: actions/cache@' <<<"$nonc")"
    if [ -z "$cache" ]; then
        echo "no actions/cache step"; rc=1
    elif grep -Evq '@[0-9a-f]{40} # v[0-9]' <<<"$cache"; then
        echo "actions/cache is not pinned to a 40-hex SHA with a version comment"; rc=1
    fi
    if ! grep -Eq 'key:.*hashFiles\(.*bun\.lock' <<<"$nonc"; then
        echo "the cache key is not tied to hashFiles of bun.lock"; rc=1
    fi
    if ! grep -q '\.bun/install/cache' <<<"$nonc"; then
        echo "the cache path is not bun's install cache"; rc=1
    fi
    load_steps "$f"
    first_install="$(find_step 'bun install')" || first_install=""
    cache="$(find_step 'actions/cache@')" || cache=""
    if [ -n "$cache" ] && [ -n "$first_install" ] && [ "$cache" -ge "$first_install" ]; then
        echo "the cache step (step $cache) is not before the first bun install (step $first_install)"; rc=1
    fi
    for ((i = 1; i <= NSTEPS; i++)); do
        while IFS= read -r bodyfile; do
            [[ "$bodyfile" == *'bun install'* && "$bodyfile" != *'--ignore-scripts'* ]] \
                && { echo "a bun install runs without --ignore-scripts: ${bodyfile# }"; rc=1; }
        done <<<"${STEP_BODY[$i]}"
    done
    return "$rc"
}

echo "lockfile-sync policy (bun):"

if out="$(check_bun "$BUN_TEMPLATE")"; then
    ok "bun template: hosted runner, late mint, credential-helper push, git hardened, setup-bun and cache pinned"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# --- mutations: each property must fail the check when undone -----------------
# mutate <name> <from> <to> — LITERAL replacement (perl \Q…\E): the patterns
# carry `$`, `{`, `[` and `|`, which sed would read as regex syntax.
mutate() {
    local name="$1" m="$WORK/mutant.yml"
    FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$BUN_TEMPLATE" > "$m"
    verdict "$name" "$m"
}
# mutate_perl <name> <perl -0777 program> — a structural mutation.
mutate_perl() {
    local name="$1" m="$WORK/mutant.yml"
    perl -0777 -pe "$2" "$BUN_TEMPLATE" > "$m"
    verdict "$name" "$m"
}
verdict() {
    if cmp -s "$2" "$BUN_TEMPLATE"; then
        bad "mutation ($1) changed nothing, so it proves nothing (template reworded?)"
    elif check_bun "$2" >/dev/null; then
        bad "mutation ($1) PASSED the check — the gate cannot catch it"
    else
        ok "mutation ($1) fails the check"
    fi
}

# The presence + mint block runs from "Minted only now" to the push step's
# comment; the assertion step's comment opens the second install.
MOVE_BLOCK='(      \# Minted only now:.*?\n\n)(?=      \# The only step that needs repository write)'

# 1. runner
mutate "self-hosted runs-on"       'runs-on: ubuntu-latest' 'runs-on: [self-hosted, linux, sassy-dog]'
mutate "runner as a render fact"   'runs-on: ubuntu-latest' 'runs-on: {{RUNNER}}'

# 2. mint order
mutate_perl "mint before checkout" "s/(    steps:\n)(.*?)$MOVE_BLOCK/\$1\$3\$2/s"
mutate_perl "mint between the installs" "s/(      \# Fail-closed assertion.*?\n\n)$MOVE_BLOCK/\$2\$1/s"
mutate "interloper after the presence step" '      - name: Mint GitHub App token' $'      - name: Interloper\n        run: echo hi\n\n      - name: Mint GitHub App token'

# 3. checkout and token scope
mutate "checkout persists credentials" 'persist-credentials: false' 'persist-credentials: true'
mutate "checkout takes the token" 'repository: ${{ env.PR_HEAD_REPO }}' $'repository: ${{ env.PR_HEAD_REPO }}\n          token: ${{ steps.app_token.outputs.token }}'
mutate_perl "token in an install's env" 's/(      - name: Update bun\.lock for the bumped packages only\n)/$1        env:\n          GH_TOKEN: \${{ steps.app_token.outputs.token }}\n/'

# 4. URL and argv
mutate "token in the push URL" 'push "https://github.com/${PR_HEAD_REPO}.git"' 'push "https://x-access-token:${GH_TOKEN}@github.com/${PR_HEAD_REPO}.git"'
mutate "token in an extraheader" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer $GH_TOKEN" \\\n'
mutate "empty helper dropped" '-c credential.helper= ' ''

# 5. git hardened
mutate "global git config left on" '      GIT_CONFIG_GLOBAL: /dev/null' ''
mutate "system git config left on" '      GIT_CONFIG_NOSYSTEM: "1"' ''
mutate "git call without nohooks"  'git "${nohooks[@]}" add bun.lock' 'git add bun.lock'
mutate "fsmonitor left on"         ' -c core.fsmonitor=false)' ')'
mutate "hooksPath left on"         'nohooks=(-c core.hooksPath=/dev/null' 'nohooks=(-c core.hooksPath=.githooks'

# 6. bun
mutate "setup-bun removed"   'oven-sh/setup-bun@' 'oven-sh/setup-node@'
mutate "setup-bun unpinned"  'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2' 'oven-sh/setup-bun@v2'
mutate "cache removed"       'actions/cache@' 'actions/restore-nothing@'
mutate "cache key not tied to bun.lock" "hashFiles('{{PKG_DIR}}/bun.lock')" "github.sha"
mutate "install scripts enabled" 'bun install --ignore-scripts --frozen-lockfile' 'bun install --frozen-lockfile'

exit "$fail"
