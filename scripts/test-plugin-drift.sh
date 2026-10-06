#!/usr/bin/env bash
# test-plugin-drift.sh — pins the four decisions in pull-plugin-drift.sh.
#
# Source-level and fixture-driven: synthetic `installed_plugins.json` files in a
# temp dir, no network, no `gh`, and the real user's state file is never read.
#
# THE ROWS, and why each is not obvious:
#
#   R01 CalVer compares FIELD-BY-FIELD AS INTEGERS. `2026.8.100` is newer than
#       `2026.8.94` and a string compare says the opposite — this repo is in
#       exactly that range today, so a lexical sort would report the newest pins
#       as the stalest and mark the genuinely stale ones current. This is the
#       row most likely to be "simplified" back, because a lexical compare is
#       right for every version below 10.
#   R02 A path with NO project entry lands in `no_entry`, never in the clean
#       set. Absent means it inherits user scope, which usually means the
#       `.claude/settings.json` declaration `setup-config` writes is missing, so
#       this checkout has no project pin and a machine without a user-scope
#       install resolves nothing locally (cloud sessions never read it; #468).
#       "Current by accident" and "current"
#       are different facts and only one survives being fixed.
#   R03 The pruned worktree/dead-path counts are EMITTED. 96 of 107 entries on
#       the machine this shipped from were agent worktrees. Filtering them is
#       what makes the output readable; reporting the count is what stops the
#       state file looking tidy forever.
#   R04 An unavailable reference makes every row NOT current. Unknown is never
#       a pass — the same rule the resolver consumers apply to a failed read.
#
# Every row is named by a mutant below, and the rows no mutant reddens are
# derived and compared to UNPINNED_ROWS.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/skills/repo-health/scripts/pull-plugin-drift.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "no scratch dir" >&2; exit 1; }

fails=0; asserts=0; seen=""
ROW_IDS="R01 R02 R03 R04"
UNPINNED_ROWS=""
FLIPPED="$WORK/flipped"; : >"$FLIPPED"

ok()  { echo "  ok    $1"; asserts=$((asserts + 1)); }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); asserts=$((asserts + 1)); }
row() { seen="$seen $1"; [ "$2" = 0 ] && ok "$1 $3" || bad "$1 $3"; }

# Two live checkouts, so a path must EXIST to be scored.
mkdir -p "$WORK/repo-old" "$WORK/repo-new"
mkdir -p "$WORK/mkt/.claude-plugin"
printf '{"version": "2026.8.94"}\n' >"$WORK/mkt/.claude-plugin/plugin.json"

fixture() { # <out> — the shared state file
    python3 - "$1" "$WORK" <<'PY'
import json, sys
out, work = sys.argv[1], sys.argv[2]
json.dump({"version": 1, "plugins": {"p@m": [
    {"scope": "user",    "version": "2026.8.100", "lastUpdated": "2026-09-04T00:00:00Z"},
    # THE DISAGREEMENT, and it only exists within one YYYY.M: against a
    # reference of 2026.8.94, `2026.8.100` is NEWER numerically and SMALLER as
    # text. Pick a reference in a later month and the two agree, which is how
    # the first edition of this fixture let M1 pass.
    {"scope": "project", "version": "2026.8.83",  "lastUpdated": "2026-08-18T00:00:00Z",
     "projectPath": work + "/repo-old"},
    {"scope": "project", "version": "2026.8.100", "lastUpdated": "2026-09-05T00:00:00Z",
     "projectPath": work + "/repo-new"},
    {"scope": "project", "version": "2026.8.83",  "lastUpdated": "2026-08-18T00:00:00Z",
     "projectPath": work + "/.claude/worktrees/agent-dead"},
    {"scope": "project", "version": "2026.8.83",  "lastUpdated": "2026-08-18T00:00:00Z",
     "projectPath": work + "/gone-forever"},
]}}, open(out, "w"))
PY
}
fixture "$WORK/state.json"

