# Cloud fallback — section 2B without `gh`

How to pull stuck shipping, backlog heat, and workflow health when `gh` is not on PATH. Cloud (CCR)
routine sessions ship no GitHub CLI, so both bundled scripts exit 10 with `skipped: gh not on PATH`
— but everything they pull except one surface is still reachable through the session's GitHub MCP
tools. Accepting the skip would drop the PR, issue, and workflow surfaces AND every blind spot
assembled from them; this recipe keeps all of that and skips only what is genuinely unreachable.

This is a promotion, not an invention. The 2026-08-08 verification run (session
`cse_01TtAVPyUMLKmAk4h1ZXd2t9`) improvised exactly this shape — 14 active repos discovered via
list-repos, each attached with `add_repo`, per-repo pulls fanned out to 5 parallel subagents, the
Dependabot gap named on the coverage line — at subagent cost and with per-run variance. That
variance is not inherent to the shape and is no longer unexplained: three later runs failed in
three specific ways — GitHub's secondary rate limit, subagents clobbering each other's scratchpad
files, and whole-file fetches blowing the token ceiling — all traceable to an unbounded fan-out.
**"Bounding the fan-out" below turns each of them into a rule; follow the whole recipe, bounds
included, instead of re-deriving it per run.**

This recipe is shared. `whats-behind` follows it too — its `pull-version-drift.sh` walks local
checkouts a cloud session does not have, so a cloud currency audit rebuilds the roster and the
per-repo reads from the same MCP capabilities. Read every rule below as applying to a currency
audit as much as to a fire sweep; where the two diverge, the divergence is called out.

The scripts stay the primary path: whenever `gh` IS on PATH, run them. #98 tracks provisioning `gh`
into the cloud environment; once that lands, this recipe becomes the degraded path rather than the
only one.

## Resolve tools by capability, never by id

MCP tool ids vary by installation — different server prefixes per host app — so a hardcoded
`mcp__...` id is a recipe that breaks on the next session. Same convention the Sentry cron surface
already follows: describe the connected GitHub MCP server's tools by what they do and let the
session resolve them. The capabilities this recipe needs:

- **List repositories for an owner** — the roster.
- **Widen repo scope** — `add_repo` in current sessions. GitHub MCP tools typically start scoped to
  the repo the session opened in (the verification run started scoped to `skills` alone);
  every other repo must be attached before its PRs, issues, or runs can be read.
- **List or search pull requests** and **issues** — org-wide where the server offers it, per repo
  only as the fallback. Prefer the org-wide form; "Bounding the fan-out" explains why.
- **List workflow runs** — per repo for the CI-health surface (no org-wide form exists, so this is
  what the fan-out is for), but **scoped to a single workflow** for the cron-recovery
  cross-reference. The two are different queries and must not be shared — see "Also unreachable
  without `gh`" below.
- **Search code** — how the currency audit (`whats-behind`) reads `uses:`, `runs-on:`, and
  toolchain pins without fetching whole workflow files. If the server offers no code search, fall
  back to a narrowly scoped file-contents read per "Read fields, not files" — never a directory
  fetch, never a whole-repo crawl.

No GitHub MCP server connected at all → there is no fallback to the fallback: all of section 2B is
`skipped — <reason>` per section 1. Never turn "could not check" into silence.

<!-- rule: public-repo-push-attach -->
### A PUBLIC repo needs `access: "push"` — `read` attaches nothing

`add_repo` with `access: "read"` is a **no-op on a public repository**. The session's git proxy
already serves anonymous git reads, so the call succeeds, reports that read access "is already
available", and attaches nothing — the MCP tool allowlist is untouched. The next `actions_list` for
that repo then answers `Access denied: repository is not configured for this session`, which reads
like a permission problem and is not one.

**Retry with `access: "push"`. MCP tool scope follows the attach.** Verified across three runs of
the org sweep: 2026-09-02 tried `read` alone and covered 13 of 15 active repos; 09-06 and 09-07
retried with `push` and covered 15 of 15.

Three constraints on using it:

- **The elevated scope is an artifact of how `add_repo` works, not a licence.** The sweep reads; it
  never writes to an attached repo.
