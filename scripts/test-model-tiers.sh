#!/usr/bin/env bash
# test-model-tiers.sh — every dispatched agent runs at a TIER, and every tier
# binding in the tree agrees with the one table in docs/MODEL-TIERS.md.
#
# Why this exists: model choice used to be implicit. `take-it` passed no model,
# so its workers inherited the session's; `dispatch-ready` pinned workers to
# Opus as "the cheaper tier relative to the coordinator's session model", a
# premise that died the day the session model became Opus; and nothing set a
# model for review at all, so the orchestrator and up to nine reviewers per PR
# inherited Opus too. Measured over 14 days: 60 worker transcripts and 666
# review-agent transcripts, almost all Opus, burning a weekly budget in 2–3
# days. The fix names a tier at every dispatch site, and this gate is what
# stops it quietly decaying back into inheritance.
#
# The tier is a harness-neutral word (astra/sol/terra/luna) because the skills
# must port to harnesses other than Claude Code. Claude Code and omp both read
# a `model:` frontmatter key but their value spaces are disjoint (`sonnet` vs
# `@task`), so a tier can never live in frontmatter: it is bound at the
# DISPATCH SITE, inline, in one fixed form a cold agent can act on without
# opening another file. Inline copies are safe only because this gate
# re-derives each one from the table — the owner-plus-gate shape this repo uses
# for its label taxonomy, rather than a transcription left to drift.
#
# Five properties, over every tracked Markdown file under skills/ and agents/:
#
#   1. The table parses, and has a row for each of the four tiers.
#   2. Every inline binding — tier `X` (Claude Code: `model: "A"` · omp:
#      `model: "@R"`) — names a tier in the table, with exactly that row's
#      Claude Code alias and omp role.
#   3. No bare model choice survives outside a binding — an alias
#      (`opus|sonnet|haiku|fable`) or a full `claude-*` model id, under a
#      YAML-style `model:` or a JSON-style `"model":` key, in either quote
#      style — `model: 'opus'` was once a gap. A bare choice is
#      Claude-only and nobody can rebind it from the table — the shape
#      `dispatch-ready`'s Opus pin had.
#   4. No agents/*.md carries `model:` frontmatter. The dispatch site owns the
#      tier; a frontmatter model is harness-specific and silently loses to (or
#      silently overrides) the site, depending on the harness.
#   5. Each REQUIRED dispatch site still carries its tier, counted PER SITE:
#      the `required` table holds the minimum number of bindings of each tier
#      per file. Removing a binding breaks nothing visible — the agent just
#      inherits the session model again — so presence is asserted, and it is
#      counted rather than merely looked for, because two files bind the same
#      tier twice (take-it's `sol` at step 6 and in §6; the orchestrator's
#      `terra` in Step 3 and in the Parent recovery batch). A per-file "is the
#      tier present anywhere" check let either copy be deleted green, and one of
#      them is Step 3 — the fan-out every PR review takes. The table is the
#      enumerated member list the repo's count rule asks for: a claim that
#      "every dispatch site is tiered" means exactly these.
#
# Wrapping: prose wraps at ~100 columns and take-it's worker template is a
# blockquote, so a binding routinely splits across lines behind `> `. Each file
# is flattened (quote markers stripped, whitespace collapsed) before matching,
# the same treatment the other prose gates give wrapped text.
#
# Mutation-proven below against ten mutants, each of which must FAIL:
#   M1 a binding's Claude Code alias flipped (terra → opus)   -> property 2
#   M2 dispatch-ready's bare `model: "opus"` pin restored     -> property 3
#   M3 an agent given `model: sonnet` frontmatter             -> property 4
#   M4 send-it's `sol` binding deleted                        -> property 5
#   M5 the table's terra row rebound to haiku, sites untouched -> property 2
#   M6 only the orchestrator's Step-3 `terra` binding removed  -> property 5
#   M7 a JSON-style `"model": "claude-sonnet-5"` added         -> property 3
#   M8 a single-quoted `'model': 'opus'` added                 -> property 3
#   M9 the isolation probe worker's `terra` binding removed    -> property 5
#   M10 dispatch-ready's own isolation-probe `terra` binding removed -> property 5 (2x needed)
# A gate that passes a mutant is vacuous for that property. Each mutant must
# also fail FOR ITS OWN REASON: an unmutated control copy has to pass first,
# and each mutant's failure output has to name its property. Without both, a
# copy broken in some unrelated way fails every mutant at once, and the whole
# proof reads green while measuring nothing. That is not hypothetical: the
# first draft built its copies from `git ls-files` while the new table was not
# yet tracked, so every copy lacked it, and all five mutants "failed as they
# must" on the missing table alone — one of them without its mutation ever
# having applied.
#
# Source-level: python3 stdlib, no gh, no network.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

