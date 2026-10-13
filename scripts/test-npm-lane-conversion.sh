#!/usr/bin/env bash
# test-npm-lane-conversion.sh — proves setup-deps' convert-npm-lanes.sh turns
# every `npm` Dependabot lane on a TEXT bun.lock into the native `bun` lane,
# folds workspace-member lanes into their root, and reports the workflows that
# conversion leaves stale (skills#509 rollout).
#
# Why this exists: Dependabot's npm_and_yarn updater refuses a directory with a
# bun.lock and no npm/yarn/pnpm lockfile (`misconfigured_tooling`), so such a
# lane fails every run and opens nothing. qr-ninja, francisco and velovate each
# kept one through a setup-deps run — their dependabot.yml files were
# hand-written, so the report-and-skip contract never read a lane — and were
# fixed by hand in qr-ninja#919, francisco#182 and velovate#2400. Those three
# repos are the fixtures that matter most: the pre-fix committed file of each
# (scripts/fixtures/npm-lane-conversion/<repo>.committed.yml, comments stripped,
# every key verbatim) must convert to exactly the lanes the hand fix landed
# (<repo>.expected, the merge commit's lanes).
#
# What it pins:
#   1. Real shapes. qr-ninja: CONVERTED npm '/' (all ignore rules kept, the
#      file changes by that one token), its owned bun.lock sync workflow
#      OBSOLETE, its hand-written auto-merge STALE because it gates on
#      npm_and_yarn and never names bun. francisco: two per-directory
#      CONVERTED lanes, no workflow finding. velovate: CONVERTED '/' plus three
#      COLLAPSED members, its hand-written sync OBSOLETE. Each output's lanes
#      equal the hand fix's, every ignore rule survives, and validate-dependabot
#      accepts every lane.
#   2. Boundaries. A bun.lockb-only workspace stays npm and its sync workflow
#      is not flagged (NO-OP, byte-identical). A member lane with no root lane
#      is retargeted to the root; a second member folds into it, carrying its
#      new ignore rule once and dropping a duplicate; the member's own comment
#      block goes with it. An npm member next to an existing bun root lane folds
#      into that lane, which gains an ignore: key for the carried rule. A nested
#      sync workflow (working-directory 'web') is OBSOLETE only when web/ holds a
#      text bun.lock. An auto-merge allowlist that names every ecosystem the
#      file has is not STALE.
#   3. Refusals, nothing written: an npm `directories:` list naming a covered
#      directory; a member rule indented unlike the root lane's; an npm entry
#      whose list item starts with a key other than package-ecosystem. Exit 2
#      when there is nothing to evaluate.
#   4. Idempotent: the converter on its own output is a NO-OP, byte-identical.
#   5. The owned-file path: an owned what2wear-shape file whose bun lane is
#      npm FAILS a plain --compare-to with the converter hint, and passes once
#      the converter's output is the --keep-ignores-from / --compare-to input.
#   6. The script's ownership regex equals the one SKILL.md documents.
#
# Mutation proof (each applied, this gate run, restored, green again):
#   - bun_cover_root returns nothing for members (membership test removed) ->
#     "velovate — lanes match" and the synthetic collapse cases.
#   - the OBSOLETE branch removed -> "qr-ninja — OBSOLETE" and "velovate —
#     OBSOLETE" and the nested-sync case.
#   - the carry of a collapsed member's ignore rules skipped -> "collapse —
#     the member's new rule is carried".
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-npm-lane-conversion.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-npm-lane-conversion: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1
command -v jq >/dev/null 2>&1 || { echo "test-npm-lane-conversion: jq not on PATH" >&2; exit 1; }

SCRIPTS="skills/setup-deps/scripts"
CONVERT="$SCRIPTS/convert-npm-lanes.sh"
VALIDATE="$SCRIPTS/validate-dependabot.sh"
RENDER="$SCRIPTS/render-dependabot.sh"
DETECT="$SCRIPTS/detect-ecosystems.sh"
FIXTURES="scripts/fixtures/npm-lane-conversion"
DELIMITER='^# ---8<---'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "npm-lane-conversion tests (work: $WORK)" >&2

