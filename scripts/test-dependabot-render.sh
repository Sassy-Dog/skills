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
#      request is byte-identical to tailoredtip.golden.yml, the committed v5
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
#      Mutation proof for #501 (each mutant applied, this gate run, restored,
#      and the gate confirmed green again; killed by the named cases):
#        - drop the DAYS > 90 check in parse_cooldown_requests -> "cooldown
#          parity — 'bun=91'" and 'bun=999' (validator side), plus the
#          renderer's "render ACCEPTED the malformed request 'bun=91'".
#        - drop the repeated-ecosystem check there -> "cooldown parity — the
#          validator ACCEPTED a repeated ecosystem" (bun=7 + bun=14, each valid
#          alone so the days check cannot mask it), plus the renderer's case.
#        - make --change-cooldown unscoped (any acknowledgement covers every
#          ecosystem) -> "cooldown scoping — acknowledging bun alone passed
#          while pub also dropped its cooldown" (committed file with bun AND pub
#          cooldowns), plus "--change-cooldown bun also waved through ... pub".
#        - drop the refusal of an unused acknowledgement -> "--change-cooldown
#          was accepted where nothing changes" and "--change-cooldown pub was
#          accepted for an ecosystem with no committed cooldown".
#        - drop the usage error for --change-cooldown without --compare-to ->
#          "--change-cooldown was accepted with nothing to compare to".
#        - drop the ^[a-z][a-z-]*$ name check on --change-cooldown -> the
#          malformed-name cases 'Bun', 'bun=7' and '1bun' (exit 2 expected).
#
#   5. Every version-updates group is minor/patch only, github-actions'
#      `actions` group included (template v5). fetch-metadata reports a grouped
#      PR's HIGHEST update-type and the auto-merge template enqueues only an
#      explicit semver-minor/patch, so one Actions major in an unrestricted
#      group held the whole weekly group (velovate#2391, qr-ninja#914). Read off
#      EVERY fixture render, so a new ecosystem block inherits the rule, with a
#      vacuity guard that at least one github-actions group was actually read.
#      github-actions must also carry no `ignore:` (majors are proposed, just
#      not grouped) and its security group no `update-types`. The v3 -> v5
#      delta is pinned too: tailoredtip.v3.golden.yml holds the v3 bytes, and
#      its non-comment lines must differ from today's no-cooldown render by
#      exactly the one added `update-types` line, so "nothing else moved" is
#      checked rather than asserted in prose.
#      Mutation proof (each applied, this gate run, restored, green again):
#        - delete the actions group's `update-types` line from the template ->
#          "version-updates groups — ... github-actions/actions" plus the golden
#          and v3 -> v5 delta cases.
#        - widen it to ["major", "minor", "patch"] -> the same
#          version-updates-groups case (the match is exact, not a substring).
#        - add a semver-major `ignore:` to the github-actions block -> "the
#          github-actions entry carries an ignore:".
#
#   6. (issue #508) ignore: rules survive a re-render. what2wear's owned file
#      carries 11 hand-added Expo SDK / React holds on its bun lane, and a
#      re-render stripped them while --compare-to exited 0. Built from that
#      shape (what2wear-ignores.committed.yml, whose rule set is copied from the
#      real file): a plain re-render must FAIL --compare-to with one DIVERGED
#      line per dropped rule naming each of the 11; `--keep-ignores-from`
#      must carry all of them (comments included, the template's own "*" hold
#      not duplicated) and pass, and carrying again from that output is
#      byte-identical. A rule whose update-types merely narrowed counts as
#      dropped. A rule on a lane with no template ignore: (github-actions) is
#      carried under a new ignore: key. Refused, never partial: a flow-form
#      ignore:, a rule indented unlike the template, a rule whose lane the
#      render lacks, and a template whose ignore: is not its entry's last key.
#      Mutation proof (each applied, this gate run, restored, green again):
#        - drop the ignore comparison in validate-dependabot.sh (empty
#          dropped_ign) -> "ignore rules — a plain re-render passed --compare-to".
#        - key a rule by its dependency-name line alone (drop continuation
#          lines from the key in extract_ignore_rules) -> "ignore rules — a
#          rule whose update-types narrowed passed".
#        - make carry_ignores return the body unchanged -> "ignore rules —
#          --keep-ignores-from render failed --compare-to" and the 12-rule case.
#        - skip carry_ignores' filter of rules the body already renders ->
#          "ignore rules — the template's own "*" hold appears 2 times".
#        - drop the renderer's end-of-render check for rules no lane received
#          -> "ignore rules — a rule for a lane the render lacks was accepted".
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
rendered_names=""
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
    rendered_names+="$name"$'\n'

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
# golden bytes, so a consumer who never asks moves nothing on re-render. The
# golden holds the v5 render (the github-actions group made minor/patch only);
# tailoredtip.v3.golden.yml keeps the v3 bytes the pre-#498 renderer and
# template produced at 69f9176, and section 5 pins the v3 -> v5 delta.
GOLDEN="$FIXTURES/tailoredtip.golden.yml"
TT_TREE="$WORK/tailoredtip/tree"
TT_FILES="$WORK/tailoredtip.files"
TT_DETECT="$WORK/tailoredtip.detect.json"
CD="$WORK/tailoredtip.cd.yml"
if [ ! -r "$GOLDEN" ] || [ ! -r "$TT_DETECT" ]; then
    bad "cooldown — missing $GOLDEN or the tailoredtip detect report; the cooldown cases did not run"
