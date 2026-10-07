#!/usr/bin/env bash
# test-verify-issue-refs.sh — proves the grooming-drift checker on the
# reference shapes that actually shipped past review in a production drain, on
# the false-positive shape that made a correct issue unpromotable (#199), and on
# the shell-repo shape whose symbol pool held no shell names at all (#263), and
# unpooled enum variants and fields whose mention check missed on macOS (#479).
#
# Provenance: the shapes are real, both fixture trees are synthetic. Each case
# below is a de-identified reduction of a body that reached the Ready column of
# Sassy-Dog/solador — or, for the shell tree, of the Sassy-Dog/platform body that
# hit #263 — and sent a worktree agent looking for something that was not there.
# A real checkout cannot be a fixture here — this repo has no Rust tree, and
# pinning one would couple these tests to another repo's refactors, which is the
# very coupling the checker exists to detect.
#
# THREE trees, and the second is not a variation on the first. `$TREE` is a
# Rust/TypeScript fixture (cases 1-7, 13, 15b, 16, 18, and case 14's rule-1 proof);
# `$SHTREE` is shell-majority (cases 8-12 and the rest of case 14); `$MAGIC` is
# one real script beside three hostile tracked FILENAMES (case 15) and is the
# only cover for the pathspec-magic empty-pool mode. Case 17 reads source, not
# a tree. A harvest that sees
# no shell definitions at all was invisible to every case in the first tree,
# which is how it survived — see the section header above case 8. (Go is named
# in #263's acceptance but is NOT covered by any of them: `func` is not even in
# the keyword alternation, so nothing here measures it.)
#
# The load-bearing assertions are the NEGATIVE ones. A checker that flags
# everything is trivially "correct" on drift and useless in practice, because it
# gets muted within a day. So the clean-body case and the new-subtree case are
# what actually keep this honest: they must stay quiet while the drift cases
# fire.
#
# Guarded here rather than left to review because these failure modes are
# SILENT. `\b` in a git -E pattern harvests zero symbols on macOS — and works on
# Linux, measured, which is worse than a flat break: a full pool on CI and an
# empty one on the machine actually doing the grooming — after which every
# lookup returns "no near match", so the checker keeps running, keeps exiting 0,
# and has simply stopped working. #263 is that same silence one turn further on:
# a pool that is full, and full of the wrong languages. Nothing in the output
# distinguishes either from a clean run.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-verify-issue-refs.sh
#
# It costs ~6s of preflight's ~39s, up from ~0.7s: three git fixtures and ten
# mutants, each of which runs the checker. That is the price of the mutation
# proofs, and it is recorded here so a future reader weighs it deliberately
# rather than discovering it.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-verify-issue-refs: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SCRIPT="skills/github-issues/scripts/verify-issue-refs.sh"
[ -f "$SCRIPT" ] || { echo "test-verify-issue-refs: $SCRIPT missing" >&2; exit 1; }

# A courtesy skip locally; a hard failure under CI, where `preflight.sh` renders
# exit 0 as PASS and a missing interpreter would void all of it silently. Same
# split as test-template-actionlint.sh.
if ! command -v python3 >/dev/null 2>&1; then
    echo "test-verify-issue-refs: python3 not installed" >&2
    [ "${CI:-}" = "true" ] && exit 1
    echo "skipped: python3 not installed" >&2
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
# Neither a pass nor a failure: a machine-capability gap, named so it cannot be
# read as a green tick. Used only where the interpreter under test is absent.
SKIPS=0
skip() { printf '  skip %s\n' "$1"; SKIPS=$((SKIPS + 1)); }

# --- the fixture tree -------------------------------------------------------
# Shaped to make each rule distinguishable from the others:
#   crates/store/src/lib.rs   a real file, with a real `open_in` method
#   crates/store/Cargo.toml   a package whose name carries the org prefix
#   app/src-tauri/src/        a real directory holding github.rs and nothing
#                             resembling repos.rs — so a near-match sibling and
#                             a bare "the directory exists" are separable
#   app/ui/                   a real directory holding one `sample-*-stale.json`
#                             fixture, the solador #338 shape: a second one
#                             beside it IS a near match by name and must still
#                             not gate when it arrives via `touches:`
#   app/ui/panel.ts           a TypeScript method shorthand — the SAME line
#                             shape a POSIX shell definition wears (#263). It is
#                             what lets case 13 fail at all: without it this tree
#                             holds nothing for a shell harvest to find, so an
#                             unscoped harvest is indistinguishable from a scoped
#                             one here. Its name is deliberately NOT a token any
#                             other case probes: naming it `open_at` put that
#                             token in the tree, where the mention fallback
#                             resolves it (historically only on Linux), and
#                             case 3's DRIFT silently stopped happening on CI.
TREE="$WORK/tree"
mkdir -p "$TREE/crates/store/src" "$TREE/app/src-tauri/src" "$TREE/app/ui"
cat > "$TREE/crates/store/src/lib.rs" <<'RS'
pub struct Store {}
impl Store {
    pub fn open() -> Self { Self {} }
    pub fn open_in(dir: &str, flag: bool) -> Self { let _ = (dir, flag); Self {} }
}
RS
cat > "$TREE/crates/store/Cargo.toml" <<'TOML'
[package]
name = "solador-store"
version = "0.1.0"
TOML
cat > "$TREE/app/src-tauri/src/github.rs" <<'RS'
pub fn repos_view() -> u8 { 0 }
pub fn runners_view() -> u8 { 0 }
pub enum RepoStatus {
    NeedsApproval,
}
pub struct RepoState {
    pub retry_count: u8,
}
// LongerNeedsApprovOnly other_galactic_zebra_suffix
RS
echo "body { color: #fff; }" > "$TREE/app/ui/app.css"
cat > "$TREE/app/ui/panel.ts" <<'TS'
export class Panel {
  render_at() {
    return 1;
  }
}
TS
echo '{"stale": true}' > "$TREE/app/ui/sample-azure-stale.json"
if ! ( cd "$TREE" && git init -q . && git add -A && \
       git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture ) >/dev/null 2>&1; then
    fail "fixture tree: git build failed — the cases below would report exit 10, not a real verdict"
fi

# Sets OUT and RC in the CALLER's scope. Deliberately not `RC=$(run ...)`: a
# command substitution runs in a subshell, so OUT would never escape it — and,
# worse, the EXIT trap above fires when that subshell ends and deletes the
# fixture tree out from under every later case. The first symptom is a run of
# `exit 10` (skipped) results that look like assertion failures and are not.
run() {
    OUT="$(bash "$SCRIPT" --body-file "$1" --tree "$TREE" --format text 2>&1)"
    RC=$?
}

# --- case 1: a bare "the parent directory exists" does NOT gate -------------
# This case used to assert the opposite, and the comment above it argued that
# LOCATION was the only usable signal for a name like `repos.rs`. Issue #199
# reversed that judgement on evidence: the same rule fires on every new file
# added to an existing directory — the ordinary shape of an issue asking
# someone to create something — deterministically, every tick, until the
# operator learns to skim past the gate. The accepted trade-off is written down
# here rather than only in the issue: an invented path with nothing resembling
# it in its directory (exactly `repos.rs`) now goes UNCAUGHT, and that is
# cheaper than a gate nobody reads. Drift still fires on evidence — case 1b.
cat > "$WORK/b1.md" <<'MD'
The per-repo view lives in `app/src-tauri/src/repos.rs`.
MD
run "$WORK/b1.md"; rc=$RC
if [ "$rc" = 0 ] && echo "$OUT" | grep -q 'new .*repos\.rs'; then
    pass "missing file with no similar sibling is new, not gated"
else
    fail "parent-exists alone must not gate (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 1b: a near-match sibling IS evidence, and is suggested -------------
