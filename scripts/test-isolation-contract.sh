#!/usr/bin/env bash
# test-isolation-contract.sh — take-it and dispatch-ready confirm the isolation
# contract before a parallel dispatch, and the design doc says what is and is not
# implemented (issues #451 and #452, following #426's contract and #453's
# settings-source evidence).
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
#      origin/<default_branch>`, inside §5's dispatched blockquote. The Serial
#      variant says dispatch-ready sends it only on omp, on a tick whose own check
#      chose serial (#452); it used to say "never by dispatch-ready".
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
#      settings", step 3's "rests on the `apply` read", "all set"), and the
#      sentences saying dispatch-ready does not yet implement it are gone.
#  13. dispatch-ready §5 carries the contract per tick (#452), AHEAD of its
#      "claim →" sentence: the check is before the claim, not merely present
#      (a stop AFTER the claim leaves an `in-progress` claim that counts as
#      in-flight and blocks other sessions). On Claude Code it is inert; on omp
#      each tick re-derives (three reads, probe, `isolated: true`), a confirmed
#      batch is verified by a fresh `git ls-remote`, an unconfirmed tick is
#      serial (one claim, one worker, never a stack-chain member) or stop, the
#      `review_site` override is reported, and the interim "until #452 lands"
#      stop is gone.
#   5b (inside property 5) The reference doc requires `isolated: true` on the
#      probe's `task` entry and on every confirmed worker's, and take-it §5 points
#      at it. The first dispatch-ready text omitted the parameter and two runs
#      probed the coordinator's own tree.
#  14. The terminal-state decision (#452): a stopped tick ends the loop through
#      DRAIN STALLED, §7's STALLED conjunct names §5's isolation check, §5 states
#      the reach (worker dispatch only), and the design doc records the decision.
#
# A gate that passes a mutant is vacuous for that property. Mutation-proven
# below against fifty-three mutants, each of which must FAIL FOR ITS OWN REASON after
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
#   M20 dispatch-ready's "isolation contract applies here" sentence removed       -> 13
#   M21 the reference doc's name for the serial step diverges from §5's           -> 9
#   M22 dispatch-ready's "without claiming a single issue" phrase swapped. This
#       proves the PHRASE only; it is NOT placement, which is M23 (its label
#       once claimed placement, and the swap proves nothing about order)  -> 13
#   M23 the confirmation paragraph moved BELOW the "claim →" sentence             -> 13 (the ordering branch)
#   M24 dispatch-ready's Claude Code definition (Agent + isolation) changed       -> 13
#   M25 dispatch-ready's "nothing in this paragraph applies" dropped              -> 13
#   M26 dispatch-ready's "never reuses `confirmed`" re-derive rule dropped        -> 13
#   M27 `isolated: true` removed from dispatch-ready (every occurrence)           -> 13
#   M28 serial's "one claim and one worker for the tick" dropped                  -> 13
#   M29 serial's "never a stack-chain member" dropped                             -> 13
#   M30 the interim "until #452 lands" stop restored                              -> 13 (the negative)
#   M31 dispatch-ready's review_site override sentence removed                    -> 13
#   M32 dispatch-ready's fresh `git ls-remote` after-batch check removed          -> 13
#   M33 §5's "DRAIN STALLED, not a fifth state" decision removed                  -> 14
#   M34 §7's STALLED conjunct no longer names §5's isolation check                -> 14
#   M35 §5's Reach paragraph removed                                              -> 14
#   M36 take-it's Serial variant reverted to "never by `dispatch-ready`"          -> 9
#   M37 "dispatch-ready does not yet" restored in the design doc                  -> 12
#   M38 the doc's "task entry without isolated: true runs on the shared tree" removed -> 5
#   M39 the doc's "every worker carries isolated: true" line removed               -> 5
#   M40 take-it §5's pointer to the isolated: true rule removed                    -> 5
#   M41 outstanding serial worker no longer blocks merge-shepherd.sh               -> 13
#   M42 the manifest read is no longer ahead of §2's merge hand-off                -> 13
#   M43 outstanding serial worker no longer blocks the fast-forward                -> 13
#   M44 the stop report no longer names a failed precondition                      -> 13
#   M45 §5's two-tick confirmation removed                                         -> 14
#   M46 §5's transient-probe rationale removed                                     -> 14
#   M47 §7's stall-record hold-root list loses the isolation root                  -> 14
#   M48 "Close each serial record from live state first" removed                   -> 13
#   M49 the explicit `"mode": "serial"` marker removed                             -> 13
#   M50 "any claim" removed from the outstanding-worker block list                 -> 13
#   M51 the confirmed branch no longer waits on the block                          -> 13
#   M52 the coordinator-site review is no longer deferred under the block          -> 13
#   M53 a forbidden restatement (`task.isolation.enabled`) injected into §5        -> 13
# Property 13 also fails if dispatch-ready §5 contains `task.isolation.enabled`,
# `omp config set` or the `merge` `patch` pin, which the reference doc owns
# (#452 item 1 asked for no third copy); M53 injects one. No tier string is
# checked: §5 legitimately carries the worker's tier binding, so a ban would be
# wrong, and no property-14 text carries such a check.
# (Property 13 began as dispatch-ready's own interim sentence, nit-added after
# review: the two dispatching skills must not contradict each other about who
# confirms. #452 replaced that sentence with the contract itself.)
#
# Source-level: python3 stdlib, no gh, no omp, no network. This gate does NOT
# run omp; the model-driven evidence that the sequence works is recorded in
# docs/HARNESS-PORTABILITY.md ("Isolation confirmation runs (#451)" for
# take-it, "(#452)" for dispatch-ready).
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

