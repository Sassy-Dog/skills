# Serializing coupled PRs

## The trap, in general form

Two PRs that both **regenerate the same derived artifacts** can each be green on a stale base. Git auto-merges the *different regions* of the derived files, so both stay `MERGEABLE`/`CLEAN` — but merging the second blind leaves the default branch with derived state missing the first PR's contribution. `CLEAN` reports the absence of a *textual* conflict; it says nothing about *consistency* of generated artifacts.

Known instances across Sassy Dog repos:

| Coupling | Derived artifacts | Broken end state |
|---|---|---|
| **Drizzle migrations** | `packages/db/src/migrations/*.sql` + `meta/_journal.json` | Second PR's migration numbered/journaled against a tree that didn't have the first → out-of-order or duplicate sequence; next `db-generate` / prod-migrate disagrees |
| **GraphQL codegen** | generated client/schema snapshots (`src/generated/*`, `__generated__/*`, `schema.graphql`) | Main's codegen snapshot missing the first PR's schema additions → no longer matches a fresh codegen run |

The same shape applies to any "schema + generated output committed together" pattern (OpenAPI clients, protobuf stubs, lockfile-from-manifest).

**Stacked PRs are the structural alternative to serializing.** Coupled PRs collide because each was branched from the same stale base and neither can see the other's derived output. Layers of a stack cannot have that problem: layer 2 is branched *from* layer 1, so it regenerates on top of layer 1's contribution by construction. Where the coupling is known up front — a schema change and the code that consumes it — stacking them removes the race rather than sequencing around it. See `references/stacked-prs.md`; note that the same `CLEAN`-means-nothing reasoning below applies to stack layers too, for a different reason (ordering, not consistency).

## With a merge queue: the queue is the structural fix

The queue builds a `merge_group` ref by rebasing each queued PR onto the real tip (main + earlier-queued entries) and **re-runs the required checks there**. If the repo's CI carries a freshness gate (a check that regenerates and diffs the derived artifacts), a stale PR fails its `merge_group` run and the queue **ejects it automatically** instead of merging inconsistent state.

So under a queue: enqueue all green PRs with `--auto` and let the queue sort ordering + staleness. **This only works if a freshness check is among the queue's required checks** — a path-filtered check that doesn't run on `merge_group` events gates nothing. If unsure whether the repo's freshness gate is queue-gating, treat the repo as if it had no queue for coupled PRs.

Eject recovery: rebase onto new main → re-run the repo's regeneration command (so artifacts reflect the union) → `--force-with-lease` → re-enqueue.

## Without a queue: serialize by hand

**Merge coupled PRs ONE AT A TIME**, re-checking mergeable after each:

```bash
# After merging the first coupled PR (the default branch typed literally):
git fetch origin <default-branch> --quiet
```

```bash
gh pr view "$NEXT_PR" --json mergeable --jq .mergeable
# MERGEABLE → safe to merge next.
# CONFLICTING / behind → rebase + regenerate before merging (below).
```

Two blocks on purpose, each its own Bash call: a worktree-isolated session refuses a command that names `git` beside a shell expansion, even in a separate statement.

Uncoupled PRs can merge in any order, in parallel. Only the PRs touching the same derived-artifact directories need the serial path. Identify them by changed paths:

```bash
gh pr view "$PR" --json files --jq '[.files[].path] | map(select(test("migrations/|generated/")))'
```

## Rebase recipe for generated-file conflicts: regenerate, don't hand-merge

When two branches both added derived artifacts, the rebase conflicts in the derived directory. Never hand-merge a migration journal or a codegen snapshot — take main's version wholesale, then regenerate yours on top so numbering/content is consistent:

```bash
git fetch origin <default-branch>
git rebase origin/<default-branch>
# On conflict in the derived dir:
git checkout --theirs <derived-dir>
git add <derived-dir>
<repo's regeneration command>     # re-emits this branch's delta on top of main's state
git add <derived-dir>
git rebase --continue
git push --force-with-lease origin HEAD
```

The regeneration command is repo-specific (e.g. `./dev db-generate` for Drizzle, a `codegen-all` script for GraphQL) — the calling project skill supplies it. If it didn't, ask rather than guessing.
