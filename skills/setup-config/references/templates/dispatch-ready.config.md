<!--
CONFIG TEMPLATE: dispatch-ready — see survey-work.config.md header for render rules.
dispatch-ready STOPS on NO_CONFIG (it dispatches and merges unattended), so this file
is required for any repo that runs it.
review_site uses the resolved Phase 1 choice (including an override), never an optional omission;
on refresh carry the chosen value forward. Site/stack slots below require the existing interview
consent; claim_label renders only when applicable (config-contract.md inventory).
-->
---
max_in_flight: {{MAX_IN_FLIGHT}}
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
  in_review_option_id: {{BOARD_IN_REVIEW_OPTION_ID}}
  done_option_id: {{BOARD_DONE_OPTION_ID}}
migrations:
  dirs: {{MIGRATION_DIRS}}
  regen_command: {{MIGRATION_REGEN_COMMAND}}
codegen:
  hint: {{CODEGEN_HINT}}
---

## extra-sequencing
