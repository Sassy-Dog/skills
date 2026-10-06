#!/usr/bin/env bash
# shellcheck shell=bash
# lib-ecosystems.sh — the ONE ecosystem table for setup-deps, sourced by
# detect-ecosystems.sh, render-dependabot.sh and validate-dependabot.sh.
# Sourced, never executed.
#
# Why a shared lib: detection ("does this repo have npm?"), location derivation
# ("at which directories?") and post-render validation ("does the directory
# this block claims actually hold that manifest?") are the same knowledge asked
# three ways. A second transcription of the table would let the validator agree
# with a renderer that is wrong — the check would pass because both copies made
# the same mistake, which is the failure mode the check exists to catch.
#
# EVIDENCE RULE (inherited by every caller): tracked repo files only, never
# what happens to be installed on this machine — a rendered config has to hold
# on every teammate's machine and in CI.
#
# CORPUS: `git ls-files` by default; `--files-from FILE` overrides it so the
# derivation is testable against a recorded consumer-repo file list without
# cloning that repo (scripts/test-dependabot-render.sh). The override is a
# TEST HOOK, not a runtime mode — nothing in SKILL.md passes it.
#
# A VENDORED EXAMPLE MANIFEST IS NOT A PROJECT: the corpus is filtered by
# EXCLUDE_RE before anything else runs, by DIRECTORY NAME rather than depth, so
# packages/web/package.json still counts and templates/package.json does not.

EXCLUDE_RE='(^|/)(templates?|fixtures?|__fixtures__|testdata|test-?data|examples?|node_modules)(/|$)'

# Populated by load_corpus.
ALL_FILES=""
FILES=""
EXCLUDED_COUNT=0
CORPUS_ROOT=""

# load_corpus [--files-from FILE] — fills ALL_FILES / FILES / EXCLUDED_COUNT.
# CORPUS_ROOT must already be set to the directory the paths are relative to
# (the few probes that must read a manifest's CONTENT resolve against it).
load_corpus() {
    local from="${1:-}"
    if [ -n "$from" ]; then
        ALL_FILES="$(cat "$from")" || return 1
    else
        ALL_FILES="$(git ls-files 2>/dev/null)" || return 1
    fi
    FILES="$(grep -Ev "$EXCLUDE_RE" <<<"$ALL_FILES")"
    local excluded
    excluded="$(grep -E "$EXCLUDE_RE" <<<"$ALL_FILES")"
    EXCLUDED_COUNT=0
    # shellcheck disable=SC2034  # reported by detect-ecosystems.sh as vendored_excluded
    [ -n "$excluded" ] && EXCLUDED_COUNT="$(grep -c '' <<<"$excluded")"
    return 0
}

# has <path-regex> — anchored at a path segment boundary, so it finds nested
# manifests in monorepos as well as root ones. Runs over the vendored-filtered
# FILES, never ALL_FILES.
#
# Herestring, NOT `printf ... | grep -q`. Under `set -o pipefail`, `grep -q`
# exits on the first match, the writer takes SIGPIPE, and the pipeline reports
# 141 — so a MATCH reads as a miss. It only trips once the file list is long
# enough that the writer is still going when grep bails, which means it
# silently under-detects the largest repos while every small-repo test passes.
has() { grep -qE "$1" <<<"$FILES"; }

# eco_manifest_re <ecosystem> — ERE matching the BASENAMES that make a
# directory a valid `directory:` for that ecosystem. This is the table
# validate-dependabot.sh asserts against, so keep it in step with the probes.
eco_manifest_re() {
    case "$1" in
        github-actions) echo '^[^/]+\.ya?ml$' ;;   # under <dir>/.github/workflows/
        bun|npm)        echo '^package\.json$' ;;
        nuget)          echo '\.(csproj|vbproj|fsproj|sln)$|^Directory\.Packages\.props$|^packages\.config$' ;;
        pub)            echo '^pubspec\.yaml$' ;;
        gomod)          echo '^go\.mod$' ;;
        swift)          echo '^Package\.swift$' ;;
        cargo)          echo '^Cargo\.toml$' ;;
        pip)            echo '^(requirements\.txt|pyproject\.toml|setup\.py|Pipfile)$' ;;
        gradle)         echo '^(build|settings)\.gradle(\.kts)?$' ;;
        docker)         echo '^Dockerfile[^/]*$' ;;
        cocoapods)      echo '^Podfile$' ;;
        *)              return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Location derivation.
