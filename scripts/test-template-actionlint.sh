#!/usr/bin/env bash
# test-template-actionlint.sh — lint setup-deps' WORKFLOW TEMPLATES by rendering
# them first (issue #245).
#
# Why this exists: `actionlint` is the gate this repo relies on for workflow
# correctness, and bare `actionlint` lints the real `.github/workflows/*`,
# including ci.yml and the release-lag reminder. The workflow templates
# setup-deps renders into every consumer repo were otherwise linted by nothing,
# while being the highest-consequence YAML in the tree:
# `pull_request_target`, a minted PLATFORM_WRITER_APP_* token, and a push to a
# PR head ref. A defect there does not redden this repo's CI; it ships to
# consumers, where Dependabot answers a broken workflow by silently doing
# nothing. The executed base-lock scenario also proves the generated bun
# workflow does not need persisted checkout credentials after checkout.
#
# THE COMPLICATION, and why this is a render gate rather than a lint path:
# the templates are not directly lintable. They carry render-time placeholders
# (`# {{IF:FLAG}}` blocks and `{{TOKEN}}` substitutions), so pointing actionlint
# at the raw files produces parse errors that are not real defects. What has to
# be linted is a RENDER. #232's agent did exactly that by hand — rendering both
# lockfile templates four ways into a scratch repo and linting the results —
# and that manual step is what this automates.
#
# The render rules implemented below are the ones the template headers document,
# and nothing else:
#
#   1. drop the template's own header (everything before the `---` line)
#   2. `# {{IF:FLAG}} … # {{ENDIF}}` (at any indent) keeps its body and loses
#      its two marker lines when the flag is ON, and is deleted wholesale when
#      it is OFF
#   3. `{{TOKEN}}` is substituted with the variant's fact; a directory fact of
#      `.` collapses the `{{DIR}}/` PREFIX to nothing instead (a `./` prefix
#      breaks the on.paths filter — see the lockfile template headers)
#
# A bare `{{DIR}}` with no trailing slash is deliberately NOT substituted on a
# root render: at the root the only correct renders of those are inside an
# IF-block that is deleted, so a surviving token means a render rule the recipe
# cannot express — the leftover-token assertion below fails loudly rather than
# emitting `'./ios'`.
#
# Five vacuous-green guards, because every way this gate could cover nothing
# looks identical to a pass:
#
#   - every tracked *.template.yml is covered by the matrix, and every matrix
#     entry names a tracked template (a NEW template is unlinted otherwise)
#   - every `{{IF:FLAG}}` appearing in a template is ON in some variant (a new
#     arm is otherwise rendered away in every variant and never linted)
#   - a render carrying a leftover `{{TOKEN}}` or marker fails
#   - the rendered bun step restores the fetched base lock while its origin is
#     unreachable, proving it performs no post-checkout authenticated fetch
#   - missing actionlint SKIPS only the lint calls locally (the coverage and
#     render assertions still run) and is a hard FAILURE under CI=true
#
# Mutation-proof (a gate that cannot fail is decorative), three ways: an
# expression defect must be caught, an unsubstituted token must be caught, and
# an unknown runner label that is NOT `sassy-dog` must still fail — the custom
# self-hosted label is declared to actionlint via a config file, so the
# tolerance is scoped to that one label rather than muting the rule.
#
# Wired into scripts/preflight.sh (which skips it under CI=true — ci.yml runs it
# as its own step, after the pinned actionlint install). Run directly:
#   bash scripts/test-template-actionlint.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-template-actionlint: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

TEMPLATE_DIR="skills/setup-deps/references/templates"
# Keep in lockstep with ACTIONLINT_IMAGE in scripts/preflight.sh and with the
# pinned version in .github/workflows/ci.yml.
ACTIONLINT_IMAGE="${ACTIONLINT_IMAGE:-rhysd/actionlint:1.7.7}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "template-actionlint tests (work: $WORK)" >&2