run() { # <script> -> JSON on stdout
    PLUGIN="p@m" STATE="$WORK/state.json" REFERENCE="${REF_OVERRIDE:-2026.8.94}" \
        bash "$1" "$WORK/asked-missing" 2>"$WORK/err"
}

score() { # <script> — emits the four rows for that source
    local out; out="$(run "$1")"
    seen=""
    python3 - "$out" "$WORK" <<'PY' >"$WORK/verdict"
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception as exc:
    print("R01 1 could not parse output: %s" % exc)
    print("R02 1 could not parse output"); print("R03 1 could not parse output")
    print("R04 1 could not parse output"); raise SystemExit
work = sys.argv[2]
rows = {r["path"]: r for r in d.get("projects", [])}
old, new = work + "/repo-old", work + "/repo-new"

# R01 — 2026.8.100 is behind 2026.9.4, and 2026.9.4 is current. A lexical
# compare calls the first current (".100" > ".4" as text) and so flips this.
good = (old in rows and new in rows
        and rows[old]["current"] is False and rows[new]["current"] is True)
print("R01 %d CalVer compares field-by-field as integers, not as text" % (0 if good else 1))

# R02 — the asked-about path does not exist as an entry.
ne = d.get("no_entry") or []
good = (work + "/asked-missing") in ne and (work + "/asked-missing") not in rows
print("R02 %d a path with no project entry lands in no_entry, never in the clean set" % (0 if good else 1))

# R03 — the worktree was pruned AND counted.
p = d.get("pruned") or {}
good = p.get("worktrees", 0) >= 1 and p.get("missing_paths", 0) >= 1
print("R03 %d pruned worktree and dead-path counts are emitted, not silently dropped" % (0 if good else 1))
PY
    # NOT `label`: `read` assigns through bash's dynamic scope and would
    # overwrite the caller's `local label`, blanking every mutant's name.
    while read -r id st rlabel; do row "$id" "$st" "$rlabel"; done <"$WORK/verdict"

    # R04 — with NO reference resolvable, nothing may read as current.
    local out4
    out4="$(REF_OVERRIDE="" PLUGIN="p@m" STATE="$WORK/state.json" \
        HOME="$WORK/nohome" bash "$1" 2>/dev/null)"
    if python3 -c "
import json,sys
d=json.loads(sys.argv[1])
ok = d['reference']['version'] is None and not any(r['current'] for r in d['projects']) \
     and not d['user_scope']['current']
sys.exit(0 if ok else 1)" "$out4" 2>/dev/null; then
        row R04 0 "an unavailable reference leaves every row NOT current"
    else
        row R04 1 "an unavailable reference was treated as a pass"
    fi
}

echo "plugin-drift: baseline"
score "$SRC"
base_fail=$fails
[ "$base_fail" = 0 ] && ok "the shipped source is clean over all 4 rows" \
    || bad "the shipped source is not clean — every mutant verdict below is measured against the wrong thing"

# --- mutants ------------------------------------------------------------------
mutants_run=0
# A mutant is scored by re-running `score` against the mutated source and
# reading its transcript, so a mutant that changes NO verdict is visible as an
# empty flip set rather than as a silent pass.
run_mut() { # <label> <named-row> <from> <to>
    local label="$1" named="$2" mut="$WORK/mut.sh" out="$WORK/mut.out" flips
    if ! python3 - "$SRC" "$mut" "$3" "$4" <<'PY'
import io, sys
src, dst, frm, to = sys.argv[1:5]
s = io.open(src, encoding="utf-8").read()
if s.count(frm) != 1:
    sys.stderr.write("occurrences=%d\n" % s.count(frm)); sys.exit(1)
io.open(dst, "w", encoding="utf-8").write(s.replace(frm, to))
PY
    then bad "$label — the mutation target did not match exactly once (stale mutant)"; return; fi
    mutants_run=$((mutants_run + 1))
    local keep_fails=$fails keep_asserts=$asserts
    fails=0; asserts=0
    score "$mut" >"$out" 2>&1
    flips="$(grep -oE '  FAIL  R[0-9]+' "$out" | awk '{print $2}' | sort -u | tr '\n' ' ')"
    fails=$keep_fails; asserts=$keep_asserts
    printf '%s\n' $flips >>"$FLIPPED"
    case " $flips " in
        *" $named "*) ok "$label reddens $named as declared (flips: ${flips% })" ;;
        *) bad "$label does NOT redden $named — it flips '${flips% }'" ;;
    esac
}

