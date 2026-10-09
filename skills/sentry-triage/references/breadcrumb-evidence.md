# Breadcrumb and event evidence (issue #489)

Read this when `SKILL.md` §5 sends you here (filing an escalation), or when a caller such as
`groom-backlog` re-validates an issue carrying a `sentry-source: <SHORT_ID>` marker.

## The rule

**"No stack trace" never means "no evidence."** An issue-level or event-level fetch
(`get_sentry_resource`) returns **no breadcrumbs** and says nothing about where they live. Crash
classes with no stack trace (iOS `WatchdogTermination`, OOM kills, app hangs) carry their only
diagnostic evidence in the breadcrumb trail and attachments. Before any event is called
undiagnosable, or any evidence step is handed to a human as "needs the Sentry UI", the catalog
tools below must have been tried.

Measured miss, 2026-10-09 (`VELOVATE-MOBILE-14`, Sassy-Dog/velovate#2344): a groom pass saw "no
stacktrace" and parked the issue for a human to open the Sentry UI. One `get_issue_breadcrumbs`
call per event showed all three events dying at the same pre-`runApp` startup step, which bounded
the cause and gave a shippable fix the same session.

## The catalog route

The breadcrumb tools are usually **not top-level MCP tools**. They are exposed through the Sentry
MCP's tool catalog: a catalog-search tool (`search_sentry_tools`) finds them, and an
execute tool (`execute_sentry_tool`) runs them. Resolve **by capability**, never a literal
`mcp__...` id:

1. Search the catalog for each capability: `get_issue_breadcrumbs`, `search_issue_events`,
   `get_event_attachment`. If the server exposes one at the top level, use that instead.
2. Run what the search returned through the execute tool, passing the org, issue and event IDs.
3. No Sentry MCP connected: `api-fallback.md` (REST) has the matching event, breadcrumb and
   attachment endpoints.

**If the catalog search does not return a capability, that is `UNKNOWN`, reported as such
(`breadcrumbs: UNKNOWN (catalog has no get_issue_breadcrumbs)`). It is never "needs human".** A
failed or empty call is reported the same way, with the reason. Unknown is not clean.

## The pull

1. `search_issue_events` for the issue: **every** event, with release, dist and device.
2. `get_issue_breadcrumbs` for the **latest** event, plus up to **2 earlier** events chosen from
   distinct users or distinct releases (so one noisy user cannot stand in for the class).
3. `get_event_attachment` when an event lists attachments and the breadcrumbs do not bound the
   cause.

## Body block

Add one compact block per sampled event to the escalation body, under a `## Breadcrumbs` heading.
Keep the last N (about 10) crumbs, oldest first, one line each. State when an event has none.

```markdown
## Breadcrumbs

Events: <total> across releases <r1, r2>. Sampled: 3.

### Event <event_id> · <release> (<dist>) · <device> · <timestamp>
- <time> <category> <message or data summary>
- ...
```

If the trails agree, say so in one line above the per-event blocks, e.g. "all three end at
`<last common crumb>`". If any pull returned `UNKNOWN`, the heading stays and carries that line
instead of the trail.

## Re-validation (callers)

For an open issue with a `sentry-source: <SHORT_ID>` marker, re-run the pull and report **new
events, new releases, and newly available evidence** (a trail or attachment the original body did
not have). A parked-for-insufficient-evidence issue with any of those is a candidate to unpark.
This is read-only against Sentry, like the rest of this skill.
