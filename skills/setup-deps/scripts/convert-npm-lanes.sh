#!/usr/bin/env bash
# convert-npm-lanes.sh — find every `npm` Dependabot lane that sits on a TEXT
# bun.lock and rewrite it as the native `bun` ecosystem, in place; then report
# the two workflows that conversion leaves stale. Runs on the committed
# .github/dependabot.yml whether this generator owns it or not.
#
# WHY IT EXISTS. Dependabot's npm_and_yarn updater refuses a directory that has
# a bun.lock and no package-lock.json / yarn.lock / pnpm-lock.yaml. Every run of
# such a lane fails with `misconfigured_tooling` ("Dependabot's `npm_and_yarn`
# ecosystem cannot update `bun.lock`. Set `package-ecosystem: "bun"`…"), opens
# no PR, and turns nothing red anywhere a person looks. qr-ninja, francisco and
# velovate each carried such lanes, dead for two to four weeks, through a
# setup-deps run: their dependabot.yml files were HAND-WRITTEN, so the
# report-and-skip ownership contract never looked at a lane, and the skill
# itself still blessed "a repo deliberately kept on grouped npm + sync"
# (qr-ninja#394) as a valid stance. The hand fixes were qr-ninja#919,
# francisco#182 and velovate#2400; this is that fix, made by the generator.
#
# THE RULE is bun_cover_root in lib-ecosystems.sh, the same function the
# renderer's bun collapse uses, so the converter folds exactly the lanes a
# fresh render would fold:
#   - an npm lane whose directory holds a text bun.lock becomes `bun` at that
#     directory — CONVERTED;
#   - an npm lane on a workspace MEMBER of a text-bun.lock root folds into that
#     root's lane — COLLAPSED. A member-only PR edits the member's package.json
#     but never the root lockfile, so it cannot pass a frozen install. The
#     root's lane is the existing `bun` lane there, else the `npm` lane there
#     (converted), else the first member lane in file order (retargeted to the
#     root). The member's ignore: rules are carried into the root's lane; its
#     other keys are dropped, and the report says so;
#   - a directory with only a binary bun.lockb is not covered: no ecosystem
#     writes bun.lockb, so it stays npm + lockfile sync.
# A converted lane keeps every key it had — groups, ignore:, labels,
# commit-message prefix, schedule, cooldown, comments — because the entry is
# edited, never re-rendered: only the `package-ecosystem:` value (and, for a
# retargeted member, the `directory:` value) changes. Group names are the
# repo's identifiers and are left alone.
#
# It REFUSES (exit 1, nothing written) rather than converting part of a file
# when an npm entry on a covered directory uses `directories:` (split it by
# hand), an npm entry's list item does not start with `package-ecosystem:` (the
# reader would not see it), or a collapsed member's ignore: rules cannot be
# appended to the root lane without mixing indents or splitting a flow-form
# ignore:.
#
# WORKFLOW FINDINGS, read from the tracked .github/workflows/ (nothing edited):
#   OBSOLETE — a bun.lock sync workflow (dependabot-bun-lockfile*.yml, or any
#     file carrying the lockfile-sync-bun template marker) whose install root
#     (its `working-directory:`, else the repo root) holds a text bun.lock. The
#     native ecosystem rewrites that lockfile in the PR itself, so the sync has
#     nothing left to do — while it still mints the org App token on every
#     Dependabot PR that touches a package.json.
#   STALE — a dependabot-auto-merge.yml that conditions on
#     `package-ecosystem` and never names an ecosystem the (converted)
#     dependabot.yml has. The template (v4) conditions on no ecosystem; a
#     hand-written gate on `npm_and_yarn` holds every `bun` PR for a human
#     forever (qr-ninja's would have). An allowlist naming every ecosystem the
#     file has is the repo's choice and is not reported.
# Each line says whether the file is owned (this generator's marker, the
# SKILL.md ownership regex) or hand-written, because that decides who removes or
# replaces it.
#
# Output: stdout carries one finding line per lane or workflow, then exactly one
# summary line (`convert-npm-lanes: …` or `NO-OP …`). The converted file goes to
# --out — byte-identical to --in when no lane moved. Errors go to stderr.
#
# Usage:
#   convert-npm-lanes.sh --out FILE [--in FILE] [--root DIR] [--files-from LIST]
#     --in          the committed config (default: .github/dependabot.yml under
#                   the repo root)
#     --files-from  test hook, as in detect-ecosystems.sh: a recorded file list
#                   instead of `git ls-files` (needs --root)
# Exit: 0 ran (findings, if any, are on stdout) · 1 refused, nothing written ·
#       2 bad usage or nothing to evaluate (no repo, no --in file, no lanes)
set -uo pipefail
export LC_ALL=C

