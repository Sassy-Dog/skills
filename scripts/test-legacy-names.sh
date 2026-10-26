#!/usr/bin/env bash
# test-legacy-names.sh — proves scripts/check-legacy-names.sh, the legacy-name
# guard preflight runs as gate 4 (issue #612).
#
# WHY THIS GATE EXISTS. The guard's allow lists were proven twice (#609, #611)
# by a manual scratch-clone run, and nothing re-ran those proofs. A later PR
# could add a file to one name's allow list to make CI green and a stale mention
# would then land unnoticed, which is the exact shape #610 had to fix by hand.
# The three refresh-sassydog- producer names had also been pooled into one
# branch, which contradicted the guard's own per-name rule.
#
# THE REAL CHECKER IS EXECUTED, and nothing of it is transcribed: this file
# holds no guarded name, no allow list and no producer list. It reads the names
# from `check-legacy-names.sh names` and each name's sanctioned paths from
# `check-legacy-names.sh allow NAME`, then runs the checker (never a copy of its
# logic) from scratch git repos built from the tracked tree. Appending text to a
# scratch copy is the only mutation, and the real checkout is only read.
#
# CASES, each asserted by exit status AND message (all on a scratch copy):
#   1. the emitters: `names` is non-empty and duplicate-free, `allow NAME` has a
#      branch for every name, an unknown name exits 1, a bad subcommand exits 64,
#      and none of it needs a repo.
#   2. green on an unmodified copy of the real tracked tree (exit 0, silent).
#   3. for every guarded name, an append to a file in NO allow list turns it red
#      (exit 1, `'<name>' outside the sanctioned back-compat files`, the file).
#   4. for every sanctioned file, appending each name that file is NOT sanctioned
#      for turns exactly those names red and leaves the names it is sanctioned
#      for green. That is the per-name proof: the three refresh-sassydog- appends
#      of issue #612 section 3 are three instances of it, and so is every
#      cross-pairing of the others.
#   5. appending every name to the files it IS sanctioned in stays green.
#   6. an unbranched name hits the default arm (exit 1, `no allow list for
#      '<name>'`) whether it is added LAST (where it would inherit the previous
#      branch's list) or FIRST (where the list would be unset), reports no false
#      residue on a clean tree, and the later names are still checked.
#   7. A `git grep` that cannot run exits 2 with its own message, and a directory
#      that is not a repo exits 2 with its own message; neither reads as clean.
#   7c. A scan failure followed by residue on a later name still exits 2: the
#      highest status wins, and the residue is still reported.
#
# MUTANTS. Each enforcing construct in the checker has one mutant: a copy of the
# real checker with that construct neutered but its message text left in the
# source. The mutant must be applied (the copy differs from the original) and the
# scenario that owns the construct must then FAIL on it. The same scenarios are
# first required to PASS on the real checker, so a mutant going red means the
# scenario saw the neutered construct and not that the scenario is broken.
#   default arm returns an inherited list ........ scenario 6 (last)
#   default arm does not fail the run ............ scenario 6 (last)
#   default arm stops the later names (break) .... scenario 6 (first)
#   a hit does not fail the run .................. scenario 3
#   note_status is a no-op, and exit is forced 0 . scenario 3
#   git grep errors read as "no residue" ......... scenario 7
#   status is last-write-wins, not highest ....... scenario 7c (a failure, then residue)
#   a non-repo directory is not fatal ............ scenario 7
#   allow lists collapse (specs ignore them) ..... scenario 5
#   one name's list gains another name's file .... scenario 4
#
# NOT CHECKED HERE, so nothing claims more than it proves: the checker's
# `cd "$root" || fatal` (a repo root that cannot be entered; no case reaches it),
# that a name was not DELETED from the checker's list (this file reads that list,
# so it cannot see a name that is gone), that an allow list is minimal (a widened list passes; the
# diff of check-legacy-names.sh is where that is reviewed), untracked files, and
# the checker's matching of a name written in a different case or split across a
# line. The checker's header says the same.
#
# Parallel-safe (issue #567): its own mktemp -d, scratch git repos only, no write
# in the checkout, no port, no named container. No gh, no network.
set -uo pipefail
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "test-legacy-names: not in a git repo" >&2; exit 1; }
CHECKER="$REPO_ROOT/scripts/check-legacy-names.sh"
[ -f "$CHECKER" ] || { echo "test-legacy-names: $CHECKER is missing" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/legacy-names.XXXXXX")" || { echo "test-legacy-names: cannot create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*" >&2; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }

# ---------------------------------------------------------------------------
# scratch tree: a copy of the tracked files, in its own git repo
# ---------------------------------------------------------------------------
SCR="$WORK/tree"
mkdir "$SCR" || exit 1
# No -C on the creating tar: GNU tar rejects -C after the -T operand, BSD tar does not. cd instead.
if ! { (cd "$REPO_ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$SCR"; }; then
    bad "scratch tree — copying the tracked files failed; every case below would run on nothing"
    echo "legacy-name tests: FAILURES above" >&2
    exit 1
fi
if ! { git -C "$SCR" init -q && git -C "$SCR" add -f -A; }; then
    bad "scratch tree — git init/add failed"
    echo "legacy-name tests: FAILURES above" >&2
    exit 1
fi
if [ -z "$(git -C "$SCR" ls-files -- scripts/check-legacy-names.sh)" ]; then
    bad "scratch tree — does not hold the checker; copying the tracked files is broken (is the checker untracked?)"
    echo "legacy-name tests: FAILURES above" >&2
    exit 1
fi

OUT=""
RC=0
run_in() { # run_in <dir> <checker> [args...] -> OUT, RC (stdout and stderr together)
    local dir="$1"
    shift
    OUT=$(cd "$dir" && bash "$@" 2>&1)
    RC=$?
}

restore() { git -C "$SCR" checkout -q -- . ; }
append() { # append <relpath> <line...>
    local f="$1"
    shift
    printf '%s\n' "$@" >>"$SCR/$f"
}
tree_clean() { [ -z "$(git -C "$SCR" diff --name-only)" ]; }

REASON=""
why() { REASON="${REASON:+$REASON; }$*"; }
out_has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------------------
# the names and lists, read from the checker (never transcribed)
# ---------------------------------------------------------------------------
NAMES=()
while IFS= read -r n; do
    [ -n "$n" ] && NAMES+=("$n")
done < <(bash "$CHECKER" names)
if [ "${#NAMES[@]}" -eq 0 ]; then
    bad "emitter — 'names' printed nothing; every per-name case below would cover nothing"
    echo "legacy-name tests: FAILURES above" >&2
    exit 1
fi

resolve() { # resolve <allow path> -> a tracked file in the scratch tree (a directory resolves to its first file)
    case "$1" in
        */) git -C "$SCR" ls-files -- "$1" | head -n 1 ;;
        *) printf '%s\n' "$1" ;;
    esac
}
covered() { # covered <name> <tracked file> : is the file inside the name's allow list?
    local n="$1" f="$2" p
    while IFS= read -r p; do
        case "$p" in
            */) case "$f" in "$p"*) return 0 ;; esac ;;
            *) [ "$p" = "$f" ] && return 0 ;;
        esac
    done < <(bash "$CHECKER" allow "$n")
    return 1
}