# --- the render matrix -------------------------------------------------------
# variant|template|ON-flags (comma-separated)|TOKEN=VALUE;TOKEN=VALUE
# One entry per documented render shape. The two lockfile templates each render
# nested and at the repo root; auto-merge renders one arm per merge strategy;
# the deps-cadence trigger and impl render as a pair per shape.
VARIANTS=(
    "auto-merge-queue|dependabot-auto-merge.template.yml|MERGE_QUEUE|RUNNER=[self-hosted, linux, sassy-dog]"
    "auto-merge-direct|dependabot-auto-merge.template.yml|DIRECT_MERGE|RUNNER=ubuntu-latest"
    "bun-nested|lockfile-sync-bun.template.yml|NESTED_PKG|RUNNER=[self-hosted, linux, sassy-dog];PKG_DIR=web"
    "bun-root|lockfile-sync-bun.template.yml||RUNNER=[self-hosted, linux, sassy-dog];PKG_DIR=."
    "pod-nested|lockfile-sync-pod.template.yml|NESTED_APP|RUNNER=[self-hosted, macOS, sassy-dog];APP_DIR=app;FLUTTER_VERSION=3.35.1"
    "pod-root|lockfile-sync-pod.template.yml||RUNNER=[self-hosted, macOS, sassy-dog];APP_DIR=.;FLUTTER_VERSION=3.35.1"
    # The deps-cadence pair renders into ONE variant directory per shape, so
    # actionlint resolves the trigger's local `uses: ./…impl.yml` against the
    # impl it is rendered beside. Two shapes put every toolchain arm ON once.
    "cadence-files|deps-cadence.template.yml||"
    "cadence-files|deps-cadence-impl.template.yml|BUN_PIN_FILE,NODE_PIN_LITERAL,FLUTTER,RUST|LANES=bun:/web npm:/tools pub:/app cargo:/;NO_REFRESH=github-actions, gradle;NOT_REFRESHED=none;BUN_VERSION_FILE=.bun-version;NODE_VERSION=22.11.0;FLUTTER_PIN_FILE=app/.fvmrc;RUST_PIN_FILE=rust-toolchain.toml"
    "cadence-literals|deps-cadence.template.yml||"
    "cadence-literals|deps-cadence-impl.template.yml|BUN_PIN_LITERAL,NODE_PIN_FILE|LANES=bun:/ npm:/;NO_REFRESH=none;NOT_REFRESHED=none;BUN_VERSION=1.3.5;NODE_VERSION_FILE=.nvmrc"
)

# The one expected finding: `sassy-dog` is a custom self-hosted label actionlint
# cannot know about. DECLARED here rather than muted with -ignore, so every
# OTHER unknown label still fails (mutation 3 proves it).
cat > "$WORK/actionlint.yaml" <<'CONFIG'
self-hosted-runner:
  labels:
    - sassy-dog
CONFIG

# render <template-path> <on-flags-csv> <subs> — the three rules above; writes
# the render to stdout.
render() {
    local tpl="$1" flags="$2" subs="$3"
    local line trimmed flag in_header=1 keep=1 out="" key value pair

    while IFS= read -r line; do
        if [ "$in_header" = "1" ]; then
            [ "$line" = "---" ] || continue
            in_header=0
        fi
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            '# {{IF:'*'}}')
                flag="${trimmed#\# \{\{IF:}"
                flag="${flag%\}\}}"
                if [[ ",$flags," == *",$flag,"* ]]; then keep=1; else keep=0; fi
                continue
                ;;
            '# {{ENDIF}}')
                keep=1
                continue
                ;;
        esac
        [ "$keep" = "1" ] && out+="$line"$'\n'
    done < "$tpl"

    while IFS= read -r -d ';' pair || [ -n "$pair" ]; do
        [ -n "$pair" ] || continue
        key="${pair%%=*}"
        value="${pair#*=}"
        if [ "$value" = "." ]; then
            out="${out//\{\{$key\}\}\//}"
        else
            out="${out//\{\{$key\}\}/$value}"
        fi
    done <<< "$subs;"

    printf '%s' "$out"
}

