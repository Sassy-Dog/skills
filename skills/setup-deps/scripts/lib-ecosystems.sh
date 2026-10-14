#!/usr/bin/env bash
# shellcheck shell=bash
# lib-ecosystems.sh — the ONE ecosystem table for setup-deps, sourced by
# detect-ecosystems.sh, render-dependabot.sh, validate-dependabot.sh and
# render-cadence.sh.
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

# parse_cooldown_requests REQUESTS — the ONE parser for `--cooldown ECOSYSTEM=DAYS`
# requests (issue #501), called by render-dependabot.sh and validate-dependabot.sh
# so the two cannot drift: a validator that accepts what the renderer refuses
# would pass a file no render could have produced. REQUESTS is the caller's
# newline-separated list. Returns 0 when every request is "ecosystem=days" with
# DAYS an integer 1..90 (Dependabot's documented range) and no ecosystem is
# named twice; otherwise returns 1 with the reason in COOLDOWN_ERR. The caller
# owns the message prefix and the exit code (render exits 1, validate exits 2).
# shellcheck disable=SC2034  # out-parameter, read by the sourcing scripts
COOLDOWN_ERR=""
parse_cooldown_requests() {
    local req seen=""
    COOLDOWN_ERR=""
    while IFS= read -r req; do
        [ -n "$req" ] || continue
        if ! [[ "$req" =~ ^([a-z][a-z-]*)=([1-9][0-9]{0,2})$ ]] || [ "${BASH_REMATCH[2]}" -gt 90 ]; then
            COOLDOWN_ERR="--cooldown '$req' must be ECOSYSTEM=DAYS with DAYS an integer 1..90"
            return 1
        fi
        if grep -qxF "${BASH_REMATCH[1]}" <<<"$seen"; then
            COOLDOWN_ERR="--cooldown names '${BASH_REMATCH[1]}' twice"
            return 1
        fi
        seen+="${BASH_REMATCH[1]}"$'\n'
    done <<<"$1"
    return 0
}