- **Name the repos attached this way on the report's sources line**, so the elevation is visible in
  the artifact rather than only in a session log.
- **A repo still unreadable after the retry stays `unread`** — never clean, never dropped from the
  count.

**Anonymous REST is not an alternative to this, and is not worth re-attempting.** Probed from inside
the routine container on 2026-09-07: every `https://api.github.com/repos/...` call is intercepted by
the session's egress proxy and answered with a synthetic 403 carrying no GitHub headers, including
for an unrelated public repo used as a control. Nothing anonymous leaves that container, so the
attach is the only route to a public repo's workflow runs.

## Order of operations

1. **Roster first.** List the org's repositories and capture per repo: name, archived flag, last
   push timestamp, default branch. The roster is the org, not the local directory (section 3), and
   it is the one hard prerequisite — every later step filters against it.
2. **Widen scope.** Attach each active repo with the scope-widening tool before any per-repo pull.
   Skipping this step does not fail loudly — an unattached repo simply comes back empty, which
   reads as "healthy" and is exactly the silent gap this skill exists to prevent.
3. **Fan out — bounded.** The per-repo pulls are chatty — dozens of raw workflow-run payloads would
   swamp the coordinating context. Dispatch parallel subagents at `B-Tier` (Claude Code:
   `model: "sonnet"` · omp: `model: "@task"`), each owning a batch of repos, each
   returning ONLY the compact per-repo JSON mapped below and each writing to its own distinct
   scratchpad path. Issue the batch in a single message with multiple Agent calls, **at most 3 in
   flight at once**. Read "Bounding the fan-out" before dispatching: the caps on concurrency, the
   distinct output paths, and the read-fields-not-files rule are what keep this step from costing
   more than it saves.
4. **Reassemble.** Merge the subagent outputs into the same two JSON shapes the scripts emit, so
   sections 3–5 consume the report identically. Read each batch back from its own distinct path —
   never a shared filename. A surface a subagent could not pull degrades the way the scripts
   degrade: empty list plus a named entry in `partial` / on the sources line — never a hole.

## Bounding the fan-out

Keep the fan-out — it is what lets an org-wide sweep finish inside a routine window. But an
unbounded fan-out has now cost three production runs more than it saved. Each rule below exists
because a run failed without it.

### Cap concurrency at 3 subagents, and stay sequential inside a batch

At most **3 subagents in flight at once**. If there are more repos than that divides evenly, give
each subagent a longer list — never add a fourth agent. Inside a batch, pull repos one at a time:
no nested fan-out, no burst of one concurrent call per repo.

The 2026-08-10 weekly run fanned 5 subagents across ~9 repos and issued concurrent per-repo PR
searches. GitHub answered with its secondary rate limit:

```text
403 You have exceeded a secondary rate limit... [retry after 57s]
```

It recurred on nearly every repo in the batch. Recovery cost roughly **8 minutes of wall clock
across four backoffs** — more than querying every repo sequentially would have taken end to end —
and one subagent gave up mid-task and returned incomplete, so the coordinator re-did that work
itself, sequentially. **Backoff costs more than sequencing.** Secondary limits fire on concurrent
bursts against the same endpoint rather than on total volume, so the lever is fewer simultaneous
calls, not fewer repos.

Two consequences worth stating outright:

- **On the first 403, stop re-firing the burst.** Finish the remaining repos sequentially in the
  coordinator instead of sleeping and re-dispatching the same shape — parallel retry is what turns
  one 57-second wait into four. A rate-limited run that finished sequentially is a success; a
  subagent that returned incomplete is a `partial` entry, never a silent gap.
- **Prefer one batched query over N per-repo calls** wherever the server offers it (an org-wide
  open-PR or open-issue search beats a per-repo list in the fan-out). Batching is the single
  largest reduction in burst pressure available here, and it shrinks the fan-out's job to the
  surfaces that genuinely have no org-wide form — chiefly per-repo workflow runs.

### Give every subagent a distinct output path