command -v python3 >/dev/null 2>&1 || {
    echo "model-tier tests: python3 not found" >&2
    exit 1
}

FAILED=0
ok() { echo "  ok    $1" >&2; }
bad() {
    echo "  FAIL  $1" >&2
    FAILED=1
}

CHECKER=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -f "$CHECKER"; rm -rf "$WORK"' EXIT

cat >"$CHECKER" <<'PY'
import pathlib, re, subprocess, sys

root = pathlib.Path(sys.argv[1])
problems = []

# --- 1. the table ------------------------------------------------------------
table_path = root / "docs" / "MODEL-TIERS.md"
row_re = re.compile(r"^\|\s*`(\w+)`\s*\|\s*(\d+)\s*\|\s*`(\w+)`\s*\|\s*`(@\w+)`\s*\|", re.M)
table = {}
if table_path.is_file():
    for tier, _rank, cc, omp in row_re.findall(table_path.read_text()):
        table[tier] = (cc, omp)
else:
    problems.append("docs/MODEL-TIERS.md is missing")
for tier in ("astra", "sol", "terra", "luna"):
    if tier not in table:
        problems.append(f"table has no row for tier `{tier}`")

# --- the scan set: tracked *.md under skills/ and agents/ --------------------
def tracked(pattern):
    out = subprocess.run(["git", "-C", str(root), "ls-files", pattern],
                         capture_output=True, text=True).stdout.split()
    return [root / p for p in out]

files = tracked("skills/*.md") + tracked("agents/*.md")
if not files:
    # an empty scan set would pass every property below vacuously
    problems.append("scan set is empty — every property below would pass vacuously")

def flatten(text):
    lines = [re.sub(r"^\s*(>\s?)+", "", ln) for ln in text.splitlines()]
    return re.sub(r"\s+", " ", " ".join(lines))

bind_re = re.compile(
    r"tier `(\w+)` \(Claude Code: `model: \"(\w+)\"` · omp: `model: \"(@\w+)\"`\)")
bare_re = re.compile(
    r"[\"']?model[\"']?\s*:\s*[\"']?(opus|sonnet|haiku|fable|claude-[\w.-]+)\b")

from collections import Counter
tiers_by_file = {}
n_bindings = 0
for f in files:
    rel = str(f.relative_to(root))
    flat = flatten(f.read_text())
    found = Counter()
    for tier, cc, omp in bind_re.findall(flat):
        n_bindings += 1
        found[tier] += 1
        # --- 2. each binding agrees with its row -----------------------------
        if tier not in table:
            problems.append(f"{rel}: binds unknown tier `{tier}`")
        elif (cc, omp) != table[tier]:
            problems.append(
                f"{rel}: tier `{tier}` bound to Claude Code `{cc}` · omp `{omp}`, "
                f"table says `{table[tier][0]}` · `{table[tier][1]}`")
    tiers_by_file[rel] = found
    # --- 3. no bare alias outside a binding --------------------------------
    for m in bare_re.finditer(bind_re.sub("", flat)):
        problems.append(f"{rel}: bare `{m.group(0)}` outside a tier binding")
    # --- 4. no model: frontmatter on agents --------------------------------
    if rel.startswith("agents/"):
        fm = re.match(r"\A---\n(.*?)\n---", f.read_text(), re.S)
        if fm and re.search(r"^model:", fm.group(1), re.M):
            problems.append(f"{rel}: carries `model:` frontmatter — the dispatch site owns the tier")

