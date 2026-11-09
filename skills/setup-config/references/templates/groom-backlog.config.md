<!--
CONFIG TEMPLATE: groom-backlog (formerly fill-it) — see survey-work.config.md header.
Migrate mode maps .claude/skills/fill-it/ onto .claude/sassy-dog/groom-backlog.md,
carrying its extra-rubric prose across.
  {{GOTCHA_SUMMARY}} -> INVARIANTS ONLY. Traps that stay true until the
                        architecture changes ("business logic lives in `crates/`,
                        never in the Tauri shell"). NEVER a status: no issue
                        number with a state claim ("#334 ... remains"), no
                        "X remains"/"still open", no "as of <date>", no roadmap.
                        Nothing recomputes this field and it is not in the `##`
                        prose lane a human curates, so a status written here rots
                        in place and groom-backlog copies it to a cold agent that
                        cannot check it (issue #249). Full rule + worked examples:
                        references/config-contract.md, "gotcha_summary carries
                        INVARIANTS ONLY". Migrate/adopt mode carries an existing
                        value across — lint it first with github-issues'
                        `verify-gotcha-claims.sh --config <path> --lint` and fix
                        what it names WITH the user; never silently.
Drop this comment block from the rendered output. `---` must be line 1.
-->
---
gotcha_summary: >
  {{GOTCHA_SUMMARY}}

# optional

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
  in_review_option_id: {{BOARD_IN_REVIEW_OPTION_ID}}
  done_option_id: {{BOARD_DONE_OPTION_ID}}
---

## extra-rubric
