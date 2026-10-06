#!/usr/bin/env bash
# preflight.sh — this repo's CI gates, runnable locally. CI's `ci` job calls
# THIS script for every gate except actionlint, which CI runs as a separate step
# from a pinned native binary (ci.yml explains why it is not the dockerized
# action); this script runs actionlint too when a local binary or docker is
# available, and reports a skip when neither is.
#
# Guard regexes live here and only here. Tool VERSIONS do not: markdownlint-cli2
# is pinned below, but shellcheck is whatever is on PATH locally versus an exact
# pin in ci.yml. That gap is real and documented in CONTRIBUTING.md — a local
# pass on a different shellcheck is not proof of a green build.
#
# Run it before every PR; `--fix` lets markdownlint auto-fix first.
#
# Usage: bash scripts/preflight.sh [--fix]
#
# Gates, in CI order:
#   1. shellcheck -S warning over every tracked *.sh, PLUS a second pass for
#      SC2006 alone. SC2006 is `style`, so the first pass cannot see it, and the
#      gap shipped a real defect twice: an unescaped backtick in a double-quoted
#      test label is command substitution, and three labels in
#      test-sentry-verification.sh were executing `which`, `that` and `where`.
#   2. frontmatter sanity (scripts/check-frontmatter.sh) — two layers. LOADER
#      requirements on every tracked skill/agent file: opening `---` on line 1,
#      `name`/`description` present, `name` matching the directory (skills) or
#      filename (agents). AGENT SKILLS SPEC constraints on `SKILL.md` ONLY
#      (issue #118): `description` <= 1024 characters, `name` <= 64 characters
#      with charset and hyphen rules, and a strict frontmatter key allowlist
#      (name, description, license, compatibility, allowed-tools, metadata)
#      whose unknown keys HARD-fail, matching what `gh skill publish` rejects.
#      `agents/*.md` are deliberately exempt from the spec layer — an agent is
#      not a skill and legitimately carries `color:`.
#   3. no bare positional tokens in Skill-args substitution surfaces (issue #39)
#   4. no legacy name residue outside the per-name sanctioned back-compat
#      files, in three groups (all enforced under this one gate): the renamed
#      generator family — 'create-dev-workflows', 'refresh-sassydog-',
#      'refresh-skills', 'refresh-hooks', 'refresh-deps' (issue #120); the
#      plugin and marketplace renames — 'ai-agent-skills', 'sassy-dog-skills'
#      (issue #71); and the workflow-skill naming sweep — 'plate-it',
#      'groom-it', 'drain-it', 'clean-it'
#   5. plugin manifests are valid JSON, the plugin version is CalVer
#      (YYYY.M.P — the one-way ratchet, docs/VERSIONING.md), and any
#      marketplace.json plugins[].version equals it (issue #31)
#   6. versioning tests (scripts/test-versioning.sh)
#   7. ownership-matcher tests (scripts/test-ownership-matchers.sh) — the
#      setup-hooks / setup-deps `generated-by:` matchers, extracted from the
#      shipped SKILL.md files and run against real pre-rename consumer
#      artifacts committed under scripts/fixtures/legacy-markers/ (issue #133)
#   8. label-taxonomy tests (scripts/test-label-taxonomy.sh) — the two label
#      taxonomies stay disjoint AND perceptually separated (cross-set CIEDE2000
#      check), issue-claim.sh's label reconcile still CORRECTS a drifted label
#      instead of silently skipping it (issue #161), and there is no THIRD copy
#      of either table: every colour from both emitters is searched for across
#      the tracked tree and any hit outside its own home fails (issue #167 —
#      the cross-set check scores two taxonomies, so a copy anywhere else is
#      invisible to it). Definitions and a mock gh only: no repo, no network.
#   9. label-migrate tests (scripts/test-label-migrate.sh) — align-labels.sh's
#      relabel-then-delete migrate mode cannot delete a label whose relabel has
#      not been verified by re-query (issue #163). Mock gh only; the MODE
#      itself is never run in CI, because it mutates other repos' issues.
#  10. dependabot-render tests (scripts/test-dependabot-render.sh) — setup-deps
#      renders one lane per (ecosystem, DIRECTORY) and every lane is backed by a
#      manifest in the directory it names, against three recorded consumer
#      layouts; the collapsed-to-"/" v2 shape must be REJECTED (issue #169).
#      Recorded file lists only: no repo, no network.
#  11. detect-hook-stack tests (scripts/test-detect-hook-stack.sh) —
#      setup-hooks' has_tracked probe still answers correctly when the match
#      list is LARGE. Under pipefail a `| head -1 | grep -q .` returns the
#      writer's SIGPIPE 141 once the output outruns the ~64KB pipe buffer, so a
#      MATCH read as a miss and the render silently dropped that tool's route
#      (issue #172). Needs a 20k-path fixture, because a small one passes
#      either way; the gate fails loudly if that fixture ever stops tripping
#      the pre-fix shape. Index-only temp repos: no real repo, no network.
#  12. visibility precondition tests (scripts/test-visibility-preconditions.sh)
#      — setup-deps' App-token renders have TWO preconditions, not one: a merge
#      gate AND a non-public repo. Its org secrets are `private`-visibility,
#      which excludes public repos in both the Actions and Dependabot stores, so
#      a render into one produces a workflow whose `secrets.*` are empty and
#      which fails weeks later on that repo's next Dependabot PR, as an auth
#      error that looks unrelated (issue #178). The precondition belongs to the
#      CREDENTIAL, not to one workflow: three templates mint it, #178 gated only
#      auto-merge, and the two it missed are the two that check out PR head
#      (issue #186) — hence the rename from test-auto-merge-visibility.sh. The
#      decision is SKILL.md prose, not script, so this pins the instruction —
#      same shape as the label-migrate single-call-site guard. Must-not-exist
#      assertions run against a whitespace-flattened copy, because this repo
#      hard-wraps prose and a line-scoped grep for forbidden wording turns a
#      wrap into a false PASS. Reads two tracked files: no gh, no network.
#  13. verify-issue-refs tests (scripts/test-verify-issue-refs.sh) — the
#      grooming-drift checker. THREE of its failure modes are SILENT and none
#      changes an exit code. (a) `\b` in a git -E harvest pattern empties the
#      near-match pool, so every unresolved reference tiers `likely-new` and the
#      checker quietly stops finding drift — and that measurement is PLATFORM-
#      SPECIFIC: `\b` matches nothing on macOS (git 2.55) and matches normally
#      on the Linux git that runs this gate (2.54/musl, 2.47/glibc), so the
#      wrong spelling would be green here and broken on the machine doing the
#      grooming. (b) A suggestion ranked on raw edit distance answers the
#      shortest neighbour (`open`) instead of the actual rename (`open_in`),
#      which is worse than no suggestion because it is the line a reader acts on
#      without re-checking. (c) A pool full of the WRONG LANGUAGES (issue #263):
#      the harvest was keyword-led and POSIX shell functions carry no keyword, so
#      on a bash repo a correct `read_monitors()` drew a confident TypeScript
#      suggestion while real drift tiered `likely-new` and passed. Also pins the
#      NEGATIVE cases — a clean body and a new-subtree body must stay quiet —
#      since a checker that fires on everything is muted within a day and then
#      gates nothing at all. THREE synthetic trees now — non-shell,
#      shell-majority, and one real script beside three hostile FILENAMES —
#      because a shell-blind harvest is invisible to every case in the first,
#      and a pathspec-magic name empties the pool with nothing else to show for
#      it. Ten mutants, each proved applied before its proofs run,
#      plus source-level assertions for the three rules no Linux run can
#      observe: the `\b` spelling itself, which is green on Linux and empties
#      the KEYWORD half on macOS so CI cannot see it go wrong; the empty-array
#      test; and the process-substitution comment trap.
#      Built in a tmpdir: no gh, no network.
#  14. stale-issues tests (scripts/test-stale-issues.sh) — the
#      tracking-parent-complete detector (issue #198). An epic that splits into
#      children can never close itself: GitHub moves an issue only on a merged
#      PR's closing keyword, and a tracking parent is the issue no PR ever
#      names. All three of this detector's wrong answers are silent — a missed
#      parent is indistinguishable from a clean repo, a PREFIX COLLISION
#      (#28 claiming #283's children) tells a human to close live work, and a
#      TRUNCATED pull returns the same empty list a clean one does. The prefix
#      fixture is mutation-proved: a copy of the script whose regex has lost
#      its non-digit guard MUST report #28, or the decoy has gone vacuous.
#      Mock gh serving recorded JSON: no repo, no network, and the run is
#      asserted to issue zero non-read calls.
#  15. teardown-args tests (scripts/test-teardown-args.sh) — teardown.sh parses
#      flags anywhere in its argument list and rejects an unrecognised -* one
#      BEFORE any teardown runs (issue #200). The bug it pins reads as success:
#      `teardown.sh <p1> <p2> --sweep` tore both worktrees down, took --sweep
#      for a third path, and never swept — a tool-level usage dump buried under
#      successful teardown lines, and a skipped phase leaves nothing behind to
#      notice. Assertions read teardown's OWN output, never basename's, whose
#      BSD/GNU wording differs (that is why it surfaced on macOS only). Scratch
#      repos with a LOCAL bare origin plus a mock gh: no real repo, no network.
#  16. markdownlint (pinned markdownlint-cli2 version)
#  17. actionlint — best-effort locally (binary, else docker); SKIPPED in CI
#      (CI=true) because the workflow runs it as its own step
#  18. config-source guard — every `!` block that inlines a repo's
#      .claude/sassy-dog/<skill>.md MUST also echo CONFIG_SOURCE. Same
#      source-level class as gates 3 and 4. The block resolves against the
#      SESSION's cwd, not the repo being acted on, and cwd resets between Bash
#      calls — so a sub-agent working in another repo is silently handed the
#      session repo's config. That is only wrong when the session repo IS
#      configured: NO_CONFIG already fails honestly, but a populated config from
#      the wrong repo is indistinguishable from the right one (2026-08-18 — two
#      agents were each handed platform's Terraform gates). Announcing the path
#      is what makes the mismatch visible. The check is LINE-scoped on purpose:
#      the reconciliation prose in each §1 also says CONFIG_SOURCE, so a
#      file-scoped grep would pass a block that had lost it.
#  19. scanning-states tests (scripts/test-scanning-states.sh) — the code- and
#      secret-scanning pulls' four silent failure modes: the 404 that means
#      BOTH "Advanced Security off" and "never analyzed" (collapsing them
#      reports a never-scanned repo as clean), the un-paginated read that
#      returns a capped 100 as if it were a measurement (live: velovate, true
#      count 102), a PR-ref alert counted as default-branch debt, and the
#      validity:"active" P0 rule acquiring an age gate. Mock gh only.
#  20. sentry-verification tests (scripts/test-sentry-verification.sh) —
#      setup-config may only write a `sentry:` block for a project VERIFIED by
#      culprit against this repo's own code, and records a failed verification
#      as `sentry: none` (issue #213). Name similarity is the evidence an agent
#      reaches for first and it is wrong invisibly: the wrong repo claims
#      another codebase's P0s while BOTH plates still render complete. Also pins
#      `sentry: none` as the config contract's first documented exception to
#      "presence is the toggle" — prose a later consistency sweep reads as drift
#      and deletes — and keeps the sibling prior-claim scan SECONDARY, since a
#      cloud session has no sibling checkouts and would lose the guard silently.
#      The `none` form now spans FOUR keys and is deliberately ASYMMETRIC across
#      them (issue #261): `sentry: none` keeps its blind-spot row, while
#      `testflight`/`posthog`/`mobile: none` take one `(n/a)` token on the clean
#      line and no row. A four-key form with one key behaving differently reads
#      as a plain inconsistency, so a tidying sweep breaks it in either
#      direction and both are silent — collapsing sentry onto the clean line
#      restores #213's gap, promoting the other three restores #261, where an
#      infra repo carried three permanently unclearable rows on every plate and
#      trained its reader to skim the heading a dark Sentry lives under. The
#      four-key table is checked by COUNTING rows, not by looking the four names
#      up: a lookup passes just as happily on a table that grew a fifth key.
#      Its own assertions have been the hard part: every review round so far has
#      found some of them passing on sources stating the inverse, and the
#      author's mutation set kept reporting "all detected" because every mutation
#      deleted the exact literal its assertion grepped for — tautologically
#      caught. The lesson generalises to every prose gate here: mutate the
#      MEANING, worded as a tidying editor would word it. Re-measured that way,
#      the mutually-exclusive-vocabularies rule still governs the PROSE — each
#      rule must speak exactly one outcome's vocabulary — but it is NOT
#      sufficient on its own, and that distinction is the one a later reader will
#      collapse. What cannot be enumerated is how negation is PHRASED ("never
#      given", "is exempt from", "no longer keeps", "aligned with the other
#      three"): an open semantic class English extends faster than any list
#      absorbs it, which is what the six-verb affirmative kept losing to. What
#      the classifier enumerates instead is NEGATORS — a closed grammatical core
#      (no, not, never, neither, nor, without, nothing) plus a deliberately short
#      set of lexical ones this repo's prose actually uses (exempt, excluded,
#      omitted, instead, rather). Only the first is truly closed; the second is
#      the part that can drift, so it stays short and each addition must be
#      justified by prose in the tree. Neither substitutes for POLARITY, which is
#      what handles composition ("not exempt") that a list of any length cannot.
#      All three of its scans stop at ONE shared clause boundary (issue #270),
#      and since #271 that boundary is their only BOUND as well. Two checked it
#      and `cancelled` did not, which reads as deliberate and was not: a negator
#      in a PREVIOUS clause cancelled a real negation, so the sentence read
#      AFFIRMED and could satisfy the very must-affirm veto meant to catch it.
#      The count bound all three carried is gone — four content words in the two
#      look-around scans, four POSITIONS in the cancellation scan, a real
#      difference and not a wording slip — because the unit was wrong in both
#      directions at once and no value of it works: too short let a
#      qualifier-heavy negator escape and read AFFIRMED, too long reached
#      negators in OTHER clauses, and raising it from four to six reddened the
#      PRE-#271 gate (no count of reddened assertions is quoted anywhere, and
#      after merge there is no bound left to raise — the live proof is that
#      restoring a count bound to any one scan reddens that scan's own case).
#      Dropping the counts is what made the three dead dash arms have to work,
#      an unfired boundary now costing the whole previous clause rather than a
#      word of window; it is what dissolved the `:` arm cost PR #272 accepted,
#      by giving the cancellation scan the parenthetical skip the left-context
#      one always had; and it removed three guards the distance had been
#      supplying by accident, every one of them failing QUIETLY. A skip region
#      now honours `hard_break`, the subset of the boundary set an aside cannot
#      contain (`.` and `;`), written as an expression of `clause_break` rather
#      than beside it and asserted at SOURCE level, since nothing behavioural
#      can tell a shared subset from two matching transcriptions. The
#      comma-bearing token is tested before it opens a skip, an odd comma having
#      otherwise consumed the negator itself — wrong on the pre-#271 source too.
#      And `post_negated` performs the same polarity flip `governed` does,
#      stops at a RELATIVIZER — and that class SPLITS: a possessive (`whose`),
#      locative (`where`) or temporal (`when`) names a new subject in its own
#      right and stops unconditionally, while the subject relatives
#      (`which|that|who|whom`) carry the antecedent forward and are exempt when
#      one heads the destination directly. A single whole-class exemption is
#      wrong exactly where a restrictive relative is most natural, immediately
#      after the destination, and each member that can fire has its own case;
#      the split was mis-drawn twice before it was right, so sort members by
#      what they DO and not by how the rule reads. It also
#      counts a participle only once a PASSIVE AUXILIARY or COPULAR verb has
#      re-attached it. That set is TWO-TIER, on the split the negator set
#      already uses: tier 1 is the two closed passive paradigms (`be` and the
#      get-passive), enumerated on the terminating argument; tier 2 is copular
#      and aspectual verbs, admitted only on the file's other rule — a lexical
#      addition justified by prose in the tree — with the wider copular class
#      (`seem|appear|look|…`) stated as a known limit rather than enumerated.
#      Every member carries its own case and NO COUNT IS WRITTEN DOWN: the set
#      has changed size twice under review and the prose stating its old size
#      survived both times. Trimming is the unsafe direction — removing any
#      member flips its own ordinary sentence to AFFIRMED, quietly — since
#      with no ceiling it otherwise fired on any participle in its clause and
#      read the #261 rule and its inverse alike. A PREPOSITION is deliberately
#      not a stop there, and a case pins why: it is the copula after it that
#      decides. The gate has a SECOND AXIS besides which verbs count: a
#      participle with NO auxiliary. A comma- or dash-set-off APPOSITIVE is
#      predicated of the destination and is admitted, but only when it opens
#      immediately after it — that position is the whole of what separates it
#      from a reduced relative modifying the nearer noun, and a looser rule
#      re-opens what the copula gate closes. `clause_break` also gained the two separators this repo's own
#      prose writes, the rule arrow and the markdown cell wall `|`; without them
#      the scan crosses live tracked text in two of the eight files, and since
#      neither drift reddens anything both arms are pinned by fixed strings
#      alone. The negator sets are factored core-and-full, the full one an
#      expression of the core, because a comma-bearing token is tested against
#      the CORE only — an adverb scopes over what follows it, a participle
#      predicates on the subject to its left. ONE limit is STATED rather than
#      fixed, in a known-limit block, and it has two faces: comma parity is a
#      guess, so a comma-joined subordinate clause is unbounded and a third
#      comma inverts the aside pairing. The block also records the fix that does
#      NOT work, measured — subordinators in `clause_break` change neither
#      string, the subordinator sitting left of the negator where a backward
#      scan meets the negator first. `hard_break` bounds both at the nearest
#      sentence, which is why it is a limit and not a hole. No count beyond that
#      is written down: two copies of this paragraph once disagreed about one,
#      which is the failure this gate refuses everywhere else. The
#      classifier carries a battery of its own — fixed strings, both directions,
#      every arm of the boundary set and every scan's bound and guard proved
#      load-bearing by a mutation — because until then its behaviour lived only
#      in comments, and a comment does not redden.
#      Windows need structural bounds rather than byte
#      counts; a veto over a rule that STATES a negative must require the
#      negation, since silence satisfies "nothing affirmed"; and every table row
#      must be classified rather than tallied. Source-level, must-not-exist
#      checks run on flattened and emphasis-stripped copies. The run prints its
#      own assertion count. No gh, no network: eight tracked files.
#  21. sentry-counts tests (scripts/test-sentry-counts.sh) — sentry-triage may
#      only gate on counts it CONFIRMED as lifetime (issue #218). `count`/
#      `userCount` mean different things per transport under identical labels:
#      REST is lifetime, the MCP's search_issues rescales to its `period`, and
#      neither says which it returned — velovate's VELOVATE-WORKERS-2 came back
#      1/1 against a true 30/3, and a 30d pull returned 1 event too, so a wider
#      window is not the fix. It went unnoticed because the REST-based routine
#      under daily review was accidentally CORRECT while the interactive run
#      called the surface clean. Pins the discovery/scoring split, the confirm
#      step's position BEFORE the gate, the ban on choosing what to confirm by
#      windowed count (which reads as a missing optimization and re-creates the
#      bug one step earlier), and both halves of `skip-unconfirmed` — never
#      qualifies, always reported. Source-level, flattened must-not-exist
#      checks. No gh, no network, no Sentry call: four tracked files.
#  22. security-listing tests (scripts/test-security-listing.sh) — a
#      security-labelled issue is never collapsed into a bare count (issue
#      #219). The label map used to reach security only via (`bug` AND
#      `security`), so visibility depended on whether the issue happened to be
#      phrased as a defect — and most security work is not (hardening, a
#      missing control, a policy decision). On velovate, two security issues
#      filed the same day at the same severity split P1/P2 on one label, and
#      the P2 one — 72 CodeQL alerts, 10 sites logging raw rider coordinates on
#      a live product — was invisible in every daily-fire-watch post since it
#      was filed. The fix is a LISTING rule, not a promotion, and that is the
#      fragile part: #219 itself proposed promoting security to P1, so a reader
#      arrives pre-loaded with the rejected option, and promotion would
#      re-derive a priority the same file forbids re-deriving. The gate pins
#      the tier-untouched wording, the `unranked` case, and the survival of the
#      re-derive principle itself. Source-level, flattened must-not-exist
#      checks; no gh, no network: two tracked files.
#  23. artifact-guard tests (scripts/test-artifact-guard.sh) — setup-hooks'
#      stray-artifact guard, whose failure mode is SILENCE: every degraded
#      input is deliberately fail-open, so a guard that has stopped firing is
#      indistinguishable from a clean repo and the artifacts quietly resume
#      piling up in the root. Pins the loud cases (exit 2 naming the file; the
#      Stop block JSON) as hard as the quiet ones, all three path-parameter
#      spellings, the deliberate .svg exclusion, and the `stop_hook_active`
#      recursion guard — the one regression that would wedge a session rather
#      than merely miss a file. Caught a real symlink bug on its first run
#      (physical vs logical repo root). Scratch git repos and empty files: no
#      gh, no network, no binaries.
#  24. doc-reconciliation tests (scripts/test-doc-reconciliation.sh) — all
#      THREE shipping paths must tell the agent to fix docs its change made
#      untrue, before the PR body is drafted (issue #220). Docs are an input
#      to no other gate, so lint, type, test and the review agent all pass on
#      a PR whose CLAUDE.md now says the opposite of what the repo does. This
#      gates the INSTRUCTION, never staleness itself: #220 rules that out,
#      because staleness is a semantic judgement with nothing to grep for and
#      a script pretending otherwise reproduces the skimmed-past output of
#      #199. take-it and dispatch-ready matter most — they dispatch sub-agents
#      that open PRs from a cold worktree and never see an interactive
#      session's CLAUDE.md, so a rule living only in send-it never runs for
#      them. Pins both traps in both directions (a closed issue does not prove
#      the behaviour landed; an OPEN one does not prove it did not) and the
#      scope limiter, since an unbounded doc step is one nobody runs.
#      Source-level; its flatten strips blockquote markers, because take-it's
#      rule lives inside a `>` prompt template where a wrap otherwise reads as
#      a missing phrase. Three tracked files, no gh, no network.
#  25. poll-queue-eject tests (scripts/test-poll-queue-eject.sh) — poll-queue.sh
#      may only call `ejected` on evidence it actually has (issue #234). #60's
#      race guard anticipates the PR-STATE flip lagging the queue-entry
#      removal; the removal EVENT lags too, and an empty timeline does not
#      distinguish "never enqueued" from "not visible yet". A tick landing in
#      that window reported qr-ninja#847 — merged cleanly the same second — as
#      EJECTED, wrong in both directions at once: a loud verdict pointing a
#      human at eject recovery, and a silent `"result":"ejected"` in the final
#      JSON that a coordinator branches on. The disproof was already in the
#      script (QSTATES, printed in the failing line). The lag case is now
#      non-terminal, bounded ONLY by the global POLL_MAX_TICKS/exit 124
#      ceiling — no per-PR counter, whose fall-through verdict would re-create
#      the same false eject — so the gate asserts the run reaches that ceiling
#      rather than resolving early, and pins the two cases that must stay
#      terminal (a real eject, a PR that never enqueued) so the fix cannot
#      swallow them. Its prose checks are flattened, both call sites being
#      hard-wrapped. Mock gh serving recorded payloads: no repo, no network.
#  26. template-actionlint tests (scripts/test-template-actionlint.sh) — the
#      three setup-deps WORKFLOW templates are linted by actionlint, in a
#      RENDER (issue #245). Bare actionlint lints real `.github/workflows/*`,
#      not the templates, so the highest-consequence YAML in the
#      repo — `pull_request_target`, a minted PLATFORM_WRITER_APP_* token, a
#      push to a PR head ref — was checked by nothing, and a defect there
#      never reddens this repo: it ships to consumers, where Dependabot
#      answers a broken workflow by silently doing nothing. The templates
#      cannot be linted directly (render-time `# {{IF:FLAG}}` blocks and
#      `{{TOKEN}}` substitutions parse as errors that are not defects), so the
#      gate renders each one in every documented shape first — the manual step
#      #232's agent performed by hand. `sassy-dog` is DECLARED to actionlint
#      as a self-hosted label rather than muted with -ignore, so every other
#      unknown label still fails. Four vacuous-green guards (an uncovered
#      template, an IF-arm that is OFF in every variant, a leftover token, and
#      a missing actionlint under CI) plus three mutations. SKIPPED here under
#      CI=true — ci.yml runs it as its own step, after the pinned actionlint
#      install, because $GITHUB_PATH reaches only LATER steps and preflight
#      runs before it. Renders into a tmpdir: no repo, no network.
#  27. review-orchestrator allowlist tests
#      (scripts/test-review-orchestrator-allowlist.sh) — the orchestrator may
#      only dispatch agents this plugin actually ships, and the defect is
#      invisible to the author who ships it: `react-typescript-engineer` and
#      `iac-cloud-architect` exist as USER-LEVEL agents on a typical
#      developer's machine, so a dispatch (or a `review_surfaces:` example)
#      naming one passes every other gate, works when its author tests it, and
#      fails only in a consumer repo. A file-listing comparison against
#      `agents/`, in the shape of gate 8's no-third-copy guard. No gh, no
#      network.
#  28. gotcha-claims tests (scripts/test-gotcha-claims.sh) — a `gotcha_summary`
#      claim about issue state may not reach an issue body unless it has been
#      CONFIRMED against that issue (issue #249). The field is prose in a
#      frontmatter slot, so it is neither derived nor in the `##` lane a human
#      curates: nothing revisits it, and groom-backlog copies it verbatim to a
#      cold worktree agent with no way to check it. solador's asserted three
#      issues were open for nine days after all three closed. The load-bearing
#      case is the KNOWN-STALE fixture — a verifier that accepts everything
#      passes every clean config, so only a config the mock gh contradicts
#      distinguishes one that works — and the second is DEGRADATION: no gh, no
#      repo, a failed lookup must still drop, because a skip here is a silent
#      pass on exactly the input the gate exists for. Its no-gh PATH is a
#      symlink sandbox rather than /usr/bin:/bin, which on a GitHub-hosted
#      runner would quietly mean "gh present". The THIRD failure mode is
#      upstream of the classifier (issue #262): the sentence splitter could not
#      see backticks, so the `;` in `code=0; cmd || code=$?` cut a claim
#      mid-span and the truncated HEAD — citing no #N — was certified an
#      invariant into the SAFE block a caller copies verbatim. Spans are now
#      paired by backtick RUN (a ``…`` delimiter otherwise pairs with itself,
#      leaving the body exposed), and an unpaired run quarantines the WHOLE
#      field, because greedy pairing can mis-bind BEFORE the stray tick. But
#      the guard that BOUNDS the family is GROUP LINKAGE: three narrower fixes
#      each decided where the cut lands and each had a next input, so the
#      fragments of a sentence are now tagged, resolved individually and
#      COMMITTED TOGETHER — a mis-parse costs a drop, never a half-sentence
#      certified. Parity and a padded-span heuristic were both tried and both
#      deleted (the header records why). The root case carries no backtick at
#      all: `;` matched the boundary regex, so a clause dropped and the
#      survivors were welded into an inverted sentence. Seven mutations
#      (neuter the state comparison; treat unresolvable as open; remove group
#      linkage; unmask the span body; pair tick-wise; drop the unpaired
#      quarantine; break the splitter), plus a coverage MATRIX that measures
#      which rule is each fixture's sole protection and fails when that moves,
#      so narrow mutation scoping cannot rot into proving nothing. The
#      sentence-start default is INVERTED (a split needs positive evidence),
#      whose accepted cost is over-linking: a neighbour can be dropped for a
#      citation that is not its own. The class is bounded, not closed —
#      anaphora is out of scope,
#      each reproducing a real fabrication rather than perturbing output; a
#      source guard bans any skip exit; three prose gates pin the contract
#      rule, the injection step, and the template slot — flattened, this repo
#      hard-wraps. Mock gh: no repo, no network.
#  29. review-gate decision tests (scripts/test-review-gate-decisions.sh) — the
#      seven decisions settled about the review gate, all prose and every one of
#      them reading like drift to an "align with the governing principle" sweep
#      (three from #237, issue #247; two from #248, issue #255; one from #273;
#      one from #280).
#      (a) The gate is UNCONDITIONAL: an absent
#      `review_agent:` resolves the shipped `sassy-dog:pr-review-orchestrator`,
#      and #235's verbatim `review: SKIPPED` line survives that default as the
#      backstop for *resolution* failure — deleting it as unreachable restores
#      the original silent-no-review bug wearing a default, since a run that
#      printed nothing is indistinguishable from one that reviewed cleanly.
#      (b) `review_agent` is deliberately NOT presence-is-the-toggle — it has a
#      default, so it was moved OUT of that key list while `review_surfaces` (no
#      default) was moved IN, and "restoring" it turns the absent key back into
#      an off switch for every consumer repo at once. (c) The opt-out is
#      `review_agent: skip`, not `none`: `none` belongs to the `sentry: none`
#      exception, which records an absence somebody went and CHECKED for, and
#      that justification does not apply to a key that merely overrides a
#      default — the missing symmetry is precisely what a tidying sweep closes.
#      (d) `review_site` is CONFIGURED, not derived, deliberately: visibility IS
#      derivable, so a literal reading of "configure only what cannot be
#      derived" deletes the key — and deriving it live means a visibility change
#      silently rewrites a repo's review architecture, downgrading pre-PR review
#      to after-the-fact review with no diff, prompt or output line (the #187
#      failure class). `setup-config` seeds it once and records the value, and
#      the Phase 4 carve-out exempting it from update mode's re-verify-every-
#      fact rule — the half that survives a REFRESH, and the half that lives in
#      another file — is pinned scoped to that phase. (e) A Blocking finding
#      blocks the merge with exactly ONE redispatch, then `blocked`; never
#      merged past, never parked back in Ready. The rationale for the number is
#      pinned with it, since "one" alone reads as an arbitrary retry count.
#      #385 extends that SAME automatic allowance to parent fallback; #386
#      spends it on at most one same-agent report-only request when returned
#      text is incomplete, with durable recovery_used accounting across
#      agents/heads/ticks.
#      (f) A review report is DELIVERED as the reviewing agent's final text —
#      its return value — and the message tool is not a delivery mechanism for
#      one, since sending needs an address the reviewer cannot reliably resolve:
#      on 2026-08-25, five occurrences across three issues and not one reaching
#      the session that dispatched it — three landed in a coordinator's session,
#      one round lost 2 of 5 dispatches that never returned, and one was
#      addressed to an agent TYPE rather than an address (#273). The dispatching
#      side is pinned in all three shipping paths, because a rule living only in
#      send-it never runs for take-it or dispatch-ready: no path may block, poll
#      or idle while a review it dispatched is outstanding — an implementing
#      agent deadlocked on a report already delivered elsewhere and lost a
#      completed review cycle — and a dispatch that SUCCEEDED whose report never
#      arrived is a THIRD outcome with its own verbatim `review: NO REPORT`
#      line, never #235's SKIPPED line, which says no agent ran at all. THREE
#      parts, pinned separately: RETURNED, never BLOCKED on, and the PR HELD
#      rather than merged. The return-value rule alone still permits a
#      dispatcher that waits forever, and the first two together still permit
#      merging the PR whose review reached nobody — which is the harm itself,
#      so the hold is pinned in both dispatching paths and on the
#      `review_site: agent` site, not only inside the coordinator-only sections.
#      #385 keeps normal nested fan-out as default and binds parent recovery to
#      the shipped orchestrator and its actual caller, not a new review site.
#      #386 accepts normal and compact-clean reports without recovery, but
#      correction/tally/partial text is NO REPORT until the same returned agent
#      uses the actual dispatch handle to return its already-completed full
#      report once. Changed input, an unreachable handle, a spent allowance or
#      another fragment stays NO REPORT; no re-analysis/fan-out is authorized.
#      Existing decision 5/6 checks cover the cold and coordinator invocation
#      regions, complete identity/provenance, missing-only dispatch,
#      report-only and aggregate-only boundaries. Control-only or incomplete
#      fallback stays NO REPORT, while send-it keeps its operator-facing
#      continuation policy.
#      These are source-contract checks, not proof that an agent obeyed them;
#      runtime review scenarios remain a separate validation responsibility.
#      (g) The reviewer -> orchestrator hop is bound the SAME way, and the
#      fan-out brief has a slot for it (#280). That hop carries the most
#      traffic — every diff-scoped review fans out to as many as nine — and it
#      was UNBINDABLE, not merely unbound: the brief said it "contains, and
#      contains only" an enumerated set with no delivery rule in it, so an
#      orchestrator following it literally could not pass the contract down,
#      while the nine carried only `Return ONLY a list of findings` — the right
#      verb, never stated to be the only one. Each of the nine now states the
#      full rule, `Return ONLY` is STRENGTHENED rather than swapped, and the
#      delivery rule joins the brief as a MEMBER: the list stays closed,
#      because closedness is what stops a brief re-authoring a reviewer's
#      checklist. The lost-reviewer REPORTING bullet survives unchanged and is
#      pinned as its own bullet — it is the backstop that made this visible on
#      #273's own PR, where round 4 lost three of four surfaces, two of them
#      carrying Blocking findings, and folding the two rules together is the
#      specific tidy #280 refuses. The nine are spelled out and then checked
#      against the tree, so a tenth reviewer cannot ship pinned by nothing —
#      and checked again against the agents the ORCHESTRATOR DISPATCHES,
#      harvested by whether `agents/<name>.md` resolves rather than by name
#      shape (the bare unprefixed form is legal, and `performance-review`
#      matches no `*-reviewer` glob). That verdict is an EQUALITY, which is
#      its vacuity floor: a membership test cannot tell nothing-to-report
#      from nothing-measured, and a neutered harvest was measured printing
#      `ok` with a real tenth target present.
#      Three scoping decisions are load-bearing, each measured: the nine copies
#      are bounded by a CANONICAL LITERAL held in the gate rather than by the
#      phrases named (deleting the paragraph's last sentence from one reviewer
#      left the gate green) — comparing the nine to EACH OTHER was tried first
#      and bounds divergence rather than content, since a uniform edit across
#      all nine stays identical and passes, so each copy is compared against
#      text held outside the files under test, as decision 6 does for the
#      NO REPORT line;
#      each reviewer's assertions are cut to its `## Output` section, the
#      MODE-AGNOSTIC contract, since a whole-file window let the paragraph be
#      relocated into the conditional `## Diff-scoped mode` section — retiring
#      it for every audit-mode run — with the gate still green; and the two
#      TOKEN COUNTS are scoped DIFFERENTLY on purpose, which is the asymmetry a
#      later tidy will collapse. `SendMessage` counts FILE-WIDE, as the
#      orchestrator's own probe does, because a fallback readmitting it is
#      written a section up rather than inside the sentence forbidding it
#      (measured: a bullet in `## Diff-scoped mode` exited 0 when both tokens
#      were paragraph-scoped). `relay` counts over `## Output` PLUS
#      `## Diff-scoped mode` — the two sections a reviewer reads as binding —
#      because it
#      is the one token that could legitimately appear as domain vocabulary (a
#      collector relaying traces, a webhook relay) and a file-wide bound would
#      redden CI on such a calibration bullet, which lives under
#      `## Sassy Dog calibration`, outside BOTH sections. Counting is not a
#      sufficient bound either way: decision 6's known limit governs this hop
#      too, and the CANONICAL LITERAL is what bounds the paragraph.
#      Source-level like gates 12, 20, 21, 22 and 24; its must-not-exist checks
#      run flattened (proved: the same forbidden wording, hard-wrapped between
#      `codegen` and `review_agent`, is invisible to a line-scoped grep and
#      caught by the flattened one), the flatten also stripping blockquote
#      markers because take-it's step-6 rule lives inside a `>` prompt template,
#      and it uses no `| grep -q` pipeline, whose SIGPIPE-plus-pipefail 141
#      reports a caught mutation as a miss (#172). Its own two summary counts —
#      the decision count and the tracked-file count — are RE-DERIVED by the
#      gate rather than transcribed (issue #276), because they were restated in
#      several places and recomputed by nothing. The decisions are counted
#      twice, from the header's enumerated list and from the body banners that
#      carry a `(decision N)` suffix, and the two must agree: a bare count of
#      numbered banners answers a different question (it runs past the
#      decisions into the trailing sweeps) and a discriminator that silently
#      matches nothing re-derives 0 and would pass every count vacuously. The
#      file count is the length of the array the existence loop iterates. A
#      stale restatement in the gate's header, in this list or in CLAUDE.md
#      fails the gate — in the SPELLED forms those sites use; a digit form is a
#      stated blind spot, as it is for the free-floating-count probe in
#      scripts/test-sentry-verification.sh. Its count-re-derivation section
#      carries its own mutation battery in the PR that added it. Every decision here is
#      mutation-proved, each battery living in the PR that added it rather than
#      as a total transcribed here to go stale. Twenty-one tracked files plus a
#      tracked-source sweep for a fourth site, no gh, no network.
#  30. pipefail-grep guard (scripts/test-pipefail-grep.sh) — no script under
#      `pipefail` may feed an UNBOUNDED writer into `grep -q` (issue #256,
#      generalising #172). grep -q closes the pipe on its first match, the
#      writer takes SIGPIPE, pipefail promotes the 141 — so the pipeline reports
#      failure precisely WHEN IT MATCHED, but only once the output outruns the
#      ~64KB pipe buffer. Nothing generalised #172: gate 11 pins one function by
#      name, and the shape recurred in PR #252, where a `scan … | grep -q` made
#      three of that gate's four mutation proofs report `undetected`. The RULE
#      is deliberately narrow and must not be "simplified": flag every pipeline
#      into `grep -q` whose SOURCE stage is not `printf` or `echo` — purely
#      syntactic, ~12 sites on the tree it landed on, all fixed in that PR. Both
#      wider options were rejected on #256 (a per-site opt-out marker: ~128
#      annotations that degrade into paste; a blanket ban: a ~131-line rewrite
#      of the scripts this repo relies on to catch its own regressions). Its
#      known limitation is stated in its own header: a huge variable through
#      `printf` slips past, because no syntactic check knows a variable's size.
#      The linter does NOT cover this — verified against shellcheck 0.11.0,
#      which says nothing about the shape and whose SC2143 actively RECOMMENDS
#      `grep -q`.
#      Exemptions are a central table in the guard keyed by (file, substring),
#      never an inline marker, and a stale one FAILS; there is exactly one, the
#      pre-#172 shape gate 11 transcribes verbatim. Fixtures are tracked under
#      scripts/fixtures/pipefail-grep/ and deliberately not `*.sh`, because the
#      guard is in its own scan scope and a printf-built fixture makes it flag
#      itself (measured — the first draft did). No gh, no network.
#  31. claim-lifecycle tests (scripts/test-claim-lifecycle.sh) — issue-claim.sh
#      writes a claim as TWO things (assignee @me + in-progress, one edit) and
#      clears it as ONE (in-progress), and `promote` may only clear the half
#      that is residue BY CONSTRUCTION (issue #281). On a CLOSED issue the
#      leftover assignee is correct — it records who shipped it — so the defect
#      is reachable only on REOPEN, where dispatch-ready §4 skips on "assignee
#      set OR label state" (a disjunction) while §3 defines in-flight as
#      assignee AND label (a conjunction): a reopened, re-promoted issue lands
#      in ready[] still assigned and is skipped as "another session got it",
#      which is false, silent, and never dispatches. BOTH obvious fixes were
#      rejected on #281 and are pinned here as NEGATIVES, because each is what a
#      later "make this symmetric" sweep reaches for: making `release` clear the
#      assignee destroys the who-shipped-it record on every closed issue, and
#      aligning §4's disjunction to §3's conjunction discards the guard for a
#      human who self-assigned without setting in-progress — so this gate never
#      reads dispatch-ready/SKILL.md and nothing in it licenses that edit.
#      THE PREMISE IS ASSERTED, NOT ASSUMED: "@me AND no in-progress -> residue"
#      holds only because `claim` writes both halves together, so a `claim` that
#      split them would turn the discriminator into a guess with every promote
#      case still green — the pairing is therefore pinned on its own. Every
#      assertion about the guard's BEHAVIOUR is behavioural, against a mock gh
#      that records writes, since a source-level grep for the guard's wording is
#      satisfied by a guard that no longer runs, and the harm being prevented is
#      a WRITE; exactly ONE check is source-level and it reads SKILL.md rather
#      than the guard, cut at the `promote` bullet. THE PROBE'S TRANSPORT is its
#      own failure mode: TAB is IFS whitespace, so `@tsv` through `read`
#      collapses the leading empty field and an unassigned issue reads its own
#      LABELS as its assignees. With `state` as a third field the broken idiom
#      shifts EVERY unassigned shape, but it was invisible in the two-field
#      draft this replaced, where an unassigned issue with NO labels was the one
#      shape it read correctly — which is exactly how that draft's fixture
#      missed it. The gate now carries an unassigned-WITH-labels fixture and
#      proves adequacy by RUNNING the pre-fix idiom against the fixture store
#      itself (the #263 posture; gate 11 does the same for its own fixture). The mutant
#      inventory is an ARRAY whose length the run prints and whose every member
#      it asserts ran, so no count here can go stale (#276); each is applied by
#      exact whole-line awk match that fails unless it hit exactly once (the
#      #262 lesson: `cmp -s` exits 2 on a missing file, which an `if` reads as
#      "differs"), and each is caught by the edit it causes rather than by a
#      literal an assertion greps for. THE STATED LIMIT IS NOW CLOSED (#287):
#      `@me` is the operator's login, not a loop identity, so the operator's own
#      self-assignment was byte-identical to the residue and `promote` stripped
#      it — dispatching a cold agent onto work a human was already doing. The
#      FOURTH conjunct is the in-progress LABELLING, not the closing-PR or
#      reopen evidence #281 named: both of those miss claim -> block -> promote,
#      which leaves the same residue with no close and no reopen anywhere in its
#      history. `claim` writes label and assignee in ONE edit, so a real claim
#      always leaves a LabeledEvent beside its AssignedEvent. The two are NOT
#      simultaneous — measured one second apart, label first — so the test
#      carries a grace window, and a fixture with identical timestamps would let
#      a rule pass that real residue defeats. What remains stated rather than
#      closed is a human who self-assigns and then adds `in-progress` by hand.
#      A CLOSED issue is refused in the gate's own body, not left to the caller.
#      IT PINS A SECOND DECISION (issue #288): the `not found` tolerance may
#      only swallow a failure that IS a removal. #281 scoped it to the
#      subcommands carrying a `--remove-label`, which fixed `promote` and left
#      the other half standing — gh's error names one label and says nothing
#      about which FLAG it came from, so `claim` and `block`, which carry an
#      `--add-label` too, went on reporting `ok` for an edit that wrote NOTHING:
#      no assignee, no `in-progress`, `ready` never stripped, and dispatch-ready
#      handing the same issue to a second cold agent on its next tick — the
#      double-pick the claim guard exists to prevent, reached through the
#      silent-success path. The match is keyed on each subcommand's OWN removal
#      tokens now, and BOTH halves are pinned because either alone is wrong: the
#      strict cases are satisfied by deleting the tolerance outright, the
#      tolerated-edge cases by never scoping it, and `block` appears twice in
#      the gate's tolerated-edge table (not in the removals table, where it is
#      one row with two tokens), being the only subcommand with two removals.
#      Every tolerated-edge case asserts the failure it relies on was actually
#      injected, since the mock errors only for a label the invocation NAMES —
#      without which a row certifies its own premise and an edit arm that
#      stopped passing that removal keeps the gate green. The `--remove-label`
#      flags stay SPELLED OUT in each edit arm rather than derived from that
#      table: gate 32 reads the `block)` arm's own text for one of its three
#      cross-file premises and asserts it by literal, so deriving them REDDENS
#      gate 32 rather than blinding it — the duplication stays because removing
#      it means repointing another gate's window at this table, which belongs to
#      whoever owns that gate and is not measured here. gh's wording is
#      measured too (2.98.0): `'<label>' not found`, identical for an add and
#      for a removal — so the token is matched QUOTED (the message embeds the
#      issue URL, where a bare `ready` is satisfied by an owner named `already`,
#      which is what the mock repo is called). Which token gh names when BOTH
#      sides are unresolvable is a scheduling race rather than a rule, and
#      nothing here relies on it. THE #288 RESIDUE IS CLOSED (#323). That
#      residue was `claim`/`block` reporting a silent `ok` on an edit whose
#      removal had been abandoned; the premise it rested on — "an edit that
#      failed on the removal token wrote nothing either" — was wrong. #288
#      measured the case where BOTH sides are
#      unresolvable, where gh refuses before mutating. With ONE bad token
#      (gh 2.100.0, 2026-09-04, live repo) adds and removes are INDEPENDENT, so
#      the removal is abandoned while the adds land — `block` added `blocked`,
#      kept `ready`, and reported `ok`. The script now re-issues the edit
#      without the named token, LOOPING bounded by the removal count because gh
#      names only ONE token per error and `block` carries two: a single pass
#      regressed a repo carrying NEITHER of block's labels to `failed` + exit 2
#      with the mandatory `--comment` never posted. #288's acceptance still
#      holds — the removal edge stays tolerated for all four, and
#      `release`/`demote` still write no label edit.
#      It also pins the `detail` field's TWO claims and their precedence
#      (#323): `requested:` names what the edit ASKED to remove and appears on
#      the ordinary path of all four removing subcommands; `removed:` reads the
#      issue's live labels on the REPAIR path and replaces it there — EXCEPT
#      the `unknown` variant, which rides ALONGSIDE `requested:` because a
#      non-answer must not suppress a computable fact. An empty list is printed
#      deliberately, being what makes a no-op strip visible. `unknown` has
#      exactly TWO triggers, a failed read and a multi-line one; stderr on a
#      SUCCESSFUL read is PREVENTED rather than reported, because gh-retry.sh
#      merges the streams and the probe therefore reads bare gh.
#      No taxonomy colour is transcribed —
#      the mock's label store is seeded from the `taxonomy` emitter, gate 8's
#      no-third-copy rule. Mock gh only: no repo, no network.
#  32. drain terminal-state tests (scripts/test-drain-terminal-states.sh) —
#      `dispatch-ready` §7's terminal states must COVER the state where
#      Ready is empty, in-flight is zero, and an open unmerged PR sits there
#      that this loop is not permitted to advance (issue #282). They did not:
#      COMPLETE is vetoed by the open PR and STALLED required Ready non-empty,
#      so neither branch was reachable and the loop ticked forever — accurately
#      reporting the state and doing nothing, unable to self-cancel. The stall
#      record could not help, being written only INSIDE the STALLED branch, so
#      the two-tick clock never started. THE ACTION THAT CREATES THE STATE IS
#      THE ACTION THAT HIDES IT: `issue-claim.sh block` strips `ready` and
#      `in-progress` together, so recording "a human must decide this" removes
#      the issue from the one set the old conjunct consulted (observed
#      2026-08-26 on #273 / PR #279; cancelled by hand).
#      THE ENUMERATION IS PART OF THE FIX, not a detail of it, and the first
#      edition of that fix omitted it and was WORSE THAN THE BUG: §2's only PR
#      discovery was the branches of IN-FLIGHT issues, and `block` strips
#      `in-progress`, so in #282's own state the tick enumerated zero PRs. A
#      held set empty because nothing was looked at is indistinguishable from
#      one empty because nothing is held — STALLED is then forbidden by the
#      non-empty rule while COMPLETE is admitted, and the loop announces DRAIN
#      COMPLETE and self-cancels with a human-gated PR still open. The
#      forever-tick at least never claimed to be finished.
#      THE SET HAS TO BE ONE SET: COMPLETE's veto and §7's held set must range
#      over the SAME PRs, since any PR that vetoes COMPLETE but can never enter
#      the held set gives Ready-empty + in-flight-zero + held-empty — #282 one
#      shape over, which an unqualified "any open PR vetoes COMPLETE" produces
#      the moment a Dependabot or hand-opened PR is sitting there. And BOTH
#      HALVES SPAN BOTH PATHS, because the blocked set is `blocked[]` only
#      without a board and a bullet written for one path is invisible on the
#      other — which is how a board repo would have kept the bug with every
#      assertion green.
#      THE FIX IS A DISCRIMINATOR, NOT A DELETED CONJUNCT, and the deletion is
#      what a later "this conjunct does nothing" sweep re-derives: an open PR is
#      not automatically a human gate — one whose checks are running or red can
#      still advance on its own. So the third conjunct is "nothing this loop is
#      permitted to advance" and a table decides which side an open PR falls on,
#      hinged on §2's ONE redispatch. ITS LAST ROW IS A DEFAULT and is pinned as
#      one, since §2 holds a PR for more reasons than the rows enumerate and a
#      table that silently answers "alive" for a shape it does not know
#      re-creates #282 one shape at a time; `CONFLICTING` is the measured case,
#      stopping CI from firing at all so that `no checks reported` reads exactly
#      like `CI hasn't started`. Rows 2-6 cannot fire at the moment STALLED is
#      decided — in-flight zero empties the branch half of the union — and §7
#      SAYS so, because a reader who works it out will otherwise trust them as
#      live or delete them as dead.
#      HOW IT IS BOUND, IN THREE LAYERS, each added after a review defeated the
#      one before it, and layer 1 now covers §7 WHOLE — FENCES INCLUDED.
#      Presence-only assertions were measured passing rewrites that KEPT the
#      sentence and QUALIFIED it; whole-paragraph equality was defeated by
#      INSERTING A SIBLING PARAGRAPH; a hand-picked SUBSET of paragraphs was
#      then defeated five rounds running, each time by a paragraph no key held
#      that inverted one a key did — including the API-failure rule a pinned
#      paragraph merely DELEGATES to. So: (1) CANON, every blank-line block of
#      §7 compared for equality after flattening, so a bullet body and a table
#      cell are as pinned as a paragraph, PLUS every fenced block with `#N`
#      normalised — the fences are the text the loop PRINTS, and a parenthetical
#      added inside the DRAIN COMPLETE fence was measured restoring #282 at exit
#      0 with markdownlint clean; (2) INVENTORY, the ordered lists of block
#      openers, list markers, table rows and headings for §7 AND for §2, §4, §6
#      and the top-level Guardrails list — Guardrails already restates a
#      §7-adjacent rule today, so hoisting one there has precedent in that very
#      file. §3 is pinned by TEXT rather than inventoried, being the file's only
#      "in-flight is" sentence, which §2, §4 and §7 all read: re-including
#      `blocked` there, or inverting "a green PR in the merge queue still counts
#      as in-flight", were each measured at exit 0 while §3 sat outside every
#      window. §5 and §1 are still unread, which is stated limit (6); (3)
#      CONSUMPTION, every canon key consumed by exactly one assertion. The claim
#      is "identical after flattening", NOT "byte-identical", and the inventory
#      keeps each opener's first words only. Must-not-exist checks run against a
#      flattened AND an emphasis-stripped copy, and FAIL CLOSED on a malformed
#      pattern — grep exits 2 on an invalid ERE, which an `if grep … || grep …`
#      reads as "not found", so every must-not-exist check was failing open,
#      three of them carrying #282's own decision. Every
#      line-scoped check runs against a resolved window; table-row patterns are
#      anchored `^[[:space:]]*\|`; example identifiers are matched by SHAPE.
#      ITS VACUITY FLOOR IS A SECTION REGISTRY WITH PER-SECTION MINIMUMS —
#      `name:count`, members enumerated beside their counts, the floor DERIVED
#      as their sum — because a bare number was measured not binding three times
#      over. The registry block's OWN minimum is held apart from that array
#      (`REGISTRY_MIN`), since while it was a summand, deleting the block and
#      its entry shrank the floor by exactly what the deletion removed. The
#      known limits are stated in its header rather than patched, and that
#      enumeration and this one must agree: §2's and §4's remaining bullets, §6
#      and Guardrails are inventoried but not content-pinned (both of the first
#      two carry text-pinned exceptions the header enumerates), so rewriting the
#      BODY of an existing bullet there can invert §7 from outside it; removing
#      a section quietly takes three coordinated edits on HEAD; canon values are
#      regenerated by hand; a gate cannot verify its own guard from inside it; markdownlint
#      remains load-bearing for a malformed table; and §5 and §1 are unread. THE
#      FLOOR VALIDATES ITS OWN INPUTS, after one deleted digit was measured
#      voiding it at exit 0 on bash 3.2 — the arithmetic aborted mid-loop and
#      dropped every later summand, and an unset `REGISTRY_MIN` ran ZERO
#      assertions and still exited 0. THE PREMISE IS ASSERTED, NOT ASSUMED:
#      `issue-claim.sh`'s `block` case is read for the one fact everything rests
#      on — that it strips BOTH labels — since if it stripped only `ready` the
#      whole account of the bug would be wrong with every prose assertion still
#      green. Its header records why it carries no `-ef` precondition and what
#      that costs a mutation harness. The assertion count is printed, never
#      transcribed.
#      THE SAME FOREVER-TICK IS REACHABLE ONE BULLET EARLIER, and #282 does not
#      close it (issue #290): every §2 failure path had a demotion route except
#      the `CONFLICTING` one, which surfaced the PR and HELD it with no comment,
#      no counter and no exit. The hold left the issue `in-progress`, so
#      in-flight never reached zero and BOTH terminal states stayed vetoed. The
#      discriminator classifies such a PR correctly the moment it is enumerable,
#      and on the in-flight path it never became so. IT CANNOT REACH A DEMOTION
#      ANY OTHER WAY EITHER: a conflicted PR stops CI firing at all, so the
#      failed-check bullet's attempt counter never starts. THE DECISION IS
#      DEMOTE ON SIGHT — comment, `blocked`, a human rebases — and the REJECTED
#      alternative is pinned as a negative, because mirroring the failed-check
#      bullet's ONE redispatch means dispatching a sub-agent to rebase, which IS
#      this loop advancing that PR and is exactly what §7's `CONFLICTING` row
#      forbids; that option costs a §7 row as well. §7's TABLE IS UNTOUCHED:
#      once the issue carries `blocked`, §7's FIRST row matches before the
#      `CONFLICTING` row is reached. Its section carries canon equality — the
#      only layer bounding a REWORDED decision, and the one the header's
#      hand-regeneration limit says a rubber-stamp regeneration silences — plus
#      literal must-exists and the `surface and hold` / `ONE redispatch` vetoes,
#      which catch a literal DELETION and nothing subtler. That asymmetry is
#      measured and stated rather than papered over by widening the greps.
#      Three tracked files — `dispatch-ready/SKILL.md`, `issue-claim.sh` and
#      `merge-shepherd.sh` — no gh, no network. The members are enumerated
#      beside the number because the number rotted here once: 369bbef (#297)
#      added the third subject and left "Two" standing through two later hand
#      edits, which is CLAUDE.md's bare-count rule collecting its own example.
#      IT NOW PINS A THIRD TERMINAL STATE (issue #286). DRAIN DEGRADED ends a
#      loop that is ticking into a void under a platform outage: measured, an
#      18-tick three-hour run that reported the state accurately, did nothing,
#      and then proposed closing and reopening a PR mid-outage. It CONSUMES
#      #285's probe rather than re-deriving health, is EVALUATED FIRST because
#      a degraded platform is exactly when COMPLETE's and STALLED's live reads
#      stop being trustworthy, and reaches the SAME stop path — a second cancel
#      implementation is the defect, not the feature. `unknown` is deliberately
#      NOT degraded and is the collapse a later sweep will make: it means the
#      probe could not measure, which is precisely the state that must not stop
#      a loop. COMPLETE and STALLED are untouched.
#      AND A FOURTH (issue #342, epic #322). #341's Site filter steps around a
#      Ready item whose `site:` labels name another machine, and that hold
#      reached §7 with nowhere to go: in-flight zero, Ready non-empty and every
#      remaining item site-held satisfies STALLED's every conjunct, so the loop
#      ended telling the operator to resolve a gate this checkout cannot. A site
#      hold is neither self-resolving — this checkout will never satisfy it —
#      nor a human gate, so DRAIN DEFERRED names the site and takes COMPLETE's
#      stop path, cron self-cancel included, and is NEVER reported as STALLED.
#      THE DISCRIMINATION IS THE WHOLE OF IT and is pinned in BOTH directions:
#      DEFERRED is STALLED plus one test — the held set holds nothing but site
#      holds — so it is evaluated FIRST or it is unreachable, while a held set
#      carrying one dependency hold, one `blocked` label or one held PR is still
#      STALLED with the site holds listed among its reasons. It takes NO
#      confirmation tick, modelled on COMPLETE rather than on the state beside
#      it: a site declaration cannot change what this checkout IS, so a second
#      tick reaches the same answer. DEGRADED cannot compete for the state at
#      all — it requires in-flight non-zero — so #286's evaluated-first rule
#      needed no widening. §4's POINTER at the new state belongs to the site
#      filter gate below (`test-site-filter.sh` row R30, deletion- AND
#      qualification-mutated there) and is deliberately not duplicated here.
#  33. audit lost-reviewer tests (scripts/test-audit-lost-reviewer.sh) — the
#      nine `*-reviewer` agents serve TWO orchestrators and only one of them
#      scored a reviewer that came back with nothing. `pr-review-orchestrator`
#      Step 5 marks such a surface `!` and names it on every run; `assess-it`
#      had no equivalent, so a reviewer that returned nothing was
#      indistinguishable from one that found nothing (issue #284). AUDIT MODE IS
#      THE WORSE PLACE FOR IT because it WRITES: the artefact is a filed Epic
#      and its child issues, so a lost `security-reviewer` yields a backlog that
#      omits a whole domain and READS COMPLETE to everyone who finds it later.
#      THE HARM LANDS AT THE PREVIEW, NOT AT THE REPORT — `assess-it` already
#      previews before it files, so the requirement is POSITIONAL: the dark
#      domains are named IN the preview and BEFORE the approval prompt, and a
#      rule landing after the ask, or in Phase 5, documents a backlog already
#      filed. AND IT IS NOT A VETO: filing still proceeds on approval, so both
#      halves are pinned because either alone is wrong. Bound the way gate 32
#      is, and for its reasons: (1) CANON over BOTH FILES WHOLE, every
#      blank-line block AND every FENCE compared for equality after flattening —
#      Phase 4's ```text fence IS the coverage block the run prints, so
#      excluding it would leave the one artefact #284 is about writable. It
#      covered seven TARGETED windows for one review round, until six
#      meaning-inverting rewrites were measured passing at 79/79, every one of
#      them in a block OUTSIDE those windows where nothing bound an existing
#      block's BODY — including a seventh item appended to orchestration.md's
#      Phase-2 ordered list reading "Drop dark domains … remove it from the
#      ledger before Phase 3". THE SUBSET WAS THE DEFECT, NOT THE CHOICE OF
#      SUBSET, which is gate 32's lesson relearned here; (2) INVENTORY,
#      openers, bullets, ORDERED-LIST items, table rows and headings for both
#      files whole, the ordered list being the one carrying #284's own decision
#      since Phase 4's ITEM ORDER is the fix — and it was missing on
#      orchestration.md entirely in that first edition, which is how the list
#      above went unseen; (3) CONSUMPTION, every canon key consumed and every
#      window's block and fence counts equal to its canon entry counts. THERE IS
#      DELIBERATELY NO PROSE VETO, the asymmetry with the prose-veto gates
#      (test-sentry-verification.sh, test-review-gate-decisions.sh) that a later
#      sweep will try to close: both veto editions built for the latter reported
#      clean on inverted sources, canon plus inventory already answers what a
#      veto would ask, and the only must-not-exist checks are for the #283
#      residue note's own literals — a literal deletion verified, not a polarity
#      judgement — run flattened AND emphasis-stripped. THE PREMISE IS ASSERTED: the ledger says
#      "every domain in the table above", so the map's rows are compared to
#      `agents/*-reviewer.md` as an EQUALITY over a count floor, since a stale
#      map would leave a whole domain with no row to be dark in while every
#      prose assertion stayed green. `agents/pr-review-orchestrator.md` is read
#      for exactly ONE fact — that its own `!` bullet survives — and nothing
#      else about it is pinned here; gate 29 owns that file. Its floor is a
#      section registry with per-section minimums whose sum is DERIVED, every
#      token validated before arithmetic touches it, and `REGISTRY_MIN` held
#      apart from the array. Five tracked files — assess-it's SKILL.md,
#      orchestration.md, github-issue-ops.md and assessment-rubric.md, plus the
#      PR orchestrator for that one fact — and a listing of `agents/`, no gh,
#      no network.
#  34. platform-health-probe tests (scripts/test-platform-health-probe.sh) —
#      pr-shepherd's degradation probe returns FOUR distinct verdicts and gates
#      NOTHING (issue #285). The unhandled case was never a `gh` error, which
#      every caller already discounts, but a `gh` call that exits 0 carrying
#      INCOMPLETE data and is then read as live state: measured 2026-08-26 on
#      PR #283, where the rollup came back without `ci`, no `CI` run existed for
#      the head across ~40 minutes while two prior heads each had one within
#      minutes, and `ci` later appeared with an EMPTY state and still no run.
#      Nothing errored; three hypotheses were produced and all three were wrong.
#      Both ways of getting this wrong are silent and they are opposite.
#      Collapsing any verdict toward `healthy` makes the probe WORSE than not
#      having one — a status page lags real degradation by minutes to tens of
#      minutes, so green can never be evidence of health and an unreachable page
#      certainly cannot — and both collapse directions are mutation-proved.
#      Letting the verdict reach a decision turns an outage into changed
#      behaviour rather than a changed explanation, so never-a-gate is asserted
#      STRUCTURALLY twice: every verdict exits 0 (the deliberate asymmetry with
#      stack-probe.sh, whose exit codes ARE a gate), and no sibling pr-shepherd
#      script names the probe — over a sibling list held as an EQUALITY against
#      the directory, so a new script cannot ship unscanned. The SKILL.md half
#      is SECTION-scoped, because a whole-file grep is satisfied by the probe's
#      own §2b and by the bundled-script table and would read a probe wired into
#      the merge section as clean; every heading in the file is scanned by
#      SECTION EQUALITY, with §2b and the script table as the only carve-outs,
#      mutation-proved by a mention in §3 and by the measured hold rule in §4
#      that a by-name list of §1/§1b/§3 left green. Two contract decisions
#      are pinned together and must be read together: an unreachable endpoint
#      never manufactures a `healthy` and never manufactures a `degraded` on its
#      own, while an anomaly BESIDE an unreadable page stays
#      `degraded (unattributed)`, the degradation having been measured
#      first-party. THERE ARE TWO DOORS INTO `healthy` and the first-party one is
#      the easier to leave open: a single-commit branch has no prior head, so an
#      earlier edition compared nothing, found nothing, and certified a branch
#      whose CI had never started — #285 one step EARLIER. `clean` now means a
#      check RAN and found nothing, and ONLY the run comparison earns it: the
#      empty-state read detects a MALFORMED entry and can never detect an ABSENT
#      one, so a rollup simply lacking `ci` looks healthy through it. Pagination
#      cuts BOTH ways — a dropped head over-detects, a boundary INSIDE the oldest
#      head's set under-detects and reaches `healthy` — so the page reports
#      whether it was truncated. Three decisions follow, each cased and
#      mutated: a gh TRANSPORT failure is `not_measured` and never an anomaly (an
#      expired token is not platform degradation); attribution is SCOPED to
#      check-relevant components, since a Copilot blip beside a genuinely red
#      `ci` invents an EXCUSE — the same wrong answer pointed the other way; and
#      the baseline is an INTERSECTION over every prior head with head-triggered
#      events only, so a path filter or a one-off workflow_dispatch is not
#      degradation. Its age floor is contract, not an optimisation — a workflow
#      that has not started is not a missing one — and so is its SCOPE: the
#      empty-state read is direct, so it is neither age-suppressed nor
#      conditional on the runs call, which an outage breaks at the same time. The
#      healthy fixture's rollup names deliberately match no workflow name, since
#      a fixture where they lined up would make the cross-namespace case vacuous.
#      THE RUNS PAYLOAD TRAVELS ON STDIN, never on argv — #263's lesson from the
#      other side: one page of 100 runs is ~1.6 MB against a 131,072-byte cap on
#      a single argv element, so `--argjson runs` exited 126 at roughly the
#      eighth run and the comparison was dead on every real repo. A failed
#      derivation is validated rather than trusted (`[ "" -eq 0 ]` is falsy and
#      falls through to the branch asserting the check RAN), and `probe_errors`
#      is CONSULTED, not merely recorded. §2b is pinned by CANON rather than by
#      presence, since a needle is satisfied by a document that still contains
#      its sentence AND its inverse; never-a-gate is scanned for the verdict
#      VOCABULARY as well as the filename, since the follow-up work will be
#      written as "on a degraded verdict, hold the PR", naming no script.
#      TWO FAILURES THAT PRODUCE NO WRONG VERDICT AT ALL are cased too (#303),
#      because both are silent. The verdict emitter ran with no handler under a
#      script with no `set -e` and an unconditional `exit 0`, so a dead `jq -n`
#      handed the caller exit 0 and EMPTY stdout — `jq -r .verdict` yields the
#      empty string, which is neither one of the four verdicts nor `unknown` —
#      while the stderr summary still printed and looked normal; the hand-built
#      fallback is mutation-proved by M25, and deleting it turns that mutant
#      into a red `«no output»`. And the OPTIONAL attribution fetch was the only
#      bounded call while the three LOAD-BEARING ones carried no timeout, in a
#      script whose trigger condition is "GitHub may be degraded right now": all
#      of them now run under `PLATFORM_GH_TIMEOUT`, asserted over a shimmed
#      `timeout`'s own ledger rather than over the call log, since the mock `gh`
#      sees an identical argv either way. A bound that FIRES is a transport
#      failure like any other — `not_measured`, never an anomaly — with its own
#      mutant beside the one it mirrors, since reporting our own cutoff as
#      evidence of degradation is the confident wrong answer reached through the
#      mitigation for a different one. The exit code is asserted on EVERY
#      verdict-form mutant, so no path can grow one that carries a verdict.
#      BOUNDING A CALL CAN CREATE A NEW WRONG ANSWER, AND THE ANSWER WAS TO STOP
#      MAKING THE CALL (#314). The cwd repo lookup WAS a bounded `gh repo view`
#      whose `|| true` discarded the status, so a fired bound was reported as
#      `not in a GitHub repo` — exit 1, empty stdout, inside a VALID checkout —
#      and every OTHER non-zero exit said the same, which is the whole class
#      rather than two codes of it. The slug is now DERIVED LOCALLY from the
#      `origin` remote, so the bounded sites are three and 17d measures the
#      derivation instead, from real cwd fixtures: the `gh` call is gone (a
#      must-not-exist mock arm and a call-log check), the URL forms parse, and
#      each failure shape still reaches a verdict. THAT FIXTURE INVENTORY IS
#      CHECKED MECHANICALLY (#324), because nine review rounds of prose did not
#      hold it — three consecutive commits each added a fixture and missed at
#      least one site, and the paragraph recording those misses was itself a
#      site missed twice, a miss being SILENT since the fixture is built and
#      simply never asserted. The set is DERIVED from the `CWD_*` declarations
#      and required at three hand-maintained sites: the built message, exactly
#      one of the two verdict loops, and — for each fixture given an origin URL
#      — the read-back loop that proves the hermetic git pins bind. The
#      accumulator and the bare-`mkdir` fixture are exempt BY NAME, each
#      asserted to still resolve. THE EXTRACTION LAYER IS THE PART WITH TEETH,
#      because every way it under-reads is this same defect one level up — a
#      reassuring `ok` for a fixture nobody checked — and the first edition of
#      the guard shipped several such reads, each escape re-measured against
#      that edition and enumerated where it is fixed — the header carries the
#      first two rounds, and each later escape is recorded beside the read that
#      closed it, in the derivation and census blocks. Never counted here: a
#      number in this file would be a third copy of a list that already lives in
#      two places, which is the shape that put the escapes there to begin with. So: continuations are joined before
#      anything is read (a wrapped `make_cwd` already exists in that file); the
#      declaration read allows indentation and requires a `"$WORK/` value; the
#      set is cross-checked BOTH ways against the `CWD_MISSING` ledger, a
#      second derivation rather than a second copy; the four single-line sites
#      must match EXACTLY one line and are newline-normalised; and the
#      `SELF_ABS` assignment is asserted to precede the `cd`, since preflight
#      runs that gate from the repo root where the broken placement resolves
#      fine — so CI cannot observe the one regression #324 records as the
#      reason a first attempt was reverted. The bound has THREE branches and only one is
#      reachable through a prepended shim, so the other two run under CURATED
#      PATHs; an earlier edition called them impossible to exercise, which was
#      false and cost the file its only coverage of the `probe` scope — the
#      scope that must NOT make a run `not_measured`, or every host without
#      coreutils reports `not_measured` on every run. Its filter is mutated on
#      a curated PATH, since no shimmed scenario produces such an entry. The bound
#      VALUE is validated and the validation is cased: `00` is all digits, not
#      empty and not the literal `0`, and `timeout 00 …` means no bound at all.
#      A fired bound is 124 OR 137 — the latter when the child ignored TERM and
#      the kill grace fired — and ONE predicate says so, since testing 124 at
#      two sites independently left the path `-k` exists for as the one path
#      neither site could name. The repo lookup's own late-flush hazard — a call
#      killed after flushing left a usable-looking fragment — went with the `gh`
#      call it belonged to, and its shim arm was deleted rather than left
#      unreachable.
#      THE GATE'S OWN REACH WAS THE NEXT DEFECT (#302): a review ran 31
#      mutations against the probe and 19 passed — three real wrong verdicts,
#      the rest holes in this gate. Every "explains nothing" string is now
#      pinned by CANON per branch, since a matcher accepting either of two
#      needles for every branch passed an inversion telling the caller a stall
#      is a real defect; the docs corpus is an EQUALITY over every tracked
#      skill doc, and the two files that may name the probe are scanned by
#      SECTION EQUALITY over their own headings, since pr-shepherd's SKILL.md
#      was in no corpus and a hold rule in its §4 was green; the
#      failed-generator door is cased BEHAVIOURALLY — a rollup of numbers kills
#      the empty-state read for real, and a fault-injecting `jq` shim kills the
#      missing-run read, which no payload can — after three source pins were
#      each defeated; a bound that fires is cased and mutated at EVERY gh site
#      through a selector on the shim, not only at the first call, which
#      absorbed it; the emitter fallback is four keys (`pr` admitted under
#      #314's narrower rule — carry nothing that could be what broke it) rather
#      than a 16-key copy of the schema, and the fallback mutants assert its
#      exact key set plus the stderr line naming which ledger failed;
#      the name `gh` is a shell function in the probe, so the chokepoint is
#      structural rather than a one-spelling grep, with calls-vs-bounds parity
#      as the behaviour; the first-party count is by EXCLUSION so an
#      unrecognised scope fails closed; and the out-of-loop mutants carry a
#      ran-counter like the loop's. Mock `gh` AND mock `curl`, both recording
#      every call so the read-only claim is measured by METHOD — per token, by
#      prefix — not by path prefix: no repo, no network.
#  35. stale-cache diagnostic tests (scripts/test-stale-cache-diagnostic.sh) —
#      the README's stale-plugin-cache diagnostic and the no-auto-stamp record
#      (issues #296, #301). The idiom it replaced compared version STRINGS and
#      answered "current" while 18 skill files and all ten agents differed, so
#      the compare block's assertions are scoped to its CODE FENCE rather than
#      the file: the paragraph underneath names every guard, and a whole-file
#      presence check passed on a README whose fence had each one deleted. Two
#      tracked files, no gh, no network.
#  36. detect-capabilities tests (scripts/test-detect-capabilities.sh) —
#      setup-config's capability probe reads the PRODUCT, never the answers
#      previously recorded about it (issue #317). The `posthog` grep was a
#      bare-word sweep of the tracked tree, and #267 put `posthog: none` into
#      `.claude/sassy-dog/survey-work.md` — a tracked file — so in a quiet tree
#      the probe's only hit was the config key ITSELF and every refresh reported
#      positive evidence against the answer while citing the file recording it.
#      Nothing crashed: update mode correctly stops and surfaces, so the harm is
#      that it stops forever, in every repo that answered §2c, with a per-repo
#      prose rationale — the #167 third-copy shape — as the only remedy. Both
#      greps now exclude `.claude/**`; the `sentry` pathspec is symmetric even
#      though its SDK patterns never matched the literal `sentry: none`, since
#      an asymmetry between adjacent lines reads as an oversight to the next
#      editor. Behavioural over eight git fixtures built under one `mktemp -d`,
#      with the two grep lines EXTRACTED from the shipped script rather than
#      transcribed: config-only and hook-only must read false; source-only,
#      docs-only, claude-md-only and both must read true; lock-only proves the
#      pre-existing `*.lock*` pathspec survived the edit; and nested-`.claude`
#      pins the pathspec's ROOT-ANCHORING as a recorded decision rather than an
#      accident. Two markdown fixtures, deliberately: docs-only carries the
#      README that `interview.md` §2c names — bare, no extension — plus a
#      `docs/` file neither caveat mentions, and claude-md-only is the
#      only fixture whose sole occurrence is the root `CLAUDE.md`, which is the
#      one carve-out in the pathspec and was pinned by nothing until it landed.
#      Fixture adequacy is its own property and runs PER self-match fixture —
#      the extracted lines with the exclusion STRIPPED must still match each of
#      config-only and hook-only on its own, or that fixture's half of the
#      false-verdict property has gone vacuous and says so. Its spelling is
#      pinned in two coupled places (the stripper and the shape guard) and the
#      header says so, since an equivalent respelling reddens both while every
#      verdict stays correct. Mock `gh`, git run with the contributor's global
#      and system config out of the way, no network, no real repo.
#
#  37. plugin-root-in-references tests
#      (scripts/test-plugin-root-in-references.sh) — `${CLAUDE_PLUGIN_ROOT}` is
#      substituted into `SKILL.md` at load time and nowhere else, so a
#      reference doc that writes it in a command resolves the path against `/`
#      and exits 127. Thirteen such lines accumulated across six docs (issue
#      #329) while CLAUDE.md documented the rule in prose the whole time —
#      this repo's own "a rule stated in prose with no gate rots silently"
#      convention, applied to itself. The guard bans the token in COMMAND
#      usage, keyed on fenced code blocks, and must NOT touch
#      `skills/assess-it/references/github-issue-ops.md`, whose prose names the
#      token to document this exact trap; that line is the discrimination
#      fixture, so a scanner degraded into matching everything fails property
#      2 rather than deleting the one doc that explains the bug. Property 3 is
#      the one with teeth: a doc using `$PLUGIN_ROOT` must carry the
#      path-resolution preamble defining it, because an unset variable
#      resolves against `/` exactly like the token it replaced — the same
#      defect wearing a different name, and the shape a later cleanup reaches
#      for. Mutation-proved both directions, plus a blockquoted fence, against
#      scratch fixtures scanned by the SAME function that scans the tree. No
#      gh, no network, no mutation.
#
#  38. file-or-link-issue tests (scripts/test-file-or-link-issue.sh) — the ONE
#      write-capable issue path is idempotent ACROSS the search index's lag
#      (issue #339). Marker-keyed idempotency was a read-after-write against an
#      ASYNCHRONOUS index: #337 filed at 21:05:37Z, the same marker re-run at
#      21:05:44Z searched, got `[]`, and filed the duplicate #338 — seven
#      seconds — while the identical search four minutes later returned both.
#      Nothing covered this script before: `grep -l file-or-link-issue
#      scripts/test-*.sh` returned nothing, so the property CLAUDE.md calls the
#      script's defining one was enforced by prose alone. The fix is TWO stages
#      and the gate refuses to let either be simplified away: the search is
#      unbounded in AGE but not fresh (M6 deletes it and loses every marker
#      older than the window), the `--search`-less listing is a direct object
#      read and read-after-write consistent but bounded in COUNT (M1/M2 delete
#      or re-index it and #339 returns verbatim). The DISCRIMINATION half is
#      load-bearing — a dedupe answering already-linked to everything satisfies
#      the reproduction and is useless — and its sharp case is the PREFIX
#      COLLISION, which arrives by TWO routes and needs the delimited footer
#      `<!-- <marker> -->` on BOTH. Stage 2's `contains()` is a substring test;
#      stage 1's GitHub phrase search matches a token SUBSEQUENCE (verified
#      read-only: `"stale-issues-title-only" in:body` returns #339/#337/#338,
#      whose marker is `stale-issues-title-only-shipped-detector`). The first
#      shipped version applied the predicate to stage 2 alone while stage 1
#      answered first on the bare marker, which is the LIKELIER route — it
#      fires on a sibling that is already indexed, i.e. any sibling more than a
#      few minutes old — and whose harm is quieter than #339's own: an epic
#      child never filed, reported as already-linked with a sibling's number.
#      One predicate, two call sites, and M3/M7/M8 prove both sites depend on
#      it. A scan that could not be PERFORMED exits 2 rather than filing blind,
#      the align-labels delete-gate shape applied to this write (M4) — as does
#      a scan that SUCCEEDED with a non-array payload, including the empty
#      stdout that `jq` reads as no output and exit 0. The `gh issue create`'s
#      own status is captured explicitly rather than left to `set -e`, which
#      used to abort the assignment before the script's `exit 2` could run and
#      report a transient 5xx as exit 1 with empty stdout and stderr. Stage 1
#      KEEPS its `|| echo "[]"` degradation, and that asymmetry is deliberate —
#      the refusal belongs to the stage that is load-bearing for freshness — so
#      a fixture EXECUTES that branch rather than leaving it written and unrun. The FIXTURE PROVES ITSELF
#      first, because #339 is about an unverified freshness assumption and
#      replacing it with a second one would be the same bug: the mock's search
#      must NOT see a just-created issue, its direct listing MUST, and the PATH
#      shim must actually shadow the real `gh`. Every verdict is measured as a
#      WRITE — `gh issue create` calls in the mock's log — never as a literal.
#      The out-of-window-AND-unindexed miss is asserted as a documented
#      limitation, PAIRED with the same input at a raised `--recent-scan`,
#      which is what proves it is the bound rather than a scan matching
#      nothing. Mock `gh` under one `mktemp -d`: no repo, no network, and no
#      real issue is ever filed — the reproduction in #339 cost a live
#      duplicate and is deliberately not repeated as a test. One harness trap
#      worth knowing before editing a target line here: the mutation cells
#      reach awk through `$ENVIRON`, never `-v`, because `-v` performs escape
#      processing and several targets carry a backslash — a shell
#      line-continuation for M2 and M5, an escaped quote for M2. With `-v` this
#      gate was green on macOS's BWK awk and red on CI's gawk claiming M2, M3
#      and M5 were STALE MUTATIONS, a diagnostic naming the wrong file. The
#      transport is round-tripped and asserted, with an adequacy conjunct, so
#      the next such awk reports the transport rather than the targets.
#
#  39. queue-snapshot site tests (scripts/test-queue-snapshot-site.sh) — the
#      execution site is read from `site:<name>` LABELS, and the three body
#      contracts are untouched by that (issue #340, epic #322). The label is
#      the point: #340 first shipped `site:` as a fourth BODY contract, and a
#      body line can be QUOTED — both issues introducing the contract carried a
#      fenced example that declared a site by accident. Preventing that meant
#      deciding what a fenced block, a code span, an HTML comment, an info
#      string and their interactions mean, i.e. implementing a subset of
#      CommonMark and discovering its edges one review at a time. A label
#      cannot be quoted in prose, so the class is gone and both the parser and
#      most of this gate went with it. Rows cover present/absent in BOTH
#      buckets, the key set as a SET, folding on the key and the value
#      independently, PREFIX-not-substring from both sides, an empty value, and
#      the rule with teeth: SEVERAL `site:` labels are a CONFLICT and must
#      never resolve to "any site" — the direction #322's originating bug ran.
#      That is why `sites` is emitted as a LIST with no scalar beside it: a
#      scalar is null for both "nothing declared" and "several declared", so
#      its obvious reading turns a conflict into "any site" where the list's
#      cannot. One row pins the whole reason for the move: a body quoting the
#      old contract declares nothing. THE MUTANTS' REACH IS DERIVED, never
#      written down — the first version of this gate carried a hand-written
#      roster over a 21x94 matrix nothing re-computed, and three separate
#      review rounds each found a row that had gone vacuous, so `mutant` now
#      diffs against the shipped baseline and the rows NO mutant flips are
#      derived and compared to a declared set. Mock `gh` that honours `--json`,
#      its shim resolution verified after `chmod`, an RFC 2606 `.invalid` slug:
#      no repo, no network, structurally.
#
#  40. site filter tests (scripts/test-site-filter.sh) — the two CONSUMERS of
#      the execution-site declaration #340 emits: dispatch-ready §4's Site
#      filter and take-it's refusal before the claim (issue #341, epic #322).
#      #340 gated the emitter and nothing read it. The costs here are
#      asymmetric, which is why the answer is a HOLD rather than a recovery: a
#      mis-groom is fixed by a human moving a card, while a wrong dispatch
#      claims the issue, spends a worktree agent that cannot reach the other
#      machine's artifacts, and lands it in `blocked` under a comment naming
#      the wrong cause. Five decisions are pinned. THE MATCH IS THE ARRAY FORM
#      FOLDED ON BOTH SIDES — `not sites or execution_site.lower() in sites` —
#      because the array read is the only one that cannot resolve an ambiguous
#      declaration to "any site", and because the snapshot folds only the LABEL
#      side, so a raw `execution_site: VDI` holds the VDI loop's own work; every
#      subject is held to one spelling, and the three that existed before #341
#      disagreed — `queue-snapshot.sh`'s header and `config-contract.md`
#      unfolded, `github-issues/SKILL.md` folded. THE DISCRIMINATION HALF IS
#      LOAD-BEARING — an empty `sites` proceeds exactly as today, and a `sites`
#      containing this checkout's site proceeds however many members it
#      carries, in BOTH consumers, since a filter that holds everything
#      satisfies "mismatched work is held" and is useless. AN UNNAMED CHECKOUT
#      IS FAIL-OPEN and is a DIFFERENT QUESTION from an unlabelled issue, each
#      with its own row, because collapsing the two sends whichever half is
#      dropped dark. A SITE HOLD IS NOT A FAILURE: no redispatch budget, no
#      demotion, and in take-it the refusal is raised BEFORE the claim, checked
#      as a line-number comparison against the claim step's heading rather than
#      from prose that reads the same wherever it sits. ONE RESOLVER, AND EVERY
#      CONSUMER RUNS IT — the buckets are label-scoped, so dispatch-ready's
#      `board:` path (whose snapshot carries `labels` and no `sites`) and
#      take-it on an unpromoted issue would each need their own, and a filter
#      with no input is a SILENT fail-open in a repo that opted in; two rows RUN
#      `queue-snapshot.sh --sites-of` rather than describing it, one for the
#      answer and one proving it reaches no `gh`. Needles are pinned THROUGH
#      their terminator, because a qualifying clause — "no redispatch budget on
#      the first hold" — inverts a decision while every phrase a substring check
#      looks for survives; each such row carries a qualification mutant beside
#      its deletion one. It re-checks none of #340's resolution rules, which are
#      test-queue-snapshot-site.sh's, and nothing about §7's terminal states
#      beyond the pointer §4 owes an operator, which are
#      test-drain-terminal-states.sh's. Mutant reach is DERIVED: the gate
#      re-runs ITSELF against each mutated copy of the tree, diffs the
#      failing-row set against a baseline proved clean first, and the rows no
#      mutant reddens are derived and compared to a declared set; each
#      whole-subject veto has a mutant writing the offending text OUTSIDE every
#      window a must-exist row reads, which is what tells a whole-subject veto
#      apart from a windowed one. Two GUARD mutants rename a section's stop
#      heading and require the child to ABORT rather than flip a row — the
#      overrun guard shipped unable to fire, because `raw_region` excludes its
#      own stop line by construction and the guard grepped the window for it.
#      Source-level plus the two emitter rows; seven tracked files, copies only,
#      no `gh`, no network.
#  41. execution-site surface tests (scripts/test-execution-site-surface.sh) —
#      the HUMAN half of the execution-site contract (issue #343, epic #322),
#      where gate 39 covers the parser and gate 40 the two dispatchers. Four
#      decisions that read like drift to a later alignment sweep: grooming
#      APPLIES the `site:<name>` label and never writes a `site:` body line,
#      though it sits beside three body contracts it does write; an unlabelled
#      issue renders on the plate exactly as it did before, because a token on
#      every line is noise proportional to the backlog; several `site:` labels
#      NARROW rather than widen — every named checkout may take the issue, so
#      neither surface refuses a multi-member declaration nor tidies it down to
#      one, and neither resolves it to "any site", which is the direction
#      #322's originating bug ran; and the interview PROPOSES a name and never
#      assumes one, so an unanswered question leaves the key absent. NEITHER
#      SURFACE RESOLVES LABELS ITSELF: both run `queue-snapshot.sh --sites-of`,
#      because their reads are not buckets — the plate lists open issues and
#      grooming lists candidates — and a paraphrase forks the rules, which is
#      the failure #341 measured when one dropped the `strip()`. The `uname -s`
#      table has exactly one home and its tokens are asserted ABSENT from the
#      three consumer files — an earlier draft of #343 wrote `darwin` / `win32`,
#      a language runtime's constants no `uname -s` emits — and that ban is
#      CASE-INSENSITIVE, because a case-sensitive one catches a faithful copy
#      and admits the lowercase form this repo actually wrote. The same pattern
#      is first pointed at the table's home so it cannot pass vacuously. The
#      three retired "no interview exists yet" sentences are each banned by a
#      pattern proved against the exact sentence it retired, and the retired
#      match-no-checkout semantics by a pattern carrying a proof per
#      INFLECTION — an English rewrite reaches for all of them, modals and
#      quantifiers included, and four successive narrowings of that one ban each
#      shipped green. DO NOT SMOOTH THAT HYPHENATION TO NATURAL ENGLISH: the
#      un-hyphenated spelling is banned across test-site-filter.sh's whole-text
#      veto, whose subject list includes THIS FILE, so writing it here turns
#      preflight red from a different gate under a message that reads as a false
#      accusation. The hyphen is the only thing keeping this line legal. MUTANT REACH IS
#      DERIVED, not written down: the gate re-runs ITSELF against each mutated
#      copy of the subjects (`EXEC_SITE_SRC` / `EXEC_SITE_CHILD`), diffs the
#      failing-row set against a baseline proved clean first, and the rows NO
#      mutant reddens are derived and compared to a declared set that is empty.
#      That replaced a header-only mutation claim, which was false as a standing
#      property the moment a row was re-anchored — the same shape
#      test-queue-snapshot-site.sh paid three review rounds for. Copies only;
#      source-level and flattened; seven tracked
#      files, no `gh`, no network.
#
#  42. plugin drift tests (scripts/test-plugin-drift.sh) — a project-scope
#      plugin install PINS the version resolved when that checkout was first
#      opened, and nothing re-resolves it. `claude plugin list` reports user and
#      project scope separately and they drift independently, so `plugin update`
#      can report success at user scope while a repo keeps loading a months-old
#      plugin. Measured 2026-09-06: user scope was 2026.9.4 while ELEVEN of
#      eleven live project pins were behind it, `platform` and `sassydog-web` at
#      2026.8.83 — and only 2026.9.4 carried the feature about to be verified in
#      those very repos, so the verification would have "failed" for a reason
#      that had nothing to do with the change. The pin is silent and has no
#      expiry, which is CLAUDE.md's bare-count rule in another shape.
#      `skills/repo-health/scripts/pull-plugin-drift.sh` reports it; this gate
#      pins the four decisions that make the report trustworthy, each named by
#      exactly one mutant. Two are the ones a later simplification takes out:
#      CalVer compares FIELD-BY-FIELD AS INTEGERS, because `2026.8.100` is newer
#      than `2026.8.94` and a text compare says the opposite — a lexical sort
#      reports the newest pins as the stalest, and every version below 10 makes
#      it look right; and a checkout with NO entry lands in `no_entry` rather
#      than the clean set, because it inherits user scope, which usually means
#      the `.claude/settings.json` declaration `setup-config` writes is missing,
#      so the checkout has no project pin and a machine without a user-scope
#      install resolves nothing locally (cloud sessions never read it; #468).
#      "Current by accident"
#      and "current" are different facts. The other two: the pruned worktree and
#      dead-path counts are EMITTED (96 of 107 entries on the machine this
#      shipped from were agent worktrees — hiding the count is how nobody ever
#      prunes them), and an unresolvable reference leaves every row NOT current,
#      since unknown is never a pass. Fixture-driven, no network, and the real
#      user state file is never read.
#  43. tech-debt exclude tests (scripts/test-tech-debt-excludes.sh) — how
#      pull-tech-debt.sh consumes EXCLUDE_PATHSPECS (issue #365). setup-config's
#      contract shipped values already carrying `:(exclude)` while the script
#      supplies that magic itself, so every repo configured per the contract
#      handed git `:(exclude):(exclude)<path>` — a VALID pathspec matching
#      nothing, which excludes nothing and exits 0. The script now strips AT
#      MOST ONE leading prefix, and the bounded half is the row a later
#      simplification takes out: `doubled-stays-broken` asserts a genuinely
#      doubled value STILL LEAKS, because a greedy strip would silently repair
#      a different config error. Its sibling `lone-prefix-token-ignored` covers
#      the direction that fails toward SUPPRESSION rather than noise: a lone
#      `:(exclude)` strips to empty and re-prefixes to a bare `:(exclude)`,
#      an empty pattern git honours as "exclude the entire tree", so one stray
#      token reported zero debt at exit 0 and the plate rendered "no debt" —
#      such an element is DROPPED with a warning instead. What bounds the strip
#      is the QUOTED glob-free pattern, not `#` over `##`, which behave
#      identically here. The loop is fenced with `set -f` because it both
#      word-splits and pathname-expands: unfenced, bash expands a bare
#      `generated/**` (skipping dotfiles) while it cannot expand the prefixed
#      form, so the two spellings genuinely diverge —
#      `glob-spellings-identical` carries a dotfile for exactly that reason.
#      Every assertion reads the emitted OUTPUT SET and never an exit code —
#      git returns 0 or 1 here and never 128, and the script swallows stderr,
#      so an exit-code check passes against the broken script and proves
#      nothing. Two fixtures, both adequacy-checked: a scratch `git init` repo
#      built with GIT_CONFIG_GLOBAL=/dev/null so a contributor's
#      `core.excludesFile` cannot leave it empty and vacuous, whose markers are
#      ASSEMBLED AT RUNTIME so this gate does not show up as debt in the scan
#      it tests, and the live checkout carrying the issue's own reproduction
#      with its excluded directory DERIVED from an unfiltered scan, so no
#      unrelated edit can make that row vacuous. Mutant reach is derived by
#      re-running the same matrix against seven mutated copies (the sixth and
#      seventh being `nofence` and `norootlock`), each anchor
#      checked for presence first; the rows no mutant reddens are compared
#      against a declared set holding exactly the two fixture-adequacy
#      preconditions. SCAN_PATHS is deliberately OUT of scope and pinned
#      unchanged — the `**`-needs-`:(glob)` claim it would rest on did not
#      reproduce when tested, and the stale assertion is annotated in place in
#      the script header rather than left to contradict this one. No gh, no
#      network.
#  44. repo-signals recovery tests (scripts/test-repo-signals-recovery.sh) —
#      how `pull-repo-signals.sh` answers `default_branch_ci`, what a SURVIVING
#      null may mean, and what the recovered verdict must carry (issue #367).
#      One unfiltered sample of the newest runs across ALL branches is the wrong
#      instrument for a per-branch, per-event question: velovate, brewslate,
#      tailoredtip, what2wear and td3000 returned null on 2026-09-06 with a
#      verdict available (tabulated in #367), and null is well-formed JSON
#      carrying no outcome, so a reader with no rule for it reads the repo as
#      fine. The recovery is ONE narrow re-query, and ALL FIVE of its flags are
#      pinned because three of five left two ordinary edits green:
#      `--event` is the half that does the work (velovate had ZERO push-on-main
#      runs in its newest 100, so no RUN_LIMIT reaches it, and the mock answers
#      a branch-only query with the `schedule` run that actually crowds a
#      default branch); `--status completed` is the one a reader assumes the
#      derivation handles — it does for the SAMPLE, which fetches RUN_LIMIT rows
#      and can walk past in-flight runs, while this query fetches ONE row and
#      has nothing to walk past; `push` alone and never `merge_group`, whose
#      head branch `gh-readonly-queue/<branch>/pr-<N>` can never satisfy the
#      branch filter; a `--repo`-less `gh run list` answers as the CWD REPO,
#      handing every repo in the org this one's verdict; and a trimmed `--json`
#      makes the derivation reject every recovered run — so the mock MODELS gh
#      (filter, then limit, then project) rather than pattern-matching it.
#      It fires ONLY on a null, counted rather than inferred, since it is a
#      per-repo extra call. The still-null path is the point:
#      `default_branch_runs_seen` is THREE-STATE like `dependabot.enabled` —
#      `0` is a positive claim and may only come from a recovery that ANSWERED,
#      an unreadable or unreducible one is null, and a sample count of zero is
#      not evidence at all while a non-zero one bounds the count from below. The
#      verdict also ships `default_branch_ci_age_days` and `_url`, because the
#      recovery is unbounded by RUN_LIMIT and a month-old green rendered as
#      "clean today" is quieter than the missing verdict it replaced. One
#      DEFINITION is not one ANSWER: mutant `ignoreevent` must redden a
#      sample-path row and a recovery-path row TOGETHER. Mutant `zeroage`
#      catches undated success/failure evidence being reported as current on
#      either query path. Reach is derived over the gate's enumerated mutants,
#      each declaring the rows it MUST redden (reddened sets overlap, so membership is
#      what makes a red build attributable); the unreached rows must equal the
#      two declared fixture-adequacy preconditions. Mock gh only, and "no
#      network" is STRUCTURAL — the shim's resolution is verified after chmod
#      and EXITS, since `mock-org` is a real GitHub organization (#348).
#
#  45. release-lag tests (scripts/test-release-lag.sh) — the actual read-only
#      checker against fixed-clock Git histories: parsed first-parent release
#      boundaries, normalized runtime payload, uninterrupted per-path age and
#      revert resets, inclusive due threshold, and unverified missing evidence.
#      Fixture due exits are asserted, never propagated as a release reminder
#      into required ci. No network or real repository mutation.
#
#  46. fire-watch block tests (scripts/test-fire-watch-block.sh) — the contract
#      between the daily-fire-watch routine's Slack post and `work-fire-watch`.
#      The consumer was first written against THIS repo's whats-on-fire template
#      and would have matched zero real posts: the routine runs the flattened
#      copy in routines, and what Slack delivers is mrkdwn that changes
#      prose shape day to day. So the consumer reads only a fenced
#      `fire-watch-v1` block, and this gate pins the sentinels both homes must
#      spell identically (block name, channel id, the poster's Slack user id —
#      the routine posts through a user-scoped connector, so "bot only" can
#      never match — and the rendered first line WITHOUT the Markdown `# `),
#      plus the handle grammar's single home and the slug rule, run against the
#      org's real workflow names, the selection rule (newest post, never page past),
#      and that work-recommendations reads the author association through
#      `gh api` (never `gh issue/pr view`, which lacks the field). Source-level,
#      no network.
#
#  47. model-tier tests (scripts/test-model-tiers.sh) — every dispatched agent
#      runs at a harness-neutral tier (astra/sol/terra/luna) bound inline at its
#      dispatch site, and every binding agrees with docs/MODEL-TIERS.md. Model
#      choice used to be implicit — inherited, or pinned to Opus on a premise
#      that stopped holding — and a removed binding breaks nothing visible, so
#      presence is asserted too. Mutation-proven with a control copy. Source-
#      level, no network.
#
#  48. testflight JWT tests (scripts/test-testflight-jwt.sh) — the App Store
#      Connect ES256 signer is openssl only and fails closed. The PyJWT branch
#      it replaced told operators to `pip3 install pyjwt`, which a PEP 668
#      Python refuses, and made the signing code depend on the machine. Fixed
#      DER vectors cover the 33-byte and short R and S a random signature
#      rarely produces; a bad key or malformed DER must return non-zero with no
#      token; a throwaway P-256 key round-trips tokens through `openssl dgst
#      -verify`, with a tampered-signature control; source guards keep one
#      signer and no Python. Mutation-proven (header lists the mutations).
#      Missing tools SKIP locally and fail in CI. No gh, no network.
#
#  49. board-snapshot call tests (scripts/test-board-snapshot-calls.sh) — every
#      `board-snapshot.sh` command in a fenced block of tracked Markdown uses
#      the script's one interface, PROJECT_NUMBER= and OWNER= in the
#      environment, and passes no flag (it parses none; three SKILL.md snippets
#      passed --number/--owner and board mode failed closed on every card,
#      issue #448). Header defines "any flag" and lists the mutants. Source-
#      level, no gh, no network.
#
#  50. plugin-root-paragraph tests (scripts/test-plugin-root-paragraph.sh) —
#      omp neither substitutes the plugin-root token in a skill body nor exports
#      it, so every SKILL.md that carries the token also carries one paragraph
#      before the first fenced command that uses it telling the agent to derive the root from the
#      `[Skill file: ...]` line and not to search (issue #454). The paragraph
#      must never spell the token: Claude Code substitutes it anywhere in a
#      SKILL.md, garbling the paragraph. The gate derives the checked set, pins
#      the paragraph text, its placement and its token-freedom, and is
#      mutation-proven against scratch fixtures. No gh, no network.
#
#  51. isolation-contract tests (scripts/test-isolation-contract.sh) — take-it
#      confirms the isolation contract before a parallel dispatch: Claude
#      Code's `isolation: "worktree"` is the confirmation and stays unchanged;
#      on omp it reads three settings, probes one worker, records the outcome,
#      verifies pushes with a fresh ls-remote, and goes serial (with a
#      branch-from-default worker step) or stops with `isolation unconfirmed`,
#      never parallel on a shared tree (issue #451). dispatch-ready §5 does the
#      same per tick but is stop-only (no serial mode) and ends a stopped loop
#      through STALLED (issue #452). Also pins the design
#      doc's corrected claims. Mutation-proven (header lists the mutants).
#      Source-level, no omp, no gh, no network.
#
#  52. config-fallback-paragraph tests (scripts/test-config-fallback-paragraph.sh) —
#      the "Unrun config line" paragraph is in the four conservative-mode skills
#      (send-it, survey-work, groom-backlog, tidy-repo), exact and directly under
#      the injected config line, and in none of the four NO_CONFIG stoppers; the
#      set of skills with a config line is derived and must equal those eight
#      (issue #463). Mutation-proven (header lists the mutants). No gh, no network.
#
# All gates run even after a failure (accumulate-and-report, same pattern as
# check-frontmatter.sh). Exit 0 = all pass, 1 = any fail. Tools that are not
# installed locally SKIP with a note — CI still enforces them.
set -uo pipefail

