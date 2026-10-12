#!/usr/bin/env bash
# render-cadence.sh — render the monthly lockfile-refresh pair,
# .github/workflows/deps-cadence.yml (thin trigger) and deps-cadence-impl.yml,
# from a detect-ecosystems.sh report (issue #509).
#
# Why a script: the impl carries facts that are easy to get wrong by hand and
# fail late. Each one is derived here, and anything that cannot be derived
# REFUSES the render instead of being guessed:
#
#   LANES      <ecosystem>:<directory> for every detected location of an
#              ecosystem with a refresh command (CADENCE_ECOSYSTEMS in
#              lib-ecosystems.sh) whose directory TRACKS that ecosystem's
#              lockfile. Same locations as dependabot.yml, from the same lib,
#              so there is no second ecosystem table. A location without its
#              lockfile is reported as not refreshed, never refreshed into a
#              brand-new lockfile.
#   toolchain  for each lane's toolchain, the repo's OWN exact pin:
#                bun / node  the pin CI uses: a `bun-version-file:` /
#                            `node-version-file:` (rendered as that file, read
#                            at run time), else a `bun-version:` /
#                            `node-version:` literal (rendered as-is), else
#                            .bun-version / package.json packageManager, or
#                            .nvmrc / .node-version.
#                flutter     .fvmrc, .fvm/fvm_config.json, or a pubspec.yaml
#                            whose environment.flutter is exact.
#                rust        rust-toolchain.toml / rust-toolchain.
#              Missing, floating ("1.3.x", "latest", "stable", "24") or
#              disagreeing pins refuse with exit 4. A different toolchain can
#              write a lockfile CI then rejects, so this fails at render time
#              rather than at 09:00 on the 1st.
#
# The Flutter and Rust pin files are validated by running the impl template's
# OWN reader steps against them, so render time and run time cannot read a
# pin differently.
#
# Two preconditions DECLINE the render (exit 3), mirroring auto-merge:
#   --visibility public   org App secrets are private-visibility and resolve
#                         to empty strings in a public repo (#178). Public-repo
#                         automation belongs in Sassy-Dog/platform#1054.
#   --merge-gate <not merge-queue>
#                         the impl enqueues with plain `gh pr merge --auto`.
#                         Without a queue that either fails (no method flag) or,
#                         with no required check, merges at once, unreviewed.
#
# There is no runner fact. The job runs package-manager code and then holds the
# org-wide App token, so the template hard-codes an ephemeral GitHub-hosted
# runner, and --runner is refused rather than ignored (a self-hosted runner can
# carry a poisoned git, gh, toolchain or global git config from an earlier job).
#
# --compare-to <committed deps-cadence-impl.yml> fails (exit 5, DIVERGED) when
# the committed LANES names a lane the fresh render drops: an owned file whose
# lanes a re-render loses is the state that once hid four lanes behind a
# current-looking dependabot.yml marker (#169).
#
# Usage:
#   render-cadence.sh --detect-json FILE --visibility VIS --merge-gate GATE
#                     --out-dir DIR [--compare-to FILE]
#   render-cadence.sh ... --files-from LIST --root DIR   (test hook only, as in
#                     detect-ecosystems.sh; nothing in SKILL.md uses it)
# Writes DIR/deps-cadence.yml and DIR/deps-cadence-impl.yml only when every
# check passes, and prints a JSON summary (lanes, toolchain sources, skips) on
# stdout. Reasons go to stderr.
# Exit: 0 rendered · 1 bad input, malformed template or tool failure
#       · 3 declined (public, no merge queue, nothing to refresh)
#       · 4 refused (a toolchain pin is missing, floating or disagrees)
#       · 5 diverged from --compare-to
set -uo pipefail
export LC_ALL=C

