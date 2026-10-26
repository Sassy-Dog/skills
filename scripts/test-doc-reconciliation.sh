#!/usr/bin/env bash
# test-doc-reconciliation.sh — pins the doc-reconciliation step in all THREE
# shipping paths (issue #220).
#
# What the shipping-path checks are NOT. They do not decide whether arbitrary
# prose is actually stale. #220 rules that out: staleness is a semantic
# judgement about whether a sentence still describes the code, there is nothing
# to grep for, and a script pretending otherwise would produce exactly the
# skimmed-past output issue #199 documents for the reference checker. This gate
# gates the INSTRUCTION's presence, the same source-level shape as
# test-visibility-preconditions.sh and test-sentry-counts.sh.
#
# The bug it guards. Nothing in the shipping path asked whether a change had
# just made a doc wrong. Lint, type, test and the review agent all pass on a PR
# whose AGENTS.md now states the opposite of what the repo does, because docs
# are an input to no other gate. One Solador PR shipped beside three doc claims
# that were already false before it started — a "not consumed" value that had
# been reaching the host cards for a while, a "hard-coded" version that was the
# git-derived CalVer, and a "no release train yet" line pointing at a closed
# issue whose release.yml ships macOS and Windows. All three were caught by a
# human noticing.
#
# Why all three skills, and why take-it/dispatch-ready are the important half:
# those dispatch SUB-AGENTS that open their own PRs from a cold worktree. They
# never see an interactive session's CLAUDE.md, so a rule that lives only in
# send-it never runs for them. #220 calls this "the half most likely to be
# missed" — so the gate treats the three as equals and fails if any one lacks
# it.
#
# Four things are pinned:
#
#   1. All three skills carry the step.
#   2. In send-it it runs BEFORE the PR body is drafted. The body is where "what
#      changed" is stated, so a doc fix belongs in the same PR, not a follow-up.
#   3. Both traps survive, with their reasons:
#        - issue state is not evidence (closed != landed, open != not landed)
#        - claims of deliberate absence rot silently
#      These are the two that produced real errors, and they are the sentences a
#      later trim reads as belt-and-braces.
#   4. The scope limiter survives ("the area you touched", not every markdown
#      file). Without it the step is unbounded, and an unbounded step is skipped.
#
# Must-not-exist assertions run on a WHITESPACE-FLATTENED copy: this repo
# hard-wraps prose, and a line-scoped grep turns a wrap into a false PASS.
#
# The structural exceptions are derivable: section 6 reconciles the gate count,
# and section 7 compares setup-config's complete template applicability inventory
# with its tracked template roster and actual nested frontmatter slots (#380).
# Missing review_site was only the first measured gap: board subfields and
# conditional site/stack/migration inputs were also missing. Checking file-wide
# mentions would accept prose about a key no template could emit.
#
# The contract's per-skill inventory is the only applicability list. The checker
# reads its always-written, conditional and hand-set columns, including unchanged
# tidy-repo; it does not duplicate the list or create a general schema validator.
# It scans the templates' simple mapping syntax, skips folded/literal scalar
# contents, and stops at the closing frontmatter fence. Template # optional
# boundaries distinguish slots that must survive omission from opt-ins.
# Hand-set review_surfaces deliberately has NO generated slot; this is not a
# rendered-config validator and must not reject a user's map or a legal omission
# of review_agent. Product-surface none alternatives remain owned by the Sentry
# gates. A skill invocation still has to prove actual rendering and consent.
#
# In-memory negative specimens exercise the same comparison as the live files:
# removed review_site/site/stack/migration slots, a nested board-field omission,
# keys moved into prose/comments/block scalars, an always-written key made
# optional, an invented hand-set slot, and template/inventory roster drift.
# Each must fail for its named path or roster mismatch, not an unrelated error.
# No gh or network; all subjects are tracked and no specimen writes to the tree.
#
# Section 8 pins CLAUDE.md as the exact two-line @AGENTS.md import (#601). It
# lives here, not in a new gate, because it is a doc-reconciliation property of
# the guide pair: every gate that reads the guide reads AGENTS.md, so content
# added to CLAUDE.md (a /memory edit, a hand edit) is loaded by Claude Code,
# never seen by Codex, and invisible to all of them. The whole file is compared
# byte for byte, trailing newline included. Mutants (append, prepend, dropped
# import, changed target, trailing newline removed) are built from the expected
# file, never the checkout's CLAUDE.md, so a wrong CLAUDE.md cannot skew them.
# They run on scratch copies in this suite's own mktemp -d, each asserted to have
# applied before it must turn red. A separate case checks an absent path: it
# derives nothing from the expected file and has no applied-check.
#
# Section 9 holds every tracked AGENTS.md chain to the org's 32 KiB guidance
# budget (#606). A chain is one AGENTS.md plus the tracked AGENTS.md in every
# ancestor directory up to the root, and its total must not exceed 32,768 bytes.
# That is Codex's default project_doc_max_bytes: the file that crosses it is cut
# at that byte with only a log-level warning, and every deeper file is dropped.
# It lives here, not in a new gate, because it is a doc-reconciliation property
# of the guide: a guide that grows past what a reader loads is stale in the way
# this suite exists to catch, and a new scripts/test-*.sh would change the gate
# count section 6 re-derives. The chain computation is a function over a
# directory and a NUL-delimited file list, so its committed cases run on scratch
# trees with no git. Those cases, each asserted to have applied before it must
# give its verdict: a root of exactly 32,768 bytes passes and 32,769 fails; a
# nested file fails when it takes the chain over though each file alone is
# under; sibling directories are not summed; a deep file with no AGENTS.md in
# the directories between still sums the root; an empty list and a nested file
# with no root both fail, so the check cannot pass vacuously. Failure paths are
# red, never a pass: a listed path that is missing or is a directory, and a git
# that cannot list the tracked files. What it does NOT measure, each pinned by a
# case so the claim stays true: an AGENTS.override.md, which Codex reads in
# place of AGENTS.md, and any untracked AGENTS.md.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-doc-reconciliation.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-doc-reconciliation: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

