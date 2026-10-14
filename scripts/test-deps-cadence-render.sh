#!/usr/bin/env bash
# test-deps-cadence-render.sh — proves setup-deps' render-cadence.sh, the
# renderer for the monthly lockfile-refresh pair (issue #509), against
# synthetic repo trees.
#
# What it pins, in the renderer's own terms:
#
#   1. LANES come from the SAME detection as dependabot.yml (detect-ecosystems.sh
#      → lib-ecosystems.sh), restricted to ecosystems with a refresh command and
#      to directories that TRACK that ecosystem's lockfile. Every such location
#      is in LANES and every lane's lockfile exists; a location without one is
#      reported as not refreshed; the other detected ecosystems are listed as
#      having no refresh command, never silently dropped.
#   2. The impl template's case arms name exactly CADENCE_ECOSYSTEMS, and each
#      arm stages that ecosystem's lockfile. The commands live in the template
#      because they run in the consumer repo; this is what stops them drifting
#      from the lib's table.
#   3. Toolchain SOURCES are derived from the repo and every source exists:
#      bun / node from CI (a version FILE CI reads, else CI's literal), else a
#      root pin file; Flutter from .fvmrc / .fvm/fvm_config.json / an exact
#      pubspec environment.flutter; Rust from rust-toolchain(.toml). A missing,
#      floating or disagreeing pin REFUSES the render (exit 4, no files), and
#      setup-deps' own rendered workflows are not read as the repo's pins.
#   3a. CI pins are read in every YAML form the fleet uses: block, flow
#      mapping (`with: { bun-version: latest }`), quoted, flow sequence and
#      expression; a commented-out pin is not one. A line-start-only reader
#      (mutation) renders what2wear's disagreeing pins instead of refusing.
#   3c. A workspace-root bun lane needs bun >= 1.4.0 (`bun update --recursive`
#      moves no member before it), refused otherwise.
#   3b. No runner fact: --runner is refused and the render runs on
#      ubuntu-latest (template version 2; the job holds the org-wide App token
#      after running package-manager code, so never the self-hosted fleet).
#   4. The two declines (exit 3, no files): a PUBLIC repo (org secrets do not
#      reach it; Sassy-Dog/platform#1054 owns that case) and a merge gate that
#      is not a queue. A repo with nothing to refresh declines too.
#   5. --compare-to fails (exit 5) a re-render that drops a committed lane.
#   6. Renders are complete: no leftover {{TOKEN}} or IF marker, both files
#      carry the generated-by marker, and the schedule-bearing render
#      references only local workflows. When actionlint is on PATH the main
#      render is linted too (test-template-actionlint.sh lints the templates
#      in CI either way).
#
#   7. The opt-in codegen workflow (#519): --codegen-command, --codegen-toolchain
#      and --codegen-globs are explicit inputs a human confirmed. All three
#      render deps-cadence-codegen.yml beside the pair; none renders nothing;
#      any other count REFUSES (exit 4). The command must be one line with no
#      single quote or {{ }}; the toolchain one of bun/node/flutter/rust with
#      the repo's own exact pin (and kept out of the impl); each glob a plain
#      relative path glob with a literal leading directory and a literal
#      extension that matches a tracked file (any tracked file, including under
#      directories lane detection ignores) and no workflow, manifest or
#      lockfile. Seven renderer mutations each flip the case that pins them.
#
# Mutation-proof: the arms check must fail on a template with an arm removed,
# and a template carrying an unknown token must fail the render.
#
# No gh, no network. Uses the --files-from / --root test hook that
# detect-ecosystems.sh and render-cadence.sh share; nothing in SKILL.md passes it.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-deps-cadence-render.sh
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/skills/setup-deps/scripts"
DETECT="$SCRIPTS/detect-ecosystems.sh"
RENDER="$SCRIPTS/render-cadence.sh"
IMPL_TPL="$ROOT/skills/setup-deps/references/templates/deps-cadence-impl.template.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "test-deps-cadence-render: jq not on PATH" >&2; exit 1; }

# tree <name> — build a repo tree from "path<TAB>content" lines on stdin
# (content may carry \n escapes) plus its file list.
tree() {
    local d="$WORK/$1" p c
    rm -rf "$d" "$d.list"; mkdir -p "$d"
    while IFS=$'\t' read -r p c; do
        [ -n "$p" ] || continue
        mkdir -p "$d/$(dirname "$p")"
        printf '%b\n' "$c" > "$d/$p"
    done
    (cd "$d" && find . -type f | sed 's#^\./##' | sort) > "$d.list"
}

# run_render <name> [args…] — detect, then render; sets RC, OUT, ERR, OUTDIR.
run_render() {
    local d="$WORK/$1"; shift
    bash "$DETECT" --files-from "$d.list" --root "$d" > "$d.detect.json" 2>/dev/null
    OUTDIR="$d.out"; rm -rf "$OUTDIR"
    OUT="$(bash "$RENDER" --detect-json "$d.detect.json" --visibility internal --merge-gate merge-queue \
        --out-dir "$OUTDIR" --files-from "$d.list" --root "$d" "$@" 2>"$d.err")"
    RC=$?
    ERR="$(cat "$d.err")"
}

