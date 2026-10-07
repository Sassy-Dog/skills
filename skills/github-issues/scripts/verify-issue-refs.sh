#!/usr/bin/env bash
# verify-issue-refs.sh — check an issue body's code references against the tree.
#
# Grooming writes issue bodies from plans, memory, and older issues; the tree
# moves underneath them. The result is a body whose TYPES and INVARIANTS are
# right and whose LOCATIONS are fiction, which reads as perfectly dispatchable
# and sends an executor looking for a symbol that is not there. Observed in
# production across one drain: `Store::open_at` (the method is `open_in`), a
# view claimed to live in `repos.rs`/`runners.rs` (both are in `github/mod.rs`),
# `cargo test -p servicestatus` (the package is `solador-servicestatus`).
#
# Two failure modes hide behind identical-looking text, and the distinction
# decides WHERE the gate belongs:
#
#   invented — the reference never existed. Written from a stale plan doc.
#              Catchable the moment the issue is groomed.
#   decayed  — correct when written; a later merge renamed or moved it. NOT
#              catchable at grooming time, because it was true then. Only a
#              re-check at dispatch sees it.
#
# So this runs at BOTH promotion (groom-backlog) and dispatch (dispatch-ready).
# A promotion-only gate cannot see decay; a dispatch-only gate lets invented
# references sit in Ready looking dispatchable.
#
# WHAT IT WILL NOT TELL YOU. It resolves references; it does not read code. An
# issue proposing a helper that duplicates a shipped one under another name has
# no unresolved reference and passes clean. That judgment stays human.
#
# ── Why "unresolved" is not the finding ─────────────────────────────────────
# Every issue legitimately names things that do not exist yet — that is what an
# issue IS. A checker that flags every unresolved reference flags the whole
# backlog and gets ignored within a day. The signal is not absence, it is
# absence WITH A NEIGHBOUR:
#
#   likely-drift — unresolved, and something close exists. Invented references
#                  are usually NEARLY right, which is exactly what makes them
#                  survive review. `open_at` beside `open_in`, `servicestatus`
#                  beside `solador-servicestatus`.
#   likely-new   — unresolved and nothing resembles it. Almost always the thing
#                  the issue is asking someone to create. Reported, never gated.
#
# Paths carry TWO qualifications on that rule, both of them earned:
#
#   1. A path harvested from a `touches:` line is NEVER drift. `touches:` is a
#      forward-looking declaration of the files a PR will write, so it names
#      files that do not exist yet by design. Tiered likely-new, rendered, never
#      gated.
#   2. Every other unresolved path needs POSITIVE EVIDENCE to tier drift: a
#      near-match sibling inside the existing parent directory, which is then
#      the suggestion. `githb.rs` beside `github.rs`. Bare "the parent directory
#      exists" is NOT evidence — it fires on every new file added to an existing
#      directory, which is the ordinary shape of an issue asking someone to
#      create something, and it fires DETERMINISTICALLY, every tick, until the
#      operator learns to skim past the gate. A gate that cries wolf on a
#      schedule is worth less than the evidence-free invention this drops
#      (`app/src-tauri/src/repos.rs` with nothing like it in the directory is
#      now reported as new). That trade is deliberate; see issue #199.
#
# Only backticked tokens, `touches:` entries, and `-p NAME` inside fenced code
# blocks are examined. Unbackticked prose is never checked: the false-positive
# rate is what decides whether a gate survives contact with a real backlog.
#
# Usage:
#   verify-issue-refs.sh <issue-number> [--repo owner/name] [--tree PATH]
#   verify-issue-refs.sh --body-file FILE [--tree PATH]
#   verify-issue-refs.sh <issue-number> --format text
#
# Env:  REPO=owner/name (fallback when --repo absent; else inferred from cwd)
#       TREE=PATH       (fallback when --tree absent; else cwd)
#
# Output (--format json, the default): one JSON object on stdout
#   {"issue":N|null,"tree":"...","counts":{"checked":N,"drift":N,"new":N},
#    "findings":[{"ref":"...","kind":"path|symbol|package",
#                 "tier":"likely-drift|likely-new","suggestion":"..."|null,
#                 "why":"..."}]}
#
# Exit: 0 no likely-drift · 3 likely-drift found · 10 skipped · 64 usage.
# Read-only with respect to the TREE and the network: it writes nothing but one
# temp file holding the symbol pool, and makes no call beyond one `gh issue view`.
set -euo pipefail

REPO="${REPO:-}"
TREE="${TREE:-}"
BODY_FILE=""
ISSUE=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)      REPO="$2";      shift 2 ;;
        --tree)      TREE="$2";      shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        --format)    FORMAT="$2";    shift 2 ;;
        -h|--help)
            echo "usage: verify-issue-refs.sh <issue-number> [--repo owner/name] [--tree PATH] [--format json|text]" >&2
            echo "       verify-issue-refs.sh --body-file FILE [--tree PATH] [--format json|text]" >&2
            exit 0 ;;
        -*) echo "verify-issue-refs: unknown option $1" >&2; exit 64 ;;
        *)
            [[ -n "$ISSUE" ]] && { echo "verify-issue-refs: one issue number at a time" >&2; exit 64; }
            ISSUE="$1"; shift ;;
    esac
