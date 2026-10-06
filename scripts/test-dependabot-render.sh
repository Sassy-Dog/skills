#!/usr/bin/env bash
# test-dependabot-render.sh — proves setup-deps renders a dependabot.yml whose
# lanes point at the directories a real consumer repo actually has (issue #169).
#
# Why this exists: the bug it guards is INVISIBLE in the render. A v2 render was
# always valid YAML — every lane just said `directory: "/"`, where no manifest
# lived, and Dependabot answers that by doing nothing and reporting nothing. The
# repo whose config would have been regressed on the next refresh (tailoredtip:
# bun /web, bun /scripts, pub /app, gradle /app/android, all stamped with this
# generator's marker) is therefore the fixture that matters most, and its
# expected output is not transcribed here — it is EXTRACTED from the committed
# upstream file under scripts/fixtures/legacy-markers/, whose bytes
# test-ownership-matchers.sh independently pins to their source blob.
#
# Three properties are asserted:
#
#   1. The render's (ecosystem, directory) pairs match the fixture's recorded
#      expectation. Real consumer layouts: tailoredtip (Flutter + bun
#      monorepo), velovate (polyglot workspaces monorepo, a real ls-files),
#      devcanopy (two-workspace cargo repo). Reconstructed from issue #467's
#      recorded detect output, not fetched: what2wear (one root bun.lock, nine
#      members -> one lane at /). Synthetic, written for the bun collapse rule:
#      bun-ownlock (a member with its own bun.lock keeps its lane), bun-nows (a
#      root bun.lock without a top-level `workspaces` key), bun-lockb (a
#      bun.lockb-only workspace stays npm), npm-workspaces (npm never
#      collapses) and bun-nonmember (a package.json the globs do not name keeps
#      its lane). Added for issue #471, one boundary each: bun-lockb-member (a
#      member with only a bun.lockb keeps its lane), bun-nested (`apps/*` does
#      not name apps/web/nested), bun-exclude / bun-exclude-brace /
#      bun-exclude-first (`!` exclusions with `**`, with `{a,b}`, and listed
#      before the positive glob), bun-class (`[ab]`), bun-untranslatable (nested
#      braces: nothing under that root collapses, and a note is emitted),
#      bun-object (the {"packages": [...]} form), bun-subroot (a workspace root
#      other than /) and bun-badjson (an invalid root package.json is a
#      detect_failures entry). A fixture's `# fixture-expect-failure: <text>`
#      header asserts that substring appears in detect_failures; an unreadable
#      Cargo workspace manifest is checked inline, since a corpus cannot
#      express file modes.
#   2. validate-dependabot.sh passes on every render: each lane is backed by a
#      tracked manifest in the directory it names.
#   3. The pre-fix shape FAILS that validation. A "v2" render of the same repo
#      (every lane collapsed onto "/") is generated and fed to the validator,
#      which must reject it — otherwise the check that replaced "valid by
#      construction" is not actually checking anything.
#
# Fixtures: scripts/fixtures/dependabot-render/<repo>.corpus is the repo's
# tracked path list (with the handful of manifest bodies whose CONTENT decides
# the derivation), and <repo>.expected the lanes it must produce, with the
# deliberate differences from that repo's committed config recorded in its
# header.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-dependabot-render.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-dependabot-render: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

command -v jq >/dev/null 2>&1 || { echo "test-dependabot-render: jq not on PATH" >&2; exit 1; }

SCRIPTS="skills/setup-deps/scripts"
FIXTURES="scripts/fixtures/dependabot-render"
LEGACY="scripts/fixtures/legacy-markers"
DELIMITER='^# ---8<---'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "dependabot-render tests (work: $WORK)" >&2

# Assert the fixture set is non-empty FIRST: a glob that matched nothing would
# walk zero fixtures and report all-green while covering nothing.
corpora=$(git ls-files "$FIXTURES/*.corpus")
if [ -z "$corpora" ]; then
    bad "fixture set — no tracked *.corpus files under $FIXTURES (moved or renamed? the run would pass while covering nothing)"
    echo "dependabot-render tests: FAILURES above" >&2
    exit 1
fi

# body <file> — everything after the ---8<--- delimiter line.
body() {
    local d
    d=$(grep -n "$DELIMITER" "$1" | head -n1 | cut -d: -f1)
    [ -n "$d" ] || return 1
    tail -n +"$((d + 1))" "$1"
}