MARKDOWNLINT_PKG="markdownlint-cli2@0.18.1"
ACTIONLINT_IMAGE="rhysd/actionlint:1.7.7"

FIX=0
case "${1:-}" in
    --fix) FIX=1 ;;
    "") ;;
    *) echo "usage: bash scripts/preflight.sh [--fix]" >&2; exit 64 ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$ROOT" ] && { echo "preflight: not in a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1

fail=0
pass() { echo "PASS  $1" >&2; }
# Gates are non-interactive by contract, and one of them harvests with `awk`,
# which reads STDIN when it is handed no file operands. A regression there should
# redden this run rather than hang it — measured: exactly that hung a run for ten
# minutes before the gate grew its own `</dev/null` (issue #263).
exec </dev/null
failed() { echo "FAIL  $1" >&2; fail=1; }
skip() { echo "SKIP  $1" >&2; }

# --- 1. shellcheck ----------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    sh_files=$(git ls-files '*.sh')
    if [ -z "$sh_files" ]; then
        pass "shellcheck (no *.sh files)"
    elif echo "$sh_files" | xargs shellcheck -S warning; then
        pass "shellcheck -S warning"
    else
        failed "shellcheck -S warning"
    fi
    # SC2006 IS A SEPARATE PASS BECAUSE IT IS `style`, AND THE ONE ABOVE STOPS
    # AT `warning`. That severity gap is the whole reason a real defect shipped
    # twice: an UNESCAPED backtick inside a double-quoted test label is command
    # substitution, so `dest_case "a `which` clause …"` runs `which` and prints
    # the label with its identifying word eaten. It happened in
    # test-sentry-verification.sh, was documented in CLAUDE.md, and then
    # happened again in the same file — three labels, executing `which`, `that`
    # and `where`, which is how a mutation of one rule produced three
    # indistinguishable FAIL lines in the gate that exists to say which rule
    # broke. Prose did not stop the recurrence; this does.
    #
    # A BESPOKE GREP WAS TRIED AND REJECTED: distinguishing a backtick inside a
    # double-quoted argument from one inside a single-quoted string is a
    # quoting-context question, and a hand-rolled scan of this repo produced 3
    # true positives against 7 false ones. shellcheck already parses the shell,
    # so it answers exactly that question — measured on a two-line fixture, the
    # unescaped form is flagged and the escaped form is not.
    #
    # NEITHER ONE-PASS SHORTCUT WORKS, both measured, so that the next person
    # weighing this does not re-derive them. Adding `--include=SC2006` to the
    # pass above reports NOTHING: the severity filter still applies to an
    # included check, so `-S warning` suppresses a `style` rule even when it is
    # named. And dropping the tree-wide run to `-S style` yields 208 findings
    # across 11 rules on this tree, which is not adoptable today. Two passes is
    # the cheap option, not the lazy one.
    #
    # COST, measured: the SC2006 pass is ~5s against a ~48s preflight, about
    # 11%. It re-parses every tracked *.sh, which is the price of shellcheck
    # having no way to ask one question of an existing parse.
    #
    # Bare `xargs` here and in the pass above ASSUMES no tracked `*.sh` path
    # contains whitespace — verified, none today. (A count was written here and
    # went stale the next time a script was added; the assumption is what
    # matters, and it is re-checked by the run itself failing loudly.) If that
    # ever changes both call sites need `-0` with `git ls-files -z`.
    if [ -n "$sh_files" ]; then
        if echo "$sh_files" | xargs shellcheck --include=SC2006; then
            pass "shellcheck SC2006 (unescaped backticks in strings)"
        else
            failed "shellcheck SC2006 (unescaped backticks in strings)"
        fi
    fi
