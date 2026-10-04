# ProjectV2 board operations

> **Path resolution.** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` at load time only — **not** into this file (reference docs are read raw), and it is **not** an environment variable in the shell. Before running anything below, set `PLUGIN_ROOT` to the plugin root's absolute path: where it comes from depends on the harness. On Claude Code the invoking `SKILL.md`'s command lines carry the root already substituted; on a harness that leaves the plugin-root placeholder unexpanded (omp), use the root that `SKILL.md`'s **Plugin root.** paragraph resolves, which is the `[Skill file: ...]` or `[Skill directory: ...]` path cut at `/skills/<skill-name>`. Do not search for it. Every command below quotes `"$PLUGIN_ROOT/..."`, so an unset value fails loudly with a 127 rather than resolving against `/`.

## Discovering board IDs

Callers of `file-or-link-issue.sh --project-id ...` and `gh project item-edit` need three IDs. Discover them once per board (they're stable — project skills pin them as facts):

```bash
# Board number + project node ID
gh project list --owner <ORG> --format json \
  | jq '.projects[] | {number, id, title}'

# Status field ID + option IDs (Backlog / In progress / Done ...)
gh project field-list <NUMBER> --owner <ORG> --format json \
  | jq '.fields[] | select(.name=="Status") | {id, options: [.options[] | {id, name}]}'
```

A PAT needs the `project` scope for these; without it, reads fail and the right behavior is to degrade (report "board skipped — no project scope"), not abort.

## Snapshot reads

Use the bundled script — it guards the truncation trap:

```bash
PROJECT_NUMBER=4 OWNER=Sassy-Dog bash "$PLUGIN_ROOT/skills/github-issues/scripts/board-snapshot.sh"
```

**The `--limit` trap:** `gh project item-list` returns items in numeric order, so a too-small limit silently drops the *newest* issues off the end (bitten in production at exactly 200). The script defaults to 2000 and reports `truncated: true` when the ceiling was hit — if you see it, raise `PROJECT_LIMIT`, don't ignore it.

## Moving cards (e.g. claiming an issue as "In progress")

```bash
ITEM_ID=$(gh project item-list <NUMBER> --owner <ORG> --format json --limit 2000 \
  | jq -r ".items[] | select(.content.number==<ISSUE>) | .id")

gh project item-edit \
  --project-id "$PROJECT_ID" \
  --id "$ITEM_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$OPTION_ID"
```

**Wrap mutating board calls in pr-shepherd's `gh-retry.sh`** — the Projects GraphQL endpoint flakes intermittently:

```bash
bash "$PLUGIN_ROOT/skills/pr-shepherd/scripts/gh-retry.sh" -- project item-edit ...
```

Board claims are **best-effort**: if the retry exhausts (exit 124) or the item isn't on the board, log it and proceed. A PR with `Closes #N` lands the card on Done automatically when it merges — don't fail a dispatch over a missing card.

## Adding an issue to a board

`addProjectV2ItemById` via GraphQL is the reliable shape (it returns the new item ID, which `gh project item-add` does not expose cleanly). `file-or-link-issue.sh` does this when given `--project-id`; reuse it rather than re-deriving the mutation.

## Board vs labels: which is the source of truth?

Repos differ: some treat the board as authoritative (issues not on the board don't exist for planning); others run label-driven backlogs (`P0..P3`, `horizon:*`) with an empty or vestigial board. A zero-item snapshot does NOT mean "no backlog" — check `gh issue list --label` before concluding that. The calling project skill should state which model its repo uses; if it doesn't, report both views.