command -v jq >/dev/null 2>&1 || { echo "render-cadence: jq not on PATH" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-ecosystems.sh
. "$SCRIPT_DIR/lib-ecosystems.sh"
TEMPLATE_DIR="$SCRIPT_DIR/../references/templates"
TRIGGER_TPL="$TEMPLATE_DIR/deps-cadence.template.yml"
IMPL_TPL="$TEMPLATE_DIR/deps-cadence-impl.template.yml"

DETECT=""
VISIBILITY=""
MERGE_GATE=""
OUT_DIR=""
COMPARE_TO=""
FILES_FROM=""
ROOT_ARG=""

die() { echo "render-cadence: $1" >&2; exit "${2:-1}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --detect-json)   DETECT="${2:-}"; shift 2 || exit 1 ;;
        --visibility)    VISIBILITY="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 || exit 1 ;;
        --merge-gate)    MERGE_GATE="${2:-}"; shift 2 || exit 1 ;;
        --out-dir)       OUT_DIR="${2:-}"; shift 2 || exit 1 ;;
        --runner)        die "--runner is not accepted: deps-cadence runs package-manager code and then holds the org-wide App token, so it renders only for an ephemeral GitHub-hosted runner (ubuntu-latest). A persistent self-hosted runner can carry a poisoned git, gh, toolchain or global git config from an earlier job." ;;
        --compare-to)    COMPARE_TO="${2:-}"; shift 2 || exit 1 ;;
        --files-from)    FILES_FROM="${2:-}"; shift 2 || exit 1 ;;
        --root)          ROOT_ARG="${2:-}"; shift 2 || exit 1 ;;
        --impl-template) IMPL_TPL="${2:-}"; shift 2 || exit 1 ;;   # test hook (mutations)
        *) die "unknown argument '$1'" ;;
    esac
done

[ -n "$DETECT" ]  || die "--detect-json is required"
[ -n "$OUT_DIR" ] || die "--out-dir is required"
case "$VISIBILITY" in
    public|private|internal) ;;
    "") die "--visibility is required (gh repo view --json visibility --jq .visibility)" ;;
    *)  die "--visibility '$VISIBILITY' is not public, private or internal" ;;
esac
case "$MERGE_GATE" in
    merge-queue|direct|none|unavailable) ;;
    "") die "--merge-gate is required (merge-queue | direct | none | unavailable, from SKILL.md §2)" ;;
    *)  die "--merge-gate '$MERGE_GATE' is not merge-queue, direct, none or unavailable" ;;
esac
for t in "$TRIGGER_TPL" "$IMPL_TPL"; do
    [ -r "$t" ] || die "template not readable: $t"
done

# --- the two declines come first: nothing below matters for these repos ------
if [ "$VISIBILITY" = "public" ]; then
    die "DECLINED: repo is public. deps-cadence mints PLATFORM_WRITER_APP_* from org secrets at private visibility, which resolve to empty strings here (Sassy-Dog/skills#178). Public-repo dependency automation runs from Sassy-Dog/platform instead (Sassy-Dog/platform#1054)." 3
fi
if [ "$MERGE_GATE" != "merge-queue" ]; then
    die "DECLINED: merge gate is '$MERGE_GATE', not a merge queue. The refresh PR is enqueued with plain \`gh pr merge --auto\`, which needs a queue: without one it fails for want of a method flag, and with no required check it would merge unreviewed." 3
fi

if [ "$DETECT" = "-" ]; then
    DETECT_JSON="$(cat)"
else
    [ -r "$DETECT" ] || die "cannot read --detect-json '$DETECT'"
    DETECT_JSON="$(cat "$DETECT")"
fi
jq -e '.locations and .present' >/dev/null 2>&1 <<<"$DETECT_JSON" \
    || die "--detect-json is not a detect-ecosystems.sh report (no .locations / .present)"

if [ -n "$FILES_FROM" ]; then
    [ -r "$FILES_FROM" ] || die "cannot read --files-from '$FILES_FROM'"
    [ -n "$ROOT_ARG" ] || die "--files-from requires --root"
    ROOT="$ROOT_ARG"
else
    ROOT="${ROOT_ARG:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    [ -n "$ROOT" ] || die "not in a git repo (pass --root)"
fi
cd "$ROOT" || die "cannot cd to $ROOT"
# shellcheck disable=SC2034  # read by lib-ecosystems.sh
CORPUS_ROOT="$ROOT"
load_corpus "$FILES_FROM" || die "could not load the file corpus"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A path rendered into YAML and into a shell loop: no whitespace, no quotes.
SAFE_PATH_RE='^[A-Za-z0-9._/@+-]+$'
EXACT_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

