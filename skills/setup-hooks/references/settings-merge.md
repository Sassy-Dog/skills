# Settings merge — ownership, wiring, uninstall

The generator's entire settings footprint is hook entries whose `command` references
`.claude/hooks/sassydog-`. That substring is the ownership marker — JSON has no comments, so
ownership lives in the command path, and the marker survives any hand-reformatting of the file.

## The entries to add

Into the chosen target file (`.claude/settings.json` committed, or `.claude/settings.local.json`
personal — Phase 2 question 1):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/sassydog-post-edit.sh\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Plus the artifact guard, which needs **two** entries because it covers two events:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|mcp__.*(screenshot|computer)",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/sassydog-artifact-guard.sh\"",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/sassydog-artifact-guard.sh\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

The `PostToolUse` matcher is a **separate matcher group** from the dispatcher's `Edit|Write` — do
not merge them. They fire on overlapping but different tool sets (the guard also wants the
browser-automation screenshot tools, which have nothing to format), and collapsing them would run
a formatter over a PNG path and a guard over every source edit.

The `Stop` entry has **no matcher** — Stop carries no tool name, so a matcher there matches nothing
and the hook would never fire.

`$CLAUDE_PROJECT_DIR` (expanded by the harness at hook time) keeps the entry correct regardless of
the shell's cwd when the hook fires. The 30s timeout covers `npx` cold starts; per-edit tools are
otherwise sub-second. The guard gets 10s: it runs `jq` plus at most one `git ls-files`, and a slow
guard would tax every Stop.

## Merge rules (surgical, never a rewrite)

1. Read the target file IN FULL first. No target file → create it with exactly the object above.
2. File exists → deep-merge ONLY the ownership-marked entry:
   - `hooks` key absent → add it.
   - `hooks.PostToolUse` absent → add the array.
   - A matcher group with the SAME matcher string already exists → append the command object to
     ITS `hooks` array (do not create a duplicate matcher group) — unless an entry referencing
     that same `.claude/hooks/sassydog-` script is already there (idempotent: nothing to do).
     Match on the exact matcher string: `Edit|Write` and the guard's matcher are different groups
     and must stay that way.
   - `hooks.Stop` absent → add the array. A pre-existing matcher-less Stop group belonging to
     someone else → append to it, same rule.
3. Never reorder, reformat, or touch any other key (`permissions`, `env`, other hooks, other
   matchers). The diff shown for approval must contain only the added/removed owned entry.
4. Refresh mode with an empty rendered tool set (repo dropped every detected stack): remove the
   `sassydog-post-edit.sh` script and **its** entry only, and say so. Leave empty matcher groups the
   removal creates — deleting a group another tool might share is not surgical. **The artifact
   guard is unaffected** — it is stack-agnostic, so an empty tool set is not a reason to remove it.
5. **Target flip: move, never duplicate.** When the chosen target is `settings.local.json` (the
   public-repo default) and the other file already holds owned entries (command contains
   `.claude/hooks/sassydog-`), remove exactly those entries from the other file and add them to the
   target, and show both diffs. Leaving the old entry keeps a tracked script wired and PR-editable.
   The reverse flip fires when the chosen target is `settings.json` and `settings.local.json`
   already holds owned entries; it moves them back the same way. Empty matcher groups the removal leaves stay, as
   in rule 4; non-owned entries never move.

## Uninstall

"Remove the sassydog hooks" = delete `.claude/hooks/sassydog-*.sh` + remove every settings entry
referencing `.claude/hooks/sassydog-` from BOTH settings files, with the same preview-then-approve
gate — including the matcher-less `Stop` entry, which is easy to miss when scanning for matcher
groups. Nothing else changes; leave the `/tmp/` gitignore line alone, since by then the repo may
have artifacts there worth keeping out of git.

## Precedence notes worth telling the user

- Project `.claude/settings.json` hooks run in addition to (not instead of) the user's global
  `~/.claude/settings.json` hooks — generating here never conflicts with a global SessionStart or
  statusline setup.
- `settings.local.json` is git-ignored by Claude Code convention, but `.claude/hooks/` is not,
  which is why a public repo also gets the `.claude/*` / `!.claude/sassy-dog/` ignore lines
  (`SKILL.md` Phase 3). Choosing it means teammates do NOT get the hooks — the right choice for personal experimentation, the wrong one for a team
  formatting standard.
- Hooks are read at session start — a refresh takes effect on the NEXT session in that repo.
