#!/usr/bin/env bash
# stamp-version.sh — the release-stamp flow: resolve this repo's CalVer and
# write it into every plugin-manifest version field (org Versioning spec v1.0,
# platform#397, §7 committed-manifest row; adopted via #31).
#
# The committed `version` in .claude-plugin/plugin.json is the
# VERSION-OF-RECORD — this script emits it at release time; commit the result
# in the release PR. The stamping commit itself changes the commit count that
# produced the stamped value: §2 idempotency is formally unsatisfiable for a
# committed manifest and is WAIVED per §7 — the manifest is authoritative.
#
# §4 mint analog — the "registry" probed is the committed manifest itself:
#   candidate = scripts/get-version-info.sh   (single algorithm owner, §3)
#   current   = .claude-plugin/plugin.json .version
#   current == candidate                     -> reuse (idempotent re-run)
#   current CalVer, same YYYY.M train,
#     current.patch >= candidate.patch       -> bump: train.(current.patch+1)
#       (the committed-manifest analog of "tag exists at a different commit";
#        also protects a stamp run from a stale checkout — never go backwards)
#   current CalVer from a LATER month        -> FAIL closed (bad clock or
#                                               stale checkout; never mint blind)
#   otherwise                                -> stamp candidate
#
# ⚠️ IRREVERSIBILITY RATCHET (§7): publishing CalVer-as-semver is one-way —
# no 0.x/1.x may ever follow (ordering consumers read it as a permanent
# downgrade). This script refuses to write any non-CalVer value, pinned or
# computed; the CI preflight gate enforces the same on the committed manifest.
#
# Multi-plugin rule (§7): one repo-wide CalVer stamped identically into every
# manifest version field. marketplace.json entries carry no version today; if
# one is ever added, this script stamps it with the same value.
#
# Usage:
#   bash scripts/stamp-version.sh             # resolve + write
#   bash scripts/stamp-version.sh --dry-run   # resolve + report, no write
#
# Output contract (stdout; progress on stderr):
#   version=<resolved>
#   action=stamp|reuse
#
# MARKETING_VERSION pin: consumed verbatim, never auto-bumped — a pin that is
# not strictly above the committed value fails loudly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$ROOT"

PLUGIN_MANIFEST=".claude-plugin/plugin.json"
MARKETPLACE_MANIFEST=".claude-plugin/marketplace.json"
CALVER_RE='^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *)
        echo "usage: bash scripts/stamp-version.sh [--dry-run]" >&2
        exit 64
        ;;
esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

candidate=$(bash "$SCRIPT_DIR/get-version-info.sh")
current=$(jq -r '.version // empty' "$PLUGIN_MANIFEST")

if ! grep -qE "$CALVER_RE" <<<"$candidate"; then
    echo "error: resolved version '$candidate' is not CalVer (YYYY.M.P)." >&2
    echo "       CalVer adoption is a one-way ratchet — no 0.x/1.x may ever follow (docs/VERSIONING.md)." >&2
    exit 1
fi

version="$candidate"
action="stamp"

if [ "$current" = "$candidate" ]; then
    action="reuse"
    echo "manifest already at $current — reusing (idempotent re-run)" >&2
elif grep -qE "$CALVER_RE" <<<"$current"; then
    cur_year="${current%%.*}"
    cur_rest="${current#*.}"
    cur_month="${cur_rest%%.*}"
    cur_patch="${current##*.}"
    new_year="${candidate%%.*}"
    new_rest="${candidate#*.}"
    new_month="${new_rest%%.*}"
    new_patch="${candidate##*.}"

    if [ "$cur_year" -gt "$new_year" ] ||
        { [ "$cur_year" -eq "$new_year" ] && [ "$cur_month" -gt "$new_month" ]; }; then
        echo "error: committed version $current is from a LATER month than resolved $candidate." >&2
        echo "       Backwards stamp (bad clock or stale checkout) — refusing to mint blind." >&2
        exit 1
    fi
    if [ "$cur_year" -eq "$new_year" ] && [ "$cur_month" -eq "$new_month" ] &&
        [ "$cur_patch" -ge "$new_patch" ]; then
        if [ -n "${MARKETING_VERSION:-}" ]; then
            echo "error: pinned MARKETING_VERSION=$candidate is not above committed $current." >&2
            echo "       A pin is consumed verbatim and never auto-bumped — pick a different pin." >&2
            exit 1
        fi
        version="${new_year}.${new_month}.$((cur_patch + 1))"
        echo "committed $current >= computed $candidate in the same train — bumping to $version (§4 ladder)" >&2
    fi
fi

if [ "$action" = "stamp" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "dry run: would stamp $PLUGIN_MANIFEST: $current -> $version" >&2
    else
        tmp="${PLUGIN_MANIFEST}.tmp"
        jq --arg v "$version" '.version = $v' "$PLUGIN_MANIFEST" > "$tmp"
        mv "$tmp" "$PLUGIN_MANIFEST"
        echo "stamped $PLUGIN_MANIFEST: $current -> $version" >&2

        # One repo-wide CalVer, stamped identically into every manifest that
        # carries a version field (none in marketplace.json today).
        if [ "$(jq '[.plugins[]? | has("version")] | any' "$MARKETPLACE_MANIFEST")" = "true" ]; then
            tmp="${MARKETPLACE_MANIFEST}.tmp"
            jq --arg v "$version" \
                '.plugins |= map(if has("version") then .version = $v else . end)' \
                "$MARKETPLACE_MANIFEST" > "$tmp"
            mv "$tmp" "$MARKETPLACE_MANIFEST"
            echo "stamped $MARKETPLACE_MANIFEST plugins[].version -> $version" >&2
        fi
    fi
fi

printf 'version=%s\naction=%s\n' "$version" "$action"
