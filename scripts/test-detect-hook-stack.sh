#!/usr/bin/env bash
# test-detect-hook-stack.sh — proves setup-hooks' tracked-file probe still
# answers correctly when the match list is LARGE (issue #172).
#
# Why this exists: the bug it guards inverts a boolean and reports nothing.
# `has_tracked` used to be `git ls-files "<glob>" | head -1 | grep -q .`, and
# under the script's `set -o pipefail` that returns 141 whenever the match list
# outruns the ~64KB pipe buffer — `head`/`grep -q` exit on the first line, the
# writer takes SIGPIPE, pipefail promotes the writer's status. A MATCH reads as
# a MISS, so the rendered hook silently drops that tool's route. It is
# size-dependent: every small repo, and every small fixture, passes either way.
# That is the whole reason the fixture here is 20k paths and not 20 — a small
# fixture would prove nothing, which is why property 1 below fails loudly if the
# fixture ever stops being big enough to trip the old shape.
#
# Six properties are asserted (the sixth, rustfmt needing a declared edition, is
# issue #569; it carries its own mutant, built by deleting the requirement):
#
#   1. The big fixture IS big enough: the PRE-FIX shape, transcribed here,
#      returns non-zero on it despite thousands of matches. If that shape ever
#      starts succeeding, this test is no longer testing anything and says so.
#   2. The SHIPPED has_tracked — extracted from detect-hook-stack.sh, not
#      transcribed — returns 0 on that same corpus, for every extension the
#      five affected detections probe.
#   3. End to end, the shipped detector run inside the big fixture reports
#      markdownlint / shellcheck / dotnet_format as DETECTED. Before the fix all
#      three came back false on this exact fixture.
#   4. No behaviour change in the common case: on a small fixture, where the old
#      shape was never wrong, the shipped detector's verdicts are unchanged.
#   5. Source-level shape guard: the shipped has_tracked contains no `head` and
#      no pipeline. Property 1 depends on a measured buffer size; this one holds
#      even if a future platform's pipe never blocks.
#
# Fixtures are built in a temp dir from a git index only (no working-tree
# files), which is why 20k paths costs ~100ms. Nothing here touches a real repo,
# the network, or the checkout it runs from.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-detect-hook-stack.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-detect-hook-stack: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

command -v jq >/dev/null 2>&1 || { echo "test-detect-hook-stack: jq not on PATH" >&2; exit 1; }

