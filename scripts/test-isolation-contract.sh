#!/usr/bin/env bash
# test-isolation-contract.sh — take-it and dispatch-ready confirm the isolation
# contract before a parallel dispatch, fall back to a guarded synchronous serial
# run only when that is safe, and the design doc says what is and is not
# implemented (issues #451, #452 and #484, following #426's contract and #453's
# settings-source evidence).
#
# WHAT #484 CHANGED HERE, AND WHAT IT DID NOT. #452 shipped dispatch-ready with
# NO serial mode: an unconfirmed tick stopped and claimed nothing. #484 replaced
# that with a safe synchronous serial fallback behind a durable checkout guard
# (skills/take-it/scripts/checkout-guard.sh). Properties 2, 8, 9, 13 and 14 used
# to pin the stop-only text and now pin its replacement; properties 1, 3-7 and
# 10-12 pin the PARALLEL contract, which #484 did not touch, and are unchanged.
# The guard's mechanics are executed, not read, by scripts/test-checkout-guard.sh
# (real processes, scratch Git, local bare remotes); this gate pins the prose that
# tells a model WHEN to call it and what to refuse, which that gate cannot see.
# An earlier edition of #484 deleted this gate in favour of the behavioural
# suite; the review that restored it measured that the two guard different
# things (the behavioural suite cannot notice `omp config set`, a dropped
# `isolated: true`, or a weakened review_site override).
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
#      unrecognised harness is unconfirmed. Serial is selected only with exclusive
#      checkout ownership, a clean/pushed starting checkout and a real supervised
#      foreground runner, for a plain independent issue/list and never a stacked
#      chain, and is reported as `serial and not isolated`. When it cannot be made
#      safe the stop names BOTH the failed isolation setting/probe and the unsafe
#      prerequisite, and claims, launches, cleans and writes nothing. take-it's own
#      §5 stop report is still `isolation unconfirmed`.
#   9. The serial lifecycle and the Serial variant (#484; #451's coordinator-side
#      loop is gone). Before each launch the tree is clean and nothing is ever
#      stashed, reset or discarded; the worker runs through the guarded FOREGROUND
#      command, never an async `task` or detached shell; the coordinator verifies
#      against a fresh `git ls-remote` before switching, reviewing, merging or a
#      later worker. The Serial variant is one blockquote inside its own §5
#      subsection, shared with dispatch-ready and never sent on Claude Code or the
#      confirmed parallel path, it fetches, branches with `git switch --no-track
#      -c` (flag BEFORE `-c`: after it, `-c` consumed `--no-track` as the branch
#      name), resumes a recovery's exact branch rather than replacing it, and says
#      never `git stash`, reset, discard edits, delete a branch or force-push.
#      Nothing of it leaks into the shared worker template.
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
#      each tick re-derives and a confirmed batch is checked after it returns,
#      and the `review_site` override is reported. UNCONFIRMED now has two
#      outcomes (#484): safe serial (exclusive ownership, clean checkout,
#      supervised foreground runner) runs ONE plain independent issue for the
#      whole tick, the quota shared with §2 recovery, and an unsafe path claims
#      nothing and names the failed prerequisite; the profile is never written.
#      Serial there is synchronous: no detached job outlives a tick and
#      termination, not a PR/RESULT/comment, is what is awaited. The property
#      still forbids the REJECTED shape (a multi-tick serial record tracking a
#      worker across ticks, #452's draft), and the interim "until #452 lands"
#      stop stays gone.
#  14. Holds and terminal states (#484 replaced #452's `isolation unconfirmed`
#      stall): disabled isolation with a safe serial path is progress; a verified
#      unsafe prerequisite is a named execution-safety hold that joins STALLED's
#      held set; only a live worker (`ownership=active`) is self-resolving; a
#      guard with no live worker is an ownership hold, the one STALLED entry that
#      waives in-flight zero, recorded with root `checkout ownership
#      <created_at>`; a coordinator never runs `abandon`. §7's wording is pinned
#      whole by test-drain-terminal-states.sh; the SAME decisions are pinned here
#      from §5's and the reference doc's side, so neither copy can drift alone.
#
# A gate that passes a mutant is vacuous for that property. Mutation-proven
# below, each mutant of which must FAIL FOR ITS OWN REASON after an unmutated
# control copy passes (the same discipline test-model-tiers.sh records: without
# the control, a copy broken in some unrelated way fails every mutant at once and
# the proof reads green while measuring nothing). The mutants, by property:
#   1   M1 (the Claude Code no-op sentence), M14 (clause widened to the probe),
#       M15, M16
#   2   M2 (pointer removed), M13 (confirmation moved below the dispatch step)
#   3   M3 (merge read dropped), M18 (apply value flipped in the pin)
#   4   M4 (a fenced `omp config set`)
#   5   M5 (show-toplevel comparison), M38/M39/M40 (the `isolated: true` rule)
#   6   M6 (manifest record)
#   7   M7 (fresh ls-remote)
#   8   M8 (guardrail), M72 (serial opened to a stacked chain), M73 (serial
#       prerequisites weakened)
#   9   M9 (clean-tree check before each launch), M10 (Serial variant step 1),
#       M19 (serial text leaked into the shared template), M21 (the one name for
#       the serial step), M69 (stash/reset/force-push guard), M70 (`--no-track`
#       after `-c`), M71 (never-sent-on-Claude-Code rule), M78 (foreground-only)
#  10   M11 (override report)
#  11   M17 (§7 isolation line)
#  12   M12, M37 (stale design-doc claims restored)
#  13   M20, M22 (phrase only), M23 (placement: the check moved BELOW the claim
#       sentence), M24-M27, M30 (interim stop restored), M31, M32, M53 (a forbidden
#       restatement injected), M54 (a multi-tick serial record restored), M56
#       (serial-is-synchronous), M57 (one issue per tick), M59-M61 (halt, wait,
#       timeout caveat), M63-M68 (the in-§2 redispatch), M74 (profile write)
#  14   M33 (disabled isolation joins the held set), M34 (STALLED conjunct), M35
#       and M58 (reach and holds), M47 (stall-record roots), M55 (isolation-
#       unconfirmed stall restored), M62 (shared checkout during coordinator
#       work), M75 (ownership waiver), M76 (only `active` is self-resolving),
#       M77 (a coordinator never abandons)
# M45 and M46 (#452's two-tick confirmation and transient-probe rationale) and
# the numbers that skipped (M28, M29, M36, M41-M44, M48-M52) went with the
# stop-only text and are not renumbered.
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
# run omp or the guard; the model-driven evidence that the sequence works is
# recorded in docs/HARNESS-PORTABILITY.md ("Isolation confirmation runs (#451)"
# for take-it, "(#452)" for dispatch-ready, "Safe serial runtime checks (#484)"
# for the serial fallback), and scripts/test-checkout-guard.sh executes the guard.
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
need("§5 names the supervised serial loop beside it", s5,
     "In serial mode instead, use the reference's supervised foreground runner one worker at a time, each to verified process completion before the next, and record `{issue, pr, branch}` (no `worktreePath`)", 2)
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
need("the stop outcome names the failed setting/probe AND the unsafe serial prerequisite", ref,
     "Name the failed isolation setting/probe AND the specific unsafe serial prerequisite", 8)
