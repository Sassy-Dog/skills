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
#      bun-object (the {"packages": [...]} form), bun-empty-alt (an empty brace
#      alternative is untranslatable, not silently dropped), bun-bare-doublestar /
#      bun-doublestar-prefix / bun-doublestar-suffix (`a**b`, `x**/y`, `x/**y`
#      are untranslatable: `**` must be a whole segment), bun-trailing-globstar (a positive `packages/**`
#      does not name packages itself), bun-question (`?` is one non-/ char),
#      bun-dot (`.` is literal), bun-negclass (`[!a]` never matches `/`),
#      bun-subroot (a workspace root
#      other than /) and bun-badjson (an invalid root package.json is a
#      detect_failures entry). Added for issue #475, one each: bun-grep-compile
#      (`!packages/[z-a]` is a descending range every grep rejects with exit 2,
#      which the membership test would read as "no match": it pins the exit-2
#      check in bun_dirs under any grep and any locale, replacing an inline
#      probe that GNU grep, i.e. CI, always skipped) and bun-class-straddle
#      (`pkg[.-0]b` has a range whose ends straddle `/`, so the ERE would fold
#      /pkg/b; `_glob_frag` refuses a class range unless both ends lie in one
#      of 0-9, a-z or A-Z). A fixture's `# fixture-expect-failure: <text>`
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
#   4. (issue #498) The optional per-ecosystem cooldown. A render with no
#      request is byte-identical to tailoredtip.golden.yml, the pre-cooldown
#      bytes (the load-bearing "re-render moves nothing" property); `--cooldown
#      bun=7` lands on every bun lane and nowhere else and leaves every other
#      non-comment line (security groups included) alone; bad days, a repeated
#      ecosystem and an ecosystem with no lane are refused; and the validator
#      accepts exactly the requested cooldown while rejecting an unrequested,
#      missing, mismatched, one-lane-only, extra-key, flow-form or bare one,
#      with --compare-to reporting a cooldown a re-render would strip.
#      (issue #501) The validator refuses the same requests the renderer does
#      (DAYS > 90, a repeated ecosystem): both call the one parser in
#      lib-ecosystems.sh. A deliberate change or removal is acknowledged per
#      ecosystem with `--change-cooldown`, reported as CHANGED or DROPPED, and
#      the acknowledgement is refused where it is a no-op, so a forgotten
#      --cooldown still fails closed.
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

# --- cooldown (issue #498) ----------------------------------------------------
# AC4 is byte-level: a render with NO cooldown request must equal the committed
# pre-#498 bytes, so a consumer who never asks moves nothing on re-render. The
# golden was produced by the pre-#498 renderer and template at 69f9176.
GOLDEN="$FIXTURES/tailoredtip.golden.yml"
TT_TREE="$WORK/tailoredtip/tree"
TT_FILES="$WORK/tailoredtip.files"
TT_DETECT="$WORK/tailoredtip.detect.json"
CD="$WORK/tailoredtip.cd.yml"
if [ ! -r "$GOLDEN" ] || [ ! -r "$TT_DETECT" ]; then
    bad "cooldown — missing $GOLDEN or the tailoredtip detect report; the cooldown cases did not run"