done

case "$FORMAT" in json|text) ;; *) echo "verify-issue-refs: --format must be json or text" >&2; exit 64 ;; esac
if [[ -z "$ISSUE" && -z "$BODY_FILE" ]]; then
    echo "verify-issue-refs: need an issue number or --body-file" >&2; exit 64
fi
if [[ -n "$ISSUE" && -n "$BODY_FILE" ]]; then
    echo "verify-issue-refs: --body-file and an issue number are mutually exclusive" >&2; exit 64
fi
if [[ -n "$ISSUE" ]]; then
    case "$ISSUE" in ''|*[!0-9]*) echo "verify-issue-refs: issue must be a number" >&2; exit 64 ;; esac
fi

command -v python3 >/dev/null 2>&1 || { echo "skipped: python3 not installed" >&2; exit 10; }
command -v git >/dev/null 2>&1     || { echo "skipped: git not installed" >&2; exit 10; }

# The tree is the authority. Resolve it before reading the body, so a bad --tree
# fails before spending a network call.
[[ -z "$TREE" ]] && TREE="$PWD"
[[ -d "$TREE" ]] || { echo "skipped: --tree $TREE is not a directory" >&2; exit 10; }
TREE_ROOT="$(git -C "$TREE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$TREE_ROOT" ]] && { echo "skipped: --tree $TREE is not inside a git repo" >&2; exit 10; }

# --- the body ---------------------------------------------------------------
if [[ -n "$BODY_FILE" ]]; then
    [[ -r "$BODY_FILE" ]] || { echo "skipped: cannot read $BODY_FILE" >&2; exit 10; }
    BODY="$(cat "$BODY_FILE")"
else
    command -v gh >/dev/null 2>&1 || { echo "skipped: gh not installed" >&2; exit 10; }
    [[ -z "$REPO" ]] && REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [[ -z "$REPO" ]] && { echo "skipped: not in a GitHub repo and REPO not set" >&2; exit 10; }
    BODY="$(gh issue view "$ISSUE" --repo "$REPO" --json body --jq .body 2>/dev/null || true)"
    [[ -z "$BODY" ]] && { echo "skipped: could not read issue #$ISSUE from $REPO" >&2; exit 10; }
fi

# --- candidate pools, harvested from the tree once --------------------------
# Defined symbols, for near-match scoring. Definition-shaped patterns only: a
# bare identifier grep would match every call site and every comment, and a
# candidate pool full of call sites makes every near-match plausible.
#
# The word boundary is spelled as an explicit character class, NOT `\b`. git's
# regex engine accepts `\b` in an -E pattern and — where it was first measured,
# see the platform split below — matches NOTHING with it, so the obvious
# spelling harvests an empty pool, every near-match lookup comes back empty, and
# every unresolved symbol is tiered `likely-new` — the checker keeps running and
# silently stops finding the thing it exists to find. Verified against a real
# tree: `\b` → 0 symbols, this form → ~3000. (Since #263 the pool has a second
# half, so `\b` here empties the KEYWORD half specifically; on a shell-primary
# repo the merged pool would still be non-empty, which makes that failure
# quieter rather than smaller.)
#
# That measurement is PLATFORM-SPECIFIC, which makes the character class more
# necessary rather than less (measured 2026-08-24, issue #263): on macOS 26.6
# with git 2.55 `\b` matches nothing, while on Linux — git 2.54/musl and git
# 2.47/glibc, i.e. what CI and every cloud session run — it matches normally.
# So `\b` here would not fail loudly anywhere; it would harvest a full pool on
# one machine and an empty one on another. The separate `resolve_symbol` mention
# fallback had the same defect for names outside the pool, including enum
# variants and fields (#479). It now uses `git grep -q -w -F -- NAME`: literal
# whole-word matching, without a platform-specific regex boundary. Only exit 1
# means absent; other failures remain unknown.
#
# An empty pool is not the worst shape it can take, though. A pool full of the
# WRONG LANGUAGES is (issue #263), and the harvest below produces one on any
# shell-primary repo: it is keyword-led, and a POSIX shell function definition
# carries no keyword at all. `name() { … }` matches none of that alternation;
# bash's optional `function name()` form does, and almost nobody writes it.
# Measured on Sassy-Dog/platform, whose primary language is bash: 368 names in
# the pool, and 257 DISTINCT POSIX-form definition names across 330 definition
# lines in tracked `*.sh`, not one of them harvested. (Issue #263's table counts
# 253. That is the same tree on the same day, and the difference is the METRIC:
# 253 is the distinct names of definitions at COLUMN 0 — 323 such lines — while
# 257 includes indented ones. Every figure here therefore names its unit.)
# That does not degrade to silence, it degrades in both directions at once. A
# correct `read_monitors()` was reported DRIFT suggesting `readMonitorsBody` —
# an unrelated TypeScript function, because near-match scoring ran against a
# pool made of other languages' names — and a genuinely renamed shell function
# has no near match in that pool either, so it tiers `likely-new`, which
# groom-backlog §6 documents as NOT a defect, and passes the gate silently.
# Hence the second harvest below.
KEYWORD_SYMBOLS="$(git -C "$TREE_ROOT" grep -hoE \
    '(^|[^A-Za-z0-9_])(fn|def|function|class|struct|enum|trait|type|interface|const)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
    -- . 2>/dev/null | awk '{print $NF}' | sort -u | head -5000 || true)"

