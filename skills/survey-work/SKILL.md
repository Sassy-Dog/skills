---
name: survey-work
description: >
  Synthesize the full work surface for the current repo — customer pain (Sentry, GitHub bugs,
  TestFlight feedback), backlog (board or open issues + labels), tech debt (TODO/FIXME, skipped
  tests), security exposure (code scanning, secret scanning, dependency alerts), dev experience (CI
  duration/flake), and synthesized "next bet" candidates with no GitHub issue yet. Dedupes across
  sources, scores within each category, returns a prioritized inline plate. Use when the user says
  "what's on our plate", "what's on our plate today", "what should we work on", "survey the work",
  "survey what's on deck", "plate it", "what's next", "what should I prioritize", "give me the
  plate", "what hurts customers most", "any leaked secrets", "what's our security exposure", or
  "triage". Reads the current repo's settings from
  `.claude/sassy-dog/survey-work.md`. Read-only unless that config sets `write_policy: gated`.
---

# Survey-Work

Synthesize everything we might tackle into one prioritized plate.

> Formerly `plate-it`. The "plate it" and "what's on our plate" triggers still resolve here.

## 1. Repo config

!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root:-<not a git repo>}"; cat "$root/.claude/sassy-dog/survey-work.md" 2>/dev/null || echo "NO_CONFIG"`

**Check `CONFIG_SOURCE` before using any of this.** It is the repo root resolved from the
**session's** working directory at skill-load time — not necessarily the repo you are about to act
on — and cwd resets between Bash calls, so you cannot influence it. If it names a repo other than
the one you are working in, **discard the block above**, read that repo's own
`.claude/sassy-dog/survey-work.md` by absolute path, and use that instead. Config is meant to be applied
exactly as written, so the wrong one silently applies another repo's rules: on 2026-08-18 two agents
shipping in `routines` and `skills` were each handed `platform`'s Terraform gates,
and caught it only by noticing the mismatch themselves.

Frontmatter supplies `scan_paths`, `exclude_pathspecs`, `ci_workflow`, `priority_labels`,
`write_policy`, the optional `execution_site`, and the optional `sentry`, `board`, `testflight`,
`mobile`, `posthog`, and `secret_bootstrap` blocks. Contract: `sassy-dog:setup-config` →
`references/config-contract.md`.

**Four of those keys also accept the scalar `none`** — `sentry`, `testflight`, `posthog`, `mobile`
(for the first three that replaces a block; `posthog` is already a scalar). `none` is a *confirmed
absence*: somebody checked. For `testflight`, `posthog` and `mobile` that means the product has no
such surface; `sentry: none` is weaker on purpose and means only that no error-monitoring project is
**verified** here — it covers a check that could not run as well as a genuine absence, which is why
§6 treats it differently. An absent key means nobody has checked at all. Never collapse the two, and note the `none` values do **not** all render alike — §6 has
the rule and the reason. Treat a `posthog: false` as an absent key, not as a decision: it is a
detection result that should never have been written through (`references/config-contract.md`).

**Write posture is decided here.** `write_policy: read-only` (or absent, or `NO_CONFIG`) means this
skill NEVER files issues or mutates anything. Only `write_policy: gated` unlocks §7.

### If it reads `NO_CONFIG`

**First check for a stranded pre-rename config**: if `.claude/sassy-dog/plate-it.md` exists, this
repo is configured but predates the `plate-it` → `survey-work` rename. Do NOT run the degraded
flow below over a repo that actually has a rich config under the old name — say exactly that,
route to `sassy-dog:setup-config` (update mode, it performs the config rename), and stop.
Never read the old filename directly.

Otherwise, **run EXACTLY these three surfaces and nothing else:**

1. GitHub bugs and open issues (§3A "GitHub bugs" + §3B boardless form) — derivable from `gh`
2. In-flight work (§3E) — derivable from `gh` and `git` alone; it needs no config block, so it
   runs unconfigured by design