# The half of the old rule worth keeping. `githb.rs` sits beside a real
# `github.rs`: the directory itself supplies the near match, so this tiers
# drift on the same footing as a renamed method — with a suggestion attached,
# which is what makes the finding actionable rather than merely alarming.
cat > "$WORK/b1b.md" <<'MD'
The GitHub client lives in `app/src-tauri/src/githb.rs`.
MD
run "$WORK/b1b.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `app/src-tauri/src/github\.rs`'; then
    pass "near-match sibling is drift, and the sibling is suggested"
else
    fail "sibling-evidence drift + suggestion (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 1c: a `touches:` path is never drift ------------------------------
# The solador #338 shape, and the reason #199 was filed. `sample-usage-stale.json`
# scores ~0.83 against the real `sample-azure-stale.json` beside it, so case 1b's
# rule would gate it — but `touches:` is a forward-looking declaration of what
# the PR will WRITE, so a file it names is expected to be absent. Origin beats
# similarity here; drop the origin tracking and this case fails.
cat > "$WORK/b1c.md" <<'MD'
Add the stale fixtures beside the existing one.

touches: app/ui/sample-usage-stale.json app/ui/sample-cronmonitors-stale.json
MD
run "$WORK/b1c.md"; rc=$RC
if [ "$rc" = 0 ] && echo "$OUT" | grep -q 'new .*sample-usage-stale\.json' \
   && ! echo "$OUT" | grep -q 'DRIFT'; then
    pass "touches: paths are reported as new even beside a near match"
else
    fail "touches: path must never gate (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 2: new subtree is NOT drift ---------------------------------------
# Same rule, other branch. An issue asking for a brand-new crate names paths
# under a directory that does not exist yet; gating on those would gate every
# greenfield issue in the backlog.
cat > "$WORK/b2.md" <<'MD'
Add the crate at `crates/crashreport/src/lib.rs` and wire it up.
MD
run "$WORK/b2.md"; rc=$RC
if [ "$rc" = 0 ] && echo "$OUT" | grep -q 'new .*crashreport'; then
    pass "path under a missing directory is reported as new, not gated"
else
    fail "new subtree must not gate (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 3: near-miss method name, with the rename suggested ---------------
# `open_at` vs the real `open_in` scores 0.714. This is the case that pins the
# 0.70 cutoff: at difflib's idiomatic 0.6 unrelated identifiers start pairing,
# and at a tidier 0.75 this exact rename slips through as "new".
cat > "$WORK/b3.md" <<'MD'
Open it with `Store::open_at` before reading settings.
MD
run "$WORK/b3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `open_in`'; then
    pass "renamed method is drift, and the rename is suggested"
else
    fail "renamed method + suggestion (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# The suggestion must be the RENAME, not the shortest near neighbour. Plain
# difflib ranks `open` (0.727) above `open_in` (0.714) because it is shorter,
# and a confidently wrong suggestion is worse than none — it is the line a
# reader acts on without re-checking.
if echo "$OUT" | grep -q 'did you mean `open`?'; then
    fail "suggestion ranked the shorter neighbour over the rename"
else
    pass "suggestion prefers shared prefix over raw ratio"
fi

# --- case 4: package name missing its workspace prefix ----------------------
# An acceptance command that cannot run. `-p` is read inside fenced blocks
# precisely because that is where acceptance criteria live.
cat > "$WORK/b4.md" <<'MD'
## Done when
```
cargo test -p store
```
MD
run "$WORK/b4.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `solador-store`'; then
    pass "unprefixed package is drift, and the real name is suggested"
else
    fail "unprefixed package + suggestion (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- b6: not a case of its own — the body case 13 and the scope proof need ---
# `render_a` appears NOWHERE in this tree, and `render_at()` is a TypeScript
# method the shell harvest must not see. Correctly scoped, this is `new` on
# every platform; unscoped, `render_at` enters the pool and answers it.
cat > "$WORK/b6.md" <<'MD'
Add `render_a()` beside the existing panel methods.
MD

# --- case 5: a correct body stays silent ------------------------------------
# The assertion that decides whether anyone leaves this enabled.
cat > "$WORK/b5.md" <<'MD'
Open the store with `Store::open_in`, defined in `crates/store/src/lib.rs`.

## Done when
```
cargo test -p solador-store
```