# 5b. the `isolated: true` rule lives in the reference doc and take-it points at it (#452 review)
need("the probe's task entry carries isolated: true", ref, "with `isolated: true` on its `task` entry", 5)
need("a task entry without isolated: true runs on the shared tree", ref,
     "A `task` entry without `isolated: true` runs on the shared tree whatever the settings read", 5)
need("every confirmed worker carries isolated: true too", ref,
     "Every worker dispatched after a confirmed outcome carries `isolated: true` on its `task` entry as well", 5)
need("take-it §5 points at the isolated: true rule", s5,
     "On omp the probe's and every worker's `task` entry carries `isolated: true`", 5)
if "set the `task` tool's isolation parameter when it offers one" in ref:
    problems.append("property 5: the reference doc still carries the wording whose probe measured the shared tree")

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
need("the serial variant says it is never sent on Claude Code, and dispatch-ready sends it only on omp", sv,
     "never sent on Claude Code, and `dispatch-ready` sends it only on omp, on a tick whose own isolation check chose serial", 9)
if "never by `dispatch-ready`" in sv:
    problems.append("property 9: the Serial variant still says dispatch-ready never sends it (#452 does, on omp)")
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
              "Requirement 3 rests on the `apply` read in step 2", "are all set",
              "`dispatch-ready` does not yet", "`dispatch-ready` cannot yet", "has neither yet (#452)",
              "Until #452 lands", "(`dispatch-ready`, open)"):
    if stale in doc:
        problems.append(f"property 12: docs/HARNESS-PORTABILITY.md still says {stale!r}")
need("the doc cites #451 (take-it)", doc, "#451", 12)
need("the doc cites #452 (dispatch-ready)", doc, "#452", 12)
need("the doc names the apply and merge reads", doc, "the `apply` and `merge` reads", 12)
need("the doc says all read", doc, "are all read", 12)
need_re("the doc has the recorded #451 runs section", DOC_RAW,
        r"(?m)^### Isolation confirmation runs \(#451\)$", 12)

