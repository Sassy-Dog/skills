---
name: setup-hooks
description: >
  This skill should be used when the user asks to "set up hooks for this repo", "set up the
  sassydog hooks", "set up per-repo hooks", "set up project hooks here", "set up the
  format-on-edit hook", "set up a post-edit format hook", "add a formatting hook here", "generate
  hooks for this repo", "create project hooks for this repo", "make the hooks repo-specific",
  "wire up format-on-edit for this repo", or "lint on edit in this repo". Creates and re-syncs a
  consumer repo's stack-specific Claude Code hooks: generated dispatcher scripts under
  .claude/hooks/sassydog-*.sh plus their .claude/settings.json wiring. Run from inside the target
  repository; re-runnable as the repo's stack evolves.
---

# Setup Hooks

Generator for **per-repo Claude Code hooks**: inspect the repo's actual stack, render a
formatter/linter dispatcher tailored to it, wire it into `.claude/settings.json`, and reconcile all
of it on every re-run. The sibling of `setup-config` — same philosophy: the plugin ships
the generator, the repo owns a generated, refreshable artifact.

Why hooks and not instructions: formatting/lint feedback belongs at the harness layer, firing on
every Edit/Write deterministically — not re-taught per session. A repo-specific render beats a
global hook because a global one fires uselessly in repos whose stack it doesn't match.

## What gets generated

1. **`.claude/hooks/sassydog-post-edit.sh`** — a PostToolUse (Edit|Write) dispatcher rendered from
   `references/templates/sassydog-post-edit.template.sh`. It reads the hook event JSON on stdin,
   extracts the edited file path, and routes by extension to the tools the repo actually has.
   Contract: **formatters fix silently (exit 0); linters with unfixable findings exit 2** so the
   harness feeds the findings straight back for an immediate fix — defects surface at edit time,
   not in the PR review loop.
2. **`.claude/hooks/sassydog-artifact-guard.sh`** — a stray-artifact guard rendered from
   `references/templates/sassydog-artifact-guard.template.sh`. Stack-agnostic, so it is always
   generated and has no conditional blocks. It keeps screenshots and other throwaway binaries out
   of the repo **root**, where they accumulate unnoticed — invisible to `git diff`, breaking
   nothing, and indistinguishable later from a deliberate asset. The sanctioned destination is
   `tmp/`, which `sassy-dog:repo-cleanup` already auto-discards universally, so `tidy-repo` sweeps
   it with no per-repo config. Contract: **it reports, it never moves or deletes.**
3. **The settings entries** in `.claude/settings.json` (or `settings.local.json` when the user
   wants personal-only): one `hooks.PostToolUse` entry per script, plus one `hooks.Stop` entry for
   the guard's catch-all scan. See `references/settings-merge.md`.
4. **A root-anchored `/tmp/` line in the target repo's `.gitignore`** — the destination the guard
   points at. Owned here rather than by `setup-config` because a guard whose destination is not
   ignored just relocates the mess; the two must not drift apart.

## Ownership contract (what a re-run may touch)

