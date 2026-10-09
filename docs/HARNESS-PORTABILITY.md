# Harness portability

An inventory of the Claude-Code-specific mechanisms in `skills/` and `agents/`, what omp offers in
their place, and the options for the shape of a fix. This is an options document for issue #410,
extended with the results of the omp spike (issue #424, [Spike results](#spike-results-424)).
**It decides no shape option.** Its Recommendation and go/no-go paragraphs
are recommendations for the operator, who makes the shape decision, and implementation issues follow
from it; the ones already landed are named where they are discussed (row 5's paragraph, #454; row 3's
`take-it` confirmation, #451).

[`MODEL-TIERS.md`](MODEL-TIERS.md) made *model choice* portable. This document covers the rest of
the dispatch mechanics, the ones that file's "What a tier does not cover" section names.

## How to read the counts

Every count is the number of **tracked files** matching the command beside it, under `skills/` and
`agents/` only. It is a file count, not a site count: a file that uses a mechanism five times counts
once. The counts are a snapshot of the tree on 2026-10-03. Nothing gates them, so they go stale as
the tree moves. Re-run the command rather than trusting the number. omp is quoted from its documentation at
`https://omp.sh/docs/...` and, since the spike, from what omp 18.5.1 (the spike) and 18.6.0 (the #440, #425 and #426 checks) did when run. Where the
documentation is silent, the entry says **unknown, not documented**. That is a different statement
from "omp cannot do it". The omp pages were read through a summarizing fetcher, so "not documented"
means "not found in the summary". Evidence labelled **observed** was produced by running omp, 18.5.1 unless the entry says 18.6.0
(commands under [Spike results](#spike-results-424), [Model-backed checks (#440)](#model-backed-checks-440), [Out-of-tree checks (#425)](#out-of-tree-checks-on-shipped-skills-425) and [Isolation checks (#426)](#isolation-checks-426)). Evidence labelled **source** was read from the
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

### Q2. Plugin root (row 5): equivalent found; unchanged skills make a model search, and a token-free root-resolution paragraph stopped it (#440, #425, #454)

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
was not seen under a model. #425 then repeated the check out of tree on a shipped skill
([A′](#out-of-tree-checks-on-shipped-skills-425)): two runs of the unchanged skill both found the script with `find`
(one ran the literal token first, and the empty variable made it `/skills/...`, exit 127), and, on a copy with a root-resolution paragraph, with a paragraph that also forbids searching (v2), 2 of 2 runs used the right root and none searched; a wording without that clause (v1) searched in its one run; the first command itself succeeded in one of the two v2 runs. #454 then ran the token-free wording that ships, at the shipping placement ([A‴](#token-free-paragraph-at-the-shipping-placement-454)): 3 of 3 runs on `github-issues` used the right root with no token run and no `find`, and the first command succeeded in 2 of 3 (the third carried a stray word from the prompt). The `[Skill file: ...]` header from
`read skill://<name>` is what the model used, not `[Skill directory: ...]`.

### Q3. Config injection (row 6): no load-time step; the unchanged skill still worked under a model (#425)

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
mechanism. That is not evidence about a consumer repo. #425 then ran the shipped `send-it` out of tree with
`omp/18.6.0` ([B′](#out-of-tree-checks-on-shipped-skills-425), `anthropic/claude-haiku-4-5`, no context file loaded). The unchanged skill, which still
carries the unexecuted `` !`...` `` line, gave the right answer in all three runs: with a config file present the agent read it (once)
or ran the line's own shell command itself (once), and with the file absent it ran that command and reported `NO_CONFIG`. So "every skill
degrades to `NO_CONFIG`" was **not** what happened in three runs with one model, but the prompts named the config, and the
agent chose to run an unrun line. That is a model choice, not a mechanism, so `take-it` and `dispatch-ready`, which block on
`NO_CONFIG`, should not rely on it. A copy with an explicit read-by-absolute-path instruction also worked, present and absent.
Issue #455 then ran the unchanged `take-it` and `dispatch-ready` on prompts that do not mention config, six runs each, and every run was right; the paragraph shipped to the four conservative-mode skills only ([Config-fallback paragraph (#455)](#config-fallback-paragraph-455)).

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
  silently. Nothing in a skill can set it, and `omp config get` cannot confirm a `--config` overlay's value
  ([#426 results](#isolation-checks-426)); it does reflect a project-level file and `PI_CONFIG_FILES`
  ([#453](#isolation-settings-sources-453)).

The model-driven `task` call with `isolated: true`, and how `apply = true` with `merge = patch` or
`merge = branch` treat a worker that pushed its own branch, are answered by check C of #440 on `omp/18.6.0`
(see [Check C](#check-c-row-3-apply-patches-the-parent-mergebranch-replays-the-commit-onto-it)): patch mode
modifies the parent checkout in place, and `merge=branch` commits the worker's change onto the parent's
current branch as a different commit from the pushed one. The 18.5.1 transcript above is unchanged.
[Isolation checks (#426)](#isolation-checks-426) then ran `apply = false` (D1: parent untouched, push verified), re-ran the default
(D2: push verified) and found the isolated checkout gone after both runs on 18.6.0. They also found that
`omp config get` ignores a `--config` overlay, which matters to the contract.
[Isolation settings sources (#453)](#isolation-settings-sources-453) found that `merge` is consulted when `apply` is false
(`merge: branch` leaves a new local branch in the parent rather than a patch file) and that a project-level file is reflected by
`omp config get` and took effect in one run.

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

**Depth (row 1), source.** `canSpawnAtDepth(max, depth)` is `depth < max` on the agent's **own** depth, so an agent
**at** depth `max` loses its `task` tool (`src/task/types.ts`, applied in `src/tools/index.ts`; children get
`parentDepth + 1` in `src/task/executor.ts`). Corrected in #426 (18.6.0 source): this sentence earlier said an agent "whose children would
sit at depth `max`" loses it, which read literally would disqualify the coordinator too. With the
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
repository outside this tree before they say anything about a consumer repo. #425 did that, see
[Out-of-tree checks on shipped skills](#out-of-tree-checks-on-shipped-skills-425).

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
  scales with the size of the tree it is pointed at. A sentence that names the resolution rule is still needed. #425 ran
  such a variant on a shipped skill: see [A″](#out-of-tree-checks-on-shipped-skills-425), where, in the two v2 runs, the first command succeeded in one and the right root was used in both; the one v1 run (a wording without the do-not-search clause, three A″ runs in all) searched. The token-free wording that ships was run in #454, see [A‴](#token-free-paragraph-at-the-shipping-placement-454): 3 of 3 runs used the right root and none searched.

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
`NO_CONFIG` branch (file absent) was not exercised here, and neither was a skill that still carries the `` !`...` `` line
next to the instruction. [#425](#out-of-tree-checks-on-shipped-skills-425) exercised both, out of tree, on the shipped `send-it`.

### Out-of-tree checks on shipped skills (#425)

Issue #425 repeated Checks A and B on **shipped** skills, from outside this tree, then tested one candidate edit per row. It
used **10** model-backed `omp` runs, the cap, all `omp/18.6.0` with `--model anthropic/claude-haiku-4-5`. Every other command
below is model-free. One model, one run per cell: this shows what can happen, not how often.

**How the plugin was loaded, per invocation, with no change to the default profile.** `git archive HEAD` extracted with `tar -x -C <scratch>/plugin`
put a copy of this repo's `skills/`, `agents/` and root files outside the repo (the coordinator states that the released
`2026.10.15` `skills/` and `agents/` are identical to this base; the copy is not the published clone). A temporary
`CLAUDE_CONFIG_DIR=<scratch>/cc` held only `plugins/installed_plugins.json`:

```text
{"version":2,"plugins":{"sassy-dog@skills":[{"scope":"user","installPath":"<scratch>/plugin","version":"2026.10.15"}]}}
```

and `--config <scratch>/overlay.yml` held `enabledProviders: [claude-plugins]`. Model-free, by calling omp's own
`Settings.loadReadOnly` and `loadSkills` from the scratch repo: with `CLAUDE_CONFIG_DIR` alone, **0** skills loaded (matching Q1's finding,
now on 18.6.0; Q1 gives the reason: `CLAUDE_CONFIG_DIR` switches on the `claude` provider only, and user-level `claude-plugins` is opt-in, `isUserSourceEnabled` in `src/capability/index.ts`.
**Source**, 18.6.0: `claude-plugins` roots listed from a `CLAUDE_CONFIG_DIR` registry carry origin `claude`, so the filter in `loadSkills`, `src/extensibility/skills.ts`
(`isSourceEnabled`, the final `level === "user"` branch), calls `isUserSourceEnabled("claude-plugins")`, which is false without the opt-in. `allowedRoots` in `src/discovery/claude-plugins.ts` also accepts `claude`, which is why the roots are found and
then dropped here). With the overlay as well, **23** loaded, from `<scratch>/plugin/skills/`. `omp read` takes no
`--config`, so the model-free listing could not be done through that subcommand. No `omp plugin install` was run.

**Where context files could come from.** The scratch repo was `mktemp -d` under `/tmp`, outside this repository and outside the home
directory, with a `git init` repo, a local bare remote at an absolute path and no GitHub remote. `find` over the scratch tree and
`find / -maxdepth 2` found no `CLAUDE.md` or `AGENTS.md`, and the temporary `CLAUDE_CONFIG_DIR` held none. From source, omp's
standalone walk (`loadStandaloneContextFiles` in `src/discovery/helpers.ts`) stops at the repository root when the repository is not
under the home directory, so only the scratch repo's own files count. A plugin's root `CLAUDE.md` is **not** loaded as context: the
`claude-plugins` provider registers skills, rules, slash commands, hooks, tools and MCP servers only, never the context-file capability
(**source**, `registerProvider` calls in `src/discovery/claude-plugins.ts`). That matters because the plugin copy, like a real install, carried this
repo's root `CLAUDE.md`. Observed with omp's own `loadProjectContextFiles` from the scratch repo, with the temporary `CLAUDE_CONFIG_DIR` and the overlay:
`context files: 0`. The same script run from this worktree listed 1 (its `CLAUDE.md`), so the check can see a file. It covers user-level
context files too, and printed paths only, never contents. It is not a dump of a model's system prompt, which the JSON stream does not carry. So, unlike
A and B of #440, **no `CLAUDE.md` was in context** here.

**Prompts.** A′ and A″, verbatim: "Use the github-issues skill. Run its queue-snapshot.sh --sites-of resolver on the label array
["site:mac","ready"] by piping that array on stdin, and report the exact output. Do not run gh, do not use the network, and do nothing else."
(the word `resolver` after `--sites-of` is a slip in the prompt, and it twice became a stray argument, see below). B′ and B″: "Use the
send-it skill, but only to report which pr_template_path value the repo's send-it config sets, and say where that value came from (the config
file, NO_CONFIG, or something else). Stop there: do not commit, push, create a PR, run gh, or perform any other workflow step." The B prompts
name the config and `NO_CONFIG`, which nudges the agent toward them. The dummy `.claude/sassy-dog/send-it.md` carried
`pr_template_path: .github/WALRUS-93-TEMPLATE.md`.

Command shape, from the scratch repo (`<scratch>/cc2` and `cc3` pointed at edited plugin copies, see below):

```text
CLAUDE_CONFIG_DIR=<scratch>/cc omp -p --no-session --model anthropic/claude-haiku-4-5 --no-title --max-time 5m --mode json --config <scratch>/overlay.yml "<prompt>"
```

| Run | Phase | Skill and variant | Config file | Tool calls, in order | Outcome |
| --- | --- | --- | --- | --- | --- |
| 1 | A′ | `github-issues`, unchanged | n/a | `read skill://github-issues`; `bash ... "${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh" --sites-of`; `find <scratch> -name queue-snapshot.sh`; `bash <abs path> --sites-of` | the literal token ran first and failed (`/skills/github-issues/scripts/queue-snapshot.sh: No such file or directory`, exit 127), then `find`, then `["mac"]` |
| 2 | A′ repeat | same | n/a | `read skill://github-issues`; `find <scratch> -name queue-snapshot.sh`; `bash <abs path> --sites-of` | no token run, but `find` first; `["mac"]` |
| 3 | A″ v1 | `github-issues`, sentence v1 | n/a | `read`; `find <plugin copy> ...`; `bash <abs path> --sites-of resolver` (exit 64); `bash <abs path> --sites-of` | no token run, `find` still first; `["mac"]` |
| 4 | A″ v2 | `github-issues`, sentence v2 | n/a | `read`; `bash <abs path> --sites-of` | **first command succeeded**, no token run, no `find`; `["mac"]` |
| 5 | A″ v2 repeat | same | n/a | `read`; `bash <abs path> --sites-of resolver` (exit 64); `bash <abs path> --sites-of` | root derived correctly, no token run, no `find`; the script was reached and refused the stray word from the prompt, then the agent corrected it |
| 6 | B′ | `send-it`, unchanged | present | `read skill://send-it`; `read .claude/sassy-dog/send-it.md` (repo-relative) | reported the config value and named the file as its source |
| 7 | B′ repeat | same | present | `read skill://send-it`; `bash` running the `` !`...` `` line's own command | printed `CONFIG_SOURCE` and the file; reported the value |
| 8 | B′ | same | absent | `read skill://send-it`; `bash` running the line's own command | printed `NO_CONFIG`; reported `NO_CONFIG` |
| 9 | B″ | `send-it`, read instruction added | present | `read`; `bash git rev-parse --show-toplevel`; `read <root>/.claude/sassy-dog/send-it.md` (absolute) | reported the value, from the file |
| 10 | B″ | same | absent | `read skill://send-it`; `bash` running the line's own command | printed `NO_CONFIG`; reported `NO_CONFIG`. It did not take the new read-by-path route, and was still correct |

The run numbers follow the table, not the order the calls were made. Run 1 is the Check A shape again, on a shipped skill and with no `CLAUDE.md` in context. Observed:

- **A′ (row 5), unchanged skill, 2 runs.** Both agents ended with the right answer, and **both used `find` to locate the script**. One of the two ran the literal
  token first. Because omp does not export `CLAUDE_PLUGIN_ROOT` to the shell, the variable expanded to nothing and the command became
  `/skills/github-issues/scripts/...` (**observed**, run 1, from that failing path). No run used the `[Skill directory: ...]` line: print mode never delivered it
  (zero occurrences), the same as Check A. `read skill://<name>` printed a
  `[Skill file: <scratch>/plugin/skills/github-issues/SKILL.md]` header, which is the only path the model was given.
- **A″ (row 5), one edit, two wordings.** The test edit (a scratch copy, never committed) added a "Plugin root" paragraph before the command at
  `skills/github-issues/SKILL.md`, directly above its `--sites-of` block (original line 54; the skill's first token command is at line 22, see the design's **Open** note). **v1** said Claude Code replaces `${CLAUDE_PLUGIN_ROOT}`, and that when it arrives literally the plugin root is the
  skill's directory with `/skills/github-issues` removed, found in the `[Skill file: ...]` or `[Skill directory: ...]` line. The agent skipped the token
  but still ran `find` (run 3). **v2** added only the clause "and do not search for the script" (v1 already said "do not run it"), told the agent to cut that path at `/skills/github-issues`, and
  gave the result form `<root>/skills/github-issues/scripts/queue-snapshot.sh`. Under v2 the agent's first script command used the correct absolute path in both runs, with no
  token and no `find`. In run 5 that command also carried the stray prompt word and the script rejected it with exit 64, so the strict reading, "first command succeeds",
  holds for run 4 only. Reading it as "the root was right on the first try" holds for both.
- **B′ (row 6), unchanged skill, 3 runs.** The agent never treated the unrun line as "no config". In run 6 it ignored the line and read the file by repo-relative path. In
  runs 7 and 8 it **ran the line's own command through `bash`**, which gave the file when it existed and `NO_CONFIG` when it did not. So the `` !`...` `` line, shipped as is, was
  followed correctly by this model. The skill's own §1 prose also says to read the config by absolute path when `CONFIG_SOURCE` names another repo, and that prose
  may have helped, so this is not a result about a skill without such a sentence.
- **B″ (row 6), read instruction added, 2 runs.** Present: the agent used `git rev-parse` and read by absolute path (run 9). Absent: it ran the line's own command and
  reported `NO_CONFIG` (run 10), correct but not through the new route. The added paragraph was therefore **followed once and not needed once**: runs 9 and 10 cannot show it adds
  reliability over runs 6 to 8.

**The inserted paragraphs, verbatim** (from the edits made to the scratch copies; each followed the unchanged sentence that ends the paragraph above the code block, whose final
`repo:` became `repo.` in the two A″ copies). A″ v1:

```text
**Plugin root.** Claude Code replaces `${CLAUDE_PLUGIN_ROOT}` in the command below before you see it. If
it reaches you as the literal token, do not run it: the plugin root is this skill's directory with
`/skills/github-issues` removed, and this skill's directory is in the `[Skill file: ...]` or
`[Skill directory: ...]` line at the top of this skill. Substitute that root for the token, then run:
```

A″ v2 (the first line is as in v1):

```text
**Plugin root.** Claude Code replaces `${CLAUDE_PLUGIN_ROOT}` in the command below before you see it. If
it reaches you as the literal token, do not run it and do not search for the script. Take the path
in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at
`/skills/github-issues`: what comes before the cut is the plugin root, so the script is at
`<root>/skills/github-issues/scripts/queue-snapshot.sh`. Write that absolute path into the command in
place of the token, then run it:
```

B″, inserted in `skills/send-it/SKILL.md` directly after the `` !`...` `` line, before its "Check `CONFIG_SOURCE`" paragraph:

```text
**If the line above reached you as text** (it starts with `!` and shows a shell command, with no
`CONFIG_SOURCE:` output beneath it), nothing ran it. Get the config yourself: take the repo root from
`git rev-parse --show-toplevel` and read `<root>/.claude/sassy-dog/send-it.md` by absolute path. If that
file does not exist, the config is `NO_CONFIG`: say `NO_CONFIG` and follow this skill's `NO_CONFIG`
handling. Never read an unrun line as "no config exists".
```

**Not shown.** Any other model; interactive `/skill:` invocation; a prompt that does not mention config or `NO_CONFIG`; the `take-it` and
`dispatch-ready` block-on-`NO_CONFIG` branch; Claude Code itself, where the edited sentences were not run. The v2 wording contains the
literal token `${CLAUDE_PLUGIN_ROOT}`, which Claude Code **would substitute inside the sentence too**, garbling it, so the shipped
wording must not spell the token. That reworded sentence was not run in #425 (no calls were left), so "first command succeeds" was proved only for the
tested v2 wording there. #454 ran the token-free wording, see [A‴](#token-free-paragraph-at-the-shipping-placement-454).

**Operator configuration.** `shasum -a 256` of the default profile's `config.yml` began `7b634967911b` before the first omp command and
`7b634967911b` after the last, and `omp plugin list` printed `No plugins installed` both times. No `omp config set`, login, token, install or update was run. Every
setting came from the overlay, and the model-free scripts opened settings read-only. The scratch tree was removed afterwards.

### Token-free paragraph at the shipping placement (#454)

Issue #454 ran the wording that ships, with no spelling of the token, out of tree on `omp/18.6.0` with `--model anthropic/claude-haiku-4-5`. It used **5** model-backed
runs of its cap of 8, same command shape and same per-invocation loading as #425 (a temporary `CLAUDE_CONFIG_DIR` registry holding one `installed_plugins.json`, and a `--config`
overlay with `enabledProviders: [claude-plugins]`; no `omp plugin install`, no `omp config set`). The plugin copy was `git archive HEAD` of this repository placed under a
`mktemp -d` directory in `/tmp`, with the paragraph added to two files of the copy. The scratch repo was a `git init` directory in the same tree. Omp's own
`loadProjectContextFiles`, called from the scratch repo with the temporary `CLAUDE_CONFIG_DIR`, printed `context files: 0`, and `find` over `/tmp` to depth 3 found no `CLAUDE.md` or `AGENTS.md`
outside the plugin copy (a plugin's root `CLAUDE.md` is not loaded as context, per #425's source read). So no `CLAUDE.md` was in context. One model, 5 runs: this shows what can happen, not how often.

The paragraph, verbatim, for `github-issues` (every other skill has its own name after `/skills/`; no spelling of the token):

```text
**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/github-issues`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.
```

It differs from v2 in two ways: it is token-free, and it no longer spells out the script path (`<root>/skills/<name>/scripts/queue-snapshot.sh`), because the command beneath it differs per skill. Shipping placement: immediately before the first fenced command that uses the token. In `github-issues` that is
the board-snapshot block (line 22 of the original file). In the copy the paragraph is at line 21 and the `--sites-of` command the prompt asks for is at line 56, 35 lines below it.

Prompt for runs 1 to 3 (the same as #425's A prompt, except that run 1 kept its `resolver` slip and runs 2 and 3 replaced the word `resolver` with `mode`): "Use the github-issues skill. Run its queue-snapshot.sh --sites-of <resolver|mode> on the label array
["site:mac","ready"] by piping that array on stdin, and report the exact output. Do not run gh, do not use the network, and do nothing else." Prompt for runs 4 and 5, which test a reference doc, with the paragraph added above the first token command of `pr-shepherd`: "Use the pr-shepherd skill. Read its stacked-prs reference doc, then run the probe command it gives, but with only the --help flag (no PR number, no --repo), and report the first line of the output. Do not run gh, do not use the network, and do nothing else." That probe, `stack-probe.sh --help`, only prints its own header comment (**source**, `skills/pr-shepherd/scripts/stack-probe.sh`).

| Run | Skill | Tool calls, in order (trimmed) | Outcome |
| --- | --- | --- | --- |
| 1 | `github-issues` | `read skill://github-issues`; `bash` piping the labels into `<abs>/skills/github-issues/scripts/queue-snapshot.sh --sites-of resolver` (exit 64); the same without the stray word | right root on the first command, no token run, no `find`; the first command was refused by the script for the prompt's stray word, then `["mac"]` |
| 2 | `github-issues` | `read skill://github-issues`; `bash` piping the labels into `<abs>/skills/github-issues/scripts/queue-snapshot.sh --sites-of` | first command succeeded, `["mac"]` |
| 3 | `github-issues` | same as run 2 | first command succeeded, `["mac"]` |
| 4 | `pr-shepherd` | `read skill://pr-shepherd`; `read skill://pr-shepherd/references/stacked-prs.md`; `bash <abs>/skills/pr-shepherd/scripts/stack-probe.sh --help` | first command succeeded, no token run, no `find` |
| 5 | `pr-shepherd` | same two reads; `bash` of the same `--help` command with its output cut to the first line (twice); two `read` calls of the script; one `bash` printing part of the script | right root on the first command, no token run, no `find`; the extra calls came from the output's first line, a shebang displayed as `!/usr/bin/env bash`, which the agent tried to get past |

`<abs>` is the plugin copy's absolute path under the scratch directory. Observed:

- **Bar met on `github-issues`, 3 runs.** The first command used the right absolute root with no literal token run and no `find` in 3 of 3 runs; it succeeded in runs 2 and 3, and in run 1 the script refused a stray argument that came from the prompt, as in #425's run 5.
  The agent used the path in `[Skill file: ...]`. No run saw `[Skill directory: ...]`.
- **A reference-doc command, 2 runs.** The resolved root reached the command in both, with no token and no `find`. **The `PLUGIN_ROOT` preamble was not what carried it:** both agents wrote the absolute path into the command itself and no run set a `PLUGIN_ROOT` variable. The reference doc's own `[Skill file: ...]` header also names its path,
  so these runs cannot say whether the paragraph's root, or that header, was the source. The preamble then said the invoking `SKILL.md` "already carries" the root "resolved in its own command lines". On omp the `SKILL.md` carries the placeholder unexpanded, so that sentence was not true there, and the hand-off worked anyway. The preambles were reworded in #459 to describe both harnesses; the omp hand-off through the reworded preamble is still unrun.
- **Not shown.** Any other model; interactive `/skill:`; a skill whose paragraph sits at a larger distance than 35 lines; every token-carrying file other than `github-issues` and `pr-shepherd` (their paragraph is the same text with the skill's own name, and the gate checks the text); `take-it`'s indented fence and `send-it`'s prose-only use, which carry the paragraph but were not run. **Known wording mismatch:** `send-it`'s anchor is a prose instruction to load a file and pass its path, not a command to run, so the paragraph's "the command below ... then run it" does not fit it exactly; the gate enforces one text, so the paragraph was not changed. Likewise `dispatch-ready` loads the Parent recovery protocol from the token path in its section 2, before its first fenced command, where the paragraph sits.

**Claude Code.** The paragraph is inert there, as designed: `claude -p --plugin-dir <worktree>` from the scratch repo, asked to invoke `sassy-dog:github-issues` and quote the paragraph and the first board-snapshot command without running anything, returned the paragraph unchanged
(including `/skills/github-issues`) and the command with an absolute path in place of the token. 1 of 2 allowed runs.

**Operator configuration.** `shasum -a 256` of the default profile's `config.yml` began `7b634967911b` before the first omp command and `7b634967911b` after the last, and `omp plugin list` printed `No plugins installed` both times. No `omp config set`, login, token, install or update was run.
The scratch tree was removed afterwards.

### Config-fallback paragraph (#455)

Issue #455 gated the paragraph for the four skills that stop on `NO_CONFIG`, then shipped it to the four conservative-mode skills and ran its absent branch. It used **13** model-backed
runs of its cap of 14, all `omp/18.6.0` with `--model anthropic/claude-haiku-4-5`, loaded per invocation as in #425 and #454 (a temporary `CLAUDE_CONFIG_DIR` registry holding one
`installed_plugins.json`, and a `--config` overlay with `enabledProviders: [claude-plugins]`; no `omp plugin install`, no `omp config set`). Runs 1 to 12 used a `git archive HEAD` copy of `main` with no edit; run 13 used a copy of the edited tree.
Two scratch repos under a `mktemp -d` directory in `/tmp`, each a bare `git init` with no commits and no remote: one with dummy `.claude/sassy-dog/take-it.md` and `dispatch-ready.md` files (a distinctive `claim_label` value),
one with no `.claude` directory. `find` over the scratch tree and over `/tmp` to depth 2 found no `CLAUDE.md` or `AGENTS.md`, and a plugin's root `CLAUDE.md` is not loaded as context (#425's source read), so no context file was in play.

**No GitHub side effects.** Every invocation ran with `GH_CONFIG_DIR` pointing at an empty temporary directory and `GH_TOKEN` and `GITHUB_TOKEN` unset, from a scratch repo with no remote, so `gh` was unauthenticated and could not write. No run was
pointed at a real repository. The runs' own tool calls confirm it: `gh issue view` and `gh repo view` failed for lack of authentication and the agents stopped there. Some agents also made `web_search` calls about `gh` authentication, and two ran a `task` sub-agent; neither touched GitHub.

**Prompts, neither of which mentions config or `NO_CONFIG`.** `take-it`: "Use the take-it skill. take #1". `dispatch-ready`: "Use the dispatch-ready skill. Drain the ready queue." Run 13 reused #425's B prompt ("Use the send-it skill, but only to report which pr_template_path value the repo's
send-it config sets, and say where that value came from (the config file, NO_CONFIG, or something else). Stop there: do not commit, push, create a PR, run gh, or perform any other workflow step."), which names the config. A run is **correct** if, with the file present, the agent used it
(read it or ran the line's command), and with the file absent, it reported `NO_CONFIG` and stopped.

| Run | Skill | Config file | Route to the config | Verdict |
| --- | --- | --- | --- | --- |
| 1 | `take-it`, unchanged | present | `git rev-parse`, then `read <root>/.claude/sassy-dog/take-it.md` (absolute) | correct; then stopped on `gh` authentication |
| 2 | `take-it`, unchanged | present | one `bash`: `git rev-parse` and `cat ./.claude/sassy-dog/take-it.md` | correct; same later stop |
| 3 | `take-it`, unchanged | present | the `!` line's own command, verbatim | correct; same later stop |
| 4 | `take-it`, unchanged | absent | `git rev-parse`, then the line's own command | `NO_CONFIG`, stopped, offered `setup-config` |
| 5 | `take-it`, unchanged | absent | `git rev-parse` and `ls` of the file | `NO_CONFIG`, stopped, offered `setup-config` |
| 6 | `take-it`, unchanged | absent | `git rev-parse` and `cat` of the file | `NO_CONFIG`, stopped, offered `setup-config` |
| 7 | `dispatch-ready`, unchanged | present | the line's own command, verbatim | correct; passed the config values to a `task` sub-agent |
| 8 | `dispatch-ready`, unchanged | present | the line's own command, verbatim | correct; later stopped on missing GitHub access |
| 9 | `dispatch-ready`, unchanged | present | the line's own command, verbatim | correct; passed the config values to a `task` sub-agent |
| 10 | `dispatch-ready`, unchanged | absent | `git rev-parse`, then `read <root>/.claude/sassy-dog/dispatch-ready.md` (absolute, missing) | `NO_CONFIG`, stopped, offered `setup-config` |
| 11 | `dispatch-ready`, unchanged | absent | the line's own command | `NO_CONFIG`, stopped, offered `setup-config` |
| 12 | `dispatch-ready`, unchanged | absent | the line's own command | `NO_CONFIG`, stopped, offered `setup-config` |
| 13 | `send-it`, with the paragraph | absent | `read .claude/sassy-dog/send-it.md` (repo-relative, missing), `git rev-parse`, then `read <root>/.claude/sassy-dog/send-it.md` (absolute, missing) | reported `NO_CONFIG`, naming the file as absent |

**Decision for the four stoppers: the paragraph is not added** to `take-it`, `dispatch-ready`, `work-recommendations` or `work-fire-watch`. All 12 unchanged runs were right, in six runs per skill, with the config both present and absent, on a prompt that never named the config, and in no run did
an agent read the unrun line as "no config exists". `work-recommendations` and `work-fire-watch` were not run. Each has its own `!` line that the agent handles before `take-it` runs, and each stops on `NO_CONFIG` before filing anything; their inclusion is #455's decision rule (`take-it`'s runs used as evidence for an identical line in a different skill and prompt), not inheritance and not a measurement. The limit of that evidence is the same as every other omp check here: one model, one prompt shape per skill, gh unauthenticated (so the runs ended at a GitHub failure rather than at a full dispatch), a dummy config, three runs per cell. It shows the
failure was not seen, not that it cannot happen. `NO_CONFIG` stays first-class and `take-it` and `dispatch-ready` still stop on it.

**Absent branch (run 13).** With the paragraph in `send-it` and the file absent, the agent tried a repo-relative read first, then derived the root with `git rev-parse --show-toplevel`, read the absolute path, found it missing and reported `NO_CONFIG`. It did not read the unrun line as "no config exists".
One run cannot say the paragraph caused the absolute-path read: #425's unchanged `send-it` also reached `NO_CONFIG` in its absent run, by running the line. What run 13 shows is that the paragraph's absent route ends in `NO_CONFIG` and not in a silent proceed. The present branch was followed once in #425 (B″, run 9) and not re-run here.

The paragraph, verbatim, for `send-it` (every other skill has its own name in the path; the four are `send-it`, `survey-work`, `groom-backlog` and `tidy-repo`):

```text
**Unrun config line.** If the line above reached you as text (it starts with `!` and shows a
command, with no `CONFIG_SOURCE:` output beneath it), nothing ran it. Take the repo root from
`git rev-parse --show-toplevel` and read `<repo root>/.claude/sassy-dog/send-it.md` by absolute path.
If that file does not exist the config is `NO_CONFIG`, handled as that state already is. Never read
an unrun line as "no config exists".
```

It sits directly under the injected line. It is inert in Claude Code, where the line runs and its output carries `CONFIG_SOURCE:`; the paragraph's condition is false there, and this was not run in Claude Code beyond reading the text. It starts no line with `!` plus a backtick, uses no positional token and does not spell the plugin-root token.

**Operator configuration.** `shasum -a 256` of the default profile's `config.yml` began `7b634967911b` before the first run and after the last; `omp plugin list` printed `No plugins installed` both times. The scratch tree was removed afterwards.

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
  The default-mode run was **not repeated** in #440 (budget), so "patch mode with a verified push" was observed only as far as the
  patch side there. **Superseded by [D2](#isolation-checks-426)**, which repeated it with an absolute remote and a verified push.
- The isolated checkout was not looked at after the run in #440. **Superseded by
  [Isolation checks (#426)](#isolation-checks-426)**, which listed `~/.omp/wt` before and after.
- The evidence that the overlay's `task.isolation.enabled: true` took effect is the result text (`Applied patches: yes`
  in C1, `Merged branch: omp/task/WorkerBranchTask` in C2) and the parent-checkout changes above, not the `isolated` field in
  the call, which the prompt asked the model to set. No setting was changed in the default profile.

**Operator configuration.** The default profile's `config.yml` had SHA-256 prefix `7b634967911b` before the first omp
command and `7b634967911b` after the last. No `omp config set`, login, token, install or update command was run, and every
setting came from a `--config` overlay in `tmp/`. Nothing needs restoring.

### Isolation checks (#426)

Run on 2026-10-03 on site `mac`, `omp/18.6.0`, the default profile, for #426: two model-backed `task` calls (D1, D2) and
a no-model `omp config get` check. **2 of the issue's 6 omp runs were used**, both on `anthropic/claude-haiku-4-5`; the
`omp config get` commands call no model. Each scratch directory came from `mktemp -d` under `/tmp`, outside this
repository, so this repo's `CLAUDE.md` was not in context (the #440 caveat does not apply). Each had a bare remote at an
**absolute** path and no GitHub remote. Every setting came from a `--config` overlay in the scratch directory:

```text
# d1.yml                      # d2.yml
task:                         task:
  isolation:                    isolation:
    enabled: true                 enabled: true
    apply: false
```

D2 therefore left `apply` and `merge` at their defaults (`true`, `patch`). Both runs used the form below, from inside the
scratch repo, with the prompt read from a file by a wrapper script (as in Check C):

```text
omp -p --no-session --model anthropic/claude-haiku-4-5 --no-title --max-time 8m --mode json --config <overlay> "<prompt>"
```

Prompt, verbatim, with `<n>` being `d1` or `d2`: "Call the task tool exactly once, with isolated set to true. The worker's job:
run 'git checkout -b feat/worker-<n>', append the line 'worker change <n>' to f.txt, run 'git add f.txt && git commit -m
worker-<n>-commit', then run 'git push -u origin feat/worker-<n>', and report the output of 'pwd', 'git log --oneline -3',
'git branch --show-current' and 'git ls-remote origin'. After the task returns, reply with only the word DONE." Parent
checkout before each run: `main` at `71f539d`, clean. In both runs the model made one batch-form `task` call, then `wait`.

| Run | Overlay | Parent checkout after | Bare remote after (my own `git ls-remote`) | `task` result text | Isolated checkout |
| --- | --- | --- | --- | --- | --- |
| D1 | `enabled: true`, `apply: false` | `main` at `71f539d`, `git status` clean, no new local branch | `main` `71f539d`, `feat/worker-d1` `cc04488` | `Isolation: changes captured at <tmp>/omp-task-<id>/WorkerD1Task.patch (apply=false). Not applied.` | worker `pwd` was `~/.omp/wt/<id>/m`; `ls ~/.omp/wt` held 0 entries afterwards |
| D2 | `enabled: true` (defaults `apply: true`, `merge: patch`) | `main` at `71f539d`, `f.txt` **modified, uncommitted** (`M f.txt`, holding `worker change d2`), no new local branch | `main` `71f539d`, `feat/worker-d2` `747632e` | `Applied patches: yes` | worker `pwd` was `~/.omp/wt/<id>/m`; `ls ~/.omp/wt` held 0 entries afterwards |

`ls ~/.omp/wt` also held 0 entries before D1, so neither run left a checkout behind. Only that directory listing was
read under `~/.omp`. D1's patch file existed under the system temp directory (`WorkerD1Task.patch`, beside a `.json`,
`.jsonl` and `.md`), outside the profile; I removed that one directory at the end of the session.

Observed, one run each, one model:

- **D1 is the "parent untouched" mode, and its push is verified.** The worker created its own branch, committed and pushed
  it to the absolute remote. The parent kept its branch, `HEAD` and a clean tree, and omp wrote the worker's change to a
  patch file instead of applying it. The pushed branch is the only copy of the change on a branch; the patch file is a
  second copy that nothing applies.
- **D2 closes Check C's C1 gap.** With the defaults, a verified push (`feat/worker-d2` on the remote) coexists with the
  parent's tree being patched: the same double-copy hazard as `merge = branch`, which shows up under `merge = patch` as a dirty tree.
- **Cleanup.** In both runs omp removed the isolated checkout itself. A coordinator has no tree to tear down on omp, and
  nothing at `.claude/worktrees` for row 15's teardown to find. The worker's branch exists only on the remote.
- **Both workers' reported `ls-remote` agreed with mine.** That is a match in these two runs, not a reason to trust a
  worker's report (Check C's C1 is the counterexample).

**`omp config get`, no model.** Commands and output, from the scratch directory, default profile unchanged:

```text
omp config get task.isolation.enabled                       # false
omp config get task.isolation.apply                         # true
omp config get task.isolation.merge                         # patch
omp --config d1.yml config get task.isolation.enabled       # false   (the overlay sets true)
omp --config d1.yml config get task.isolation.apply         # true    (the overlay sets false)
omp config get task.isolation.enabled --config d1.yml       # error: Unknown option '--config'
```

`omp config get` reports the **default profile's** value and **ignores** a `--config` overlay placed before the
subcommand; the flag after the subcommand is rejected. Yet the same overlays took effect on the `task` calls (D1 captured
a patch, D2 applied one), so `omp config get` is not evidence of what a run will do when settings come from an overlay. It
does read the profile's own value, which is where `omp config set` or an edit of `config.yml` puts a setting. Whether an
environment override or a project-level `.omp` settings file is visible to `omp config get` was not tried here; it is
answered by [Isolation settings sources (#453)](#isolation-settings-sources-453), which also corrects "reports the default
profile's value": `omp config get` reports the merged value across several layers, and only the `--config` flag is missing from it.

**Operator configuration.** The default profile's `config.yml` had SHA-256 prefix `7b634967911b` before the first omp
command and `7b634967911b` after the last. No `omp config set`, login, token, install or update command was run. Nothing
needs restoring.

### Isolation settings sources (#453)

Run on 2026-10-03 on site `mac`, `omp/18.6.0`, the default profile, for #453 (it follows #426). **2 of the issue's 6 omp
runs were used** (E1 and P1), both on `anthropic/claude-haiku-4-5`; step 1's `omp config get` commands call no model.
Each scratch directory came from `mktemp -d` under `/tmp`, outside this repository, with a bare remote at an **absolute**
path and no GitHub remote. **No profile setting was written**: no `omp config set`, `reset`, login, token, install or
update command was run, and `config.yml` had SHA-256 prefix `7b634967911b` before and after (`omp plugin list` still said
`No plugins installed`).

**Step 1, no model: which sources does `omp config get` reflect?** Run from inside a scratch git repo, the profile
holding the defaults (`enabled` false, `apply` true, `merge` patch). Each source set `task.isolation.enabled: true`,
`apply: false` and `merge: branch`; the output is the three `omp config get task.isolation.<key>` values, in that order:

```text
source                                                                      omp config get reports
none (baseline)                                                             false / true / patch
env PI_CONFIG_FILES=<abs path to an overlay file with the three values>     true / false / branch
env TASK_ISOLATION_ENABLED, PI_TASK_ISOLATION_ENABLED, OMP_TASK_ISOLATION_ENABLED = true   false / true / patch
project <repo>/.omp/config.yml                                              true / false / branch
project <repo>/.omp/settings.json  (JSON, same keys)                        true / false / branch
project <repo>/.claude/settings.json  (JSON, same keys)                     true / false / branch
project <repo>/.claude/settings.yml                                         false / true / patch
omp --config <file> config get ...  (recorded in #426)                      false / true / patch
```

- **Environment.** The three keys have **no per-key environment variable**: the definitions of `task.isolation.enabled`,
  `apply` and `merge` carry no `env` entry (**source**, `src/task/settings.ts`; a setting that has one declares it in the
  definition, `src/config/registry.ts`), and the three guessed names above changed nothing. The environment source that
  does exist is `PI_CONFIG_FILES`, a path-delimited list of overlay files that the `Settings` constructor reads
  (**source**, `src/config/settings.ts`). `omp config get` calls `Settings.init()` with no overlay argument
  (**source**, `src/cli/config-cli.ts`, `runConfigCommand`), so it sees `PI_CONFIG_FILES` and not the `--config` flag, which
  only the main run path passes (**source**, `src/main.ts`, the `Settings.init` call carrying `configFiles`).
- **Project.** A project-level file in the scratch repo is reflected when it is `.omp/config.yml`, `.omp/settings.json` or
  `.claude/settings.json`, and is not when it is `.claude/settings.yml`. The project layer is discovered through omp's
  settings capability and merged over the profile's own value (**source**, `src/config/settings.ts`, `#readProjectSettings`
  and `getProvenance`, whose documented precedence is runtime override, `--config` overlay, project, global, default). The
  source comment for `getProjectSettings` also lists `.claude/settings.yml`, and the observation disagrees; the observation
  is what is recorded, from one run of each file, and the discrepancy is unexplained. Whether a project file wins over a
  profile value that disagrees with it was **not run**, only read in that precedence comment.

Two consequences follow from the table and one run (P1, below). A settings source that `omp config get` reflects and that
needs no profile write exists: a project file, committed to the consumer repo. And a source can be reflected by
`omp config get` and still be overridden at run time by the `--config` flag, which `omp config get` cannot see. Step 2
of the contract therefore reads a passing value, and step 3 still runs.

**Step 2, model-driven: is `merge` consulted when `apply` is false? (E1.)** Overlay `enabled: true`, `apply: false`,
`merge: branch`, passed as `--config <abs path>`. The command, the prompt and the worker's job are D1's, with `e1` as
`<n>` ([Isolation checks (#426)](#isolation-checks-426)), run from inside `repo` by a wrapper script. One batch-form
`task` call.

| | Before | After |
| --- | --- | --- |
| Parent branch | `main` | `main` |
| Parent `HEAD` | `919d789` | `919d789` |
| Parent `git status --short` | empty | empty |
| Parent local branches | `main` | `main` and **`omp/task/IsolatedGitWorker`** at `ba3b91a` |
| Bare remote (my own `git ls-remote origin`) | `main` `919d789` | `main` `919d789`, `feat/worker-e1` `ba3b91a` |
| `ls ~/.omp/wt` | 0 entries | 0 entries |

Result text: ``Isolation: changes captured on branch `omp/task/IsolatedGitWorker` (apply=false). Not merged.`` (compare D1's
`changes captured at <tmp>/omp-task-<id>/WorkerD1Task.patch (apply=false). Not applied.`). Observed, one run, one model:

- **`merge` is consulted when `apply` is false, but only to choose the artifact.** With `merge: branch` omp leaves the
  worker's commits on a **new local branch in the parent repo**, `omp/task/<Name>`, and does not merge it; with
  `merge: patch` (D1) it leaves a patch file. The result text comes from `src/prompts/tools/isolation-summary.md`.
- **The branch is at the worker's pushed commit.** `omp/task/IsolatedGitWorker` and `feat/worker-e1` were both `ba3b91a`,
  one commit rather than the two copies of a change that `merge: branch` with `apply: true` left (Check C2).
- **Requirement 3 still held**: the parent's checked-out branch, `HEAD` and working tree did not move. A new local ref
  appeared, which a before-and-after check of the current branch, `HEAD` and `git status` does not see and a check of
  `git branch` does. The contract therefore pins `merge: patch` rather than relying on a coordinator to look.
- **The temp directory was left**: `<tmp>/omp-task-<id>/` held `IsolatedGitWorker.patch` beside a `.json`, `.jsonl` and
  `.md`, with the branch **and** a patch both present. I verified the push with the `ls-remote` in the wrapper, then removed
  my own directory. Older `omp-task-*` directories from other sessions were in the same place and were not touched.

**Step 3, model-driven: a run on values step 2 of the contract can confirm. (P1.)** No overlay and nothing in the profile:
the scratch repo carried a **committed** `.omp/config.yml` with `task.isolation.enabled: true` and `apply: false` (`merge`
unset). From inside that repo, before the run, `omp config get` gave `true`, `false`, `patch`: the contract's step 2 passes
on a project file alone. The run command was D1's with no `--config` flag, `p1` as `<n>`, one batch-form `task` call.

| | Before | After |
| --- | --- | --- |
| Parent branch and `HEAD` | `main`, `40c8643` | `main`, `40c8643` |
| Parent `git status --short` | empty | empty |
| Parent local branches | `main` | `main` |
| Bare remote | `main` `40c8643` | `main` `40c8643`, `feat/worker-p1` `b6696d4` |
| `ls ~/.omp/wt` | 0 entries | 0 entries |

Result text: ``Isolation: changes captured at `<tmp>/omp-task-<id>/WorkerP1.patch` (apply=false). Not applied.`` So a project
file set the isolation, the same behaviour D1 gave from an overlay: a private checkout, a push verified by my own
`ls-remote`, the parent untouched, a patch file left, and a temp directory I removed after the check. One run, one model;
the file was committed to the scratch repo, and the **untracked** variant was not run.

**What this does not show.** One run per setting, one model, one worker at a time, macOS. Nothing here shows a project file
beats a disagreeing profile value in a run, that a `.claude/settings.json` project file takes effect in a run (only that
`omp config get` reflects it), that the file reaches a worker's isolated checkout, or what happens with two concurrent
workers.

**Operator configuration.** `config.yml` had SHA-256 prefix `7b634967911b` before the first omp command and
`7b634967911b` after the last. **Profile changes: none, so nothing was restored.** Only `ls ~/.omp/wt` was read under
`~/.omp`, plus the hash of `config.yml`. The `omp-task-*` directory each run left in the system temp directory was removed
after verifying the push.

### Isolation confirmation runs (#451)

Run on 2026-10-04 on site `mac`, `omp/18.6.0`, for #451 (it implements #426's contract in `take-it`). **2 of the issue's 6 omp runs
were used**, both on `anthropic/claude-haiku-4-5`. The plugin loaded the way [#425](#out-of-tree-checks-on-shipped-skills-425)
loaded it: a temporary `CLAUDE_CONFIG_DIR` registry pointing at a copy of the working tree **with the new §5 text**, plus a
`--config` overlay enabling `claude-plugins`. Each run used its own `mktemp -d` scratch repo under `/tmp` with a committed
`.omp/config.yml`, a bare remote at an absolute path and no GitHub remote. `GH_CONFIG_DIR` pointed at an empty directory and
`GH_TOKEN` and `GITHUB_TOKEN` were unset, so `gh` could write nothing (no `gh` call appeared in either run). No profile write:
`config.yml` had SHA-256 prefix `7b634967911b` before the first run and after the last, and `omp plugin list` said
`No plugins installed` both times. The prompt asked the model to follow **only** §5's "Confirm isolation" paragraph and the
reference doc it points to (no issue was read or claimed, no attempt record written, and the worker template was not used), then
dispatch two trivial `task` workers (each creates a branch, commits one file, pushes) or follow the fail-closed rule.

| Run | Committed `.omp/config.yml` | `omp config get` (enabled / apply / merge) | What the model did | Parent after (my own checks) | Bare remote after (my own `git ls-remote`) |
| --- | --- | --- | --- | --- | --- |
| 1 | `enabled: false`, `apply: false` | false / false / patch | read the doc, ran the three reads, saw `enabled` false, took **serial** (reported "not isolated"), no probe, wrote the manifest, ran workers A then B (each told to fetch, branch from `origin/<default>` and return to the default branch) | `main` at the same `HEAD`, clean, local branches `feat/a-disabled` and `feat/b-disabled` (workers shared the tree, as serial mode implies) | `feat/a-disabled` and `feat/b-disabled`, each one commit on the seed |
| 2 | `enabled: true`, `apply: false` (`merge` unset) | true / false / patch | read the doc, ran the three reads, recorded the coordinator's `pwd`, top level, branch, `HEAD` and status, dispatched one `isolated: true` probe (worker `pwd` was under `~/.omp/wt/`, not the coordinator's), re-checked the parent, wrote the manifest, then dispatched workers A and B as **one `task` call with two tasks**, then ran its own `git ls-remote` | `main` at the same `HEAD`, clean, **no new local branch**, `~/.omp/wt` empty | `feat/a-project` and `feat/b-project`, each one commit on the seed |

Observed, two runs, one model:

- **The disabled case went serial rather than stopping**, which the contract permits for a plain list. It is the
  weaker outcome to evaluate: the model's own coordinator never ran the pre-dispatch `git status --porcelain` check, it only told
  the workers to. Nothing was dirty, so nothing leaked; the run does not show the check is followed.
- **The project-file case dispatched in parallel with the parent untouched**, the same result as P1 with two workers in one `task` call (overlap not measured)
  instead of one. Both pushes were verified by my own `git ls-remote`.
- **The after-batch cleanup step was not followed in run 2.** The model compared branch, `HEAD` and status and ran a fresh
  `ls-remote`, but did not remove the `<tmp>/omp-task-<id>/` directories (three, one per `task`, each with a `.patch`). I verified
  both pushes and removed my own three by hand; four older directories from other sessions were not touched. Run 1 left two
  directories (worker logs, no patch) that I removed the same way. A skill step that a haiku run skips is not a
  guarantee, so the temp-directory cleanup is stated, not shown.
- **No `review_site` override was exercised**: neither scratch repo configured `review_site`, so the report line was not tested.
- **Not shown:** a full `take-it` invocation on omp (the claim, attempt-record and PR steps were deliberately out of scope), a probe
  that finds isolation off under a passing read, `review_site: agent` on omp, the Stop branch (not run), and any model other than haiku.

**Operator configuration.** `config.yml` SHA-256 prefix `7b634967911b` before and after; `omp plugin list` `No plugins installed`
before and after. Only `ls ~/.omp/wt` and that hash were read under `~/.omp`.

### Isolation confirmation runs (#452)

Run on 2026-10-04 on site `mac`, `omp/18.6.0`, for #452 (it implements #426's contract in `dispatch-ready`). **6 of the issue's 6 omp runs were used**, all on
`anthropic/claude-haiku-4-5`, loading the plugin as the #451 runs did (a temporary `CLAUDE_CONFIG_DIR` registry pointing at a copy of the working tree with the new §5 text, plus
a `--config` overlay enabling `claude-plugins`). Each run used a scratch repo under `/tmp` with a bare remote at an absolute path and no GitHub remote;
`GH_CONFIG_DIR` pointed at an empty directory and `GH_TOKEN` and `GITHUB_TOKEN` were unset, and no run was given a `gh` step. The prompt told the model to follow **only** §5's
"Confirm isolation before this tick claims anything" paragraph and the reference doc, with the claim step simulated as one appended line per claim in a local log, then
to dispatch or follow the fail-closed rule. **This is not a tick**: §2, §3, §4, §7 and the claim scripts were not run. No profile write: `config.yml` had SHA-256 prefix
`7b634967911b` before and after, `omp plugin list` said `No plugins installed` both times, and the profile still read `enabled=false`, `apply=true`, `merge=patch`.

| Run | Committed `.omp/config.yml`, candidates, §5 wording | What the model did | Parent and bare remote after (my own checks) |
| --- | --- | --- | --- |
| 1 | `enabled: false`; stack chain #7 then #8; first wording | read `enabled` false, took **stop**, claimed nothing, printed `isolation unconfirmed` | parent untouched, empty claim log, remote has only `main` |
| 2 | `enabled: false`; plain #7 and #8; first wording | (serial mode, which does not ship) took serial, **claimed both issues and ran both workers** (one claim per tick was not yet stated) | parent clean on `main`; `feat/issue-7-x` and `feat/issue-8-x` on the remote |
| 3 | `enabled: true`, `apply: false`; plain #7 and #8; first wording | settings passed, then reported the probe "failed" and went serial; claimed both; ran no worker | parent clean, remote has only `main` |
| 4 | same as run 3; prompt now asked for the probe's reply verbatim | settings passed; the probe replied the coordinator's own `pwd`, so isolation was **unconfirmed** and the model went serial (the text did not yet require `isolated: true`); claimed both, ran both | parent clean; both branches on the remote |
| 5 | `enabled: true`, `apply: false`; plain #7 and #8; text now requires `isolated: true` on the probe and every worker | settings passed; the probe replied a `~/.omp/wt/...` path, not the coordinator's; **confirmed**, two workers in parallel | parent on `main` at the same `HEAD`, clean, **no new local branch**; `feat/issue-7-x` and `feat/issue-8-x` on the remote, verified by my own `git ls-remote` |
| 6 | `enabled: false`; plain #7 and #8; text now says one claim and one worker per tick | (serial mode, which does not ship) took serial, **claimed #7 only** and left #8 unclaimed | no worker ran in this run (it described the dispatch); its claim line went to a path inside the scratch repo, leaving one untracked file |

Observed, one model, prompted. **Runs 2, 3, 4 and 6 exercised the asynchronous serial draft rejected in #452**, not #484's supervised foreground implementation. Only runs 1 and 5 bore on #452's shipped stop-only text; run 1 used the first wording. These historical runs do not verify the new serial lifecycle.

- **Stop** (run 1) claimed nothing and reported `isolation unconfirmed`. That is the case that decides the loop's terminal state, and the run did not exercise §7.
- **The project-file case dispatched in parallel with the parent untouched** only after the text required `isolated: true` on the probe and every worker (runs 4 and 5).
  Before that edit the probe measured the shared tree and the model failed closed, which is the contract working and also a gap in the text, now closed.
- **The one-claim-per-tick serial rule was followed once it was stated** (runs 2, 3 and 4 claimed both; run 6 claimed one). A serial worker that actually ran was observed
  in runs 2 and 4 only; the Serial variant's own steps were not checked against the worker's commands.
- **Not shown:** a full tick, a claim through `issue-claim.sh`, the §2 redispatch path, §7 reaching STALLED from this hold (source-pinned, not run), the after-batch
  `omp-task-<id>` cleanup (the system temp directory was not inspected and cleanup was not exercised; the runs used the shell's default `TMPDIR`), `review_site: agent` on omp, Claude Code, and any model other than haiku.

**Operator configuration.** `config.yml` SHA-256 prefix `7b634967911b` before and after; `omp plugin list` `No plugins installed` before and after.
Only `ls ~/.omp/wt` and that hash were read under `~/.omp`.

**Not re-run after review.** Every §5 change made after the six runs was text and gate work and was not run through a model: the `isolated: true` rule moved into the reference doc and pointed at from `take-it` §5; §5 cut to its tick-specific differences; the outstanding-serial-worker precondition (later removed); serial records and close-from-live-state (later removed); the hold-root and stop-report wording; the `review` deferral (later removed); and **removal of serial mode, so an unconfirmed tick stops**, with the why-no-serial-mode paragraph and the simplified Reach; then the in-tick baseline capture, the omp `wait` on the batch's `task` results, the same-tick after-batch check, the timeout path and the omp scoping of all of it (with the §2-redispatch placement), and then the in-§2 omp redispatch with its own baseline, wait and check, replacing the earlier deferral of that redispatch into §5's batch (which §3's capacity stop would have starved). Run 5's push check was the runner's own `git ls-remote`, not the model's after-batch check.

### Verdicts for rows 3, 4, 5 and 6

| Row | Verdict | Evidence beside it |
| --- | --- | --- |
| 3 isolation | equivalent found, conditional on three settings the plugin cannot ship (`enabled: true`, `apply: false`, `merge: patch`) | Q4 transcript: private checkout, own branch, commit, push to `origin` all worked. Off by default (`task.isolation.enabled = false`). Check C and D2 (18.6.0): patch mode dirties the parent, `merge=branch` commits onto its current branch. D1 (18.6.0): `apply = false` leaves the parent untouched with the push verified. E1 (#453): `merge` is consulted under `apply = false`, and `branch` leaves a local branch `omp/task/<Name>` in the parent. P1 (#453): a committed `.omp/config.yml` that `omp config get` reflects drove the same untouched-parent run, with no profile write. See [Isolation contract (#426)](#isolation-contract-426) |
| 4 skill delegation | equivalent found (bare name) | `skill://take-it` resolves, `skill://sassy-dog:take-it` does not. Namespace only on collision |
| 5 plugin root | equivalent found; unchanged skills make a model search, and the shipped token-free paragraph stopped it in 3 of 3 runs on `github-issues` | `[Skill directory: ...]` on `/skill:` and the path header on `read skill://<name>/<path>`. The token itself is not substituted, and `CLAUDE_PLUGIN_ROOT` is not exported to the shell. Check A (18.6.0, this repo's `CLAUDE.md` in context): the agent ran the literal token, failed, then used `find`. #425, shipped `github-issues`, no context file: unchanged 2 of 2 used `find`; with a paragraph that also forbids searching (v2), 2 of 2 runs used the right root and none searched; a wording without that clause (v1) searched in its one run. #454, the token-free wording that ships, at the shipping placement: 3 of 3 runs used the right root with no token run and no `find` (first command succeeded in 2 of 3), and 2 of 2 runs of a reference-doc command did too, but not through the `PLUGIN_ROOT` preamble ([A‴](#token-free-paragraph-at-the-shipping-placement-454)). Design: [row 5](#row-5-claude_plugin_root-keep-the-token-add-a-root-resolution-paragraph) |
| 6 config injection | none as a load-time step; the unchanged skill still worked in 3 of 3 runs because the agent ran the line or read the file itself, and #455: unchanged `take-it` and `dispatch-ready` right in 12 of 12 runs, so the fallback paragraph shipped only in the four conservative-mode skills, absent branch run once | `read skill://take-it` shows the `` !`...` `` line verbatim, and the render path has no shell step. Check B (18.6.0, this repo's `CLAUDE.md` in context): an agent read the config by absolute path and acted on it. #425, shipped `send-it`, no context file: unchanged, file present twice and absent once, all correct; with a read-by-path paragraph, present and absent correct, the paragraph followed once. #455 (`take-it` and `dispatch-ready` unchanged, prompts that do not mention config, gh unauthenticated, dummy config): config present 6 of 6 used, config absent 6 of 6 `NO_CONFIG` and stop; the paragraph's absent branch on `send-it` reached `NO_CONFIG` once ([Config-fallback paragraph (#455)](#config-fallback-paragraph-455)). Design: [row 6](#row-6-config-injection-keep-the-line-add-a-fallback-paragraph-gate-the-stoppers-on-a-first-run) |

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
path twice on 18.6.0 (Check C): patch mode dirties the parent checkout and `merge=branch` commits onto its current
branch. #426 then ran `apply = false` (D1: parent untouched, push verified) and the default with a verified push (D2),
see [Isolation checks (#426)](#isolation-checks-426).

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
`read skill://<name>` and recovered by searching. #425 (out of tree, shipped `github-issues`) saw the same search in 2 of 2 unchanged runs and
none in the 2 v2 runs of a root-resolution paragraph that also forbids searching (the one v1 run, without that clause, searched). #454 shipped the token-free paragraph in every `SKILL.md` that carries the token and ran it out of tree: 3 of 3 runs used the right root with no `find` ([A‴](#token-free-paragraph-at-the-shipping-placement-454)); the design is under [Design for rows 5 and 6](#design-for-rows-5-and-6-425).

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
inside a skill, so that part stays unknown. #425 (shipped `send-it`, one model) found the unchanged skill still handled correctly in 3 of 3 runs, with the agent
running the line's command or reading the file itself; the design is under [Design for rows 5 and 6](#design-for-rows-5-and-6-425). #455 shipped the fallback paragraph in `send-it`, `survey-work`, `groom-backlog` and `tidy-repo`, and not in the four skills that stop on `NO_CONFIG`, after 12 of 12 unchanged runs of `take-it` and `dispatch-ready` were right ([Config-fallback paragraph (#455)](#config-fallback-paragraph-455)).

### 7. Per-repo config under `.claude/sassy-dog/`

**Used for.** The per-repo behaviour of every workflow skill. This is the data half of row 6.

**omp.** Not an omp concept. omp reads `.claude/CLAUDE.md` as a compatible context file
(`https://omp.sh/docs/context-files`) and finds skills under `.claude/skills/`
(`https://omp.sh/docs/skills`), but nothing documented reads `.claude/sassy-dog/`. The files are
plain Markdown, so any harness that can read a file can read them. The gap is how the content
reaches the skill (row 6), not the format. **Spike:** nothing changed; the row-6 result applies.

### 8. Plugin and marketplace declaration in `.claude/settings.json`

**Used for.** `setup-config` and `setup-repo` write `extraKnownMarketplaces` and `enabledPlugins`
into a consumer repo so local sessions on any machine resolve the plugin (it does not reach cloud
sessions or routines, #468). `repo-health`'s `SKILL.md`
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

## Design for rows 5 and 6 (#425)

This section records what #425 chose for the two mechanisms that gate every skill. It commits no option of "Options for the shape": both
designs below are an edit to skill text, which options B and D already allow. The operator still decides the shape. The evidence is the
[#425 section](#out-of-tree-checks-on-shipped-skills-425) (10 runs, one model, no context file) and Q2 and Q3. Nothing here was run in Claude Code.

### Row 5 (`${CLAUDE_PLUGIN_ROOT}`): keep the token, add a root-resolution paragraph

- **Replacement.** In each `SKILL.md` that carries the token (15 files, ``git grep -l CLAUDE_PLUGIN_ROOT -- 'skills/*/SKILL.md'``), add one paragraph
  immediately before the first fenced command that uses it (shipped by #454 in every file the derivation above lists; #425's tested edit sat above a later command, see **Open**). Claude Code substitutes the token and never needs the paragraph. On a harness that does not, the paragraph tells
  the agent where the plugin root is: take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of the skill, cut it at
  `/skills/<name>`, and use what comes before the cut as the root; write that absolute path into the command in place of the token; do not search for the script.
- **Evidence.** Unchanged skill: 2 of 2 runs searched with `find`, 1 of 2 first ran the literal token and failed (exit 127). With the "do not search" wording (v2):
  0 of 2 searched, 0 of 2 ran the token, and the root was right on the first try in 2 of 2, with the very first command succeeding in 1 of 2 (the other hit a stray
  argument from the prompt, not a path error). The weaker wording (v1, which only described the rule) still searched. That does not isolate the cause. v2 forbade searching, but it also told the agent where to cut the path and spelled out the resulting script path, and one v1 run cannot separate which of those changes mattered. #454's runs (token-free, no script path spelled, the do-not-search clause kept) used the right root and did not search in 3 of 3 runs, so the shipped wording works with its search clause and without the spelled-out script path. They did not run it without the clause, so what the clause contributes is still unmeasured.
- **A trap the tested wording has.** The v2 sentence spelled the token. Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` anywhere in a `SKILL.md`, so the
  sentence would be rewritten into a path in the middle of its own explanation. The shipped wording must refer to "the plugin-root placeholder in the command below"
  and never spell the token. That wording was run in #454: see [A‴](#token-free-paragraph-at-the-shipping-placement-454).
- **Why not the alternatives.** Relying on an environment variable fails: omp does not export `CLAUDE_PLUGIN_ROOT` to the shell, and the unset variable made the command a
  path under `/`. A search-based fallback works, but costs a failed command plus a `find` whose cost scales with the tree searched. A per-harness binding table
  (option A) has nothing to hold: the value is a path computed from the skill's own location.
- **Rules kept.** The token still expands only in `SKILL.md` and no reference doc gains it (`scripts/test-plugin-root-in-references.sh`). Reference docs keep taking the
  resolved path from the `SKILL.md` that invokes them, through their `PLUGIN_ROOT` preamble. #454 exercised that hand-off in 2 runs: the root reached the command, but the agents wrote the absolute path in directly and never set the variable, so the preamble was not the carrier. The `[Skill directory: ...]` form is named in the paragraph for
  interactive `/skill:` use but only the `[Skill file: ...]` form was seen under a model.
- **Open.** One model, 5 runs, two skills. #425's tested paragraph sat directly above the `--sites-of` block (about line 54 of the original file), while that skill's first token command
  is at line 22 and the token occurs 21 times. #454 ran the shipping placement (above line 22, `--sites-of` 35 lines below it) and it worked in 3 of 3 runs. Distances larger than that, other models, interactive `/skill:`, and the `take-it` (indented fence) and `send-it` (prose-only use) placements were not run. The reference-doc hand-off worked in 2 of 2 runs but not through the `PLUGIN_ROOT` preamble, see [A‴](#token-free-paragraph-at-the-shipping-placement-454).

### Row 6 (config injection): keep the line, add a fallback paragraph, gate the stoppers on a first run

- **Replacement.** Keep the `` !`...` `` line in the nine files that carry it (``git grep -l -E '^!`' -- skills agents``). That count is eight skills and
  `skills/setup-config/references/config-contract.md`, which documents the line. Under each skill's line, add a short paragraph: if the line reached you as text (it starts
  with `!` and shows a command, with no `CONFIG_SOURCE:` output beneath it), nothing ran it; read by absolute path the file the `!` line above names (`<repo root>/.claude/sassy-dog/<skill>.md`, and `take-it.md` for the two front-ends `work-recommendations` and `work-fire-watch`), the root from
  `git rev-parse --show-toplevel`; if the file does not exist the config is `NO_CONFIG`, handled as that state already is; **never read an unrun line as "no config
  exists"**. `NO_CONFIG` stays the first-class state it is today, and `take-it` and `dispatch-ready` still stop on it. This is a generalised later edit of the B″ text that ran (it adds `<skill>` and
  "handled as that state already is" and drops "Get the config yourself"); the B″ text is verbatim in the #425 section.
- **Evidence, and its limit.** The paragraph was followed once with the file present (read by absolute path) and the absent case gave `NO_CONFIG` (run 10, via the line's own command).
  But the **unchanged** skill was right in 3 of 3 runs, because the agent ran the line's command itself twice and read the file once. The prompts named the config and `NO_CONFIG`, and `send-it`'s own
  prose already mentions reading the config by absolute path in one case. So the paragraph was followed once with the file present, and its own absent branch was not exercised; the data do not show it is **needed**, for this model on this prompt.
- **Why not "keep Claude-Code-only".** Correct behaviour currently depends on an agent choosing to run a line it was shown as text. A cold worker in `take-it` or `dispatch-ready` that
  skips it would read a repo that has config as having none. For `take-it` and `dispatch-ready` that is a spurious stop. For the skills with a conservative
  `NO_CONFIG` mode (`send-it` among them) it is worse: the skill runs, and silently ignores the repo's own rules, such as its pre-flight commands. One paragraph per skill is cheap against that.
- **Why not remove the line or move it.** It is the Claude Code mechanism, `NO_CONFIG` as a first-class state depends on it, and row 7 shows nothing else in omp reads
  `.claude/sassy-dog/`. The `@path` include was not tried in a skill, so it stays an unknown.
- **Gate the stoppers on a first run; ship to the conservative skills regardless.** The eight skills split four and four. The four that stop on `NO_CONFIG` are `take-it`, `dispatch-ready` and the two
  front-ends that read `take-it.md` (`work-recommendations`, `work-fire-watch`). Run the unchanged `take-it` and `dispatch-ready` out of tree with a prompt that does **not** mention config, with the
  file present and absent, three runs each if the budget allows. If every unchanged run is right, the paragraph is dropped for those four. The four conservative-mode skills (`send-it`, `survey-work`,
  `groom-backlog`, `tidy-repo`) get it whatever that run shows, because their failure is the silent one above and no first run on a different skill shows it absent.
- **Status (#455).** Done as designed, narrowly: the paragraph is in the four conservative-mode skills (`send-it`, `survey-work`, `groom-backlog`, `tidy-repo`) and not in the four stoppers, because the first run the gate asks for came back right 12 of 12 (six unchanged runs each of `take-it` and `dispatch-ready`, config present and absent, prompts that do not mention config). Its absent branch was run once on `send-it` and ended in `NO_CONFIG`. Runs, wording and limits: [Config-fallback paragraph (#455)](#config-fallback-paragraph-455). `work-recommendations` and `work-fire-watch` were not run (their inclusion is the decision rule applied to `take-it`'s runs, not a measurement), and a different model or prompt could still skip an unrun line, which is why the stoppers' stop on `NO_CONFIG` is left as it was.
- **Rules kept.** The paragraph must not start a line with `` !` ``, since the row 6 grep counts such lines. It must not use a bare `$1` to `$9`, `$@` or `$*` in a `SKILL.md` body. It must not spell
  the plugin-root token. `config-contract.md`'s description of the injected line is updated in the same change, and the gates that read it (`test-doc-reconciliation.sh`,
  `test-gotcha-claims.sh`, per the table in `CLAUDE.md`) must stay green.

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
   spike found a path-resolvable equivalent for row 5 (a model recovered by searching, #440, and, in #425, used the right root in 2 of 2 runs with a paragraph that also forbids searching (v2; v1 searched), and #454 shipped a token-free paragraph and used the right root in 3 of 3 runs) and no
   load-time step for row 6 (a model ran the line or read the file itself, #425, and #455 shipped a fallback paragraph in the four conservative-mode skills after the four stoppers' first run was right 12 of 12). The designs are
   in [Design for rows 5 and 6](#design-for-rows-5-and-6-425).
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
path-resolvable equivalent: unchanged skills made a model search for the script, and with a paragraph that also forbids searching (v2), 2 of 2 runs used the right root and none searched; a wording without that clause (v1) searched in its one run (#425). The token-free wording that ships (#454) used the right root with no search in 3 of 3 runs (one model). Row 3 has a working isolation, and row 4 has a bare-name equivalent. Row 6
has no load-time step, but the unchanged `send-it` was still handled correctly in three runs because the agent ran or read the config itself (#425, one model). The dispatch family still cannot be called supported, because
no dispatch, isolation or delegation path has been run through a model for a real skill, and the settings that gate it are off by default or
consumer-owned (for row 3, `task.isolation.enabled: true`, `task.isolation.apply: false` and `task.isolation.merge: patch`, see the
[isolation contract](#isolation-contract-426); `task.maxRecursionDepth` gates only `review_site: agent`, which the contract pins away). The #440 checks ran toy probe skills and
two isolated `task` calls. #425 ran two shipped skills (`github-issues`, `send-it`) on a narrow probe that stopped before any workflow step. That is
not an end-to-end run, so the README matrix keeps its `not supported` and `untested` cells unchanged. What changed is the reason given for them, and that is updated beside the matrix.

**Go/no-go for #425 (plugin root and config injection).** **Go on both, as small edits to skill text, with a first-run gate on row 6.** #425 repeated A and B
out of tree on shipped skills, with no context file in the prompt (see the #425 section), one model, 10 runs. **Row 5: go, and done by #454, which shipped the token-free wording in every `SKILL.md` that carries the token after re-running it at the shipping placement.** Unchanged, the agent searched for the script in 2 of 2 runs and ran the
literal token first in 1 of 2. With a paragraph that resolves the root from the `[Skill file: ...]` header and also forbids searching (v2), the root was right on the first try in 2 of 2 runs and nothing
searched; a wording without that clause (v1) searched in its one run. The paragraph must not spell the token, because Claude Code would substitute it inside the paragraph. #454 ran that token-free wording at the shipping placement (3 of 3 runs on `github-issues` used the right root with no token run and no `find`) and
checked once in Claude Code that the paragraph is inert there; the paragraph's placement in every token-carrying file other than `github-issues` and `pr-shepherd` was not run through a model, and `scripts/test-plugin-root-paragraph.sh` pins its text and placement.
**Row 6: go, narrowly, and done by #455.** There is no load-time step, but the unchanged skill was right in 3 of 3 runs (#425), so the data did not show the fallback paragraph is needed. #455 then ran the unchanged `take-it` and `dispatch-ready` on prompts that do not mention config, 12 runs, config present and absent, and every run was right, so the paragraph is **not** in the four skills that stop on `NO_CONFIG` (`take-it`, `dispatch-ready`, `work-recommendations`, `work-fire-watch`). The four conservative-mode skills (`send-it`, `survey-work`, `groom-backlog`, `tidy-repo`) carry it regardless, because their failure is silent, and its absent branch was run once on `send-it`: `NO_CONFIG`. One model, three runs per cell, gh unauthenticated: see [Config-fallback paragraph (#455)](#config-fallback-paragraph-455). An unexecuted line must still never be read as "no config exists", and `NO_CONFIG` stays first-class.

**Go/no-go for #426 (isolation contract).** **Go for the contract, no-go for running parallel workers on omp today.** The contract's
configuration is `task.isolation.enabled: true`, `task.isolation.apply: false` and `task.isolation.merge: patch`. `take-it` now confirms
it (#451, [Isolation confirmation runs (#451)](#isolation-confirmation-runs-451)); `dispatch-ready`
confirms it once per tick (#452). #484 adds guarded synchronous serial execution when parallel
isolation is unavailable; see [the current tick contract](#dispatch-ready-the-tick-its-terminal-state-and-its-reach-452).
That does not certify the whole parallel dispatch/review/merge workflow on omp.
The configurations that can pass step 2 are a project-level file, `PI_CONFIG_FILES` and
profile-set values; of those only a committed `.omp/config.yml` has driven a run (P1, #453; again in #451 with two workers in one `task` call, overlap not measured), and profile-set values have not.
The worker-owns-a-branch-and-pushes design works inside omp isolation (Check C2, D1 and D2: the worker's push was
confirmed by `ls-remote` in all three runs that used an absolute remote; Q4's 18.5.1 direct-function transcript showed the
pushed branch under `remotes/origin/`). The parent never receives the worker's branch name.
**D1 answers the question #440 left open:** with `apply = false` the parent kept its branch, `HEAD` and a clean tree, the
push landed, and omp left the change as a patch file nobody applies. Both `apply = true` modes change the parent (D2 and
Check C). What a skill cannot do is read a `--config` flag's value: `omp config get` ignores it (see
[Isolation checks (#426)](#isolation-checks-426)), but it does reflect a project-level file and `PI_CONFIG_FILES`
([#453](#isolation-settings-sources-453)), so confirmation is a read of those plus a behavioural probe, as
[Isolation contract (#426)](#isolation-contract-426) specifies. #453 also found that `merge` is consulted under `apply = false`
(E1: `merge: branch` leaves a local branch `omp/task/<Name>` in the parent, not a patch) and that the parent's branch, `HEAD` and tree stay put. The evidence is one run per mode with one model.
`review_site: agent` cannot work on omp without raising `task.maxRecursionDepth`, so the contract pins `coordinator` for omp.
The implementation issues are #451 (`take-it`) and #452 (`dispatch-ready`); both are implemented.

Candidate follow-up issues, for the operator to accept or drop:

1. Done: the omp spike (#424), recorded above.
2. #425: done as a design (see [Design for rows 5 and 6](#design-for-rows-5-and-6-425)). The row 5 root-resolution paragraph is done (#454, every `SKILL.md` that carries the token, plus `scripts/test-plugin-root-paragraph.sh`). The row 6 fallback paragraph is done (#455: the four conservative-mode skills, after a first run on `take-it` and `dispatch-ready` showed the four stoppers did not need it).
3. #426's parallel contract is implemented by #451 (`take-it`) and #452 (`dispatch-ready`). Their historical model runs are recorded above. #484 replaces #452's stop-only fallback with synchronous guarded serial execution, without changing the parallel settings/probe contract. Project-level files, `PI_CONFIG_FILES` and profile-set values remain the supported settings sources; the plugin never writes an operator profile to enable isolation.
4. Bare agent and skill names on omp (`subagent_type` and `Skill: sassy-dog:<name>` sites), which
   neither #425 nor #426 covers.
5. A README note that a repo's `.claude/settings.json` declaration does not install the plugin on omp.

## Isolation contract (#426)

What `take-it` and `dispatch-ready` need from a harness before they may run workers in parallel. They are the two
parallel-worker sites among row 3's four files; `repo-cleanup` and `pr-shepherd`'s teardown reference only clean up after
them. Row 3 is the mechanism and [Isolation checks (#426)](#isolation-checks-426) the evidence. This section **specifies**
a contract. `take-it` implements its confirmation sequence ([#451](https://github.com/Sassy-Dog/skills/issues/451),
`skills/take-it/references/isolation-confirmation.md`, read before claims);
`dispatch-ready` implements it once per tick ([#452](https://github.com/Sassy-Dog/skills/issues/452)).
`scripts/test-isolation-contract.sh` pins these instructions' prose, including the serial fallback
added by #484, and `scripts/test-checkout-guard.sh` executes the guard they call. Claude Code satisfies parallel isolation through
`isolation: "worktree"`, a linked worktree under `.claude/worktrees/` that the coordinator tears down
(`skills/pr-shepherd/references/worktree-teardown.md`).

### The contract

A harness may run workers in parallel only if, for each worker:

1. **Own branch and working tree.** The worker edits files in a tree that no other worker and not the coordinator's
   checkout shares, and creates its own branch there.
2. **Commit and push.** The worker can commit and push that branch to the repo's remote (`origin` resolves from inside the
   tree), which is how it opens its PR.
3. **Parent untouched.** Nothing the worker does moves the coordinator's checkout: not its branch, `HEAD`, index or working
   tree. A change the worker already pushed must not also appear in the parent, or a coordinator that then merges the
   pushed branch meets the change twice (Check C and D2).
4. **Teardown.** The coordinator can remove the worker's tree, or the harness removes it, and no tree is left that a later
   run could mistake for live work.

Requirement 1's "no other worker shares it" is inferred from the per-task `<id>` in the checkout path; no run had two
concurrent workers (#451 dispatched two in one `task` call; their overlap was not measured).

### What omp 18.6.0 needs to satisfy it

| Requirement | omp setting | Evidence |
| --- | --- | --- |
| 1 and 2 | `task.isolation.enabled: true` (default `false`, which shares one checkout silently) | Q4 (18.5.1, functions called directly), D1 and D2 (18.6.0, model-driven): private checkout at `~/.omp/wt/<id>/m`, own branch, commit, verified push |
| 3 | `task.isolation.apply: false` (default `true`) and `task.isolation.merge: patch` (the default) | D1 and P1 (`merge: patch`): parent `main` at the same `HEAD`, clean `git status`. E1 (`merge: branch`): the same, plus a new local branch `omp/task/<Name>` in the parent. D2 (defaults `apply: true`, `merge: patch`): parent `f.txt` modified. Check C2 (`apply: true`, `merge: branch`): a different commit on the parent's branch |
| 4 | none; omp removes the checkout. With `apply: false` it still leaves `<tmp>/omp-task-<id>/` (the patch plus a `.json`, `.jsonl` and `.md`) in the system temp directory, which the coordinator must remove, but only after the worker's push is verified with a fresh `git ls-remote` in the same step, because that directory holds the only remaining copy of a change from a worker that did not push; under a `dispatch-ready` loop that is one leftover temp directory per worker | D1, D2, E1 and P1: `ls ~/.omp/wt` held 0 entries after each run. With `apply: false` the temp directory existed after D1, E1 and P1 and I removed each by hand. E1 (`merge: branch`) left a `.patch` there too, and a local `omp/task/<Name>` ref in the parent that nothing removes (see below) |

`merge` is consulted when `apply` is false (E1, [#453](#isolation-settings-sources-453)), but only to pick the artifact:
`merge: patch` leaves a patch file (D1, P1) and `merge: branch` leaves the worker's commits on a new local branch
`omp/task/<Name>` in the parent, at the pushed commit, **not merged**. Neither moved the parent's current branch, `HEAD` or tree.
**The contract pins `merge: patch`.** Under `merge: branch` omp's `commitToBranch` (**source**, `src/task/worktree.ts`) fetches
the worker's commits into the parent as a local `refs/heads/omp/task/<id>` ref with a `+HEAD:` force refspec (the source
comment says it overwrites a stale branch from a prior run). That is one extra ref in the coordinator's repo per worker
name, left behind (E1), that no step of the contract or of omp's cleanup removes, and the step 3 comparison of branch, `HEAD`
and `git status` does not see it. `merge: patch` left no ref (D1, P1). **omp therefore satisfies the contract natively only
when `enabled: true`, `apply: false` and `merge: patch` are all read**, in the profile or, per P1, in a project-level file. Qualifier: one run per setting, one model, one worker at a
time, macOS with `isolation.backend: auto`. `gh pr create` from inside the isolated checkout was never run, because the
scratch repos had no GitHub remote. The plugin cannot ship these settings. A consumer repo can set them in a committed `.omp/config.yml`, which is the only
non-profile source that has driven a run (P1, one run, one worker; see "What this does not show" in
[#453](#isolation-settings-sources-453)). With `apply: false`
omp writes a patch file into the system temp directory and applies nothing, which is right for a worker that pushed its own
branch. A worker that did *not* push loses its change from every branch, so the worker prompt's push step is a dependency of the contract.

### How a skill confirms the contract before a parallel dispatch

`omp config get task.isolation.enabled`, `omp config get task.isolation.apply` and `omp config get task.isolation.merge` read the merged value of the profile,
a project-level file (`.omp/config.yml`, `.omp/settings.json`, `.claude/settings.json`) and `PI_CONFIG_FILES`, and ignore the
`--config` flag ([#453](#isolation-settings-sources-453)), so they are necessary and not sufficient. In order, the first failure stops the parallel dispatch:

1. **Harness known?** On Claude Code, `isolation: "worktree"` is the contract, and nothing below applies. On omp, continue.
   On an unrecognised harness, treat isolation as unconfirmed and fail closed (below).
2. **Read the settings.** On omp, run the three `omp config get` commands from inside the repo. `enabled` not `true`, `apply`
   not `false`, or `merge` not `patch`, means unconfirmed (an unset `merge` reads `patch`, and P1 ran that way). Because `omp config get` ignores the `--config` flag, settings supplied **only** by that
   flag can never pass this step; the passing sources are a committed project-level file, `PI_CONFIG_FILES` or the profile.
   **A committed `.omp/config.yml` with `task.isolation.enabled: true` and `apply: false` passed this step and drove a run
   (P1) with no profile write**; that is the only non-profile source that has driven a run (one run, one worker). Not run:
   profile-set values, a project file that disagrees with the profile, an untracked project file, and concurrent workers. A passing read can still be overridden at run time by a `--config` flag, hence
   step 3.
3. **Probe, against a `--config` flag or other source overriding a passing read.** Step 2 fails closed on flag-only settings, so this
   step runs only after step 2 passed; it guards against a `--config` flag or another source overriding those values. Before the first parallel batch, dispatch **one** worker, with `isolated: true` on its `task` entry (a `task` entry without it runs on the shared tree whatever the settings read; `skills/take-it/references/isolation-confirmation.md` owns that rule), whose only
   job is to report `pwd` and `git rev-parse --show-toplevel`, and compare them with the coordinator's own. The same path
   means isolation is off. This probes requirement 1 only. Requirement 3 rests on the `apply` and `merge` reads in step 2 and on the
   coordinator comparing its own branch and `HEAD` before and after each batch, as well as `git status`: `merge: branch`
   leaves the parent clean with `HEAD` moved (Check C2). A moved branch or `HEAD`, or a dirty tree, after a worker returned
   means unconfirmed, and no further batch is dispatched.
4. **Record the outcome** in the batch manifest (`.git/take-it-batch.json`, `.git/dispatch-ready-batch.json`) so a later tick
   does not start from nothing.

`take-it` implements these steps (#451, `skills/take-it/references/isolation-confirmation.md`); `dispatch-ready` implements them
per tick (#452): it re-reads the settings and re-probes every tick rather than reusing a recorded `confirmed`, because a tick shares no memory with the last. Two model-driven runs followed the `take-it` text on omp (see [Isolation confirmation runs (#451)](#isolation-confirmation-runs-451)):
the probe and the `omp config get` reads ran when the model was prompted with the §5 text, in the project-file run. The probe costs one extra dispatch per invocation on an unconfirmed harness.

### Fail closed

**Where isolation is unconfirmed, the skill never dispatches parallel workers on a shared tree.** It has two permitted
outcomes and takes the first that applies:

- **Serial.** Both dispatchers reuse take-it's Serial variant and the synchronous lifecycle in
  `skills/take-it/references/isolation-confirmation.md`. An atomic durable guard in the Git common
  directory is acquired before reconciliation, fetch, branch switches, merges or teardown.
  A supervised foreground worker must actually exit; its PR, terminal comment or clean tree is
  not termination evidence. Initial branches start from freshly fetched origin/default; recovery
  resumes the existing attempt branch. Dirty, unpushed and uncertain work is never stashed/reset.
  The coordinator independently verifies exact remote tips before switching or releasing.
  `dispatch-ready` runs at most one serial issue per tick, including a §2 recovery; take-it may
  complete its independent list one by one. Neither serial path accepts a stacked chain.
- **Stop dispatch.** Where ownership, clean/published work or foreground supervision cannot be
  verified, claim nothing and report the specific safety hold. No TTL expires ownership and no
  operator-profile write makes the check pass. A missing worker result remains unresolved.

A skill never degrades silently from parallel to a shared tree. The failure this rule exists for is workers that look like
they worked while overwriting each other.

### `review_site: coordinator` on omp

Pin `review_site: coordinator` (what an absent key already selects) for omp. Under `agent` the worker sits at `task` depth 1
and `pr-review-orchestrator` at 2, and an agent **at** depth `task.maxRecursionDepth` (default 2) has no
`task` tool (the gate is the agent's own depth, `taskDepth < maxRecursionDepth`), so the orchestrator cannot dispatch the nine reviewers (Q5 "Depth", **source**; not run through a model).
Raising `task.maxRecursionDepth` to 3 is a consumer-side setting the plugin cannot ship. A skill on omp that finds
`review_site: agent` in config treats it as unsatisfied, uses `coordinator`, and says so in its report.

### `dispatch-ready`: the tick, its terminal state and its reach (#452)

The isolation settings/probe are still re-derived per tick, before claims. Claude Code keeps
its existing `Agent` worktree behavior. A confirmed omp batch still uses `isolated: true`,
captures its coordinator baseline, waits for its actual returns and performs the after-batch
check. A safe unconfirmed checkout instead runs one foreground serial worker to completion,
bounded by `--timeout 3600` because an unattended tick must end; a timeout retains the guard and
reaches DRAIN STALLED through the ownership hold. The omp bash call that runs it passes
`timeout: 0`: on omp 18.8.5 a bash tool call defaults to a 300s deadline and caps any other value
at 3600s, and a tool deadline that fires first kills the supervisor while its worker, in its own
session, keeps writing unsupervised. A refused acquisition (dirty or unpushed
checkout, guard unavailable) blocks reconciliation just as completely, so it takes that hold's
in-flight waiver rather than ticking forever behind in-flight PRs.

**Terminal-state decision: an unsafe serial prerequisite or an ownership hold ends the loop through DRAIN STALLED, and no fifth state is added.** #452 first made a stopped tick (isolation unconfirmed, no serial mode) STALLED with the hold root `isolation unconfirmed`, so the loop could self-cancel instead of reporting the same sentence every tick, the shape of the #282 bug that `scripts/test-drain-terminal-states.sh` records. #484 replaced that hold rather than adding to it: disabled isolation with a safe serial path is progress, so STALLED's third conjunct now reads "held by a §4 filter or a verified §5 execution-safety gate", and an ownership hold (a checkout guard with no live worker) waives in-flight zero, recorded with the root `checkout ownership <created_at>`, as does a refused acquisition, recorded with `checkout refused <exit code> <branch>`. The route is still the one that gate's header names, to widen an existing state's conjunct, and the reasoning is unchanged:

- **Not DEFERRED.** DEFERRED is for a hold this checkout can never clear (a `site:` label naming another machine) and takes no confirmation tick. An operator can clear either hold from this checkout, so each is a hold a human could clear, which is STALLED's definition.
- **Not a fifth state.** It would be STALLED under another noun: the same conjuncts, the same stop path and cron self-cancel, and one more count and canon entry that would not behave differently.
- **The two-tick confirmation is wanted, not tolerated**, so one unverified tick cannot end a healthy loop; the same guard on the next tick does.
- **Confirmed and serial ticks are unaffected**: they dispatch, which deletes any stall record and resets the clock. A live worker (`ownership=active`) is self-resolving and writes no record.

**Ownership precedes §2, not merely §5.** Every non-Claude coordinator, even one expecting
parallel isolation, acquires the shared checkout guard before reconciliation can switch,
fast-forward, merge or tear down. A contender cannot claim or mutate. This is cooperative
exclusion, not a sandbox against arbitrary human commands or older plugin callers.

**Recovery remains in §2, before capacity.** An eligible pending recovery uses the same runner
and consumes the tick's one-worker quota. Its authenticated reservation becomes started just
before launch and finished only after real worker termination; it keeps `recovery_used=1`.
No new §5 issue is claimed after that recovery. A started/uncertain attempt never gains a retry
by observing a missing PR, blocked issue or elapsed timer.

**Release is verification, not cleanup.** `checkout-guard.sh verify` establishes positive
termination, a clean checkout and fresh exact remote tips for every run branch before further
local mutation. `release` repeats those checks and archives a receipt. It deletes no branches
or worker artifacts. Return to the clean published default before release; a later server-side
merge may delete the issue branch. take-it releases the verified worker epoch and acquires a
fresh merge epoch before merging, so server auto-deletion cannot erase required worker evidence.
A clean default behind upstream may acquire and fast-forward safely; ahead/diverged work is
retained. Interrupted/timed-out/uncertain runs retain their durable guard for operator
investigation; automatic force-unlock is deliberately absent. A refused acquisition archives
the guard it had just published, since no token or worker exists yet. A coordinator that dies
holding the token leaves a `held` guard no later caller can tell from a live one: dispatch-ready
escalates it to STALLED across two ticks, and only an operator runs `checkout-guard.sh abandon
--reason`. That command needs no token, but for `held`/`completed` (or `uncertain` with no runs)
it repeats every `verify` check before archiving. Any other phase, or an unreadable record, needs
`--investigated` after the operator runbook in the reference: the attestation stands in for the
durable termination record alone, while every recorded process must be gone now and the tree
clean with exact pushed tips. Neither form is a force-unlock. A worker that failed before
creating its branch committed nothing, so that branch needs no tip check and cannot hold the
checkout forever.

**Terminal states still describe the drain, not isolation settings.** Disabled isolation with
a safe serial path is progress, not STALLED. A known unsafe serial prerequisite is a named
execution-safety hold. An active writer is self-resolving. A guard with no live worker, held or
unresolved, is an ownership hold: it proves no COMPLETE, DEFERRED or DEGRADED verdict, but the
same guard on two ticks confirms STALLED. Only a `status` read that itself fails proves nothing. Existing Ready-only, dependency, collision,
migration, claim, review and merge safeguards remain applicable.

### Safe serial runtime checks (#484)

`scripts/test-checkout-guard.sh` is the behavioural gate: it runs real foreground processes in
temporary Git consumers with local bare remotes, with no model, GitHub or network. It covers
cross-worktree contention before reconciliation, token rejection, dirty acquisition,
behind-default fast-forward, sequential verified pushes, server branch deletion after archival,
missing/stale remote tips and dirty failure (its `Ownership` suite), and a live worker beside a
terminal-failure comment, a killed supervisor, an actual runner timeout, the timeout signal,
competing runners, foreground tool groups that exit and a surviving tool group that must retain
ownership (its `Lifecycle` suite). Since #486 the guard lives in `skills/pr-shepherd/scripts/`
and exposes a read-only `check` that `teardown.sh` and `merge-shepherd.sh` run before any local
mutation; its `Check` suite covers no guard, a matching `SASSY_DOG_CHECKOUT_TOKEN`, a missing or
wrong token, a live writer, an argv token being ignored and unresolved state, each refusal proved
against a mutant, and `scripts/test-teardown-args.sh` (property 7) shows `teardown.sh` leaving
branches, HEAD and the worktree list untouched while a guard is held and proceeding once the
token matches. It does not claim to verify the model's §7 judgement.

The prose gates stay what they were. `scripts/test-isolation-contract.sh` pins the isolation
contract: the parallel path (#451, #452) unchanged, and #484's serial fallback, its ownership
holds and its refusal to write an operator profile. `scripts/test-drain-terminal-states.sh` pins §7's
terminal-state canon, re-derived for the blocks #484 added or reworded, plus the execution-safety
and ownership holds that replaced #452's `isolation unconfirmed` hold. Neither gate was loosened:
only the text #484 intentionally replaced was re-pinned.

The foreground CLI is a distinct API from `task`: on omp 18.8.5, `omp --model @task` failed with
`Model "@task" not found` before any worker ran. The serial contract therefore resolves the
configured task model (configured default fallback, reported) to a concrete CLI selector before
claiming. It excludes the `task` tool and prohibits detached commands. Process-group supervision
cannot prove absence of a deliberately escaped process; cooperative foreground execution is
part of the worker contract, not a sandbox claim.

An actual foreground omp worker also exposed two defects in the draft. Shell tool calls used
separate process groups even with `--no-pty`; rejecting every new group held a successfully
pushed worker forever. The guard now records observed groups and verifies their termination.
The draft's `git switch -c --no-track <branch> <start>` failed because `-c` consumed
`--no-track` as its branch argument; the Serial variant now puts `--no-track` before `-c`.
The failed invocation preserved its checkout and retained ownership when its assigned branch
did not exist. A CLI exit of zero was correctly not treated as implementation or push success.

The model-backed scratch runs used **omp 18.8.5 on macOS arm64**, the working-tree plugin
loaded with `--plugin-dir`, and project isolation disabled. Each consumer had a real local
bare remote, two independent Ready issues and a third dependent on the first. A stateful `gh`
fixture supplied only that disposable board; Git commits, pushes, process supervision and
remote-tip checks were real. GitHub tokens were removed from the subprocess environment and
its `gh` adapter had no production fallback. The configured task model was absent, so the
reported concrete default fallback was `openai-codex/gpt-6-astra:xhigh`.

|Scenario|Observed result|
|---|---|
|Clean initial tick|Claimed only #7; worker changed `alpha.txt` to exact `enabled\n`, committed and pushed `1a40e350f8ffdee2add497acad03f704fdb433c9`, and opened fixture PR #101. #8 remained Ready/unclaimed; #9 remained dependency-held. Real exit and fresh remote tip verified; returned to `main`, released ownership.|
|Concurrent tick during that worker|Acquire exited 3 before reconciliation, reporting an active writer. The contender claimed nothing, started no worker, switched no branch and performed no merge or cleanup.|
|Pending recovery at capacity 1/1|Recovered #7 before the capacity stop, repaired a missing newline and pushed `0f43e0d87998478f58c9ab85a88ffc57c81df53e` to existing PR #101. One reservation moved pending → started → finished with `recovery_used=1`; no new issue or replacement PR. Actual termination/push verified and ownership released. This run preceded the explicit return-to-default wording; the initial-tick run above exercised that final wording.|

The parent independently checked Git objects against fresh `ls-remote`, exact file bytes,
the fixture claims/PRs and archived real-process receipts; the workers' summaries were not
the evidence. Both progress runs reported serial mode, not STALLED.

**Limits:** GitHub was fixture-backed, PR checks deliberately stayed pending, and review used
an explicit fixture-only opt-out. These runs prove neither live GitHub review/merge nor a full
drain's terminal-state judgement. The existing parallel settings/probe and Claude Code path
remain unchanged; neither received a new model-backed execution in this verification. The
README therefore keeps full-flow support untested rather than certifying it from this smoke.

## Not read

The four pages the first pass skipped were read in #424 and are summarized under "What omp's remaining
pages say": `https://omp.sh/docs/env`, `https://omp.sh/docs/hooks`, `https://omp.sh/docs/slash`,
`https://omp.sh/docs/custom-tools`. `https://omp.sh/docs/subagents` was re-read for the task and
isolation parameters. What is still **not** read or tried: the `@path` include inside a skill, the
hook file format, and the other pages of omp's bundled docs index (134 files, listed by
`omp read omp://`), which hold far more than the website summaries gave.
