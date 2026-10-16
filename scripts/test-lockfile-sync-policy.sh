#!/usr/bin/env bash
# test-lockfile-sync-policy.sh — pins the CREDENTIAL POLICY of setup-deps'
# lockfile-sync templates: bun (issue #528, part of #515) and pod (#529, the same
# shape; its decision is on #515: GitHub-hosted macOS, the ~10x minute cost
# accepted).
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
# Version 12 is two jobs, and the gate pins the split; pod v7 took that shape
# directly rather than #529's single-job description, since `pod install`
# evaluates Podfile and podspec Ruby and so must never share a VM with the token.
# Every defect passes actionlint (the YAML and the shell are valid, just permissive), so this gate
# asserts the policy on the template source. It is modelled on
# test-deps-cadence-policy.sh property 9 and test-auto-merge-policy.sh, and
# reads no render: the properties are identical in every render arm
# (test-template-actionlint.sh proves the renders lint).
#
# Each template has exactly two jobs, split by position: JOB 1 (token-free) runs
# the package manager and uploads a patch; JOB 2 (token) runs no package manager,
# validates the patch, mints and pushes. Properties (`check_common`, driven by
# the C_* facts each `check_<template>` sets, then the template's own toolchain
# check and its executed validator):
#
#   1. RUNNER. Each job's `runs-on` is hard-coded and exact: bun, ubuntu-latest
#      on both; pod, macos-latest on job 1 (the only job that needs macOS) and
#      ubuntu-latest on job 2, which may name macOS nowhere. No `{{RUNNER}}`
#      fact, no `self-hosted` anywhere outside a comment. A fact would let a
#      consumer re-open the hole at render time.
#   2. NO CACHE. No `actions/cache` anywhere. Under pull_request_target a save
#      lands in the default-branch cache scope, built from an install of the PR
#      head's lockfile: cache poisoning. This departs from #515's "actions/cache
#      keyed on bun.lock" decision on purpose; every run is a cold install. For
#      pod, the Flutter action's own `cache:` input is a cache save too, so any
#      `*cache*:` input fails.
#   3. ACTOR GATE. Both jobs' `if:` carry `github.actor == 'dependabot[bot]'`.
#   4. JOB 1 IS TOKEN-FREE. No `secrets.`, no PLATFORM_WRITER_APP, no
#      app_token, no mint action, no GH_TOKEN/GITHUB_TOKEN; job-level
#      `permissions: contents: read`; checkout persist-credentials: false and
#      no `token:`; the patch is `git diff HEAD --binary --no-renames
#      --no-ext-diff --no-textconv` of exactly the template's lockfile
#      pathspecs (bun: the one `{{PKG_DIR}}/bun.lock`; pod: `{{APP_DIR}}/
#      pubspec.lock` and `{{APP_DIR}}/ios/Podfile.lock`, never a `*.lock` glob),
#      uploaded by a SHA-pinned upload-artifact.
#   5. JOB 2 RUNS NO PACKAGE MANAGER. No setup-bun/setup-node/flutter-action and
#      no bun, npm, yarn, pnpm, pod, bundle, gem, flutter or dart command in a
#      run: body. It is the VM that holds the token, so nothing a package
#      manager started may share it.
#   6. VALIDATE BEFORE THE MINT. Job 2 has a `Validate and apply` step before
#      the mint that reads the patch with `git apply --summary` (no create,
#      delete, rename or mode change) and `--numstat` (not binary), requires
#      every path to be allowed (bun: EQUAL `allowed='{{PKG_DIR}}/bun.lock'`,
#      exactly one file; pod: a member of `allowed=('{{APP_DIR}}/pubspec.lock'
#      '{{APP_DIR}}/ios/Podfile.lock')`, a non-empty subset, none twice; the root
#      collapse included), requires a tracked regular file (`ls-files -s`, mode
#      100644 or 100755), applies with `git apply --index` and re-checks the
#      staged set is only what the patch named. The artifact download is SHA-pinned. This
#      property is STATIC (the command names are in the step, in that order);
#      property 14 is the one that proves the rejections work.
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
#      A git call is recognised at line start, after whitespace and after `(`,
#      `"` or a backtick, so `$(git ...)` is one (a boundary of whitespace alone
#      missed every `x="$(git ...)"` and let a missing nohooks through).
#  11. BUN (the bun template only). bun comes from oven-sh/setup-bun, SHA-pinned
#      with a version comment, in both render arms (BUN_PIN_FILE and
#      BUN_PIN_LITERAL), never the image's; every `bun install` passes
#      --ignore-scripts.
#  12. HEAD SHA AND CONCURRENCY. Both jobs bind PR_HEAD_SHA to
#      github.event.pull_request.head.sha and check that out, not the branch
#      name. The guard is the `--force-with-lease` on that SHA (property 15), not
#      fast-forwardness: a branch that moved or was deleted between the jobs
#      fails the lease closed. A
#      top-level `concurrency:` group is keyed on the PR number with
#      cancel-in-progress: false (the deps-cadence-codegen precedent).
#  13. WIRING AND DESTINATION. Job 2 `needs:` job 1 (`update-bun-lock` /
#      `update-pod-lock`) and its `if:`
#      requires the `changed == 'true'` output job 1 exports; job 1's upload sets
#      `if-no-files-found: error`; the push goes to exactly
#      `https://github.com/${PR_HEAD_REPO}.git` and the refspec
#      `HEAD:refs/heads/${PR_HEAD_REF}`, each with its own mutant.
#  14. THE VALIDATOR, EXECUTED. Properties 6 and 7 only see names; `true ||
#      reject` keeps every name and defeats the rule (a reviewer did exactly that
#      to the binary-hunk reject and the gate stayed green). So the validate
#      step's run: body is extracted from the template, {{PKG_DIR}} is
#      substituted for a root install ('.', the `{{PKG_DIR}}/` collapse) and a
#      nested one (`web`), a non-ASCII one (see (b) below), and it runs in a scratch git repo (tracked
#      bun.lock + package.json at the root and in web/) against crafted
#      artifacts. A clean content change must exit 0 with exactly the allowed
#      path staged. Each of these must exit 1 AND print its own reason, so a
#      reject that fires from a different check cannot stand in for the one
#      under test: a binary hunk, a rename, a mode change, a create, a delete,
#      two files (bun.lock + package.json), the other install root's bun.lock, a
#      bun.lock tracked as a symlink (120000), a header-only no-op patch,
#      garbage, an empty patch, a missing patch, a clean patch with an extra
#      file already staged, and a clean patch beside a stray untracked file. A
#      `git` that fails only for `status` must abort the step (the status is
#      captured into a variable first; piped into grep, a failed status read as
#      a clean tree). One mutant per enforcing construct neuters it while keeping
#      its message text. There is deliberately no `[ -n "$numstat" ]` check: git
#      never prints an empty numstat for a patch it parses (a header-only patch
#      prints `0 0 path`), so it was unreachable and could not be pinned; the
#      "it changes nothing" reject on `0 0` is the reachable form. The executed
#      suite is memoised on the extracted body, so mutants that leave the step
#      alone do not re-run it.
#      Two further properties of the executed suite (#540). (a) THE PARSE
#      FAILURES ARE SEPARATE SITES: `git apply --summary` and `--numstat` each
#      `reject "git cannot parse it"`, and no single real patch can fail one and
#      not the other (both read the same parse), so each is proved by a `git`
#      shim on PATH that fails only that flag (as the `status` shim does), and
#      each has its own mutant, so neither call site is covered by the other's.
#      (b) A NON-ASCII, SPACE-CONTAINING INSTALL ROOT is a third location (bun
#      `w<e-acute> b`, pod the same app dir) beside the root and nested one, with
#      every case run against it. Plain `--numstat` C-quotes such a path
#      (`"w\303\251 b/bun.lock"`), so no compare matches and every patch for that
#      root was rejected with a misleading `X is not Y` naming the C-quoted path; the validators read `--numstat -z`
#      (NUL-terminated, unquoted) from a FILE (a shell variable drops NULs) and
#      the staged-set check reads `diff --cached --name-only -z`. Mutants: the
#      `-z` dropped from numstat, and from the staged-set read (the latter fails
#      only for the non-ASCII root, which is its point). (c) THE READ DOES NOT
#      TRIM: tab is IFS whitespace, so `IFS=$'\t' read added removed path`
#      strips a leading or trailing tab from the path and binds a tracked file
#      named `bun.lock<TAB>` to `bun.lock`; only the post-apply staged-set check
#      would catch it. The loop splits the record by hand and rejects a path that
#      is empty or holds a tab or newline; a tracked tab-named lockfile in every
#      root is a case asserted by THAT reason (not the staged-set one), and a
#      mutant restoring the trimming read is killed by it.
#
#  15. THE LEASE. The push passes `--force-with-lease="refs/heads/${PR_HEAD_REF}:
#      ${PR_HEAD_SHA}"`, the head SHA both jobs checked out, so a branch that
#      moved or was deleted between the jobs fails closed (a plain push would
#      recreate a deleted branch). A nit on #534, taken in #529 for both
#      templates (bun 13, pod 7); a dropped lease, one expecting the branch name,
#      a bare `--force-with-lease` and `--force` each have a mutant.
#
# THE POD VALIDATOR (`check_validator_pod`) is the same executed suite over the
# pod template's allowed set: a root app (`.`) and a nested one (`app`), each
# with a tracked pubspec.lock and ios/Podfile.lock in a scratch repo. A patch
# touching one lockfile or both is accepted with exactly those paths staged; and
# each of these exits 1 with its own reason: binary, rename, mode change,
# create, delete, a third file, an allowed name in the wrong directory (the other
# app's Podfile.lock), a symlinked lock, the same path twice, a no-op, garbage,
# empty, missing, a pre-staged file, a stray untracked file; a failing `git
# status` aborts the step. Pod has no one-file rule (a subset of two is the
# point); the duplicate-path rule and the allowed-set membership replace it.
#
# Vacuous-green guards: the template must split into exactly two jobs, and each
# job's step table must find what it is checked for (job 1: checkout and at least
# two installs; job 2: checkout, download, validate, presence step, mint, push),
# the pod template must hold exactly one flutter-action use,
# the validator's run: body must extract and have no {{…}} left after
# substitution, and every executed case is asserted by exit status AND reason,
# or the check fails rather than covering nothing.
#
# Mutation-proof (a gate that cannot fail is decorative): one mutation per
# property is applied to a copy of the template under test (the bun block, then
# the pod block, each with its own mutants) and each must FAIL the check
# WITH the expected reason (a mutation that fails for some other reason proves
# nothing), a mutation that changes nothing fails the gate (template reworded),
# and a perl that is missing, exits non-zero or writes an empty mutant fails the
# gate rather than letting a broken mutation pass vacuously. Expected reasons are
# full message fragments: the step-table-incomplete message names `push`,
# `checkout` and `contents: read` too, so a bare word would let a mutant that
# only broke step detection pass for the wrong reason.
#
# Reads two tracked files (the bun and pod templates). No gh, no network, no actionlint; perl for the
# mutations, git and cp for the executed validator's scratch repos (global and
# system git config off, as in the job). Wired into scripts/preflight.sh; run directly:
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
    # A git call starts at line start, after whitespace, or after ( " or a
    # backtick: `$(git ...)` and `"$(git ...)"` are calls too.
    local gitre='(^|[[:space:]("`])git[[:space:]]'
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
            [[ "$line" =~ $gitre ]] || continue
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