# extract_ignore_rules FILE — the ONE reader of a dependabot.yml's `ignore:`
# rules (issue #508), called by render-dependabot.sh (--keep-ignores-from, to
# carry a committed file's rules into the render) and validate-dependabot.sh
# (--compare-to, to fail a render that drops one). Sharing it matters for the
# reason parse_cooldown_requests is shared: a carry and a check that read rules
# differently would let the check agree with a carry that lost something.
# FILE may be "-" for stdin.
#
# One line per source line of every rule, tab-separated:
#   ecosystem  directory  rule-id  key  dash-indent  source-line
# - rule-id is unique per rule within the file; all of a rule's lines share it.
# - key is the rule's identity: its content lines (comments dropped, the list
#   dash dropped, whitespace and quotes removed) joined by ";", e.g.
#   `dependency-name:expo;update-types:[version-update:semver-major]`. It
#   covers dependency-name, update-types AND versions, so a rule whose
#   update-types narrowed is a different rule, not the same one.
# - source-line is verbatim. Comment and blank lines immediately above a rule
#   belong to it (that is where a hold's explanation lives), so a carried rule
#   keeps its reasoning; trailing ones before the next key belong to nothing.
# An entry with several directories emits each rule once per directory, since
# the renderer writes one entry per (ecosystem, directory). An entry with no
# directory reports it as "" so it can never match a rendered lane.
#
# FAIL CLOSED: a flow-form `ignore: [...]` cannot be split into rules, so the
# whole value becomes one rule keyed `!unparsed:<value>`. It still counts as a
# rule the render must carry (so the validator reports it), and the renderer
# refuses to carry it rather than guess.
# The parser is a variable, not inlined in the function, because two consumers
# must run the SAME program: the function below (validator, renderer carry) and
# render-cadence.sh, which injects it into the deps-cadence impl so the monthly
# report reads the bare `ignore:` holds with it at run time (#524). A single
# source is the point; a hand copy in the template would drift. It holds no
# single quote (the awk uses \047), so it can sit in a shell single-quoted
# string both here and in the rendered workflow.
IGNORE_RULES_AWK='
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function ind(s,   m) { match(s, /^ */); return RLENGTH }
    function unq(s) {
        s = trim(s); sub(/[ \t]+#.*$/, "", s)
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
        return s
    }
    function normdir(d) { while (length(d) > 1 && substr(d, length(d)) == "/") d = substr(d, 1, length(d) - 1); return d }
    function keypart(s) { sub(/^[ \t]*-[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); gsub(/[ \t"\047]/, "", s); return s }
    function close_rule() {
        if (rtext != "") { n_rules++; rk[n_rules] = rkey; rt[n_rules] = rtext; rdi[n_rules] = di }
        rtext = ""; rkey = ""
    }
    function end_ignore() { close_rule(); pending = ""; inign = 0 }
    function flush_entry(   i, j, k, nl, lines, d) {
        if (inign) end_ignore()
        if (have) {
            if (n_dirs == 0) { n_dirs = 1; dirs[1] = "" }
            for (i = 1; i <= n_rules; i++) {
                nl = split(rt[i], lines, "\n")
                for (j = 1; j <= n_dirs; j++)
                    for (k = 1; k < nl; k++)
                        printf "%s\t%s\t%d.%d\t%s\t%d\t%s\n", eco, dirs[j], entry, i, rk[i], rdi[i], lines[k]
            }
        }
        have = 0; n_rules = 0; n_dirs = 0; inign = 0; indirs = 0; pending = ""
    }
    {
        line = $0
        if (indirs) {
            if (line ~ /^[ \t]*-[ \t]*["\047]?\//) { v = line; sub(/^[ \t]*-[ \t]*/, "", v); dirs[++n_dirs] = normdir(unq(v)); next }
            indirs = 0
        }
        if (inign) {
            if (line ~ /^[ \t]*$/) { pending = pending line "\n"; next }
            if (line ~ /^[ \t]*#/) {
                if (ind(line) > ii) { pending = pending line "\n"; next }
                end_ignore()
            } else if (line ~ /^ *- / && (di < 0 ? ind(line) >= ii : ind(line) == di)) {
                close_rule(); if (di < 0) di = ind(line)
                rtext = pending line "\n"; pending = ""; rkey = keypart(line); next
            } else if (rtext != "" && ind(line) > di) {
                rtext = rtext pending line "\n"; pending = ""; rkey = rkey ";" keypart(line); next
            } else {
                end_ignore()
            }
        }
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
        if (line ~ /^[ \t]*-[ \t]*package-ecosystem:/) {
            flush_entry(); v = line; sub(/^[^:]*package-ecosystem:/, "", v)
            eco = unq(v); have = 1; entry++; next
        }
        if (line ~ /^[^ ]/) { flush_entry(); next }
        if (!have) next
        if (line ~ /^ +directory:/) { v = line; sub(/^ +directory:/, "", v); dirs[++n_dirs] = normdir(unq(v)); next }
        if (line ~ /^ +directories:/) {
            v = line; sub(/^ +directories:/, "", v); v = unq(v)
            if (v == "") { indirs = 1; next }
            gsub(/^\[|\]$/, "", v); nd = split(v, parts, ",")
            for (p = 1; p <= nd; p++) { d = unq(parts[p]); if (d != "") dirs[++n_dirs] = normdir(d) }
            next
        }
        if (line ~ /^ +ignore:/) {
            v = line; sub(/^ +ignore:/, "", v); v = unq(v)
            if (v != "") {
                n_rules++; rk[n_rules] = "!unparsed:" v; rt[n_rules] = line "\n"; rdi[n_rules] = -1
                next
            }
            inign = 1; ii = ind(line); di = -1; pending = ""; rtext = ""
            next
        }
    }
    END { flush_entry() }
'
extract_ignore_rules() {
    awk "$IGNORE_RULES_AWK" "$1"
}

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
# Monthly deps-cadence lanes (issue #509).
#
# The cadence renders its LANES from the SAME (ecosystem, directory) locations
# this file derives for dependabot.yml, so the two can never disagree about
# where a project lives. What it adds is which ecosystems have a refresh
# command at all, the lockfile that command rewrites (a lane is rendered only
# where that lockfile is tracked), and the toolchain it needs.
# Every other detected ecosystem (gradle, nuget, docker, github-actions, …) is
# Dependabot-only: the rendered file lists it as a deliberate absence.
#
# The refresh COMMANDS live in deps-cadence-impl.template.yml's case arms,
# because they run in the consumer repo. scripts/test-deps-cadence-render.sh
# fails when those arms and CADENCE_ECOSYSTEMS name different sets.
# ---------------------------------------------------------------------------
CADENCE_ECOSYSTEMS="bun npm pub cargo"

# cadence_lockfile <ecosystem> — the lockfile basename the refresh rewrites.
cadence_lockfile() {
    case "$1" in
        bun)   echo 'bun.lock' ;;
        npm)   echo 'package-lock.json' ;;
        pub)   echo 'pubspec.lock' ;;
        cargo) echo 'Cargo.lock' ;;
        *)     return 1 ;;
    esac
}

# cadence_toolchain <ecosystem> — the toolchain whose pin the lane needs.
cadence_toolchain() {
    case "$1" in
        bun)   echo 'bun' ;;
        npm)   echo 'node' ;;
        pub)   echo 'flutter' ;;
        cargo) echo 'rust' ;;
        *)     return 1 ;;
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
#   - bun     — a workspace MEMBER (named by the root package.json's top-level
#     `workspaces` globs) covered by a root text bun.lock is not
#     independently updatable: a PR from a member entry edits only that member's
#     package.json, never the root lockfile, so it fails `bun install
#     --frozen-lockfile` and can never merge (what2wear: seven per-member PRs
#     red, while the root entry's grouped PR rewrote every member manifest plus
#     bun.lock and passed). A member with its OWN lockfile keeps its own entry.
#     velovate's per-member lanes were never a precedent: same
#     single-root-lockfile shape, but `npm`, which does not regenerate bun.lock
#     either (qr-ninja#326), and velovate#2400 folded them into one bun lane.
#     convert-npm-lanes.sh folds such lanes by this same rule (bun_cover_root).
# npm, pub, nuget and docker deliberately do NOT collapse: velovate's committed
# config lists each pubspec (including one nested under another), each .csproj
# folder and each Dockerfile folder.
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