# POSIX shell function definitions. A second PATTERN rather than another branch
# of the alternation above, because the shape is positional — `name()` at the
# head of a line — not keyword-led.
#
# FOUR scoping rules, each earned, because the same shape means something else
# somewhere else and every leak restores #263 through a different door:
#
#   1. Only shell FILES are read: a tracked `*.sh`/`*.bash`, or a tracked file
#      whose FIRST line is a shell shebang (repos keep real entry points at
#      `run`, `dev`, `preflight` with no extension). `  render() {` is a method
#      shorthand in JS/TS and `poll()` at column 0 is a K&R definition in C, so
#      a tree-wide harvest puts other languages' names straight back in.
#   2. HEREDOC bodies inside those files are skipped, because scoping by file is
#      not enough on its own. Generators — this repo's included — write `.ts`,
#      `.c` and `.sh` payloads inside `<<EOF` blocks in shell scripts. Measured
#      here: a TypeScript method and a K&R C definition, each sitting in a
#      heredoc inside a real `*.sh` file, both RESOLVED CLEAN before the skip —
#      a false resolve, #263's silent half restored one door over. This repo's
#      own before/after count is deliberately NOT quoted: the gate's fixtures
#      are themselves heredoc payloads, so the number moves whenever a case is
#      added, and it moved inside the PR that introduced it. Measured on a tree
#      that is not measuring itself, the cost is now ZERO — Sassy-Dog/platform
#      harvests 255 distinct names with the skip and 255 without it, because the
#      one name it used to drop (`print`, out of an awk payload) is already
#      excluded by rule 4. The skip earns its place in the INVENT direction, not
#      by what it removes from a healthy tree. It is also why
#      the shebang probe reads line 1 rather than trusting `git grep '^#!'`: a
#      shebang inside a heredoc is a payload, not a script.
#   3. The file list is read NUL-separated and handed to awk as ABSOLUTE PATHS,
#      never as git pathspecs, and only REGULAR NON-SYMLINK files are opened.
#      `--` stops option parsing but not pathspec MAGIC: one tracked
#      `:(weird)name.sh` makes `git grep -- <list>` exit 128, and a harvest that
#      empties on error is indistinguishable to the resolver from a repo with no
#      shell in it — the fail-open shape `resolve_symbol` already refuses when it
#      answers "unknown, not absent". The symlink half is why `-f` and `! -L` are
#      both there: a tracked `zero.sh -> /dev/zero` satisfies `[[ -r ]]`, and awk
#      reading it never returns — under `dispatch-ready`'s `/loop 5m` that stacks
#      one hung awk per tick, and no documented exit code can express a run that
#      does not end. A symlink OUT of the checkout is the same door in reverse:
#      it puts another codebase's identifiers into a `did you mean` line that
#      this org pastes into issue bodies in a PUBLIC repo. `git grep` never had
#      either problem for the FINAL component; a symlinked parent DIRECTORY over
#      a tracked path escapes both, which HEAD does too (`git grep` reads the
#      working tree, not blobs) — pre-existing, widened here from keyword-form
#      to POSIX-form names, and worth its own issue rather than a wider claim. Absolute paths also keep a
#      leading `-` or an embedded `=` from reaching awk as an option or an
#      assignment, and `-z` keeps git from C-quoting a non-ASCII name into one
#      that no longer opens.
#   4. A definition must carry a BODY — `()` followed by `{` or `(` on the same
#      line. Without it a bare `flush()` CALL SITE inside a quoted `awk '…'`
#      program reads as a definition, and that is not hypothetical: it put a
#      fabricated `flush` into the shell half of the pool on the very repo #263
#      was measured on (`platform/scripts/lint-token-scope-sync.sh:82`), where no
#      shell `flush()` exists at all. The tracker skips heredocs but has no
#      notion of a multi-line quoted string, and this rule closes that door
#      without one. Measured across platform, this repo and velovate-app — 823
#      definitions — it drops exactly one name, that `flush`, and no real
#      definition anywhere: the `name()` newline `{` style is legal shell and
#      simply does not occur, and if it did the cost would be a SKIP.
#
# WHAT THIS DOES NOT FIX, stated because it looks like a regression and is not:
# the pool is one flat set, so a near-match suggestion can come from a language
# the reference is not. That predates this change and is not introduced by it —
# measured both ways on a mixed tree whose only near neighbour is a RUST
# `render_page`, HEAD already answers `render_panel()` with "did you mean
# `render_page`?" and exits 3. What changes here is that SHELL names now behave
# the way every other language's already did. Making the scoring origin-aware
# would change how every language scores, i.e. the tiering contract
# `dispatch-ready` consumes — the blast radius #263's decision holds out of
# scope, and the right shape for its own issue.
#
# KNOWN LIMITATION, and it now degrades in the safe direction ONLY. The heredoc
# tracker is a line scanner, so a `<<` that opens no heredoc can still start one
# and skip to EOF. What it must never do is END one early, or MISS one, because
# either scans a payload as code and INVENTS a name — the false resolve above.
# Three shapes did exactly that and are fixed here rather than documented away:
#   * an indented terminator now closes only a `<<-` heredoc, which is the only
#     form that permits one. A plain `<<EOF` whose payload contains an indented
#     `EOF` used to close early and scan the rest of the payload as code.
#   * the arithmetic VETO is gone. It skipped tracking for any line containing
#     `$((`, so `n=$(( 1 + 1 )); cat > z.ts <<EOF` opened no heredoc at all and
#     scanned the payload as code. What replaces it is narrower and had to be
#     found by measurement: an ALL-DIGIT delimiter is refused, so `$(( 1 << 2 ))`
#     opens nothing, while `<<2EOF` — which bash accepts — still does.
#   * every opener on a line is queued, not just the first, so `cat <<A <<B`
#     tracks B after A closes instead of scanning B's payload as code.
# What remains is skip-direction, and it is worth naming precisely, because a
# PHANTOM heredoc costs every definition BELOW it in that file — not one name:
#   * a `<<` that opens no heredoc but is shaped like one, which costs every
#     definition BELOW it in that file rather than one name.
#   * a `<<` inside a quoted string. This tracker has no notion of one, which is
#     also why rule 4 exists. Rule 4 covers only the BODYLESS half, though: a
#     brace-carrying definition of another language inside a multi-line quoted
#     payload (`JS='… render() { …'`) is harvested, which is invent-direction and
#     not fixable without real quote tracking — its own issue, not this one.
#   * a delimiter carrying a space (`<<'MY EOF'`), which truncates at the space.
#   * an arithmetic operand that is not a plain numeral — `$(( x << n ))`,
#     `$(( 1 << 0x02 ))`, `$(( 1 << 2, 3 ))`, `2#10` — each of which opens a
#     phantom and skips the rest of that file.
#   * a trailing inline comment mentioning a heredoc (a whole-line comment is
#     already excluded), and a terminator that never appears at all.
#   * `foo ( ) {` — a space between the parens — which rule 4's literal `()`
#     does not match. Zero occurrences across every Sassy Dog repo, measured.
# Each of these skips definitions and lands back on the pre-#263 behaviour of
# reporting `likely-new` and gating nothing.
# Same word-boundary rule as the harvest above: no `\b` anywhere in here.
SHELL_SHEBANG_RE='^#!.*[/[:space:]](ba|da|k|z|a)?sh([[:space:]]|$)'
# Rule order is load-bearing. The definition rule runs BEFORE the heredoc rule
# and does not consume the line, so `foo() { cat <<EOF` yields `foo` and still
# opens the heredoc. The comment rule sits between them because its only job is
# to stop a comment OPENING one; a commented-out definition is already unmatched,
# the definition regex requiring an identifier at the head of the line.
#
# The program carries no single quote, which is what lets it be a single-quoted
# shell string — hence the quote characters are compared through `sprintf("%c")`
# rather than written as literals. The delimiter keeps every OTHER character it
# has: `<<MY-DELIM` must be recorded with its hyphen or its terminator never
# matches, so only POSIX's three quoting forms come off (`'`, `"`, `\`).
# Stripping the rest is `MUTANT_MANGLE`, an explicitly rejected design.
SHELL_DEF_AWK='
FNR == 1 { inhd = 0; qn = 0; qi = 0 }
inhd {
    line = $0
    if (qdash[qi]) sub(/^\t+/, "", line)
    if (line == qterm[qi]) {
        if (qi < qn) { qi++ } else { inhd = 0; qn = 0; qi = 0 }
    }
    next
}
match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*[{(]/) {
    name = substr($0, RSTART, RLENGTH)
    sub(/^[ \t]*/, "", name)
    sub(/[ \t]*\(\).*$/, "", name)
    print name
}
/^[ \t]*#/ { next }
{
    probe = $0
    gsub(/<<</, "@@", probe)
    qn = 0
    while (match(probe, /<<-?[ \t]*[^ \t;&|<>()]+/)) {
        tok = substr(probe, RSTART, RLENGTH)
        probe = substr(probe, RSTART + RLENGTH)
        d = (substr(tok, 3, 1) == "-")
        sub(/^<<-?[ \t]*/, "", tok)
        gsub(/\\/, "", tok)
        sq = sprintf("%c", 39); dq = sprintf("%c", 34)
        if (substr(tok, 1, 1) == sq || substr(tok, 1, 1) == dq) tok = substr(tok, 2)
        if (length(tok) > 0) {
            last = substr(tok, length(tok), 1)
            if (last == sq || last == dq) tok = substr(tok, 1, length(tok) - 1)
        }
        if (tok ~ /^[A-Za-z0-9_]/ && tok !~ /^[0-9]+$/) { qn++; qterm[qn] = tok; qdash[qn] = d }
    }
    if (qn > 0) { inhd = 1; qi = 1 }
}
'
# A function, not an inline `<( { … } )` group, and the reason is measured: bash
# 3.2 — macOS system bash, which `#!/usr/bin/env bash` still selects on a Mac
# without Homebrew — does not recognise `#` comments inside a process
# substitution. An apostrophe or a stray `(` in one is then read as syntax, and
# the whole script dies at `bad substitution: no closing )` before it runs a
# line. Verified four ways on 3.2.57: no comment passes, a comment with neither
# character passes, a comment containing `consumer's` fails, a comment
# containing `(` fails. Comments in a function body are ordinary comments.
shell_file_candidates() {
    # Stage 1 is a fixed pathspec. Stage 2 matches `#!` on ANY line, so every
    # doc that merely quotes a shebang is a candidate; line 1 is then read with
    # the `read` BUILTIN rather than a `head -1` fork. Measured on a tree of
    # 12,001 shebang-quoting files: 33.3s of forks against 0.9s of builtin
    # reads, i.e. ~2.8ms per candidate against ~0.08ms, and this runs unattended
    # once per issue per tick.
    #
    # Stage 2 also skips what stage 1 already emitted. Without that every shell
    # file is listed twice, and since the cap counts entries rather than unique
    # files, a 5000 bound becomes an effective 2500 — dropping precisely the
    # extensionless entry points stage 2 exists to find.
    local rc=0 cand=0 c first
    git -C "$TREE_ROOT" ls-files -z -- '*.sh' '*.bash' 2>/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "verify-issue-refs: ls-files failed (exit $rc) — shell file list is incomplete" >&2
    fi
    while IFS= read -r -d '' c; do
        [[ -n "$c" ]] || continue
        case "$c" in *.sh|*.bash) continue ;; esac
        cand=$((cand + 1))
        if [[ "$cand" -gt 5000 ]]; then break; fi
        # Same predicate as the consumer below, applied BEFORE the open — this
        # is the first thing that opens a candidate by path, so "regular,
        # non-symlink files only" has to hold here too. `-n 512` bounds it: a
        # shebang lives in the first few dozen bytes, and a one-line 80MB file
        # would otherwise be slurped whole.
        [[ -f "$TREE_ROOT/$c" && ! -L "$TREE_ROOT/$c" && -r "$TREE_ROOT/$c" ]] || continue
        first=""
        IFS= read -r -n 512 first 2>/dev/null < "$TREE_ROOT/$c" || true
        if [[ "$first" =~ $SHELL_SHEBANG_RE ]]; then printf '%s\0' "$c"; fi
    done < <(shebang_scan)
}