SEND="skills/send-it/SKILL.md"
TAKE="skills/take-it/SKILL.md"
DISPATCH="skills/dispatch-ready/SKILL.md"

fails=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "Doc reconciliation in the shipping path (issue #220)"

for f in "$SEND" "$TAKE" "$DISPATCH"; do
    [ -r "$f" ] || bad "missing file: $f"
done
[ "$fails" -eq 0 ] || { echo "test-doc-reconciliation: FAILED" >&2; exit 1; }

# Flatten to one line for phrase matching. Two normalisations, both load-bearing:
#
#   sed 1  strip leading blockquote markers. take-it's rule lives INSIDE a `>`
#          prompt template, so a phrase wrapping across two lines flattens to
#          "not every > markdown file" and a plain grep misses it. That is a
#          FALSE PASS on a must-not-exist check and a false FAIL here — this
#          gate hit all three of its own assertions that way before the strip
#          was added.
#   sed 2  drop list/continuation indentation left behind by the join.
#
# Same class as the wrap trap the other prose gates flatten for; blockquotes
# just make it survive the newline.
flat() {
    sed -e 's/^[[:space:]]*>[[:space:]]\{0,1\}//' -e 's/^[[:space:]]*//' "$1" |
        tr '\n' ' ' | tr -s ' '
}
send_flat="$(flat "$SEND")"
take_flat="$(flat "$TAKE")"
dispatch_flat="$(flat "$DISPATCH")"

# --- 1. All three carry the step ---------------------------------------------

for pair in "send-it:$send_flat" "take-it:$take_flat" "dispatch-ready:$dispatch_flat"; do
    name="${pair%%:*}"; body="${pair#*:}"
    if grep -qiE 'doc-reconciliation|Reconcile the docs|Reconcile the docs against the repo|reconcile the docs against the repo' <<<"$body"; then
        ok "$name carries a doc-reconciliation step"
    else
        bad "$name has no doc-reconciliation step"
    fi
done

# The sub-agent brief is the half that gets missed: its rule must be inside the
# prompt template the agent actually receives, not just narrated around it.
if grep -q '^> [0-9]*\. \*\*Reconcile the docs against the repo before you commit\.\*\*' "$TAKE"; then
    ok "take-it's rule is a numbered step INSIDE the sub-agent prompt"
else
    bad "take-it's doc rule is not a numbered step inside the sub-agent prompt"
fi

# --- 2. In send-it it precedes the PR body -----------------------------------

