# Stacked pull requests

GitHub shipped stacked PRs to public preview on 2026-07-30. A stack is a chain of PRs where the bottom targets the trunk and each layer above targets the branch of the layer below. Layers merge **bottom-up**; when a lower one lands, GitHub keeps the upper ones open and retargets them.

Everything here is **read-and-gate only**. This skill never creates, extends, or dissolves a stack — the dispatchers (`take-it`, `dispatch-ready`) own creation, gated behind their `stacked_prs:` config.

> **Path resolution.** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at load time only — **not** into this file (reference docs are read raw), and it is **not** an environment variable in the shell. Before running anything below, set `PLUGIN_ROOT` to the plugin root's absolute path: where it comes from depends on the harness. On Claude Code the invoking `SKILL.md`'s command lines carry the root already substituted; on a harness that leaves the plugin-root placeholder unexpanded (omp), use the root that `SKILL.md`'s **Plugin root.** paragraph resolves, which is the `[Skill file: ...]` or `[Skill directory: ...]` path cut at `/skills/<skill-name>`. Do not search for it. Every command below quotes `"$PLUGIN_ROOT/..."`, so an unset value fails loudly with a 127 rather than resolving against `/`.

## Why a stack is dangerous to this skill specifically

`merge-shepherd.sh` is the single writer, and it merges any PR that is green **AND** `mergeable=MERGEABLE` **AND** `mergeStateStatus=CLEAN`.

**A middle layer of a stack reports exactly those three values.** Its base is the layer below, that base is a real branch, and there is no textual conflict — so `CLEAN` is truthful and useless. Merging on it lands layer 3 into layer 2's branch while layer 1 is still open: out of order, silently, with no error anywhere.

This is the same shape as the coupled-PR trap in `references/serialization.md` — `CLEAN` reports the absence of a *textual* conflict and says nothing about whether merging is *correct*. The fix here is a gate, not a heuristic: `stack-probe.sh` reports which layers below are still open, and a non-empty list stops the merge.

## Detection needs two probes, not one

This is the part that is easy to get wrong.

| Question | Probe | Answers |
|---|---|---|
| Is this **repo** enabled for stacks? | `GET /repos/{owner}/{name}/stacks` | `200` available · `404` not enabled (or no access) |

> **`Sassy-Dog` IS enabled for the preview, as of 2026-08-13** (verified: `200` on `skills`
> and `velovate`; it was `404` for every org repo when this support was written). The consequence is
> not cosmetic: `merge-shepherd.sh`'s `stack_gate()` used to short-circuit on exit `11` (repo not
> enabled) for every merge in every repo, so the GraphQL membership probe was effectively dead code
> here. It now runs on every merge. Verified non-regressive at the time — the field resolves, a
> non-stacked PR returns exit `10`, and `stack_gate()` treats `10` and `11` identically.
| Is this **PR** in a stack? | GraphQL `PullRequest.stack` | object, or `null` |

**GraphQL `null` means both "the repo isn't enabled" and "this PR isn't stacked."** A caller that reads that one null concludes *not stacked, safe to merge* on a repo it never actually checked. Both probes are required, and `stack-probe.sh` is where they live so nothing re-derives the rule.

### `gh pr view --json` has no `stack` field

Membership is GraphQL-only. `gh pr view --json stack` fails with `Unknown JSON field` — the identical trap as `isInMergeQueue` (see `references/merge-queue.md`). `gh`'s JSON surface lags new GitHub features; assume a newly shipped field is GraphQL-only until proven otherwise.

### The probe

```bash
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/stack-probe.sh" <pr> --repo owner/name
```

Exit `0` in a stack · `10` available but not stacked · `11` stacks unavailable here · `1` usage/API error. Omit the PR number to probe the repo and list its open stacks.

**Verified against a real stack, 2026-08-13** — `github/gh-stack` stack **350**, five layers
(PRs 330 → 333 → 343 → 307 → 321). Probing layers 1, 2 and 3 returned exit `0` with
`in_stack: true`, `size: 5`, correct **1-based** `position` (330→1, 333→2, 343→3), `entries[]`
ordered bottom→top with per-layer state, and `lower_open` / `lower_closed_unmerged` / `truncated`
all derived. That path had never executed before — it was unreachable while every org repo answered
`404`.

**The ordering gate is verified too, against a purpose-built live stack** (2026-08-13,
`skills` stack 195: two empty-commit PRs, both closed afterwards). This corrects an earlier
claim in this file that exit 23 could not be exercised because every `Sassy-Dog` repo runs a merge
queue. **That was wrong, and the reason is worth keeping**, because it is the same mistake a future
reader is likely to make:

