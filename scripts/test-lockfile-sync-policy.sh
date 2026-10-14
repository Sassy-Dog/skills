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
# modify the tool cache, and capture the token. Template version 11 moved to a
# hosted runner with a late mint in ONE job; review rejected that, because a
# process bun starts can outlive its step and read a later-minted token from
# /proc/*/environ, $RUNNER_TEMP or step files (the rule deps-cadence v3 set).
# Version 12 is two jobs, and the gate pins the split. Every defect passes
# actionlint (the YAML and the shell are valid, just permissive), so this gate
# asserts the policy on the template source. It is modelled on
# test-deps-cadence-policy.sh property 9 and test-auto-merge-policy.sh, and
# reads no render: the properties are identical in every render arm
# (test-template-actionlint.sh proves the renders lint).
#
# The template has exactly two jobs, split by position: JOB 1 (token-free) runs
# the package manager and uploads a patch; JOB 2 (token) runs no package manager,
# validates the patch, mints and pushes. Properties (`check_common`, then the
# template's own toolchain check):
#
#   1. RUNNER. Both jobs `runs-on: ubuntu-latest`, hard-coded: no `{{RUNNER}}`
#      fact, no `self-hosted` anywhere outside a comment. A fact would let a
#      consumer re-open the hole at render time.
#   2. NO CACHE. No `actions/cache` anywhere. Under pull_request_target a save
#      lands in the default-branch cache scope, built from an install of the PR
#      head's lockfile: cache poisoning. This departs from #515's "actions/cache
#      keyed on bun.lock" decision on purpose; every run is a cold install.
#   3. ACTOR GATE. Both jobs' `if:` carry `github.actor == 'dependabot[bot]'`.
#   4. JOB 1 IS TOKEN-FREE. No `secrets.`, no PLATFORM_WRITER_APP, no
#      app_token, no mint action, no GH_TOKEN/GITHUB_TOKEN; job-level
#      `permissions: contents: read`; checkout persist-credentials: false and
#      no `token:`; the patch is `git diff HEAD --binary --no-renames
#      --no-ext-diff --no-textconv` of the one `{{PKG_DIR}}/bun.lock` pathspec,
#      uploaded by a SHA-pinned upload-artifact.
#   5. JOB 2 RUNS NO PACKAGE MANAGER. No setup-bun/setup-node and no bun, npm,
#      yarn, pnpm, pod or bundle command in a run: body. It is the VM that holds
#      the token, so nothing a package manager started may share it.
#   6. VALIDATE BEFORE THE MINT. Job 2 has a `Validate and apply` step before
#      the mint that reads the patch with `git apply --summary` (no create,
#      delete, rename or mode change) and `--numstat` (one file, not binary),
#      requires that path to EQUAL `allowed='{{PKG_DIR}}/bun.lock'` (the root
#      collapse included), requires a tracked regular file (`ls-files -s`, mode
#      100644 or 100755), applies with `git apply --index` and re-checks the
#      staged set is only that path. The artifact download is SHA-pinned.
#   7. MINT ORDER. In job 2 the App token is minted after checkout, after the
#      download and after validation, with the `Require the app credentials`
#      presence step immediately before the mint (test-visibility-preconditions
#      slices both by name), and the push after the mint. Nothing before the mint
#      mentions the token action, steps.app_token, or the App secrets (the
#      presence step reads the secrets for its test only).
#   8. CHECKOUT (both jobs) carries `persist-credentials: false` and no `token:`.
#   9. NO TOKEN IN A URL OR ARGV. `steps.app_token.outputs.token` occurs EXACTLY
#      ONCE in the file, as the push step's `GH_TOKEN:` binding: a second
#      binding (GITHUB_TOKEN, an inlined extraheader or `-c url...` use) is the
#      defect. Every line that mentions GH_TOKEN is either that binding or the
#      single-quoted credential helper git's own shell expands; the empty helper
#      (`-c credential.helper=`) clears any other first; no URL carries
#      userinfo. Whole-file, so a token moved into a continuation line or a
#      second push is also caught.
#  10. GIT HARDENED, per job. GIT_CONFIG_NOSYSTEM and GIT_CONFIG_GLOBAL=/dev/null
#      are in the job env (before the first step), and every git call other than
#      `git config` passes `"${nohooks[@]}"` with that array defined, with both
#      core.hooksPath=/dev/null and core.fsmonitor=false, in the same step.
#      A hook or fsmonitor program would inherit the push step's environment.
#  11. BUN (the bun template only). bun comes from oven-sh/setup-bun, SHA-pinned
#      with a version comment, in both render arms (BUN_PIN_FILE and
#      BUN_PIN_LITERAL), never the image's; every `bun install` passes
#      --ignore-scripts.
#
# Vacuous-green guards: the template must split into exactly two jobs, and each
# job's step table must find what it is checked for (job 1: checkout and at least
# two installs; job 2: checkout, download, validate, presence step, mint, push),
# or the check fails rather than covering nothing.
#
# Mutation-proof (a gate that cannot fail is decorative): one mutation per
# property is applied to a copy of the bun template and each must FAIL the check
# WITH the expected reason (a mutation that fails for some other reason proves
# nothing), a mutation that changes nothing fails the gate (template reworded),
# and a perl that is missing, exits non-zero or writes an empty mutant fails the
# gate rather than letting a broken mutation pass vacuously.
#
# To extend to the pod template (#529): add `check_pod` (check_common with the
# pod template's package-manager pattern plus its toolchain check), call it on
# the pod template, and give it its own mutants. check_common's job-2 rules name
# the bun.lock path through a parameter-free `allowed=` literal match, so a pod
# template will need that literal passed in.
#
# Reads one tracked file. No gh, no network, no actionlint; perl for the
# mutations. Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-lockfile-sync-policy.sh
set -uo pipefail
export LC_ALL=C

