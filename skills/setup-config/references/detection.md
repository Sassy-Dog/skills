# Phase 1 — capability detection

Run the bundled probe from the target repo's root:

> **Path resolution.** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at load time only — **not** into this file (reference docs are read raw), and it is **not** an environment variable in the shell. Before running anything below, set `PLUGIN_ROOT` to the plugin root's absolute path: `setup-config`'s `SKILL.md` carries no plugin-root command line and no **Plugin root.** paragraph, so derive it from this skill's own location. On Claude Code, take the announced `Base directory for this skill` and cut it at `/skills/setup-config`. On omp, take the `[Skill file: ...]` header printed when this doc is read (via `read skill://setup-config/references/detection.md`), or the `[Skill directory: ...]` line, and cut it at `/skills/setup-config`. What comes before the cut is the plugin root. Do not search for it. Every command below quotes `"$PLUGIN_ROOT/..."`, so an unset value fails loudly with a 127 rather than resolving against `/`.

```bash
bash "$PLUGIN_ROOT/skills/setup-config/scripts/detect-capabilities.sh"
```

It emits one JSON object; every probe degrades to `null`/`[]` plus an entry in `detect_failures` rather than aborting. Treat the output as *evidence to confirm*, not truth — the interview validates anything consequential.

## Output fields → template inputs

