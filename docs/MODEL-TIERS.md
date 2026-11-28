# Model tiers

Every dispatch site this plugin has names a **tier**, not a model. A tier is a harness-neutral
word, and each harness binds it to its own model. This file is the single home of that binding.
`scripts/test-model-tiers.sh` holds the sites to it, and its `required` table is the enumerated list
of those sites. "Every dispatch site" means exactly that list. A new site joins it in the same PR
that adds the site, or it inherits the session model unchecked.

There are four tables below, one per question: which tiers exist (Tiers), which efforts exist
(Efforts), which model a tier runs on (Model bindings) and which provider setting an effort maps to
(Effort bindings). One binding changes in one place, without reading the others.

## Tiers

A tier is a rank and a use, nothing harness-specific. The grade carries its own order: S above A
above B above C. A tier is always written exactly `S-Tier`, `A-Tier`, `B-Tier` or `C-Tier`: a capital
letter, a hyphen and a capital T, in backticks. A bare letter is never a tier, because `A` and `B`
also label the options in decision prompts and in take-it attempt records.

| Tier | Rank | Used for |
| --- | --- | --- |
| `S-Tier` | 1 | reserved — nothing dispatches here today |
| `A-Tier` | 2 | the resolved review agent (`review_agent:`, by default `pr-review-orchestrator`): the integration pass and the Blocking-vs-Nits judgement |
| `B-Tier` | 3 | implementation workers (`take-it`, `dispatch-ready`); the nine `*-reviewer` agents in both review modes; `assess-it`'s refute-pass skeptics; `whats-on-fire`'s org-sweep subagents |
| `C-Tier` | 4 | reserved — nothing dispatches here today |

Rank 1 is the strongest. History: these were named `astra`, `sol`, `terra` and `luna` until
2026-11-27, and those names said nothing about which tier was stronger. The legacy-name guard
(`scripts/check-legacy-names.sh`) keeps the old names from coming back.

## Efforts

An effort is how hard the model thinks, independent of which model it is. A dispatch site must name
a tier. It may name an effort, and naming none means `standard`. An effort is always `light`,
`standard` or `deep`, lowercase and in backticks.

| Effort | Meaning |
| --- | --- |
| `light` | The fewest thinking tokens per turn the model offers. Cheapest and fastest. |
| `standard` | The provider's default for that model. Every dispatch site runs at this today. |
| `deep` | The model's highest level short of an unbounded one. |

`standard` is deliberately not the same level on every model: Carbon's default is `medium`, Neon's
is `high`. It means "what the provider tuned this model to run at", not one fixed number. Claude
Code's `max` is not bound, because nothing needs it; if a site ever does, it can be added as a
fourth effort.

## Model bindings

Tier to model, verified 2026-11-27. The Claude Code column is the value for the Agent tool's
`model` parameter. The omp column is an omp role alias, and it resolves to whatever model that role
is configured to use.

| Tier | Claude Code `model:` | omp role | Anthropic model | Google model |
| --- | --- | --- | --- | --- |
| `S-Tier` | `fable` | `@slow` | `claude-fable-5-2` | `gemini-4-carbon` |
| `A-Tier` | `opus` | `@default` | `claude-opus-5-5` | `gemini-4-neon` |
| `B-Tier` | `sonnet` | `@task` | `claude-sonnet-5-5` | `gemini-4-hydrogen` |
| `C-Tier` | `haiku` | `@smol` | `claude-haiku-5-5` | `gemini-3.5-flash-lite` |

The omp aliases are task-tool bindings, not CLI model selectors. The supervised serial
transport resolves `modelRoles.task` to a concrete `omp --model` selector, falling back
explicitly to configured `modelRoles.default` when task is unset and reporting that fallback.
Missing configuration is a pre-claim hold, never an invented model or a profile write.
On omp 18.8.5 the literal CLI selector `@task` was rejected; the shared invocation lives in
`skills/take-it/references/isolation-confirmation.md`.

The Google column is documentation only. No harness reads it yet, and no dispatch site carries a
Google entry, so `scripts/test-model-tiers.sh` does not require one. Wiring a Google harness is
separate work:

- Gemini CLI custom subagents take a `model:` frontmatter key with a full ID, or `inherit` by
  default. Antigravity CLI replaced Gemini CLI for unpaid and Google One users on 2026-06-18. omp
  could bind its roles to these IDs.
- Neon and Carbon need the paid API tier. Hydrogen and Flash-Lite are also on the free tier.
- **Pin the IDs.** Google documents no per-family `-latest` alias, only the `gemini-flash-latest`
  naming pattern, so these IDs do not follow new releases on their own, and Google is already
  rerouting retired IDs (`gemini-2.5-pro` and `gemini-2.5-flash` from 2026-12-01). Re-verify this
  column when Google support lands.
- **Price** per 1M tokens (input / output), read 2026-11-27: Carbon $2 / $10, a promotion that runs
  until Nov 30 (the pricing page shows $4 / $20 from Dec 1); Neon $3 / $15; Hydrogen $1.50 / $7.50;
  Flash-Lite $0.30 / $2.50.