else
    if cmp -s "$GOLDEN" "$WORK/tailoredtip.yml"; then
        ok "cooldown — no request renders byte-identical to the committed pre-cooldown bytes (template-version 3)"
    else
        bad "cooldown — a render with no cooldown request differs from $GOLDEN:"
        diff -u "$GOLDEN" "$WORK/tailoredtip.yml" | sed 's/^/        /' >&2
    fi

    bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown bun=7 > "$CD" 2> "$WORK/cd.err"
    bun_lanes="$(grep -c 'package-ecosystem: "bun"' "$CD")"
    if [ "$(grep -c '^      default-days: 7$' "$CD")" = "$bun_lanes" ] && [ "$bun_lanes" -ge 2 ] \
        && [ "$(grep -c '^    cooldown:$' "$CD")" = "$bun_lanes" ]; then
        ok "cooldown — bun=7 lands on every bun lane ($bun_lanes) and on nothing else"
    else
        bad "cooldown — bun=7 did not render exactly once per bun lane ($bun_lanes lanes)"
    fi
    if grep -q 'template-version: 4$' "$CD"; then
        ok "cooldown — a cooldown render stamps template-version 4"
    else
        bad "cooldown — a cooldown render does not stamp template-version 4"
    fi
    # Everything that is not a comment or the cooldown block is untouched: the
    # lanes, groups (security ones included), schedules and majors ignores.
    strip() { grep -v '^#' "$1" | grep -vE '^    cooldown:$|^      default-days: [0-9]+$'; }
    if diff <(strip "$GOLDEN") <(strip "$CD") >/dev/null; then
        ok "cooldown — every non-comment line outside the cooldown block (security groups included) is unchanged"
    else
        bad "cooldown — a cooldown render changed something beyond the cooldown block"
    fi

    # Refusals: the request is validated, never silently dropped.
    for bad_req in "bun=0" "bun=91" "bun=7x" "Bun=7" "bun" "bun=-1"; do
        if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown "$bad_req" >/dev/null 2>&1; then
            bad "cooldown — render ACCEPTED the malformed request '$bad_req'"
        else
            ok "cooldown — render refuses '$bad_req'"
        fi
    done
    if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown cargo=7 >/dev/null 2>&1; then
        bad "cooldown — render ACCEPTED a cooldown for cargo, which has no lane here (silently dropped)"
    else
        ok "cooldown — render refuses a cooldown for an ecosystem with no lane"
    fi
    if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown bun=7 --cooldown bun=8 >/dev/null 2>&1; then
        bad "cooldown — render ACCEPTED two requests for bun"
    else
        ok "cooldown — render refuses a repeated ecosystem"
    fi

    vd() { bash "$SCRIPTS/validate-dependabot.sh" "$@" --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2> "$WORK/vd.err"; }

    if vd "$CD" --cooldown bun=7; then
        ok "cooldown — the validator passes the render when the request is passed"
    else
        bad "cooldown — the validator rejected its own cooldown render:"; grep FAIL "$WORK/vd.err" | sed 's/^/        /' >&2
    fi
    if vd "$CD"; then
        bad "cooldown — the validator ACCEPTED a cooldown nobody requested (a hand-added cooldown in an owned file)"
    else
        ok "cooldown — the validator fails a cooldown that was not requested"
    fi
    if vd "$GOLDEN" --cooldown bun=7; then
        bad "cooldown — the validator ACCEPTED a render missing a requested cooldown"
    else
        ok "cooldown — the validator fails a requested cooldown that is absent"
    fi
    if vd "$CD" --cooldown bun=14; then
        bad "cooldown — the validator ACCEPTED a cooldown whose days differ from the request"
    else
        ok "cooldown — the validator fails a cooldown whose days differ from the request"
    fi
    if vd "$CD" --cooldown bun=7 --cooldown pub=3; then
        bad "cooldown — the validator ACCEPTED a request for pub, which carries no cooldown"
    else
        ok "cooldown — the validator fails a request the file does not carry"
    fi

    # Hand-edits to an otherwise valid cooldown render, each of which must fail.
    # 1: cooldown dropped from ONE bun lane only (the second occurrence).
    awk '/^    cooldown:$/ { n++; if (n == 2) { getline; next } } { print }' "$CD" > "$WORK/cd.onelane.yml"
    # 2: an extra, unsupported key.
    awk '{ print } /^      default-days: 7$/ && !d { print "      semver-major-days: 30"; d=1 }' "$CD" > "$WORK/cd.extrakey.yml"
    # 3: a cooldown hand-added on a non-bun lane (the pub entry's schedule).
    awk '{ print } /package-ecosystem: "pub"/ { p=1 } p && /open-pull-requests-limit/ { print "    cooldown:"; print "      default-days: 7"; p=0 }' "$CD" > "$WORK/cd.pub.yml"
    # 4: the flow form, and a bare key.
    sed -E 's/^    cooldown:$/    cooldown: {default-days: 7, include: ["a"]}/; /^      default-days: 7$/d' "$CD" > "$WORK/cd.flow.yml"
    sed -E '/^      default-days: 7$/d' "$CD" > "$WORK/cd.bare.yml"
    for variant in onelane extrakey pub flow bare; do
        if vd "$WORK/cd.$variant.yml" --cooldown bun=7; then
            bad "cooldown — the validator ACCEPTED the hand-edited '$variant' variant"
        else
            ok "cooldown — the validator rejects the hand-edited '$variant' variant"
        fi
    done

    # A bare `cooldown:` with no keys is still a cooldown: unrequested, it fails.
    if vd "$WORK/cd.bare.yml"; then
        bad "cooldown — the validator ACCEPTED a bare 'cooldown:' nobody requested (read as no cooldown)"
    else
        ok "cooldown — the validator fails a bare 'cooldown:' that was not requested"
    fi

    # --compare-to: a cooldown the existing owned file carries that the fresh
    # render lacks is DIVERGED; a render that merely ADDS one is not.
    if bash "$SCRIPTS/validate-dependabot.sh" "$GOLDEN" --root "$TT_TREE" --files-from "$TT_FILES" \
        --compare-to "$CD" >/dev/null 2> "$WORK/cmp.err"; then
        bad "cooldown — --compare-to ACCEPTED a re-render that silently strips the existing cooldown"
    elif grep -q 'DIVERGED: .* cooldown' "$WORK/cmp.err"; then
        ok "cooldown — --compare-to reports DIVERGED when a re-render would strip an existing cooldown"
    else
        bad "cooldown — --compare-to failed, but not with a cooldown DIVERGED line"
    fi
    if bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown bun=7 --root "$TT_TREE" --files-from "$TT_FILES" \
        --compare-to "$CD" >/dev/null 2>&1; then
        ok "cooldown — --compare-to passes when the same request is re-rendered"
    else
        bad "cooldown — --compare-to rejected a re-render with the same request"
    fi
    if bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown bun=7 --root "$TT_TREE" --files-from "$TT_FILES" \
        --compare-to "$GOLDEN" >/dev/null 2>&1; then
        ok "cooldown — --compare-to lets a render ADD a cooldown to an existing file without one"
    else
        bad "cooldown — --compare-to rejected a render that only adds a cooldown"
    fi
    if bash "$SCRIPTS/validate-dependabot.sh" "$GOLDEN" --root "$TT_TREE" --files-from "$TT_FILES" \
        --compare-to "$WORK/cd.pub.yml" >/dev/null 2>&1; then
        bad "cooldown — --compare-to ACCEPTED a hand-added pub cooldown being stripped"
    else
        ok "cooldown — --compare-to reports a hand-added cooldown on a non-requested ecosystem"
    fi

    # --- parity (issue #501): the validator refuses what the renderer refuses.
    # Both call parse_cooldown_requests in lib-ecosystems.sh; each case below is
    # fed to BOTH scripts, and the validator must exit 2 (bad usage) exactly
    # where the renderer exits 1.
    for bad_req in "bun=91" "bun=999" "bun=0" "bun=7x" "Bun=7" "bun" "bun=-1"; do
        bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown "$bad_req" --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2>&1
        if [ "$?" = "2" ]; then
            ok "cooldown parity — the validator refuses '$bad_req' as the renderer does"
        else
            bad "cooldown parity — the validator ACCEPTED '$bad_req', which the renderer refuses"
        fi
    done
    bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown bun=7 --cooldown bun=99 --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2>&1
    if [ "$?" = "2" ]; then
        ok "cooldown parity — the validator refuses a repeated ecosystem as the renderer does"
    else
        bad "cooldown parity — the validator ACCEPTED a repeated ecosystem (first one wins), which the renderer refuses"
    fi
    bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown bun=90 --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2>&1
    if [ "$?" != "2" ]; then
        ok "cooldown parity — 90 days, the documented ceiling, is not refused by the validator"
    else
        bad "cooldown parity — the validator refused 90 days, the top of the 1..90 range"
    fi

    # --- change and removal (issue #501). The committed file is the only record
    # of the request, so a re-render that does not repeat it must fail closed
    # (a forgotten flag never strips a cooldown), while a deliberate change or
    # removal is acknowledged per ecosystem with --change-cooldown.
    CD14="$WORK/tailoredtip.cd14.yml"
    bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown bun=14 > "$CD14" 2>/dev/null
    cmpd() { bash "$SCRIPTS/validate-dependabot.sh" "$@" --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2> "$WORK/chg.err"; }

    if cmpd "$CD14" --cooldown bun=14 --compare-to "$CD"; then
        bad "cooldown change — an unacknowledged 7 -> 14 change passed --compare-to"
    elif grep -q 'DIVERGED: .*CHANGED' "$WORK/chg.err" && grep -q -- '--change-cooldown bun' "$WORK/chg.err"; then
        ok "cooldown change — an unacknowledged change fails as CHANGED and names --change-cooldown"
    else
        bad "cooldown change — the unacknowledged change failed, but not with a CHANGED line naming --change-cooldown"
    fi
    if cmpd "$CD14" --cooldown bun=14 --change-cooldown bun --compare-to "$CD"; then
        ok "cooldown change — a deliberate 7 -> 14 change passes with --change-cooldown bun"
    else
        bad "cooldown change — a deliberate change was still rejected:"; grep FAIL "$WORK/chg.err" | sed 's/^/        /' >&2
    fi
    if cmpd "$GOLDEN" --compare-to "$CD"; then
        bad "cooldown removal — a render that drops the cooldown passed --compare-to unacknowledged"
    elif grep -q 'DIVERGED: .*DROPPED' "$WORK/chg.err" && grep -q 'forgotten' "$WORK/chg.err"; then
        ok "cooldown removal — a dropped cooldown fails as DROPPED and names the forgotten flag as the likely cause"
    else
        bad "cooldown removal — the dropped cooldown failed, but not with a DROPPED line naming a forgotten flag"
    fi
    if cmpd "$GOLDEN" --change-cooldown bun --compare-to "$CD"; then
        ok "cooldown removal — a deliberate removal passes with --change-cooldown bun"
    else
        bad "cooldown removal — a deliberate removal was still rejected:"; grep FAIL "$WORK/chg.err" | sed 's/^/        /' >&2
    fi
    if cmpd "$GOLDEN" --change-cooldown bun --compare-to "$WORK/cd.pub.yml"; then
        bad "cooldown removal — --change-cooldown bun also waved through a DIFFERENT ecosystem's (pub) dropped cooldown"
    else
        ok "cooldown removal — the acknowledgement covers only the ecosystem it names"
    fi
    if cmpd "$CD" --cooldown bun=7 --change-cooldown bun --compare-to "$CD"; then
        bad "cooldown change — --change-cooldown was accepted where nothing changes (a no-op acknowledgement)"
    else
        ok "cooldown change — --change-cooldown is refused where the render reproduces the committed cooldown"
    fi
    if cmpd "$CD" --cooldown bun=7 --change-cooldown pub --compare-to "$GOLDEN"; then
        bad "cooldown change — --change-cooldown pub was accepted for an ecosystem with no committed cooldown"
    else
        ok "cooldown change — --change-cooldown is refused for an ecosystem with no committed cooldown"
    fi
    bash "$SCRIPTS/validate-dependabot.sh" "$GOLDEN" --change-cooldown bun --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2>&1
    if [ "$?" = "2" ]; then
        ok "cooldown change — --change-cooldown without --compare-to is a usage error"
    else
        bad "cooldown change — --change-cooldown was accepted with nothing to compare to"
    fi
    if cmpd "$CD" --compare-to "$CD" ; then
        bad "cooldown change — a forgotten --cooldown on a re-render of the same file passed"
    elif grep -q 'most likely --cooldown bun=DAYS was not passed' "$WORK/chg.err"; then
        ok "cooldown change — a forgotten flag on validate is blamed on the flag, not only on a hand-added cooldown"
    else
        bad "cooldown change — the forgotten-flag failure did not name the likely cause"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "dependabot-render tests: all green" >&2
    exit 0
fi
echo "dependabot-render tests: FAILURES above" >&2
exit 1