if n_bindings == 0:
    problems.append("no tier bindings found anywhere — the binding pattern matches nothing")

# --- 5. required dispatch sites keep their tier -------------------------------
# Minimum bindings per (file, tier). Each count is a set of dispatch sites:
required = {
    # §5 worker dispatch (terra); step-6 orchestrator + §6 coordinator gate (sol ×2)
    "skills/take-it/SKILL.md": {"terra": 1, "sol": 2},
    # the isolation probe worker (#451): a dispatch site that lives in the reference doc §5 points to
    "skills/take-it/references/isolation-confirmation.md": {"terra": 1},
    # §5 worker model policy (terra) + §5's isolation probe (terra, #452); §2 coordinator review (sol)
    "skills/dispatch-ready/SKILL.md": {"terra": 2, "sol": 1},
    # §4 review gate
    "skills/send-it/SKILL.md": {"sol": 1},
    # Step 3 fan-out + Parent recovery batch
    "agents/pr-review-orchestrator.md": {"terra": 2},
    # Phase 1 audit fan-out
    "skills/assess-it/SKILL.md": {"terra": 1},
    # audit Dispatch rule + refute-pass skeptics
    "skills/assess-it/orchestration.md": {"terra": 2},
    # org-sweep subagent fan-out
    "skills/whats-on-fire/references/cloud-fallback.md": {"terra": 1},
}
for rel, need in required.items():
    have = tiers_by_file.get(rel, Counter())
    for tier, n in sorted(need.items()):
        if have[tier] < n:
            problems.append(
                f"{rel}: required dispatch tier `{tier}` bound {have[tier]}x, needs at least {n}x")

for p in problems:
    print(p)
print(f"BINDINGS {n_bindings}")
sys.exit(1 if problems else 0)
PY

# --- the real tree ------------------------------------------------------------
out=$(python3 "$CHECKER" "$ROOT")
status=$?
n=$(printf '%s\n' "$out" | sed -n 's/^BINDINGS //p')
if [ "$status" = 0 ]; then
    ok "table parses with all four tiers; $n inline bindings agree with it"
    ok "no bare model alias outside a binding; no agent carries model: frontmatter"
    ok "every required dispatch site carries its tier"
else
    printf '%s\n' "$out" | grep -v '^BINDINGS ' | while IFS= read -r line; do bad "$line"; done
fi

# --- mutation proof: each mutant must FAIL, for its own reason ----------------
# A copy of just what the checker reads, as a throwaway git repo so its
# `git ls-files` scan behaves exactly as it does on the real tree.
make_copy() {
    local dst="$WORK/$1"
    mkdir -p "$dst"
    (cd "$ROOT" && git ls-files 'skills/*.md' 'agents/*.md') |
        while IFS= read -r p; do
            mkdir -p "$dst/$(dirname "$p")"
            cp "$ROOT/$p" "$dst/$p"
        done
    # The table is read by path, never via ls-files — copy it by path too, or
    # a not-yet-tracked table silently vanishes from every copy.
    mkdir -p "$dst/docs"
    cp "$ROOT/docs/MODEL-TIERS.md" "$dst/docs/MODEL-TIERS.md"
    git -C "$dst" init -q
    git -C "$dst" add -A >/dev/null 2>&1
    printf '%s' "$dst"
}

# Mutate in place; exit non-zero when the anchor is absent, so a mutant that
# never applied is reported as broken rather than counted as a proof.
mutate() { # mutate <file> <regex> <replacement>
    python3 - "$1" "$2" "$3" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
new, n = re.subn(sys.argv[2], lambda _m: sys.argv[3], s, count=1)
if not n:
    sys.exit(1)
p.write_text(new)
PY
}

