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
# The tier is a harness-neutral word (S-Tier/A-Tier/B-Tier/C-Tier) because the skills
# must port to harnesses other than Claude Code. Claude Code and omp both read
# a `model:` frontmatter key but their value spaces are disjoint (`sonnet` vs
# `@task`), so a tier can never live in frontmatter: it is bound at the
# DISPATCH SITE, inline, in one fixed form a cold agent can act on without
# opening another file. Inline copies are safe only because this gate
# re-derives each one from the table — the owner-plus-gate shape this repo uses
# for its label taxonomy, rather than a transcription left to drift.
#
# A binding also carries an EFFORT (light/standard/deep; absent means standard),
# and the doc holds four tables: Tiers, Efforts, Model bindings, Effort bindings
# (issue #668). The gate matches ONLY the bound forms
#   `B-Tier` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`)
#   `S-Tier` · `deep` (Claude Code: `model: "fable"`, `effort: "xhigh"` · omp: ...)
# and never the bare words: `standard` and `light` are ordinary English, and a
# gate keyed on them would fail on prose or, worse, be loosened until it
# checked nothing. The Google columns of the doc are documentation only: no
# dispatch site carries a Google entry and nothing below requires one.
#
# Six properties, over every tracked Markdown file under skills/ and agents/
# (6 also reads docs/, and 2 also reads docs/MODEL-TIERS.md's own examples):
#
#   1. The four tables parse: a row for each of the four tiers (Tiers and Model
#      bindings), each of the three efforts (Efforts and Effort bindings).
#   2. Every inline binding names a tier in the table, with exactly that row's
#      Claude Code alias and omp role, and its effort part agrees with the
#      Effort bindings table: `light` -> `effort: "low"`, `standard` (or no
#      effort word) -> no `effort:` key at all, `deep` -> `effort: "xhigh"`.
#      An effort word outside the three, inside a binding, fails here.
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
#      tier twice (take-it's `A-Tier` at step 6 and in §6; the orchestrator's
#      `B-Tier` in Step 3 and in the Parent recovery batch). A per-file "is the
#      tier present anywhere" check let either copy be deleted green, and one of
#      them is Step 3 — the fan-out every PR review takes. The table is the
#      enumerated member list the repo's count rule asks for: a claim that
#      "every dispatch site is tiered" means exactly these.
#   6. No near-miss tier spelling in any tracked Markdown under skills/, agents/
#      or docs/: `S-tier`, `s-tier`, `S tier`, `STier` (and the same for A, B, C).
#      The one spelling is a capital letter, a hyphen and a capital T. "A tier"
#      and "B tier" with a lowercase t are English ("a tier of"), so only the
#      forms no sentence contains are flagged.
#   6. No near-miss tier spelling in any tracked Markdown under skills/, agents/
#      or docs/: `S-tier`, `s-tier`, `S tier`, `STier` (and the same for A, B, C).
#      The one spelling is a capital letter, a hyphen and a capital T. "A tier"
#      and "B tier" with a lowercase t are English ("a tier of"), so only the
#      forms no sentence contains are flagged.
#
# Wrapping: prose wraps at ~100 columns and take-it's worker template is a
# blockquote, so a binding routinely splits across lines behind `> `. Each file
# is flattened (quote markers stripped, whitespace collapsed) before matching,
# the same treatment the other prose gates give wrapped text.
#
# Mutation-proven below against twenty-four mutants, each of which must FAIL:
#   M1 a binding's Claude Code alias flipped (B-Tier → opus)   -> property 2
#   M2 dispatch-ready's bare `model: "opus"` pin restored     -> property 3
#   M3 an agent given `model: sonnet` frontmatter             -> property 4
#   M4 send-it's `A-Tier` binding deleted                        -> property 5
#   M5 the table's B-Tier row rebound to haiku, sites untouched -> property 2
#   M6 only the orchestrator's Step-3 `B-Tier` binding removed  -> property 5
#   M7 a JSON-style `"model": "claude-sonnet-5"` added         -> property 3
#   M8 a single-quoted `'model': 'opus'` added                 -> property 3
#   M9 the isolation probe worker's `B-Tier` binding removed    -> property 5
#   M10 the supervised serial worker's `B-Tier` binding removed -> property 5
#   M11 take-it's nit roll-in delta-review `A-Tier` binding removed -> property 5
#   M12 dispatch-ready's nit roll-in delta-review `A-Tier` binding removed -> property 5
#   (M1-M12 were written against the old names; they now use the new ones.)
#   M13 a near-miss `S-tier` added to a skill                  -> property 6
#   M14 a near-miss `s-tier` added to a skill                  -> property 6
#   M15 a near-miss `S tier` added to a skill                  -> property 6
#   M16 a near-miss `STier` added to a skill                   -> property 6
#   M17 a near-miss `B-tier` added to a doc under docs/        -> property 6
#   M18 an unknown effort word `heavy` inside a binding         -> property 2
#   M19 a deep binding whose Claude Code effort is `high`       -> property 2
#   M20 a standard binding that sets `effort: "low"`            -> property 2
#   M21 a light binding that omits its `effort:`                -> property 2
#   M22 the Efforts table's deep row rebound to `max`, a well-formed deep
#       binding added, sites untouched                          -> property 2
#   M23 the Effort bindings table loses its `deep` row          -> property 1
#   M24 the Model bindings table loses its `C-Tier` row         -> property 1
#   Positive controls (must PASS, so the mutants above fail for their mutation
#   and the gate is not simply hostile to every new form):
#   C1 prose using the bare words `standard`, `light` and `deep`, and "A tier"
#   C2 a well-formed `S-Tier` · `deep` and an `S-Tier` · `light` binding
#   C3 a binding with no Google entry (every binding; asserted explicitly)
#   C2 a well-formed `S-Tier` · `deep` and an `S-Tier` · `light` binding
#   C3 a binding with no Google entry (every binding; asserted explicitly)
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
from collections import Counter