touches: crates/store/src/lib.rs app/ui/**
MD
run "$WORK/b5.md"; rc=$RC
if [ "$rc" = 0 ] && ! echo "$OUT" | grep -q 'DRIFT'; then
    pass "a body whose references all resolve exits 0 silently"
else
    fail "clean body must not report drift (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 6: the fixture can populate a pool at all -------------------------
# A FIXTURE-ADEQUACY floor, not a guard on the shipped harvest — the distinction
# matters because the label used to claim the latter. It runs its own copy of the
# regex, so emptying `KEYWORD_SYMBOLS` in the script leaves it green; what
# catches that are cases 3, 8 and 14a, which read the script's actual output.
# What this does catch is a fixture that stopped containing definitions, which
# would make those cases pass against nothing.
POOL_COUNT=$(git -C "$TREE" grep -hoE \
    '(^|[^A-Za-z0-9_])(fn|def|function|class|struct|enum|trait|type|interface|const)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    -- . 2>/dev/null | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')
if [ "${POOL_COUNT:-0}" -ge 4 ]; then
    pass "definition harvest finds symbols ($POOL_COUNT in the fixture)"
else
    fail "definition harvest returned $POOL_COUNT — the near-match pool is empty"
fi

# --- case 7: usage errors are distinguishable from findings -----------------
bash "$SCRIPT" --body-file "$WORK/b5.md" --tree "$TREE" --format bogus >/dev/null 2>&1
[ $? = 64 ] && pass "bad --format exits 64, not 3" || fail "bad --format should exit 64"

bash "$SCRIPT" --body-file "$WORK/b5.md" --tree "$WORK/definitely-not-here" >/dev/null 2>&1
[ $? = 10 ] && pass "missing tree exits 10 (skipped), not 3" || fail "missing tree should exit 10"

# ===========================================================================
# The shell tree (issue #263)
# ===========================================================================
# Everything above runs against a Rust/TS-shaped fixture, and that is exactly
# how the harvest could be keyword-only for months with nothing here going red:
# a POSIX shell function definition carries no keyword, `name() { … }` matches
# none of the `(fn|def|function|class|…)` alternation, and no fixture above ever
# contained one. Measured on Sassy-Dog/platform, whose primary language is bash:
# 368 names in the pool, and 257 distinct POSIX-form definition names across 330
# definition lines in tracked `*.sh`, not one of them harvested (#263's table
# counts 253: the same tree on the same day, counting distinct names of
# COLUMN-0 definitions only — the unit is what differs, so each figure states
# its own). The near-match pool was therefore made almost
# entirely of OTHER languages' names, and the checker failed in both directions
# at once — a correct `read_monitors()` reported DRIFT suggesting
# `readMonitorsBody`, a TypeScript function; and a genuinely renamed shell
# function tiering `likely-new`, which groom-backlog §6 documents as not a
# defect, so real drift passed silently.
#
# This tree is that shape, reduced, plus one specimen of every way the harvest
# can leak: the same `name()` line shape in TypeScript and in K&R C, a shell
# payload inside a heredoc, a `#!` that is heredoc content rather than a
# shebang, and a here-string — which is not a heredoc and cost `align-labels.sh`
# 9 of its 14 definitions while this was being written.
SHTREE="$WORK/shtree"
mkdir -p "$SHTREE/scripts" "$SHTREE/jobs/src/monitors" "$SHTREE/native" \
         "$SHTREE/templates" "$SHTREE/docs"

# The shell file. `fetch_config` carries the space before `()` that the shape
# also allows; `parse_line` puts TWO here-strings before later definitions, a
# literal and a variable — only the literal survives the delimiter's own
# quote-stripping to become a phantom, so a fixture carrying just the variable
# form stopped catching the missing `<<<` guard the moment quote-stripping
# arrived, measured — and
# `emit_client` puts a heredoc before them, so anything the tracker mis-reads
# swallows `run_all` and case 12 says so.
cat > "$SHTREE/scripts/check-sentry-monitors.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

read_monitors() {
    echo m
}

fetch_config () {
    echo c
}

parse_line() {
    IFS='|' read -r a b <<<"one|two"
    IFS='|' read -r c d <<<"$line"
    echo "$a$b$c$d"
}

emit_client() {
    cat > client.ts <<'EOF'
export class Dashboard {
  render_widget() {
    return 1;
  }
}
EOF
}

run_all() {
    read_monitors
    fetch_config
    parse_line
    emit_client
}
run_all

# The renderer writes its payload in a <<EOF block, which is prose, not a
# heredoc: read this comment as an opener and tail_helper disappears.
tail_helper() {
    echo t
}

emit_config() {
    cat > cfg.ts <<EOF
export const cfg = {
	EOF
};
invented_from_payload() {
    return 1;
}
EOF
}

emit_dash() {
	cat <<-EOF
	export class Dashed {
    EOF
	invented_by_space_indent() {
	  return 3;
	}
	EOF
}

emit_digit() {
    cat > two.ts <<2EOF
export class Two {
  invented_digit_delim() {
    return 4;
  }
}
2EOF
}

sum_lines() {
    awk '
        { n += 1 }
        END {
            flush()
            print n
        }
    ' "${file:-/dev/null}"
}

emit_pair() {
    cat <<A <<B
alpha
A
export class Two {
  invented_from_b_body() {
    return 2;
  }
}
B
}
SH

# A PHANTOM heredoc is the costliest mis-read here: not one name, but every
# definition BELOW it in the file. Both shapes are ordinary shell — a bit-shift
# and a hyphenated delimiter — and both cost this file everything after them
# before they were fixed.
cat > "$SHTREE/scripts/masks.sh" <<'SH'
#!/usr/bin/env bash
PERM_MASK=$(( 1 << 2 ))

mask_helper() {
    echo "$PERM_MASK"
}

emit_manifest() {
    cat <<MY-DELIM
one payload line
MY-DELIM
}

after_hyphen() {
    echo a
}
SH

# No extension: only the shebang says this is shell. Three of them, because the
# shebang test has to be wrong in BOTH directions to be worth having — widened
# to `^#!` it swallows every scripted language's bin/ entry point, narrowed to
# bash/sh it drops the ones this org actually ships.
cat > "$SHTREE/run" <<'SH'
#!/bin/sh
dev_server() {
    echo up
}
dev_server
SH
mkdir -p "$SHTREE/bin"
cat > "$SHTREE/bin/zshtool" <<'SH'
#!/bin/zsh
zsh_entry_point() {
    echo z
}
SH
cat > "$SHTREE/bin/nodetool" <<'JS'
#!/usr/bin/env node
export class Bin {
  node_bin_helper() {
    return 5;
  }
}
JS

# The other language in the pool. `readMonitorsBody` is keyword-defined, so it
# is in the pool before and after the fix — it is the wrong suggestion the
# production case actually emitted. `list_widgets` is a method shorthand: the
# SAME line shape as a shell definition, in a file that is not shell.
cat > "$SHTREE/jobs/src/monitors/client.ts" <<'TS'
export function readMonitorsBody(): string {
  return "";
}
export class Panel {
  list_widgets() {
    return 1;
  }
}
TS

# C at column 0, carrying its brace on the same line — a K&R definition whose
# `{` sits on the NEXT line is already excluded by the body requirement, so it
# would pass this case with no file scoping at all and prove nothing.
cat > "$SHTREE/native/poll.c" <<'C'
int x;
poll_status() {
    return 0;
}
C

# Prose that quotes a shebang at column 0 and a definition below it, with no
# heredoc anywhere. This is the file that pins the LINE-1 rule on its own: the
# template below is covered by the heredoc rule too, so it cannot tell whether
# line 1 is still being checked. Measured — with only the template, removing the
# line-1 test changed no assertion.
cat > "$SHTREE/docs/hooks.md" <<'MD'
# Hook reference

Every generated dispatcher opens with

#!/usr/bin/env bash

and defines

doc_only_helper() {
    :
}
MD

# A shebang that is not a script: line 1 is the heredoc, the `#!` is content.
# This is the shape this repo's own generators emit, and it is why the shebang
# probe reads line 1 rather than trusting `git grep '^#!'`.
cat > "$SHTREE/templates/render.txt" <<'TXT'
cat > out.sh <<'EOF'
#!/usr/bin/env bash
inner_helper() {
    echo nested
}
EOF
TXT

# A tracked symlink pointing OUT of the checkout. `[[ -r ]]` and `[[ -f ]]` both
# follow it, so only `! -L` keeps another codebase's identifiers out of a
# `did you mean` line that this org pastes into issue bodies in a PUBLIC repo.
# The sibling case — a symlink to `/dev/zero`, which awk reads forever — is
# deliberately NOT built here: it would hang the gate rather than fail it, which
# is exactly why the script refuses symlinks by class instead of by target.
mkdir -p "$WORK/outside"
cat > "$WORK/outside/leaked.sh" <<'SH'
#!/usr/bin/env bash
leaked_from_outside() {
    echo nope
}
SH
ln -s ../../outside/leaked.sh "$SHTREE/scripts/link.sh"

if ! { git -C "$SHTREE" init -q . && git -C "$SHTREE" add -A && \
       git -C "$SHTREE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture; } >/dev/null 2>&1; then
    fail "shell fixture: git build failed — every case below would be meaningless"
fi

# Same subshell caveat as run(): sets OUT and RC in the CALLER's scope. Takes
# the script and the tree because the proofs below run MUTATED copies of the
# script, and case 13 runs two copies over the original fixture.
run_at() {
    OUT="$(bash "$1" --body-file "$3" --tree "$2" --format text 2>&1)"
    RC=$?
}

# --- the mutants, built before anything asserts with them -------------------
# Ten, one per rule this change rests on. Each is a ONE-LINE edit whose
# application is checked rather than assumed: `cmp -s` exits 2 on a missing
# file, which an `if` reads as "they differ", so a sed that matched nothing
# would report `mutation applied` and every negative assertion after it would
# pass against a file that was never run (the #262 lesson).
#
#   MUTANT_PRE    drops "$SHELL_SYMBOLS" from the pool merge — the pre-#263
#                 pool exactly, since `%s\n%s\n` with one argument renders the
#                 second as empty and the empty line is filtered.
#   MUTANT_SCOPE  widens the file list to every tracked file — scoping rule 1.
#   MUTANT_HEREDOC never enters heredoc state — scoping rule 2.
#   MUTANT_DASH   lets ANY indented line close a heredoc, not just a `<<-` one.
#   MUTANT_QUEUE  tracks only the first opener on a line, not `cat <<A <<B`.
#   MUTANT_SPACEDASH strips spaces as well as tabs for `<<-`, which POSIX does
#                 not, so a space-indented payload line closes the heredoc.
#   MUTANT_DIGIT  requires an identifier-shaped delimiter, so `<<2EOF` — which
#                 bash accepts — is never tracked and its payload is scanned.
#   MUTANT_BRACE  drops the body requirement, so a bare `flush()` call site
#                 inside a quoted awk program reads as a definition.
#   MUTANT_SHIFT  lets an all-digit token be a delimiter, so `$(( 1 << 2 ))`
#                 opens a PHANTOM heredoc that runs to the end of the file.
#   MUTANT_MANGLE strips every non-identifier character from the delimiter, so
#                 `<<MY-DELIM` records `MYDELIM` and never closes.
#
# The last two matter more than their size suggests. Skipping a heredoc the
# tracker should not have opened costs a name; ENDING one early, or missing the
# second one, scans a payload as code and INVENTS a name — which is the false
# resolve the whole scoping exists to prevent.
MUTANT_PRE="$WORK/verify-issue-refs.prefix.sh"
MUTANT_SCOPE="$WORK/verify-issue-refs.unscoped.sh"
MUTANT_HEREDOC="$WORK/verify-issue-refs.noheredoc.sh"
MUTANT_DASH="$WORK/verify-issue-refs.anyindent.sh"
MUTANT_QUEUE="$WORK/verify-issue-refs.firstopener.sh"
MUTANT_SPACEDASH="$WORK/verify-issue-refs.spacedash.sh"
MUTANT_DIGIT="$WORK/verify-issue-refs.identdelim.sh"
MUTANT_BRACE="$WORK/verify-issue-refs.nobrace.sh"
MUTANT_SHIFT="$WORK/verify-issue-refs.digitdelim.sh"
MUTANT_MANGLE="$WORK/verify-issue-refs.manglelim.sh"
sed 's/ "\$SHELL_SYMBOLS"//'                            "$SCRIPT" > "$MUTANT_PRE"
sed "s/ls-files -z -- '\*.sh' '\*.bash'/ls-files -z --/"  "$SCRIPT" > "$MUTANT_SCOPE"
sed 's/if (qn > 0) { inhd = 1; qi = 1 }/if (qn > 0) { inhd = 0; qi = 1 }/' \
                                                        "$SCRIPT" > "$MUTANT_HEREDOC"
sed 's/if (qdash\[qi\]) sub/if (1) sub/'                 "$SCRIPT" > "$MUTANT_DASH"
sed 's/    while (match(probe,/    if (match(probe,/'    "$SCRIPT" > "$MUTANT_QUEUE"
sed 's|sub(/^\\t+/, "", line)|sub(/^[ \\t]+/, "", line)|'  "$SCRIPT" > "$MUTANT_SPACEDASH"
sed 's/tok ~ \/\^\[A-Za-z0-9_\]\//tok ~ \/^[A-Za-z_]\//'   "$SCRIPT" > "$MUTANT_DIGIT"
sed 's/\\(\\)\[ \\t\]\*\[{(\]/\\(\\)/'                     "$SCRIPT" > "$MUTANT_BRACE"
sed 's/ && tok !~ \/\^\[0-9\]+\$\///'                "$SCRIPT" > "$MUTANT_SHIFT"
sed 's/if (substr(tok, 1, 1) == sq || substr(tok, 1, 1) == dq) tok = substr(tok, 2)/gsub(\/[^A-Za-z0-9_]\/, "", tok)/' \
                                                        "$SCRIPT" > "$MUTANT_MANGLE"

check_mutant() {   # check_mutant <path> <label>
    local changed
    changed=$(diff "$SCRIPT" "$1" | grep -c '^<' || true)
    if [ -s "$1" ] && [ "${changed:-0}" = 1 ]; then
        pass "mutant built: $2 (1 line changed)"
    else
        fail "mutant NOT built: $2 ($changed line(s) changed) — its proofs would be vacuous"
    fi
}
check_mutant "$MUTANT_PRE"     "pre-#263 keyword-only pool"
check_mutant "$MUTANT_SCOPE"   "harvest unscoped to every tracked file"
check_mutant "$MUTANT_HEREDOC" "heredoc bodies not skipped"
check_mutant "$MUTANT_DASH"    "any indented line closes a heredoc"
check_mutant "$MUTANT_QUEUE"   "only the first opener on a line is tracked"
check_mutant "$MUTANT_SPACEDASH" "dash-form heredoc strips spaces as well as tabs"
check_mutant "$MUTANT_DIGIT"   "a delimiter must be identifier-shaped"
check_mutant "$MUTANT_BRACE"   "a definition needs no body"
check_mutant "$MUTANT_SHIFT"   "an all-digit delimiter opens a heredoc"
check_mutant "$MUTANT_MANGLE"  "delimiter characters are stripped, not just quotes"

# The two heredoc fixtures turn on WHITESPACE, which is exactly the thing an
# editor or a careless sed normalises away. Assert the bytes are what the cases
# assume before any of them runs, or `MUTANT_DASH` and `MUTANT_SPACEDASH` both
# go quietly vacuous.
TABBED=$(grep -c "$(printf '^\tEOF$')" "$SHTREE/scripts/check-sentry-monitors.sh" || true)
SPACED=$(grep -c '^    EOF$' "$SHTREE/scripts/check-sentry-monitors.sh" || true)
if [ "${TABBED:-0}" = 2 ] && [ "${SPACED:-0}" = 1 ]; then
    pass "shell fixture: both indented terminators carry their exact whitespace"
else
    fail "shell fixture: terminator whitespace changed (tab=$TABBED want 2, space=$SPACED want 1) — two mutants go vacuous"
fi

# Case 11's specimens need the same floor as the terminators: each must actually
# BE in its fixture, or the assertion that it stays out of the pool passes
# against a file that never contained it. Measured: deleting the symlink, or
# emptying any one of these definitions, left the gate green.
SPECIMENS_OK=1
check_specimen() {   # check_specimen <file> <pattern> <what>
    if ! grep -q "$2" "$1" 2>/dev/null; then
        fail "shell fixture: $3 is missing from ${1##*/} — case 11 would pass against nothing"
        SPECIMENS_OK=0
    fi
}
check_specimen "$SHTREE/jobs/src/monitors/client.ts" 'list_widgets()'          "the TS method shorthand"
check_specimen "$SHTREE/native/poll.c"               'poll_status() {'         "the C definition"
check_specimen "$SHTREE/docs/hooks.md"               'doc_only_helper()'       "the prose definition"
check_specimen "$SHTREE/bin/nodetool"                'node_bin_helper()'       "the node bin definition"
check_specimen "$SHTREE/scripts/check-sentry-monitors.sh" 'render_widget()'    "the heredoc payload definition"
check_specimen "$SHTREE/scripts/check-sentry-monitors.sh" 'invented_from_payload()' "the early-close payload definition"
check_specimen "$SHTREE/scripts/check-sentry-monitors.sh" 'invented_by_space_indent()' "the dash-heredoc payload definition"
check_specimen "$SHTREE/scripts/check-sentry-monitors.sh" 'invented_digit_delim()' "the digit-delimiter payload definition"
check_specimen "$SHTREE/scripts/check-sentry-monitors.sh" 'flush()'            "the awk-program call site"
check_specimen "$SHTREE/templates/render.txt"        'inner_helper()'          "the template payload definition"
check_specimen "$WORK/outside/leaked.sh"             'leaked_from_outside()'   "the out-of-tree definition"
if [ -L "$SHTREE/scripts/link.sh" ] && [ "$SPECIMENS_OK" = 1 ]; then
    pass "shell fixture: all eleven negative specimens are present, symlink included"
