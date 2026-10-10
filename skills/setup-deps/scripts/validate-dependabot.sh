#!/usr/bin/env bash
# validate-dependabot.sh — the post-render assertion that replaced "valid by
# construction" (issue #169).
#
# WHAT IT ASSERTS, and why that is the useful assertion: every `directory:` a
# dependabot.yml declares must actually HOLD the manifest its ecosystem claims.
# A v2 render was always valid YAML — it just pointed every lane at "/", where
# no manifest lived, and Dependabot answers that by doing nothing at all and
# reporting nothing at all. Structural validity could never catch that; this
# can, because it checks the file against the repo it is about to be written
# into.
#
# It reads the same tracked-files corpus and the same ecosystem table as
# detect-ecosystems.sh (lib-ecosystems.sh) on purpose: a second transcription
# of the table would let this agree with a renderer that is wrong.
#
# --compare-to EXISTING covers the DIVERGED-BUT-OWNED case. A file stamped with
# this generator's marker whose content a fresh render no longer reproduces is
# a silent-regression hazard: the ownership matcher says "mine, reconcile it",
# the render then drops lanes the repo actually needs, and nothing errors
# (tailoredtip carried a v2 marker over four correctly-directed lanes that a v2
# render would have collapsed onto "/"). Every (ecosystem, directory) pair the
# existing file has and the fresh render lacks is reported and fails the run —
# the point is that a human decides, not that the refresh proceeds.
#
# COOLDOWN (issue #498). A `cooldown:` block is accepted ONLY where the caller
# says it was requested: `--cooldown ECOSYSTEM=DAYS` (repeatable) is the same
# request that was handed to render-dependabot.sh. Every entry of a requested
# ecosystem must carry exactly `default-days: DAYS` and nothing else, every
# other entry must carry no cooldown at all, and a requested ecosystem with no
# entry is a failure. With NO --cooldown flag any cooldown in FILE fails, which
# is what makes a hand-added one visible. Under --compare-to, a cooldown the
# existing file carries that the fresh render does not is DIVERGED, like a
# dropped lane: re-rendering without the request would silently strip it, and
# a human decides. The message says which of two things happened: CHANGED (the
# render carries the ecosystem's cooldown at a different value) or DROPPED (the
# render carries none, which is what a forgotten --cooldown looks like — the
# committed file is the only record of the request, so the message tells the
# operator to read it from there). A DELIBERATE change or removal is
# acknowledged per ecosystem with `--change-cooldown ECOSYSTEM` (repeatable,
# needs --compare-to): it accepts exactly that ecosystem's CHANGED or DROPPED
# line and nothing else. It is refused when it would be a no-op (the existing
# file carries no cooldown there, or the render reproduces it unchanged), so a
# typo cannot silently disarm the guard, and a forgotten --cooldown without it
# still fails closed. The requests are parsed by parse_cooldown_requests in
# lib-ecosystems.sh, the same parser render-dependabot.sh uses (DAYS 1..90, one
# request per ecosystem). Only `default-days` is understood; `semver-*-days`,
# `include` and `exclude` are reported as divergence.
#
# Usage:
#   validate-dependabot.sh FILE [--root DIR] [--files-from LIST]
#                               [--compare-to EXISTING]
#                               [--cooldown ECOSYSTEM=DAYS]...
#                               [--change-cooldown ECOSYSTEM]...
#   validate-dependabot.sh FILE --pairs-only     # the extracted lanes, nothing
#                                                # asserted (needs no repo)
# Exit: 0 every lane is backed by a manifest (and nothing was dropped)
#       1 a lane points at nothing, the file is structurally unreadable, or a
#         comparison found dropped lanes
#       2 bad usage
set -uo pipefail
export LC_ALL=C   # comm needs both sides sorted the same way

# shellcheck source=./lib-ecosystems.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ecosystems.sh"