root = pathlib.Path(sys.argv[1])
problems = []

TIERS = ("S-Tier", "A-Tier", "B-Tier", "C-Tier")
EFFORTS = ("light", "standard", "deep")

# --- 1. the four tables ------------------------------------------------------
table_path = root / "docs" / "MODEL-TIERS.md"
doc = table_path.read_text() if table_path.is_file() else ""
if not doc:
    problems.append("docs/MODEL-TIERS.md is missing")

def section(name):
    m = re.search(r"^## " + re.escape(name) + r"\s*$(.*?)(?=^## |\Z)", doc, re.M | re.S)
    return m.group(1) if m else ""

def rows(text):
    out = []
    for ln in text.splitlines():
        if ln.startswith("|") and not re.match(r"^\|\s*-", ln):
            out.append([c.strip() for c in ln.strip().strip("|").split("|")])
    return out[1:]  # drop the header row

def tick(cell):
    m = re.match(r"^`([^`]+)`", cell)
    return m.group(1) if m else None

tiers_t = {r[0].strip("`"): r for r in rows(section("Tiers")) if len(r) >= 2}
models_t = {}      # tier -> (claude code alias, omp role)
for r in rows(section("Model bindings")):
    if len(r) >= 3 and tick(r[0]) and tick(r[1]) and tick(r[2]):
        models_t[tick(r[0])] = (tick(r[1]), tick(r[2]))
efforts_t = {r[0].strip("`") for r in rows(section("Efforts")) if r}
cc_effort = {}     # effort -> the Claude Code effort value, or None when omitted
for r in rows(section("Effort bindings")):
    if len(r) >= 2 and tick(r[0]):
        cc_effort[tick(r[0])] = tick(r[1])   # "omitted (...)" has no leading tick -> None
for tier in TIERS:
    if tier not in tiers_t:
        problems.append(f"Tiers table has no row for tier `{tier}`")
    if tier not in models_t:
        problems.append(f"Model bindings table has no row for tier `{tier}`")
