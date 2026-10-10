---
name: setup-deps
description: >
  This skill should be used when the user asks to "set up Dependabot for this repo", "set up
  dependency automation", "set up dependency updates here", "set up dependabot auto-merge", "set
  up the dependency workflows", "add dependabot config here", "wire up dependabot auto-merge",
  "group the dependabot PRs", "stop the dependabot PR flood", "why do dependabot PRs keep failing
  CI", "fix the bun.lock dependabot problem", "regenerate lockfiles on dependabot PRs", or
  "standardize dependency updates across our repos". Generates and re-syncs a repo's
  `.github/dependabot.yml` plus its dependency automation workflows (auto-merge, bun.lock sync,
  pod lockfile sync) from detected ecosystems. Run from inside the target repository; re-runnable
  as the stack evolves.
---

<!-- generated-by-companion: templates in references/templates/ -->

# Setup Deps

Generator/refresher for a repo's dependency automation, in the same family as
`setup-config` and `setup-hooks`: detect the stack, render from templates,
reconcile only what this generator owns.

It renders up to three things:

| File | When |
|---|---|
| `.github/dependabot.yml` | always — grouped, one entry per (ecosystem, **directory**) |
| `.github/workflows/dependabot-auto-merge.yml` | when the repo has a merge gate **AND is not public** — two preconditions, see §2 |
| `.github/workflows/dependabot-bun-lockfile.yml` | legacy fallback — only when npm has `lockfile_risk` (binary `bun.lockb`, or a repo deliberately on npm + sync) **AND the repo is not public**; a text `bun.lock` renders the native `bun` ecosystem instead, no sync workflow. One per bun install root, not one per repo |
| `.github/workflows/dependabot-pod-lockfile.yml` | when cocoapods is detected **and** the app's `ios/Podfile.lock` is tracked (see §3) **AND the repo is not public** |

Bundled scripts (`scripts/`): `detect-ecosystems.sh` (probe), `render-dependabot.sh` (render),
`validate-dependabot.sh` (post-render assertion + divergence check), and `lib-ecosystems.sh` — the
one ecosystem table all three read, so the validator can never agree with a renderer that is wrong.

Ownership marker: the `generated-by:` comment on the first non-blank line after the YAML document
start. Re-runs reconcile **only** files carrying that marker — a hand-written `dependabot.yml` is
reported and left alone, never overwritten.

**Ownership matching is deliberately wide: accept EITHER marker namespace — the current
`sassy-dog:` prefix and the pre-rename `ai-agent-skills:` prefix (plugin ≤ 2026.8.20) — paired
with ANY producer name this generator has ever emitted: `setup-deps` (current), `refresh-deps`
(plugin ≤ 2026.8.39), and `refresh-sassydog-deps` (plugin ≤ 2026.7.21).** A file is owned when its
marker matches:

```text
generated-by: (sassy-dog|ai-agent-skills):(setup-deps|refresh-deps|refresh-sassydog-deps)
```

