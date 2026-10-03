# Harness portability

An inventory of the Claude-Code-specific mechanisms in `skills/` and `agents/`, what omp offers in
their place, and the options for the shape of a fix. This is an options document for issue #410.
**It decides nothing and implements nothing.** The shape decision belongs to the operator, and
implementation issues follow from it.

[`MODEL-TIERS.md`](MODEL-TIERS.md) made *model choice* portable. This document covers the rest of
the dispatch mechanics, the ones that file's "What a tier does not cover" section names.

## How to read the counts

Every count is the number of **tracked files** matching the command beside it, under `skills/` and
`agents/` only. It is a file count, not a site count: a file that uses a mechanism five times counts
once. The counts are a snapshot of the tree on 2026-10-03. Nothing gates them, so they go stale as
the tree moves. Re-run the command rather than trusting the number. omp is quoted only from its
documentation at `https://omp.sh/docs/...`. Where that documentation is silent, the entry says
**unknown, not documented**. That is a different statement from "omp cannot do it". The omp pages
were read through a summarizing fetcher, so "not documented" means "not found in the summary".

## Inventory

| # | Mechanism | Files | Reproducing command |
| --- | --- | --- | --- |
| 1 | Agent tool dispatch (every site that binds a tier) | 7 | ``git grep -l -F 'tier `' -- skills agents`` |
| 2 | `subagent_type` plugin-namespaced agent names | 2 | `git grep -l 'subagent_type' -- skills agents` |
| 3 | `isolation: "worktree"` | 4 | `git grep -l 'isolation: "worktree"' -- skills agents` |
| 4 | Skill delegation by namespaced name (`Skill: sassy-dog:<name>`, "invoke `sassy-dog:<name>`", "delegate to `sassy-dog:<name>`") | 10 | `git grep -l -E -e 'Skill: sassy-dog:' -e '[Ii]nvoke .sassy-dog:' -e '[Dd]elegates? to .sassy-dog:' -- skills agents` |
| 5 | `${CLAUDE_PLUGIN_ROOT}` | 22 | `git grep -l CLAUDE_PLUGIN_ROOT -- skills agents` |
| 6 | `` !`...` `` dynamic context injection | 9 | ``git grep -l -E '^!`' -- skills agents`` |
| 7 | Per-repo config under `.claude/sassy-dog/` | 22 | `git grep -l '\.claude/sassy-dog' -- skills agents` |
| 8 | Plugin and marketplace declaration in `.claude/settings.json` | 5 | `git grep -l -e extraKnownMarketplaces -e enabledPlugins -- skills agents` |
| 9 | Claude Code settings and hooks generation | 9 settings, 5 hooks | `git grep -l '\.claude/settings' -- skills agents` and `git grep -l '\.claude/hooks' -- skills agents` |
| 10 | `AskUserQuestion` interview tool | 1 | `git grep -l AskUserQuestion -- skills agents` |
| 11 | `/loop` driver | 2 | `git grep -l '/loop' -- skills agents` |
| 12 | Agent frontmatter `color:` | 10 | `git grep -l '^color:' -- agents` |
| 13 | `claude plugin` CLI and install state | 8 | `git grep -l -e 'claude plugin' -e installed_plugins -- skills agents` |
| 14 | `mcp__...` tool-id literals | 6 | `git grep -l 'mcp__' -- skills agents` |
| 15 | `.claude/worktrees` path convention | 4 | `git grep -l '\.claude/worktrees' -- skills agents` |

Rows 1 to 6 are the five mechanisms named in the issue, with row 2 split out of the Agent tool row
because omp's answer differs. Rows 7 to 15 came from the search for mechanisms the issue did not
list. Row 14 is not a dependency: the six files only forbid hardcoding a tool id, and one shows a
hook matcher example, because tool ids are resolved by capability. It is listed so nobody re-searches
it. Skill frontmatter was checked as well, and it carries only `name` and `description`, with no
`allowed-tools`, `model` or `argument-hint` key. Agent frontmatter carries `name`, `description`
and, on ten agents, `color`.

