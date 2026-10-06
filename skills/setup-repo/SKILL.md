---
name: setup-repo
description: >
  This skill should be used when the user asks to "set up this repo", "set this repo up",
  "bootstrap this repo", "setup repo", "configure this repo", "wire this repo up", "get this repo
  set up", "onboard this repo", "set up everything for this repo", "new repo setup", or "full repo
  setup" — the broad whole-repo intent, with no single area named. Orchestrates the three
  generators strictly in sequence (workflow config, then hooks, then dependency automation),
  presents one combined plan of every file they would touch, and reports what ran, what was
  skipped, and why. Delegates all generation and owns none of it. Run from inside the target
  repository. When the user names one area specifically — config, hooks, or Dependabot — that
  generator runs directly instead of this one.
---

# Setup Repo

The umbrella entry point for the generator family. "Set up this repo" is three jobs, not one:

| Order | Generator | Owns |
| --- | --- | --- |
| 1 | `sassy-dog:setup-config` | `.claude/sassy-dog/*.md` workflow config + the `.claude/settings.json` marketplace/plugin declaration |
| 2 | `sassy-dog:setup-hooks` | `.claude/hooks/sassydog-*.sh` + their `.claude/settings.json` hook entries |
| 3 | `sassy-dog:setup-deps` | `.github/dependabot.yml` + the dependency automation workflows |

**This skill contains no generation logic.** Detection, mode selection, ownership markers,
rendering and content previews all live in the three generators. A bug in any of that is fixed in
the generator, never here. This skill decides only *which* generators run, in *what order*, and
what the run report says.

**The trigger description above owns the broad intent ALONE, and that scope is deliberate.** Each
of the three generators keeps its own specific vocabulary — "set up hooks for this repo", "add
dependabot config here", "configure survey-work for this repo" — and a description here that
swallowed those phrasings would make the specific invocations ambiguous: a user who names one area
would land on the umbrella and get a three-generator plan they did not ask for. Broadening this
description is the trigger-phrase tightening to refuse.

## Why the orchestrator exists

**The gap is invisible.** A repo reached through one generator alone is a third of a setup, and
nothing reports the other two-thirds as missing — it surfaces later as a repo with no hooks, or a
Dependabot flood nobody automated. Naming all three in one report is the
whole point.