command -v perl >/dev/null 2>&1 || { echo "  FAIL perl is required for the mutations and is not on PATH"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL_DIR="$ROOT/skills/setup-deps/references/templates"
BUN_TEMPLATE="$TPL_DIR/lockfile-sync-bun.template.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# load_steps <job file> — fills STEP_BODY[0..N] (0 = everything before the first
# step, the job header and env included) from the file with whole-line comments
# removed, and NSTEPS = N. A step starts at a 6-space `- ` list item (the
# templates' only step indent).
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

# find_step <fixed string> — prints the index of the first step whose body
# contains it, or nothing.
find_step() {
    local i
    for ((i = 1; i <= NSTEPS; i++)); do
        [[ "${STEP_BODY[$i]}" == *"$1"* ]] && { echo "$i"; return 0; }
    done
    return 1
}

# split_jobs <file> <dir> — writes <dir>/job1.yml .. jobN.yml (each job's
# header line to the line before the next) and prints N.
split_jobs() {
    rm -f "$2"/job*.yml
    awk -v dir="$2" '
        /^jobs:/ { injobs = 1; next }
        injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { n++ }
        injobs && n > 0 { print > (dir "/job" n ".yml") }
        END { print n + 0 }
    ' "$1"
}

# check_git_hardened <job label> — property 10 over the loaded STEP_BODY.
check_git_hardened() {
    local label="$1" rc=0 i body line uses_git
    if [[ "${STEP_BODY[0]}" != *'GIT_CONFIG_NOSYSTEM: "1"'* ]]; then
        echo "$label: GIT_CONFIG_NOSYSTEM=1 is not in the job env"; rc=1
    fi
    if [[ "${STEP_BODY[0]}" != *'GIT_CONFIG_GLOBAL: /dev/null'* ]]; then
        echo "$label: GIT_CONFIG_GLOBAL=/dev/null is not in the job env"; rc=1
    fi
    for ((i = 1; i <= NSTEPS; i++)); do
        body="${STEP_BODY[$i]}"
        uses_git=0
        while IFS= read -r line; do
            [[ "$line" =~ (^|[[:space:]])git[[:space:]] ]] || continue
            [[ "$line" =~ git[[:space:]]+config[[:space:]] ]] && continue
            uses_git=1
            if [[ "$line" != *'"${nohooks[@]}"'* ]]; then
                echo "$label: step $i runs a git call without \"\${nohooks[@]}\": ${line# }"; rc=1
            fi
        done <<<"$body"
        if [ "$uses_git" -eq 1 ]; then
            if ! grep -Eq 'nohooks=\(-c core\.hooksPath=/dev/null -c core\.fsmonitor=false\)' <<<"$body"; then
                echo "$label: step $i calls git but does not define nohooks with core.hooksPath=/dev/null and core.fsmonitor=false"; rc=1
            fi
        fi
    done
    return "$rc"
}

# check_checkout <job label> — property 8 over the loaded STEP_BODY.
check_checkout() {
    local label="$1" rc=0 co body
    co="$(find_step 'actions/checkout@')" || co=""
    [ -n "$co" ] || { echo "$label: no checkout step — the check would cover nothing"; return 1; }
    body="${STEP_BODY[$co]}"
    [[ "$body" == *'persist-credentials: false'* ]] || { echo "$label: checkout does not set persist-credentials: false"; rc=1; }
    if grep -Eq '^[[:space:]]+token:' <<<"$body"; then echo "$label: checkout passes a token:"; rc=1; fi
    return "$rc"
}

# check_common <file> <job-1 package-manager regex> — properties 1-10. 0 when
# the policy holds, 1 (reasons on stdout) otherwise.
check_common() {
    local f="$1" pm="$2" rc=0 d="$WORK/split" i line body nonc runs n
    local checkout download validate gate mint push installs=() j1 j2 uploads patch gateline
    # A package manager at command position: line start (after run:), or after
    # && ; | or $( — not a word inside a quoted message.
    local pm2='(^[[:space:]]*(run:[[:space:]]+)?|&&[[:space:]]*|;[[:space:]]*|\|[[:space:]]*|\$\([[:space:]]*)(bun|bunx|npm|npx|yarn|pnpm|pod|bundle)([[:space:]]|$)'

    mkdir -p "$d"
    n="$(split_jobs "$f" "$d")"
    if [ "$n" != "2" ]; then
        echo "expected exactly two jobs (token-free update, token push), found $n — the check would cover nothing"
        return 1
    fi
    j1="$d/job1.yml"; j2="$d/job2.yml"
    nonc="$(grep -Ev '^[[:space:]]*#' "$f")"

    # 1. runner
    runs="$(grep -E '^    runs-on:' "$f")"
    if [ "$(grep -c . <<<"$runs")" -ne 2 ] || [ "$(sort -u <<<"$runs")" != "    runs-on: ubuntu-latest" ]; then
        echo "both jobs must hard-code runs-on: ubuntu-latest (no render fact, no self-hosted label): ${runs//$'\n'/ | }"; rc=1
    fi
    if grep -qF '{{RUNNER}}' <<<"$nonc" || grep -qi 'self-hosted' <<<"$nonc"; then
        echo "a {{RUNNER}} fact or a self-hosted label survives outside a comment"; rc=1
    fi

    # 2. no cache
    if grep -Eqi 'actions/cache|restore-keys|\.bun/install/cache' <<<"$nonc"; then
        echo "an actions/cache step (or a cache path) is present: a save under pull_request_target poisons the default-branch cache scope"; rc=1
    fi

    # 3. actor gate, on both jobs
    for i in 1 2; do
        gateline="$(grep -E '^    if:' "$d/job$i.yml")"
        if ! grep -qF "github.actor == 'dependabot[bot]'" <<<"$gateline"; then
            echo "job $i has no github.actor == 'dependabot[bot]' actor gate in its if:"; rc=1
        fi
    done

    # 9 (whole file). The token occurs once, as the push step's GH_TOKEN binding.
    n="$(grep -o 'steps\.app_token\.outputs\.token' <<<"$nonc" | wc -l | tr -d ' ')"
    if [ "$n" != "1" ]; then
        echo "steps.app_token.outputs.token must occur exactly once (the push step's GH_TOKEN binding), found $n"; rc=1
    fi
    while IFS= read -r line; do
        [[ "$line" == *GH_TOKEN* ]] || continue
        if [[ "$line" =~ ^[[:space:]]+GH_TOKEN:\ \$\{\{\ steps\.app_token\.outputs\.token\ \}\}$ ]]; then continue; fi
        if [[ "$line" == *"'credential.helper=!f()"* && "$line" == *'password=$GH_TOKEN'* ]]; then continue; fi
        echo "GH_TOKEN reaches somewhere other than the step env binding or the single-quoted credential helper: ${line# }"; rc=1
    done <<<"$nonc"
    if grep -Eq 'x-access-token:|://[^[:space:]"'"'"']*@' <<<"$nonc"; then
        echo "a URL carries userinfo (a token in the remote URL lands in argv)"; rc=1
    fi

    # ---- job 1: the token-free package-manager job ---------------------------
    load_steps "$j1"
    check_checkout "job 1" || rc=1
    check_git_hardened "job 1" || rc=1
    for ((i = 1; i <= NSTEPS; i++)); do
        grep -Eq "$pm" <<<"${STEP_BODY[$i]}" && installs+=("$i")
    done
    if [ "${#installs[@]}" -lt 2 ]; then
        echo "job 1: found ${#installs[@]} package-manager step(s), expected at least two — the check would cover nothing"; return 1
    fi
    body="$(grep -Ev '^[[:space:]]*#' "$j1")"
    if grep -Eq 'secrets\.|PLATFORM_WRITER_APP|app_token|create-github-app-token|GH_TOKEN|GITHUB_TOKEN' <<<"$body"; then
        echo "job 1 (the token-free job that runs the package manager) names a secret, the App token, the mint action or a token variable"; rc=1
    fi
    if [[ "${STEP_BODY[0]}" != *$'\n    permissions:\n      contents: read\n'* ]]; then
        echo "job 1 does not set job-level permissions: contents: read"; rc=1
    fi
    if grep -Eq '^      [a-z-]+: (write|admin)' <<<"$body"; then
        echo "job 1 grants a write permission"; rc=1
    fi
    patch="$(find_step 'id: patch')" || patch=""
    if [ -z "$patch" ] || [[ "${STEP_BODY[$patch]}" != *'diff HEAD --binary --no-renames --no-ext-diff --no-textconv'* ]]; then
        echo "job 1 does not package the change with git diff HEAD --binary --no-renames --no-ext-diff --no-textconv"; rc=1
    elif [[ "${STEP_BODY[$patch]}" != *"-- '{{PKG_DIR}}/bun.lock'"* ]]; then
        echo "job 1's patch is not limited to the one '{{PKG_DIR}}/bun.lock' pathspec"; rc=1
    fi
    uploads="$(grep -E 'uses: actions/upload-artifact@' <<<"$body")"
    if [ "$(grep -c . <<<"$uploads")" -ne 1 ] || grep -Evq '@[0-9a-f]{40} # v[0-9]' <<<"$uploads"; then
        echo "job 1 must upload the patch with exactly one SHA-pinned (40-hex plus version comment) actions/upload-artifact"; rc=1
    fi

    # ---- job 2: the token job ------------------------------------------------
    load_steps "$j2"
    check_checkout "job 2" || rc=1
    check_git_hardened "job 2" || rc=1
    checkout="$(find_step 'actions/checkout@')" || checkout=""
    download="$(find_step 'actions/download-artifact@')" || download=""
    validate="$(find_step 'name: Validate and apply')" || validate=""
    gate="$(find_step 'name: Require the app credentials')" || gate=""
    mint="$(find_step 'actions/create-github-app-token@')" || mint=""
    push="$(find_step ' push ')" || push=""
    if [ -z "$checkout" ] || [ -z "$download" ] || [ -z "$validate" ] || [ -z "$gate" ] || [ -z "$mint" ] || [ -z "$push" ]; then
        echo "job 2 step table incomplete (checkout=${checkout:-?} download=${download:-?} validate=${validate:-?} gate=${gate:-?} mint=${mint:-?} push=${push:-?}) — the check would cover nothing"
        return 1
    fi

    # 5. no package manager on the token VM
    body="$(grep -Ev '^[[:space:]]*#' "$j2")"
    if grep -Eq 'uses: (oven-sh|actions)/setup-' <<<"$body" || grep -Eq "$pm2" <<<"$body" || grep -Eq "$pm" <<<"$body"; then
        echo "job 2 (the token job) runs a package manager or a setup-* toolchain action: $(grep -E "uses: (oven-sh|actions)/setup-|$pm2" <<<"$body" | head -1 | sed 's/^ *//')"; rc=1
    fi

    # 6. validate before the mint
    if [ "$validate" -ge "$mint" ]; then
        echo "the patch is validated (step $validate) at or after the mint (step $mint)"; rc=1
    fi
    if [ "$download" -ge "$validate" ]; then
        echo "the artifact is downloaded (step $download) at or after validation (step $validate)"; rc=1
    fi
    body="${STEP_BODY[$download]}"
    if ! grep -Eq 'uses: actions/download-artifact@[0-9a-f]{40} # v[0-9]' <<<"$body"; then
        echo "actions/download-artifact is not pinned to a 40-hex SHA with a version comment"; rc=1
    fi
    body="${STEP_BODY[$validate]}"
    if [[ "$body" != *"allowed='{{PKG_DIR}}/bun.lock'"* ]]; then
        echo "the validator's allowed path is not exactly '{{PKG_DIR}}/bun.lock'"; rc=1
    fi
    if [[ "$body" != *'[ "$path" = "$allowed" ]'* ]]; then
        echo "the validator does not require the patched path to EQUAL the allowed path"; rc=1
    fi
    [[ "$body" == *'apply --summary'* ]] || { echo "the validator does not read the patch with git apply --summary (create/delete/rename/mode)"; rc=1; }
    [[ "$body" == *'apply --numstat'* ]] || { echo "the validator does not read the patch with git apply --numstat (binary, path)"; rc=1; }
    [[ "$body" == *'wc -l'* && "$body" == *'-eq 1'* ]] || { echo "the validator does not require exactly one patched file"; rc=1; }
    [[ "$body" == *'ls-files -s'* && "$body" == *100644* ]] || { echo "the validator does not require a tracked regular file (ls-files -s, mode 100644/100755)"; rc=1; }
    [[ "$body" == *'apply --index'* ]] || { echo "the validator does not apply the patch with git apply --index"; rc=1; }
    [[ "$body" == *'diff --cached --name-only'* ]] || { echo "the validator does not re-check the staged set after applying"; rc=1; }

    # 7. mint order
    if [ "$mint" -le "$checkout" ]; then
        echo "the App token is minted (step $mint) at or before checkout (step $checkout)"; rc=1
    fi
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

    # 9 (push step). The helper form and the single binding.
    body="${STEP_BODY[$push]}"
    if ! grep -Eq -- '-c credential\.helper= ' <<<"$body"; then
        echo "the push does not clear other credential helpers first (-c credential.helper=)"; rc=1
    fi
    if [[ "$body" != *"'credential.helper=!f()"* ]]; then
        echo "the push does not use the env-reading credential helper"; rc=1
    fi
    if [[ "$body" != *'GH_TOKEN: ${{ steps.app_token.outputs.token }}'* ]]; then
        echo "the push step does not bind GH_TOKEN to the minted token"; rc=1
    fi
    return "$rc"
}

# check_bun <file> — the bun template: check_common plus property 11.
check_bun() {
    local f="$1" rc=0 nonc uses n i line
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
    while IFS= read -r line; do
        [[ "$line" == *'bun install'* && "$line" != *'--ignore-scripts'* ]] \
            && { echo "a bun install runs without --ignore-scripts: ${line# }"; rc=1; }
    done <<<"$nonc"
    return "$rc"
}

echo "lockfile-sync policy (bun):"

if out="$(check_bun "$BUN_TEMPLATE")"; then
    ok "bun template: two jobs on hosted runners, token-free install job, validate-then-mint push job, single token binding, no cache, git hardened, setup-bun pinned"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# --- mutations: each property must fail the check when undone -----------------
# Each mutant must fail WITH the expected reason (a substring of the check's
# output); a mutant that fails for some other reason proves nothing.
#
# mutate <name> <want> <from> <to> — LITERAL replacement (perl \Q…\E): the
# patterns carry `$`, `{`, `[` and `|`, which sed would read as regex syntax.
mutate() {
    local name="$1" want="$2" m="$WORK/mutant.yml"
    if ! FROM="$3" TO="$4" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$BUN_TEMPLATE" > "$m"; then
        bad "mutation ($name): perl exited non-zero, so the mutant is meaningless"; return
    fi
    verdict "$name" "$want" "$m"
}
# mutate_perl <name> <want> <perl -0777 program> — a structural mutation.
mutate_perl() {
    local name="$1" want="$2" m="$WORK/mutant.yml"
    if ! perl -0777 -pe "$3" "$BUN_TEMPLATE" > "$m"; then
        bad "mutation ($name): perl exited non-zero, so the mutant is meaningless"; return
    fi
    verdict "$name" "$want" "$m"
}
verdict() {
    local out
    if [ ! -s "$3" ]; then
        bad "mutation ($1) produced an empty mutant, so it proves nothing"
    elif cmp -s "$3" "$BUN_TEMPLATE"; then
        bad "mutation ($1) changed nothing, so it proves nothing (template reworded?)"
    elif out="$(check_bun "$3")"; then
        bad "mutation ($1) PASSED the check — the gate cannot catch it"
    elif ! grep -qF -- "$2" <<<"$out"; then
        bad "mutation ($1) failed, but not for the expected reason ($2): $(head -1 <<<"$out")"
    else
        ok "mutation ($1) fails the check"
    fi
}

J2='push-bun-lock:.*?'
# The validate step (its leading comment through its last line), the presence +
# mint block, and the push step's leading comment.
VALIDATE_BLOCK='(      \# Every rule here is about the patch.*?\n\n)'
MINT_BLOCK='(      \# Minted only now:.*?\n\n)'
PUSH_COMMENT='(?=      \# The only step that needs repository write)'

# 1. runner
mutate "self-hosted runs-on (both jobs)" "hard-code runs-on" 'runs-on: ubuntu-latest' 'runs-on: [self-hosted, linux, sassy-dog]'
mutate_perl "self-hosted runs-on (token job only)" "hard-code runs-on" "s/(${J2}runs-on: )ubuntu-latest/\${1}[self-hosted, linux]/s"
mutate "runner as a render fact" "{{RUNNER}} fact" 'runs-on: ubuntu-latest' 'runs-on: {{RUNNER}}'

# 2. no cache
mutate_perl "actions/cache re-added" "actions/cache" 's/(      \# Restore the BASE branch.s bun\.lock)/      - uses: actions\/cache\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: ~\/.bun\/install\/cache\n          key: bun-\${{ runner.os }}-\${{ hashFiles(\x27{{PKG_DIR}}\/bun.lock\x27) }}\n\n$1/'
mutate_perl "cache re-added to the token job" "actions/cache" 's/(      - uses: actions\/download-artifact)/      - uses: actions\/cache\/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: y\n\n$1/'

# 3. actor gate
mutate "actor gate dropped from job 1" "job 1 has no" "    if: \${{ github.actor == 'dependabot[bot]' }}" '    if: ${{ true }}'
mutate "actor gate dropped from job 2" "job 2 has no" "github.actor == 'dependabot[bot]' && needs" 'needs'

# 4. job 1 is token-free
mutate_perl "token in an install's env" "token-free" 's/(      - name: Update bun\.lock for the bumped packages only\n)/$1        env:\n          GH_TOKEN: \${{ steps.app_token.outputs.token }}\n/'
mutate_perl "App secret in job 1's env" "token-free" 's/(    steps:\n)/    env:\n      PLATFORM_WRITER_APP_PRIVATE_KEY: \${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n$1/'
mutate_perl "mint action in job 1" "token-free" 's/(      - name: Assert the lock is frozen-valid\n)/      - uses: actions\/create-github-app-token\@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n\n$1/'
mutate_perl "job 1 loses contents: read" "contents: read" 's/(    timeout-minutes: 15\n    permissions:\n      contents: )read/$1write/'
mutate_perl "job 1 patch not limited to bun.lock" "pathspec" "s/ -- '\\{\\{PKG_DIR\\}\\}\\/bun\\.lock' >/ >/"
mutate "job 1 patch with textconv allowed" "diff HEAD --binary" ' --no-textconv --' ' -- '
mutate_perl "job 1 upload unpinned" "upload-artifact" 's/upload-artifact\@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7\.0\.2/upload-artifact\@v7/'

# 5. job 2 runs no package manager
mutate_perl "bun install in the token job" "package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: bun install --ignore-scripts\n\n$1/'
mutate_perl "npm in the token job" "package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: cd x \&\& npm ci\n\n$1/'
mutate_perl "setup-bun in the token job" "package manager" "s/(${J2})(      - uses: actions\\/download-artifact)/\$1      - uses: oven-sh\\/setup-bun\\\@0c5077e51419868618aeaa5fe8019c62421857d6 # v2\n\n\$2/s"

# 6. validate before the mint
mutate_perl "validate moved after the mint" "is validated (step" "s/$VALIDATE_BLOCK$MINT_BLOCK$PUSH_COMMENT/\$2\$1/s"
mutate "allowed path widened to the directory" "allowed path" "allowed='{{PKG_DIR}}/bun.lock'" "allowed='{{PKG_DIR}}/'"
mutate "path match loosened to a glob" "EQUAL" '[ "$path" = "$allowed" ]' '[[ "$path" == *bun.lock ]]'
mutate "apply --summary dropped" "--summary" 'apply --summary' 'apply --stat'
mutate "apply --numstat dropped" "--numstat" 'apply --numstat' 'apply --stat'
mutate "single-file rule dropped" "exactly one patched file" '-eq 1 ]' '-ge 1 ]'
mutate "regular-file mode check dropped" "regular file" 'ls-files -s' 'ls-files'
mutate "apply --index dropped" "apply --index" 'apply --index' 'apply --3way'
mutate "staged re-check dropped" "staged set" 'diff --cached --name-only)" = ' 'diff --cached --quiet)" = '
mutate "artifact download unpinned" "download-artifact" 'download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2' 'download-artifact@v8'

# 7. mint order
mutate_perl "mint before checkout" "checkout" "s/(${J2}    steps:\n)(.*?)$MINT_BLOCK$PUSH_COMMENT/\$1\$3\$2/s"
mutate "interloper after the presence step" "immediately before the mint" '      - name: Mint GitHub App token' $'      - name: Interloper\n        run: echo hi\n\n      - name: Mint GitHub App token'
mutate_perl "push before the mint" "push" 's/(      - name: Mint GitHub App token\n.*?\n\n)(      \# The only step that needs repository write.*)\z/$2\n$1/s'
mutate_perl "App secret read before the presence step" "reads the App secrets" 's/(      - name: Validate and apply the lockfile patch\n)/$1        env:\n          LEAK: \${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n/'

# 8. checkout and token scope
mutate "checkout persists credentials (both jobs)" "persist-credentials" 'persist-credentials: false' 'persist-credentials: true'
mutate_perl "token job checkout persists credentials" "job 2: checkout does not set" "s/(${J2}persist-credentials: )false/\$1true/s"
mutate "checkout takes the token" "checkout passes a token" 'repository: ${{ env.PR_HEAD_REPO }}' $'repository: ${{ env.PR_HEAD_REPO }}\n          token: ${{ steps.app_token.outputs.token }}'

# 9. URL, argv and the single binding
mutate "token in the push URL" "userinfo" 'push "https://github.com/${PR_HEAD_REPO}.git"' 'push "https://x-access-token:${GH_TOKEN}@github.com/${PR_HEAD_REPO}.git"'
mutate "token in an extraheader" "GH_TOKEN reaches" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer $GH_TOKEN" \\\n'
mutate "token inlined into an extraheader" "exactly once" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer ${{ steps.app_token.outputs.token }}" \\\n'
mutate "token inlined into a url rewrite" "exactly once" $'-c credential.helper= \\\n' $'-c credential.helper= -c "url.https://x:${{ steps.app_token.outputs.token }}@github.com/.insteadOf=https://github.com/" \\\n'
mutate "second binding of the token" "exactly once" $'          GH_TOKEN: ${{ steps.app_token.outputs.token }}\n' $'          GH_TOKEN: ${{ steps.app_token.outputs.token }}\n          GITHUB_TOKEN: ${{ steps.app_token.outputs.token }}\n'
mutate "push missing its GH_TOKEN binding" "bind GH_TOKEN" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}' 'GH_TOKEN: nothing'
mutate "env-reading helper form missing" "env-reading credential helper" "'credential.helper=!f()" "'credential.helper=!g()"
mutate "empty helper dropped" "credential helpers first" '-c credential.helper= ' ''