need("the stop outcome claims, launches, cleans and writes nothing", ref,
     "No new claim, no invented launch, no dirty-work cleanup and no profile changes", 8)
need("§5 names both outcomes", s5, "either run **serial**", 8)
need("§5 names the stop report", s5, "report `isolation unconfirmed`", 8)
need("the guardrail carries the rule", flatten(section(SKILL_RAW, "## Guardrails")),
     "**Never dispatch parallel workers on a shared tree.**", 8)
need("serial is limited to a plain independent issue or list, never a chain", ref,
     "Only a plain independent issue/list, never a stacked chain", 8)
need("serial needs ownership, a clean/pushed checkout and a supervised foreground runner", ref,
     "Checkout ownership, a clean/pushed starting checkout, and a real supervised foreground runner must be available", 8)
need("serial is reported as serial and not isolated", ref, "Say **serial and not isolated**", 8)
need("a harness without a demonstrable foreground runner stops", ref, "stop with `serial runner unavailable`", 8)

# 9. serial lifecycle and the Serial variant (#484 replaced #451's coordinator-side loop)
need("the lifecycle never stashes, resets or discards work", ref, "never stash, reset or discard work", 9)
need("each launch is preceded by a clean-tree check", ref,
     "Before each launch confirm `git status --porcelain` is empty", 9)
