#!/usr/bin/env bash
# test-pipefail-grep.sh — no script under `set -o pipefail` may feed an
# UNBOUNDED writer into `grep -q` (issue #256, generalising issue #172).
#
# THE FAILURE. `grep -q` exits on its first match and closes the pipe; the
# writer upstream takes SIGPIPE and dies with 141; `pipefail` promotes that 141
# to the pipeline's status. The pipeline therefore reports FAILURE precisely
# when it matched — a match reads as a miss. It only happens once the writer's
# output outruns the ~64KB pipe buffer, which is what makes it invisible in
# review and in small fixtures: the identical line is correct today and wrong
# later, with no code change, when the tree or file or API page it reads grows.
#
# The two original failures were inside code written to prevent silent passes:
#   #172  setup-hooks' has_tracked (`git ls-files <glob> | head -1 | grep -q .`)
#         read a match as a miss, and the rendered hook silently dropped that
#         tool's route. Gated — but the gate pins that ONE function by name.
#   #252  test-review-orchestrator-allowlist.sh's `scan … | grep -q` made three
#         of its four MUTATION PROOFS report `undetected`: the mutations were
#         caught and the harness said they were missed. A gate whose whole
#         purpose is refusing vacuous greens was reporting vacuously. It
#         surfaced only because the author checked the proofs actually fired.
#
# THE RULE, and why it is this rule (settled 2026-08-24 on issue #256 — do not
# "simplify" it into the blanket ban below). A pipeline into `grep -q` is
# flagged unless the pipeline's SOURCE stage is `printf` or `echo`. Purely
# syntactic: no judgement about any particular site lives in this script, and
# the allowlisted writers use values already materialized in memory. That is
# not a size bound or proof that their pipe writes will finish.
#
# KNOWN LIMITATION, accepted. The allowlist is a HEURISTIC, not a proof.
# `printf '%s' "$huge" | grep -q x` slips through, because the writer is
# `printf` and nothing here can know how large `$huge` is. The original failures
# involved COMMAND writers — `git ls-files` over a large tree, or `grep`/`jq`
# over a file. A large variable later hit the same boundary in
# test-tech-debt-excludes.sh (main CI after PR #481); that helper now uses a
# here-string and carries a large-value regression. The syntactic allowlist
# stays unchanged: this scanner does not infer data size.
#
# REJECTED on #256, recorded so it is not re-litigated:
#   * Flag everything, opt out with an inline `# pipefail-safe:` marker. It
#     moves the bounded/unbounded judgement to a human at each site, but costs
#     ~128 one-off annotations on today's tree, and a marker that dense
#     degrades into something pasted without being read.
#   * Ban the pipeline outright, rewriting every site to a captured variable.
#     It removes the class entirely, but is a ~131-line diff across the very
#     test scripts this repo relies on to catch its own regressions — real
#     transcription risk in exactly the place a silent error costs the most.
#
# THE LINTER DOES NOT COVER THIS. Verified against shellcheck 0.11.0 rather
# than assumed: on `git ls-files | head -1 | grep -q .` under `set -o pipefail`
# it reports nothing at all, even at `-S style`. SC2143 is a different rule
# about `[ -n "$(grep …)" ]`, and it RECOMMENDS `grep -q` — it pushes code
# toward this shape rather than away from it. (Do not start this line with the
# linter's name: a comment that does is parsed as a directive, SC1072/SC1073.)
#
# EXEMPTIONS live in a central table in THIS file, keyed by (file, distinctive
# substring) — never an inline marker in the scanned file, which is the design
# rejected above. There is exactly one, and it is the line whose entire job is
# to BE the bug: the pre-#172 shape transcribed verbatim in
# test-detect-hook-stack.sh as its fixture-adequacy probe. An exemption that no
# longer matches a risky line FAILS as stale, so it cannot outlive its subject.
# The key is a substring rather than the line text so that this file never has
# to carry a copy of the shape it exists to flag.
#
# SCANNER NOTES. It works on LOGICAL lines — `\` and trailing-`|` continuations
# are joined, because five of the real sites put the writer on the line above
# the `grep -q`. It skips whole-line comments. It is otherwise quote-blind and
# heredoc-blind, and every ambiguity resolves toward FLAGGING: over-flagging is
# a loud failure a human fixes in one line, under-flagging is the silence this
# gate exists to end. A consequence worth knowing before you "tidy" the
# fixtures: this file is itself in scope, so a fixture built here with a
# multi-line `printf` puts the risky shape on a live line and the guard flags
# ITSELF. That is why the fixtures are tracked files under
# scripts/fixtures/pipefail-grep/ (their README records the rest), and it was
# measured rather than predicted — the first draft did exactly that.
#
# Self-checks, because a gate that scans nothing passes vacuously: the corpus
# must be non-empty, each risky fixture must be FLAGGED (the mutation proof,
# built in), the allowlisted ones must not be, a file with no `pipefail` must be
# out of scope WHILE the scanner can still see its shape, and every exemption
# must still be in use.
#
# Reads tracked files plus a tmpdir: no gh, no network, no repo mutation.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-pipefail-grep.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-pipefail-grep: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