elif [ "$SPECIMENS_OK" = 1 ]; then
    fail "shell fixture: the out-of-tree symlink is gone — case 11's symlink specimen proves nothing"
fi

# --- case 8: the shell fixture is ADEQUATE ----------------------------------
# Acceptance item 4, and the assertion every case below rests on. A "shell"
# fixture the keyword harvest happened to see anyway would pass before the fix
# as well as after it — the vacuous-green shape.
#
# It is measured by RUNNING the pre-#263 script rather than by transcribing its
# regex a third time (the script has it, case 6 has it): a transcription drifts
# silently the day the alternation is widened, and this is the one assertion
# that must not.
cat > "$WORK/s0.md" <<'MD'
Widen `read_monitrs()`, then call `fetch_confg()` and `dev_servr()`.
MD
run_at "$MUTANT_PRE" "$SHTREE" "$WORK/s0.md"
if echo "$OUT" | grep -q 'readMonitorsBody' \
   && ! echo "$OUT" | grep -q 'did you mean `read_monitors`' \
   && ! echo "$OUT" | grep -q 'did you mean `fetch_config`' \
   && ! echo "$OUT" | grep -q 'did you mean `dev_server`'; then
    pass "shell fixture: the pre-#263 pool holds readMonitorsBody and no shell name"
