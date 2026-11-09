# Phase 2 — the interview

Ask ONLY what detection couldn't establish or what's policy (not fact). Use AskUserQuestion; batch into at most two rounds. Show detected values as the recommended option — the user confirms rather than recites.

## Questions

### 0. Merge policy — merge queue or direct? (ALWAYS confirmed, never remembered)

The single most expensive fact to get wrong, and the one most likely to be stale in an existing
render. **Read it from live state, then show the user what you found:**

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"NAME"){mergeQueue(branch:"BRANCH"){id configuration{mergeMethod}}}}' \
  --jq '.data.repository.mergeQueue'
```

| Result | `merge_queue` | What the skills do |
|---|---|---|
| non-null | `true` | `gh pr merge --auto`, no method flag, **no** `--delete-branch` (GitHub rejects it when a queue is enabled), confirm `isInMergeQueue` |
| `null` | `false` | `gh pr merge --delete-branch`, by the first of `--squash`, `--merge`, `--rebase` the repo allows |

This plugin's own repo had `merge_queue: false` written into a generated skill after the queue was
enabled; the error only surfaced as a rejected merge. Never carry this value forward.

### 1. take-it wanted? (skip in update mode unless the user raised it)

Parallel issue-shipping is opt-in. Default **yes** if the repo has GitHub Issues + Actions and a worktree-friendly dev loop; default **no** if the repo is a prototype or the user runs strictly serial. A trio without take-it is a valid steady state — update mode must never add take-it unasked.

### 2. survey-work write policy

| Option | Meaning |
|---|---|
| **Read-only** (default for new adoptions) | Plate reports; never files. `IF:WRITE_GATE_SENTRY` off. |
| **Gated Sentry→GH auto-file** | Qualifying Sentry hits (sentry-triage gate defaults: unresolved · lastSeen ≤ 7d · userCount ≥ 2 ∨ events ≥ 5 ∨ error ∧ events ≥ 2) auto-file so the plate always hands take-it real issue numbers. Burst rail: > 5 would-file → stop and ask. |

Offer the gate defaults verbatim; record any threshold tweak in `{{SENTRY_GATE_SUMMARY}}`. Requires Sentry detected + an escalation repo.

### 2b. Sentry project — confirm a prior claim (asked ONLY when the sibling scan hit)

Never ask "which project is this repo's?" — that question invites a name match. The project is
established by the culprit check in `detection.md` (its culprits must resolve in *this* repo), and a
candidate that fails it is not offered to the user at all; it becomes `sentry: none`.

Ask this question only when the best-effort sibling-checkout scan found the verified slug already
declared in another repo's `.claude/sassy-dog/survey-work.md`. Name the other repo and its config
path, and **default the answer to "it is already owned — do not configure it here"**: two repos
declaring one project double-report the same Sentry issues while both plates still look complete,
so a wrong "yes" is invisible. Configure it here only on an explicit confirmation that this repo is
the right owner (or that both genuinely emit into it).

A *miss* here asks nothing and blocks nothing. The scan is secondary by design: a cloud session has
no sibling checkouts on disk, so it finds nothing there — which is exactly why the culprit check,
not this question, is the guard that has to hold.

### 2c. Confirmed-absent product surfaces — `testflight`, `posthog`, `mobile`

**Asked for each of the three keys this run would otherwise leave ABSENT — or leave carrying a value
the contract no longer defines.** That is the trigger, and both halves are load-bearing.

It is not "keys detection could not establish", which silently excluded `posthog`: its detector
always answers, `true` or `false`, so the key that motivated this form would have been unreachable on
the very path that writes it.

And it is not "absent" alone. `posthog: false` is a legal *detection result* and an illegal *config
value* (`config-contract.md`), and a pre-existing config can carry one — `main`'s template rendered
`posthog: {{POSTHOG}}` straight from the detector. Such a key is neither absent nor valid, so an
absent-only trigger drops it during frontmatter regeneration, never asks, and leaves the blind-spot
row this form exists to clear. (Probed 2026-08-25: no Sassy-Dog consumer config carries one today —
the five that set `posthog` all set `true` — so this is latent rather than live. It is still the
cheaper half to get right now than to diagnose later.)

**All four generator modes reach this question.** In **create** mode: ask for every key with no
positive evidence, and for every key whose only evidence the user dismisses. In **update** mode: ask
for every key missing from the existing config, or carrying `posthog: false`. In **migrate** mode:
ask for every one of the three, always — a legacy generated skill has no way to express a `none`, so
a migrated config arrives in exactly the pre-#261 state (`references/migrate-mode.md`). In **adopt**
mode: ask for every one of the three, always, and for the same reason — a hand-written skill has no
way to express a `none` either (`references/update-mode.md`, "Adopt mode" step 2b).

It is the only way a repo ever gets a `none` on these three: **never default one, and never infer one
from a quiet tree.** `none` asserts that a human checked, so a guessed `none` retires a real blind
spot with nothing announcing it — the mirror of the failure the form exists to fix.

Ask once per key, naming the exact value it writes and what that value claims:

- `testflight: none` — this product has no beta channel
- `posthog: none` — this product has no product analytics
- `mobile: none` — this product has no mobile app

**Not skipped on a refresh** — unlike §1, §3b, §3c and §3d. A key missing from the config is a key left
absent, which is the state every consumer repo configured before this form existed is in, so a
refresh that skipped the question would leave the blind-spot rows exactly where they were
(`references/update-mode.md`).

Detection may *propose* the answer, as everywhere else in this interview, but check what it actually
gives you: `scripts/detect-capabilities.sh` derives `posthog` (a tracked-tree grep with `.claude/**`
excluded — so a repo that merely *documents* PostHog in its README or its source still trips it, say
which file matched, but the `posthog: none` this question writes is never itself the evidence on the
next refresh, [#317](https://github.com/Sassy-Dog/skills/issues/317)) and
`testflight_bundle_id` (only when an `ios/` path or an `app.json` is tracked). **There is no "has a mobile target" field**, so a `mobile`
proposal comes from checking the tree yourself — `ios/`, `android/`, `app.json`, `pubspec.yaml`. The
user's answer is what writes the key; a quiet tree never is.

| Answer | Written | What `survey-work` does |
|---|---|---|
| Confirmed: this product has no such surface | `<key>: none` | one `(n/a)` token on `✓ Clean today:` — **no** blind-spot row |
| Not sure / not decided yet | key omitted | a blind-spot row on every plate until someone answers |
| It has one | the block, with its facts | the surface runs |

State the stakes plainly, because "not sure" is the safe answer and it should stay available: an
omitted key costs a recurring row, a wrong `none` costs the row *forever* on a surface that later
exists. An infra repo with no app carried three unclearable rows on every plate before this
question existed ([#261](https://github.com/Sassy-Dog/skills/issues/261)).

**Do not offer the same question for `sentry:`.** Its `none` is not an interview answer at all — it
is what `setup-config` writes when culprit verification fails (§2b, `references/detection.md`), and
it keeps its blind-spot row deliberately: absent error monitoring is a gap somebody could close, an
absent mobile app is a product fact (`references/config-contract.md`, "The one exception"). Offering
"confirm this repo has no Sentry" would read as a way to clear that row. It is not one.

### 3. Merge policy — always confirm, never trust the probe alone

Show the detected value (`merge_queue: true/false/null` + repo settings) and have the user confirm queue vs direct. State the stakes: a wrong "queue" guess means `--auto` calls that silently never merge; a wrong "direct" guess bypasses queue serialization. Sets `IF:MERGE_QUEUE` and `{{MERGE_POLICY_NOTE}}`.

### 3b. groom-backlog / dispatch-ready wanted? (opt-in pair; skip in update mode unless raised)

Both are **board-optional**: with `IF:BOARD` they drive the board's **Ready** status column; boardless renders drive the `ready` + `in-progress` labels instead (the degraded-board contract — Ready column → `ready` label, In progress + assignee → assignee @me + `in-progress`, failure demotion → strip labels + `blocked` + comment). dispatch-ready additionally requires take-it. Default **no** unless the repo already runs a Ready-based flow (board column or `ready` label). If dispatch-ready is wanted, confirm two policy facts:

- `{{MAX_IN_FLIGHT}}` — concurrent in-flight cap (default **5**).
- If `IF:BOARD`: pin `{{BOARD_READY_OPTION_ID}}` (and Backlog id for bounce-backs) alongside the other board IDs.
- groom-backlog: confirm `{{GOTCHA_SUMMARY}}` — the one-line list of repo gotchas every refined issue body should carry (e.g. codegen paths, i18n catalogs, migration policy). **Ask for invariants, not status.** A trap that stays true until the architecture changes belongs here; an issue number with a state claim (`#334 … remains`), an "as of `<date>`", or a roadmap position does not — nothing recomputes this field, so a status written here rots in place and is copied verbatim into issue bodies (config-contract.md, "`gotcha_summary` carries INVARIANTS ONLY"). If the user offers one, say why and rewrite it with them.

### 3c. Stacked PRs? (opt-in; default NO — skip in update mode unless raised)

Asked only when take-it or dispatch-ready is on, and only after the merge-policy question, because the two interact.

Enabling writes the `stacked_prs:` block and lets `groom-backlog` propose a `stack:` chain and the dispatchers build one. **Default no.** Do not ask this as "do you want the new feature?" — ask whether this repo has work that arrives as *genuinely dependent chains* (schema then consumer, extract then refactor). A repo whose issues are mostly independent gains nothing and takes on a sequential dispatch shape for free.

State two things plainly before the user answers:

- **The preview is still rolling out per-repo.** Run `sassy-dog:pr-shepherd`'s `scripts/stack-probe.sh --repo <slug>` and report the result. Exit 11 means this repo cannot use stacks *yet* — enabling the block is still legal and simply dormant until GitHub enables it, but say so rather than letting the user assume it works today.
- **If `merge_queue: true`,** dispatchers may open stacks that `pr-shepherd` will refuse to land (exit 24) until GitHub finishes shipping queue support. That is a real cost; confirm the user accepts landing those by hand.

`{{STACK_MAX_DEPTH}}` — layer cap (default **4**). Beyond it the dispatchers fall back to independent PRs.

### 3d. Execution site — what does this checkout answer to? (`execution_site`)

**Asked once, in create, migrate and adopt modes. Skipped on a refresh unless the user raises it.**
That split is the mechanism, not a convenience: the key names a machine, nothing can re-derive it,
and a question re-asked on every refresh is a proposal re-offered forever. Create, migrate and adopt
are one-time transitions, so each repo gets exactly one offer — and a repo that answered "no" then
stays unasked, which is the only way a decline is recorded at all — and, until a repo has actually
been offered the question, an absent key records nothing but that. `references/update-mode.md`
carries that distinction for the refresh path. `references/update-mode.md` and
`references/migrate-mode.md` carry each mode's own half.

`references/config-contract.md` documents the key — what it means, what its absence means, how a
consumer matches it. **Do not restate any of that to the user, and do not write a second description
of it anywhere.** This question only fills the slot.

**Propose from the platform, and take the mapping from that contract's `uname -s` table.** Run the
shell, read the table, offer the name it gives. **Never copy the table here** — a second copy is one
that drifts, and this one would drift toward a language runtime's platform constants, which the
table exists to rule out. Some platforms have no proposal at all; where the table gives none, ask
with **no default** rather than inventing one.

**The proposal is a starting point the user renames, and it is never assumed.** The name is theirs:
`vdi` carries a meaning no platform string does, and the platform can only ever say what *kind* of
machine this is. So:

| Answer | Written |
|---|---|
| A name (the proposal, or their own) | `execution_site: <name>`, into every skill file that reads it — the contract names them |
| Declined, unanswered, or "just use defaults" | the key is **omitted** |

An omitted key is a legitimate steady state, not an unfinished one: a repo whose work all runs from
one machine wants exactly that, and nothing renders a blind-spot row for it. **Never write a value
the user did not say**, and never offer a `none` — the confirmed-absent form does not cover this key
and the contract says why.

### 3e. Board option ids (every render with `IF:BOARD`, whichever skills are on)

Pin `{{BOARD_IN_REVIEW_OPTION_ID}}` and `{{BOARD_DONE_OPTION_ID}}` alongside the Ready, Backlog and In progress ids, from the same Status-field option list (`gh project field-list`), whatever the columns are named. groom-backlog's `board-drift.sh` resolves its column names from these ids, and survey-work, take-it and dispatch-ready carry the same `board:` block. Leave either key unwritten when the board has no such column.

### 4. Commands (fact confirmation, free-text)

- Pre-flight commands (`{{PREFLIGHT_COMMANDS}}`) — propose from the runner; user edits.
- Migration regen command (`{{MIGRATION_REGEN_COMMAND}}`) if `IF:MIGRATIONS`.
- Codegen command + output dirs if `IF:CODEGEN`.
- Secret bootstrap command (`{{SECRET_BOOTSTRAP_CMD}}`) if detection reports a `secret_manager` (`.envrc`/`doppler.yaml`) — the one-liner survey-work §1 runs to load managed secrets BEFORE its env presence probes (propose `eval "$(doppler secrets download --no-file --format env 2>/dev/null)"` for Doppler repos). Confirming it sets `IF:SECRET_BOOTSTRAP`. In update/adopt mode, an "environment bootstrap" note sitting in a PROJECT-SPECIFIC fence (typically under §2.C — too late, the §1 probes already ran) is the tell: offer to promote that command into this placeholder.

### 4b. tidy-repo never-discard files (fact confirmation; tidy-repo is core, so always asked)

tidy-repo auto-discards untracked noise against an allowlist — confirm the **never-discard** list of
gitignored-but-precious files it must leave alone (`{{NEVER_DISCARD}}`). Propose `.env.local` for web
apps (Vercel Blob token / Neon branch URL / OIDC); add any repo-specific local secret/state files.
The dep-globs, noise allowlist, and `delete_branch_on_merge` are derived from detection (no question);
the claim-label step renders only if take-it is on and a `status:in-progress`-style label exists.

### 5. Project-specific surfaces & rules (free text, optional)

Anything detection can't know: in-app feedback tables/CLIs, funnel-health surfaces with PRD targets, infra-drift checks, tenant-scoping invariants for sub-agents, deprecation scans, repo-unique cleanup steps. Each answer lands inside the matching `PROJECT-SPECIFIC` fence (`extra-surfaces`, `scoring-overrides`, `subagent-rules`, `extra-gates`, `extra-cleanup`, `extra-guardrails`) — never woven into template-owned sections, or the next update loses it.

## Defaults summary (when the user says "just use defaults")

delegation: plugin-backed · take-it: yes (if Issues + Actions) · survey-work: read-only · merge: detected value but still confirmed · scoring: repo-health defaults · tidy-repo: core (always rendered), never-discard `.env.local` for web apps · secret bootstrap: only when detection finds a `secret_manager` (Doppler repos get the `doppler secrets download` eval) · **stacked PRs: off** · **confirmed-absent surfaces (§2c): never defaulted — "just use defaults" omits the key, it does not write a `none`** · **`execution_site` (§3d): never defaulted either — the platform proposal is offered, never applied, so "just use defaults" omits the key** · no project-specific extras.