# 13. dispatch-ready carries the contract per tick, ahead of its claim
DR_RAW = read("skills/dispatch-ready/SKILL.md")
dr = flatten(DR_RAW)
d5_raw = section(DR_RAW, "## 5. Dispatch")
d5 = flatten(d5_raw)
d7_raw = section(DR_RAW, "## 7. Terminal states — drain complete, drain deferred, drain stalled, drain degraded")
d7 = flatten(d7_raw)
if not d5:
    problems.append("dispatch-ready §5 did not slice — every property 13 assertion would pass vacuously")
if not d7:
    problems.append("dispatch-ready §7 did not slice")
need("dispatch-ready says take-it's isolation contract applies, adapted to a tick", d5,
     "take-it's isolation contract applies here, adapted to a tick that remembers nothing", 13)
need("dispatch-ready defines Claude Code as the Agent tool taking isolation: worktree", d5,
     'Claude Code means the dispatch tool is `Agent` and it takes `isolation: "worktree"`', 13)
need("dispatch-ready says nothing applies on Claude Code and the dispatch is unchanged", d5,
     "that parameter *is* the confirmation, nothing in this paragraph applies, and the dispatch below is unchanged", 13)
need("dispatch-ready checks before this tick claims anything", d5,
     "Check it **before this tick claims anything**", 13)
# ORDER, not presence: a check placed after the claim leaves an `in-progress` claim behind.
i_chk = d5_raw.find("**Confirm isolation before this tick claims anything.**")
i_clm = d5_raw.find("Use take-it's mechanics verbatim")
if min(i_chk, i_clm) < 0:
    problems.append("property 13: the isolation check or §5's 'claim →' sentence was not found in dispatch-ready §5")
elif not i_chk < i_clm:
    problems.append("property 13: the isolation check must precede §5's 'claim →' sentence, or a stop leaves a claim behind")
need("dispatch-ready's claim sentence still opens with claim →", d5, "verbatim, after the isolation check above: claim →", 13)
need("dispatch-ready re-derives every tick", d5, "**Re-derive every tick.**", 13)
need("dispatch-ready never reuses a previous tick's confirmed", d5, "never reuses `confirmed`", 13)
need("dispatch-ready runs the doc's settings reads and probe rather than restating them", d5,
     "Run the doc's settings reads on every tick and, on a tick about to dispatch a parallel batch, its probe", 13)
need("dispatch-ready points at the doc's worker-dispatch rule", d5,
     "under the doc's worker-dispatch rule (`isolated: true` on every `task` entry)", 13)
need("dispatch-ready points at the doc's after-every-batch check", d5,
     "run the doc's after-every-batch check before trusting them", 13)
for copy in ("task.isolation.enabled", "omp config set", "`merge` `patch`"):
    if copy in d5:
        problems.append(f"property 13: dispatch-ready §5 restates {copy!r}; the reference doc owns it (#452 item 1)")
need("dispatch-ready's outstanding-serial-worker rule exists", d5,
     "**An outstanding serial worker blocks every local-tree step of every tick.**", 13)
need("dispatch-ready reads the manifest ahead of §2's merge hand-off", d5,
     "ahead of §2's merge hand-off even though §2 runs first", 13)
need("an outstanding serial worker blocks any claim and the fast-forward", d5,
     "any claim; the default-branch fast-forward; any dispatch", 13)
need("the confirmed branch waits on the outstanding-worker block", d5,
     "once the outstanding-serial-worker block below is clear (claim, fast-forward and dispatch all wait on it)", 13)
need("serial records are marked mode serial explicitly", d5,
     'A serial record carries `"mode": "serial"` explicitly, never inferred from an absent `worktreePath`', 13)
need("dispatch-ready closes serial records from live state first", d5,
     "**Close each serial record from live state first.**", 13)
need("a serial record closes on a PR plus a clean default-branch checkout", d5,
     "finds a PR on the record's branch **and** the coordinator's checkout is back on the default branch", 13)
need("a terminal failure record or blocked closes a serial record", d5,
     "`take-it-terminal-failure` for the active attempt) exists for the issue, or the issue carries `blocked`", 13)