# assert_complete <rendered-file> — the render must carry no leftover
# `{{TOKEN}}` and must not be empty. Prints the reason and returns non-zero.
assert_complete() {
    local f="$1" leftovers
    if [ ! -s "$f" ]; then
        echo "render is empty (no '---' document start in the template?)"
        return 1
    fi
    leftovers=$(grep -nE '\{\{[A-Za-z_]+(:[A-Za-z_]+)?\}\}' "$f")
    if [ -n "$leftovers" ]; then
        echo "unsubstituted token(s) survived the render: $(tr '\n' ' ' <<< "$leftovers")"
        return 1
    fi
    return 0
}

# --- resolve actionlint ------------------------------------------------------
# Missing actionlint is a courtesy SKIP for a contributor and a hard FAILURE in
# CI: a gate that quietly no-ops in the only place it is required is decorative.
# The checks that need no linter — matrix coverage, flag coverage, and the
# render assertions — run either way, so a contributor without actionlint still
# catches a template the matrix no longer covers.
HAVE_AL=1
AL=(actionlint)
if ! command -v actionlint >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        AL=(docker run --rm -v "$WORK:/w" --workdir /w "$ACTIONLINT_IMAGE")
    else
        HAVE_AL=0
    fi
fi
if [ "$HAVE_AL" -eq 0 ]; then
    if [ "${CI:-}" = "true" ]; then
        echo "  FAIL  actionlint unavailable under CI — this gate must never skip in CI" >&2
        echo "template-actionlint tests: FAILURES above" >&2
        exit 1
    fi
    echo "  skip  actionlint itself (no binary or docker — CI still enforces); render checks still run" >&2
fi

# lint <relative-paths...> — always invoked with $WORK as the working directory
# so the same relative paths address the binary and the container mount.
lint() {
    ( cd "$WORK" && "${AL[@]}" -config-file actionlint.yaml -no-color "$@" 2>&1 )
}

# --- 1. matrix coverage ------------------------------------------------------
# A template nobody rendered is a template nobody linted, and it reads as a pass.
tracked_templates=$(git ls-files "$TEMPLATE_DIR/*.template.yml")
if [ -z "$tracked_templates" ]; then
    bad "template set — no tracked *.template.yml under $TEMPLATE_DIR (moved or renamed? the run would pass while covering nothing)"
else
    matrix_fail=0
    covered=$(printf '%s\n' "${VARIANTS[@]}" | cut -d'|' -f2 | sort -u)
    for t in $tracked_templates; do
        base="${t##*/}"
        if ! grep -qxF "$base" <<< "$covered"; then
            bad "matrix coverage — $base is tracked but no variant renders it (it would be linted by nothing)"
            matrix_fail=1
        fi
    done
    while IFS= read -r base; do
        if [ ! -r "$TEMPLATE_DIR/$base" ]; then
            bad "matrix coverage — variant names '$base', which is not a readable template"
            matrix_fail=1
        fi
    done <<< "$covered"
    [ "$matrix_fail" -eq 0 ] &&
        ok "matrix coverage ($(wc -l <<< "$covered" | tr -d ' ') templates, ${#VARIANTS[@]} variants)"
fi

# --- 2. flag coverage --------------------------------------------------------
# An IF-arm that is OFF in every variant is rendered away every time and never
# linted — the same vacuous green one directory up.
# Scanned in the BODY only (the region a render keeps): every template header
# spells the marker syntax out as a literal `# {{IF:FLAG}}` example, and no
# variant can turn a documentation example on.
all_flags=$(for t in $tracked_templates; do
        sed -n '/^---$/,$p' "$t" | grep -oE '\{\{IF:[A-Za-z_]+\}\}'
    done | sed 's/{{IF://; s/}}//' | sort -u)