# 10. git hardened
mutate "global git config left on (both jobs)" "GIT_CONFIG_GLOBAL" '      GIT_CONFIG_GLOBAL: /dev/null' ''
mutate "system git config left on (both jobs)" "GIT_CONFIG_NOSYSTEM" '      GIT_CONFIG_NOSYSTEM: "1"' ''
mutate "git call without nohooks (job 1)" "without" 'git "${nohooks[@]}" diff HEAD' 'git diff HEAD'
mutate "git call without nohooks (job 2)" "without" 'git "${nohooks[@]}" commit' 'git commit'
mutate "fsmonitor left on" "core.fsmonitor" ' -c core.fsmonitor=false)' ')'
mutate "hooksPath left on" "core.hooksPath" 'nohooks=(-c core.hooksPath=/dev/null' 'nohooks=(-c core.hooksPath=.githooks'

# 11. bun
mutate "setup-bun removed" "setup-bun" 'oven-sh/setup-bun@' 'oven-sh/setup-node@'
mutate "setup-bun unpinned" "setup-bun use is not pinned" 'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2' 'oven-sh/setup-bun@v2'
mutate "install scripts enabled" "without --ignore-scripts" 'bun install --ignore-scripts --frozen-lockfile' 'bun install --frozen-lockfile'

exit "$fail"