3. `repo-health` tech-debt scan **with no `SCAN_PATHS`**, letting it default to the whole tracked
   tree — you do not know this repo's source layout

**Do NOT run.** Each one is then a **blind spot**, not a footnote: render it as a row in §6's
`## ⚠️ Blind spots (this plate cannot see these)` section, directly above the recommendations —
plus its `skipped — not configured` token on the sources line, which indexes the same set and
never a different one. The surfaces: Sentry, TestFlight, PostHog, mobile release lag, board
snapshot, secret bootstrap, CI health.

> **The trap this closes.** "Derivable" means *derivable from git or `gh` in this repo*. It does
> NOT mean "I can discover it another way." Sentry projects for the org are listable, and a
> `SCAN_PATHS` value can be guessed from the directory tree — doing either produces a plate built
> on invented inputs that reads exactly like a real one. A surface with no config block is OFF, no
> matter how reachable it looks.

Then tell the user:

> No `.claude/sassy-dog/survey-work.md` in this repo — ran GitHub issues, in-flight work, and a
> whole-tree debt scan only. If this repo has a project-level `plate-it` (the legacy name) or
> `survey-work` under `.claude/skills/`, use that instead; it has the real config.

Routing to an existing project skill takes precedence over offering to migrate: it gets the user a
real plate now. Make the setup offer in the final section, after the output.

A degraded plate is useful. A plate built from guessed inputs is worse than none, because it looks
authoritative.

## 2. Prerequisites

Run these probes. For each failure, label that surface "skipped — <reason>" in the output **and
give it a row in §6's `## ⚠️ Blind spots` section** — a probe that failed leaves the surface every
bit as dark as one that was never configured. Continue either way: **never abort the whole plate on
one missing precondition.**

```bash
gh auth status && cd "$(git rev-parse --show-toplevel)"
```

**If `secret_bootstrap:` is configured**, run it here — before any presence probe below.
Non-interactive agent shells never fire direnv, so probing a bare environment false-negatives
("missing") on credentials the secret manager actually holds. On bootstrap error, continue; the
probes then report their surfaces per the skip rule above.

Each tool shell starts bare — the bootstrap only loads the shell it runs in. Prefix any later
env-dependent command (such as the §3 TestFlight pull) with the same bootstrap line. Never
presence-check an environment variable this skill hasn't loaded yet.

Probe only the surfaces config enables: Sentry by listing projects for the configured org;
TestFlight by checking that the App Store Connect key is present.

## 3. Pull all surfaces in parallel

Issue the independent pulls in a single message with multiple tool calls.

### A. Customer pain

**Sentry** — **ONLY if the config has a `sentry:` block.** `sentry: none` is not a block, and it is
also **not** a clean-line token: alone among the four `none` keys it still gets a blind-spot row in
§6, worded as confirmed rather than unchecked — `skipped — sentry: none (recorded at setup)` on the
sources line, and the matching row. §6's *Confirmed N/A* rule carries the reason, and the limit: the
row reports that no project is verified here, never that the repo has no Sentry. No key at all →
`skipped — not configured`
**and a blind-spot row in §6, the loudest one there**; do not list org projects to discover one.
Invoke `sassy-dog:sentry-triage` with the
configured org and projects. Gate policy: the configured `sentry.gate` when `write_policy: gated`,
otherwise report-only with no escalation. It handles query syntax, the qualifying gate, and GitHub
cross-referencing.

**GitHub bugs** —

```bash
gh issue list --state open --label bug \
  --limit 100 --json number,title,labels,createdAt,updatedAt,reactionGroups,comments,url
```

Demand proxy = reactions + comments.

**TestFlight** — **ONLY if the config has a `testflight:` block.** `testflight: none` is a
confirmed absence, not a hole: this product has no beta channel, so render one `TestFlight (n/a)`
token on the clean line and **no** blind-spot row. No key at all → `skipped — not configured`
**and a blind-spot row in §6**, ranked alongside Sentry as customer pain. Invoke
`sassy-dog:testflight` with the
configured bundle id, command `feedback`. Parse screenshot submissions (tester comments) and crash
submissions (stack signatures). Tag items `[TestFlight]`.