else
    if cmp -s "$GOLDEN" "$WORK/tailoredtip.yml"; then
        ok "cooldown — no request renders byte-identical to the committed golden bytes (template-version 5)"
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
    if grep -q 'template-version: 6$' "$CD"; then
        ok "cooldown — a cooldown render stamps template-version 6"
    else
        bad "cooldown — a cooldown render does not stamp template-version 6"
    fi
    if grep -q 'template-version: 5$' "$WORK/tailoredtip.yml"; then
        ok "cooldown — a render with no cooldown stamps template-version 5"
    else
        bad "cooldown — a render with no cooldown does not stamp template-version 5"
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
        bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown "$bad_req" >/dev/null 2>&1
        render_rc="$?"
        bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown "$bad_req" --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2>&1
        valid_rc="$?"
        if [ "$render_rc" = "1" ] && [ "$valid_rc" = "2" ]; then
            ok "cooldown parity — the validator refuses '$bad_req' as the renderer does"
        else
            bad "cooldown parity — '$bad_req': the renderer exited $render_rc (want 1) or the validator exited $valid_rc (want 2)"
        fi
    done
    # Two individually VALID values (bun=99 would exit on the days check first
    # and never reach the repeat check).
    bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --cooldown bun=7 --cooldown bun=14 >/dev/null 2>&1
    render_rc="$?"
    bash "$SCRIPTS/validate-dependabot.sh" "$CD" --cooldown bun=7 --cooldown bun=14 --root "$TT_TREE" --files-from "$TT_FILES" >/dev/null 2>&1
    valid_rc="$?"
    if [ "$render_rc" = "1" ] && [ "$valid_rc" = "2" ]; then
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
    # Scoping, isolated: BOTH bun and pub carry a cooldown in the committed file
    # (cd.pub.yml is the bun render plus a hand-added pub block) and the render
    # drops both. Acknowledging bun alone must still fail on pub, with pub
    # named as DROPPED; acknowledging both passes. An unscoped acknowledgement
    # would wave pub through.
    if cmpd "$GOLDEN" --change-cooldown bun --compare-to "$WORK/cd.pub.yml"; then
        bad "cooldown scoping — acknowledging bun alone passed while pub also dropped its cooldown"
    elif grep -q 'DIVERGED: .*pub cooldown.*DROPPED' "$WORK/chg.err" && ! grep -q 'DIVERGED: .*bun cooldown' "$WORK/chg.err"; then
        ok "cooldown scoping — with bun and pub both dropped, acknowledging bun alone still fails on pub only"
    else
        bad "cooldown scoping — the run failed, but not on pub alone"
    fi
    if cmpd "$GOLDEN" --change-cooldown bun --change-cooldown pub --compare-to "$WORK/cd.pub.yml"; then
        ok "cooldown scoping — acknowledging both bun and pub passes when both dropped"
    else
        bad "cooldown scoping — acknowledging both dropped ecosystems was still rejected"
    fi
    for bad_name in "Bun" "bun=7" "1bun"; do
        cmpd "$GOLDEN" --change-cooldown "$bad_name" --compare-to "$CD"
        if [ "$?" = "2" ] && grep -q 'must be an ECOSYSTEM name' "$WORK/chg.err"; then
            ok "cooldown change — a malformed --change-cooldown name '$bad_name' is a usage error"
        else
            bad "cooldown change — a malformed --change-cooldown name '$bad_name' was not refused as a usage error (exit 2)"
        fi
    done
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