FILE=""
ROOT_ARG=""
FILES_FROM=""
COMPARE_TO=""
PAIRS_ONLY=0
COOLDOWNS=""   # newline-separated "ecosystem=days"
ACKS=""        # newline-separated ecosystems whose cooldown change/removal is deliberate

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)       ROOT_ARG="${2:-}"; shift 2 || exit 2 ;;
        --files-from) FILES_FROM="${2:-}"; shift 2 || exit 2 ;;
        --compare-to) COMPARE_TO="${2:-}"; shift 2 || exit 2 ;;
        --pairs-only) PAIRS_ONLY=1; shift ;;
        --cooldown)   COOLDOWNS+="${2:-}"$'\n'; shift 2 || exit 2 ;;
        --change-cooldown) ACKS+="${2:-}"$'\n'; shift 2 || exit 2 ;;
        -*) echo "validate-dependabot: unknown argument '$1'" >&2; exit 2 ;;
        *)  [ -z "$FILE" ] || { echo "validate-dependabot: one file at a time" >&2; exit 2; }
            FILE="$1"; shift ;;
    esac
done

[ -n "$FILE" ] || { echo "usage: validate-dependabot.sh FILE [--root DIR] [--files-from LIST] [--compare-to EXISTING] [--cooldown ECOSYSTEM=DAYS]... [--change-cooldown ECOSYSTEM]..." >&2; exit 2; }
parse_cooldown_requests "$COOLDOWNS" || { echo "validate-dependabot: $COOLDOWN_ERR" >&2; exit 2; }
while IFS= read -r ack; do
    [ -n "$ack" ] || continue
    [[ "$ack" =~ ^[a-z][a-z-]*$ ]] || { echo "validate-dependabot: --change-cooldown '$ack' must be an ECOSYSTEM name" >&2; exit 2; }
done <<<"$ACKS"
[ -z "$ACKS" ] || [ -n "$COMPARE_TO" ] || { echo "validate-dependabot: --change-cooldown acknowledges a difference from the committed file, so it needs --compare-to" >&2; exit 2; }
[ -r "$FILE" ] || { echo "validate-dependabot: cannot read '$FILE'" >&2; exit 2; }

abspath() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }

FILE_ABS="$(abspath "$FILE")"
COMPARE_ABS=""
if [ -n "$COMPARE_TO" ]; then
    [ -r "$COMPARE_TO" ] || { echo "validate-dependabot: cannot read --compare-to '$COMPARE_TO'" >&2; exit 2; }
    COMPARE_ABS="$(abspath "$COMPARE_TO")"
fi

if [ "$PAIRS_ONLY" -eq 0 ]; then
    if [ -n "$FILES_FROM" ]; then
        [ -r "$FILES_FROM" ] || { echo "validate-dependabot: cannot read --files-from '$FILES_FROM'" >&2; exit 2; }
        [ -n "$ROOT_ARG" ] || { echo "validate-dependabot: --files-from requires --root" >&2; exit 2; }
        FILES_FROM="$(abspath "$FILES_FROM")"
        ROOT="$ROOT_ARG"
    else
        ROOT="${ROOT_ARG:-$(git rev-parse --show-toplevel 2>/dev/null)}"
        [ -n "$ROOT" ] || { echo "validate-dependabot: not in a git repo (pass --root)" >&2; exit 2; }
    fi
    cd "$ROOT" || exit 2
    CORPUS_ROOT="$PWD"
    load_corpus "$FILES_FROM" || { echo "validate-dependabot: could not load the file corpus" >&2; exit 1; }
fi

# --- extraction --------------------------------------------------------------
# A line reader rather than a YAML library: no YAML parser is guaranteed on a
# developer machine or on the self-hosted fleet, and dependabot.yml has a fixed
# shape. It is deliberately STRICT — an entry with no directory key is REPORTED
# rather than skipped, because a silently skipped entry is the very class of
# bug this script exists to catch. Comment lines are dropped first: consumer
# configs discuss `directory:` in prose (velovate's does), and a reader that
# swallowed prose would invent lanes nobody declared.
_scalar() {
    local s="${1%%#*}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"
    printf '%s' "$s"
}