# ---------------------------------------------------------------------------
# 1. the emitters
# ---------------------------------------------------------------------------
dups=$(printf '%s\n' "${NAMES[@]}" | sort | uniq -d)
if [ -z "$dups" ]; then ok "emitter — 'names' lists ${#NAMES[@]} names, none twice"; else bad "emitter — 'names' repeats: $dups"; fi

NOREPO="$WORK/norepo"
mkdir "$NOREPO"
missing=""
for n in "${NAMES[@]}"; do
    run_in "$NOREPO" "$CHECKER" allow "$n"
    if [ "$RC" -ne 0 ] || [ -z "$OUT" ]; then missing="$missing '$n'(exit $RC)"; fi
done
if [ -z "$missing" ]; then ok "emitter — every guarded name has a branch with a non-empty allow list (read outside any repo)"; else bad "emitter — no usable allow list for:$missing"; fi

run_in "$NOREPO" "$CHECKER" allow "zz-no-such-name"
if [ "$RC" = 1 ]; then ok "emitter — an unknown name exits 1"; else bad "emitter — an unknown name exited $RC, wanted 1"; fi
run_in "$NOREPO" "$CHECKER" allow
if [ "$RC" = 64 ]; then ok "emitter — 'allow' without a name exits 64"; else bad "emitter — 'allow' without a name exited $RC, wanted 64"; fi
run_in "$NOREPO" "$CHECKER" bogus
if [ "$RC" = 64 ]; then ok "emitter — an unknown subcommand exits 64"; else bad "emitter — an unknown subcommand exited $RC, wanted 64"; fi
run_in "$NOREPO" "$CHECKER" names
if [ "$RC" = 0 ]; then ok "emitter — 'names' needs no repo"; else bad "emitter — 'names' exited $RC outside a repo"; fi