tracked() { grep -qxF -- "$1" <<<"$FILES"; }

# --- lanes ----------------------------------------------------------------------
LANES=""
NOT_REFRESHED=""
TOOLCHAINS=""
lanes_json='[]'
skipped_json='[]'
while IFS=$'\t' read -r eco dir; do
    [ -n "$eco" ] || continue
    lock="$(cadence_lockfile "$eco")" || continue
    [[ "$dir" =~ $SAFE_PATH_RE ]] || die "lane $eco:$dir has a directory this renderer will not put in a shell loop (whitespace or quotes)"
    if [ "$dir" = "/" ]; then lockpath="$lock"; else lockpath="${dir#/}/$lock"; fi
    if tracked "$lockpath"; then
        LANES+="${LANES:+ }$eco:$dir"
        lanes_json="$(jq -c --arg l "$eco:$dir" '. + [$l]' <<<"$lanes_json")"
        tc="$(cadence_toolchain "$eco")"
        grep -qxF "$tc" <<<"$TOOLCHAINS" || TOOLCHAINS+="$tc"$'\n'
    else
        NOT_REFRESHED+="${NOT_REFRESHED:+; }$eco:$dir (no tracked $lock)"
        skipped_json="$(jq -c --arg l "$eco:$dir" --arg r "no tracked $lock" '. + [{lane: $l, reason: $r}]' <<<"$skipped_json")"
    fi
done < <(jq -r '.locations[] | [.ecosystem, .directory] | @tsv' <<<"$DETECT_JSON")

NO_REFRESH=""
while IFS= read -r eco; do
    [ -n "$eco" ] || continue
    case " $CADENCE_ECOSYSTEMS " in *" $eco "*) continue ;; esac
    NO_REFRESH+="${NO_REFRESH:+, }$eco"
done < <(jq -r '.present[]' <<<"$DETECT_JSON")

if [ -z "$LANES" ]; then
    die "DECLINED: nothing to refresh. No detected bun, npm, pub or cargo location tracks its lockfile${NOT_REFRESHED:+ ($NOT_REFRESHED)}." 3
fi

# --- toolchain pins -----------------------------------------------------------------
REFUSALS=""
refuse() { REFUSALS+="$1"$'\n'; }

# CI workflows to read pins from: tracked, not this cadence, not owned by
# setup-deps (those are this generator's own output, not the repo's choice).
CI_FILES=""
while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    case "${wf##*/}" in deps-cadence.yml|deps-cadence.yaml|deps-cadence-impl.yml|deps-cadence-impl.yaml) continue ;; esac
    [ -r "$ROOT/$wf" ] || continue
    if grep -qE 'generated-by: [^ ]+ \| template: ' "$ROOT/$wf"; then
        continue
    fi
    CI_FILES+="$wf"$'\n'
done < <(grep -E '^\.github/workflows/[^/]+\.ya?ml$' <<<"$ALL_FILES")

# ci_values <key> — "value<TAB>workflow" for every `<key>:` in a CI workflow,
# with the comment, quotes and surrounding space removed.
ci_values() {
    local key="$1" wf
    while IFS= read -r wf; do
        [ -n "$wf" ] || continue
        grep -E "^[[:space:]]*-?[[:space:]]*${key}:" "$ROOT/$wf" \
            | sed -E "s/^[[:space:]]*-?[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]+$//" \
            | while IFS= read -r v; do printf '%s\t%s\n' "$v" "$wf"; done
    done <<<"$CI_FILES"
}