need("the operator step for a worker that died is documented", d5,
     "**A worker that died with neither** leaves a record only the operator can close", 13)
need("an outstanding serial worker defers the coordinator-site review", d5,
     "dispatch, whose orchestrator diffs the working tree it runs in", 13)
need("an outstanding serial worker blocks teardown.sh in any mode", d5, "`teardown.sh` in any mode", 13)
need("an outstanding serial worker blocks merge-shepherd.sh, which tears down itself", d5,
     "`merge-shepherd.sh` for any PR", 13)
need("dispatch-ready defines outstanding as no pr and no terminal failure", d5,
     "Outstanding means a serial record with neither a `pr` nor a recorded terminal failure", 13)
need("the stop report names a failed precondition, not only a setting", d5,
     "a setting, the probe, a dirty tree, only stack-chain candidates, or an outstanding serial worker", 13)
need("dispatch-ready goes serial or stops, never parallel on a shared tree", d5,
     "**serial or stop, never parallel on a shared tree.**", 13)
need("dispatch-ready's serial is one claim and one worker per tick", d5,
     "**one claim and one worker for the tick, and the tick ends there**", 13)
need("dispatch-ready's serial never takes a stack-chain member", d5, "never a stack-chain member", 13)
need("dispatch-ready's serial checks a clean tree", d5, "`git status --porcelain` empty", 13)
need("dispatch-ready claims only that one issue when serial", d5, "**that one issue only**", 13)
need("dispatch-ready claims nothing on the stop", d5, "without claiming a single issue", 13)
need("dispatch-ready reports the review_site override on omp", d5,
     "`review_site: agent` is unsatisfiable on omp", 13)
need("dispatch-ready's override is never silent and never edits config", d5,
     "never silent, and the config is never edited", 13)
for stale in ("until #452 lands", "do **not** apply here", "the operator ends the `/loop`",
              "whether to add one is #452's decision"):
    if stale in d5:
        problems.append(f"property 13: dispatch-ready §5 still carries the interim stop ({stale!r})")

# 14. the terminal-state decision (#452), its reach, and the design doc's record of it
need("dispatch-ready §5 records that a stopped tick ends in DRAIN STALLED, not a fifth state", d5,
     "**How a stopped tick ends the loop: DRAIN STALLED, not a fifth state.**", 14)
need("dispatch-ready §5 names the hold root", d5, "the hold root `isolation unconfirmed`", 14)
need("dispatch-ready §5 says why it is not DEFERRED", d5, "Not DEFERRED, because", 14)
need("dispatch-ready §5 keeps the two-tick confirmation", d5,
     "confirmed across two ticks, then the stop path and its cron self-cancel", 14)
need("dispatch-ready §5 gives the transient-probe rationale", d5,
     "The two ticks also keep a transient probe failure from ending a healthy loop.", 14)
need("§7 lists the isolation hold among holds a human could clear", d7,
     "an `isolation unconfirmed` hold — any one of them", 14)
need("§7's stall record carries the isolation hold root", d7,
     "the decision gate, `isolation unconfirmed`, the Blocking finding", 14)
need("§5's Reach says an outstanding serial worker defers merges and teardown", d5,
     "A serial worker outstanding defers the merge hand-off and its teardown", 14)
need("dispatch-ready §7's STALLED conjunct names §5's isolation check", d7,
     "every Ready item held by a §4 filter or by §5's isolation check", 14)
need("dispatch-ready §5 states its reach", d5, "**Reach.** The check gates **worker dispatch** and the local-tree steps above, and nothing else.", 14)
need("dispatch-ready §5 says a §2 redispatch passes the check", d5, "A §2 redispatch is a worker dispatch", 14)
need("dispatch-ready §5 states the known limitation", d5, "**Known and accepted:**", 14)
need("the doc records the terminal-state decision", doc,
     "a stopped tick ends the loop through DRAIN STALLED, and no fifth state is added", 14)
need_re("the doc has the recorded #452 runs section", DOC_RAW,
        r"(?m)^### Isolation confirmation runs \(#452\)$", 14)
