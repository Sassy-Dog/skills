---
name: whats-behind
description: >
  This skill should be used when the user asks "what's behind", "what needs a bump", "what's out of
  date across our repos", "which products are lagging", "who's on an old version", "portfolio
  dependency audit", "audit our dependencies across products", "are any products falling behind",
  "version drift", "which repos have stale actions", "keep the runners updated", or wants a
  cross-repo currency check spanning EVERY repo in a portfolio rather than one repository. Compares
  each repo's pinned GitHub Actions, toolchain versions, runner labels, and Dependabot coverage
  against its peers, then reports which repos are lagging and whether the cause is a missing
  automation config. Read-only — never edits pins, never opens PRs. For things that are broken or
  stalled rather than merely old, use whats-on-fire; for single-repo prioritization, use that
  repository's own survey-work skill.
---

# What's Behind

A currency check across every repo in a portfolio: who is lagging their peers on shared versions,
and — more usefully — **why**.

This skill is **read-only**. It measures and reports; it never edits a pin or opens a PR.

**Scope boundary.** `whats-on-fire` covers things that are *broken or stalled*. This covers things
that merely *drift*: nothing here is failing today. A product quietly sitting three major versions
behind its siblings never shows up as a fire, which is exactly why it needs its own pass.

## 1. Pull the drift

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/whats-behind`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
PORTFOLIO_ROOT=~/Repos/sassy-dog bash ${CLAUDE_PLUGIN_ROOT}/skills/whats-behind/scripts/pull-version-drift.sh
```

Emits `{repos, actions, toolchains, runners, dependabot, skipped}`. `MAX_DEPTH` defaults to 2 so
multi-repo product groups are covered; depth counts the repo, not its `.git`.

**Exclude archived repos before ranking.** The script walks local checkouts, and archived repos
routinely linger on disk long after they stop mattering. Cross-reference the org
(`gh repo list <ORG> --json name,isArchived`) and drop the archived ones, or the report will
solemnly tell you a dead product is behind. No `gh` on PATH (cloud sessions): pull the same roster
via the GitHub MCP list-repos capability — the pattern in `whats-on-fire`'s
`references/cloud-fallback.md`.

## 2. Rank peer-relative, not absolute

The comparison is **against peers, not a registry**. If eleven repos run `actions/checkout` v7 and
one runs v4, that one is behind — regardless of what upstream shipped this week. Peer-relative
ranking also works offline and never nags about a version nobody has adopted.

Read `references/interpreting.md` for the tiers. The short version:

- **Behind the fleet** — repo's version is below the portfolio mode for that item. Rank by distance
  (major gaps first).
- **Internally inconsistent** — one repo pinning two versions of the same thing. Rank this ABOVE a
  plain lag: it means the repo has no single source of truth, so any bump is already partial.
- **Unmanaged** — no Dependabot config, or config that omits `github-actions`.

## 3. Report the cause, not just the symptom

**This is the step that makes the skill worth running.** Cross-reference every laggard against
`dependabot[<repo>]`. Stale pins are usually not neglect; they are the visible signature of a repo
nothing is watching. A repo with no config will drift back within weeks of any manual bump, so a
report that says "bump these six" prescribes work that undoes itself.

Say which it is:

- **Lagging AND unmanaged** → the fix is to render the config (`sassy-dog:setup-deps`),
  not to bump by hand. Dependabot then opens the bumps itself and they stay closed.
- **Lagging BUT managed** → config exists and has not cycled yet, or something is pinning it back.
  Check whether the ecosystem is actually listed and whether its PRs are being merged.
- **Managed and current** → the control group. Name it; it is the evidence the first bullet is right.

## 4. Runner currency

`runners[<repo>]` counts hosted vs self-hosted jobs. Report migration progress per repo, and treat a
repo still fully on hosted runners as behind the fleet standard — but check the known blockers
before calling it neglect. Some jobs cannot move: a runner image without a needed **system library**
is a hard block, because the fleet runs as non-root with no `sudo`. Language toolchains that unpack
into `$HOME` are portable; system libraries are not.

## 5. Output format

Render inline as markdown. Empty categories collapse to one line on `✓ Current:`; skip empty tiers;
recommendations LAST.

**`Load:` is a REQUIRED field on the header line — always rendered, never dropped**, including on a
long report, a truncated one, or a crowded header. Its value is `plugin` when this skill ran as
`sassy-dog:whats-behind`, and `fallback (degraded)` when this body was read from
`skills/whats-behind/SKILL.md` because the plugin skill was not among the session's available skills
(the routine fallback clause in `CLAUDE.md`). It is a field rather than a sentence for one reason: a
missing sentence reads as a healthy run, while an empty slot reads as broken — on 2026-08-11 a
degraded run silently omitted its degraded note and delivered an otherwise complete, authoritative
report (#146). The field is still this run's own claim about itself, so it is never the authority:
**where the report and the run log disagree, the run log wins** — settle it with the out-of-band
check in `docs/ROUTINES.md`.

```markdown
# What's behind (YYYY-MM-DD)

_Load: <plugin|fallback (degraded)> · Scanned: N repos · M archived excluded_

✓ Current: <repo> · <repo> · ...

## 📉 Behind the fleet
- **<repo>** — `<item>` <version> vs fleet <version> — <managed|UNMANAGED>

## 🔀 Internally inconsistent
- **<repo>** — `<item>` pinned at both <a> and <b>

## 🕳 Unmanaged (no Dependabot config)
- <repo> — drift will return after any manual bump

## 🏃 Runner migration
- **<repo>** — N hosted · M self-hosted <· blocked by: reason>

## 👉 Recommended
1. **<action>** — <which repos> · <why this order>
```

## 6. Read-only contract

NEVER edits a version pin, writes a Dependabot config, or opens a PR. It reports; the human (or
`setup-deps`) acts. Keeping the audit read-only is what makes it safe to run on a
schedule against every repo at once.