# expect_fail <name> <copy dir> <substring its failure must contain>
expect_fail() {
    local name=$1 dst=$2 why=$3 out
    git -C "$dst" add -A >/dev/null 2>&1
    if out=$(python3 "$CHECKER" "$dst" 2>&1); then
        bad "$name: mutant PASSED — that property is vacuous"
    elif printf '%s' "$out" | grep -qF -- "$why"; then
        ok "$name: fails, naming its own property"
    else
        bad "$name: fails, but NOT for its own reason (wanted '$why') — the proof measures something else"
    fi
}

d=$(make_copy control)
if python3 "$CHECKER" "$d" >/dev/null 2>&1; then
    ok "control: an unmutated copy passes, so each mutant below fails for its mutation"
else
    bad "control: an UNMUTATED copy fails — every mutant below would 'fail' vacuously"
fi

d=$(make_copy m1)
mutate "$d/skills/take-it/SKILL.md" 'Claude Code: `model: "sonnet"`' 'Claude Code: `model: "opus"`' ||
    bad "M1: mutation did not apply"
expect_fail "M1 flipped binding alias" "$d" 'table says'

d=$(make_copy m2)
printf '\nPass `model: "opus"` on every dispatched Agent call.\n' >>"$d/skills/dispatch-ready/SKILL.md"
expect_fail "M2 bare Opus pin restored" "$d" 'outside a tier binding'

d=$(make_copy m3)
mutate "$d/agents/security-reviewer.md" '\A---\n' $'---\nmodel: sonnet\n' ||
    bad "M3: mutation did not apply"
expect_fail "M3 agent model: frontmatter" "$d" 'carries `model:` frontmatter'

d=$(make_copy m4)
mutate "$d/skills/send-it/SKILL.md" ' at tier `sol` \(Claude Code:\s*`model: "opus"` · omp:\s*`model: "@default"`\)' '' ||
    bad "M4: mutation did not apply"
expect_fail "M4 required sol site removed" "$d" 'required dispatch tier `sol` bound 0x'

d=$(make_copy m5)
mutate "$d/docs/MODEL-TIERS.md" '\| `terra` \| 3 \| `sonnet` \|' '| `terra` | 3 | `haiku` |' ||
    bad "M5: mutation did not apply"
expect_fail "M5 table row rebound, sites untouched" "$d" 'table says `haiku`'

d=$(make_copy m6)
mutate "$d/agents/pr-review-orchestrator.md" ' at tier\s+`terra` \(Claude Code:\s*`model: "sonnet"` · omp:\s*`model: "@task"`\)' '' ||
    bad "M6: mutation did not apply"
expect_fail "M6 one of two orchestrator terra sites removed" "$d" 'required dispatch tier `terra` bound 1x, needs at least 2x'

d=$(make_copy m7)
printf '\nConfigure with `"model": "claude-sonnet-5"` for this call.\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M7 JSON-style full model id" "$d" 'outside a tier binding'

d=$(make_copy m8)
printf "\nPass \`'model': 'opus'\` here.\n" >>"$d/skills/dispatch-ready/SKILL.md"
expect_fail "M8 single-quoted bare pin" "$d" 'outside a tier binding'

d=$(make_copy m9)
mutate "$d/skills/take-it/references/isolation-confirmation.md" ' at tier `terra` \(Claude Code:\s*`model: "sonnet"` · omp:\s*`model: "@task"`\)' '' ||
    bad "M9: mutation did not apply"
expect_fail "M9 isolation probe worker's terra site removed" "$d" 'isolation-confirmation.md: required dispatch tier `terra` bound 0x'

d=$(make_copy m10)
mutate "$d/skills/dispatch-ready/SKILL.md" ' at tier `terra` \(Claude Code:\s*`model: "sonnet"` · omp:\s*`model: "@task"`\)' '' ||
    bad "M10: mutation did not apply"
expect_fail "M10 dispatch-ready isolation probe's terra site removed" "$d" 'skills/dispatch-ready/SKILL.md: required dispatch tier `terra` bound 1x, needs at least 2x'

if [ "$FAILED" = 0 ]; then
    echo "model-tier tests: all green" >&2
    exit 0
else
    echo "model-tier tests: FAILURES above" >&2
    exit 1
fi