else
    skip "shellcheck (not installed — CI still enforces)"
fi

# --- 2. frontmatter ---------------------------------------------------------
if bash scripts/check-frontmatter.sh; then
    pass "frontmatter sanity"
else
    failed "frontmatter sanity"
fi

# --- 3. no bare positional tokens in Skill-args substitution surfaces -------
# SKILL.md bodies (and the config templates that render into consumer repos)
# get $1-$9/$ARGUMENTS substituted when the skill is invoked with args — a
# literal $1 in a snippet is corrupted at render time. references/ docs and
# scripts/ (including this one) are not substituted.
#
# The template pathspec is asserted non-empty FIRST. A pathspec that matches
# nothing makes `git ls-files` emit no paths, so the guard would still pass
# while silently covering nothing — which is exactly what a rename of the
# generator directory used to cause. Fail loudly instead.
POSITIONAL_TEMPLATE_GLOB='skills/setup-config/references/templates/*'
if [ -z "$(git ls-files "$POSITIONAL_TEMPLATE_GLOB")" ]; then
    failed "positional-token guard — template pathspec '$POSITIONAL_TEMPLATE_GLOB' matched no tracked files (renamed or moved? the guard would silently cover nothing)"
else
    # shellcheck disable=SC2016  # the regex is a literal, not a missed expansion
    if git ls-files 'skills/*/SKILL.md' '.claude/skills/*/SKILL.md' "$POSITIONAL_TEMPLATE_GLOB" \
        | xargs grep -nE '\$([0-9]|@|\*)'; then
        failed "positional-token guard — use cut -f1/%(format) idioms or move the snippet to references/ or scripts/ (issue #39)"
    else
        pass "positional-token guard"
    fi