shebang_scan() {
    # git grep exits 1 for "nothing matched", which is ordinary, and >1 for a
    # real failure, which is not. Collapsing the two is the same fail-open the
    # third scoping rule refuses: the harvest would silently revert to the
    # pre-#263 pool with nothing on stderr to say so.
    local rc=0
    git -C "$TREE_ROOT" grep -lIzE '^#!.*sh' -- . 2>/dev/null || rc=$?
    if [[ "$rc" -gt 1 ]]; then
        echo "verify-issue-refs: shebang scan failed (git exit $rc) — shell file list is incomplete" >&2
    fi
}

SHELL_FILES=()
SHELL_FILE_COUNT=0
while IFS= read -r -d '' _f; do
    [[ -n "$_f" ]] || continue
    # Regular files only, and never a symlink — see scoping rule 3.
    [[ -f "$TREE_ROOT/$_f" && ! -L "$TREE_ROOT/$_f" && -r "$TREE_ROOT/$_f" ]] || continue
    SHELL_FILES+=("$TREE_ROOT/$_f")
    SHELL_FILE_COUNT=$((SHELL_FILE_COUNT + 1))
    # Bounded for the same reason the symbol pools are: argv, not correctness.
    if [[ "$SHELL_FILE_COUNT" -ge 5000 ]]; then break; fi