need_re("the doc has the #452 terminal-state section", DOC_RAW,
        r"(?m)^### `dispatch-ready`: the tick, its terminal state and its reach \(#452\)$", 14)

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY

# --- the real tree ------------------------------------------------------------
if out=$(python3 "$CHECKER" "$ROOT" 2>&1); then
    ok "take-it and dispatch-ready confirm isolation before a parallel dispatch; the design doc agrees (14 properties)"
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
mutate "$d/skills/dispatch-ready/SKILL.md" "take-it's isolation contract applies here," "take-it's isolation contract is background," || bad "M20: mutation did not apply"
expect_fail "M20 dispatch-ready's contract sentence removed" "$d" 'isolation contract applies, adapted to a tick'

d=$(make_copy m21)
mutate "$d/$RF" 'Serial variant (its step 1)' 'serial-mode step 0' || bad "M21: mutation did not apply"
expect_fail "M21 the one name for the serial step diverges" "$d" "the reference doc names the Serial variant and its step 1"

d=$(make_copy m22)
mutate "$d/skills/dispatch-ready/SKILL.md" 'without claiming a single issue' 'after claiming up to capacity' || bad "M22: mutation did not apply"
expect_fail "M22 dispatch-ready's stop phrase swapped (phrase only; placement is M23)" "$d" 'dispatch-ready claims nothing on the stop'

# M23: the confirmation paragraph moved BELOW the "claim →" paragraph, still inside §5,
# so the "not found" branch cannot be what fires; only the ordering branch can.
d=$(make_copy m23)
python3 - "$d/skills/dispatch-ready/SKILL.md" <<'PY' || bad "M23: mutation did not apply"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = s.index("**Confirm isolation before this tick claims anything.**")
b = s.index("Use take-it's mechanics verbatim")
para = s[a:b]
s = s[:a] + s[b:]
anchor = "A stack chain uses take-it's **stacked variant**"
i = s.index(anchor)
p.write_text(s[:i] + para + s[i:])
PY
expect_fail "M23 confirmation moved below the claim sentence" "$d" 'must precede §5'"'"'s '"'"'claim →'"'"' sentence'

d=$(make_copy m24)
mutate "$d/skills/dispatch-ready/SKILL.md" 'Claude Code means the dispatch tool is `Agent`' 'Claude Code means the dispatch tool is `Task`' || bad "M24: mutation did not apply"
expect_fail "M24 Claude Code definition changed" "$d" 'dispatch-ready defines Claude Code as the Agent tool'

d=$(make_copy m25)
mutate "$d/skills/dispatch-ready/SKILL.md" 'nothing in this paragraph applies,' 'something in this paragraph applies,' || bad "M25: mutation did not apply"
expect_fail "M25 'nothing applies' dropped" "$d" 'dispatch-ready says nothing applies on Claude Code'

d=$(make_copy m26)
mutate "$d/skills/dispatch-ready/SKILL.md" 'never reuses `confirmed`' 'reuses `confirmed`' || bad "M26: mutation did not apply"
expect_fail "M26 re-derive rule dropped" "$d" 'dispatch-ready never reuses a previous tick'"'"'s confirmed'

d=$(make_copy m27)
mutate "$d/skills/dispatch-ready/SKILL.md" '`isolated: true`' '`isolated: false`' all || bad "M27: mutation did not apply"
expect_fail "M27 isolated: true removed" "$d" "dispatch-ready points at the doc's worker-dispatch rule"

d=$(make_copy m28)
mutate "$d/skills/dispatch-ready/SKILL.md" 'for the tick, and the tick ends there**' 'for the tick**' || bad "M28: mutation did not apply"
expect_fail "M28 one claim and one worker dropped" "$d" 'dispatch-ready'"'"'s serial is one claim and one worker per tick'