# ---------------------------------------------------------------------------
# the probe: a tracked file that NO allow list sanctions
# ---------------------------------------------------------------------------
PROBE=LICENSE
if [ -z "$(git -C "$SCR" ls-files -- "$PROBE")" ]; then
    bad "probe — $PROBE is not tracked; the 'outside every allow list' cases have no target"
    echo "legacy-name tests: FAILURES above" >&2
    exit 1
fi
probe_sanctioned=""
for n in "${NAMES[@]}"; do
    covered "$n" "$PROBE" && probe_sanctioned="$probe_sanctioned '$n'"
done
if [ -z "$probe_sanctioned" ]; then ok "probe — $PROBE is outside every name's allow list"; else bad "probe — $PROBE is sanctioned for:$probe_sanctioned; pick another file"; fi

# every sanctioned file, resolved to a tracked path, once
SANCTIONED=$(
    for n in "${NAMES[@]}"; do
        while IFS= read -r p; do resolve "$p"; done < <(bash "$CHECKER" allow "$n")
    done | sort -u
)

# ---------------------------------------------------------------------------
# scenarios: each takes the checker to test and returns 0 when it behaves
# correctly, filling REASON otherwise. The real checker must pass every one;
# each mutant must fail the one that owns its construct.
# ---------------------------------------------------------------------------
scn_green() { # 2. unmodified tree
    REASON=""
    run_in "$SCR" "$1"
    [ "$RC" = 0 ] || why "exit $RC on the unmodified tree, wanted 0"
    [ -z "$OUT" ] || why "output on the unmodified tree: $OUT"
    [ -z "$REASON" ]
}

scn_hit() { # 3. every name, appended to a file outside every allow list
    REASON=""
    local n
    for n in "${NAMES[@]}"; do append "$PROBE" "$n"; done
    run_in "$SCR" "$1"
    restore
    [ "$RC" = 1 ] || why "exit $RC with every name planted in $PROBE, wanted 1"
    for n in "${NAMES[@]}"; do
        out_has "'$n' outside the sanctioned back-compat files" || why "'$n' planted in $PROBE was not reported"
    done
    out_has "$PROBE" || why "$PROBE was not named"
    [ -z "$REASON" ]
}

scn_cross() { # 4. a sanctioned file only sanctions the names it is sanctioned for
    REASON=""
    local f n exp_red
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        exp_red=""
        for n in "${NAMES[@]}"; do
            covered "$n" "$f" || { append "$f" "$n"; exp_red="$exp_red $n"; }
        done
        [ -n "$exp_red" ] || continue
        run_in "$SCR" "$1"
        restore
        [ "$RC" = 1 ] || why "$f: exit $RC, wanted 1"
        for n in "${NAMES[@]}"; do
            if covered "$n" "$f"; then
                out_has "'$n' outside" && why "$f is sanctioned for '$n' but '$n' was reported"
            else
                out_has "'$n' outside the sanctioned back-compat files" || why "$f: '$n' is not sanctioned there but was not reported"
            fi
        done
    done <<<"$SANCTIONED"
    [ -z "$REASON" ]
}

scn_sanctioned() { # 5. every name, appended to the files it IS sanctioned in
    REASON=""
    local n p f
    for n in "${NAMES[@]}"; do
        while IFS= read -r p; do
            f=$(resolve "$p")
            [ -n "$f" ] && append "$f" "$n"
        done < <(bash "$CHECKER" allow "$n")
    done
    run_in "$SCR" "$1"
    restore
    [ "$RC" = 0 ] || why "exit $RC with each name in its own sanctioned files, wanted 0"
    [ -z "$OUT" ] || why "output: $OUT"
    [ -z "$REASON" ]
}