fi

# --- 4. no legacy skill-name residue -----------------------------------------
# The whole generator family was renamed to setup-* in issue #120:
#   create-dev-workflows -> refresh-skills (0.9.0)
#   refresh-skills -> refresh-skills (2026.7.22)
#   refresh-skills -> setup-config (issue #121)
#   refresh-hooks -> setup-hooks (issue #122)
#   refresh-deps  -> setup-deps  (issue #123)
# Every superseded name may appear only in the sanctioned backward-compat
# mentions — the ownership matchers still have to RECOGNISE artifacts produced
# under the older names, and those markers are committed inside every consumer
# repo. Anything else is a stale reference that would confuse a render or send
# a reader to a dead path.
#
# Exclusions are PER NAME, not one shared union: a name is sanctioned in
# exactly the files that must still spell it out. A union list would let a
# stale `refresh-deps` hide in a file sanctioned only for `refresh-skills`,
# which is the residue this guard exists to catch.
legacy_residue=0
for legacy in 'create-dev-workflows' 'refresh-sassydog-' 'refresh-skills' 'refresh-hooks' 'refresh-deps'; do
    case "$legacy" in
        refresh-skills)
            # setup-config's marker recognizer, the adopt/update walkthrough
            # that names the superseded producer, and CLAUDE.md's statement of
            # the same recognition rule.
            allow=(
                ':!skills/setup-config/SKILL.md'
                ':!skills/setup-config/references/update-mode.md'
                ':!CLAUDE.md'
                ':!scripts/preflight.sh'
            ) ;;
        refresh-hooks)
            # setup-hooks' generated-by ownership matcher + CLAUDE.md's
            # statement of it, plus the committed consumer artifacts that
            # PROVE the matcher still accepts this producer name (issue #133 —
            # the fixtures are verbatim upstream bytes; sanitising the name out
            # of them would defeat their entire purpose).
            allow=(
                ':!skills/setup-hooks/SKILL.md'
                ':!CLAUDE.md'
                ':!scripts/preflight.sh'
                ':!scripts/fixtures/legacy-markers/'
            ) ;;
        refresh-deps)
            # setup-deps' generated-by ownership matcher + the committed
            # consumer artifacts proving the matcher accepts it (issue #133).
            allow=(
                ':!skills/setup-deps/SKILL.md'
                ':!scripts/preflight.sh'
                ':!scripts/fixtures/legacy-markers/'
            ) ;;
        *)
            # 'refresh-sassydog-' also appears verbatim inside the committed
            # consumer hook fixtures (issue #133).
            allow=(
                ':!skills/setup-config/references/update-mode.md'
                ':!skills/setup-config/references/migrate-mode.md'
                ':!skills/setup-config/SKILL.md'
                ':!skills/setup-deps/SKILL.md'
                ':!skills/setup-hooks/SKILL.md'
                ':!CLAUDE.md'
                ':!scripts/preflight.sh'
                ':!scripts/fixtures/legacy-markers/'
            ) ;;
    esac
    if git grep -l "$legacy" -- "${allow[@]}"; then
        failed "legacy-name guard — '$legacy' outside the sanctioned back-compat files"
        legacy_residue=1
    fi
