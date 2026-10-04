---
name: groom-backlog
description: >
  Backlog grooming: refine open issues until they are fully dispatchable by a cold worktree
  sub-agent, then promote them to Ready. The counterpart that feeds dispatch-ready. Use when the user
  says "groom it", "groom the backlog", "refine the backlog", "scope these issues", "make these
  dispatchable", "get the backlog ready", "fill it", or asks to move issues to Ready. Writes:
  issue-body edits, Ready promotion, epic-split sub-issues, and rubric #9's `site:<name>` label —
  which it creates in the repo when that label does not yet exist — only; never deletes, never
  closes, never dispatches work. Reads the current repo's settings from `.claude/sassy-dog/groom-backlog.md`.
---

# Groom-Backlog

Groom the backlog until every issue is either **Ready** — a cold sub-agent could ship it — or
**explicitly parked with a named reason**.

Groom-backlog owns *content quality*; sequencing and dispatch belong to dispatch-ready. The two share one
contract: **Ready means dispatchable.** Nothing reaches Ready that you would not hand to a worktree
agent with zero conversation context.

> Formerly `groom-it`, and `fill-it` before that. The "groom it" and "fill it" triggers still
> resolve here.

## 1. Repo config

!`root="$(git rev-parse --show-toplevel 2>/dev/null)"; echo "CONFIG_SOURCE: ${root:-<not a git repo>}"; cat "$root/.claude/sassy-dog/groom-backlog.md" 2>/dev/null || echo "NO_CONFIG"`

**Check `CONFIG_SOURCE` before using any of this.** It is the repo root resolved from the
**session's** working directory at skill-load time — not necessarily the repo you are about to act
on — and cwd resets between Bash calls, so you cannot influence it. If it names a repo other than
the one you are working in, **discard the block above**, read that repo's own
`.claude/sassy-dog/groom-backlog.md` by absolute path, and use that instead. Config is meant to be applied
exactly as written, so the wrong one silently applies another repo's rules: on 2026-08-18 two agents
shipping in `routines` and `skills` were each handed `platform`'s Terraform gates,
and caught it only by noticing the mismatch themselves.

Frontmatter supplies `gotcha_summary`, the optional `board` and `stacked_prs` blocks, and the
optional `execution_site` — the name this checkout answers to, used by rubric #9 to propose a site
label rather than invent one. An absent `execution_site` is not a defect: it means this checkout
answers to no particular name, so rubric #9 asks instead of proposing. Contract:
`sassy-dog:setup-config` → `references/config-contract.md`.

**If it reads `NO_CONFIG`**, first check for a stranded pre-rename config: if
`.claude/sassy-dog/groom-it.md` exists, this repo is configured but predates the
`groom-it` → `groom-backlog` rename — say exactly that, route to `sassy-dog:setup-config`
(update mode, it performs the config rename), and stop rather than running degraded. Never read
the old filename directly.

Otherwise run boardless (the `ready`-label flow below) and skip the repo-gotchas
step in §4 — **do not invent gotchas** by reading the repo's CLAUDE.md or CI config; a wrong gotcha
in an issue body misleads a cold sub-agent that has no way to check it. Say the step was skipped.