#
# The unit Dependabot works on is a (ecosystem, directory) PAIR: it reads the
# manifest AT `directory` and does NOT recurse. So a directory that holds no
# manifest is a lane that silently finds nothing — the failure this whole
# module exists to make impossible.
#
# Default rule: one directory per tracked manifest. Three ecosystems override it,
# and each override is backed by evidence rather than a guess:
#   - gradle  — settings.gradle(.kts) defines the BUILD ROOT; app/build.gradle
#     under it is a module of the same build, not a second project
#     (tailoredtip: /app/android, never /app/android/app).
#   - cargo   — a member of a [workspace] is not independently updatable;
#     Dependabot wants the workspace root (devcanopy: / and /agent, never the
#     nine crates/* members — /agent is listed because it declares its own
#     empty [workspace] table).
#   - bun     — a workspace member covered by a root bun.lock/bun.lockb is not
#     independently updatable: a PR from a member entry edits only that member's
#     package.json, never the root lockfile, so it fails `bun install
#     --frozen-lockfile` and can never merge (what2wear: seven per-member PRs
#     red, while the root entry's grouped PR rewrote every member manifest plus
#     bun.lock and passed). A member with its OWN lockfile keeps its own entry.
#     The cited precedent for per-member entries does not apply: velovate has
#     the same single-root-lockfile shape, and its per-member lanes are `npm`,
#     which does not regenerate bun.lock either (qr-ninja#326, 0 of 20 merged).
# npm, pub, nuget and docker deliberately do NOT collapse: velovate's committed
# config lists each npm workspace member, each pubspec (including one nested
# under another), each .csproj folder and each Dockerfile folder.
# ---------------------------------------------------------------------------

# _display_dir <path> — the `directory:` value for the directory holding <path>.
_display_dir() {
    local d="${1%/*}"
    [ "$d" = "$1" ] && d=""
    if [ -z "$d" ]; then echo "/"; else echo "/$d"; fi
}

# dirs_of <basename-ere> — sorted unique directories of matching corpus files.
dirs_of() {
    local re="$1" p base
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        base="${p##*/}"
        [[ "$base" =~ $re ]] || continue
        _display_dir "$p"
    done <<<"$FILES" | sort -u
}

