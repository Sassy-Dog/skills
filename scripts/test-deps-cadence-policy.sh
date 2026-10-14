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
    metadata) cat "${FAKE_CARGO_METADATA:-/dev/null}"; exit 0 ;;
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
    local mint_ln refresh_ln report_ln report2_ln pr_ln first_ref validate_ln
    mint_ln="$(grep -nE 'actions/create-github-app-token@' "$impl" | head -1 | cut -d: -f1)"
    refresh_ln="$(grep -nF "      - name: $REFRESH_STEP" "$impl" | cut -d: -f1)"
    report_ln="$(grep -nF "      - name: $REPORT_STEP" "$impl" | cut -d: -f1)"
    report2_ln="$(grep -nF "      - name: $REPORT2_STEP" "$impl" | cut -d: -f1)"
    pr_ln="$(grep -nF "      - name: $PR_STEP" "$impl" | cut -d: -f1)"
    validate_ln="$(grep -nF "      - name: $VALIDATE_STEP" "$impl" | cut -d: -f1)"
    first_ref="$(grep -nE 'steps\.app_token\.' "$impl" | head -1 | cut -d: -f1)"
    if [ -z "$mint_ln" ] || [ -z "$refresh_ln" ] || [ -z "$report_ln" ] || [ -z "$report2_ln" ] || [ -z "$pr_ln" ] || [ -z "$validate_ln" ]; then
        echo "could not locate the mint, refresh, report, validate and PR steps to order them"; rc=1
    elif [ "$mint_ln" -lt "$refresh_ln" ] || [ "$mint_ln" -lt "$report_ln" ] || [ "$mint_ln" -lt "$report2_ln" ] || [ "$mint_ln" -lt "$validate_ln" ] || [ "$mint_ln" -gt "$pr_ln" ]; then
        echo "the App token is minted at line $mint_ln, not after the package managers (refresh $refresh_ln, reports $report_ln and $report2_ln) and the patch validation ($validate_ln), before the PR step ($pr_ln)"; rc=1
    elif [ -n "$first_ref" ] && [ "$first_ref" -lt "$mint_ln" ]; then
        echo "a step before the mint reads steps.app_token (line $first_ref)"; rc=1
    fi
    if grep -qE 'x-access-token:\$|https://[^ "]*\$\{?GH_TOKEN' <<<"$c"; then
        echo "the token is interpolated into a URL"; rc=1
    fi

    # --- executed ---------------------------------------------------------------
    refresh="$WORK/refresh.sh"; report="$WORK/report.sh"; prstep="$WORK/pr.sh"
    local package="$WORK/package.sh" validate="$WORK/validate.sh" report2="$WORK/report2.sh"
    step_run "$impl" "$REPORT2_STEP" > "$report2"
    step_run "$impl" "$REFRESH_STEP" > "$refresh"
    step_run "$impl" "$REPORT_STEP" > "$report"
    step_run "$impl" "$PR_STEP" > "$prstep"
    step_run "$impl" "$PACKAGE_STEP" > "$package"
    step_run "$impl" "$VALIDATE_STEP" > "$validate"
    for f in "$refresh" "$report" "$report2" "$prstep" "$package" "$validate"; do
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
mutate "no lane still writes a section" impl '[ "$wanted" -eq 1 ] || exit 0' 'true'
mutate "bun/npm heading reworded" impl 'echo "### Exact pins (bun and npm lanes)"' 'echo "### Exact pins (bun, npm, pub and cargo lanes)"'
mutate "bun/npm sentence reworded" impl 'No bun or npm lane declares an exact pin.' 'No bun or npm lane declares an exact pin in this repo.'
mutate "not-reported claim returns" impl '# do the same in a second section of their own (version 4).' '# exact pins are not reported in this version.'
mutate "pub/cargo report after the mint" impl $'      - name: Report exact pins (pub and cargo lanes)\n' $'      - name: Mint GitHub App token\n        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          client-id: ${{ secrets.PLATFORM_WRITER_APP_CLIENT_ID }}\n          private-key: ${{ secrets.PLATFORM_WRITER_APP_PRIVATE_KEY }}\n\n      - name: Report exact pins (pub and cargo lanes)\n'

exit "$fail"
