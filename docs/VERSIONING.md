# Versioning — sassy-dog plugin instance

This repo's instance of the org **Versioning spec v1.0** (frozen 2026-07-11).
When this doc and the spec conflict, the spec wins, and changes go through the
spec rather than a local fork.

> **Note for readers outside Sassy Dog:** the spec itself is internal, so the
> two pointers below resolve only for maintainers — an internal knowledge base
> (`Sassy Dog/Architecture/Development/Versioning.md`) and its mirror on
> `Sassy-Dog/platform#397`. Nothing here depends on reading them: this document
> is self-contained, and `scripts/test-versioning.sh` is the executable copy of
> every rule it states about *resolving and stamping a version*. Where you
> want the authority for such a rule, read the test. The separate release-lag
> behavior is exercised by `scripts/test-release-lag.sh`; the no-auto-stamp
> rationale remains prose rather than a version-resolution rule.

Adopted 2026-07-11 via issue #31. Per spec §9, this doc is validated against the
scripts at adoption and whenever either changes — the validation is automated as
`scripts/test-versioning.sh`, run by `scripts/preflight.sh` (CI).

## Repo classification (spec §7)

**Library / plugin (committed manifest)** — a Claude Code plugin marketplace.
The artifact that leaves this repo is the plugin itself, consumed by Claude
Code's marketplace install/update flow, which reads the committed manifest.

## The model

- **Marketing version — monthly-rolling CalVer**: `YYYY.M.<commits-this-month>`
  (non-padded month, UTC, patch floored at 1), e.g. `2026.7.16`. CalVer is
  valid semver, so version-ordering consumers keep working.
- **Version-of-record**: the committed `version` in
  `.claude-plugin/plugin.json`. The scripts *emit* it at release time
  (`scripts/stamp-version.sh`); consumers read the manifest, never git.
  Any `v*` tag, if minted, must equal it.
- **Build number: N/A** (declared per §7) — this repo has no store, appcast,
  or force-update surface; nothing consumes a monotonic integer.
  `scripts/get-build-number.sh` intentionally does not exist.
- **Tags: optional** (declared stance) — releases are marked by the stamping
  commit itself; `v*` tags may be minted as changelog anchors only, and must
  equal the committed manifest value.
- **One repo-wide CalVer**: the marketplace hosts a single plugin today. If
  more plugins are ever added, every manifest `version` field gets the
  identical repo-wide value, stamped by the same script (per-plugin drift is
  forbidden). Per-plugin trains with path-scoped counts would be a declared
  change via platform#397, not a local decision.
- **§2 idempotency waiver** (the documented self-reference): the stamping
  commit changes the commit count that produced the stamped value, so §2's
  re-run idempotency is formally unsatisfiable for a committed manifest. It
  is waived per §7 — the manifest is authoritative. In practice the stamping
  commit also pushes the monthly count past the value it stamped, so the next
  release always resolves strictly higher within the month.

## ⚠️ One-way ratchet (irreversible)