doc_line="$(grep -n 'Reconcile the docs against the repo' "$SEND" | head -1 | cut -d: -f1)"
body_line="$(grep -n '^## 5\. Template-compliant PR body' "$SEND" | head -1 | cut -d: -f1)"
if [ -n "$doc_line" ] && [ -n "$body_line" ] && [ "$doc_line" -lt "$body_line" ]; then
    ok "send-it reconciles docs before the PR body is drafted"
else
    bad "send-it's doc step no longer precedes the PR body (doc=$doc_line body=$body_line)"
fi

# ...and it says WHY, which is what stops it being moved later as a tidy-up.
if grep -qi 'same PR as the change that invalidated it' <<<"$send_flat"; then
    ok "send-it explains why the step runs before the body"
else
    bad "send-it no longer explains why the doc step must precede the body"
fi

# --- 3. Both traps survive, with reasons -------------------------------------

for pair in "send-it:$send_flat" "take-it:$take_flat"; do
    name="${pair%%:*}"; body="${pair#*:}"

    if grep -qi 'Issue state is not evidence' <<<"$body"; then
        ok "$name keeps the issue-state trap"
    else
        bad "$name lost the issue-state trap"
    fi

    # Both halves. "Closed doesn't mean done" alone still lets someone treat an
    # OPEN issue as proof the behaviour is absent, which is the other direction.
    if grep -qi 'closed issue does not prove' <<<"$body" &&
       grep -qiE 'open one does not prove' <<<"$body"; then
        ok "$name states BOTH directions of the issue-state trap"
    else
        bad "$name states only one direction of the issue-state trap"
    fi

    if grep -qiE 'absence rot silently|deliberate absence' <<<"$body"; then
        ok "$name keeps the deliberate-absence trap"
    else
        bad "$name lost the deliberate-absence trap"
    fi

    # The reason is the deletable part, and without it the rule reads as fussy.
    if grep -qi 'nothing fails when they stop being true' <<<"$body" ||
       grep -qi 'nothing fails when these stop being true' <<<"$body"; then
        ok "$name keeps the reason absence-claims rot"
    else
        bad "$name dropped why deliberate-absence claims rot"
    fi
done

# --- 4. The scope limiter survives -------------------------------------------
#
# An unbounded "check the docs" step is one nobody runs. #220 says so directly.

for pair in "send-it:$send_flat" "take-it:$take_flat"; do
    name="${pair%%:*}"; body="${pair#*:}"
    if grep -qiE 'not every markdown file' <<<"$body"; then
        ok "$name bounds the step (not every markdown file)"
    else
        bad "$name lost the scope limiter — an unbounded doc step gets skipped"
    fi
done

# --- 5. dispatch-ready names it as reuse-critical ----------------------------
#
# dispatch-ready does not restate the prompt; it reuses take-it's. So its job is
# to name the doc step among the rules the reuse must preserve, exactly as it
# already does for the shared-state isolation rules. If it does not, a future
# edit that rebuilds the prompt drops the doc step and nothing notices.
if grep -qi 'doc-reconciliation step' <<<"$dispatch_flat"; then
    ok "dispatch-ready names the doc step among the reused rules"
else
    bad "dispatch-ready does not name the doc step as reuse-critical"
fi

if grep -qiE 'never see an interactive session|cold worktree' <<<"$dispatch_flat"; then
    ok "dispatch-ready records why its sub-agents need the rule spelled out"
else
    bad "dispatch-ready lost the reason its sub-agents need the rule"
fi

# --- 6. AGENTS.md's gate count is DERIVED, not asserted -----------------------
#
# This repo's own convention: "a count stated in prose is safe only when its
# members are enumerated beside it, or when a gate re-derives it." AGENTS.md
# spells the number of `scripts/test-*.sh` gates and nothing re-derived it —
# equally bare at 30, 31 and 33, correct each time and unenforced every time
# (issue #348). It belongs HERE rather than in preflight, because a doc claim
# going stale against the repo is exactly what this gate is for.
#
# THREE sources, all required to agree, because each catches a different slip:
# a gate file added but never wired runs nowhere; a gate wired but deleted fails
# the run; and either one leaves the sentence wrong.
n_files="$(git -C "$REPO_ROOT" ls-files 'scripts/test-*.sh' | grep -c .)"
# `if` OR `elif`: test-template-actionlint.sh is reached through an `elif`,
# because preflight skips the actionlint pair in CI (the pinned binary reaches
# only LATER steps) and runs it locally. An `^if`-only pattern reported 32 of 33
# on this check's very first run. Since #567 a gate is reached through the
# parallel runner, `pg_gate` (or `pg_gate_serial`); that each test is wired
# EXACTLY ONCE, by name, is test-preflight-wiring.sh's job — this is the count.
n_wired="$(grep -cE '^(el)?if pg_gate(_serial)? scripts/test-[a-z0-9-]+\.sh' "$REPO_ROOT/scripts/preflight.sh")"
n_said="$(grep -oE 'the [0-9]+ `scripts/test-\*\.sh` gates' "$REPO_ROOT/AGENTS.md" | grep -oE '[0-9]+' | head -1)"

