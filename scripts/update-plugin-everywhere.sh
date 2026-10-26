#!/usr/bin/env bash
# update-plugin-everywhere.sh — bring EVERY installed copy of the plugin on this
# machine up to the marketplace's current content, and prove it by content.
#
# Why this exists: Claude Code registers a plugin once PER SCOPE in
# ~/.claude/plugins/installed_plugins.json, and every repo whose
# .claude/settings.json (committed, or local and ignored as in this public repo)
# declares `enabledPlugins` gets its own `project` entry the first time a session opens there — pinned to
# whatever was current THEN. `claude plugin update` acts on exactly one entry
# (default `user`), so there is no system-wide command. Measured 2026-09-19:
# user scope at 2026.9.43, six live repos at 2026.9.4 (two weeks stale), this
# repo's own project pin at 2026.9.36, and 35 dead entries left by torn-down
# agent worktrees. README "Updating / Troubleshooting" documents the per-copy
# procedure; this script runs it over every copy at once:
#
#   1. refresh the marketplace clone FIRST, even on a dry run — load-bearing,
#      not tidiness: an unrefreshed clone matches a stale cache exactly and
#      reports "current" (README measured 0 diffs before the refresh, 28 after)
#   2. back up installed_plugins.json (timestamped, beside it)
#   3. `plugin update --scope user`, then `--scope project` from INSIDE each
#      live NON-worktree project path (the scope flag from the target cwd is
#      the only thing that moves a project pin)
#   4. delete registry entries whose projectPath no longer exists, and entries
#      whose projectPath is a LINKED GIT WORKTREE — a pin is re-created at
#      whatever is current the next time a session opens there, and this is the
#      ONLY safe way to clear them: `claude plugin uninstall --scope project`
#      rewrites the repo's COMMITTED settings.json. A linked worktree cannot be
#      updated at all (#590): `claude plugin update --scope project` run inside
#      one resolves to the MAIN checkout's entry, prints "already at the latest
#      version" and leaves the worktree's own entry stale forever (measured
#      2026-10-25: a brewslate agent worktree and `routines-runner-image-queue`,
#      at 2026.10.52 and 2026.10.64 beside a 2026.10.101 current). Detected by
#      the worktree's git dir differing from its common dir (`rev-parse
#      --absolute-git-dir` vs `--git-common-dir`); a submodule, whose `.git` is
#      also a file, has the same dir for both and is NOT a worktree. The dry run
#      reports them under their own count. Gate: scripts/test-update-plugin-everywhere.sh.
#   5. verify every surviving entry BY CONTENT — `diff -rq` of skills/, agents/
#      and scripts/ against the clone — never by version string: the manifest
#      is stamped only on release PRs while content lands on every merge, so
#      a cache and main routinely share one version over different files
#      (issue #296). Any diff output, or a directory that could not be
#      compared, is STALE.
#   6. name the one stale state the installer cannot fix: every copy already
#      AT the clone's stamped version yet differing by content. `claude plugin
#      update` is version-keyed — "already at the latest version" and nothing
#      copied — so the remedy is a release stamp (`scripts/stamp-version.sh` in
#      a `chore(release)` PR), after which the next run installs a fresh
#      version directory. Dogfooded 2026-09-19: seven pins moved 2026.9.4 →
#      2026.9.43 and every one stayed stale, because the two skills merged
#      that day were newer than the 2026.9.43 stamp.
#
# Without `--apply` it only refreshes the clone (a git pull of the marketplace
# checkout) and reports. With `--apply` it edits installed_plugins.json (after
# the backup) and runs the `claude plugin update` commands. It never touches a
# repo's own files. Exit 0 when every surviving copy is current; 1 when any is
# stale or could not be compared; 2 on usage error or a missing tool.
#
# Sessions already open keep running the old copy until restarted — the
# script says so at the end, every time, because that is the silent half.
set -uo pipefail