# --- 5. every version-updates group is minor/patch only (template v5) -------
# vu_groups FILE — one line per group under an entry's `groups:`, as
# "<RESTRICTED|UNRESTRICTED|SECURITY-RESTRICTED|security><TAB>ecosystem/group".
# A group with no `applies-to` covers version updates (Dependabot's default),
# so only an explicit `applies-to: security-updates` exempts one. The
# restriction must be exactly ["minor", "patch"]: a widened list fails.
vu_groups() {
    awk '
    function flush() {
        if (g != "") {
            if (sec) print (mp ? "SECURITY-RESTRICTED" : "security") "\t" eco "/" g
            else     print (mp ? "RESTRICTED" : "UNRESTRICTED") "\t" eco "/" g
        }
        g = ""; sec = 0; mp = 0
    }
    /^[[:space:]]*#/ { next }
    /^  - package-ecosystem:/ {
        flush(); eco = $0
        sub(/.*package-ecosystem:[[:space:]]*/, "", eco); gsub(/"/, "", eco)
        ingroups = 0; next
    }
    /^    groups:[[:space:]]*$/ { flush(); ingroups = 1; next }
    /^    [^ ]/ { flush(); ingroups = 0; next }
    ingroups && /^      [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); g = $1; sub(/:$/, "", g); next }
    ingroups && /^        applies-to:[[:space:]]*security-updates[[:space:]]*$/ { sec = 1; next }
    ingroups && /^        update-types:[[:space:]]*\[[[:space:]]*"minor",[[:space:]]*"patch"[[:space:]]*\][[:space:]]*$/ { mp = 1; next }
    END { flush() }
    ' "$1"
}

vu_checked=0
actions_checked=0
vu_bad=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    groups_out="$(vu_groups "$WORK/$name.yml")"
    vu_checked=$((vu_checked + $(grep -cE '^(RESTRICTED|UNRESTRICTED)' <<<"$groups_out")))
    actions_checked=$((actions_checked + $(grep -cE $'^(RESTRICTED|UNRESTRICTED)\tgithub-actions/' <<<"$groups_out")))
    while IFS=$'\t' read -r verdict grp; do
        case "$verdict" in
            UNRESTRICTED) vu_bad+="$name: $grp (version updates, no update-types [\"minor\", \"patch\"])"$'\n' ;;
            SECURITY-RESTRICTED) vu_bad+="$name: $grp (a security group restricted to minor/patch would drop security majors)"$'\n' ;;
        esac
    done <<<"$groups_out"
done <<<"$rendered_names"
if [ "$vu_checked" -eq 0 ] || [ "$actions_checked" -eq 0 ]; then
    bad "version-updates groups — read $vu_checked group(s), $actions_checked github-actions; nothing to check means the rule is unproven"
elif [ -n "$vu_bad" ]; then
    bad "version-updates groups — majors would ride in (and hold) these groups:"
    printf '%s' "$vu_bad" | sed 's/^/        /' >&2
else
    ok "version-updates groups — all $vu_checked are minor/patch only ($actions_checked github-actions), security groups unrestricted"
fi

# github-actions proposes majors as their own PRs: an `ignore:` would stop
# them being proposed at all, which is not the fix.
actions_ignore=""
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if awk '/^[[:space:]]*#/ { next }
            /^  - package-ecosystem:/ { a = ($0 ~ /"github-actions"/); next }
            a && /^    ignore:/ { found = 1 }
            END { exit !found }' "$WORK/$name.yml"; then
        actions_ignore+="$name "
    fi
