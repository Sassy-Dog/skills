# Scheduled routines — checking load state out of band

> **Moved, 2026-08-13.** The two sweep routines no longer clone this repo. They now source
> [`Sassy-Dog/routines`](https://github.com/Sassy-Dog/routines), where their
> prompts and cloud-adapted skill bodies are version-controlled. **Start debugging a sweep there,
> not here.**
>
> The reasoning below still stands and is why the move happened: since a plugin skill can never
> load in a routine (#175), the fallback path was the *only* path, and the bodies it read were
> written for an interactive laptop session — `gh` authenticated, whole portfolio checked out —
> neither of which exists in a routine container. `routines` carries versions written for
> that container, plus tested reducers replacing the ad-hoc parsing that repeatedly blew the
> tool-result token ceiling.
>
> The skills in this repo are unchanged and remain correct for interactive use. They and the copies
> in `routines` are now deliberately divergent — do not "resync" them.
>
> One consequence for this doc: the `Load:` field there reads
> `repo (routines@<short-sha>)`, not `plugin` / `fallback (degraded)`. The precedence rule
> below is unchanged and still applies.

Historical context follows, for the two routines as they ran until 2026-08-13. Each carried the
skill-load fallback clause required by [`AGENTS.md`](../AGENTS.md) so that a plugin-loading gap
produced a degraded run rather than a silent no-op (#97, #98).

| Routine | Invoked | Fallback body |
| --- | --- | --- |
| `daily-fire-watch` | `sassy-dog:whats-on-fire` | `skills/whats-on-fire/SKILL.md` |
| `weekly-portfolio-currency` | `sassy-dog:whats-behind` | `skills/whats-behind/SKILL.md` |

Routines are keyed by name here rather than by `trig_…` id. Two reasons: this repo is public, and
ids are **mutable** — replacing a routine mints a new id, so an id committed here goes quietly
wrong. Resolve the current id by name when you need it, from the Routines list in claude.ai or the
triggers API.

Note the asymmetry if you are scripting against routines: **delete exists only in the claude.ai UI,
not in the triggers API.** An agent can create a routine it cannot remove, so anything created
programmatically needs a human to finish the cleanup — disable it and rename it so the leftover is
unmistakable in the meantime.

The routine prompts were untracked config living behind the routines API, outside any repo — which
is precisely what the move fixed. They are now `routines/*.md` in `routines`, and what
remains behind the API is a thin pointer at those files. This doc covers the one thing that was
durable about a run even then: its log.

## The precedence rule

**Where the report and the run log disagree, the run log wins.**

There are two signals for whether a routine run loaded the plugin, and they are not equal:

- **The `Load:` field in the delivered report** (`plugin` / `fallback (degraded)`) is the run
  reporting on itself. It is cheap, it is visible in the artifact people actually read, and it is
  right almost always — but a run that is wrong about its own state will render it wrong, and a run
  under output pressure can drop it. Treat it as a convenience, never as proof.
- **The run log** is written by the harness, not by the model. It records what the Skill tool
  actually did. This is the authoritative signal, and the only one that survives a run being wrong
  about itself.

This is not a hypothetical ordering. On 2026-08-11 the weekly run
(`cse_01155VeBrfvMevpqUUuJLSSV`) delivered a complete, accurate-looking report with **no** degraded
note, while its own log showed the skill had failed to load. "No degraded note" was then briefly
taken as evidence that the plugin had loaded, which is exactly backwards — see #144 and #146.

**So: never date a regression, close a loading issue, or claim a fix landed from the report alone.
Read the log.**

## The out-of-band check

### The signature

A cloud session that could not resolve the plugin skill emits a `Skill` tool call that errors. The
literal pair, from run `cse_01155VeBrfvMevpqUUuJLSSV` (weekly, 2026-08-11):

```text
[15:03:03] tool_use Skill: {"skill":"sassy-dog:whats-behind"}
[15:03:03] tool_result ERROR: <tool_use_error>Unknown skill: sassy-dog:whats-behind</tool_use_error>
```

The load-bearing string is `Unknown skill: sassy-dog:` followed by the skill name. It is emitted by
the harness as a tool error, so it appears in the log whether or not the model ever mentions it.

### Where it appears

Near the **start** of the run, at the first `Skill` tool call — the routine prompts invoke the skill
before doing any work, so the `tool_use` / `tool_result` pair sits within the first few entries,
right after the prompt. A degraded run then continues: the fallback clause sends it to read
`skills/<name>/SKILL.md` with the Read tool, and every entry after that looks like a normal run.
That is why the tail of a degraded log is indistinguishable from a healthy one, and why the check
has to target the first Skill call rather than skimming for anything unusual.

### The recipe

1. Resolve the routine's current trigger id by name (table above), then get the run's session id
   (`cse_…`) from that routine's run history.
2. Open that session's log and search it for the literal `Unknown skill: sassy-dog:`. With the log
   saved to a file, that is `grep -n 'Unknown skill: sassy-dog:' <logfile>`.
3. Confirm the *first* `Skill` tool call in the run either succeeded or produced that error — a hit
   anywhere is conclusive for degraded, but a clean grep is only meaningful over the whole log.

### Reading the result

| Log | Report `Load:` | Verdict |
| --- | --- | --- |
| `Unknown skill: sassy-dog:<name>` present | `fallback (degraded)` | Degraded, correctly reported. |
| `Unknown skill: sassy-dog:<name>` present | `plugin`, or field absent | **Degraded.** The log wins; the report is wrong about itself — this is the 2026-08-11 failure. |
| Skill call succeeded, no such error | `plugin` | Loaded natively. |
| Skill call succeeded, no such error | `fallback (degraded)` | Loaded; the report is wrong. Log wins, but investigate — a run misreporting in this direction is still a bug. |
| Log unavailable | anything | **Unknown, not healthy.** Say so; do not promote the report to evidence. |

A missing log is not a passing check. The routine that produced no report at all in #97 is the
reminder: absence of a signal and a healthy signal are different states, and only one of them is
good news.

## Ruled out: the published artifact is not the fault (#162)

When a load gap turns up, the first instinct is to suspect the plugin — a bad manifest, a rename that
broke a path, a skill the publisher would refuse. **That was tested directly on 2026-08-11 and it is
not the cause.** Do not re-run this bisect; re-run the *install*, below, only if the manifest has
changed since.

Both sides of the suspected regression boundary install cleanly, tested through the same harness with
each tree exported by `git archive` into a throwaway
`CLAUDE_CONFIG_DIR` sandbox:

| Version | Commit | `marketplace add` | `install` | Inventory |
| --- | --- | --- | --- | --- |
| `2026.8.33` (pre-rename) | `15d60ee` | exit 0 | exit 0 | 20 skills, 9 agents |
| `2026.8.41` (post-rename) | `b5e0681` | exit 0 | exit 0 | 21 skills, 9 agents |

A clean `claude plugin marketplace add Sassy-Dog/skills` + `claude plugin install` against
the real GitHub marketplace at `main` also succeeds, and resolves the full inventory — including both
skills the routines invoke. The 20→21 delta is exactly epic #120 (`refresh-*` → `setup-*`, plus
`setup-repo`), not a loss.

**The local cache stalling at `2026.8.33` is a coincidence, not a signal.** There is no marketplace
auto-refresh — `lastUpdated` across registered marketplaces is scattered over months, each stamp a
manual action. `skills` last refreshed 2026-08-09, a day *before* the rename commits landed,
so it never saw a post-rename version to reject. It is stale because nobody ran
`claude plugin update`.

So a degraded run pointed at **cloud-side resolution**, not at the artifact. That line of inquiry is
now **closed** — see [#175](https://github.com/Sassy-Dog/skills/issues/175) for the full
ruled-out table. The short version, because it changes how you read every degraded run below:

- **There is no supported way to load a plugin skill in a routine session.** The routine-scoped
  `enabled_plugins` / `extra_marketplaces` fields accept correctly-typed API writes, return HTTP 200,
  bump `updated_at`, and persist nothing — at `create` as well as `update`. The routine edit UI has no
  plugins control at all. An account-level plugin install reaches interactive claude.ai sessions only:
  two verification runs, 20s and 5min after a confirmed install, were both degraded.
- **A degraded run is therefore the expected state, not an incident.** Do not open an issue for one.
  The fallback clause is permanent contract, and `Load: fallback (degraded)` on every run is correct
  output. What still deserves investigation is a run that produces *no* report, or one whose `Load:`
  field disagrees with its log.
- **Repo visibility was a real cause, of a different problem.** While this repo was `INTERNAL` the
  claude.ai account marketplace could not sync it at all (`Marketplace sync failed`), despite the
  `claude` GitHub App being installed org-wide for **All repositories** and an active SAML session for
  `Sassy-Dog`. Flipping the repo to `PUBLIC` fixed the sync on the first attempt. Neither SSO nor app
  scope was ever implicated — do not re-test those.

## Consumers of the posted report

`skills/work-fire-watch/SKILL.md` reads the newest `daily-fire-watch` post from Slack
`#daily-fire-watch` and works the items routed to the repo it runs in. What Slack delivers is
mrkdwn whose prose shape changes from day to day (bullets one day, inline runs the next), so the
consumer **never parses the prose**. The contract is a fenced machine block the routine **must
post as the first reply in every report's thread** — `fire-watch-v1`, one
`item|<repo>|<kind>|<id>|<tier>|<labels>|<title>` line per item plus `top|<rank>|<repo>|<kind>:<id>`
lines for the cross-product Top 5 — specified in full in that skill's §2. The producer resolves
the product→repo map, so the consumer's routing is one exact `repo` match. The producer side
landed in [routines#69](https://github.com/Sassy-Dog/routines/pull/69)
(closing #68) with the block at the end of the message body, and moved it to the thread reply on
2026-09-21; the consumer accepts the in-body form only on reports dated before that. A report
with no block reaches the consumer's stop, whose text is in the skill's §2 table.

```text
item|<repo>|<kind>|<id>|<tier>|<labels>|<title>
top|<rank>|<repo>|<kind>:<id>
```

The sentinels the consumer keys on, so that a producer-side edit is a visible two-repo change:

| Sentinel | Value the consumer expects |
| --- | --- |
| channel | `#daily-fire-watch`, id `C0BNNEE59PX` |
| poster | Slack user id `U0AAJ2WGMTQ` — the user-scoped connector the routine posts through; the trailing `Sent using` line is plain text and never evidence. Only that id's **newest sentinel post** is judged — never page past it to an older one; that id's ordinary chatter and any report-shaped post from another id are skipped and named. The same id is the only one whose **thread reply** counts as the block — its first reply, never a later one, never another id's |
| report first line | `Daily Fire Watch (YYYY-MM-DD)` — no leading `#` once Slack has rendered it |
| header lines, copied verbatim | `_Load: repo (routines@<sha>) · Sources: …_` and `_Coverage: …_` |
| machine block | **the first reply in the report's thread from the pinned poster** (since 2026-09-21; earlier reports carried it at the end of the message body, and the consumer still accepts that form): a fence opening with three backticks and `fire-watch-v1`, header `date=… run=… poster=… truncated=no\|yes`, then `item\|<repo>\|<kind>\|<id>\|<tier>\|<labels>\|<title>` and `top\|<rank>\|<repo>\|<kind>:<id>` lines; the block is bounded by Slack's 5000-char-per-element cap (a fence is one element), so `truncated=yes` means rows may be missing as well as prose — the producer drops the least urgent tiers first and never a `top`-named row |
| could-not-run post | first line contains `daily-fire-watch could not run.` (the routine prompt's missing-skill-body path; matched on the substring because Slack strips the Markdown around it) |
| anything else from the pinned poster | the consumer stops and prints the first line |

The routines repo's CI is the right home for a gate over this table — it can clone this repo
anonymously, while this repo's CI cannot authenticate to it ([#178](https://github.com/Sassy-Dog/skills/issues/178)). Here, `scripts/test-fire-watch-block.sh` pins, in both this file and
the consumer, the block name, channel id, poster id, the rendered first line, the could-not-run
line and the two block line shapes — not the header-line rows — plus the handle grammar the
block feeds. A change to any row
above lands **here first**, then in `routines`.

## What the in-report field is for

The `Load:` field is not redundant with this check — it covers the case nobody is investigating.
Most runs are read by a human glancing at Slack who will never open a session log, and for them a
degraded run needs to announce itself on the line they already read. The out-of-band check covers
the case where load state is being used as *evidence*: dating a regression, verifying a fix,
closing an issue. Use the field to notice; use the log to conclude.

Both report skills render the field on their header line:

- `skills/whats-on-fire/SKILL.md` §5 — `_Load: <plugin|fallback (degraded)> · Sources: …_`
- `skills/whats-behind/SKILL.md` §5 — `_Load: <plugin|fallback (degraded)> · Scanned: …_`

When either skill's output format changes, keep the field on the header line and keep the
precedence rule stated in both places — this doc and `AGENTS.md`. Dropping it from one leaves the
other reading like the whole contract.