done

# The plugin itself renamed too: ai-agent-skills -> sassy-dog, the marketplace
# sassy-dog-skills -> skills (issue #71), and the GitHub repo
# ai-agent-skills -> skills (issue #72). The old plugin name may
# appear ONLY where it is still load-bearing:
#   - README.md — the one historical line recording the #71 rename
#   - CLAUDE.md — the marker-recognition rule: recognizers must accept
#     pre-rename 'generated-by: ai-agent-skills:*' markers
#   - skills/setup-deps/SKILL.md, skills/setup-hooks/SKILL.md — those
#     generated-by recognizers themselves. Their markers are committed inside
#     every consumer repo, so each must also keep naming its own superseded
#     producers (setup-hooks accepts refresh-hooks and refresh-sassydog-hooks,
#     see issue #122; setup-deps accepts refresh-deps and refresh-sassydog-deps,
#     see issue #123) — a narrower matcher would silently treat a pre-rename
#     consumer file as hand-written.
#   - scripts/fixtures/legacy-markers/ — real consumer artifacts still stamped
#     with the pre-rename namespace, committed verbatim so the matchers are
#     proven against a genuine older-plugin file rather than a synthetic
#     pattern we wrote ourselves (issue #133)
#   - this script (the guard itself)
if git grep -l 'ai-agent-skills' -- \
    ':!README.md' \
    ':!CLAUDE.md' \
    ':!skills/setup-deps/SKILL.md' \
    ':!skills/setup-hooks/SKILL.md' \
    ':!scripts/preflight.sh' \
    ':!scripts/fixtures/legacy-markers/'; then
    failed "legacy-name guard — 'ai-agent-skills' outside the sanctioned files (plugin renamed to sassy-dog, issue #71)"
    legacy_residue=1
