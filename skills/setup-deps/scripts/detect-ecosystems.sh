#!/usr/bin/env bash
# detect-ecosystems.sh — read-only probe: which Dependabot ecosystems does THIS
# repo actually have, AT WHICH DIRECTORIES, and which of them will hand
# Dependabot a lockfile it cannot regenerate? Emits one JSON object; every probe
# degrades to detected:false and appends to detect_failures rather than
# aborting (same contract as setup-hooks' detect-hook-stack.sh).
#
# Evidence rule: an ecosystem counts as detected only on TRACKED REPO FILES —
# never on what happens to be installed on this machine, because the rendered
# config must hold on every teammate's machine and in CI.
#
# `directories` is why this probe is not just a yes/no. Dependabot reads the
# manifest AT `directory:` and does not recurse, so an ecosystem detected in a
# subdirectory and reported without its location renders as `directory: "/"` —
# valid YAML pointing at nothing, and Dependabot then silently does nothing
# (issue #169: tailoredtip's four correctly-directed lanes would have collapsed
# onto the root on the next refresh). The derivation rules, and the three
# ecosystems that collapse to a build/workspace root (gradle, cargo, bun), live
# in lib-ecosystems.sh.
#
# `lockfile_risk` is the field that matters most. Dependabot updates a manifest
# (package.json, Podfile) but only writes the lockfile formats it supports. When
# it cannot, CI running a frozen-lockfile install rejects every PR it opens —
# qr-ninja hit exactly this and merged 0 of 20 npm PRs before removing the
# ecosystem. A true here means "this ecosystem needs a lockfile-sync workflow,
# or its PRs will be dead on arrival." Since Dependabot's native `bun`
# ecosystem GA'd (2025-02) the text bun.lock is written natively, so the risk
# survives only for the binary bun.lockb and for cocoapods.
#
# Matching is by PATH REGEX over the corpus, not git pathspec globs: a pathspec
# like 'package.json' matches only the repo root, which would silently report
# "no npm" for every workspaces monorepo in the org. Anchor with (^|/).
#
# A VENDORED EXAMPLE MANIFEST IS NOT A PROJECT. Scaffolder templates, test
# fixtures and sample projects commit real-looking manifests (a scaffolding
# `templates/package.json` whose fields are literally {{PROJECT_ID}} once made
# this probe report npm on a repo with no npm project at all), and Dependabot
# then either opens PRs against a placeholder or silently does nothing. So the
# corpus is filtered by EXCLUDE_RE before any ecosystem test runs. Excluding by
# DIRECTORY NAME, not by depth, is what preserves the anchoring property above:
# packages/web/package.json still counts, templates/package.json does not.
# Path convention beats content-sniffing — a fixture manifest can be perfectly
# valid JSON and still not be a project, so parsing would not help. The
# assumption: anything genuinely built from those directories also has a real
# manifest outside them. The drop count is reported (vendored_excluded) so the
# filter is visible rather than silent.
#
# Usage: detect-ecosystems.sh   (run from anywhere inside the target repo)
#        detect-ecosystems.sh --files-from LIST --root DIR   (test hook only —
#          run the derivation against a recorded file list instead of a repo;
#          see scripts/test-dependabot-render.sh. Nothing in SKILL.md uses it.)
# Exit:  0 ok · 1 jq missing, not a git repo, or a bad test-hook argument
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "detect-ecosystems: jq not on PATH" >&2; exit 1; }

# shellcheck source=./lib-ecosystems.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ecosystems.sh"

FILES_FROM=""
ROOT_ARG=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --files-from) FILES_FROM="${2:-}"; shift 2 || exit 1 ;;
        --root)       ROOT_ARG="${2:-}"; shift 2 || exit 1 ;;
        *) echo "detect-ecosystems: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

if [ -n "$FILES_FROM" ]; then
    [ -r "$FILES_FROM" ] || { echo "detect-ecosystems: cannot read --files-from '$FILES_FROM'" >&2; exit 1; }
    [ -n "$ROOT_ARG" ] || { echo "detect-ecosystems: --files-from requires --root" >&2; exit 1; }
    ROOT="$ROOT_ARG"
else
    ROOT="${ROOT_ARG:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    [ -n "$ROOT" ] || { echo "detect-ecosystems: not in a git repo" >&2; exit 1; }
fi
cd "$ROOT" || exit 1
# shellcheck disable=SC2034  # read by lib-ecosystems.sh's content probes
CORPUS_ROOT="$ROOT"

load_corpus "$FILES_FROM" || { echo "detect-ecosystems: could not load the file corpus" >&2; exit 1; }

