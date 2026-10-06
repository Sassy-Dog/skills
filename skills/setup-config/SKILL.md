---
name: setup-config
description: >
  This skill should be used when the user asks to "set up the config for this repo", "set up this
  repo's sassy-dog config", "configure this repo's workflow skills", "configure survey-work for
  this repo", "configure send-it here", "set up the workflow config", "bootstrap the sassy-dog
  config", "refresh this repo's sassy-dog config", "re-sync this repo's workflow config", "update
  the workflow config", "migrate this repo to config-based workflow skills", "move the workflow
  skills to config", "adopt the legacy hand-written workflow skills", or "declare the sassy-dog
  plugin in this repo's settings". Writes and re-syncs a repo's `.claude/sassy-dog/*.md` workflow
  config plus its `.claude/settings.json` marketplace + plugin declaration, and migrates repos
  still carrying older generated skills under `.claude/skills/`. Run from inside the target
  repository.
---

# Setup Config

Configuration generator for the workflow family. The six skills themselves — `survey-work`,
`groom-backlog`, `take-it`, `dispatch-ready`, `send-it`, `tidy-repo` — ship generically in this
plugin. This skill writes the **per-repo config** they read:

```text
.claude/sassy-dog/<skill>.md      # YAML frontmatter (facts) + ## sections (prose)
.claude/settings.json             # extraKnownMarketplaces + enabledPlugins declarations
```

The format is `references/config-contract.md`. **Read it before writing anything.**

This skill does **not** render skill bodies. A repo that still has
`.claude/skills/{plate-it,fill-it,take-it,drain-it,send-it,clean-it}/` is on the superseded
architecture and needs **migrate mode** (Phase 3).

## Two rules that shape everything here

**Configure only what cannot be derived.** Repo slug, default branch, and `delete_branch_on_merge`
come from `gh repo view` at runtime and never appear in config. A configured value is a value that
can drift — see the drift incident recorded in `references/config-contract.md`.

**Re-verify every configured fact against live state.** Never copy a fact forward from an existing
render or config just because it is written down. `merge_queue` in particular has no `gh repo view`
equivalent and must be read from GraphQL:

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"NAME"){mergeQueue(branch:"BRANCH"){id}}}' \
  --jq '.data.repository.mergeQueue != null'