**PostHog** — **ONLY if the config sets `posthog: true`** (best-effort even then). `posthog: none`
is a confirmed absence — one `PostHog (n/a)` token on the clean line and **no** blind-spot row. No
key at all → `skipped` **and a blind-spot row in §6**. If a read key is provisioned, pull survey
responses and high-frequency `$exception` events; otherwise render `skipped — PostHog (no read
key)` and move on.

### B. Backlog

**With `board:`** — board snapshot via `sassy-dog:github-issues`, using the configured board
number and owner, plus its stale-issue detection.

**Without a board** — open issues and labels:

```bash
gh issue list --state open --limit 200 --json number,title,labels,updatedAt
```

plus `sassy-dog:github-issues` stale-issue detection.

**Either way, resolve each issue's execution site from the labels the pull already returned.** A
`site:<name>` label declares a workstation the issue can be worked from
([#340](https://github.com/Sassy-Dog/skills/issues/340)); no such label means any site.
**Run the resolver rather than re-deriving its rules** — a paraphrase forks them, which is the
failure [#341](https://github.com/Sassy-Dog/skills/issues/341) measured when one dropped
the `strip()`. This backlog read is not a `queue-snapshot.sh` bucket (those are label-scoped to
`ready`/`in-progress`/`blocked`), so it takes the same emitter `take-it` and `dispatch-ready`'s
`board:` path do, which runs no `gh` and touches no network. **Feed it the labels this step's own
pull already returned** — both forms above carry them, and a re-fetch would cost one API call per
issue and read a tree that has moved since the pull:

```bash
# Capture in the SAME Bash call as the read below — shell state does not survive between
# calls, and empty stdin makes `--sites-of` exit 64 rather than print `[]`.

# boardless: the `gh issue list --json ...,labels` result above.
ISSUES=$(gh issue list --state open --limit 200 --json number,title,labels,updatedAt)

# One issue shown; run it per issue — the pull holds up to 200.
jq -c '[.[] | select(.number == 1712) | .labels[].name]' <<<"$ISSUES" |
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh --sites-of

# board mode: `board-snapshot.sh` already carries each card's labels
BOARD_SNAPSHOT=$(PROJECT_NUMBER=<board.number> OWNER=<board.owner> \
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/board-snapshot.sh)
jq -c '[.items[] | select(.number == 1712) | .labels[]]' <<<"$BOARD_SNAPSHOT" |
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh --sites-of
```

**A resolver that could not run is UNKNOWN, never "no label".** `--sites-of` exits **10** when
`python3` is missing and prints **nothing** on stdout, while a genuinely unlabelled issue prints
`[]` and exits 0. Do not lean on that difference: empty stdout is also what a `jq` failure or
unbound input produces, and those exit **64**. Only the exit status separates the three
reliably. **Read the exit status, not the output.** On anything but 0 the site
column is dark for this run: say `skipped — site resolver unavailable` on the sources line, give it
a blind-spot row, and render no site tokens at all rather than the unmarked lines an empty answer
would produce. **The `To ship:` bound below is then unverified too** — say so instead of listing a
command built from a check that did not run.

**The test is `not sites or execution_site.lower() in sites`, folded on both sides** — the emitter
folds the label's value, folding the configured one is this skill's half. Membership **narrows**:
several labels name several machines that may take the issue, and each of them can, so a
multi-member declaration is never "any site" and never nothing. §6 owns how it renders; this step
only resolves it.

With no `execution_site` there is nothing to compare against, so resolve the declaration and stop
there — never guess which site this checkout is. §6 says what that leaves renderable.

**Never act on it.** This surface stays read-only whatever the `write_policy`: a missing label is
not filed, a wrong one is not corrected, and a conflict is not resolved. Those are
`sassy-dog:groom-backlog`'s rubric #9, and the plate's job is to make them visible.

**Either way, render its `tracking-parent-complete` hits** — an open epic whose children (the
`Part of #<parent>` lines `sassy-dog:groom-backlog` writes at split time) have all closed. Such a
parent can never self-close, because GitHub's automation fires on a merged PR's `Closes #N` and no
PR ever names a tracking issue, so it stays on the backlog as apparent work indefinitely
(issue #198). One line each under the backlog section — `#<parent> · N children, all closed` —
labelled as finished work still open. **Never score it as available work, never recommend it in
§5's top 5, and never close it**: this skill is read-only here whatever the `write_policy`, and a
human closes. A `truncated: true` result is reported as unknown, not clean — and so is an **exit 10**, where the detector printed no sections at all: a run that could not read GitHub has nothing to report `none` from, and saying `none` there is exactly the false-clean this detector exists to prevent. Name the failure and the cause.

### C. Tech debt + dev experience

Invoke `sassy-dog:repo-health`:

- tech-debt scan with the configured `scan_paths` and `exclude_pathspecs`. **Never invent these** —
  with no config, omit `SCAN_PATHS` entirely so the script defaults to the whole tracked tree. A
  guessed path silently scans the wrong subtree and reports a clean repo.
- CI health with the configured `ci_workflow`. No config → skip **and render a blind-spot row in
  §6**; do not guess a workflow filename.
- dependency exposure + remediation (no environment needed; defaults to cwd)
- code scanning and secret scanning (no environment needed; both default to cwd). `analyzed: false`
  or `enabled: false` is a **blind spot** row — it goes in §6's `## ⚠️ Blind spots` section with
  every other dark surface, never on the clean line; `enabled: null` is a token-scope question.
  `truncated: true` makes `open` a floor — report "at least N".
- mobile release lag with the configured `mobile.release_workflow` and `mobile.path_prefix`, **if
  `mobile:` is configured** — `mobile: none` is a confirmed absence (this product has no mobile
  app): one `mobile release lag (n/a)` token on the clean line and **no** blind-spot row. No key at
  all → a blind-spot row in §6, the quietest kind

Its `references/scoring.md` thresholds apply unless overridden by config.

**MEMORY signals** — scan the project memory index for recurring friction (`feedback_*` /
`project_*` entries); each derived suggestion cites its memory file.

Then apply any `## extra-surfaces` section from config — additional product-specific surfaces such
as in-app feedback tables, funnel health, infra drift, or deprecation scans.

### D. Next bets (synthesized)

Cluster feedback and error items that lack a GitHub issue into candidate "next bets" — themes with
≥2 independent signals. Recommendation-only; never auto-filed.

### E. In-flight work

Feeds §6's `## ✅ Already in flight`. Everything here derives from `gh` and `git` alone — no
config block, so this surface also runs under `NO_CONFIG`. It is read-only under every
`write_policy`: report, never file, comment, push, or delete (the `git fetch` below refreshes
remote-tracking refs only; it touches no working tree and no local branch).

```bash
# The genuinely in-flight set: open PRs with check status
gh pr list --state open --json number,title,headRefName,isDraft,statusCheckRollup

# Refresh the remote view BEFORE classifying local branches — a stale
# origin/<default> feeds the same trap the guardrail below describes
git fetch origin --quiet

# Classify every local branch (including the checked-out one) by PR STATE
git for-each-ref refs/heads --format='%(refname:short)' | while read -r branch; do
  gh pr list --state all --head "$branch" --json number,state,mergedAt
done
```

Classification — PR state is the source of truth:

| Probe result | Classification |
|---|---|
| Open PR | Genuinely in flight — list with check status, draft flagged |
| Merged PR | Post-merge residue — route to `tidy-repo` as a one-line pointer in the output; NEVER surface as an actionable plate item |
| Closed-unmerged PR | Deliberately dropped — not a plate item |
| No PR in any state AND commits not in `origin/<default>` (`git rev-list --count` against the just-fetched remote-tracking ref) | Unshipped work — a legitimate plate item, "a `send it` away" |

"Route to `tidy-repo`" means naming it in the plate (see the residue line in §6's template), not
running the cleanup from here.

> **Guardrail — squash-merge + a stale local main lie in unison.** Never derive "unshipped" from
> `main..HEAD` or from an open-only PR list. Under squash merge a branch's commits never land on
> the default branch verbatim, so against an un-fast-forwarded local main, `main..HEAD` claims
> "ahead" forever — and the merged PR is invisible to `--state open`. The two stale views
> corroborate each other into a confident false actionable. This is the same trap
> `sassy-dog:repo-cleanup` documents for branch sweeps: use PR state, never ancestry.

## 4. Dedupe across sources

Correlation keys: auto-file marker ↔ GitHub body (`<source>-source: <ID>`); bug-labeled issue ↔
board item ("also on board"); TODO containing `#NNN` ↔ that issue; TestFlight crash signature ↔
Sentry `culprit` via fuzzy top-frame match.

Merged items retain ALL source links — cross-source overlap boosts score in §5.

## 5. Score within each category

Score each category independently; surface a cross-category top-5 by relative rank at the end.

**Customer pain**:
`impact = severity × log10(1+occurrences) × log10(1+distinct_users) × recency_decay × source_overlap_boost`
— severity: crash=10, error=6, bug-label=4, feedback=2, suggestion=1; recency_decay 1.0/0.7/0.4/0.1
for ≤2d/≤7d/≤30d/older; overlap boost 1.0/1.5/2.0 for 1/2/3 sources.

`occurrences` and `distinct_users` mean **lifetime** totals, and the formula is worthless without
that. A windowed count multiplies through two logs and collapses exactly the long-running recurring
issues the gate exists to catch: on 2026-08-20 a velovate issue at a true 30/3 arrived as 1/1 and
the whole Sentry surface rendered as clean (issue #218). `sassy-dog:sentry-triage` confirms counts
per issue before it gates — take its numbers, never a raw search result, and never quote a figure it
tagged `skip-unconfirmed` as though it were measured.

**Backlog**: lead with the issue's own priority label (the configured `priority_labels`), tie-break
by reactions + comments. Don't re-derive a priority the maintainer already assigned.

**Tech debt + dev experience**: `sassy-dog:repo-health` scoring defaults.

**Security — dependency exposure**: rank by REMEDIATION STATE, never by alert count — a count only
falls when a fix merges, so a fresh CVE batch with fixes already queued looks identical to a year of
neglect. A `parked_green` PR aged ≥3 days is **P0** and belongs under **Security** with its number
and merge command: the fix exists, it is green, and only a human press is missing.
`unremediated_packages` with an available patch is **P1** (**P0** past 14 days). A `BLOCKED` or
`DIRTY` fix PR is **P1** — name the failing check, since it is usually a lockfile the updater
cannot regenerate. A fresh batch (≤2 days) fully covered by open fix PRs is not a finding; it goes
on the `✓ Clean today:` line.

**Security — code scanning**: rank rule-clustered, never per alert. A rule whose newest alert is
≤14 days old is `new[]`: **P0** at `critical` or with `autofix: "ready"` (the fix exists and only a
human press is missing), **P1** at `high`. Everything older is `inherited` — ONE debt line naming
the rule count and the oldest age, never enumerated and never in the top 5. A flat severity ranking
here reproduces exactly the wall-of-findings problem the dependency rule above exists to prevent.

**Security — secret scanning**: `validity: "active"` is **P0 on day zero** — GitHub validated the
credential against its provider, so it is live and no age math applies. A `bypassed: true` alert is
**P0**: a human overrode push protection to commit it. `unknown` validity is **P1**, escalating to
**P0** at 30 days, because unverified and untriaged for a month is itself the finding. `inactive`
is already rotated — one token on the clean line.

Then apply any `## scoring-overrides` section from config — project-specific re-weights.

## 6. Output format

Render inline as markdown. Four rules are non-negotiable.

**Empty is not dark.** A surface that was checked and came back with nothing gets a single token on
the consolidated `✓ Clean today:` line, never its own section. A surface that was NOT checked never
reaches that line at all — it gets a blind-spot row instead. Collapsing the two is exactly the
failure the blind-spots section exists to prevent: a never-queried surface reported as clean.

**Confirmed N/A is a THIRD state, and it is not "empty" either.** `testflight: none`,
`posthog: none`, and `mobile: none` say a human confirmed this product has no such surface. They
take the clean line with an explicit `(n/a)` marker — `TestFlight (n/a)` — and get **no**
blind-spot row and **no** `skipped —` token on the sources line, so the token↔row invariant below
still holds exactly. The marker is the whole point: "checked, nothing there" and "there is nothing
here to check" are different claims, and it is the only thing distinguishing them.
**`sentry: none` is the deliberate exception and keeps its blind-spot row** — absent error
monitoring is a gap somebody could close, an absent mobile app is a product fact
(`sassy-dog:setup-config` → `references/config-contract.md`, "The one exception"). Its row is worded
as recorded-at-setup rather than as a product fact, and that wording is exact rather than tactful:
`sentry: none` covers **two** outcomes, "this repo genuinely has no error monitoring" and "the
culprit check could not run at all" (no MCP server, no issues to sample — `references/detection.md`).
Neither is something this plate checked, and the second is a reason on its own for the row to
survive. Never widen it into a claim that the repo has no Sentry.

**Skip empty P-buckets** within a section.

**Recommendations go LAST — below the blind spots**, so a reader weighs what the plate could not
see against the ranking, instead of discovering it afterwards in a footnote.

```markdown
# On the plate (YYYY-MM-DD)

_Sources: <pulled> · <dark surface> skipped — <reason> → Blind spots · ..._

✓ Clean today: <checked-and-empty surface> · <confirmed-absent surface> (n/a) · ...

## 🔥 Customer pain (P0: N · P1: N · P2: N)
### P0
- **<title>** — score X.X
  - Impact: N users, M occurrences, last seen Yh ago
  - Sources: [Sentry](url) · [GH #123](url)
  - Why this matters: <one line>
### P2 (count + 3 sample titles, collapsed)

## 🔒 Security (P0: N · P1: N)
### P0
- **<rule or credential type>** — <one-line why>
  - Evidence: <alert numbers> · <validity or severity> · open <N>d
  - Fix: <merge command, autofix note, or "rotate and revoke">
_Inherited: N alerts across M rules, oldest Dd — debt, not a plate item._

## 🎯 Backlog priorities
- **#NNN <title>** — `<label>` — <one-line why>
- **#NNN <title>** — `<label>` — `site:vdi` `site:mac` (not this checkout) — <one-line why>

_Suspected complete: #NNN (N children, all closed) — finished work still open; close it, don't groom it._

## 🧹 Tech debt
## 🛠 Dev experience
## 💡 Next bet candidates (synthesized — not yet on the backlog)

## ✅ Already in flight   <!-- from §3E; classified by PR state, never main..HEAD -->
- **PR #NNN <title>** — <branch> · <checks summary> · <draft?>
- **<branch>** — unshipped, no PR in any state — a `send it` away

_<N> merged-PR branches lingering locally — residue for `clean it`, not plate items._

## 🆕 Auto-filed this run   <!-- gated write_policy only; omit entirely when empty -->

## ⚠️ Blind spots (this plate cannot see these)   <!-- omit entirely when nothing is dark -->
- **Customer pain** — no `sentry:` block. Production errors were NOT checked.
- **Customer pain** — `sentry: none`: confirmed at setup that no error-monitoring project is verified for this repo (either there is none, or the culprit check could not run). This plate did not miss production errors; nothing here is watching for them.
- **Customer pain** — no `testflight:` block. Beta crashes and tester feedback were NOT checked.
- **Security — code scanning** — never analyzed. Vulnerable code patterns were NOT checked.
- **Dev experience** — no `ci_workflow`. Pipeline duration and flake were NOT checked.
- **Mobile release lag** — no `mobile:` block. Shipped-vs-main drift was NOT checked.

## 👉 Today's recommendations (cross-category top 5)
1. **<title>** — <category> · <one-line why> · <handle>

_To ship: `take #<N> #<M>`_   <!-- only issues this checkout can take; see the site rule below -->
```

### The handle on every recommendation line

The **final ` · ` segment** of each numbered line is the item's handle, and it is the one thing
`work-recommendations` reads to act on the line — it never has to find the title in the section
above, where a paraphrase would lose it. The grammar is that skill's (`work-recommendations` §3),
so this list is closed:

| Item | Handle |
| --- | --- |
| backed by a GitHub issue (Backlog, or Customer pain with `[GH #N]`) | `#N` — with `(not this checkout)` still rendered before it when the site rule says so |
| already in flight as a PR | `pr:#N` |
| Customer pain with a Sentry link and no issue | `sentry:<SHORT_ID>` (`PROJ-123`, the same id the `sentry-source:` marker uses) |
| anything else — a next bet, a tech-debt or dev-experience item, a security finding | `none` — the `<category>` on the line says which, and that is what decides its disposition there |

A title never contains `·`, `**`, `—` or `#` — replace them with spaces when rendering the
line — so nothing but the last segment can read as a handle.

### Execution site on backlog lines

The site separates *"this checkout can pick it up"* from *"waits for site `<x>`"*, which is the
whole reason the declaration exists. Four rendering rules, from the value §3B resolved:

- **An issue with no `site:` label renders exactly as it did before this rule existed** — no token,
  no `(any site)` marker, nothing. Unlabelled is the overwhelming majority, so a token on every line
  would bury the handful that carry one, and the plate would grow noise proportional to the backlog
  to say nothing at all.
- **A declaration this checkout is a member of renders as bare `` `site:<name>` `` tokens**, every
  declared site listed. It is context, not a warning: the work is takeable here.
- **A declaration this checkout is not a member of** renders the same tokens plus
  `(not this checkout)`. Keep the item in its P-bucket, scored and ranked as always — it is real
  work, it is simply not *this* session's to start. Never demote it for being elsewhere; that would
  hide the very item the label exists to point at, and on the day somebody sits down at that
  machine the plate is the thing that tells them what is waiting.
- **Several `site:` labels list every one of them and mark nothing special.** They **narrow**: each
  named machine may take the issue, membership decides which of the two rules above applies, and
  the reading to refuse is "any site" — the direction
  [#322](https://github.com/Sassy-Dog/skills/issues/322)'s originating bug ran. There is no
  third rendering for a multi-member declaration, and it is never reported as undispatchable: a
  checkout it names can dispatch it today.

`work-recommendations` consumes this block and the `To ship:` line as rendered — the numbered
order, the inline handle (final ` · ` segment), the `<category>` token and the
`(not this checkout)` marker are what it keys on.

**Only issues this checkout can take reach the closing `To ship:` line** — an off-site issue named
there hands the user a `take` that the dispatcher will refuse, and a recommendation the tooling then
rejects trains a reader to stop trusting the line. When the top 5 is entirely off-site, say so in
one line instead of emitting an empty command.

With no `execution_site` configured, the middle two rules collapse into one: every declared site
renders as a bare token and nothing is marked as elsewhere, because this checkout answers to no
name and there is nothing to be elsewhere *from*. That is the same fail-open the dispatchers take,
and it is a different question from an issue carrying no label — neither is evidence for the other.

### Blind spots

One row per dark surface, and every row carries three things: the surface, the missing config key
or failed probe, and — in plain past tense — what was NOT checked. The one row that does not fit
that third thing is `sentry: none`, which reports what setup **recorded** rather than what this
plate skipped. Five rules:

- **A confirmed absence is not a dark surface — with exactly one exception.** `testflight: none`,
  `posthog: none`, and `mobile: none` produce **no row at all**; they belong on the clean line with
  the `(n/a)` marker above. `sentry: none` produces a row, worded as confirmed rather than
  unchecked. That asymmetry is deliberate, is pinned in CI, and is not an inconsistency to tidy
  away — see `references/config-contract.md`, "The one exception"
  ([#261](https://github.com/Sassy-Dog/skills/issues/261)). An unclearable row is worse
  than no row: on an infra repo with no app, those three rendered on **every** plate with no config
  that could clear them, two of them in the loudest position this section has. A reader who meets
  the same unactionable rows every time stops reading the heading — and then the row that should
  stop them, a genuinely dark Sentry, is sitting in a list they learned to skip.
- **Order by what the darkness costs, customer pain first.** Sentry and TestFlight rank loudest.
  Customer pain is usually the single highest-signal category on the plate, so a dark Sentry means
  the recommendations below were ranked without the input most likely to have topped them. Security
  is next, then backlog, then tech debt, dev experience, and mobile release lag last. A dark
  mobile-release-lag check narrows a plate; a dark Sentry can invert one.
- **This section and the sources line are the same set, restated.** Every `skipped —` token up top
  has exactly one row here, and every row has its token. The token is an index; the row is the
  finding. If the two disagree about a surface the plate is wrong — a dark surface visible ONLY on
  the sources line is the defect this section replaces.
- **Omit the section entirely when nothing is dark** — heading included, per the anti-verbosity
  rules above. A fully-covered plate says nothing here.
- **Never score, rank, or recommend a blind spot.** It is a statement about the plate's own
  coverage, not a work item: it stays out of §5's scoring and out of the top 5. The fix for a blind
  spot is `sassy-dog:setup-config`, which the closing section already offers.

## 7. Write policy

**When `write_policy: read-only`, absent, or `NO_CONFIG`** — this skill NEVER files GitHub issues,
changes Sentry status, or mutates anything. If an unfiled signal deserves an issue, the plate says
so and the human files it, or runs the filing flow explicitly. Stop here.

**When `write_policy: gated`** — the skill writes in exactly ONE place: qualifying Sentry hits
promoted to GitHub issues via `sassy-dog:github-issues`' `file-or-link-issue.sh` with
`--marker "sentry-source: <SHORT_ID>"`. Gate and burst rail per `sassy-dog:sentry-triage`
(`references/qualifying-gate.md`), using the configured `sentry.gate`. Labels
`bug,sentry-escalation`; when `board:` is configured, file onto its Backlog column.

Hard prohibitions, regardless of policy: never mutate Sentry status; never edit existing issues
from this gate; never file from tech debt, CI, memory, or next-bet surfaces — those stay
recommendations. Dry-run with `DRY_RUN=1` after any gate change.

Apply any `## extra-guardrails` section from config on top of these.

## If this repo had no config

### Offer to set this repo up

**Then, after the output above — not before it — offer once:**

- **If `.claude/skills/plate-it/SKILL.md` exists with a `generated-by:` marker** (the legacy
  generated-skills name) — this repo is on the
  superseded generated-skills architecture. Say so concretely: *"This repo has a generated
  `survey-work` I can migrate — I'd extract its config, show you the result, and remove the old skill
  only after you approve. Want me to?"*
- **Otherwise** — nothing to extract from: *"I can set this repo up. It takes a few questions about
  how this repo works. Want me to?"*

Naming which path applies matters: one of them ends in deleting a file the user may not know is
there.

On yes, delegate to `sassy-dog:setup-config`. **Never write config yourself** — the
refresher owns the contract, and a skill that writes its own forks the format the moment the
contract moves.

**Offer once per session.** Running deliberately in an unconfigured repo is legitimate; re-prompting
every invocation is noise. If declined, carry on and don't raise it again.