| JSON field | Feeds | Notes |
|---|---|---|
| `repo`, `default_branch` | `{{REPO_SLUG}}`, `{{DEFAULT_BRANCH}}`, `{{ORG}}` | |
| `repo_settings` | merge policy | `autoMergeAllowed`, `deleteBranchOnMerge`, `squashMergeAllowed` |
| `merge_queue` | `IF:MERGE_QUEUE` | **Best-effort** — GraphQL scopes often block it. `null` → MUST confirm in interview. A wrong merge policy is the most expensive mistake the generator can make (the `--auto` method-flag trap silently never-merges). |
| `pr_template.path/.sections` | `{{PR_TEMPLATE_PATH}}`, `{{PR_TEMPLATE_SECTION_CHECKLIST}}` | Sections become the §4 checklist, one `- [ ]` line each |
| `workflows`, `ci_workflow_guess` | `{{CI_WORKFLOW}}` | Confirm the guess if multiple workflows exist |
| `project_boards` | `IF:BOARD`, `{{BOARD_NUMBER}}` | Numbers/titles only. If a board is selected, discover its IDs at generation time per `github-issues/references/board-graphql.md` (`gh project field-list`) and pin them as `{{BOARD_PROJECT_ID}}`, `{{BOARD_STATUS_FIELD_ID}}`, option IDs. **An existing-but-empty board may mean the backlog is label-driven** — ask, don't assume (sets `{{BACKLOG_SOURCE_DESCRIPTION}}`/`{{BACKLOG_SOURCE_NOTE}}`). |
| `labels` | `{{PRIORITY_LABELS}}` | Detect a `P0..P3`-style taxonomy if present |
| `migrations.kind/.dirs` | `IF:MIGRATIONS`, `{{MIGRATION_DIRS}}`, `{{SCHEMA_DIR}}` | The regen command (`{{MIGRATION_REGEN_COMMAND}}`) is interview-confirmed — detection can't know `./dev db-generate` vs `bunx drizzle-kit generate` |
| `codegen` | `IF:CODEGEN`, `{{CODEGEN_COMMAND}}`, `{{CODEGEN_OUTPUT_DIRS}}` | Hint only; confirm the actual command |
| `monorepo` | `{{STACK_SUMMARY}}`, `{{PREFLIGHT_COMMANDS}}`, tidy-repo `{{DEP_VERSION_GLOBS}}`/`{{NOISE_ALLOWLIST}}` | Preflight derives from runner + scripts: e.g. bun → `bun run lint && bun run type-check && bun run --filter <pkg> test`; confirm in interview. **tidy-repo facts derive from `runner` + `migrations.dirs`** (no extra probe) — see the derivation table below |
| `repo_settings.deleteBranchOnMerge` | tidy-repo `{{DELETE_BRANCH_ON_MERGE}}` | Drives whether tidy-repo's stale-remote-branch step is a no-op |
| `sentry`, `posthog`, `testflight_bundle_id` | `IF:SENTRY`/`IF:POSTHOG`/`IF:TESTFLIGHT`, `{{BUNDLE_ID}}` | `sentry: true` means the SDK is initialized — it says nothing about *which* project. An MCP listing or the interview only proposes candidate slugs; each one must pass the culprit check in the hand-checks below before it is written, and an unverified candidate becomes `sentry: none` |
| `secret_manager` | `IF:SECRET_BOOTSTRAP`, `{{SECRET_BOOTSTRAP_CMD}}` | Hint only (`.envrc`/`doppler.yaml` presence). Non-interactive agent shells never fire direnv, so survey-work §1 must run the bootstrap itself, BEFORE its env presence probes — otherwise the ASC probe false-negatives `asc:missing` on loaded-lazily credentials. The exact command is interview-confirmed (detection can't know `eval "$(doppler secrets download --no-file --format env)"` vs a repo wrapper). |

## tidy-repo fact derivation (from existing fields — no extra probe)

tidy-repo is **core** (always rendered). Derive its facts from the JSON the script already emits:

| Template input | Derive from | Example |
|---|---|---|
| `{{DEP_VERSION_GLOBS}}` (files that block stash auto-drop) | `monorepo.runner` + `migrations.dirs` | bun/npm/pnpm → `package.json bun.lock bun.lockb`; flutter → `pubspec.yaml pubspec.lock *.podspec`; dotnet → `*.csproj`; **always append each `migrations.dirs` entry** |
| `{{NOISE_ALLOWLIST}}` (extra auto-discard, beyond the universal `.DS_Store`/`*.swp`/`tmp/` defaults baked into `repo-cleanup`) | `monorepo.runner` | bun/npm/pnpm → `**/node_modules/`; flutter → `**/.dart_tool/ **/build/`; dotnet → `**/bin/ **/obj/` |
| `{{DELETE_BRANCH_ON_MERGE}}` | `repo_settings.deleteBranchOnMerge` | `true`/`false` verbatim |
| `IF:CLAIM_LABEL` + `{{CLAIM_LABEL}}` | take-it selected **and** `labels` contains a `status:in-progress`-style claim label | only render when take-it is on AND such a label exists |

## Hand checks the script can't do

After the script, verify in the session (cheap, parallel):

- **tidy-repo never-discard list** (`{{NEVER_DISCARD}}`): gitignored-but-precious files the noise sweep must leave alone — scan `.gitignore` / repo docs for `.env.local`, local secret files, etc. Default `.env.local` if a web app; confirm in the interview (it's unconfirmable from the stack alone).
- **tidy-repo claim label** (`{{CLAIM_LABEL}}`): if take-it is selected, grep the existing/rendered take-it for the label it sets to claim an issue (commonly `status:in-progress`); only then render `IF:CLAIM_LABEL`.

- **Sentry project — verify by CULPRIT, never by name.** If `sentry: true`, an MCP project listing
  gives you *candidates*, not an answer. **Name similarity is not evidence.** A Sentry project and a
  GitHub repo can share a name and belong to different codebases — a marketing-site repo named
  `<product>-web` sitting beside a Sentry project `<product>-web` that actually receives events from
  a member-app frontend living in another repo. Verify before writing anything:

  1. List the org's projects (MCP) to get candidate slugs.
  2. For each candidate, sample its recent issues and read each one's `culprit`, plus the route,
     module, and file paths in the top stack frames.
  3. Confirm those paths **resolve in the repo being configured** — the file is tracked here, the
     route is served here, the symbol is defined here. Check with `git ls-files` / `rg` against this
     repo's tree; recollection is not a check.
  4. A project whose culprits match **no** path in this repo is the wrong project **regardless of
     what it is called**. Do not write it.

  **Verification failing writes `sentry: none`, never a guessed block.** Failing includes: no MCP
  server connected, no recent issues to sample, and culprits that do not resolve here. `sentry: none`
  is the confirmed-absent form — "no error-monitoring project is **verified** for this repo" — and it
  is a different claim from omitting the key, which means "never checked". **It is deliberately not
  the stronger claim.** Two of the three failure modes above are unfinished verifications, not
  absences, so `sentry: none` must never be glossed as "this repo has no error monitoring": nothing
  downstream can tell an absence from a check that could not run, which is also why its
  `survey-work` row survives while the three sibling `none` keys lose theirs. See
  `config-contract.md`, "Governing principle: presence is the toggle", for the three states and the
  asymmetry.

  The cost of guessing is invisible after the fact: the wrong repo claims another codebase's P0s,
  two repos double-report the same Sentry issues, `take-it` is dispatched against a repo holding no
  such route or symbol — and both plates still look complete, so nothing signals the error.

- **Sentry prior-claim scan — best-effort, SECONDARY, never blocking.** Once a candidate survives
  the culprit check, look for another repo that already declares it. Sibling checkouts under the
  same parent directory are the cheap place to look:

  ```bash
  grep -rl "candidate-slug" ../*/.claude/sassy-dog/survey-work.md 2>/dev/null
  ```

  A hit means another repo already claims that project. **Default to assuming it is already owned**
  — do not configure it here until the user confirms explicitly (interview question 2b).

  **This scan is secondary to the culprit check and must never be the only guard.** A cloud session
  has no sibling checkouts on disk, so it finds nothing there and says nothing about it; a miss is
  therefore never fatal and never blocks the run. The culprit check is the one that works
  everywhere — and it alone would have caught the case that motivated this rule, where zero of the
  erroring routes existed in the same-named repo.
- **Critical paths** for repo-health scoring (`{{SCAN_PATHS}}`, `{{EXCLUDE_PATHSPECS}}`): propose source dirs from the layout, excluding detected migration/generated dirs. `{{EXCLUDE_PATHSPECS}}` is a space-separated list of **bare paths** — never `:(exclude)`-prefixed. `pull-tech-debt.sh` adds that magic itself, and a prefixed value reaches git doubled, where it is a valid pathspec that matches nothing and silently excludes nothing ([#365](https://github.com/Sassy-Dog/skills/issues/365)).
- **Review orchestrator**: `ls .claude/agents/*review*` in the target repo → offers `IF:REVIEW_ORCHESTRATOR` + `{{REVIEW_ORCHESTRATOR_AGENT}}`. No local agent → **omit the key**, which is not "no review": `send-it`'s gate then dispatches the shipped `sassy-dog:pr-review-orchestrator`. Render `review_agent: skip` only when the user declines review outright.
- **Mobile release workflow**: if a workflow name matches `mobile|release.*ios|eas`, propose `{{RELEASE_WORKFLOW}}` + `{{MOBILE_PATH_PREFIX}}` (sets `IF:MOBILE`).
