# Detection — probe table and evidence rules

`scripts/detect-hook-stack.sh` implements this table; run it rather than probing by hand. Output is
evidence, not truth — anything surprising gets confirmed with the user in Phase 2.

## The evidence rule

A tool is detected only on **repo evidence** — a config file, a manifest section, or tracked file
types — never on what is installed on the current machine. Committed hooks
(`.claude/settings.json`) execute on every teammate's machine; "ruff happens to be on this laptop's
PATH" is not evidence the repo wants ruff. The rendered dispatcher still self-guards every route
with `command -v <tool> || exit 0`, so a machine without the tool degrades to a no-op instead of a
hook error.

## Probe table

| Tool | Detected when | Routes | Trap |
|------|---------------|--------|------|
| `ruff` | `ruff.toml` / `.ruff.toml`, or `pyproject.toml` with a `[tool.ruff` section — AND tracked `*.py` | `*.py` → `ruff format` + `ruff check --fix`; unfixable findings exit 2 | Tracked `*.py` with no ruff config is reported but NOT detected — generating ruff for a repo that never adopted it imposes a formatter the team didn't choose. Say so and let the user opt in by adding config. |
| `prettier` | A `.prettierrc*` / `prettier.config.*` file, or a `prettier` key in `package.json` | `*.ts,tsx,js,jsx,mjs,cjs,css,scss,json` → `npx --no-install prettier --write` | `--no-install` on purpose: prettier must come from the repo's own `node_modules` (the repo pins its version); a bare `npx -y` would fetch latest and fight the pin. |
| `markdownlint` | A `.markdownlint-cli2.*` / `.markdownlint.*` config AND tracked `*.md` | `*.md` → `markdownlint-cli2 --fix`, then re-check; unfixable exit 2 | The version pin is **not optional** — see below. An unpinned `npx -y` resolves to latest and blocks on rules CI does not run. |
| `shellcheck` | Tracked `*.sh` (shellcheck in a CI workflow strengthens the evidence and is reported in `why`) | `*.sh` → `shellcheck -S warning`; findings exit 2 | Lint-only — never rewrites. There is no standard shellcheck config file, so tracked shell IS the evidence. |
| `dart` | A tracked `pubspec.yaml` **anywhere** in the tree | `*.dart` → `dart format` | Format-only; `dart analyze` is too slow per-edit. |
| `rustfmt` | A tracked `Cargo.toml` **anywhere** in the tree AND, for every directory with tracked `Cargo.toml` / `*.rs`, the NEAREST tracked `rustfmt.toml` / `.rustfmt.toml` declares `edition` (see below) | `*.rs` → `rustfmt` | Format-only; `cargo clippy` per edit is far too slow. Bare `rustfmt <file>` never reads `Cargo.toml`: with no `edition` in a rustfmt config it formats as **edition 2015** (parse errors on 2018+ syntax, swallowed by the route's error suppression, and 2015-style reordering that fails `cargo fmt --check`). A `Cargo.toml` with no declaring config is reported NOT detected, with the fix in `why` and `detect_failures`. |
| `gofmt` | A tracked `go.mod` **anywhere** in the tree | `*.go` → `gofmt -w` | — |
| `dotnet_format` | Tracked `*.sln` / `*.csproj` | `*.cs` → `dotnet format --include <file>` | **SLOW** (solution load per invocation) — always opt-in via the Phase 2 interview, never auto-included. |

## rustfmt needs a declared edition (issue #569)

rustfmt resolves its config by walking **up** from the formatted file's directory to the nearest
`rustfmt.toml` / `.rustfmt.toml`, and **uses only that one**: configs are never merged, so a nearer
config without `edition` shadows a declaring ancestor, and within one directory `.rustfmt.toml` wins
over `rustfmt.toml`. The probe mirrors that: for every directory holding a tracked non-vendored
`Cargo.toml` or `*.rs` file (`.rs` too, because a config can sit below the crate root, such as
`crates/b/src/rustfmt.toml`), walk up to the first directory with any tracked config (the effective
one) and require **that** config to hold an uncommented `edition =` line (`style_edition` does not
count). A root config therefore covers a workspace only where no nearer config exists. The route is
a single `*.rs` case for the tree, so one uncovered directory withholds it, and the skip reason names
that directory and, for a shadowing config, where it is. The edition is deliberately **not** read from `Cargo.toml` and passed as `--edition`:
that is a configured fact that drifts when the edition moves. In the preview, state the skip and the
fix: add a `rustfmt.toml` holding `edition = "<the crate's edition>"`, then re-run.

## Manifest probes are monorepo-safe (`dart` / `rustfmt` / `gofmt`)

These three match a **path regex over the tracked tree**, anchored with `(^|/)`, not a root-only
file test. A `[ -f pubspec.yaml ]` (or a bare `pubspec.yaml` pathspec) matches the repo root only,
which reported "no dart" for every monorepo in the org — velovate keeps its Flutter app at
`apps/mobile/`, so the render carried no `*.dart` route and nothing errored. For dart and gofmt the
`why` string names the file that matched, because in a monorepo *which* manifest armed the route is
the useful fact; rustfmt's `why` names the directory of the config(s) that covered it instead (or the
uncovered directory when skipped).