# materialize <corpus-body> <dir> — recreate the recorded tree: every path as a
# file, with content only where the fixture records it (Cargo.toml's
# [workspace] table is what tells a workspace root from a member).
materialize() {
    local src="$1" dest="$2" line path content
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path="${line%%$'\t'*}"
        content=""
        [ "$path" != "$line" ] && content="${line#*$'\t'}"
        mkdir -p "$dest/$(dirname "$path")"
        printf '%s\n' "$content" > "$dest/$path"
        printf '%s\n' "$path"
    done < "$src"
}

v2_rejected=0
v2_exempt=0
for corpus in $corpora; do
    name="$(basename "$corpus" .corpus)"
    expected="$FIXTURES/$name.expected"
    tree="$WORK/$name/tree"
    mkdir -p "$tree"

    if ! body "$corpus" > "$WORK/$name.body"; then
        bad "$name — corpus has no ---8<--- delimiter"
        continue
    fi
    materialize "$WORK/$name.body" "$tree" > "$WORK/$name.files"

    if [ ! -r "$expected" ]; then
        bad "$name — no committed $expected"
        continue
    fi

    if ! bash "$SCRIPTS/detect-ecosystems.sh" --files-from "$WORK/$name.files" --root "$tree" \
        > "$WORK/$name.detect.json" 2> "$WORK/$name.detect.err"; then
        bad "$name — detect-ecosystems.sh failed: $(tail -n1 "$WORK/$name.detect.err")"
        continue
    fi

    if ! bash "$SCRIPTS/render-dependabot.sh" --detect-json "$WORK/$name.detect.json" \
        > "$WORK/$name.yml" 2> "$WORK/$name.render.err"; then
        bad "$name — render-dependabot.sh failed: $(tail -n1 "$WORK/$name.render.err")"
        continue
    fi

    # 1. the lanes the render declares
    if ! bash "$SCRIPTS/validate-dependabot.sh" "$WORK/$name.yml" --pairs-only \
        > "$WORK/$name.pairs" 2>/dev/null; then
        bad "$name — could not extract lanes from the render"
        continue
    fi
    if diff -u <(body "$expected" | sort) <(sort "$WORK/$name.pairs") > "$WORK/$name.diff"; then
        ok "$name — render matches $expected ($(grep -c . "$WORK/$name.pairs") lanes)"
    else
        bad "$name — render does not match $expected:"
        sed 's/^/        /' "$WORK/$name.diff" >&2
    fi

    # 1b. a fixture may record a detect_failures substring it must produce
    #     (an unparsable root manifest, an untranslatable workspace glob).
    want_fail="$(sed -n 's/^# fixture-expect-failure: //p' "$expected" | head -n1)"
    if [ -n "$want_fail" ]; then
        if jq -e --arg w "$want_fail" '.detect_failures | map(select(contains($w))) | length > 0' \
            "$WORK/$name.detect.json" >/dev/null 2>&1; then
            ok "$name — detect_failures carries a '$want_fail' entry"
        else
            bad "$name — detect_failures has no '$want_fail' entry (CORPUS_NOTES lost in a subshell?)"
        fi
    fi

    # 2. every lane is backed by a manifest in the directory it names
    if bash "$SCRIPTS/validate-dependabot.sh" "$WORK/$name.yml" \
        --root "$tree" --files-from "$WORK/$name.files" > /dev/null 2> "$WORK/$name.val.err"; then
        ok "$name — every rendered lane is backed by a tracked manifest"
    else
        bad "$name — validate-dependabot.sh rejected the render:"
        grep 'FAIL' "$WORK/$name.val.err" | sed 's/^/        /' >&2
    fi

    # 3. the pre-fix shape must be REJECTED. Collapse every lane onto "/", the
    #    v2 render, and require the validator to catch it — a validator that
    #    passes this proves nothing about the renders above.
    sed -E 's#^( *directory: ")[^"]*(")#\1/\2#' "$WORK/$name.yml" > "$WORK/$name.v2.yml"
    if cmp -s "$WORK/$name.yml" "$WORK/$name.v2.yml"; then
        ok "$name — root-only repo: the v2 shape is the correct shape here, nothing to reject"
    elif grep -q '^# fixture-v2-valid:' "$expected"; then
        v2_exempt=$((v2_exempt + 1))
        # Opt-in, recorded in the fixture's own header: the root holds the
        # manifests, so a "/" lane IS backed (the own-lockfile bun fixture —
        # collapsing there only duplicates a lane, it does not point at
        # nothing). Rejection is still proven by the other fixtures.
        ok "$name — fixture declares the collapsed-to-\"/\" shape backed by root manifests; rejection is proven by the other fixtures"
    elif bash "$SCRIPTS/validate-dependabot.sh" "$WORK/$name.v2.yml" \
        --root "$tree" --files-from "$WORK/$name.files" >/dev/null 2>&1; then
        bad "$name — the validator ACCEPTED the collapsed-to-\"/\" v2 render; the post-render check is not checking anything"
    else
        v2_rejected=$((v2_rejected + 1))
        ok "$name — the collapsed-to-\"/\" v2 render is rejected"
    fi