# _norm_dir — trailing slashes off, except for the root, which IS "/".
_norm_dir() {
    local d="$1"
    while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
    printf '%s' "$d"
}

# extract_pairs <file> — one "ecosystem<TAB>directory" line per declared lane.
# Structural complaints ride along as "!STRUCTURE<TAB>message" lines.
extract_pairs() {
    local f="$1" line eco="" val item
    local entry=0 dir_count=0 in_dirs=0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*package-ecosystem:[[:space:]]*(.*)$ ]]; then
            if [ "$entry" -eq 1 ] && [ "$dir_count" -eq 0 ]; then
                printf '!STRUCTURE\t%s\n' "entry '$eco' declares no directory/directories key"
            fi
            eco="$(_scalar "${BASH_REMATCH[1]}")"
            entry=1; dir_count=0; in_dirs=0
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*directories:[[:space:]]*(.*)$ ]]; then
            val="$(_scalar "${BASH_REMATCH[1]}")"
            if [ -n "$val" ]; then
                # inline flow list: directories: ["/a", "/b"]
                in_dirs=0
                val="${val#[}"; val="${val%]}"
                while IFS= read -r item; do
                    item="$(_scalar "$item")"
                    [ -n "$item" ] || continue
                    printf '%s\t%s\n' "$eco" "$(_norm_dir "$item")"
                    dir_count=$((dir_count + 1))
                done <<<"${val//,/$'\n'}"
            else
                in_dirs=1
            fi
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*directory:[[:space:]]*(.*)$ ]]; then
            in_dirs=0
            val="$(_scalar "${BASH_REMATCH[1]}")"
            printf '%s\t%s\n' "$eco" "$(_norm_dir "$val")"
            dir_count=$((dir_count + 1))
            continue
        fi
        if [ "$in_dirs" -eq 1 ]; then
            # Block-list items are bare scalars starting with '/'. Anything else
            # (a `- dependency-name: "*"` under ignore:, the next key) closes
            # the list instead of being swallowed into it.
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*[\"\']?(/[^\"\']*)[\"\']?[[:space:]]*$ ]]; then
                val="$(_scalar "${BASH_REMATCH[1]}")"
                printf '%s\t%s\n' "$eco" "$(_norm_dir "$val")"
                dir_count=$((dir_count + 1))
            else
                in_dirs=0
            fi
        fi
    done < "$f"
    if [ "$entry" -eq 1 ] && [ "$dir_count" -eq 0 ]; then
        printf '!STRUCTURE\t%s\n' "entry '$eco' declares no directory/directories key"
    fi
}

