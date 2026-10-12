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
#   8. The exact-pin report (ported from a consumer's deps-update script): its
#      `bun outdated` table parser against VERBATIM bun 1.4.2 captures in
#      scripts/fixtures/deps-cadence/ (plain, workspaces with the extra column,
#      and coloured, where bun draws columns with U+2502 and wraps cells in ANSI
#      codes), and garbage must parse to nothing. End to end: a stale exact pin
#      is reported, a range is not, a failing `bun outdated` reads "could not
#      evaluate" (never current), and the report step does not depend on
#      whether anything moved.
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
PR_STEP="Open the refresh PR and enqueue it"

# code <file> — the template body (after `---`) without comment-only lines.
# Comments explain the rules in the very words the checks forbid.
code() { sed -n '/^---$/,$p' "$1" | grep -vE '^[[:space:]]*#'; }

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
[ "$1" = "update" ] || exit 0
echo "# bumped" >> Cargo.lock
[ -f src/main.rs ] && echo '// touched' >> src/main.rs
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
chmod +x "$BIN"/*

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
        echo '{"name":"web","dependencies":{"is-number":"6.0.0","left-pad":"^1.1.0"},"devDependencies":{"kind-of":"=6.0.3"}}' > web/package.json
        echo 'lock' > web/bun.lock
        echo '{"name":"pkg"}' > web/pkg/package.json
        echo 'readme' > web/README.md
        echo '[package]' > Cargo.toml
        echo 'lock' > Cargo.lock
        echo 'fn main() {}' > src/main.rs
        git add -A && git commit -qm init
    )
}

# --- the check -------------------------------------------------------------------
# check <trigger> <impl> — 0 when every rule holds, 1 with reasons otherwise.
check() {
    local trig="$1" impl="$2" rc=0 c line n refresh report prstep d out

    # 1. one credential
    c="$(code "$impl")"
    if grep -qE 'GITHUB_TOKEN|github\.token' <<<"$c"; then
        echo "impl reads GITHUB_TOKEN outside a comment (no fallback credential)"; rc=1
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
        if ! [[ "$line" =~ ^[[:space:]]*GH_TOKEN:[[:space:]]*\$\{\{[[:space:]]*steps\.app_token\.outputs\.token[[:space:]]*\}\}[[:space:]]*$ ]]; then
            echo "GH_TOKEN is not exactly the minted App token: $line"; rc=1
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
    n="$(grep -cE '(^|[^a-z-])git add' <<<"$c")"
    if [ "$n" -ne 1 ] || ! grep -qE 'git add --pathspec-from-file="\$work/stage\.z" --pathspec-file-nul[[:space:]]*$' <<<"$c"; then
        echo "git add must appear once, staging only the recorded lane paths (\$work/stage.z); found $n"; rc=1
    fi
    if grep -qE 'git add[^\n]*( -A| --all| -u| --update| \.( |$))|git commit[^\n]*( -a| --all| -[a-zA-Z]*a)' <<<"$c"; then
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

    # --- executed ---------------------------------------------------------------
    refresh="$WORK/refresh.sh"; report="$WORK/report.sh"; prstep="$WORK/pr.sh"
    step_run "$impl" "$REFRESH_STEP" > "$refresh"
    step_run "$impl" "$REPORT_STEP" > "$report"
    step_run "$impl" "$PR_STEP" > "$prstep"
    for f in "$refresh" "$report" "$prstep"; do
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
    d="$WORK/x-ok"; rm -rf "$d" "$d.bare" "$d.tmp"; new_repo "$d"
    git init -q --bare "$d.bare"
    printf '[url "%s"]\n\tinsteadOf = https://x-access-token:tok@github.com/o/r.git\n' "$d.bare" > "$d.gitconfig"
    if ! out="$(cd "$d" && gh_shell "$refresh" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" 2>&1)"; then
        echo "the refresh step failed on a healthy scratch repo: $(tail -n1 <<<"$out")"; rc=1
    else
        local staged
        staged="$(tr '\0' '\n' < "$d.tmp/deps-cadence/stage.z" | sort -u | tr '\n' ' ')"
        if [ "$staged" != "Cargo.lock web/bun.lock web/pkg/package.json " ]; then
            echo "the refresh recorded paths other than the lanes' manifests and lockfiles: $staged"; rc=1
        fi
        echo "report" > "$d.tmp/deps-cadence/pins.md"
        : > "$d.ghlog"
        if ! out="$(cd "$d" && gh_shell "$prstep" RUNNER_TEMP="$d.tmp" LANES="bun:/web cargo:/" GH_TOKEN=tok APP_SLUG=cadence-app \
                BRANCH=chore/deps-2026-10 MONTH=2026-10 DEFAULT_BRANCH=main GITHUB_REPOSITORY=o/r \
                GIT_CONFIG_GLOBAL="$d.gitconfig" FAKE_GH_LOG="$d.ghlog" 2>&1)"; then
            echo "the PR step failed: $(tail -n2 <<<"$out" | tr '\n' ' ')"; rc=1
        else
            local committed
            committed="$(git -C "$d.bare" diff-tree --no-commit-id --name-only -r refs/heads/chore/deps-2026-10 2>/dev/null | sort | tr '\n' ' ')"
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
        fi
    fi

    # 7 (executed). nothing moved: exit 0, notice, no PR.
    d="$WORK/x-none"; rm -rf "$d" "$d.tmp"; new_repo "$d"
    mkdir -p "$d.tmp/deps-cadence"; : > "$d.tmp/deps-cadence/stage.z"; : > "$d.ghlog"
    if ! out="$(cd "$d" && gh_shell "$prstep" RUNNER_TEMP="$d.tmp" LANES="bun:/web" GH_TOKEN=tok APP_SLUG=a \
            BRANCH=b MONTH=m DEFAULT_BRANCH=main GITHUB_REPOSITORY=o/r FAKE_GH_LOG="$d.ghlog" 2>&1)"; then
        echo "nothing moved, yet the PR step failed"; rc=1
    elif ! grep -q '::notice::Nothing moved' <<<"$out" || grep -q '^pr create' "$d.ghlog"; then
        echo "nothing moved must be a ::notice:: and no PR"; rc=1
    fi

    # 8. the exact-pin report.
    report_checks "$impl" "$report" || rc=1
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
    # The report never waits on a change: its only condition is the month skip.
    cond="$(step_block "$impl" "$REPORT_STEP" | sed -n 's/^        if: //p')"
    [ "$cond" = "\${{ steps.plan.outputs.skip != 'true' }}" ] \
        || { echo "the report step's condition is '$cond'; it must run whether or not anything moved"; rc=1; }
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
mutate "refresh failure swallowed"   impl    '(cd "./$rel" && bun update --ignore-scripts)' '(cd "./$rel" && bun update --ignore-scripts) || true'
mutate "unknown ecosystem tolerated" impl    $'                echo "::error::LANES names \'$eco\', which has no refresh command here. Re-render with sassy-dog:setup-deps."\n                exit 1 ;;' $'                echo "::warning::skipping $eco"\n                continue ;;'
mutate "continue-on-error"           impl    $'        id: refresh\n' $'        id: refresh\n        continue-on-error: true\n'
mutate "--label on the PR"           impl    '--title "$title" --body-file' '--title "$title" --label dependencies --body-file'
mutate "git add -A"                  impl    'git add --pathspec-from-file="$work/stage.z" --pathspec-file-nul' 'git add -A'
mutate "bun lane stages its whole dir" impl  '":(glob)${prefix}**/package.json"' '":(glob)${prefix}**"'
mutate "non-local uses in trigger"   trigger 'uses: ./.github/workflows/deps-cadence-impl.yml' 'uses: octo-org/shared/.github/workflows/deps-cadence-impl.yml@v1'
mutate "schedule in the impl"        impl    $'on:\n  workflow_call:' $'on:\n  schedule:\n    - cron: "0 9 1 * *"\n  workflow_call:'
mutate "merge method flag"           impl    'gh pr merge --auto "$url"' 'gh pr merge --auto --squash "$url"'
mutate "parser ignores U+2502"       impl    's/\x1b\[[0-9;]*m//g; s/\xe2\x94\x82/|/g' 's/\x1b\[[0-9;]*m//g'
mutate "report waits on a change"    impl    $'      - name: Report exact pins (bun and npm lanes)\n        if: ${{ steps.plan.outputs.skip != \'true\' }}' $'      - name: Report exact pins (bun and npm lanes)\n        if: ${{ steps.plan.outputs.skip != \'true\' && steps.refresh.outputs.changed == \'true\' }}'

exit "$fail"