# check_checkout <job label> — properties 8 and 12 over the loaded STEP_BODY.
check_checkout() {
    local label="$1" rc=0 co body
    co="$(find_step 'actions/checkout@')" || co=""
    [ -n "$co" ] || { echo "$label: no checkout step — the check would cover nothing"; return 1; }
    body="${STEP_BODY[$co]}"
    [[ "${STEP_BODY[0]}" == *'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}'* ]] \
        || { echo "$label: PR_HEAD_SHA is not bound to github.event.pull_request.head.sha in the job env"; rc=1; }
    [[ "$body" == *'ref: ${{ env.PR_HEAD_SHA }}'* ]] \
        || { echo "$label: checkout does not check out the PR head SHA (a branch name can move between the jobs)"; rc=1; }
    [[ "$body" == *'persist-credentials: false'* ]] || { echo "$label: checkout does not set persist-credentials: false"; rc=1; }
    if grep -Eq '^[[:space:]]+token:' <<<"$body"; then echo "$label: checkout passes a token:"; rc=1; fi
    return "$rc"
}

# check_common <file> <job-1 package-manager regex> — properties 1-10, 12, 13
# and 15. 0 when the policy holds, 1 (reasons on stdout) otherwise. The
# per-template facts come from the C_* globals each check_<template> sets first:
#   C_J1            job 1's id (job 2 `needs:` it, and reads its `changed` output)
#   C_R1 / C_R2     the hard-coded runs-on of job 1 / job 2
#   C_PATHSPEC      the pathspec literal job 1's patch step must end its diff with
#   C_PATHSPEC_DESC what that pathspec is, for the message
#   C_VALIDATE      the function that statically checks job 2's validate step
check_common() {
    local f="$1" pm="$2" rc=0 d="$WORK/split" i line body nonc runs n
    local checkout download validate gate mint push installs=() j1 j2 uploads patch gateline up want j2nonc
    # A package manager at command position: line start (after run:), or after
    # && ; | or $( — not a word inside a quoted message.
    local pm2='(^[[:space:]]*(run:[[:space:]]+)?|&&[[:space:]]*|;[[:space:]]*|\|[[:space:]]*|\$\([[:space:]]*)(bun|bunx|npm|npx|yarn|pnpm|pod|bundle|gem|flutter|dart)([[:space:]]|$)'

    mkdir -p "$d"
    n="$(split_jobs "$f" "$d")"
    if [ "$n" != "2" ]; then
        echo "expected exactly two jobs (token-free update, token push), found $n — the check would cover nothing"
        return 1
    fi
    j1="$d/job1.yml"; j2="$d/job2.yml"
    nonc="$(grep -Ev '^[[:space:]]*#' "$f")"

    # 1. runner. Each job's own label, hard-coded: job 1 may need a platform
    # (pod: macOS) that job 2, the token VM, never does.
    for i in 1 2; do
        want="$C_R1"; [ "$i" = 2 ] && want="$C_R2"
        runs="$(grep -E '^    runs-on:' "$d/job$i.yml")"
        if [ "$runs" != "    runs-on: $want" ]; then
            echo "job $i must hard-code runs-on: $want (no render fact, no self-hosted label): ${runs:-<none>}"; rc=1
        fi
    done
    if grep -qF '{{RUNNER}}' <<<"$nonc" || grep -qi 'self-hosted' <<<"$nonc"; then
        echo "a {{RUNNER}} fact or a self-hosted label survives outside a comment"; rc=1
    fi
    j2nonc="$(grep -Ev '^[[:space:]]*#' "$j2")"
    if grep -Eqi 'macos' <<<"$j2nonc"; then
        echo "job 2 (the token job) names a macOS runner or label: only job 1 may need macOS"; rc=1
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

    # 12. concurrency: one run per PR (the file's only top-level block).
    if ! grep -qxF 'concurrency:' <<<"$nonc"; then
        echo "no workflow-level concurrency block"; rc=1
    elif ! grep -Eq '^  group: [A-Za-z0-9-]+-\$\{\{ github\.event\.pull_request\.number \}\}$' <<<"$nonc"; then
        echo "the concurrency group is not keyed on github.event.pull_request.number"; rc=1
    elif ! grep -qxF '  cancel-in-progress: false' <<<"$nonc"; then
        echo "the concurrency block does not set cancel-in-progress: false (a cancelled push is a half-pushed one)"; rc=1
    fi

    # 13 (job wiring). Job 2 waits for job 1 and runs only when job 1 changed the lock.
    if ! grep -qxF "    needs: $C_J1" "$j2"; then
        echo "job 2 does not declare needs: $C_J1"; rc=1
    fi
    if ! grep -qF "needs.$C_J1.outputs.changed == 'true'" <<<"$(grep -E '^    if:' "$j2")"; then
        echo "job 2's if: does not require needs.$C_J1.outputs.changed == 'true'"; rc=1
    fi

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
    if [[ "${STEP_BODY[0]}" != *'changed: ${{ steps.patch.outputs.changed }}'* ]]; then
        echo "job 1 does not export changed: \${{ steps.patch.outputs.changed }} for job 2's gate"; rc=1
    fi
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
    elif [[ "${STEP_BODY[$patch]}" != *"$C_PATHSPEC"* ]]; then
        echo "job 1's patch is not limited to $C_PATHSPEC_DESC"; rc=1
    fi
    uploads="$(grep -E 'uses: actions/upload-artifact@' <<<"$body")"
    if [ "$(grep -c . <<<"$uploads")" -ne 1 ] || grep -Evq '@[0-9a-f]{40} # v[0-9]' <<<"$uploads"; then
        echo "job 1 must upload the patch with exactly one SHA-pinned (40-hex plus version comment) actions/upload-artifact"; rc=1
    fi
    up="$(find_step 'actions/upload-artifact@')" || up=""
    if [ -z "$up" ] || [[ "${STEP_BODY[$up]}" != *'if-no-files-found: error'* ]]; then
        echo "job 1's upload does not set if-no-files-found: error (a missing patch must fail the job, not upload nothing)"; rc=1
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
    local setupre='uses: (oven-sh/setup-|actions/setup-|subosito/flutter-action|ruby/setup-ruby)'
    if grep -Eq "$setupre" <<<"$body" || grep -Eq "$pm2" <<<"$body" || grep -Eq "$pm" <<<"$body"; then
        echo "job 2 (the token job) runs a package manager or a setup-* toolchain action: $(grep -E "$setupre|$pm2" <<<"$body" | head -1 | sed 's/^ *//')"; rc=1
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
    "$C_VALIDATE" "$body" || rc=1
    [[ "$body" == *'apply --summary'* ]] || { echo "the validator does not read the patch with git apply --summary (create/delete/rename/mode)"; rc=1; }
    [[ "$body" == *'apply --numstat'* ]] || { echo "the validator does not read the patch with git apply --numstat (binary, path)"; rc=1; }
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
    # 13 (destination). The PR's own head repo and head branch, nothing else.
    if [[ "$body" != *' "https://github.com/${PR_HEAD_REPO}.git" '* ]]; then
        echo "the push URL is not exactly \"https://github.com/\${PR_HEAD_REPO}.git\""; rc=1
    fi
    if [[ "$body" != *' "HEAD:refs/heads/${PR_HEAD_REF}"'* ]]; then
        echo "the push refspec is not exactly \"HEAD:refs/heads/\${PR_HEAD_REF}\""; rc=1
    fi
    # 15. The lease. A plain push to a branch that was deleted since checkout
    # recreates it, and one to a branch that moved only fails by accident of
    # fast-forwardness; the lease names the tip both jobs saw.
    if [[ "$body" != *' push --force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}" '* ]]; then
        echo "the push is not leased to the head SHA (--force-with-lease=\"refs/heads/\${PR_HEAD_REF}:\${PR_HEAD_SHA}\"): a branch that moved or was deleted would not fail closed"; rc=1
    fi
    return "$rc"
}

# static_validate_bun <validate step body> — the bun template's own static rules
# on the validator: one allowed path, exactly one patched file.
static_validate_bun() {
    local body="$1" rc=0
    if [[ "$body" != *"allowed='{{PKG_DIR}}/bun.lock'"* ]]; then
        echo "the validator's allowed path is not exactly '{{PKG_DIR}}/bun.lock'"; rc=1
    fi
    if [[ "$body" != *'[ "$path" = "$allowed" ]'* ]]; then
        echo "the validator does not require the patched path to EQUAL the allowed path"; rc=1
    fi
    [[ "$body" == *'wc -c'* && "$body" == *'-eq 1'* ]] || { echo "the validator does not require exactly one patched file"; rc=1; }
    return "$rc"
}

# static_validate_pod <validate step body> — the pod template's: the allowed set
# is EXACTLY the two lockfiles, every patched path must be a member, none twice.
static_validate_pod() {
    local body="$1" rc=0
    if [[ "$body" != *"allowed=('{{APP_DIR}}/pubspec.lock' '{{APP_DIR}}/ios/Podfile.lock')"* ]]; then
        echo "the validator's allowed set is not exactly '{{APP_DIR}}/pubspec.lock' and '{{APP_DIR}}/ios/Podfile.lock'"; rc=1
    fi
    if [[ "$body" != *'[ "$path" = "$a" ]'* || "$body" != *'[ "$listed" -eq 1 ]'* ]]; then
        echo "the validator does not require every patched path to EQUAL a member of the allowed set"; rc=1
    fi
    if [[ "$body" != *'appears more than once'* ]]; then
        echo "the validator does not reject a path that appears twice in the patch"; rc=1
    fi
    return "$rc"
}