UNBRANCHED=zz-unbranched-name
with_extra_name() { # with_extra_name <checker> first|last <out> : a copy that guards one more name, with no branch
    case "$2" in
        first) awk -v n="$UNBRANCHED" '{ print } /^GUARDED_NAMES=\($/ { print "    \047" n "\047" }' "$1" >"$3" ;;
        last)  awk -v n="$UNBRANCHED" '/^GUARDED_NAMES=\($/ { inl = 1 } inl && /^\)$/ { print "    \047" n "\047"; inl = 0 } { print }' "$1" >"$3" ;;
    esac
}

scn_unbranched() { # 6. <checker> first|last
    REASON=""
    local pos="$2" copy="$WORK/unbranched-$2.sh" planted
    with_extra_name "$1" "$pos" "$copy"
    cmp -s "$1" "$copy" && why "the extra-name copy equals the original ($pos); the case did not apply"
    # clean tree: only the missing-list message, no false residue
    run_in "$SCR" "$copy"
    [ "$RC" = 1 ] || why "$pos, clean tree: exit $RC, wanted 1"
    out_has "no allow list for '$UNBRANCHED'" || why "$pos, clean tree: no 'no allow list' message"
    out_has "outside the sanctioned" && why "$pos, clean tree: the unbranched name inherited a list and flagged residue"
    # a real violation of the name checked AFTER it (first) or BEFORE it (last)
    case "$pos" in first) planted="${NAMES[$((${#NAMES[@]} - 1))]}" ;; *) planted="${NAMES[0]}" ;; esac
    append "$PROBE" "$planted"
    run_in "$SCR" "$copy"
    restore
    out_has "no allow list for '$UNBRANCHED'" || why "$pos, planted: no 'no allow list' message"
    out_has "'$planted' outside the sanctioned back-compat files" || why "$pos: '$planted' was not checked after the unbranched name"
    [ -z "$REASON" ]
}
scn_unbranched_last() { scn_unbranched "$1" last; }
scn_unbranched_first() { scn_unbranched "$1" first; }

REAL_GIT="$(command -v git)"
mkdir "$WORK/stub"
# STUB_FAIL_NAME, when set, restricts the refusal to a grep for that name.
printf '#!/bin/sh\nif [ "$1" = grep ]; then case "$*" in *"${STUB_FAIL_NAME:-}"*) echo "stub git: grep refused" >&2; exit 2;; esac; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$WORK/stub/git"
chmod +x "$WORK/stub/git"

scn_gitfail() { # 7a. git grep cannot run
    REASON=""
    OUT=$(cd "$SCR" && PATH="$WORK/stub:$PATH" bash "$1" 2>&1)
    RC=$?
    [ "$RC" = 2 ] || why "exit $RC when git grep fails, wanted 2"
    out_has "git grep failed" || why "no 'git grep failed' message"
    [ -z "$REASON" ]
}

scn_failthenhit() { # 7c. a scan failure followed by residue on a later name: the failure wins
    REASON=""
    local failing="${NAMES[0]}" later="${NAMES[$((${#NAMES[@]} - 1))]}"
    append "$PROBE" "$later"
    OUT=$(cd "$SCR" && STUB_FAIL_NAME="$failing" PATH="$WORK/stub:$PATH" bash "$1" 2>&1)
    RC=$?
    restore
    [ "$RC" = 2 ] || why "exit $RC for a scan failure followed by residue, wanted 2 (the highest status wins)"
    out_has "git grep failed" || why "no 'git grep failed' message"
    out_has "'$later' outside the sanctioned back-compat files" || why "'$later' residue after the failure was not reported"
    [ -z "$REASON" ]
}

scn_nonrepo() { # 7b. not a repository
    REASON=""
    OUT=$(cd "$NOREPO" && GIT_CEILING_DIRECTORIES="$WORK" bash "$1" 2>&1)
    RC=$?
    [ "$RC" = 2 ] || why "exit $RC outside a repo, wanted 2"
    out_has "not inside a git repository" || why "no 'not inside a git repository' message"
    [ -z "$REASON" ]
}