need("the lifecycle runs a guarded foreground command, never an async task", ref,
     "Use the foreground CLI below, not an asynchronous `task` or detached shell.", 9)
need("the coordinator verifies before switching, reviewing, merging or a later worker", ref,
     "Before branch switching, coordinator review/merge/teardown or a later take-it worker:", 9)
need("verification reads a fresh ls-remote, not the worker's report", ref,
     "fresh `git ls-remote origin refs/heads/<branch>` evidence", 9)
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
     "git switch --no-track -c {prefix}/issue-{N}-{slug} origin/{default_branch}", 9)
if "git switch -c --no-track" in sv:
    problems.append("property 9: the Serial variant puts --no-track after -c, which consumes it as the branch name (#484)")
need("the serial step fetches", sv, "Run `git fetch origin --quiet`", 9)
need("a recovery resumes its exact branch and never creates a replacement", sv,
     "For RECOVERY, resume the exact branch supplied with the authenticated attempt: never create a replacement.", 9)
need("the serial step pushes with -u at push time", sv,
     "git push -u origin {prefix}/issue-{N}-{slug}", 9)
need("the serial step checks for a clean tree", sv,
     "Confirm `git status --porcelain` is empty before any checkout mutation", 9)
need("the serial step carries the stash, reset and force-push guard", sv,
     "**Never `git stash`, reset, discard edits, delete a branch or force-push.**", 9)
need("the serial step carries the editable-install guard", sv, "Never run an editable or dev install", 9)
need("the serial variant is shared and never sent on Claude Code or the confirmed parallel path", sv,
     "Shared by take-it and dispatch-ready; never sent on Claude Code or the confirmed parallel path.", 9)
need("the serial variant limits dispatch-ready to one issue per tick, recovery included", sv,
     "dispatch-ready launches at most one issue total per tick, including recovery", 9)
if "> **Serial-variant step 1.**" not in sv_raw:
    problems.append("property 9: the serial step is not a blockquote inside the Serial variant subsection")
# The shared worker template (also reused by dispatch-ready) must not carry it.
for leak in ("Serial-variant", "Serial-mode", "--no-track", "git switch -c"):
    if leak in template_raw:
        problems.append(f"property 9: the shared worker template carries {leak!r}; the serial step must stay in its own subsection")
need("§5's omp paragraph points at the Serial variant", s5, "using the **Serial variant** below", 9)
need("the reference doc substitutes the Serial variant for step 1", ref,
     "Replace step 1 with the **Serial variant** verbatim.", 9)
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
              "Until #452 lands", "(`dispatch-ready`, open)",
              "Whole-paragraph and wording snapshots were removed", "The isolation and terminal-state gates now run real"):
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
i_clm = d5_raw.find("use take-it's mechanics verbatim after the")
if min(i_chk, i_clm) < 0:
    problems.append("property 13: the isolation check or §5's 'claim →' sentence was not found in dispatch-ready §5")
elif not i_chk < i_clm:
    problems.append("property 13: the isolation check must precede §5's 'claim →' sentence, or a stop leaves a claim behind")
need("dispatch-ready's claim sentence follows the checks and opens with claim →", d5,
     "use take-it's mechanics verbatim after the checks above: claim →", 13)
need("dispatch-ready re-derives every tick", d5, "**Re-derive every tick.**", 13)
need("dispatch-ready never reuses a previous tick's confirmed", d5, "never reuses `confirmed`", 13)
need("dispatch-ready runs the doc's settings reads and probe rather than restating them", d5,
     "Run the doc's settings reads on every tick and, on a tick about to dispatch a parallel batch, its probe", 13)
need("dispatch-ready points at the doc's worker-dispatch rule", d5,
     "under the doc's worker-dispatch rule (`isolated: true` on every `task` entry)", 13)
need("dispatch-ready points at the doc's after-every-batch check", d5,
     "run the doc's after-every-batch check (its §4) against this tick's baseline", 13)
need("a confirmed tick waits for its batch's task results before it ends", d5,
     "**on omp, wait for that batch's `task` results before this tick ends**", 13)
