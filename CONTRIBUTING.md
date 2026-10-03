# Contributing

Thanks for looking. This repo has a few conventions that are enforced by CI and are not obvious from the file tree — reading this first will save you a red build.

## The short version

```bash
git clone https://github.com/Sassy-Dog/skills
cd skills
bash scripts/preflight.sh
```

There is **no build step**. The entire repo is Markdown (skills and agents) plus the Bash scripts bundled inside them. `scripts/preflight.sh` runs every gate CI runs, so run it before every PR. `--fix` auto-fixes markdownlint findings.

Two ways it can pass locally and still fail in CI, both worth knowing:

- **Preflight skips tools you don't have installed and still exits 0.** Read its output — a skipped gate is reported, not hidden — but CI has every tool and enforces all of them.
- **Tool versions can differ.** CI pins shellcheck and actionlint to exact versions; your local copies are whatever you installed. `shellcheck -S warning` findings are version-dependent, so a local pass on a different version is not proof.

## Testing a change for real

Preflight is necessary but **not sufficient**. It cannot tell you whether a skill's trigger phrases match the things people actually say, or whether its instructions work when an agent follows them. Load the plugin from your working tree and invoke it:

```bash
claude --plugin-dir /path/to/skills
```

Then use the skill the way a user would. A skill that parses cleanly and never triggers is broken.

## Rules CI actually enforces

These fail the build. Preflight reports each one by name.

**Frontmatter must satisfy the Agent Skills spec.** Every `SKILL.md` needs `---` on line 1, a `name` matching its directory, and a `description`. The key allowlist is **strict** — an unknown frontmatter key is a hard failure, so CI cannot go green on a file the publisher would reject. `name` is ≤64 chars with charset and hyphen rules; `description` is ≤1024 chars. This is the most common way a first new skill goes red.

**No bare `$1`–`$9`, `$@`, or `$*` in a `SKILL.md` body.** Skill bodies are an argument-substitution surface: when a skill is invoked with args, positional tokens in the rendered body get replaced, corrupting any embedded command. Use `cut -f1` / `--format` idioms instead, or move the snippet into a `references/` doc or a bundled script — neither is substituted.

**No superseded names in prose.** Several skills, the plugin, and the marketplace have been renamed. A guard greps the tree for each retired name and fails the build if one appears outside an explicit per-file allowlist — the sanctioned files are the ones where the old name is still load-bearing (back-compat trigger phrases, marker recognisers, committed fixtures). The names and the reason each file is exempt are listed in comments in `scripts/preflight.sh`; read those before writing about a rename. This paragraph deliberately names none of them, because doing so would fail the gate it describes.

**Version shape.** `.claude-plugin/plugin.json`'s `version` must be well-formed CalVer and must agree with `marketplace.json`. See below for why you should not be editing it at all.

**shellcheck, markdownlint, actionlint** across the tree, plus the suite of invariant tests in `scripts/test-*.sh`. actionlint covers `setup-deps`' workflow templates as well as this repo's own workflows, but it has to lint a **render** of them — their `# {{IF:FLAG}}` blocks and `{{TOKEN}}` placeholders are not valid on their own. Adding a template, or a new `{{IF:}}` arm to one, means adding it to the render matrix in `scripts/test-template-actionlint.sh`; the gate fails rather than silently leaving it unlinted.

## Rules enforced in review, not by CI

Nothing here is machine-checkable, and all of it gets raised on a PR.

**A skill `description` is a trigger spec, not a summary.** It is dense with quoted user phrases ("set a GitHub secret", "check TestFlight feedback") because matching those phrases is what activates the skill. CI checks that a description *exists* and fits the length limit; it cannot tell whether the phrases match anything a person would say. Write it as the list of utterances that should trigger the skill.

**Progressive disclosure.** `SKILL.md` stays thin and actionable; depth belongs in `references/*.md` that the skill tells the reader to open "when you reach that phase". Don't inline reference-doc detail into `SKILL.md`.

**Never hand-edit the version.** It is stamped, never typed:

```bash
bash scripts/stamp-version.sh
```

Run it only in a dedicated `chore(release)` PR, never in a feature PR: stamping is release-only (`docs/VERSIONING.md`, "Releasing"). CI validates the *shape*, so a hand-typed number can pass the gate and still be wrong. It is a one-way ratchet — see [`docs/VERSIONING.md`](docs/VERSIONING.md).

**Adding or removing a skill or agent?** Update `README.md`'s plugin/skill table, agent list and `### Harness support` matrix in the same PR. No gate reads those tables — the one thing any gate reads in the README is the *values* of its `review_surfaces:` example, which must name agents this plugin ships (`scripts/test-review-orchestrator-allowlist.sh`). A stale table stays stale until a human notices.

**Conventional commits** — `feat:`, `fix:`, `chore:`, `docs:`. There is no commit-lint; this is convention. PRs go to `main`, which has a merge queue.

## Where the tricky parts are

Two architectures in this repo are easy to break from the outside. [`CLAUDE.md`](CLAUDE.md) states the decisions governing both; the depth sits in the skill, agent, and gate-script files it points at:

- **Generator + capability skills.** The workflow skills (`survey-work`, `take-it`, `send-it`, …) are generic and ship once; per-repo behaviour lives in each consumer repo's `.claude/sassy-dog/*.md` config. Shared mechanics live in capability skills (`github-issues`, `pr-shepherd`, `repo-cleanup`, …). **Fix mechanics in the capability skill, never in a workflow skill.**
- **Ownership markers must keep recognising historical names.** Generated files in consumer repos carry a `generated-by:` marker, and the producer name has changed more than once. Matchers accept every name this generator has emitted, across both marker namespaces. Narrowing a matcher to the current name makes every pre-rename consumer file look hand-written and get skipped **silently** — the contract is report-and-skip, not error. `scripts/test-ownership-matchers.sh` pins this against real committed artifacts; if it fails, that is the reason.

Several tests pin invariants that live **outside runtime behaviour** — in a script's source shape, or in `SKILL.md` prose an agent follows. `scripts/test-visibility-preconditions.sh` pins instructions; `scripts/test-label-migrate.sh` and `scripts/test-detect-hook-stack.sh` pin source-level shape (a single call site for a destructive action; a probe that must carry no pipeline). If one fails on what looks like a cosmetic change, the wording or shape was load-bearing — read the test's header comment, which explains what it protects and why.

## Filing issues

Public issues are welcome for bugs, unclear instructions, and skills that don't trigger when they should. For anything security-relevant, use [private reporting](SECURITY.md) instead.

Useful in a bug report: the skill you invoked, what you said to trigger it, what happened, and what you expected. If a skill did not trigger at all, the exact phrasing you used is the single most useful detail.

## Licence

Contributions are accepted under [Apache-2.0](LICENSE), the licence this project ships under.