PLUGIN="sassy-dog@skills"
MARKET="skills"
APPLY=0
REGISTRY="$HOME/.claude/plugins/installed_plugins.json"
CLONE="$HOME/.claude/plugins/marketplaces/$MARKET"

usage() {
    cat >&2 <<EOF
usage: $0 [--apply] [--plugin <name@marketplace>] [--marketplace <name>]
  --apply         run the updates and prune dead entries (default: report only)
  --plugin        marketplace-qualified plugin name (default: $PLUGIN)
  --marketplace   marketplace name (default: $MARKET)
EOF
    exit 2
}
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --plugin) shift; [ $# -gt 0 ] || usage; PLUGIN="$1" ;;
        --marketplace) shift; [ $# -gt 0 ] || usage; MARKET="$1"; CLONE="$HOME/.claude/plugins/marketplaces/$MARKET" ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
    shift
done

for tool in jq claude diff git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done
[ -r "$REGISTRY" ] || { echo "no registry at $REGISTRY" >&2; exit 2; }
[ -d "$CLONE" ] || { echo "no marketplace clone at $CLONE — run: claude plugin marketplace add" >&2; exit 2; }

# --- helpers --------------------------------------------------------------------
entries() {  # scope \t version \t projectPath \t installPath, one per line
    jq -r --arg p "$PLUGIN" '
      .plugins[$p] // [] | .[]
      | [.scope, (.version // "?"), (.projectPath // "-"), (.installPath // "-")] | @tsv
    ' "$REGISTRY"
}

is_linked_worktree() {  # $1 = project path -> 0 when it is a linked git worktree
    local p="$1" gd cd_
    gd="$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
    cd_="$(git -C "$p" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$cd_" in /*) ;; *) cd_="$p/$cd_" ;; esac
    gd="$(cd "$gd" 2>/dev/null && pwd -P)" || return 1
    cd_="$(cd "$cd_" 2>/dev/null && pwd -P)" || return 1
    [ "$gd" != "$cd_" ]
}

project_kind() {  # $1 = project path -> dead | worktree | live
    if [ ! -d "$1" ]; then echo dead
    elif is_linked_worktree "$1"; then echo worktree
    else echo live; fi
}

content_state() {  # $1 = installPath → prints current | stale | not-compared
    local ip="$1" d out state="current"
    for d in skills agents scripts; do
        if [ ! -d "$ip/$d" ] || [ ! -d "$CLONE/$d" ]; then state="not-compared"; continue; fi
        out="$(diff -rq "$CLONE/$d" "$ip/$d" 2>&1)"
        [ -z "$out" ] || state="stale"
    done
    printf '%s' "$state"
}

print_table() {  # $1 = heading
    echo "== $1 =="
    printf '%-8s %-12s %-13s %s\n' scope version content projectPath
    while IFS=$'\t' read -r scope version ppath ipath; do
        local st
        st="$(content_state "$ipath")"
        if [ "$scope" = "project" ]; then
            case "$(project_kind "$ppath")" in
                dead) st="DEAD" ;;
                worktree) st="WORKTREE" ;;
            esac
        fi
        printf '%-8s %-12s %-13s %s\n' "$scope" "$version" "$st" "$ppath"
    done < <(entries)
}

# --- 1. refresh the clone, then measure --------------------------------------------
echo "== refresh marketplace clone =="
claude plugin marketplace update "$MARKET" 2>&1 | sed 's/^/  /'
echo
print_table "before"

if [ "$APPLY" -eq 0 ]; then
    dead=0; wt=0; live=0
    while read -r p; do
        case "$(project_kind "$p")" in dead) dead=$((dead + 1)) ;; worktree) wt=$((wt + 1)) ;; *) live=$((live + 1)) ;; esac
    done < <(entries | awk -F'\t' '$1=="project"{print $3}')
    echo
    echo "dry run: would update user scope + $live live project scope(s), prune $dead dead entr(y|ies) and $wt linked-worktree pin(s) (re-created on the next open)."
    echo "re-run with --apply."
    exit 0
fi

# --- 2. backup + refresh the clone ------------------------------------------------
stamp="$(date +%Y%m%d-%H%M%S)"
cp "$REGISTRY" "$REGISTRY.bak-$stamp" || { echo "backup failed" >&2; exit 2; }
echo
echo "backup: $REGISTRY.bak-$stamp"

# --- 3. update user scope, then every live project scope -------------------------
echo "== update user scope =="
claude plugin update "$PLUGIN" --scope user 2>&1 | sed 's/^/  /'

while IFS=$'\t' read -r scope version ppath ipath; do
    [ "$scope" = "project" ] || continue
    [ "$(project_kind "$ppath")" = live ] || continue
    echo "== update project scope: $ppath (was $version) =="
    ( cd "$ppath" && claude plugin update "$PLUGIN" --scope project 2>&1 | sed 's/^/  /' )
done < <(entries)

# --- 4. prune dead project entries ---------------------------------------------
echo "== prune dead project entries and linked-worktree pins =="
tmp="$(mktemp)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -f "$tmp"' EXIT
pruned=0
keep='[]'
while IFS=$'\t' read -r scope version ppath ipath; do
    kind=live
    [ "$scope" = "project" ] && kind="$(project_kind "$ppath")"
    if [ "$kind" = dead ]; then
        echo "  removed: $ppath ($version)"
        pruned=$((pruned + 1))
    elif [ "$kind" = worktree ]; then
        echo "  removed worktree pin: $ppath ($version) — re-created on the next open there"
        pruned=$((pruned + 1))
    else
        keep="$(jq -c --arg s "$scope" --arg p "$ppath" '. + [{scope:$s, projectPath:$p}]' <<<"$keep")"
    fi
done < <(entries)
# Re-derive the kept list from the live file so no field is lost: keep every
# entry whose (scope, projectPath) survived, in original order.
jq --arg p "$PLUGIN" --argjson keep "$keep" '
  .plugins[$p] |= map(
    select(
      (.scope != "project") or
      ((.projectPath // "-") as $pp | ($keep | map(select(.scope=="project" and .projectPath==$pp)) | length) > 0)
    )
  )
' "$REGISTRY" >"$tmp" && jq -e . "$tmp" >/dev/null && cp "$tmp" "$REGISTRY" \
    || { echo "registry rewrite failed — backup left at $REGISTRY.bak-$stamp" >&2; exit 2; }
echo "  pruned $pruned"

# --- 5. after: verify by content ------------------------------------------------
echo
print_table "after"
stale="$(entries | while IFS=$'\t' read -r scope version ppath ipath; do
    if [ "$scope" = "project" ] && [ "$(project_kind "$ppath")" != live ]; then continue; fi
    st="$(content_state "$ipath")"; [ "$st" = "current" ] || echo "$ppath"
done | wc -l | tr -d ' ')"
echo
echo "RESTART REQUIRED: every open Claude Code session keeps running the copy it loaded until restarted."
if [ "$stale" -eq 0 ]; then
    echo "all surviving copies are current by content."
    exit 0
fi
clone_version="$(jq -r '.version // "?"' "$CLONE/.claude-plugin/plugin.json" 2>/dev/null)"
behind_stamp="$(entries | while IFS=$'\t' read -r scope version ppath ipath; do
    if [ "$scope" = "project" ] && [ "$(project_kind "$ppath")" != live ]; then continue; fi
    [ "$version" = "$clone_version" ] || echo "$ppath"
done | wc -l | tr -d ' ')"
if [ "$behind_stamp" -eq 0 ]; then
    echo "$stale cop(y|ies) stale, and every one is already at the clone's stamped version ($clone_version):"
    echo "  main has merged content newer than that stamp, and \`claude plugin update\` is version-keyed, so it"
    echo "  copies nothing. Remedy: stamp a release — \`bash scripts/stamp-version.sh\` in a chore(release) PR"
    echo "  (docs/VERSIONING.md) — then re-run this script."
else
    echo "$stale cop(y|ies) still stale or not compared — see the table."
fi
exit 1