# body <file> — everything after the ---8<--- delimiter line.
body() {
    local d
    d=$(grep -n "$DELIMITER" "$1" | head -n1 | cut -d: -f1)
    [ -n "$d" ] || return 1
    tail -n +"$((d + 1))" "$1"
}

# materialize <corpus-body> <dir> — every path as a file, with its recorded
# one-line content (if any); prints the path list.
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

# convert <name> <tree> <files> <in> — run the converter; stdout to
# $WORK/<name>.out, the file to $WORK/<name>.yml, exit code in $rc.
convert() {
    bash "$CONVERT" --root "$2" --files-from "$3" --in "$4" --out "$WORK/$1.yml" \
        > "$WORK/$1.out" 2> "$WORK/$1.err"
    rc=$?
}

pairs() { bash "$VALIDATE" "$1" --pairs-only 2>/dev/null | sort; }
ignores() { (. "$SCRIPTS/lib-ecosystems.sh"; extract_ignore_rules "$1" | cut -f1,2,4 | sort -u); }
has_line() { grep -qE "$2" "$WORK/$1.out"; }

# --- 1. the three real shapes -------------------------------------------------
for repo in qr-ninja francisco velovate; do
    for f in corpus committed.yml expected; do
        [ -r "$FIXTURES/$repo.$f" ] || { bad "$repo — missing $FIXTURES/$repo.$f"; continue 2; }
    done
    tree="$WORK/$repo/tree"; mkdir -p "$tree"
    body "$FIXTURES/$repo.corpus" > "$WORK/$repo.corpus"
    materialize "$WORK/$repo.corpus" "$tree" > "$WORK/$repo.files"
    body "$FIXTURES/$repo.committed.yml" > "$WORK/$repo.in.yml"
    convert "$repo" "$tree" "$WORK/$repo.files" "$WORK/$repo.in.yml"
    if [ "$rc" -ne 0 ]; then
        bad "$repo — the converter exited $rc: $(tail -n1 "$WORK/$repo.err")"
        continue
    fi
    if diff -u <(body "$FIXTURES/$repo.expected" | sort) <(pairs "$WORK/$repo.yml") > "$WORK/$repo.diff"; then
        ok "$repo — lanes match the hand fix ($(grep -c . <(body "$FIXTURES/$repo.expected")) lanes)"
    else
        bad "$repo — lanes differ from the hand fix:"; sed 's/^/        /' "$WORK/$repo.diff" >&2
    fi
    if diff <(ignores "$WORK/$repo.in.yml" | sed 's/^npm\t/bun\t/' | sort) <(ignores "$WORK/$repo.yml") >/dev/null; then
        ok "$repo — every ignore rule survives ($(ignores "$WORK/$repo.in.yml" | grep -c .) compared)"
    else
        bad "$repo — the conversion lost or changed an ignore rule"
    fi
    if bash "$VALIDATE" "$WORK/$repo.yml" --root "$tree" --files-from "$WORK/$repo.files" >/dev/null 2>"$WORK/$repo.val"; then
        ok "$repo — every converted lane is backed by a tracked manifest"
    else
        bad "$repo — validate-dependabot.sh rejected the conversion:"; grep FAIL "$WORK/$repo.val" | sed 's/^/        /' >&2
    fi
    if has_line "$repo" '^NO-OP'; then bad "$repo — reported NO-OP on a file it changed"; fi
done

# qr-ninja: one token changes, nothing else.
if [ -r "$WORK/qr-ninja.yml" ]; then
    d="$(diff "$WORK/qr-ninja.in.yml" "$WORK/qr-ninja.yml" | grep -E '^[<>]')"
    if [ "$d" = $'<   - package-ecosystem: "npm"\n>   - package-ecosystem: "bun"' ]; then
        ok "qr-ninja — the conversion changes exactly the one package-ecosystem line"
    else
        bad "qr-ninja — the conversion changed more than the package-ecosystem line:"; printf '%s\n' "$d" | sed 's/^/        /' >&2
    fi
    has_line qr-ninja "^CONVERTED npm '/' -> bun '/'" && ok "qr-ninja — CONVERTED line" || bad "qr-ninja — no CONVERTED npm '/' line"
    has_line qr-ninja "^OBSOLETE \.github/workflows/dependabot-bun-lockfile\.yml: .*'/'.* owned: " \
        && ok "qr-ninja — OBSOLETE: its owned bun.lock sync workflow" || bad "qr-ninja — OBSOLETE line missing or not marked owned"
    has_line qr-ninja "^STALE \.github/workflows/dependabot-auto-merge\.yml: .*never names bun.* hand-written: " \
        && ok "qr-ninja — STALE: the hand-written auto-merge gates on npm_and_yarn and never names bun" \
        || bad "qr-ninja — STALE line missing, or not naming bun, or not marked hand-written"
