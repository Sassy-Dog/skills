#!/usr/bin/env bash
# pull-plugin-drift.sh — which checkouts are running a STALE plugin.
# Read-only. No network, no `gh`. Emits a single JSON object on stdout.
#
# Env:
#   PLUGIN    plugin key (default: sassy-dog@skills)
#   STATE     installed_plugins.json (default: ~/.claude/plugins/installed_plugins.json)
#   REFERENCE version to compare against; default is the marketplace clone's own
#             manifest, which is what `claude plugin update` would resolve to
#
# Args: zero or more absolute checkout paths to report on explicitly, INCLUDING
# ones with no project entry — see "absent is not current" below.
#
# Output shape:
#   { "plugin": "...", "reference": {"version": "...", "source": "...", "stale_clone_hint": bool},
#     "user_scope": {"version": "..."|null, "current": bool},
#     "projects":  [ {"path": "...", "version": "...", "last_updated": "...", "current": bool} ],
#     "behind":    [ same shape, the subset that is not current ],
#     "no_entry":  [ "<path>", ... ],   # asked about, inherits user scope
#     "pruned":    {"worktrees": N, "missing_paths": N} }
#
# WHY THIS EXISTS. A project-scope install pins the version resolved when that
# checkout was first opened and NOTHING re-resolves it. `claude plugin list`
# reports user and project scope separately and they drift independently, so a
# repo can sit on a months-old plugin while `plugin update` reports success at
# user scope. Measured 2026-09-06: user scope was 2026.9.4 while `platform` and
# `sassydog-web` were pinned at 2026.8.83 and `velovate-web` at 2026.8.94 — and
# only 2026.9.4 carried the feature about to be verified in those very repos.
# The pin is silent, has no expiry, and is the shape this repo's own convention
# calls out: a value nothing re-derives.
#
# THREE THINGS THAT LOOK LIKE DETAIL AND ARE NOT:
#
#   1. VERSIONS COMPARE NUMERICALLY, FIELD BY FIELD. CalVer is `YYYY.M.N` and a
#      string compare gets it backwards the moment N reaches three digits:
#      "2026.8.100" < "2026.8.94" lexically, which is exactly the range this
#      repo is in. A lexical sort here would report the NEWEST pins as the
#      stalest and hide the real ones.
#   2. ABSENT IS NOT CURRENT. A checkout with no project entry inherits user
#      scope — which usually means it is missing the `.claude/settings.json`
#      declaration `setup-config` writes, so this checkout has no project pin
#      and a machine without a user-scope install resolves nothing locally
#      (cloud sessions never read it; #468). It is reported under
#      `no_entry`, never folded into the clean set: "current by accident" and
#      "current" are different facts, and only one of them survives being fixed.
#   3. THE PRUNED COUNTS ARE REPORTED, not silently dropped. 96 of 107 entries
#      here were agent worktrees and 94 pointed at paths that no longer exist.
#      Hiding them makes the output readable; hiding the COUNT makes it look
#      like the state file is tidy, which is how nobody ever prunes it.
#
# The reference is the marketplace CLONE's manifest rather than the version-of-
# record on `main`, because the clone is what an update would actually install:
# a clone behind `main` means `plugin update` cannot fix a drift yet, and
# `marketplace update` must run first. `stale_clone_hint` is true when a cached
# install is NEWER than the clone, which is the only in-band evidence of that.

set -uo pipefail

PLUGIN="${PLUGIN:-sassy-dog@skills}"
STATE="${STATE:-$HOME/.claude/plugins/installed_plugins.json}"
REFERENCE="${REFERENCE:-}"

command -v python3 >/dev/null 2>&1 || {
    echo "skipped: python3 not installed" >&2; exit 10; }
[ -f "$STATE" ] || {
    echo "skipped: no installed_plugins.json at $STATE" >&2; exit 10; }

PLUGIN="$PLUGIN" STATE="$STATE" REFERENCE="$REFERENCE" python3 - "$@" <<'PY'
import json, os, sys

plugin = os.environ["PLUGIN"]
state = os.environ["STATE"]
ref_override = os.environ.get("REFERENCE") or ""
asked = [os.path.abspath(a) for a in sys.argv[1:]]

def vkey(v):
    # Field-by-field integers. See note 1 in the header: a lexical compare
    # inverts 2026.8.100 vs 2026.8.94.
    out = []
    for part in str(v).split("."):
        digits = "".join(c for c in part if c.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)

try:
    doc = json.load(open(state))
except Exception as exc:
    sys.stderr.write("skipped: %s is not readable JSON: %s\n" % (state, exc))
    sys.exit(10)

entries = (doc.get("plugins") or {}).get(plugin) or []

marketplace = plugin.split("@")[-1]
clone = os.path.expanduser(
    "~/.claude/plugins/marketplaces/%s/.claude-plugin/plugin.json" % marketplace)
reference, ref_source = ref_override, "env"
if not reference:
    try:
        reference = json.load(open(clone))["version"]
        ref_source = "marketplace-clone"
    except Exception:
        reference, ref_source = "", "unavailable"

user_version = None
projects, pruned_wt, pruned_gone = [], 0, 0
for e in entries:
    if e.get("scope") == "user":
        if user_version is None or vkey(e.get("version", "")) > vkey(user_version):
            user_version = e.get("version")
        continue
    path = e.get("projectPath") or ""
    if "/.claude/worktrees/" in path:
        pruned_wt += 1
        continue
    if not path or not os.path.isdir(path):
        pruned_gone += 1
        continue
    projects.append(e)

# One row per path: the most recently updated entry wins.
best = {}
for e in projects:
    p = e["projectPath"]
    if p not in best or (e.get("lastUpdated") or "") > (best[p].get("lastUpdated") or ""):
        best[p] = e

def row(e):
    v = e.get("version") or ""
    return {
        "path": e["projectPath"],
        "version": v,
        "last_updated": (e.get("lastUpdated") or "")[:10],
        # No reference means UNKNOWN, never "current" — same rule the resolver
        # consumers use for an unreadable read.
        "current": bool(reference) and vkey(v) >= vkey(reference),
    }

rows = sorted((row(e) for e in best.values()), key=lambda r: r["path"])
behind = [r for r in rows if not r["current"]]
no_entry = [p for p in asked if p not in best]

newest_installed = max([vkey(r["version"]) for r in rows] + [vkey(user_version or "0")])
stale_clone = bool(reference) and newest_installed > vkey(reference)

print(json.dumps({
    "plugin": plugin,
    "reference": {
        "version": reference or None,
        "source": ref_source,
        "stale_clone_hint": stale_clone,
    },
    "user_scope": {
        "version": user_version,
        "current": bool(reference) and bool(user_version)
                   and vkey(user_version) >= vkey(reference),
    },
    "projects": rows,
    "behind": behind,
    "no_entry": no_entry,
    "pruned": {"worktrees": pruned_wt, "missing_paths": pruned_gone},
}, indent=2))
PY
