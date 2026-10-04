# GitHub Issue Operations

Exact commands for dedupe, labels, issue creation, and native sub-issue linking. Run these **only after the user approves the preview** (Phase 4).

> Assumes `gh` is authenticated with `repo` scope on the target. Set `REPO="owner/name"` (from `gh repo view --json nameWithOwner -q .nameWithOwner`).

## 1. Dedupe index (Phase 0, reused in Phase 2 & 4)

```bash
# Open issues — primary dedupe source
gh issue list --repo "$REPO" --state open --limit 500 \
  --json number,title,labels,body,url > /tmp/assess_open_issues.json

# Recently closed — context (avoid re-filing something just fixed)
gh issue list --repo "$REPO" --state closed --limit 200 \
  --json number,title,closedAt,url > /tmp/assess_closed_issues.json
```

Match on title similarity + same file/area in the body. When a candidate matches an open issue, **comment on it** instead of creating a duplicate:

```bash
gh issue comment <N> --repo "$REPO" \
  --body "Re-surfaced by codebase assessment ($(date +%F)). Still open; evidence: <file:line>."
```

## 2. Labels — delegated to the taxonomy's owner (this file defines none)

The engineering-dimension + severity taxonomy has exactly **one** home: `scripts/align-labels.sh` at the plugin root. Run it against the target repo; never transcribe its table here.

This file used to carry its own `ensure_label` copy. It froze at the pre-#158 colours, so four labels drifted (`epic`, `security`, `tech-debt`, `infra`) and `infra` ended up wearing `tech-debt`'s colour — a collision **created by a change to the canonical table, in a copy that table did not know existed** (issue #167). The copy was the defect; a re-transcription with today's hexes would simply restart the clock.