When subagents write to the session scratchpad, the coordinator MUST hand each one an explicit,
distinct filename keyed by its batch index — `fanout-batch-1.json`, `fanout-batch-2.json`, … — and
reassemble from those exact paths. Never let a subagent choose its own filename, and never let two
of them be handed a generic one.

The 2026-08-11 daily run dispatched 5 subagents into one shared scratchpad directory; several wrote
the same generic name (`final.json`) and raced. One agent found its output file overwritten mid-run
with unrelated content. The figures in that report survived only because the agent noticed and
recovered — the design did nothing to prevent it. The deeper cost is interpretive: clobbered output
is indistinguishable from a subagent returning wrong data, so a mundane filename collision becomes
an unanswerable question about the report's provenance. Distinct paths remove the ambiguity
outright.

If a subagent reports that its output file changed underneath it, treat that as a fan-out defect:
name the affected surface in `partial` and re-pull that batch rather than trusting either version.

### Read fields, not files

Pull the smallest thing that answers the question. Workflow and manifest files in this org are
large — `tailoredtip/release.yml` alone is 1,417 lines, and monorepo workflows in `platform` and
`velovate` are comparable — and a whole-file fetch simply fails:

```text
Error: result (135,933 characters) exceeds maximum allowed tokens. Output has been saved to ...
```

Three fetches blew the ceiling in the 2026-08-11 weekly run, at 65,953 / 101,018 / 135,933
characters, each forcing a detour through the saved temp file plus ad-hoc `jq`/`python3` extraction
before the run could continue.

Neither consumer of this recipe needs whole files. The fire sweep needs workflow *run* metadata,
which the workflow-runs capability returns without touching file contents at all. The currency
audit needs only `uses:` pins, `runs-on:` labels, and toolchain version pins. So:

- **Search for the field, don't fetch the file.** A code-search capability scoped to the token and
  path (`uses:` or `runs-on:` under `.github/workflows`) answers the currency questions in one
  call per org, not one fetch per workflow.
- **When a file genuinely must be fetched, request the narrowest form the server offers** — a
  single explicit path, never a directory; a line range where supported.
- **When a fetch does exceed the ceiling, do not re-fetch and do not retry the same call.** The
  tool has already written the full result to a file; grep that file for the fields you need. The
  detour is recoverable, but it is a detour — the retry is what wastes the window.
- **Never read a file to enumerate repos, PRs, issues, or runs.** Those come from the list and
  search capabilities above, already compact.

## Field map — `pull-org-github.sh` equivalent

| Script field | MCP equivalent |
|---|---|
| `repos[]` — `name`, `archived`, `pushed_at`, `default_branch` | List-repositories capability for the org; read the same four attributes. |
| `prs[]` — `repo`, `number`, `title`, `url`, `draft`, `author` | ONE org-wide open-PR search where the server offers it; per-repo listing inside the fan-out only as the fallback. The batched form is the primary defence against the secondary rate limit — see "Bounding the fan-out". |
| `prs[].idle_days`, `prs[].age_days` | Not served by any tool — compute `floor((now - updated_at) / 86400)` and the same from `created_at`. Whole days, floored, so every consumer ranks on the same clock. |
| `issues[]` — `repo`, `number`, `title`, `url`, `labels`, `idle_days` | Open-issue search or list, same scoping and the same batched-first preference; flatten `labels` to names; compute `idle_days` as above. |
| `partial[]` | Any surface whose pull failed: emit the empty list and name the surface, exactly as the script does. |

Carry the script's two load-bearing invariants (its header explains both):

- **Archived repos stay in `repos` (flagged) and stay OUT of `prs` and `issues`.** Search happily
  returns hits from archived repos — at Sassy Dog that silently adds dozens of dead lupita issues
  and skews the ranking. Filter both lists against the roster.
- **Precompute the day counts once at assembly.** Raw timestamps left for section 4 to interpret
  produce a different clock per run.

## Field map — `pull-repo-signals.sh` equivalent

Per active repo, from the workflow-runs capability: sample the most recent ~25 runs (the script's
`RUN_LIMIT`), then reduce over **completed** runs only. This is the one surface with no org-wide
batched form, so it is the fan-out's real job — keep it to 3 subagents in flight, one repo at a
time inside each. Every field here comes from run metadata; **never open a workflow file to
populate this table** (the token ceiling is why — see "Read fields, not files").