done < <(shell_file_candidates)

SHELL_SYMBOLS=""
if [[ "$SHELL_FILE_COUNT" -gt 0 ]]; then
    # The guard is not cosmetic, and it protects against more than one thing:
    # bash 3.2 aborts on "${arr[@]}" for an EMPTY array under `set -u`, so a tree
    # with no shell in it would kill the run on macOS system bash. On bash 5 the
    # same expansion yields NO arguments, and `awk PROG` with no file operands
    # reads STDIN — which under an unattended `/loop 5m` tick is a process that
    # never returns and no exit code can describe. Measured: removing this guard
    # hung a run for ten minutes before it was killed. `</dev/null` closes that
    # door a second time, because a guard is a line someone can delete.
    #
    # A failed awk keeps whatever it DID emit. It exits 2 on one unopenable file
    # while still printing every other file's names, so discarding its output
    # would trade one missing file for the entire pool.
    if _shell_raw="$(awk "$SHELL_DEF_AWK" "${SHELL_FILES[@]}" 2>/dev/null </dev/null)"; then
        :
    else
        echo "verify-issue-refs: shell definition harvest incomplete (awk exit $?) — near-match pool may be missing names" >&2
    fi
    SHELL_SYMBOLS="$(printf '%s\n' "$_shell_raw" | grep -v '^$' | sort -u | head -5000 || true)"
