#!/usr/bin/env bash
# test-isolation-contract.sh — take-it confirms the isolation contract before a
# parallel dispatch, and the design doc says what is and is not implemented
# (issue #451, following #426's contract and #453's settings-source evidence).
#
# Why this exists: `take-it` dispatched every worker with `isolation: "worktree"`
# and nothing else. That parameter is the whole contract on Claude Code, but on
# omp isolation is a SETTING that defaults to off, so the same call put parallel
# workers in one checkout while they all looked like they worked. The fix is a
# confirmation sequence (skills/take-it/references/isolation-confirmation.md,
# pointed to from §5). Removing any step breaks nothing visible — the workers
# just overwrite each other on a harness nobody is testing — so presence is
# asserted here, and each step is asserted for the detail that is easy to lose:
#
#   1. §5 states that on Claude Code `isolation: "worktree"` IS the confirmation
#      and the dispatch is unchanged, so the new sequence is a no-op there.
#   2. §5 points at the reference doc, and the pointer sits BEFORE both the
#      "Issue ALL Agent calls" step and the attempt record, because an
#      unconfirmed stop that has already written an attempt comment has left
#      state behind for a dispatch that never happened.
#   3. The doc reads all THREE keys and pins the values true / false / patch,
#      with an unset `merge` reading `patch`. `merge` is the one a two-key
#      version drops: `merge: branch` under `apply: false` leaves a local
#      `omp/task/<Name>` ref in the parent that no later check sees (#453, E1).
#   4. The doc states `omp config get` ignores a `--config` overlay, so
#      overlay-only settings can never pass, and no fenced command anywhere in
#      take-it runs `omp config set`: the profile is never written to make a
#      check pass.
#   5. The probe worker is dispatched at tier `terra` and compares `pwd` and
#      `git rev-parse --show-toplevel` with the coordinator's; the same path
#      means isolation is off. (The tier binding's presence is also counted by
#      test-model-tiers.sh's `required` table; this is the behavioural half.)
#   6. The outcome is recorded in the batch manifest `take-it-batch.json`.
#   7. After each batch: the coordinator's branch, `HEAD` and `git status` are
#      compared with their values from before (`merge: branch` leaves a clean
#      tree with `HEAD` moved, so status alone is blind to it); the push is
#      verified with a FRESH `git ls-remote`; and the `omp-task-<id>` temp
#      directory, which holds the only copy of an unpushed worker's change, is
#      removed only after that verification.
#   8. Fail closed: serial or Stop, never parallel on a shared tree; an
#      unrecognised harness is unconfirmed; the stop report is
#      `isolation unconfirmed`.
#   9. Serial mode is only safe with its prerequisite, and BOTH halves are
#      required: the coordinator fetches and confirms `git status --porcelain`
#      is empty before each dispatch (`git switch -c` carries a prior worker's
#      uncommitted edits onto the new branch), and the worker prompt carries a
#      serial-mode step that branches with `git switch -c <branch>
#      origin/<default_branch>`, inside §5's dispatched blockquote.
#  10. `review_site: agent` on omp is overridden to `coordinator` for the run,
#      and the override is REPORTED, never silent and never written to config.
#      This is a per-run override, not the config-derived flip decision 4 of
#      test-review-gate-decisions.sh forbids; `review_site` stays configured,
#      and take-it's "never silently change `review_site`" sentences are still
#      required to be present so the two rules cannot be traded for each other.
#  11. §7 reports the isolation outcome and the guardrails carry the rule.
#  12. docs/HARNESS-PORTABILITY.md no longer claims the contract "implements
#      nothing" or that "No skill implements" it, no longer says "Drafts 1 and
#      2", cites the filed issues #451 and #452, and the summary lines that
#      predate the `merge: patch` pin are corrected (the row 3 verdict's "two
#      settings", step 3's "rests on the `apply` read", "all set").
#
# A gate that passes a mutant is vacuous for that property. Mutation-proven
# below against twenty-one mutants, each of which must FAIL FOR ITS OWN REASON after
# an unmutated control copy passes (the same discipline test-model-tiers.sh
# records: without the control, a copy broken in some unrelated way fails every
# mutant at once and the proof reads green while measuring nothing):
#   M1  §5 no longer says Claude Code's isolation parameter is the confirmation -> 1
#   M2  the §5 pointer removed (the "pointer missing" branch)                   -> 2
#   M3  the `merge` read dropped from the reference doc                          -> 3
#   M4  a fenced `omp config set` added to the reference doc                     -> 4
#   M5  the probe's `show-toplevel` comparison removed                           -> 5
#   M6  the manifest record removed                                              -> 6
#   M7  the fresh `git ls-remote` requirement removed                            -> 7
#   M8  "Never dispatch parallel workers on a shared tree" guardrail removed     -> 8
#   M9  the `git status --porcelain` check before each serial dispatch removed   -> 9
#   M10 the Serial variant's step 1 removed                                      -> 9
#   M11 the review_site override report removed                                  -> 10
#   M12 "implements nothing" restored in the design doc                          -> 12
#   M13 the confirmation paragraph moved below the dispatch step, inside §5       -> 2 (the ordering branch)
#   M14 the Claude Code clause widened to mention the probe                       -> 1
#   M15 "nothing in this paragraph applies" dropped                               -> 1
#   M16 "the dispatch below is unchanged" dropped                                 -> 1
#   M17 §7's isolation-outcome line removed                                       -> 11
#   M18 the `true`/`false`/`patch` pin's apply value flipped                      -> 3
#   M19 serial-step text leaked into the shared worker template                   -> 9
#   M20 dispatch-ready's "does not apply" sentence removed                        -> 13
#   M21 the reference doc's name for the serial step diverges from §5's           -> 9
# (Property 13 is dispatch-ready's own sentence, nit-added after review: the
# two dispatching skills must not contradict each other about who confirms.)
#
# Source-level: python3 stdlib, no gh, no omp, no network. This gate does NOT
# run omp; the model-driven evidence that the sequence works is recorded in
# docs/HARNESS-PORTABILITY.md ("Isolation confirmation runs (#451)").
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