# version_in_file <tool> <path> — the exact version a pin file names. Returns
# 1 when the file names a version that is not exact (a floating pin), 3 when it
# names none at all (a package.json with no packageManager is not a pin file).
# package.json carries bun as packageManager "bun@X.Y.Z[+hash]" and node as
# engines.node.
version_in_file() {
    local tool="$1" path="$2" v=""
    [ -r "$ROOT/$path" ] || return 3
    case "${path##*/}" in
        package.json)
            if [ "$tool" = "bun" ]; then
                v="$(jq -r '.packageManager // empty' "$ROOT/$path" 2>/dev/null)"
                case "$v" in bun@*) v="${v#bun@}"; v="${v%%+*}" ;; *) v="" ;; esac
            else
                v="$(jq -r '.engines.node // empty' "$ROOT/$path" 2>/dev/null)"
            fi ;;
        .tool-versions)
            if [ "$tool" = "bun" ]; then
                v="$(awk '$1 == "bun" {print $2; exit}' "$ROOT/$path")"
            else
                v="$(awk '$1 == "nodejs" || $1 == "node" {print $2; exit}' "$ROOT/$path")"
            fi ;;
        *)
            v="$(grep -m1 -vE '^[[:space:]]*(#|$)' "$ROOT/$path" | tr -d '[:space:]')" ;;
    esac
    [ -n "$v" ] || return 3
    v="${v#v}"
    [[ "$v" =~ $EXACT_RE ]] || return 1
    printf '%s' "$v"
}

# derive_setup_pin <tool> <ci-key> <ci-file-key> <fallback-file>... — sets
# PIN_KIND (file|literal), PIN_VALUE (the path, or the literal version),
# PIN_VERSION and PIN_FROM, or records a refusal and returns 1.
derive_setup_pin() {
    local tool="$1" key="$2" filekey="$3"; shift 3
    local lits files n f v rc
    PIN_KIND=""; PIN_VALUE=""; PIN_VERSION=""; PIN_FROM=""
    lits="$(ci_values "$key")"
    files="$(ci_values "$filekey")"
    if [ -n "$lits" ] && [ -n "$files" ]; then
        refuse "$tool: CI sets it both as $key ($(cut -f2 <<<"$lits" | sort -u | tr '\n' ' ')) and as $filekey ($(cut -f2 <<<"$files" | sort -u | tr '\n' ' ')). Make CI use one pin, then re-render."
        return 1
    fi
    if [ -n "$files" ]; then
        n="$(cut -f1 <<<"$files" | sort -u | grep -c .)"
        if [ "$n" -ne 1 ]; then
            refuse "$tool: CI names $n different $filekey values ($(cut -f1 <<<"$files" | sort -u | tr '\n' ' ')). Make them agree, then re-render."
            return 1
        fi
        f="$(head -1 <<<"$files" | cut -f1)"; f="${f#./}"
        if ! [[ "$f" =~ $SAFE_PATH_RE ]] || ! grep -qxF -- "$f" <<<"$ALL_FILES"; then
            refuse "$tool: CI's $filekey '$f' is not a tracked file."
            return 1
        fi
        if ! v="$(version_in_file "$tool" "$f")"; then
            refuse "$tool: CI's $filekey '$f' does not name an exact version (X.Y.Z)."
            return 1
        fi
        PIN_KIND="file"; PIN_VALUE="$f"; PIN_VERSION="$v"; PIN_FROM="CI $filekey"
        return 0
    fi
    if [ -n "$lits" ]; then
        n="$(cut -f1 <<<"$lits" | sort -u | grep -c .)"
        if [ "$n" -ne 1 ]; then
            refuse "$tool: CI pins $n different versions ($(cut -f1 <<<"$lits" | sort -u | tr '\n' ' ')). Make them agree, then re-render."
            return 1
        fi
        v="$(head -1 <<<"$lits" | cut -f1)"
        if ! [[ "$v" =~ $EXACT_RE ]]; then
            refuse "$tool: CI pins it as '$v' ($(cut -f2 <<<"$lits" | sort -u | tr '\n' ' ')), which is not an exact version. Pin X.Y.Z in CI (or a version file CI reads), then re-render."
            return 1
        fi
        PIN_KIND="literal"; PIN_VALUE="$v"; PIN_VERSION="$v"; PIN_FROM="CI $key"
        return 0
    fi
    for f in "$@"; do
        grep -qxF -- "$f" <<<"$ALL_FILES" || continue
        v="$(version_in_file "$tool" "$f")"; rc=$?
        [ "$rc" -eq 3 ] && continue
        if [ "$rc" -ne 0 ]; then
            refuse "$tool: $f pins it, but not as an exact version (X.Y.Z)."
            return 1
        fi
        PIN_KIND="file"; PIN_VALUE="$f"; PIN_VERSION="$v"; PIN_FROM="$f"
        return 0
    done
    refuse "$tool: no pin. CI sets no $key / $filekey, and none of $* pins it at the repo root. Pin an exact version, then re-render."
    return 1
}