# --- the validator, EXECUTED -------------------------------------------------
# The static rules above only prove the validator's command names are present;
# `true || reject` in place of a reject keeps every name and defeats the rule.
# So the "Validate and apply the lockfile patch" run: body is extracted from the
# template (the way test-deps-cadence-policy.sh extracts its impl steps), its
# {{PKG_DIR}} substituted for a root install ('.', where '{{PKG_DIR}}/'
# collapses to nothing) and a nested one ('web'), and run in a scratch git repo
# against crafted patch artifacts. Each hostile one must exit 1 WITH its own
# rejection reason, so a rejection that fires from a different check does not
# pass for the one under test.
step_run() {
    awk -v want="      - name: $2" '
        index($0, want) == 1 { step = 1; next }
        step && /^        run: \|$/ { body = 1; next }
        body && /^[[:space:]]*$/ { print ""; next }
        body && !/^          / { exit }
        body { sub(/^          /, ""); print }' "$1"
}

# Scratch repos must not read the user's git config (a managed-identity hook
# refuses commits whose identity does not come from it), exactly the job env.
vg() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }

VX="$WORK/vx"
# The non-ASCII, space-containing install root / app directory (UTF-8 e-acute,
# spelled in octal so the source stays ASCII). git C-quotes such a path in plain
# --numstat output, and `-z` is what lets the validators compare it.
VX_UNI="$(printf 'w\303\251 b')"
# The artifact dir, patch file name and patch-fixture prefix vx_run uses; each
# check_validator* sets them for its template before running a case.
VX_IN=bun-lock-in; VX_PF=bun-lock.patch; VX_PD=patch-
# vx_base <dir> <text|sym> — a committed repo holding a root install and a web/
# install, each with a tracked package.json and bun.lock (a regular file, or a
# symlink in the sym variant).
vx_base() {
    mkdir -p "$1/web" "$1/$VX_UNI"
    (
        cd "$1" || exit 1
        vg init -q -b main .
        vg config user.name t; vg config user.email t@example.com
        printf '{"name":"root"}\n' > package.json
        printf '{"name":"web"}\n' > web/package.json
        printf '{"name":"uni"}\n' > "$VX_UNI/package.json"
        if [ "$2" = sym ]; then
            ln -s package.json bun.lock
            ln -s package.json web/bun.lock
            ln -s package.json "$VX_UNI/bun.lock"
        else
            printf 'lockfileVersion 1\ndep a 1.0.0\n' > bun.lock
            printf 'lockfileVersion 1\ndep b 2.0.0\n' > web/bun.lock
            printf 'lockfileVersion 1\ndep c 3.0.0\n' > "$VX_UNI/bun.lock"
        fi
        # A tracked file whose name ENDS in a tab, beside each bun.lock: the
        # trimming `read` would bind it to bun.lock.
        local d
        for d in . web "$VX_UNI"; do printf 'lockfileVersion 1\n' > "$d/bun.lock"$'\t'; done
        vg add -A && vg commit -qm base
    )
}

# vx_dir <root|web|uni> — the install root's directory.
vx_dir() { case "$1" in root) echo . ;; web) echo web ;; uni) echo "$VX_UNI" ;; esac; }

# vx_patch <root|web|uni> <case> — writes $VX/patch-<P>/<case>.patch.
vx_patch() {
    local P="$1" c="$2" A=bun.lock O=web/bun.lock D=. base="$VX/base-text" g="$VX/gen"
    [ "$P" != root ] && { D="$(vx_dir "$P")"; A="$D/bun.lock"; O=bun.lock; }
    [ "$c" = symlink ] && base="$VX/base-sym"
    mkdir -p "$VX/patch-$P"
    rm -rf "$g"; cp -R "$base" "$g"
    (
        cd "$g" || exit 1
        local out="$VX/patch-$P/$c.patch" plain=(diff HEAD --binary --no-renames --no-ext-diff --no-textconv)
        case "$c" in
            clean)     echo 'dep a 1.0.1' >> "$A"; vg "${plain[@]}" > "$out" ;;
            binary)    printf 'bin\0ary\0\1\2' > "$A"; vg "${plain[@]}" > "$out" ;;
            rename)    vg mv "$A" "$D/bun.lock.moved"; vg diff --cached HEAD -M --binary > "$out" ;;
            mode)      chmod +x "$A"; vg "${plain[@]}" > "$out" ;;
            create)    echo x > "$D/extra.lock"; vg add -A; vg diff --cached HEAD --binary > "$out" ;;
            delete)    vg rm -q "$A"; vg diff --cached HEAD --binary > "$out" ;;
            two)       echo 'dep a 1.0.1' >> "$A"; echo '{"x":1}' > "$D/package.json"; vg "${plain[@]}" > "$out" ;;
            wrongpath) echo 'dep z 9.9.9' >> "$O"; vg "${plain[@]}" > "$out" ;;
            symlink)   ln -sfn nowhere "$A"; vg "${plain[@]}" > "$out" ;;
            nochange)  echo 'dep a 1.0.1' >> "$A"; vg "${plain[@]}" | head -4 | sed '2s/.*/index 1111111..1111111 100644/' > "$out" ;;
            tabname)   echo 'dep a 1.0.1' >> "$A"$'\t'; vg "${plain[@]}" > "$out" ;;
            garbage)   printf 'this is not a patch\n' > "$out" ;;
            empty)     : > "$out" ;;
            *) exit 1 ;;
        esac
    ) || { echo "fixture: could not build the $P/$c patch" >&2; return 1; }
}

VX_CASES="clean binary rename mode create delete two wrongpath symlink nochange tabname garbage empty"
vx_build() {
    local P c
    mkdir -p "$VX"
    vx_base "$VX/base-text" text
    vx_base "$VX/base-sym" sym
    for P in root web uni; do
        for c in $VX_CASES; do vx_patch "$P" "$c" || return 1; done
    done
    # A `git` that fails only for one subcommand or flag, to prove each call
    # site is load-bearing on its own: `status` (a failing status aborts), and
    # `--summary` / `--numstat` (the two `git cannot parse it` sites, which one
    # real patch cannot separate, because both read the same parse).
    local w
    for w in status --summary --numstat; do
        mkdir -p "$VX/fail$w"
        printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = %s ] && { echo "fatal: simulated %s failure" >&2; exit 128; }; done\nexec %s "$@"\n' "$w" "$w" "$(command -v git)" > "$VX/fail$w/git"
        chmod +x "$VX/fail$w/git"
    done
}

# vx_run <body.sh> <root|web> <case> <base> <prep> — runs the body in a fresh
# copy of <base>; prints its output, returns its status. <case> "missing" runs
# with no patch file at all.
vx_run() {
    local body="$1" P="$2" c="$3" base="$4" prep="${5:-}" run="$VX/run" rt="$VX/rt" path="$PATH"
    rm -rf "$run" "$rt"; cp -R "$base" "$run"; mkdir -p "$rt/$VX_IN"
    # A copied tree has new mtimes, and `git apply --index` refuses a stale index.
    (cd "$run" && vg update-index -q --refresh)
    [ "$c" = missing ] || cp "$VX/$VX_PD$P/$c.patch" "$rt/$VX_IN/$VX_PF"
    case "$prep" in
        staged)     echo x > "$run/extra.txt"; (cd "$run" && vg add extra.txt) ;;
        untracked)  echo x > "$run/stray.txt" ;;
        statusfail) path="$VX/failstatus:$PATH" ;;
        summaryfail) path="$VX/fail--summary:$PATH" ;;
        numstatfail) path="$VX/fail--numstat:$PATH" ;;
    esac
    (cd "$run" && env RUNNER_TEMP="$rt" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null PATH="$path" \
        bash --noprofile --norc -eo pipefail "$body" 2>&1)
}

# vx_expect <body.sh> <root|web> <label> <case> <base> <prep> <want-rc> <fragment>
# — one executed case; prints a reason when it does not behave.
vx_expect() {
    local body="$1" P="$2" label="$3" c="$4" base="$5" prep="$6" want="$7" frag="$8" out rc A=bun.lock O=web/bun.lock
    [ "$P" != root ] && { A="$(vx_dir "$P")/bun.lock"; O=bun.lock; }
    frag="${frag//@A/$A}"; frag="${frag//@O/$O}"
    out="$(vx_run "$body" "$P" "$c" "$base" "$prep")"; rc=$?
    if [ "$want" = ok ]; then
        if [ "$rc" -ne 0 ]; then
            echo "validator [$P] $label: a clean lockfile patch was rejected (rc=$rc): $(grep -m1 '::error::' <<<"$out")"; return 1
        fi
        if [ "$(cd "$VX/run" && vg -c core.quotePath=false diff --cached --name-only)" != "$A" ] || [ "$(cd "$VX/run" && vg status --porcelain -z | tr '\0' '\n')" != "M  $A" ]; then
            echo "validator [$P] $label: accepted, but the staged set is not exactly $A"; return 1
        fi
        return 0
    fi
    if [ "$want" = fail ]; then
        if [ "$rc" -eq 0 ]; then
            echo "validator [$P] $label: ACCEPTED a hostile patch (expected a rejection containing '$frag')"; return 1
        fi
        if ! grep -qF -- "$frag" <<<"$out"; then
            echo "validator [$P] $label: rejected (rc=$rc), but not for the expected reason '$frag': $(grep -m1 -e '::error::' -e fatal <<<"$out")"; return 1
        fi
        return 0
    fi
    # rejected exactly through Rejected …, status 1
    if [ "$rc" -ne 1 ]; then
        echo "validator [$P] $label: expected exit status 1, got $rc (expected a rejection containing '$frag')"; return 1
    fi
    if ! grep -qF -- "Rejected the lockfile patch: " <<<"$out" || ! grep -qF -- "$frag" <<<"$out"; then
        echo "validator [$P] $label: exit 1, but not rejected for the expected reason '$frag': $(grep -m1 '::error::' <<<"$out")"; return 1
    fi
    return 0
}