fi

# The union carries NO third cap, and that is the whole point. Each half is
# already bounded at 5000; capping the merge as well is an ALPHABETICAL
# truncation of a set that just grew, so on a repo whose keyword half saturates
# it silently EVICTS names the pre-#263 pool contained. Measured on
# velovate-app (2797 files, 8627 distinct keyword names): the third cap dropped
# 95 names HEAD resolved — each one now unresolved, near-matched, and answered
# with a confident wrong suggestion at exit 3 — while 88 of the 189 new shell
# names never reached the pool at all. That is #263's loud half reintroduced on
# exactly the largest repos, and it breaks the "existing behaviour unchanged"
# acceptance item.
#
# The cap existed for ARGV, so the pool stops travelling on argv. It goes to a
# temp file, which is also the only bound that is stated in the right unit:
# Linux caps a single argv element at 131,072 BYTES regardless of name count,
# and velovate-app's pool is already 113,361 bytes — 86.5% of that ceiling, and
# an overrun is `Argument list too long`, exit 126, which is not one of the
# documented 0/3/10/64 and reads to a caller branching on "not 3" as no drift.
SYMBOLS="$(printf '%s\n%s\n' "$KEYWORD_SYMBOLS" "$SHELL_SYMBOLS" | grep -v '^$' | sort -u || true)"
SYMBOLS_FILE="$(mktemp)" || { echo "skipped: could not create a temp file for the symbol pool" >&2; exit 10; }
# The BODY travels the same way, and for a stronger reason: the pool is derived
# from the tree, while the body is whatever an issue says. GitHub caps a body at
# 65,536 CHARACTERS and Linux caps one argv element at 131,072 BYTES, so ~44k
# CJK codepoints clears the second while sitting inside the first — and the
# failure is `Argument list too long`, exit 126, which is not one of the
# documented 0/3/10/64 and which `groom-backlog` §6 and `dispatch-ready` read as
# "not 3", i.e. promote and dispatch. Moving the pool off argv without moving
# the body would have hardened the half that was never attacker-influenced.
BODY_FILE_ARG="$(mktemp)" || { echo "skipped: could not create a temp file for the issue body" >&2; exit 10; }
trap 'rm -f "$SYMBOLS_FILE" "$BODY_FILE_ARG"' EXIT
printf '%s\n' "$SYMBOLS" > "$SYMBOLS_FILE"
printf '%s' "$BODY" > "$BODY_FILE_ARG"

# Package names. Cargo first (the org's Rust repos), then node workspaces.
PACKAGES=""
if [[ -f "$TREE_ROOT/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
    PACKAGES="$(cargo metadata --no-deps --format-version 1 --manifest-path "$TREE_ROOT/Cargo.toml" 2>/dev/null \
        | python3 -c 'import json,sys
try: print("\n".join(p["name"] for p in json.load(sys.stdin)["packages"]))
except Exception: pass' || true)"
fi
if [[ -z "$PACKAGES" ]]; then
    # Fall back to manifest names on disk — works for cargo without the toolchain
    # installed, and for node/bun workspaces. A package this misses is reported
    # as likely-new rather than asserted absent.
    PACKAGES="$( { git -C "$TREE_ROOT" ls-files '*Cargo.toml' 2>/dev/null | while read -r f; do
                     sed -n 's/^name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TREE_ROOT/$f" | head -1
                   done
                   git -C "$TREE_ROOT" ls-files '*package.json' 2>/dev/null | while read -r f; do
                     python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("name") or "")
except Exception: pass' "$TREE_ROOT/$f"
                   done; } | grep -v '^$' | sort -u || true)"
fi

export VIR_TREE_ROOT="$TREE_ROOT"

python3 - "$BODY_FILE_ARG" "$SYMBOLS_FILE" "$PACKAGES" "$ISSUE" "$TREE_ROOT" "$FORMAT" <<'PY'
import difflib, json, os, re, subprocess, sys

body_path, symbols_path, packages_raw, issue, tree_root, fmt = sys.argv[1:7]
# Both the body and the pool arrive as FILES, not argv elements: Linux caps one
# argv string at 131,072 bytes, the pool is unbounded by design (see the merge
# above), and an issue body is whatever someone wrote.
body = open(body_path).read()
symbols = {s for s in open(symbols_path).read().splitlines() if s}
packages = {p for p in packages_raw.splitlines() if p}