DETECT="skills/setup-hooks/scripts/detect-hook-stack.sh"
[ -f "$DETECT" ] || { echo "test-detect-hook-stack: $DETECT not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "detect-hook-stack tests (work: $WORK)" >&2

# The pre-fix shape, kept verbatim so the fixture's adequacy is checked against
# the real thing rather than an approximation of it. Must NOT be reintroduced
# into detect-hook-stack.sh — property 5 enforces that.
has_tracked_prefix_shape() { git ls-files "$1" | head -1 | grep -q .; }

# The shipped one, EXTRACTED rather than transcribed: a test carrying its own
# copy of the fix would keep passing after the fix was reverted.
shipped_def="$(grep -c '^has_tracked()' "$DETECT")"
if [ "$shipped_def" != "1" ]; then
    bad "expected exactly one one-line 'has_tracked()' definition in $DETECT, found $shipped_def — this test extracts it; update the extractor"
    echo "detect-hook-stack tests: FAILED" >&2
    exit 1
fi
eval "$(grep '^has_tracked()' "$DETECT")"

# --- fixture builders ---------------------------------------------------------
# Index-only repos: git ls-files reads the index, so no working-tree file has to
# exist for a path to be "tracked". 20k entries build in ~100ms this way.
mkrepo() { # <dir>
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email test@example.invalid
    git -C "$1" config user.name test
    git -C "$1" hash-object -w --stdin <<<"x"
}

addpaths() { # <dir> <blob> <n> <path-printf-fmt>
    seq 1 "$3" | awk -v b="$2" -v fmt="$4" '{printf "100644 %s\t" fmt "\n", b, int($1/100), $1}' \
        | git -C "$1" update-index --index-info
}

BIG="$WORK/big"
blob="$(mkrepo "$BIG")"
addpaths "$BIG" "$blob" 8000 'docs/pkg%d/note-%06d-a-realistically-long-name.md'
addpaths "$BIG" "$blob" 8000 'scripts/pkg%d/tool-%06d-a-realistically-long-name.sh'
addpaths "$BIG" "$blob" 4000 'src/pkg%d/Proj-%06d-a-realistically-long-name.csproj'
printf '100644 %s\t.markdownlint-cli2.jsonc\n' "$blob" | git -C "$BIG" update-index --index-info
: > "$BIG/.markdownlint-cli2.jsonc"   # markdownlint needs the config ON DISK too

SMALL="$WORK/small"
blob="$(mkrepo "$SMALL")"
addpaths "$SMALL" "$blob" 3 'docs/pkg%d/note-%d.md'
addpaths "$SMALL" "$blob" 3 'scripts/pkg%d/tool-%d.sh'
printf '100644 %s\t.markdownlint-cli2.jsonc\n' "$blob" | git -C "$SMALL" update-index --index-info
: > "$SMALL/.markdownlint-cli2.jsonc"

big_paths=$(git -C "$BIG" ls-files | wc -l | tr -d ' ')
big_md_bytes=$(git -C "$BIG" ls-files '*.md' | wc -c | tr -d ' ')
echo "  big fixture: $big_paths tracked paths, *.md match list $big_md_bytes bytes" >&2

# --- 1. the fixture is big enough to trip the pre-fix shape --------------------
for glob in '*.md' '*.sh' '*.csproj'; do
    ( cd "$BIG" && has_tracked_prefix_shape "$glob" )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "fixture no longer proves the bug: the pre-fix shape returned 0 for '$glob' on a $big_paths-path repo. Grow the fixture past the pipe buffer, or this test is vacuous"
    else
        ok "pre-fix shape returns $rc (a match read as a miss) for '$glob' on $big_paths paths"
    fi
done

# --- 2. the shipped helper answers correctly on the same corpus ----------------
# has_tracked reads the ALL_TRACKED corpus, so build it the way the script does.
# shellcheck disable=SC2034  # read by the has_tracked eval'd in above
ALL_TRACKED="$(git -C "$BIG" ls-files)"
for re in '\.md$' '\.sh$' '\.csproj$'; do
    if has_tracked "$re"; then
        ok "shipped has_tracked '$re' -> 0 on $big_paths paths"
    else
        bad "shipped has_tracked '$re' returned non-zero despite thousands of matches (issue #172 regression)"
    fi
done
for re in '\.py$' '\.sln$'; do
    if has_tracked "$re"; then
        bad "shipped has_tracked '$re' -> 0 on a corpus with no such file"
    else
        ok "shipped has_tracked '$re' -> non-zero (correctly no match)"
    fi
done

# --- 3. end to end: the big repo's tools are detected --------------------------
verdicts() { # <repo-dir> -> {tool: bool}
    ( cd "$1" && bash "$REPO_ROOT/$DETECT" ) | jq -Sc '.tools | with_entries(.value |= .detected)'
}

big_out=$(verdicts "$BIG")
for tool in markdownlint shellcheck dotnet_format; do
    if [ "$(jq -r --arg t "$tool" '.[$t]' <<<"$big_out")" = "true" ]; then
        ok "detect-hook-stack: $tool detected on the big repo"
    else
        bad "detect-hook-stack: $tool NOT detected on a repo with thousands of matching tracked files — this is exactly issue #172 (all three returned false here before the fix)"
    fi
done
if [ "$(jq -r '.ruff' <<<"$big_out")" = "false" ]; then
    ok "detect-hook-stack: ruff correctly not detected (no *.py, no ruff config)"
else
    bad "detect-hook-stack: ruff detected on a repo with no Python"
fi

# --- 4. no behaviour change on a small repo -----------------------------------
# The pre-fix shape was never wrong here, so its answers are the expectation the
# fix must reproduce exactly.
small_out=$(verdicts "$SMALL")
for pair in 'markdownlint:*.md' 'shellcheck:*.sh' 'ruff:*.py' 'dotnet_format:*.sln'; do
    tool="${pair%%:*}"; glob="${pair##*:}"
    ( cd "$SMALL" && has_tracked_prefix_shape "$glob" ) && expected=true || expected=false
    got="$(jq -r --arg t "$tool" '.[$t]' <<<"$small_out")"
    if [ "$got" = "$expected" ]; then
        ok "small repo: $tool = $got, unchanged from the pre-fix verdict"
    else
        bad "small repo: $tool = $got but the pre-fix shape said $expected for '$glob' — the fix changed behaviour in the common case"
    fi
done

# --- 5. source-level shape guard ----------------------------------------------
# Property 1 rests on a measured pipe-buffer size. This one does not: it fails
# the moment the trap shape reappears, on any platform.
def_line="$(grep '^has_tracked()' "$DETECT")"
if grep -qE '\|[[:space:]]*(head|grep|tail|sed)\b' <<<"$def_line"; then
    bad "has_tracked contains a pipeline: $def_line — under pipefail a reader that exits early makes the writer's SIGPIPE (141) the answer, so a match reads as a miss (issue #172). Match the corpus with a herestring instead"
else
    ok "has_tracked has no pipeline (SIGPIPE cannot decide its answer)"
fi

# --- 6. rustfmt needs a declared edition (issue #569) -------------------------
# Bare `rustfmt <file>` ignores Cargo.toml and formats as edition 2015, so the
# route renders only when a tracked rustfmt.toml/.rustfmt.toml declares
# `edition` in the crate's directory or an ancestor. Cases run the shipped
# detector inside real (working-tree + index) fixtures.
rustrepo() { # <name> -> dir; files are written by the caller then tracked
    local d="$WORK/rust-$1"
    mkdir -p "$d"
    git -C "$d" init -q
    printf '%s\n' "$d"
}
rust_track() { # <dir> -- track everything on disk
    git -C "$1" add -A >/dev/null 2>&1
}
rust_case() { # <name> <expected true|false> <reason-substring-or-empty> <detector-script>
    local d="$WORK/rust-$1" out det why notes
    out=$(cd "$d" && bash "$4")
    det=$(jq -r '.tools.rustfmt.detected' <<<"$out")
    why=$(jq -r '.tools.rustfmt.why' <<<"$out")
    notes=$(jq -r '.detect_failures | join("\n")' <<<"$out")
    if [ "$det" != "$2" ]; then
        bad "rustfmt/$1: detected=$det, expected $2 (why: $why)"; return
    fi
    if [ -n "$3" ]; then
        if grep -qF -- "$3" <<<"$why" && grep -qF -- "$3" <<<"$notes" && grep -qF 'edition = "' <<<"$notes"; then
            ok "rustfmt/$1: detected=$2, skip reason surfaced in why and detect_failures with the fix"
        else
            bad "rustfmt/$1: skipped but the reason/fix is not surfaced (why: $why | notes: $notes)"
        fi
    else
        ok "rustfmt/$1: detected=$2"
    fi
}

d=$(rustrepo declared); printf '[package]\nname="a"\n' >"$d/Cargo.toml"; printf 'edition = "2024"\n' >"$d/rustfmt.toml"; rust_track "$d"
d=$(rustrepo dotfile); printf '[package]\nname="a"\n' >"$d/Cargo.toml"; printf 'edition = "2021"\n' >"$d/.rustfmt.toml"; rust_track "$d"
d=$(rustrepo none); printf '[package]\nname="a"\n' >"$d/Cargo.toml"; rust_track "$d"
d=$(rustrepo noedition); printf '[package]\nname="a"\n' >"$d/Cargo.toml"; printf 'max_width = 100\nstyle_edition = "2024"\n# edition = "2024"\n' >"$d/rustfmt.toml"; rust_track "$d"
d=$(rustrepo ws-root); mkdir -p "$d/crates/a" "$d/crates/b"
printf '[workspace]\n' >"$d/Cargo.toml"; printf '[package]\nname="a"\n' >"$d/crates/a/Cargo.toml"; printf '[package]\nname="b"\n' >"$d/crates/b/Cargo.toml"
printf 'edition = "2024"\n' >"$d/rustfmt.toml"; rust_track "$d"
d=$(rustrepo ws-partial); mkdir -p "$d/crates/a" "$d/crates/b"
printf '[package]\nname="a"\n' >"$d/crates/a/Cargo.toml"; printf '[package]\nname="b"\n' >"$d/crates/b/Cargo.toml"
printf 'edition = "2024"\n' >"$d/crates/a/rustfmt.toml"; rust_track "$d"
d=$(rustrepo vendored-cfg); printf '[package]\nname="a"\n' >"$d/Cargo.toml"; mkdir -p "$d/examples"; printf 'edition = "2024"\n' >"$d/examples/rustfmt.toml"; rust_track "$d"

rust_matrix() { # <detector-script>
    rust_case declared true "" "$1"
    rust_case dotfile true "" "$1"
    rust_case none false "declaring edition" "$1"
    rust_case noedition false "declaring edition" "$1"
    rust_case ws-root true "" "$1"
    rust_case ws-partial false "crates/b/Cargo.toml" "$1"
    rust_case vendored-cfg false "declaring edition" "$1"
}
rust_matrix "$REPO_ROOT/$DETECT"

# Mutation: neuter the edition requirement (any tracked Cargo.toml detects, the
# old behaviour). The matrix MUST fail against it, or it asserts nothing.
MUT="$WORK/detect-mutant.sh"
awk '/^rustfmt_cargo=/ {print "manifest_tool rustfmt \x27(^|/)Cargo\\.toml$\x27 Cargo.toml"; skip=1; next}
     skip && /^fi$/ {skip=0; next}
     !skip {print}' "$REPO_ROOT/$DETECT" >"$MUT"
if bash -n "$MUT" && ! diff -q "$MUT" "$REPO_ROOT/$DETECT" >/dev/null; then
    mut_fail=$( { rust_matrix "$MUT"; } 2>&1 | grep -c 'FAIL' )
    if [ "$mut_fail" -gt 0 ]; then
        ok "rustfmt mutant (edition requirement removed) is caught by $mut_fail assertion(s)"
    else
        bad "rustfmt mutant (edition requirement removed) passed the matrix: the new assertions are vacuous"
    fi
else
    bad "rustfmt mutant could not be built (anchor 'rustfmt_cargo=' moved?)"
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "detect-hook-stack tests: all green" >&2
    exit 0
else
    echo "detect-hook-stack tests: FAILURES above" >&2
    exit 1
fi