# extract_cooldowns <file> — one "ecosystem<TAB>spec" line per package-ecosystem
# entry, spec being the entry's cooldown keys as sorted `key=value` pairs joined
# by commas (empty when the entry has no cooldown). Comments are dropped first,
# so the file header's prose about `cooldown:` is never read as a block.
extract_cooldowns() {
    local f="$1" line eco="" have=0 cd_indent=-1 spec="" cd_seen=0 ind k v pair
    _flush() { [ "$cd_seen" -eq 1 ] && [ -z "$spec" ] && spec="bare=,"; [ "$have" -eq 1 ] && printf '%s\t%s\n' "$eco" "$(tr ',' '\n' <<<"$spec" | grep -v '^$' | sort | paste -sd, -)"; return 0; }
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*package-ecosystem:[[:space:]]*(.*)$ ]]; then
            _flush
            eco="$(_scalar "${BASH_REMATCH[1]}")"; have=1; cd_indent=-1; spec=""; cd_seen=0
            continue
        fi
        [ "$have" -eq 1 ] || continue
        if [[ "$line" =~ ^([[:space:]]*)cooldown:[[:space:]]*(.*)$ ]]; then
            ind="${BASH_REMATCH[1]}"; v="$(_scalar "${BASH_REMATCH[2]}")"
            cd_indent=${#ind}
            if [ -n "$v" ]; then
                # inline flow form: cooldown: {default-days: 7}
                v="${v#\{}"; v="${v%\}}"; cd_indent=-1
                while IFS= read -r pair; do
                    [ -n "${pair//[[:space:]]/}" ] || continue
                    k="$(_scalar "${pair%%:*}")"; v="$(_scalar "${pair#*:}")"
                    spec+="$k=$v,"
                done <<<"${v//,/$'\n'}"
                [ -n "$spec" ] || spec="flow=unreadable,"
            else
                cd_seen=1   # a bare `cooldown:` is itself a (key-less) cooldown
            fi
            continue
        fi
        if [ "$cd_indent" -ge 0 ]; then
            if [[ "$line" =~ ^([[:space:]]*)([A-Za-z0-9_-]+):[[:space:]]*(.*)$ ]] && [ "${#BASH_REMATCH[1]}" -gt "$cd_indent" ]; then
                spec+="${BASH_REMATCH[2]}=$(_scalar "${BASH_REMATCH[3]}"),"
            elif [[ "$line" =~ ^([[:space:]]*)- ]] && [ "${#BASH_REMATCH[1]}" -gt "$cd_indent" ]; then
                :   # a list item under include:/exclude: — the key already counts
            else
                cd_indent=-1
            fi
        fi
    done < "$f"
    _flush
}

# requested_spec ECOSYSTEM — the spec the caller's --cooldown requests, or empty.
requested_spec() {
    local req
    while IFS= read -r req; do
        [ "${req%%=*}" = "$1" ] && { echo "default-days=${req#*=}"; return 0; }
    done <<<"$COOLDOWNS"
    return 0
}

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

raw="$(extract_pairs "$FILE_ABS")"
structure="$(grep '^!STRUCTURE' <<<"$raw" | cut -f2-)"
if [ -n "$structure" ]; then
    while IFS= read -r msg; do [ -n "$msg" ] && bad "$FILE: $msg"; done <<<"$structure"
fi
pairs="$(grep -v '^!STRUCTURE' <<<"$raw" | grep -v '^[[:space:]]*$' | sort -u)"

if [ -z "$pairs" ]; then
    bad "$FILE: no (ecosystem, directory) pairs found — an empty or unreadable config is not a valid render"
    echo "validate-dependabot: FAILURES above" >&2
    exit 1
fi

if [ "$PAIRS_ONLY" -eq 1 ]; then
    printf '%s\n' "$pairs"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

echo "validate-dependabot: $FILE against $CORPUS_ROOT" >&2

# --- cooldown ----------------------------------------------------------------
file_cd="$(extract_cooldowns "$FILE_ABS")"
seen_cd_eco=""
while IFS=$'\t' read -r eco spec; do
    [ -n "$eco" ] || continue
    seen_cd_eco+="$eco"$'\n'
    want="$(requested_spec "$eco")"
    if [ "$spec" = "$want" ]; then
        [ -z "$spec" ] || ok "$eco cooldown $spec (requested)"
    elif [ -z "$want" ]; then
        bad "$eco: carries a cooldown ($spec) that was not requested — most likely --cooldown $eco=DAYS was not passed (the request is not stored; read default-days from the committed file and pass it to render AND validate); otherwise it is a hand-added cooldown in an owned file"
    elif [ -z "$spec" ]; then
        bad "$eco: cooldown requested ($want) but this entry carries none"
    else
        bad "$eco: cooldown '$spec' does not match the request '$want'"
    fi
done <<<"$file_cd"
while IFS= read -r req; do
    [ -n "$req" ] || continue
    grep -qxF "${req%%=*}" <<<"$seen_cd_eco" || bad "${req%%=*}: cooldown requested but the file has no such ecosystem entry"
done <<<"$COOLDOWNS"
while IFS=$'\t' read -r eco dir; do
    [ -n "$eco" ] || continue
    if [ -z "$dir" ]; then bad "$eco: entry declares an empty directory"; continue; fi
    case "$dir" in /*) ;; *) bad "$eco '$dir': a Dependabot directory must start with '/'"; continue ;; esac
    if ! eco_manifest_re "$eco" >/dev/null; then
        bad "$eco '$dir': ecosystem unknown to setup-deps' table — cannot assert its manifest (hand-written config?)"
        continue
    fi
    if dir_holds_manifest "$eco" "$dir"; then
        ok "$eco $dir"
    else
        bad "$eco '$dir': no tracked $eco manifest in that directory — Dependabot finds nothing there and says nothing about it"
    fi
done <<<"$pairs"

# --- divergence --------------------------------------------------------------
if [ -n "$COMPARE_ABS" ]; then
    existing="$(extract_pairs "$COMPARE_ABS" | grep -v '^!STRUCTURE' | grep -v '^[[:space:]]*$' | sort -u)"
    dropped="$(comm -23 <(printf '%s\n' "$existing") <(printf '%s\n' "$pairs"))"
    added="$(comm -13 <(printf '%s\n' "$existing") <(printf '%s\n' "$pairs"))"
    if [ -n "$(tr -d '[:space:]' <<<"$dropped")" ]; then
        while IFS=$'\t' read -r eco dir; do
            [ -n "$eco" ] || continue
            bad "DIVERGED: $COMPARE_TO declares $eco '$dir', which this render does not — reconciling would drop that lane silently"
        done <<<"$dropped"
    else
        ok "no lane in $COMPARE_TO is dropped by this render"
    fi
    existing_cd="$(extract_cooldowns "$COMPARE_ABS" | grep -vE $'\t$' | sort -u)"
    render_cd="$(printf '%s\n' "$file_cd" | grep -vE $'\t$' | sort -u)"
    dropped_cd="$(comm -23 <(printf '%s\n' "$existing_cd") <(printf '%s\n' "$render_cd"))"
    acked_used=""
    if [ -n "$(tr -d '[:space:]' <<<"$dropped_cd")" ]; then
        while IFS=$'\t' read -r eco spec; do
            [ -n "$eco" ] || continue
            now="$(awk -F'\t' -v e="$eco" '$1 == e { print $2; exit }' <<<"$render_cd")"
            if [ -n "$now" ]; then kind="CHANGED"; else kind="DROPPED"; fi
            if grep -qxF "$eco" <<<"$ACKS"; then
                acked_used+="$eco"$'\n'
                if [ "$kind" = "CHANGED" ]; then
                    ok "$eco cooldown deliberately changed ($spec -> $now), acknowledged by --change-cooldown $eco"
                else
                    ok "$eco cooldown ($spec) deliberately removed, acknowledged by --change-cooldown $eco"
                fi
            elif [ "$kind" = "CHANGED" ]; then
                bad "DIVERGED: $COMPARE_TO carries a $eco cooldown ($spec) that this render CHANGED to ($now) — if the change is deliberate, re-run with --change-cooldown $eco; if not, pass the committed value as --cooldown $eco=DAYS"
            else
                bad "DIVERGED: $COMPARE_TO carries a $eco cooldown ($spec) that this render DROPPED — most likely --cooldown $eco=DAYS was forgotten (read default-days from $COMPARE_TO and pass it to render AND validate); if removing the cooldown is deliberate, re-run with --change-cooldown $eco"
            fi
        done <<<"$dropped_cd"
    else
        ok "no cooldown in $COMPARE_TO is dropped by this render"
    fi
    while IFS= read -r ack; do
        [ -n "$ack" ] || continue
        grep -qxF "$ack" <<<"$acked_used" || bad "--change-cooldown $ack acknowledges nothing: $COMPARE_TO carries no $ack cooldown that this render changes or drops"
    done <<<"$ACKS"
    while IFS=$'\t' read -r eco dir; do
        [ -n "$eco" ] || continue
        echo "  note  this render adds $eco '$dir' (absent from $COMPARE_TO)" >&2
    done <<<"$added"
fi

if [ "$fail" -eq 0 ]; then
    echo "validate-dependabot: every lane is backed by a tracked manifest" >&2
    exit 0
fi
echo "validate-dependabot: FAILURES above" >&2
exit 1