# expect_rc <label> <rc> — and, for any non-zero exit, that no file was written.
expect_rc() {
    if [ "$RC" -ne "$2" ]; then
        bad "$1: exit $RC, expected $2 ($(tail -n1 <<<"$ERR"))"; return 1
    fi
    if [ "$2" -ne 0 ] && [ -e "$OUTDIR" ]; then
        bad "$1: exit $2 but files were written to the out dir"; return 1
    fi
    return 0
}
jqv() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
impl_has() { grep -qF -- "$1" "$OUTDIR/deps-cadence-impl.yml"; }

# arms_of <impl-template> — ecosystems named by the refresh step's case arms.
arms_of() {
    awk '
        index($0, "      - name: Refresh each lane within its declared ranges") == 1 { f = 1; next }
        f && /^      - / { exit }
        f && /^              [a-z][a-z-]*\)$/ { a = $0; gsub(/[ )]/, "", a); print a }
    ' "$1" | sort -u | tr '\n' ' '
}
# arms_check <impl-template> — 0 when the arms equal CADENCE_ECOSYSTEMS and
# each arm stages its lockfile.
arms_check() {
    local tpl="$1" want got eco lock rc=0
    want="$(bash -c '. "$1"; printf "%s\n" $CADENCE_ECOSYSTEMS' _ "$SCRIPTS/lib-ecosystems.sh" | sort -u | tr '\n' ' ')"
    got="$(arms_of "$tpl")"
    if [ -z "$got" ]; then echo "no case arms found in the refresh step"; return 1; fi
    if [ "$got" != "$want" ]; then echo "template arms '$got' != CADENCE_ECOSYSTEMS '$want'"; rc=1; fi
    local sets
    for eco in $got; do
        lock="$(bash -c '. "$1"; cadence_lockfile "$2"' _ "$SCRIPTS/lib-ecosystems.sh" "$eco")" || continue
        sets="$(awk -v arm="              $eco)" '
                index($0, arm) == 1 { f = 1; next }
                f && /^              [a-z*][a-z-]*\)$/ { exit }
                f && /^[[:space:]]*set -- / { print }' "$tpl")"
        if ! grep -qF "$lock" <<<"$sets"; then
            echo "the $eco arm does not stage $lock"; rc=1
        fi
    done
    return "$rc"
}

echo "deps-cadence render:"

# --- 2. arms vs the lib table ---------------------------------------------------
if out="$(arms_check "$IMPL_TPL")"; then
    ok "template case arms = CADENCE_ECOSYSTEMS ($(arms_of "$IMPL_TPL")), each staging its lockfile"
else
    while IFS= read -r l; do bad "$l"; done <<<"$out"
fi
MUT="$WORK/mut-impl.yml"
perl -0pe 's/\n              cargo\)\n.*?;;\n//s' "$IMPL_TPL" > "$MUT"
if cmp -s "$MUT" "$IMPL_TPL"; then
    bad "mutation (arm removed) changed nothing, so it proves nothing"
elif arms_check "$MUT" >/dev/null; then
    bad "mutation (cargo arm removed) PASSED the arms check"
else
    ok "mutation (cargo arm removed) fails the arms check"
fi