# ── extraction ──────────────────────────────────────────────────────────────
# Backticked spans are the discipline signal: this org writes code references in
# backticks. Fenced blocks are read for `-p NAME` only — their prose is a
# transcript, not a claim about the tree.
FENCE = re.compile(r'```.*?```', re.S)
fenced = FENCE.findall(body)
prose = FENCE.sub('\n', body)

inline = re.findall(r'`([^`\n]+)`', prose)
touches = []
for line in body.splitlines():
    m = re.match(r'^\s*touches:\s*(.+)$', line, re.I)
    if m:
        touches = [t for t in re.split(r'[,\s]+', m.group(1).replace('`', ' ').strip()) if t]
        break

pkg_refs = set()
for blk in fenced + [prose]:
    for m in re.finditer(r'(?:^|\s)-p[=\s]+([A-Za-z0-9_.-]+)', blk):
        pkg_refs.add(m.group(1))

# Tokens that are backticked but are not code references. Kept deliberately
# small: a long denylist is a sign the shape rules below are too loose.
NOISE = re.compile(r'''
      ^-                              # flags: --dry-run, -p
    | ^\d                             # 0.1.0, 200
    | ^https?://                      # URLs
    | ^[A-Z_]+$                       # ENV_VARS
    | ^(true|false|null|none|ok|main|ready|blocked|in-progress)$
''', re.X | re.I)

PATHISH = re.compile(r'^[\w.@-]+(/[\w.*@-]+)+/?\**$')
EXT = re.compile(r'\.(rs|ts|tsx|js|jsx|py|go|swift|kt|java|cs|rb|sh|md|json|toml|yaml|yml|css|html)$')
# A symbol reference: Type::method, mod::fn, name(), or a snake/camel identifier
# with enough shape to not be an English word.
SYMBOLISH = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)+(\(\))?$|^[A-Za-z_][A-Za-z0-9_]*\(\)$|^[a-z]+(_[a-z0-9]+)+$')

def classify(tok):
    tok = tok.strip()
    if not tok or NOISE.search(tok) or ' ' in tok:
        return None
    if PATHISH.match(tok) or EXT.search(tok):
        return 'path'
    if SYMBOLISH.match(tok):
        return 'symbol'
    return None

refs = {}            # ref -> kind   (first classification wins; dedup by text)
touches_paths = set()  # refs whose ORIGIN is the touches: line — tiering needs
                       # the origin, not just the text, because a touches entry
                       # is a claim about the FUTURE tree and an inline one is a
                       # claim about the current tree.
for t in touches:
    k = classify(t) or 'path'    # a touches entry is a path claim by definition
    refs.setdefault(t, k)
    if k == 'path':
        touches_paths.add(t)
for t in inline:
    k = classify(t)
    if k:
        refs.setdefault(t, k)
for p in pkg_refs:
    refs[p] = 'package'          # a -p arg outranks an inline-code guess

# ── resolution ──────────────────────────────────────────────────────────────
def git_grep(name):
    try:
        rc = subprocess.run(['git', '-C', tree_root, 'grep', '-q', '-w', '-F', '--', name],
                            capture_output=True, timeout=30).returncode
        return rc == 0 if rc in (0, 1) else None
    except Exception:
        return None            # unknown, never "absent"

def clean_path(ref):
    return re.sub(r'/?\*+$', '', ref).rstrip('/')

def resolve_path(ref):
    """(resolved, why, parent) — parent is the EXISTING parent directory when
    the file is missing but its directory is real, else None.

    It is returned rather than baked into the tier because "the parent exists"
    is a place to LOOK for evidence, not the evidence itself: the caller scores
    the names in that directory and tiers drift only on a near match.
    """
    p = clean_path(ref)
    full = os.path.join(tree_root, p)
    if os.path.exists(full):
        return True, None, None
    parent = os.path.dirname(p)
    if not parent:
        return False, 'top-level path not present', None
    if os.path.isdir(os.path.join(tree_root, parent)):
        return False, 'parent directory %s/ exists but this file does not' % parent, parent
    return False, 'parent directory %s/ does not exist either' % parent, None

def siblings(parent):
    """Names in an existing directory — the near-match pool for a missing file."""
    try:
        return os.listdir(os.path.join(tree_root, parent))
    except OSError:
        return []

def leaf(ref):
    return re.sub(r'\(\)$', '', ref).split('::')[-1]

def best_match(name, pool, cutoff):
    """Closest candidate, tie-broken by shared prefix rather than raw ratio.

    difflib alone answers `open` for `open_at` (0.727) over the actually-renamed
    `open_in` (0.714) — the shorter candidate wins on ratio precisely because it
    is shorter. A rename keeps its prefix and mutates the tail, so the candidate
    sharing the longest prefix is the better guess whenever both clear the
    cutoff. A wrong suggestion is worse than none: it is the line a reader acts
    on without re-checking.
    """
    cands = difflib.get_close_matches(name, pool, n=5, cutoff=cutoff)
    if not cands:
        return []
    def shared_prefix(c):
        n = 0
        for a, b in zip(name, c):
            if a != b:
                break
            n += 1
        return n
    cands.sort(key=lambda c: (shared_prefix(c),
                              difflib.SequenceMatcher(None, name, c).ratio()),
               reverse=True)
    return cands[:1]