failures=()
DIRS_TMP="$(mktemp)"
trap 'rm -f "$DIRS_TMP"' EXIT
note() { failures+=("$1"); }

results=""
# add <ecosystem> <detected 0/1> <lockfile_risk 0/1> <why> — a detected
# ecosystem also carries the directories it was detected AT.
add() {
    local name="$1" det="$2" risk="$3" why="$4" dirs_json='[]'
    if [ "$det" = "1" ]; then
        # Not `$(ecosystem_dirs ...)`: a subshell would drop the CORPUS_NOTES
        # the probes append, and they are read below into detect_failures.
        ecosystem_dirs "$name" > "$DIRS_TMP"
        dirs_json="$(jq -Rs 'split("\n")|map(select(length>0))' < "$DIRS_TMP")"
        if [ "$dirs_json" = "[]" ]; then
            # Detected but located nowhere: refusing to guess "/" is the whole
            # point — a lane at a directory with no manifest finds nothing and
            # says nothing about it.
            note "$name: detected but no directory could be derived — render it by hand or fix the derivation"
        fi
    fi
    results+=$(jq -cn --arg n "$name" --argjson d "$det" --argjson r "$risk" --arg w "$why" --argjson dirs "$dirs_json" \
        '{($n): {detected: ($d == 1), lockfile_risk: ($r == 1), directories: $dirs, why: $w}}')$'\n'
}

# --- github-actions: always safe. Touches workflow YAML only, no lockfile. ---
det=0; why="no tracked .github/workflows/*.y*ml"
if has '^\.github/workflows/.*\.ya?ml$'; then det=1; why="tracked workflow files"; fi
add "github-actions" "$det" 0 "$why"

# --- bun: native Dependabot ecosystem (GA 2025-02) ---------------------------
# Dependabot's `bun` ecosystem reads and REWRITES the text bun.lock itself
# (bun >= 1.1.39), so a bun repo needs no lockfile-sync workflow — its version
# PRs arrive frozen-lockfile valid. Caveats that stay true today: security
# updates are not yet supported for bun (version updates only), and the binary
# bun.lockb predates the text format and is NOT readable by the native
# ecosystem — a lockb-only repo falls through to the legacy npm +
# lockfile-sync classification below until it migrates
# (`bun install --save-text-lockfile`).
det=0; why="no tracked bun.lock"
if has '(^|/)bun\.lock$'; then
    if has '(^|/)package\.json$'; then
        det=1; why="tracked bun.lock + package.json — native bun ecosystem writes the text lockfile itself"
    else
        why="bun.lock without package.json — no manifest for Dependabot to update"
    fi
elif has '(^|/)bun\.lockb$'; then
    why="binary bun.lockb only — native bun needs the text bun.lock (bun >= 1.1.39); classified as legacy npm + lockfile sync"
fi
add "bun" "$det" 0 "$why"

# --- npm family: the package MANAGER decides whether Dependabot can finish ---
# Dependabot's npm ecosystem writes package-lock.json / yarn.lock / pnpm-lock.yaml.
# The text bun.lock belongs to the native bun ecosystem above, so it does NOT
# count as npm here. Only the legacy binary bun.lockb still lands in npm with
# lockfile_risk: no Dependabot ecosystem can write it, so those repos keep the
# npm + lockfile-sync pairing (or migrate the lockfile and re-run this probe).
det=0; risk=0; why="no tracked package.json"
if has '(^|/)package\.json$'; then
    if has '(^|/)bun\.lock$'; then
        why="package.json + bun.lock — covered by the native bun ecosystem, not npm"
    elif has '(^|/)bun\.lockb$'; then
        det=1; risk=1
        why="package.json + binary bun.lockb — no Dependabot ecosystem writes it; legacy path: npm + lockfile sync (or migrate via bun install --save-text-lockfile)"
    elif has '(^|/)pnpm-lock\.yaml$'; then
        det=1; why="package.json + pnpm-lock.yaml (Dependabot writes this natively)"
    elif has '(^|/)yarn\.lock$'; then
        det=1; why="package.json + yarn.lock (Dependabot writes this natively)"
    elif has '(^|/)package-lock\.json$'; then
        det=1; why="package.json + package-lock.json (Dependabot writes this natively)"
    else
        det=1; why="package.json with no lockfile — nothing to go stale"
    fi
fi
add "npm" "$det" "$risk" "$why"

