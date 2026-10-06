# Migrate mode

Converts a repo from the superseded generated-skills architecture to config.

Entry here is decided by Phase 0's union of local **and remote** state. Generated skills present
only in the local checkout — while the remote default branch already carries
`.claude/sassy-dog/*.md` or has deleted the `.claude/skills/` directories — mean a stale checkout,
not an un-migrated repo: fast-forward, re-probe, and land in update mode instead.

**Before:** `.claude/skills/{plate-it,fill-it,take-it,drain-it,send-it,clean-it}/SKILL.md` — each a
full rendered skill body carrying that repo's facts inline.

**After:** `.claude/sassy-dog/{survey-work,groom-backlog,take-it,dispatch-ready,send-it,tidy-repo}.md`
— config only, read by the generic plugin skills. (Four skills were renamed after the generated
era — the full legacy → current map is Step 3.)

## The ordering rule

```text
1. Extract    from the generated SKILL.md
2. Re-verify  every fact against live state
3. Write      .claude/sassy-dog/*.md + .claude/settings.json
4. Preview    config + the exact deletion list
5. Delete     the old directories, on approval only
```

**The generated skill is the SOURCE, not merely the thing being replaced.** It holds the only copy
of the repo's Sentry projects, board IDs, scan paths, and project-specific prose. Deleting before
writing destroys the input and leaves nothing to recover from short of git history.

This was verified live: in an un-migrated repo the generic `survey-work` finds no config and routes
the user back to the project skill, because that is still where the real configuration lives. Delete
it early and both paths degrade at once.

## Step 1 — extract

Per generated `SKILL.md`, pull two things.

**Facts**, from the rendered prose. The old templates interpolated these inline, so they appear as
concrete values rather than placeholders:

| Config key | Where it was rendered |
| --- | --- |
| `scan_paths`, `exclude_pathspecs` | plate-it §C `SCAN_PATHS=` / `EXCLUDE_PATHSPECS=` |
| `ci_workflow` | plate-it §C `WORKFLOW=` |
| `sentry.org`, `sentry.projects` | plate-it §A Sentry line |
| `testflight.bundle_id` | plate-it §A TestFlight line |
| `mobile.release_workflow`, `mobile.path_prefix` | plate-it §C mobile release lag |
| `posthog` | presence of the plate-it PostHog paragraph |
| `secret_bootstrap` | plate-it §1 bootstrap command |
| `write_policy` | plate-it — a §6 write gate means `gated`, else `read-only` |
| `board.*` | any board GraphQL ID block (project, status field, option ids) |
| `priority_labels` | plate-it §4 Backlog scoring line |
| `preflight_commands` | send-it pre-flight block |
| `pr_template_path`, `pr_template_sections` | send-it PR-body section |
| `migrations.*`, `codegen.*` | send-it freshness gates |
| `review_agent` | send-it review-orchestrator block |
| `stack_summary` | take-it sub-agent prompt, first line |
| `max_in_flight` | drain-it capacity line |
| `gotcha_summary` | fill-it §3 "Record repo gotchas" |
| `dep_version_globs`, `noise_allowlist`, `never_discard` | clean-it project-facts table |
| `claim_label` | clean-it claim-label row, or take-it's claim step |

**Prose**, from the fences. Copy the content *between* the markers verbatim.

Three rules, each of which was violated by a first attempt at this migration:

1. **Strip HTML comments before deciding whether a fence is empty — and they span multiple lines.**
   A line-based filter reports this as two lines of prose when it is an empty placeholder:

   ```markdown
   <!-- BEGIN PROJECT-SPECIFIC: extra-cleanup -->
   <!-- Repo-unique cleanup steps that repo-cleanup doesn't cover (extra label hygiene, cache dirs,
        vendored-artifact pruning, etc.) go here and survive template updates. -->
   <!-- END PROJECT-SPECIFIC -->
   ```

   Strip with a DOTALL `<!--.*?-->` pass, then test whether anything remains. Migrating a
   placeholder writes template boilerplate into config as if the user had authored it — and the
   next refresh then preserves it forever, because prose is never rewritten.

2. **Verbatim means verbatim — do not re-wrap.** Line width is not yours to normalise. MD013 is
   disabled in this repo's markdownlint config precisely so long lines survive.

3. **Never synthesise prose from a fact you already captured in frontmatter.** If `merge_queue:
   true` is in the frontmatter, do not also write a "Merge policy" paragraph restating it — that is
   two sources for one fact, and the prose half is the one that goes stale silently.

Fence-to-config mapping:

| Fence slot | Config section | Destination file |
| --- | --- | --- |
| `extra-surfaces` | `## extra-surfaces` | `survey-work.md` |
| `scoring-overrides` | `## scoring-overrides` | `survey-work.md` |
| `extra-rubric` | `## extra-rubric` | `groom-backlog.md` |
| `subagent-rules` | `## subagent-rules` | `take-it.md` |
| `extra-sequencing` | `## extra-sequencing` | `dispatch-ready.md` |
| `extra-gates` | `## extra-gates` | `send-it.md` |
| `extra-cleanup` | `## extra-cleanup` | `tidy-repo.md` |
| `extra-guardrails` | `## extra-guardrails` | whichever file it came from |