else
    fail "shell fixture inadequate: a shell name was already reachable pre-fix"
    echo "$OUT" | sed 's/^/       /'
fi

# --- case 9: a POSIX-defined function RESOLVES ------------------------------
# Acceptance item 1, and the production false positive: `read_monitors()` is
# defined, and was reported DRIFT against another language's name.
#
# A defined name is also a mentioned one, so the portable mention fallback
# resolves it even without pool membership. Before #479, the ERE `\b` spelling
# resolved it on Linux (2.54/musl, 2.47/glibc) but not macOS (2.55, 26.6); that
# platform split no longer applies. Case 12 proves pool membership on every
# platform, using near-miss names that appear nowhere.
cat > "$WORK/s1.md" <<'MD'
The monitor list comes from `read_monitors()` in `scripts/check-sentry-monitors.sh`.
MD
run_at "$SCRIPT" "$SHTREE" "$WORK/s1.md"; rc=$RC
if [ "$rc" = 0 ] && ! echo "$OUT" | grep -q 'DRIFT'; then
    pass "POSIX-defined shell function does not gate (case 12 carries the pool proof)"
else
    fail "defined shell function must not gate (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 10: a missing shell function tiers on a SHELL name ----------------
# Acceptance item 2, and the other half of the bug: the tier was right before
# the fix only by accident, and the suggestion came from the wrong language.
# `read_monitrs` scores 0.960 against the real `read_monitors` and 0.714 against
# `readMonitorsBody` — both clear the 0.70 cutoff, so this case is decided by
# WHICH names are in the pool, not by the cutoff.
cat > "$WORK/s2.md" <<'MD'
Widen the window inside `read_monitrs()` before the gate runs.
MD
run_at "$SCRIPT" "$SHTREE" "$WORK/s2.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `read_monitors`' \
   && ! echo "$OUT" | grep -q 'readMonitorsBody'; then
    pass "missing shell function is drift, suggested from shell names"
else
    fail "shell near-match must beat the other language's name (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 11: the same line shape elsewhere is NOT a shell definition -------
# Acceptance item 3, and rules 1 and 2 of the scoping together. `list_widgets()`
# is a JS/TS method shorthand, `poll_status()` at column 0 is K&R C,
# `inner_helper()` sits in a heredoc in a .txt whose `#!` is on line 2,
# `render_widget()` is TypeScript inside a heredoc in a REAL shell file — the
# one the file-level scope cannot catch — and `doc_only_helper()` is prose in a
# .md that quotes a shebang at column 0, which is the only specimen here that
# the line-1 rule alone can save.
#
# The last two are the INVENT shapes, which are worse than a leak because the
# tracker manufactures them out of a payload it stopped suppressing:
# `invented_from_payload()` sits after an INDENTED `EOF` inside a plain `<<EOF`
# (only `<<-` permits an indented terminator, so it must not close there), and
# `invented_from_b_body()` sits in the SECOND payload of `cat <<A <<B`.
# `leaked_from_outside()` is in a real shell file that a tracked SYMLINK points
# to from outside the checkout — the one specimen whose definition is not in the
# tree at all. `invented_by_space_indent()` follows a SPACE-indented `EOF` inside
# a `<<-` heredoc, which strips TABS only, so that line is payload and not a
# terminator; `invented_digit_delim()` sits under `<<2EOF`, a delimiter bash
# accepts and an identifier-shaped test would reject; and `flush()` is a bare
# CALL SITE inside a quoted awk program — the shape that put a fabricated name
# in the pool on the reference repo itself (`platform/scripts/
# lint-token-scope-sync.sh:82`), which is why a definition must carry a body.
#
# Every reference here is a near-miss of its definition — scoring >0.94 — and
# none of them appears anywhere in the tree, so the mention probe returns no
# match and the verdict is the pool's alone on every platform.
# A leak therefore fires loudly, as a suggestion, rather than as a silent
# resolve that reads the same as a clean run.
cat > "$WORK/s3.md" <<'MD'
Call `list_widgts()`, `poll_statu()`, `inner_helpr()`, `render_widgt()`, `doc_only_helpr()`,
`invented_from_paylod()`, `invented_from_b_bdy()`, `leaked_from_outsid()`,
`invented_by_space_indnt()`, `invented_digit_delm()`, `flus()` and `node_bin_helpr()`.
MD
run_at "$SCRIPT" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 0 ] && ! echo "$OUT" | grep -q 'did you mean' \
   && echo "$OUT" | grep -q 'new .*list_widgts' \
   && echo "$OUT" | grep -q 'new .*poll_statu' \
   && echo "$OUT" | grep -q 'new .*inner_helpr' \
   && echo "$OUT" | grep -q 'new .*render_widgt' \
   && echo "$OUT" | grep -q 'new .*doc_only_helpr' \
   && echo "$OUT" | grep -q 'new .*invented_from_paylod' \
   && echo "$OUT" | grep -q 'new .*invented_from_b_bdy' \
   && echo "$OUT" | grep -q 'new .*leaked_from_outsid' \
   && echo "$OUT" | grep -q 'new .*invented_by_space_indnt' \
   && echo "$OUT" | grep -q 'new .*invented_digit_delm' \
   && echo "$OUT" | grep -q 'new .*flus()' \
   && echo "$OUT" | grep -q 'new .*node_bin_helpr'; then
    pass "no name() from another language, a heredoc payload, or quoted prose enters the pool"
else
    fail "non-shell name() must not enter the pool (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 12: the pool holds every shell name, proved by absent near misses ---
# Each reference here appears NOWHERE in the tree, so the mention probe returns
# no match and the verdict is decided by the pool alone. It covers all
# three shell sources at once — `fetch_config` from the `*.sh`, `dev_server`
# from an extensionless shebang script, `parse_line` from after a here-string,
# `run_all` from after a heredoc, `tail_helper` from after a COMMENT that
# mentions `<<EOF`, `mask_helper` from after a BIT-SHIFT (`$(( 1 << 2 ))`, whose
# `2` must not read as a delimiter) and `after_hyphen` from after a HYPHENATED
# delimiter (`<<MY-DELIM`, which must be recorded with its hyphen intact or its
# terminator never matches). The last two are phantom-heredoc shapes, and a
# phantom costs every definition below it rather than one name. The last three are the tracker's own regression test, and
# each one is a bug this change actually had: reading `<<<"$line"` as an opener
# cost `align-labels.sh` 9 of its 14 definitions, and reading a comment as one
# cost `verify-issue-refs.sh` both of its own.
cat > "$WORK/s4.md" <<'MD'
Wire `fetch_confg()`, `dev_servr()`, `parse_lne()`, `run_al()`, `tail_helpr()`,
`zsh_entry_poin()`, `mask_helpr()` and `after_hyphn()` together.
MD
run_at "$SCRIPT" "$SHTREE" "$WORK/s4.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `fetch_config`' \
   && echo "$OUT" | grep -q 'did you mean `dev_server`' \
   && echo "$OUT" | grep -q 'did you mean `parse_line`' \
   && echo "$OUT" | grep -q 'did you mean `run_all`' \
   && echo "$OUT" | grep -q 'did you mean `tail_helper`' \
   && echo "$OUT" | grep -q 'did you mean `zsh_entry_point`' \
   && echo "$OUT" | grep -q 'did you mean `mask_helper`' \
   && echo "$OUT" | grep -q 'did you mean `after_hyphen`'; then
    pass "pool holds *.sh, sh and zsh shebangs, post-here-string, post-heredoc and post-comment names"