# --- 1, 3, 6. a monorepo with every refreshable ecosystem ------------------------
tree mono <<'EOF'
package.json	{"name":"root","workspaces":["packages/*"]}
bun.lock	lock
packages/a/package.json	{"name":"a"}
tools/package.json	{"name":"tools"}
tools/bun.lock	lock
legacy/package.json	{"name":"legacy"}
app/pubspec.yaml	name: app\nenvironment:\n  sdk: ^3.5.0
app/pubspec.lock	lock
app/.fvmrc	{"flutter": "3.44.1"}
Cargo.toml	[workspace]\nmembers = ["crates/x"]
crates/x/Cargo.toml	[package]\nname = "x"
Cargo.lock	lock
rust-toolchain.toml	[toolchain]\nchannel = "1.85.0"\ncomponents = ["clippy"]
android/settings.gradle	include ':app'
android/build.gradle	// build
.bun-version	1.4.0
.github/workflows/ci.yml	jobs:\n  t:\n    steps:\n      - uses: oven-sh/setup-bun@v2\n        with:\n          bun-version-file: .bun-version
.github/workflows/dependabot-bun-lockfile.yml	---\n# generated-by: sassy-dog:setup-deps | template: lockfile-sync-bun | template-version: 10\njobs:\n  x:\n    steps:\n      - with:\n          bun-version: latest
EOF
run_render mono
if expect_rc "monorepo render" 0; then
    [ "$(jqv .lanes_line)" = "bun:/ bun:/tools pub:/app cargo:/" ] \
        && ok "LANES from detection: $(jqv .lanes_line)" \
        || bad "LANES is '$(jqv .lanes_line)', expected 'bun:/ bun:/tools pub:/app cargo:/'"
    [ "$(jqv '[.not_refreshed[].lane] | join(" ")')" = "bun:/legacy" ] \
        && ok "a location without its lockfile is reported as not refreshed (bun:/legacy)" \
        || bad "not_refreshed is '$(jqv '[.not_refreshed[].lane] | join(" ")')', expected bun:/legacy"
    [ "$(jqv '.no_refresh_command | join(",")')" = "github-actions,gradle" ] \
        && ok "ecosystems with no refresh command are listed: $(jqv '.no_refresh_command | join(",")')" \
        || bad "no_refresh_command is '$(jqv '.no_refresh_command | join(",")')'"
    # every refreshable location that tracks its lockfile is a lane; every lane's lockfile exists
    miss=""
    while IFS=$'\t' read -r eco dir; do
        lock="$(bash -c '. "$1"; cadence_lockfile "$2"' _ "$SCRIPTS/lib-ecosystems.sh" "$eco")" || continue
        if [ "$dir" = "/" ]; then p="$lock"; else p="${dir#/}/$lock"; fi
        if [ -f "$WORK/mono/$p" ]; then
            case " $(jqv .lanes_line) " in *" $eco:$dir "*) ;; *) miss+="$eco:$dir(missing) " ;; esac
        fi
    done < <(jq -r '.locations[] | [.ecosystem, .directory] | @tsv' "$WORK/mono.detect.json")
    for l in $(jqv .lanes_line); do
        eco="${l%%:*}"; dir="${l#*:}"
        lock="$(bash -c '. "$1"; cadence_lockfile "$2"' _ "$SCRIPTS/lib-ecosystems.sh" "$eco")"
        if [ "$dir" = "/" ]; then p="$lock"; else p="${dir#/}/$lock"; fi
        [ -f "$WORK/mono/$p" ] || miss+="$l(no $p) "
    done
    [ -z "$miss" ] && ok "every refreshable location with a lockfile is a lane, and every lane's lockfile exists" \
        || bad "lane/lockfile mismatch: $miss"
    tc="$(jqv '.toolchains | to_entries | map("\(.key)=\(.value.kind):\(.value.source)") | join(" ")')"
    [ "$tc" = "bun=file:.bun-version flutter=file:app/.fvmrc rust=file:rust-toolchain.toml" ] \
        && ok "toolchain sources derived: $tc (setup-deps' own workflow ignored)" \
        || bad "toolchain sources are '$tc'"
    srcmiss=""
    for s in $(jqv '.toolchains[] | select(.kind == "file") | .source'); do [ -f "$WORK/mono/$s" ] || srcmiss+="$s "; done
    [ -z "$srcmiss" ] && ok "every toolchain source file exists" || bad "toolchain sources missing: $srcmiss"
    impl_has 'LANES: "bun:/ bun:/tools pub:/app cargo:/"' && impl_has "bun-version-file: '.bun-version'" \
        && impl_has "PIN_FILE: 'app/.fvmrc'" && impl_has "PIN_FILE: 'rust-toolchain.toml'" \
        && ! impl_has "setup-node" && ! impl_has "bun-version: '" \
        && ok "impl renders the derived facts and only the arms they select" \
        || bad "impl render does not carry the derived facts / arms"
    left="$(grep -nE '\{\{[A-Za-z_]+(:[A-Za-z_]+)?\}\}' "$OUTDIR"/*.yml)"
    [ -z "$left" ] && ok "no leftover token or IF marker in either render" || bad "leftovers: $left"
    for f in deps-cadence.yml deps-cadence-impl.yml; do
        grep -qE '^# generated-by: sassy-dog:setup-deps \| template: deps-cadence(-impl)? \| template-version: [0-9]+$' "$OUTDIR/$f" \
            || bad "$f carries no generated-by marker"
    done
    nonlocal="$(grep -E '^[[:space:]]*(- )?uses:' "$OUTDIR/deps-cadence.yml" | grep -vE 'uses:[[:space:]]*\./')"
    { grep -qE '^[[:space:]]*schedule:' "$OUTDIR/deps-cadence.yml" && [ -z "$nonlocal" ]; } \
        && ok "the schedule-bearing render references only local workflows" \
        || bad "schedule-bearing render: ${nonlocal:-no schedule}"
    if command -v actionlint >/dev/null 2>&1; then
        mkdir -p "$WORK/lint/.github/workflows"
        cp "$OUTDIR"/*.yml "$WORK/lint/.github/workflows/"
        printf 'self-hosted-runner:\n  labels:\n    - sassy-dog\n' > "$WORK/lint/al.yaml"
        if lout="$(cd "$WORK/lint" && actionlint -config-file al.yaml -no-color .github/workflows/*.yml 2>&1)"; then
            ok "actionlint clean on the rendered pair"
        else
            bad "actionlint on the rendered pair: $(head -5 <<<"$lout" | tr '\n' ' ')"
        fi
    else
        echo "  skip actionlint on the rendered pair (not on PATH; test-template-actionlint.sh covers the templates)"
    fi
fi

# --- 3. toolchain pins ------------------------------------------------------------
# bun_case <name> <expect-rc> <expect-in-impl-or-err> — a one-lane bun repo plus
# the extra files on stdin.
bun_case() {
    local name="$1" rc="$2" want="$3"
    { printf 'web/package.json\t{"name":"w"}\nweb/bun.lock\tlock\n'; cat; } | tree "$name"
    run_render "$name"
    expect_rc "$name" "$rc" || return
    if [ "$rc" -eq 0 ]; then
        impl_has "$want" && ok "$name → $want" || bad "$name: impl lacks '$want'"
    else
        grep -qF -- "$want" <<<"$ERR" && [ "$(jqv '.refusals | length')" -gt 0 ] \
            && ok "$name refused (exit $rc): $want" || bad "$name: refusal does not mention '$want': $ERR"
    fi
}
CI='.github/workflows/ci.yml'
printf '%s\t      - with:\\n          bun-version: 1.3.5\n' "$CI" | bun_case "bun-ci-literal" 0 "bun-version: '1.3.5'"
printf '%s\t      - with:\\n          bun-version: "1.3.x"\n' "$CI" | bun_case "bun-ci-range" 4 "1.3.x"
printf '%s\t      - with:\\n          bun-version: latest\n' "$CI" | bun_case "bun-ci-latest" 4 "latest"
printf '%s\t      - with:\\n          bun-version: 1.3.5\\n      - with:\\n          bun-version-file: .bun-version\n.bun-version\t1.3.5\n' "$CI" \
    | bun_case "bun-ci-both-forms" 4 "both as bun-version"
printf '%s\t      - with:\\n          bun-version: 1.3.5\\n      - with:\\n          bun-version: 1.3.6\n' "$CI" | bun_case "bun-ci-disagree" 4 "2 different versions"
printf 'package.json\t{"packageManager":"bun@1.2.3+sha512.abc"}\n' | bun_case "bun-packagemanager" 0 "bun-version-file: 'package.json'"
printf 'package.json\t{"name":"r"}\n' | bun_case "bun-no-pin" 4 "bun: no pin"
printf '.bun-version\tlatest\n' | bun_case "bun-file-floating" 4 ".bun-version pins it, but not as an exact version"

# Every YAML form a CI pin takes in the fleet's workflows, not just a key at
# the start of a line. The disagree case is what2wear's real shape: six
# `with: { bun-version: latest }` and one block-style `bun-version: 1.4.0`.
printf '%s\t      - with: { bun-version: 1.4.0 }\n' "$CI" | bun_case "bun-ci-inline" 0 "bun-version: '1.4.0'"
printf '%s\t      - with: {bun-version: "1.4.0", no-cache: true}\n' "$CI" | bun_case "bun-ci-inline-multikey" 0 "bun-version: '1.4.0'"
printf '%s\t      - with: { bun-version: latest }\\n      - with: { bun-version: latest }\\n      - with:\\n          bun-version: 1.4.0\n' "$CI" \
    | bun_case "bun-ci-inline-disagree" 4 "2 different versions"
printf '%s\t      - with: { bun-version: latest }\n' "$CI" | bun_case "bun-ci-inline-latest" 4 "latest"
printf '%s\t      - with: { bun-version-file: .bun-version }\n.bun-version\t1.4.0\n' "$CI" | bun_case "bun-ci-inline-file" 0 "bun-version-file: '.bun-version'"
printf '%s\t      # with: { bun-version: latest }\\n      - with:\\n          bun-version: 1.4.0\n' "$CI" | bun_case "bun-ci-comment-ignored" 0 "bun-version: '1.4.0'"
# shellcheck disable=SC2016  # a literal GitHub expression, not shell
printf '%s\t      - with: { bun-version: ${{ matrix.bun }} }\n' "$CI" | bun_case "bun-ci-expression" 4 'matrix.bun'
printf '%s\t    strategy:\\n      matrix:\\n        bun-version: [1.4.0, latest]\n' "$CI" | bun_case "bun-ci-flow-sequence" 4 "2 different versions"

# A workspace-root bun lane runs `bun update --recursive`, which moves the
# members only from bun 1.4.0 (1.3.5 and 1.3.14 accept the flag and move none).
ws_case() {
    local name="$1" ver="$2" rc="$3" want="$4"
    printf 'package.json\t{"name":"r","workspaces":["apps/*"]}\nbun.lock\tlock\napps/a/package.json\t{"name":"a"}\n.bun-version\t%s\n' "$ver" | tree "$name"
    run_render "$name"
    expect_rc "$name" "$rc" || return
    if [ "$rc" -eq 0 ]; then ok "$name: bun $ver renders a workspace-root lane"
    elif grep -qF -- "$want" <<<"$ERR"; then ok "$name refused (exit $rc): bun $ver on a workspace root"
    else bad "$name: refusal does not mention '$want': $ERR"; fi
}
ws_case "bun-workspace-1.3.14" 1.3.14 4 "moves workspace members only from bun 1.4.0"
ws_case "bun-workspace-1.3.5" 1.3.5 4 "moves workspace members only from bun 1.4.0"
ws_case "bun-workspace-1.4.0" 1.4.0 0 ""

# flutter_case <name> <expect-rc> <want> — a pub lane at /app plus stdin files.
flutter_case() {
    local name="$1" rc="$2" want="$3"
    { printf 'app/pubspec.lock\tlock\n'; cat; } | tree "$name"
    run_render "$name"
    expect_rc "$name" "$rc" || return
    if [ "$rc" -eq 0 ]; then
        impl_has "$want" && ok "$name → $want" || bad "$name: impl lacks '$want'"
    else
        grep -qF -- "$want" <<<"$ERR" && ok "$name refused (exit $rc): $want" || bad "$name: refusal does not mention '$want': $ERR"
    fi
}
PUB='app/pubspec.yaml\tname: app\\nenvironment:\\n  sdk: ^3.5.0'
printf "$PUB"'\napp/.fvm/fvm_config.json\t{"flutterSdkVersion": "3.47.0"}\n' | flutter_case "flutter-fvm-config" 0 "PIN_FILE: 'app/.fvm/fvm_config.json'"
printf "$PUB"'\napp/.fvmrc\t{"flutter": "stable"}\n' | flutter_case "flutter-floating" 4 "does not pin an exact Flutter version"
printf "$PUB"'\napp/.fvmrc\t{"flutter": "3.44.1"}\napp/.fvm/fvm_config.json\t{"flutterSdkVersion": "3.47.0"}\n' \
    | flutter_case "flutter-disagree" 4 "pins disagree"
printf 'app/pubspec.yaml\tname: app\\nenvironment:\\n  sdk: ^3.5.0\\n  flutter: "3.44.1"\n' | flutter_case "flutter-pubspec" 0 "PIN_FILE: 'app/pubspec.yaml'"
printf 'app/pubspec.yaml\tname: app\\nenvironment:\\n  sdk: ^3.5.0\\n  flutter: ">=3.0.0"\n' | flutter_case "flutter-constraint-only" 4 "flutter: no pin"

# rust_case <name> <expect-rc> <want>
rust_case() {
    local name="$1" rc="$2" want="$3"
    { printf 'Cargo.toml\t[package]\\nname = "r"\nCargo.lock\tlock\n'; cat; } | tree "$name"
    run_render "$name"
    expect_rc "$name" "$rc" || return
    if [ "$rc" -eq 0 ]; then
        impl_has "$want" && ok "$name → $want" || bad "$name: impl lacks '$want'"
    else
        grep -qF -- "$want" <<<"$ERR" && ok "$name refused (exit $rc): $want" || bad "$name: refusal does not mention '$want': $ERR"
    fi
}
printf 'rust-toolchain.toml\t[toolchain]\\nchannel = "stable"\n' | rust_case "rust-floating" 4 "does not pin an exact Rust toolchain"
printf 'README.md\tno toolchain\n' | rust_case "rust-missing" 4 "rust: no pin"
printf 'rust-toolchain\t1.80.0\n' | rust_case "rust-legacy-file" 0 "PIN_FILE: 'rust-toolchain'"

# node (npm lanes)
npm_case() {
    local name="$1" rc="$2" want="$3"
    { printf 'package.json\t{"name":"n"}\npackage-lock.json\t{}\n'; cat; } | tree "$name"
    run_render "$name"
    expect_rc "$name" "$rc" || return
    if [ "$rc" -eq 0 ]; then
        impl_has "$want" && ok "$name → $want" || bad "$name: impl lacks '$want'"
    else
        grep -qF -- "$want" <<<"$ERR" && ok "$name refused (exit $rc): $want" || bad "$name: refusal does not mention '$want': $ERR"
    fi
}
printf '.nvmrc\t24\n' | npm_case "node-major-only" 4 ".nvmrc pins it, but not as an exact version"
printf '.nvmrc\tv24.1.0\n' | npm_case "node-nvmrc" 0 "node-version-file: '.nvmrc'"
printf '%s\t      - with:\\n          node-version: 22.11.0\n' "$CI" | npm_case "node-ci-literal" 0 "node-version: '22.11.0'"
printf '%s\t      - with: { node-version: 22.11.0 }\n' "$CI" | npm_case "node-ci-inline" 0 "node-version: '22.11.0'"
printf '%s\t      - with: { node-version-file: .nvmrc }\n.nvmrc\t24.1.0\n' "$CI" | npm_case "node-ci-inline-file" 0 "node-version-file: '.nvmrc'"
printf '%s\t      - with: { node-version: "24" }\\n      - with:\\n          node-version: 22.11.0\n' "$CI" | npm_case "node-ci-inline-disagree" 4 "2 different versions"

# --- 4. declines -------------------------------------------------------------------
run_render mono --visibility public
if expect_rc "public repo" 3; then
    grep -qF 'Sassy-Dog/platform#1054' <<<"$ERR" && ok "a public repo is declined (exit 3) and pointed at Sassy-Dog/platform#1054" \
        || bad "public decline does not point at Sassy-Dog/platform#1054: $ERR"
fi
run_render mono --visibility PUBLIC
expect_rc "public repo (upper case, as gh prints it)" 3 && ok "visibility is matched case-insensitively (gh prints PUBLIC)"
run_render mono --merge-gate direct
expect_rc "direct-merge repo" 3 && ok "a repo without a merge queue is declined (exit 3)"
printf 'android/settings.gradle\tinclude\nandroid/build.gradle\t// b\n' | tree gradle-only
run_render gradle-only
expect_rc "nothing to refresh" 3 && ok "a repo with nothing to refresh is declined (exit 3)"

run_render mono --runner '[self-hosted, linux, sassy-dog]'
if expect_rc "--runner" 1; then
    grep -qF 'GitHub-hosted' <<<"$ERR" && ok "--runner is refused (exit 1): the cadence renders only for an ephemeral GitHub-hosted runner" \
        || bad "--runner refusal does not say why: $ERR"
fi
run_render mono
grep -qE '^[[:space:]]*runs-on: ubuntu-latest$' "$OUTDIR/deps-cadence-impl.yml" && [ "$(jqv .runner)" = "ubuntu-latest" ] \
    && ok "the render runs on ubuntu-latest, never the fleet" || bad "the render's runs-on is not ubuntu-latest"

# --- 5. --compare-to ----------------------------------------------------------------
printf -- '---\njobs:\n  refresh:\n    env:\n      LANES: "bun:/ bun:/tools pub:/app cargo:/ bun:/gone"\n' > "$WORK/committed-extra.yml"
printf -- '---\njobs:\n  refresh:\n    env:\n      LANES: "bun:/ pub:/app"\n' > "$WORK/committed-subset.yml"
run_render mono --compare-to "$WORK/committed-extra.yml"
if expect_rc "compare-to, committed lane dropped" 5; then
    grep -q 'DIVERGED committed lane bun:/gone' <<<"$ERR" && ok "a re-render that drops a committed lane is DIVERGED (exit 5)" \
        || bad "DIVERGED not reported: $ERR"
fi
run_render mono --compare-to "$WORK/committed-subset.yml"
expect_rc "compare-to, lanes added" 0 && ok "a re-render that only adds lanes passes --compare-to"

# --- mutation: a line-start-only pin reader must miss what2wear's shape ------------
MUTPLUG="$WORK/mutplug/skills/setup-deps"
mkdir -p "$MUTPLUG"; cp -R "$ROOT/skills/setup-deps/scripts" "$ROOT/skills/setup-deps/references" "$MUTPLUG/"
FROM='(?:^|[\s{,])' TO='^\s*' perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$MUTPLUG/scripts/render-cadence.sh"
if cmp -s "$MUTPLUG/scripts/render-cadence.sh" "$RENDER"; then
    bad "mutation (inline pin ignored) changed nothing, so it proves nothing"
else
    REAL_RENDER="$RENDER"; RENDER="$MUTPLUG/scripts/render-cadence.sh"
    run_render bun-ci-inline-disagree
    RENDER="$REAL_RENDER"
    if [ "$RC" -eq 4 ]; then
        bad "mutation (inline pin ignored) still refused the what2wear shape; the case cannot tell the readers apart"
    else
        ok "mutation (inline pin ignored) renders the what2wear shape (exit $RC), which the real reader refuses"
    fi
fi
# --- 6. mutation: an unknown token must fail the render -----------------------------
sed 's/^name: Dependency cadence (impl)$/name: Dependency cadence (impl) {{UNKNOWN_FACT}}/' "$IMPL_TPL" > "$WORK/mut-token.yml"
if cmp -s "$WORK/mut-token.yml" "$IMPL_TPL"; then
    bad "mutation (unknown token) changed nothing, so it proves nothing"
else
    run_render mono --impl-template "$WORK/mut-token.yml"
    if [ "$RC" -eq 1 ] && grep -q 'left a token' <<<"$ERR" && [ ! -e "$OUTDIR" ]; then
        ok "mutation (unknown token) fails the render with nothing written"
    else
        bad "mutation (unknown token) was not refused: exit $RC"
    fi
fi

# --- 7. the optional codegen workflow (#519) ----------------------------------------
# deps-cadence-codegen.yml is opt-in. Its command, toolchain and generated-path
# globs are EXPLICIT inputs a human confirmed; the renderer refuses unless all
# three are supplied and renders nothing when none are. It never parses workflow
# YAML to derive them.
GEN="apps/mobile/lib/graphql/__generated__"
tree cg <<EOF
apps/mobile/pubspec.yaml	name: app\nenvironment:\n  sdk: ^3.5.0
apps/mobile/pubspec.lock	lock
apps/mobile/.fvmrc	{"flutter": "3.44.1"}
$GEN/weather.req.gql.dart	// generated
$GEN/weather.req.gql.g.dart	// generated
apps/mobile/test/providers/chat_test.mocks.dart	// mocks
apps/mobile/test/fixtures/odd_test.mocks.dart	// a mock under a directory the lane detection ignores
.bun-version	1.4.0
.github/workflows/ci.yml	name: ci
EOF
CG_CMD='(cd apps/mobile && flutter pub get && dart run build_runner build --delete-conflicting-outputs)'
CG_GLOBS="$GEN/*.gql.dart $GEN/*.gql.g.dart apps/mobile/test/**/*_test.mocks.dart"
cg_args=(--codegen-command "$CG_CMD" --codegen-toolchain flutter --codegen-globs "$CG_GLOBS")
cg_has() { grep -qF -- "$1" "$OUTDIR/deps-cadence-codegen.yml"; }