`git grep -l SendMessage -- skills agents` also hits all nine reviewers and the orchestrator, but
only to say a report is returned and never sent, so it creates no dependency.

## Per-mechanism detail

Each entry gives what the plugin uses the mechanism for, then what omp documents.

### 1. Agent tool dispatch

**Used for.** Fan-out. `take-it` and `dispatch-ready` dispatch implementation workers and the review
agent, `send-it` dispatches the review agent, `assess-it` fans out reviewers,
`pr-review-orchestrator` fans out to the nine reviewers, and `whats-on-fire`'s cloud fallback runs
org-sweep subagents. The seven files are exactly the sites in `scripts/test-model-tiers.sh`'s
`required` table. The command keys on the inline tier binding, because the wording around a
dispatch varies (`Agent tool`, `Agent call`, `Agent(...)`, or none) and a grep for the tool name
misses `send-it` and `dispatch-ready`. The contract is "issue every call in a single message so they run
concurrently", with a tier bound inline at each site.

**omp.** `task` is the dispatch tool: "Fan independent work out to specialist subagents,
optionally in isolated workspaces, and collect their results" (`https://omp.sh/docs/tools`).
Concurrency is `task.maxConcurrency` (default 32) and nesting is capped by `task.maxRecursionDepth`
(default 2) (`https://omp.sh/docs/subagents`). Results are "delivered back into the main
conversation" (same page). The parameters `task` itself takes, and whether one message can carry
several calls: **unknown, not documented**. The subagents page describes delegation in natural
language ("Use the scout to map...") and names no call syntax.

**Fit.** Partial. The concept exists. The single-message-batch wording and the `Agent(...)` call
shape in `agents/pr-review-orchestrator.md` have no documented omp counterpart. Nesting depth is a
concrete conflict with omp's default `task.maxRecursionDepth` of 2. At the default
`review_site: coordinator` the chain is coordinator, `pr-review-orchestrator`, reviewer: two nested
hops, so the default **sits at** the cap. Under `review_site: agent` the worker dispatches the
orchestrator itself (`skills/take-it/SKILL.md`), giving coordinator, worker, orchestrator, reviewer:
three nested hops, which **exceeds** the cap. Whether the cap counts hops or levels is **unknown,
not documented**, so even the default may fail. The setting is configurable, but raising it is a
consumer-side change this plugin cannot ship.

### 2. `subagent_type` and plugin-namespaced agent names

**Used for.** Selecting a shipped reviewer by its namespaced name, `sassy-dog:<name>`, from the
orchestrator and from `assess-it`.

**omp.** Agents are Markdown files with YAML frontmatter in `.omp/agents/` (project) or
`~/.omp/agent/agents/` (user), and the discovery list includes "OMP extensions and Claude
marketplace plugins" (`https://omp.sh/docs/subagent-authoring`). Documented frontmatter keys on that
page: `name`, `description`, `tools`, `model`, `thinking-level`, `spawns`, `autoload-skills`,
`read-summarize`, `output`, `blocking`, `prewalk`, `advisor`. Invocation is by exact agent name in
natural language. Whether a plugin agent keeps a `sassy-dog:` namespace under omp: **unknown, not
documented**. Whether an unlisted key such as `color` is ignored or rejected: **unknown, not
documented**. `model` accepts a role alias such as `@slow`, but this repo keeps agent files
model-free and applies the tier at the dispatch site. Whether a dispatch can override an agent's
model per call: **unknown, not documented**. omp documents a settings override,
`task.agentModelOverrides.<agent-name>` (`https://omp.sh/docs/agents-and-roles`), which is per agent,
not per call.

### 3. `isolation: "worktree"`