else
    fail "a shell definition is missing from the pool (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 13: non-shell trees are BYTE-IDENTICAL to the pre-#263 script -----
# Acceptance item 5, measured rather than declared: every body above is run
# through both the shipped script and the pre-#263 one against the original
# fixture, and the two outputs must match exactly.
#
# It is only worth running because that fixture now CONTAINS the shape — the
# `render_at()` method in app/ui/panel.ts, probed by b6. Without it the
# comparison is green however the harvest is scoped, since there is nothing
# there for a shell harvest to find, and the case proves nothing at all.
IDENTICAL=1
for b in b1 b1b b1c b2 b3 b4 b5 b6; do
    run_at "$SCRIPT" "$TREE" "$WORK/$b.md"; NEW_OUT="$OUT"; NEW_RC=$RC
    run_at "$MUTANT_PRE" "$TREE" "$WORK/$b.md"; OLD_OUT="$OUT"; OLD_RC=$RC
    if [ "$NEW_OUT" != "$OLD_OUT" ] || [ "$NEW_RC" != "$OLD_RC" ]; then
        IDENTICAL=0
        printf '       %s differs (was exit %s, now exit %s)\n' "$b" "$OLD_RC" "$NEW_RC"
    fi
done
if [ "$IDENTICAL" = 1 ]; then
    pass "non-shell fixture: 8 bodies, output and exit identical before and after"
else
    fail "the shell harvest changed behaviour on a non-shell tree"
fi

# --- case 14: the proofs ----------------------------------------------------
# Each asserts what the mutated script actually DID, not merely that it did
# something else: a mutation "detected" by an assertion that would also fire on
# a crash proves nothing.
run_at "$MUTANT_PRE" "$SHTREE" "$WORK/s2.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `readMonitorsBody`'; then
    pass "proof: pre-#263, read_monitrs() was answered with the TypeScript name"
else
    fail "MUTANT_PRE undetected by case 10 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

run_at "$MUTANT_PRE" "$SHTREE" "$WORK/s4.md"; rc=$RC
if [ "$rc" = 0 ] && echo "$OUT" | grep -q 'new .*dev_servr'; then
    pass "proof: pre-#263, dev_servr() passed the gate silently as likely-new"
else
    fail "MUTANT_PRE undetected by case 12 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# Rule 1: unscoped, the TypeScript method in the NON-shell fixture enters the
# pool and answers a reference that must read as `new` — a suggestion drawn from
# a language the harvest is not supposed to be reading at all.
run_at "$MUTANT_SCOPE" "$TREE" "$WORK/b6.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `render_at`'; then
    pass "proof: unscoped, a TypeScript method answers render_a()"
else
    fail "MUTANT_SCOPE undetected by case 13/b6 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# Rule 2: without the heredoc skip, the TypeScript method inside a heredoc in a
# real shell file reaches the pool and case 11's `render_widgt()` gates on it.
run_at "$MUTANT_HEREDOC" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `render_widget`'; then
    pass "proof: without the heredoc skip, a heredoc payload becomes a suggestion"
else
    fail "MUTANT_HEREDOC undetected by case 11 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# Rule 2, the invent half. An indented terminator closing a plain `<<EOF`, and
# a second opener never tracked, each scan a payload as code — so a name that
# exists only inside a TypeScript payload becomes a suggestion.
run_at "$MUTANT_DASH" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `invented_from_payload`'; then
    pass "proof: with any indent closing a heredoc, its payload is harvested"
else
    fail "MUTANT_DASH undetected by case 11 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

run_at "$MUTANT_QUEUE" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `invented_from_b_body`'; then
    pass "proof: with only the first opener tracked, the second payload is harvested"
else
    fail "MUTANT_QUEUE undetected by case 11 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# The same three, one per newly-fixed INVENT shape. Each mutation is the code as
# it stood one round earlier, and each fixture is a shape that occurs in real
# shell — a `<<-` payload, a digit-led delimiter, and a call site inside a quoted
# awk program, which is where the reference repo's own fabricated name came from.
run_at "$MUTANT_SPACEDASH" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `invented_by_space_indent`'; then
    pass "proof: stripping spaces for a dash heredoc closes on a payload line and harvests it"
else
    fail "MUTANT_SPACEDASH undetected by case 11 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

run_at "$MUTANT_DIGIT" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `invented_digit_delim`'; then
    pass "proof: rejecting a digit-led delimiter scans its payload as code"
else
    fail "MUTANT_DIGIT undetected by case 11 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

run_at "$MUTANT_BRACE" "$SHTREE" "$WORK/s3.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `flush`'; then
    pass "proof: without a body requirement, a call site in an awk program is a definition"
else
    fail "MUTANT_BRACE undetected by case 11 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# The phantom pair. Both cost every definition BELOW the mis-read line, so the
# proof asserts the whole tail of that file has left the pool, not one name.
#
# Note the labels here and above spell the shape out in words. A literal `<<`
# inside a STRING in a tracked shell file is itself a phantom opener — this file
# had three, and the first of them suppressed everything below it from this
# repo's own pool, `boundary_ok` included. Measured before and after: three
# stuck files, then zero.
run_at "$MUTANT_SHIFT" "$SHTREE" "$WORK/s4.md"; rc=$RC
if [ "$rc" = 3 ] && ! echo "$OUT" | grep -q 'did you mean `mask_helper`' \
   && ! echo "$OUT" | grep -q 'did you mean `after_hyphen`'; then
    pass "proof: an all-digit delimiter opens a phantom heredoc and loses the file tail"
else
    fail "MUTANT_SHIFT undetected by case 12 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

run_at "$MUTANT_MANGLE" "$SHTREE" "$WORK/s4.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `mask_helper`' \
   && ! echo "$OUT" | grep -q 'did you mean `after_hyphen`'; then
    pass "proof: mangling the delimiter loses everything after a hyphenated one"
else
    fail "MUTANT_MANGLE undetected by case 12 (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 15: a pathspec-magic filename must not empty the pool -------------
# The file list is repo-derived, and `--` stops option parsing but NOT pathspec
# magic: one tracked `:(weird)note.sh` made `git grep -- <list>` exit 128, which
# the `2>/dev/null … || true` swallowed into an empty pool — a checker that
# reports "all resolve" on every shell reference in the repo. The names here are
# the three shapes that break a naive list: pathspec magic, a leading `-` read
# as an option, and an `=` read by awk as a variable assignment.
MAGIC="$WORK/magic"
mkdir -p "$MAGIC/scripts"
cat > "$MAGIC/scripts/mon.sh" <<'SH'
#!/usr/bin/env bash
read_monitors() {
    echo m
}
SH
printf '#!/bin/sh\necho hi\n' > "$MAGIC/:(weird)note.sh"
printf '#!/bin/sh\necho hi\n' > "$MAGIC/-dash.sh"
printf '#!/bin/sh\necho hi\n' > "$MAGIC/x=y.sh"
if ! { git -C "$MAGIC" init -q . && git -C "$MAGIC" add -A && \
       git -C "$MAGIC" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture; } >/dev/null 2>&1; then
    fail "magic-name fixture: git build failed"