need("the timeout caveat is stated", d5,
     "a `wait` that times out, or a worker that never returns, ends the tick without the check", 13)
need("a §2 redispatch on omp is dispatched within §2, not deferred", d5,
     "**A §2 redispatch on omp is dispatched within §2, not deferred to this batch.**", 13)
need("the in-§2 redispatch captures its own baseline before dispatching", d5,
     "it captures its own baseline (the coordinator's branch, `HEAD` and `git status --porcelain`) immediately before the dispatch", 13)
need("nothing moving HEAD runs between the redispatch baseline and its check", d5,
     "Nothing that moves the coordinator's `HEAD` or tree runs between this redispatch's baseline and its after-batch check", 13)
need("an unconfirmed in-§2 recovery with a safe serial path resumes in §2, before the capacity stop", d5,
     "resume the existing attempt branch using take-it's Serial variant and the guarded foreground runner **here in §2, before §3's capacity stop**", 13)
need("a failed gate on that recovery holds without launching or spending an allowance", d5,
     "A failed gate holds without launching or spending another allowance.", 13)
need("a recovery that cannot run serially is held with its reason, not demoted for disabled isolation", d5,
     "is held with the specific reason, not demoted for disabled isolation", 13)
need("Claude Code waits for nothing", d5,
     "On Claude Code nothing here waits: the background `Agent` batch is issued as before", 13)
d2 = flatten(section(DR_RAW, "## 2. Reconcile in-flight (always first)"))
if not d2:
    problems.append("dispatch-ready §2 did not slice")
need("§2's failed-check bullet points at §5's in-§2 dispatch", d2,
     "On omp the redispatch goes through §5's isolation check and its in-§2 dispatch.", 13)
need("§2's review-finding bullet points at §5's in-§2 dispatch", d2,
     "On omp it goes through §5's isolation check and its in-§2 dispatch.", 13)
need("an in-§2 omp redispatch counts as a batch for the probe trigger", d5,
     "a single in-§2 omp redispatch counts as a batch for that trigger, so the probe runs before it", 13)
need("the in-§2 redispatch states the invariant rather than a §2 ordering", d5,
     "§2 is not reordered, and the baseline is taken after any earlier §2 step has run", 13)
if "ahead of §2's merge hand-off and its teardown" in d5:
    problems.append("property 13: §5 claims the redispatch runs ahead of §2's merge hand-off, which contradicts §2's bullet order")
need("no later tick runs the after-batch check", d5, "No later tick runs it, because nothing persists a baseline", 13)
for copy in ("task.isolation.enabled", "omp config set", "`merge` `patch`"):
    if copy in d5:
        problems.append(f"property 13: dispatch-ready §5 restates {copy!r}; the reference doc owns it (#452 item 1)")
need("dispatch-ready's unconfirmed outcome is never parallel on a shared tree", d5,
     "**Unconfirmed** → never parallel on a shared tree.", 13)
need("serial needs exclusive ownership, a clean checkout and a supervised foreground runner", d5,
     "With exclusive checkout ownership, a clean safe checkout, and an available supervised foreground runner, select **serial and not isolated**.", 13)
need("serial reuses take-it's Serial variant and the reference's lifecycle rather than restating them", d5,
     "Reuse take-it's Serial variant and the reference's synchronous execution contract.", 13)
need("one plain independent issue for the entire tick, the rest left unclaimed", d5,
     "Select only one plain independent issue for the entire tick, not a stack, and leave all others unclaimed.", 13)
need("an unsafe serial path stops dispatch and names the failed prerequisite", d5,
     "naming the failed prerequisite as well as the isolation setting/probe", 13)
need("the operator's profile is never written to enable isolation", d5,
     "Never enable isolation by writing the operator's profile.", 13)
need("serial is synchronous, not an in-flight shared-checkout task", d5,
     "**Serial is synchronous, not an in-flight shared-checkout task.**", 13)
need("no detached job may outlive an ordinary successful tick", d5,
     "No detached Agent, task, async shell job or worker process may outlive an ordinary successful tick.", 13)
need("termination is awaited, not inferred from a PR, RESULT or comment", d5,
     "Await actual process termination, not a PR, RESULT or terminal-failure comment.", 13)