if [ -z "$all_flags" ]; then
    bad "flag coverage — no {{IF:FLAG}} markers found in any template body (marker syntax changed? the renders would cover nothing)"
else
    flag_fail=0
    on_flags=$(printf '%s\n' "${VARIANTS[@]}" | cut -d'|' -f3 | tr ',' '\n' | sort -u)
    for f in $all_flags; do
        if ! grep -qxF "$f" <<< "$on_flags"; then
            bad "flag coverage — {{IF:$f}} is never ON in any variant, so its body is never linted"
            flag_fail=1
        fi
    done
    [ "$flag_fail" -eq 0 ] &&
        ok "flag coverage ($(wc -l <<< "$all_flags" | tr -d ' ') flags, each ON in at least one variant)"
fi

# --- 3. every variant renders clean and lints clean --------------------------
lint_targets=()
for spec in "${VARIANTS[@]}"; do
    IFS='|' read -r variant template flags subs <<< "$spec"
    rel="renders/$variant/.github/workflows/${template%.template.yml}.yml"
    mkdir -p "$WORK/$(dirname "$rel")"
    render "$TEMPLATE_DIR/$template" "$flags" "$subs" > "$WORK/$rel"
    if reason=$(assert_complete "$WORK/$rel"); then
        lint_targets+=("$rel")
    else
        bad "render $variant — $reason"
    fi
done

[ "${#lint_targets[@]}" -eq "${#VARIANTS[@]}" ] &&
    ok "every variant renders complete (${#lint_targets[@]} renders, no leftover tokens or markers)"

if [ "${#lint_targets[@]}" -gt 0 ] && [ "$HAVE_AL" -eq 1 ]; then
    if out=$(lint "${lint_targets[@]}"); then
        ok "actionlint clean across ${#lint_targets[@]} renders"
    else
        echo "$out" | head -40 >&2
        bad "actionlint reported findings in the rendered templates (above)"
    fi
fi

# --- 4. base-lock restore is credential-free after checkout -----------------
# `persist-credentials: false` removes checkout's auth before later commands.
# Execute the ACTUAL rendered step with origin made unreachable: it must restore
# the already-fetched base ref without trying the network. The pre-fix template
# ran `git fetch` here and fails this scenario for every private/internal repo.
RESTORE_YML="$WORK/renders/bun-root/.github/workflows/lockfile-sync-bun.yml"
RESTORE_SCRIPT="$WORK/restore-base-lock.sh"
awk '
    /^      - name: Update bun.lock for the bumped packages only$/ { step=1; next }
    step && /^        run: \|$/ { script=1; next }
    script && !/^          / { exit }
    script { sub(/^          /, ""); print }
' "$RESTORE_YML" > "$RESTORE_SCRIPT"

RESTORE_REPO="$WORK/base-lock-repo"
mkdir -p "$RESTORE_REPO" "$WORK/fake-bin"
cat > "$WORK/fake-bin/bun" <<'BUN'
#!/usr/bin/env bash
exit 0
BUN
chmod +x "$WORK/fake-bin/bun"

(
    cd "$RESTORE_REPO" || exit 1
    git init -q -b main
    git config user.name "Template Test"
    git config user.email "template-test@example.com"
    printf 'base lock\n' > bun.lock
    git add bun.lock
    git commit -qm "base"
    git update-ref refs/remotes/origin/main HEAD
    git switch -qc dependabot/npm_and_yarn/example
    printf 'dependabot lock\n' > bun.lock
    git commit -qam "dependabot"
    git remote add origin https://invalid.invalid/private/repo.git
    PATH="$WORK/fake-bin:$PATH" PR_BASE_REF=main bash -e -o pipefail "$RESTORE_SCRIPT"
) > "$WORK/restore.out" 2> "$WORK/restore.err"
restore_status=$?