| Script field | MCP equivalent |
|---|---|
| `runs_sampled`, `failures`, `failure_rate` | Count completed runs and completed-with-`failure`; rate is failures / sampled × 100, rounded; null when nothing was sampled. |
| `default_branch_ci` | Conclusion of the MOST RECENT completed run on the default branch whose event is `push` or `merge_group`. Never widen to `schedule` — the push/schedule split is load-bearing (section 2B). **Null when the sample holds no such run** — that is unknown, never clean and never P0 (`scoring.md`). Recover it before reporting: re-issue the runs call for that repo narrowed to `{branch: <default_branch>, status: completed, event: push}` and reduce the result the same way. All three are load-bearing — `event` is the half that does the work (a busy default branch is crowded by `schedule` runs, which a branch filter keeps), and `status` is the one a single-row re-query cannot walk past without. |
| `default_branch_ci_age_days`, `default_branch_ci_url` | Age in days of the run the verdict came from, and its link — projected from the SAME run, never from a different one. The recovery is not bounded by the sample size, so the verdict can be weeks old; `scoring.md` bounds both directions at 14 days and cannot apply that rule without these. **The age is null when the run carries no usable timestamp** — emit the null rather than a guessed date, and never read it as "recent": `scoring.md` resolves an undated conclusion the way it resolves one past the bound, so a `success` lands in the stale-verdict section and a `failure` ranks P1. `last_failure` is derived from the sample, so a RECOVERED failure has none beside it and this url is its only link. |
| `default_branch_runs_seen` | Push-class runs on the default branch, counted **regardless of status**, over whichever query answered. **Three-state** (`scoring.md` renders one sentence per state): `0` only from a recovery that ANSWERED and found none; non-zero means they are all still in flight; `null` when the recovery could not be read — a failed call must never be reported as `0`, which is a positive claim. Bounded by whichever query answered, so read the split, never the total. |
| `scheduled_failing[]` | Group `schedule`-event runs by workflow; a workflow is listed only if its most recent completed run failed. A stale failure already followed by green is not an active fire. |
| `last_failure` | Most recent completed run with conclusion `failure`: workflow, branch, event, url, created_at; null when none. |
| `dependabot` | **No MCP equivalent — do not populate. See below.** |
| `code_scanning` | **Unverified — see below.** |
| `secret_scanning` | **Unverified — see below.** |

## Unreachable: the Dependabot surface

There is no MCP tool for the Dependabot alerts endpoint, so everything derived from it goes dark:
`enabled`, `open`, `high_crit`, `oldest_high_crit_age_days`, `vulnerable_packages`, `open_fix_prs`
(the per-package `addresses` match needs the alert list), and `unremediated_packages`. That takes
out section 4's remediation-state table and the two Dependabot blind-spot rows in section 2C.

Render it exactly as `skipped — no gh CLI (Dependabot API unreachable)`, named on the report's
sources line per sections 1 and 5:

```markdown
_Load: <plugin|fallback (degraded)> · Sources: Sentry · Sentry crons · GitHub (MCP fallback) · Dependabot skipped — no gh CLI (Dependabot API unreachable) · Code scanning skipped — unverified MCP capability · Secret scanning skipped — unverified MCP capability_
```

Do NOT approximate it. The PR capability can see Dependabot's open fix PRs, which makes a partial
reconstruction tempting — but without the alert list there is no `vulnerable_packages` to match
against, so remediation cannot be judged per package, and section 4 ranks Dependabot exposure by
remediation state, never by count. A half-surface would quietly re-create the exact
any-PR-counts-as-remediation failure the script's header documents. A named skip is the honest
answer.

## Settled: the code- and secret-scanning surfaces are absent