if [ -z "$n_said" ]; then
    bad "AGENTS.md no longer spells a gate count in the form this gate re-derives — restore it, or this check silently covers nothing"
elif [ "$n_files" = "$n_wired" ] && [ "$n_wired" = "$n_said" ]; then
    ok "AGENTS.md's gate count is re-derived: $n_said tracked = $n_wired wired = $n_said stated"
else
    bad "gate count disagrees — $n_files tracked scripts/test-*.sh, $n_wired wired into preflight, AGENTS.md says $n_said"
fi

# --- 7. Template applicability reconciles against actual frontmatter ----------
#
# Python stdlib only, like the other structural gates. This deliberately reads
# slots, not placeholder VALUES: YAML rendering and runtime skill proof remain
# separate, and {{FACT}} is not itself a resolved YAML scalar.
if python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
template_dir = "skills/setup-config/references/templates/"
contract = (root / "skills/setup-config/references/config-contract.md").read_text()
tracked = subprocess.check_output(
    ["git", "ls-files", "-z", template_dir], cwd=root
).decode().split("\0")
templates = {
    path[len(template_dir):]: (root / path).read_text()
    for path in tracked if path
}


def inventory(text):
    section = text.split("### Template applicability inventory\n", 1)[1]
    section = section.split("\n### ", 1)[0]
    rows = {}
    for line in section.splitlines():
        if not line.startswith("| `"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) != 4 or not re.fullmatch(r"`[a-z-]+`", cells[0]):
            raise ValueError("malformed applicability row")
        name = cells[0].strip("`") + ".config.md"
        if name in rows:
            raise ValueError(f"duplicate inventory template: {name}")
        slots = {}
        for mode, cell in zip(("always", "conditional", "hand-set"), cells[1:]):
            if cell == "none":
                continue
            for token in cell.split(", "):
                if not re.fullmatch(r"`[a-z_]+(?:\.[a-z_]+)*`", token):
                    raise ValueError(f"{name}: malformed inventory path {token}")
                path = token.strip("`")
                if path in slots:
                    raise ValueError(f"{name}: duplicate inventory path {path}")
                slots[path] = mode
        if not slots:
            raise ValueError(f"{name}: empty applicability row")
        rows[name] = slots
    if not rows:
        raise ValueError("empty applicability inventory")
    return rows


def frontmatter_slots(text):
    # Drop ONLY the leading template header, never body comments. The resulting
    # first line must be the opening fence, not an arbitrary fence found later.
    text = re.sub(r"\A<!--.*?-->\r?\n", "", text, count=1, flags=re.S)
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("frontmatter must start on line 1 after the header")
    slots, parents = {}, []
    mode, scalar_indent = "always", None
    for line in lines[1:]:
        if line == "---":
            return slots
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if scalar_indent is not None:
            if indent > scalar_indent:
                continue
            scalar_indent = None
        if line.startswith("# optional"):
            mode = "conditional"
        if line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"( *)([a-z_]+):(?:\s+(.*))?", line)
        if not match:
            raise ValueError(f"unsupported template mapping line: {line}")
        while parents and parents[-1][0] >= indent:
            parents.pop()
        expected_indent = parents[-1][0] + 2 if parents else 0
        if indent != expected_indent:
            raise ValueError(f"invalid mapping indentation: {line}")
        path = ".".join([parent[1] for parent in parents] + [match[2]])
        if path in slots:
            raise ValueError(f"duplicate frontmatter path: {path}")
        value = (match[3] or "").split(" #", 1)[0].strip()
        if value.startswith("#"):
            value = ""
        slots[path] = (mode, not value)
        if not value:
            parents.append((indent, match[2]))
        elif re.fullmatch(r"[>|][-+0-9]*", value):
            scalar_indent = indent
    raise ValueError("missing closing frontmatter fence")