fi
# Adequacy floor first: the fixture only proves something if the naive form —
# the file list as PATHSPECS, which is what this replaced — actually fatals on
# it. Rename these files benign and the case passes either way.
# The floor asserts git's EXIT STATUS, not its wording: a reworded message would
# otherwise redden this gate for a reason unrelated to any change here. 128 is
# git's fatal; 1 would merely be "no match".
# shellcheck disable=SC2046  # the unquoted split IS the naive shape under test
git -C "$MAGIC" grep -hoIE 'read_monitors' -- $(git -C "$MAGIC" ls-files) >/dev/null 2>&1
naive_rc=$?
if [ "$naive_rc" = 128 ]; then
    pass "magic fixture: the naive pathspec form still fatals on it (git exit 128)"
else
    fail "magic fixture is inadequate — the naive form exits $naive_rc, so case 15 proves nothing"
fi

run_at "$SCRIPT" "$MAGIC" "$WORK/s2.md"; rc=$RC
if [ "$rc" = 3 ] && echo "$OUT" | grep -q 'did you mean `read_monitors`'; then
    pass "pathspec magic, leading dash and = in tracked names do not empty the pool"
else
    fail "a hostile tracked filename emptied the harvest (exit $rc)"; echo "$OUT" | sed 's/^/       /'
fi

# --- case 15b: a clean run says nothing on stderr ---------------------------
# The three new diagnostics distinguish a FAILED harvest from an empty one, and
# a diagnostic that fires on every clean run is worth less than none: `git grep`
# exits 1 for "no match", which is the ordinary case on a repo with no shell in
# it, so the shebang scan's threshold has to be `-gt 1` and not `-ne 0`.
STDERR="$(bash "$SCRIPT" --body-file "$WORK/b5.md" --tree "$TREE" --format text 2>&1 >/dev/null)"
if [ -z "$STDERR" ]; then
    pass "a clean run on a shell-free tree prints nothing on stderr"
else
    fail "a clean run emitted a diagnostic"; printf '%s\n' "$STDERR" | sed 's/^/       /'
fi

# --- case 16: bash 3.2 (macOS system bash) ----------------------------------
# `#!/usr/bin/env bash` selects /bin/bash on a Mac without Homebrew, and 3.2 is
# where two of this change's constructs break: `"${arr[@]}"` on an EMPTY array
# aborts under `set -u`, and a process substitution wrapping a brace group with
# comments and a nested `< <(…)` fails to PARSE — the whole script, before it
# runs a line. Neither is reachable on the bash 5 that CI runs, which is the
# CI-green/locally-broken asymmetry, so this runs the real interpreter when the
# machine has one and says so plainly when it does not.
SYSBASH_V="$(/bin/bash --version 2>/dev/null | head -1 || true)"
case "$SYSBASH_V" in
    *"version 3."*)
        run_at "$SCRIPT" "$TREE" "$WORK/b3.md"; ref_out="$OUT"; ref_rc=$RC
        OUT="$(/bin/bash "$SCRIPT" --body-file "$WORK/b3.md" --tree "$TREE" --format text 2>&1)"; rc=$?
        if [ "$rc" = "$ref_rc" ] && [ "$OUT" = "$ref_out" ]; then
            pass "bash 3.2 runs it identically on a tree with no shell files"
        else
            fail "bash 3.2 diverges — exit $rc vs $ref_rc, output below vs bash 5 above"
            echo "$ref_out" | sed 's/^/  5:   /'
            echo "$OUT" | sed 's/^/  3.2: /'
        fi
        ;;
    *)
        skip "no bash 3.x at /bin/bash (found: ${SYSBASH_V:-none}) — empty-array and parse checks not exercised"
        ;;
esac

# --- case 17: the bash 3.2 guards exist in the SOURCE -----------------------
# Case 16 is the real proof and it `skip`s on ubuntu-latest — so on the one
# platform where the required check actually runs, nothing observes either
# guard. Neutering the count test to `if true` ships green through CI and kills
# the checker on every Mac without Homebrew bash; moving a comment back inside
# the process substitution does the same. Source-level for exactly that reason,
# the same shape as test-label-migrate.sh's single-call-site invariant.
# Each HALF keeps its cap; the UNION must not have one. A third cap is an
# alphabetical truncation of a set that just grew, so on a repo whose keyword
# half saturates it evicts names the pre-#263 pool held — #263's loud failure
# reintroduced on the largest repos. Anchored to the assignment lines rather
# than counted as a literal, because a comment mentioning the cap satisfies a
# count and satisfies nothing else.
# The one rule this whole file's history turns on, and the one nothing else can
# see: `\b` in a git -E pattern harvests NOTHING on macOS and works normally on
# Linux, so the wrong spelling is fully green on CI and empties the pool on the
# machine doing the grooming. Case 16 cannot help — it skips on Linux.
#
# It reads the KEYWORD harvest's own pattern line, not a range: an earlier
# version counted lines in the range carrying `[^A-Za-z0-9_]` and was satisfied
# by the heredoc delimiter cleaner two hundred lines away, which meant deleting
# the boundary outright still passed. This checks only the harvest; case 18
# separately covers the mention fallback's actual git argv.
boundary_ok() {   # boundary_ok <script> — 0 when the harvest boundary is the class
    local line
    line=$(grep -F '(fn|def|function|class|struct|enum|trait|type|interface|const)' "$1" | head -1)
    case "$line" in
        *'\b'*|*'\<'*|*'\>'*|*'[[:<:]]'*|*'[[:>:]]'*) return 1 ;;
    esac
    case "$line" in
        *'(^|[^A-Za-z0-9_])'*) return 0 ;;
        *)                     return 1 ;;
    esac
}

# Proved against every spelling that reproduces the split, not just the one it
# names: a bare `\b`, GNU's `\<`, and no boundary at all. A check that passes
# two of those is the check this replaced.
BND_OK=1
sed 's/(\^|\[\^A-Za-z0-9_\])(fn|def/(\\b)(fn|def/'   "$SCRIPT" > "$WORK/bnd-b.sh"
sed 's/(\^|\[\^A-Za-z0-9_\])(fn|def/(\\<)(fn|def/'   "$SCRIPT" > "$WORK/bnd-lt.sh"
sed 's/(\^|\[\^A-Za-z0-9_\])(fn|def/(fn|def/'        "$SCRIPT" > "$WORK/bnd-none.sh"
for m in bnd-b bnd-lt bnd-none; do
    if diff -q "$SCRIPT" "$WORK/$m.sh" >/dev/null 2>&1; then
        fail "source: boundary mutant $m did not apply — the check below proves nothing"
        BND_OK=0
    elif boundary_ok "$WORK/$m.sh"; then
        fail "source: the boundary check accepts $m, which reproduces the macOS/Linux split"
        BND_OK=0
    fi
done
if [ "$BND_OK" = 1 ] && boundary_ok "$SCRIPT"; then
    pass "source: the harvest boundary is the character class, and \\b, \\< and none are all rejected"
elif [ "$BND_OK" = 1 ]; then
    fail "source: the harvest no longer spells its word boundary as a character class"
fi

# The must-not-exist half reads the union assignment as a WHOLE, continuation
# lines included, which is the flatten-before-must-not-exist convention three
# sibling gates already follow. A line-scoped grep for the forbidden shape turns
# a line WRAP into a false PASS, and that is not
# hypothetical here: the sibling `KEYWORD_SYMBOLS=` assignment is already a
# three-line continuation, so re-adding the union cap as a wrapped assignment is
# exactly how the next person would write it. Measured: wrapped, the unflattened
# check stayed green.
HALF_CAPS=$(grep -c 'sort -u | head -5000 || true)"$' "$SCRIPT" || true)
UNION_ASSIGN=$(sed -n '/^SYMBOLS="\$(printf/,/)"$/p' "$SCRIPT" | tr '\n' ' ')
case "$UNION_ASSIGN" in
    *head*) UNION_CAPPED=1 ;;
    *)      UNION_CAPPED=0 ;;
