# Orchestration

How the main agent dispatches review agents, what each returns, and how findings become issues.

## Agent → domain map

Dispatch only the agents with signal for the detected stack. All ship with this plugin and namespace as `sassy-dog:<name>`.

| Agent (`subagent_type`) | Owns rubric areas | Dispatch when |
|---|---|---|
| `sassy-dog:architecture-reviewer` | 2 structure, 3 architecture, 13 team/scaling | always |
| `sassy-dog:code-quality-reviewer` | 4 code quality, 12 tech debt | always |
| `sassy-dog:security-reviewer` | 5 security (app + supply chain + pipeline + ops) | always |
| `sassy-dog:testing-reviewer` | 7 testing | always |
| `sassy-dog:cicd-release-reviewer` | 8 CI/CD & release | `.github/workflows/` or other CI config present |
| `sassy-dog:infra-platform-reviewer` | 9 infrastructure & platform | `*.tf`/`*.bicep`/`Dockerfile`/k8s manifests present |
| `sassy-dog:observability-ops-reviewer` | 10 observability & operations | always (light if app is tiny) |
| `sassy-dog:dx-docs-reviewer` | 6 DX, 11 docs | always |
| `sassy-dog:dependency-supply-chain-reviewer` | 5 supply-chain slice, 12 dep debt | a lockfile/manifest is present |