command -v jq >/dev/null 2>&1 || { echo "convert-npm-lanes: jq not on PATH" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-ecosystems.sh
. "$SCRIPT_DIR/lib-ecosystems.sh"

# The ownership regex documented in SKILL.md §"Ownership marker" (every
# namespace × producer name this generator has emitted).
# scripts/test-npm-lane-conversion.sh fails when this and SKILL.md differ.
OWNED_RE='generated-by: (sassy-dog|ai-agent-skills):(setup-deps|refresh-deps|refresh-sassydog-deps)'

IN=""
OUT=""
ROOT_ARG=""
FILES_FROM=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --in)         IN="${2:-}"; shift 2 || exit 2 ;;
        --out)        OUT="${2:-}"; shift 2 || exit 2 ;;
        --root)       ROOT_ARG="${2:-}"; shift 2 || exit 2 ;;
        --files-from) FILES_FROM="${2:-}"; shift 2 || exit 2 ;;
        *) echo "convert-npm-lanes: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "usage: convert-npm-lanes.sh --out FILE [--in FILE] [--root DIR] [--files-from LIST]" >&2; exit 2; }

abspath() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
OUT_ABS="$(abspath "$OUT")" || { echo "convert-npm-lanes: --out directory does not exist" >&2; exit 2; }
if [ -n "$FILES_FROM" ]; then
    [ -r "$FILES_FROM" ] || { echo "convert-npm-lanes: cannot read --files-from '$FILES_FROM'" >&2; exit 2; }
    [ -n "$ROOT_ARG" ] || { echo "convert-npm-lanes: --files-from requires --root" >&2; exit 2; }
    FILES_FROM="$(abspath "$FILES_FROM")"
fi
[ -z "$IN" ] || IN="$(abspath "$IN")"
ROOT="${ROOT_ARG:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$ROOT" ] || { echo "convert-npm-lanes: not in a git repo (pass --root)" >&2; exit 2; }
cd "$ROOT" || exit 2
CORPUS_ROOT="$PWD"
[ -n "$IN" ] || IN="$CORPUS_ROOT/.github/dependabot.yml"
[ -r "$IN" ] || { echo "convert-npm-lanes: cannot read '$IN' — nothing to evaluate" >&2; exit 2; }
load_corpus "$FILES_FROM" || { echo "convert-npm-lanes: could not load the file corpus" >&2; exit 2; }
_bun_load_roots