done

# The opt-out above is a header any fixture can carry, so it must not be able to
# silence step 3 everywhere: at least one fixture's v2 render has to have been
# actually rejected, or the post-render validator is unproven.
if [ "$v2_rejected" -eq 0 ]; then
    bad "step 3 proved nothing — no fixture's collapsed-to-\"/\" v2 render was rejected ($v2_exempt exempted by fixture-v2-valid)"
else
    ok "step 3 is live — $v2_rejected fixture(s) had their v2 render rejected ($v2_exempt exempted)"
fi

# --- an unreadable Cargo workspace manifest reaches detect_failures ----------
# cargo_dirs appends to CORPUS_NOTES while detect-ecosystems.sh builds each
# ecosystem's directories; a `$(...)` subshell there once dropped every note.
# Skipped when the shell can read a mode-000 file anyway (running as root).
CR="$WORK/cargo-unreadable"
mkdir -p "$CR/crates/a"
printf '[workspace]\n' > "$CR/Cargo.toml"
printf '[package]\n' > "$CR/crates/a/Cargo.toml"
printf 'Cargo.toml\ncrates/a/Cargo.toml\n' > "$WORK/cargo-unreadable.files"
chmod 000 "$CR/Cargo.toml"
if [ -r "$CR/Cargo.toml" ]; then
    ok "cargo-unreadable — skipped: this user can read a mode-000 file"
elif bash "$SCRIPTS/detect-ecosystems.sh" --files-from "$WORK/cargo-unreadable.files" --root "$CR" 2>/dev/null \
    | jq -e '.detect_failures | map(select(contains("not readable"))) | length > 0' >/dev/null 2>&1; then
    ok "cargo-unreadable — an unreadable Cargo workspace manifest reaches detect_failures"
else
    bad "cargo-unreadable — no 'not readable' entry in detect_failures (CORPUS_NOTES lost in a subshell?)"
fi
chmod 600 "$CR/Cargo.toml"

# --- the regression case, against real committed bytes -----------------------
# tailoredtip is the repo a refresh would have regressed: marked owned, content
# diverged past what v2 could produce. Its expectation is EXTRACTED from the
# committed upstream copy of its dependabot.yml rather than transcribed, so
# this cannot pass by agreeing with a copy we wrote ourselves.
TT_FIXTURE="$LEGACY/tailoredtip-dependabot.fixture"
if [ -r "$TT_FIXTURE" ] && [ -r "$WORK/tailoredtip.pairs" ]; then
    body "$TT_FIXTURE" > "$WORK/tt-committed.yml"
    if bash "$SCRIPTS/validate-dependabot.sh" "$WORK/tt-committed.yml" --pairs-only \
        > "$WORK/tt-committed.pairs" 2>/dev/null; then
        if diff -u <(sort "$WORK/tt-committed.pairs") <(sort "$WORK/tailoredtip.pairs") > "$WORK/tt.diff"; then
            ok "tailoredtip — the render reproduces its COMMITTED lanes exactly (incl. both bun blocks)"
        else
            bad "tailoredtip — the render does not reproduce its committed lanes:"
            sed 's/^/        /' "$WORK/tt.diff" >&2
        fi
    else
        bad "tailoredtip — could not extract lanes from $TT_FIXTURE"
    fi
else
    bad "tailoredtip — missing $TT_FIXTURE or its render; the regression case did not run"
fi

if [ "$fail" -eq 0 ]; then
    echo "dependabot-render tests: all green" >&2
    exit 0
fi
echo "dependabot-render tests: FAILURES above" >&2
exit 1