All six namespace × producer-name combinations are owned. The plugin rename moved the namespace
*before* the colon; the two generator renames moved the name after it. This matters more here than
almost anywhere else in the plugin: the marker is committed **inside every consumer repo**, in
`.github/dependabot.yml` and each dependency workflow, so a matcher narrowed to the current
producer name would classify every pre-rename file as hand-written and refuse to reconcile it —
and it would fail *silently*, because the contract above is report-and-skip, not error.
**Normalise the marker to the current `sassy-dog:setup-deps` form on write** (expect a one-line
diff per file on a pre-rename repo's first re-run; that is the intended outcome, not drift).

## 1. Detect

Before rendering anything, classify each target file: marker matching the wide pattern above →
**owned**, reconcile it; no `generated-by:` marker at all → **hand-written**, report and skip.
Never narrow that probe to the current producer name — skipping a repo's own generated files
because they carry a superseded name is the silent-failure path this contract exists to prevent.

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/setup-deps`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/detect-ecosystems.sh
```

Emits `{repo, ci_workflow, ecosystems{<eco>: {detected, lockfile_risk, directories[], why}},
present[], needs_lockfile_sync[], locations[], vendored_excluded{}, detect_failures[]}`. Evidence
is tracked repo files only, never what is installed locally.

`needs_lockfile_sync` is the field that decides whether this repo's Dependabot PRs can ever merge.
Read §3 before skipping it.

**`directories` is the field that decides whether Dependabot finds anything at all.** Dependabot
reads the manifest AT `directory:` and does not recurse, so an ecosystem detected in a
subdirectory and rendered at `/` is a lane pointing at nothing — valid YAML, zero PRs, no error
(issue #169). The probe therefore reports one directory per manifest, with three ecosystem-specific
collapses. Two are backed by a consumer repo's committed config: **gradle** folds modules into the
build root that holds `settings.gradle` (tailoredtip: `/app/android`, never `/app/android/app`) and
**cargo** folds `[workspace]` members into their workspace root (devcanopy: `/` and `/agent`, never
the nine `crates/*`). The third is backed by observed failures instead (issue #467): **bun** folds
workspace members into a root that holds a text `bun.lock` and whose `package.json` declares a
top-level `workspaces` (array form or `{"packages": [...]}`). A member is a directory whose path
under that root matches one of those globs and that carries no bun lockfile of its own — membership,
not ancestry, so a `package.json` the globs do not name keeps its lane. Globs follow Bun's syntax
(`*` stays inside one segment, `**/` is zero or more segments, `[ab]`, one level of `{a,b}`); every
`!` glob excludes after all positive globs whatever its list position, and a `!` glob's trailing `/**`
also matches zero segments — each undocumented point resolves toward keeping a lane. `**` is
honoured only as a whole path segment. A glob the translator cannot handle — for example nested
braces, extglob, an unterminated `[` or `{`, a class range whose ends are not both within one of `0-9`, `a-z` or
`A-Z` (`[.-0]`), an empty `{a,}` alternative, a `**` that is not a whole
segment, or any pattern the local `grep -E` refuses to compile — collapses nothing under that root
and is reported in `detect_failures`. A member-only PR never
rewrites the root lockfile, so it fails `bun install --frozen-lockfile` and cannot merge (what2wear:
seven red PRs, while the root entry's grouped PR passed). A repo with only the binary `bun.lockb` is
not bun at all — it stays npm + lockfile-sync, and its lanes do not collapse. npm, pub, nuget and
docker do **not** collapse — velovate's hand-written config lists every npm workspace member, every
pubspec including a nested one, every `.csproj` folder and every Dockerfile folder, and that is the
coverage it wants (those velovate lanes are `npm`, which does not regenerate `bun.lock` either, so
they are the committed config's choice and not evidence that per-member bun lanes merge). An ecosystem
detected with an empty `directories` is reported in `detect_failures` and rendered as nothing;
never paper over it with `/`.

### The diverged-but-owned case

Before reconciling an owned `dependabot.yml`, render the fresh one (§3) and compare it with what
is already committed:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/validate-dependabot.sh /tmp/dependabot.new.yml \
  --compare-to .github/dependabot.yml --cooldown bun=7
```

The `--cooldown bun=7` above stands for every cooldown the committed file already carries: the
request is not stored anywhere but that file, so read each ecosystem's `cooldown:` /
`default-days:` from `.github/dependabot.yml` and pass it as `--cooldown ECOSYSTEM=DAYS` to **both**
the render and this validate. Omit the flag when the committed file carries no cooldown.

Any lane the existing file declares that the fresh render does not is printed as `DIVERGED` and
fails the run. So is a `cooldown:` the existing file carries that the fresh render lacks, reported
as `DROPPED`; the likeliest cause is a forgotten `--cooldown`, not a hand-added block. A cooldown
the render carries at a different value is reported as `CHANGED`. Both are covered under "Changing
or removing a cooldown" below. **A lost lane is the stop signal, not a formality.** A file stamped
`template-version: N` whose content a fresh render of 3 or 4, the two current stamps, no longer
reproduces is the most dangerous state this generator has: the matcher says "mine, reconcile it", the render quietly drops lanes the repo depends on, and
nothing errors — tailoredtip sat in exactly that state with four correctly-directed lanes under a
v2 marker. Report the dropped lanes to the user and stop; do not overwrite, and do not "fix" it by
re-stamping the marker, which only launders a diverged file as current.

**A vendored example manifest is not a project.** Scaffolder templates, test fixtures and sample
projects commit real-looking manifests, and an unfiltered path match counts them as evidence: a
scaffolding `templates/package.json` whose fields are literally `{{PROJECT_ID}}` once made this
probe report `npm: detected` on a repo with no npm project at all. `dependabot.yml` then gets an
ecosystem block for a directory that is not a project, and Dependabot either opens PRs against a
placeholder or silently does nothing — the render is otherwise correct, so nothing surfaces the
mistake. The probe therefore drops these paths from the corpus **before** any ecosystem test runs:

```text
(^|/)(templates?|fixtures?|__fixtures__|testdata|test-?data|examples?|node_modules)(/|$)
```

Two properties to preserve if you touch it:

- **Exclude by directory NAME, never by depth.** That is what keeps the `(^|/)` anchoring intact —
  `packages/web/package.json` is still detected (the workspaces monorepos in this org depend on
  it) while `templates/package.json` and `packages/web/__fixtures__/package.json` are not.
- **Path convention beats content-sniffing.** A fixture manifest can be perfectly valid JSON and
  still not be a project, so parsing it would not help. The assumption this rests on: anything
  genuinely built from those directories also has a real manifest outside them. A repo that
  violates it — a real app living only under `examples/` — needs the ecosystem added by hand.

`vendored_excluded` reports `{count, pattern}` so the filter is visible rather than silent; a
detection that quietly drops files is the same class of problem as the one it fixes. When a count
looks wrong, list what went: `git ls-files | grep -E '<pattern>'`.

## 2. Confirm the merge gate

Auto-merge is only safe behind a required check. Probe both — legacy branch protection and rulesets
are different APIs, and a repo protected by a ruleset returns 404 from the protection endpoint,
which reads as "unprotected" if you only ask one:

```bash
gh api "repos/${REPO}/branches/${BRANCH}/protection" --jq '.required_status_checks.checks[]?.context'
gh api "repos/${REPO}/rulesets" --jq '.[] | select(.enforcement=="active") | .name'
```

**Read the HTTP status, not the empty stdout — the protection probe has three outcomes, not two.**
A failed `gh api` prints the code on stderr (`gh: Branch not protected (HTTP 404)`); when a wrapper
swallows that line, force the status into view by re-running the same call with `--include` and
taking the first line of output.

| Response | Means | What it changes about the advice |
| --- | --- | --- |
| `200` | Legacy branch protection exists | read the required contexts off the response |
| `404` | No *legacy* protection — a ruleset may still gate the branch | ask the rulesets probe before concluding anything |
| `403` | The plan does not offer protection **at all** | there is nothing to enable; stop recommending a gate |

`403` is what a **private repo on a free personal account** returns, and it comes back from *both*
probes — branch protection and rulesets alike require GitHub Pro or a public repo. Never fold it
into `404`: `404` means "you could enable this", `403` means "you cannot, so this skill's refusal to
render the auto-merge workflow is the only enforcement there will ever be." Reported as a `404`, it
turns into advice the account cannot act on.

### The second precondition: repo visibility

**A merge gate is necessary but NOT sufficient. Probe visibility before classifying — it can veto
every arm below.**

```bash
gh repo view "${REPO}" --json visibility --jq .visibility
```

`public` → **do not render ANY of the three App-token workflows**, whatever the gate says:
`dependabot-auto-merge.yml`, `dependabot-bun-lockfile.yml`, and `dependabot-pod-lockfile.yml`.

**The precondition belongs to the credential, not to the auto-merge workflow.** All three mint a
GitHub App token from the same two org secrets, and org secrets at `private` visibility (= private +
internal) **exclude public repos** — in the Actions store *and* the Dependabot store alike. Rendered
anyway, `secrets.*` resolves to the empty string and `create-github-app-token` fails, but not until
that repo's next Dependabot PR — days or weeks later, as an auth error that looks unrelated to the
render that caused it. Scoping this rule to auto-merge alone is what shipped the identical failure
through two other doors ([#186](https://github.com/Sassy-Dog/skills/issues/186)).

The two lockfile templates are the **worse** case, and the ordering is worth noticing:
`dependabot-auto-merge` deliberately never checks out ("no checkout. PR code never executes here"),
while both lockfile templates `actions/checkout` the **PR head ref** inside a job that mints the
credential. They are hard-gated to `dependabot[bot]`, bun runs `--ignore-scripts`, and since
[#232](https://github.com/Sassy-Dog/skills/issues/232) the token is no longer handed to
`checkout` at all — `persist-credentials: false`, no `token:`, and the push authenticated from its
own step `env:` — so the posture is sound as it stands, but the two templates carrying more surface
were the two without the precondition.

Report the skip and its reason; per this skill's report-and-skip contract, a skipped file is a
reported outcome, never a silent omission. **For the two lockfile templates the report must also
carry the consequence and the manual path**, because unlike auto-merge — which had run zero times in
sixty and was simply dropped — losing lockfile sync breaks the very thing the template exists for:

> `SKIPPED dependabot-bun-lockfile.yml` — repo is public, so `PLATFORM_WRITER_APP_*` cannot resolve
> here (#178). **Consequence:** every npm-path Dependabot PR will fail a frozen-lockfile CI install
> and cannot merge. **Workaround:** regenerate the lockfile locally on the PR branch and push it,
> per PR — this is the answer for public repos, not a stopgap (see below).

### The manual path IS the answer for a public repo — deliberate non-automation

Decided in [#190](https://github.com/Sassy-Dog/skills/issues/190). **A public repo
regenerates its lockfile by hand on the PR branch. Do not automate it, and do not invent a
substitute credential to fill the gap.**

This is a decision, not an unfinished item, and it should not read as one. Automating it requires a
**write-capable credential living inside a public repo**, and every route there is worse than the
manual push:

- **`GITHUB_TOKEN`** — ruled out twice over. See the trap immediately below for the first reason;
  the second is that a `GITHUB_TOKEN` push lands as `github-actions[bot]`, which does **not**
  re-trigger CI on the new commit. The lockfile would be fixed on a PR whose checks never re-run,
  so a human is still required — automation that does not remove the human is not automation.
- **Re-scoping the org secrets to `all` visibility** — widens `PLATFORM_WRITER_APP_*` to every
  public repo in the org to serve one, inverting the `private`-visibility default deliberately.
- **A PAT** — a standing credential in a public repo, on a workflow that checks out the PR head ref.

**If the manual cost ever genuinely bites**, the one acceptable route is a **dedicated App installed
only on that repo** with `contents: write`, its credentials held as **repo-level Dependabot secrets**
(not org). That keeps the blast radius to the single repo. Take that route only when a real repo is
paying the cost — not pre-emptively.

Do not reach for a `GITHUB_TOKEN` variant as a consolation prize without testing it first: workflows
triggered by Dependabot's `pull_request` get a **read-only** `GITHUB_TOKEN` and are served from the
Dependabot secret store, not Actions, so the naive swap fails for a second, different reason.

The `private`/`internal` case falls through to the gate classification below, unchanged.

Classify into exactly one:

- **merge queue** → render the `MERGE_QUEUE` arm (plain `--auto`, no method flag).
- **required checks, no queue** → render the `DIRECT_MERGE` arm, and confirm
  `allow_auto_merge` is on (`gh api repos/${REPO} --jq .allow_auto_merge`); enable it if not.
- **no gate at all** → **do not render the auto-merge workflow.** Render `dependabot.yml`, plus any
  lockfile-sync workflow that its own preconditions still allow — **the visibility veto above
  applies here too**, so a public repo gets `dependabot.yml` alone. Tell the user the repo needs a
  gate first. With no required
  check, `--auto` merges immediately and the review gate is imaginary.
  **`403` lands in this arm too, but for the opposite reason** — not "has not enabled a gate" but
  "cannot". Same behaviour, different report: say the plan offers no gate at all, that the missing
  auto-merge workflow is therefore permanent rather than pending, and that reviewing Dependabot PRs
  by hand is the enforcement. Do not hand that repo an "enable a required check first" follow-up.

## 3. Render

Substitute `{{FACT}}` values and delete the `# {{IF:FLAG}}` / `# {{ENDIF}}` blocks that do not
apply. Never hand-edit a rendered file to fix a bug; fix the template and re-render.

**`dependabot.yml` is rendered by script, and VALIDATED AFTER RENDER — it is no longer valid by
construction.** `dependabot.yml.template` (v3, or v4 when a cooldown is requested) repeats a block per (ecosystem, directory) pair, which
deletion alone cannot express, so the old static guarantee is gone here on purpose. What replaced
it is stronger: the render is parsed and every emitted `directory:` is asserted to hold the
manifest it claims. The old guarantee never caught the bug that forced the change — a v2 render was
always valid YAML, it just pointed at directories with no manifests. (`setup-hooks` keeps its
deletion-only invariant; it has no per-location repetition and needs none.)

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/detect-ecosystems.sh > /tmp/deps.json
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/render-dependabot.sh \
  --detect-json /tmp/deps.json --out /tmp/dependabot.new.yml
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/validate-dependabot.sh /tmp/dependabot.new.yml
```

**Optional per-ecosystem cooldown.** `dependabot.yml` can carry Dependabot's release-age buffer on
chosen ecosystems: pass `--cooldown ECOSYSTEM=DAYS` (repeatable, one per ecosystem, DAYS an integer
1..90) to **both** scripts. It cannot be derived from the repo, so ask the user which ecosystems want
one; absent the flag, nothing is rendered. Example, a 7-day cooldown on routine Bun version updates
(the first consumer, brewslate#112):

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/render-dependabot.sh \
  --detect-json /tmp/deps.json --cooldown bun=7 --out /tmp/dependabot.new.yml
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/validate-dependabot.sh /tmp/dependabot.new.yml \
  --cooldown bun=7
```

It renders `cooldown:` / `default-days: N` on **every lane of that ecosystem** (a `bun` request
covers each bun directory) and on no other entry, and the file header gains a paragraph saying so.
Dependabot applies `cooldown` to **version updates only**, so security updates still arrive at once
and the security groups are untouched. Only `default-days` is supported; `semver-*-days`, `include`
and `exclude` are not rendered. The request is refused, never silently dropped, when DAYS is not
1..90, an ecosystem is named twice, or the ecosystem has no lane in the render. The validator
accepts a `cooldown:` only where the same `--cooldown` request says so and fails any other (a
hand-added one, a different value, a lane missing it, extra keys). Both scripts parse the request
through one shared function in `lib-ecosystems.sh`, so they refuse the same input. With no request
the output is byte-identical to the previous render (`template-version: 3`); a cooldown render
stamps `template-version: 4`, set by the renderer.

**Re-rendering keeps the cooldown only if you carry it.** The request is not stored in the repo;
the committed `.github/dependabot.yml` is its only record. Before any re-render, read each
ecosystem's `cooldown:` / `default-days:` from that file and pass it as `--cooldown ECOSYSTEM=DAYS`
to both scripts. Forgetting it fails closed: the validator reports the dropped cooldown as
`DROPPED`, naming the forgotten flag, and never writes a file that strips it.

**Changing or removing a cooldown is a deliberate plan item, not drift.** Put it in the plan the
user approves (`bun` 7 days to 14, or `bun` cooldown removed), then run the sequence below. The
`--change-cooldown ECOSYSTEM` flag is the explicit acknowledgement that the committed cooldown for
that one ecosystem is meant to differ; it is accepted only with `--compare-to`, only for an
ecosystem whose committed cooldown the render really changes or drops, and it waves through nothing
else. A forgotten `--cooldown` has no such acknowledgement, so it keeps failing. Example, brewslate's
`bun` 7-day cooldown:

```bash
# Change 7 -> 14: the NEW value goes to render and validate; the acknowledgement goes to validate.
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/render-dependabot.sh \
  --detect-json /tmp/deps.json --cooldown bun=14 --out /tmp/dependabot.new.yml
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/validate-dependabot.sh /tmp/dependabot.new.yml \
  --cooldown bun=14 --change-cooldown bun --compare-to .github/dependabot.yml

# Remove: no --cooldown for bun at all; the acknowledgement is what permits the drop.
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/render-dependabot.sh \
  --detect-json /tmp/deps.json --out /tmp/dependabot.new.yml
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-deps/scripts/validate-dependabot.sh /tmp/dependabot.new.yml \
  --change-cooldown bun --compare-to .github/dependabot.yml
```

A run that reports `CHANGED` or `DROPPED` for an ecosystem the user did not ask to touch is the
forgotten-flag case: re-render with the committed value instead of adding `--change-cooldown`.

**Never write a render the validator rejected**, and never "fix" a rejection by editing the output:
a failing lane means the derivation is wrong, so fix `lib-ecosystems.sh` and re-render. The
workflow templates stay hand-rendered — they carry no per-location repeat.

Every template already carries the current `generated-by: sassy-dog:setup-deps` marker, so a
render normalises a pre-rename file's marker for free — keep the template's marker line verbatim
rather than preserving whatever the existing file carried. Leave each template's
`template-version` alone. The one exception is `dependabot.yml`, whose stamp the renderer sets: 3, or 4
when a cooldown is rendered. Otherwise move a stamp only when the template's *content* changed. The
producer rename is an identity change, and the stamp should not move for it. **A bump does not trigger anything** —
measured while shipping [#316](https://github.com/Sassy-Dog/skills/issues/316): no script
reads `template-version`, and re-render is decided *solely* by the `generated-by:` ownership
matcher, so a marker-owned file is reconciled on any run regardless of its stamp and a marker-less
one is skipped regardless of its stamp. The stamp is provenance that rides along on a re-render,
never a trigger for one. **Nothing compares a consumer's committed version to the shipped one**, so
consumer drift is invisible from here — that is why a template change rolls out as one issue per
consumer repo rather than by waiting for re-runs.

Facts: `{{RUNNER}}`, `{{APP_DIR}}`, `{{PKG_DIR}}`, `{{FLUTTER_VERSION}}` (keep in lockstep with the
release workflow). `{{APP_DIR}}` is the Flutter app directory relative to the repo root — `app` for
tailoredtip, `apps/mobile` for velovate, `.` for a root-level app. It replaces the pod template's
v1 `{{PUBSPEC_PATH}}`/`{{IOS_DIR}}` facts: all three named points on the same directory, and
overlapping facts that must agree will eventually disagree — every pubspec/Podfile path now
derives from the one fact. Render rules are in the template header: a nested app substitutes the
token and deletes only the `# {{IF:NESTED_APP}}` marker comments; a root-level app deletes those
blocks wholesale and collapses each `{{APP_DIR}}/` prefix to nothing (a `./` prefix would break
the `on.paths` filter), which keeps root renders byte-identical to v1 output.

`{{PKG_DIR}}` is the same shape one template over: the **bun install root** for
`lockfile-sync-bun` — the directory holding the `package.json` + `bun.lock` that workflow syncs
(`web` for tailoredtip, `.` for qr-ninja), with the identical nested-vs-root render rule
(`# {{IF:NESTED_PKG}}`, `{{PKG_DIR}}/` collapsing to nothing at the root, so a root render stays
byte-identical to v5's `'**/package.json'` trigger). v5 assumed the root outright, which is why
tailoredtip's copy is hand-tuned: reconciling it to v5 would have pointed `bun install` at a
directory that does not exist and fired the workflow on `scripts/package.json`, which its body
cannot handle. **One rendered workflow per install root** — a repo with two independent
`bun.lock` files needs two, each owning its own lockfile.

`{{RUNNER}}` defaults to the Sassy Dog self-hosted fleet — `[self-hosted, linux, sassy-dog]`, or
`[self-hosted, macOS, sassy-dog]` for the pod template, which **must** have macOS to run
`pod install`. Both org runner groups are `visibility=all`, so every repo can reach the fleet.
Prefer those label forms over the legacy product-scoped ones (`velovate`, `qr-ninja`): the runners
still carry those labels, but scoping by product is a leftover, not a constraint.

**The lockfile trap — the single most important thing this skill exists for.** Dependabot updates a
manifest but writes only the lockfile formats it supports; CI running a frozen-lockfile install then
rejects every PR it opens. One repo in this org merged **0 of 20** npm PRs that way before deleting
the ecosystem to stop the noise. The bun half of that trap is closed by default now: Dependabot's
native `bun` ecosystem (GA 2025-02) reads and rewrites the text `bun.lock` itself (bun >= 1.1.39),
so a bun repo renders the `bun` block and no sync workflow. The npm + `lockfile-sync-bun` pairing
survives only as the legacy fallback — binary `bun.lockb` (which no ecosystem writes), or a repo
that deliberately stays on grouped npm (qr-ninja#394's workspaces-monorepo stance). One caveat keeps
that fallback relevant: bun security updates are not yet supported upstream (version updates only),
and security PRs fire on any vulnerable dependency regardless of the ecosystem list — one arriving
via the npm path edits the manifest without touching `bun.lock`, and only the sync workflow makes it
mergeable. CocoaPods is the trap in full force: Dependabot has no cocoapods ecosystem at all, so the
pod sync workflow is never optional there — without it the security PRs are dead on arrival and the
alerts stay open.

**Pod-template precondition — a tracked Podfile is necessary but not sufficient.** Render
`lockfile-sync-pod` only when the app's `ios/Podfile.lock` is itself tracked; check with
`git ls-files -- "<app-dir>/ios/Podfile.lock"` (empty output = gitignored or untracked). A repo
that gitignores the lock (tailoredtip: release builds regenerate it every run, so it is a build
artifact there, not a committed version pin) has nothing to sync — and the rendered workflow
hard-fails rather than no-ops: `flutter pub get` still changes the tracked `pubspec.lock`, so the
changed-lockfiles guard falls through to `git add` on an explicitly-ignored path, which exits 1
under `bash -e` — a red job occupying the fleet's single macOS runner on every pub PR (the
tailoredtip#252 field report). Gitignored `Podfile.lock` → **do not render**; record in the run
report why the pod workflow was skipped, so the next refresh skips it deliberately instead of
shipping a red workflow. If the repo later wants a committed pod pin (velovate's posture), tracking
the lock is the prerequisite change — the template becomes renderable the moment it lands.

## 4. Prerequisites the render assumes

- **`PLATFORM_WRITER_APP_CLIENT_ID` / `PLATFORM_WRITER_APP_PRIVATE_KEY` in the DEPENDABOT secrets store**,
  not the Actions store. Dependabot-triggered runs cannot see Actions secrets at all — this is the
  most common reason a copied workflow silently no-ops. Org-level with `private` visibility
  (= private + internal); source of truth is Doppler `_scm/github`. **That does NOT cover a public
  repo** — `private` visibility excludes public repos in both the Actions and Dependabot stores, so
  the render must not emit this workflow into one (the credentials resolve to empty strings and the
  failure surfaces weeks later on that repo's next Dependabot PR). See
  [#178](https://github.com/Sassy-Dog/skills/issues/178); a merge gate is a necessary but
  not sufficient precondition, repo visibility is the other one.
  **The CLIENT ID, not the numeric App ID** — `actions/create-github-app-token` v3.2.0 deprecated the
  `app-id:` input in favour of `client-id:` ([#316](https://github.com/Sassy-Dog/skills/issues/316)),
  and every template here mints with `client-id:`. `PLATFORM_WRITER_APP_ID` still exists in both org
  stores and is a DIFFERENT value; do not substitute it to avoid provisioning. GitHub's JWT `iss`
  claim happens to accept either, so the shortcut works and is still wrong: it puts an App ID in an
  input named `client-id` in every consumer, and the next reader believes the name.
  The value is the App's **client ID** (`Iv23…`), readable from the App settings page or
  `gh api /orgs/<org>/installations`; it already exists in both org stores at `private`. A new org
  adds it to Doppler `_scm/github` and syncs, never by hand — and note `gh api …/secrets` pages at
  30, so check with `--paginate` before concluding it is absent.
- **`allow_auto_merge`** on the repo, for the direct-merge arm.
- A **CI workflow** whose check is actually required. If `detect_failures` reports no conventional
  CI workflow, that repo needs one before auto-merge means anything.

## 5. Verify

```bash
gh api "repos/${REPO}/dependabot/alerts?state=open&per_page=100" --jq 'length'
```

After the first Dependabot run, confirm the PRs are **grouped** (one entry per (ecosystem,
directory), not one per package) and that a pod repo's PR — or a legacy npm+sync bun repo's —
carries a follow-up lockfile
commit (a native-`bun` PR edits `bun.lock` in the PR itself; no follow-up). An ungrouped flood means
a group is missing `applies-to: security-updates` — a group without it covers version updates only,
silently leaving security PRs ungrouped, and the mistake is invisible until the flood arrives.

## Guardrails

- Never render the auto-merge workflow into a repo with no required check.
- Never render **any App-token workflow** — auto-merge, bun lockfile-sync, or pod lockfile-sync —
  into a **public** repo. Their org secrets are `private`-visibility and cannot resolve there, so
  the render produces a workflow that fails late and looks unrelated. The precondition belongs to
  the credential, not to one workflow: scoping it to auto-merge left the two templates that check
  out PR head ungated (#186). For the lockfile ones, report the consequence and the manual
  regenerate-and-push path too — dropping them is not free the way dropping auto-merge was.
- Never auto-merge semver-major. A green build does not disprove an API break.
- Never widen the `dependabot[bot]` actor gate on a `pull_request_target` workflow — that gate is
  what keeps contributor code out of a write-capable context.
- Never inline `github.event.pull_request.head.ref` into a `run:` shell; funnel it through `env:`.
- Never hand the minted App token to `actions/checkout` in either lockfile-sync template, and never
  drop their `persist-credentials: false`. `checkout` defaults that to true, which writes the
  credential into `.git/config` for the rest of a job whose workspace holds PR-authored content —
  for no benefit, since only the push needs write and it authenticates from its own step `env:`
  ([#232](https://github.com/Sassy-Dog/skills/issues/232)).
- Never overwrite a `dependabot.yml` lacking this generator's marker; report it and stop.
- Never write a `dependabot.yml` that `validate-dependabot.sh` rejected, and never default a lane
  to `directory: "/"` because the location is unclear. A lane pointing at a directory with no
  manifest is the one failure here nothing else surfaces: no error, no PRs, no signal.
- Never hand-add a `cooldown:` to a rendered `dependabot.yml`, and never render one nobody asked
  for: the request is `--cooldown ECOSYSTEM=DAYS`, validated with the same flag.
- Never drop or change a committed cooldown without the user's approval of that exact change as a
  plan item, and never pass `--change-cooldown` to turn a failing run green: a forgotten
  `--cooldown` is fixed by passing the committed value.
- Never overwrite an owned file whose committed lanes a fresh render drops (`--compare-to`
  reports `DIVERGED`). Report it and stop — and do not re-stamp its marker, which only makes a
  diverged file look current.