fi

# The old marketplace name may appear only in the one-time re-add
# instructions (which must name it to remove it) and this script.
if git grep -l 'sassy-dog-skills' -- \
    ':!README.md' \
    ':!scripts/preflight.sh'; then
    failed "legacy-name guard — 'sassy-dog-skills' outside the sanctioned files (marketplace renamed to skills, issue #71)"
    legacy_residue=1
fi

# Four workflow skills lost the -it suffix in the collection-scope naming
# sweep: plate-it -> survey-work, groom-it -> groom-backlog (nee fill-it),
# drain-it -> dispatch-ready, clean-it -> tidy-repo. Each legacy name may
# appear ONLY where it is still load-bearing:
#   - the renamed skill's own SKILL.md — legacy trigger phrases, the
#     "Formerly" note, and the stranded-pre-rename-config detection
#   - skills/setup-config/SKILL.md + references/{migrate,update}-mode.md —
#     the rename map and legacy-artifact recognition (generated dirs and
#     pre-rename config filenames keep their old names in consumer repos)
#   - skills/whats-on-fire/SKILL.md — the blind-spot probe distinguishes a
#     legacy-named survey-work config from a missing one
#   - README.md — the "(formerly ...)" annotations
#   - this script (the guard itself)
for legacy in 'plate-it' 'groom-it' 'drain-it' 'clean-it'; do
    if git grep -l "$legacy" -- \
        ':!skills/survey-work/SKILL.md' \
        ':!skills/groom-backlog/SKILL.md' \
        ':!skills/dispatch-ready/SKILL.md' \
        ':!skills/tidy-repo/SKILL.md' \
        ':!skills/setup-config/SKILL.md' \
        ':!skills/setup-config/references/migrate-mode.md' \
        ':!skills/setup-config/references/update-mode.md' \
        ':!skills/whats-on-fire/SKILL.md' \
        ':!README.md' \
        ':!scripts/preflight.sh'; then
        failed "legacy-name guard — '$legacy' outside the sanctioned back-compat files (naming sweep: collection-scoped skills lost -it)"
        legacy_residue=1
    fi