# template_step_script <template> <step name> — the step's `run: |` body,
# dedented. Used to run the impl's OWN pin readers at render time.
template_step_script() {
    awk -v want="      - name: $2" '
        index($0, want) == 1 { step = 1; next }
        step && /^        run: \|$/ { body = 1; next }
        body && /^[[:space:]]*$/ { print ""; next }
        body && !/^          / { exit }
        body { sub(/^          /, ""); print }
    ' "$1"
}

# read_pin <step name> <output key> <path> — run the impl's reader step on a
# repo file; prints the value it would install, or returns 1 with its reason
# on stdout.
read_pin() {
    local script="$WORK/reader.sh" out="$WORK/reader.out" msg
    template_step_script "$IMPL_TPL" "$1" > "$script"
    [ -s "$script" ] || { echo "the impl template has no '$1' step"; return 2; }
    : > "$out"
    if ! msg="$(PIN_FILE="$ROOT/$3" GITHUB_OUTPUT="$out" bash "$script" 2>&1)"; then
        echo "$msg" | sed 's/^::error:://' | sed "s#$ROOT/##g" | tail -1
        return 1
    fi
    sed -n "s/^$2=//p" "$out" | tail -1
}

# derive_file_pin <tool> <step name> <output key> <ignore-unpinned-re> <candidates>
# — every candidate the reader accepts must agree; a candidate it rejects is a
# refusal, except paths matching <ignore-unpinned-re> (a pubspec.yaml whose
# environment.flutter is a constraint, not a pin). The source is the first
# candidate in the order given.
derive_file_pin() {
    local tool="$1" step="$2" key="$3" ignore_re="$4" cands="$5" c v found="" bad=0 rc
    PIN_VALUE=""; PIN_VERSION=""
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        v="$(read_pin "$step" "$key" "$c")"; rc=$?
        if [ "$rc" -eq 2 ]; then die "$v"; fi
        if [ "$rc" -ne 0 ]; then
            if [ -n "$ignore_re" ] && [[ "$c" =~ $ignore_re ]]; then continue; fi
            refuse "$tool: $v"
            bad=1; continue
        fi
        if ! [[ "$c" =~ $SAFE_PATH_RE ]]; then refuse "$tool: pin file '$c' has a path this renderer will not quote"; bad=1; continue; fi
        found+="$v"$'\t'"$c"$'\n'
    done <<<"$cands"
    [ "$bad" -eq 0 ] || return 1
    if [ -z "$found" ]; then
        return 3
    fi
    if [ "$(cut -f1 <<<"$found" | grep -v '^$' | sort -u | grep -c .)" -ne 1 ]; then
        refuse "$tool: pins disagree: $(grep -v '^$' <<<"$found" | awk -F'\t' '{printf "%s=%s ", $2, $1}'). Make them agree, then re-render."
        return 1
    fi
    PIN_VERSION="$(head -1 <<<"$found" | cut -f1)"
    PIN_VALUE="$(head -1 <<<"$found" | cut -f2)"
    return 0
}

# by_depth — sort paths shallowest first, then by name.
by_depth() { awk -F/ '{print NF "\t" $0}' | sort -t$'\t' -k1,1n -k2 | cut -f2-; }

FLAGS=""
toolchains_json='{}'
add_tc_json() { # <tool> <kind> <source> <version> <from>
    toolchains_json="$(jq -c --arg t "$1" --arg k "$2" --arg s "$3" --arg v "$4" --arg f "$5" \
        '. + {($t): {kind: $k, source: $s, version: $v, from: $f}}' <<<"$toolchains_json")"
}
BUN_VERSION_FILE=""; BUN_VERSION=""; NODE_VERSION_FILE=""; NODE_VERSION=""
FLUTTER_PIN_FILE=""; RUST_PIN_FILE=""