command -v python3 >/dev/null 2>&1 || {
    echo "isolation-contract tests: python3 not found" >&2
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
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
problems = []

def read(rel):
    p = root / rel
    if not p.is_file():
        problems.append(f"{rel}: missing")
        return ""
    return p.read_text()

def flatten(text):
    lines = [re.sub(r"^\s*(>\s?)+", "", ln) for ln in text.splitlines()]
    return re.sub(r"\s+", " ", " ".join(lines))

def need(label, hay, needle, prop):
    if needle not in hay:
        problems.append(f"property {prop}: {label} (missing: {needle!r})")

def need_re(label, hay, pattern, prop):
    if not re.search(pattern, hay):
        problems.append(f"property {prop}: {label} (no match: {pattern!r})")

SKILL_RAW = read("skills/take-it/SKILL.md")
REF_RAW = read("skills/take-it/references/isolation-confirmation.md")
DOC_RAW = read("docs/HARNESS-PORTABILITY.md")
skill, ref, doc = flatten(SKILL_RAW), flatten(REF_RAW), flatten(DOC_RAW)

def section(raw, heading):
    """Lines of one `## ` section, to the next `## `. Raw lines, not flattened."""
    out, on = [], False
    for ln in raw.splitlines():
        if ln.startswith("## "):
            if on:
                break
            on = ln.strip() == heading
            continue
        if on:
            out.append(ln)
    return "\n".join(out)

s5_raw = section(SKILL_RAW, "## 5. Dispatch sub-agents in parallel")
s7_raw = section(SKILL_RAW, "## 7. Final report")
s5, s7 = flatten(s5_raw), flatten(s7_raw)
if not s5:
    problems.append("take-it §5 did not slice — every §5 assertion would pass vacuously")
if not s7:
    problems.append("take-it §7 did not slice")
if not ref:
    problems.append("the isolation reference doc is empty or missing")

# 1. Claude Code: the parameter is the confirmation, nothing changes
need("§5 says Claude Code's isolation parameter is the confirmation",
     s5, '`isolation: "worktree"` *is* the confirmation', 1)
need("§5 says the Claude Code dispatch is unchanged", s5, "the dispatch below is unchanged", 1)
need("§5 says nothing in the paragraph applies on Claude Code", s5, "nothing in this paragraph applies", 1)
need("the reference doc stops reading on Claude Code",
     ref, "that parameter is the confirmation", 1)
need("the reference doc says nothing below applies on Claude Code", ref, "nothing below applies", 1)
need("§5's omp trigger is omp or an unrecognised harness",
     s5, "On omp (workers are `task` calls), or on any harness you do not recognise", 1)
# The Claude Code clause must stay inert: it may not mention the omp machinery.
def between(hay, a, b):
    i = hay.find(a)
    j = hay.find(b, i + 1) if i >= 0 else -1
    return hay[i:j] if i >= 0 and j > i else ""
cc_s5 = between(s5, "On Claude Code `isolation:", "On omp (workers")
cc_ref = between(ref, "- **Claude Code**", "- **omp**")
for label, seg in (("§5", cc_s5), ("the reference doc", cc_ref)):
    if not seg:
        problems.append(f"property 1: {label}'s Claude Code clause did not slice")
    for word in ("probe", "omp config get", "manifest", "task.isolation"):
        if word in seg:
            problems.append(f"property 1: {label}'s Claude Code clause mentions {word!r}")

# 2. the pointer, and where it sits
ptr = "references/isolation-confirmation.md"
need("§5 points at the reference doc", s5, ptr, 2)
i_ptr = s5_raw.find(ptr)
need("§5 scopes the single-message dispatch to Claude Code or a confirmed run", s5,
     "On Claude Code, or once the confirmation above passed, issue ALL Agent calls in a single message", 2)
need("§5 names the serial loop beside it", s5,
     "dispatch one worker at a time, each to completion before the next, and record `{issue, pr, branch}` (no `worktreePath`)", 2)
i_all = s5_raw.find("**On Claude Code, or once the confirmation above passed")
i_att = s5_raw.find("**Issue-only terminal handoff**")
if min(i_ptr, i_all, i_att) < 0:
    problems.append("property 2: pointer, dispatch step or attempt-record anchor not found in §5")
elif not (i_ptr < i_all and i_ptr < i_att):
    problems.append("property 2: the isolation pointer must precede the dispatch step AND the attempt record")
need("§5 puts the confirmation before the attempt record", s5,
     "before the attempt record below is created", 2)

# 3. three keys, three values, unset merge
for k in ("task.isolation.enabled", "task.isolation.apply", "task.isolation.merge"):
    need(f"the reference doc runs `omp config get {k}`", ref, f"omp config get {k}", 3)
need("the doc pins true, false and patch",
     ref, "must read `true`, `false` and `patch`", 3)
need("the doc says an unset merge reads patch", ref, "An unset `merge` reads `patch`", 3)
need("the doc says why merge: branch is refused", ref, "omp/task/<Name>", 3)
need("§5 names all three values", s5,
     "(`task.isolation.enabled` `true`, `apply` `false`, `merge` `patch`)", 3)

# 4. --config blind spot; never write the profile
need("the doc says omp config get ignores the --config overlay",
     ref, "does **not** reflect a `--config` overlay", 4)
for rel, raw in (("skills/take-it/SKILL.md", SKILL_RAW),
                 ("skills/take-it/references/isolation-confirmation.md", REF_RAW)):
    for blk in re.findall(r"```[^\n]*\n(.*?)```", raw, re.S):
        if re.search(r"omp\s+config\s+set\b", blk):
            problems.append(f"property 4: {rel} runs `omp config set` in a fenced command")
need("the doc forbids `omp config set`", ref, "Never run `omp config set`", 4)

# 5. probe
need("the probe is dispatched at tier terra",
     ref, 'tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`)', 5)
need("the probe reports pwd", ref, "`pwd -P`", 5)
need("the probe reports the top level", ref, "git rev-parse --show-toplevel", 5)
need("the same path means isolation is off", ref, "means isolation is off", 5)
need("the probe changes nothing", ref, "Change nothing, create no branch, commit nothing and push nothing", 5)

# 6. manifest
need("the outcome is recorded in the batch manifest", ref, "take-it-batch.json", 6)
need("a resumed run never reuses `confirmed`", ref, "never reuses `confirmed`", 6)

# 7. after each batch
need("branch and HEAD compared after each batch", ref,
     "Compare the coordinator's branch and `HEAD` with the values from before the batch", 7)
need("git status compared after each batch", ref, "`git status --porcelain`", 7)
need("merge: branch's clean-tree-moved-HEAD shape is named", ref,
     "leaves the tree clean with `HEAD` moved", 7)
need("the push is verified with a fresh ls-remote", ref, "**fresh** `git ls-remote origin <branch>`", 7)
need("a worker's own push report is not the check", ref, "Never take the worker's own report of the push as the check", 7)
need("the omp-task temp dir is removed only after verification", ref,
     "only after step 2 showed the branch on the remote in the same step", 7)
need("an unverified temp dir is left in place", ref, "leave the directory", 7)

# 8. fail closed
need("serial or Stop, never a shared tree", ref,
     "never dispatch parallel workers on a shared tree", 8)
need("an unrecognised harness is unconfirmed", ref, "isolation is **unconfirmed**", 8)
need("the stop report names isolation unconfirmed", ref, "report `isolation unconfirmed`", 8)
need("§5 names both outcomes", s5, "either run **serial**", 8)
need("§5 names the stop report", s5, "report `isolation unconfirmed`", 8)
need("the guardrail carries the rule", flatten(section(SKILL_RAW, "## Guardrails")),
     "**Never dispatch parallel workers on a shared tree.**", 8)
need("serial is limited to a plain list", ref, "Allowed only for a plain list of independent issues", 8)

# 9. serial prerequisite, both halves
need("the coordinator checks a clean tree before each serial dispatch", ref,
     "confirm `git status --porcelain` is empty; if it is not, **Stop**", 9)
need("the coordinator fetches before each serial dispatch", ref, "`git fetch origin --quiet`", 9)
SV = "### Serial variant (ONLY when §5's isolation confirmation chose serial mode)"
i_sv = s5_raw.find(SV)
if i_sv < 0:
    problems.append("property 9: §5 has no 'Serial variant' subsection")
    sv_raw, template_raw = "", s5_raw
else:
    j = s5_raw.find("\n### ", i_sv + 1)
    sv_raw = s5_raw[i_sv:j if j > 0 else len(s5_raw)]
    template_raw = s5_raw[:i_sv]
sv = flatten(sv_raw)
need("the serial variant carries step 1", sv, "**Serial-variant step 1.**", 9)
need("the serial step branches from the fetched default branch without tracking", sv,
     "git switch -c --no-track {prefix}/issue-{N}-{slug} origin/{default_branch}", 9)
need("the serial step pushes with -u at push time", sv,
     "git push -u origin {prefix}/issue-{N}-{slug}", 9)
need("the serial step also checks for a clean tree", sv, "confirm `git status --porcelain` is empty", 9)
need("the serial step carries the stash guard", sv, "**Never `git stash`**", 9)
need("the serial step carries the editable-install guard", sv, "never run an editable or dev install", 9)
need("the serial variant says it is never sent on Claude Code or by dispatch-ready", sv,
     "never sent on Claude Code and never by `dispatch-ready`", 9)
if "> **Serial-variant step 1.**" not in sv_raw:
    problems.append("property 9: the serial step is not a blockquote inside the Serial variant subsection")
# The shared worker template (also reused by dispatch-ready) must not carry it.
for leak in ("Serial-variant", "Serial-mode", "--no-track", "git switch -c"):
    if leak in template_raw:
        problems.append(f"property 9: the shared worker template carries {leak!r}; the serial step must stay in its own subsection")
need("§5's omp paragraph points at the Serial variant", s5, "using the **Serial variant** below", 9)
need("the reference doc names the Serial variant and its step 1", ref, "Serial variant (its step 1)", 9)
if "serial-mode step" in (ref + skill).lower():
    problems.append("property 9: a 'serial-mode step' spelling survives; the one name is 'Serial variant'")

# 10. review_site override
need("§5 states the omp review_site override", s5, "`review_site: agent` is unsatisfiable", 10)
need("§5 says the override is reported in §7", s5, "report the override in §7", 10)
need("§5 says the config is never edited", s5, "the config itself is never edited", 10)
need("the reference doc reports the override", ref, "report the override in §7", 10)
need("take-it still says never silently change review_site", skill,
     "silently change `review_site`", 10)

# 11. §7 and report
need("§7 reports the isolation outcome", s7, "State the isolation outcome in the report", 11)
need("§7 names the serial-and-not-isolated outcome", s7, "serial and not isolated", 11)

# 12. the design doc
for stale in ("implements nothing", "No skill implements them", "Drafts 1 and 2",
              "until Drafts 1 and 2", "Even after Draft 1", "conditional on two settings",
              "Requirement 3 rests on the `apply` read in step 2", "are all set"):
    if stale in doc:
        problems.append(f"property 12: docs/HARNESS-PORTABILITY.md still says {stale!r}")
need("the doc cites #451 (take-it)", doc, "#451", 12)
need("the doc cites #452 (dispatch-ready)", doc, "#452", 12)
need("the doc names the apply and merge reads", doc, "the `apply` and `merge` reads", 12)
need("the doc says all read", doc, "are all read", 12)
need_re("the doc has the recorded #451 runs section", DOC_RAW,
        r"(?m)^### Isolation confirmation runs \(#451\)$", 12)

# 13. dispatch-ready does not inherit take-it's confirmation, and says so
dr = flatten(read("skills/dispatch-ready/SKILL.md"))
need("dispatch-ready says take-it's confirmation, Serial variant and override do not apply", dr,
     "take-it's isolation-confirmation paragraph, its Serial variant and its omp `review_site` override do **not** apply here", 13)
need("dispatch-ready reports isolation unconfirmed off Claude Code and dispatches nothing", dr,
     "on any harness other than Claude Code this loop reports `isolation unconfirmed` and dispatches nothing until #452 lands", 13)

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY

# --- the real tree ------------------------------------------------------------
if out=$(python3 "$CHECKER" "$ROOT" 2>&1); then
    ok "take-it confirms isolation before a parallel dispatch; the design doc agrees (13 properties)"
else
    printf '%s\n' "$out" | while IFS= read -r line; do bad "$line"; done
fi

# --- mutation proof: each mutant must FAIL, for its own reason ----------------
make_copy() {
    local dst="$WORK/$1"
    mkdir -p "$dst/skills/take-it/references" "$dst/skills/dispatch-ready" "$dst/docs"
    cp "$ROOT/skills/take-it/SKILL.md" "$dst/skills/take-it/SKILL.md"
    cp "$ROOT/skills/dispatch-ready/SKILL.md" "$dst/skills/dispatch-ready/SKILL.md"
    cp "$ROOT/skills/take-it/references/isolation-confirmation.md" "$dst/skills/take-it/references/"
    cp "$ROOT/docs/HARNESS-PORTABILITY.md" "$dst/docs/"
    printf '%s' "$dst"
}

# Exit non-zero when the anchor is absent, so a mutant that never applied is
# reported as broken rather than counted as a proof. Literal match, first hit.
mutate() { # mutate <file> <literal> <replacement> [all]  (all: every occurrence)
    python3 - "$@" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if sys.argv[2] not in s:
    sys.exit(1)
p.write_text(s.replace(sys.argv[2], sys.argv[3], -1 if len(sys.argv) > 4 else 1))
PY
}

expect_fail() { # expect_fail <name> <copy dir> <substring its failure must contain>
    local name=$1 dst=$2 why=$3 out
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

SK=skills/take-it/SKILL.md
RF=skills/take-it/references/isolation-confirmation.md
DC=docs/HARNESS-PORTABILITY.md

d=$(make_copy m1)
mutate "$d/$SK" '`isolation: "worktree"` *is* the confirmation' '`isolation: "worktree"` is used' || bad "M1: mutation did not apply"
expect_fail "M1 Claude Code no-op sentence dropped" "$d" 'property 1:'

d=$(make_copy m2)
mutate "$d/$SK" 'read `${CLAUDE_PLUGIN_ROOT}/skills/take-it/references/isolation-confirmation.md`' 'read the isolation doc' || bad "M2: mutation did not apply"
printf '\n%s\n' 'Late pointer: skills/take-it/references/isolation-confirmation.md' >>"$d/$SK"
# the appended pointer is outside §5 (after the last section), so §5 has none
expect_fail "M2 pointer removed from §5" "$d" 'property 2:'

d=$(make_copy m3)
mutate "$d/$RF" 'omp config get task.isolation.merge' 'omp config get task.isolation.mode' || bad "M3: mutation did not apply"
expect_fail "M3 merge read dropped" "$d" 'omp config get task.isolation.merge'

d=$(make_copy m4)
printf '\n```bash\nomp config set task.isolation.enabled true\n```\n' >>"$d/$RF"
expect_fail "M4 profile write added" "$d" 'runs `omp config set`'

d=$(make_copy m5)
mutate "$d/$RF" 'git rev-parse --show-toplevel' 'git rev-parse HEAD' all || bad "M5: mutation did not apply"
expect_fail "M5 probe top-level comparison removed" "$d" 'the probe reports the top level'

d=$(make_copy m6)
mutate "$d/$RF" 'take-it-batch.json' 'batch.json' all || bad "M6: mutation did not apply"
expect_fail "M6 manifest record removed" "$d" 'recorded in the batch manifest'

d=$(make_copy m7)
mutate "$d/$RF" '**fresh** `git ls-remote origin <branch>`' '`git ls-remote origin <branch>`' || bad "M7: mutation did not apply"
expect_fail "M7 fresh ls-remote requirement removed" "$d" 'the push is verified with a fresh ls-remote'

d=$(make_copy m8)
mutate "$d/$SK" '- **Never dispatch parallel workers on a shared tree.**' '- Prefer isolation.' || bad "M8: mutation did not apply"
expect_fail "M8 guardrail removed" "$d" 'the guardrail carries the rule'

d=$(make_copy m9)
mutate "$d/$RF" 'confirm `git status --porcelain` is empty; if it is not, **Stop**' 'carry on' || bad "M9: mutation did not apply"
expect_fail "M9 clean-tree check before serial dispatch removed" "$d" 'clean tree before each serial dispatch'

d=$(make_copy m10)
mutate "$d/$SK" '> **Serial-variant step 1.**' '> **Optional note.**' || bad "M10: mutation did not apply"
expect_fail "M10 serial variant's step 1 removed" "$d" 'the serial variant carries step 1'

d=$(make_copy m11)
mutate "$d/$SK" '**report the
override in §7**' '**mention it**' || mutate "$d/$SK" 'report the
override in §7' 'mention it' || bad "M11: mutation did not apply"
expect_fail "M11 override report removed" "$d" 'property 10:'

d=$(make_copy m12)
printf '\nThis section **specifies** a contract and implements nothing.\n' >>"$d/$DC"
expect_fail "M12 'implements nothing' restored" "$d" "still says 'implements nothing'"

# M13: the whole confirmation paragraph moved BELOW the dispatch paragraph, still
# inside §5, so the "anchor not found" branch cannot be what fires.
d=$(make_copy m13)
python3 - "$d/$SK" <<'PY' || bad "M13: mutation did not apply"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = s.index("**Confirm isolation before any parallel dispatch")
b = s.index("**On Claude Code, or once the confirmation above passed")
para = s[a:b]
s = s[:a] + s[b:]
anchor = "so a crashed coordinator's worktrees stay reclaimable.\n\n"
i = s.index(anchor) + len(anchor)
p.write_text(s[:i] + para + s[i:])
PY
expect_fail "M13 confirmation moved below the dispatch step" "$d" 'must precede the dispatch step AND the attempt record'

d=$(make_copy m14)
mutate "$d/$SK" 'applies and the dispatch below is unchanged' 'applies; also run the probe first' || bad "M14: mutation did not apply"
expect_fail "M14 Claude Code clause widened to the probe" "$d" "Claude Code clause mentions 'probe'"

d=$(make_copy m15)
mutate "$d/$SK" 'nothing in this paragraph
applies' 'something in this paragraph
applies' || bad "M15: mutation did not apply"
expect_fail "M15 'nothing applies' sentence dropped" "$d" 'nothing in the paragraph applies on Claude Code'

d=$(make_copy m16)
mutate "$d/$SK" 'the dispatch below is unchanged' 'the dispatch below changes' || bad "M16: mutation did not apply"
expect_fail "M16 'dispatch unchanged' sentence dropped" "$d" 'the Claude Code dispatch is unchanged'

d=$(make_copy m17)
mutate "$d/$SK" 'State the isolation outcome in the report' 'Say how it went' || bad "M17: mutation did not apply"
expect_fail "M17 §7 isolation line removed" "$d" 'property 11:'

d=$(make_copy m18)
mutate "$d/$RF" 'must read `true`, `false` and `patch`' 'must read `true`, `true` and `patch`' || bad "M18: mutation did not apply"
expect_fail "M18 apply value flipped in the pin" "$d" 'the doc pins true, false and patch'

d=$(make_copy m19)
printf '\n> **Serial-variant step 1.** leaked\n' >>"$d/$SK"
mutate "$d/$SK" '### Stacked variant (ONLY for a chain resolved in §2)' '> git switch -c --no-track x origin/y

### Stacked variant (ONLY for a chain resolved in §2)' || bad "M19: mutation did not apply"
mutate "$d/$SK" '### Serial variant (ONLY' '> git switch -c leak
>
### Serial variant (ONLY' || bad "M19: second mutation did not apply"
expect_fail "M19 serial step leaked into the shared template" "$d" 'the shared worker template carries'

d=$(make_copy m20)
mutate "$d/skills/dispatch-ready/SKILL.md" 'do **not** apply here' 'apply here' || bad "M20: mutation did not apply"
expect_fail "M20 dispatch-ready sentence removed" "$d" 'property 13:'

d=$(make_copy m21)
mutate "$d/$RF" 'Serial variant (its step 1)' 'serial-mode step 0' || bad "M21: mutation did not apply"
expect_fail "M21 the one name for the serial step diverges" "$d" "the reference doc names the Serial variant and its step 1"

if [ "$FAILED" = 0 ]; then
    echo "isolation-contract tests: all green" >&2
    exit 0
else
    echo "isolation-contract tests: FAILURES above" >&2
    exit 1
fi