Publishing CalVer-as-semver is **permanent**. The adoption stamp was
`0.11.0 → 2026.7.16` (2026-07-11, issue #31): no `0.x`/`1.x`/`2.x` semver may
**ever** follow, because version-ordering consumers (the plugin update flow)
would read it as a permanent downgrade and silently freeze every consumer at
the last CalVer. Enforced twice:

1. `scripts/stamp-version.sh` refuses to write any non-CalVer value, pinned
   or computed.
2. The CI preflight gate (`scripts/preflight.sh`, manifests gate) fails on a
   non-CalVer manifest version, so a hand-rolled semver can't merge.

## Interface contract (spec §3)

| Capability | Owner |
|---|---|
| Marketing-version command | `scripts/get-version-info.sh` (the §2 algorithm exists exactly once, here; `stamp-version.sh` delegates) |
| Build-number command | N/A — declared above |
| Mint-probe owner | `scripts/stamp-version.sh` — the §4 probe/reuse/bump ladder expressed against the committed manifest instead of tags: equal → reuse; same-train at-or-below committed → bump past it; earlier-month than committed → fail closed |
| Replay pin | `MARKETING_VERSION` (verbatim, never auto-bumped — a pin at/below the committed value fails loudly); `VERSION_DATE_OVERRIDE` / `VERSION_PATCH_OVERRIDE` as test seams |

## Releasing

```bash
bash scripts/stamp-version.sh            # resolve CalVer + write plugin.json
bash scripts/stamp-version.sh --dry-run  # preview without writing
```

Commit the stamped manifest in the release PR — the committed value **is**
the release. Never hand-edit `version`. After the merge, consumer machines
still update manually (`claude plugin update --scope <scope> sassy-dog@skills`
— see README "Updating / Troubleshooting", under "`claude plugin marketplace
update` is not a plugin update", which is where the content check lives).

**Cadence: dedicated release-only stamping, with a daily read-only reminder.**
Content lands on `main` on every merge; the manifest moves only when someone
runs the stamp script and commits the result. Historical stamps have also
ridden feature PRs (`2026.8.96` → `2026.8.100` at `98d5d42`), so a commit subject
cannot identify the baseline. Nor can a manifest touch (`951e131` added
`license` without changing `2026.8.41`), or a version-line grep that misses
reformatted JSON. Use `scripts/check-release-lag.sh` below: it compares parsed
versions on the first-parent integration history.

When the reminder reports **due**, review its changed-path evidence, run
`bash scripts/stamp-version.sh --dry-run` then `bash scripts/stamp-version.sh`,
and commit the stamped manifest in a dedicated release PR. Use the ordinary
review, CI and merge-queue path; never push `main` directly. The checker neither
stamps nor opens that PR. A release resets its baseline and pending clocks,
including when only the version changes, so the stamp cannot create a loop.

Measured 2026-08-27 at `31e9579`, the committed `2026.8.100` was 23 below what
its own formula resolved, across 22 unstamped merges (issue #296). The
apparent off-by-one between those two numbers is correct rather than an error:
the stamp is computed *before* its own merge lands, which is the §2
self-reference waived above. Two consequences follow, and both are
load-bearing:

- The version string does **not** distinguish trees. Two checkouts with
  different content routinely carry the same `version`, so nothing may key a
  content or cache-freshness decision on it. That is why README's
  stale-cache diagnostic compares files rather than version strings.
- "The committed value **is** the release" stays true as the *definition* of
  what a release is. It is not a claim that the manifest tracks `main`, and
  between releases it does not.

Migration note (spec §6): the semver → CalVer switch needed no cutover gate —
`2026.M.P` strictly exceeds the pre-adoption `0.x` train, and this repo has no
store tier, so the mid-month switch was monotonic-safe.

## Release-lag reminder

`.github/workflows/release-lag.yml` checks the event repository's derived default
branch daily at **09:17 UTC** (`17 9 * * *`) and via `workflow_dispatch`.
Both triggers use the same checker with full history. A release is due when
any currently pending path has remained divergent for **at least 72 elapsed
hours** (259200 seconds, inclusive). No merge-count threshold or rounded-day
comparison is involved. Daily sampling can notice that boundary roughly one
interval later, plus GitHub scheduling delays; notification delivery depends
on the user's Actions settings and is not guaranteed.

```bash
bash scripts/check-release-lag.sh --repo . --ref HEAD --format markdown
bash scripts/check-release-lag.sh --repo . --ref HEAD --format json \
  --due-after-hours 72 --now 2026-09-08T09:17:00Z
```

Requires Git and Python 3 (standard library only). Defaults: current checkout,
`HEAD`, JSON, 72 hours and the current UTC clock. `--now` is an explicit UTC
ISO-8601 observation-clock seam for deterministic history fixtures, not a
CalVer override. The checker reads **committed objects only**, never the index
or working files, fetches nothing (including no lazy object fetch), performs
no repair or mutation, and never calls the live CalVer resolver as lag evidence.

### Baseline and runtime inventory

The baseline is the newest **first-parent commit whose parsed top-level plugin
version differs from its first parent's**. Its tree includes that commit's
delivered content. A complete-history root introducing a valid CalVer may be
the baseline. Formatting, same-value rewrites, metadata edits, subjects, tags
and today's computed CalVer are not releases. The current committed version
must be valid CalVer (non-padded month 1–12, positive patch).

The fixed release-relevant inventory is:

- All tracked content under `skills/`, `agents/` and `hooks/`, including bundled scripts,
  references, templates and removals.
- The runtime root helper `scripts/align-labels.sh`, not every root script.
- `.claude-plugin/plugin.json`, parsed with **only top-level `version` removed**.
- `.claude-plugin/marketplace.json`, parsed with **only optional
  `plugins[].version` removed**. Source, identity and configuration metadata
  remain relevant.

Manifest object-key order and whitespace normalize away; arrays and every
non-version value remain significant. Ordinary entries compare content,
presence, executable mode and symlink identity; manifest modes also remain
significant. Missing ordinary entries are deletions, but both required manifests
must be readable JSON objects (marketplace `plugins` is an array of objects).
Repo-only documentation, README, CI, lint/config files and other root scripts
do not create release demand. This is a fixed inventory, not a dependency crawler.

### Pending clocks and unverified evidence

No net difference between normalized baseline and analyzed payload is **clean**,
including full change/revert cycles, unrelated work and formula/month changes.
For each currently differing path, walk first-parent integration commits to
find the start of its **current uninterrupted divergence** from that baseline
entry. Returning to baseline resets that path; reintroduction starts it again.
Later edits, including partial reverts that leave a file divergent, retain its
pending date. Currently reverted paths cannot age newer outstanding paths.
Dates are committers' integration timestamps, not old side-branch author dates.

Incomplete/shallow history, unavailable refs or objects, missing/malformed
required manifests, invalid current CalVer, unusable pending timestamps or a
selected pending time after the observation clock produce **error/unverified**.
There is no guessed baseline, zero-age substitute, clamp, history repair or
protection workaround. Required manifests across the analyzed interval must
remain valid, even when the final payload has reverted.

### Reports and response

JSON and Markdown render the same computed report: `status`, `analyzed_ref`,
`head_sha`, `release_version`, `baseline_sha`, `baseline_date`,
`observation_time`, `due_after_hours`, `threshold_seconds`, `changed_paths`,
`oldest_pending_age_seconds` and `error`. Each changed path has `path`, `status`
(`added`, `deleted`, `modified`), `first_pending_sha`, `first_pending_date` and
`age_seconds`. Unknown evidence is JSON `null` (Markdown `unknown`), never a
fabricated zero; a clean result has an empty changed-path list and no pending
age. Unverified analysis retains known identity fields but no certified pending
list or age. Error reports carry the concrete reason.

| State | Exit | Response |
|---|---|---|
| clean | 0 | No net runtime difference; no pending release |
| pending | 0 | Pending content is younger than the threshold |
| due | 3 | Follow the [dedicated release procedure](#releasing) |
| error | 1 | Evidence is unverified; resolve the reported prerequisite |
| usage error | 64 | Correct the checker arguments |

The dedicated reminder captures the checker exit under errexit, publishes the
same Markdown in logs and `GITHUB_STEP_SUMMARY`, then annotates and fails on
**due** or **error** with distinct messages. A process failure before a report
is generated is also visible and nonzero. It has only `contents: read`, uses a
GitHub-hosted Ubuntu runner, and creates no release, PR, issue, token or secret.
It is **not a required PR/merge-queue gate**. Preflight runs only the isolated
behavioral fixture, so overdue work cannot block its own release PR.

This signal cannot certify consumer pins or already-running sessions. Keep using
README's [Updating / Troubleshooting](../README.md#updating--troubleshooting)
content comparison, correct-scope update and restart diagnostic; CI does not
read install registries or update consumer installations.

## CI (spec §8)

The required `ci` job does not compute this repo's live version — preflight
shape-checks the committed manifest (`^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$`) and
cross-checks any `marketplace.json` `plugins[].version` against it. Its checkout
stays shallow. The separate release-lag reminder **does** need
`fetch-depth: 0`, to inspect release boundaries and pending history, not to
compute or stamp CalVer.

Preflight executes the versioning scripts (`scripts/test-versioning.sh`) and
the release-lag checker (`scripts/test-release-lag.sh`) against isolated
`mktemp` histories, not this checkout's history. Thus a live formula/manifest
gap is not a manifest-gate failure, and an overdue release is not a required
`ci` failure. If a future CI job computes a live version, that job also needs
full history. Automatic stamping remains a **deliberate absence** for the
reasons below; the read-only reminder changes none of them.

### Why there is no per-merge auto-stamp

Stamping `main` after every merge — what issue #296 asked for, so that the
version-of-record tracks content 1:1 — needs a job that **writes to `main`**,
and nothing available inside this repo can.

`main` is governed by the repository ruleset `main protection`, read
2026-08-28: `pull_request` (a PR is required), `merge_queue` (that PR merges
through the queue), `required_status_checks: ["ci"]`, `bypass_actors: []`
and `current_user_can_bypass: "never"` — alongside classic protection with
`enforce_admins: true`. So there is no direct push to `main` for any actor,
admins included, and the bypass list is empty *by policy* — one Terraform PR
from non-empty, which is route 1 below, and not a door that can be opened
from here. The only route in today is a pull request carrying a green `ci`.

The only credential a workflow here can reach is its own `GITHUB_TOKEN`.
Measured 2026-08-28, all four stores are empty for this repo:
`actions/organization-secrets` — the org-available endpoint, and the one that
actually answers the question — returns `total_count: 0`, as do
`actions/secrets`, `dependabot/secrets` and `environments`. (For Dependabot
there is no per-repo org-available endpoint; the org store answers it —
`orgs/Sassy-Dog/dependabot/secrets`, every entry `private`-visibility.) The cause is that
every org secret is `private`-visibility and public repos are excluded
(issue #178), and this repo is public by exception. (Cite the org-available
endpoint, not the repository store: an org secret re-scoped to `all` leaves
the repository store at 0 as well, so that endpoint alone cannot see the
change.)

A pull request opened with `GITHUB_TOKEN` never reaches a successful `ci`
unattended — GitHub withholds the run such a PR would otherwise trigger, the
recursion guard working as designed. `ci` is a required status check, so a
stamp PR that cannot produce one cannot merge. **That is the whole of the
argument; do not reach past it for a mechanism.** `.github/workflows/ci.yml`
fires on `pull_request`, `merge_group`, and `push` filtered to `main`, and precisely where
such a PR stalls — before it can be queued, or inside the queue — has not
been measured here. The conclusion does not depend on knowing: no successful
`ci`, no merge.

`skills/setup-deps/SKILL.md` has already ruled on this exact shape
(issue #190), and states it as "ruled out twice over": `GITHUB_TOKEN` is out
because
its writes do not re-trigger CI *and* on a second, Dependabot-specific ground
that does not carry here; re-scoping the org secrets to `all` visibility is
out; and a standing PAT in a public repo is out.

Two directions could unblock it, and neither is takeable from inside this
repo:

1. **A ruleset bypass** for a stamping identity, added in `Sassy-Dog/platform`
   where repo settings are Terraform-owned and verified.
2. **A dedicated GitHub App** that opens the stamp PR — note that this is not
   an alternative to route 1 in the naive form: `contents: write` is a token
   scope, not a ruleset bypass, so an App cannot push to `main` either. The
   variant that needs no bypass is the one where the App *opens a PR* and the
   queue merges it, its `ci` running normally because the recursion guard does
   not apply to an App token.

**Neither is designed here, deliberately.** Both put a write-capable
credential, or a hole in branch protection, on a public repo whose `main`
installs and executes on every Sassy Dog machine and cloud session — so the
blast radius is every consumer, not this repo, and `setup-deps`' repo-scoped-App
reasoning does not transfer on its own terms. Working out the trigger, the
credential store, the guards and the self-trigger stop is a design task with
its own security review, and it belongs in its own issue rather than in
sketch form here: three attempts to sketch it in this document produced three
sets of confidently wrong specifics. What this section is for is recording
*why* the absence exists, so it is not re-derived as an oversight.

A third option needs no write to `main` at all and is listed here because it
is the one a reader re-derives first: **stamp in the PR**. Issue #296 weighed
and rejected it for an unrelated reason — every PR would then touch
`.claude-plugin/plugin.json`, putting that path in every issue's `touches:`
line and permanently serializing `dispatch-ready`'s collision filter at a
throughput of 1. It is rejected on that ground, not on the credential ground
above.

The version-of-record still does not track every content merge. The read-only
release-lag reminder detects pending runtime content and directs it to a
dedicated release PR; it does not implement any rejected stamping policy.
Consumer consequences remain handled by README's stale-cache diagnostic, keyed
on file content rather than the version string. The policy decisions in this
no-auto-stamp section remain prose; neither the versioning fixture nor the
release-lag fixture proves that policy reasoning.