def reconcile(text, sources):
    errors = []
    try:
        rows = inventory(text)
    except (IndexError, ValueError) as error:
        return [f"inventory: {error}"]
    if rows.keys() != sources.keys():
        errors.append(
            "roster mismatch: unlisted=" + str(sorted(sources.keys() - rows.keys()))
            + "; missing=" + str(sorted(rows.keys() - sources.keys()))
        )
    for name in sorted(rows.keys() & sources.keys()):
        expected = {}
        for path, mode in rows[name].items():
            if mode == "hand-set":
                continue
            parts = path.split(".")
            for depth in range(1, len(parts) + 1):
                key = ".".join(parts[:depth])
                value = (mode, depth < len(parts))
                if key in expected and expected[key] != value:
                    errors.append(f"{name}: conflicting inventory path {key}")
                expected[key] = value
        try:
            actual = frontmatter_slots(sources[name])
        except ValueError as error:
            errors.append(f"{name}: {error}")
            continue
        for path in sorted(expected.keys() | actual.keys()):
            if expected.get(path) != actual.get(path):
                errors.append(
                    f"{name}: {path}: expected {expected.get(path)}, got {actual.get(path)}"
                )
    return errors


errors = reconcile(contract, templates)
if errors:
    print("\n".join("  FAIL  " + error for error in errors), file=sys.stderr)
    sys.exit(1)
print(f"  ok    applicability reconciles all {len(templates)} tracked templates")


def rejected(label, sources, expected, text=contract):
    failures = reconcile(text, sources)
    if not any(expected in failure for failure in failures):
        raise AssertionError(f"{label}: expected {expected!r}, got {failures}")
    print(f"  ok    rejects {label}")


def without_line(name, line):
    original = templates[name]
    if original.count(line) != 1:
        raise AssertionError(f"{name}: specimen line is not unique: {line!r}")
    return {**templates, name: original.replace(line, "", 1)}


# Each independent missing slot must fail at the named path, not merely because
# some other specimen happened to break YAML or the inventory roster.
for name, line, path in (
    ("take-it", "review_site: {{REVIEW_SITE}}\n", "review_site"),
    ("dispatch-ready", "review_site: {{REVIEW_SITE}}\n", "review_site"),
    ("survey-work", "execution_site: {{EXECUTION_SITE}}\n", "execution_site"),
    ("send-it", "  max_depth: {{STACK_MAX_DEPTH}}\n", "stacked_prs.max_depth"),
    ("take-it", "  regen_command: {{MIGRATION_REGEN_COMMAND}}\n", "migrations.regen_command"),
    ("dispatch-ready", "  owner: {{BOARD_OWNER}}\n", "board.owner"),
):
    filename = name + ".config.md"
    rejected(f"{name} missing {path}", without_line(filename, line), f"{filename}: {path}:")

name = "take-it.config.md"
line = "review_site: {{REVIEW_SITE}}\n"
missing = without_line(name, line)
for label, replacement in (
    ("body-only key", missing[name] + "\n```yaml\n" + line + "```\n"),
    ("comment-only key", templates[name].replace(line, "# " + line)),
    ("block-scalar-only key", missing[name].replace(
        "  {{STACK_SUMMARY}}\n", "  {{STACK_SUMMARY}}\n  " + line
    )),
    ("always-written key moved to optional", missing[name].replace(
        "# optional\n", "# optional\n" + line
    )),
):
    rejected(label, {**templates, name: replacement}, f"{name}: review_site:")

name = "send-it.config.md"
invented = templates[name].replace("# optional\n", "# optional\nreview_surfaces: {}\n")
rejected("generated hand-set map", {**templates, name: invented}, f"{name}: review_surfaces:")
rejected("unlisted template", {**templates, "extra.config.md": templates[name]}, "roster mismatch")
rejected("removed tidy-repo template",
         {key: value for key, value in templates.items() if key != "tidy-repo.config.md"},
         "roster mismatch")
row = next(line for line in contract.splitlines(True) if line.startswith("| `tidy-repo` |"))
rejected("inventory row removed", templates, "roster mismatch", contract.replace(row, "", 1))
PY
then
    ok "template applicability and negative specimens"
else
    bad "template applicability or its negative specimens failed"
fi