done <<<"$rendered_names"
if [ -n "$actions_ignore" ]; then
    bad "version-updates groups — the github-actions entry carries an ignore: in $actions_ignore(majors must still be proposed, just not grouped)"
else
    ok "version-updates groups — no github-actions entry carries an ignore:, so majors are still proposed"
fi

# The v3 -> v5 delta: comments aside, exactly one added line, and it is the
# actions group's restriction. Anything else moving is an undocumented change.
V3_GOLDEN="$FIXTURES/tailoredtip.v3.golden.yml"
if [ ! -r "$V3_GOLDEN" ] || [ ! -r "$WORK/tailoredtip.yml" ]; then
    bad "v3 -> v5 delta — missing $V3_GOLDEN or the tailoredtip render; the case did not run"
else
    delta="$(diff <(grep -v '^[[:space:]]*#' "$V3_GOLDEN") <(grep -v '^[[:space:]]*#' "$WORK/tailoredtip.yml") | grep -E '^[<>]')"
    # One added line, and the group it landed in is the actions group: the
    # only group whose verdict moved from UNRESTRICTED (v3) to RESTRICTED.
    moved="$(diff <(vu_groups "$V3_GOLDEN") <(vu_groups "$WORK/tailoredtip.yml") | grep -E '^[<>]')"
    if [ "$delta" = '>         update-types: ["minor", "patch"]' ] \
        && [ "$moved" = $'< UNRESTRICTED\tgithub-actions/actions\n> RESTRICTED\tgithub-actions/actions' ]; then
        ok "v3 -> v5 delta — the only non-comment change is the actions group's update-types line"
    else
        bad "v3 -> v5 delta — the non-comment diff against $V3_GOLDEN is not exactly the one update-types line:"
        printf '%s\n' "$delta" | sed 's/^/        /' >&2
    fi
fi

# --- 6. ignore: rules survive a re-render (issue #508) -----------------------
IGN_COMMITTED="$FIXTURES/what2wear-ignores.committed.yml"
W_TREE="$WORK/what2wear/tree"
W_FILES="$WORK/what2wear.files"
W_DETECT="$WORK/what2wear.detect.json"
W_PLAIN="$WORK/what2wear.yml"
W_KEPT="$WORK/what2wear.kept.yml"
HOLDS='react-native react-native-* @react-native/* react react-dom react-test-renderer @sentry/react-native expo expo-* @expo/* jest-expo'
if [ ! -r "$IGN_COMMITTED" ] || [ ! -r "$W_DETECT" ] || [ ! -r "$W_PLAIN" ]; then
    bad "ignore rules — missing $IGN_COMMITTED or the what2wear render; the cases did not run"