# _glob_frag <glob-fragment> <allow-braces 0|1> — translate Bun's documented
# `workspaces` glob syntax to an ERE fragment, on stdout. `*` and `?` do not
# span `/`; `**/` is zero or more segments, a bare `**` spans anything; `[...]`
# is a character class (a leading `!` or `^` negates); `{a,b}` is alternation,
# one level only. Returns 1 for anything it will not guess at — nested braces,
# extglob (`!(`, `@(`, `?(`, `*(`, `+(`), backslash escapes, an unterminated or
# stray `[`/`{`/`}`/`]`, an empty or `/`-bearing class, a class range whose
# ends are not both within one of 0-9, a-z or A-Z — so the caller can
# fail safe rather than fold a package it misread.
_glob_frag() {
    local g="$1" braces="$2" out="" i ch next j body alt alts frag neg k lo hi
    for ((i = 0; i < ${#g}; i++)); do
        ch="${g:i:1}"; next="${g:i+1:1}"
        case "$ch" in
            '?'|'*'|'+'|'@'|'!') [ "$next" = "(" ] && return 1 ;;
        esac
        case "$ch" in
            '*')
                if [ "$next" = "*" ]; then
                    # `**` is only defined as a WHOLE segment (at the start or
                    # after `/`, before `/` or the end), and not inside braces;
                    # anything else is a guess at Bun's semantics, so refuse.
                    [ "$braces" -eq 1 ] || return 1
                    { [ "$i" -eq 0 ] || [ "${g:i-1:1}" = "/" ]; } || return 1
                    case "${g:i+2:1}" in ''|'/') ;; *) return 1 ;; esac
                    if [ "${g:i+2:1}" = "/" ]; then out+='(.*/)?'; i=$((i + 2)); else out+='.*'; i=$((i + 1)); fi
                else out+='[^/]*'; fi ;;
            '?') out+='[^/]' ;;
            '[')
                j="${g:i+1}"
                case "$j" in *']'*) ;; *) return 1 ;; esac
                body="${j%%]*}"
                i=$((i + ${#body} + 1))
                neg=""
                case "$body" in '!'*|'^'*) neg='^'; body="${body:1}" ;; esac
                [ -n "$body" ] || return 1
                case "$body" in *'/'*|*'['*|*'\'*) return 1 ;; esac
                # A range is only portable between two ends of one of 0-9, a-z
                # or A-Z: anything else (`[.-0]` straddles `/`) is ordered by
                # locale and by grep flavour, so refuse rather than guess. Ends
                # are compared by code point, which no locale reorders.
                for ((k = 1; k < ${#body} - 1; k++)); do
                    [ "${body:k:1}" = "-" ] || continue
                    lo="$(LC_ALL=C printf '%d' "'${body:k-1:1}")"
                    hi="$(LC_ALL=C printf '%d' "'${body:k+1:1}")"
                    if   [ "$lo" -ge 48 ] && [ "$lo" -le 57 ]  && [ "$hi" -ge 48 ] && [ "$hi" -le 57 ];  then :
                    elif [ "$lo" -ge 97 ] && [ "$lo" -le 122 ] && [ "$hi" -ge 97 ] && [ "$hi" -le 122 ]; then :
                    elif [ "$lo" -ge 65 ] && [ "$lo" -le 90 ]  && [ "$hi" -ge 65 ] && [ "$hi" -le 90 ];  then :
                    else return 1; fi
                done
                [ -n "$neg" ] && neg='^/'
                out+="[$neg$body]" ;;
            '{')
                [ "$braces" -eq 1 ] || return 1
                j="${g:i+1}"
                case "$j" in *'}'*) ;; *) return 1 ;; esac
                body="${j%%\}*}"
                case "$body" in *'{'*) return 1 ;; esac
                i=$((i + ${#body} + 1))
                alts=""
                while :; do
                    alt="${body%%,*}"
                    [ -n "$alt" ] || return 1
                    frag="$(_glob_frag "$alt" 0)" || return 1
                    alts+="${alts:+|}$frag"
                    case "$body" in *,*) body="${body#*,}" ;; *) break ;; esac
                done
                out+="($alts)" ;;
            ']'|'}'|'\') return 1 ;;
            '.'|'+'|'('|')'|'^'|'$'|'|') out+="\\$ch" ;;
            *) out+="$ch" ;;
        esac
    done
    printf '%s' "$out"
}