fi
if [ -r "$WORK/francisco.out" ]; then
    [ "$(grep -c '^CONVERTED npm' "$WORK/francisco.out")" = 2 ] && ok "francisco — two per-directory CONVERTED lines" \
        || bad "francisco — expected two CONVERTED lines"
    grep -qE '^(COLLAPSED|OBSOLETE|STALE)' "$WORK/francisco.out" && bad "francisco — unexpected COLLAPSED/OBSOLETE/STALE line" \
        || ok "francisco — no collapse and no workflow finding (each web app has its own bun.lock)"
fi
if [ -r "$WORK/velovate.out" ]; then
    [ "$(grep -c "^COLLAPSED npm '/[^']*' -> bun '/'" "$WORK/velovate.out")" = 3 ] && ok "velovate — three member lanes COLLAPSED into '/'" \
        || bad "velovate — expected three COLLAPSED lines"
    has_line velovate "^OBSOLETE \.github/workflows/dependabot-bun-lockfile\.yml: .* hand-written: " \
        && ok "velovate — OBSOLETE: its hand-written bun.lock sync workflow" || bad "velovate — OBSOLETE line missing or not marked hand-written"
fi

# --- 2. boundaries (synthetic trees) -----------------------------------------
# mk <tree> <path> [content] — one tracked file.
mk() { mkdir -p "$1/$(dirname "$2")"; printf '%s\n' "${3:-}" > "$1/$2"; printf '%s\n' "$2" >> "$1.files"; }

# bun.lockb only: npm + sync is still the answer; nothing moves.
T="$WORK/lockb"
mk "$T" bun.lockb; mk "$T" package.json '{"workspaces":["apps/*"]}'; mk "$T" apps/a/package.json
mk "$T" .github/workflows/dependabot-bun-lockfile.yml '# generated-by: sassy-dog:setup-deps | template: lockfile-sync-bun | template-version: 10'
cat > "$WORK/lockb.in.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "npm"
    directory: "/apps/a"
    schedule:
      interval: "weekly"
EOF
convert lockb "$T" "$T.files" "$WORK/lockb.in.yml"
if [ "$rc" -eq 0 ] && cmp -s "$WORK/lockb.in.yml" "$WORK/lockb.yml" && has_line lockb '^NO-OP' && ! grep -q '^OBSOLETE' "$WORK/lockb.out"; then
    ok "bun.lockb only — both npm lanes and the sync workflow stay (NO-OP, byte-identical)"
else
    bad "bun.lockb only — the converter moved something:"; sed 's/^/        /' "$WORK/lockb.out" >&2
fi

# Members only, no root lane: the first member becomes the root's bun lane, the
# second folds into it with its rules (one new, one duplicate) and its comments.
T="$WORK/members"
mk "$T" bun.lock; mk "$T" package.json '{"workspaces":["packages/*"]}'
mk "$T" packages/a/package.json; mk "$T" packages/b/package.json
cat > "$WORK/members.in.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"

  # Package a.
  - package-ecosystem: npm
    directory: /packages/a
    schedule:
      interval: "weekly"
    labels: ["deps"]
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]

  # Package b — this comment block leaves with its lane.
  - package-ecosystem: npm
    directory: /packages/b
    schedule:
      interval: "daily"
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]
      # Hold react until the SDK moves.
      - dependency-name: "react"
EOF
convert members "$T" "$T.files" "$WORK/members.in.yml"
if [ "$rc" -eq 0 ] && [ "$(pairs "$WORK/members.yml" | paste -sd' ' -)" = $'bun\t/ github-actions\t/' ]; then
    ok "collapse — members-only: one bun lane at '/', github-actions untouched"