else
    # shellcheck source=../skills/setup-deps/scripts/lib-ecosystems.sh
    . "$SCRIPTS/lib-ecosystems.sh"
    rules_of() { extract_ignore_rules "$1" | cut -f1,2,4 | sort -u; }
    wval() { bash "$SCRIPTS/validate-dependabot.sh" "$@" --root "$W_TREE" --files-from "$W_FILES" >/dev/null 2> "$WORK/ign.err"; }

    n_committed="$(rules_of "$IGN_COMMITTED" | grep -c .)"
    if [ "$n_committed" = "12" ]; then
        ok "ignore rules — the what2wear-shape fixture declares 12 rules (the template hold + 11)"
    else
        bad "ignore rules — the fixture declares $n_committed rules, not 12; the cases below would prove less than they claim"
    fi

    # a. the original failure: a plain re-render strips the 11 holds.
    if wval "$W_PLAIN" --compare-to "$IGN_COMMITTED"; then
        bad "ignore rules — a plain re-render passed --compare-to while dropping the 11 holds (the #508 failure)"
    else
        n_div="$(grep -c 'DIVERGED: .* ignore rule' "$WORK/ign.err")"
        missing=""
        for h in $HOLDS; do
            grep -qF "ignore rule (dependency-name:$h)" "$WORK/ign.err" \
                || grep -qF "ignore rule (dependency-name:$h;" "$WORK/ign.err" || missing+="$h "
        done
        if [ "$n_div" = "11" ] && [ -z "$missing" ]; then
            ok "ignore rules — a plain re-render fails --compare-to with 11 DIVERGED lines, one per hold, each named"
        else
            bad "ignore rules — a plain re-render failed, but with $n_div DIVERGED ignore lines (want 11); unnamed: ${missing:-none}"
        fi
    fi

    # b. --keep-ignores-from carries every rule, comments included, once.
    if ! bash "$SCRIPTS/render-dependabot.sh" --detect-json "$W_DETECT" --keep-ignores-from "$IGN_COMMITTED" \
        > "$W_KEPT" 2> "$WORK/ign.render.err"; then
        bad "ignore rules — --keep-ignores-from render failed: $(tail -n1 "$WORK/ign.render.err")"
    else
        if wval "$W_KEPT" --compare-to "$IGN_COMMITTED"; then
            ok "ignore rules — the --keep-ignores-from render passes --compare-to"
        else
            bad "ignore rules — --keep-ignores-from render failed --compare-to:"; grep FAIL "$WORK/ign.err" | sed 's/^/        /' >&2
        fi
        if diff <(rules_of "$IGN_COMMITTED") <(rules_of "$W_KEPT") >/dev/null; then
            ok "ignore rules — the carried render declares exactly the committed 12 rules"
        else
            bad "ignore rules — the carried render's rules differ from the committed 12"
        fi
        stars="$(grep -c '^      - dependency-name: "\*"$' "$W_KEPT")"
        if [ "$stars" = "1" ]; then
            ok "ignore rules — the template's own \"*\" hold is not duplicated by the carry"
        else
            bad "ignore rules — the template's own \"*\" hold appears $stars times"
        fi
        if grep -q 'EXPO SDK PINS' "$W_KEPT" && grep -q 'The Expo major IS the SDK version' "$W_KEPT"; then
            ok "ignore rules — a carried rule keeps the comments above it"
        else
            bad "ignore rules — the carried rules lost their comments"
        fi
        bash "$SCRIPTS/render-dependabot.sh" --detect-json "$W_DETECT" --keep-ignores-from "$W_KEPT" > "$WORK/w.kept2.yml" 2>/dev/null
        if cmp -s "$W_KEPT" "$WORK/w.kept2.yml"; then
            ok "ignore rules — carrying again from the carried render is byte-identical"
        else
            bad "ignore rules — carrying from the carried render changed it (not idempotent)"
        fi

        # d. identity includes update-types: narrowing one is a dropped rule.
        sed 's/\["version-update:semver-minor", "version-update:semver-major"\]/["version-update:semver-major"]/' \
            "$W_KEPT" > "$WORK/w.narrowed.yml"
        if cmp -s "$W_KEPT" "$WORK/w.narrowed.yml"; then
            bad "ignore rules — the narrowing edit matched nothing; the case proves nothing"
        elif wval "$WORK/w.narrowed.yml" --compare-to "$IGN_COMMITTED"; then
            bad "ignore rules — a rule whose update-types narrowed passed --compare-to"
        elif grep -q 'DIVERGED: .*ignore rule (dependency-name:@sentry/react-native;update-types:\[version-update:semver-minor' "$WORK/ign.err"; then
            ok "ignore rules — narrowing a rule's update-types is reported as dropping that rule"
        else
            bad "ignore rules — the narrowed rule failed, but not as a DIVERGED @sentry/react-native rule"
        fi
    fi

    # h. a rule whose lane the render does not emit is refused, not dropped.
    sed 's#^    directory: "/"$#    directory: "/apps/mobile"#' "$IGN_COMMITTED" > "$WORK/w.otherlane.yml"
    if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$W_DETECT" --keep-ignores-from "$WORK/w.otherlane.yml" >/dev/null 2> "$WORK/ign.render.err"; then
        bad "ignore rules — a rule for a lane the render lacks was accepted (and dropped)"
    elif grep -q 'no bun ./apps/mobile. lane to carry it into' "$WORK/ign.render.err"; then
        ok "ignore rules — a rule for a lane the render lacks is refused"
    else
        bad "ignore rules — the lane-less rule was refused, but not with the no-lane message"
    fi

    # e/f/g. github-actions has no template ignore:, so a carried rule needs a
    # new key; a flow-form or differently indented one is refused.
    ga_ignore() {   # FILE BODY... — the tailoredtip golden with BODY after actions-security's patterns
        # ENVIRON, not -v: BSD awk rejects a newline inside a -v value.
        IGN_BODY="$2" awk '{ print } /^      actions-security:$/ { s = 1 } s && /^        patterns:/ { print ENVIRON["IGN_BODY"]; s = 0 }' "$GOLDEN" > "$1"
    }
    TT_DETECT="$WORK/tailoredtip.detect.json"
    ttval() { bash "$SCRIPTS/validate-dependabot.sh" "$@" --root "$WORK/tailoredtip/tree" --files-from "$WORK/tailoredtip.files" >/dev/null 2> "$WORK/ign.err"; }
    ga_ignore "$WORK/tt.ga.yml" $'    ignore:\n      - dependency-name: "actions/upload-artifact"\n        versions: [">= 5"]'
    ga_ignore "$WORK/tt.flow.yml" '    ignore: [{dependency-name: "actions/upload-artifact"}]'
    ga_ignore "$WORK/tt.indent.yml" $'    ignore:\n    - dependency-name: "actions/upload-artifact"'
    if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --keep-ignores-from "$WORK/tt.ga.yml" > "$WORK/tt.ga.out" 2>/dev/null \
        && ttval "$WORK/tt.ga.out" --compare-to "$WORK/tt.ga.yml" \
        && awk '/package-ecosystem: "github-actions"/ { a = 1; next } /package-ecosystem:/ { a = 0 } a && /^    ignore:$/ { f = 1 } END { exit !f }' "$WORK/tt.ga.out"; then
        ok "ignore rules — a github-actions rule is carried under a new ignore: key and passes --compare-to"
    else
        bad "ignore rules — a github-actions rule (no template ignore:) was not carried cleanly"
    fi
    if ttval "$WORK/tailoredtip.yml" --compare-to "$WORK/tt.flow.yml"; then
        bad "ignore rules — a flow-form ignore: in the committed file was dropped silently"
    elif grep -q 'DIVERGED: .*ignore rule (!unparsed:' "$WORK/ign.err"; then
        ok "ignore rules — a flow-form ignore: that a render drops is DIVERGED, not skipped"
    else
        bad "ignore rules — the flow-form case failed, but not as an unparsed DIVERGED rule"
    fi
    for v in flow indent; do
        if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$TT_DETECT" --keep-ignores-from "$WORK/tt.$v.yml" >/dev/null 2>&1; then
            bad "ignore rules — the renderer carried a $v ignore: it should refuse"
        else
            ok "ignore rules — the renderer refuses to carry a $v ignore:"
        fi
    done

    # i. appending only works while ignore: is the entry's last key.
    awk '{ print } /^        update-types: \["version-update:semver-major"\]$/ { print "    versioning-strategy: increase" }' \
        skills/setup-deps/references/templates/dependabot.yml.template > "$WORK/notlast.template"
    if bash "$SCRIPTS/render-dependabot.sh" --detect-json "$W_DETECT" --template "$WORK/notlast.template" \
        --keep-ignores-from "$IGN_COMMITTED" >/dev/null 2> "$WORK/ign.render.err"; then
        bad "ignore rules — rules were appended after a key that follows ignore: (they would land in the wrong key)"
    elif grep -q 'is not the last key' "$WORK/ign.render.err"; then
        ok "ignore rules — the carry refuses a template whose ignore: is not its entry's last key"
    else
        bad "ignore rules — the not-last template was refused, but not for that reason"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "dependabot-render tests: all green" >&2
    exit 0
fi
echo "dependabot-render tests: FAILURES above" >&2
exit 1
