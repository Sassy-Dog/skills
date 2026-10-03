---
pr_template_path: ".github/PULL_REQUEST_TEMPLATE.md"
pr_template_sections: [Summary, Changes, Verification]
preflight_commands: |
  bash scripts/preflight.sh
merge_queue: true
---

## extra-gates

**Merge policy note** — `main` has a **merge queue** (squash method). Enqueue with
`gh pr merge --auto`, with **no** method flag and **no** `--delete-branch` — GitHub rejects
`--delete-branch` outright when a queue is enabled, and `deleteBranchOnMerge` is on, so cleanup is
automatic. Confirm `isInMergeQueue` after enqueuing. PRs run the `CI` workflow (job `ci`), required
by branch protection on `main`; `ci.yml` carries the `merge_group` trigger, without which queue
entries strand.

**PR body** — `.github/PULL_REQUEST_TEMPLATE.md` carries these sections; fill it rather than
composing a body from scratch, and keep the sections in its order:

- **Summary** — what and why, one short paragraph
- **Changes** — bullet list of skills/agents/scripts touched
- **Verification** — how it was exercised (e.g. `claude --plugin-dir ~/Repos/sassy-dog/skills`
  plus invoking the skill), or why not applicable

**README/version sync gate** — if the diff adds or removes a skill (`skills/*/SKILL.md`) or reviewer
agent (`agents/*.md`):

- `README.md`'s plugin/skill table, agent list and `### Harness support` matrix must be updated in the same PR.
- `.claude-plugin/plugin.json` `version` is **not** stamped in a feature PR. Stamping is
  release-only, in a dedicated `chore(release)` PR when the daily reminder reports **due**
  (`docs/VERSIONING.md`; stamp-in-PR was weighed and rejected in #296 because it would put the
  manifest in every issue's `touches:` line and serialize `dispatch-ready`). Never hand-edit it —
  `bash scripts/stamp-version.sh` is the only writer, one-way CalVer ratchet.

**Post-merge plugin update reminder** — consumer machines do NOT pick up changes automatically,
and a `version` bump is NOT the trigger: content lands on `main` on every merge while the manifest
is stamped only by a dedicated release PR, so a cached copy and `main` routinely share one `version` over
different files (issue #296). After ANY merge that changes `skills/`, `agents/` or `scripts/align-labels.sh` (the one
root-`scripts/` path a skill invokes at runtime through `${CLAUDE_PLUGIN_ROOT}`), remind the
operator to update on each consumer machine — following README step 4, which carries the
marketplace-qualified name AND the `--scope` that matches the copy actually in use. Do not
prescribe the bare command here: it defaults to `--scope user` and silently updates a copy the
session may not be running. Do not verify with `ls`: the version
string cannot answer the question, and the cache holds every version ever installed. Verify by the
content comparison in README "Updating / Troubleshooting" → "`claude plugin marketplace
update` is not a plugin update", which is the single copy of that
procedure — do not restate its steps here.

## extra-guardrails

<!-- Additional send-it guardrails go here. -->