need("max_in_flight alone is not the protection", d5, "`max_in_flight: 1` alone provides no such protection.", 13)
need("the serial quota is shared with §2 recovery", d5,
     "This consumes the tick's single serial-worker quota even on failure: no second §2 repair and no §5 claim/worker this tick.", 13)
need("a §5 serial claim happens only while the quota remains", d5,
     "if the shared one-worker quota remains unused, claim just the selected independent issue", 13)
need("a confirmed batch that fails the after-batch check dispatches no further batch", d5,
     "A moved branch or `HEAD`, or a dirty tree, dispatches no further batch", 13)
# serial in dispatch-ready is one synchronous worker per tick; it must never grow a
# persisted multi-tick serial record or a second worker (#452's rejected draft).
for forbidden in ('"mode": "serial"', "outstanding serial", "outstanding-serial",
                  "Close each serial record", "that one issue only"):
    if forbidden in d5:
        problems.append(f"property 13: dispatch-ready §5 offers a multi-tick serial path ({forbidden!r}); serial is one synchronous worker per tick")
need("dispatch-ready claims nothing on the stop", d5, "without claiming a single issue", 13)
need("dispatch-ready reports the review_site override on omp", d5,
     "`review_site: agent` is unsatisfiable on omp", 13)
need("dispatch-ready's override is never silent and never edits config", d5,
     "never silent, and the config is never edited", 13)
for stale in ("until #452 lands", "do **not** apply here", "the operator ends the `/loop`",
              "whether to add one is #452's decision"):
    if stale in d5:
        problems.append(f"property 13: dispatch-ready §5 still carries the interim stop ({stale!r})")

# 14. holds and terminal states (#484 replaced #452's isolation-unconfirmed stall)
need("dispatch-ready §5 states reach and holds", d5,
     "**Reach and holds.** Ownership gates all local reconciliation, not just dispatch.", 14)
need("no worker shares the checkout during coordinator work", d5,
     "no worker may share the checkout during it", 14)
need("disabled isolation with a safe serial path is progress, never a stall", d5,
     "Isolation disabled with a safe serial path is progress, never an `isolation unconfirmed` stall.", 14)
need("the one-worker quota is scheduling, not a human hold", d5,
     "The one-worker quota is scheduling, not a human hold", 14)
need("a verified unsafe serial prerequisite is a named execution-safety hold", d5,
     "is a named execution-safety hold", 14)
need("a live worker is self-resolving; a guard without one is an ownership hold §7 escalates", d5,
     "A live worker is self-resolving and proves no terminal state; a held or unresolved guard with no live worker is an ownership hold, which §7 escalates rather than waiting on.", 14)
need("no safety hold authorizes cleanup, a fresh claim, a new allowance or a profile write", d5,
     "No safety hold authorizes cleanup, a fresh claim, a changed recovery allowance or a profile write.", 14)
if "the hold root `isolation unconfirmed`" in d5 or "isolation unconfirmed`, the Blocking" in d7:
    problems.append("property 14: #452's isolation-unconfirmed hold root survives in dispatch-ready; #484 replaced it")
need("§7: only ownership=active is a self-resolving hold", d7,
     "Only a live worker (`status` reports `ownership=active`) is a self-resolving hold like a foreign claim", 14)
need("§7: a guard with no live worker is an ownership hold", d7,
     "A guard with no live worker (`held` or `unresolved`) is an **ownership hold**", 14)
need("§7: an ownership hold is the one STALLED entry that waives in-flight zero", d7,
     "it is the one STALLED entry that does not wait for in-flight zero", 14)
need("§7: an ownership hold is recorded with the checkout ownership root", d7,
     "Record the guard path with root `checkout ownership <created_at>`", 14)
need("§7: disabled isolation alone never joins the held set while serial is available", d7,
     "Disabled isolation alone never joins that set while safe serial execution is available.", 14)
need("§7's STALLED conjunct names verified execution-safety gates", d7,
     "every Ready item held by a §4 filter or a verified §5 execution-safety gate", 14)
need("§7 lists the execution-safety hold among holds a human could clear", d7,
     "a verified execution-safety hold — any one of them", 14)
need("§7's stall record carries the execution-safety and ownership roots", d7,
     "the specific execution-safety prerequisite, an ownership hold's guard path and `created_at`", 14)