- **Argon is deliberately not bound.** Google calls it its "efficient Gemini 4 frontier reasoning
  model", with lower token spend per turn than Carbon, and `S-Tier` · `light` (Carbon at `low`)
  covers that need. Argon appears nowhere on Google's choosing-a-model page, and Gemini CLI's docs
  say it "has not been optimized for Gemini 4 Argon". Revisit only if Carbon at `low` turns out too
  slow or too costly.
- Google's own task guidance
  ([choosing a model](https://aistudio.google.com/docs/choosing-a-model), read 2026-11-27) matches
  the tier uses: Hydrogen for "parallel worker subagents" (`B-Tier`: workers and the nine
  reviewers), Neon where "a developer or coding agent is waiting on the response" (`A-Tier`: the
  orchestrator), Carbon for "deep verification" and to escalate to when Neon at high or xhigh
  "gets stuck" (`S-Tier`), and Flash-Lite as the "fastest, lowest-cost general model for
  high-volume tasks" (`C-Tier`). Its rule, "pick the lowest thinking_level that passes your quality
  bar", is why every site defaults to `standard` and `deep` is opt-in.

## Effort bindings

Effort to each provider's setting, verified 2026-11-27. Gemini's levels are per model and are set
with the API's `thinking_level` parameter (Google's "General-purpose and reasoning models" table:
Carbon `low`, `medium` (default), `high`; Neon and Hydrogen `low`, `medium`, `high` (default),
`xhigh`; Flash-Lite `minimal` (default), `low`, `medium`, `high`).

| Effort | Claude Code `effort:` | Carbon | Neon | Hydrogen | Flash-Lite | omp |
| --- | --- | --- | --- | --- | --- | --- |
| `light` | `low` | `low` | `low` | `low` | `minimal` | verify |
| `standard` | omitted (the agent's usual effort, not the session's) | `medium` (its default) | `high` (its default) | `high` (its default) | `minimal` (its default) | verify |
| `deep` | `xhigh` | `high` | `xhigh` | `xhigh` | `high` | verify |

- **Claude Code** reads `effort` on the Agent tool, and its documentation says to set it only when
  the user, or an instruction such as a skill, asks. A skill's inline binding is exactly that
  instruction. `standard` sets none.
- **Google `standard` sets the default value explicitly.** The page lists each model's default but
  does not say what omitting `thinking_level` does, so `standard` writes the default level until
  omitting it is confirmed to give the same result.
- **omp is still to verify.** If omp has no effort setting, its half of a binding carries the model
  only, and this table should record that omp runs every effort at its default. If omp would
  otherwise inherit the session's thinking level, `standard` has to be bound explicitly there.

## Why tiers, and why at the dispatch site

**Implementation and fan-out review run at `B-Tier`, and this is a cost decision.** A measured
14-day window had 60 worker transcripts and 666 review-agent transcripts, nearly all inheriting
the session's Opus model. `dispatch-ready` also pinned its workers to Opus, on the stated premise
that Opus was "the cheaper tier relative to the coordinator's session model". That premise stopped
holding once the session model itself became Opus. One judgement-heavy agent per PR stays at
`A-Tier`: the orchestrator, which derives Blocking from Nits and runs the cross-surface integration
pass.

**A tier word never goes in `model:` frontmatter.** Claude Code and omp both read a `model:` key,
but their value spaces do not overlap: Claude Code takes `sonnet`, `opus` and the like, while omp
takes `@task`, `@smol` and the like, or a provider id. A tier word is valid in neither. So
**agent files stay model-free**, and the tier is chosen where the agent is dispatched. The same
reviewer then runs at the same tier from every caller, and one table rebinds every site.

**Each dispatch site carries its binding inline.** A `standard` site, which is every site today,
looks like this:

```text
`B-Tier` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`)
```

Any other effort adds the effort word and its Claude Code value:

```text
`S-Tier` · `deep` (Claude Code: `model: "fable"`, `effort: "xhigh"` · omp: `model: "@slow"`)
```

A cold sub-agent or a `/loop` tick acts on the text in front of it and never opens this file, so
the binding has to be at the site. The copies are safe because the gate re-derives each one from
the tables above, both the model and the effort part. A binding that disagrees with its rows fails
CI. So does a bare `model: "opus"` left outside a binding, an effort word other than the three,
a near-miss tier spelling, and removing a required site's binding. Only the bound forms are matched,
never the bare words, because `standard` and `light` are ordinary English.

## What a tier does not cover

A tier makes the *model choice* portable. The dispatch mechanics are still Claude-Code-shaped: the
Agent tool, `isolation: "worktree"`, the Skill tool, and `${CLAUDE_PLUGIN_ROOT}`. A harness that
runs these skills still has to supply those mechanics. [`HARNESS-PORTABILITY.md`](HARNESS-PORTABILITY.md)
inventories them, records omp's documented equivalent for each, and sets out the options.

The coordinator itself is not tiered. `take-it` and `dispatch-ready` coordinate from whatever session
invoked them, and only the agents they dispatch carry a tier.

## Adding a harness

1. Add a column to the Model bindings table, and one to the Effort bindings table. Every tier and
   every effort needs a value, and the reserved tiers too, so a later site can adopt them without
   a table edit.
2. Extend the inline form in every binding with `· <harness>: \`<value>\``. Then extend the gate's
   binding pattern and table parse to match. Land all three in the same PR, or every site fails the
   gate at once.
