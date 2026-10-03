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

> 4. **README/version sync**: if you add or remove a skill (`skills/*/SKILL.md`) or reviewer agent
>    (`agents/*.md`), update `README.md`'s plugin/skill table, agent list and `### Harness support` matrix in the same PR. **Do
>    not stamp `version` in `.claude-plugin/plugin.json`.** Stamping is release-only, in a dedicated
>    `chore(release)` PR (`docs/VERSIONING.md`). A stamp inside a feature PR puts the manifest in
>    every issue's touch-set and serializes `dispatch-ready` (#296).
> 5. **No bare positional tokens** (`$1`–`$9`, `$@`, `$*`) in any `SKILL.md` body — CI greps for
>    them. Skill bodies are arg-substitution surfaces. Use `cut -f1` / `%(format)` idioms, or move
>    the snippet into `references/` or a bundled script.

## extra-guardrails

<!-- Additional take-it guardrails go here. -->
