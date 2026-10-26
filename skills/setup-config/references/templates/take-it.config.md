<!--
CONFIG TEMPLATE: take-it — see survey-work.config.md header for render rules.
review_site uses the resolved Phase 1 choice (including an override), never an optional omission;
on refresh carry the chosen value forward. Site/stack slots below require the existing interview
consent; migrations and claim_label render only when applicable (config-contract.md inventory).
Drop THIS block from the rendered output. The comment below `## subagent-rules` is NOT part of it:
that one sits after the frontmatter, is body prose, and RENDERS into the consumer config on
purpose — the same shape as the commented "... go here." placeholders a config carries under its
other prose headings. It is the only place a reader of a generated config learns that a rule list
starting at `4.` is complete (Sassy-Dog/skills#373); dropping it puts the defect back.
(Never write a literal comment terminator inside EITHER of this file's comment blocks — this one, or
the one below `## subagent-rules`, which is the block that invites editing. HTML comments do not
nest, so an inner terminator closes its block early: here that turns the frontmatter's `---` into a
setext heading, and there it spills the rest of the explanation into the consumer config as visible
prose. markdownlint catches the first. Nothing catches the second.)
-->
---
stack_summary: >
  {{STACK_SUMMARY}}
preflight_commands: |
  {{PREFLIGHT_COMMANDS}}
pr_template_sections: {{PR_TEMPLATE_SECTIONS}}
merge_queue: {{MERGE_QUEUE}}
review_site: {{REVIEW_SITE}}

# optional

claim_label: {{CLAIM_LABEL}}
execution_site: {{EXECUTION_SITE}}
stacked_prs:
  max_depth: {{STACK_MAX_DEPTH}}
board:
  number: {{BOARD_NUMBER}}
  owner: {{BOARD_OWNER}}
  project_id: {{BOARD_PROJECT_ID}}
  status_field_id: {{BOARD_STATUS_FIELD_ID}}
  ready_option_id: {{BOARD_READY_OPTION_ID}}
  backlog_option_id: {{BOARD_BACKLOG_OPTION_ID}}
  in_progress_option_id: {{BOARD_IN_PROGRESS_OPTION_ID}}
migrations:
  dirs: {{MIGRATION_DIRS}}
  regen_command: {{MIGRATION_REGEN_COMMAND}}
codegen:
  hint: {{CODEGEN_HINT}}
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

## extra-guardrails