# cg_refused <label> <fragment> <args…> — exit 4, the reason named, no file.
cg_refused() {
    local label="$1" frag="$2"; shift 2
    run_render cg "$@"
    expect_rc "codegen: $label" 4 || return
    if grep -qF -- "$frag" <<<"$ERR" && [ "$(jqv '.refusals | length')" -gt 0 ] && [ "$(jqv '.codegen')" = "null" ]; then
        ok "codegen refused (exit 4): $label"
    else
        bad "codegen: $label — refusal does not say '$frag': $ERR"
    fi
}

run_render cg
if expect_rc "codegen absent" 0; then
    { [ ! -e "$OUTDIR/deps-cadence-codegen.yml" ] && [ "$(jqv .codegen)" = "null" ] && [ "$(jqv '.files | length')" = "2" ]; } \
        && ok "no codegen input: no codegen workflow, and the summary lists the pair only" \
        || bad "no codegen input still produced a codegen file or summary entry"
fi

run_render cg "${cg_args[@]}"
if expect_rc "codegen render" 0; then
    [ -s "$OUTDIR/deps-cadence-codegen.yml" ] && [ "$(jqv '.files | length')" = "3" ] \
        && ok "all three inputs render deps-cadence-codegen.yml beside the pair" \
        || bad "codegen file missing or not in the summary"
    grep -qE '^# generated-by: sassy-dog:setup-deps \| template: deps-cadence-codegen \| template-version: [0-9]+$' "$OUTDIR/deps-cadence-codegen.yml" \
        && ok "the codegen render carries its generated-by marker" || bad "codegen render has no generated-by marker"
    cg_has "CODEGEN_COMMAND: '$CG_CMD'" && cg_has "CODEGEN_GLOBS: '$CG_GLOBS'" \
        && ok "the confirmed command and globs are rendered verbatim" || bad "command or globs not rendered verbatim"
    cg_has "PIN_FILE: 'apps/mobile/.fvmrc'" && ! cg_has "setup-bun" && ! cg_has "setup-node" \
        && ok "only the named toolchain is set up, from the repo's own pin" || bad "codegen toolchain steps wrong"
    left="$(grep -nE '\{\{[A-Za-z_]+(:[A-Za-z_]+)?\}\}' "$OUTDIR/deps-cadence-codegen.yml")"
    [ -z "$left" ] && ok "no leftover token or IF marker in the codegen render" || bad "codegen leftovers: $left"
    # The impl is the same file it was without codegen: the codegen toolchain
    # does not leak into it.
    run_render cg; plain_impl="$(cat "$OUTDIR/deps-cadence-impl.yml")"
    run_render cg "${cg_args[@]}"
    [ "$(cat "$OUTDIR/deps-cadence-impl.yml")" = "$plain_impl" ] \
        && ok "supplying codegen leaves deps-cadence-impl.yml byte-identical" || bad "codegen inputs changed the impl render"
    if command -v actionlint >/dev/null 2>&1; then
        rm -rf "$WORK/lint2"; mkdir -p "$WORK/lint2/.github/workflows"
        cp "$OUTDIR"/*.yml "$WORK/lint2/.github/workflows/"
        printf 'self-hosted-runner:\n  labels:\n    - sassy-dog\n' > "$WORK/lint2/al.yaml"
        if lout="$(cd "$WORK/lint2" && actionlint -config-file al.yaml -no-color .github/workflows/*.yml 2>&1)"; then
            ok "actionlint clean on the rendered trio"
        else
            bad "actionlint on the rendered trio: $(head -5 <<<"$lout" | tr '\n' ' ')"
        fi
    fi
fi

# A toolchain no lane uses is still pinned from the repo, and stays out of the impl.
run_render cg --codegen-command 'bunx graphql-codegen' --codegen-toolchain bun --codegen-globs "$GEN/*.gql.dart"
if expect_rc "codegen bun" 0; then
    cg_has "bun-version-file: '.bun-version'" && ! impl_has "setup-bun" \
        && ok "a codegen-only toolchain is set up in the codegen workflow and never in the impl" \
        || bad "codegen-only bun leaked into the impl or is missing from the codegen workflow"
fi
run_render cg --codegen-command 'node gen.js' --codegen-toolchain node --codegen-globs "$GEN/*.gql.dart"
expect_rc "codegen node, no pin" 4 && grep -qF 'node: no pin' <<<"$ERR" \
    && ok "an unpinned codegen toolchain refuses like a lane's would (node: no pin)" || bad "unpinned codegen toolchain not refused: $ERR"

# Explicit means all three, or none.
cg_refused "command only" "--codegen-toolchain --codegen-globs" --codegen-command "$CG_CMD"
cg_refused "globs only" "--codegen-command --codegen-toolchain" --codegen-globs "$CG_GLOBS"
cg_refused "toolchain and globs, no command" "missing or empty: --codegen-command" --codegen-toolchain flutter --codegen-globs "$CG_GLOBS"
cg_refused "an empty command" "missing or empty: --codegen-command" --codegen-command '' --codegen-toolchain flutter --codegen-globs "$CG_GLOBS"
cg_refused "an unknown toolchain" "is not one of bun, node, flutter, rust" --codegen-command x --codegen-toolchain python --codegen-globs "$CG_GLOBS"
# The command lands in a single-quoted YAML scalar run by bash -c.
cg_refused "a single quote in the command" "single quote" --codegen-command "echo 'hi'" --codegen-toolchain flutter --codegen-globs "$CG_GLOBS"
cg_refused "a newline in the command" "one line" --codegen-command $'make gen\nrm -rf x' --codegen-toolchain flutter --codegen-globs "$CG_GLOBS"
# shellcheck disable=SC2016  # a literal GitHub expression, not shell
cg_refused "an expression in the command" "'{{' or '}}'" --codegen-command 'echo ${{ secrets.X }}' --codegen-toolchain flutter --codegen-globs "$CG_GLOBS"
# The globs are the push job's allowlist: nothing broad, nothing that is a
# workflow, manifest or lockfile, nothing that names no file.
cg_refused "a glob that is a lockfile" "a workflow, manifest or lockfile" --codegen-command x --codegen-toolchain flutter --codegen-globs "apps/mobile/*.lock"
cg_refused "a glob that reaches a manifest" "pubspec.yaml, a workflow" --codegen-command x --codegen-toolchain flutter --codegen-globs "apps/**/*.yaml"
cg_refused "a glob that reaches a workflow" "must begin with a literal directory" --codegen-command x --codegen-toolchain flutter --codegen-globs ".github/workflows/*.yml"
cg_refused "a glob that starts with a wildcard" "must begin with a literal directory" --codegen-command x --codegen-toolchain flutter --codegen-globs "**/*.dart"
cg_refused "a glob with no directory" "must begin with a literal directory" --codegen-command x --codegen-toolchain flutter --codegen-globs "weather.gql.dart"
cg_refused "a glob that names a directory, not files" "must end in a literal file extension" --codegen-command x --codegen-toolchain flutter --codegen-globs "$GEN/*"
cg_refused "a glob that ends in a wildcard extension" "must end in a literal file extension" --codegen-command x --codegen-toolchain flutter --codegen-globs "$GEN/weather.*"
cg_refused "a glob that matches no tracked file" "matches no tracked file" --codegen-command x --codegen-toolchain flutter --codegen-globs "$GEN/*.nothing.dart"
cg_refused "a glob that walks out of the repo" "not a plain relative path glob" --codegen-command x --codegen-toolchain flutter --codegen-globs "apps/../etc/*.dart"
cg_refused "a glob with shell metacharacters" "not a plain relative path glob" --codegen-command x --codegen-toolchain flutter --codegen-globs 'apps/$(id)/*.dart'
# The globs are matched against EVERY tracked file, not only the ones the lane
# detection reads: a mock under test/fixtures/ is generated code too.
run_render cg --codegen-command x --codegen-toolchain flutter --codegen-globs "apps/mobile/test/fixtures/*_test.mocks.dart"
expect_rc "codegen glob into an excluded directory" 0 && ok "a glob matches tracked files under directories the lane detection ignores (fixtures/)" \
    || bad "a glob into test/fixtures was refused"