echo "plugin-drift: mutants"
run_mut "M1: versions compare as text" R01 \
    '    out = []
    for part in str(v).split("."):
        digits = "".join(c for c in part if c.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out)' \
    '    return str(v)'
run_mut "M2: a path with no entry is folded in as current" R02 \
    'no_entry = [p for p in asked if p not in best]' \
    'no_entry = []'
run_mut "M3: the pruned counts are dropped" R03 \
    '"pruned": {"worktrees": pruned_wt, "missing_paths": pruned_gone},' \
    '"pruned": {},'
run_mut "M4: an unresolvable reference reads as current" R04 \
    '        "current": bool(reference) and vkey(v) >= vkey(reference),' \
    '        "current": (not reference) or vkey(v) >= vkey(reference),'

# --- 5. the destructive-command warning, in the doc that carries it ------------
#
# NOT a row in the matrix above: those are scored from the script's JSON, and no
# mutation of the script can reach a sentence in SKILL.md. It carries its own
# proof instead, the way `reject()` does elsewhere in this repo — the predicate
# is run against a copy with the sentence removed, so a check that could never
# fail is itself a failure.
#
# WHY IT IS PINNED AT ALL. `claude plugin uninstall --scope project` does not
# only remove local state: it EDITS the repo's committed `.claude/settings.json`
# and empties `enabledPlugins`, stripping the declaration `setup-config` writes. Measured
# 2026-09-06 across 13 checkouts, 10 of which had the key silently deleted from
# a tracked file. It is the one command in this area that damages a repo, and
# the sentence warning about it is exactly the kind a later trim reads as
# belt-and-braces.
DOC="$ROOT/skills/repo-health/SKILL.md"
WARN='Never clear a pin with `claude plugin uninstall --scope project`'
EDITS='edits the repo'"'"'s committed'

asserts=$((asserts + 1))
if grep -qF -- "$WARN" "$DOC" && grep -qF -- "$EDITS" "$DOC"; then
    ok "repo-health/SKILL.md warns that uninstall --scope project edits the committed settings"
else
    bad "repo-health/SKILL.md has lost the uninstall --scope project warning, or the reason it gives"
fi

# The self-proof: with the sentence gone, the same predicate must fail.
sed "s/Never clear a pin with/A pin may be cleared with/" "$DOC" >"$WORK/doc-mut.md"
asserts=$((asserts + 1))
if grep -qF -- "$WARN" "$WORK/doc-mut.md"; then
    bad "the warning check is vacuous — it still matches a copy with the warning removed"
else
    ok "and removing that warning reddens the check rather than passing it"
fi

# --- the derived matrix -------------------------------------------------------
derived=""
for r in $ROW_IDS; do grep -qx "$r" "$FLIPPED" || derived="$derived $r"; done
derived="${derived# }"
asserts=$((asserts + 1))
if [ "$derived" = "$UNPINNED_ROWS" ]; then
    ok "the rows no mutant reddens are exactly the declared set ('$UNPINNED_ROWS')"
else
    bad "rows no mutant reddens: '$derived', declared: '$UNPINNED_ROWS' — a row nothing can redden proves nothing"
fi
asserts=$((asserts + 1))
[ "$mutants_run" = 4 ] && ok "every declared mutant ran (4 of 4)" \
    || bad "$mutants_run of 4 mutants ran — the matrix is measured against a partial set"

if [ "$fails" -ne 0 ]; then
    echo "test-plugin-drift: FAILED ($fails)" >&2; exit 1
fi
echo "Plugin drift tests: all green ($asserts assertions, $mutants_run mutants)"