esac
PY_LINE=$(grep -F 'python3 - ' "$SCRIPT" || true)
case "$PY_LINE" in
    *'"$BODY_FILE_ARG" "$SYMBOLS_FILE"'*) ARGS_VIA_FILE=1 ;;
    *)                                    ARGS_VIA_FILE=0 ;;
esac
if [ "${HALF_CAPS:-0}" = 2 ] && [ "$UNION_CAPPED" = 0 ] && [ "$ARGS_VIA_FILE" = 1 ]; then
    pass "source: both halves capped, the union is not, and body and pool travel by file"
else
    fail "source: pool bounds moved (half-caps=$HALF_CAPS union-capped=$UNION_CAPPED via-file=$ARGS_VIA_FILE)"
fi

# `</dev/null` on the harvest awk is the second door on the hang: with the
# empty-array guard gone, bash 5 expands the array to nothing and `awk PROG`
# with no operands reads stdin forever. Measured — a coverage run hung ten
# minutes on exactly that before it was added.
if grep -Fq '2>/dev/null </dev/null)"' "$SCRIPT"; then
    pass "source: the harvest awk cannot fall through to stdin"
else
    fail "source: the harvest awk lost its </dev/null — with the guard gone it hangs rather than fails"
fi

EXPANSIONS=$(grep -Fc '"${SHELL_FILES[@]}"' "$SCRIPT" || true)
if grep -Fq 'if [[ "$SHELL_FILE_COUNT" -gt 0 ]]; then' "$SCRIPT" \
   && [ "${EXPANSIONS:-0}" = 1 ]; then
    pass "source: empty-array guard present, and the array expands exactly once"
else
    fail "source: the bash 3.2 empty-array guard is gone, or the array expands $EXPANSIONS times"
fi

# The candidate list is built in FUNCTIONS, and that is load-bearing rather than
# stylistic: bash 3.2 does not recognise `#` comments inside a process
# substitution, so an apostrophe or a `(` in one is read as syntax and the whole
# script dies at `bad substitution` before running a line. Measured on 3.2.57:
# no comment passes, a comment with neither character passes, `consumer's` fails,
# `(` fails. So no `<(` in this file's subject may contain a comment.
# Depth counter, not a line pattern: a substitution that opens and closes on one
# line is fine, and only an UNCLOSED one can swallow a following comment. It
# reads the SUBJECT only — this file embeds the known-bad shape as a fixture
# below, and a line-based detector cannot tell that from the real thing.
cat > "$WORK/comment-detector.awk" <<'AWK'
{
    o = gsub(/<\(/, "&")
    c = gsub(/\)/, "&")
    depth += o - c
    if (depth < 0) depth = 0
    if (depth > 0 && $0 ~ /^[[:space:]]*#/) found = 1
}
END { exit(found ? 1 : 0) }
AWK
# Positive control first: a detector that never fires would pass every file,
# including the shape this exists to catch.
cat > "$WORK/badshape.sh" <<'BAD'
while IFS= read -r x; do
    echo "$x"
done < <( { printf 'one\n'
            # the consumer's cap — an apostrophe here is what breaks 3.2
            printf 'two\n'
          } | sort -u )
BAD
if awk -f "$WORK/comment-detector.awk" "$WORK/badshape.sh"; then
    fail "source: the comment-in-substitution detector does not fire on the known-bad shape"
elif awk -f "$WORK/comment-detector.awk" "$SCRIPT"; then
    pass "source: no comment inside an open process substitution (bash 3.2 parse trap)"
else
    fail "source: a comment sits inside an open process substitution — bash 3.2 cannot parse it"
fi

# --- case 18: unpooled symbols use portable, whole-word literal mentions ----
# GNU ERE accepts \b, so a real-tree test alone would pass the old spelling on
# Linux. Observe the actual argv and emulate Darwin's miss for that spelling;
# all other git calls, including fixed-string word searches, reach real git.
# Exit 1 is absence; errors must stay unknown, even with a real qualifier.
if python3 - "$SCRIPT" "$TREE" "$WORK" <<'PY'
import json, os, pathlib, shutil, subprocess, sys

script, tree, work = sys.argv[1:]
shim_dir = pathlib.Path(work) / 'mention-bin'
shim_dir.mkdir()
shim = shim_dir / 'git'
shim.write_text('#!%s\n' % sys.executable + r'''
import json, os, sys
args = sys.argv[1:]
if 'grep' in args:
    search = args[args.index('grep'):]
    if '-q' in search or '-qE' in search:
        with open(os.environ['MENTION_LOG'], 'a') as log:
            log.write(json.dumps(search) + '\n')
        if os.environ['MENTION_MODE'] == 'error':
            sys.exit(2)
        if '-qE' in search and any(r'\b' in arg for arg in search):
            sys.exit(1)
os.execv(os.environ['REAL_GIT'], ['git'] + args)
''')
shim.chmod(0o755)
env = dict(os.environ, REAL_GIT=shutil.which('git'),
           PATH=str(shim_dir) + os.pathsep + os.environ['PATH'],
           MENTION_LOG=str(pathlib.Path(work) / 'mention-argv.jsonl'))
body = pathlib.Path(work) / 'b18.md'

def check(text, mode='normal'):
    body.write_text(text)
    pathlib.Path(env['MENTION_LOG']).write_text('')
    result = subprocess.run(['bash', script, '--body-file', str(body),
                             '--tree', tree, '--format', 'json'],
                            env=dict(env, MENTION_MODE=mode),
                            capture_output=True, text=True, timeout=60)
    data = json.loads(result.stdout)
    calls = [json.loads(line) for line in
             pathlib.Path(env['MENTION_LOG']).read_text().splitlines()]
    return result.returncode, data, calls

rc, data, calls = check('Use `RepoStatus::NeedsApproval` and `RepoState::retry_count`.')
expected = [['grep', '-q', '-w', '-F', '--', name]
            for name in ('retry_count', 'NeedsApproval')]
assert calls == expected, ('nonportable mention argv', calls)
assert rc == 0 and data['findings'] == [] and data['counts']['checked'] == 2, (rc, data)
print('  ok   unpooled enum variant and field resolve with literal word-match argv')

rc, data, _ = check('Use `RepoStatus::NeedsApprov` and `galactic_zebra()`.')
assert rc == 3 and {f['ref']: f['tier'] for f in data['findings']} == {
    'RepoStatus::NeedsApprov': 'likely-drift', 'galactic_zebra()': 'likely-new'
}, (rc, data)
print('  ok   substrings do not resolve absent symbols; drift/new tiers survive')

rc, data, _ = check('Use `RepoStatus::NeedsApproval`.', mode='error')
assert rc == 0 and len(data['findings']) == 1, (rc, data)
finding = data['findings'][0]
assert finding['tier'] == 'unknown' and finding['suggestion'] is None, data
assert 'git grep failed' in finding['why'], data
print('  ok   git grep exit 2 is unknown, not absence or qualified drift')
PY
then
    :
else
    fail "portable mention fallback, word boundaries, or error classification"
fi

if [ "$FAILURES" -eq 0 ]; then
    if [ "$SKIPS" -gt 0 ]; then
        echo "test-verify-issue-refs: all assertions passed ($SKIPS skipped — see above)"
    else
        echo "test-verify-issue-refs: all assertions passed"
    fi
    exit 0
fi
echo "test-verify-issue-refs: $FAILURES assertion(s) failed" >&2
exit 1