need("§2 acquires checkout ownership before any reconciliation", d2,
     "**Checkout ownership is the first precondition,", 14)
need("the reference: only ownership=active is self-resolving", ref,
     "Only `ownership=active` (a live supervisor running a worker) is `checkout active writer`, which is self-resolving.", 14)
need("the reference: a coordinator never abandons a guard", ref,
     "A coordinator never runs `abandon`, deletes the guard, or invents an automatic force-unlock route.", 14)
need("the reference: abandonment is the operator's, with positive evidence", ref,
     "**Operator-only abandonment**, after the operator confirms the owning session has ended:", 14)
need("the reference: nothing time-based releases ownership", ref,
     "No timer, missing PR, blocked issue, terminal comment,", 14)
need("the doc records the terminal-state decision", doc,
     "an unsafe serial prerequisite or an ownership hold ends the loop through DRAIN STALLED, and no fifth state is added", 14)
need("the doc names the behavioural gate that executes the guard", doc, "test-checkout-guard.sh", 14)
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
mutate "$d/$RF" 'Before each launch confirm `git status --porcelain` is empty' 'Before each launch carry on' || bad "M9: mutation did not apply"
expect_fail "M9 clean-tree check before each serial launch removed" "$d" 'each launch is preceded by a clean-tree check'

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
mutate "$d/$RF" 'Replace step 1 with the **Serial variant** verbatim.' 'Replace step 1 with the serial-mode step 0.' || bad "M21: mutation did not apply"
expect_fail "M21 the one name for the serial step diverges" "$d" "the reference doc substitutes the Serial variant for step 1"

d=$(make_copy m22)
mutate "$d/skills/dispatch-ready/SKILL.md" 'without claiming a single issue' 'after claiming up to capacity' || bad "M22: mutation did not apply"
expect_fail "M22 dispatch-ready's stop phrase swapped (phrase only; placement is M23)" "$d" 'dispatch-ready claims nothing on the stop'

# M23: the confirmation paragraph (and everything up to the claim sentence) moved BELOW the
# "claim →" paragraph, still inside §5, so the "not found" branch cannot be what fires;
# only the ordering branch can.
d=$(make_copy m23)
python3 - "$d/skills/dispatch-ready/SKILL.md" <<'PY' || bad "M23: mutation did not apply"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a = s.index("**Confirm isolation before this tick claims anything.**")
b = s.index("For Claude Code and the confirmed parallel path, use take-it's mechanics verbatim")
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
mutate "$d/skills/dispatch-ready/SKILL.md" "(its §4) against this tick's baseline" "(its §4) against the last tick's baseline" || bad "M32: mutation did not apply"
expect_fail "M32 after-every-batch pointer removed" "$d" "dispatch-ready points at the doc's after-every-batch check"

d=$(make_copy m33)
mutate "$d/skills/dispatch-ready/SKILL.md" 'Disabled isolation alone never joins that set while safe serial execution is available.' 'Disabled isolation joins that set.' || bad "M33: mutation did not apply"
expect_fail "M33 disabled-isolation-is-progress decision removed from §7" "$d" 'disabled isolation alone never joins the held set while serial is available'

d=$(make_copy m34)
mutate "$d/skills/dispatch-ready/SKILL.md" "or a verified §5 execution-safety gate" "or by §5's isolation check" || bad "M34: mutation did not apply"
expect_fail "M34 STALLED conjunct no longer names verified execution-safety gates" "$d" "STALLED conjunct names verified execution-safety gates"

d=$(make_copy m35)
mutate "$d/skills/dispatch-ready/SKILL.md" '**Reach and holds.**' '**Notes.**' || bad "M35: mutation did not apply"
expect_fail "M35 Reach and holds paragraph removed" "$d" 'dispatch-ready §5 states reach and holds'

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

d=$(make_copy m47)
mutate "$d/skills/dispatch-ready/SKILL.md" "the specific execution-safety prerequisite, an ownership hold's guard path and \`created_at\`," "the decision gate," || bad "M47: mutation did not apply"
expect_fail "M47 stall record loses the execution-safety and ownership roots" "$d" "stall record carries the execution-safety and ownership roots"

d=$(make_copy m53)
mutate "$d/skills/dispatch-ready/SKILL.md" '## 5. Dispatch

