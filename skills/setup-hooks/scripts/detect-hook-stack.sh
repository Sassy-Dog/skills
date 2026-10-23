#!/usr/bin/env bash
# detect-hook-stack.sh — read-only probe: which formatter/linter tools does THIS
# repo's configuration call for? Emits one JSON object; every probe degrades to
# detected:false and appends to detect_failures rather than aborting (same
# contract as setup-config' detect-capabilities.sh).
#
# Evidence rule: a tool counts as detected only on REPO EVIDENCE (config file,
# manifest section, tracked file types) — never on what happens to be installed
# on this machine, because committed hooks must hold on every teammate's
# machine. references/detection.md documents each probe and its traps.
#
# Usage: detect-hook-stack.sh   (run from anywhere inside the target repo)
# Exit:  0 ok · 1 missing gh-independent tooling (jq) or not a git repo
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "detect-hook-stack: jq not on PATH" >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "detect-hook-stack: not in a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1

failures=()
note() { failures+=("$1"); }

# tool <name> <detected 0/1> <why> [extra-json-object]
results=""
add() {
    local name="$1" det="$2" why="$3" extra="${4:-}"
    [ -n "$extra" ] || extra='{}'
    results+=$(jq -cn --arg n "$name" --argjson d "$det" --arg w "$why" --argjson e "$extra" \
        '{($n): ({detected: ($d == 1), why: $w} + $e)}')$'\n'
}

# --- tracked-file corpus (every path probe reads THIS, never its own pipeline)
# Manifest probes match by PATH REGEX over the tracked tree, not by git
# pathspec: a bare pathspec like 'pubspec.yaml' — or a `[ -f pubspec.yaml ]`
# test — matches only the repo ROOT, which silently reported "no dart" for
# every monorepo in the org (velovate keeps its Flutter app under
# apps/mobile/, so the render simply had no *.dart route and nothing errored).
# Anchor with (^|/) so packages/app/Cargo.toml counts and notcargo.toml does
# not. Same rule, same anchoring as setup-deps' detect-ecosystems.sh.
#
# A VENDORED EXAMPLE MANIFEST IS NOT A PROJECT. Scaffolder templates, test
# fixtures and sample projects commit real-looking manifests, so the corpus is
# filtered by VENDORED_RE before any probe runs — excluding by DIRECTORY NAME,
# not by depth, is what preserves the anchoring above (packages/web/Cargo.toml
# still counts, templates/Cargo.toml does not). Same exclusion list as
# detect-ecosystems.sh. A manifest found ONLY under an excluded path is
# reported in `why` and in detect_failures, so the filter is visible rather
# than silent.
VENDORED_RE='(^|/)(templates?|fixtures?|__fixtures__|testdata|test-?data|examples?|node_modules)(/|$)'
ALL_TRACKED="$(git ls-files 2>/dev/null)"
TRACKED_FILES="$(grep -Ev "$VENDORED_RE" <<<"$ALL_TRACKED")"
VENDORED_FILES="$(grep -E "$VENDORED_RE" <<<"$ALL_TRACKED")"

# has_tracked <path-regex> — does the tracked tree hold a file matching it?
# Matches the corpus above with a herestring. THERE IS NO PIPELINE HERE, and
# that is the entire point: do not "simplify" this back to
# `git ls-files "<glob>" | head -1 | grep -q .`.
#
# That was the original shape, and under this script's `set -o pipefail` it
# INVERTS ITS OWN ANSWER ON LARGE REPOS (issue #172). `head -1`/`grep -q` exit
# on the first line; if the match list is bigger than the ~64KB pipe buffer the
# writer is still going, takes SIGPIPE, and pipefail hands the pipeline the
# writer's 141 — so a MATCH returns non-zero and READS AS A MISS, and the
# rendered hook silently drops that tool's route. Measured: it flips somewhere
# between 1000 and 2000 paths (~64KB of output), and `git ls-files "*"` in
# velovate's 2787-path tree exits 141 today. Size-dependent, so it is invisible
# in every small-repo test and wrong exactly where a wrong answer costs most —
# which is why scripts/test-detect-hook-stack.sh pins it against a 20k-path
# fixture and rejects any `| head` in this definition.
#
# ALL_TRACKED, not TRACKED_FILES: these probes have always counted vendored
# paths (a `*.sh` under examples/ still wants shellcheck). Narrowing them is a
# behaviour change, not part of this fix.
has_tracked() { grep -qE "$1" <<<"$ALL_TRACKED"; }