Grooming is otherwise safe to run un-configured: its writes are issue-body edits and **issue-scoped**
label changes, both reversible by re-editing the issue. **One write is not issue-scoped.** Rubric #9
creates a `site:<name>` label in the *repository* when the repo lacks it, and the only reversal for
that is `gh label delete` — the operation this repo puts behind a structural gate
(`scripts/align-labels.sh`'s `migrate_delete_gate()`) precisely because it strips the label from
every issue carrying it, unrecoverably. So create one deliberately, on an issue that needs it, and
never as tidying. Do not assume a board exists — a board with no config block is OFF.

## 2. Collect candidates

**With `board:` configured** — the board is authoritative. Snapshot via
`sassy-dog:github-issues` (`board-snapshot.sh`, using `board.number` and `board.owner`).
Candidates are every open issue in **Backlog** or with **no status** — *open* established by the
reconcile join below, never assumed from the card. Open issues missing from the board are handled
there too (drift class 4); they are not added unilaterally.

**Without a board** — open issues are the backlog and the `ready` label is Ready:

```bash
gh issue list --state open --limit 200 --json number,title,labels,assignees
```

Candidates are every open issue **without** the `ready` label. Skip issues another loop already
claimed — assignee set plus `in-progress` label.

**Either way, re-validate existing Ready items every run.** The snapshot or list is already in
hand, and drift happens: a decision marker or new blocker added after promotion demotes the item
back to Backlog with a comment. Demotion via `sassy-dog:github-issues`:
`issue-claim.sh demote N --comment "<the drift>"` — the comment is mandatory. Ready is a promise;
stale promises break dispatch-ready.

Read each candidate IN FULL — `gh issue view N --comments` — scope often lives in follow-up
comments.

### Suspected-complete tracking parents (board AND boardless)

An epic that split into children never closes itself. GitHub's automation moves on a merged PR's
`Closes #N` keyword, and a tracking parent is definitionally the issue no PR ever names — so its
children close one by one under their own PRs while the parent sits open indefinitely, counted as
pending work by every read of this backlog. One repo's grooming pass found four such issues among
its eight open (issue #198).

Detection is `sassy-dog:github-issues`' `stale-issues.sh`, detector
**`tracking-parent-complete`**: an open parent with ≥1 child — bodies carrying the literal
`Part of #<parent>` line §5 writes — where every child is CLOSED. Run it in this step whatever the
board mode; unlike the reconcile below, this pass has nothing to do with columns.

Each hit is **reported for a human to close — never groomed, never closed here.** List it as
`#<parent> — N children, all closed (#286 #287 …)` and drop it from the candidate list: refining an
issue whose work has already shipped does not merely waste the pass, it re-legitimises the issue
and the next reader trusts it again.

A `truncated: true` result means the detector's pull came back at its ceiling. Report that as
**unknown**, not clean, and re-run with a higher `ALL_LIMIT` — same rule as the reconcile join
below.

### Reconcile the board against issue state (board mode only)

**Skip this pass entirely without a `board:` block** — a boardless repo has no columns to reconcile,
and label drift is a separate question that is not in scope here.

Re-validation above asks *"is this still dispatchable?"*. This asks *"does this card still tell the
truth?"* — because the snapshot carries `status` but no issue **state**, so a column can assert
something its issue flatly contradicts. GitHub's built-in workflow only moves a card when a merged
PR closes the issue via `Closes #N`; an issue closed by hand — an epic, a duplicate, a won't-fix —
is never the target of such a line, so its card never moves and nothing else catches it.

One extra read closes the gap. Join it to the snapshot by issue number:

```bash
gh issue list --state all --limit 500 --json number,state,assignees
```

Raise the limit if the result comes back at the ceiling — a truncated join silently reports "no
drift", which is the failure this pass exists to end.

| # | Drift | Detection | Fix (on confirmation) |
| --- | --- | --- | --- |
| 1 | Closed issue, card in a non-Done column | `state == CLOSED` and `status != Done` | move card → **Done** |
| 2 | Open issue, card in **Done** | `state == OPEN` and `status == Done` | move card → **Backlog**, or **Ready** if it passes §3 this run |
| 3 | Card claimed (**In progress** / **In review**) with no assignee and no open PR | board `status` vs `assignees`, plus `gh issue view N --json assignees,closedByPullRequestsReferences` | move card → **Ready** or **Backlog**; the claim is stale |
| 4 | Open issue absent from the board | `gh issue list` minus the snapshot's items | add to board → **Backlog** |

Class 1 also constrains §2's candidate list: **a closed issue is never a grooming candidate.** Its
card sitting in Backlog *is* the drift — route it here, and never refine, promote, or report it as
work. Class 2's direction is the quieter one: a reopened issue stranded in Done vanishes from
planning entirely, because Done is the column nobody reads.

`closedByPullRequestsReferences` only sees PRs that wrote a closing keyword, so a branch in flight
under a PR with no `Closes #N` line reads as "no open PR". That is exactly why class 3 asks.

**Report always; act only on explicit confirmation.** Print the drift as one itemised list — issue ·
current column · issue state · proposed move — on *every* run, including runs where you change
nothing. Then:

- **Class 1** is safe and mechanical; it may be confirmed as a group.
- **Classes 2 and 3** carry judgement the board cannot answer — was the reopen deliberate? is that
  claim stalled or merely slow? — so confirm them **item by item** and never infer the answer.
- **Class 4** may be confirmed as a group, but show every issue number before asking.

Partial approval is the normal case: apply exactly what was confirmed, leave everything else
untouched, and carry each declined item into the §6 report so the drift stays named rather than
quietly dropped.

**Mutations go through `sassy-dog:github-issues`** (`references/board-graphql.md`) — card moves via
its `## Moving cards` recipe, board adds via `## Adding an issue to a board`. Wrap every mutating
call in `skills/pr-shepherd/scripts/gh-retry.sh`, as that reference mandates; the Projects GraphQL
endpoint flakes. Never hand-roll the GraphQL here. A move whose retries exhaust (exit 124), or one
whose card has since vanished, is recorded as `failed` and reported — not retried by hand, and not
fatal to the grooming run.

## 3. The dispatchability rubric

An issue is **Ready** only if ALL of these hold:

| # | Test | Failure action |
| --- | --- | --- |
| 1 | Problem + desired outcome stated in the body | Refine (§4) |
| 2 | Scope names real touchpoints (files/components/services), or enough pointers that a cold agent finds them in one recon pass | Refine (§4) — recon the codebase yourself, write the map in |
| 3 | Acceptance criteria checklist present | Refine (§4) |
| 4 | Self-contained: screenshots/attachments transcribed into prose, referenced docs committed on the default branch | Refine (§4); ask the user to paste any image you cannot read — until they do, the verdict is **parked: awaiting-user** |
| 5 | No open product decisions: no `(decision)` markers, no `## Open questions`, no "TBD" | Surface the decision with a recommended default; issue stays unpromoted until resolved |
| 6 | Right-sized: one coherent PR per issue | Epic → split (§5) |
| 7 | Dependencies recorded as literal `Depends on #N` lines, one per line | Add them — dispatch-ready enforces ordering from these lines |
| 8 | Touch-set annotated: a single machine-readable `touches:` line naming the repo-relative paths/globs the issue's PR will edit | Add it (§4) — dispatch-ready reads it to avoid dispatching two file-overlapping issues concurrently |
| 9 | Execution site declared where it matters: a body naming tools, hosts, credentials or paths that exist on **one workstation only** carries a `site:<name>` label | Apply the label (below) — or park it `operational (site <x>)` when the work is a human-run checklist that produces no PR |

GitHub `user-attachments` URLs are cookie-walled and unreadable from a worktree agent, which is why
test 4 demands transcription rather than a link.

A dependency being open does NOT block Ready — dispatch-ready sequences at dispatch time. Only
*unrecorded* dependencies block, because invisible ordering is how parallel agents collide.

### Rubric #9 — the execution site is a LABEL

**Grooming applies the `site:<name>` label; it never writes a `site:` line into the body.** The three
body contracts beside it — `touches:`, `Depends on #N`, `stack:` — are raw-line parses, and a raw
line can be *quoted*: an issue documenting this contract, or a template carrying an unfilled
placeholder, would declare a site by accident. A label cannot be quoted in prose, which is why
[#340](https://github.com/Sassy-Dog/skills/issues/340) put the site on one.

**Resolve a candidate's declaration by RUNNING the resolver, never by paraphrasing its rules.**
`sassy-dog:github-issues`' `queue-snapshot.sh` owns them, and a paraphrase forks them — one written
into a skill dropped the `strip()` and answered `" vdi"` where the script answers `"vdi"`, for a
label its own header calls legal ([#341](https://github.com/Sassy-Dog/skills/issues/341)).
§2's candidate pull already returned each issue's labels, so feed **those** through the emitter,
which runs no `gh` and touches no network. Re-fetching would cost one API call per candidate and
read a tree that has moved since the pull:

```bash
# Capture in the SAME Bash call as the read below — shell state does not survive between
# calls, and empty stdin makes `--sites-of` exit 64 rather than print `[]`.

# boardless: the `gh issue list --json ...,labels` result from §2.
CANDIDATES=$(gh issue list --state open --limit 200 --json number,title,labels,assignees)

# One candidate shown; run it per candidate — the pull holds up to 200.
jq -c '[.[] | select(.number == 1712) | .labels[].name]' <<<"$CANDIDATES" |
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh --sites-of

# board mode: `board-snapshot.sh` already carries each card's labels
BOARD_SNAPSHOT=$(PROJECT_NUMBER=<board.number> OWNER=<board.owner> \
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/board-snapshot.sh)
jq -c '[.items[] | select(.number == 1712) | .labels[]]' <<<"$BOARD_SNAPSHOT" |
  bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/queue-snapshot.sh --sites-of
```

**A resolver that could not run is UNKNOWN, never "no label".** `--sites-of` exits **10** when
`python3` is missing and prints **nothing** on stdout, while a genuinely unlabelled issue prints
`[]` and exits 0. Do not lean on that difference: empty stdout is also what a `jq` failure or
unbound input produces, and those exit **64**. Only the exit status separates the three
reliably. **Read the exit status, not the output.** On anything but 0, rubric #9
was not evaluated for that candidate: say so, and do not promote it on the strength of a check that
did not happen. Treating the silence as "no label" is the false-clean this whole rubric exists to
prevent, and it fails in the direction that promotes site-held work to Ready.

Grooming's candidates are **not** a `queue-snapshot.sh` bucket — the buckets are label-scoped
(`ready`, `in-progress`, `blocked`) and §2's candidates are precisely the issues that carry none of
them — so this emitter is the route, exactly as it is for `take-it` on an unpromoted issue.

**No label is the right answer for almost every issue.** An unlabelled issue runs anywhere, so add
one only when the body names something a second checkout genuinely cannot reach — a vendor SDK
installed on one host, a sibling checkout, network reach behind a VPN, a hardware device. Ordinary
repo work is not site-held, and a label applied "to be safe" is strictly a loss: it removes the
issue from every other checkout's queue and nothing reports that it did. **Never label defensively.**

**Never invent the name.** The site name is the user's — `vdi` carries meaning no platform string
does. Propose this checkout's configured `execution_site` when the tools the body names are the ones
*this* checkout has, and otherwise ask which site. Apply it with the plain label write, creating the
label first if the repo lacks it:

```bash
# Exact read, not a listing — 0 means it exists, 404 means it does not.
gh api "repos/<owner>/<repo>/labels/site:vdi" --silent
gh label create "site:vdi" --description "Work executable only from the vdi workstation"
gh issue edit N --add-label "site:vdi"
```

Three things about that create. **Ask about the one label, never a listing.** `gh label list`
defaults to **30** and sorts by *creation* order, so a freshly created `site:` label is exactly the
one a truncated read misses — reported absent with exit 0, after which the create hard-fails with
"already exists". Raising `--limit` only moves the edge. The exact read has no edge, and it is the
shape `github-issues`' `issue-claim.sh` already uses.

**An "already exists" failure is a branch, not an error.** The label is there, which is all this
step wanted: skip the create and go straight to `gh issue edit`. What must never appear is
`|| true`, which is precisely the silent no-op `scripts/test-label-taxonomy.sh` exists because of —
it swallows every *other* failure too.

**Never pass `--force`.** `gh label create` advertises it for the already-exists case, and with no
`--color` given it rewrites the existing label's colour **repo-wide** — a taxonomy mutation this
step has no business making, reached by trying to be tidy about an error that was already the
answer.

And **pass no `--color`**: `gh label create` then assigns a random one, so the label does carry a
colour — it is simply not a *chosen* one, and two repos will differ. That inconsistency is the
accepted trade. `site:` belongs to neither label taxonomy (`scripts/align-labels.sh` and
`github-issues`' `issue-claim.sh` own those), so naming a colour here would put a taxonomy value
outside its home, with nothing to reconcile it on a later run.

**Several `site:` labels NARROW; they never widen, and they are never a defect to tidy away.** Two
labels name two machines that may take the issue, and the dispatchers' test is membership —
`not sites or execution_site.lower() in sites` — so a multi-member declaration is a legal, useful
answer and passes rubric #9 like any other. **Never remove one to "resolve a conflict"**: that
strips the issue from a checkout the declaration explicitly named, which is a narrowing nobody
asked for and nothing reports. The one reading to refuse is the opposite one — several labels are
not "any site", which is the direction
[#322](https://github.com/Sassy-Dog/skills/issues/322)'s originating bug ran.

Widen or narrow the set only where the *work* changed, with the user, and say which direction you
moved it.

### The `parked: operational (site <x>)` verdict

Some site-held work is not a code change at all: a checklist a human runs against live
infrastructure, yielding no PR. That work is **never Ready**, however completely the rest of the
rubric is satisfied — dispatch-ready's model is "in flight until MERGED", and a task producing no PR
gives that loop nothing to converge on, so promoting it strands a dispatch slot indefinitely.

Park it `operational (site <x>)`, keep the `site:<name>` label on it so every plate still shows
where it belongs, and say in the report that the reason is its shape rather than its content. A
future body edit does not clear this verdict; only turning the work into something that ships a PR
does.

### Stack candidates (ONLY if `stacked_prs:` is configured)

**Skip this entirely when the config has no `stacked_prs:` block** — that is the default and it means
this repo has not opted in. Do not propose a stack because the chain looks like one.

A recorded `Depends on #N` chain is *not* automatically a stack. "Depends on" usually means **later**;
a stack means **ship together, as one worktree, merged bottom-up**. Propose one only when all hold:

| # | Test |
| --- | --- |
| 1 | The chain is **linear** — each issue depends on exactly one other, no fan-in or fan-out |
| 2 | The layers genuinely build on each other's code, not merely on each other's *decisions* |
| 3 | Depth ≤ `stacked_prs.max_depth` |
| 4 | Every member is otherwise Ready by the rubric above |

Then propose it to the user — never write it unprompted, because it changes how the chain dispatches
(one sequential agent instead of N parallel ones). On approval, add ONE line to the **bottom** issue,
naming every member including itself, bottom → top:

```text
stack: #101 #102 #103
```

Order is the merge order, so it is never sorted. It lives on the bottom issue alone; a copy on each
member is a second source of truth that drifts. Members above the bottom keep their `Depends on #N`
lines unchanged — the two contracts coexist, and a repo that later turns `stacked_prs:` off falls
back to dependency sequencing with nothing lost.

Fan-out or fan-in dependency graphs are exactly what stacks cannot express (a stack is a line, not a
tree). Leave them to dispatch-ready's dependency filter and say so rather than forcing a linearisation.

## 4. Refine

Per failing candidate:

1. Ground the scope in the codebase — dispatch `Explore` agents for recon when touchpoints are
   unknown. Never write a scope you haven't verified against real files.
2. Rewrite the body: preserve the original ask as a `> quote`, then problem, scope, touchpoints,
   acceptance, and dispatch-notes sections.
3. Write the **touch-set**: a single `touches:` line listing the repo-relative paths/globs the
   issue's PR will edit, distilled from the scope you just grounded and its `file:line` citations.
   Space-separated, globs allowed. Keep it to files that will actually change, not every file
   mentioned. This is the coupling signal dispatch-ready parses, so under-scoping it re-introduces the
   conflict churn it exists to prevent.
4. Record the repo gotchas a cold sub-agent needs — **from the verifier's output, never from the
   config field directly** (see below).
5. `gh issue edit N --body-file …` — edit the body, don't comment-and-hope.

Decisions are NEVER guessed: present each to the user as a recommendation with trade-offs, then
fold the answer into the body marked **Decision (date)** so it supersedes any `(decision)` marker.

### Verify the gotchas before they reach a body

`gotcha_summary` is the one config field nothing ever revisits: it is not derived, and it is not in
the `##` prose lane a human curates. So a status written there — "#334 (Windows + Authenticode)
remains" — stays asserted long after the issue closed, and the reader is a cold worktree agent with
no way to check it. One repo's config asserted three closed issues were open for nine days
(issue #249). Resolve it every time, never once per session:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/verify-gotcha-claims.sh \
  --config <repo-root>/.claude/sassy-dog/groom-backlog.md --repo <owner/name>
```

**Copy only the text between `--- BEGIN SAFE GOTCHAS ---` and `--- END SAFE GOTCHAS ---` into the
issue body.** Never the raw field, and never a dropped claim "with a caveat" — a caveat in a body a
cold agent reads as ground truth is not a protection.

Exit `3` means at least one claim was dropped: its cited issue is in the opposite state, could not
be resolved at all, or the field is `malformed` — an unpaired backtick run, which makes the whole
field unparseable and drops all of it (issue #262). Fragments of one sentence are
dropped together, and the split needs positive evidence of a sentence start, so a **neighbouring
invariant can go with a dropped one** — read the report, not just the safe block, when a gotcha you
expected is missing. Exit `3` **also** covers a splitter failure,
which prints `the claim splitter failed` and certifies nothing: when you see it, report the parse
failure rather than `gotchas dropped: none`, because nothing was verified at all. **Unresolvable is dropped too** — a missing `gh`, an unknown repo, a failed lookup.
Unknown is held, never passed through, so this gate has no skip: a verifier that degrades to
"assume fine" is worth nothing on the day it matters. Exit 3 does not fail the grooming run; the
surviving gotchas still go in, and every drop is named in §6.

A `KEEP time-varying` line is not a drop — it is a claim nothing here *can* resolve (an "as of
`<date>`", a roadmap position). It still goes into the body, and it is still a defect in the config:
report it and offer to fix the config with the user. The contract rule and the offline `--lint` mode
that finds these across a whole config are in `sassy-dog:setup-config` →
`references/config-contract.md`.

With `NO_CONFIG` there is no field to verify — the gotchas step is skipped and said so, per §1.

## 5. Epic split

A multi-workstream issue gets child issues — one per dispatchable unit — via the gated write path:
`sassy-dog:github-issues` `file-or-link-issue.sh`, marker `epic-split: #<parent>/<slug>`,
body containing `Part of #<parent>` (NOT `Closes`). Children then pass the §3 rubric individually;
the parent stays out of Ready, because it tracks rather than dispatches.

**Then write the children table onto the parent.** Without it the split is one-directional — the
children point up, the parent holds nothing — so a finished epic reads exactly like an untouched
one and its only remaining signal is that somebody remembers. Once the children exist, edit the
parent's body to carry a `## Children` section, one row per child:

```markdown
## Children

| Child | Title | State |
| --- | --- | --- |
| #286 | Extract the token-minting helper | closed |
| #287 | Route the sync workflows through it | open |
```

Write it through the body-file path §4 already uses — `gh issue edit "$PARENT" --body-file <file>`
— never a comment. **Refresh the State column on every later grooming pass**, from the issue state
the §2 pull already has in hand. The table is a snapshot, and a stale snapshot is worse than none:
it is the artifact a reader trusts *instead of* re-checking. The parent still stays out of Ready,
and the table is never a substitute for the §2 detector — the table is what a human reads, the
detector is what notices.

**Run splits FIRST in a grooming pass.** `Depends on #N` lines must point at dispatchable issues —
children, never a tracking parent — so an issue depending on "the schema part of epic #E" cannot
finalize its dependency line until #E's split has produced the child number.

## 6. Promote and report

**Before promoting, resolve each candidate's code references against the tree**
via `sassy-dog:github-issues`:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/github-issues/scripts/verify-issue-refs.sh <N> --tree <checkout> --format text
```

Exit `3` means at least one `likely-drift` finding — a symbol, package, or path
with a near neighbour in the tree that it does not match. **Fix the body and
re-run; do not promote on a 3.** Ready means dispatchable, and a body naming
`Store::open_at` where the method is `open_in` is not dispatchable, it just
reads that way. The suggestion is usually the whole fix.

This is the pass that catches **invented** references: bodies written from plans,
memory, or older issues while the tree moved underneath them. It cannot catch
**decay** — a reference that was correct when groomed and was renamed later — so
dispatch-ready re-runs the same check at dispatch. Neither gate substitutes for
the other.

`likely-new` findings are not a defect: an issue naming files it is asking
someone to create is doing its job. Read them, don't gate on them.

Exit `10` is a skip (no `python3`, no checkout to point `--tree` at), not a pass.
Say so in the report rather than recording a clean run.

**With `board:`** — move qualifying cards to **Ready** per `sassy-dog:github-issues`
(`references/board-graphql.md`), using the board IDs from config. Note this path never calls
`issue-claim.sh promote`, so it does **not** clear the residual claim assignee described below: a
board-configured repo accrues the same residue and nothing here removes it (issue #281).

**Without a board** — label qualifying issues `ready` via `sassy-dog:github-issues`, which
owns the label taxonomy and ensure-creates before use:

```bash
issue-claim.sh promote N1 N2
```

`promote` also clears a **residual claim assignee**, and only the one shape that is residue by
construction: assigned to exactly `@me` with **no** `in-progress` label. A reopened issue keeps the
assignee its last claim wrote, and `dispatch-ready` §4 then skips it as already claimed — false,
silent, and it never dispatches (issue #281). Any other assignee is **reported and left alone**: a
different login is a human who took it, and `@me` *with* `in-progress` is live in-flight work.
One limit worth knowing rather than rediscovering: `@me` is the *operator's* login rather than a
loop identity, so an issue the operator assigned to themselves without setting `in-progress`
matches the residue shape too (issue #287). The board path has its own note above.

Demotion is the reverse and **requires the reason**: `issue-claim.sh demote N --comment "<why>"`.
Never a silent strip.

Every promoted issue carries its `touches:` line from rubric #8.

Final table: issue · verdict (**Ready** / needs-decision / split → children / parked:
awaiting-user / **parked: operational (site `<x>`)** / parked: reason) · what changed.

A `parked: operational (site <x>)` row names the site it belongs to, so the verdict says *where*
and not only *why*. Never report it as blocked work — it is work that ships without a PR, and a
reader who mistakes it for a stalled issue goes looking for a branch that will never exist.

**Always add the suspected-complete line** from §2, on every run:

```text
suspected complete: #283 (8 children, all closed) · #284 (5 children, all closed)
```

Write `suspected complete: none` when the detector found none,
`suspected complete: UNKNOWN (pull truncated at ALL_LIMIT=<n>)` when it could not see the whole
repo, and `suspected complete: UNKNOWN (detector exited 10: <reason>)` when it could not run at
all — `stale-issues.sh` exits 10 for a missing `gh`, an unresolvable repo, or a failed pull, and
prints **no sections whatsoever**, so there is nothing to read a `none` out of. Those are the only
four values, and the line is never omitted — silence reads as "none", and so does picking `none`
because the run produced nothing to quote, which is precisely the assertion this detector exists
to stop the report making by accident. An exit 10 is the one case where the *absence* of output is
the finding.

**Always add the dropped-gotchas line**, on every run that refined at least one body:

```text
gotchas dropped: #334 (config asserts open, actually CLOSED) · #501 (cited, no checkable state)
```

Write `gotchas dropped: none` when every claim survived, and
`gotchas dropped: skipped (NO_CONFIG)` when there was no field to verify. A dropped claim is a
defect in `.claude/sassy-dog/groom-backlog.md`, not in the issue — name the config file and offer
to fix it. A `malformed` drop is the whole field at once and its reason names no `#N`, so report it
as `gotchas dropped: all (malformed — unpaired backtick run in gotcha_summary)` and fix it
before the next run. Never omit the line: a silent drop and a clean field look identical, and the
whole point of dropping is that somebody learns the config is wrong.

**With `board:`, add one board line** stating the board's end state rather than only the Ready
count:

```text
board reconcile: 3 moved (class 1×2, class 4×1) · 2 declined · 1 failed
```

Name every declined and failed item by issue number and drift class, so declining a fix leaves the
drift recorded instead of forgotten. Write `board reconcile: no drift` when the §2 pass found none.
**Never omit the line** — silence reads as "the board is fine", which is the assertion this whole
pass exists to stop making by accident.

End with the decisions awaiting the user, if any.

## Guardrails

- Never file new issues outside the §5 epic-split gate; synthesis of brand-new work is survey-work's
  job.
- Never close issues, and never delete content — the original ask always survives as a quote.
  Board **card state** may be reconciled, but only from the reconcile step and only on explicit
  user confirmation — never silently, and never in bulk without the list being shown first.
  This binds §2's suspected-complete parents too: a `tracking-parent-complete` hit is **reported
  for a human to close**, never closed here and never refined back into pending work — no matter
  how certain the evidence looks.
- Never promote with an unresolved decision "because the default is obvious" — the default goes to
  the user first.
- Never write a `stack:` line unprompted, and never write one at all without a `stacked_prs:` block.
- Never write a `site:` line into an issue body, never invent a site name, and never delete a
  `site:` label to reduce a multi-site declaration: rubric #9 applies a label, the name is the
  user's, and several of them narrow rather than conflict.
- Ready is a promise to dispatch-ready. When in doubt, park with a reason instead.

Apply any `## extra-rubric` section from config as additional Ready tests.

## If this repo had no config

### Offer to set this repo up

**Then, after the output above — not before it — offer once:**

- **If `.claude/skills/fill-it/SKILL.md` exists with a `generated-by:` marker** (the legacy
  generated-skills name) — this repo is on the
  superseded generated-skills architecture. Say so concretely: *"This repo has a generated
  `fill-it` I can migrate — I'd extract its config, show you the result, and remove the old skill
  only after you approve. Want me to?"*
- **Otherwise** — nothing to extract from: *"I can set this repo up. It takes a few questions about
  how this repo works. Want me to?"*

Naming which path applies matters: one of them ends in deleting a file the user may not know is
there.

On yes, delegate to `sassy-dog:setup-config`. **Never write config yourself** — the
refresher owns the contract, and a skill that writes its own forks the format the moment the
contract moves.

**Offer once per session.** Running deliberately in an unconfigured repo is legitimate; re-prompting
every invocation is noise. If declined, carry on and don't raise it again.