**Used for.** Giving each parallel worker its own git worktree, so workers do not collide in one
checkout. `take-it` and `dispatch-ready` depend on it. The other two files (`repo-cleanup` and
`pr-shepherd`'s teardown reference) handle the cleanup of what it creates.

**omp.** Isolation is a setting, not a call parameter. `task.isolation.mode` is `auto` or a named
backend and defaults to "none". Related keys are `task.isolation.merge` (`patch` by default, or
`branches`), `task.isolation.apply` and `worktree.base` (default `~/.omp/wt`)
(`https://omp.sh/docs/subagents`). A prompt can also ask for it ("Use the migration-fixer subagent
in an isolated worktree..."), and that page says it "requires Git support and configured task
isolation" (`https://omp.sh/docs/subagent-authoring`). The strategy is "filesystem clone or overlay
selected for the platform", so it is not documented as a git worktree with a branch. This repo's
workers create a branch and open a PR from inside the isolated tree. Whether an omp isolated
workspace can do that, and whether `patch` merge is compatible with a worker that pushes its own
branch: **unknown, not documented**. This is the riskiest mechanism in the inventory. The default is
"none", so a misconfigured run would put parallel workers in one checkout.

### 4. Skill delegation by namespaced name

**Used for.** Workflow skills handing work to other skills by name. Ten files do it with one of
three phrasings: `send-it`, `take-it`, `setup-repo`, `tidy-repo`, `work-fire-watch` and
`work-recommendations` (`Skill: sassy-dog:<name>`), `dispatch-ready` and `groom-backlog`
("delegate to `sassy-dog:<name>`"), and `survey-work` and `whats-on-fire` ("invoke
`sassy-dog:<name>`"). The phrasing is open-ended, so the count is a floor. Other files name a
skill with other verbs ("via", "route to", "goes through"), which the command does not match. Across `skills/*/SKILL.md`, 19 of the 23 skills contain some
`sassy-dog:<name>` reference, which also catches self-references, so it is an upper bound and not
a delegation count (``git grep -l -E 'sassy-dog:[a-z-]+' -- 'skills/*/SKILL.md'``).

**omp.** Skills are `SKILL.md` files with `description` and optional `name` frontmatter, discovered
under `.claude/skills/` among other paths, and invoked as `/skill:<name>` or by description match
(`https://omp.sh/docs/skills`). Whether a skill body can invoke another skill, and how plugin
skills are namespaced: **unknown, not documented**. Plugins list `skills/` as a conventional
directory (`https://omp.sh/docs/plugins`).

### 5. `${CLAUDE_PLUGIN_ROOT}`

**Used for.** Resolving the absolute path of the plugin's bundled scripts and reference docs. It
expands only in `SKILL.md`, at load time. 15 `SKILL.md` files carry it
(``git grep -l CLAUDE_PLUGIN_ROOT -- 'skills/*/SKILL.md'``), and 7 reference docs mention it through
their `PLUGIN_ROOT` preamble (``git grep -l CLAUDE_PLUGIN_ROOT -- 'skills/*/references/*.md'``).

**omp.** None found. The plugins page documents no path variable or environment variable for a
plugin's install directory (`https://omp.sh/docs/plugins`), and the skills page documents no
plugin-root variable (`https://omp.sh/docs/skills`). The environment variable reference
(`https://omp.sh/docs/env`) was not read for this document. Read it before concluding there is no
equivalent.

### 6. `` !`...` `` dynamic context injection

**Used for.** Inlining each repo's `.claude/sassy-dog/<skill>.md` into the skill at load time. The
injected text also carries a `NO_CONFIG` sentinel and a `CONFIG_SOURCE` line. Without it a skill
sees no config and takes its conservative path, or blocks, as `take-it` and `dispatch-ready` do.

**omp.** None found. The skills page documents no argument substitution and no shell injection
syntax, and the context-files page finds no evidence of shell execution at load time
(`https://omp.sh/docs/skills`, `https://omp.sh/docs/context-files`). omp does have an `@path`
include token in context files, resolved relative to the including file, up to five hops
(`https://omp.sh/docs/context-files`). That inlines a fixed file, not a path computed from
`git rev-parse --show-toplevel`, and it is documented for context files, not skills. Whether it
works inside a `SKILL.md`: **unknown, not documented**.

### 7. Per-repo config under `.claude/sassy-dog/`

**Used for.** The per-repo behaviour of every workflow skill. This is the data half of row 6.

**omp.** Not an omp concept. omp reads `.claude/CLAUDE.md` as a compatible context file
(`https://omp.sh/docs/context-files`) and finds skills under `.claude/skills/`
(`https://omp.sh/docs/skills`), but nothing documented reads `.claude/sassy-dog/`. The files are
plain Markdown, so any harness that can read a file can read them. The gap is how the content
reaches the skill (row 6), not the format.

### 8. Plugin and marketplace declaration in `.claude/settings.json`

**Used for.** `setup-config` and `setup-repo` write `extraKnownMarketplaces` and `enabledPlugins`
into a consumer repo, so a cloud session or routine loads the plugin. `repo-health`'s `SKILL.md`
reads both keys for its plugin-drift guidance. Of the five files, four are the writers' own
skill and reference docs and one is that reader.

**omp.** A different mechanism. omp installs with `omp plugin install name@marketplace --scope
project` or `/marketplace install ...`, and no documented command references `.claude/settings.json`
or `enabledPlugins` (`https://omp.sh/docs/marketplace`). omp plugins use a `package.json` manifest
with an `omp` field. A marketplace catalog may be `.omp-plugin/marketplace.json` or fall back to the
Claude-compatible `.claude-plugin/marketplace.json` (`https://omp.sh/docs/plugins`,
`https://omp.sh/docs/marketplace`). Whether a `.claude-plugin/plugin.json` plugin installs as is:
**unknown, not documented**. The fallback is documented for catalogs only.

### 9. Claude Code settings and hooks generation

**Used for.** `setup-hooks` renders a PostToolUse dispatcher, a stray-artifact guard and a `Stop`
entry into `.claude/hooks/` plus `.claude/settings.json`. It is Claude-Code-specific by purpose.

**omp.** omp has hooks (`https://omp.sh/docs/hooks`). That page was not read, so event names, config
location and whether the Claude shape is accepted are **unknown, not documented** here.

### 10. `AskUserQuestion`

**Used for.** `setup-config`'s interview, in one reference doc.

**omp.** `ask`: "Let omp pause for a choice, confirmation, or missing detail when it cannot safely
derive the answer" (`https://omp.sh/docs/tools`). Batching several questions into one call:
**unknown, not documented**.

### 11. `/loop`

**Used for.** `dispatch-ready` is designed to run as `/loop 5m /dispatch-ready`, each tick idempotent
and with no memory of the previous one. `verify-issue-refs.sh` also names it.

**omp.** None found in the pages read. The slash-command page (`https://omp.sh/docs/slash`) was not
read, so omp may have an interval driver: **unknown, not documented**. The skill is already
tick-idempotent, so any external scheduler that re-invokes it would work.

### 12. Agent frontmatter `color:`

Cosmetic, on ten agents. omp's documented key list (row 2) does not include it. Behaviour on an
unknown key: **unknown, not documented**.

### 13. `claude plugin` CLI and install state

**Used for.** Two things. Five workflow skills (`send-it`, `take-it`, `tidy-repo`, `work-fire-watch`,
`work-recommendations`) tell a degraded session to run `claude plugin install sassy-dog`, and
`setup-config`'s contract and `repo-health`'s drift guidance cite `claude plugin update`. `repo-health`'s plugin-drift check reads `claude plugin` output
and `~/.claude/plugins/installed_plugins.json`.

**omp.** The install command differs: `omp plugin install name@marketplace`
(`https://omp.sh/docs/marketplace`). The drift diagnostic covers a Claude Code cache failure mode
and has no omp analogue in the pages read.

### 14. `mcp__...` tool-id literals

Not a dependency, as noted under the table. No omp equivalent is needed.

### 15. `.claude/worktrees` path

**Used for.** Worktree location in teardown and cleanup (`pr-shepherd`'s `teardown.sh` and
`worktree-teardown.md`, `repo-cleanup`'s `SKILL.md`), and path classification in
`repo-health/scripts/pull-plugin-drift.sh`, which tests `"/.claude/worktrees/" in path` to
recognise worktree paths when checking plugin drift. Claude Code creates agent worktrees there.
omp defaults to `~/.omp/wt` (`worktree.base`, `https://omp.sh/docs/subagents`), so teardown and
cleanup would not find omp's worktrees at the Claude path, and the drift check would misclassify
them as ordinary paths.

## What does not need a port

`gh`, `git`, `jq`, Bash scripts and Markdown references carry most of the repo's logic and are
harness-neutral. Skill frontmatter is only `name` and `description`, and omp documents both
(`https://omp.sh/docs/skills`). omp also finds skills in `.claude/skills/` and loads
`.claude/CLAUDE.md` (`https://omp.sh/docs/skills`, `https://omp.sh/docs/context-files`).

## Options for the shape

### A. A per-harness binding table, like `MODEL-TIERS.md`

One doc maps each mechanism to a per-harness spelling. Sites keep neutral wording, and a gate checks
them against the table.

- **For:** one place to edit per harness. Adding a harness is a column.
- **Against:** a cold sub-agent or `/loop` tick acts on the text in front of it and never opens the
  table, which is the conclusion `MODEL-TIERS.md` itself reaches. A table fits a one-word value such
  as a model. It fits badly for a procedure such as worktree isolation, where the semantics differ
  and not just the name.

### B. Harness-neutral wording with inline bindings at each site (the #405 pattern)

Each site names the intent and carries a per-harness binding inline, validated by a gate.

- **For:** works for a cold reader, and is a pattern the repo already gates.
- **Against:** it scales with sites. Row 5 alone is 22 files. The mechanisms with no omp equivalent
  (rows 5 and 6) cannot be bound inline at all, because there is nothing to write in the omp slot.

### C. Declare some skills Claude-Code-only

State a support matrix per skill, and port only what is cheap.

- **For:** honest and cheap. The capability skills that are scripts plus Markdown depend mainly on
  row 5, the plugin root.
- **Against:** the dispatch family (`take-it`, `dispatch-ready`, `assess-it`, `send-it` and the
  review gate) is where parallel agents, isolation and delegation concentrate, and it is the part a
  second harness most wants. Declaring it Claude-only gives up the goal for the highest-value skills.

### D. A hybrid, staged by evidence

Resolve the two mechanisms that block everything first, then decide per family.

1. Rows 5 and 6 (plugin root, config injection) gate every skill, and omp documents neither.
2. Row 3 (isolation) gates the parallel-worker skills, and the risk is a silent no-op.
3. Rows 1 and 2 are lower risk. omp documents a dispatch tool and an agent format, and the
   remaining questions are about call shape.
4. Row 4 is medium risk, not low. omp documents `/skill:<name>` invocation but nothing about a skill
   body invoking another skill or about plugin namespacing, and ten files, `dispatch-ready` among
   them, depend on it. If the namespaced name does not resolve, every workflow skill loses its
   capability skills. The spike should test it early.

## Recommendation

Option **D**, with **C** as the stance in the meantime: until a spike shows rows 5 and 6 can be met
on omp, say in the README that only the harness-neutral capability scripts are expected to run
there. Do not start with A or B. Both are mechanical rewrites across the rows 1 to 6 files, and for
rows 5 and 6 they have nothing to bind to.

The cheapest next step is a spike on a real omp install, not more reading. It would answer, in
order: whether the plugin installs, whether a script path can be resolved from inside a skill,
whether a repo config can be injected, whether `task` isolation yields a branch a worker can push,
and what a `task` call looks like. The gaps those questions cover are all of that kind. The pages under `## Not read` are a separate, reading-only gap that a spike does not close.

Candidate follow-up issues, for the operator to accept or drop:

1. Spike: install the plugin on omp and record the answers to the questions above.
2. Plugin-root and config-injection replacement, if the spike finds none.
3. Isolation contract for parallel workers on omp.
4. A README support matrix per skill family.

## Not read

These omp pages were not read, and any claim they would settle is marked unknown above:
`https://omp.sh/docs/env`, `https://omp.sh/docs/hooks`, `https://omp.sh/docs/slash`,
`https://omp.sh/docs/custom-tools`.