for eff in EFFORTS:
    if eff not in efforts_t:
        problems.append(f"Efforts table has no row for effort `{eff}`")
    if eff not in cc_effort:
        problems.append(f"Effort bindings table has no row for effort `{eff}`")
if cc_effort.get("standard") is not None:
    problems.append("Effort bindings table gives `standard` a Claude Code effort; it must be omitted")

# --- the scan set: tracked *.md under skills/ and agents/ --------------------
def tracked(pattern):
    out = subprocess.run(["git", "-C", str(root), "ls-files", pattern],
                         capture_output=True, text=True).stdout.split()
    return [root / p for p in out]

files = tracked("skills/*.md") + tracked("agents/*.md")
docs_files = tracked("docs/*.md")
if not files:
    # an empty scan set would pass every property below vacuously
    problems.append("scan set is empty — every property below would pass vacuously")

def flatten(text):
    lines = [re.sub(r"^\s*(>\s?)+", "", ln) for ln in text.splitlines()]
    return re.sub(r"\s+", " ", " ".join(lines))

# `TIER` [· `EFFORT`] (Claude Code: `model: "A"`[, `effort: "E"`] · omp: `model: "@R"`)
bind_re = re.compile(
    r"`([^`]+)`(?: · `([^`]*)`)? \(Claude Code: `model: \"(\w+)\"`"
    r"(?:, `effort: \"(\w+)\"`)? · omp: `model: \"(@\w+)\"`\)")
bare_re = re.compile(
    r"[\"']?model[\"']?\s*:\s*[\"']?(opus|sonnet|haiku|fable|claude-[\w.-]+)\b")
# near-miss tier spellings: only forms no English sentence contains ("a tier" is English)
near_res = [
    re.compile(r"(?<![\w-])[SABCsabc]-(?:tier|Tier)\b"),
    re.compile(r"(?<![\w-])[SABC] Tier\b"),
    re.compile(r"(?<![\w-])[Ss] tier\b"),
    re.compile(r"(?<![\w-])[SABCsabc][Tt]ier\b"),
]

def check_bindings(rel, flat):
    n = 0
    found = Counter()
    for tier, eff, cc, cce, omp in bind_re.findall(flat):
        n += 1
        found[tier] += 1
        # --- 2. each binding agrees with its rows ---------------------------
        if tier not in models_t:
            problems.append(f"{rel}: binds unknown tier `{tier}`")
        elif (cc, omp) != models_t[tier]:
            problems.append(
                f"{rel}: tier `{tier}` bound to Claude Code `{cc}` · omp `{omp}`, "
                f"table says `{models_t[tier][0]}` · `{models_t[tier][1]}`")
        effort = eff or "standard"
        if effort not in EFFORTS:
            problems.append(f"{rel}: binding of tier `{tier}` names unknown effort `{effort}`")
        elif effort in cc_effort and (cce or None) != cc_effort[effort]:
            problems.append(
                f"{rel}: tier `{tier}` at effort `{effort}` sets Claude Code effort "
                f"`{cce or 'none'}`, table says `{cc_effort[effort] or 'none'}`")
    return n, found

tiers_by_file = {}
n_bindings = 0
for f in files:
    rel = str(f.relative_to(root))
    text = f.read_text()
    flat = flatten(text)
    n, found = check_bindings(rel, flat)
    n_bindings += n
    tiers_by_file[rel] = found
    # --- 3. no bare alias outside a binding --------------------------------
    for m in bare_re.finditer(bind_re.sub("", flat)):
        problems.append(f"{rel}: bare `{m.group(0)}` outside a tier binding")
    # --- 4. no model: frontmatter on agents --------------------------------
    if rel.startswith("agents/"):
        fm = re.match(r"\A---\n(.*?)\n---", text, re.S)
        if fm and re.search(r"^model:", fm.group(1), re.M):
            problems.append(f"{rel}: carries `model:` frontmatter — the dispatch site owns the tier")