# An entry whose list item does not START with package-ecosystem (`- directory:`
# first) is invisible to this reader, as it is to validate-dependabot.sh and
# extract_ignore_rules. Refuse rather than leave an npm lane unexamined.
if grep -vE '^[[:space:]]*#' "$IN" | grep -qE '^[[:space:]]+package-ecosystem:[[:space:]]*["'\'']?npm["'\'']?[[:space:]]*(#.*)?$'; then
    echo "REFUSED $IN has an npm entry whose list item does not start with package-ecosystem: — move that key first, then re-run"
    echo "convert-npm-lanes: refused — nothing written" >&2
    exit 1
fi

# --- 1. the entries ----------------------------------------------------------
# One TSV record per `- package-ecosystem:` entry, counted the way
# extract_ignore_rules counts them (comment lines skipped), so the rule ids it
# emits ("<entry>.<rule>") index these records:
#   idx eco eco_line dir dir_line multi dash_ind key_ind start end ign_line ign_end ign_flow
# dir is "-" when the entry has no `directory:` (a tab-separated `read` would
# otherwise collapse the empty field and shift every field after it).
# start is the first line of the comment block directly above the dash (the
# entry's own commentary) or of the blank run before it, so a removed entry
# takes its spacing and comments with it; end is its last line of content.
entries="$(awk '
function ind(s) { match(s, /^ */); return RLENGTH }
function unq(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s)
    if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
    while (length(s) > 1 && substr(s, length(s)) == "/") s = substr(s, 1, length(s) - 1)
    return s
}
function close_ign() { if (inign) { ie[n] = ign_last; inign = 0 } }
function close_entry() { if (n > 0 && open) { close_ign(); en[n] = last; open = 0 } }
{ L[NR] = $0 }
/^[ \t]*#/ || /^[ \t]*$/ {
    if (open && $0 ~ /^[ \t]*#/ && ind($0) > di[n]) { if (inign && ind($0) > ki[n]) ign_last = NR }
    next
}
/^[ \t]*-[ \t]*package-ecosystem:/ {
    close_entry()
    n++; open = 1
    v = $0; sub(/^[^:]*package-ecosystem:/, "", v); eco[n] = unq(v); el[n] = NR
    di[n] = ind($0)
    tmp = $0; sub(/^ *- */, "", tmp); ki[n] = length($0) - length(tmp)
    dir[n] = ""; dl[n] = 0; multi[n] = 0; il[n] = 0; ie[n] = 0; flow[n] = 0
    # the comment block directly above, then the blank run above that
    s = NR; while (s > 1 && L[s-1] ~ /^[ \t]*#/) s--
    while (s > 1 && L[s-1] ~ /^[ \t]*$/) s--
    if (n > 1 && s <= en_guard) s = en_guard + 1
    st[n] = s; last = NR
    next
}
{
    if (!open) next
    if (ind($0) <= di[n]) { close_entry(); en_guard = en[n]; next }
    last = NR; en_guard = NR
    if (inign) {
        if (ind($0) > ki[n]) { ign_last = NR } else { close_ign() }
    }
    if (ind($0) == ki[n] && $0 ~ /^ *directory:/) { v = $0; sub(/^ *directory:/, "", v); dir[n] = unq(v); dl[n] = NR }
    if (ind($0) == ki[n] && $0 ~ /^ *directories:/) multi[n] = 1
    if (ind($0) == ki[n] && $0 ~ /^ *ignore:/) {
        il[n] = NR; ign_last = NR
        v = $0; sub(/^ *ignore:/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/[ \t]/, "", v)
        if (v != "") flow[n] = 1; else inign = 1
    }
}
END {
    close_entry()
    for (i = 1; i <= n; i++)
        printf "%d\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", i, eco[i], el[i], (dir[i] == "" ? "-" : dir[i]), dl[i], multi[i], di[i], ki[i], st[i], en[i], il[i], ie[i], flow[i]
}' "$IN")"

if [ -z "$entries" ]; then
    echo "convert-npm-lanes: $IN declares no package-ecosystem entries — nothing to evaluate" >&2
    exit 2
fi

rules="$(extract_ignore_rules "$IN")"

# field <record> <n> — the nth tab-separated field.
field() { cut -f"$2" <<<"$1"; }
rec_of() { awk -F'\t' -v i="$1" '$1 == i' <<<"$entries"; }

# --- 2. which lanes move, and where ----------------------------------------
findings=""
refused=0
refuse() { echo "REFUSED $1"; refused=1; }

moves=""   # idx<TAB>root  for every npm entry covered by a text bun.lock root
while IFS=$'\t' read -r idx eco _ d _ multi _; do
    [ "$eco" = "npm" ] || continue
    if [ "$multi" = "1" ]; then
        # A directories: list cannot be split safely; refuse only if one of its
        # directories is actually covered.
        while IFS=$'\t' read -r e dd; do
            [ "$e" = "npm" ] || continue
            if [ -n "$(bun_cover_root "$dd")" ]; then
                refuse "npm entry #$idx lists '$dd' under directories:, which a text bun.lock covers — split that entry into one directory: per lane by hand, then re-run"
                break
            fi
        done < <(awk -v i="$idx" 'BEGIN{n=0} /^[ \t]*#/ {next} /^[ \t]*-[ \t]*package-ecosystem:/ {n++} n == i' "$IN" \
            | sed -n '/directories:/,/^[^ ]/p' | sed -nE 's#^[[:space:]]*-[[:space:]]*["'\'']?(/[^"'\'']*)["'\'']?[[:space:]]*$#npm\t\1#p')
        continue
    fi
    [ "$d" != "-" ] || continue
    r="$(bun_cover_root "$d")"
    [ -n "$r" ] || continue
    moves+="$idx"$'\t'"$r"$'\n'
done <<<"$entries"

[ "$refused" -eq 0 ] || { echo "convert-npm-lanes: refused — nothing written" >&2; exit 1; }

# edits: "<line>\t<op>\t<text>", op S (substitute), D (delete), A (append after)
edits=""
n_conv=0
n_coll=0
roots="$(cut -f2 <<<"$moves" | grep -v '^$' | sort -u)"
while IFS= read -r r; do
    [ -n "$r" ] || continue
    movers="$(awk -F'\t' -v r="$r" '$2 == r { print $1 }' <<<"$moves")"
    # The keeper: an existing bun lane at the root, else the npm lane at the
    # root, else the first member lane in file order.
    keeper="$(awk -F'\t' -v r="$r" '$2 == "bun" && $4 == r && $6 == 0 { print $1; exit }' <<<"$entries")"
    keeper_was_bun=1
    if [ -z "$keeper" ]; then
        keeper_was_bun=0
        keeper="$(while IFS= read -r i; do
            [ "$(field "$(rec_of "$i")" 4)" = "$r" ] && { echo "$i"; break; }
        done <<<"$movers")"
        [ -n "$keeper" ] || keeper="$(head -n1 <<<"$movers")"
    fi
    krec="$(rec_of "$keeper")"
    k_eco_line="$(field "$krec" 3)"; k_dir="$(field "$krec" 4)"; k_dir_line="$(field "$krec" 5)"
    k_ki="$(field "$krec" 8)"; k_end="$(field "$krec" 10)"
    k_ign="$(field "$krec" 11)"; k_ign_end="$(field "$krec" 12)"; k_flow="$(field "$krec" 13)"

    if [ "$keeper_was_bun" -eq 0 ]; then
        line="$(sed -n "${k_eco_line}p" "$IN")"
        new="$(sed -E 's/(package-ecosystem:[[:space:]]*["'\'']?)npm(["'\'']?)/\1bun\2/' <<<"$line")"
        edits+="$k_eco_line"$'\t'"S"$'\t'"$new"$'\n'
        if [ "$k_dir" = "$r" ]; then
            n_conv=$((n_conv + 1))
            findings+="CONVERTED npm '$r' -> bun '$r': '$r' holds a text bun.lock, which Dependabot's npm_and_yarn updater refuses (misconfigured_tooling) — every run of this lane failed and opened nothing. Every key of the lane is kept; only package-ecosystem changes"$'\n'
        else
            line="$(sed -n "${k_dir_line}p" "$IN")"
            new="$(sed -E "s#(directory:[[:space:]]*[\"']?)[^\"' ]*([\"']?)#\\1$r\\2#" <<<"$line")"
            edits+="$k_dir_line"$'\t'"S"$'\t'"$new"$'\n'
            n_coll=$((n_coll + 1))
            findings+="COLLAPSED npm '$k_dir' -> bun '$r': workspace member of the text bun.lock root '$r', which has no lane of its own here — this entry becomes the root's bun lane (directory retargeted; every other key kept)"$'\n'
        fi
    fi

    # Fold every other mover into the keeper.
    keeper_keys="$(awk -F'\t' -v i="$keeper" '{ split($3, a, "."); if (a[1] == i) print $4 }' <<<"$rules" | sort -u)"
    carried_text=""
    while IFS= read -r i; do
        [ -n "$i" ] && [ "$i" != "$keeper" ] || continue
        rec="$(rec_of "$i")"
        m_dir="$(field "$rec" 4)"; m_start="$(field "$rec" 9)"; m_end="$(field "$rec" 10)"
        m_ign="$(field "$rec" 11)"; m_ki="$(field "$rec" 8)"; m_flow="$(field "$rec" 13)"
        n_carried=0
        if [ "$m_ign" != "0" ]; then
            if [ "$m_flow" = "1" ] || [ "$k_flow" = "1" ]; then
                refuse "npm '$m_dir' folds into bun '$r', but a flow-form ignore: cannot be merged rule by rule — rewrite it as a block list, then re-run"
                continue
            fi
            # Rules of this entry not already in the keeper (or carried already).
            m_rules="$(awk -F'\t' -v i="$i" '{ split($3, a, "."); if (a[1] == i) print }' <<<"$rules")"
            while IFS= read -r rid; do
                [ -n "$rid" ] || continue
                rkey="$(awk -F'\t' -v id="$rid" '$3 == id { print $4; exit }' <<<"$m_rules")"
                grep -qxF -- "$rkey" <<<"$keeper_keys" && continue
                rind="$(awk -F'\t' -v id="$rid" '$3 == id { print $5; exit }' <<<"$m_rules")"
                if [ "$k_ign" != "0" ]; then
                    want="$(awk -F'\t' -v i="$keeper" '{ split($3, a, "."); if (a[1] == i) { print $5; exit } }' <<<"$rules")"
                    [ -n "$want" ] || want=$((k_ki + 2))
                else
                    want=$((k_ki + 2))
                    [ "$m_ki" = "$k_ki" ] || want=-1
                fi
                if [ "$rind" != "$want" ]; then
                    refuse "npm '$m_dir' folds into bun '$r', but its ignore rule ($rkey) is indented unlike the root lane's — re-indent it in the committed file, then re-run"
                    continue 2
                fi
                carried_text+="$(awk -F'\t' -v id="$rid" '$3 == id' <<<"$m_rules" | cut -f6-)"$'\n'
                keeper_keys+=$'\n'"$rkey"
                n_carried=$((n_carried + 1))
            done < <(cut -f3 <<<"$m_rules" | awk '!seen[$0]++')
        fi
        for ((l = m_start; l <= m_end; l++)); do edits+="$l"$'\t'"D"$'\t'$'\n'; done
        n_coll=$((n_coll + 1))
        m_eco="$(field "$rec" 2)"
        why="workspace member of the text bun.lock root '$r'; a member-only PR never rewrites the root lockfile and cannot pass a frozen install"
        [ "$m_dir" = "$r" ] && why="a second lane on the same root, which already has a bun lane"
        findings+="COLLAPSED $m_eco '$m_dir' -> bun '$r': $why. Carried $n_carried ignore rule(s) into the root lane; this entry's other keys (schedule, labels, commit-message, groups) are dropped — the root lane's apply"$'\n'
    done <<<"$movers"
    if [ -n "$carried_text" ]; then
        if [ "$k_ign" != "0" ]; then
            at="$k_ign_end"
        else
            at="$k_end"
            carried_text="$(printf '%*s' "$k_ki" '')ignore:"$'\n'"$carried_text"
        fi
        while IFS= read -r t; do
            edits+="$at"$'\t'"A"$'\t'"$t"$'\n'
        done <<<"${carried_text%$'\n'}"
    fi
done <<<"$roots"

[ "$refused" -eq 0 ] || { echo "convert-npm-lanes: refused — nothing written" >&2; exit 1; }

# --- 3. apply ---------------------------------------------------------------
if [ -z "$edits" ]; then
    cp "$IN" "$OUT_ABS" || exit 2
else
    awk -F'\t' '
        NR == FNR {
            if ($2 == "S") sub_[$1] = substr($0, length($1) + 4)
            else if ($2 == "D") del[$1] = 1
            else if ($2 == "A") { na[$1]++; app[$1, na[$1]] = substr($0, length($1) + 4) }
            next
        }
        {
            if (!(FNR in del)) print ((FNR in sub_) ? sub_[FNR] : $0)
            for (k = 1; k <= na[FNR]; k++) print app[FNR, k]
        }' <(printf '%s' "$edits") "$IN" > "$OUT_ABS" || exit 2
fi

# --- 4. workflows the conversion leaves stale -------------------------------
lanes_after="$(awk '/^[ \t]*#/ {next} /^[ \t]*-[ \t]*package-ecosystem:/ {
        v = $0; sub(/^[^:]*package-ecosystem:/, "", v); gsub(/[ \t"\047]/, "", v); sub(/#.*/, "", v); print v }' "$OUT_ABS" | sort -u)"

ownership() { if grep -qE "$OWNED_RE" "$1"; then echo "owned"; else echo "hand-written"; fi; }

# fetch-metadata's package-ecosystem name for a dependabot.yml ecosystem.
fm_name() {
    case "$1" in
        npm) echo npm_and_yarn ;; github-actions) echo github_actions ;; gomod) echo go_modules ;;
        *) echo "${1//-/_}" ;;
    esac
}