- Generated scripts are exactly the files matching `.claude/hooks/sassydog-*.sh`, each carrying a
  `generated-by:` header comment. **Ownership matching is deliberately wide: accept EITHER marker
  namespace — the current `sassy-dog:` prefix and the pre-rename `ai-agent-skills:` prefix
  (plugin ≤ 2026.8.20) — paired with ANY producer name this generator has ever emitted:
  `setup-hooks` (current), `refresh-hooks` (plugin ≤ 2026.8.37), and `refresh-sassydog-hooks`
  (plugin ≤ 2026.7.21).** A script is owned when its header matches:

  ```text
  generated-by: (sassy-dog|ai-agent-skills):(setup-hooks|refresh-hooks|refresh-sassydog-hooks)
  ```

  All six namespace × producer-name combinations are owned. This matters more here than anywhere
  else in the plugin: the marker is committed **inside every consumer repo**, so a strict matcher
  would classify every pre-rename script as hand-written and refuse to refresh it — and it would
  fail *silently*, because the ownership contract below is report-and-skip, not error.
  **Normalise the marker to the current `sassy-dog:setup-hooks` form on write** (expect a one-line
  diff on a pre-rename repo's first refresh; that is the intended outcome, not drift).
  (The settings-entry marker below is a command *path*, so no producer rename affects it.)
- Settings entries owned by this generator are exactly the hook entries whose command references
  `.claude/hooks/sassydog-`. A refresh regenerates the scripts and adds/removes **only those
  entries** — every other hook (hand-written project hooks, the user's global hooks) is untouched,
  always. Read `references/settings-merge.md` before any settings write.
- Hand-edits inside a `sassydog-*.sh` script are overwritten on refresh — durable customization
  belongs in a separate hand-written hook, never in a generated file.

## Phase 0 — locate & mode

1. Confirm cwd is the target repo root: `git rev-parse --show-toplevel`.
2. Pick the mode: any `.claude/hooks/sassydog-*.sh` whose `generated-by:` header matches the wide
   ownership pattern above — **any** of the three producer names, in **either** namespace → **refresh
   mode** (re-detect, re-render, reconcile settings entries, normalise the marker); none →
   **create mode**. Never narrow this probe to the current producer name: create mode on a repo
   that already has generated hooks is the silent-failure path this contract exists to prevent.
3. Read the existing `.claude/settings.json` (and `settings.local.json`) IN FULL before planning
   any change — the merge is additive and surgical, never a rewrite of unrelated keys.

## Phase 1 — detect

Run the read-only probe from the repo root and treat its output as evidence:

**Plugin root.** If the plugin-root placeholder in the command below reaches you unexpanded, do not run it and do not search for the script. Take the path in the `[Skill file: ...]` or `[Skill directory: ...]` line at the top of this skill and cut it at `/skills/setup-hooks`: what comes before the cut is the plugin root. Write that absolute root into the command in place of the placeholder, then run it.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/setup-hooks/scripts/detect-hook-stack.sh
```

It emits one JSON object — per-tool `detected` + `why` (ruff, prettier, markdownlint, shellcheck,
dart, rustfmt, gofmt, dotnet-format) plus `detect_failures`. `tools.markdownlint` carries two extra
fields, `pin` and `pin_source` — the markdownlint-cli2 version the repo's CI enforces, and where it
was found. The probe table (what counts as evidence per tool, and the traps) is
`references/detection.md`. Detection keys on **repo config presence** (e.g. a `[tool.ruff]` section,
a `.prettierrc*`, a `.markdownlint-cli2.jsonc`), not on what happens to be installed on this
machine — the render must hold on a colleague's machine too.

## Phase 2 — interview (short)

Ask only what detection cannot answer:

1. **Settings target** — committed `.claude/settings.json` (default: the whole team gets the
   hooks) or personal `.claude/settings.local.json`? In a **public** repo, recommend the local file
   and an untracked `hooks/`: project hooks run with no trust prompt when only a parent folder was
   trusted, under `claude -p` / the Agent SDK and in cloud sessions, so tracked hook scripts are
   code any PR can change and contributors run unprompted (`setup-config` Phase 7 step 2).
2. **Lint strictness** — linters exit 2 (findings feed back for immediate fix — default) or
   advisory (log to the user, exit 0)?
3. **Slow tools** — anything detected with a meaningful per-edit cost (`dotnet format`, full
   `cargo fmt`) is opt-in; confirm before including.

## Phase 3 — render + preview-then-approve

Render the dispatcher from `references/templates/sassydog-post-edit.template.sh`: keep each
`# {{IF:<TOOL>}} ... # {{ENDIF}}` block only when that tool was detected (and confirmed, for slow
tools), strip the marker comment lines, keep the `generated-by` header — normalised to the current
`sassy-dog:setup-hooks` form, whatever the pre-existing script carried. The template is valid,
shellcheck-clean bash with every block present — rendering only deletes blocks, so the render is
valid by construction.

**The markdownlint route takes the one substitution, and one conditional inside a conditional.**
`npx -y markdownlint-cli2` resolves to **latest at hook time**, so an unpinned render blocks on
rules CI does not run — the fastest way to teach the user to ignore the exit-2 signal that makes
this hook worth having:

- **`tools.markdownlint.pin` non-empty** → replace the quoted `markdownlint-cli2` token with
  `markdownlint-cli2@<pin>` on **both** invocations (the `--fix` pass and the blocking re-check),
  and keep the nested `# {{IF:MARKDOWNLINT_BLOCKING}} ... # {{ENDIF:MARKDOWNLINT_BLOCKING}}` block.
- **`pin` empty** → delete that nested block. The route renders **fix-only**: it still fixes
  silently, it just cannot block. Fixing silently is always safe; blocking on rules CI does not run
  is not. **Say this in the preview** — name it as a deliberate downgrade and tell the user that
  pinning markdownlint-cli2 in CI (workflow, `Makefile`/`justfile`, or `package.json`) earns the
  blocking half back on the next refresh.

Never introduce a `{{...}}` placeholder into executable shell for the version — braces there trip
SC1083 and break the lint-clean-as-is invariant. Prettier is the deliberate contrast and needs no
equivalent: `npx --no-install` makes the repo's own lockfile its pin, so leave it exactly as it is.

Render the artifact guard from `references/templates/sassydog-artifact-guard.template.sh`. It is
stack-agnostic with no `{{IF:...}}` blocks, so the render is a verbatim copy minus the TEMPLATE
NOTE paragraph, with the `generated-by` header normalised the same way. It is generated
unconditionally — an empty detected tool set removes the post-edit dispatcher but never this.

Then compose the settings change per `references/settings-merge.md` (add the owned entries if
missing; in refresh mode also remove the post-edit entry when its tool set became empty).

**Also ensure `/tmp/` is in the target repo's `.gitignore`** — root-anchored, so it never shadows a
tracked `tmp/` deeper in the tree. Idempotent: check with
`git check-ignore -q tmp/probe` from the repo root and skip when already covered. Append it under
the repo's existing comment style; include the line in the approval diff like any other write.

**Print the full rendered script AND the settings diff, and write only after the user approves** —
writing into a product repo is an outward-facing action; never write silently. Preserve the
execute bit on the script.

## Phase 4 — verify

1. Shellcheck the rendered script: `shellcheck -S warning .claude/hooks/sassydog-post-edit.sh`.
2. Fire it with a synthetic event for one detected extension and confirm the routing:

   ```bash
   printf '{"tool_input":{"file_path":"<some-real-repo-file>"}}' | bash .claude/hooks/sassydog-post-edit.sh
   ```

3. Shellcheck the guard too, then drive **both** its events against the real repo — a guard that
   silently no-ops is the failure mode here, so assert the loud case actually fires:

   ```bash
   shellcheck -S warning .claude/hooks/sassydog-artifact-guard.sh
   # expect exit 2 + a nudge naming the file:
   printf '{"hook_event_name":"PostToolUse","cwd":"%s","tool_input":{"file_path":"probe.png"}}' "$PWD" \
     | bash .claude/hooks/sassydog-artifact-guard.sh
   # expect {"decision":"block",...} on stdout while a root artifact exists:
   printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$PWD" \
     | bash .claude/hooks/sassydog-artifact-guard.sh
   # expect SILENT — the recursion guard:
   printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":true}' "$PWD" \
     | bash .claude/hooks/sassydog-artifact-guard.sh
   ```

   Create and delete a throwaway `probe.png` in the root around this; leaving it behind is the
   very thing the hook exists to catch.
4. Confirm `tmp/` is actually ignored: `git check-ignore -v tmp/probe.png` must print the rule.
5. Validate the settings file still parses: `jq -e . .claude/settings.json`.
6. If the markdownlint route was rendered, confirm the version the hook will run matches CI's —
   `grep -o 'markdownlint-cli2[^"]*' .claude/hooks/sassydog-post-edit.sh` against the probe's
   `pin_source`. A pinned render must show the pin on both invocations; a fix-only render must show
   no blocking re-check at all. Nothing else in this flow catches a drifted version.
7. Remind: hooks load on the next session in that repo (settings changes are not hot-reloaded).

## Guardrails

- Never write or overwrite files in the target repo without showing the full content/diff and
  getting approval.
- Never touch hook entries this generator does not own (anything not referencing
  `.claude/hooks/sassydog-`), and never rewrite unrelated settings keys.
- **The post-edit dispatcher** must stay non-destructive: format-in-place and read-only lint only —
  never a hook that deletes, commits, pushes, or mutates anything beyond the edited file's
  formatting.
- **The artifact guard must not mutate at all** — it names a stray and tells Claude to move it,
  and never relocates or deletes the file itself. Auto-moving a file the user is about to open is
  worse than reporting it, and a guard that silently rearranges a working tree is exactly the class
  of hook the rule above exists to prevent.
- **Never make the guard's Stop entry exit 2, and never drop its `stop_hook_active` check.** Stop
  is the one event where blocking is self-perpetuating: Claude Code sets that flag session-wide
  while a stop continuation is in flight, so without the guard a stray the model legitimately
  chooses to keep wedges the session. Emit `{"decision":"block","reason":...}` on stdout instead.
- The generator itself always runs from the plugin — generated hooks are repo state, the generator
  is not.

## Additional resources

- **`references/detection.md`** — per-tool probe table, evidence rules, traps.
- **`references/settings-merge.md`** — the settings.json ownership/merge/uninstall contract.
- **`references/templates/sassydog-post-edit.template.sh`** — the dispatcher template (valid bash;
  render = delete unmatched blocks).
- **`scripts/detect-hook-stack.sh`** — read-only stack probe, JSON out.