**Dispatch rule:** issue all selected agents in **one message, multiple Agent calls** (concurrent), each at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`). Give each: the absolute repo path, the detected stack summary, the dedupe index is *not* needed by agents (you dedupe centrally), and an instruction to return **only** the JSON object `{"findings": [...]}` in the schema below as its final text, with no Markdown fences or surrounding prose. Tell each agent it is in **audit mode**: find what's wrong, cite evidence, do not propose to write code.

## Dispatch outcomes (Phase 1)

Every domain in the table above gets an **outcome**, recorded as the fan-out returns. Together they are the run's **ledger**: built in Phase 1, carried through Phases 2 and 3 unchanged, and printed in Phase 4's preview before the approval prompt.

Three outcomes belong to the fan-out itself:

| Outcome | What it means | Reviewed |
|---|---|---|
| `returned` | The agent came back with a JSON object containing a `findings` array in the schema below — empty or not | yes |
| `no report` | The dispatch succeeded but returned no usable envelope (bare JSON object, or exactly one fenced block holding it with only whitespace outside): prose before or after the object (fenced or not), two or more fences, a fence that does not close, missing final text, malformed JSON, JSON `null`, missing `findings`, null/non-array `findings`, a legacy bare array, or invalid finding entries | **no** |
| `could not dispatch` | The Agent call errored, timed out, or the agent could not be resolved | **no** |

A fourth records a decision taken *before* the fan-out: `not dispatched`, for a domain the Phase-0 stack detection found no signal for. Record it with the reason that skipped it.

**A domain whose outcome is not `returned` is DARK, and a dark domain is never scored as clean and never reported as "no findings".** Those are the two claims this audit is not entitled to make about a domain nobody reviewed. Name it, name its outcome, and say that this run does not cover it. Keep `not dispatched` visibly apart from the two dark outcomes: a domain skipped for cause and a domain that went dark are indistinguishable once both are merely missing from the Epic, and only one of them is a decision somebody made.

**This is the sibling of the diff-scoped rule, not a copy of it and not derived from it.** `agents/pr-review-orchestrator.md`, Step 5, scores a lost reviewer's surface `!` in a report a human reads while the context is still live; a hole there costs a re-run. This path **writes**. Its artefact is a filed Epic and its child issues, which becomes the durable record of what is wrong with the repo — so a lost `security-reviewer` here yields a backlog that omits an entire domain and **reads complete** to everyone who finds it later. Same question, different consequence: neither rule is evidence about the other, and changing one does not license changing the other ([#280](https://github.com/Sassy-Dog/skills/issues/280), [#284](https://github.com/Sassy-Dog/skills/issues/284)).

**A dark domain is surfaced, not a veto.** It never stops the run and never blocks filing: findings that did come back are still verified, grouped, previewed and — on approval — filed. The human was always the gate here; what was missing is that they were not told a domain went dark. Re-dispatching a dark domain is allowed **while Phase 1 is still running**, and the ledger then records the outcome of the last attempt — a domain that comes back on a retry is `returned`. Once Phase 2 begins the ledger is fixed: Phases 2 and 3 never add a domain, clear one, or re-open the fan-out.

## Finding output schema

Each agent returns a JSON object `{"findings": [...]}` in both audit and diff-scoped mode. A returned final text is a **usable envelope** only when, after trimming surrounding whitespace, it is either (1) a bare JSON object, or (2) exactly one fenced block (` ```json ` or a bare ` ``` `) with only whitespace outside it whose contents are a JSON object. A fence is a line that begins with three backticks, outside any JSON string value; a triple backtick inside a string value is neither a fence nor prose. Anything else is unusable and the cause is named: prose before or after the object (fenced or not), two or more fences, a fence that does not close, or JSON that fails the schema. Reviewers must still return a bare object; consumers accept one fence only so a completed review is not discarded, never as licence for reviewers to fence. Accept the object only when `findings` is an array and every entry satisfies the existing finding schema; never coerce an unusable result to empty findings or salvage a partial array. Unwrap usable `findings` into Phase 2 verification without changing its fields. Each finding:

```
- title:            imperative, PR-sized ("Pin GitHub Actions to commit SHAs")
  area:             one of the 15 rubric areas
  severity:         critical | high | medium | low
  likelihood:       high | medium | low
  evidence:         one or more "path/to/file.ext:LINE" with a 1-line quote/why
  why_it_matters:   concrete consequence in THIS repo (not generic)
  proposed_fix:     what a PR would do
  acceptance:       how we'd know it's fixed
  pr_size:          xs | s | m | l   (l = consider splitting)
  labels:           suggested labels from the taxonomy
  confidence:       0.0–1.0  (agent's own confidence the finding is real)
```

Agents that find nothing in their domain return `{"findings": []}` — that is a valid, useful result, **and it is a result only once you have received it**. A completed empty envelope that arrived is a clean domain; missing or unusable output is a dark one. The ledger above is the only thing that tells them apart, which is why it is recorded rather than inferred from what the Epic ended up containing.

## Adversarial review (Phase 2)

For each finding, in order of severity:

1. **Verify evidence** — open the cited `file:line`. If it doesn't say what the finding claims → drop.
2. **Genuine vs. preference** — is this a real risk, or a style opinion / valid convention? Drop preferences.
3. **Recalibrate** — adjust severity/likelihood to reality; downgrade theoretical threats.
4. **Dedupe vs. existing issues** — compare against the Phase-0 GitHub index (title + body similarity, same file/area). If already tracked → mark `duplicate-of #N` (comment later, don't refile).
5. **Dedupe vs. siblings** — merge near-identical findings from different agents.
6. **Refute pass (high-impact only)** — for `critical`/`high`, optionally dispatch 1–3 skeptic subagents at tier `terra` (Claude Code: `model: "sonnet"` · omp: `model: "@task"`), each told to *try to prove the finding wrong* (distinct lenses: exploitability, does-it-reproduce, is-it-already-mitigated). Keep the finding only if it survives a majority.

Survivors carry a final `confidence`. Drop anything below ~0.6 unless severity is `critical`.

## Grouping into PR-sized issues (Phase 3)

- Cluster survivors that a single PR would naturally fix together (same subsystem, same kind of change). Each cluster → one child issue; list its findings as a checklist in the body.
- A single `l`/`xl` finding may be its own issue with a "split into N PRs" note.
- Keep clusters cohesive: don't bundle unrelated areas just to reduce issue count.
- Order issues by ROI (severity × likelihood ÷ effort) for the Epic's top-10.

Then proceed to `references/github-issue-ops.md` for filing.