if [ "$restore_status" -ne 0 ]; then
    bad "base-lock restore — rendered step tried unreachable origin or otherwise failed: $(tail -n1 "$WORK/restore.err")"
elif [ "$(cat "$RESTORE_REPO/bun.lock")" != "base lock" ]; then
    bad "base-lock restore — rendered step did not restore origin/main's bun.lock"
else
    ok "base-lock restore — rendered step reuses fetched base ref without network credentials"
fi

# --- 5. mutation: an expression defect must fail -----------------------------
# The gate has to be able to go red, or none of the greens above mean anything.
MUT_TPL="$WORK/mutated.template.yml"
AUTO_MERGE="$TEMPLATE_DIR/dependabot-auto-merge.template.yml"

sed 's/github\.actor/githubb.actor/g; s/github\.event\.pull_request\.user\.login/githubb.event.pull_request.user.login/g' \
    "$AUTO_MERGE" > "$MUT_TPL"
if cmp -s "$MUT_TPL" "$AUTO_MERGE"; then
    bad "mutation (expression) — the mutation changed nothing, so it proves nothing (template reworded?)"
elif [ "$HAVE_AL" -eq 1 ]; then
    mkdir -p "$WORK/mut-expr/.github/workflows"
    render "$MUT_TPL" "MERGE_QUEUE" "RUNNER=[self-hosted, linux, sassy-dog]" \
        > "$WORK/mut-expr/.github/workflows/dependabot-auto-merge.yml"
    if lint "mut-expr/.github/workflows/dependabot-auto-merge.yml" >/dev/null 2>&1; then
        bad "mutation (expression) — actionlint PASSED a render with an undefined context variable; the gate cannot fail"
    else
        ok "mutation (expression) — an undefined context variable fails the gate"
    fi
fi

# --- 6. mutation: an unsubstituted token must fail ---------------------------
sed 's/^name: Dependabot auto-merge$/name: Dependabot auto-merge {{UNKNOWN_FACT}}/' \
    "$AUTO_MERGE" > "$MUT_TPL"
if cmp -s "$MUT_TPL" "$AUTO_MERGE"; then
    bad "mutation (token) — the mutation changed nothing, so it proves nothing (template reworded?)"
else
    mkdir -p "$WORK/mut-token/.github/workflows"
    render "$MUT_TPL" "MERGE_QUEUE" "RUNNER=[self-hosted, linux, sassy-dog]" \
        > "$WORK/mut-token/.github/workflows/dependabot-auto-merge.yml"
    if assert_complete "$WORK/mut-token/.github/workflows/dependabot-auto-merge.yml" >/dev/null; then
        bad "mutation (token) — the leftover-token assertion did not see a fact no variant substitutes"
    else
        ok "mutation (token) — a fact no variant substitutes fails the render assertion"
    fi
fi

# --- 7. mutation: the runner-label tolerance is scoped to `sassy-dog` --------
# The acceptance criterion is that ONE label is tolerated, not that the rule is
# off. A config file declaring the label keeps every other unknown label fatal.
if [ "$HAVE_AL" -eq 1 ]; then
    mkdir -p "$WORK/mut-label/.github/workflows"
    render "$TEMPLATE_DIR/dependabot-auto-merge.template.yml" "MERGE_QUEUE" \
        "RUNNER=[self-hosted, linux, not-a-real-label]" > "$WORK/mut-label/.github/workflows/dependabot-auto-merge.yml"
    if lint "mut-label/.github/workflows/dependabot-auto-merge.yml" >/dev/null 2>&1; then
        bad "mutation (runner-label) — an unknown label other than sassy-dog PASSED; the tolerance mutes the whole rule"
    else
        ok "mutation (runner-label) — the tolerance is scoped to the sassy-dog label"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "template-actionlint tests: all passed" >&2
    exit 0
fi
echo "template-actionlint tests: FAILURES above" >&2
exit 1