# The scanned corpus. Both globs are asserted non-empty below — a pathspec that
# matches nothing makes this gate pass while covering nothing, which is the
# failure mode preflight's positional-token guard already had once.
SCAN_GLOBS=('scripts/*.sh' 'skills/*/scripts/*.sh')

# Deliberately NOT under either glob, and deliberately not `*.sh`: these are
# inputs, not code. See scripts/fixtures/pipefail-grep/README.md.
FIXTURES="scripts/fixtures/pipefail-grep"

# file <TAB> distinctive substring <TAB> reason.  Adding an entry means editing
# THIS file, on purpose: an exemption is a reviewed, central act, not something
# a site can grant itself.
EXEMPTIONS=(
    "scripts/test-detect-hook-stack.sh	has_tracked_prefix_shape	the pre-#172 shape, transcribed verbatim as #172's fixture-adequacy probe — rewriting it would make that gate vacuous"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "pipefail-grep guard (work: $WORK)" >&2

# --- the scanner --------------------------------------------------------------
# scan_file <path> [<display-path>] — prints one TAB-separated finding per risky
# pipeline: "<display>:<line>\t<source-command>\t<logical line>".
scan_file() {
    awk -v FNAME="${2:-$1}" '
        BEGIN { SEP = "\001" }

        # Does the text following "| grep " carry a -q (or --quiet) flag?
        # Walks the option tokens only, and stops at the first non-option — so
        # a `q` inside the PATTERN never counts.
        function isquiet(s,   n, arr, i, t) {
            n = split(s, arr, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                t = arr[i]
                if (t == "") continue
                if (t == "--") return 0
                if (substr(t, 1, 1) != "-") return 0
                if (t == "--quiet") return 1
                if (t ~ /^-[A-Za-z]*q/) return 1
            }
            return 0
        }

        # The first real command word of a fragment: shell keywords, negation
        # and env-assignment prefixes are stepped over, the command is not.
        function firsttoken(p,   n, arr, i, t) {
            n = split(p, arr, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                t = arr[i]
                if (t == "") continue
                if (t == "!" || t == "if" || t == "then" || t == "elif" ||
                    t == "else" || t == "while" || t == "until" || t == "do" ||
                    t == "time" || t == "command" || t == "eval") continue
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
                return t
            }
            return ""
        }

        # The command that SOURCES the pipeline feeding grep. Command separators
        # are collapsed first so `a && printf x` is read as `printf x`, then the
        # remaining command list is split on `|` and its FIRST stage taken —
        # the source is what determines whether the data is bounded; a later
        # stage can only shrink it. `#172`s shape is caught here: the first
        # stage of `git ls-files … | head -1` is `git`, not `head`.
        function sourcehead(pre,   s, n, arr, p, brr) {
            s = pre
            gsub(/\|\|/, SEP, s)
            gsub(/&&/, SEP, s)
            gsub(/[;(){}`]/, SEP, s)
            n = split(s, arr, SEP)
            p = arr[n]
            split(p, brr, "|")
            return firsttoken(brr[1])
        }

        function process(l, n,   rest, consumed, pre, after, head, label, brr) {
            rest = l
            consumed = ""
            while (match(rest, /\|[[:space:]]*grep[[:space:]]/)) {
                pre      = consumed substr(rest, 1, RSTART - 1)
                after    = substr(rest, RSTART + RLENGTH)
                consumed = consumed substr(rest, 1, RSTART + RLENGTH - 1)
                rest     = substr(rest, RSTART + RLENGTH)
                # `a || grep …` is a fallback, not a pipeline.
                if (pre ~ /\|[[:space:]]*$/) continue
                if (!isquiet(after)) continue
                head = sourcehead(pre)
                if (head == "printf" || head == "echo") continue
                # Reporting only. A quoted `(`, `)` or `;` inside an earlier
                # stage (a jq program, say) makes sourcehead land on an empty
                # fragment; it still FLAGS — ambiguity resolves toward flagging
                # — but "?" is a useless thing to hand a reader, so name the
                # command from the uncollapsed text instead.
                label = head
                if (label == "") {
                    split(pre, brr, "|")
                    label = firsttoken(brr[1])
                }
                printf "%s:%d\t%s\t%s\n", FNAME, n, (label == "" ? "?" : label), l
            }
        }

        {
            t = $0
            sub(/[[:space:]]+$/, "", t)
            if (buf == "") {
                if (t ~ /^[[:space:]]*#/ || t == "") next
                start = FNR
                buf = t
            } else {
                sub(/^[[:space:]]+/, "", t)
                buf = buf " " t
            }
            if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
            if (buf ~ /\|$/) next
            process(buf, start)
            buf = ""
        }
        END { if (buf != "") process(buf, start) }
    ' "$1"
}

# --- 1. the corpus is real ----------------------------------------------------
scan_files=""
for glob in "${SCAN_GLOBS[@]}"; do
    matched="$(git ls-files "$glob")"
    if [ -z "$matched" ]; then
        bad "scan pathspec '$glob' matched no tracked files — this gate would cover nothing"
    else
        scan_files="$scan_files$matched"$'\n'
    fi
done

pipefail_files=""
n_scanned=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -q 'pipefail' "$f"; then
        pipefail_files="$pipefail_files$f"$'\n'
        n_scanned=$((n_scanned + 1))
    fi
done <<<"$scan_files"

if [ "$n_scanned" -lt 20 ]; then
    bad "only $n_scanned in-scope scripts carry 'pipefail' — the corpus collapsed; the gate is no longer covering the repo"
else
    ok "corpus: $n_scanned tracked scripts under \`pipefail\` in scope"
fi

# --- 2. mutation proof: a risky fixture MUST be flagged -----------------------
# Fixtures are TRACKED files under scripts/fixtures/pipefail-grep/, not strings
# built here — see that directory's README. A `printf`-built fixture puts the
# risky shape on a live line of THIS file, and this file is in scope: the guard
# flags itself. Measured, not assumed; the first draft did exactly that.
for fx in risky-tree risky-file risky-continued risky-trailing-pipe; do
    path="$FIXTURES/$fx.bash"
    if [ ! -f "$path" ]; then
        bad "fixture $path is missing — the mutation proof is not running"
        continue
    fi
    found="$(scan_file "$path" "$fx")"
    if [ -n "$found" ]; then
        writers="$(cut -f2 <<<"$found" | tr '\n' ' ')"
        ok "mutation proof: '$fx' is flagged (writer: ${writers% })"
    else
        bad "mutation proof: '$fx' was NOT flagged — the scanner no longer detects the shape it exists for"
    fi
done

# --- 3. the allowlist actually allows -----------------------------------------
# If these were flagged the gate would be unusable, and an unusable gate is
# turned off — the same outcome as not having one.
path="$FIXTURES/safe-allowlisted.bash"
if [ ! -f "$path" ]; then
    bad "fixture $path is missing — the allowlist is unproven"
else
    found="$(scan_file "$path" safe-allowlisted)"
    if [ -z "$found" ]; then
        ok "allowlist: printf/echo writers pass, through \`!\`, \`&&\`, \`||\` and a case label"
    else
        bad "allowlist: a bounded printf/echo writer was flagged — $(tr '\n' ';' <<<"$found")"
    fi
fi

# --- 4. scope: no pipefail, no finding ----------------------------------------
# The inversion needs pipefail to promote the 141. This asserts the scanner
# still SEES the shape, so that the corpus filter is demonstrably what excludes
# the file — a blind scanner would look identical from the outside.
path="$FIXTURES/no-pipefail.bash"
if [ ! -f "$path" ]; then
    bad "fixture $path is missing — the scope rule is unproven"
elif grep -q 'pipefail' "$path"; then
    bad "fixture $path is wrong — it carries pipefail after all"
elif [ -n "$(scan_file "$path" no-pipefail)" ]; then
    ok "scope: the corpus filter excludes a no-pipefail script the scanner can still see"
else
    bad "scope: the scanner did not see the shape at all — the corpus filter is not what is doing the excluding"
fi

# --- 5. comments are not code -------------------------------------------------
path="$FIXTURES/comment-only.bash"
if [ ! -f "$path" ]; then
    bad "fixture $path is missing — prose handling is unproven"
elif [ -z "$(scan_file "$path" comment-only)" ]; then
    ok "prose: a whole-line comment describing the shape is not a finding"
else
    bad "prose: a comment describing the shape was flagged as code"
fi

# --- 6. the tree itself -------------------------------------------------------
: >"$WORK/findings"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    scan_file "$f" >>"$WORK/findings"
done <<<"$pipefail_files"

# Split findings into exempt / reported, and record which exemptions fired.
: >"$WORK/reported"
used=()
for _ in "${EXEMPTIONS[@]}"; do used+=(0); done

while IFS= read -r finding; do
    [ -z "$finding" ] && continue
    loc="${finding%%$'\t'*}"
    file="${loc%%:*}"
    text="${finding#*$'\t'}"
    text="${text#*$'\t'}"
    hit=-1
    for i in "${!EXEMPTIONS[@]}"; do
        IFS=$'\t' read -r ex_file ex_sub _ <<<"${EXEMPTIONS[$i]}"
        if [ "$file" = "$ex_file" ] && case "$text" in *"$ex_sub"*) true ;; *) false ;; esac; then
            used[i]=1
            hit=$i
            break
        fi
    done
    [ "$hit" -lt 0 ] && printf '%s\n' "$finding" >>"$WORK/reported"
done <"$WORK/findings"

n_reported=$(grep -c '' "$WORK/reported")
if [ "$n_reported" -eq 0 ]; then
    ok "tree: no unbounded writer feeds \`grep -q\` in any script under pipefail"
else
    bad "tree: $n_reported pipeline(s) feed an unbounded writer into \`grep -q\` under pipefail (issue #256)"
    while IFS= read -r finding; do
        [ -z "$finding" ] && continue
        loc="${finding%%$'\t'*}"
        rest="${finding#*$'\t'}"
        head_cmd="${rest%%$'\t'*}"
        echo "        $loc  writer: $head_cmd" >&2
        echo "          ${rest#*$'\t'}" >&2
    done <"$WORK/reported"
    echo "        Fix: capture the writer's output first, then match it with a" >&2
    echo "        herestring — \`out=\"\$(cmd)\"; grep -q pat <<<\"\$out\"\` — or" >&2
    echo "        redirect a file into grep directly. Never a pipe into grep -q." >&2
fi

# --- 7. no stale exemptions ---------------------------------------------------
# An exemption that stops matching is not harmless: it is a standing licence
# nobody is checking, and the next line that happens to contain its substring
# inherits it.
for i in "${!EXEMPTIONS[@]}"; do
    IFS=$'\t' read -r ex_file ex_sub ex_why <<<"${EXEMPTIONS[$i]}"
    if [ "${used[$i]}" = "1" ]; then
        ok "exemption in use: $ex_file ($ex_sub) — $ex_why"
    else
        bad "STALE exemption: $ex_file / '$ex_sub' no longer matches a flagged line — delete it or fix the key"
    fi
done

if [ "$fails" -eq 0 ]; then
    echo "pipefail-grep guard: PASS" >&2
    exit 0
fi
echo "pipefail-grep guard: FAILED ($fails)" >&2
exit 1
