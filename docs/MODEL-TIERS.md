# Model tiers

Every dispatch site this plugin has names a **tier**, not a model. A tier is a harness-neutral
word, and each harness binds it to its own model. This file is the single home of that binding.
`scripts/test-model-tiers.sh` holds the sites to it, and its `required` table is the enumerated list
of those sites. "Every dispatch site" means exactly that list. A new site joins it in the same PR
that adds the site, or it inherits the session model unchecked.

## The tiers

| Tier | Rank | Claude Code | omp | Used for |
| --- | --- | --- | --- | --- |
| `astra` | 1 | `fable` | `@slow` | reserved — nothing dispatches here today |
| `sol` | 2 | `opus` | `@default` | the resolved review agent (`review_agent:`, by default `pr-review-orchestrator`): the integration pass and the Blocking-vs-Nits judgement |
| `terra` | 3 | `sonnet` | `@task` | implementation workers (`take-it`, `dispatch-ready`); the nine `*-reviewer` agents in both review modes; `assess-it`'s refute-pass skeptics; `whats-on-fire`'s org-sweep subagents |
| `luna` | 4 | `haiku` | `@smol` | reserved — nothing dispatches here today |

Rank 1 is the strongest. The Claude Code column is the value for the Agent tool's `model`
parameter. The omp column is an omp role alias, and it resolves to whatever model that role is
configured to use.

The omp aliases are task-tool bindings, not CLI model selectors. The supervised serial
transport resolves `modelRoles.task` to a concrete `omp --model` selector, falling back
explicitly to configured `modelRoles.default` when task is unset and reporting that fallback.
Missing configuration is a pre-claim hold, never an invented model or a profile write.
On omp 18.8.5 the literal CLI selector `@task` was rejected; the shared invocation lives in
`skills/take-it/references/isolation-confirmation.md`.

## Why tiers, and why at the dispatch site

**Implementation and fan-out review run at `terra`, and this is a cost decision.** A measured
14-day window had 60 worker transcripts and 666 review-agent transcripts, nearly all inheriting
the session's Opus model. `dispatch-ready` also pinned its workers to Opus, on the stated premise
that Opus was "the cheaper tier relative to the coordinator's session model". That premise stopped
holding once the session model itself became Opus. One judgement-heavy agent per PR stays at `sol`:
the orchestrator, which derives Blocking from Nits and runs the cross-surface integration pass.

**A tier word never goes in `model:` frontmatter.** Claude Code and omp both read a `model:` key,
but their value spaces do not overlap: Claude Code takes `sonnet`, `opus` and the like, while omp
takes `@task`, `@smol` and the like, or a provider id. A tier word is valid in neither. So
**agent files stay model-free**, and the tier is chosen where the agent is dispatched. The same
reviewer then runs at the same tier from every caller, and one table rebinds every site.

**Each dispatch site carries its binding inline**, in exactly this form:

```text
tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`)
```

A cold sub-agent or a `/loop` tick acts on the text in front of it and never opens this file, so
the binding has to be at the site. The copies are safe because the gate re-derives each one from
the table above. A binding that disagrees with its row fails CI. So does a bare `model: "opus"`
left outside a binding, and so does removing a required site's binding.

## What a tier does not cover

A tier makes the *model choice* portable. The dispatch mechanics are still Claude-Code-shaped: the
Agent tool, `isolation: "worktree"`, the Skill tool, and `${CLAUDE_PLUGIN_ROOT}`. A harness that
runs these skills still has to supply those mechanics. [`HARNESS-PORTABILITY.md`](HARNESS-PORTABILITY.md)
inventories them, records omp's documented equivalent for each, and sets out the options.

The coordinator itself is not tiered. `take-it` and `dispatch-ready` coordinate from whatever session
invoked them, and only the agents they dispatch carry a tier.

## Adding a harness

1. Add a column to the table above. Every tier needs a value, and the reserved tiers too, so a
   later site can adopt them without a table edit.
2. Extend the inline form in every binding with `· <harness>: \`<value>\``. Then extend the gate's
   binding pattern and table parse to match. Land all three in the same PR, or every site fails the
   gate at once.