**A vendored example manifest is not a project.** Scaffolder templates, test fixtures and sample
projects commit real-looking manifests, so the corpus drops
`templates?|fixtures?|__fixtures__|testdata|test-?data|examples?|node_modules` path segments first —
the same exclusion `setup-deps`' `detect-ecosystems.sh` carries, and excluding by *directory name*
rather than depth is what keeps `packages/app/Cargo.toml` counting. A manifest found **only** under
an excluded path is not detected, and says so in both `why` and `detect_failures` rather than
vanishing.

## Every path probe reads one corpus — never its own pipeline

`ALL_TRACKED` is read once and every probe matches against it with a herestring. That is a
correctness requirement, not tidiness. The probe used to be
`git ls-files "<glob>" | head -1 | grep -q .`, and under the script's `set -o pipefail` that
**inverts its own answer on large repos** (issue #172): `head`/`grep -q` exit on the first line, and
if the match list is bigger than the ~64KB pipe buffer the writer is still going, takes `SIGPIPE`,
and `pipefail` makes the writer's **141** the pipeline's status. A match returns non-zero, reads as
a miss, and the render simply carries no route for that tool — nothing errors.

It flips somewhere between 1000 and 2000 paths, so it is invisible in every small-repo check and
wrong exactly on the biggest repos, where a dropped route costs most (`git ls-files "*"` in
velovate's 2787-path tree exits 141). All five glob probes — `*.py`, `*.md`, `*.sh`, `*.sln`,
`*.csproj` — were exposed; the manifest probes never were, because they already read the corpus.
`scripts/test-detect-hook-stack.sh` pins this against a 20k-path fixture and rejects any pipeline in
the `has_tracked` definition.

## The markdownlint version pin (`pin` / `pin_source`)

`tools.markdownlint` carries two extra probe fields beyond `detected` / `why`:

| Field | Value |
|-------|-------|
| `pin` | The discovered markdownlint-cli2 spec — a version (`0.18.1`) or a range (`^0.18.1`). Empty string when nothing was discoverable. |
| `pin_source` | The file the pin came from, e.g. `scripts/preflight.sh`, or `package.json (dependency range)`. Empty when `pin` is empty. |

**Why it exists.** `npx -y markdownlint-cli2` resolves to **latest at hook time**. A repo whose CI
pins an older release gets a hook that blocks on rules CI does not have — measured: CI on `0.18.1`,
hook resolving `0.23.2`, `MD060` (which does not exist in `0.18.1`) flagging six errors on a README
CI calls clean. The exit-2 contract is the whole value of the hook; a hook that fires on rules
nobody enforces trains the user to ignore exactly that signal, and it fails *silently* — nothing
else compares the hook's resolved version against CI's.

**Search order** (first explicit `markdownlint-cli2@<spec>` wins):

1. `.github/workflows/*.yml` / `*.yaml`
2. The shell scripts those workflows invoke — **one hop**, matching `*.sh` paths in the workflow
   text and keeping the ones that exist. This catches the common "CI calls `scripts/preflight.sh`"
   shape, where the workflow itself never names a version. (This repo is exactly that case:
   `MARKDOWNLINT_PKG="markdownlint-cli2@0.18.1"` lives in `scripts/preflight.sh`.)
3. `Makefile` / `makefile` / `GNUmakefile`, then `justfile` / `Justfile` / `.justfile`
4. `package.json` — an explicit `markdownlint-cli2@<spec>` anywhere in it (typically an npm script)
5. Fallback: the `package.json` dependency range —
   `devDependencies["markdownlint-cli2"]`, else `dependencies["markdownlint-cli2"]`

**No pin discoverable → render fix-only.** The probe appends a `detect_failures` note and the render
drops the blocking half (see `templates/sassydog-post-edit.template.sh`, the nested
`MARKDOWNLINT_BLOCKING` block). Fixing silently is always safe; blocking on rules CI does not run is
not. Say so in the Phase 3 preview so the downgrade is visible, not silent — the fix is for the repo
to pin its own version, after which a refresh renders the blocking half back in.

Prettier needs no equivalent field: it renders `npx --no-install`, so the repo's own lockfile is
already the pin.

## Refresh-mode signal

`existing_generated_hooks` in the probe output lists `.claude/hooks/sassydog-*.sh` files already
present — non-empty means refresh mode (re-render + reconcile), empty means create mode.

## Multi-stack repos

A repo detecting several tools still gets ONE dispatcher with several routes — never one hook entry
per tool. One settings entry, one script, extension routing inside; that keeps the ownership
contract trivial (everything the generator owns references `sassydog-`).