else
    bad "collapse — members-only did not produce {bun /, github-actions /} (exit $rc):"; sed 's/^/        /' "$WORK/members.out" "$WORK/members.err" >&2
fi
if grep -q 'package-ecosystem: bun' "$WORK/members.yml" && grep -q 'directory: /$' "$WORK/members.yml" && grep -q 'labels: \["deps"\]' "$WORK/members.yml"; then
    ok "collapse — the first member is retargeted in place (unquoted style kept, its labels kept)"
else
    bad "collapse — the retargeted member lost its shape or keys"
fi
if [ "$(grep -c 'dependency-name: "react"' "$WORK/members.yml")" = 1 ] && grep -q '# Hold react until the SDK moves.' "$WORK/members.yml" \
    && [ "$(grep -c 'dependency-name: "\*"' "$WORK/members.yml")" = 1 ]; then
    ok "collapse — the member's new rule is carried once with its comment; the duplicate hold is not repeated"
else
    bad "collapse — the member's new rule is carried: rules wrong in the output"
fi
if grep -q 'Package b' "$WORK/members.yml" || grep -q 'interval: "daily"' "$WORK/members.yml"; then
    bad "collapse — the folded member's comment block or keys survived"
else
    ok "collapse — the folded member's comment block and other keys are gone"
fi
has_line members "^COLLAPSED npm '/packages/a' -> bun '/'.*retargeted" && has_line members "^COLLAPSED npm '/packages/b' -> bun '/'.*Carried 1 ignore rule" \
    && ok "collapse — both COLLAPSED lines, with the carried-rule count" || bad "collapse — COLLAPSED lines missing or miscounted"

# An existing bun root lane absorbs an npm member; it gains an ignore: key.
T="$WORK/bunroot"
mk "$T" bun.lock; mk "$T" package.json '{"workspaces":{"packages":["apps/*"]}}'; mk "$T" apps/web/package.json
cat > "$WORK/bunroot.in.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "bun"
    directory: "/"
    schedule:
      interval: "weekly"

  - package-ecosystem: "npm"
    directory: "/apps/web"
    schedule:
      interval: "weekly"
    ignore:
      - dependency-name: "next"
EOF
convert bunroot "$T" "$T.files" "$WORK/bunroot.in.yml"
if [ "$rc" -eq 0 ] && [ "$(pairs "$WORK/bunroot.yml")" = $'bun\t/' ] && [ "$(ignores "$WORK/bunroot.yml")" = $'bun\t/\tdependency-name:next' ]; then
    ok "collapse — an npm member folds into the existing bun root lane, which gains ignore: for its rule"
else
    bad "collapse — the existing bun root lane did not absorb the member and its rule (exit $rc)"
fi

# Nested sync workflow: obsolete only where its install root holds a text bun.lock.
T="$WORK/nested"
mk "$T" web/bun.lock; mk "$T" web/package.json; mk "$T" tools/bun.lockb; mk "$T" tools/package.json
mk "$T" .github/workflows/dependabot-bun-lockfile.yml "        working-directory: 'web'"
mk "$T" .github/workflows/dependabot-bun-lockfile-tools.yml "        working-directory: tools"
mk "$T" .github/workflows/dependabot-auto-merge.yml "(steps.meta.outputs.package-ecosystem == 'github_actions' || steps.meta.outputs.package-ecosystem == 'bun') &&"
cat > "$WORK/nested.in.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "bun"
    directory: "/web"
    schedule:
      interval: "weekly"
  - package-ecosystem: "npm"
    directory: "/tools"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
EOF
convert nested "$T" "$T.files" "$WORK/nested.in.yml"
if has_line nested "^OBSOLETE \.github/workflows/dependabot-bun-lockfile\.yml: syncs bun\.lock for '/web'" \
    && ! grep -q 'dependabot-bun-lockfile-tools' "$WORK/nested.out"; then
    ok "nested sync — OBSOLETE for web/ (text bun.lock), not for tools/ (bun.lockb only)"
else
    bad "nested sync — wrong OBSOLETE findings:"; sed 's/^/        /' "$WORK/nested.out" >&2