# check_validator <file> — extracts, substitutes and runs the validator over
# every case for both install roots. Memoised on the extracted body, so the
# mutants that leave this step alone do not re-run it.
check_validator() {
    local f="$1" raw key cache P body rc=0 line
    VX_IN=bun-lock-in; VX_PF=bun-lock.patch; VX_PD=patch-
    raw="$(step_run "$f" 'Validate and apply the lockfile patch')"
    if [ -z "$raw" ]; then
        echo "validator: could not extract the 'Validate and apply the lockfile patch' run: body — the executed check would cover nothing"
        return 1
    fi
    key="$(printf '%s' "$raw" | cksum | cut -d' ' -f1)"
    cache="$WORK/vcache.$key"
    if [ -f "$cache.rc" ]; then cat "$cache"; return "$(cat "$cache.rc")"; fi
    {
        for P in root web uni; do
            body="$VX/body-$P.sh"
            if [ "$P" = root ]; then
                sed 's#{{PKG_DIR}}/##g' <<<"$raw" > "$body"
            else
                sed "s#{{PKG_DIR}}#$(vx_dir "$P")#g" <<<"$raw" > "$body"
            fi
            if grep -qF '{{' "$body"; then echo "validator [$P]: an unsubstituted {{…}} placeholder survives in the run: body"; rc=1; fi
            vx_expect "$body" "$P" "clean content change"  clean     "$VX/base-text" ""         ok   ""                                                      || rc=1
            vx_expect "$body" "$P" "binary hunk"           binary    "$VX/base-text" ""         rej  "is a binary change"                                    || rc=1
            vx_expect "$body" "$P" "rename"                rename    "$VX/base-text" ""         rej  "creates, deletes, renames, copies or re-modes"         || rc=1
            vx_expect "$body" "$P" "mode change"           mode      "$VX/base-text" ""         rej  "creates, deletes, renames, copies or re-modes"         || rc=1
            vx_expect "$body" "$P" "create"                create    "$VX/base-text" ""         rej  "creates, deletes, renames, copies or re-modes"         || rc=1
            vx_expect "$body" "$P" "delete"                delete    "$VX/base-text" ""         rej  "creates, deletes, renames, copies or re-modes"         || rc=1
            vx_expect "$body" "$P" "two files"             two       "$VX/base-text" ""         rej  "it touches more than one file"                         || rc=1
            vx_expect "$body" "$P" "wrong path"            wrongpath "$VX/base-text" ""         rej  "@O is not @A"                                          || rc=1
            vx_expect "$body" "$P" "symlink"               symlink   "$VX/base-sym"  ""         rej  "is not a tracked regular file"                         || rc=1
            vx_expect "$body" "$P" "no-op patch"           nochange  "$VX/base-text" ""         rej  "it changes nothing"                                    || rc=1
            vx_expect "$body" "$P" "tab-named lockfile"    tabname   "$VX/base-text" ""         rej  "a patched path is empty or holds a tab or newline"     || rc=1
            vx_expect "$body" "$P" "garbage patch"         garbage   "$VX/base-text" ""         rej  "git cannot parse it"                                   || rc=1
            vx_expect "$body" "$P" "empty patch"           empty     "$VX/base-text" ""         rej  "the artifact holds no patch"                           || rc=1
            vx_expect "$body" "$P" "missing patch"         missing   "$VX/base-text" ""         rej  "the artifact holds no patch"                           || rc=1
            vx_expect "$body" "$P" "pre-staged extra file" clean     "$VX/base-text" staged     rej  "something other than @A is staged"                     || rc=1
            vx_expect "$body" "$P" "stray untracked file"  clean     "$VX/base-text" untracked  rej  "the tree holds changes outside the index"               || rc=1
            vx_expect "$body" "$P" "git status failure"    clean     "$VX/base-text" statusfail fail "simulated status failure"                              || rc=1
            vx_expect "$body" "$P" "summary parse failure" clean     "$VX/base-text" summaryfail rej "git cannot parse it"                                    || rc=1
            vx_expect "$body" "$P" "numstat parse failure" clean     "$VX/base-text" numstatfail rej "git cannot parse it"                                    || rc=1
        done
    } > "$cache"
    printf '%s\n' "$rc" > "$cache.rc"
    cat "$cache"
    return "$rc"
}

# --- the pod template's validator, EXECUTED ---------------------------------
# Same idea as above, with the pod template's allowed set: a non-empty subset of
# {<app>/pubspec.lock, <app>/ios/Podfile.lock}, each path at most once. The app
# is the repo root ('.', where '{{APP_DIR}}/' collapses to nothing) or `app`.
PXF="pubspec.yaml"
# px_base <dir> <text|sym> — a committed repo holding a root app and an app/
# app, each with a tracked pubspec.yaml, pubspec.lock and ios/Podfile.lock (the
# two locks regular files, or symlinks in the sym variant).
px_base() {
    mkdir -p "$1/ios" "$1/app/ios" "$1/$VX_UNI/ios"
    (
        cd "$1" || exit 1
        vg init -q -b main .
        vg config user.name t; vg config user.email t@example.com
        local d
        for d in . app "$VX_UNI"; do
            printf 'name: x\n' > "$d/$PXF"
            if [ "$2" = sym ]; then
                ln -s "$PXF" "$d/pubspec.lock"
                ln -s "$PXF" "$d/ios/Podfile.lock"
            else
                printf 'packages:\n  a: 1.0.0\n' > "$d/pubspec.lock"
                printf 'PODS:\n  - a (1.0.0)\n' > "$d/ios/Podfile.lock"
            fi
        done
        # A tracked file whose name ENDS in a tab, beside each pubspec.lock.
        for d in . app "$VX_UNI"; do printf 'packages:\n' > "$d/pubspec.lock"$'\t'; done
        vg add -A && vg commit -qm base
    )
}

# px_dir <root|app|uni> — the app's directory prefix ('' at the root).
px_dir() { case "$1" in root) echo "" ;; app) echo "app/" ;; uni) echo "$VX_UNI/" ;; esac; }

# px_patch <root|app|uni> <case> — writes $VX/ppatch-<P>/<case>.patch.
px_patch() {
    local P="$1" c="$2" D="" O="app/ios/Podfile.lock" base="$VX/pbase-text" g="$VX/pgen"
    [ "$P" != root ] && { D="$(px_dir "$P")"; O="ios/Podfile.lock"; }
    local A1="${D}pubspec.lock" A2="${D}ios/Podfile.lock"
    [ "$c" = symlink ] && base="$VX/pbase-sym"
    mkdir -p "$VX/ppatch-$P"
    rm -rf "$g"; cp -R "$base" "$g"
    (
        cd "$g" || exit 1
        local out="$VX/ppatch-$P/$c.patch" plain=(diff HEAD --binary --no-renames --no-ext-diff --no-textconv)
        case "$c" in
            clean1)    echo '  b: 1.0.1' >> "$A1"; vg "${plain[@]}" > "$out" ;;
            clean2)    echo '  - b (2.0.0)' >> "$A2"; vg "${plain[@]}" > "$out" ;;
            clean)     echo '  b: 1.0.1' >> "$A1"; echo '  - b (2.0.0)' >> "$A2"; vg "${plain[@]}" > "$out" ;;
            binary)    printf 'bin\0ary\0\1\2' > "$A2"; vg "${plain[@]}" > "$out" ;;
            rename)    vg mv "$A1" "$A1.moved"; vg diff --cached HEAD -M --binary > "$out" ;;
            mode)      chmod +x "$A1"; vg "${plain[@]}" > "$out" ;;
            create)    echo x > "${D}extra.lock"; vg add -A; vg diff --cached HEAD --binary > "$out" ;;
            delete)    vg rm -q "$A2"; vg diff --cached HEAD --binary > "$out" ;;
            third)     echo '  b: 1.0.1' >> "$A1"; echo '  - b (2.0.0)' >> "$A2"; echo 'name: y' >> "${D}$PXF"; vg "${plain[@]}" > "$out" ;;
            wrongpath) echo '  - z (9.9.9)' >> "$O"; vg "${plain[@]}" > "$out" ;;
            symlink)   ln -sfn nowhere "$A2"; vg "${plain[@]}" > "$out" ;;
            dup)       echo '  b: 1.0.1' >> "$A1"; vg "${plain[@]}" > "$g.p1"
                       vg add -A; vg commit -qm one
                       echo '  b: 1.0.2' >> "$A1"; vg "${plain[@]}" > "$g.p2"
                       cat "$g.p1" "$g.p2" > "$out" ;;
            nochange)  echo '  b: 1.0.1' >> "$A1"; vg "${plain[@]}" | head -4 | sed '2s/.*/index 1111111..1111111 100644/' > "$out" ;;
            tabname)   echo '  b: 1.0.1' >> "$A1"$'\t'; vg "${plain[@]}" > "$out" ;;
            garbage)   printf 'this is not a patch\n' > "$out" ;;
            empty)     : > "$out" ;;
            *) exit 1 ;;
        esac
    ) || { echo "fixture: could not build the $P/$c pod patch" >&2; return 1; }
}

PX_CASES="clean1 clean2 clean binary rename mode create delete third wrongpath symlink dup nochange tabname garbage empty"
px_build() {
    local P c
    px_base "$VX/pbase-text" text
    px_base "$VX/pbase-sym" sym
    for P in root app uni; do
        for c in $PX_CASES; do px_patch "$P" "$c" || return 1; done
    done
}

# px_expect <body.sh> <root|app> <label> <case> <base> <prep> <ok|rej|fail> <fragment> [staged]
# — one executed case. @A1 @A2 @O @T in the fragment are the app's pubspec.lock,
# Podfile.lock, the OTHER app's Podfile.lock and the app's pubspec.yaml; staged
# (ok only) is the set the clean patch must leave staged: A1, A2 or A1+A2.
px_expect() {
    local body="$1" P="$2" label="$3" c="$4" base="$5" prep="$6" want="$7" frag="$8" staged="${9:-}"
    local out rc D="" O="app/ios/Podfile.lock" t exp got
    [ "$P" != root ] && { D="$(px_dir "$P")"; O="ios/Podfile.lock"; }
    local A1="${D}pubspec.lock" A2="${D}ios/Podfile.lock" T="${D}$PXF"
    frag="${frag//@A1/$A1}"; frag="${frag//@A2/$A2}"; frag="${frag//@O/$O}"; frag="${frag//@T/$T}"
    out="$(vx_run "$body" "$P" "$c" "$base" "$prep")"; rc=$?
    if [ "$want" = ok ]; then
        if [ "$rc" -ne 0 ]; then
            echo "validator [$P] $label: a clean lockfile patch was rejected (rc=$rc): $(grep -m1 '::error::' <<<"$out")"; return 1
        fi
        exp="$(for t in ${staged//+/ }; do case "$t" in A1) echo "$A1" ;; A2) echo "$A2" ;; esac; done | sort)"
        got="$(cd "$VX/run" && vg -c core.quotePath=false diff --cached --name-only | sort)"
        if [ -z "$exp" ] || [ "$got" != "$exp" ] || [ -n "$(cd "$VX/run" && vg status --porcelain | grep -v '^M  ' || true)" ]; then
            echo "validator [$P] $label: accepted, but the staged set is not exactly ${staged//+/ and } (staged: ${got//$'\n'/ })"; return 1
        fi
        return 0
    fi
    if [ "$want" = fail ]; then
        if [ "$rc" -eq 0 ]; then
            echo "validator [$P] $label: ACCEPTED a hostile patch (expected a failure containing '$frag')"; return 1
        fi
        if ! grep -qF -- "$frag" <<<"$out"; then
            echo "validator [$P] $label: failed (rc=$rc), but not for the expected reason '$frag': $(grep -m1 -e '::error::' -e fatal <<<"$out")"; return 1
        fi
        return 0
    fi
    if [ "$rc" -ne 1 ]; then
        echo "validator [$P] $label: expected exit status 1, got $rc (expected a rejection containing '$frag')"; return 1
    fi
    if ! grep -qF -- "Rejected the lockfile patch: " <<<"$out" || ! grep -qF -- "$frag" <<<"$out"; then
        echo "validator [$P] $label: exit 1, but not rejected for the expected reason '$frag': $(grep -m1 '::error::' <<<"$out")"; return 1
    fi
    return 0
}