d=$(make_copy m29)
mutate "$d/skills/dispatch-ready/SKILL.md" 'never a stack-chain member' 'any candidate' || bad "M29: mutation did not apply"
expect_fail "M29 stack-chain exclusion dropped" "$d" 'dispatch-ready'"'"'s serial never takes a stack-chain member'

d=$(make_copy m30)
mutate "$d/skills/dispatch-ready/SKILL.md" '## 5. Dispatch

' '## 5. Dispatch

Dispatches nothing until #452 lands.

' || bad "M30: mutation did not apply"
expect_fail "M30 interim stop restored" "$d" 'still carries the interim stop'

d=$(make_copy m31)
mutate "$d/skills/dispatch-ready/SKILL.md" 'is unsatisfiable on omp' 'is fine on omp' || bad "M31: mutation did not apply"
expect_fail "M31 review_site override removed" "$d" 'dispatch-ready reports the review_site override on omp'

d=$(make_copy m32)
mutate "$d/skills/dispatch-ready/SKILL.md" 'after-every-batch check before trusting them' 'later check' || bad "M32: mutation did not apply"
expect_fail "M32 after-every-batch pointer removed" "$d" "dispatch-ready points at the doc's after-every-batch check"

d=$(make_copy m33)
mutate "$d/skills/dispatch-ready/SKILL.md" '**How a stopped tick ends the loop: DRAIN STALLED, not a fifth state.**' '**How a stopped tick ends the loop.**' || bad "M33: mutation did not apply"
expect_fail "M33 terminal-state decision removed" "$d" 'a stopped tick ends in DRAIN STALLED'

d=$(make_copy m34)
mutate "$d/skills/dispatch-ready/SKILL.md" "held by a §4 filter or by §5's isolation check" 'held by a §4 filter' || bad "M34: mutation did not apply"
expect_fail "M34 STALLED conjunct no longer names the check" "$d" "STALLED conjunct names"

d=$(make_copy m35)
mutate "$d/skills/dispatch-ready/SKILL.md" '**Reach.** The check gates' '**Scope.** The check gates' || bad "M35: mutation did not apply"
expect_fail "M35 Reach paragraph removed" "$d" 'dispatch-ready §5 states its reach'

d=$(make_copy m36)
mutate "$d/$SK" 'never sent on Claude Code, and `dispatch-ready` sends it only on omp,' 'never sent on Claude Code and never by `dispatch-ready`,' || bad "M36: mutation did not apply"
expect_fail "M36 take-it's Serial variant reverted" "$d" 'property 9:'

d=$(make_copy m37)
printf '\n`dispatch-ready` does not yet implement it.\n' >>"$d/$DC"
expect_fail "M37 'does not yet' restored in the design doc" "$d" "still says '\`dispatch-ready\` does not yet'"

d=$(make_copy m38)
mutate "$d/$RF" 'A `task` entry without `isolated: true` runs on the shared tree whatever the settings read' 'A `task` entry may omit it' || bad "M38: mutation did not apply"
expect_fail "M38 doc's shared-tree sentence removed" "$d" 'a task entry without isolated: true runs on the shared tree'

d=$(make_copy m39)
mutate "$d/$RF" 'Every worker dispatched after a confirmed outcome carries `isolated: true` on its `task` entry as well' 'Workers need nothing more' || bad "M39: mutation did not apply"
expect_fail "M39 doc's worker line removed" "$d" 'every confirmed worker carries isolated: true too'

d=$(make_copy m40)
mutate "$d/$SK" "On omp the probe's and every worker's \`task\` entry carries" "On omp the probe's entry carries" || bad "M40: mutation did not apply"
expect_fail "M40 take-it pointer removed" "$d" 'take-it §5 points at the isolated: true rule'

d=$(make_copy m41)
mutate "$d/skills/dispatch-ready/SKILL.md" '`merge-shepherd.sh` for any PR,' 'nothing else,' || bad "M41: mutation did not apply"
expect_fail "M41 merge-shepherd no longer blocked" "$d" 'blocks merge-shepherd.sh'