def resolve_symbol(ref):
    name = leaf(ref)
    if name in symbols:
        return True, None
    # Not in the definitions pool; is it mentioned at all? Enum variants, fields
    # and call sites can still tell us the body is not inventing it wholesale.
    hit = git_grep(name)
    if hit is None:
        return None, 'git grep failed — treated as unknown, not absent'
    if hit:
        return True, None
    return False, 'no definition and no mention in the tree'

findings = []
unresolved_syms = []

for ref, kind in sorted(refs.items()):
    if kind == 'path':
        ok, why, parent = resolve_path(ref)
        if ok:
            continue
        if ref in touches_paths:
            findings.append({'ref': ref, 'kind': kind, 'tier': 'likely-new',
                             'suggestion': None,
                             'why': why + '; declared in touches:, so read as a file to create'})
            continue
        # Same cutoff as the symbol pass, for the same reason: 0.6 starts
        # pairing files that merely share an extension, and a wrong suggestion
        # is worse than none.
        near = best_match(os.path.basename(clean_path(ref)), siblings(parent), 0.70) if parent else []
        if near:
            findings.append({'ref': ref, 'kind': kind, 'tier': 'likely-drift',
                             'suggestion': os.path.join(parent, near[0]), 'why': why})
        else:
            findings.append({'ref': ref, 'kind': kind, 'tier': 'likely-new',
                             'suggestion': None,
                             'why': why + ('; nothing similar beside it' if parent else '')})
    elif kind == 'package':
        if ref in packages:
            continue
        # A dropped workspace prefix (`store` for `solador-store`) is THE
        # package drift, and edit distance is worst precisely where the case is
        # clearest: the longer the prefix, the lower the ratio. `store` scores
        # 0.556 against `solador-store` and would be missed. A hyphen-segment
        # match is exact evidence rather than a guess, so it outranks scoring.
        seg = [p for p in packages if p.endswith('-' + ref) or p.startswith(ref + '-')]
        near = seg[:1] or best_match(ref, packages, cutoff=0.6)
        findings.append({'ref': ref, 'kind': kind,
                         'tier': 'likely-drift' if near else 'likely-new',
                         'suggestion': near[0] if near else None,
                         'why': 'no such package in this workspace'})
    else:
        ok, why = resolve_symbol(ref)
        if ok or ok is None:
            if ok is None:
                findings.append({'ref': ref, 'kind': kind, 'tier': 'unknown',
                                 'suggestion': None, 'why': why})
            continue
        unresolved_syms.append((ref, why))

for ref, why in unresolved_syms:
    # 0.70, not the difflib-idiomatic 0.6 or a tidier 0.75. Measured against the
    # real case this was built for: `open_at` vs the actual `open_in` scores
    # 0.714 — the shared `open_` prefix with a two-letter divergence is the
    # canonical shape of an invented method name, and 0.75 misses it by a
    # hair while 0.6 starts pairing unrelated same-length identifiers.
    near = best_match(leaf(ref), symbols, cutoff=0.70)
    # A qualified reference whose QUALIFIER resolves but whose leaf does not is
    # drift on its own evidence, near-match or not: the body knows a real type
    # and names a member it does not have. Same shape as the path rule — the
    # container exists, the thing inside it does not — and it catches renames
    # too far apart for any distance threshold to pair up.
    qualifier = ref.split('::')[0] if '::' in ref else None
    qualified_drift = bool(qualifier) and qualifier in symbols
    if qualified_drift and not near:
        why += '; %s exists but has no such member' % qualifier
    findings.append({'ref': ref, 'kind': 'symbol',
                     'tier': 'likely-drift' if (near or qualified_drift) else 'likely-new',
                     'suggestion': near[0] if near else None, 'why': why})

drift = [f for f in findings if f['tier'] == 'likely-drift']
new = [f for f in findings if f['tier'] == 'likely-new']

if fmt == 'text':
    if not findings:
        print('verify-issue-refs: %d reference(s) checked, all resolve.' % len(refs))
    else:
        print('verify-issue-refs: %d reference(s) checked in %s' % (len(refs), tree_root))
        for f in drift:
            s = ' — did you mean `%s`?' % f['suggestion'] if f['suggestion'] else ''
            print('  DRIFT  %-40s %s%s' % (f['ref'], f['why'], s))
        for f in new:
            print('  new    %-40s %s' % (f['ref'], f['why']))
        for f in findings:
            if f['tier'] == 'unknown':
                print('  ?      %-40s %s' % (f['ref'], f['why']))
else:
    print(json.dumps({
        'issue': int(issue) if issue else None,
        'tree': tree_root,
        'counts': {'checked': len(refs), 'drift': len(drift), 'new': len(new)},
        'findings': findings,
    }, indent=2))

sys.exit(3 if drift else 0)
PY