# check_validator_pod <file> — extracts, substitutes and runs the pod validator
# over every case for both app locations. Memoised on the extracted body.
check_validator_pod() {
    local f="$1" raw key cache P body rc=0
    VX_IN=pod-lock-in; VX_PF=pod-lock.patch; VX_PD=ppatch-
    raw="$(step_run "$f" 'Validate and apply the lockfile patch')"
    if [ -z "$raw" ]; then
        echo "validator: could not extract the 'Validate and apply the lockfile patch' run: body — the executed check would cover nothing"
        return 1
    fi
    key="$(printf '%s' "$raw" | cksum | cut -d' ' -f1)"
    cache="$WORK/pvcache.$key"
    if [ -f "$cache.rc" ]; then cat "$cache"; return "$(cat "$cache.rc")"; fi
    {
        for P in root app uni; do
            body="$VX/pbody-$P.sh"
            if [ "$P" = root ]; then
                sed 's#{{APP_DIR}}/##g' <<<"$raw" > "$body"
            else
                sed "s#{{APP_DIR}}#$(px_dir "$P" | sed 's#/$##')#g" <<<"$raw" > "$body"
            fi
            if grep -qF '{{' "$body"; then echo "validator [$P]: an unsubstituted {{…}} placeholder survives in the run: body"; rc=1; fi
            px_expect "$body" "$P" "pubspec.lock only"      clean1    "$VX/pbase-text" ""         ok   ""                                                  A1    || rc=1
            px_expect "$body" "$P" "Podfile.lock only"      clean2    "$VX/pbase-text" ""         ok   ""                                                  A2    || rc=1
            px_expect "$body" "$P" "both lockfiles"         clean     "$VX/pbase-text" ""         ok   ""                                                  A1+A2 || rc=1
            px_expect "$body" "$P" "binary hunk"            binary    "$VX/pbase-text" ""         rej  "@A2 is a binary change"                                  || rc=1
            px_expect "$body" "$P" "rename"                 rename    "$VX/pbase-text" ""         rej  "creates, deletes, renames, copies or re-modes"           || rc=1
            px_expect "$body" "$P" "mode change"            mode      "$VX/pbase-text" ""         rej  "creates, deletes, renames, copies or re-modes"           || rc=1
            px_expect "$body" "$P" "create"                 create    "$VX/pbase-text" ""         rej  "creates, deletes, renames, copies or re-modes"           || rc=1
            px_expect "$body" "$P" "delete"                 delete    "$VX/pbase-text" ""         rej  "creates, deletes, renames, copies or re-modes"           || rc=1
            px_expect "$body" "$P" "a third file"           third     "$VX/pbase-text" ""         rej  "@T is not an allowed lockfile path"                      || rc=1
            px_expect "$body" "$P" "wrong directory"        wrongpath "$VX/pbase-text" ""         rej  "@O is not an allowed lockfile path"                      || rc=1
            px_expect "$body" "$P" "symlink"                symlink   "$VX/pbase-sym"  ""         rej  "@A2 is not a tracked regular file"                       || rc=1
            px_expect "$body" "$P" "duplicate path"         dup       "$VX/pbase-text" ""         rej  "@A1 appears more than once in the patch"                 || rc=1
            px_expect "$body" "$P" "no-op patch"            nochange  "$VX/pbase-text" ""         rej  "it changes nothing"                                      || rc=1
            px_expect "$body" "$P" "tab-named lockfile"     tabname   "$VX/pbase-text" ""         rej  "a patched path is empty or holds a tab or newline"      || rc=1
            px_expect "$body" "$P" "garbage patch"          garbage   "$VX/pbase-text" ""         rej  "git cannot parse it"                                     || rc=1
            px_expect "$body" "$P" "empty patch"            empty     "$VX/pbase-text" ""         rej  "the artifact holds no patch"                             || rc=1
            px_expect "$body" "$P" "missing patch"          missing   "$VX/pbase-text" ""         rej  "the artifact holds no patch"                             || rc=1
            px_expect "$body" "$P" "pre-staged extra file"  clean     "$VX/pbase-text" staged     rej  "something other than the patched lockfiles is staged"   || rc=1
            px_expect "$body" "$P" "stray untracked file"   clean     "$VX/pbase-text" untracked  rej  "the tree holds changes outside the index"                || rc=1
            px_expect "$body" "$P" "git status failure"     clean     "$VX/pbase-text" statusfail fail "simulated status failure"                                || rc=1
            px_expect "$body" "$P" "summary parse failure"  clean     "$VX/pbase-text" summaryfail rej "git cannot parse it"                                     || rc=1
            px_expect "$body" "$P" "numstat parse failure"  clean     "$VX/pbase-text" numstatfail rej "git cannot parse it"                                     || rc=1
        done
    } > "$cache"
    printf '%s\n' "$rc" > "$cache.rc"
    cat "$cache"
    return "$rc"
}

# check_pod <file> — the pod template: check_common plus the Flutter toolchain.
check_pod() {
    local f="$1" rc=0 nonc uses n
    C_J1=update-pod-lock; C_R1=macos-latest; C_R2=ubuntu-latest
    C_PATHSPEC="-- '{{APP_DIR}}/pubspec.lock' '{{APP_DIR}}/ios/Podfile.lock' >"
    C_PATHSPEC_DESC="the two '{{APP_DIR}}/pubspec.lock' and '{{APP_DIR}}/ios/Podfile.lock' pathspecs"
    C_VALIDATE=static_validate_pod
    check_common "$f" 'flutter pub get|pod install' || rc=1
    check_validator_pod "$f" || rc=1

    nonc="$(grep -Ev '^[[:space:]]*#' "$f")"
    uses="$(grep -E 'uses: subosito/flutter-action@' <<<"$nonc")"
    n="$(grep -c . <<<"$uses")"
    if [ "$n" -ne 1 ]; then
        echo "expected exactly one flutter-action use, found $n"; rc=1
    elif grep -Evq '@[0-9a-f]{40} # v[0-9]' <<<"$uses"; then
        echo "the flutter-action use is not pinned to a 40-hex SHA with a version comment"; rc=1
    fi
    if [[ "$nonc" != *'flutter-version: ${{ env.FLUTTER_VERSION }}'* ]]; then
        echo "flutter-action does not take the repo's pin (flutter-version: \${{ env.FLUTTER_VERSION }})"; rc=1
    fi
    if [[ "$nonc" != *"FLUTTER_VERSION: '{{FLUTTER_VERSION}}'"* ]]; then
        echo "FLUTTER_VERSION is not bound to the {{FLUTTER_VERSION}} fact"; rc=1
    fi
    if grep -Eq '^[[:space:]]+[a-z-]*cache[a-z-]*:' <<<"$nonc"; then
        echo "a cache input (cache:, cache-key:, pub-cache-path:) is set: the Flutter action saves through actions/cache"; rc=1
    fi
    return "$rc"
}