check_scn() { # check_scn <label> <scenario> : on the real checker
    if "$2" "$CHECKER"; then ok "$1"; else bad "$1 — $REASON"; fi
    tree_clean || { bad "$1 — left the scratch tree modified"; restore; }
}
check_scn "2. green on an unmodified copy of the tracked tree" scn_green
check_scn "3. every guarded name planted outside every allow list is reported" scn_hit
check_scn "4. a sanctioned file sanctions only its own names (per-name lists)" scn_cross
check_scn "5. every name in its own sanctioned files stays green" scn_sanctioned
check_scn "6a. an unbranched name added last hits the default arm; earlier names still checked" scn_unbranched_last
check_scn "6b. an unbranched name added first hits the default arm; later names still checked" scn_unbranched_first
check_scn "7a. a git grep that cannot run exits 2, never clean" scn_gitfail
check_scn "7c. a scan failure then later residue exits 2 (highest status wins)" scn_failthenhit
check_scn "7b. a directory that is not a repo exits 2, never clean" scn_nonrepo

# ---------------------------------------------------------------------------
# mutants
# ---------------------------------------------------------------------------
mutant() { # mutant <label> <scenario> <sed script>  : must apply, and the scenario must then fail
    local label="$1" scn="$2" script="$3" copy
    copy="$WORK/mutant-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-').sh"
    sed "$script" "$CHECKER" >"$copy"
    mutant_check "$label" "$scn" "$copy"
}
mutant_check() { # mutant_check <label> <scenario> <mutant file>
    local label="$1" scn="$2" copy="$3"
    if cmp -s "$CHECKER" "$copy"; then
        bad "mutant: $label — did not apply (the construct it targets moved; update the mutant)"
        return
    fi
    if "$scn" "$copy"; then
        bad "mutant: $label — NOT caught by $scn (the construct is unenforced)"
    else
        ok "mutant: $label — caught by $scn (${REASON%%;*})"
    fi
    tree_clean || restore
}

mutant "default arm returns an inherited list" scn_unbranched_last \
    "s|^        \*) ALLOW=(.*; return 1 ;;|        *) ALLOW=('scripts/check-legacy-names.sh'); return 0 ;;|"
mutant "default arm does not fail the run" scn_unbranched_last \
    's|note_status 1 # unbranched|: # unbranched|'
mutant "default arm stops the later names" scn_unbranched_first \
    's|continue # later names|break # later names|'
mutant "a hit does not fail the run" scn_hit \
    's|note_status 1 # residue|: # residue|'
mutant "note_status is a no-op" scn_hit \
    's|^note_status() {.*|note_status() { return 0; }|'
mutant "exit status forced to 0" scn_hit \
    's|^exit "\$status"|exit 0|'
mutant "git grep errors read as no residue" scn_gitfail \
    's|^        1) : ;;|        [1-9]*) : ;;|'
mutant "status is last-write-wins, not highest" scn_failthenhit \
    's|^note_status() {.*|note_status() { status="$1"; return 0; }|'
mutant "a non-repo directory is not fatal" scn_nonrepo \
    's/|| fatal "not inside/|| : "not inside/'
mutant "allow lists collapse to the checker" scn_sanctioned \
    "s|specs+=(\":!\\\$p\")|specs+=(\":!scripts/check-legacy-names.sh\")|"

# pooling: the first name's list gains a file sanctioned only for other names.
# Built with awk (a multi-line insert is not portable in sed) from the emitters,
# so no name or path is spelled here.
POOL="$WORK/mutant-pooled.sh"
POOL_NAME="${NAMES[0]}"
POOL_FILE=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    covered "$POOL_NAME" "$f" || { POOL_FILE="$f"; break; }
done <<<"$SANCTIONED"
if [ -z "$POOL_FILE" ]; then
    bad "mutant: one name's list gains another name's file — no sanctioned file lies outside '$POOL_NAME'"
else
    awk -v a="$POOL_NAME" -v f="$POOL_FILE" '
        $0 == "        " a ")" { b = 1 }
        { print }
        b && /ALLOW=\($/ { print "                \047" f "\047"; b = 0 }
    ' "$CHECKER" >"$POOL"
    mutant_check "one name's list gains another name's file" scn_cross "$POOL"
fi

echo "legacy-name tests: $pass ok, $fail failed" >&2
if [ "$fail" -eq 0 ]; then
    echo "legacy-name tests: all green" >&2
    exit 0
fi
echo "legacy-name tests: FAILURES above" >&2
exit 1