' '## 5. Dispatch

Read task.isolation.enabled here.

' || bad "M53: mutation did not apply"
expect_fail "M53 forbidden restatement injected" "$d" "restates 'task.isolation.enabled'"

d=$(make_copy m54)
mutate "$d/skills/dispatch-ready/SKILL.md" '## 5. Dispatch

' '## 5. Dispatch

Record `{issue, pr, branch, "mode": "serial"}`.

' || bad "M54: mutation did not apply"
expect_fail "M54 multi-tick serial record restored" "$d" 'offers a multi-tick serial path'

d=$(make_copy m55)
mutate "$d/skills/dispatch-ready/SKILL.md" 'Isolation disabled with a safe serial path is progress, never an `isolation unconfirmed` stall.' 'Isolation disabled is an `isolation unconfirmed` stall.' || bad "M55: mutation did not apply"
expect_fail "M55 isolation-unconfirmed stall restored" "$d" 'disabled isolation with a safe serial path is progress, never a stall'

d=$(make_copy m56)
mutate "$d/skills/dispatch-ready/SKILL.md" '**Serial is synchronous, not an in-flight shared-checkout task.**' '**Notes.**' || bad "M56: mutation did not apply"
expect_fail "M56 serial-is-synchronous paragraph removed" "$d" 'serial is synchronous, not an in-flight shared-checkout task'

d=$(make_copy m57)
mutate "$d/skills/dispatch-ready/SKILL.md" 'and leave all others unclaimed' 'and claim up to capacity' || bad "M57: mutation did not apply"
expect_fail "M57 one-issue-per-tick limit replaced" "$d" 'one plain independent issue for the entire tick'

d=$(make_copy m58)
mutate "$d/skills/dispatch-ready/SKILL.md" 'Ownership gates all local reconciliation, not just dispatch.' 'Ownership gates dispatch only.' || bad "M58: mutation did not apply"
expect_fail "M58 ownership-gates-reconciliation sentence replaced" "$d" 'dispatch-ready §5 states reach and holds'

d=$(make_copy m59)
mutate "$d/skills/dispatch-ready/SKILL.md" 'A moved branch or `HEAD`, or' 'Nothing happens, or' || bad "M59: mutation did not apply"
expect_fail "M59 after-batch halt removed" "$d" 'dispatches no further batch'

d=$(make_copy m60)
mutate "$d/skills/dispatch-ready/SKILL.md" "wait for
   that batch's \`task\` results" "carry on" || bad "M60: mutation did not apply"
expect_fail "M60 confirmed tick no longer waits" "$d" 'a confirmed tick waits for its batch'

d=$(make_copy m61)
mutate "$d/skills/dispatch-ready/SKILL.md" 'a `wait` that times out,' 'a `wait` that always returns,' || bad "M61: mutation did not apply"
expect_fail "M61 timeout caveat removed" "$d" 'the timeout caveat is stated'

d=$(make_copy m62)
mutate "$d/skills/dispatch-ready/SKILL.md" 'no worker may share the checkout during it' 'a worker may share the checkout during it' || bad "M62: mutation did not apply"
expect_fail "M62 shared-checkout-during-coordinator-work rule dropped" "$d" 'no worker shares the checkout during coordinator work'

d=$(make_copy m63)
mutate "$d/skills/dispatch-ready/SKILL.md" '**A §2 redispatch on omp is dispatched within §2, not deferred to this batch.**' '**Redispatch.**' || bad "M63: mutation did not apply"
expect_fail "M63 in-§2 redispatch paragraph removed" "$d" 'a §2 redispatch on omp is dispatched within §2'

d=$(make_copy m64)
mutate "$d/skills/dispatch-ready/SKILL.md" 'nothing here waits' 'everything here waits' || bad "M64: mutation did not apply"
expect_fail "M64 Claude Code carve-out removed" "$d" 'Claude Code waits for nothing'

d=$(make_copy m65)
mutate "$d/skills/dispatch-ready/SKILL.md" "On omp the redispatch goes through" "The redispatch waits for" || bad "M65: mutation did not apply"
expect_fail "M65 failed-check pointer removed" "$d" "failed-check bullet points at §5's in-§2 dispatch"