fi
# The auto-merge names bun and github_actions but not npm_and_yarn, and the
# tools/ npm lane is still there — so it IS stale for npm.
has_line nested "^STALE .*never names npm_and_yarn" && ok "auto-merge — a gate missing a remaining ecosystem (npm_and_yarn) is STALE" \
    || bad "auto-merge — a gate missing npm_and_yarn was not reported"
# ...while an allowlist naming every ecosystem the file has is the repo's choice.
T="$WORK/allow"
mk "$T" bun.lock; mk "$T" package.json
mk "$T" .github/workflows/dependabot-auto-merge.yml "(steps.meta.outputs.package-ecosystem == 'github_actions' || steps.meta.outputs.package-ecosystem == 'bun') &&"
printf 'version: 2\nupdates:\n  - package-ecosystem: "bun"\n    directory: "/"\n  - package-ecosystem: "github-actions"\n    directory: "/"\n' > "$WORK/allow.in.yml"
convert allow "$T" "$T.files" "$WORK/allow.in.yml"
[ "$rc" -eq 0 ] && has_line allow '^NO-OP' && ok "auto-merge — an allowlist naming every ecosystem is not STALE (qr-ninja's post-fix shape)" \
    || bad "auto-merge — an allowlist naming every ecosystem was reported"

# --- 3. refusals and nothing-to-evaluate --------------------------------------
T="$WORK/dirs"
mk "$T" bun.lock; mk "$T" package.json; mk "$T" other/package.json
printf 'version: 2\nupdates:\n  - package-ecosystem: "npm"\n    directories:\n      - "/"\n      - "/other"\n' > "$WORK/dirs.in.yml"
convert dirs "$T" "$T.files" "$WORK/dirs.in.yml"
if [ "$rc" -eq 1 ] && [ ! -e "$WORK/dirs.yml" ] && has_line dirs "^REFUSED .*directories:"; then
    ok "refusal — an npm directories: list naming a covered directory (exit 1, nothing written)"
else
    bad "refusal — a covered directories: list was not refused (exit $rc)"
fi
T="$WORK/indent"
mk "$T" bun.lock; mk "$T" package.json '{"workspaces":["p/*"]}'; mk "$T" p/a/package.json
cat > "$WORK/indent.in.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    ignore:
      - dependency-name: "a"
  - package-ecosystem: "npm"
    directory: "/p/a"
    ignore:
        - dependency-name: "b"
EOF
convert indent "$T" "$T.files" "$WORK/indent.in.yml"
if [ "$rc" -eq 1 ] && [ ! -e "$WORK/indent.yml" ] && has_line indent "^REFUSED .*indented"; then
    ok "refusal — a member rule indented unlike the root lane's (exit 1, nothing written)"
else
    bad "refusal — a mis-indented member rule was not refused (exit $rc)"
fi
printf 'version: 2\nupdates:\n  - directory: "/"\n    package-ecosystem: "npm"\n' > "$WORK/order.in.yml"
convert order "$T" "$T.files" "$WORK/order.in.yml"
if [ "$rc" -eq 1 ] && [ ! -e "$WORK/order.yml" ] && has_line order "^REFUSED .*does not start with package-ecosystem"; then
    ok "refusal — an npm entry whose list item starts with another key (the reader cannot see it)"
else
    bad "refusal — an npm entry starting with directory: was not refused (exit $rc)"
fi
bash "$CONVERT" --root "$T" --files-from "$T.files" --in "$WORK/does-not-exist.yml" --out "$WORK/x.yml" >/dev/null 2>&1
[ $? -eq 2 ] && ok "nothing to evaluate — a missing --in exits 2" || bad "nothing to evaluate — a missing --in did not exit 2"
printf 'version: 2\n' > "$WORK/empty.in.yml"
bash "$CONVERT" --root "$T" --files-from "$T.files" --in "$WORK/empty.in.yml" --out "$WORK/x.yml" >/dev/null 2>&1
[ $? -eq 2 ] && ok "nothing to evaluate — a file with no entries exits 2" || bad "nothing to evaluate — a file with no entries did not exit 2"