All eight slots must round-trip. Earlier docs listed only six — `extra-rubric` and
`extra-sequencing` were omitted while the templates emitted them, so a migration written from that
list would silently drop two repos' worth of prose.

## Step 2 — re-verify, because extracted facts are stale by default

**A rendered fact was true when it was rendered. Nothing has re-checked it since.**

Migrating this plugin's own repo surfaced two wrong facts in its own generated skills: they asserted
`delete_branch_on_merge: false` and "there is no merge queue", while the repo had since enabled
both. The derivable one self-corrected the moment it stopped being configured. `merge_queue` did
not, and only a rejected `gh pr merge --delete-branch` exposed it.

Re-verify at minimum:

```bash
# Derived facts — these never enter config at all
gh repo view --json nameWithOwner,defaultBranchRef,deleteBranchOnMerge

# merge_queue has no `gh repo view` equivalent
gh api graphql -f query='{repository(owner:"OWNER",name:"NAME"){mergeQueue(branch:"BRANCH"){id}}}' \
  --jq '.data.repository.mergeQueue != null'

# Workflows named in ci_workflow / mobile.release_workflow still exist
gh workflow list --json name,path
```

**Do not carry `coauthor` forward — drop it.** Older generated skills pinned a commit trailer
naming a specific model (`Co-Authored-By: Claude Opus 4.8 (1M context)`). That fact is wrong the
moment a different model does the work, and it is wrong on *every commit* while looking entirely
deliberate. The trailer is now derived from the running model; if the config being migrated has a
`coauthor` key, drop it and say so in the preview.

**Also grep the extracted prose for a pinned model name.** Prose is user-owned and never rewritten,
so a `Commit trailer: Co-Authored-By: Claude <old model>` line inside a `subagent-rules` block
survives migration intact and keeps pinning the wrong model. Surface it for the user to edit; do not
silently rewrite it.

Board option IDs, Sentry project slugs, and label names are equally capable of drifting. Anything
you cannot verify, surface to the user rather than carrying it forward silently.

**Measured on a real migration.** Running this against this plugin's own pre-migration skills, six
facts were extractable and five were safe to carry:

| Fact | Extracted | Live | Verdict |
| --- | --- | --- | --- |
| `scan_paths` | `skills agents` | — | safe |
| `exclude_pathspecs` | `""` | — | safe |
| `ci_workflow` | `ci.yml` | confirmed by `gh workflow list` | safe |
| `write_policy` | `read-only` | — | safe |
| `max_in_flight` | `3` | — | safe |
| **merge policy** | **"direct squash merge"** | **queue enabled** | **WRONG** |

The one poisoned fact is indistinguishable from the other five by inspection — it reads as a
confident, specific statement. Only the live check separates them, which is why this step is not
optional and not a "when in doubt" measure.

## Step 2b — ask §2c for the three confirmed-absent keys, always