**Path resolution (the omp route is unrun; see #454).** `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` when the skill loads; it is **not** substituted into this file (reference docs are read raw) and it is **not** an environment variable in the shell. So take the plugin root from the invoking `SKILL.md`: on Claude Code, **SKILL.md Phase 4** prints the resolved absolute path; on a harness that leaves the plugin-root placeholder unexpanded (omp), use the root its **Plugin root.** paragraph resolves, which is the `[Skill file: ...]` or `[Skill directory: ...]` path cut at `/skills/assess-it`. Either way the script is `<plugin root>/scripts/align-labels.sh` (at the plugin root's `scripts/`, alongside `skills/`, and shipped in the installed plugin tree). Do not search for it.

```bash
ALIGN=<path from SKILL.md Phase 4>

bash "$ALIGN" --repo "$REPO" --dry-run   # preview: what is missing or drifted, writes nothing
bash "$ALIGN" --repo "$REPO"             # apply: create what is missing, correct what has drifted
bash "$ALIGN" taxonomy                   # the table as data: name|color|description per line
```

The align pass is idempotent and — unlike the old `gh label create … || true` — it **corrects** a label whose colour or description has drifted instead of silently skipping it. One JSON line per label on stdout (`ok|create|update|failed`), summary on stderr. It never deletes a label and never touches an issue. A failure here is reportable, not fatal: file the issues, and tell the user which labels could not be aligned.

### Which label goes on a finding (routing, not definition)

Names only — colours and descriptions come from the script above.

| Finding source | Dimension label |
| --- | --- |
| `architecture-reviewer` | `architecture` |
| `code-quality-reviewer` | `tech-debt` |
| `security-reviewer` | `security` |
| `dependency-supply-chain-reviewer` | `security` |
| `testing-reviewer` | `testing` |
| `cicd-release-reviewer` | `ci-cd` |
| `infra-platform-reviewer` | `infra` |
| `observability-ops-reviewer` | `observability` |
| `dx-docs-reviewer` | `dx` |

Every issue also carries `assessment`; each child carries `sev:<critical|high|medium|low>` from its severity; the Epic carries `epic`.

**There is no `dependencies` label, and assess-it must not create one** (decided 2026-08-11, issue #167). Dependabot auto-creates `dependencies` in every repo it runs in, with its own colour, and that name is already forked three ways across the org precisely because whichever system reaches a repo first owns the colour forever. Supply-chain findings map to `security` — the same mapping the canonical set already uses. Leave Dependabot's label alone.

## 3. Child issue body template

```markdown
## Problem
<one-paragraph statement of the genuine risk>

## Evidence
- `path/to/file.ext:LINE` — <what's there and why it's a problem>
- `path/to/other.ext:LINE` — <…>

## Why it matters
<concrete consequence in this repo>

## Proposed fix
<what this PR should do — scoped to one PR>

## Acceptance criteria
- [ ] <observable condition that proves it's fixed>

---
Severity: **<critical|high|medium|low>** · Likelihood: **<high|medium|low>** · Size: **<xs|s|m|l>**
Filed by `assess-it` on <date>. Part of Epic #<EPIC>.
```

Create it (capture the number):

```bash
CHILD_URL=$(gh issue create --repo "$REPO" \
  --title "<imperative title>" \
  --label assessment --label <area> --label sev:<level> \
  --body-file /tmp/child_body.md)
CHILD_NUM=$(basename "$CHILD_URL")
```

> **Do this once per cluster — one explicit `gh issue create` call each.** Do **not** collapse the children into a shell array + loop that splits a `"title|labels"` string with `IFS`. A temporary `IFS='|' read` assignment leaks into later word-splitting (`for l in $LABELS`), so the whole label list is passed to `gh` as a *single* label name (`'security sev:high tech-debt'`) — every `gh issue create` then fails with `not found` and creates nothing. Pass each `--label` as its own literal flag. The few extra lines are worth the determinism.

## 4. Epic issue

Body = the executive report from `assessment-rubric.md` (scores, strengths, biggest risks, "if I inherited this repo", top-10 ROI, 30/90/180-day roadmap), then **the coverage block**, then the child list. Create the Epic **after** the children so you can list/link them.

### The coverage block is REQUIRED, and it is the durable half

Phase 4's preview and Phase 5's report are **session output**: they tell the person who approved the filing which domains went dark, and they tell nobody else, ever. The Epic is the artefact that becomes the record. Without this block a backlog missing an entire domain **reads complete** to every later reader — which is the harm [#294](https://github.com/Sassy-Dog/skills/issues/294) is about, and the half [#284](https://github.com/Sassy-Dog/skills/issues/284) deliberately left open.

Render Phase 1's per-domain ledger verbatim, every domain, including the ones that returned:

```markdown
## Audit coverage

| Domain | Outcome |
| --- | --- |
| architecture | returned |
| security | **no report** |
| testing | returned |
| dx-docs | not dispatched (no docs surface — Phase 0) |

**A domain that is not `returned` was NOT audited.** The absence of findings for it is not
evidence of health, and this backlog is not complete with respect to it. Re-run the audit for
those domains before treating this Epic as a full picture.
```

A domain skipped for cause by Phase 0 stays visibly apart from one that went dark: *nobody looked because there is nothing there* and *nobody looked and there might be* are different facts, and once both are merely missing from the Epic they are indistinguishable. **List every domain, never only the dark ones** — a block that appears only when something went wrong is a block whose absence a reader cannot interpret.

```bash
EPIC_URL=$(gh issue create --repo "$REPO" \
  --title "Codebase Assessment — <repo> (<date>)" \
  --label assessment --label epic \
  --body-file /tmp/epic_body.md)
EPIC_NUM=$(basename "$EPIC_URL")
```

## 5. Link children as native sub-issues

GitHub sub-issues link by the child's **issue id** (the REST `id`, *not* the issue number).

```bash
link_sub_issue() {  # $1 = epic number, $2 = child number
  local child_id
  child_id=$(gh api "repos/$REPO/issues/$2" --jq '.id')   # REST integer id, NOT the issue number or node id
  gh api --method POST "repos/$REPO/issues/$1/sub_issues" \
    -F "sub_issue_id=${child_id}" >/dev/null \
    && echo "linked #$2 → epic #$1"   # -F sends sub_issue_id as an integer (required); -f would send a string
}

for n in "${CHILD_NUMS[@]}"; do link_sub_issue "$EPIC_NUM" "$n"; done
```

Verify: `gh issue view "$EPIC_NUM" --repo "$REPO"` should show sub-issue progress.

### Fallback (sub-issues API unavailable)

If `POST .../sub_issues` returns 404/403 (older GHES, missing scope), fall back to a task-list checklist in the Epic body — GitHub renders `- [ ] #N` as tracked items:

```markdown
## Tracked issues
- [ ] #12 Pin GitHub Actions to commit SHAs
- [ ] #13 Add integration tests for checkout flow
```

## Order of operations (Phase 4, after approval)

1. Align the labels: `bash "$ALIGN" --repo "$REPO"` (section 2 — the taxonomy's owner, never a copy of its table).
2. For each PR-sized cluster: re-check dedupe → create child issue → collect `CHILD_NUM`.
3. Create the Epic with the executive report + **the coverage block** + child list.
4. Link every child as a sub-issue (or task-list fallback).
5. Print Epic URL + child URLs, and reprint the coverage ledger for the operator.

**This list is the LAST instruction an agent reads, so it must not be a subset of the first.**
It already omitted the executive summary once; a step named in section 4 above and missing here is
a step that does not happen. If you add to the Epic body, add to this list in the same edit.