```

## Phase 0 — locate and pick the mode

Confirm cwd is a git repo with a GitHub remote:

```bash
gh repo view --json nameWithOwner,defaultBranchRef,deleteBranchOnMerge,visibility
```

`visibility` is on that call and is read exactly once: it seeds `review_site:`
(Phase 1). Extend this call rather than adding a second one — and never re-read it on a refresh,
for the reason Phase 4 gives. The plan's tracking choice (Phase 3 step 5, Phase 6) and Phase 7 step 2 reuse this same probe
value; that use is advisory, is never written to config, and never feeds `review_site:`.

**Probe the remote before trusting the checkout.** Every signal the mode table reads lives in the
working tree, and the working tree can be days stale. Fetch, then list what the remote default
branch actually carries (BRANCH is `defaultBranchRef` from the probe above — never assume `main`):

```bash
git fetch origin --quiet
git ls-tree --name-only origin/BRANCH .claude/ .claude/sassy-dog/
```

Route on the **union** of local and remote state. Either remote signal means the checkout is
stale, not un-migrated:

- The remote has `.claude/sassy-dog/*.md` that the local checkout lacks — the migration already
  landed on the default branch.
- The remote no longer carries `.claude/skills/` directories the local checkout still has — the
  deletion half of the same landed migration.

On either signal, instruct a fast-forward pull of the default branch, then **re-probe before
picking a mode** — a remote-migrated repo lands in update mode, never migrate mode. This was hit
live (tailoredtip, 2026-08-08): a 9-day-stale checkout still carried the four marker-bearing
`.claude/skills/` directories, Phase 0 picked migrate mode from local state alone, and the entire
extract/interview/preview/write/delete pipeline ran before rebase conflicts against the remote
exposed that the migration had landed the day before. The probe costs one fetch; the failure it
prevents is all of that work built on a vanished premise.

With local and remote in agreement, pick exactly one mode:

| Found | Mode |
| --- | --- |
| `.claude/skills/<name>/SKILL.md` carrying a `generated-by:` marker | **migrate** (Phase 3) |
| `.claude/sassy-dog/*.md` already present | **update** (Phase 4) |
| Legacy hand-written `*plate-it*` / `*get-it*` / `*send-it*` / `*clean-it*`, no marker | **adopt** (Phase 5) |
| None of the above | **create** (Phase 6) |

**Marker recognition accepts every producer name.** Match on the `generated-by:` prefix and accept
`refresh-skills` (plugin 2026.7.22 until this skill became `setup-config`),
`refresh-skills` (plugin 0.9.0–2026.7.21), and `create-dev-workflows` (≤ 0.8.1). Match it
**anywhere in the file** — older renders put it on line 1, where the loader could not parse the
frontmatter, and hand-fixes moved it. A repo whose marker is not recognised falls through to adopt
or create mode and its config is silently lost, so this matcher is load-bearing.

`setup-config` is deliberately **absent** from that list, and must stay absent. The list is frozen
history: it matches only the superseded generated-skills path (`.claude/skills/<name>/SKILL.md`),
and the `.claude/sassy-dog/*.md` config this skill writes carries **no** `generated-by:` marker at
all. A `setup-config` marker has never existed to recognise.

## Phase 1 — detect

Read `references/detection.md`, run `scripts/detect-capabilities.sh` from the repo root, and do the
listed hand-checks (Sentry project **verified by culprit**, review-orchestrator agents, mobile
workflows). Detection output is evidence, not truth — consequential fields get confirmed in Phase 2.

### Seed `review_site` — once, from visibility, then never again

`take-it.md` and `dispatch-ready.md` each carry a `review_site:` key deciding **where** their review
gate runs: in each dispatched sub-agent before its PR opens (`agent`), or in the dispatching loop
after each PR opens and before it merges (`coordinator`). Resolve it from the `visibility` field of
the Phase 0 probe and write the resolved value **explicitly** into both files:

| `visibility` | `review_site:` |
| --- | --- |
| `PUBLIC` | `agent` |
| `INTERNAL` / `PRIVATE` | `coordinator` |

**Write the resolved value, never the rule that produced it,** and never leave the key out so a
skill can read visibility at run time. A derived `review_site` means a later visibility change
silently rewrites the repo's review architecture — taking a repo private downgrades pre-PR review
to after-the-fact review with nothing announcing it, the failure class issue #187 documents.
`references/config-contract.md` → `review_site` carries the full argument; read it before
"simplifying" this key into a derivation.

Exposure is only the *default* grounds for the choice, so the seeded value is a proposal like any
other: show it in the preview, and let the user override it on cost, latency, or a wish for
stricter review than the repo's visibility implies.

**The Sentry hand-check is a verification, not a listing.** An MCP project listing proposes
candidates; **name similarity is not evidence**, because a Sentry project and a repo can share a
name and belong to different codebases. Sample the candidate's recent issues and confirm their
`culprit` / route / file paths resolve in *this* repo. Unverified — including no MCP server and no
issues to sample — writes `sentry: none` (the confirmed-absent form, `references/config-contract.md`),
never a guessed block. The sibling-checkout prior-claim scan is best-effort and secondary; it never
substitutes for the culprit check and never blocks the run.

## Phase 2 — interview

Read `references/interview.md`. Ask only policy questions and unconfirmable facts. Merge policy is
**always** confirmed against live state, never asked from memory — a wrong merge policy is the most
expensive mistake this generator can make.

**Never default a confirmed-absent `none`.** `testflight: none`, `posthog: none` and `mobile: none`
are written only on an explicit answer to interview §2c — detection may propose one, but a quiet
tree is not a confirmation, and a guessed `none` retires a real blind spot with nothing announcing
it. (`sentry: none` is the exception in the other direction: it is never asked, it is what a failed
culprit check records.)

In migrate mode most answers come from the existing render; ask only about what it cannot supply.

## Phase 3 — migrate mode

Converts a repo from generated skills to config. Read `references/migrate-mode.md` first.

The essential shape:

1. **Extract** facts and `BEGIN/END PROJECT-SPECIFIC` fence contents from each generated SKILL.md
2. **Re-verify** every extracted fact against live state — extracted values are *stale by default*
3. **Map** legacy names to current config files per `references/migrate-mode.md` Step 3
   (`plate-it` → `survey-work.md`, `fill-it` → `groom-backlog.md`, `drain-it` →
   `dispatch-ready.md`, `clean-it` → `tidy-repo.md`), carrying each skill's prose
4. **Write** `.claude/sassy-dog/*.md` + merge `.claude/settings.json`
5. **Preview** the full config, the exact list of directories to be deleted, and — in a public
   repo — the tracking choice (see "Tracking choice in the plan" under Phase 6)
6. **Delete** the old `.claude/skills/<name>/` directories only after approval

**Order is not negotiable: write config, verify, then delete.** The generated skill is the *source*
the config is extracted from. Deleting first destroys the only copy of the repo's Sentry projects,
board IDs, scan paths, and project-specific prose.

**Never touch a directory without a `generated-by:` marker.** Hand-written skills that happen to
sit alongside — `qr-ninja-design`, `what2wear-clean-it`, velovate's `terraform-apply` — are not
yours.

## Phase 4 — update mode

The repo already has `.claude/sassy-dog/*.md`. Re-run detection, re-verify every fact against live
state, and diff the result against the committed config.

**Frontmatter is regenerated; `##` prose sections are carried across verbatim.** That split is the
whole point of the format — prose is the thing a refresh must never rewrite.

**`review_site:` is a fact this phase must NOT re-derive.** It was seeded from visibility at
setup and is carried forward unchanged; re-reading visibility here is precisely what would flip a
repo's review architecture on the first refresh after a visibility change, with the change invisible
in every run's output. If live visibility no longer matches what the configured value implies,
**stop and surface both sides** — the same shape a `merge_queue` disagreement gets — and let the
user decide. If the key is absent because the config predates it, propose the seeded value as an
addition and say so in the preview; until then the reading skills default it to `coordinator`.

**`execution_site:` is the same kind of fact, for a different reason** — see the guardrail below,
which owns the rule. The one thing that belongs in *this* phase: a platform differing from the
configured name is NOT a disagreement and must not be routed into the stop-and-surface rule above.
`MINGW64_NT-…` against `execution_site: vdi` is the ordinary case — it is *why* the name is
configured rather than derived. Only the user disputing their own value is a disagreement, and that
is theirs to raise.

**The three `none` answers are carried forward, not re-asked** — but an **absent** one is asked.
**`sentry: none` is not one of them.** `testflight: none`, `posthog: none` and `mobile: none` each record
a human's confirmation, so re-litigating them on every refresh reopens exactly what the form closed.
The one signal that reaches an existing value is *positive* evidence — an iOS target under a
`mobile: none`, a PostHog SDK under a `posthog: none` — and that is a **stop and surface** like any
other disagreement, never a silent rewrite. **Where one of the three is missing entirely (or carries
a `posthog: false`), put interview §2c to the user for that key**: every consumer repo predates this
form, so absent is the state they are all in, and a refresh that only carries values forward would
change nothing anywhere.

**`sentry: none` is re-derived on every refresh, like any other fact.** It is written when the
culprit check fails *or could not run* — no MCP server, no issues to sample — which are conditions of
the session, not facts about the repo. Freezing it would let one unlucky run permanently retire the
plate's highest-signal surface with no path back, since the only contradicting evidence is the check
that was skipped. See `references/update-mode.md`.

Apply per file, on approval only.

**In a public repo, the preview also carries "Tracking choice in the plan"** (Phase 6) whenever
this run writes `.claude/settings.json`; update mode is not exempt, or a refresh would leave
`settings.json` and `hooks/` tracked.

## Phase 5 — adopt mode

Legacy hand-written skills with no marker. Read `references/update-mode.md`. Side-by-side review of
every hand-written section, the user decides per section (fold into config prose / promote upstream
as plugin feedback / drop), then the legacy directories are deleted on approval. In a public repo the preview also carries
"Tracking choice in the plan" (Phase 6) whenever this run writes `.claude/settings.json`.

## Phase 6 — create mode

No prior state. Interview, then write config. Render each file from
`references/templates/<skill>.config.md`: substitute the `{{FACT}}` placeholders, omit each optional
block this repo lacks, drop the template's own leading comment block, and keep everything below the
frontmatter as written — including a `##` section's explanatory comment, which is the only place a
generated config explains its own conventions to the next reader.

**The template is the starting point, never the authority on completeness.** Check the rendered
config against `references/config-contract.md`'s template applicability inventory before printing
it, including nested fields: a template can lag the contract, and rendering is not a licence to omit
an applicable slot. Write the already-resolved `review_site` explicitly in both dispatch configs,
outside optional omissions; Phase 1 owns the seed and override, and Phase 4 owns carry-forward.
An absent `review_agent` is valid and selects the shipped orchestrator; preserve an explicit `skip`
or override and any hand-set `review_surfaces` without inventing a map. Conditional slots use only
the existing verified facts and interview consent; omit declined opt-ins and boardless blocks
wholesale, and leave no unresolved placeholders. **Print every file in full and
write only after the user approves** — writing into a product repo is outward-facing and never
silent.

### Tracking choice in the plan (every mode that writes `settings.json`, public repos)

**This section owns the tracking mechanics, the two end states and every transition between
them.** `setup-hooks`, `setup-repo` and `references/migrate-mode.md` reference it and never restate
it, so the generators cannot diverge.

Whether `.claude/settings.json` and the owned hook scripts are tracked is decided **in the approved
plan**, not advised after the write. It applies in create, migrate, update and adopt modes whenever
this run writes `settings.json`, and only when `visibility` from the Phase 0 probe is `PUBLIC`
(unknown visibility: ask, as `setup-hooks` does; private and internal repos see none of this and a
committed `settings.json` stays the default). The chosen **target** is one of two end states, both
defined by the exact `.gitignore` shape and by tracked/ignored status. "Owned scripts" means the
`.claude/hooks/sassydog-*.sh` files that exist or that this run's generators render: the artifact
guard always, the post-edit dispatcher only when a tool was detected. Any other file under
`.claude/hooks/` is **non-owned**.

| End state | `.gitignore` (in this order) | `settings.json` and each owned script |
|---|---|---|
| **local** (public default) | `.claude/*`, then `!.claude/sassy-dog/`; neither `!.claude/settings.json` nor `!.claude/hooks/` | untracked **and** ignored |
| **committed** | `.claude/*`, then `!.claude/sassy-dog/`, `!.claude/settings.json`, `!.claude/hooks/`; every negation after `.claude/*` | tracked **and** not ignored |

In both, `.claude/sassy-dog/*.md` is tracked and not ignored, and `.claude/settings.local.json`,
`worktrees/` and the rest of `.claude/` stay ignored. There is no third form: never narrow or drop
`.claude/*`, because that un-ignores `settings.local.json`.

**Derive the current state from the repo, every run** (a declined choice is never persisted, so
this is what stops a re-run re-proposing). Per-line, never with a bare `git check-ignore` on a
tracked path; probe ignore status with `git check-ignore --no-index -q` (exit 0 = ignored) and
tracking with `git ls-files --error-unmatch`; a line is present iff `grep -qxF` finds it, and its
position is `grep -nxF`:

- **committed:** both negations present after `.claude/*`, and `settings.json` tracked and not
  ignored.
- **local:** neither negation present, `.claude/*` then `!.claude/sassy-dog/` in order, and
  `settings.json` untracked and ignored.
- **mixed:** anything else (one negation missing, a negation before `.claude/*`, a bare `.claude/`
  or `.claude` line, tracked-but-ignored, untracked-but-not-ignored, no lines at all).

| Derived state | Target **local** | Target **committed** |
|---|---|---|
| local | nothing | **local → committed** |
| committed | **committed → local** | nothing |
| mixed | report the exact mismatch; propose the transition to **local** | report the exact mismatch; propose the transition to **committed** |

"Nothing" means the preview shows no tracking change at all. Every transition below is shown in the
preview, approval-only, never run unpreviewed:

- **local → committed.** Add `!.claude/settings.json` and `!.claude/hooks/` after `.claude/*`
  (and the `!.claude/sassy-dog/` line if missing), then `git add` `.claude/settings.json` and each
  owned script **individually by path, never the directory**. List non-owned files under
  `.claude/hooks/` separately and do not auto-add them; say that `!.claude/hooks/` un-ignores
  them, so a later `git add -A` would stage them, and that they are the user's to commit or
  to ignore by a specific line.
- **committed → local.** Remove those two negation lines. Untrack with `git rm --cached` on
  `.claude/settings.json` and each owned script, individually (working copy stays; the deletion is
  staged, not committed). `git rm -r --cached .claude/hooks` would untrack non-owned files too, so
  list each non-owned file under `.claude/hooks/` separately and name it in the warning below.
- **mixed → target.** Whichever of the two above reaches the target shape, fixing a misordered
  line by moving it after `.claude/*`, replacing a bare `.claude/` or `.claude` line with
  `.claude/*` (flagged, never silently kept: `.claude/` followed by `!…` does not re-include,
  because an ignored directory is never visited), and adding only the lines still missing.

**What untracking does to everyone else.** After an untracking commit lands, every collaborator
who pulls has those files **deleted** from their working tree: their plugin declaration and any
hand-added `PreToolUse` push guard go with it (a prior migration lost one exactly this way). The
preview says so and gives the restore, run **right after pulling** (the pull is what deletes the
file, so a restore run before it is undone):
`git restore --source=<untrack-commit>^ --worktree -- .claude/settings.json .claude/hooks/<each
path the commit untracked, non-owned ones included>` (it recreates the `.claude/hooks/` directory
the pull removed, keeps the exec bit, and leaves the files untracked and ignored; a
`git show … > path` redirect fails there with "No such file or directory"), or re-run
`setup-hooks` for the owned ones. It **warns when the file holds keys beyond the generators' own**
(anything other than `extraKnownMarketplaces`, `enabledPlugins` and hook entries whose command
contains `.claude/hooks/sassydog-`, for example `permissions`, `env`, or non-owned hooks), since
those are shared team settings that stop being shared.

**Other tracked `.claude/` paths.** List `git ls-files .claude` entries outside `sassy-dog/`,
`settings.json` and the owned scripts (kept `skills/`, `agents/`, `commands/`). `.claude/*` would
silently ignore new files there, so offer a `!.claude/<dir>/` line for each such directory.

**Verify the end state** with `--no-index` probes: local target, exit 0 for `settings.json` and each
owned script; committed target, tracked and exit 1 for each; either way exit 1 for
`.claude/sassy-dog/<name>.md` (the config has to stay committable) and exit 0 for
`.claude/settings.local.json`.

The user may decline and keep the files tracked; that is recorded in the report. It is not
persisted, so a later run derives the mixed state again and re-proposes the transition; say so.
Visibility is never written to config and never feeds `review_site:`.

## Phase 7 — verify

1. Every written `.claude/sassy-dog/*.md` parses: `---` on line 1, valid YAML frontmatter, `##`
   sections intact.
2. If `.claude/settings.json` exists — tracked or kept local — it is valid JSON and declares
   **both** the marketplace (`extraKnownMarketplaces`) and the plugin (`enabledPlugins`). **Committing it is
   a per-repo choice for local multi-machine convenience, not a requirement, and it does not
   reach cloud sessions or scheduled routines.** Per the Claude Code docs (plugins/install, "Cloud
   session"; plugins/loading; cloud-environments, "What carries over"), a cloud session loads
   neither the plugins installed on a user's machine nor the ones a repo's `.claude/settings.json`
   turns on, and it does not add the marketplaces under `extraKnownMarketplaces`, because that
   needs the workspace trust dialog, which a cloud session never shows. A scheduled routine cannot
   load a plugin skill at all (#175); only org-managed settings reach those sessions.
   Declaring the plugin costs something to every contributor without it: a project-only
   `enabledPlugins` entry for a `github`-sourced plugin installs nothing, so they get a `/plugin`
   Errors-tab row, and accepting the trust dialog clones the marketplace repo in the background.
   - **Public repos** (`visibility` from the Phase 0 probe — never from config): **verify** the
     end state the approved plan chose, with the "Verify the end state" probes of "Tracking choice
     in the plan" (`--no-index`, because the config is tracked and a plain probe exits 1
     regardless of `.gitignore`). Verify only when this run's plan carried the tracking choice
     (create, migrate, or an update or adopt run that writes `settings.json`); otherwise no plan
     made the choice, so report the derived state (local, committed or mixed) only and say which
     case applied. Other tracked `.claude/` paths (kept `skills/`, `agents/`) are expected and not
     an error. Report any mismatch rather than fixing it unpreviewed; if the user declined the
     choice, say so. The default rule behind it: `settings.json` and `hooks/` stay local. Hooks in a
     project's settings run with **no trust prompt** when only a parent folder was trusted, under
     `claude -p` / the Agent SDK, and in cloud sessions (permissions, "What runs before you trust a
     folder"; cloud-environments, "What carries over"), so in a public repo a tracked
     `.claude/hooks/sassydog-*.sh` is code that runs on contributors' machines without per-repo
     consent and is editable by any PR. The ignore-file form is `.claude/*` followed by
     `!.claude/sassy-dog/`; `.claude/` followed by `!…` does **not** re-include, because the
     directory itself is ignored and its contents are never visited. Ignoring alone is not a
     boundary: checking out a branch that force-adds `.claude/settings.json` overwrites the local
     ignored copy and deletes it on switching back. A CI guard that fails when anything under
     `.claude` other than `.claude/sassy-dog/<name>.md` is tracked is an option (case-insensitive,
     any depth, symlinks caught); `Sassy-Dog/solador` ships one as `scripts/claude-dir-guard.sh`.
     Offer it, never add it unasked.
   - **Non-public repos:** committing the declaration remains reasonable, since team members on
     other machines pick the plugin up from it.
3. In migrate mode: `.claude/skills/` contains no marker-carrying directory, and every unmarked one
   still exists.
4. Remind: config is read at skill invocation, so it takes effect immediately — no session restart
   needed, unlike the old generated skills.
5. Suggest a first run: `plate it`, then `send it` on a trivial branch.

## Guardrails

- Never write into the target repo without showing full content and getting approval.
- Never delete a directory lacking a `generated-by:` marker.
- Never delete generated skills before their config is written and verified.
- Never copy a fact forward without re-verifying it against live state — except `review_site:`,
  which is seeded once and carried forward by design; `execution_site:`, which names a machine no
  live state can name back and is likewise carried verbatim, with an absent one left absent; and
  the three confirmed-absent `none` forms
  (`testflight:`, `posthog:`, `mobile:`), which record a check that already happened.
  **An `execution_site:` is proposed in exactly one place — interview §3d, in create, migrate and
  adopt modes only** ([#343](https://github.com/Sassy-Dog/skills/issues/343)). A refresh
  never offers it, and that is what records a "declined": those three modes run once per repo, so a
  user who said no is not asked again. Move the question into the refresh path and the proposal is
  re-offered forever.
  **`sentry: none` is not one of them**: it is re-derived on every refresh, because it is also
  written when the culprit check merely could not run, so freezing it would retire the plate's
  highest-signal surface with no path back (Phase 4, `references/update-mode.md`). A
  live-visibility mismatch is surfaced, never applied.
- Prose in `##` sections is user-owned: carried across verbatim, never rewritten or summarised.
- This skill always runs from the plugin; it is never copied into a consumer repo.