d=$(make_copy m67)
mutate "$d/skills/dispatch-ready/SKILL.md" "On omp it goes through" "It waits for" || bad "M67: mutation did not apply"
expect_fail "M67 review-finding pointer removed" "$d" "review-finding bullet points at §5's in-§2 dispatch"

d=$(make_copy m66)
mutate "$d/skills/dispatch-ready/SKILL.md" 'it captures its own baseline' 'it uses the tick baseline' || bad "M66: mutation did not apply"
expect_fail "M66 own-baseline sentence removed" "$d" 'captures its own baseline before dispatching'

d=$(make_copy m68)
mutate "$d/skills/dispatch-ready/SKILL.md" "a single in-§2 omp redispatch counts as a batch for that" "an in-§2 omp redispatch needs no probe for that" || bad "M68: mutation did not apply"
expect_fail "M68 probe-trigger sentence removed" "$d" 'counts as a batch for the probe trigger'

d=$(make_copy m69)
mutate "$d/$SK" '**Never `git stash`, reset, discard edits, delete a branch or force-push.**' '**Stash freely.**' || bad "M69: mutation did not apply"
expect_fail "M69 serial stash/reset/force-push guard removed" "$d" 'the serial step carries the stash, reset and force-push guard'

d=$(make_copy m70)
mutate "$d/$SK" 'git switch --no-track -c {prefix}' 'git switch -c --no-track {prefix}' || bad "M70: mutation did not apply"
expect_fail "M70 --no-track placed after -c" "$d" 'puts --no-track after -c'

d=$(make_copy m71)
mutate "$d/$SK" 'Shared by take-it and dispatch-ready; never sent on Claude Code or the confirmed parallel path.' 'Sent wherever convenient.' || bad "M71: mutation did not apply"
expect_fail "M71 Serial variant's never-sent-on-Claude-Code rule removed" "$d" 'the serial variant is shared and never sent on Claude Code'

d=$(make_copy m72)
mutate "$d/$RF" 'Only a plain independent issue/list, never a stacked chain' 'Any list, including a stacked chain' || bad "M72: mutation did not apply"
expect_fail "M72 serial opened to a stacked chain" "$d" 'serial is limited to a plain independent issue or list'

d=$(make_copy m73)
mutate "$d/$RF" 'Checkout ownership, a clean/pushed starting checkout,' 'A starting checkout' || bad "M73: mutation did not apply"
expect_fail "M73 serial prerequisites weakened" "$d" 'serial needs ownership, a clean/pushed checkout'

d=$(make_copy m74)
mutate "$d/skills/dispatch-ready/SKILL.md" "Never enable isolation by writing" 'Enable isolation if needed by writing' || bad "M74: mutation did not apply"
expect_fail "M74 profile-write prohibition removed" "$d" "the operator's profile is never written to enable isolation"

d=$(make_copy m75)
mutate "$d/skills/dispatch-ready/SKILL.md" 'entry that does not wait for in-flight zero' 'entry that waits for in-flight zero' || bad "M75: mutation did not apply"
expect_fail "M75 ownership-hold waiver removed" "$d" 'an ownership hold is the one STALLED entry that waives in-flight zero'

d=$(make_copy m76)
mutate "$d/skills/dispatch-ready/SKILL.md" 'Only a live worker (`status`' 'Any held guard (`status`' || bad "M76: mutation did not apply"
expect_fail "M76 only-active-is-self-resolving narrowed away" "$d" 'only ownership=active is a self-resolving hold'

d=$(make_copy m77)
mutate "$d/$RF" 'A coordinator never runs `abandon`, deletes the' 'A coordinator may run abandon after a timeout, deletes the' || bad "M77: mutation did not apply"
expect_fail "M77 coordinator-abandon prohibition removed" "$d" 'a coordinator never abandons a guard'

d=$(make_copy m78)
mutate "$d/$RF" 'Use the foreground CLI below, not an asynchronous `task` or detached shell.' 'Use a task or a detached shell.' || bad "M78: mutation did not apply"
expect_fail "M78 foreground-only launch rule removed" "$d" 'the lifecycle runs a guarded foreground command'

if [ "$FAILED" = 0 ]; then
    echo "isolation-contract tests: all green" >&2
    exit 0
else
    echo "isolation-contract tests: FAILURES above" >&2
    exit 1
fi