d=$(make_copy m42)
mutate "$d/skills/dispatch-ready/SKILL.md" "ahead of §2's merge hand-off" "after §2's merge hand-off" || bad "M42: mutation did not apply"
expect_fail "M42 manifest read moved after the hand-off" "$d" "reads the manifest ahead of §2's merge hand-off"

d=$(make_copy m43)
mutate "$d/skills/dispatch-ready/SKILL.md" 'the default-branch fast-forward; any' 'any' || bad "M43: mutation did not apply"
expect_fail "M43 fast-forward no longer blocked" "$d" 'blocks any claim and the fast-forward'

d=$(make_copy m44)
mutate "$d/skills/dispatch-ready/SKILL.md" 'a dirty tree, only stack-chain candidates, or an outstanding' 'or an' || bad "M44: mutation did not apply"
expect_fail "M44 stop report no longer names the precondition" "$d" 'the stop report names a failed precondition'

d=$(make_copy m45)
mutate "$d/skills/dispatch-ready/SKILL.md" 'confirmed across two ticks, then' 'confirmed at once, then' || bad "M45: mutation did not apply"
expect_fail "M45 two-tick confirmation removed" "$d" 'keeps the two-tick confirmation'

d=$(make_copy m46)
mutate "$d/skills/dispatch-ready/SKILL.md" 'The two ticks also keep a transient probe failure from ending a healthy loop.' 'The two ticks add nothing.' || bad "M46: mutation did not apply"
expect_fail "M46 transient-probe rationale removed" "$d" 'gives the transient-probe rationale'

d=$(make_copy m47)
mutate "$d/skills/dispatch-ready/SKILL.md" 'the decision gate, `isolation unconfirmed`, the Blocking' 'the decision gate, the Blocking' || bad "M47: mutation did not apply"
expect_fail "M47 stall record loses the isolation root" "$d" "stall record carries the isolation hold root"

d=$(make_copy m48)
mutate "$d/skills/dispatch-ready/SKILL.md" '**Close each serial record from live state first.**' '**Records.**' || bad "M48: mutation did not apply"
expect_fail "M48 close-from-live-state removed" "$d" 'closes serial records from live state first'

d=$(make_copy m49)
mutate "$d/skills/dispatch-ready/SKILL.md" 'A serial record carries `"mode": "serial"` explicitly' 'A serial record carries nothing explicit' || bad "M49: mutation did not apply"
expect_fail "M49 explicit serial marker removed" "$d" 'serial records are marked mode serial explicitly'

d=$(make_copy m50)
mutate "$d/skills/dispatch-ready/SKILL.md" 'any claim; the default-branch' 'the default-branch' || bad "M50: mutation did not apply"
expect_fail "M50 claim no longer blocked" "$d" 'blocks any claim and the fast-forward'

d=$(make_copy m51)
mutate "$d/skills/dispatch-ready/SKILL.md" 'once the outstanding-serial-worker block below is clear (claim, fast-forward and' 'immediately (claim, fast-forward and' || bad "M51: mutation did not apply"
expect_fail "M51 confirmed branch no longer gated" "$d" 'the confirmed branch waits on the outstanding-worker block'

d=$(make_copy m52)
mutate "$d/skills/dispatch-ready/SKILL.md" 'whose orchestrator diffs the working tree it runs in' 'which is harmless' || bad "M52: mutation did not apply"
expect_fail "M52 review no longer deferred" "$d" 'defers the coordinator-site review'

d=$(make_copy m53)
mutate "$d/skills/dispatch-ready/SKILL.md" '## 5. Dispatch

' '## 5. Dispatch

Read task.isolation.enabled here.

' || bad "M53: mutation did not apply"
expect_fail "M53 forbidden restatement injected" "$d" "restates 'task.isolation.enabled'"

if [ "$FAILED" = 0 ]; then
    echo "isolation-contract tests: all green" >&2
    exit 0
else
    echo "isolation-contract tests: FAILURES above" >&2
    exit 1
fi
