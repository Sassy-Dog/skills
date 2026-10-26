---
stack_summary: >
  A Claude Code plugin marketplace: Markdown skills + reviewer agents with bundled Bash scripts.
  No build or test step — correctness means valid frontmatter plus instructions that actually work
  when the skill is invoked.
preflight_commands: |
  bash scripts/preflight.sh
pr_template_sections: [Summary, Changes, Verification]
merge_queue: true
claim_label: in-progress
review_site: coordinator
---

## subagent-rules

<!--
Repo-specific implementation rules for a take-it sub-agent go here — free text from the interview,
usually a blockquoted numbered list. By convention the first rule is numbered `4.`, not `1.`

Why: take-it hands each sub-agent one self-contained prompt whose step 4 directs it to read this
section (`skills/take-it/SKILL.md`, "Sub-agent prompt template"). The prompt spends its first three
steps before that — stay inside your worktree · read the issue · implement per `AGENTS.md` — so
rules written here continue its numbering from 4 rather than restarting at 1 and reading as a
competing list.

Note where that leaves you as a reader: the prompt's steps 1-3 are in the SKILL, not in this file,
so nothing beside these rules accounts for the numbers they start at. That distance is the whole
problem — the explanation below has to work for someone reading this config standalone, who never
sees the prompt at all.

**A list here that starts at 4 is COMPLETE.** There are no items 1-3 in this file, and there never
were; nothing is being withheld from the agent reading it. That is the whole reason this comment
exists: a numbered list beginning at 4 reads as truncation, and a dispatching session has already
acted on that misreading — telling two cold worktree agents that items 1-3 were absent from the
config, a mitigation for a gap that did not exist (Sassy-Dog/skills#373). Keep this
comment when you add rules; it is what tells the next reader the list is whole.

Two things that keep the above true rather than merely tidy:

- The convention is "continue the prompt's numbering". `4.` is where that lands while the prompt
  opens with three steps ahead of this section; renumber the prompt and the start number here moves
  with it. The reader rule does not move: this section never has items above the one it starts with.
- Nothing parses these numbers. They are prose, carried across verbatim on every config refresh
  (`setup-config/references/update-mode.md`), and step 4 points the agent here rather than pasting
  the list into the prompt — so the numbering is a reading aid for a human, never a mechanism.
  Starting at 1, or using bullets, is equally valid; it only loses the continuity.
-->

> 4. **README/version sync**: if you add or remove a skill (`skills/*/SKILL.md`) or reviewer agent
>    (`agents/*.md`), update `README.md`'s plugin/skill table, agent list and `### Harness support` matrix in the same PR. **Do
>    not stamp `version` in `.claude-plugin/plugin.json`.** Stamping is release-only, in a dedicated
>    `chore(release)` PR (`docs/VERSIONING.md`). A stamp inside a feature PR puts the manifest in
>    every issue's touch-set and serializes `dispatch-ready` (#296).
> 5. **No bare positional tokens** (`$1`–`$9`, `$@`, `$*`) in any `SKILL.md` body — CI greps for
>    them. Skill bodies are arg-substitution surfaces. Use `cut -f1` / `%(format)` idioms, or move
>    the snippet into `references/` or a bundled script.
> 6. **Sweep every claim your change makes untrue.** Many facts here are stated in several files.
>    For each sentence you change (a rule, a measured behaviour, a count, what a file does), grep
>    the tracked tree for its old wording and its key nouns, and fix or delete every stale hit in
>    this PR. Point at a fact's one home instead of restating it, and never copy a gate's header
>    into prose. That applies even if the issue body asks for a restatement: point at the home
>    instead, and say in the PR body that you did. If a stale claim is too large to fix in this PR,
>    name it in the PR body rather than leaving it unmentioned. List the phrases you grepped under
>    Verification.
> 7. **Test what you add on its failure paths, in committed cases.** For any script, guard or
>    self-check this PR adds or changes, each error path (a failing tool, empty input, a scratch
>    directory that cannot be created) gets a case in the gate that covers it, committed in this
>    PR. A manual run does not count, because nothing re-runs it. Every shape its header says it
>    catches gets a case, and every shape it misses is named in the header. A header must not claim
>    more than its committed cases prove. `AGENTS.md` says how a new gate is wired and kept safe to
>    run in parallel.

## extra-guardrails

<!-- Additional take-it guardrails go here. -->
