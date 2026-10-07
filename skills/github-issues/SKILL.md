---
name: github-issues
description: >
  This skill should be used when the user asks to "snapshot the project board", "show the board
  by status", "pull the backlog with labels", "find stale issues", "which issues shipped but are
  still open", "find stub issues that need scoping", "file an issue but check for duplicates first",
  "dedupe before filing", "link this Sentry or feedback item to a GitHub issue", or any task
  involving GitHub issue/board reads via gh + GraphQL, label taxonomy, stale-issue detection, or
  gated dedupe-then-file issue creation. Also triggers when a project workflow skill (a generated
  survey-work or take-it) invokes sassy-dog:github-issues by name.
---

# GitHub Issues

Issue and ProjectV2 board operations for any GitHub repo: board snapshots, backlog reads, stale-issue detection, idempotent dedupe-then-file issue creation, and the fill/drain label-state transitions. Reads are free; **this skill bundles exactly two write paths — `scripts/file-or-link-issue.sh` (issue creation, preview-then-confirm) and `scripts/issue-claim.sh` (label-state transitions plus `promote`'s shape-gated assignee clear, dry-runnable)** — plus one it points at, `${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh`, which owns the engineering-dimension and severity half of the label taxonomy.

## Reads

### Board snapshot (grouped by status column)

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/github-issues`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
PROJECT_NUMBER=<n> OWNER=<org> bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/board-snapshot.sh
```

Emits `{counts, truncated, items[]}`. If `truncated: true`, raise `PROJECT_LIMIT` — the newest issues are what got dropped. For board ID discovery (project/field/option IDs), card moves, and the board-vs-labels source-of-truth question, read `references/board-graphql.md`.

### Backlog via labels

Some repos run label-driven backlogs with an empty board — an empty snapshot does not mean no backlog:

```bash
gh issue list --repo <R> --state open --limit 200 --json number,title,labels,updatedAt
```

### Boardless work-queue snapshot (fill/drain)

One call replaces the per-tick ready/in-flight/blocked list reads AND parses the three machine-readable body contracts — `touches:` collision sets, literal `Depends on #N` lines, and `stack:` chains — in one place:

```bash
REPO=<owner/name> bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh
```

Emits `{repo, me, ready[], in_flight[], blocked[]}` — `ready` ordered number-ascending with `touches`/`stack`/`sites`/`depends_on`/`unannotated` per issue, `in_flight` with the same set minus `depends_on`/`unannotated` plus a `mine` flag, carried rather than silently filtering to @me so a loop can count its own claims while still seeing other sessions'. The **execution site comes from `site:<name>` LABELS**, never from the body ([#340](https://github.com/Sassy-Dog/skills/issues/340)) — a body line can be quoted in prose, a label cannot. `sites` is a sorted **list** with no scalar beside it: `[]` is any site, one member is that site, **more than one is a conflict only a checkout named among them may take** — narrowing, never widening. Match it as `not sites or execution_site.lower() in sites` — the values are already folded, so a raw `execution_site: VDI` would otherwise hold the VDI loop's own work. A scalar would read a conflict as "any site". Judgment (touches-set intersection, priority, site matching, the smell test) stays with the caller — this is a read, not a dispatcher.

#### Resolving a site from labels you already hold

The buckets above are **label-scoped**, so two legitimate callers hold labels the snapshot never
saw: a board card from `board-snapshot.sh`, and `take-it`'s `gh issue view` on an issue nobody
promoted to Ready. They run the resolver rather than re-implementing it — no `gh`, no network, no
repo:

```bash
gh issue view <N> --repo <R> --json labels --jq '[.labels[].name]' |
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh --sites-of
```

Takes a JSON array of label names on stdin, prints the resolved `sites` array — `["Site: VDI"]`
gives `["vdi"]` and `["site:mac","site:vdi"]` gives `["mac", "vdi"]` (`json.dumps` spacing, pinned
by `scripts/test-site-filter.sh`). A label that is not a `site:` one **contributes nothing rather
than zeroing the result**: `["Site: VDI","ready","offsite:x","site:"]` still gives `["vdi"]`, since
`offsite:` is not the prefix and an empty value declares nothing. Only an array with no `site:`
label carrying a value gives `[]`. Stdin that is not a JSON array of strings — including empty
stdin, which is what an upstream failure produces — is refused with **exit 64** and no stdout, and
a missing `python3` exits **10**: read the exit status, because every one of those prints exactly
what an unlabelled issue prints. **A
consumer that paraphrases the resolution rules instead has forked them**: an inline "prefix,
folded, empty ignored" list dropped the `strip()` and answered `" vdi"` where the script answers
`"vdi"`, for the same label the header calls legal ([#341](https://github.com/Sassy-Dog/skills/issues/341)).
Exit 64 on stdin that is not a JSON array of strings.

### Reference check (grooming drift)

Resolves an issue body's code references against a real checkout — paths,
symbols, and `-p` package args:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/verify-issue-refs.sh <N> --tree /path/to/checkout --format text
```

Bodies get written from plans and older issues while the tree moves underneath
them, producing specs whose types and invariants are right and whose *locations*
are fiction — which reads as perfectly dispatchable. Exit `3` means at least one
`likely-drift` finding; `0` means none.

Symbols outside the definitions pool (including enum variants and fields) resolve
through a portable literal whole-word mention check. Git exit `1` means absent;
other grep failures are reported as `unknown`, never drift or new.

**The tier is the point, not the absence.** Every issue names things that do not
exist yet, so unresolved-means-broken would flag the whole backlog. A finding is
`likely-drift` only when something *close* exists — an invented reference is
usually nearly right, which is what lets it survive review: a near-match symbol,
a package missing its workspace prefix, a near-match **sibling file** in the
directory the path names. Everything else is `likely-new` and is reported
without gating.

**Two path rules keep the gate credible.** A path from a `touches:` line is
never drift — `touches:` declares what the PR will *write*, so it names files
that do not exist yet by design. And for any other path, "its parent directory
exists" is where the checker goes looking for evidence, not evidence in itself:
without a near-match sibling it stays `likely-new`. Gating on the bare location
fired on every new file added to an existing directory, every tick, until the
operator learned to skim past the gate — which is exactly when a real finding
slips through (issue #199). The cost is real and accepted: an invented path with
nothing resembling it beside it is no longer caught.

Run it in **both** places, because two different failure modes look identical in
the text: a reference that never existed is catchable at grooming, while one
that a later merge renamed was true when written and only a re-check at dispatch
can see it.

It resolves references; it does not read code. An issue proposing a helper that
duplicates a shipped one under another name passes clean.

### Gotcha check (config claims that rot)

Resolves a `groom-backlog` config's `gotcha_summary` against real issue state,
before `groom-backlog` copies any of it into an issue body:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/verify-gotcha-claims.sh --config <repo-root>/.claude/sassy-dog/groom-backlog.md --repo <owner/name>
```

`gotcha_summary` is prose in a frontmatter slot, so nothing recomputes it and no
human curates it — it is the one config field that can assert a time-varying fact
and never be revisited. One repo's asserted "#15 is not finished — #308 (updater)
and #334 (Windows + Authenticode) remain" for nine days after all three closed
(issue #249), aimed at a cold worktree agent with no way to check it.

**Callers inject the text between the SAFE GOTCHAS markers, never the raw field.**
Exit `3` means at least one claim was dropped. A claim citing `#N` survives only
when its asserted state is explicit and currently true; wrong, ambiguous, and
**unresolvable** all drop. So does **malformed** — a field carrying an unpaired
backtick run cannot be parsed, so all of it drops (issue #262). Inline code is
*parsed* before the sentence split, pairing spans by backtick run, so a `;`,
`.`, `!` or `?` inside `` `code=0; cmd || code=$?` `` no longer ends a claim,
and the fragments of one sentence are **linked into a group that is kept or
dropped together** — so a **span mis-parse or a clause boundary** costs a drop
rather than a half-sentence presented as verified. Splitting requires positive
evidence of a sentence start, so text after an abbreviation-shaped token
(`U.S.`, `No.`, `SHA.`) stays welded: **that over-links, and a neighbouring
invariant can be dropped for a citation that is not its own.**

**The class is bounded, not closed.** Two residuals remain, both known:

- A sentence whose **referent** was dropped can survive — `Always export it.`
  after the clause defining "it" has gone. Resolving that needs anaphora.
- A terminator mid-sentence after a token that is **longer than four
  characters, not dotted, and not a single letter** reads as a real sentence
  start, so the head is certified: `The output is truncated... then per #N …`
  certifies `The output is truncated...`. Likelihood is low — ellipses and
  `Assoc.` are rare in terse invariant prose, and the surviving text visibly
  signals incompleteness — but it is a half-sentence, so do not read the
  guarantee above as absolute.

A fourth exit `3` cause is a **splitter failure**: it reports `the claim
splitter failed` and certifies nothing, so exit 3 with an empty block is never
"nothing to verify". There is
deliberately **no skip exit** — a missing `gh` or an undetermined repo makes
every citing claim unresolvable, so unknown is held rather than passed through. Claims citing no issue are invariants and are
kept, annotated `KEEP time-varying` when they carry a date or a roadmap position
that nothing here can resolve.

`--lint` is the offline half — no `gh`, no network — reporting the four banned
shapes (issue-ref, state-verb, dated, roadmap) so an existing config carrying
them can be named at refresh rather than carried forward. The rule those shapes
come from is `sassy-dog:setup-config` → `references/config-contract.md`.

### Stale-issue detection

```bash
REPO=<owner/name> bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/stale-issues.sh
```

Three buckets: `shipped-but-still-open` (a merged PR named the issue without closing it — either in a title `(#N)` parenthetical or in the PR **body** with no closing keyword; every hit carries `matched_via: title | body | title+body`, and a body hit is a review prompt rather than a verdict), `stub-body` (needs scoping) and `tracking-parent-complete` (an open epic whose children have all closed). **Before flagging a stub to the user, read its comments** — `gh issue view N --comments` — scope often lives in a follow-up comment.

**Exit 10 is not a clean result.** Every bucket answers a healthy repo with an empty list, so a failed pull is reported as skipped-with-a-reason and never as "nothing found". Read stderr too — but the two degraded signals point in OPPOSITE directions and must not be collapsed. `truncated: true` is a possible false **negative**, scoped to `tracking-parent-complete`: the all-state pull hit its ceiling, so a finished epic may be unseen. `comment_strip_refused` is a possible false **positive**, scoped to detector 1's body arm: a comment too large to strip was left in place, so refs inside it are still readable and may be template boilerplate. One means *something may be missing*; the other means *something here may not count*.

## Writes: dedupe-then-file

Read `references/dedupe-and-file.md` before the first write of a session. The contract in brief:

1. The caller's qualifying gate runs first (this skill doesn't judge severity).
2. Idempotency by body marker (`<source>-source: <STABLE_ID>`) — re-runs return the existing issue, never a duplicate. **Two stages**: the search index (unbounded in age, but *asynchronous*) and a direct recent-listing scan (read-after-write consistent, bounded to `--recent-scan` issues). A re-run seconds later is covered by the second; a marker from years ago by the first. **Both** filter on the delimited footer `<!-- <marker> -->` — GitHub phrase search matches a token *subsequence*, so a marker that is a prefix of a sibling's is not swallowed.
3. **Preview-then-confirm**: dry-run the batch, show `would-file` results, file only on approval.
4. **Burst rail**: > 5 would-file in one run → stop and show the list; consider one umbrella issue.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/file-or-link-issue.sh \
  --repo <owner/name> \
  --marker "sentry-source: PROJ-123" \
  --title "<title>" --body-file /tmp/body.md \
  --labels "bug,sentry-escalation" \
  --ensure-label "sentry-escalation:9c846b:Auto-filed from a Sentry hit" \
  --project-id PVT_xxx --status-field-id PVTSSF_xxx --status-option-id <backlog-id> \
  --dry-run
```

Output actions: `filed` / `already-linked` / `filed-no-board` / `would-file`. An `already-linked` carries `via: search | recent-scan` naming which idempotency stage answered; the three filing outcomes carry `scan_truncated`, true when the scan window came back full and a match one row past its edge would have been invisible. Board placement is optional and degrades gracefully. Exit `2` covers every transport failure — an idempotency scan that could not be performed, and a `gh issue create` that failed — so retrying is always safe; exit `1` is reserved for calling the script wrong.

## Writes: label-state transitions (fill/drain claims), and one assignee clear

The org label taxonomy has **two canonical homes, disjoint by design.** Neither script defines the other's labels — two homes for one label is precisely the drift both exist to prevent:

| Subset | Canonical home | Written |
|--------|----------------|---------|
| dev-workflow **state**: `ready`, `in-progress`, `blocked` | `scripts/issue-claim.sh` (this skill) | ensure-created at the claim/promote/block transition that needs it |
| signal escalation: `sentry-escalation` | value in `scripts/issue-claim.sh`'s table | written by `scripts/file-or-link-issue.sh --ensure-label`, whose caller quotes that row |
| engineering **dimensions + severity** (10 + 4) | `${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh` | applied repo-wide, ambient classification (below) |

Dependabot's per-ecosystem labels (`javascript`, `github_actions`, `rust`, `dart`, …) are auto-created and correctly differ per repo — no script here touches them.

`scripts/issue-claim.sh` is the canonical home of the boardless dev-workflow label taxonomy — those labels, their colors, and their descriptions are defined in the script, nowhere else. Read them from the script itself with `issue-claim.sh taxonomy` (emits `name|color|description`, needs no gh/jq/repo); the table below is the same data for humans:

| Label | Color | Meaning |
|-------|-------|---------|
| `ready` | `38fa99` | Dispatchable: a cold worktree agent could ship this (groom-backlog promoted) |
| `in-progress` | `190132` | Claimed by a take-it/dispatch-ready loop |
| `blocked` | `52363d` | Needs a human decision before it can be dispatched (dispatch-ready demoted) |
| `sentry-escalation` | `9c846b` | Auto-filed from a Sentry hit |

**The colors are measured, not chosen.** All four used to share a hex exactly with a canonical label from the other taxonomy (`ready`/`sev:low`, `in-progress`/`architecture`, `blocked`/`sev:critical`, `sentry-escalation`/`sev:critical`) — ΔE 0, on issues that carry one label from each set. The replacements are the maximum-separation point of a CIEDE2000 sweep over the union of both taxonomies; `align-labels.sh --collisions` now gates the pair. Don't nudge them toward a palette default.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/issue-claim.sh \
  <claim|release|block|promote|demote> <N> [N ...] \
  [--repo <owner/name>] [--comment "why"] [--force] [--dry-run]

bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/issue-claim.sh \
  sync-labels [--repo <owner/name>] [--dry-run]      # reconcile the 4 labels, touch no issue
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/issue-claim.sh taxonomy
```

- `claim` — assignee @me + `in-progress`, strips `ready`; **skips issues already assigned to someone else** (double-pick guard; `--force` overrides).
- `release` — strips `in-progress` (post-merge: `Closes #N` closes the issue but never strips labels). Deliberately **not** symmetric with `claim`: it leaves the assignee alone, because on a closed issue that assignee records who shipped it.
- `promote` — adds `ready`, and clears a **residual claim assignee** — but only the one shape that is residue *by construction*: assigned to exactly `@me`, **no** `in-progress` label, and the issue **OPEN**. `claim` always writes those two halves in a single edit and the loop only ever assigns `@me`, so no *other* account can produce that shape. Every other shape is **reported and left alone**: a different assignee is a human who took it, `@me` *with* `in-progress` is live in-flight work, an issue holding `@me` alongside a human is not residue either, a **CLOSED** issue keeps its assignee — that is the who-shipped-it record `release` is deliberately asymmetric to protect, and `promote` has no business destroying it — and a probe that could not run (own login unresolved, issue unreadable, result truncated) is unknown, which is not verified. `--force` does not widen it. **One stated limit** [#287](https://github.com/Sassy-Dog/skills/issues/287): `@me` is the *operator's* login rather than a loop identity, so an issue the operator assigned to themselves without setting `in-progress` matches the residue shape too. Without this, a reopened and re-promoted issue arrives still assigned and `dispatch-ready`'s §4 filter skips it as "another session got it", which is false and silent (issue #281). `--dry-run` previews the decision as `would clear`.
- `block` / `demote` — **require `--comment`**; a demotion without a reason is a silent failure for the next human. `block` strips `ready` **and** `in-progress` and adds `blocked`; `demote` strips `ready`.
- **`detail` carries `requested: <labels>` on every `ok` from its ORDINARY path, for the four subcommands that remove one** — `claim`, `release`, `block`, `demote`. It names what the edit **requested** to remove, minus anything dropped as absent from the repo; a zero exit proves gh applied that set. Label names are matched case-insensitively (as gh matches them) and reported in taxonomy spelling. It is **not** a claim the issue carried those labels — `demote` on an issue with no `ready` succeeds, removes nothing, and reports `requested: ready` all the same, so never read it as past tense. (`block` requests both of its labels, so its value is `requested: ready,in-progress`.) Distinguishing a real strip from a no-op needs live state, which is the `removed:` field, which reads the issue's live labels on the repair path and **replaces** `requested:` there — **except** when the probe could not answer: a failed or malformed read reports `unknown`, and that one variant rides **alongside** `requested:` rather than displacing it, because a non-answer must not suppress a computable fact. Only `block` shows the pair — every other removing subcommand has a single removal, which is always the dropped one, so its `requested:` field is omitted rather than printed empty, and `removed: unknown` appears alone. An empty `removed:` list is printed deliberately: that is what makes a no-op strip visible. Note all four removing subcommands previously emitted an empty `detail` on their ordinary paths and now do not.
- Every label is reconciled before use: created when absent, **corrected when its color or description has drifted**, untouched when it already matches. A colour change therefore reaches repos that already carry the label — it used to be `gh label create || true`, which fails on an existing label and silently left every onboarded repo on the old colour forever.
- `sync-labels` does that reconcile for all four labels in one pass without touching an issue — the entry point for propagating a taxonomy change to a repo that isn't currently transitioning anything. `--dry-run` previews.
- Mutations route through pr-shepherd's `gh-retry.sh`; one JSON line per issue on stdout (`sync-labels` emits one per label); batch continues past per-issue failures (exit 2 if any hard-failed). A label reconcile that fails is always announced on stderr, and since [#288](https://github.com/Sassy-Dog/skills/issues/288) it is no longer harmless: if the reconcile leaves the label **absent**, the edit naming it fails, and only that subcommand's own **removal** token is tolerated — so a failed `--add-label` makes `claim`/`block` report `failed` and exit 2 rather than `ok`. That is deliberate. An `ok` on an edit that wrote nothing left the issue unassigned, unlabelled and still `ready`, which is how the same issue reached two cold agents. A tolerated removal still reports `ok` and names the swallowed token in its `detail` and on stderr — and since [#323](https://github.com/Sassy-Dog/skills/issues/323) it also **repairs** the edit rather than abandoning it. `gh` applies adds and removes as *independent* operations, so one unresolvable removal token used to take every **other** removal in that edit down with it while the adds landed: `block` on a repo lacking `in-progress` added `blocked`, left `ready` standing, and reported `ok`, so a demoted issue stayed in every `--label ready` queue. The script now re-issues the edit without the named token — a label absent from the repo is on no issue, so dropping it is a no-op by construction — and a retry that fails is a hard failure, which keeps #288's wholly-failed-add case reporting `failed`.

## Writes: canonical dimension + severity labels

`${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh` — plugin root, **not** this skill's `scripts/` — is the canonical home of the other half: the 10 engineering dimensions (`architecture` `assessment` `ci-cd` `dx` `infra` `observability` `security` `tech-debt` `testing` `epic`) and the 4 severities (`sev:critical` `sev:high` `sev:medium` `sev:low`). Colors and descriptions live in that script's table and are deliberately **not** mirrored here — a second copy is the drift the table exists to prevent. Read them with `--check`.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo <owner/name> --check     # drift report, exit 3 if drifted, no writes
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo <owner/name> --dry-run   # same pass, always exit 0
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo <owner/name>             # create missing + correct drifted
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --collisions                    # cross-set colour check only, no repo
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh taxonomy                        # the table as data, no repo
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo <owner/name> --migrate <plan> --dry-run
bash ${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh --repo <owner/name> --migrate <plan>
```

- Idempotent: it creates what is absent and corrects color/description/case drift, so an already-aligned repo issues zero writes. One JSON line per label on stdout, summary on stderr.
- **The default pass never deletes a label and never relabels an issue.** Only `--migrate` can, and it is the one destructive capability in this plugin.
- **`--migrate <plan>` folds a repo's one-off labels onto the canonical set: relabel first, delete second, structurally.** `<plan>` is data — one `<repo>|<old>|<new>` per line, `#` comments allowed, `-` reads stdin — so one file drives every repo and each run processes only the lines matching `--repo`. Deleting a label strips it from every issue carrying it, unrecoverably, so `gh label delete` has exactly ONE call site in the script, inside `migrate_delete_gate()`, whose own body re-queries GitHub immediately above it and withholds the delete on every path that is not "zero issues still carry the old label" — a failed or truncated re-query included, because unknown is not verified. Held-back mappings are named on stderr and exit 4. Run `--dry-run` first and read it: the preview names every issue it would relabel and every label it would then gate a delete on. Targets are never invented — run the align pass first — and a mapping touching `ready` / `in-progress` / `blocked` / `sentry-escalation` is refused (exit 64) before any network call, because those belong to the other taxonomy.
- Three colors sit deliberately off their modal palette value so chips stay distinguishable (`security`, `tech-debt`, `epic`), and `infra`'s was picked by measured perceptual distance. The script header records which collision each one escaped; don't "tidy" them back.
- **Cross-set check.** Each taxonomy used to validate only against itself, which is how four pairs reached ΔE 0. `--collisions` scores every (dev-workflow × canonical) pair with CIEDE2000 and fails below ΔE 10; `--check` runs it too and folds a hit into its exit 3. It reads the dev-workflow colors from `issue-claim.sh taxonomy` rather than copying them — a shared *check*, never a shared *table*.
- **`taxonomy` is the mirror of that emitter**: `name|color|description` per canonical label, no gh, no jq, no repo, no network. A consumer that needs the table as *data* reads it here; one that needs it *applied* runs the align pass. Neither transcribes it — `assess-it` did, froze at the pre-#158 colours, and painted a collision into every repo it audited (issue #167). Gate 8 of `scripts/preflight.sh` now fails on any taxonomy colour that appears outside its home.

## Bundled scripts

| Script | Purpose |
|--------|---------|
| `scripts/board-snapshot.sh` | ProjectV2 snapshot grouped by status. Read-only. Guards the `--limit` truncation trap. |
| `scripts/queue-snapshot.sh` | Boardless fill/drain queue read: ready/in-flight/blocked buckets + the parsed `touches:`, `Depends on #N` and `stack:` body contracts, plus the execution site read from `site:<name>` **labels** (prefix-matched including the colon, folded, empty value ignored). Emits `sites` as a sorted list with no scalar, so several labels are a conflict only a checkout named among them may take rather than "any site". `--sites-of` exposes that same resolver to callers holding labels from elsewhere — JSON array in, JSON array out, no `gh`. Read-only. Exit 10 skip convention. |
| `scripts/verify-issue-refs.sh` | Resolves a body's paths, symbols, and `-p` package args against a checkout. Tiers each miss `likely-drift` (something close exists — a near-match symbol, package, or sibling file) vs `likely-new` (nothing resembles it, or the path came from `touches:`), and suggests the near match. Read-only with respect to the tree and the network; it writes one temp file for the symbol pool. Exit 0 clean / 3 drift / 10 skipped / 64 usage. |
| `scripts/verify-gotcha-claims.sh` | Resolves a `groom-backlog` config's `gotcha_summary` against issue state and emits only the claims that survive, between SAFE GOTCHAS markers. Fail-closed: wrong state, ambiguous assertion, unresolvable, and malformed (an unpaired backtick run, which drops the whole field) all drop, so there is no skip exit. Inline code is parsed, spans paired by backtick run, before the sentence split, and the fragments of a sentence are committed as one group, so shell punctuation inside a span never ends a claim and a mis-parse degrades to a drop rather than a certified fragment. A splitter failure is its own exit 3, never a clean empty field. `--lint` reports time-varying shapes offline. Read-only. Exit 0 clean / 3 dropped or found / 64 usage. |
| `scripts/stale-issues.sh` | shipped-but-still-open + stub-body + tracking-parent-complete detection. Read-only with respect to the repo and GitHub; it stages its three pulls in a temp dir, because argv cannot carry them. Detector 1 has two arms and labels every hit `matched_via`: PR **titles**, handling compound refs like `(#419 + #421)`; and PR **bodies**, where the reference nearly always is — GitHub appends `(#N)` to the squash-merge *commit* title, not the PR title, and appends the PR's own number ([#337](https://github.com/Sassy-Dog/skills/issues/337)). The body arm excludes refs under a closing keyword (GitHub already closed those) and refs inside HTML comments (leftover PR-template boilerplate, which would otherwise flag on every PR); both exclusions are deliberately narrow, since an over-broad one is a silent false negative — suppression is positional rather than body-global, the keyword must sit on the same line and in prose (not in a code fence, a code span or a quotation), and a comment that would swallow the body is refused and marked `comment_strip_refused`. Detector 3 reads the epic-split `Part of #<parent>` convention with a prefix guard (`#28` never claims `#283`'s children) and reports `truncated: true` — never a clean-looking empty result — when its all-state pull hits `ALL_LIMIT` (default 500). Exit 0 clean / 10 skipped **or a failed pull**: a degraded run never renders as three empty sections and exit 0. |
| `scripts/file-or-link-issue.sh` | Write path #1: issue creation. Marker-keyed create-or-find + optional board add. Idempotency is two stages — the asynchronous search index, then a read-after-write-consistent recent-listing scan (`--recent-scan`, default 100) that closes the index-lag window a bare search re-filed into (#339). Both stages filter on the delimited marker footer, so a prefix-sibling is never returned. A scan that cannot be performed, and a failed create, both exit `2` rather than filing blind or looking like a usage error. `--dry-run` for previews. |
| `scripts/issue-claim.sh` | Write path #2: fill/drain label-state transitions (claim/release/block/promote/demote) — plus its one assignee-CLEARING write, `promote`'s shape-gated claim-residue clear (#281), the counterpart to the `--add-assignee` half `claim` writes — plus `sync-labels` (reconcile the taxonomy, touch no issue) and `taxonomy` (print it). Owns the dev-workflow half of the label taxonomy; labels are created *and corrected* in place; `--dry-run`; retries via pr-shepherd's `gh-retry.sh`. |

Not bundled here but paired with it: `${CLAUDE_PLUGIN_ROOT}/scripts/align-labels.sh` owns the dimension + severity half. It lives at the plugin root because it aligns a whole repo rather than serving one issue-flow call.

## Guardrails

- Never `gh issue create` directly when filing from an automated signal — route through `file-or-link-issue.sh` so idempotency and markers can't drift.
- Never hand-roll `gh label create`, claim-label `gh issue edit`, or assignee edits in a fill/drain flow — route through `issue-claim.sh` so the taxonomy (names, colors, descriptions), the double-pick guard, and `promote`'s residue gate can't drift. A hand-rolled `--remove-assignee` in particular bypasses the shape gate that is the only thing keeping a human's assignment off the strip list.
- Never hand-roll the dimension/severity labels either — route through `align-labels.sh`, and never define a label in both scripts: one label, one home.
- Mutating board calls go through pr-shepherd's `gh-retry.sh` (Projects GraphQL flakes); board claims are best-effort, never a hard failure.
- Signal escalated on an existing issue → comment on it, don't re-file.