done

[ "$legacy_residue" -eq 0 ] && pass "legacy-name guard"

# --- 5. plugin manifests -----------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    if jq -e . .claude-plugin/plugin.json .claude-plugin/marketplace.json >/dev/null; then
        pass "plugin manifests valid JSON"

        # Version-of-record guard (issue #31; docs/VERSIONING.md; org
        # Versioning spec §7 committed-manifest row). CalVer adoption is a
        # ONE-WAY RATCHET: a hand-rolled 0.x/1.x here reads as a permanent
        # downgrade to version-ordering consumers. Stamp via
        # scripts/stamp-version.sh, never by hand.
        plugin_version=$(jq -r '.version // empty' .claude-plugin/plugin.json)
        if echo "$plugin_version" | grep -qE '^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$'; then
            pass "plugin version is CalVer ($plugin_version)"
        else
            failed "plugin version '$plugin_version' is not CalVer (YYYY.M.P) — stamp via scripts/stamp-version.sh (docs/VERSIONING.md)"
        fi

        # One repo-wide CalVer: any plugins[].version in marketplace.json
        # must equal the version-of-record (per-plugin drift forbidden).
        if jq -e --arg v "$plugin_version" \
            '[.plugins[]? | select(has("version")) | .version == $v] | all' \
            .claude-plugin/marketplace.json >/dev/null; then
            pass "marketplace plugins[].version matches version-of-record"
        else
            failed "marketplace.json plugins[].version differs from plugin.json — one repo-wide CalVer; stamp via scripts/stamp-version.sh"
        fi
    else
        failed "plugin manifests valid JSON"
    fi
else
    skip "plugin manifests (jq not installed — CI still enforces)"
fi

# --- 6. versioning tests -------------------------------------------------------
if bash scripts/test-versioning.sh; then
    pass "versioning tests (scripts/test-versioning.sh)"
else
    failed "versioning tests (scripts/test-versioning.sh)"
fi

# --- 7. ownership-matcher tests -----------------------------------------------
if bash scripts/test-ownership-matchers.sh; then
    pass "ownership-matcher tests (scripts/test-ownership-matchers.sh)"
else
    failed "ownership-matcher tests (scripts/test-ownership-matchers.sh)"
fi

# --- 8. label-taxonomy tests ---------------------------------------------------
# Definitions + a mock gh. #158 deliberately kept align-labels.sh out of CI
# because it MUTATES other repos — this gate runs neither applying mode, only
# the cross-set colour check (`--collisions`, which needs no repo and no
# network) and issue-claim.sh's reconcile logic against a recorded mock.
if bash scripts/test-label-taxonomy.sh; then
    pass "label-taxonomy tests (scripts/test-label-taxonomy.sh)"
else
    failed "label-taxonomy tests (scripts/test-label-taxonomy.sh)"
fi

# --- 9. label-migrate tests ----------------------------------------------------
# Same rule as gate 8, one notch more dangerous: align-labels.sh's migrate mode
# DELETES labels in other repos, and a delete strips the label from every issue
# carrying it unrecoverably. So CI runs the mode's PROOF, never the mode — a
# mock gh that records writes, plus a source-level invariant (one delete call
# site, inside the gate, downstream of the re-query) and a mutation that
# neuters the gate to show the withheld delete was withheld BY it (issue #163).
if bash scripts/test-label-migrate.sh; then
    pass "label-migrate tests (scripts/test-label-migrate.sh)"
else
    failed "label-migrate tests (scripts/test-label-migrate.sh)"
fi

# --- 10. dependabot-render tests -----------------------------------------------
# setup-deps stopped being valid-by-construction when its template gained a
# per-(ecosystem, directory) repeat (issue #169), so the render is checked
# dynamically instead — here against recorded consumer file lists, and at run
# time by validate-dependabot.sh against the repo being written into. The gate
# also asserts the OLD shape fails: a validator that accepts every lane
# collapsed onto "/" proves nothing.
if bash scripts/test-dependabot-render.sh; then
    pass "dependabot-render tests (scripts/test-dependabot-render.sh)"
else
    failed "dependabot-render tests (scripts/test-dependabot-render.sh)"
fi

# --- 11. detect-hook-stack tests -----------------------------------------------
# The bug this pins (issue #172) is size-dependent: `has_tracked` returned the
# writer's SIGPIPE 141 rather than "match" once the match list overran the pipe
# buffer, so the five affected detections under-reported on exactly the largest
# repos and the render dropped a route with nothing in the output to say so. A
# small fixture proves nothing here, so the test builds a 20k-path index-only
# repo and asserts BOTH that the pre-fix shape still fails on it (else the test
# has gone vacuous) and that the shipped probe does not.
if bash scripts/test-detect-hook-stack.sh; then
    pass "detect-hook-stack tests (scripts/test-detect-hook-stack.sh)"
else
    failed "detect-hook-stack tests (scripts/test-detect-hook-stack.sh)"
fi

# --- 12. visibility preconditions -------------------------------------------
# skills went public on 2026-08-12 and its auto-merge workflow was
# deleted rather than re-credentialed (#177). Without this gate the next
# setup-deps run would put it straight back: a merge gate is present, and the
# gate was the only precondition the skill checked. The failure it reintroduces
# is invisible at render time and surfaces elsewhere, later, looking unrelated.
# #186 widened this from the auto-merge workflow to every template that mints
# the App token, after the same failure was found open through two other doors.
if bash scripts/test-visibility-preconditions.sh; then
    pass "visibility precondition tests (scripts/test-visibility-preconditions.sh)"
else
    failed "visibility precondition tests (scripts/test-visibility-preconditions.sh)"
fi

# --- 13. verify-issue-refs tests ---------------------------------------------
if bash scripts/test-verify-issue-refs.sh; then
    pass "verify-issue-refs tests (scripts/test-verify-issue-refs.sh)"
else
    failed "verify-issue-refs tests (scripts/test-verify-issue-refs.sh)"
fi

# --- 14. stale-issues tests ---------------------------------------------------
# The tracking-parent-complete detector is the only thing that notices a
# finished epic, so every way it can be wrong is silent: a miss looks like a
# clean repo, a prefix collision points a human at live work, and a truncated
# pull returns the empty list a clean pull returns. The prefix fixture is
# mutation-proved live rather than trusted. Mock gh only: no repo, no network.
if bash scripts/test-stale-issues.sh; then
    pass "stale-issues tests (scripts/test-stale-issues.sh)"
else
    failed "stale-issues tests (scripts/test-stale-issues.sh)"
fi

# --- 15. teardown-args tests ---------------------------------------------------
# Every wrong answer here is quiet: a flag taken for a worktree path fails in
# the middle of a run whose visible output is dominated by successful teardown
# lines, and the phase that never ran leaves no trace. So the gate asserts the
# phases are REACHED and that they did their work, and that a rejected argument
# list mutates nothing at all. Scratch repos + a mock gh: no real repo, no
# network, and the fixture is verified to be its own git root before teardown
# runs in it (teardown resolves its target by walking up from cwd).
if bash scripts/test-teardown-args.sh; then
    pass "teardown-args tests (scripts/test-teardown-args.sh)"
else
    failed "teardown-args tests (scripts/test-teardown-args.sh)"
fi

# --- 19. scanning-states tests -----------------------------------------------
# Every failure mode here emits well-formed JSON carrying a plausible number, so
# nothing downstream can tell a wrong answer from a right one. Mock gh only: no
# repo, no network.
if bash scripts/test-scanning-states.sh; then
    pass "scanning-states tests (scripts/test-scanning-states.sh)"
else
    failed "scanning-states tests (scripts/test-scanning-states.sh)"
fi

# --- 20. sentry-verification tests -------------------------------------------
# The decisions under test are prose an agent follows, not code a script runs, so
# the gate reads the instructions themselves. Every failure it guards is silent by
# construction — a mis-configured Sentry project produces a plate that looks
# complete in both repos, and a `none` form flattened to symmetry produces a plate
# that looks complete on a repo whose Sentry nothing is watching. Four decisions:
# #213's culprit verification, `sentry: none` as the contract's first documented
# exception, #261's deliberately ASYMMETRIC four-key `none`, and #268's
# carry-forward split — the `none` carve-out covers three keys and NOT `sentry:`,
# asserted at all four sites that state it. The run prints its own assertion
# count, so no inventory number here can go stale.
# Eight tracked files: no gh, no network.
if bash scripts/test-sentry-verification.sh; then
    pass "sentry-verification tests (scripts/test-sentry-verification.sh)"
else
    failed "sentry-verification tests (scripts/test-sentry-verification.sh)"
fi

# --- 21. sentry-counts tests -------------------------------------------------
# Also prose, and the failure it guards is a false CLEAN rather than a false
# alarm: an under-reported count does not look wrong, it looks quiet. Reads four
# tracked files; no gh, no network, no Sentry call.
if bash scripts/test-sentry-counts.sh; then
    pass "sentry-counts tests (scripts/test-sentry-counts.sh)"
else
    failed "sentry-counts tests (scripts/test-sentry-counts.sh)"
fi

# --- 22. security-listing tests ----------------------------------------------
# Also prose, and also a false CLEAN rather than a false alarm: the issue was
# counted, so the report looked complete while naming nothing. Two tracked
# files; no gh, no network.
if bash scripts/test-security-listing.sh; then
    pass "security-listing tests (scripts/test-security-listing.sh)"
else
    failed "security-listing tests (scripts/test-security-listing.sh)"
fi

# --- 16. markdownlint --------------------------------------------------------
if command -v npx >/dev/null 2>&1; then
    if [ "$FIX" = "1" ]; then
        npx -y "$MARKDOWNLINT_PKG" --fix "**/*.md" >/dev/null 2>&1 || true
    fi
    if md_out=$(npx -y "$MARKDOWNLINT_PKG" "**/*.md" 2>&1); then
        pass "markdownlint ($MARKDOWNLINT_PKG)"
    else
        echo "$md_out" | grep -v '^npm' | tail -30 >&2
        failed "markdownlint ($MARKDOWNLINT_PKG)"
    fi
else
    skip "markdownlint (npx not installed — CI still enforces)"
fi

# --- 17. actionlint (best-effort locally; CI runs its own dockerized step) ---
if [ "${CI:-}" = "true" ]; then
    skip "actionlint (separate CI step)"
elif command -v actionlint >/dev/null 2>&1; then
    if actionlint -color; then pass "actionlint"; else failed "actionlint"; fi
elif docker info >/dev/null 2>&1; then
    if docker run --rm -v "$PWD:/repo" --workdir /repo "$ACTIONLINT_IMAGE" -color; then
        pass "actionlint (docker)"
    else
        failed "actionlint (docker)"
    fi
else
    skip "actionlint (no binary or docker — CI still enforces)"
fi

# --- 18. config-injection blocks must announce CONFIG_SOURCE ------------------
# Two vacuous-green guards, because this gate's whole output is an absence and
# both ways of covering nothing look identical to a pass: the pathspec matching
# no tracked files (a directory rename), and no file carrying an injection block
# at all (the block reworded out from under the regex).
CONFIG_SOURCE_PATHSPEC=('skills/*/SKILL.md' 'skills/setup-config/references/config-contract.md')
CONFIG_INJECT_RE='^!`.*\.claude/sassy-dog/'
config_source_files=$(git ls-files "${CONFIG_SOURCE_PATHSPEC[@]}")
if [ -z "$config_source_files" ]; then
    failed "config-source guard — pathspec '${CONFIG_SOURCE_PATHSPEC[*]}' matched no tracked files (renamed or moved? the guard would silently cover nothing)"
else
    config_inject_files=$(echo "$config_source_files" | xargs grep -l "$CONFIG_INJECT_RE" 2>/dev/null)
    if [ -z "$config_inject_files" ]; then
        failed "config-source guard — no tracked file carries a .claude/sassy-dog injection block (reworded? the guard would silently cover nothing)"
    else
        # Line-scoped: the §1 reconciliation prose also mentions CONFIG_SOURCE,
        # so only the injection LINE itself is evidence that it still announces.
        config_source_bad=$(echo "$config_inject_files" | xargs grep -n "$CONFIG_INJECT_RE" | grep -v 'CONFIG_SOURCE')
        if [ -n "$config_source_bad" ]; then
            echo "$config_source_bad" >&2
            failed "config-source guard — the injection blocks above do not echo CONFIG_SOURCE, so a consumer cannot tell whose config it was handed (see setup-config/references/config-contract.md)"
        else
            pass "config-source guard ($(echo "$config_inject_files" | wc -l | tr -d ' ') injection blocks)"
        fi
    fi
fi

# --- 23. artifact-guard tests -------------------------------------------------
if bash scripts/test-artifact-guard.sh; then
    pass "artifact-guard tests (scripts/test-artifact-guard.sh)"
else
    failed "artifact-guard tests (scripts/test-artifact-guard.sh)"
fi

# --- 24. doc-reconciliation tests --------------------------------------------
# Gates the instruction, not staleness — see the header note. The sub-agent
# briefs are the half that gets missed. Three tracked files; no gh, no network.
if bash scripts/test-doc-reconciliation.sh; then
    pass "doc-reconciliation tests (scripts/test-doc-reconciliation.sh)"
else
    failed "doc-reconciliation tests (scripts/test-doc-reconciliation.sh)"
fi

# --- 25. poll-queue-eject tests ----------------------------------------------
# The verdict under test is terminal and loud, and its JSON twin is silent — a
# false `ejected` on a merged PR sends a human to eject recovery and a
# coordinator down the recovery branch with no warning at all. Section 1 also
# carries the "no per-PR counter" decision: the run must reach the global
# ceiling rather than resolve early. Mock gh: no repo, no network.
if bash scripts/test-poll-queue-eject.sh; then
    pass "poll-queue-eject tests (scripts/test-poll-queue-eject.sh)"
else
    failed "poll-queue-eject tests (scripts/test-poll-queue-eject.sh)"
fi

# --- 26. template-actionlint tests -------------------------------------------
# Same CI split as gate 17, for a mechanical reason: ci.yml puts the pinned
# actionlint on $GITHUB_PATH, which reaches only the steps AFTER the install —
# and this script runs before it. So CI owns this gate as its own step; here it
# is the local half. The script itself hard-FAILS rather than skips when
# CI=true and actionlint is missing, so the CI step cannot quietly no-op.
if [ "${CI:-}" = "true" ]; then
    skip "template-actionlint (separate CI step)"
elif bash scripts/test-template-actionlint.sh; then
    pass "template-actionlint tests (scripts/test-template-actionlint.sh)"
else
    failed "template-actionlint tests (scripts/test-template-actionlint.sh)"
fi

# --- 27. review-orchestrator allowlist tests ---------------------------------
# The defect this catches is invisible to the author who ships it: `react-typescript-engineer`
# and `iac-cloud-architect` exist as USER-LEVEL agents on a typical developer's
# machine, so an orchestrator dispatch (or a `review_surfaces:` example) naming
# one passes every other gate, works when its author tests it, and fails only in
# a consumer repo. A file-listing comparison against agents/, in the shape of
# gate 8's no-third-copy guard. No gh, no network.
if bash scripts/test-review-orchestrator-allowlist.sh; then
    pass "review-orchestrator allowlist tests (scripts/test-review-orchestrator-allowlist.sh)"
else
    failed "review-orchestrator allowlist tests (scripts/test-review-orchestrator-allowlist.sh)"
fi

# --- 28. gotcha-claims tests --------------------------------------------------
# The verifier's whole contract is "unknown is held": a claim citing #N reaches
# an issue body only when its asserted state was confirmed. So the fixture that
# matters is the stale one, and the failure mode that matters is degrading to a
# skip when gh is missing. Mock gh, symlink-sandboxed PATH: no repo, no network.
if bash scripts/test-gotcha-claims.sh; then
    pass "gotcha-claims tests (scripts/test-gotcha-claims.sh)"
else
    failed "gotcha-claims tests (scripts/test-gotcha-claims.sh)"
fi

# --- 29. review-gate decision tests -------------------------------------------
# The prose decisions from #237, #248, #273 and #280 that each read as drift:
# the gate is unconditional (and the SKIPPED line survives the default),
# `review_agent` is deliberately not presence-is-the-toggle, the opt-out is
# `skip` and not `none`, `review_site` is configured rather than derived, a
# Blocking finding blocks the merge with exactly one redispatch, a review report
# is RETURNED as the agent's final text — with a lost one held as its own
# outcome rather than merged past or folded into the SKIPPED line — and the
# reviewer -> orchestrator hop is bound the same way, with the fan-out brief
# carrying a slot to pass the contract down. #385 extends decisions 5/6 with
# bounded parent recovery, stale-result rejection and actual-caller accounting;
# it does not add a decision or a read-set member. Must-not-exist checks run
# flattened — this repo hard-wraps. This banner deliberately carries NO counts:
# it is out of reach of both windows the count re-derivation checks, so a count
# here is one
# nothing holds. The counts live in the gate list above, where the gate
# re-derives them.
if bash scripts/test-review-gate-decisions.sh; then
    pass "review-gate decision tests (scripts/test-review-gate-decisions.sh)"
