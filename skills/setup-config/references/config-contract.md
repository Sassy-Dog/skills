# Repo config contract

The generic workflow skills — `survey-work`, `groom-backlog`, `take-it`, `dispatch-ready`, `send-it`, `tidy-repo` —
ship one implementation each in the plugin and read their per-repo behavior from:

```text
<repo-root>/.claude/sassy-dog/<skill-name>.md
```

One file per skill. Each file is YAML frontmatter (facts and toggles) followed by `##` sections
(freeform prose). This document is the source of truth for that format; `setup-config`
writes these files and the six skills read them. Two dispatch front-ends with no file of their own also read `take-it.md`:
`work-recommendations` (including `board.backlog_option_id`, which `take-it` itself never reads —
do not prune it as unread) and `work-fire-watch`.

## Governing principle: configure only what cannot be derived

Never write a fact into config that the skill can obtain at runtime. A configured value is a value
that can drift; a derived value cannot.

**Always derived, never configured:**

| Fact | How the skill gets it |
| --- | --- |
| Repo slug | `gh repo view --json nameWithOwner --jq .nameWithOwner` |
| Default branch | `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` |
| `delete_branch_on_merge` | `gh repo view --json deleteBranchOnMerge --jq .deleteBranchOnMerge` |
| Current branch | `git branch --show-current` |
| Repo root | `git rev-parse --show-toplevel` |
| Commit co-author trailer | the running model's own name — `Co-Authored-By: Claude <model> <noreply@anthropic.com>` |

This is why no `repo:` or `default_branch:` key appears in the schemas below, even though the old
templates rendered `{{REPO_SLUG}}` and `{{DEFAULT_BRANCH}}` into every generated skill.

**This is not theoretical.** Migrating this repo surfaced two facts that had drifted in its
generated skills: they asserted `delete_branch_on_merge: false` and "there is no merge queue", while
the repo had since enabled both. The derivable one self-corrected the moment it became derived. The
other — `merge_queue`, which has no `gh repo view` equivalent — carried the staleness across, and
only a rejected `gh pr merge --delete-branch` exposed it.

So: the principle removes drift exactly where a fact is derivable, and nowhere else. **A refresh
must re-verify every configured fact against live state**, not copy it forward from the previous
render. `merge_queue` in particular should be checked via the `mergeQueue(branch:)` GraphQL field
rather than asked about or inherited.

**Re-verification is not adoption.** Live state tells you which merge methods the repo *allows*;
config records the one the repo *intends*. Those are different claims, and the allowed set being a
hard constraint does not make it the right answer. A repo can depend downstream on the intended
method — a build number taken from `git rev-list --count HEAD` increments by exactly 1 per merged PR
only while history stays linear squash-merges, so switching to merge commits corrupts version
ordering with no error anywhere. A refresh that derived the allowed set and picked from it would
make exactly that switch, silently, the day someone enabled merge commits.

> **Derive what is *allowed*. Keep what is *intended*. Stop when they disagree.**

Where a repo states an intended method — in this config, in `docs/`, or in its own skills — and
live state no longer permits it, that disagreement is a **stop and surface**: report both sides and
let the user decide which one is wrong. It is never an automatic rewrite of the configured value,
and never a silent adaptation to whatever happens to be allowed today.

## Governing principle: presence is the toggle

The old templates carried paired state — an `IF:SENTRY` flag *and* `{{SENTRY_ORG}}`/`{{SENTRY_PROJECTS}}`
facts — which can disagree. In config, **the presence of a block enables the feature**:

```yaml
sentry:                     # present  -> the Sentry surface runs
  org: sassy-dog
  projects: [qrninja-web]
```

Omit the `sentry:` key entirely and the surface is skipped. There is no `sentry: false` — the one
documented exception to this principle is `sentry: none`, below, a form three sibling keys now share
(`testflight: none`, `posthog: none`, `mobile: none`) with a deliberately *different* consequence.
The same holds for `board`, `testflight`, `mobile`,
`migrations`, `codegen`, `secret_bootstrap`, `review_surfaces`, `execution_site`, and `claim_label`. Presence remains
the toggle for the four `none` keys too — `none` is an *additional* value on them, never a
replacement for presence, so a key that is simply absent is still off.

Four keys are genuine scalars rather than blocks, because they carry no sub-facts:

- `merge_queue: true|false` — merge queue vs. direct squash-merge. It carries **intent**, not an
  observation: a refresh re-verifies it against `mergeQueue(branch:)`, but a live state that
  contradicts the configured value is surfaced to the user rather than written over it
- `write_policy: read-only|gated` — whether `survey-work` may file issues under its Sentry gate
- `review_agent: <agent>|skip` — which agent `send-it`'s review gate dispatches. **This key is not
  governed by presence-is-the-toggle at all: it has a default.** Omitting it does not disable the
  gate, it selects the shipped `sassy-dog:pr-review-orchestrator` — see `review_agent` below. Its
  optional companion `review_surfaces:` is an ordinary presence-toggled block with no default, and
  the difference is the point: one chooses *whether* a review happens, the other only *where* paths
  route inside one
- `review_site: agent|coordinator` — **where** the review gate runs on the two dispatching paths,
  `take-it` and `dispatch-ready`. Like `review_agent:` it carries a default rather than an off
  switch (absent selects `coordinator`), and unlike every other key here it is *seeded from a derived
  fact and then frozen* — `review_site` below says why that is deliberate rather than drift

### The one exception: `sentry: none`

**`sentry: none` is the FIRST documented exception to presence-is-the-toggle, and it is deliberate.**
It is not a `false` flag by another name and it does not reopen paired state: it carries a fact the
absence of the key cannot carry — that someone **checked**, and no error-monitoring project could be
verified for this repo. (Not the stronger claim that the repo has none; see the second reason below.)

The reason the exception is worth its cost: `setup-config` may only write a `sentry:` block for a
project it has **verified by culprit** against this repo's own code (`references/detection.md`,
"Sentry project — verify by CULPRIT, never by name"). Verification can fail — no MCP server, no
recent issues to sample, or culprits that resolve in some other codebase — and the alternatives are
both worse than a new form. Guessing a same-named project makes the wrong repo claim another
codebase's P0s, silently. Omitting the key instead makes a *finished* check indistinguishable from
one that never ran, so the next refresh re-litigates it and the next guess is one interview away.

Three states, all distinct:

| Config | Meaning | `survey-work` behaviour |
| --- | --- | --- |
| `sentry:` block with `org`/`projects` | verified project | surface runs |
| `sentry: none` | confirmed: no error-monitoring project is verified here | reported as a blind spot |
| key absent | never configured / unknown | reported as a blind spot (unconfirmed) |