# manifest_tool <tool> <path-regex> <label> — detect on a manifest tracked
# ANYWHERE, naming the file it matched (a monorepo user needs to know WHICH
# pubspec.yaml armed the route).
#
# Herestrings, NOT `printf ... | grep`: under pipefail a `grep -q` that exits on
# the first match leaves the writer with SIGPIPE and the pipeline reports 141,
# so a MATCH reads as a miss — and only once the file list is long enough that
# the writer is still going, i.e. it under-detects the largest repos while every
# small-repo test passes.
manifest_tool() {
    local name="$1" re="$2" label="$3" hit vendored
    hit=$(grep -E "$re" <<<"$TRACKED_FILES" | head -1)
    if [ -n "$hit" ]; then
        add "$name" 1 "tracked $label ($hit)"
        return
    fi
    vendored=$(grep -E "$re" <<<"$VENDORED_FILES" | head -1)
    if [ -n "$vendored" ]; then
        add "$name" 0 "no project $label — only a vendored one ($vendored)"
        note "$name: $label found only under a vendored path ($vendored) — a fixture/template manifest is not a project, so $name is NOT detected"
    else
        add "$name" 0 "no tracked $label"
    fi
}

# --- ruff: config section or ruff.toml, plus tracked *.py -------------------
why=""
det=0
if has_tracked '\.py$'; then
    if [ -f ruff.toml ] || [ -f .ruff.toml ]; then
        det=1; why="ruff.toml present + tracked *.py"
    elif [ -f pyproject.toml ] && grep -q '^\[tool\.ruff' pyproject.toml 2>/dev/null; then
        det=1; why="pyproject.toml [tool.ruff] + tracked *.py"
    else
        why="tracked *.py but no ruff config (add ruff.toml or [tool.ruff] to opt in)"
    fi
else
    why="no tracked *.py"
fi
add ruff "$det" "$why"

# --- prettier: config file or package.json "prettier" key -------------------
why=""; det=0
if [ -f .prettierrc ] || [ -f .prettierrc.json ] || [ -f .prettierrc.yaml ] || [ -f .prettierrc.yml ] \
    || [ -f .prettierrc.js ] || [ -f prettier.config.js ] || [ -f prettier.config.mjs ]; then
    det=1; why="prettier config file present"
elif [ -f package.json ] && jq -e '.prettier' package.json >/dev/null 2>&1; then
    det=1; why="package.json prettier key"
else
    why="no prettier config"
fi
add prettier "$det" "$why"

# --- markdownlint: cli2 config + tracked *.md --------------------------------
why=""; det=0
if [ -f .markdownlint-cli2.jsonc ] || [ -f .markdownlint-cli2.yaml ] || [ -f .markdownlint.jsonc ] || [ -f .markdownlint.json ]; then
    if has_tracked '\.md$'; then det=1; why="markdownlint config + tracked *.md"; else why="config but no tracked *.md"; fi
else
    why="no markdownlint config"
fi

# markdownlint version pin: the hook must lint with the SAME markdownlint-cli2
# the repo's CI enforces. An unpinned `npx -y markdownlint-cli2` resolves to
# LATEST at hook time, so a repo whose CI pins an older release gets a hook
# that blocks on rules CI does not run (measured: CI 0.18.1 vs hook 0.23.2,
# MD060 flagging a README CI calls clean). Precedence: an explicit
# markdownlint-cli2@<spec> in .github/workflows/*, then in a shell script those
# workflows invoke (one hop — the common "CI calls scripts/preflight.sh"
# shape), then Makefile/justfile/package.json, then the package.json dependency
# range. Empty pin => the render drops the blocking half and is fix-only.
pin_spec_in() {  # <file> -> prints the pinned spec (version or range), or nothing
    local f="$1" hit
    [ -f "$f" ] || return 1
    hit=$(grep -ohE 'markdownlint-cli2@[0-9A-Za-z.^~><=*+|-]+' "$f" 2>/dev/null | head -1)
    [ -n "$hit" ] || return 1
    printf '%s' "${hit#markdownlint-cli2@}"
}