# --- 8. CLAUDE.md stays the exact two-line @AGENTS.md import (#601) -----------
#
# See the header: byte-for-byte compare, committed mutants, missing-file case.
claude_scratch="$(mktemp -d)"
trap 'rm -rf "$claude_scratch"' EXIT
claude_expected_file="$claude_scratch/expected"
printf '%s\n%s\n' \
    '<!-- Agent instructions live in AGENTS.md; edit that file. Claude Code expands the import below. -->' \
    '@AGENTS.md' >"$claude_expected_file"

# claude_import_check FILE: prints a reason and returns 1 unless FILE is exactly the import.
claude_import_check() {
    if [ ! -f "$1" ]; then
        echo "CLAUDE.md is missing"
        return 1
    fi
    if ! cmp -s "$1" "$claude_expected_file"; then
        echo "CLAUDE.md differs from the exact two-line @AGENTS.md import"
        return 1
    fi
    return 0
}

if reason="$(claude_import_check CLAUDE.md)"; then
    ok "CLAUDE.md is exactly the two-line @AGENTS.md import"
else
    bad "$reason"
fi

claude_mutant() { # label, expected-reason-substring, each mutator rewrites the copy at $m, starting from the expected file
    local label="$1" want="$2" m="$claude_scratch/mutant"
    cp "$claude_expected_file" "$m"
    "$3" "$m"
    if cmp -s "$m" "$claude_expected_file"; then
        bad "CLAUDE.md mutant '$label' did not apply"
        return
    fi
    if reason="$(claude_import_check "$m")"; then
        bad "CLAUDE.md mutant '$label' stayed green"
    elif [ "$reason" = "$want" ]; then
        ok "CLAUDE.md mutant '$label' turns the section red"
    else
        bad "CLAUDE.md mutant '$label' failed with the wrong message: $reason"
    fi
}
mut_append()  { printf 'extra rule\n' >>"$1"; }
mut_prepend() { { printf 'extra rule\n'; cat "$claude_expected_file"; } >"$1.t" && mv "$1.t" "$1"; }
mut_drop()    { sed '$d' "$claude_expected_file" >"$1.t" && mv "$1.t" "$1"; }
mut_target()  { sed 's/^@AGENTS\.md$/@CLAUDE.md/' "$claude_expected_file" >"$1.t" && mv "$1.t" "$1"; }
mut_nonl()    { local c; c="$(cat "$claude_expected_file")" && printf '%s' "$c" >"$1.t" && mv "$1.t" "$1"; }
differs="CLAUDE.md differs from the exact two-line @AGENTS.md import"
claude_mutant "appended line" "$differs" mut_append
claude_mutant "prepended line" "$differs" mut_prepend
claude_mutant "dropped import line" "$differs" mut_drop
claude_mutant "changed import target" "$differs" mut_target
claude_mutant "trailing newline removed" "$differs" mut_nonl

if reason="$(claude_import_check "$claude_scratch/absent")"; then
    bad "a missing CLAUDE.md passed"
elif [ "$reason" = "CLAUDE.md is missing" ]; then
    ok "a missing CLAUDE.md fails with its own message"
else
    bad "a missing CLAUDE.md failed with the wrong message: $reason"
fi

# --- 9. AGENTS.md chains stay within the 32 KiB guidance budget (#606) ---------
#
# See the header: chain function over (directory, file list), committed cases on
# scratch trees, failure paths red.
BUDGET_BYTES=32768
budget_scratch="$claude_scratch/budget"
mkdir -p "$budget_scratch" || { bad "cannot create the budget scratch directory"; budget_scratch=""; }

# budget_bytes FILE: prints FILE's byte count; returns 1 unless it is a readable regular file.
budget_bytes() {
    local n
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then
        return 1
    fi
    n="$(wc -c <"$1")" || return 1
    n="${n//[[:space:]]/}"
    case "$n" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$n"
}