**The shared write.** `setup-config` and `setup-hooks` both write `.claude/` settings — config
writes `extraKnownMarketplaces` + `enabledPlugins` to `.claude/settings.json`, hooks writes the
`hooks.PostToolUse` entry to `.claude/settings.json` (or `settings.local.json`, where the
generator's own public-repo rule sends it). Whether files are tracked is each generator's call
(`setup-config` Phase 7 step 2); this skill only relays it.
Each documents a *surgical merge into its own keys*, never a rewrite, so **sequential** runs
compose: the second reads the file as the first left it and adds to it. Run them concurrently — or
let either plan against one copy and write back a whole file later — and one of the two
declarations vanishes with no error anywhere, because both generators' contracts are
report-and-skip, not fail. A prior migration lost a consumer's `PreToolUse` push guard to exactly
this class of settings overwrite.

**Never dispatch these as parallel sub-agents. One at a time, in order, each reading
`.claude/settings.json` as the previous one left it.**

## Phase 0 — locate

Confirm the cwd is the target repo root, and that it is a GitHub repo:

```bash
git rev-parse --show-toplevel
gh repo view --json nameWithOwner,defaultBranchRef
```

Run from inside the repo being set up — never from the plugin checkout.

## Phase 1 — plan, read-only

Walk the three generators **in order**. For each, invoke it by namespaced name and follow it
through its own detection and mode selection, stopping at the point where it would write:

1. `Skill: sassy-dog:setup-config`
2. `Skill: sassy-dog:setup-hooks`
3. `Skill: sassy-dog:setup-deps`

Capture from each: the mode it picked, and **every file it would create or modify**. Take the
generator's own detection output at face value — this skill never second-guesses it, and never
re-derives a stack of its own.

A generator drops out of the sweep here, not silently:

| Reason to skip | Source of the decision |
| --- | --- |
| The user asked for only part of the setup | the user, at invocation or at the plan gate |
| Detection found nothing to render (no configured formatter/linter, no ecosystem, no CI) | that generator's own detection output |
| A prerequisite the generator itself refuses to proceed without | that generator's guardrails |

Record the reason verbatim. Anything skipped is carried into the report in Phase 4.

## Phase 2 — combined plan gate

Print one plan covering all three: per generator, its mode, the full list of files it would create
or modify, and — for anything skipped — the reason. Then ask for approval. **Nothing is written
before this gate.**

Where a generator reports a tracking or `.gitignore` change in a public repo, the plan relays that
report as that generator reported it. `setup-config` owns the displayed `.gitignore` edit and
`setup-hooks` shows it only when run standalone, so it appears once; this skill assigns no
mechanics of its own.

Two of the three print their full rendered content before writing as well (`setup-config`,
`setup-hooks`). This gate is what makes the *sweep* visible: three generators firing across
`.claude/` and `.github/` is exactly the blast radius this repo's preview-then-confirm convention
exists for, and it is the only gate covering a generator that has no content preview of its own.

The user may approve all, approve a subset, or cancel. A generator dropped at this gate is a
skip with the reason "declined at plan gate" — it still appears in the report.

## Phase 3 — apply, strictly in sequence

Run the approved generators one at a time, in the order above. Each keeps its own guardrails and
its own content-preview gate; this skill never bypasses them.

**Do not start the next generator until the previous one has finished writing (or has been
declined).** That ordering is the settings-merge contract, not a stylistic preference — see the
shared-write section above.

If a generator fails or is declined mid-sweep, keep going with the remaining ones (they are
independent apart from the settings-file ordering) and record the failure. Never abandon the run
report.

## Phase 4 — verify and report

When both settings writers ran, confirm the file carries both declarations and the hook entry —
this is the direct proof that the shared write composed rather than clobbered:

```bash
jq '{extraKnownMarketplaces, enabledPlugins, hooks}' .claude/settings.json
```

Any of those three showing `null` after its generator reported success means one write overwrote
another. Say so plainly and stop; do not re-run a generator over a clobbered file without first
showing the user what is missing.

Then print the run report — one row per generator, always three rows:

| Generator | Mode | Outcome | Detail |
| --- | --- | --- | --- |
| `setup-config` | create/migrate/update/adopt | applied / skipped / declined / failed | files written, or the skip reason |
| `setup-hooks` | create/refresh | applied / skipped / declined / failed | files written, or the skip reason |
| `setup-deps` | — | applied / skipped / declined / failed | files written, or the skip reason |

A missing row is an incomplete run, not a clean one. Close with when each change takes effect:
config is read at skill invocation (immediately), hooks load on the next session in that repo, and
dependency automation takes effect on Dependabot's next run.

## Guardrails

- Never write anything directly. Every file in a consumer repo is written by the generator that
  owns it.
- Never run the generators concurrently, and never reorder them — `setup-config` before
  `setup-hooks` is the settings-merge contract.
- Never skip a generator silently. A skip is a reported outcome with a reason.
- Never re-implement a generator's detection, mode selection, or ownership matching here. Fix it in
  the generator.
- Never proceed past the plan gate without approval.

## Additional resources

Read the generator's own SKILL.md when you reach its step in Phase 1 — each carries its detection
tables, mode rules, ownership contract, and reference docs:

- **`skills/setup-config/SKILL.md`** — workflow config + the marketplace/plugin declaration.
- **`skills/setup-hooks/SKILL.md`** — hook dispatcher render + the settings-entry merge contract.
- **`skills/setup-deps/SKILL.md`** — Dependabot config + dependency automation workflows.