A generated skill has no way to express a `none`, so **extraction can never produce one**. Every
migrated config therefore arrives with `testflight:`, `posthog:` and `mobile:` absent — which means
"nobody has checked" and renders a `survey-work` blind-spot row for each, permanently, with no config
that clears it (issue [#261](https://github.com/Sassy-Dog/skills/issues/261)).

So put **interview §2c** to the user for all three, here, as part of this mode. This is the one
question migrate mode must ask rather than infer: Step 1's "ask only about what the render cannot
supply" applies, and a `none` is precisely what a legacy render cannot supply.

Two things not to shortcut. A quiet tree is **not** an answer — `none` asserts that a human checked,
so it is never defaulted or inferred. And `sentry:` is **not** part of this question: its `none` is
written by the culprit check in `references/detection.md`, and it keeps its blind-spot row
deliberately (`references/config-contract.md`, "The one exception").

## Step 2c — ask §3d for `execution_site`, once

The same shape as Step 2b and for the same reason: a legacy generated skill cannot express an
execution site either, so extraction never produces one. The full rule is
**`execution_site` on a migration** at the end of this file — read it here rather than walking past
it, because it is an offer this mode makes exactly once and a walk of Steps 1-6 is what an agent
follows.

## Step 3 — the renames: legacy names map to current names

Four of the six skills have been renamed since the generated era (`fill-it` twice, via `groom-it`).
Every legacy artifact maps to the **current** config filename — never write a config under a legacy
name:

| Legacy generated dir (migrate source) | Pre-rename config (update-mode source) | Current config file |
| --- | --- | --- |
| `.claude/skills/plate-it/` | `.claude/sassy-dog/plate-it.md` | `survey-work.md` |
| `.claude/skills/fill-it/` | `.claude/sassy-dog/groom-it.md` | `groom-backlog.md` |
| `.claude/skills/drain-it/` | `.claude/sassy-dog/drain-it.md` | `dispatch-ready.md` |
| `.claude/skills/clean-it/` | `.claude/sassy-dog/clean-it.md` | `tidy-repo.md` |
| `.claude/skills/take-it/` | — (name unchanged) | `take-it.md` |
| `.claude/skills/send-it/` | — (name unchanged) | `send-it.md` |

A middle-vintage repo (config era, pre-rename) is update mode's case, not migrate mode's: the
rename step in `update-mode.md` performs the `git mv`, prose carried verbatim. A repo with no
legacy artifact for a skill gets no config file for it, which is correct — the generic skills run
fine on `NO_CONFIG` (dispatch-ready and take-it stop, by design).

Mention every rename in the preview. `/plate-it`, `/fill-it`, `/drain-it`, and `/clean-it` will
stop appearing as such, and that surprises people — the legacy trigger *phrases* still resolve to
the renamed skills.

## Step 4 — `.claude/settings.json`

Merge, never overwrite. `setup-hooks` may already own a hooks entry in the same file.
Whether this file is **committed** is a per-repo choice (`SKILL.md` Phase 7 step 2): a public repo
should track only `.claude/sassy-dog/*.md` and keep `settings.json` local, in which case write the
entries locally and do not stage the file.

**In migrate mode the file is usually already tracked, and that is the common case.** The
untracking commands, the ignore-line predicate, the collaborator-deletion warning with its restore
command, and the already-tracked `.claude/hooks/` handling are all owned by `SKILL.md`, "Tracking
choice in the plan". Put each of them in the Step 5 preview; an unstaged edit to a tracked file
stays tracked and dirties the tree, so nothing here substitutes for them. Private and internal repos
skip this and keep the committed file.

```json
{
  "extraKnownMarketplaces": {
    "skills": {
      "source": {
        "source": "github",
        "repo": "Sassy-Dog/skills"
      }
    }
  },
  "enabledPlugins": {
    "sassy-dog@skills": true
  }
}
```

Preserve every existing key; add only the `extraKnownMarketplaces` and `enabledPlugins` entries. If
the file already declares both, leave it alone. A file that declares only `enabledPlugins` is the
pre-#97 state — add the missing `extraKnownMarketplaces` entry.

**What this does and does not buy:** it makes the plugin resolvable for local sessions on any
machine that opens the repo, and `enabledPlugins` alone is not enough there: it names the
marketplace, but registration otherwise lives in user-level state
(`~/.claude/plugins/known_marketplaces.json`), so `extraKnownMarketplaces` is what lets the session
resolve `@skills`. It does **not** reach cloud sessions or scheduled routines: those load neither
user-scope nor repo-declared plugins (Claude Code docs, plugins/install "Cloud session" and
cloud-environments "What carries over"), and a routine cannot load a plugin skill at all (#175).

## Step 5 — preview

Show, before any write or delete:

1. Each `.claude/sassy-dog/*.md` in full
2. Every fact that **changed** during re-verification, old → new, with how it was checked
3. Every fact that could **not** be verified
4. The exact list of directories to be deleted, each with its `generated-by:` marker quoted
5. Any `.claude/skills/` directory being **kept** because it has no marker
6. In a public repo, the tracking choice exactly as `SKILL.md` "Tracking choice in the plan" lists
   it: the derived end state and the transition to the chosen target (untracking commands,
   collaborator-deletion warning and restore command, the `.gitignore` lines), and other tracked
   `.claude/` paths (Step 4)

Then write config, verify it, and delete only on explicit approval.

## Step 6 — what must not be touched

Skills without a `generated-by:` marker are hand-written and not yours. Known cases:

- `qr-ninja/.claude/skills/qr-ninja-design/`
- `what2wear/.claude/skills/what2wear-clean-it/` (legacy prefixed, adopt-mode candidate)
- `velovate/velovate-app/.claude/skills/terraform-apply/`

Check for a marker per directory. Never infer from the name.

## Consumer repos

Ten, and a one-level `*/` glob under the portfolio root **misses two** — velovate and devcanopy
nest their app one directory deeper. Scan at depth 4:

```bash
find ~/Repos/sassy-dog -maxdepth 4 -type d -path '*/.claude/skills'
```

francisco, mission-control, platform, qr-ninja, quickshot, sassydog-web, tailoredtip, what2wear,
`velovate/velovate-app`, `devcanopy/devcanopy`. `lupita/lupita` is excluded — legacy prefixed
skills, no markers, and the product is being sunset.

## `execution_site` on a migration — ask §3d, once

A legacy generated skill has no way to express an execution site, so **extraction can never produce
one** and every migrated config would otherwise arrive with `execution_site` absent — the same shape
as Step 2b's three keys, for the same reason. So put **interview §3d** to the user here, as part of
this mode: it is the one offer this repo gets, because a refresh deliberately never repeats it
(`update-mode.md`).

Two things not to shortcut. **The platform proposes; the user names.** Take the proposal from
`references/config-contract.md`'s `uname -s` table, never from a language runtime's platform
constant, and never write a name the user did not say — a declined question leaves the key absent,
which is a legitimate answer and the one every repo already has. And a migration **never carries a
name across from anywhere else**: there is nothing in a legacy skill to carry, and a sibling repo's
config is a different clone on a possibly different machine.

This rule is stated here as well as in `update-mode.md` because migrate mode reads this file, and a
rule stated only there is a rule this path never reads.