# budget_check ROOT LISTFILE: LISTFILE is NUL-delimited AGENTS.md paths relative
# to ROOT. Prints one line per problem and returns 1 if there is any.
budget_check() {
    local root="$1" list="$2" p cur cand member total n names found rc=0 have_root=0
    local -a all=()
    if [ ! -r "$list" ]; then
        echo "cannot read the AGENTS.md file list"
        return 1
    fi
    while IFS= read -r -d '' p; do
        all+=("$p")
    done <"$list"
    if [ "${#all[@]}" -gt 0 ]; then
        for p in "${all[@]}"; do
            [ "$p" = "AGENTS.md" ] && have_root=1
        done
    fi
    if [ "$have_root" -ne 1 ]; then
        echo "no root AGENTS.md tracked: this repo must have one"
        return 1
    fi
    for p in "${all[@]}"; do
        case "$p" in
            AGENTS.md|*/AGENTS.md) ;;
            *) echo "listed path is not an AGENTS.md: $p"; rc=1; continue ;;
        esac
        total=0
        names=""
        cur="$(dirname "$p")"
        while :; do
            if [ "$cur" = "." ]; then cand="AGENTS.md"; else cand="$cur/AGENTS.md"; fi
            found=0
            for member in "${all[@]}"; do
                [ "$member" = "$cand" ] && found=1
            done
            if [ "$found" -eq 1 ]; then
                if ! n="$(budget_bytes "$root/$cand")"; then
                    echo "cannot take the byte count of $cand"
                    rc=1
                    total=-1
                    break
                fi
                total=$((total + n))
                names="${names:+$names + }$cand"
            fi
            [ "$cur" = "." ] && break
            cur="$(dirname "$cur")"
        done
        if [ "$total" -gt "$BUDGET_BYTES" ]; then
            echo "AGENTS.md chain over budget: $names = $total bytes > $BUDGET_BYTES"
            rc=1
        fi
    done
    return "$rc"
}

# budget_list ROOT OUT: writes the tracked AGENTS.md paths (NUL-delimited) to OUT; returns 1 if git cannot list them.
budget_list() {
    git -C "$1" ls-files -z -- 'AGENTS.md' ':(glob)**/AGENTS.md' >"$2" 2>/dev/null
}