else
    failed "review-gate decision tests (scripts/test-review-gate-decisions.sh)"
fi

# --- 30. pipefail-grep guard --------------------------------------------------
# Source-level, and the one gate whose subject is the OTHER gates: a `| grep -q`
# under pipefail reports a match as a miss once the writer outruns the pipe
# buffer, which is how PR #252's mutation proofs came back `undetected`. The
# printf/echo allowlist is the settled rule (#256) and the guard's header
# carries both its rationale and its known limitation — read that before
# widening or narrowing it. Tracked fixtures, no gh, no network.
if bash scripts/test-pipefail-grep.sh; then
    pass "pipefail-grep guard (scripts/test-pipefail-grep.sh)"
else
    failed "pipefail-grep guard (scripts/test-pipefail-grep.sh)"
fi

# --- 31. claim-lifecycle tests -----------------------------------------------
# The failure it guards is a write on somebody else's issue, so the gate
# measures writes: a mock gh records every mutating call and each case is judged
# on whether a --remove-assignee appeared. Its two negatives are the fixes #281
# rejected — a symmetric `release`, and aligning dispatch-ready's §3/§4 — and
# both read as tidying, which is why they are asserted rather than described.
# Mock gh only: no repo, no network.
if bash scripts/test-claim-lifecycle.sh; then
    pass "claim-lifecycle tests (scripts/test-claim-lifecycle.sh)"
else
    failed "claim-lifecycle tests (scripts/test-claim-lifecycle.sh)"
fi

# --- 32. drain terminal-state tests -------------------------------------------
# Source-level: §7 IS the instruction the loop follows, so there is nothing to
# run. It pins the state neither terminal state covered (#282), the §2
# enumeration the held set depends on — on BOTH the board and boardless paths,
# and without which the tick sees no PR at all and announces a false DRAIN
# COMPLETE — the one-set invariant tying COMPLETE's veto to that same set, the
# discriminator and its held-by-default last row, the non-empty held set that
# stops STALLED being satisfied vacuously, and the four things the fix must NOT
# have moved: both carve-outs, COMPLETE and its veto, the two-tick confirmation,
# and the single stop path. It also pins §2's CONFLICTING demotion (#290) —
# demote on sight, demote ONCE, the failed-write outcome and the §4
# carry-forward — without which a conflicted PR holds in-flight open forever and
# no terminal state can fire. It pins the FOURTH terminal state too (#342):
# a Ready column held entirely by §4's Site filter ends the loop at DRAIN
# DEFERRED, naming the site and taking COMPLETE's stop path, never as a stall the
# operator is told to resolve — with the discrimination pinned the other way as
# well, since a held set carrying anything else is STALLED still. Bound in three
# layers — canon, inventory, consumption — each added after a review defeated the
# one before it. Three tracked files — `dispatch-ready/SKILL.md`,
# `issue-claim.sh` and `merge-shepherd.sh` — no gh, no network.
if bash scripts/test-drain-terminal-states.sh; then
    pass "drain terminal-state tests (scripts/test-drain-terminal-states.sh)"
else
    failed "drain terminal-state tests (scripts/test-drain-terminal-states.sh)"
fi

# --- 33. audit lost-reviewer tests --------------------------------------------
# Source-level: the two assess-it documents ARE the instruction an audit run
# follows, so there is nothing to execute. It pins the per-domain outcome ledger
# (#284), the rule that a domain which did not return is never scored clean, the
# ledger's POSITION before the approval prompt — the harm lands at the preview,
# not at the report — and the half that stops the fix overshooting: a dark
# domain is surfaced, never a veto on filing. Bound like gate 32 in three layers
# (canon, inventory, consumption) over both files whole, with the fences
# included because Phase 4's ```text fence is the coverage block the run prints.
# No prose veto, deliberately; the only must-not-exist checks are the #283
# residue note's own literals. `agents/pr-review-orchestrator.md` is read for
# one fact only — gate 29 owns that file, and that double-pin is deliberate,
# "the sibling survives untouched" being an acceptance item of #284 itself.
# It pins the PREVIEW half only: the coverage record does not yet reach the
# filed Epic, which is issue #294 and is stated rather than claimed. Three
# tracked files, no gh, no network.
if bash scripts/test-audit-lost-reviewer.sh; then
    pass "audit lost-reviewer tests (scripts/test-audit-lost-reviewer.sh)"
else
    failed "audit lost-reviewer tests (scripts/test-audit-lost-reviewer.sh)"
fi

# --- 34. platform-health-probe tests -------------------------------------------
# Behavioural where the harm is behavioural and source-level where the rule is
# prose. The probe answers "is the platform degraded, or is this a real defect?"
# with one of four verdicts (#285), and every way of being wrong is silent:
# collapsing one toward `healthy` converts an unknown into a confident wrong
# answer, and letting one reach a merge/hold/block/redispatch decision turns an
# outage into changed behaviour instead of a changed explanation. So the four
# verdicts are exercised against a mock gh AND a mock curl, both collapse
# directions are mutation-proved, and never-a-gate is asserted structurally —
# every verdict exits 0, no sibling script names the probe (sibling list held as
# an equality against the directory), and the SKILL.md decision sections are
# checked SECTION-scoped, because a whole-file grep is satisfied by the probe's
# own section. No repo, no network.
if bash scripts/test-platform-health-probe.sh; then
    pass "platform-health-probe tests (scripts/test-platform-health-probe.sh)"
else
    failed "platform-health-probe tests (scripts/test-platform-health-probe.sh)"
fi

# --- 35. stale-cache diagnostic ------------------------------------------------
# The stale-cache diagnostic and the no-auto-stamp record (issues #296, #301).
# NONE of #301's three decisions was pinned by anything, and the idiom it
# deleted — `ls` the cache directory and compare the version STRING — was itself
# shipped deliberately in #12 and survived until #296 measured it giving the
# wrong answer: cache and clone both at `2026.8.100`, with 18 skill files and
# all ten agents differing. A documented diagnostic that returns "current" on a
# stale cache is worse than none, because a reader who runs it stops looking.
# Its assertions on the compare block are SCOPED TO THE CODE FENCE, not the
# file: checking the flattened README for `2>&1`, `[ -d ` and the directory
# names passed on a README whose code block had each of them removed, because
# the paragraph underneath explains every one by name — a presence check
# satisfied by the prose ABOUT a guard rather than by the guard. Three mutants
# proved that before the window existed. Two tracked files, no gh, no network.
if bash scripts/test-stale-cache-diagnostic.sh; then
    pass "stale-cache diagnostic tests (scripts/test-stale-cache-diagnostic.sh)"
else
    failed "stale-cache diagnostic tests (scripts/test-stale-cache-diagnostic.sh)"
fi

# --- 36. detect-capabilities tests ---------------------------------------------
# Behavioural: the probe's verdict is what a `setup-config` refresh acts on, so
# the shipped script is RUN inside eight throwaway git fixtures rather than
# grepped. `posthog` was a bare-word sweep of the tracked tree while #267 has
# consumers record `posthog: none` in a tracked config file, so the detector's
# only hit in a quiet tree was that answer and every refresh contradicted it
# (issue #317). Both greps now exclude `.claude/**` — agent configuration is
# never the product — and the sentry pathspec is symmetric on purpose. The grep
# lines are extracted from the script, so a reverted pathspec cannot pass on a
# transcribed copy; adequacy is asserted PER self-match fixture before either
# false verdict is trusted; a docs-only fixture holds the shipped caveat that a
# repo which merely documents the surface still trips detection; and a
# nested-`.claude` fixture records the root-anchoring decision. Mock `gh`, git
# isolated from global and system config, no network.
if bash scripts/test-detect-capabilities.sh; then
    pass "detect-capabilities tests (scripts/test-detect-capabilities.sh)"
else
    failed "detect-capabilities tests (scripts/test-detect-capabilities.sh)"
fi

# --- 37. plugin-root-in-references tests ---------------------------------------
# `${CLAUDE_PLUGIN_ROOT}` is substituted into SKILL.md at load time and nowhere
# else, so a reference doc writing it in a command resolves against `/` and
# exits 127. The header entry above carries the rest.
if bash scripts/test-plugin-root-in-references.sh; then
    pass "plugin-root-in-references tests (scripts/test-plugin-root-in-references.sh)"
else
    failed "plugin-root-in-references tests (scripts/test-plugin-root-in-references.sh)"
fi

# --- 38. file-or-link-issue tests -------------------------------------------
# The only write-capable issue path, which had no gate at all until #339: its
# marker-keyed idempotency was a read-after-write against GitHub's ASYNCHRONOUS
# search index, and a re-run seven seconds later filed a duplicate. Both stages
# are pinned — the search covers age, the `--search`-less direct listing covers
# recency — along with the discrimination half (a new marker still files, and a
# marker that is a PREFIX of an existing one is not swallowed on EITHER route)
# and the refusal to file when the scan could not be performed. Mock `gh`, no
# network, and no real issue is ever filed.
if bash scripts/test-file-or-link-issue.sh; then
    pass "file-or-link-issue tests (scripts/test-file-or-link-issue.sh)"
else
    failed "file-or-link-issue tests (scripts/test-file-or-link-issue.sh)"
fi

# --- 39. queue-snapshot site tests ---------------------------------------------
# The execution site comes from a `site:<name>` label, never the body: a body
# line can be quoted in prose and both issues introducing the contract quoted
# it. Rows cover present/absent in both buckets, folding, prefix-not-substring,
# an empty value, and the fail-safe rule — several labels are a conflict, never
# "any site". Mutant reach is derived from a baseline diff rather than asserted
# in prose. Mock `gh`, no repo, no network.
if bash scripts/test-queue-snapshot-site.sh; then
    pass "queue-snapshot site tests (scripts/test-queue-snapshot-site.sh)"
else
    failed "queue-snapshot site tests (scripts/test-queue-snapshot-site.sh)"
fi

# --- 40. site filter tests -----------------------------------------------------
# The two consumers of the execution-site declaration: dispatch-ready §4's Site
# filter and take-it's refusal before the claim. Rows cover the folded array
# match in every subject that spells it, the discrimination half (an unlabelled
# issue still proceeds, and membership proceeds however many members `sites`
# carries, in both consumers), fail-open in an unnamed checkout as its own
# question, the hold costing no redispatch budget and never demoting — pinned
# through the clause's terminator, so a qualifier cannot invert it — take-it's
# refusal preceding the claim by line number, and two rows that RUN
# `queue-snapshot.sh --sites-of`, the emitter the `board:` path and take-it
# need because the buckets are label-scoped. Mutant reach is derived from a
# baseline diff of the gate re-run against mutated copies; two guard mutants
# require the run to abort instead. No repo, no network.
if bash scripts/test-site-filter.sh; then
    pass "site filter tests (scripts/test-site-filter.sh)"
else
    failed "site filter tests (scripts/test-site-filter.sh)"
fi

# --- 41. execution-site surface tests ------------------------------------------
# The human half of the same contract: grooming applies the label and never a
# body line, an unlabelled issue renders on the plate exactly as before, several
# labels narrow rather than widen — every named checkout may take the issue, so
# neither surface refuses one nor reads it as "any site" — and the interview
# proposes a platform-derived name it never assumes. Both surfaces run
# `queue-snapshot.sh --sites-of` rather than paraphrasing the resolution rules,
# and the `uname -s` table stays in its one home under a case-insensitive ban.
# Mutant reach is derived from a baseline diff of the gate re-run against
# mutated copies; the rows no mutant reddens must be the empty declared set.
# Copies only, no repo, no network.
if bash scripts/test-execution-site-surface.sh; then
    pass "execution-site surface tests (scripts/test-execution-site-surface.sh)"
else
    failed "execution-site surface tests (scripts/test-execution-site-surface.sh)"
fi

if bash scripts/test-plugin-drift.sh; then
    pass "plugin drift tests (scripts/test-plugin-drift.sh)"
else
    failed "plugin drift tests (scripts/test-plugin-drift.sh)"
fi

# --- 43. tech-debt exclude tests -----------------------------------------------
# EXCLUDE_PATHSPECS reached git double-prefixed and silently excluded nothing.
# Rows read the OUTPUT SET, never an exit code — git never returns 128 here and
# the script swallows stderr. A doubled value is asserted to STILL LEAK: the
# strip is bounded on purpose, so a real config error is not silently repaired.
# Its sibling row covers the opposite direction: an element that strips to empty
# would re-prefix to a bare `:(exclude)`, which git reads as "exclude the entire
# tree", so it is dropped rather than passed through. The loop's `set -f` fence
# keeps a `**` a git pathspec instead of a shell glob, which is the only thing
# making the two spellings equivalent for glob values.
# Mutant reach is derived by re-running the matrix against seven mutated copies
# (nostrip greedy noguard noloop nobuiltin nofence norootlock);
# the unreached rows must equal the two declared fixture-adequacy preconditions.
if bash scripts/test-tech-debt-excludes.sh; then
    pass "tech-debt exclude tests (scripts/test-tech-debt-excludes.sh)"
else
    failed "tech-debt exclude tests (scripts/test-tech-debt-excludes.sh)"
fi

# --- 44. repo-signals recovery tests -------------------------------------------
# A null `default_branch_ci` is recovered by ONE narrow re-query, and all FIVE of
# its flags are pinned: `--event` is the half that does the work, `--status`
# stops a single in-flight row re-creating the null, `push` alone because a
# merge_group head branch can never equal the default branch, a `--repo`-less
# call answers as the CWD repo, and a trimmed `--json` reduces to nothing. The
# recovery fires only on a null (counted, not inferred). `default_branch_runs_seen`
# is THREE-STATE — `0` is a positive claim that only an ANSWERED recovery may
# make — and the verdict ships its age, because the recovery is unbounded by
# RUN_LIMIT and a month-old green rendered as current is quieter than the missing
# verdict it replaced. One definition is not one answer: `ignoreevent` must redden
# a sample-path row and a recovery-path row together. Mutant `zeroage` catches
# unknown ages becoming zero on both paths. Reach is derived over the gate's
# enumerated mutants; unreached rows must equal the two declared preconditions.
# "No network" is structural (shim check, #348).
if bash scripts/test-repo-signals-recovery.sh; then
    pass "repo-signals recovery tests (scripts/test-repo-signals-recovery.sh)"
else
    failed "repo-signals recovery tests (scripts/test-repo-signals-recovery.sh)"
fi

# --- 45. release-lag tests ------------------------------------------------------
# The scheduled reminder alone gates on live lag. Here only fixture behavior
# is checked, so overdue runtime work cannot block its own dedicated release PR.
if bash scripts/test-release-lag.sh; then
    pass "release-lag tests (scripts/test-release-lag.sh)"
else
    failed "release-lag tests (scripts/test-release-lag.sh)"
fi

# --- 46. fire-watch block tests -------------------------------------------------
# The routine's Slack post is parsed only through its `fire-watch-v1` block;
# the sentinels the consumer and docs/ROUTINES.md must agree on, the handle
# grammar's one home, and the slug rule against real workflow names. Source-
# level, no network.
if bash scripts/test-fire-watch-block.sh; then
    pass "fire-watch block tests (scripts/test-fire-watch-block.sh)"
else
    failed "fire-watch block tests (scripts/test-fire-watch-block.sh)"
fi

# --- 47. model-tier tests -------------------------------------------------------
# Dispatch sites name a tier, never inherit the session model, and every inline
# binding matches docs/MODEL-TIERS.md. Source-level, no network.
if bash scripts/test-model-tiers.sh; then
    pass "model-tier tests (scripts/test-model-tiers.sh)"
else
    failed "model-tier tests (scripts/test-model-tiers.sh)"
fi

# --- 48. testflight JWT tests ---------------------------------------------------
# The App Store Connect signer is openssl only and its ES256 output verifies.
# Throwaway key, no gh, no network.
if bash scripts/test-testflight-jwt.sh; then
    pass "testflight JWT tests (scripts/test-testflight-jwt.sh)"
else
    failed "testflight JWT tests (scripts/test-testflight-jwt.sh)"
fi

# --- 49. board-snapshot call tests ----------------------------------------------
# Fenced board-snapshot.sh commands use the environment form and pass no flag.
# Source-level, no network.
if bash scripts/test-board-snapshot-calls.sh; then
    pass "board-snapshot call tests (scripts/test-board-snapshot-calls.sh)"
else
    failed "board-snapshot call tests (scripts/test-board-snapshot-calls.sh)"
fi

# --- 50. plugin-root-paragraph tests --------------------------------------------
# Every SKILL.md carrying the plugin-root token carries the root-resolution
# paragraph before the first fenced command, and no paragraph spells the token.
# Source-level, no network.
if bash scripts/test-plugin-root-paragraph.sh; then
    pass "plugin-root-paragraph tests (scripts/test-plugin-root-paragraph.sh)"
else
    failed "plugin-root-paragraph tests (scripts/test-plugin-root-paragraph.sh)"
fi

# --- 51. isolation-contract tests -----------------------------------------------
# take-it confirms isolation before a parallel dispatch and fails closed; the
# design doc's claims agree. Source-level, no omp, no network.
if bash scripts/test-isolation-contract.sh; then
    pass "isolation-contract tests (scripts/test-isolation-contract.sh)"
else
    failed "isolation-contract tests (scripts/test-isolation-contract.sh)"
fi

# --- 52. config-fallback-paragraph tests ----------------------------------------
# The unrun-config paragraph sits in the four carriers, exactly and directly under
# the config line, and in none of the four stoppers. Source-level, no network.
if bash scripts/test-config-fallback-paragraph.sh; then
    pass "config-fallback-paragraph tests (scripts/test-config-fallback-paragraph.sh)"
else
    failed "config-fallback-paragraph tests (scripts/test-config-fallback-paragraph.sh)"
fi

# ------------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    echo "preflight: all gates green" >&2
    exit 0
else
    echo "preflight: FAILURES above" >&2
    exit 1
fi