The session's GitHub MCP surface exposes **neither** capability. Settled on 2026-08-19 by
enumerating the 55-tool roster: no tool lists or gets either alert type, so no call is refused
because no call exists ([routines#11](https://github.com/Sassy-Dog/routines/issues/11#issuecomment-5335967737)).
Render both as named skips beside Dependabot's — the blind-spot rows these feed are specifically
about distinguishing "no alerts" from "never scanned", and an approximation destroys exactly that
distinction. Record it as a Container fact, not a per-run probe.

`run_secret_scanning` is **not** this capability: it scans file contents handed to it in the call
and cannot enumerate a repo's stored alerts.

**If the roster ever changes and this is re-probed**, the positive control exists to separate three
outcomes an empty result cannot tell apart on its own — the tool is absent, the tool is gated, or
the repo is genuinely clean. It can only do that job while the control repo is definitively **not**
clean. So the rule is: **measure the control in the same session as the probe, and never cite a
count written down here.**

That is a post-mortem, not a precaution. This file used to assert as settled fact that `velovate`
carried 102 open code-scanning and 4 open secret-scanning alerts. Two days later the secret half was
zero — all four resolved on 2026-08-19, two of them the live Google API keys that the 2026-08-19
sweep had itself ranked #2 in its top 5. **The control decayed precisely because the fire watch
worked**, and an empty result would then have read as *confirming* the tool was absent, when zero is
exactly what a working tool returns. Half the control still discriminated and half silently did not,
which is the hardest version of this failure to notice.

<!-- rule: control-durable-fixture -->
### Pick the fixture from an archived repo

A control's durability is the whole point, and it runs **opposite** to the ranking rule. A fire in
an archived repo is not a fire — but an *alert* in an archived repo is the ideal fixture, because
nobody will ever remediate it. Scoping the control search to live repos is how the 2026-08-21 pass
concluded "no durable secret-scanning control exists" while a 9-month-stable one sat in plain sight.

Measured 2026-08-21 — re-measure, do not cite:

- **Code scanning.** `Sassy-Dog/velovate`, 77 open alerts.
- **Secret scanning.** `Sassy-Dog/qrninja-app` (archived), 11 open alerts, unchanged since
  2025-11-19. Org-wide there are 16 open and 15 of them sit in archived repos; the one live alert is
  an `active` credential — something to revoke, never to preserve as a fixture.

## Also unreachable without `gh`: the cron-recovery cross-reference

`scripts/check-dispatch-recovery.sh` shells out to `gh`, so section 2A's cron-recovery
cross-reference (`references/cron-recovery.md`) needs a fallback too. Unlike the Dependabot
surface, this one **does** have an MCP equivalent — but only if it is queried in the right shape,
and getting that wrong is not a skipped surface, it is a **false P0 every morning**.

**Query the workflow's own runs, never a repo-wide page.** Ask the runs capability for
`<basename>.yml`, filtered to `workflow_dispatch` and completed status — the same shape
`check-dispatch-recovery.sh` uses (`/actions/workflows/<file>/runs?event=workflow_dispatch&status=completed`).
Then apply the rules in `cron-recovery.md` unchanged.

The reason is measured, not theoretical. On 2026-08-18 the daily sweep ranked `cron-doppler-audit`
as a live P0 for a control that had been verified green the previous evening. That sweep ran from
`Sassy-Dog/routines`, whose port of this contract had pulled a **repo-wide** page and
filtered by workflow afterwards — and a repo-wide page is **30 runs deep, not N hours deep**. How
much wall-clock that buys is a function of repo activity alone: on `Sassy-Dog/platform` it has been
measured at under an hour. That morning its horizon stopped at 22:53Z, three hours *after* the
19:49Z green dispatch it needed to see, with 52 unrelated runs in between. The page contained zero
`doppler-audit.yml` runs at all.

That is the failure this whole reference exists to prevent, in its most dangerous form: a truncated
page is indistinguishable from an empty one, so "we could not see far enough" renders as "nobody
verified the fix" — evidence, exit 0, no footer. Scoped to the workflow the same query returns 9
runs and 128KB: under the ceiling, no spill, and no way to truncate away the answer.

**If you cannot scope the call**, the surface is `skipped — <reason>`: the monitor reports at full
severity AND the repo goes in the cross-reference footer. Never hand the decision a repo-wide page
and treat the result as evidence.