The exception is **the `none` form itself**, and it is scoped to the four keys whose absence
`survey-work` renders as a blind-spot row: `sentry:`, `testflight:`, `posthog:`, and `mobile:`. A
fifth key needs both halves of the justification, not one — a confirmed-absent state a reader would
otherwise mistake for an unfinished check, **and** a surface whose absence already costs that reader
something to read. The keys deliberately left out are listed below.

#### The four keys, and why `none` is ASYMMETRIC across them

| Config | Meaning | `survey-work` behaviour |
| --- | --- | --- |
| `sentry: none` | confirmed: no *verified* error-monitoring project | **blind-spot row — kept** |
| `testflight: none` | confirmed: no beta channel | on the clean line, no row |
| `posthog: none` | confirmed: no product analytics | on the clean line, no row |
| `mobile: none` | confirmed: no mobile app | on the clean line, no row |

`survey-work` §6 owns the exact rendering — the `(n/a)` marker and the `✓ Clean today:` line — and
this table deliberately does not transcribe it; a third copy of a format is the #167 shape.

**Absent error monitoring is a gap somebody could close; an absent mobile app is a product fact.**
That single sentence is the whole asymmetry. A repo with no Sentry should keep being told so on
every plate: the row is the only place anything says the production errors are not merely unseen by
this plate but unrecorded anywhere, and it is a decision somebody can revisit tomorrow. A repo with
no mobile target should not: no plate will ever change that, and there is no configuration that
clears the row.

**A second reason, and it applies to `sentry:` alone.** The three sibling keys mean exactly one
thing. `sentry: none` means **two**: this repo has no error monitoring, *or* the culprit check could
not run — no MCP server connected, no recent issues to sample (`references/detection.md`). The
second is not a confirmed absence at all, it is an unfinished verification wearing the same value,
and nothing downstream can tell them apart. That alone disqualifies the clean line: a surface whose
state is *unknown* must not be reported as one somebody checked and cleared. So the row is worded as
*confirmed at setup that no project is verified* — confirmed of the verification, never of the
absence — and the sources-line token beside it reads `recorded at setup`. Precise rather than
tactful; "this repo has no Sentry" is the one thing neither may say.