# Declines still come first.
run_render cg --visibility public "${cg_args[@]}"
expect_rc "codegen on a public repo" 3 && ok "a public repo is declined (exit 3) whatever codegen inputs are given"
run_render cg --merge-gate direct "${cg_args[@]}"
expect_rc "codegen without a merge queue" 3 && ok "a repo without a merge queue is declined (exit 3) whatever codegen inputs are given"

# Mutations of the renderer itself. Each must flip the case that pins it.
mutate_render() { # <name> <from> <to> <case-fn> <expect-rc-without-the-rule: not this>
    local name="$1" from="$2" to="$3" fn="$4" want_not="$5" real="$RENDER"
    local mp="$WORK/mutcg-$RANDOM/skills/setup-deps"
    mkdir -p "$mp"; cp -R "$ROOT/skills/setup-deps/scripts" "$ROOT/skills/setup-deps/references" "$mp/"
    FROM="$from" TO="$to" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$mp/scripts/render-cadence.sh"
    if cmp -s "$mp/scripts/render-cadence.sh" "$real"; then
        bad "mutation ($name) changed nothing, so it proves nothing"; return
    fi
    RENDER="$mp/scripts/render-cadence.sh"
    "$fn"
    RENDER="$real"
    if [ "$RC" -eq "$want_not" ]; then
        bad "mutation ($name) still behaves as before (exit $RC); no case pins that rule"
    else
        ok "mutation ($name) changes the outcome (exit $RC, was $want_not)"
    fi
}
case_command_only() { run_render cg --codegen-command "$CG_CMD"; grep -qF 'all three of --codegen-command' <<<"$ERR" || RC=99; }
case_lockfile_glob() { run_render cg --codegen-command x --codegen-toolchain flutter --codegen-globs "apps/mobile/*.lock"; }
case_no_match() { run_render cg --codegen-command x --codegen-toolchain flutter --codegen-globs "$GEN/*.nothing.dart"; }
case_quote() { run_render cg --codegen-command "echo 'hi'" --codegen-toolchain flutter --codegen-globs "$CG_GLOBS"; }
case_wild_first() { run_render cg --codegen-command x --codegen-toolchain flutter --codegen-globs "**/*.dart"; }
case_dir_only() { run_render cg --codegen-command x --codegen-toolchain flutter --codegen-globs "$GEN/*"; }
case_bun_codegen() { run_render cg --codegen-command 'bunx graphql-codegen' --codegen-toolchain bun --codegen-globs "$GEN/*.gql.dart"; if grep -qF "setup-bun" "$OUTDIR/deps-cadence-impl.yml"; then RC=99; fi; }
mutate_render "all-three check dropped" 'if [ -n "$cg_missing" ]; then' 'if false; then' case_command_only 4
mutate_render "lockfile/manifest check dropped" 'if [[ "$f" =~ $cg_denied ]]; then bad_hit' 'if false; then bad_hit' case_lockfile_glob 4
mutate_render "no-match check dropped" 'elif [ "$hits" -eq 0 ]; then' 'elif false; then' case_no_match 4
mutate_render "single-quote check dropped" 'elif [[ "$CODEGEN_COMMAND" == *"'"'"'"* ]]; then' 'elif false; then' case_quote 4
mutate_render "literal-directory check dropped" 'if [ "$first" = "$g" ] || [[ "$first" == *[*?]* ]] || [[ "$first" == .git* ]]; then' 'if false; then' case_wild_first 4
mutate_render "literal-extension check dropped" 'if ! [[ "${g##*/}" =~ \.[A-Za-z0-9]{1,8}$ ]]; then' 'if false; then' case_dir_only 4
mutate_render "codegen toolchain flags leak into the impl" 'render "$IMPL_TPL" "${IMPL_FLAGS#,}"' 'render "$IMPL_TPL" "${IMPL_FLAGS#,}${TF_bun}"' case_bun_codegen 0

exit "$fail"