if grep -qx bun <<<"$TOOLCHAINS"; then
    if derive_setup_pin bun bun-version bun-version-file .bun-version .tool-versions package.json; then
        if [ "$PIN_KIND" = "file" ]; then FLAGS+=",BUN_PIN_FILE"; BUN_VERSION_FILE="$PIN_VALUE"
        else FLAGS+=",BUN_PIN_LITERAL"; BUN_VERSION="$PIN_VALUE"; fi
        add_tc_json bun "$PIN_KIND" "$PIN_VALUE" "$PIN_VERSION" "$PIN_FROM"
    fi
fi
if grep -qx node <<<"$TOOLCHAINS"; then
    if derive_setup_pin node node-version node-version-file .nvmrc .node-version .tool-versions; then
        if [ "$PIN_KIND" = "file" ]; then FLAGS+=",NODE_PIN_FILE"; NODE_VERSION_FILE="$PIN_VALUE"
        else FLAGS+=",NODE_PIN_LITERAL"; NODE_VERSION="$PIN_VALUE"; fi
        add_tc_json node "$PIN_KIND" "$PIN_VALUE" "$PIN_VERSION" "$PIN_FROM"
    fi
fi
if grep -qx flutter <<<"$TOOLCHAINS"; then
    # Priority: .fvmrc, then .fvm/fvm_config.json, then the pub lanes' own
    # pubspec.yaml (only an exact environment.flutter counts as a pin there).
    pubspecs="$(for l in $LANES; do
        case "$l" in pub:/) echo "pubspec.yaml" ;; pub:*) echo "${l#pub:/}/pubspec.yaml" ;; esac
    done)"
    cands="$( { grep -E '(^|/)\.fvmrc$' <<<"$FILES" | by_depth
                grep -E '(^|/)\.fvm/fvm_config\.json$' <<<"$FILES" | by_depth
                by_depth <<<"$pubspecs"; } | grep -v '^$')"
    derive_file_pin flutter "Read the Flutter pin" version '(^|/)pubspec\.yaml$' "$cands"; rc=$?
    if [ "$rc" -eq 0 ]; then
        FLAGS+=",FLUTTER"; FLUTTER_PIN_FILE="$PIN_VALUE"
        add_tc_json flutter file "$PIN_VALUE" "$PIN_VERSION" "$PIN_VALUE"
    elif [ "$rc" -eq 3 ]; then
        refuse "flutter: no pin. Track .fvmrc or .fvm/fvm_config.json with an exact version (or an exact environment.flutter in a pub lane's pubspec.yaml), then re-render."
    fi
fi
if grep -qx rust <<<"$TOOLCHAINS"; then
    cands="$( { grep -E '(^|/)rust-toolchain\.toml$' <<<"$FILES" | by_depth
                grep -E '(^|/)rust-toolchain$' <<<"$FILES" | by_depth; } | grep -v '^$')"
    derive_file_pin rust "Read the Rust toolchain pin" toolchain '' "$cands"; rc=$?
    if [ "$rc" -eq 0 ]; then
        FLAGS+=",RUST"; RUST_PIN_FILE="$PIN_VALUE"
        add_tc_json rust file "$PIN_VALUE" "$PIN_VERSION" "$PIN_VALUE"
    elif [ "$rc" -eq 3 ]; then
        refuse "rust: no pin. Track a rust-toolchain.toml whose channel is an exact version (X.Y.Z), then re-render."
    fi
fi

# summary <refusals-text> — the JSON report on stdout. A refused render prints
# it too (with the refusals and no files), so the plan can show what the repo
# WOULD get and exactly what it is missing.
summary() {
    jq -n --argjson lanes "$lanes_json" --argjson skipped "$skipped_json" \
        --arg norefresh "$NO_REFRESH" --argjson tc "$toolchains_json" --arg runner "ubuntu-latest" \
        --arg refusals "$1" \
        '{lanes: $lanes, lanes_line: ($lanes | join(" ")), not_refreshed: $skipped,
          no_refresh_command: ($norefresh | split(", ") | map(select(length > 0))),
          toolchains: $tc, runner: $runner,
          refusals: ($refusals | split("\n") | map(select(length > 0))),
          files: (if $refusals == "" then [".github/workflows/deps-cadence.yml", ".github/workflows/deps-cadence-impl.yml"] else [] end)}'
}