**The failure this closes is a trained reader, not an untidy plate**
([#261](https://github.com/Sassy-Dog/skills/issues/261)). `survey-work` §6 orders
blind-spot rows by what the darkness costs, customer pain first, so an infra repo with no app —
`Sassy-Dog/platform`, observed 2026-08-24 — rendered `testflight`, `posthog` and `mobile` rows on
**every** plate, two of them in the loudest position the section has, with no config that could
clear them. A reader who meets the same three unactionable rows every time learns to skim the
heading, and the row that should stop them — a genuinely dark Sentry on a repo that has one — is
then sitting in a list they have been trained to ignore.

**Do not "align the `none` forms."** A four-key form where one key behaves differently reads as a
plain inconsistency, which is exactly why the asymmetry is pinned in CI
(`scripts/test-sentry-verification.sh`) and not merely written here. Collapsing `sentry: none` onto
the clean line re-creates the silent gap [#213](https://github.com/Sassy-Dog/skills/issues/213)
opened this form to close; promoting the other three back into rows re-creates #261.

**Where each `none` comes from differs too.** `setup-config` writes `sentry: none` itself, as the
recorded outcome of a culprit verification that failed (`references/detection.md`). The other three
are never derived and never defaulted — they are written only on an explicit answer in the
interview (`references/interview.md` §2c), because `none` asserts that a human checked, and a
guessed `none` retires a real blind spot with nothing announcing it. A refresh carries **those
three** forward rather than re-asking, and re-derives `sentry: none` like any other fact: it is also
written when the culprit check merely could not run, so freezing it would let one unlucky session
retire the plate's highest-signal surface with no path back (`references/update-mode.md`).

**Deliberately not extended further.** Each new `none` is one more state a reader has to hold, so
the form is scoped to keys whose absence is *loud*:

- **`board:` is excluded.** `survey-work` §3B already ships a boardless form that reads open issues
  directly, so an absent `board:` selects a documented alternative path rather than going dark. It
  renders no blind-spot row today and needs no opt-out.
- **`secret_bootstrap:`, `migrations:`, `codegen:`, `claim_label:`, `review_surfaces:` and
  `execution_site:` are excluded.** None of them render a blind-spot row, so their absence costs a
  reader nothing and a `none` would only add a state to get wrong. `execution_site:` is the
  clearest of them: its absence already reads as "this checkout answers to no particular name",
  which is what a `none` would have said.
- **`stacked_prs:` is excluded, and for a third reason.** Its absence already means something
  specific — the repo has not opted in — and a refresh is forbidden from adding it at all
  (`references/update-mode.md`). Enablement is availability; the block is consent. A `none` there
  would be a second way to spell "no consent", which is not a state anyone needs.
- **`ci_workflow:` is excluded**, even though its absence *does* render a blind-spot row, which makes
  it the one apparent counter-example to the criterion above. The difference is what the absence
  means: a missing `ci_workflow` is a missing **fact the skill needs** — it cannot guess a workflow
  filename — so the row is a request for configuration and clears the moment the key is filled in. It
  is never a statement about the product. There is nothing for a `none` to confirm.
- **`review_agent:` and `review_site:` are excluded for a different reason.** They are not
  presence-toggled at all — they carry defaults — and `review_agent`'s opt-out is spelled `skip`
  precisely so that it is not mistaken for this form. See `review_agent` below.

#### Why this section is still headed `sentry: none`

The heading names one key while the body scopes the form to four. That is deliberate. One CI gate
anchors the heading line verbatim — `scripts/test-review-gate-decisions.sh` asserts it, anchored, as
a link target for the `review_agent: skip`-not-`none` decision (#237, tracked as
[#247](https://github.com/Sassy-Dog/skills/issues/247)) — while
`scripts/test-sentry-verification.sh` extracts this section by a prefix of it, and five prose
cross-references point at it by name (`references/update-mode.md`, `references/migrate-mode.md`,
`references/interview.md`, and `survey-work`'s §6 twice).
Renaming it to cover the four would redden a gate whose failure message points a reader at the
review-gate decisions (#237, tracked as
[#247](https://github.com/Sassy-Dog/skills/issues/247)) instead of at this section.
`sentry: none` is also still the *first* documented exception and the one whose justification the
others inherit, so the name is accurate as a citation even where it is incomplete as a summary.
Leave it.

## Shared blocks

These appear in whichever skill files need them. A repo that uses a project board puts the same
`board:` block in `survey-work.md`, `groom-backlog.md`, `take-it.md`, and `dispatch-ready.md`.

```yaml
board:
  number: 4                 # project number
  owner: Sassy-Dog
  project_id: PVT_kwDO...   # GraphQL node IDs, from board-snapshot.sh
  status_field_id: PVTSSF_...
  ready_option_id: 47fc9ee4
  backlog_option_id: f75ad846
  in_progress_option_id: 98236657

sentry:                     # or `sentry: none` — no verified project (see the exception below)
  org: sassy-dog
  projects: [qrninja-web, qrninja-mobile]
  gate: defaults            # or an explicit override of the qualifying gate

testflight:                 # or `testflight: none` — confirmed: no beta channel
  bundle_id: com.sassy-dog.qrninja

mobile:                     # or `mobile: none` — confirmed: no mobile app
  release_workflow: mobile-release.yml
  path_prefix: apps/mobile/

migrations:
  schema_dir: packages/db/src/schema
  dirs: packages/db/src/migrations
  regen_command: bun run db:generate

codegen:
  command: bun run codegen
  output_dirs: apps/web/src/generated
  hint: run codegen after touching any tRPC router

stacked_prs:
  max_depth: 4              # cap on layers a dispatcher will build

secret_bootstrap: eval "$(doppler secrets download --no-file --format env 2>/dev/null)"
review_agent: qr-ninja-review-orchestrator   # override; omit -> sassy-dog:pr-review-orchestrator
review_surfaces:                            # optional; steers the shipped orchestrator only
  "ops/**": sassy-dog:infra-platform-reviewer
review_site: agent                          # where the gate runs on the dispatching paths
execution_site: mac                         # the name THIS checkout answers to
claim_label: in-progress
posthog: true                               # or `none` — confirmed: no product analytics
merge_queue: false
```

Omit any block the repo doesn't use — with two exceptions, `review_agent:` and `review_site:`,
where omitting the key selects a default rather than disabling anything. Four of these keys —
`sentry:`, `testflight:`, `posthog:`, `mobile:` — additionally accept the scalar `none`, the
confirmed-absent form above. For the first three that replaces a block; `posthog` is already a
scalar, so `none` simply joins `true` as one of its values. Omitted means nobody has checked; `none`
means somebody has, and only `sentry: none` still renders a blind-spot row.

**`posthog: false` is not one of the forms.** `scripts/detect-capabilities.sh` reports the
capability as `true`/`false`, but that is a detection *result*, not a config value: a render writes
`posthog: true`, or `posthog: none` on a confirmed absence, or omits the key. Writing the `false`
through would re-create exactly the paired state this section's principle removes — a flag that can
disagree with the facts beside it — and `survey-work` branches on `true` and on the key's absence, so
a `false` behaves as absent while reading like a decision.

### `review_agent` — read by `send-it`

`send-it`'s review gate resolves an agent on **every** run; the config only chooses which one:

| Config | Gate behaviour |
| --- | --- |
| `review_agent: <agent>` | dispatches that agent — a repo's own orchestrator wins |
| key absent | dispatches `sassy-dog:pr-review-orchestrator`, the diff-scoped orchestrator the plugin ships |
| `review_agent: skip` | dispatches nothing, and still prints `review: SKIPPED — no review_agent resolved (lint/type/test only)` |

**Omitting the key selects the shipped orchestrator.** It is no longer the off switch it was before
the default existed: the orchestrator ships with the plugin, so it resolves in any repo that has
the plugin and nothing else, which is what makes default-on statable as a rule instead of a
per-repo opt-in. No `send-it` run can therefore silently ship unreviewed. The accepted cost is one
extra review pass of latency and tokens on every `send-it` run in every consumer repo.

**A named agent inherits the delivery contract, whoever wrote it.** Whatever a repo names here must
return its report as its **final text** — the shipping paths read the value the agent returns and
nothing else, and they never wait on a message or a notification to bring one in. An agent that
delivers any other way is classified `review: NO REPORT — <agent> dispatched, no report returned
(lint/type/test only)` on every run — and in the two dispatching paths that PR is held rather than
merged. **The discriminator is UNATTENDED MERGING, not whether a PR exists at gate time**, and
getting that wrong is the trap: under `review_site: agent`, `take-it`'s sub-agent runs
its gate at step 6 — before its commit and before its PR — exactly like `send-it`, so a reader
applying "does a PR exist yet?" concludes the agent site has nothing to hold either, which is the
one conclusion these paths were changed to prevent. What separates them is what happens NEXT:
`take-it` and `dispatch-ready` go on to merge that PR with no human reading along, so a lost
report there becomes an unreviewed merge. `send-it` hands its run back to the person who started
it, so it records the outcome and carries on. That is the intended behaviour on a lost
report, not a bug to work around by making a dispatcher wait. This is the one
obligation that *does* reach outside the shipped orchestrator — unlike `review_surfaces:`, whose
contract stops at it (below) — because the failure it prevents is a PR merged on a review nobody
read.

**The default-on claim above scopes to `send-it`, and a companion key extends it.** `take-it` and `dispatch-ready`
dispatch sub-agents that open their own PRs from a cold worktree and never invoke `send-it`, so
this default cannot reach them on its own. `review_site` below is what carries the gate into those
two paths; `review_agent` still decides *which* agent runs once it does.

A repo that genuinely wants no design review sets **`review_agent: skip`** — an explicit act that
shows up in the config diff, and one `send-it` still reports on the run rather than passing over in
silence. The same SKIPPED line covers a *resolution failure*, which is a different thing: the two
share that line because they share a consequence — a diff nobody reviewed — and a run that printed
nothing would be indistinguishable from a clean review. They do not share urgency, so `send-it`
names which one it hit on the line after; the quoted line itself is fixed.

**The opt-out is spelled `skip`, not `none`.** `none` belongs to the presence-is-the-toggle
exception above, which records a confirmed absence somebody went and checked for; `review_agent` is
not a presence-toggle key at all, so its opt-out overrides a default rather than confirming an
absence — and `skip` names the line the gate actually prints.

### `review_site` — read by `take-it` and `dispatch-ready`

**Where** the review gate runs on the two dispatching paths. `send-it` does not read this key: it
has exactly one site, its own run, and always reviews there.

| Config | Where the review happens |
| --- | --- |
| `review_site: agent` | each dispatched sub-agent reviews **its own diff before it opens a PR** — `send-it`'s TIMING exactly: Blocking findings are fixed and re-reviewed before the PR body is drafted, so nothing unreviewed reaches GitHub. Its NO REPORT handling differs — the dispatching path still holds the PR, being the one that would otherwise merge it unattended |
| `review_site: coordinator` | the dispatching loop reviews each PR **after it opens**, before it merges — centralised, single writer, one place to read every outcome |
| key absent | `coordinator`, for cost. On `agent` every worker runs the full reviewer fan-out itself, once per fix round: 30–45 agent invocations to ship one issue, measured on this plugin's own repo. Every PR is still reviewed before it merges. The accepted cost is that a diff is visible on GitHub, and runs CI, before it is reviewed. That matters for a PUBLIC repo, and **the seed rule does not cover every PUBLIC repo**. `setup-config` writes PUBLIC → `agent` only where it writes the key, and a config reaches this default precisely because it never did: it predates the key, or was hand-written. A PUBLIC repo in that state runs `coordinator` until a `setup-config` refresh adds the seeded `agent`. The dispatchers must not read visibility themselves to close the gap, because a derived site is what decision 4 forbids (`SKILL.md`, "never leave the key out so a skill can read visibility at run time"). Like an absent `review_agent`, an absent key still reviews; it only chooses where |

On the `agent` site the gate's TIMING matches `send-it`'s, but its NO REPORT handling does not:
the dispatching path still holds the PR, because it is the one that would otherwise merge it
unattended.

**This key chooses the site, never the agent and never whether.** Which agent runs is
`review_agent`'s resolution order in the section above — unchanged by this key, and deliberately
not restated here, because an order written twice drifts into an order honoured in neither place.
No value of `review_site`, and no absence of it, turns the gate off. Only `review_agent: skip`
does, and that still prints the SKIPPED line.

**A Blocking finding is never merged past.** On the `coordinator` site `dispatch-ready` treats one
exactly like a failed check — surface it named, one redispatch carrying the finding as context,
then the `blocked` label — and never parks it back in Ready. That path lives in
`dispatch-ready` §2; this key only decides whether it is the path that runs.

**`NO_CONFIG` is not a hole in this.** `take-it` and `dispatch-ready` are the two workflow skills
that stop outright on `NO_CONFIG` rather than degrading (the `work-recommendations` and
`work-fire-watch` front-ends stop with them, on `take-it.md`), so an unconfigured repo dispatches nothing
and therefore produces no unreviewed PR by this route. The absent-key default covers the other
half: a repo configured before this key existed still gets a review, at `agent`, until its next
`setup-config` run writes a value.

#### Why this key is CONFIGURED and not DERIVED

This is a deliberate exception to *configure only what cannot be derived*, the governing principle
at the top of this document, and the reason has to live beside the key rather than in the commit
that added it.

Visibility **is** derivable — `gh repo view --json visibility` answers it on any run — so a literal
reading of the principle deletes this key and reads visibility live. Do not. **Deriving it live
means a visibility change silently rewrites the repo's review architecture.** Taking a repo private
would downgrade it from pre-PR review to after-the-fact review with nothing announcing the change:
no config diff, no prompt, no line in any run's output. That is the failure class
[#187](https://github.com/Sassy-Dog/skills/issues/187) documents — a visibility transition
silently disabling the protections a repo was relying on — and a review architecture that changes
when nobody chose to change it is the same defect with a different subject.

Seeding once at setup and recording the resolved value keeps the derivation's benefit — nobody
hand-picks a default — without the silent flip, and it leaves room to choose on grounds other than
exposure: cost, latency, or a repo that simply wants stricter review than its visibility implies.

So `setup-config` reads visibility **once**, at setup, and writes the resolved value explicitly:

| `visibility` | Seeded `review_site:` |
| --- | --- |
| `PUBLIC` | `agent` |
| `INTERNAL` / `PRIVATE` | `coordinator` |

In a public repo a bad diff is world-visible the instant it is pushed, so pre-PR review earns its
cost; internally that exposure argument mostly evaporates. **A refresh carries the value forward.**
It is the one configured fact update mode must not re-derive from live state — where live
visibility no longer matches what the value was seeded from, that is a *stop and surface*, exactly
as a `merge_queue` disagreement is, and never an automatic rewrite.

### `review_surfaces` — read by `send-it`, steers `pr-review-orchestrator`

**Optional, and omitted by default.** A glob → reviewer map that steers the shipped orchestrator's
path classification — the third tier, between the plugin's built-in heuristics and authoring a whole
agent. A repo whose infrastructure lives in `ops/` rather than `infra/`, or whose executable
artifacts are Markdown, can route those paths to the right specialist without owning an agent.

```yaml
review_surfaces:
  "ops/**":         sassy-dog:infra-platform-reviewer
  "skills/**/*.md": sassy-dog:code-quality-reviewer
  "**/*.bats":      sassy-dog:testing-reviewer
```

**Values are restricted to the nine reviewers this plugin ships** — `architecture-reviewer`,
`code-quality-reviewer`, `security-reviewer`, `testing-reviewer`, `cicd-release-reviewer`,
`infra-platform-reviewer`, `observability-ops-reviewer`, `dx-docs-reviewer`,
`dependency-supply-chain-reviewer` — with or without the `sassy-dog:` prefix, the bare name meaning
the namespaced agent. Nothing else is legal. An agent living in someone's own `~/.claude/agents/`
resolves on the machine that wrote the map and nowhere else, so a map naming one would steer for its
author and steer nothing for everybody else — the same class of failure as fanning out to an agent a
consumer repo lacks ([#236](https://github.com/Sassy-Dog/skills/issues/236)).

**An unresolvable value is a loud error, never a skipped surface.** The orchestrator validates the
map before it dispatches anything; on any bad value it discards the **whole** map, classifies by its
built-in table, reviews the diff as it otherwise would, and returns a **Blocking** finding naming
every offending entry. A typo therefore costs the repo its steering and never its review, and
`send-it`'s Blocking → "fix and re-run" mapping is what makes it loud. A partly-applied map is
deliberately not on offer: some paths steered and some not is precisely the state no report could
describe. A glob that matches nothing is not an error — the map describes the repo's layout, not one
diff.

**The map only ever adds routes.** A path it matches goes to the mapped reviewer *in addition to*
every built-in row it already matched; no form of it removes a route. Under-dispatch is invisible
where over-dispatch is merely slower, and an override-shaped map sits one line away from stripping a
route that exists precisely because it is easy to miss — `"**/*.md"` pointed at `dx-docs-reviewer`
would send a repo whose skill bodies *are* its source back to being reviewed as prose. A repo that
needs a route **removed** has outgrown this tier and wants its own `review_agent:`.

**It reaches the orchestrator only through `send-it`,** which forwards it verbatim in the dispatch
brief without validating it; the orchestrator never reads config itself. Two consequences: a
`review_agent:` naming a repo's own agent is handed no map — the key has no contract outside the
shipped orchestrator, and `send-it` reports that on the run — and `take-it` / `dispatch-ready`, which
open their own PRs without invoking `send-it`, never forward one, so the orchestrator falls back to
its built-in classification there. Those two paths do still run a review, under the
`review_site:` key above; it is an *unsteered* one. Forwarding this map to them is a separate change, not something
the key already does.

**`setup-config` never proposes this key.** There is no detection for it and there should not be:
the globs are a deliberate statement about a repo's layout, and a generator guessing them would be
the no-invention rule's failure mode with a config file to make it look considered. It is hand-set,
by a user who asked for it.

### `stacked_prs` — read by `groom-backlog`, `take-it`, `dispatch-ready`, `send-it`

Presence enables GitHub [stacked PRs](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs): `groom-backlog` may propose a `stack:` chain, and the dispatchers may build one. **Absent is the correct value for a repo that has not deliberately opted in**, and it is absent everywhere today.

Three things are deliberately NOT configured here, because they are derived:

| Fact | How it is obtained |
| --- | --- |
| Is this repo enabled for stacks? | `sassy-dog:pr-shepherd` → `scripts/stack-probe.sh` (REST `GET /repos/{o}/{n}/stacks`, 200 vs 404) |
| Is a given PR a stack layer, and which? | the same probe (GraphQL `PullRequest.stack`) |
| Is it safe to merge this layer now? | the probe's derived `lower_open` |

The preview is still rolling out per-repo, so enablement is exactly the kind of fact that would go stale the day after it was written down. Config carries only the *policy* — may we stack here, and how deep.

**`stacked_prs` and `merge_queue: true` together are refused at merge time,** not at config time: GitHub's queue support for stacks is still rolling out, and `pr-shepherd` stops with exit 24 rather than guessing. Setting both is legal — it simply means the dispatchers may open stacks that a human has to land.

### `execution_site` — read by `dispatch-ready`, `take-it`, `groom-backlog` and `survey-work`

```yaml
execution_site: mac
```

Written into the `.claude/sassy-dog/*.md` file of each skill that reads it — `dispatch-ready.md`,
`take-it.md`, `groom-backlog.md` and `survey-work.md` — like every other shared block. A value in
any other file is carried across verbatim by every refresh and read by nobody.

A free-form lowercase token naming the workstation this checkout runs on. It is the config half of
the **execution-site contract** ([#322](https://github.com/Sassy-Dog/skills/issues/322)):
some work is executable only from one machine — the host holding a vendor's multi-GB images, the
sibling checkout, the network reach — and nothing in the workflow skills could express that.

The issue half is a **label**, `site:<name>`, which `github-issues`' `queue-snapshot.sh` reads off
the labels it already fetches and emits as a per-issue `sites`
([#340](https://github.com/Sassy-Dog/skills/issues/340)). An issue with no such label runs
anywhere.

**It is a label and not a body line on purpose.** The three body contracts beside it — `touches:`,
`Depends on #N`, `stack:` — can be quoted: an issue documenting the contract, or a template
carrying an unfilled placeholder, would declare a site by accident, and preventing that means
deciding what a fenced block, a code span, an HTML comment and their interactions mean. A label
cannot be quoted in prose. The script's header is the copy to trust for the resolution rules; three
of them matter to whoever writes a config:

- **The match is a prefix on the label name, folded.** `site:vdi`, `SITE:vdi` and `site: VDI` are
  one declaration; `offsite:x` and a label named `website` are not declarations at all. A bare
  `site:` with no value names no site.
- **Several `site:` labels are a CONFLICT, never "any site".** `sites` is a sorted list and there is
  deliberately no scalar beside it: `[]` means any site, one member means that site, and more than
  one means only a checkout **named among them** may take the issue — narrowing, never widening.
  A scalar would be null for *both* "nothing declared" and "several
  declared", so its obvious reading — `site is None or site == execution_site` — turns a conflict
  into "any site", which re-creates
  [#322](https://github.com/Sassy-Dog/skills/issues/322)'s originating bug with two labels
  instead of none. The list's obvious reading, `not sites or execution_site.lower() in sites`,
  cannot.
  **Read `sites`; a reader that wants a scalar has to decide what a conflict means first.**
- **The comparison is case-insensitive on both sides, and the value is data.** `queue-snapshot.sh`
  folds the label's value; folding the configured value is the reading skill's half, so write it
  `not sites or execution_site.lower() in sites` — write `execution_site` lowercase by convention,
  but never implement the match as plain equality against
  the raw config value, since `execution_site: VDI` would then hold the VDI loop's own work
  ([#341](https://github.com/Sassy-Dog/skills/issues/341)). No character
  grammar is applied to a label value: labels are created through the UI or API by somebody with
  triage and are visible on the issue. A consumer still treats the value as data — quote it, never
  build a command or a URL by concatenation.

**This key fits the config model unusually well.** Config is per-checkout by construction — one
`.claude/sassy-dog/` tree per clone, never shared — and the site is exactly a per-checkout fact.
That is why it is configured rather than derived, and it is not the `review_site:` exception
repeated: the machine's *kind* is derivable, but the resolved name is the **user's**, because `vdi`
carries a meaning no platform string does.

**Where a proposal would come from, when one exists.** The source is `uname -s`, not a language
runtime's platform constant — an agent following this contract runs a shell:

| `uname -s` | Proposed name |
| --- | --- |
| `Darwin` | `mac` |
| `MINGW64_NT-…` / `MSYS_NT-…` / `CYGWIN_NT-…` | `windows` |
| `Linux` | **no proposal** |

`Linux` gets none on purpose. It is what every cloud and scheduled-routine session reports, and a
container that exists for one run is not a workstation with a name — proposing `linux` there would
write a site into a checkout that should answer to none. A Linux user whose machine *is* a
workstation names it themselves, like everybody else.

**Absent means this checkout answers to no name.** There is then nothing for a `site:` label to be
compared against, which is presence-is-the-toggle behaving as it does everywhere else. A repo whose
work all runs from one machine should simply omit it.

**How a refresh treats this key is `setup-config`'s guardrail list, which owns that rule and is the
copy to trust** — deliberately a pointer rather than a restatement, because the rule was written out
in five places once and the copy that drifted was found by a reviewer rather than by anything that
fails. `update-mode.md` and `migrate-mode.md` carry the operational side for their own modes, since
a mode reads its own file and inherits nothing; `interview.md` §3d carries the question's own half —
which modes ask it, and why a refresh is not one of them
([#343](https://github.com/Sassy-Dog/skills/issues/343)). **Do not read that as a closed
set.** It was asserted as one, and was wrong on landing: `interview.md` states §3d's refresh
semantics from *outside* §3d as well. A count with nothing re-deriving it is what this repo's own
convention warns about, and a "nothing else restates it" clause is that shape at its worst — it
reads as verified and is checked by nothing.

**Who reads it, by the change that adds the reader.** The label read and this contract landed first
and alone ([#340](https://github.com/Sassy-Dog/skills/issues/340)), so that each consumer
stayed small enough to review:

| Change | Adds |
| --- | --- |
| [#341](https://github.com/Sassy-Dog/skills/issues/341) | `dispatch-ready` skips a Ready issue whose `sites` excludes this value; `take-it` refuses one before claiming it |
| [#343](https://github.com/Sassy-Dog/skills/issues/343) | `groom-backlog` requires the declaration before Ready; `survey-work` shows the site on backlog lines; `setup-config` asks for this key |

**Read the skill, not this table, for what a given release does.** The table says which change
introduces each reader, not which of them have landed — deliberately, because the alternative is a
sentence about issue state that nothing re-derives. Getting it wrong in the "not yet" direction is
the one that bites: a reader who concludes the key is inert skips it on a mac checkout, which turns
the site filter off — #322's originating bug, reintroduced by its own contract.

**Cross-site dispatch is a non-goal** at every stage: the contract only lets a loop on one site step
around work that belongs to another, and say so.

## Per-skill schemas

The applicability inventory below includes shared blocks; the YAML examples in the subsequent
sections show only each skill's additional keys. Shared-block policy above remains authoritative.

### Template applicability inventory

Each row accounts for one `references/templates/<skill>.config.md`, including the unchanged
`tidy-repo` template. Paths enumerate **leaf slots**, with dots denoting nested frontmatter keys.
`scripts/test-doc-reconciliation.sh` compares this roster to every tracked template and compares
these paths to its actual frontmatter, not to key mentions in comments or body prose.

- **Always-written** means written whenever that config file is selected, not that all six files
  must be selected. These slots precede the template's `# optional` boundary.
- **Conditional** slots follow that boundary: write only for applicable verified facts or existing
  consent, per the shared-block rules and interview. This column describes the block form of
  product surfaces; the existing scalar `none` alternatives and their verification rules are
  unchanged. A conditional slot is not a new default or another interview.
- **Hand-set** fields have no generated slot. Preserve a user's existing value, but never propose
  one. `none` in this column means no hand-set field, not a rendered config value.
- A field absent from a row is **inapplicable to that template**, not a missing slot to fill from
  the entire shared example. In particular, the dispatchers use `send-it`'s review-agent choice;
  they do not acquire their own `review_agent` or `review_surfaces` slots. `dispatch_model` is
  not a config key.

| Template | Always-written | Conditional | Hand-set |
| --- | --- | --- | --- |
| `survey-work` | `scan_paths`, `exclude_pathspecs`, `ci_workflow`, `priority_labels`, `write_policy` | `execution_site`, `sentry.org`, `sentry.projects`, `sentry.gate`, `board.number`, `board.owner`, `board.project_id`, `board.status_field_id`, `board.ready_option_id`, `board.backlog_option_id`, `board.in_progress_option_id`, `testflight.bundle_id`, `mobile.release_workflow`, `mobile.path_prefix`, `posthog`, `secret_bootstrap` | none |
| `groom-backlog` | `gotcha_summary` | `execution_site`, `stacked_prs.max_depth`, `board.number`, `board.owner`, `board.project_id`, `board.status_field_id`, `board.ready_option_id`, `board.backlog_option_id`, `board.in_progress_option_id` | none |
| `take-it` | `stack_summary`, `preflight_commands`, `pr_template_sections`, `merge_queue`, `review_site` | `claim_label`, `execution_site`, `stacked_prs.max_depth`, `board.number`, `board.owner`, `board.project_id`, `board.status_field_id`, `board.ready_option_id`, `board.backlog_option_id`, `board.in_progress_option_id`, `migrations.dirs`, `migrations.regen_command`, `codegen.hint` | none |
| `dispatch-ready` | `max_in_flight`, `merge_queue`, `review_site` | `claim_label`, `execution_site`, `stacked_prs.max_depth`, `board.number`, `board.owner`, `board.project_id`, `board.status_field_id`, `board.ready_option_id`, `board.backlog_option_id`, `board.in_progress_option_id`, `migrations.dirs`, `migrations.regen_command`, `codegen.hint` | none |
| `send-it` | `pr_template_path`, `pr_template_sections`, `preflight_commands`, `merge_queue` | `stacked_prs.max_depth`, `migrations.schema_dir`, `migrations.dirs`, `migrations.regen_command`, `codegen.command`, `codegen.output_dirs`, `review_agent` | `review_surfaces` |
| `tidy-repo` | `dep_version_globs`, `noise_allowlist`, `never_discard` | `claim_label` | none |

Use the **same selected board block** in the four rows that list it, with every field from the
shared block above; omit it wholesale for a boardless repo. Read the actual project owner and IDs
from the selected board, never infer the owner from the repo slug or invent missing IDs.
`migrations.schema_dir` is a `send-it` input only; the dispatchers need the existing
`migrations.dirs` / `migrations.regen_command` coupling inputs. Likewise `codegen.hint` is for
the dispatchers, while `send-it` takes `codegen.command` / `codegen.output_dirs`.
`claim_label` is conditional on the repo's claim-label flow, including tidy-repo's existing
interview §4b condition; it is not an unconditional placeholder to leave unresolved.

Both `review_site` slots take the **already-resolved choice** from Phase 1, including a user
override, or the carried-forward choice from Phase 4. They are outside optional omissions.
This does not make `review_agent` required: omission selects the shipped orchestrator, and an
explicit override or `skip` remains valid. Preserve hand-set `review_surfaces` in `send-it`
without guessing a map. User-confirmed `execution_site` and approved `stacked_prs.max_depth`
reach only their enumerated consumers; declined opt-ins remain absent, and refresh follows the
existing carry-forward rules. No new seeding or proposal table belongs in these templates.

### `survey-work.md`

```yaml
scan_paths: apps packages          # tech-debt scan roots
exclude_pathspecs: "packages/db/src/migrations"   # BARE — never `:(exclude)`-prefixed
ci_workflow: ci.yml
priority_labels: [p0, p1, p2]
write_policy: read-only            # or `gated` to allow the Sentry->GitHub file path
```

`exclude_pathspecs` values are **bare paths**. `repo-health`'s `pull-tech-debt.sh` supplies the
`:(exclude)` magic itself, so a prefixed value used to reach git as `:(exclude):(exclude)<path>` — a
valid pathspec matching nothing, which excludes nothing and exits `0`, silently disabling the
exclusion ([#365](https://github.com/Sassy-Dog/skills/issues/365)). The script now strips
one leading `:(exclude)`, so a config already carrying the old spelling needs **no edit** — write
new ones bare. That is not the same as nothing to do: the strip lives in the plugin, so a consumer
repo keeps scanning with the exclusion disabled until the plugin is updated **for that checkout**.
Do not assume an ordinary update reached it: every repo this paragraph addresses declares the
plugin in its `.claude/settings.json`, which is precisely what creates a **project pin**, and
against a project pin the bare `claude plugin update` reports success at user scope while moving
nothing for the checkout it ran in. The working procedure, and the cheaper route that avoids it,
are in `repo-health`'s "Plugin drift (which checkouts run a stale plugin)" section — which owns
that answer, so it is deliberately not restated here.

Values are passed to git **literally**, so a `**` is a git pathspec and never a shell glob; the
loop is fenced with `set -f` for exactly that reason. Do not write a value expecting shell
expansion, and note that both spellings are equivalent only because of that fence — unfenced, bash
expands a bare `src/generated/**` (skipping dotfiles, so `src/generated/.hidden.txt` leaks) while it
cannot expand the prefixed form.

A value that is unusable after the strip — a lone `:(exclude)`, or anything whose remainder still
begins with `:` — is **dropped with a warning on stderr**, never passed through. A bare `:(exclude)`
is an empty pattern that git honours as "exclude the entire tree", which would report zero tech debt
at exit `0`. All of this is pinned by `scripts/test-tech-debt-excludes.sh`.

Prose sections: `## extra-surfaces`, `## scoring-overrides`, `## extra-guardrails`.

### `groom-backlog.md`

```yaml
gotcha_summary: >
  Repo-specific traps a cold sub-agent must know before an issue is dispatchable.
```

Prose sections: `## extra-rubric`.

#### `gotcha_summary` carries INVARIANTS ONLY

**An invariant is a trap that stays true until someone changes the architecture. A status is a fact
about today.** This field takes the first and never the second — because it is the one field the
format protects with neither of its two mechanisms. It is not *derived* (nothing recomputes it after
setup, unlike every fact in the table above), and it is not *prose* (it sits in frontmatter, so it
is outside the `##` lane a human curates when reality moves). Nothing revisits it, ever, and
`groom-backlog` copies it into issue bodies read by a cold worktree agent that has no way to check
it.

Good — invariants, all still true a year later:

```yaml
gotcha_summary: >
  Business logic lives in `crates/`, never in the Tauri shell. Renaming `LEGACY_SERVICE` orphans
  every stored credential. Migrations are irreversible in this repo — additive changes only.
```

Rotting — every one of these is a status:

```yaml
gotcha_summary: >
  The release path WORKS as of 2026-08-15. #15 is not finished — #308 (updater) and #334
  (Windows + Authenticode) remain. Windows signing is next up after the 1.2 milestone.
```

Four shapes are banned outright:

| Banned | Example | Why |
| --- | --- | --- |
| An issue number with a state claim | `#334 (Windows + Authenticode) remains` | The issue closes; the sentence does not |
| "X remains" / "still open" / "not finished" | `the updater is still unfinished` | Asserts a moment, reads as a rule |
| "as of `<date>`" | `the release path WORKS as of 2026-08-15` | Its own timestamp is the tell |
| Roadmap status | `Windows signing is next up` | Plans move; this field does not |

**This is not hypothetical.** `Sassy-Dog/solador` carried the rotting example above from 2026-08-15
onward. All three issues closed within two days — #308 on the 16th, #334 and #15 on the 17th — and
nine days later the config still asserted they were open, ready to be written verbatim into a fresh
issue body (issue #249). The same repo asserted the same class of claim in `survey-work.md`'s
`## extra-guardrails`, a **prose** section, and *that* copy was corrected within two days. Same
repo, same week, same kind of claim: the lane with a human curator got maintained and the
frontmatter one rotted. The rule above exists because that seam is in the format, not in one
operator.

Two mechanics back the rule up, and neither replaces it:

- **At injection.** `groom-backlog` §4 never copies this field into an issue body directly. It runs
  `github-issues`' `verify-gotcha-claims.sh`, which resolves every cited `#N` against real issue
  state and **drops** any claim whose asserted state is wrong *or unresolvable* — unknown is held,
  never passed through — then injects only what survived. **Keep inline code spans paired.** An
  unpaired backtick run makes the field unparseable, and the verifier drops all of it rather than
  split it into fragments that may be truncated (issue #262) — one stray `` ` `` therefore costs
  every gotcha in the field, not just its own sentence. Where the pairing is merely *wrong* rather
  than unpaired — two stray ticks, so every run still finds a partner — the fragments of a sentence
  are kept or dropped **together**, so the worst case is losing that sentence, never certifying half
  of it. Splitting requires positive evidence of a sentence start, so a sentence following an
  abbreviation-shaped token (`U.S.`, `No.`, or any word of four characters or fewer) is welded to
  its predecessor and can be dropped with it — **write each gotcha as its own sentence ending in a
  full word** if you want it judged independently. Write a literal backtick as `` `` ` `` `` rather than bare.
- **At refresh.** `verify-gotcha-claims.sh --config <path> --lint` reports the four banned shapes
  offline (no `gh`, no network; exit 3 = findings), so a config that already carries them can be
  **named** rather than carried forward unexamined. It reports an unpaired backtick run too, and it
  evaluates whole sentences rather than fragments, so it never shows you a fragment you did not
  write as if it were your claim. A refresh
  regenerates frontmatter, so an offending `gotcha_summary` is rewritten with the user, not
  silently preserved.

**Both mechanics are a deliberate interim, not the intended end state.** The deeper fix is moving
`gotcha_summary` out of frontmatter and into the `##` prose lane, where a human curator already
maintains everything else that cannot be re-derived — and it is deliberately separate work, because
it is a format migration reaching every consumer config, which this org rolls out by filing an issue
per repo rather than as a direct cross-repo sweep. Read the verifier as the backstop it is: do not
take it for the design, and do not "just move the field" as a tidy-up inside one repo.

### `take-it.md`

```yaml
stack_summary: Bun workspaces monorepo; Next.js 15 web + Drizzle db package
preflight_commands: |
  bun run lint
  bun run typecheck
pr_template_sections: [Summary, Testing, Risk]
```

Prose sections: `## subagent-rules`, `## extra-guardrails`.

### `dispatch-ready.md`

```yaml
max_in_flight: 3
```

Prose sections: `## extra-sequencing`.

### `send-it.md`

```yaml
pr_template_path: .github/pull_request_template.md
pr_template_sections: [Summary, Testing, Risk]
preflight_commands: |
  bash scripts/preflight.sh
```

Prose sections: `## extra-gates`, `## extra-guardrails`.

### `tidy-repo.md`

```yaml
dep_version_globs: ["**/package.json", "**/bun.lock"]
noise_allowlist: ["*.log", ".DS_Store"]
never_discard: [".env.local", "*.pem"]
```

Prose sections: `## extra-cleanup`, `## extra-guardrails`.

## Prose sections

Section names carry over verbatim from the `BEGIN/END PROJECT-SPECIFIC` fence slots the old
generated skills used, so migration is a mechanical lift:

| Old fence slot | New config section | File |
| --- | --- | --- |
| `extra-surfaces` | `## extra-surfaces` | `survey-work.md` |
| `scoring-overrides` | `## scoring-overrides` | `survey-work.md` |
| `extra-rubric` | `## extra-rubric` | `groom-backlog.md` |
| `subagent-rules` | `## subagent-rules` | `take-it.md` |
| `extra-sequencing` | `## extra-sequencing` | `dispatch-ready.md` |
| `extra-gates` | `## extra-gates` | `send-it.md` |
| `extra-cleanup` | `## extra-cleanup` | `tidy-repo.md` |
| `extra-guardrails` | `## extra-guardrails` | four files |

All eight slots must round-trip through migration. The old `update-mode.md` slot list omitted
`extra-rubric` and `extra-sequencing`; that omission is fixed here.

Prose is never generated or rewritten by a refresh — it is carried across verbatim, which is the
whole point of keeping it separate from the frontmatter facts.

## How skills read this

Each skill inlines its config at load time with dynamic context injection:

```text
!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root:-<not a git repo>}"; cat "$root/.claude/sassy-dog/<skill>.md" 2>/dev/null || echo "NO_CONFIG"`
```

`git rev-parse` rather than `${CLAUDE_PROJECT_DIR}` because the substitution order between
placeholder expansion and shell execution is not specified, and every one of these skills requires
a git repo regardless. The command is safe outside a repo — it yields `NO_CONFIG` with no stderr.

**Where the harness never runs the line.** Claude Code runs it at load time; omp renders it as
text. The four skills that degrade silently on a missed config — `send-it`, `survey-work`,
`groom-backlog` and `tidy-repo` — therefore carry one paragraph directly under the line: if the line
reached the agent as text (it starts with `!` and has no `CONFIG_SOURCE:` output beneath it), read
`<repo root>/.claude/sassy-dog/<skill>.md` by absolute path, treat a missing file as `NO_CONFIG`, and
never read an unrun line as "no config exists". On Claude Code the condition is false, so the
paragraph is inert there. The four that stop on `NO_CONFIG` (`take-it`, `dispatch-ready`,
`work-recommendations` and `work-fire-watch`) do not carry it, because the unchanged `take-it` and
`dispatch-ready` were right in 12 of 12 omp runs ([`docs/HARNESS-PORTABILITY.md`](../../../docs/HARNESS-PORTABILITY.md),
"Config-fallback paragraph (#455)"). `work-recommendations` and `work-fire-watch` were **never run**:
their inclusion is #455's decision rule (`take-it`'s runs used as evidence for an identical line in a
different skill and prompt), not a measurement. The runs were one model, one prompt shape per skill, a
dummy config and gh unauthenticated, so a skill that stops on `NO_CONFIG` must still never infer "no
config" from an unrun line. No gate pins the paragraph's text, its placement or its absence from the
stoppers yet; [#463](https://github.com/Sassy-Dog/skills/issues/463) tracks the gate. The paragraph is
not part of the config format, and `setup-config` neither writes nor checks it.

### `CONFIG_SOURCE` — why the block announces where it read from

**The block resolves against the SESSION's working directory, not the repo being acted on**, and
those are the same thing only when the session was started in the target repo. The harness pins cwd
to the session root and **resets it between Bash calls**, so an agent cannot `cd` into another repo
and re-trigger the load — whichever repo the session started in owns config resolution for the whole
session. Cross-repo work is therefore the exposed case: a sub-agent shipping in repo B, dispatched
from a session rooted in repo A, is handed A's config.

The failure is silent in exactly one quadrant, which is why it survived so long:

| Session-root repo | Result |
| --- | --- |
| Unconfigured | `NO_CONFIG` → the skill stops and asks ✓ |
| Configured, same as the target | correct ✓ |
| Configured, **different** from the target | **confident wrong answer**, silent ✗ |

`NO_CONFIG` already fails honestly. The third row did not, because a populated config from the wrong
repo is indistinguishable from the right one — the same class as a truncated API page reading as an
empty one. On 2026-08-18 two sub-agents shipping in `routines` and `skills` were
each handed `platform`'s Terraform gates (`terraform fmt`, `tflint`,
`infrastructure/environments/core`) while their real gates were `bats`/`ruff`/`actionlint` and
`scripts/preflight.sh`. Both caught it only by noticing the mismatch themselves — and since every
skill instructs that config be applied exactly as written, a *compliant* agent would have run the
wrong gates.

Hence `CONFIG_SOURCE`: the block names the path it read from, so the mismatch is visible rather than
inferred. Each skill's §1 carries the reconciliation rule inline — discard, re-read the target repo's
own file by absolute path, use that. The rule is inline rather than a pointer here on purpose: the
failure mode is an agent proceeding confidently without reading further, and a pointer is exactly
what such an agent skips.

**`NO_CONFIG` is a first-class state, not an error.** A skill that finds no config must derive what
it safely can, run in its most conservative mode, and tell the user to run
`sassy-dog:setup-config`.

### The no-invention rule

**"Derivable" means derivable from git or `gh` in this repo. It does NOT mean "reachable by some
other means."** This distinction is the whole safety property, and it is easy to lose.

Observed 2026-08-05: the generic `survey-work` was run in an un-migrated repo, correctly reported
`NO_CONFIG`, and then invoked the Sentry surface anyway and ran the tech-debt scan with the example
`SCAN_PATHS` from `repo-health`'s own docs. Sentry projects *are* listable for the org, and a scan
path *can* be guessed from the directory tree — so both looked derivable. The result was a plate
built on invented inputs that read exactly like a real one.

Two rules follow, and both are load-bearing:

1. **A surface with no config block is OFF**, however reachable it looks. Render it
   `skipped — not configured`.
2. **State the rule at the point of use, not only in the `NO_CONFIG` preamble.** The failure above
   happened because the instruction lived in §1 and the temptation lived in §3. By the time a skill
   reaches the pull section it has read a lot of text, and a parenthetical `*(if configured)*` is a
   weak signal against a concrete, available action. Each conditional surface must carry its own
   **ONLY if** guard.

The asymmetry that justifies the strictness: **skipping a surface knowingly is recoverable; acting
on a fabricated one is not**, because the output is indistinguishable from a real result. This is
sharpest in `send-it`, which pushes and merges on the strength of a pre-flight command — a guessed
command that exits 0 without running anything looks exactly like a passing check.

Skills that write or dispatch unattended (`take-it`, `dispatch-ready`) do not degrade at all; they stop.

## Cloud sessions and routines

A repo carrying these config files must also declare, in its own `.claude/settings.json`, both the
marketplace (`extraKnownMarketplaces` → `skills` from `Sassy-Dog/skills`) and the
plugin (`enabledPlugins` → `sassy-dog@skills`). Plugin skills enabled only in user settings
do not transfer to cloud sessions or scheduled routines — only repo-declared plugins install at
session start, and they install *from the marketplace the repo declares*. `enabledPlugins` alone
references the marketplace by name only; the name resolves locally through user-level registration
(`~/.claude/plugins/known_marketplaces.json`), which never reaches a cloud VM. Without both
declarations a scheduled `dispatch-ready` silently finds no skill, while every local session works fine.