mdl_pin=""; mdl_pin_source=""
scan=()
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] && scan+=("$f")
done
if [ ${#scan[@]} -gt 0 ]; then
    # one hop: the shell scripts those workflows invoke
    while IFS= read -r ref; do
        ref="${ref#./}"
        [ -n "$ref" ] && [ -f "$ref" ] && scan+=("$ref")
    done < <(grep -ohE '[A-Za-z0-9_./-]+\.sh' "${scan[@]}" 2>/dev/null | sort -u)
fi
for f in Makefile makefile GNUmakefile justfile Justfile .justfile package.json; do
    [ -f "$f" ] && scan+=("$f")
done
for f in "${scan[@]+"${scan[@]}"}"; do
    if spec=$(pin_spec_in "$f"); then
        mdl_pin="$spec"; mdl_pin_source="$f"
        break
    fi
done
if [ -z "$mdl_pin" ] && [ -f package.json ]; then
    spec=$(jq -r '(.devDependencies["markdownlint-cli2"] // .dependencies["markdownlint-cli2"]) // empty' package.json 2>/dev/null)
    if [ -n "$spec" ]; then mdl_pin="$spec"; mdl_pin_source="package.json (dependency range)"; fi
fi
if [ "$det" = 1 ]; then
    if [ -n "$mdl_pin" ]; then
        why="$why + pin markdownlint-cli2@$mdl_pin from $mdl_pin_source"
    else
        why="$why + NO version pin discovered — render fix-only (blocking half omitted)"
        note "markdownlint: no version pin found in .github/workflows/*, CI shell scripts, Makefile, justfile or package.json — the hook renders fix-only so it cannot block on rules CI does not run"
    fi
fi
add markdownlint "$det" "$why" \
    "$(jq -cn --arg p "$mdl_pin" --arg s "$mdl_pin_source" '{pin: $p, pin_source: $s}')"

# --- shellcheck: tracked *.sh (no config file convention — presence of shell
#     scripts IS the evidence; CI repos that shellcheck already prove intent) --
why=""; det=0
if has_tracked '\.sh$'; then
    det=1; why="tracked *.sh"
    grep -rq "shellcheck" .github/workflows/ 2>/dev/null && why="tracked *.sh + shellcheck in CI"
else
    why="no tracked *.sh"
fi
add shellcheck "$det" "$why"

# --- dart / rustfmt / gofmt / dotnet-format: manifest presence ----------------
# Tracked ANYWHERE in the tree, vendored paths excluded — see manifest_tool.
manifest_tool dart '(^|/)pubspec\.yaml$' pubspec.yaml
# rustfmt: a tracked Cargo.toml AND a tracked rustfmt config declaring `edition`.
# Bare `rustfmt <file>` never reads Cargo.toml, so with no `edition` in a
# rustfmt.toml it formats as edition 2015 while `cargo fmt` passes the crate's
# real edition: 2018+ files fail to parse (E0670, swallowed by the route's
# error suppression) and the rest are reformatted in 2015 style, which then
# fails `cargo fmt --check` (issue #569). So the route renders only when the
# edition is declared in repo config. We deliberately do NOT read the edition
# out of Cargo.toml and pass `--edition`: that is a configured fact that drifts.
#
# rustfmt resolves its config by walking UP from the formatted file's directory
# and uses ONLY the NEAREST directory that holds any config (configs are never
# merged), preferring `.rustfmt.toml` over `rustfmt.toml` within one directory.
# So a nearer non-declaring config SHADOWS a declaring ancestor. The rule:
# record each directory's EFFECTIVE config (`.rustfmt.toml` first) whether or
# not it declares edition, then for every directory that holds a tracked
# non-vendored `*.rs` or `Cargo.toml` walk up to the first directory with ANY
# config and require THAT one to declare. Seeding from `*.rs` directories (not
# just Cargo.toml) is because a config can sit below a crate root, e.g.
# crates/b/src/rustfmt.toml. One uncovered directory withholds the route and the
# reason names it, because the route is one `*.rs` case for the whole tree. A
# config counts only if tracked, non-vendored, with an uncommented `edition =`
# line (`style_edition` does not count). Directory sets are newline-delimited
# and matched with `grep -Fxq` on a herestring: a space-joined string would let
# `my crate` falsely match `my`, and a pipe into `grep -q` is the #172 trap.
rustfmt_cargo=$(grep -E '(^|/)Cargo\.toml$' <<<"$TRACKED_FILES")
if [ -z "$rustfmt_cargo" ]; then
    manifest_tool rustfmt '(^|/)Cargo\.toml$' Cargo.toml
else
    rustfmt_any_dirs=""; rustfmt_decl_dirs=""; rustfmt_dot_dirs=""
    # `.rustfmt.toml` listed first so it is recorded before a sibling `rustfmt.toml`
    while IFS= read -r cfg; do
        [ -n "$cfg" ] || continue
        d="${cfg%/*}"; [ "$d" = "$cfg" ] && d="."
        if [ "${cfg##*/}" = "rustfmt.toml" ] && grep -Fxq -- "$d" <<<"$rustfmt_dot_dirs"; then continue; fi
        [ "${cfg##*/}" = ".rustfmt.toml" ] && rustfmt_dot_dirs+="$d"$'\n'
        rustfmt_any_dirs+="$d"$'\n'
        if [ -f "$cfg" ] && grep -qE '^[[:space:]]*edition[[:space:]]*=' "$cfg" 2>/dev/null; then
            rustfmt_decl_dirs+="$d"$'\n'
        fi
    done < <(grep -E '(^|/)\.rustfmt\.toml$' <<<"$TRACKED_FILES"; grep -E '(^|/)rustfmt\.toml$' <<<"$TRACKED_FILES")
    rustfmt_uncovered=""; rustfmt_covering=""
    rustfmt_seeds=$(while IFS= read -r p; do
        d="${p%/*}"; [ "$d" = "$p" ] && d="."; printf '%s\n' "$d"
    done < <(grep -E '(^|/)Cargo\.toml$|\.rs$' <<<"$TRACKED_FILES") | sort -u)
    while IFS= read -r seed; do
        [ -n "$seed" ] || continue
        walk="$seed"; verdict=""
        while :; do
            if grep -Fxq -- "$walk" <<<"$rustfmt_any_dirs"; then
                if grep -Fxq -- "$walk" <<<"$rustfmt_decl_dirs"; then verdict="ok:$walk"; else verdict="bad:$walk"; fi
                break
            fi
            [ "$walk" = "." ] && break
            case "$walk" in */*) walk="${walk%/*}" ;; *) walk="." ;; esac
        done
        case "$verdict" in
            ok:*) rustfmt_covering+="${verdict#ok:}"$'\n' ;;
            bad:*) rustfmt_uncovered="$seed/ (its nearest rustfmt config, in ${verdict#bad:}/, does not declare edition)"; break ;;
            *) rustfmt_uncovered="$seed/ (no rustfmt.toml / .rustfmt.toml in it or any ancestor)"; break ;;
        esac
    done <<<"$rustfmt_seeds"
    if [ -z "$rustfmt_uncovered" ]; then
        rustfmt_cov_list=$(sort -u <<<"$rustfmt_covering" | paste -sd, -)
        add rustfmt 1 "tracked Cargo.toml + nearest rustfmt config declares edition (config dir(s): $rustfmt_cov_list)"
    else
        add rustfmt 0 "rustfmt would format files in $rustfmt_uncovered as edition 2015; rustfmt uses only the nearest config, so that one must declare edition = \"<the crate's edition>\" (add it there, or create rustfmt.toml) to opt in"
        note "rustfmt: route skipped; files in $rustfmt_uncovered would be formatted as edition 2015. Bare rustfmt ignores Cargo.toml and uses only the nearest rustfmt.toml/.rustfmt.toml, so without a declared edition it fails to parse 2018+ files and reformats the rest wrongly; add edition = \"<the crate's edition>\" (matching Cargo.toml) to that nearest config and re-run"
    fi
fi
manifest_tool gofmt '(^|/)go\.mod$' go.mod
why=""; det=0
if has_tracked '\.sln$' || has_tracked '\.csproj$'; then
    det=1; why="tracked .sln/.csproj (SLOW per-edit — opt-in only)"
else
    why="no .sln/.csproj"
fi
add dotnet_format "$det" "$why"

# --- existing generated hooks (refresh-mode signal) ---------------------------
existing="[]"
if ls .claude/hooks/sassydog-*.sh >/dev/null 2>&1; then
    existing=$(ls .claude/hooks/sassydog-*.sh | jq -Rn '[inputs]')
fi

# ------------------------------------------------------------------------------
tools=$(printf '%s' "$results" | jq -sc 'add // {}')
jq -n \
    --arg root "$ROOT" \
    --argjson tools "$tools" \
    --argjson existing "$existing" \
    --argjson fails "$(printf '%s\n' "${failures[@]+"${failures[@]}"}" | jq -Rn '[inputs | select(length > 0)]')" \
    '{repo_root: $root, tools: $tools, existing_generated_hooks: $existing, detect_failures: $fails}'
