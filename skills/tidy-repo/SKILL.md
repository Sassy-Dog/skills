---
name: tidy-repo
description: >
  Clean up local + remote git state after a productive day — fast-forward the default branch and
  prune, inventory stale branches/worktrees, triage orphan stashes, sweep untracked-file noise,
  remove stale worktrees, delete merged-PR branches local + remote. Use when the user says "clean
  it", "clean up", "tidy the repo", "tidy up", "tidy it", "clean branches", or asks to remove
  stale worktrees/branches/stashes. Reads the current repo's settings from
  `.claude/sassy-dog/tidy-repo.md`; run `setup-config` if that file is missing.
---

# Tidy-Repo

Post-shipping git reconciliation for the current repo.

> Formerly `clean-it`. The "clean it" and "clean up" triggers still resolve here.

This skill is **thin**: it reads the repo's facts from config and delegates the actual mechanics —
the `[gone]` grep trap, squash-merge `-D`, stash triage by `closedByPullRequestsReferences`,
agent-worktree teardown — to `sassy-dog:repo-cleanup`, so the plumbing lives in one place
across every repo.

**Acting principle:** assess first, act on what's confident, escalate only on mixed signal —
substantive WIP, dep-file touches, abandoned-but-non-trivial work. Never auto-drop a stash on an
OPEN issue; never auto-discard outside the allowlist.

## 1. Derive the repo facts

These are never configured — read them live so they cannot drift:

```bash
gh repo view --json nameWithOwner,defaultBranchRef,deleteBranchOnMerge \
  --jq '"repo=\(.nameWithOwner) branch=\(.defaultBranchRef.name) dbom=\(.deleteBranchOnMerge)"'
```

## 2. Repo config

!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root:-<not a git repo>}"; cat "$root/.claude/sassy-dog/tidy-repo.md" 2>/dev/null || echo "NO_CONFIG"`

**Unrun config line.** If the line above reached you as text (it starts with `!` and shows a
command, with no `CONFIG_SOURCE:` output beneath it), nothing ran it. Take the repo root from
`git rev-parse --show-toplevel` and read `<repo root>/.claude/sassy-dog/tidy-repo.md` by absolute path.
If that file does not exist the config is `NO_CONFIG`, handled as that state already is. Never read
an unrun line as "no config exists".

**Check `CONFIG_SOURCE` before using any of this.** It is the repo root resolved from the
**session's** working directory at skill-load time — not necessarily the repo you are about to act
on — and cwd resets between Bash calls, so you cannot influence it. If it names a repo other than
the one you are working in, **discard the block above**, read that repo's own
`.claude/sassy-dog/tidy-repo.md` by absolute path, and use that instead. Config is meant to be applied
exactly as written, so the wrong one silently applies another repo's rules: on 2026-08-18 two agents
shipping in `routines` and `skills` were each handed `platform`'s Terraform gates,
and caught it only by noticing the mismatch themselves.

The block above is this repo's `.claude/sassy-dog/tidy-repo.md`, inlined at load time. Its
frontmatter carries the sweep policy — `dep_version_globs`, `noise_allowlist`, `never_discard`,
optional `claim_label` — and its `##` sections carry repo-specific prose. The contract is
`sassy-dog:setup-config` → `references/config-contract.md`.

**If it reads `NO_CONFIG`**, first check for a stranded pre-rename config: if
`.claude/sassy-dog/clean-it.md` exists, this repo is configured but predates the
`clean-it` → `tidy-repo` rename — say exactly that, route to `sassy-dog:setup-config`
(update mode, it performs the config rename), and stop rather than running degraded. Never read
the old filename directly.

Otherwise, this repo has not been set up yet. The §1 facts are still available,
so the branch/worktree work is safe to do. But run with an **empty** noise allowlist and an empty
dep-version-glob list: with no `never_discard` list you cannot know which untracked files are
precious, so **discard nothing at all** and report what you would have swept.

**Do not infer an allowlist from the repo's `.gitignore` or file extensions.** `.gitignore` lists
files that are intentionally untracked, which is the opposite of disposable — that is exactly where
`.env.local` lives. Then tell the user:

> No `.claude/sassy-dog/tidy-repo.md` in this repo — running in conservative mode with no
> auto-discard.

Then run the reconciliation, and make the offer in the final section — after the user has seen what
was found, not before. The inventory is the useful part; a setup prompt in front of it just delays
the answer they asked for.

## 3. Run

Delegate the full reconciliation, passing the §1 facts and the §2 policy:

```
Skill: sassy-dog:repo-cleanup
Args: "Reconcile <repo> post-shipping. default-branch=<default_branch>;
       delete-branch-on-merge=<delete_branch_on_merge>;
       dep-version-globs=<dep_version_globs>;
       noise-allowlist=<noise_allowlist>;
       never-discard=<never_discard>;
       claim-label=<claim_label, omit if unset>.
       Inventory read-only first, then sync+prune, triage stashes, sweep untracked noise, tear
       down stale/detached worktrees, delete [gone] + squash-merged branches, mop up stale remote
       branches, clear orphan claim labels if a claim label is set. Apply the assess-first /
       ask-on-mixed-signal principle."
```

`repo`, `default_branch`, and `delete_branch_on_merge` come from §1; the rest come from §2's
frontmatter. Omit `claim-label` entirely when the config does not set one.

If `sassy-dog:repo-cleanup` is not in your available skills, STOP and tell the user to
install the plugin (`claude plugin install sassy-dog`) — do not improvise the reconciliation
from memory. The `[gone]` grep trap and squash-merge `-D` are easy to get wrong and lose work.

## 4. Repo-specific cleanup

If the config has an `## extra-cleanup` section, perform those steps after the delegation above.
They cover repo-unique work `repo-cleanup` doesn't know about — extra label hygiene, cache
directories, vendored-artifact pruning.

## Guardrails

- Never delete a branch with an OPEN PR; never delete the default branch, local or remote.
- Never `--force` remove a worktree whose SHA isn't in the default branch without confirming.
- Never auto-drop a stash on an OPEN issue; `closedByPullRequestsReferences`, not bare issue
  state, is the "shipped" signal.
- Never auto-discard untracked files outside the allowlist, or anything in the never-discard list.
- Don't disable `delete_branch_on_merge`; don't run inside a worktree you're about to remove.

Apply any `## extra-guardrails` section from the config on top of these.

## If this repo had no config

### Offer to set this repo up

**Then, after the output above — not before it — offer once:**

- **If `.claude/skills/clean-it/SKILL.md` exists with a `generated-by:` marker** (the legacy
  generated-skills name) — this repo is on the superseded generated-skills architecture. Say so
  concretely: *"This repo has a generated `clean-it` I can migrate — I'd extract its config, show
  you the result, and remove the old skill only after you approve. Want me to?"*
- **Otherwise** — nothing to extract from: *"I can set this repo up. It takes a few questions about
  how this repo works. Want me to?"*

Naming which path applies matters: one of them ends in deleting a file the user may not know is
there.

On yes, delegate to `sassy-dog:setup-config`. **Never write config yourself** — the
refresher owns the contract, and a skill that writes its own forks the format the moment the
contract moves.

**Offer once per session.** Running deliberately in an unconfigured repo is legitimate; re-prompting
every invocation is noise. If declined, carry on and don't raise it again.
