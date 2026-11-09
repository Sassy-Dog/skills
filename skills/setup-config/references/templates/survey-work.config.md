<!--
CONFIG TEMPLATE: survey-work
Rendered into a consumer repo as .claude/sassy-dog/survey-work.md
  {{FACT}}          -> the detected + LIVE-VERIFIED value
                       Policy slots use the existing resolved choice or interview consent,
                       not a new detection/default (config-contract.md applicability inventory).
  optional: blocks  -> omit the whole block when the repo lacks that surface.
                       Presence is the toggle. There is no `sentry: false` — the
                       confirmed-absent form is the scalar `none`, the contract's
                       one documented exception, and FOUR keys carry it:
                       `sentry: none`, `testflight: none`, `posthog: none`,
                       `mobile: none` (config-contract.md).
                       Omitted = nobody checked; `none` = somebody checked and
                       there is nothing there. The four are deliberately NOT
                       symmetric: only `sentry: none` still renders a blind-spot
                       row on the plate. Never default a `none` — it is written
                       only on an explicit answer (interview.md §2c), except
                       `sentry: none`, which records a failed culprit check.
  ## sections       -> carried across verbatim on refresh, never rewritten.
Drop this comment block from the rendered output. `---` must be line 1.
-->
---
scan_paths: {{SCAN_PATHS}}
exclude_pathspecs: "{{EXCLUDE_PATHSPECS}}"
ci_workflow: {{CI_WORKFLOW}}
priority_labels: {{PRIORITY_LABELS}}
write_policy: {{WRITE_POLICY}}

# optional — omit any block this repo does not have (`sentry:` only for a culprit-verified project — name similarity is not evidence; unverified renders `sentry: none`). For `sentry`/`testflight`/`posthog`/`mobile` the confirmed-absent alternative is the scalar `none` in place of the block

execution_site: {{EXECUTION_SITE}}
sentry:                                 # or `sentry: none` — no verified project (never "no error monitoring")
  org: {{SENTRY_ORG}}
  projects: {{SENTRY_PROJECTS}}
  gate: {{SENTRY_GATE}}
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
testflight:                             # or `testflight: none` — confirmed: no beta channel
  bundle_id: {{BUNDLE_ID}}
mobile:                                 # or `mobile: none` — confirmed: no mobile app
  release_workflow: {{RELEASE_WORKFLOW}}
  path_prefix: {{MOBILE_PATH_PREFIX}}
posthog: {{POSTHOG}}                    # `true`, or `none` — confirmed: no product analytics. Never render `false`; omit the key instead
secret_bootstrap: {{SECRET_BOOTSTRAP_CMD}}
---

## extra-surfaces

## scoring-overrides

## extra-guardrails