if [ -n "$budget_scratch" ]; then
    live_list="$budget_scratch/live.list"
    if ! budget_list "$REPO_ROOT" "$live_list"; then
        bad "cannot list the tracked AGENTS.md files"
    elif reason="$(budget_check "$REPO_ROOT" "$live_list")"; then
        ok "every tracked AGENTS.md chain is within $BUDGET_BYTES bytes"
    else
        bad "$reason"
    fi

    # budget_tree NAME: a fresh scratch tree; sets $t. budget_file REL BYTES: writes BYTES bytes at $t/REL.
    budget_tree() { t="$budget_scratch/$1"; rm -rf "$t"; mkdir -p "$t" || bad "cannot create scratch tree $1"; : >"$t/.list"; }
    budget_file() {
        mkdir -p "$(dirname "$t/$1")"
        head -c "$2" /dev/zero | tr '\0' 'a' >"$t/$1"
    }
    budget_list_add() { printf '%s\0' "$1" >>"$t/.list"; }
    # budget_case LABEL WANT: WANT is "pass" or a substring the failure message must carry.
    budget_case() {
        local label="$1" want="$2" out
        if out="$(budget_check "$t" "$t/.list")"; then
            if [ "$want" = "pass" ]; then ok "budget: $label passes"; else bad "budget: $label stayed green"; fi
        elif [ "$want" = "pass" ]; then
            bad "budget: $label failed: $out"
        else
            case "$out" in
                *"$want"*) ok "budget: $label turns the section red" ;;
                *) bad "budget: $label failed with the wrong message: $out" ;;
            esac
        fi
    }
    budget_applied() { # LABEL FILE BYTES: the mutant's file really has that size
        local n
        if n="$(budget_bytes "$2")" && [ "$n" = "$3" ]; then return 0; fi
        bad "budget: mutant '$1' did not apply"
        return 1
    }

    budget_tree boundary-pass; budget_file AGENTS.md 32768; budget_list_add AGENTS.md
    budget_applied "root at the boundary" "$t/AGENTS.md" 32768 && budget_case "a root of exactly 32768 bytes" pass

    budget_tree root-over; budget_file AGENTS.md 32769; budget_list_add AGENTS.md
    budget_applied "root one byte over" "$t/AGENTS.md" 32769 && budget_case "a root of 32769 bytes" "AGENTS.md chain over budget: AGENTS.md = 32769 bytes"

    budget_tree nested-over; budget_file AGENTS.md 20000; budget_file sub/AGENTS.md 15000
    budget_list_add AGENTS.md; budget_list_add sub/AGENTS.md
    if budget_applied "nested root" "$t/AGENTS.md" 20000 && budget_applied "nested file" "$t/sub/AGENTS.md" 15000; then
        budget_case "a nested file that takes the chain over with each file alone under" "AGENTS.md chain over budget: sub/AGENTS.md + AGENTS.md = 35000 bytes"
    fi

    budget_tree nested-boundary; budget_file AGENTS.md 16384; budget_file sub/AGENTS.md 16384
    budget_list_add AGENTS.md; budget_list_add sub/AGENTS.md
    budget_applied "nested at the boundary" "$t/sub/AGENTS.md" 16384 && budget_case "a chain of exactly 32768 bytes across two files" pass

    budget_tree siblings; budget_file AGENTS.md 20000; budget_file a/AGENTS.md 10000; budget_file b/AGENTS.md 10000
    budget_list_add AGENTS.md; budget_list_add a/AGENTS.md; budget_list_add b/AGENTS.md
    budget_applied "sibling" "$t/b/AGENTS.md" 10000 && budget_case "sibling directories are not summed" pass

    budget_tree skipped-level; budget_file AGENTS.md 30000; budget_file sub/deep/AGENTS.md 5000
    budget_list_add AGENTS.md; budget_list_add sub/deep/AGENTS.md
    budget_applied "skipped level" "$t/sub/deep/AGENTS.md" 5000 && budget_case "a deep file with no AGENTS.md in the directory between still sums the root" "sub/deep/AGENTS.md + AGENTS.md = 35000 bytes"

    budget_tree no-agents
    budget_case "a tree with no AGENTS.md at all" "no root AGENTS.md tracked"

    budget_tree nested-only; budget_file sub/AGENTS.md 100; budget_list_add sub/AGENTS.md
    budget_applied "nested only" "$t/sub/AGENTS.md" 100 && budget_case "a nested AGENTS.md with no root" "no root AGENTS.md tracked"

    budget_tree listed-missing; budget_file AGENTS.md 100; budget_list_add AGENTS.md; budget_list_add sub/AGENTS.md
    if [ ! -e "$t/sub/AGENTS.md" ]; then
        budget_case "a listed path that does not exist" "cannot take the byte count of sub/AGENTS.md"
    else
        bad "budget: mutant 'listed but missing' did not apply"
    fi

    budget_tree listed-dir; budget_file AGENTS.md 100; budget_list_add AGENTS.md; mkdir -p "$t/sub/AGENTS.md"; budget_list_add sub/AGENTS.md
    if [ -d "$t/sub/AGENTS.md" ]; then
        budget_case "a listed AGENTS.md that is a directory" "cannot take the byte count of sub/AGENTS.md"
    else
        bad "budget: mutant 'listed directory' did not apply"
    fi

    budget_tree list-unreadable; budget_file AGENTS.md 100
    if out="$(budget_check "$t" "$t/absent.list")"; then
        bad "budget: a missing file list passed"
    else
        case "$out" in
            *"cannot read the AGENTS.md file list"*) ok "budget: a missing file list turns the section red" ;;
            *) bad "budget: a missing file list failed with the wrong message: $out" ;;
        esac
    fi

    budget_tree not-a-repo; budget_file AGENTS.md 100
    if git -C "$t" rev-parse --git-dir >/dev/null 2>&1; then
        bad "budget: mutant 'git cannot list' did not apply (scratch tree is inside a repository)"
    elif budget_list "$t" "$t/.list"; then
        bad "budget: a git that cannot list the tracked files passed"
    else
        ok "budget: a git that cannot list the tracked files turns the section red"
    fi

    # Shapes the gate does not measure, pinned so the header's claim stays true.
    budget_tree untracked; budget_file AGENTS.md 20000; budget_file sub/AGENTS.md 20000; budget_list_add AGENTS.md
    budget_applied "untracked file" "$t/sub/AGENTS.md" 20000 && budget_case "an untracked nested AGENTS.md is not measured" pass

    budget_tree override; budget_file AGENTS.md 20000; budget_file AGENTS.override.md 40000; budget_list_add AGENTS.md
    budget_applied "override file" "$t/AGENTS.override.md" 40000 && budget_case "an AGENTS.override.md is not measured" pass
fi

if [ "$fails" -ne 0 ]; then
    echo "test-doc-reconciliation: FAILED ($fails)" >&2
    exit 1
fi
echo "Doc reconciliation tests: all green"