if [ -n "$REFUSALS" ]; then
    printf '%s' "$REFUSALS" | sed 's/^/render-cadence: REFUSED /' >&2
    summary "$REFUSALS"
    exit 4
fi

# --- compare to the committed impl -------------------------------------------------
if [ -n "$COMPARE_TO" ]; then
    [ -r "$COMPARE_TO" ] || die "cannot read --compare-to '$COMPARE_TO'"
    committed="$(sed -n 's/^[[:space:]]*LANES:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$COMPARE_TO" | head -1)"
    [ -n "$committed" ] || die "--compare-to '$COMPARE_TO' carries no LANES: line to compare"
    diverged=0
    for l in $committed; do
        case " $LANES " in *" $l "*) ;; *) echo "render-cadence: DIVERGED committed lane $l is not in the fresh render" >&2; diverged=1 ;; esac
    done
    [ "$diverged" -eq 0 ] || exit 5
fi

# --- render ---------------------------------------------------------------------------
# The three rules every setup-deps template documents: drop the header (all
# before `---`), keep or delete each `# {{IF:FLAG}} … # {{ENDIF}}`, substitute
# each `{{TOKEN}}`.
render() { # <template> <flags-csv>
    local tpl="$1" flags="$2" line trimmed flag in_header=1 keep=1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in_header" = "1" ]; then
            [ "$line" = "---" ] || continue
            in_header=0
        fi
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            '# {{IF:'*'}}')
                flag="${trimmed#\# \{\{IF:}"; flag="${flag%\}\}}"
                if [[ ",$flags," == *",$flag,"* ]]; then keep=1; else keep=0; fi
                continue ;;
            '# {{ENDIF}}') keep=1; continue ;;
        esac
        [ "$keep" = "1" ] || continue
        line="${line//\{\{LANES\}\}/$LANES}"
        line="${line//\{\{NO_REFRESH\}\}/${NO_REFRESH:-none}}"
        line="${line//\{\{NOT_REFRESHED\}\}/${NOT_REFRESHED:-none}}"
        line="${line//\{\{BUN_VERSION_FILE\}\}/$BUN_VERSION_FILE}"
        line="${line//\{\{BUN_VERSION\}\}/$BUN_VERSION}"
        line="${line//\{\{NODE_VERSION_FILE\}\}/$NODE_VERSION_FILE}"
        line="${line//\{\{NODE_VERSION\}\}/$NODE_VERSION}"
        line="${line//\{\{FLUTTER_PIN_FILE\}\}/$FLUTTER_PIN_FILE}"
        line="${line//\{\{RUST_PIN_FILE\}\}/$RUST_PIN_FILE}"
        printf '%s\n' "$line"
    done < "$tpl"
}

# Bash 5.2 treats `&` in a ${x//p/r} replacement as the match; no value here
# should carry one, and turning it off keeps a future one literal.
shopt -u patsub_replacement 2>/dev/null || true

render "$TRIGGER_TPL" "" > "$WORK/deps-cadence.yml"
render "$IMPL_TPL" "${FLAGS#,}" > "$WORK/deps-cadence-impl.yml"
for f in deps-cadence.yml deps-cadence-impl.yml; do
    [ -s "$WORK/$f" ] || die "render of $f is empty (no '---' in the template?)"
    if left="$(grep -nE '\{\{[A-Za-z_]+(:[A-Za-z_]+)?\}\}' "$WORK/$f")"; then
        die "render of $f left a token or marker behind: $(tr '\n' ' ' <<<"$left")"
    fi
done

mkdir -p "$OUT_DIR" || die "cannot create --out-dir '$OUT_DIR'"
cp "$WORK/deps-cadence.yml" "$WORK/deps-cadence-impl.yml" "$OUT_DIR/" || die "cannot write into '$OUT_DIR'"

summary ""