# the doc's own example bindings obey the same tables (never counted as sites)
if doc:
    check_bindings("docs/MODEL-TIERS.md", flatten(doc))

if n_bindings == 0:
    problems.append("no tier bindings found anywhere — the binding pattern matches nothing")

# --- 6. no near-miss tier spelling in skills, agents or docs ------------------
for f in files + docs_files:
    rel = str(f.relative_to(root))
    for lineno, ln in enumerate(f.read_text().splitlines(), 1):
        ln = re.sub(r"`?[SABC]-Tier`?", "", ln)   # the one right spelling, removed first
        for rx in near_res:
            for m in rx.finditer(ln):
                problems.append(f"{rel}:{lineno}: near-miss tier spelling `{m.group(0)}` — write S-Tier, A-Tier, B-Tier or C-Tier")

# --- 5. required dispatch sites keep their tier -------------------------------
# Minimum bindings per (file, tier). Each count is a set of dispatch sites:
required = {
    # §5 worker dispatch (B-Tier); step-6 orchestrator + §6 coordinator gate + §6 nit roll-in
    # delta review (A-Tier ×3)
    "skills/take-it/SKILL.md": {"B-Tier": 1, "A-Tier": 3},
    # the isolation probe worker (#451) and the supervised serial worker (#484): two dispatch
    # sites that live in the reference doc §5 points to
    "skills/take-it/references/isolation-confirmation.md": {"B-Tier": 2},
    # §5 worker model policy (B-Tier); §2 coordinator review + §2 nit roll-in delta review (A-Tier ×2)
    "skills/dispatch-ready/SKILL.md": {"B-Tier": 1, "A-Tier": 2},
    # §4 review gate
    "skills/send-it/SKILL.md": {"A-Tier": 1},
    # Step 3 fan-out + Parent recovery batch
    "agents/pr-review-orchestrator.md": {"B-Tier": 2},
    # Phase 1 audit fan-out
    "skills/assess-it/SKILL.md": {"B-Tier": 1},
    # audit Dispatch rule + refute-pass skeptics
    "skills/assess-it/orchestration.md": {"B-Tier": 2},
    # org-sweep subagent fan-out
    "skills/whats-on-fire/references/cloud-fallback.md": {"B-Tier": 1},
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
    ok "the four tables parse; $n inline bindings agree with them, model and effort"
    ok "no bare model alias outside a binding; no agent carries model: frontmatter"
    ok "every required dispatch site carries its tier"
    ok "no near-miss tier spelling in skills, agents or docs"
else
    printf '%s\n' "$out" | grep -v '^BINDINGS ' | while IFS= read -r line; do bad "$line"; done
fi

# --- mutation proof: each mutant must FAIL, for its own reason ----------------
# A copy of just what the checker reads, as a throwaway git repo so its
# `git ls-files` scan behaves exactly as it does on the real tree.
make_copy() {
    local dst="$WORK/$1"
    mkdir -p "$dst"
    (cd "$ROOT" && git ls-files 'skills/*.md' 'agents/*.md' 'docs/*.md') |
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
    elif grep -qF -- "$why" <<<"$out"; then
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
mutate "$d/skills/send-it/SKILL.md" ' at `A-Tier` \(Claude Code:\s*`model: "opus"` · omp:\s*`model: "@default"`\)' '' ||
    bad "M4: mutation did not apply"
expect_fail "M4 required A-Tier site removed" "$d" 'required dispatch tier `A-Tier` bound 0x'

d=$(make_copy m5)
mutate "$d/docs/MODEL-TIERS.md" '\| `B-Tier` \| `sonnet` \|' '| `B-Tier` | `haiku` |' ||
    bad "M5: mutation did not apply"
expect_fail "M5 table row rebound, sites untouched" "$d" 'table says `haiku`'

d=$(make_copy m6)
mutate "$d/agents/pr-review-orchestrator.md" ' at\s+`B-Tier` \(Claude Code:\s*`model: "sonnet"` · omp:\s*`model: "@task"`\)' '' ||
    bad "M6: mutation did not apply"
expect_fail "M6 one of two orchestrator B-Tier sites removed" "$d" 'required dispatch tier `B-Tier` bound 1x, needs at least 2x'

d=$(make_copy m7)
printf '\nConfigure with `"model": "claude-sonnet-5"` for this call.\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M7 JSON-style full model id" "$d" 'outside a tier binding'

d=$(make_copy m8)
printf "\nPass \`'model': 'opus'\` here.\n" >>"$d/skills/dispatch-ready/SKILL.md"
expect_fail "M8 single-quoted bare pin" "$d" 'outside a tier binding'

d=$(make_copy m9)
mutate "$d/skills/take-it/references/isolation-confirmation.md" ' at `B-Tier` \(Claude Code:\s*`model: "sonnet"` · omp:\s*`model: "@task"`\)' '' ||
    bad "M9: mutation did not apply"
expect_fail "M9 isolation probe worker's B-Tier site removed" "$d" 'isolation-confirmation.md: required dispatch tier `B-Tier` bound 1x, needs at least 2x'

d=$(make_copy m10)
mutate "$d/skills/take-it/references/isolation-confirmation.md" 'serial worker, a dispatch at `B-Tier` \(Claude Code:\s*`model: "sonnet"` · omp:\s*`model: "@task"`\)' 'serial worker' ||
    bad "M10: mutation did not apply"
expect_fail "M10 serial worker's B-Tier site removed" "$d" 'isolation-confirmation.md: required dispatch tier `B-Tier` bound 1x, needs at least 2x'

d=$(make_copy m11)
mutate "$d/skills/take-it/SKILL.md" 'Dispatch the same agent at `A-Tier` \(Claude Code:\s*`model:\s*"opus"` · omp:\s*`model:\s*"@default"`\) with `base_override`' 'Dispatch the same agent with `base_override`' ||
    bad "M11: mutation did not apply"
expect_fail "M11 take-it nit roll-in delta review's A-Tier site removed" "$d" 'take-it/SKILL.md: required dispatch tier `A-Tier` bound 2x, needs at least 3x'

d=$(make_copy m12)
mutate "$d/skills/dispatch-ready/SKILL.md" 'a delta review through `base_override` at `A-Tier` \(Claude Code: `model: "opus"` · omp: `model:\s*"@default"`\)' 'a delta review through `base_override`' ||
    bad "M12: mutation did not apply"
expect_fail "M12 dispatch-ready nit roll-in delta review's A-Tier site removed" "$d" 'dispatch-ready/SKILL.md: required dispatch tier `A-Tier` bound 1x, needs at least 2x'

# --- the effort dimension and the spelling rule (#668) -------------------------
# Positive controls first: the new forms must PASS, or the mutants below could be
# failing because the gate is hostile to every non-standard binding.
expect_pass() { # expect_pass <name> <copy dir>
    local name=$1 dst=$2 out
    git -C "$dst" add -A >/dev/null 2>&1
    if out=$(python3 "$CHECKER" "$dst" 2>&1); then
        ok "$name: passes"
    else
        bad "$name: FAILED, but it is well-formed: $(head -n 3 <<<"$out" | tr '\n' ' ')"
    fi
}

# Well-formed non-standard bindings, as they would appear at a dispatch site.
DEEP='`S-Tier` · `deep` (Claude Code: `model: "fable"`, `effort: "xhigh"` · omp: `model: "@slow"`)'
LIGHT='`S-Tier` · `light` (Claude Code: `model: "fable"`, `effort: "low"` · omp: `model: "@slow"`)'

d=$(make_copy c1)
printf '\nKeep the prompt light, the checks standard and the review deep. A tier of work is not a tier word.\n' >>"$d/skills/take-it/SKILL.md"
expect_pass "C1 bare effort words and 'A tier' in prose are never matched" "$d"

d=$(make_copy c2)
printf '\nArbitrate at %s; check in at %s.\n' "$DEEP" "$LIGHT" >>"$d/skills/take-it/SKILL.md"
expect_pass "C2 a well-formed S-Tier deep binding and light binding" "$d"

# C3: every binding in the real tree is Google-free, and the gate passes anyway.
if git -C "$ROOT" grep -qiE 'gemini' -- skills agents; then
    bad "C3: a skill or agent carries a Google entry — the Google columns are documentation only"
else
    ok "C3 no dispatch site carries a Google entry, and the gate does not require one"
fi

d=$(make_copy m13)
printf '\nRun this at S-tier.\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M13 near-miss S-tier" "$d" 'near-miss tier spelling `S-tier`'

d=$(make_copy m14)
printf '\nRun this at s-tier.\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M14 near-miss s-tier" "$d" 'near-miss tier spelling `s-tier`'

d=$(make_copy m15)
printf '\nRun this at S tier.\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M15 near-miss S tier" "$d" 'near-miss tier spelling `S tier`'

d=$(make_copy m16)
printf '\nRun this at STier.\n' >>"$d/agents/security-reviewer.md"
expect_fail "M16 near-miss STier, in an agent" "$d" 'near-miss tier spelling `STier`'

d=$(make_copy m17)
printf '\nThe workers run at B-tier.\n' >>"$d/docs/ARCHITECTURE.md"
expect_fail "M17 near-miss B-tier, in docs/" "$d" 'ARCHITECTURE.md:'

d=$(make_copy m18)
printf '\nArbitrate at `S-Tier` · `heavy` (Claude Code: `model: "fable"` · omp: `model: "@slow"`).\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M18 unknown effort word inside a binding" "$d" 'unknown effort `heavy`'

d=$(make_copy m19)
printf '\nArbitrate at `S-Tier` · `deep` (Claude Code: `model: "fable"`, `effort: "high"` · omp: `model: "@slow"`).\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M19 deep binding with the wrong Claude Code effort" "$d" 'at effort `deep` sets Claude Code effort `high`, table says `xhigh`'

d=$(make_copy m20)
printf '\nRun at `B-Tier` (Claude Code: `model: "sonnet"`, `effort: "low"` · omp: `model: "@task"`).\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M20 standard binding that sets an effort" "$d" 'at effort `standard` sets Claude Code effort `low`, table says `none`'

d=$(make_copy m21)
printf '\nCheck in at `S-Tier` · `light` (Claude Code: `model: "fable"` · omp: `model: "@slow"`).\n' >>"$d/skills/take-it/SKILL.md"
expect_fail "M21 light binding that omits its effort" "$d" 'at effort `light` sets Claude Code effort `none`, table says `low`'

d=$(make_copy m22)
printf '\nArbitrate at %s.\n' "$DEEP" >>"$d/skills/take-it/SKILL.md"
mutate "$d/docs/MODEL-TIERS.md" '\| `deep` \| `xhigh` \|' '| `deep` | `max` |' ||
    bad "M22: mutation did not apply"
expect_fail "M22 Effort bindings deep row rebound, a deep site untouched" "$d" 'table says `max`'

d=$(make_copy m23)
mutate "$d/docs/MODEL-TIERS.md" '\| `deep` \| `xhigh` \|[^\n]*\n' '' ||
    bad "M23: mutation did not apply"
expect_fail "M23 Effort bindings table loses its deep row" "$d" 'Effort bindings table has no row for effort `deep`'

d=$(make_copy m24)
mutate "$d/docs/MODEL-TIERS.md" '\| `C-Tier` \| `haiku` \|[^\n]*\n' '' ||
    bad "M24: mutation did not apply"
expect_fail "M24 Model bindings table loses its C-Tier row" "$d" 'Model bindings table has no row for tier `C-Tier`'


if [ "$FAILED" = 0 ]; then
    echo "model-tier tests: all green" >&2
    exit 0
else
    echo "model-tier tests: FAILURES above" >&2
    exit 1
fi