while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    [ -r "$CORPUS_ROOT/$wf" ] || continue
    base="${wf##*/}"
    if [[ "$base" =~ ^dependabot-bun-lockfile.*\.ya?ml$ ]] || grep -q 'template: lockfile-sync-bun' "$CORPUS_ROOT/$wf"; then
        wd="$(sed -nE "s/^[[:space:]]*working-directory:[[:space:]]*[\"']?([^\"' #]*)[\"']?.*$/\\1/p" "$CORPUS_ROOT/$wf" | head -n1)"
        wd="${wd#./}"; wd="${wd%/}"
        if [ -z "$wd" ] || [ "$wd" = "." ]; then wroot="/"; else wroot="/$wd"; fi
        if grep -qxF -- "$wroot" <<<"$BUN_TEXT_DIRS"; then
            own="$(ownership "$CORPUS_ROOT/$wf")"
            if [ "$own" = "owned" ]; then
                act="this generator no longer renders it there, so delete it in this run"
            else
                act="delete it as a plan item the user approves by name"
            fi
            findings+="OBSOLETE $wf: syncs bun.lock for '$wroot', which holds a text bun.lock — the native bun lane rewrites that lockfile in the PR itself, so this workflow has nothing left to do but mint the org App token on every Dependabot package.json PR. $own: $act"$'\n'
        fi
    fi
    if [ "$base" = "dependabot-auto-merge.yml" ] || [ "$base" = "dependabot-auto-merge.yaml" ]; then
        named="$(grep -v '^[[:space:]]*#' "$CORPUS_ROOT/$wf" | grep -oE "package-ecosystem[[:space:]]*[!=]=[[:space:]]*'[^']*'" \
            | sed -E "s/.*'([^']*)'/\\1/" | sort -u)"
        if [ -n "$named" ]; then
            # Flagged only when the gate actually holds a lane's PRs: an
            # allowlist that names every ecosystem dependabot.yml has is the
            # repo's choice, not a defect.
            missing=""
            while IFS= read -r e; do
                [ -n "$e" ] || continue
                f="$(fm_name "$e")"
                grep -qxF -- "$f" <<<"$named" || missing+="${missing:+, }$f"
            done <<<"$lanes_after"
            own="$(ownership "$CORPUS_ROOT/$wf")"
            if [ "$own" = "owned" ]; then
                act="the re-render replaces it with the template, which conditions on no ecosystem"
            else
                act="replace it with the template render (v4 conditions on no ecosystem) as a plan item the user approves by name"
            fi
            [ -z "$missing" ] || findings+="STALE $wf: conditions on package-ecosystem ($(paste -sd, - <<<"$named" | sed 's/,/, /g')) and never names $missing, which dependabot.yml has — every PR from those is held for a human, whatever its update-type. $own: $act"$'\n'
        fi
    fi
done < <(grep -E '^\.github/workflows/[^/]+\.ya?ml$' <<<"$FILES")

printf '%s' "$findings"
if [ -z "$findings" ]; then
    echo "NO-OP convert-npm-lanes: no npm lane on a text bun.lock, no obsolete bun.lock sync workflow, no ecosystem-conditioned auto-merge"
else
    echo "convert-npm-lanes: $n_conv converted, $n_coll collapsed, $(grep -c '^OBSOLETE' <<<"$findings") obsolete workflow(s), $(grep -c '^STALE' <<<"$findings") stale auto-merge — converted file: $OUT"
fi
exit 0
