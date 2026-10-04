# Harness portability

An inventory of the Claude-Code-specific mechanisms in `skills/` and `agents/`, what omp offers in
their place, and the options for the shape of a fix. This is an options document for issue #410,
extended with the results of the omp spike (issue #424, [Spike results](#spike-results-424)).
**It decides no shape option and implements nothing.** Its Recommendation and go/no-go paragraphs
are recommendations for the operator, who makes the shape decision, and implementation issues follow
from it.

[`MODEL-TIERS.md`](MODEL-TIERS.md) made *model choice* portable. This document covers the rest of
the dispatch mechanics, the ones that file's "What a tier does not cover" section names.

## How to read the counts

Every count is the number of **tracked files** matching the command beside it, under `skills/` and
`agents/` only. It is a file count, not a site count: a file that uses a mechanism five times counts
once. The counts are a snapshot of the tree on 2026-10-03. Nothing gates them, so they go stale as
the tree moves. Re-run the command rather than trusting the number. omp is quoted from its documentation at
`https://omp.sh/docs/...` and, since the spike, from what omp 18.5.1 (the spike) and 18.6.0 (the #440 checks) did when run. Where the
documentation is silent, the entry says **unknown, not documented**. That is a different statement
from "omp cannot do it". The omp pages were read through a summarizing fetcher, so "not documented"
means "not found in the summary". Evidence labelled **observed** was produced by running omp, 18.5.1 unless the entry says 18.6.0
(commands under [Spike results](#spike-results-424) and [Model-backed checks (#440)](#model-backed-checks-440)). Evidence labelled **source** was read from the
installed package's `src/` and was not run through a model; it is as good as that version and no
better.

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

## Spike results (#424)

Run on 2026-10-03 on site `mac` against `omp/18.5.1` (`omp --version` printed `omp/18.5.1`, binary
`~/.bun/bin/omp`). The operator's omp was not installed, upgraded or reconfigured by the spike.

**Isolation method.** omp had no `~/.omp` before the spike. Every omp command ran with
`OMP_PROFILE=spike424` (or `spike424b`), the documented profile selector
(`https://omp.sh/docs/env`), which keeps auth, settings, plugins and caches under
`~/.omp/profiles/<name>/`. Overriding `HOME` was not possible from the worktree sandbox, so the
profile directory lives outside the worktree. It was the only omp-written location: a search for
`~/.cache/omp`, `~/.config/omp`, `~/.local/share/omp` and `~/.local/state/omp` found nothing. The
spike removed `~/.omp` afterwards (it did not exist beforehand), so the operator has nothing to undo.
Scratch scripts and a throwaway repo were under the worktree's gitignored `tmp/`.
**The spike itself ran no model-backed omp command**: the profiles held no credentials, and everything below came
from `omp` subcommands that need no model (`plugin`, `read`, `config`) plus scripts that call omp's own
modules directly. That means no `task` call, `/skill:` invocation or `` !`...` `` load was driven
end to end by a model in #424. Each answer says which parts were run and which were read from source.
Those two claims (the `OMP_PROFILE` isolation and "no model-backed command") are scoped to #424. The
later #440 attempts used the default profile and did run model-backed calls, on `omp/18.6.0`; see
[Model-backed checks (#440)](#model-backed-checks-440).

### Q1. Does the plugin install as is? Yes (row 8)

```text
$ omp plugin marketplace add Sassy-Dog/skills
✔ Added marketplace: Sassy-Dog/skills
$ omp plugin install sassy-dog@skills
✔ Installed sassy-dog from skills (2026.10.5)
$ omp plugin list
Marketplace Plugins:
  sassy-dog@skills (2026.10.5) (user)
```

The marketplace was read from `.claude-plugin/marketplace.json` and the plugin from
`.claude-plugin/plugin.json`, with no `package.json` and no `omp` field. omp cloned the whole repo into
`~/.omp/profiles/spike424/plugins/cache/plugins/skills___sassy-dog___2026.10.5/`. The skill
loader then listed 23 skills: the `Available:` list that `omp read` printed for an unknown name holds
23 bare names, matching the count of `skills/` in the clone. The agent loader returned all 10 agents
(the `discoverAgents` listing under Q5). `omp plugin doctor` printed one warning, `package_manifest:
Not created yet`, which is benign. `omp plugin features sassy-dog` printed `Plugin "sassy-dog" not
found`, because that command looks at npm-style plugins only.

**`CLAUDE_CONFIG_DIR` import, observed.** A Claude-Code-format registry
(`<dir>/plugins/installed_plugins.json`, copied from the install above) under a temp
`CLAUDE_CONFIG_DIR` did **not** make the skill appear on its own: `omp read skill://take-it` printed
`Unknown skill: take-it` / `Available: none`. After `omp config set enabledProviders
'["claude-plugins"]'` it resolved. omp's source says why: a foreign provider's user-level config is
opt-in, and `CLAUDE_CONFIG_DIR` only switches on the `claude` provider, not `claude-plugins`
(**source**, `src/capability/index.ts` `isUserSourceEnabled`). `https://omp.sh/docs/env` says only
that the variable "Relocates imported Claude Code commands, plugins, MCP configuration, sessions, and
`.claude.json`", so the opt-in is a docs gap. Row 8's own mechanism does not carry over. `enabledPlugins`
in `.claude/settings.json` is read, but only as an on/off override for a plugin that some registry
already lists, and nothing reads `extraKnownMarketplaces` (**source**, `src/discovery/helpers.ts`
`readClaudeEnabledPlugins`, and a grep of `src/` for `extraKnownMarketplaces` with no hit). A consumer
repo that declares both keys therefore does **not** get the plugin installed on omp.

### Q2. Plugin root (row 5): equivalent found; a model recovered by searching (#440)

Observed, `omp read skill://pr-shepherd` (the `read` tool's own output for a skill):

```text
[Skill file: ~/.omp/profiles/spike424/plugins/cache/plugins/skills___sassy-dog___2026.10.5/skills/pr-shepherd/SKILL.md]
...
bash ${CLAUDE_PLUGIN_ROOT}/skills/pr-shepherd/scripts/poll-prs.sh --once "$PR"
```

The token is **not** substituted in a skill body. Two things resolve a path instead:

- `omp read skill://<name>/<path>` works and prints the absolute file path in its header
  (`omp read skill://pr-shepherd/scripts/teardown.sh` printed `[Skill file: .../skills/pr-shepherd/scripts/teardown.sh]`).
- A `/skill:<name>` invocation appends `[Skill directory: <absolute path>]` and tells the model to
  resolve relative paths against it. Observed by calling omp's `buildSkillPromptMessage` directly for
  `pr-shepherd`: the message ended `[Skill directory: .../skills/pr-shepherd]`, and the body still held the
  literal token (`literal token kept: true`). A hidden autoloaded skill gets the file path instead
  (**source**, `src/extensibility/skills.ts`, `src/prompts/skills/*.md`).

So the plugin root is the skill directory's grandparent (`<root>/skills/<name>`), and a model could
derive it from the `[Skill directory: ...]` line (18.5.1, called directly); the one #440 run recovered by searching
instead. It is not a mechanical substitution, so the 22 files that write the token still need a
sentence that tells the model how to resolve it. omp does substitute `${CLAUDE_PLUGIN_ROOT}` and
`${OMP_PLUGIN_ROOT}`, but only inside a plugin's MCP server config and the env omp passes to plugin
processes (**source**, `src/discovery/substitute-plugin-root.ts`, used from `claude-plugins.ts` and
`omp-plugins.ts`). `https://omp.sh/docs/env` and `https://omp.sh/docs/plugins` document neither.
Check A of #440 then ran a model against it (`omp/18.6.0`, see
[Check A](#check-a-row-5-the-model-does-not-derive-the-plugin-root-it-recovers-by-searching)): in one traced
run with one model, with this repo's `CLAUDE.md` in context (see the #440 Setup caveat), the agent
ran the literal token first, failed with exit 127, found the script with `find` and ran it. It did
not derive the grandparent. Print mode also did not expand `/skill:`, so the `[Skill directory: ...]` line above
was not seen under a model. Whether a sentence naming the rule makes the first command succeed is **unknown**.

### Q3. Config injection (row 6): none

The same `omp read skill://take-it` output printed the `` !`...` `` line verbatim
(`` !`root="$(git rev-parse --show-toplevel ...` ``). `buildSkillPromptMessage` reads the file,
strips frontmatter and renders the body into a template with no substitution or shell step
(**source**, `src/extensibility/skills.ts`). User arguments are appended as `User: <args>`, so
there is no positional or `$ARGUMENTS` expansion either (`https://omp.sh/docs/slash` documents none).
The `@path` include token is documented for context files only (`https://omp.sh/docs/context-files`)
and was not tried inside a skill. The skill therefore sees an unexecuted command, not the config
and not `NO_CONFIG`. Check B of #440 (`omp/18.6.0`, see [Check B](#check-b-row-6-the-model-follows-an-explicit-read-the-config-instruction))
then showed that an agent told to read `.claude/sassy-dog/<skill>.md` by absolute path did so and acted
on the value, in one run with one model, **with this repo's `CLAUDE.md` in context**, which documents that
mechanism. That is not evidence about a consumer repo. That instruction was not combined with the `` !`...` `` line, so
"every skill degrades to its `NO_CONFIG` path" is still the safe reading for a skill left unchanged. `take-it`
and `dispatch-ready` would block on it.

### Q4. Isolation (row 3): equivalent found, with a default that disables it

The settings in 18.5.1 (`omp config list`): `task.isolation.enabled = false`,
`task.isolation.apply = true`, `task.isolation.merge = patch (patch|branch)`,
`task.isolation.commits = generic`, `isolation.backend = auto`, `worktree.clone = true`.
`https://omp.sh/docs/subagents` still documents the legacy key `task.isolation.mode` (default
`none`). 18.5.1 migrates that key on load: any value other than `none` becomes
`task.isolation.enabled: true`, with the backend split out into `isolation.backend` (**source**,
`src/config/settings.ts`, the "Split the legacy combined isolation setting" block). The page's merge
values (`patch` rather than branches) match the installed `patch|branch` enum
(`cfgTaskIsolationMerge` in `src/task/settings.ts`). The only divergence is therefore the legacy
`mode` spelling, and a config that sets it still works.

Observed, by driving omp's own isolation functions (`ensureIsolation`, `captureIsolationBaseline`,
`commitToBranch`, `cleanupIsolation` from `src/task/worktree.ts`) against a scratch repo with a local
bare `origin`, with a worker's commands run inside the isolated directory:

```text
backend: 0 fellBack: false dir: ~/.omp/profiles/spike424/wt/t61e11e128/m
$ git rev-parse --git-dir --git-common-dir; git branch --show-current; git remote -v
.git
.git
main
origin  <abs path>/remote.git (fetch)   (and push)
$ git checkout -b feat/worker-branch && echo change >> f.txt && git add f.txt && git commit -qm 'worker commit'
362f80c worker commit
$ git push -u origin feat/worker-branch
 * [new branch]      feat/worker-branch -> feat/worker-branch
commitToBranch: {"branchName":"omp/task/spike424probe","baseSha":"88dc568..."}
```

- The isolated directory is a full checkout with its **own private `.git`** (`--git-dir` and
  `--git-common-dir` are both `.git`), not a linked `git worktree`. It keeps the parent's remotes.
  The worker created its own branch, committed, and **pushed it to `origin`**. A worker that opens its
  PR from inside the tree can therefore work, which is what `take-it` and `dispatch-ready` need.
- The parent repo does **not** receive the worker's branch name. After the run it had
  `omp/task/<task-id>` (a branch omp writes from the worker's commits) and no `feat/worker-branch`.
  `remotes/origin/` held the pushed branch. The source says omp deliberately detaches the isolation's
  git metadata so a worker cannot move the parent's HEAD, index or refs (**source**,
  `src/task/worktree.ts`, `ensureIsolation`).
- The isolation lives under `<profile>/wt/` (`~/.omp/wt` with no profile, matching `worktree.base`) and
  `cleanupIsolation` removes it, so there is no `.claude/worktrees` path for row 15's teardown to find
  and no long-lived tree to tear down.
- `task.isolation.enabled` defaults to **false**. With it off, parallel workers share one checkout,
  silently. Nothing in a skill can set it.

The model-driven `task` call with `isolated: true`, and how `apply = true` with `merge = patch` or
`merge = branch` treat a worker that pushed its own branch, are answered by check C of #440 on `omp/18.6.0`
(see [Check C](#check-c-row-3-apply-patches-the-parent-mergebranch-replays-the-commit-onto-it)): patch mode
modifies the parent checkout in place, and `merge=branch` commits the worker's change onto the parent's
current branch as a different commit from the pushed one. The 18.5.1 transcript above is unchanged.

### Q5. Dispatch and delegation (rows 1, 2, 4)

**Agents (row 2), observed.** Calling omp's `discoverAgents` with the plugin installed returned all ten
plugin agents under their **bare** frontmatter names (`pr-review-orchestrator`, `security-reviewer`,
and so on), source `user`, `model`, `tools` and `spawns` all undefined. Lookup by `sassy-dog:pr-review-orchestrator`
returned nothing, by `pr-review-orchestrator` returned the agent. omp also bundles `scout`,
`reviewer`, `task`, `sonic` and its own **`security-reviewer`** (**source**, `src/task/agents.ts`,
`src/prompts/agents/security-reviewer.md`). That one collides with this plugin's `security-reviewer`.
`discoverAgents` loads plugin agents first and drops later same-name agents (the `seen` filter in
`src/task/discovery.ts`), so the plugin's agent silently shadows omp's under the bare name, which is why
the bundled list printed by the discovery call did not include it. A bare name is first-come, so the
follow-up for bare agent and skill names must treat a collision as a hazard in both directions: a
plugin agent can hide a bundled one, and a user or project agent of the same name hides the plugin's. `color:` is not a recognised key and is dropped without error: the
agent loaded (**source**, `parseAgentFields` in `src/discovery/helpers.ts`, requires only `name` and
`description`). A Claude marketplace plugin's `model` is ignored by design (`ignoreModel`), which fits
this repo's model-free agent files.

**`task` call shape (row 1), source.** `src/task/types.ts` defines the parameters: `agent` (a name,
default `task`), `task` (the prompt), `solutionSpace`, and optional `name`, `model` (string or array,
**per call**), `outputSchema`, `schemaMode`, `tools` and, when isolation is on, `isolated`. With
`task.batch` true (the default) the call is instead `{context, tasks: [...]}`, one call carrying an
array of those items, with no top-level `model`. That batch call is the omp counterpart of "issue
every call in a single message so they run concurrently". It also answers the per-call model question
the earlier sections marked unknown: a per-call model exists, per item.

**Depth (row 1), source.** `canSpawnAtDepth(max, depth)` is `depth < max`, and an agent whose children
would sit at depth `max` loses its `task` tool (`src/task/types.ts`, `src/task/executor.ts`). With the
default 2 and the main session at depth 0: coordinator (0) dispatches `pr-review-orchestrator` (1),
which dispatches the reviewers (2). That chain **works**, and the reviewers need no `task` tool. Under
`review_site: agent` the worker is at 1 and the orchestrator at 2, so the orchestrator has **no
`task` tool** and cannot dispatch reviewers. Correction to row 1's earlier "sits at the cap, may
fail": the default fits exactly and `agent` fails. `task.maxRecursionDepth` set to 3 or -1 fixes the
second, and the plugin cannot ship that setting.

**Delegation (row 4), observed.** omp has no `Skill` tool. A model loads another skill by reading it,
`skill://<name>`. `omp read skill://take-it` resolved. `skill://sassy-dog:take-it` printed `Unknown
skill: sassy-dog:take-it`, and `skill://sassy-dog/take-it` printed `Unknown skill: sassy-dog`, both with
the list of bare names (`assess-it, dispatch-ready, github-issues, ...`). The `<namespace>/<name>`
form exists, but only when a bare name is already taken by another skill (**source**,
`skillNamespace` and collision handling in `src/extensibility/skills.ts`). `/skill:<name>` is the user
form (`https://omp.sh/docs/slash`). So `Skill: sassy-dog:<name>` as written does not resolve, a bare
`<name>` does, and a collision with another installed skill of the same name would change what the bare
name means. Whether a model follows "read `skill://<name>`" reliably: **unknown**.

### Model-backed checks (#440)

Issue #440 asked for three model-backed checks on site `mac` with the default omp profile: **A** (row 5,
a cold agent resolves the plugin root and runs a bundled script), **B** (row 6, a cold agent follows an
explicit "read `.claude/sassy-dog/<skill>.md` by absolute path" instruction instead of falling back to
`NO_CONFIG`) and **C** (row 3, two `task` calls with isolation on, one per merge mode, where the worker commits and pushes to a
local bare remote, then what `apply` and `merge` do to the parent checkout under the default and under
`merge=branch`). History: a first attempt on 2026-10-03 against `omp/18.5.1` could not run any of them
(no credentials, and the only model, the on-device `apple` one, has an 8,192-token window against omp's
19,579-token prompt). That attempt spent 1 call. A second attempt the same day, after the operator logged
the default profile in, ran all three. **A, B and C are each observed**, with the caveats stated per check.

**Setup.** `omp --version` printed `omp/18.6.0`, binary `~/.bun/bin/omp`. That is a newer build than the
`omp/18.5.1` that #424 and the first #440 attempt used, so Q1 to Q5 above remain 18.5.1 evidence unless a
paragraph here says otherwise. Every call used `--model anthropic/claude-haiku-4-5` (200K context, the
cheapest suitable model `omp models ls` listed), `-p --no-session --no-title --mode json` (the first
call of A omitted `--mode json`) and the default profile. This attempt made **5** model-backed calls
(A 2, B 1, C 2), so with the first attempt's 1 the issue's cap of 6 was reached and not exceeded. Scratch repos
lived under the worktree's gitignored `tmp/`, each with a local bare remote and no GitHub remote.
`omp plugin list` printed `No plugins installed` for the default profile and the attempt installed
nothing, so **A and B ran repo-local skills** (`.claude/skills/<name>/SKILL.md` in a scratch repo,
laid out like a plugin skill), not the shipped `sassy-dog` plugin. They are not a run of a real plugin skill.

**Caveat: this repo's `CLAUDE.md` was in context for A and B.** The scratch repos sit under this repo's worktree, and
omp 18.6.0 walks up from the cwd past a nested repository's own root, collecting context files up to but not including the
home directory: `loadStandaloneContextFiles` in `src/discovery/helpers.ts` ("continue past the Git root to discover
workspace-level files"), keeping one project-level file per depth (`src/capability/context-file.ts`, the `key` of
`contextFileCapability`). Read from that source, not observed in the model's prompt (the JSON event stream does not carry
the system prompt), the run therefore loaded this repo's `CLAUDE.md` (about 43.6 KB) from the worktree root and from the
main checkout above it. That file documents both mechanisms under test, `${CLAUDE_PLUGIN_ROOT}` with the `PLUGIN_ROOT`
preamble and `.claude/sassy-dog/<skill>.md` with `NO_CONFIG`, and names `~/Repos/sassy-dog/skills`, the directory Check A's
recovery `find` searched. PR #444's earlier wording hedged the same way ("including any `CLAUDE.md` it found walking up from the cwd"), without the source
citation. "Cold" in A and B therefore
means no skill-specific instruction beyond the skill text, not no knowledge of the mechanisms. A and B must be repeated from a
repository outside this tree before they say anything about a consumer repo.

### Check A (row 5): the model does not derive the plugin root, it recovers by searching

Skill `probe-root`, whose body is one command, `bash ${CLAUDE_PLUGIN_ROOT}/skills/probe-root/scripts/probe.sh`,
over a script that prints `PROBE-ROOT-OK nonce=7Q4Z`. Command (from inside the scratch repo):

```text
omp -p --no-session --model anthropic/claude-haiku-4-5 --no-title --max-time 5m --mode json "/skill:probe-root"
```

Call 1 (without `--mode json`) printed `PROBE-ROOT-OK nonce=7Q4Z` and nothing that shows how. Call 2
(`--mode json`) recorded the tool calls, in order:

```text
read   path=skill://probe-root
bash   bash ${CLAUDE_PLUGIN_ROOT}/skills/probe-root/scripts/probe.sh        -> No such file or directory, exit 127
bash   find ~/Repos/sassy-dog/skills -name probe.sh -type f 2>/dev/null
bash   bash <scratch>/tmp/a-repo/.claude/skills/probe-root/scripts/probe.sh -> PROBE-ROOT-OK nonce=7Q4Z
```

Observed, 18.6.0:

- The script **did run**, and the answer was correct, but the agent (with this repo's `CLAUDE.md` in context, see Setup) **ran the literal token first**
  and failed, then found the script with `find` over a parent directory. It did not take the skill
  directory's grandparent as the root. The path that worked was the skill directory itself, an absolute
  path under `.claude/skills/probe-root/`.
- In `-p` mode the message `/skill:probe-root` was **not expanded as a slash command**. The user turn held the
  literal text, and the model chose `read skill://probe-root` itself. The tool result header was
  `[Skill file: <scratch>/tmp/a-repo/.claude/skills/probe-root/SKILL.md]`. The string `Skill directory` appeared
  zero times in the run, so the `[Skill directory: ...]` line Q2 saw from `buildSkillPromptMessage`
  (18.5.1, called directly) was **not exercised** here. Print mode and the interactive `/skill:` form may differ,
  and only print mode was run.
- So the token is not substituted under a model either, and "a model can derive the root" is true only in the
  weak sense that it found the script by searching, at the cost of one failed command and a `find` that
  scales with the size of the tree it is pointed at. A sentence that names the resolution rule is still needed. Whether it
  would make the first command succeed is **not shown**: no variant with such a sentence was run.

### Check B (row 6): the model follows an explicit read-the-config instruction

Skill `probe-config`: "Read `.claude/sassy-dog/probe-config.md` by absolute path (resolve it against the
repository root, `git rev-parse --show-toplevel`). If the file does not exist, print `NO_CONFIG` and stop.
Otherwise print the value of its `marker:` key on a line starting `MARKER=`." The scratch repo held that file with
`marker: violet-walrus-93`.

```text
$ omp -p --no-session --model anthropic/claude-haiku-4-5 --no-title --max-time 5m --mode json "/skill:probe-config"
read   path=skill://probe-config
bash   git rev-parse --show-toplevel
bash   test -f "<repo root>/.claude/sassy-dog/probe-config.md" ...
read   path=<scratch>/tmp/b-repo/.claude/sassy-dog/probe-config.md
MARKER=violet-walrus-93
```

Observed: the agent **read the file by absolute path and acted on its value**, with this repo's `CLAUDE.md` in context (see Setup). It did not fall back to
`NO_CONFIG`. One call, one run, one model: it shows the instruction can work, not that it is reliable. The
`NO_CONFIG` branch (file absent) was not exercised, and neither was a skill that still carries the `` !`...` `` line
next to the instruction.

### Check C (row 3): `apply` patches the parent, `merge=branch` replays the commit onto it

Overlays under `tmp/` (never the default profile's `config.yml`), passed as `--config <file>`: one with
`task.isolation.enabled: true`, one adding `task.isolation.merge: branch`. `task.isolation.apply` stayed at its
default of `true`. Paths below are relative to the worktree root. Commands, as run by a wrapper script (`tmp/run-c.sh`) that
`cd`s into `tmp/c1-repo` or `tmp/c2-repo` first, so the overlays were passed as `../iso-patch.yml` and `../iso-branch.yml`, with
the prompt read from `tmp/c-prompt.txt` (its text differed between the two runs, as shown below):

```text
omp -p --no-session --model anthropic/claude-haiku-4-5 --no-title --max-time 8m --mode json --config ../iso-patch.yml  "<prompt>"   # C1, in tmp/c1-repo
omp -p --no-session --model anthropic/claude-haiku-4-5 --no-title --max-time 8m --mode json --config ../iso-branch.yml "<prompt>"   # C2, in tmp/c2-repo
```

The prompts, verbatim as run. C1: "Call the task tool exactly once, with isolated set to true. The worker's job: run 'git checkout
-b feat/worker-branch', append the line 'worker change' to f.txt, run 'git add f.txt && git commit -m worker-commit', then run 'git
push -u origin feat/worker-branch', and report the output of 'git log --oneline -3' and 'git branch --show-current'. After the task
returns, reply with only the word DONE." C2 is the same except that the report clause reads "and report the output of 'git log
--oneline -3' , 'git branch --show-current' and 'git ls-remote origin'." The prompt told the model to call `task` once with `isolated` true, with a worker that runs
`git checkout -b feat/worker-branch`, appends a line to `f.txt`, commits, pushes `-u origin feat/worker-branch`
and reports `git log`, `git branch --show-current` and (second run only) `git ls-remote origin`. The model's call
used the batch form (`tasks: [{name, agent: "task", task, solutionSpace, isolated: true}]`, plus `context`), spawned
the worker asynchronously, then called `wait`. Parent checkout before each run: `main` at `1f63b9f`, clean.

| Run | Setting | Remote | Worker reported | Parent checkout after |
| --- | --- | --- | --- | --- |
| C1 | default (`merge = patch`, `apply = true`) | relative `../c1-remote.git` | pushed, `57631f2 worker-commit` on `feat/worker-branch` | `main` still `1f63b9f`, `f.txt` **modified and uncommitted**, no new branch. Result text: `Applied patches: yes` |
| C2 | `merge: branch` | absolute path | pushed, `8fc8645 worker-commit` on `feat/worker-branch`; its own `ls-remote` listed `refs/heads/feat/worker-branch` | `main` moved to `37a7e63 worker-commit` (one parent, `1f63b9f`), tree clean, no new local branch. Result text: `Merged branch: omp/task/WorkerBranchTask` |

After C2 the bare remote held `refs/heads/feat/worker-branch` at `8fc8645` and the parent held the same change
as `37a7e63`, a **different commit** on `main`. The pushed branch and the parent's commit are two copies of one change.

- **Default (patch):** the parent checkout is patched in place, with no commit and no branch. A worker that has
  already pushed its own branch therefore leaves the parent dirty with the same change.
- **`merge=branch`:** omp merges the worker's commits into the parent's **current branch** (the result text names `omp/task/WorkerBranchTask`,
  but no new local branch remained afterwards), so the parent's `main` advanced by a commit that is not the pushed one. A coordinator that then pushes
  or merges the real branch would meet the change twice.
- **Caveat on C1.** The worker said it pushed, but the bare remote held only `main` afterwards. The scratch remote
  URL was relative (`../c1-remote.git`), which does not resolve from omp's isolated checkout outside the repo, so the
  push most likely failed or went elsewhere and the worker misreported it. C1's push claim is therefore **unverified**
  (the result text itself says "claimed artifacts unverified"), and C1 supports only the parent-checkout
  observation. C2 used an absolute remote and its push is confirmed by `ls-remote`.
  The default-mode run was **not repeated** (budget), so "patch mode with a verified push" is observed only as far as the
  patch side; the push side is the C2 evidence.
- The isolated checkout was not looked at after the run; where omp kept it, and whether it cleaned it, is not recorded
  for 18.6.0 (Q4's 18.5.1 account still stands).
- The evidence that the overlay's `task.isolation.enabled: true` took effect is the result text (`Applied patches: yes`
  in C1, `Merged branch: omp/task/WorkerBranchTask` in C2) and the parent-checkout changes above, not the `isolated` field in
  the call, which the prompt asked the model to set. No setting was changed in the default profile.

**Operator configuration.** The default profile's `config.yml` had SHA-256 prefix `7b634967911b` before the first omp
command and `7b634967911b` after the last. No `omp config set`, login, token, install or update command was run, and every
setting came from a `--config` overlay in `tmp/`. Nothing needs restoring.

### Verdicts for rows 3, 4, 5 and 6

| Row | Verdict | Evidence beside it |
| --- | --- | --- |
| 3 isolation | equivalent found | Q4 transcript: private checkout, own branch, commit, push to `origin` all worked. Off by default (`task.isolation.enabled = false`). Check C (18.6.0): patch mode dirties the parent, `merge=branch` commits onto its current branch |
| 4 skill delegation | equivalent found (bare name) | `skill://take-it` resolves, `skill://sassy-dog:take-it` does not. Namespace only on collision |
| 5 plugin root | equivalent found, but in one run a model recovered by searching | `[Skill directory: ...]` on `/skill:` and the path header on `read skill://<name>/<path>`. The token itself is not substituted. Check A (18.6.0, this repo's `CLAUDE.md` in context): the agent ran the literal token, failed, then used `find` |
| 6 config injection | none as a load-time step; an explicit read instruction worked once | `read skill://take-it` shows the `` !`...` `` line verbatim, and the render path has no shell step. Check B (18.6.0, this repo's `CLAUDE.md` in context): an agent read the config by absolute path and acted on it |

### What omp's remaining pages say

- **env** (`https://omp.sh/docs/env`): `CLAUDE_CONFIG_DIR`, `PI_CONFIG_DIR` (a directory name under
  home, default `.omp`), `OMP_PROFILE` and the legacy `PI_PROFILE`. No plugin-root variable, and
  nothing about what is exported to skills, hooks or tools.
- **hooks** (`https://omp.sh/docs/hooks`): events are named (`tool_call`, `tool_result`,
  `session_stop`, `session_start`, and others) and hooks are discovered in `.omp/hooks/pre/` and
  `.omp/hooks/post/` or the profile's `agent/hooks/`. The page never mentions Claude Code or a
  `settings.json` hooks shape. Row 9: `setup-hooks` output is **not** consumed by omp, so it stays
  Claude-Code-only. Hook file format and a Stop equivalent are otherwise unknown here.
- **slash** (`https://omp.sh/docs/slash`): skills appear as `/skill:<name> [arguments]`, with no
  `$ARGUMENTS` substitution and no shell injection. `/loop [count|duration] [--while|--until '<cmd>']
  [prompt]` re-submits after every yield (**source**, `src/slash-commands/builtin-modes.ts`). That is
  not `/loop 5m /dispatch-ready`: the duration bounds the loop and there is no per-tick interval. Row 11
  is therefore a partial equivalent, and `dispatch-ready`'s tick idempotency is what makes it usable.
- **custom-tools** (`https://omp.sh/docs/custom-tools`): TypeScript or JavaScript modules, shippable in
  plugins, discovered in `.omp/tools/<name>/index.ts` and, as a legacy path, `.claude/tools`. The
  factory host exposes the session working directory as `pi.cwd`. It documents no plugin-root value and
  no skill-to-skill call.

## Per-mechanism detail

Each entry gives what the plugin uses the mechanism for, then what omp documents, then a
**Spike** line where #424 observed or read something that settles or corrects it.

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

**Spike.** The call shape, the batch form and the depth rule are now known (Q5). The default chain
fits and the `review_site: agent` chain does not, so the two sentences above are corrected: the
default works at depth 2, and `agent` leaves the orchestrator without a `task` tool.

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

**Spike.** Plugin agents load, unprefixed: the lookup key is the frontmatter `name`, so
`sassy-dog:<name>` finds nothing and `<name>` does. `color` is ignored without error, and `task` takes a
per-call `model` (Q5). Every `subagent_type` site that spells a `sassy-dog:` name needs the bare name
on omp.

### 3. `isolation: "worktree"`

**Used for.** Giving each parallel worker its own git worktree, so workers do not collide in one
checkout. `take-it` and `dispatch-ready` depend on it. The other two files (`repo-cleanup` and
`pr-shepherd`'s teardown reference) handle the cleanup of what it creates.

**omp.** Isolation is a setting, not a call parameter. `task.isolation.mode` is `auto` or a named
backend and defaults to "none" (a legacy key that 18.5.1 migrates to `task.isolation.enabled`). Related
keys are `task.isolation.merge` (`patch` by default, or `branch`), `task.isolation.apply` and `worktree.base` (default `~/.omp/wt`)
(`https://omp.sh/docs/subagents`). A prompt can also ask for it ("Use the migration-fixer subagent
in an isolated worktree..."), and that page says it "requires Git support and configured task
isolation" (`https://omp.sh/docs/subagent-authoring`). The strategy is "filesystem clone or overlay
selected for the platform", so it is not documented as a git worktree with a branch. This repo's
workers create a branch and open a PR from inside the isolated tree. Whether an omp isolated
workspace can do that, and whether `patch` merge is compatible with a worker that pushes its own
branch: **unknown, not documented**. This is the riskiest mechanism in the inventory. The default is
"none", so a misconfigured run would put parallel workers in one checkout.

**Spike.** The unknown above is answered for the isolation itself (Q4): a worker gets its own checkout,
can branch, commit and push, and the parent receives `omp/task/<id>`, not the worker's branch. The
default stays off and the setting names in the docs differ from 18.5.1. #440 then ran the model-driven `task`
path twice on 18.6.0 (Check C): patch mode dirties the parent checkout, `merge=branch` commits onto its current
branch, and `apply = false` is untested.

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

**Spike.** A skill is loaded by reading `skill://<name>`; `sassy-dog:<name>` does not resolve and the
bare name does, with `<namespace>/<name>` only after a collision (Q5). omp has no skill-invoking tool.

### 5. `${CLAUDE_PLUGIN_ROOT}`

**Used for.** Resolving the absolute path of the plugin's bundled scripts and reference docs. It
expands only in `SKILL.md`, at load time. 15 `SKILL.md` files carry it
(``git grep -l CLAUDE_PLUGIN_ROOT -- 'skills/*/SKILL.md'``), and 7 reference docs mention it through
their `PLUGIN_ROOT` preamble (``git grep -l CLAUDE_PLUGIN_ROOT -- 'skills/*/references/*.md'``).

**omp.** None found. The plugins page documents no path variable or environment variable for a
plugin's install directory (`https://omp.sh/docs/plugins`), and the skills page documents no
plugin-root variable (`https://omp.sh/docs/skills`). The environment variable reference
(`https://omp.sh/docs/env`) has no such variable either.

**Spike.** Not substituted, but resolvable: the skill directory is handed to the model, and its
grandparent is the plugin root (Q2). #440 (Check A, print mode, 18.6.0) found that `/skill:` was not expanded
there and `[Skill directory: ...]` was never delivered: the model got a `[Skill file: ...]` header from
`read skill://<name>` and recovered by searching.

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

**Spike.** Confirmed none: the line reaches the model unexecuted (Q3). The `@path` token was not tried
inside a skill, so that part stays unknown.

### 7. Per-repo config under `.claude/sassy-dog/`

**Used for.** The per-repo behaviour of every workflow skill. This is the data half of row 6.

**omp.** Not an omp concept. omp reads `.claude/CLAUDE.md` as a compatible context file
(`https://omp.sh/docs/context-files`) and finds skills under `.claude/skills/`
(`https://omp.sh/docs/skills`), but nothing documented reads `.claude/sassy-dog/`. The files are
plain Markdown, so any harness that can read a file can read them. The gap is how the content
reaches the skill (row 6), not the format. **Spike:** nothing changed; the row-6 result applies.

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

**Spike.** It installs as is (Q1). The `extraKnownMarketplaces`/`enabledPlugins` declaration does
nothing for omp's install, and importing Claude Code's own registry needs `CLAUDE_CONFIG_DIR` plus
`enabledProviders` set to `["claude-plugins"]`.

### 9. Claude Code settings and hooks generation

**Used for.** `setup-hooks` renders a PostToolUse dispatcher, a stray-artifact guard and a `Stop`
entry into `.claude/hooks/` plus `.claude/settings.json`. It is Claude-Code-specific by purpose.

**omp.** omp has hooks (`https://omp.sh/docs/hooks`). Before #424 that page had not been read, so event
names, config location and whether the Claude shape is accepted were unknown.

**Spike.** The hooks page names events and `.omp/hooks/pre/` and `post/` locations and never mentions
`settings.json`, so `setup-hooks` output is not consumed by omp. It stays Claude-Code-only.

### 10. `AskUserQuestion`

**Used for.** `setup-config`'s interview, in one reference doc.

**omp.** `ask`: "Let omp pause for a choice, confirmation, or missing detail when it cannot safely
derive the answer" (`https://omp.sh/docs/tools`). Batching several questions into one call:
**unknown, not documented**.

### 11. `/loop`

**Used for.** `dispatch-ready` is designed to run as `/loop 5m /dispatch-ready`, each tick idempotent
and with no memory of the previous one. `verify-issue-refs.sh` also names it.

**omp.** Before #424 none had been found in the pages read, and the slash-command page
(`https://omp.sh/docs/slash`) was unread, so an interval driver was **unknown, not documented**. The skill is already
tick-idempotent, so any external scheduler that re-invokes it would work.

**Spike.** omp has `/loop [count|duration] [--while|--until '<cmd>'] [prompt]`, which re-submits after
every yield. It has no per-tick interval, so it is a partial equivalent only.

### 12. Agent frontmatter `color:`

Cosmetic, on ten agents. omp's documented key list (row 2) does not include it. Behaviour on an
unknown key: ignored without error (Q5, **source**).

### 13. `claude plugin` CLI and install state

**Used for.** Two things. Five workflow skills (`send-it`, `take-it`, `tidy-repo`, `work-fire-watch`,
`work-recommendations`) tell a degraded session to run `claude plugin install sassy-dog`, and
`setup-config`'s contract and `repo-health`'s drift guidance cite `claude plugin update`.
`repo-health`'s plugin-drift script runs no `claude` command. It reads
`~/.claude/plugins/installed_plugins.json` and the marketplace clone's manifest.

**omp.** The install command differs: `omp plugin install name@marketplace`
(`https://omp.sh/docs/marketplace`). The drift diagnostic covers a Claude Code cache failure mode
and has no omp analogue in the pages read. **Spike:** an omp install writes under
`~/.omp/` (`plugins/installed_plugins.json` plus a cache clone), so a diagnostic would read there.

### 14. `mcp__...` tool-id literals

Not a dependency, as noted under the table. No omp equivalent is needed.

### 15. `.claude/worktrees` path

**Used for.** Worktree location in teardown and cleanup (`pr-shepherd`'s `teardown.sh` and
`worktree-teardown.md`, `repo-cleanup`'s `SKILL.md`), and path classification in
`repo-health/scripts/pull-plugin-drift.sh`, which tests `"/.claude/worktrees/" in path` to
recognise worktree paths when checking plugin drift. Claude Code creates agent worktrees there.
omp defaults to `~/.omp/wt` (`worktree.base`, `https://omp.sh/docs/subagents`), so teardown and
cleanup would not find omp's worktrees at the Claude path. The drift check walks only Claude
Code's own `installed_plugins.json` (row 13), so omp needs no port of it; if a Claude Code session
opens one of omp's worktrees, though, the check would list it as an ordinary project path rather
than prune it.

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

1. Rows 5 and 6 (plugin root, config injection) gate every skill, and omp documents neither. The
   spike found a path-resolvable equivalent for row 5 (a model recovered by searching, #440) and none for row 6.
2. Row 3 (isolation) gates the parallel-worker skills, and the risk is a silent no-op.
3. Rows 1 and 2 are lower risk. omp documents a dispatch tool and an agent format, and the
   remaining questions are about call shape.
4. Row 4 is medium risk, not low. omp documents `/skill:<name>` invocation but nothing about a skill
   body invoking another skill or about plugin namespacing, and ten files, `dispatch-ready` among
   them, depend on it. If the namespaced name does not resolve, every workflow skill loses its
   capability skills. The spike tested it: the namespaced name does not resolve, the bare name does.

## Recommendation

Option **D**, with **C** as the stance until a skill family has been run through a model on omp. The
spike (above) answered the five questions by running omp 18.5.1 and reading its source, with no
model-backed run, and the #440 checks then ran three narrow probes through a model on 18.6.0. Do not start with A or B. Both are mechanical rewrites across the rows 1 to 6 files,
and row 6 still has nothing to bind to.

What the spike changed. The plugin installs and all 23 skills and 10 agents load (Q1). Row 5 has a
path-resolvable equivalent that a model reached only by searching, row 3 has a working isolation, and row 4 has a bare-name equivalent. Row 6
has none. The dispatch family still cannot be called supported, because every one of those results
is untested through a model for a real skill and the two settings that gate it are off by default or
consumer-owned (`task.isolation.enabled`, `task.maxRecursionDepth`). The #440 checks ran toy probe skills and
two isolated `task` calls, not a shipped skill, so the README matrix keeps its `not supported` and `untested` cells
unchanged. What changed is the reason given for them, and that is updated beside the matrix.

**Go/no-go for #425 (plugin root and config injection).** Split, and weaker than the first draft of #440 said. Both
model-backed checks ran with this repo's `CLAUDE.md` in context (see the #440 Setup caveat), a file that documents
both mechanisms, from a probe skill and not the installed plugin, in one run each with one model. They show what
can happen, not what a cold consumer-repo agent does. **Go on the plugin root, conditionally.** The token is
not substituted, and in the one traced run the agent ran the literal token, got exit 127, then searched with `find` and
recovered. That run did not show the grandparent being derived. The follow-up should add one resolution sentence per
`SKILL.md` that carries the token (15 files) and per reference-doc preamble, keeping the token for Claude Code, and
should treat "the first command succeeds" as the thing to prove. Print mode did not expand `/skill:`, so the sentence
must not rely on a `[Skill directory: ...]` line that print mode never delivered (the model got a `[Skill file: ...]`
header from `read skill://<name>`). **No-go as a mechanical port of config injection**: omp has no load-time shell
step, so the `` !`...` `` line arrives unexecuted. **A different design is plausible, not proven.** An explicit "read
`.claude/sassy-dog/<skill>.md` by absolute path" instruction was followed once, with no `NO_CONFIG` fallback, but with a
context file in the prompt that explains that very path and fallback, so the result may owe as much to that file as to the
skill's own sentence. #425 should not rewrite 22 files on this evidence: first repeat A and B on one shipped skill
installed from the plugin, run from a repository outside this tree. The `take-it` and `dispatch-ready` stop on
`NO_CONFIG` remains the safe default meanwhile, because an unexecuted line must never be read as "no config exists".

**Go/no-go for #426 (isolation contract).** **Go**, narrowly. The worker-owns-a-branch-and-pushes
design works inside omp isolation (Q4, and check C: with an absolute-path remote the worker's push was confirmed by
`ls-remote`), which suits a worker that opens its own PR. The parent never receives the worker's branch name. The
contract has to state three things the plugin cannot set: `task.isolation.enabled` must be true (default false, a
silent shared checkout otherwise), a skill should read it with `omp config get` and stop when it is off, and
`apply`/`merge` must be chosen so the parent checkout is not changed by a change the worker already pushed. Check C
answers the last point for the two documented modes, and **neither leaves the parent untouched**: the default
`merge = patch` modifies the parent's working tree in place (uncommitted), and `merge = branch` commits the same change
onto the parent's current branch as a different commit from the pushed one. A coordinator that then merges the pushed
branch meets the change twice. What is **still unknown** is `task.isolation.apply = false`, which was not run and
which is the candidate for "parent untouched"; it is the first thing #426 should test through a real `task` call.
The default-mode run's own push was not verified (relative remote, see Check C), so a patch-mode run with a verified
push is also not observed. The go stays narrow.
Separately, `review_site: agent` cannot work on omp without raising `task.maxRecursionDepth`, so the
contract should pin `coordinator` for omp.

Candidate follow-up issues, for the operator to accept or drop:

1. Done: the omp spike (#424), recorded above.
2. #425: #440's checks ran with this repo's `CLAUDE.md` in context, so start by repeating A and B on one shipped skill installed from the plugin, run from a repository outside this tree, then add the root-resolution sentence and prove the first command succeeds.
3. #426, scoped as above, including the `review_site` pin and a test of `task.isolation.apply = false`.
4. Bare agent and skill names on omp (`subagent_type` and `Skill: sassy-dog:<name>` sites), which
   neither #425 nor #426 covers.
5. A README note that a repo's `.claude/settings.json` declaration does not install the plugin on omp.

## Not read

The four pages the first pass skipped were read in #424 and are summarized under "What omp's remaining
pages say": `https://omp.sh/docs/env`, `https://omp.sh/docs/hooks`, `https://omp.sh/docs/slash`,
`https://omp.sh/docs/custom-tools`. `https://omp.sh/docs/subagents` was re-read for the task and
isolation parameters. What is still **not** read or tried: the `@path` include inside a skill, the
hook file format, and the other pages of omp's bundled docs index (134 files, listed by
`omp read omp://`), which hold far more than the website summaries gave.