# _glob_to_ere <workspace-glob> <neg 0|1> — the glob as an ERE anchored to a
# whole relative path, or return 1 when it cannot be translated safely. In a
# positive glob a trailing `/**` needs at least one more segment (the narrow,
# lane-keeping reading). In a `!` glob it also matches zero segments: Bun's docs
# do not say, and excluding more keeps more lanes.
_glob_to_ere() {
    local g="${1#./}" neg="$2" tail="" frag
    g="${g%/}"
    if [ "$neg" -eq 1 ] && [[ "$g" == */'**' ]]; then g="${g%/\*\*}"; tail='(/.*)?'; fi
    frag="$(_glob_frag "$g" 1)" || return 1
    printf '^%s%s$' "$frag" "$tail"
}

# _bun_load_roots — fills BUN_ROOT_DIRS / BUN_ROOT_GLOBS (the workspace roots),
# BUN_TEXT_DIRS (every directory holding a text bun.lock) and BUN_LOCK_DIRS
# (every directory holding a bun.lock or bun.lockb). A root is a directory
# holding the TEXT bun.lock (a bun.lockb-only repo is classified npm by
# detect-ecosystems.sh and never collapses) whose package.json declares a
# TOP-LEVEL `workspaces` (array form or {"packages": [...]}), read with jq. An
# unparsable manifest, or a root with any glob _glob_to_ere cannot translate,
# degrades to "not a workspace root" and is noted in CORPUS_NOTES. Call it at
# the top level, never inside $(...) or a pipeline: a subshell would drop both
# the arrays and the notes.
BUN_ROOTS_LOADED=0
BUN_TEXT_DIRS=""
BUN_LOCK_DIRS=""
BUN_ROOT_DIRS=()
BUN_ROOT_GLOBS=()
_bun_load_roots() {
    local d p g neg globs bad ere
    [ "$BUN_ROOTS_LOADED" -eq 1 ] && return 0
    BUN_ROOTS_LOADED=1
    BUN_LOCK_DIRS="$(dirs_of '^bun\.lockb?$')"
    BUN_TEXT_DIRS="$(dirs_of '^bun\.lock$')"
    BUN_ROOT_DIRS=(); BUN_ROOT_GLOBS=()
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$d" = "/" ]; then p="package.json"; else p="${d#/}/package.json"; fi
        if [ -r "$CORPUS_ROOT/$p" ]; then
            if globs="$(jq -r 'if (.workspaces|type)=="array" then .workspaces[]
                elif (.workspaces|type)=="object" then (.workspaces.packages // [])[]
                else empty end' "$CORPUS_ROOT/$p" 2>/dev/null)"; then
                if [ -n "$globs" ]; then
                    bad=""
                    while IFS= read -r g; do
                        [ -n "$g" ] || continue
                        neg=0
                        case "$g" in '!'*) neg=1 ;; esac
                        ere="$(_glob_to_ere "${g#!}" "$neg")" || { bad="$g"; break; }
                        # A regex this grep cannot compile exits 2, which the
                        # membership test below would read as "no match".
                        grep -E -- "$ere" </dev/null >/dev/null 2>&1
                        if [ $? -eq 2 ]; then bad="$g"; break; fi
                    done <<<"$globs"
                    if [ -n "$bad" ]; then
                        CORPUS_NOTES+="bun: $p workspaces glob '$bad' is not translatable — no member under $d collapses"$'\n'
                    else
                        BUN_ROOT_DIRS+=("$d"); BUN_ROOT_GLOBS+=("$globs")
                    fi
                fi
            else
                CORPUS_NOTES+="bun: $p is not valid JSON — treated as a non-workspace root"$'\n'
            fi
        else
            CORPUS_NOTES+="bun: $p not readable — treated as a non-workspace root"$'\n'
        fi
    done <<<"$BUN_TEXT_DIRS"
}

# bun_cover_root <display-dir> — the bun install root whose TEXT bun.lock covers
# <display-dir>, on stdout, or nothing. The directory itself when it holds a text
# bun.lock; nothing when it holds only a bun.lockb (its own lockfile, which no
# Dependabot ecosystem writes); otherwise the deepest workspace root whose globs
# name it as a member. A member is a directory whose path under the root matches
# one of the root's globs (every `!glob` excludes, wherever it sits in the list,
# and a `!` glob's trailing `/**` also matches zero segments). Membership, not
# ancestry: a package.json under the root that the globs do not name is not
# covered by the root install. The ONE membership rule: bun_dirs collapses by it
# and convert-npm-lanes.sh converts by it, so a lane the renderer would fold is
# exactly a lane the converter folds. _bun_load_roots must already have run.
bun_cover_root() {
    local c="$1" i r rel g neg hit excl ere best=""
    if grep -qxF -- "$c" <<<"$BUN_TEXT_DIRS"; then echo "$c"; return 0; fi
    grep -qxF -- "$c" <<<"$BUN_LOCK_DIRS" && return 0
    for i in "${!BUN_ROOT_DIRS[@]}"; do
        r="${BUN_ROOT_DIRS[$i]}"
        is_ancestor "$r" "$c" || continue
        if [ "$r" = "/" ]; then rel="${c#/}"; else rel="${c#"$r"/}"; fi
        hit=0; excl=0
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            neg=0
            case "$g" in '!'*) neg=1; g="${g#!}" ;; esac
            ere="$(_glob_to_ere "$g" "$neg")"
            if grep -qE -- "$ere" <<<"$rel"; then
                if [ "$neg" -eq 1 ]; then excl=1; else hit=1; fi
            fi
        done <<<"${BUN_ROOT_GLOBS[$i]}"
        [ "$excl" -eq 1 ] && hit=0
        # Deepest root wins: a member of a nested root belongs to that root.
        if [ "$hit" -eq 1 ] && [ "${#r}" -gt "${#best}" ]; then best="$r"; fi
    done
    [ -z "$best" ] || echo "$best"
    return 0
}

# bun_dirs — package.json directories minus the workspace MEMBERS a root bun.lock
# covers: a directory keeps its lane unless bun_cover_root names a root other
# than itself (a bun.lockb still counts as a member's OWN lockfile, so it keeps
# its lane).
bun_dirs() {
    local all c r
    all="$(dirs_of '^package\.json$')"
    _bun_load_roots
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        r="$(bun_cover_root "$c")"
        if [ -z "$r" ] || [ "$r" = "$c" ]; then echo "$c"; fi
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