# --- cocoapods: Dependabot has NO cocoapods ecosystem at all ----------------
# Pods drift in via a Podfile that a native bump touches; the .lock must be
# refreshed out of band. Flagged so the caller renders the pod sync workflow —
# the directories are the Podfile folders, which is where that workflow runs.
det=0; risk=0; why="no tracked Podfile"
if has '(^|/)Podfile$'; then
    det=1; risk=1; why="tracked Podfile — no Dependabot cocoapods ecosystem; needs lockfile sync"
fi
add "cocoapods" "$det" "$risk" "$why"

# --- nuget ------------------------------------------------------------------
det=0; why="no tracked *.csproj / *.sln / Directory.Packages.props"
if has '\.csproj$|\.sln$|(^|/)Directory\.Packages\.props$'; then
    det=1; why="tracked .NET project files"
fi
add "nuget" "$det" 0 "$why"

# --- pub (Dart / Flutter) ---------------------------------------------------
det=0; why="no tracked pubspec.yaml"
if has '(^|/)pubspec\.yaml$'; then det=1; why="tracked pubspec.yaml"; fi
add "pub" "$det" 0 "$why"

# --- gomod ------------------------------------------------------------------
det=0; why="no tracked go.mod"
if has '(^|/)go\.mod$'; then det=1; why="tracked go.mod"; fi
add "gomod" "$det" 0 "$why"

# --- swift ------------------------------------------------------------------
det=0; why="no tracked Package.swift"
if has '(^|/)Package\.swift$'; then det=1; why="tracked Package.swift"; fi
add "swift" "$det" 0 "$why"

# --- cargo ------------------------------------------------------------------
det=0; why="no tracked Cargo.toml"
if has '(^|/)Cargo\.toml$'; then det=1; why="tracked Cargo.toml"; fi
add "cargo" "$det" 0 "$why"

# --- pip --------------------------------------------------------------------
det=0; why="no tracked requirements.txt / pyproject.toml"
if has '(^|/)requirements\.txt$'; then
    det=1; why="tracked requirements.txt"
elif has '(^|/)pyproject\.toml$'; then
    det=1; why="tracked pyproject.toml"
fi
add "pip" "$det" 0 "$why"

# --- gradle -----------------------------------------------------------------
det=0; why="no tracked build.gradle(.kts)"
if has '(^|/)build\.gradle(\.kts)?$'; then det=1; why="tracked build.gradle"; fi
add "gradle" "$det" 0 "$why"

# --- docker -----------------------------------------------------------------
det=0; why="no tracked Dockerfile"
if has '(^|/)Dockerfile[^/]*$'; then det=1; why="tracked Dockerfile"; fi
add "docker" "$det" 0 "$why"

# --- CI workflow: the check a merge gate would require ----------------------
ci_workflow=""
for cand in ci.yml ci.yaml CI.yml build.yml test.yml; do
    if grep -qx "\.github/workflows/$cand" <<<"$FILES"; then ci_workflow="$cand"; break; fi
done
[ -z "$ci_workflow" ] && note "no conventional CI workflow file (ci.yml/build.yml/test.yml) found"

# Anything a content probe could not read degrades to a note rather than an
# abort — same contract as every other probe here.
while IFS= read -r n; do [ -n "$n" ] && note "$n"; done <<<"${CORPUS_NOTES:-}"

repo_slug=""
if [ -z "$FILES_FROM" ]; then
    repo_slug="$(git config --get remote.origin.url 2>/dev/null \
        | sed -E 's#(git@|https://)github\.com[:/]##; s#\.git$##')"
    [ -z "$repo_slug" ] && note "no origin remote — repo slug unresolved"
fi

fails_json="$(printf '%s\n' "${failures[@]+"${failures[@]}"}" | jq -Rs 'split("\n")|map(select(length>0))')"

printf '%s' "$results" | jq -s \
    --arg repo "$repo_slug" \
    --arg ci "$ci_workflow" \
    --arg excl_re "$EXCLUDE_RE" \
    --argjson excl_n "$EXCLUDED_COUNT" \
    --argjson fails "$fails_json" \
    'add | {
        repo: $repo,
        ci_workflow: (if $ci == "" then null else $ci end),
        ecosystems: .,
        present: [ to_entries[] | select(.value.detected) | .key ],
        needs_lockfile_sync: [ to_entries[] | select(.value.detected and .value.lockfile_risk) | .key ],
        locations: [ to_entries[] | select(.value.detected) as $e | $e.value.directories[] | {ecosystem: $e.key, directory: .} ],
        vendored_excluded: { count: $excl_n, pattern: $excl_re },
        detect_failures: $fails
     }'