# --- 4. idempotent -------------------------------------------------------------
for repo in qr-ninja velovate members; do
    [ -r "$WORK/$repo.yml" ] || continue
    if [ -d "$WORK/$repo/tree" ]; then t="$WORK/$repo/tree"; f="$WORK/$repo.files"; else t="$WORK/$repo"; f="$WORK/$repo.files"; fi
    cp "$WORK/$repo.yml" "$WORK/$repo.once.yml"
    convert "$repo.again" "$t" "$f" "$WORK/$repo.once.yml"
    if [ "$rc" -eq 0 ] && cmp -s "$WORK/$repo.once.yml" "$WORK/$repo.again.yml" && ! grep -qE '^(CONVERTED|COLLAPSED)' "$WORK/$repo.again.out"; then
        ok "idempotent — $repo: a second run moves no lane, byte-identical"
    else
        bad "idempotent — $repo: a second run changed the file again"
    fi
done

# --- 5. the owned-file path ----------------------------------------------------
W2W="scripts/fixtures/dependabot-render/what2wear-ignores.committed.yml"
W2W_CORPUS="scripts/fixtures/dependabot-render/what2wear.corpus"
T="$WORK/w2w"; mkdir -p "$T"
body "$W2W_CORPUS" > "$WORK/w2w.corpus"; materialize "$WORK/w2w.corpus" "$T" > "$WORK/w2w.files"
sed -n '/^---$/,$p' "$W2W" > "$WORK/w2w.owned.yml"
sed 's/package-ecosystem: "bun"/package-ecosystem: "npm"/' "$WORK/w2w.owned.yml" > "$WORK/w2w.npm.yml"
bash "$DETECT" --files-from "$WORK/w2w.files" --root "$T" > "$WORK/w2w.detect.json" 2>/dev/null
bash "$RENDER" --detect-json "$WORK/w2w.detect.json" --out "$WORK/w2w.plain.yml" 2>/dev/null
if bash "$VALIDATE" "$WORK/w2w.plain.yml" --root "$T" --files-from "$WORK/w2w.files" --compare-to "$WORK/w2w.npm.yml" >/dev/null 2>"$WORK/w2w.val1"; then
    bad "owned path — a render passed --compare-to against an owned npm-on-bun.lock file"
elif grep -q "DIVERGED: .*npm '/', which a text bun.lock covers .*convert-npm-lanes.sh" "$WORK/w2w.val1"; then
    ok "owned path — a plain --compare-to fails with the converter hint, not a bare lost-lane line"
else
    bad "owned path — the DIVERGED line does not point at convert-npm-lanes.sh"
fi
convert w2w "$T" "$WORK/w2w.files" "$WORK/w2w.npm.yml"
if [ "$rc" -eq 0 ] && cmp -s "$WORK/w2w.yml" "$WORK/w2w.owned.yml"; then
    ok "owned path — the converter restores the bun lane byte-for-byte"
else
    bad "owned path — the converter output differs from the bun original"
fi
if bash "$RENDER" --detect-json "$WORK/w2w.detect.json" --keep-ignores-from "$WORK/w2w.yml" --out "$WORK/w2w.render.yml" 2>/dev/null \
    && bash "$VALIDATE" "$WORK/w2w.render.yml" --root "$T" --files-from "$WORK/w2w.files" --compare-to "$WORK/w2w.yml" >/dev/null 2>&1; then
    ok "owned path — render --keep-ignores-from <converted> passes --compare-to <converted> (all 12 holds carried)"
else
    bad "owned path — the converted file does not feed render/validate cleanly"
fi

# --- 6. one ownership regex ----------------------------------------------------
skill_re="$(grep -E '^generated-by: \(' skills/setup-deps/SKILL.md | head -n1)"
script_re="$(sed -nE "s/^OWNED_RE='(.*)'$/\\1/p" "$CONVERT")"
if [ -n "$skill_re" ] && [ "$skill_re" = "$script_re" ]; then
    ok "ownership — the converter's regex is SKILL.md's"
else
    bad "ownership — the converter's regex ('$script_re') differs from SKILL.md's ('$skill_re')"
fi

if [ "$fail" -eq 0 ]; then
    echo "npm-lane-conversion tests: all green" >&2
    exit 0
fi
echo "npm-lane-conversion tests: FAILURES above" >&2
exit 1