# check_bun <file> — the bun template: check_common plus property 11.
check_bun() {
    local f="$1" rc=0 nonc uses n i line
    C_J1=update-bun-lock; C_R1=ubuntu-latest; C_R2=ubuntu-latest
    C_PATHSPEC="-- '{{PKG_DIR}}/bun.lock'"; C_PATHSPEC_DESC="the one '{{PKG_DIR}}/bun.lock' pathspec"
    C_VALIDATE=static_validate_bun
    check_common "$f" 'bun install' || rc=1
    check_validator "$f" || rc=1

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

vx_build || { echo "  FAIL could not build the validator fixtures"; exit 1; }
px_build || { echo "  FAIL could not build the pod validator fixtures"; exit 1; }

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
MUT_TPL="$BUN_TEMPLATE"; MUT_CHECK=check_bun
mutate() {
    local name="$1" want="$2" m="$WORK/mutant.yml"
    if ! FROM="$3" TO="$4" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$MUT_TPL" > "$m"; then
        bad "mutation ($name): perl exited non-zero, so the mutant is meaningless"; return
    fi
    verdict "$name" "$want" "$m"
}
# mutate_perl <name> <want> <perl -0777 program> — a structural mutation.
mutate_perl() {
    local name="$1" want="$2" m="$WORK/mutant.yml"
    if ! perl -0777 -pe "$3" "$MUT_TPL" > "$m"; then
        bad "mutation ($name): perl exited non-zero, so the mutant is meaningless"; return
    fi
    verdict "$name" "$want" "$m"
}
verdict() {
    local out
    if [ ! -s "$3" ]; then
        bad "mutation ($1) produced an empty mutant, so it proves nothing"
    elif cmp -s "$3" "$MUT_TPL"; then
        bad "mutation ($1) changed nothing, so it proves nothing (template reworded?)"
    elif out="$("$MUT_CHECK" "$3")"; then
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
mutate "self-hosted runs-on (both jobs)" "must hard-code runs-on" 'runs-on: ubuntu-latest' 'runs-on: [self-hosted, linux, sassy-dog]'
mutate_perl "self-hosted runs-on (token job only)" "hard-code runs-on" "s/(${J2}runs-on: )ubuntu-latest/\${1}[self-hosted, linux]/s"
mutate "runner as a render fact" "{{RUNNER}} fact" 'runs-on: ubuntu-latest' 'runs-on: {{RUNNER}}'

# 2. no cache
mutate_perl "actions/cache re-added" "actions/cache" 's/(      \# Restore the BASE branch.s bun\.lock)/      - uses: actions\/cache\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: ~\/.bun\/install\/cache\n          key: bun-\${{ runner.os }}-\${{ hashFiles(\x27{{PKG_DIR}}\/bun.lock\x27) }}\n\n$1/'
mutate_perl "cache re-added to the token job" "actions/cache" 's/(      - uses: actions\/download-artifact)/      - uses: actions\/cache\/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: y\n\n$1/'

# 3. actor gate
mutate "actor gate dropped from job 1" "job 1 has no github.actor" "    if: \${{ github.actor == 'dependabot[bot]' }}" '    if: ${{ true }}'
mutate "actor gate dropped from job 2" "job 2 has no github.actor" "github.actor == 'dependabot[bot]' && needs" 'needs'

# 4. job 1 is token-free
mutate_perl "token in an install's env" "token-free" 's/(      - name: Update bun\.lock for the bumped packages only\n)/$1        env:\n          GH_TOKEN: \${{ steps.app_token.outputs.token }}\n/'
mutate_perl "App secret in job 1's env" "token-free" 's/(    steps:\n)/    env:\n      PLATFORM_WRITER_APP_PRIVATE_KEY: \${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n$1/'
mutate_perl "mint action in job 1" "token-free" 's/(      - name: Assert the lock is frozen-valid\n)/      - uses: actions\/create-github-app-token\@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n\n$1/'
mutate_perl "job 1 loses contents: read" "job 1 does not set job-level permissions: contents: read" 's/(    timeout-minutes: 15\n    permissions:\n      contents: )read/$1write/'
mutate_perl "job 1 patch not limited to bun.lock" "is not limited to the one" "s/ -- '\\{\\{PKG_DIR\\}\\}\\/bun\\.lock' >/ >/"
mutate "job 1 patch with textconv allowed" "does not package the change with git diff HEAD --binary" ' --no-textconv --' ' -- '
mutate_perl "job 1 upload unpinned" "job 1 must upload the patch with exactly one SHA-pinned" 's/upload-artifact\@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7\.0\.2/upload-artifact\@v7/'

# 5. job 2 runs no package manager
mutate_perl "bun install in the token job" "job 2 (the token job) runs a package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: bun install --ignore-scripts\n\n$1/'
mutate_perl "npm in the token job" "job 2 (the token job) runs a package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: cd x \&\& npm ci\n\n$1/'
mutate_perl "setup-bun in the token job" "job 2 (the token job) runs a package manager" "s/(${J2})(      - uses: actions\\/download-artifact)/\$1      - uses: oven-sh\\/setup-bun\\\@0c5077e51419868618aeaa5fe8019c62421857d6 # v2\n\n\$2/s"

# 6. validate before the mint
mutate_perl "validate moved after the mint" "is validated (step" "s/$VALIDATE_BLOCK$MINT_BLOCK$PUSH_COMMENT/\$2\$1/s"
mutate "allowed path widened to the directory" "the validator's allowed path is not exactly" "allowed='{{PKG_DIR}}/bun.lock'" "allowed='{{PKG_DIR}}/'"
mutate "path match loosened to a glob" "does not require the patched path to EQUAL" '[ "$path" = "$allowed" ]' '[[ "$path" == *bun.lock ]]'
mutate "apply --summary dropped" "does not read the patch with git apply --summary" 'apply --summary' 'apply --stat'
mutate "apply --numstat dropped" "does not read the patch with git apply --numstat" 'apply --numstat' 'apply --stat'
mutate "single-file rule dropped" "does not require exactly one patched file" '-eq 1 ]' '-ge 1 ]'
mutate "regular-file mode check dropped" "does not require a tracked regular file" 'ls-files -s' 'ls-files'
mutate "apply --index dropped" "does not apply the patch with git apply --index" 'apply --index' 'apply --3way'
mutate "staged re-check dropped" "does not re-check the staged set" 'diff --cached --name-only -z' 'diff --cached --stat -z'
mutate "artifact download unpinned" "actions/download-artifact is not pinned" 'download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2' 'download-artifact@v8'

# 7. mint order
mutate_perl "mint before checkout" "at or before checkout" "s/(${J2}    steps:\n)(.*?)$MINT_BLOCK$PUSH_COMMENT/\$1\$3\$2/s"
mutate "interloper after the presence step" "immediately before the mint" '      - name: Mint GitHub App token' $'      - name: Interloper\n        run: echo hi\n\n      - name: Mint GitHub App token'
mutate_perl "push before the mint" "is not after the mint" 's/(      - name: Mint GitHub App token\n.*?\n\n)(      \# The only step that needs repository write.*)\z/$2\n$1/s'
mutate_perl "App secret read before the presence step" "reads the App secrets" 's/(      - name: Validate and apply the lockfile patch\n)/$1        env:\n          LEAK: \${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n/'

# 8. checkout and token scope
mutate "checkout persists credentials (both jobs)" "checkout does not set persist-credentials: false" 'persist-credentials: false' 'persist-credentials: true'
mutate_perl "token job checkout persists credentials" "job 2: checkout does not set persist-credentials: false" "s/(${J2}persist-credentials: )false/\$1true/s"
mutate "checkout takes the token" "checkout passes a token" 'repository: ${{ env.PR_HEAD_REPO }}' $'repository: ${{ env.PR_HEAD_REPO }}\n          token: ${{ steps.app_token.outputs.token }}'

# 9. URL, argv and the single binding
mutate "token in the push URL" "userinfo" '"https://github.com/${PR_HEAD_REPO}.git" "HEAD' '"https://x-access-token:${GH_TOKEN}@github.com/${PR_HEAD_REPO}.git" "HEAD'
mutate "token in an extraheader" "GH_TOKEN reaches" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer $GH_TOKEN" \\\n'
mutate "token inlined into an extraheader" "exactly once" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer ${{ steps.app_token.outputs.token }}" \\\n'
mutate "token inlined into a url rewrite" "exactly once" $'-c credential.helper= \\\n' $'-c credential.helper= -c "url.https://x:${{ steps.app_token.outputs.token }}@github.com/.insteadOf=https://github.com/" \\\n'
mutate "second binding of the token" "exactly once" $'          GH_TOKEN: ${{ steps.app_token.outputs.token }}\n' $'          GH_TOKEN: ${{ steps.app_token.outputs.token }}\n          GITHUB_TOKEN: ${{ steps.app_token.outputs.token }}\n'
mutate "push missing its GH_TOKEN binding" "the push step does not bind GH_TOKEN" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}' 'GH_TOKEN: nothing'
mutate "env-reading helper form missing" "env-reading credential helper" "'credential.helper=!f()" "'credential.helper=!g()"
mutate "empty helper dropped" "does not clear other credential helpers first" '-c credential.helper= ' ''

# 10. git hardened
mutate "global git config left on (both jobs)" "GIT_CONFIG_GLOBAL=/dev/null is not in the job env" '      GIT_CONFIG_GLOBAL: /dev/null' ''
mutate "system git config left on (both jobs)" "GIT_CONFIG_NOSYSTEM=1 is not in the job env" '      GIT_CONFIG_NOSYSTEM: "1"' ''
mutate "git call without nohooks (job 1)" "job 1: step" 'git "${nohooks[@]}" diff HEAD' 'git diff HEAD'
mutate "git call without nohooks (job 2)" "job 2: step" 'git "${nohooks[@]}" commit' 'git commit'
mutate "fsmonitor left on" "does not define nohooks with core.hooksPath=/dev/null and core.fsmonitor=false" ' -c core.fsmonitor=false)' ')'
mutate "hooksPath left on" "does not define nohooks with core.hooksPath=/dev/null and core.fsmonitor=false" 'nohooks=(-c core.hooksPath=/dev/null' 'nohooks=(-c core.hooksPath=.githooks'

# 11. bun
mutate "setup-bun removed" "expected two setup-bun uses" 'oven-sh/setup-bun@' 'oven-sh/setup-node@'
mutate "setup-bun unpinned" "a setup-bun use is not pinned to a 40-hex SHA" 'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6 # v2' 'oven-sh/setup-bun@v2'
mutate "install scripts enabled" "a bun install runs without --ignore-scripts" 'bun install --ignore-scripts --frozen-lockfile' 'bun install --frozen-lockfile'

# 12. head SHA pin and concurrency
mutate "checkout by branch name (both jobs)" "checkout does not check out the PR head SHA" 'ref: ${{ env.PR_HEAD_SHA }}' 'ref: ${{ env.PR_HEAD_REF }}'
mutate_perl "checkout by branch name (job 1 only)" "job 1: checkout does not check out the PR head SHA" 's/(ref: \$\{\{ env\.)PR_HEAD_SHA/${1}PR_HEAD_REF/'
mutate_perl "checkout by branch name (token job only)" "job 2: checkout does not check out the PR head SHA" "s/(${J2}ref: \\\$\\{\\{ env\\.)PR_HEAD_SHA/\${1}PR_HEAD_REF/s"
mutate "head SHA bound to the branch name" "PR_HEAD_SHA is not bound to github.event.pull_request.head.sha" 'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' 'PR_HEAD_SHA: ${{ github.event.pull_request.head.ref }}'
mutate_perl "concurrency block removed" "no workflow-level concurrency block" 's/^concurrency:\n  group:[^\n]*\n  cancel-in-progress: false\n\n//m'
mutate "concurrency group not keyed on the PR" "not keyed on github.event.pull_request.number" 'group: dependabot-bun-lock-sync-${{ github.event.pull_request.number }}' 'group: dependabot-bun-lock-sync'
mutate "concurrency cancels in progress" "does not set cancel-in-progress: false" '  cancel-in-progress: false' '  cancel-in-progress: true'

# 13. job wiring and the push destination
mutate "needs dropped from the token job" "job 2 does not declare needs: update-bun-lock" '    needs: update-bun-lock' ''
mutate "changed gate dropped from the token job" "does not require needs.update-bun-lock.outputs.changed == 'true'" " && needs.update-bun-lock.outputs.changed == 'true'" ''
mutate "changed output dropped from job 1" "job 1 does not export changed" 'changed: ${{ steps.patch.outputs.changed }}' 'changed: true'
mutate "upload tolerates a missing patch" "if-no-files-found: error" 'if-no-files-found: error' 'if-no-files-found: ignore'
mutate "push to a different URL" "the push URL is not exactly" '"https://github.com/${PR_HEAD_REPO}.git" "HEAD' '"https://github.com/${GITHUB_REPOSITORY}.git" "HEAD'
mutate "push to a different branch" "the push refspec is not exactly" '"HEAD:refs/heads/${PR_HEAD_REF}"' '"HEAD:refs/heads/main"'

# 15. the push lease
mutate "push lease dropped" "the push is not leased to the head SHA" ' --force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}"' ''
mutate "push lease expects the branch name" "the push is not leased to the head SHA" ':${PR_HEAD_SHA}" \' ':${PR_HEAD_REF}" \'
mutate "push lease without an expected value" "the push is not leased to the head SHA" '--force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}"' '--force-with-lease'
mutate "push forced outright" "the push is not leased to the head SHA" '--force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}"' '--force'

# 10 (boundary). A git call inside $( ) is a git call.
mutate "git call without nohooks inside \$( )" "job 2: step" 'summary="$(git "${nohooks[@]}" apply --summary' 'summary="$(git apply --summary'

# 14. the validator, executed: each enforcing construct neutered while its
# message text stays. The static names are all still present in every one of
# these, so only the executed suite can fail them, and it must fail for the case
# that construct guards.
mutate "validator: empty-patch reject neutered" "validator [root] empty patch:" '[ -s "$patch" ] || reject' 'true || reject'
mutate "validator: --summary parse failure swallowed" "validator [root] summary parse failure:" $'apply --summary -- "$patch")" || reject "git cannot parse it"' $'apply --summary -- "$patch")" || true'
mutate "validator: --numstat parse failure swallowed" "validator [root] numstat parse failure:" $'> "$numstat" || reject "git cannot parse it"' $'> "$numstat" || true'
mutate_perl "validator: IFS-trimming read restored (tab-named path binds to the lockfile)" "validator [root] tab-named lockfile:" 's/while IFS= read -r -d \x27\x27 rec; do.*?esac\n/while IFS=\$\x27\\t\x27 read -r -d \x27\x27 added removed path; do\n/s'
mutate "validator: staged set read C-quoted" "validator [uni] clean content change:" 'diff --cached --name-only -z' 'diff --cached --name-only'
mutate "validator: numstat read without -z" "validator [root] clean content change:" 'apply --numstat -z --' 'apply --numstat --'
mutate "validator: summary-must-be-empty reject neutered" "validator [root] rename:" '[ -z "$summary" ] || reject' 'true || reject'
mutate "validator: one-file reject neutered" "validator [root] two files:" $'[ "$(tr -cd \'\\0\' < "$numstat" | wc -c)" -eq 1 ] || reject' 'true || reject'
mutate "validator: binary reject neutered" "validator [root] binary hunk:" '[ "$added" != "-" ] || reject' 'true || reject'
mutate "validator: changes-nothing reject neutered" "validator [root] no-op patch:" '[ "$added$removed" != "00" ] || reject' 'true || reject'
mutate "validator: path-equality reject neutered" "validator [root] wrong path:" '[ "$path" = "$allowed" ] || reject' 'true || reject'
mutate "validator: mode reject neutered" "validator [root] symlink:" '[ "$mode" = "100644" ] || [ "$mode" = "100755" ]' 'true'
mutate "validator: staged re-check neutered" "validator [root] pre-staged extra file:" '|| reject "after applying, something other' '|| : "after applying, something other'
mutate "validator: outside-the-index reject neutered" "validator [root] stray untracked file:" 'reject "after applying, the tree holds changes outside the index"' ': "after applying, the tree holds changes outside the index"'
mutate_perl "validator: git status piped into grep (failure reads as clean)" "validator [root] git status failure:" 's/tree="\$\((git "\$\{nohooks\[\@\]\}" status --porcelain --untracked-files=all)\)"\n          if \[ -n "\$\(grep -v \x27\^M  \x27 <<<"\$tree" \|\| true\)" \]; then/if [ -n "\$($1 | grep -v \x27^M  \x27 || true)" ]; then/'


# ============================================================================
# The pod template. Same checks (check_common, then its own toolchain check),
# plus the macOS-on-job-1-only runner rule, the two-file allowed set and the
# Flutter pin. The mutants below are written out beside the bun ones rather
# than shared: the step names, the allowed set and the validator's messages
# differ, and a shared table would have to parameterise every one of them.
# ============================================================================
POD_TEMPLATE="$TPL_DIR/lockfile-sync-pod.template.yml"
MUT_TPL="$POD_TEMPLATE"; MUT_CHECK=check_pod

echo "lockfile-sync policy (pod):"

if out="$(check_pod "$POD_TEMPLATE")"; then
    ok "pod template: macOS only on the token-free job, ubuntu-latest token job, validate-then-mint push job, single token binding, leased push, no cache, git hardened, Flutter pinned"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

J2='push-pod-lock:.*?'

# 1. runner
mutate "pod: job 1 on a Linux runner" "job 1 must hard-code runs-on: macos-latest" 'runs-on: macos-latest' 'runs-on: ubuntu-latest'
mutate "pod: self-hosted runs-on (job 1)" "job 1 must hard-code runs-on: macos-latest" 'runs-on: macos-latest' 'runs-on: [self-hosted, macOS, sassy-dog]'
mutate_perl "pod: token job on macOS" "job 2 must hard-code runs-on: ubuntu-latest" "s/(${J2}runs-on: )ubuntu-latest/\${1}macos-latest/s"
mutate_perl "pod: self-hosted runs-on (token job only)" "job 2 must hard-code runs-on: ubuntu-latest" "s/(${J2}runs-on: )ubuntu-latest/\${1}[self-hosted, linux]/s"
mutate "pod: runner as a render fact" "a {{RUNNER}} fact or a self-hosted label" 'runs-on: macos-latest' 'runs-on: {{RUNNER}}'
mutate_perl "pod: a macOS condition in the token job" "only job 1 may need macOS" "s/(${J2}      - uses: actions\\/checkout[^\\n]*\\n)/\$1        if: \\\${{ runner.os == 'macOS' }}\\n/s"

# 2. no cache
mutate_perl "pod: actions/cache re-added to job 1" "actions/cache" 's/(      - name: Regenerate pubspec\.lock\n)/      - uses: actions\/cache\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: ~\/.pub-cache\n          key: pub-\${{ runner.os }}\n\n$1/'
mutate_perl "pod: actions/cache re-added to the token job" "actions/cache" 's/(      - uses: actions\/download-artifact)/      - uses: actions\/cache\/restore\@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: y\n\n$1/'
mutate "pod: the Flutter action's own cache on" "a cache input" $'          flutter-version: ${{ env.FLUTTER_VERSION }}\n' $'          flutter-version: ${{ env.FLUTTER_VERSION }}\n          cache: true\n'

# 3. actor gate
mutate "pod: actor gate dropped from job 1" "job 1 has no github.actor" "    if: \${{ github.actor == 'dependabot[bot]' }}" '    if: ${{ true }}'
mutate "pod: actor gate dropped from job 2" "job 2 has no github.actor" "github.actor == 'dependabot[bot]' && needs" 'needs'

# 4. job 1 is token-free
mutate_perl "pod: token in an install's env" "token-free" 's/(      - name: Regenerate Podfile\.lock\n)/$1        env:\n          GH_TOKEN: \${{ steps.app_token.outputs.token }}\n/'
mutate_perl "pod: App secret in job 1's env" "token-free" 's/(    steps:\n)/    env:\n      PLATFORM_WRITER_APP_PRIVATE_KEY: \${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n$1/'
mutate_perl "pod: mint action in job 1" "token-free" 's/(      - name: Regenerate Podfile\.lock\n)/      - uses: actions\/create-github-app-token\@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n\n$1/'
mutate_perl "pod: job 1 loses contents: read" "job 1 does not set job-level permissions: contents: read" 's/(    timeout-minutes: 30\n    permissions:\n      contents: )read/$1write/'
mutate "pod: patch not limited to the two lockfiles (one dropped)" "is not limited to the two" " '{{APP_DIR}}/ios/Podfile.lock' >" ' >'
mutate "pod: patch widened to a glob" "is not limited to the two" "'{{APP_DIR}}/pubspec.lock' '{{APP_DIR}}/ios/Podfile.lock' >" "'*.lock' >"
mutate "pod: patch with textconv allowed" "does not package the change with git diff HEAD --binary" ' --no-textconv --' ' -- '
mutate_perl "pod: upload unpinned" "job 1 must upload the patch with exactly one SHA-pinned" 's/upload-artifact\@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7\.0\.2/upload-artifact\@v7/'
mutate "pod: upload tolerates a missing patch" "if-no-files-found: error" 'if-no-files-found: error' 'if-no-files-found: ignore'

# 5. job 2 runs no package manager
mutate_perl "pod: pod install in the token job" "job 2 (the token job) runs a package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: pod install --repo-update\n\n$1/'
mutate_perl "pod: flutter pub get in the token job" "job 2 (the token job) runs a package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: cd x \&\& flutter pub get\n\n$1/'
mutate_perl "pod: bundler in the token job" "job 2 (the token job) runs a package manager" 's/(      - name: Require the app credentials\n)/      - name: Interloper\n        run: bundle exec pod install\n\n$1/'
mutate_perl "pod: the Flutter action in the token job" "job 2 (the token job) runs a package manager" "s/(${J2})(      - uses: actions\\/download-artifact)/\$1      - uses: subosito\\/flutter-action\\\@fd55f4c5af5b953cc57a2be44cb082c8f6635e8e # v2.21.0\n\n\$2/s"

# 6. validate before the mint
VALIDATE_BLOCK='(      \# Every rule here is about the patch.*?\n\n)'
MINT_BLOCK='(      \# Minted only now:.*?\n\n)'
PUSH_COMMENT='(?=      \# The only step that needs repository write)'
mutate_perl "pod: validate moved after the mint" "is validated (step" "s/$VALIDATE_BLOCK$MINT_BLOCK$PUSH_COMMENT/\$2\$1/s"
mutate "pod: allowed set widened" "the validator's allowed set is not exactly" "'{{APP_DIR}}/ios/Podfile.lock')" "'{{APP_DIR}}/ios/Podfile.lock' '{{APP_DIR}}/pubspec.yaml')"
mutate "pod: membership loosened to a glob" "does not require every patched path to EQUAL a member" '[ "$path" = "$a" ]' '[[ "$path" == *"$a" ]]'
mutate "pod: apply --summary dropped" "does not read the patch with git apply --summary" 'apply --summary' 'apply --stat'
mutate "pod: apply --numstat dropped" "does not read the patch with git apply --numstat" 'apply --numstat' 'apply --stat'
mutate "pod: regular-file mode check dropped" "does not require a tracked regular file" 'ls-files -s' 'ls-files'
mutate "pod: apply --index dropped" "does not apply the patch with git apply --index" 'apply --index' 'apply --3way'
mutate "pod: staged re-check dropped" "does not re-check the staged set" 'diff --cached --name-only -z' 'diff --cached --stat -z'
mutate "pod: duplicate-path rule dropped" "does not reject a path that appears twice" 'appears more than once' 'appears twice'
mutate "pod: artifact download unpinned" "actions/download-artifact is not pinned" 'download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2' 'download-artifact@v8'

# 7. mint order
mutate_perl "pod: mint before checkout" "at or before checkout" "s/(${J2}    steps:\n)(.*?)$MINT_BLOCK$PUSH_COMMENT/\$1\$3\$2/s"
mutate "pod: interloper after the presence step" "immediately before the mint" '      - name: Mint GitHub App token' $'      - name: Interloper\n        run: echo hi\n\n      - name: Mint GitHub App token'
mutate_perl "pod: push before the mint" "is not after the mint" 's/(      - name: Mint GitHub App token\n.*?\n\n)(      \# The only step that needs repository write.*)\z/$2\n$1/s'
mutate_perl "pod: App secret read before the presence step" "reads the App secrets" 's/(      - name: Validate and apply the lockfile patch\n)/$1        env:\n          LEAK: \${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n/'

# 8. checkout and token scope
mutate "pod: checkout persists credentials (both jobs)" "checkout does not set persist-credentials: false" 'persist-credentials: false' 'persist-credentials: true'
mutate_perl "pod: token job checkout persists credentials" "job 2: checkout does not set persist-credentials: false" "s/(${J2}persist-credentials: )false/\$1true/s"
mutate "pod: checkout takes the token" "checkout passes a token" 'repository: ${{ env.PR_HEAD_REPO }}' $'repository: ${{ env.PR_HEAD_REPO }}\n          token: ${{ steps.app_token.outputs.token }}'

# 9. URL, argv and the single binding
mutate "pod: token in the push URL" "userinfo" '"https://github.com/${PR_HEAD_REPO}.git" "HEAD' '"https://x-access-token:${GH_TOKEN}@github.com/${PR_HEAD_REPO}.git" "HEAD'
mutate "pod: token in an extraheader" "GH_TOKEN reaches" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer $GH_TOKEN" \\\n'
mutate "pod: token inlined into an extraheader" "exactly once" $'-c credential.helper= \\\n' $'-c credential.helper= -c "http.extraheader=Authorization: bearer ${{ steps.app_token.outputs.token }}" \\\n'
mutate "pod: second binding of the token" "exactly once" $'          GH_TOKEN: ${{ steps.app_token.outputs.token }}\n' $'          GH_TOKEN: ${{ steps.app_token.outputs.token }}\n          GITHUB_TOKEN: ${{ steps.app_token.outputs.token }}\n'
mutate "pod: push missing its GH_TOKEN binding" "the push step does not bind GH_TOKEN" 'GH_TOKEN: ${{ steps.app_token.outputs.token }}' 'GH_TOKEN: nothing'
mutate "pod: env-reading helper form missing" "env-reading credential helper" "'credential.helper=!f()" "'credential.helper=!g()"
mutate "pod: empty helper dropped" "does not clear other credential helpers first" '-c credential.helper= ' ''

# 10. git hardened
mutate "pod: global git config left on (both jobs)" "GIT_CONFIG_GLOBAL=/dev/null is not in the job env" '      GIT_CONFIG_GLOBAL: /dev/null' ''
mutate "pod: system git config left on (both jobs)" "GIT_CONFIG_NOSYSTEM=1 is not in the job env" '      GIT_CONFIG_NOSYSTEM: "1"' ''
mutate "pod: git call without nohooks (job 1)" "job 1: step" 'git "${nohooks[@]}" diff HEAD' 'git diff HEAD'
mutate "pod: git call without nohooks (job 2)" "job 2: step" 'git "${nohooks[@]}" commit' 'git commit'
mutate "pod: git call without nohooks inside \$( )" "job 2: step" 'summary="$(git "${nohooks[@]}" apply --summary' 'summary="$(git apply --summary'
mutate "pod: fsmonitor left on" "does not define nohooks with core.hooksPath=/dev/null and core.fsmonitor=false" ' -c core.fsmonitor=false)' ')'
mutate "pod: hooksPath left on" "does not define nohooks with core.hooksPath=/dev/null and core.fsmonitor=false" 'nohooks=(-c core.hooksPath=/dev/null' 'nohooks=(-c core.hooksPath=.githooks'

# 12. head SHA pin and concurrency
mutate "pod: checkout by branch name (both jobs)" "checkout does not check out the PR head SHA" 'ref: ${{ env.PR_HEAD_SHA }}' 'ref: ${{ env.PR_HEAD_REF }}'
mutate_perl "pod: checkout by branch name (token job only)" "job 2: checkout does not check out the PR head SHA" "s/(${J2}ref: \\\$\\{\\{ env\\.)PR_HEAD_SHA/\${1}PR_HEAD_REF/s"
mutate "pod: head SHA bound to the branch name" "PR_HEAD_SHA is not bound to github.event.pull_request.head.sha" 'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' 'PR_HEAD_SHA: ${{ github.event.pull_request.head.ref }}'
mutate_perl "pod: concurrency block removed" "no workflow-level concurrency block" 's/^concurrency:\n  group:[^\n]*\n  cancel-in-progress: false\n\n//m'
mutate "pod: concurrency group not keyed on the PR" "not keyed on github.event.pull_request.number" 'group: dependabot-pod-lock-sync-${{ github.event.pull_request.number }}' 'group: dependabot-pod-lock-sync'
mutate "pod: concurrency cancels in progress" "does not set cancel-in-progress: false" '  cancel-in-progress: false' '  cancel-in-progress: true'

# 13. job wiring and the push destination
mutate "pod: needs dropped from the token job" "job 2 does not declare needs: update-pod-lock" '    needs: update-pod-lock' ''
mutate "pod: changed gate dropped from the token job" "does not require needs.update-pod-lock.outputs.changed == 'true'" " && needs.update-pod-lock.outputs.changed == 'true'" ''
mutate "pod: changed output dropped from job 1" "job 1 does not export changed" 'changed: ${{ steps.patch.outputs.changed }}' 'changed: true'
mutate "pod: push to a different URL" "the push URL is not exactly" '"https://github.com/${PR_HEAD_REPO}.git" "HEAD' '"https://github.com/${GITHUB_REPOSITORY}.git" "HEAD'
mutate "pod: push to a different branch" "the push refspec is not exactly" '"HEAD:refs/heads/${PR_HEAD_REF}"' '"HEAD:refs/heads/main"'

# 15. the push lease
mutate "pod: push lease dropped" "the push is not leased to the head SHA" ' --force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}"' ''
mutate "pod: push lease expects the branch name" "the push is not leased to the head SHA" ':${PR_HEAD_SHA}" \' ':${PR_HEAD_REF}" \'
mutate "pod: push lease without an expected value" "the push is not leased to the head SHA" '--force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}"' '--force-with-lease'
mutate "pod: push forced outright" "the push is not leased to the head SHA" '--force-with-lease="refs/heads/${PR_HEAD_REF}:${PR_HEAD_SHA}"' '--force'

# Flutter
mutate "pod: Flutter action removed" "expected exactly one flutter-action use" 'subosito/flutter-action@' 'subosito/setup-flutter@'
mutate "pod: Flutter action unpinned" "the flutter-action use is not pinned to a 40-hex SHA" 'subosito/flutter-action@fd55f4c5af5b953cc57a2be44cb082c8f6635e8e # v2.21.0' 'subosito/flutter-action@v2'
mutate "pod: Flutter taken from the image" "flutter-action does not take the repo's pin" 'flutter-version: ${{ env.FLUTTER_VERSION }}' 'flutter-version: stable'
mutate "pod: Flutter pin not a render fact" "FLUTTER_VERSION is not bound to the {{FLUTTER_VERSION}} fact" "FLUTTER_VERSION: '{{FLUTTER_VERSION}}'" "FLUTTER_VERSION: '3.35.1'"

# 14. the validator, executed. Each enforcing construct neutered while its
# message text stays, so only the executed suite can fail it.
mutate "pod validator: empty-patch reject neutered" "validator [root] empty patch:" '[ -s "$patch" ] || reject' 'true || reject'
mutate "pod validator: --summary parse failure swallowed" "validator [root] summary parse failure:" $'apply --summary -- "$patch")" || reject "git cannot parse it"' $'apply --summary -- "$patch")" || true'
mutate "pod validator: --numstat parse failure swallowed" "validator [root] numstat parse failure:" $'> "$numstat" || reject "git cannot parse it"' $'> "$numstat" || true'
mutate_perl "pod validator: IFS-trimming read restored (tab-named path binds to the lockfile)" "validator [root] tab-named lockfile:" 's/while IFS= read -r -d \x27\x27 rec; do.*?esac\n/while IFS=\$\x27\\t\x27 read -r -d \x27\x27 added removed path; do\n/s'
mutate "pod validator: staged set read C-quoted" "validator [uni] pubspec.lock only:" 'diff --cached --name-only -z' 'diff --cached --name-only'
mutate "pod validator: numstat read without -z" "validator [root] binary hunk:" 'apply --numstat -z --' 'apply --numstat --'
mutate "pod validator: summary-must-be-empty reject neutered" "validator [root] rename:" '[ -z "$summary" ] || reject' 'true || reject'
mutate "pod validator: binary reject neutered" "validator [root] binary hunk:" '[ "$added" != "-" ] || reject' 'true || reject'
mutate "pod validator: changes-nothing reject neutered" "validator [root] no-op patch:" '[ "$added$removed" != "00" ] || reject' 'true || reject'
mutate "pod validator: allowed-set reject neutered" "validator [root] a third file:" '|| reject "$path is not an allowed lockfile path' '|| : "$path is not an allowed lockfile path'
mutate "pod validator: duplicate-path reject neutered" "validator [root] duplicate path:" 'reject "$path appears more than once in the patch"' ': "$path appears more than once in the patch"'
mutate "pod validator: mode reject neutered" "validator [root] symlink:" '[ "$mode" = "100644" ] || [ "$mode" = "100755" ]' 'true'
mutate "pod validator: staged re-check neutered" "validator [root] pre-staged extra file:" '|| reject "after applying, something other than the patched lockfiles is staged"' '|| : "after applying, something other than the patched lockfiles is staged"'
mutate "pod validator: outside-the-index reject neutered" "validator [root] stray untracked file:" 'reject "after applying, the tree holds changes outside the index"' ': "after applying, the tree holds changes outside the index"'
mutate_perl "pod validator: git status piped into grep (failure reads as clean)" "validator [root] git status failure:" 's/tree="\$\((git "\$\{nohooks\[\@\]\}" status --porcelain --untracked-files=all)\)"\n          if \[ -n "\$\(grep -v \x27\^M  \x27 <<<"\$tree" \|\| true\)" \]; then/if [ -n "\$($1 | grep -v \x27^M  \x27 || true)" ]; then/'

exit "$fail"