| Probe | Result |
|---|---|
| `stack-probe.sh` on the UPPER layer | exit `0`, `position: 2`, **`lower_open: [193]`** |
| `stack-probe.sh` on the LOWER layer | exit `0`, `position: 1`, `lower_open: []` |
| `merge-shepherd.sh` on the UPPER layer | **exit `23`** — "blocked by open lower layer(s): 193" |
| `merge-shepherd.sh` on the LOWER layer | **exit `24`** — "STACKED under a merge queue" |

Nothing merged in any of the four.

**A merge queue does NOT prevent exercising exit 23.** In `stack_gate()` the `lower_open` check
precedes the queue check, so an upper layer returns `23` whatever the repo's queue configuration;
the queue branch is reached only when `lower_open` is EMPTY — i.e. only for the bottom-most open
layer, the one that would actually merge. Reading "this repo has a merge queue" as "the stack paths
are untestable here" inverts that ordering.

**A chained PR is not a stack.** Opening PR B against PR A's branch leaves both `in_stack: false`
(exit `10`); stack membership requires an explicit `POST /repos/{o}/{n}/stacks` with
`{"pull_requests": [<int>, ...]}`. This is why `merge-shepherd.sh`'s empty-rollup note treats
"intermediate chained/stacked PR" as two cases — the chained one gets no stack gate at all, and is
caught by the empty-rollup gate instead.

A stack whose PRs all close flips to `open: false` on its own; there is no delete endpoint, and the
closed record is history in the same way a closed PR is.

The fields that matter downstream:

- `position` — 1-based, bottom is 1.
- `lower_open` — layers below this one still `OPEN`. **Non-empty means do not merge.**
- `lower_closed_unmerged` — layers below closed *without* merging. The stack is broken; a human decides.
- `truncated` — `entries` is capped at 100; compare against `size`. Never true in practice, but a silently short list would under-report blockers.

## Merge rules

1. **Bottom-up, one layer per run.** There is no REST endpoint to merge a stack — the stacked-PR REST surface is list / create / add / unstack only. Whole-stack merge exists solely as `gh stack merge` in the `gh-stack` extension, which this plugin does not require. Merge the bottom-most open layer with plain `gh pr merge`; the layer above becomes the bottom-most open layer on the next pass. This is already `merge-shepherd.sh`'s stateless "advance one step" contract, so it needs no new loop.

2. **Never merge a layer with a non-empty `lower_open`.** `merge-shepherd.sh` exits **23** instead. 23 is deliberately *not* terminal in `--watch` mode: it clears on its own when the layer below lands.

3. **An inconclusive probe waits — it does not merge.** A probe that could not answer "is this stacked?" is not evidence that it isn't, and the cost of guessing wrong is an out-of-order merge. `merge-shepherd.sh` returns 11 (re-run) on probe error. Transient failures clear on the next pass, so this never wedges.

4. **Merge queue + stack: refuse (exit 24).** GitHub shipped queue support for stacks as "rolling out progressively over the coming weeks," and we cannot verify the interaction. Enqueuing a layer and hoping is exactly the asymmetry the config contract warns about — skipping knowingly is recoverable, acting on an unverified assumption is not. Surface it for a human.

## After a lower layer merges

GitHub retargets the upper layers automatically. It does **not** rewrite their history, which matters under squash-merge:

> Layer 1 squash-merges into `main` as one new commit. Layer 2's branch still contains layer 1's *original* commits, and now targets `main`.

Depending on the diff, layer 2 comes back either clean or `CONFLICTING`. Both land on machinery this skill already has: the existing guardrail is **surface `CONFLICTING`, never auto-rebase**, and the recovery is the regenerate-don't-hand-merge recipe in `references/serialization.md`. Nothing new is needed — but do not be surprised when a layer that was green goes conflicting the moment the layer below it lands. That is the expected shape, not a fault.

## Creating a stack (context for dispatcher callers)

Creation does not need the `gh-stack` extension, and this plugin never requires it — an extension install cannot be assumed in cloud sessions, cron routines, or a consumer repo. Both steps are plain `gh`:

1. Open each PR against the branch below it: `gh pr create --base <lower-branch>`.
2. Link them, bottom to top. Pass the body as explicit JSON rather than `gh api`'s `key[]=` array
   sugar — `pull_requests` must be an array of **integers**, and `-f` would send strings:

   ```bash
   echo '{"pull_requests":[101,102]}' | gh api "repos/$REPO/stacks" -X POST --input -
   ```

`pull_requests` is ordered **bottom → top** on both create and `POST /stacks/{n}/add`.

The extension remains a fine human convenience (`gh stack view`, `gh stack rebase`, `gh stack merge`); it is simply never a code path here.

## Constraints worth knowing

- **Same-repo only.** Cross-fork stacks are unsupported, so a stack can never span a fork-based contribution.
- **Every layer enforces branch protection and required checks**, not just the bottom one.
- **Not supported in GitHub Desktop.** Irrelevant to automation, relevant when a human asks why they cannot see it.