# is_ancestor <ancestor-dir> <dir> — both in display form; proper ancestry only.
is_ancestor() {
    [ "$1" = "$2" ] && return 1
    if [ "$1" = "/" ]; then return 0; fi
    case "$2" in "$1"/*) return 0 ;; *) return 1 ;; esac
}

# _roots_under <root-dirs> <candidate-dirs> — keep a candidate when it IS a
# root, or when no root is an ancestor of it (a project outside every declared
# root is its own root). Both args are newline-separated display dirs.
_roots_under() {
    local roots="$1" candidates="$2" c r keep
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        keep=1
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            if [ "$c" = "$r" ]; then keep=1; break; fi
            if is_ancestor "$r" "$c"; then keep=0; fi
        done <<<"$roots"
        [ "$keep" -eq 1 ] && echo "$c"
    done <<<"$candidates" | sort -u
}

# gradle_dirs — build roots only (see the override note above).
gradle_dirs() {
    local settings builds
    settings="$(dirs_of '^settings\.gradle(\.kts)?$')"
    builds="$(dirs_of '^build\.gradle(\.kts)?$')"
    [ -z "$builds" ] && builds="$settings"
    _roots_under "$settings" "$builds"
}

# cargo_dirs — workspace roots plus standalone crates. Reads Cargo.toml
# CONTENT, because `[workspace]` is where cargo itself defines the boundary;
# no path convention can tell a member from a nested root. (The vendored-
# manifest filter stays path-based on purpose — that question is "is this a
# project", which content cannot answer.) An unreadable manifest degrades to
# "not a workspace root" and is reported via CORPUS_NOTES.
CORPUS_NOTES=""
cargo_dirs() {
    local all ws p d
    all="$(dirs_of '^Cargo\.toml$')"
    ws=""
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "/" ]; then p="Cargo.toml"; else p="${d#/}/Cargo.toml"; fi
        if [ -r "$CORPUS_ROOT/$p" ]; then
            if grep -qE '^[[:space:]]*\[workspace\]' "$CORPUS_ROOT/$p"; then
                ws+="$d"$'\n'
            fi
        else
            CORPUS_NOTES+="cargo: $p not readable — treated as a non-workspace crate"$'\n'
        fi
    done <<<"$all"
    _roots_under "$ws" "$all"
}

# bun_dirs — package.json directories minus workspace members that a root
# lockfile covers. A lockfile dir is a workspace root only when its own
# package.json declares `workspaces` (content probe, same degrade-and-note
# shape as cargo_dirs). A package.json dir collapses into the nearest-or-any
# such ancestor unless it holds a bun lockfile itself.
bun_dirs() {
    local all locks ws d p c r keep
    all="$(dirs_of '^package\.json$')"
    locks="$(dirs_of '^bun\.lockb?$')"
    ws=""
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "/" ]; then p="package.json"; else p="${d#/}/package.json"; fi
        if [ -r "$CORPUS_ROOT/$p" ]; then
            grep -qE '"workspaces"[[:space:]]*:' "$CORPUS_ROOT/$p" && ws+="$d"$'\n'
        else
            CORPUS_NOTES+="bun: $p not readable — treated as a non-workspace root"$'\n'
        fi
    done <<<"$locks"
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        keep=1
        if ! grep -qxF -- "$c" <<<"$locks"; then
            while IFS= read -r r; do
                [ -n "$r" ] || continue
                is_ancestor "$r" "$c" && keep=0
            done <<<"$ws"
        fi
        [ "$keep" -eq 1 ] && echo "$c"
    done <<<"$all" | sort -u
}

# nuget_dirs — project folders; Dependabot does not recurse, so a lane pointed
# at a solution folder with no project file in it discovers nothing (velovate
# froze its API deps for months that way). Fall back to the solution/central-
# package-management folder only when the repo has no project files at all.
nuget_dirs() {
    local projects
    projects="$(dirs_of '\.(csproj|vbproj|fsproj)$')"
    if [ -n "$projects" ]; then
        echo "$projects"
    else
        dirs_of '\.sln$|^Directory\.Packages\.props$|^packages\.config$'
    fi
}

# ecosystem_dirs <ecosystem> — the directories for a DETECTED ecosystem.
ecosystem_dirs() {
    case "$1" in
        github-actions)
            # Dependabot scans .github/workflows at the repo root only.
            has '^\.github/workflows/.*\.ya?ml$' && echo "/" ;;
        bun)       bun_dirs ;;
        npm)       dirs_of '^package\.json$' ;;
        nuget)     nuget_dirs ;;
        pub)       dirs_of '^pubspec\.yaml$' ;;
        gomod)     dirs_of '^go\.mod$' ;;
        swift)     dirs_of '^Package\.swift$' ;;
        cargo)     cargo_dirs ;;
        pip)       dirs_of '^(requirements\.txt|pyproject\.toml|setup\.py|Pipfile)$' ;;
        gradle)    gradle_dirs ;;
        docker)    dirs_of '^Dockerfile[^/]*$' ;;
        cocoapods) dirs_of '^Podfile$' ;;
        *)         return 1 ;;
    esac
}

# dir_holds_manifest <ecosystem> <display-dir> — the post-render assertion:
# does the corpus hold a manifest for <ecosystem> DIRECTLY in <display-dir>?
# Directly, not recursively: Dependabot does not recurse either.
dir_holds_manifest() {
    local eco="$1" dir="$2" re prefix p rest
    re="$(eco_manifest_re "$eco")" || return 2
    if [ "$dir" = "/" ]; then prefix=""; else prefix="${dir#/}/"; fi
    [ "$eco" = "github-actions" ] && prefix="${prefix}.github/workflows/"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in "$prefix"*) rest="${p#"$prefix"}" ;; *) continue ;; esac
        case "$rest" in */*) continue ;; esac   # deeper than <dir>, not in it
        [[ "$rest" =~ $re ]] && return 0
    done <<<"$FILES"
    return 1
}
