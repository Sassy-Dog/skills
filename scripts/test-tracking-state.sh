#!/usr/bin/env bash
# test-tracking-state.sh — proves skills/setup-config/scripts/tracking-state.sh
# derives, plans, applies and verifies the public-repo tracking end state of
# `.claude/settings.json` and the owned hook scripts (issue #475).
#
# WHY THE RULES LIVE IN A SCRIPT AND THIS GATE. The tracking choice was first
# written as prose and patched three times: each patch fixed the transition the
# reviewer had just reproduced and left the next one. Round 2: local -> committed
# -> local left settings.json and every hook UNTRACKED BUT NOT IGNORED, so
# `git add -A` staged them. Round 3, three more: (1) under setup-repo,
# setup-config added settings.json before setup-hooks rendered the artifact
# guard, so the state derived as committed, the guard was never added, and
# setup-hooks' verify failed on every re-run; (2) local lines + an untracked
# settings.json + a still-tracked owned script derived as local and passed green;
# (3) committed lines without `!.claude/sassy-dog/` derived as committed while
# new config was ignored. Round 4 added the hostile-input class a script that
# runs `git add` on names it finds has to survive: unquoted path lists
# (`sassydog-x .env .sh` made `plan` print `git-add: .env`), a symlinked
# .gitignore written through, and `*` spanning `/`. Each came from deriving "the
# state" from one or two of the facts that define it, or trusting a name. A
# script that derives from ALL of them, and a gate that enumerates their
# combinations and the hostile ones, replaces re-reading prose for what it forgot.
#
# WHAT IT RUNS. Temp `git init` repos only: no network, no gh, nothing in this
# repo's own .claude/ or .gitignore. Each distinct input state (the .gitignore
# variant x settings.json tracked/untracked x an owned script
# none/tracked/untracked/passed-only-via---owned x a non-owned hook) is BUILT
# ONCE, derived once, then `cp -a`'d per target. For every row the gate asserts,
# against an ORACLE written independently of the script (it reads the row's own
# parameters, never the script's output): the derived state and that `.mismatches`
# is empty exactly when the state is not mixed (with a named mismatch on the
# representative rows); that `plan` then `apply --plan-id` reaches the target and
# `verify` passes; that a second `plan` proposes nothing; that `git add -A -n`
# stages no non-owned hook and no settings.local.json; and, with
# `git check-ignore --no-index` and `git ls-files` rather than the script's own
# probes, the end state's tracked/ignored facts. A row already AT its target must
# plan nothing and leave the index and .gitignore unchanged.
#
# NAMED SCENARIOS (each its own labelled assertions): the round-2 chain; round-3
# failures 1-3; the BLOCKING round-4 sequence (setup-config's committed plan and
# apply, passing no --owned, succeeds with exit 0 while a sibling generator
# renders the guard LATER, then setup-hooks' plan + apply adds it, and `apply`
# refuses with exit 4 a path that does not exist yet); the plan-id refusal and
# the required --plan-id; unrelated lines interleaved with the managed block (they
# and their order survive); duplicate managed lines; no .gitignore; a missing
# trailing newline; CRLF; hostile hook names (whitespace, glob, quote, `$`) that
# must never reach `git add` or a printed command; a symlinked .gitignore
# (refused, the outside file untouched); an owned-name DIRECTORY and a path
# nested under one (`git add -A -n` stages nothing nested); a tracked non-owned
# hook (stays tracked); a corrupted index (fails closed: "unknown, not
# verified", never ok); and the mismatch TIE (a misordered line makes local and
# committed equally far, and the tie goes to local). Issue #477 added: every
# refusal kind runs toward BOTH targets (refused_both) with a .gitignore
# checksum, `git ls-files -s` and `git add -A -n` snapshot before and after,
# including an index-only symlink (120000) and submodule (160000); plan stability
# before and after an owned script is rendered, and "nothing to do" printing no
# plan-id; an ignore rule OUTSIDE the managed lines (nested .gitignore in both
# directions, an unmanaged root line, .git/info/exclude, core.excludesFile) that
# apply refuses with exit 8, plus the two cases that must NOT block (an
# info/exclude line the root negation outranks, a nested rule that agrees with
# the target); a symlinked .claude keeping git's own stderr; and exit 5 from a
# failed `git add`. The matrix size is pinned as literals (76 states, 152 rows).
#
# NON-VACUOUS BY CONSTRUCTION. The gate mutates a COPY of the script and runs the
# scenario that owns each mutation against it; a mutant is only scored once it
# passes `bash -n` and a baseline `derive` on it still emits valid JSON (a mutant
# that merely does not run is not "caught"), and it must turn at least one
# assertion red or the gate fails ("mutant survived"). Recorded here because a
# gate that cannot show it fires is the failure mode this repo keeps paying for:
#   dropowned   removes the owned scripts from derive's status checks. Caught by
#               round-3 failure 2 (a tracked owned script under local lines).
#   dropsassy   removes BOTH `!.claude/sassy-dog/` checks (the missing-line check
#               and the not-ignored probe of a new config path). Caught by
#               round-3 failure 3. Dropping only one is not enough on purpose:
#               the other still catches it, which is why both go.
#   droporder   committed negations no longer have to follow their pattern.
#               Caught by the misordered-line scenario.
#   tie         the nearer-state comparison `-lt` becomes `-le`, so a tie reports
#               the committed list instead of the local one. Caught by the tie row.
#   dropsafe    the [A-Za-z0-9._/-] name check is removed, so a hostile name
#               reaches the path lists unquoted (the unquoted-path class). Caught
#               by the hostile-names scenario.
#   dropsymlink the symlink refusal is removed. Caught by the symlinked
#               .gitignore scenario (apply must exit 6 and leave the link alone).
#   dropfail    `exit 2` on a failed git probe is removed, so a corrupted index
#               reads as a clean state. Caught by the corrupted-index scenario.
#   droprefuse  the exit-7 refusal before the first write is removed, so `apply`
#               no longer refuses while an unsafe, nested, directory or symlinked
#               owned-name entry exists. Caught by the hostile, nested and
#               symlinked-owned-name scenarios (exit code, checksum of .gitignore,
#               `git ls-files -s` and `git add -A -n` before and after).
#   droprule    the exit-8 refusal for an ignore rule outside the managed lines is
#               removed. Caught by s_rulesrc (exit code, snapshots).
#   hidecause   git check-ignore's stderr is discarded again, so the fail-closed
#               message loses git's cause. Caught by the symlinked-.claude scenario.
#   shrinkmatrix one VARIANTS entry is dropped and the state list rebuilt. Caught
#               by the pinned literals (built, not run, so it costs nothing).
#   killrow     a row worker is made to exit before it reports. Caught by the
#               harness's own accounting: exactly one `@@counts` line and a zero
#               exit status per launched worker, and totals equal to what was
#               launched (a worker killed with `kill -9` once read as 150 rows,
#               "all green").
# Also asserted here, not mutated: every skills/*/SKILL.md path that names
# tracking-state.sh resolves to the real file (setup-hooks reaches across skills
# to setup-config's script and nothing else fails if it moves).
#
# CLAUDE.md names the pipeline-into-grep rule (test-pipefail-grep.sh): every
# probe here captures into a variable and matches with a here-string or case.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-tracking-state.sh
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/setup-config/scripts/tracking-state.sh"
[ -r "$SCRIPT" ] || { echo "FAIL: $SCRIPT is missing" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

PASS=0; FAIL=0; QUIET=0
ok()  { PASS=$((PASS + 1)); [ "$QUIET" -eq 1 ] || echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); [ "$QUIET" -eq 1 ] || echo "  FAIL  $1" >&2; }
# expect <label> <got> <want>
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
# contains <label> <haystack> <needle>
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (found '$3' in: $2)" ;; *) ok "$1" ;; esac; }

TS="$SCRIPT"
# tsd <dir> <args...> — run the script in <dir>.
tsd() { local d="$1"; shift; if [ "$QUIET" -eq 1 ]; then ( cd "$d" && bash "$TS" "$@" 2>/dev/null ); else ( cd "$d" && bash "$TS" "$@" ); fi; }
# do_apply <dir> <target> [--owned ...] — preview, then apply the previewed plan-id.
APPLY_RC=0; APPLY_OUT=""
do_apply() {
    local d="$1" t="$2" id; shift 2
    id="$(tsd "$d" plan --target "$t" "$@" | sed -n 's/^plan-id: //p')"
    APPLY_OUT="$(tsd "$d" apply --target "$t" "$@" --plan-id "${id:-none}" 2>&1)"; APPLY_RC=$?
}

G='.claude/hooks/sassydog-artifact-guard.sh'
NONOWNED='.claude/hooks/mine.sh'
W='.claude/*'; S='!.claude/sassy-dog/'; NS='!.claude/settings.json'; NH='!.claude/hooks/'
HW='.claude/hooks/*'; HN='!.claude/hooks/sassydog-*.sh'; HD='.claude/hooks/sassydog-*.sh/'

# gi_variant <name> — the .gitignore body for a variant, to stdout.
gi_variant() {
    case "$1" in
        local-exact)        printf '%s\n' "$W" "$S" ;;
        committed-exact)    printf '%s\n' "$W" "$S" "$NS" "$NH" "$HW" "$HN" "$HD" ;;
        local-no-sassy)     printf '%s\n' "$W" ;;
        committed-no-sassy) printf '%s\n' "$W" "$NS" "$NH" "$HW" "$HN" "$HD" ;;
        committed-no-NS)    printf '%s\n' "$W" "$S" "$NH" "$HW" "$HN" "$HD" ;;
        committed-no-NH)    printf '%s\n' "$W" "$S" "$NS" "$HW" "$HN" "$HD" ;;
        committed-no-HW)    printf '%s\n' "$W" "$S" "$NS" "$NH" "$HN" "$HD" ;;
        committed-no-HN)    printf '%s\n' "$W" "$S" "$NS" "$NH" "$HW" "$HD" ;;
        committed-no-HD)    printf '%s\n' "$W" "$S" "$NS" "$NH" "$HW" "$HN" ;;
        committed-NS-first) printf '%s\n' "$NS" "$W" "$S" "$NH" "$HW" "$HN" "$HD" ;;
        committed-HN-first) printf '%s\n' "$W" "$S" "$NS" "$NH" "$HN" "$HW" "$HD" ;;
        committed-HD-first) printf '%s\n' "$W" "$S" "$NS" "$NH" "$HW" "$HD" "$HN" ;;
        round2-negs-only)   printf '%s\n' "$W" "$S" "$NS" "$NH" ;;
        bare-claude)        printf '%s\n' '.claude/' "$S" ;;
        empty)              : ;;
    esac
}
VARIANTS="local-exact committed-exact local-no-sassy committed-no-sassy committed-no-NS committed-no-NH committed-no-HW committed-no-HN committed-no-HD committed-NS-first committed-HN-first committed-HD-first round2-negs-only bare-claude empty"

# The template every state starts from: a repo whose only commit tracks the
# sassy-dog config. `cp -a` of it is far cheaper than rebuilding per row.
mkdir -p "$WORK/emptytpl"
TPL="$WORK/tpl"
mkdir -p "$TPL/.claude/sassy-dog" "$TPL/.claude/hooks"
( cd "$TPL" || exit 1
  git init -q --template="$WORK/emptytpl" .
  echo '---' > .claude/sassy-dog/send-it.md
  git add -f .claude/sassy-dog
  git commit -qm base ) >/dev/null 2>&1

# mkstate <dir> <gi variant|-> <settings tracked|untracked> <owned none|tracked|untracked|flag> <nonowned 0|1>
mkstate() {
    local d="$1" v="$2" s="$3" o="$4" n="$5"
    rm -rf "$d"; cp -a "$TPL" "$d"
    ( cd "$d" || exit 1
      local adds=()
      if [ "$v" != - ]; then gi_variant "$v" > .gitignore; adds+=(.gitignore); fi
      echo '{}' > .claude/settings.json
      echo '{}' > .claude/settings.local.json
      mkdir -p .claude/worktrees/x; echo w > .claude/worktrees/x/f
      [ "$s" = tracked ] && adds+=(.claude/settings.json)
      case "$o" in
          tracked)   printf '#!/bin/sh\n' > "$G"; adds+=("$G") ;;
          untracked) printf '#!/bin/sh\n' > "$G" ;;
      esac
      [ "$n" = 1 ] && printf '#!/bin/sh\n' > "$NONOWNED"
      [ "${#adds[@]}" -eq 0 ] || git add -f -- "${adds[@]}" ) >/dev/null 2>&1
}

# oracle <variant> <settings> <owned> — the state the row MUST derive.
oracle() {
    local v="$1" s="$2" o="$3"
    if [ "$v" = committed-exact ] && [ "$s" = tracked ] && { [ "$o" = none ] || [ "$o" = tracked ]; }; then echo committed
    elif [ "$v" = local-exact ] && [ "$s" = untracked ] && { [ "$o" = none ] || [ "$o" = untracked ] || [ "$o" = flag ]; }; then echo local
    else echo mixed; fi
}

# mm_expect <variant> <settings> <owned> — a substring the representative rows'
# `.mismatches` must carry, or empty when the row is not one the nearer end state
# is unambiguous for.
mm_expect() {
    local v="$1" s="$2" o="$3"
    [ "$o" = none ] || return 0
    case "$v:$s" in
        committed-no-sassy:tracked) echo "lacks '$S'" ;;
        committed-no-NS:tracked)    echo "lacks '$NS'" ;;
        committed-no-NH:tracked)    echo "lacks '$NH'" ;;
        committed-no-HW:tracked)    echo "lacks '$HW'" ;;
        committed-no-HN:tracked)    echo "lacks '$HN'" ;;
        committed-no-HD:tracked)    echo "lacks '$HD'" ;;
        committed-NS-first:tracked) echo "does not come after" ;;
        committed-HN-first:tracked) echo "does not come after" ;;
        committed-HD-first:tracked) echo "does not come after" ;;
        local-no-sassy:untracked)   echo "lacks '$S'" ;;
        bare-claude:untracked)      echo "bare '.claude/' line" ;;
    esac
}

# facts <dir> <target> <owned> <label> — independent of the script's own probes.
facts() {
    local d="$1" t="$2" o="$3" lbl="$4" err
    err="$( cd "$d" || exit 1
      for p in .claude/settings.json "$G"; do
          [ "$p" = "$G" ] && [ "$o" = none ] && continue
          tr=n; git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && tr=y
          ig=n; git check-ignore --no-index -q -- "$p" && ig=y
          if [ "$t" = local ]; then
              { [ "$tr" = n ] && [ "$ig" = y ]; } || { echo "$p tracked=$tr ignored=$ig, want untracked+ignored"; exit 1; }
          else
              { [ "$tr" = y ] && [ "$ig" = n ]; } || { echo "$p tracked=$tr ignored=$ig, want tracked+not ignored"; exit 1; }
          fi
      done
      ! git check-ignore --no-index -q -- .claude/sassy-dog/zz.md || { echo "config would be ignored"; exit 1; }
      git check-ignore --no-index -q -- .claude/settings.local.json || { echo "settings.local.json not ignored"; exit 1; }
      git check-ignore --no-index -q -- .claude/worktrees/x/f || { echo "worktrees not ignored"; exit 1; }
      staged="$(git add -A -n 2>&1)"
      case "$staged" in *mine.sh*|*settings.local.json*|*worktrees*|*evil*) echo "git add -A -n would stage: $staged"; exit 1 ;; esac
    )" && ok "$lbl: end-state facts hold ($t)" || bad "$lbl: end-state facts ($t): $err"
}

# flow <dir> <label> <target> <owned> <want-state> — the plan/apply/verify cycle on a copy.
flow() {
    local d="$1" lbl="$2" t="$3" o="$4" want="$5" plan out gi0 st0
    local flags=(); [ "$o" = flag ] && flags=(--owned "$G")
    if [ "$want" = "$t" ]; then
        gi0="$(cat "$d/.gitignore" 2>/dev/null)"; st0="$(cd "$d" && git status --porcelain)"
        plan="$(tsd "$d" plan --target "$t" "${flags[@]}")"
        contains "$lbl: at target -> nothing to do" "$plan" "nothing to do"
        expect "$lbl: at target, nothing changed" "$gi0|$st0" "$(cat "$d/.gitignore" 2>/dev/null)|$(cd "$d" && git status --porcelain)"
        return 0
    fi
    [ "$o" = flag ] && printf '#!/bin/sh\n' > "$d/$G"   # a late-rendered script exists by apply time
    do_apply "$d" "$t" "${flags[@]}"
    if [ "$APPLY_RC" -eq 0 ]; then ok "$lbl: apply reaches $t"; else bad "$lbl: apply exit $APPLY_RC: $APPLY_OUT"; fi
    tsd "$d" verify --target "$t" "${flags[@]}" >/dev/null 2>&1; expect "$lbl: verify passes" "$?" 0
    plan="$(tsd "$d" plan --target "$t" "${flags[@]}")"
    contains "$lbl: second plan proposes nothing" "$plan" "nothing to do"
    facts "$d" "$t" "$o" "$lbl"
}

# run_state <label> <variant> <settings> <owned> <nonowned> — build once, derive once, flow per target.
run_state() {
    local idx="$1" lbl="$2" v="$3" s="$4" o="$5" n="$6" want got json mm exp
    local flags=(); [ "$o" = flag ] && flags=(--owned "$G")
    mkstate "$WORK/st.$idx" "$v" "$s" "$o" "$n"
    want="$(oracle "$v" "$s" "$o")"
    json="$(tsd "$WORK/st.$idx" derive "${flags[@]}")"
    got="$(jq -r .state <<<"$json")"; mm="$(jq -r '.mismatches | join(" | ")' <<<"$json")"
    expect "$lbl: derives $want" "$got" "$want"
    if [ "$want" = mixed ]; then [ -n "$mm" ] && ok "$lbl: mixed names a mismatch" || bad "$lbl: mixed with no mismatch"
    else expect "$lbl: ${want} has no mismatches" "$mm" ""; fi
    exp="$(mm_expect "$v" "$s" "$o")"
    [ -z "$exp" ] || contains "$lbl: names the mismatch" "$mm" "$exp"
    for t in local committed; do
        rows=$((rows + 1))
        rm -rf "$WORK/tg.$idx"; cp -a "$WORK/st.$idx" "$WORK/tg.$idx"
        flow "$WORK/tg.$idx" "$lbl -> $t" "$t" "$o" "$want"
    done
    rm -rf "$WORK/st.$idx" "$WORK/tg.$idx"
}

# --- named scenarios -------------------------------------------------------------
# Each takes no arguments and is self-contained, so a mutant run can pick the one
# that owns it.
fresh() { mkstate "$WORK/sc" "$1" "$2" "$3" "$4"; SC="$WORK/sc"; }
state_of() { tsd "$1" derive "${@:2}" | jq -r .state; }

s_round2() {
    fresh local-exact untracked none 0
    do_apply "$SC" committed; do_apply "$SC" local
    facts "$SC" local none "round-2 chain, back at local"
    do_apply "$SC" committed
    facts "$SC" committed none "round-2 chain, committed again"
}
s_blocking() {
    # setup-config: committed, no --owned, guard not rendered yet
    fresh local-exact untracked none 0
    expect "round-4 blocking: setup-config derive with no --owned" "$(state_of "$SC")" local
    do_apply "$SC" committed
    expect "round-4 blocking: setup-config's committed apply exits 0" "$APPLY_RC" 0
    # setup-config passing --owned for a script that does not exist yet is refused
    fresh local-exact untracked none 0
    local gi0; gi0="$(cat "$SC/.gitignore")"
    do_apply "$SC" committed --owned "$G"
    expect "round-4 blocking: apply refuses a not-yet-rendered --owned path (exit 4)" "$APPLY_RC" 4
    expect "round-4 blocking: the refusal wrote nothing" "$(cat "$SC/.gitignore")" "$gi0"
    # the real sequence: setup-config applies, setup-hooks renders then plans+applies
    fresh local-exact untracked none 0
    do_apply "$SC" committed
    printf '#!/bin/sh\n' > "$SC/$G"
    expect "round-3 #1: a script rendered after the settings.json add derives mixed" "$(state_of "$SC")" mixed
    contains "round-3 #1: and names it" "$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')" "$G is untracked"
    do_apply "$SC" committed --owned "$G"
    expect "round-4 blocking: setup-hooks' plan+apply adds the guard (exit 0)" "$APPLY_RC" 0
    tsd "$SC" verify --target committed --owned "$G" >/dev/null 2>&1; expect "round-4 blocking: setup-hooks' verify passes" "$?" 0
    facts "$SC" committed tracked "round-4 blocking, after setup-hooks"
    # --owned of an absent script keeps the derive honest before it exists
    fresh local-exact untracked none 0
    expect "round-3 #1: --owned of an absent script keeps local derive local" "$(state_of "$SC" --owned "$G")" local
    contains "round-3 #1: plan names the not-yet-rendered guard" "$(tsd "$SC" plan --target committed --owned "$G")" "git-add: $G"
}
s_r3_2() {
    fresh local-exact untracked tracked 0
    expect "round-3 #2: a tracked owned script under local lines derives mixed" "$(state_of "$SC")" mixed
    do_apply "$SC" local
    facts "$SC" local tracked "round-3 #2, after apply"
}
s_r3_3() {
    fresh committed-no-sassy tracked none 0
    expect "round-3 #3: committed lines without the sassy-dog negation derive mixed" "$(state_of "$SC")" mixed
    do_apply "$SC" committed
    facts "$SC" committed none "round-3 #3, after apply"
}
s_order() {
    fresh committed-NS-first tracked none 0
    expect "misordered negation derives mixed" "$(state_of "$SC")" mixed
    contains "misordered negation is named" "$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')" "does not come after"
    do_apply "$SC" committed
    facts "$SC" committed none "misordered negation, after apply"
}
s_tie() {
    # NS before W, then S, NH, HW: local and committed are each 4 mismatches away.
    mkstate "$WORK/sc" - tracked none 0; SC="$WORK/sc"
    printf '%s\n' "$NS" "$W" "$S" "$NH" "$HW" > "$SC/.gitignore"
    local lc cc mm lm
    lc="$(tsd "$SC" verify --target local | grep -c .)"; cc="$(tsd "$SC" verify --target committed | grep -c .)"
    expect "tie row is a real tie (local and committed equally far)" "$lc" "$cc"
    mm="$(tsd "$SC" derive | jq -r '.mismatches | join("|")')"
    lm="$(tsd "$SC" verify --target local | tr '\n' '|')"; lm="${lm%|}"
    expect "tie row: a tie reports LOCAL's mismatches" "$mm" "$lm"
}
s_unrelated() {
    mkstate "$WORK/sc" - untracked none 0; SC="$WORK/sc"
    printf '%s\n' 'node_modules/' "$W" '# keep me' "$S" 'dist/' > "$SC/.gitignore"
    do_apply "$SC" committed
    expect "interleaved: apply exits 0" "$APPLY_RC" 0
    expect "interleaved: unrelated lines survive in order" "$(unrelated "$SC/.gitignore")" "node_modules/|# keep me|dist/"
    do_apply "$SC" local
    expect "interleaved: back to local exits 0" "$APPLY_RC" 0
    expect "interleaved: unrelated lines still survive in order" "$(unrelated "$SC/.gitignore")" "node_modules/|# keep me|dist/"
}
# unrelated <file> — the lines that are not managed, '|'-joined, CR stripped.
unrelated() {
    local l t out=""
    while IFS= read -r l || [ -n "$l" ]; do
        t="${l%$'\r'}"
        case "$t" in "$W"|"$S"|"$NS"|"$NH"|"$HW"|"$HN"|"$HD"|'.claude/'|'.claude') ;; *) out+="$t|" ;; esac
    done < "$1"
    printf '%s' "${out%|}"
}
s_dup() {
    mkstate "$WORK/sc" - untracked none 0; SC="$WORK/sc"
    printf '%s\n' "$W" "$S" "$W" "$S" > "$SC/.gitignore"
    do_apply "$SC" committed
    expect "duplicate managed lines: apply exits 0" "$APPLY_RC" 0
    tsd "$SC" verify --target committed >/dev/null 2>&1; expect "duplicate managed lines: verify passes" "$?" 0
    facts "$SC" committed none "duplicate managed lines"
}
s_nogi() {
    mkstate "$WORK/sc" - untracked none 0; SC="$WORK/sc"
    rm -f "$SC/.gitignore"
    do_apply "$SC" committed
    expect "no .gitignore: apply exits 0" "$APPLY_RC" 0
    expect "no .gitignore: created as a regular file" "$([ -f "$SC/.gitignore" ] && [ ! -L "$SC/.gitignore" ] && echo yes)" yes
    facts "$SC" committed none "no .gitignore"
}
s_nonl() {
    mkstate "$WORK/sc" - untracked none 0; SC="$WORK/sc"
    printf '%s\n%s' "$W" "$S" > "$SC/.gitignore"
    do_apply "$SC" committed
    expect "no trailing newline: apply exits 0" "$APPLY_RC" 0
    expect "no trailing newline: the file now ends in one" "$(tail -c1 "$SC/.gitignore" | od -An -c | tr -d ' ')" '\n'
    expect "no trailing newline: seven lines" "$(grep -c . "$SC/.gitignore")" 7
    facts "$SC" committed none "no trailing newline"
}
s_crlf() {
    mkstate "$WORK/sc" - untracked none 0; SC="$WORK/sc"
    printf 'node_modules/\r\n%s\r\n%s\r\n' "$W" "$S" > "$SC/.gitignore"
    expect "CRLF: lines ending in CR are read (derives local)" "$(state_of "$SC")" local
    do_apply "$SC" committed
    expect "CRLF: apply exits 0" "$APPLY_RC" 0
    local l bare=0 total=0
    while IFS= read -r l || [ -n "$l" ]; do total=$((total + 1)); case "$l" in *$'\r') ;; *) bare=$((bare + 1)) ;; esac; done < "$SC/.gitignore"
    expect "CRLF: no line lost its CR (never mixed)" "$bare" 0
    expect "CRLF: eight lines" "$total" 8
    facts "$SC" committed none "CRLF"
}
s_nonowned_tracked() {
    mkstate "$WORK/sc" local-exact untracked none 1; SC="$WORK/sc"
    ( cd "$SC" && git add -f "$NONOWNED" ) >/dev/null 2>&1
    do_apply "$SC" committed
    expect "tracked non-owned hook: apply exits 0" "$APPLY_RC" 0
    contains "tracked non-owned hook stays tracked" "$(cd "$SC" && git ls-files)" "$NONOWNED"
    do_apply "$SC" local
    contains "tracked non-owned hook stays tracked after untracking the owned ones" "$(cd "$SC" && git ls-files)" "$NONOWNED"
}
# snap <dir> — checksum of .gitignore, the staged index, and what `git add -A -n` would stage.
snap() { ( cd "$1" && { cksum < .gitignore 2>/dev/null || echo nogi; git ls-files -s; echo "--"; git add -A -n 2>&1; } ); }
# refused <label> <dir> <target> <rc> [flags] — apply must exit <rc> and change NOTHING.
REFUSED_PLAN=""
refused() {
    local lbl="$1" d="$2" t="$3" rc="$4" before after plan; shift 4
    before="$(snap "$d")"
    plan="$(tsd "$d" plan --target "$t" "$@")"; REFUSED_PLAN="$plan"
    contains "$lbl: plan prints blocked:" "$plan" "blocked:"
    lacks "$lbl: plan proposes no action" "$plan" "git-add:"
    lacks "$lbl: plan proposes no untracking" "$plan" "git-rm-cached:"
    lacks "$lbl: plan proposes no .gitignore edit" "$plan" "gitignore-"
    do_apply "$d" "$t" "$@"
    expect "$lbl: apply refuses with exit $rc" "$APPLY_RC" "$rc"
    after="$(snap "$d")"
    expect "$lbl: .gitignore, index and git add -A -n are all unchanged" "$after" "$before"
}
# refused_both <label> <dir> <rc> [flags] — the same refusal toward BOTH targets
# on the same directory (a refusal writes nothing, so the second run starts from
# the identical state).
refused_both() {
    local lbl="$1" d="$2" rc="$3"; shift 3
    refused "$lbl -> committed" "$d" committed "$rc" "$@"
    refused "$lbl -> local" "$d" local "$rc" "$@"
}
s_hostile() {
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    ( cd "$SC" || exit 1
      printf 'secret\n' > .env
      printf '#!/bin/sh\n' > '.claude/hooks/sassydog-x .env .sh'
      printf '#!/bin/sh\n' > '.claude/hooks/sassydog-g*.sh'
      printf '#!/bin/sh\n' > ".claude/hooks/sassydog-q'x.sh"
      printf '#!/bin/sh\n' > '.claude/hooks/sassydog-$HOME.sh' )
    local plan json
    plan="$(tsd "$SC" plan --target committed)"
    lacks "hostile names: plan never prints 'git-add: .env'" "$plan" "git-add: .env"
    json="$(tsd "$SC" derive)"
    expect "hostile names: none is owned" "$(jq -r '.owned | length' <<<"$json")" 0
    expect "hostile names: each is an unsafe-name mismatch" "$(jq -r '[.mismatches[] | select(startswith("unsafe owned name"))] | length' <<<"$json")" 4
    refused_both "hostile names" "$SC" 7
    lacks "hostile names: no hostile hook would be staged" "$(cd "$SC" && git add -A -n 2>&1)" "sassydog-"
    tsd "$SC" derive --owned '.claude/hooks/sassydog-x .env .sh' >/dev/null 2>&1; expect "hostile names: --owned with whitespace is refused (exit 64)" "$?" 64
    # committed to local with a tracked unsafe name must not untrack settings.json or the guard
    mkstate "$WORK/sc" committed-exact tracked tracked 0; SC="$WORK/sc"
    ( cd "$SC" && printf '#!/bin/sh\n' > '.claude/hooks/sassydog-a b.sh' && git add -f -- '.claude/hooks/sassydog-a b.sh' ) >/dev/null 2>&1
    refused_both "tracked hostile name" "$SC" 7
    contains "tracked hostile name: settings.json is still tracked" "$(cd "$SC" && git ls-files)" ".claude/settings.json"
    # the restore line is built with %q: a safe name stays plain
    mkstate "$WORK/sc" committed-exact tracked tracked 0; SC="$WORK/sc"
    contains "restore line lists the safe owned path" "$(tsd "$SC" plan --target local)" "restore (run right after pulling): git restore --source=<untrack-commit>^ --worktree -- .claude/settings.json $G"
}
s_ownedlink() {
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    ln -s /etc/hosts "$SC/.claude/hooks/sassydog-link.sh"
    contains "symlinked owned-name entry is named" "$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')" "sassydog-link.sh is not a regular file (symlink)"
    refused_both "symlinked owned-name entry" "$SC" 7
    expect "symlinked owned-name entry: the link is untouched" "$(readlink "$SC/.claude/hooks/sassydog-link.sh")" /etc/hosts
}
s_symlink() {
    mkstate "$WORK/sc" - untracked none 0; SC="$WORK/sc"
    printf 'outside\n' > "$WORK/outside-gi"
    rm -f "$SC/.gitignore"; ln -s "$WORK/outside-gi" "$SC/.gitignore"
    expect "symlinked .gitignore derives mixed" "$(state_of "$SC")" mixed
    contains "symlinked .gitignore is named" "$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')" "symlink"
    refused_both "symlinked .gitignore" "$SC" 6
    expect "symlinked .gitignore: the outside file is unchanged" "$(cat "$WORK/outside-gi")" outside
    expect "symlinked .gitignore: still a symlink" "$([ -L "$SC/.gitignore" ] && echo yes)" yes
}
s_nested() {
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    mkdir -p "$SC/.claude/hooks/sassydog-d.sh" "$SC/.claude/hooks/sassydog-e.sh"
    printf 'x\n' > "$SC/.claude/hooks/sassydog-d.sh/evil"
    local mm
    mm="$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')"
    contains "owned-name directory is not a regular file" "$mm" "sassydog-e.sh is not a regular file"
    contains "path nested under an owned-name entry is named" "$mm" "nested path under an owned-name entry: .claude/hooks/sassydog-d.sh/evil"
    refused_both "nested path and owned-name directory" "$SC" 7
    lacks "nested path: nothing nested is tracked" "$(cd "$SC" && git ls-files)" "evil"
    lacks "nested path: git add -A -n stages nothing nested" "$(cd "$SC" && git add -A -n 2>&1)" "evil"
    lacks "owned-name directory: git add -A -n stages none" "$(cd "$SC" && git add -A -n 2>&1)" "sassydog-e.sh"
}
# s_indexkinds — an owned-name entry that exists only in the INDEX as a symlink
# (mode 120000) or a submodule (160000): no working-tree file backs it.
s_indexkinds() {
    local blob
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    blob="$(cd "$SC" && printf '/etc/hosts' | git hash-object -w --stdin)"
    ( cd "$SC" && git update-index --add --cacheinfo "120000,$blob,.claude/hooks/sassydog-idxlink.sh" ) >/dev/null 2>&1
    contains "index-level symlink is named" "$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')" "sassydog-idxlink.sh is not a regular file (symlink)"
    refused_both "index-level symlink (mode 120000)" "$SC" 7
    mkstate "$WORK/sc" committed-exact tracked tracked 0; SC="$WORK/sc"
    ( cd "$SC" && git update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,.claude/hooks/sassydog-sub.sh" ) >/dev/null 2>&1
    contains "index-level submodule is named" "$(tsd "$SC" derive | jq -r '.mismatches | join(" | ")')" "sassydog-sub.sh is not a regular file (dir)"
    refused_both "index-level submodule (mode 160000)" "$SC" 7
}
# s_planstable — a plan previewed BEFORE an owned script is rendered is the plan
# after it exists (setup-hooks previews, writes, then re-plans); and a plan that
# is "nothing to do" has NO plan-id, so a caller must not demand one.
s_planstable() {
    local before after
    fresh local-exact untracked none 0
    before="$(tsd "$SC" plan --target committed --owned "$G")"
    printf '#!/bin/sh\n' > "$SC/$G"
    after="$(tsd "$SC" plan --target committed --owned "$G")"
    contains "plan before the script is rendered carries a plan-id" "$before" "plan-id: "
    expect "plan before and after the script is rendered: identical action lines and plan-id" "$after" "$before"
    fresh local-exact untracked none 0
    before="$(tsd "$SC" plan --target local --owned "$G")"
    printf '#!/bin/sh\n' > "$SC/$G"
    after="$(tsd "$SC" plan --target local --owned "$G")"
    contains "local target, script not yet rendered: nothing to do" "$before" "nothing to do"
    lacks "nothing to do prints no plan-id" "$before" "plan-id"
    contains "local target, script rendered: still nothing to do" "$after" "nothing to do"
    lacks "nothing to do after rendering prints no plan-id" "$after" "plan-id"
}
# s_rulesrc — an ignore rule OUTSIDE the managed root lines. apply must refuse
# with exit 8 before its first write, and plan names the winning rule.
s_rulesrc() {
    local lc
    # a nested .gitignore ignoring settings.json, target committed (the #477 repro)
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    printf 'settings.json\n' > "$SC/.claude/.gitignore"
    refused "nested .gitignore ignores settings.json -> committed" "$SC" committed 8
    contains "nested ignore: plan names the file and line" "$REFUSED_PLAN" ".claude/.gitignore:1:settings.json"
    contains "nested ignore: plan says git add -f does not help" "$REFUSED_PLAN" "git add -f would not help"
    # the other direction: a nested negation keeps settings.json un-ignored, target local
    mkstate "$WORK/sc" committed-exact tracked none 0; SC="$WORK/sc"
    printf '!settings.json\n' > "$SC/.claude/.gitignore"
    refused "nested .gitignore un-ignores settings.json -> local" "$SC" local 8
    contains "nested negation: plan names the file and line" "$REFUSED_PLAN" ".claude/.gitignore:1:!settings.json"
    # an unmanaged line of the root .gitignore that outranks the managed negation
    mkstate "$WORK/sc" committed-exact tracked none 0; SC="$WORK/sc"
    printf '%s\n' 'settings.json' >> "$SC/.gitignore"
    refused "unmanaged root line ignores settings.json -> committed" "$SC" committed 8
    contains "unmanaged root line: plan names the root file and line" "$REFUSED_PLAN" ".gitignore:8:settings.json"
    # .git/info/exclude ignoring every .md (new sassy-dog config would be ignored), both targets
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    mkdir -p "$SC/.git/info"; printf "*.md\n" >> "$SC/.git/info/exclude"
    refused_both "info/exclude ignores *.md" "$SC" 8
    contains "info/exclude: plan names the exclude file" "$REFUSED_PLAN" "info/exclude:"
    # core.excludesFile, both targets
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    printf '*.md\n' > "$WORK/global-exclude"
    ( cd "$SC" && git config core.excludesFile "$WORK/global-exclude" ) >/dev/null 2>&1
    refused_both "core.excludesFile ignores *.md" "$SC" 8
    contains "core.excludesFile: plan names that file" "$REFUSED_PLAN" "$WORK/global-exclude:1:*.md"
    # NOT a block: info/exclude ignoring settings.json is outranked by the root's own negation
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    mkdir -p "$SC/.git/info"; printf ".claude/settings.json\n" >> "$SC/.git/info/exclude"
    do_apply "$SC" committed
    expect "info/exclude ignoring settings.json is outranked by the root negation: apply exits 0" "$APPLY_RC" 0
    facts "$SC" committed none "info/exclude outranked by the root negation"
    # a nested rule that agrees with the target is fine (settings.local.json stays ignored)
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    printf 'settings.local.json\n' > "$SC/.claude/.gitignore"
    do_apply "$SC" committed
    expect "a nested rule that agrees with the target does not block (exit 0)" "$APPLY_RC" 0
    lc="$(cd "$SC" && git ls-files)"
    contains "and settings.json is tracked" "$lc" ".claude/settings.json"
}
# s_claudelink — a symlinked .claude: git refuses, the script fails closed (exit 2)
# AND keeps git's own cause instead of discarding it.
s_claudelink() {
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    rm -rf "$WORK/claude-real"; mv "$SC/.claude" "$WORK/claude-real"; ln -s "$WORK/claude-real" "$SC/.claude"
    local out rc
    out="$(cd "$SC" && bash "$TS" derive 2>&1)"; rc=$?
    expect "symlinked .claude: derive fails closed (exit 2)" "$rc" 2
    contains "symlinked .claude: says unknown, not verified" "$out" "unknown, not verified"
    contains "symlinked .claude: carries git's own cause" "$out" "beyond a symbolic link"
}
# s_exit5 — a git add that FAILS after the rewrite is exit 5 with a message naming it.
s_exit5() {
    local id
    fresh local-exact untracked none 0
    id="$(tsd "$SC" plan --target committed | sed -n 's/^plan-id: //p')"
    : > "$SC/.git/index.lock"
    APPLY_OUT="$(tsd "$SC" apply --target committed --plan-id "$id" 2>&1)"; APPLY_RC=$?
    expect "failed git add: apply exits 5" "$APPLY_RC" 5
    contains "failed git add: a message names the path" "$APPLY_OUT" "git add failed for .claude/settings.json (exit 5)"
    rm -f "$SC/.git/index.lock"
}
s_corrupt() {
    mkstate "$WORK/sc" local-exact untracked none 0; SC="$WORK/sc"
    printf 'garbage' > "$SC/.git/index"
    local out rc
    out="$(cd "$SC" && bash "$TS" derive 2>&1)"; rc=$?
    expect "corrupted index: derive fails closed (exit 2)" "$rc" 2
    contains "corrupted index: says unknown, not verified" "$out" "unknown, not verified"
    out="$(cd "$SC" && bash "$TS" verify --target local 2>&1)"; rc=$?
    expect "corrupted index: verify never says ok (exit 2)" "$rc" 2
    lacks "corrupted index: verify prints no ok" "$out" "ok:"
    out="$(cd "$SC" && bash "$TS" apply --target committed --plan-id 1 2>&1)"; rc=$?
    expect "corrupted index: apply fails closed (exit 2)" "$rc" 2
}
s_planid() {
    fresh local-exact untracked none 0
    local id rc
    id="$(tsd "$SC" plan --target committed | sed -n 's/^plan-id: //p')"
    printf '#!/bin/sh\n' > "$SC/$G"
    tsd "$SC" apply --target committed --plan-id "$id" >/dev/null 2>&1; rc=$?
    expect "plan-id: apply refuses (exit 3) once the repo moved past the previewed plan" "$rc" 3
    tsd "$SC" apply --target committed >/dev/null 2>&1; rc=$?
    expect "plan-id: apply without --plan-id is a usage error (exit 64)" "$rc" 64
}

SCENARIOS="s_round2 s_blocking s_r3_2 s_r3_3 s_order s_tie s_planid s_unrelated s_dup s_nogi s_nonl s_crlf s_nonowned_tracked s_hostile s_ownedlink s_symlink s_nested s_indexkinds s_planstable s_rulesrc s_claudelink s_exit5 s_corrupt"

# --- 1. the enumerated rows -------------------------------------------------------
# Rows are independent (each state has its own directories), so they run in
# batches of JOBS background subshells; each writes its report and exactly one
# counts line to its own file. The harness checks every worker's exit status and
# that it printed exactly one counts line, and that the totals equal what it
# launched: a worker that dies is a failure, never a silently shorter run.
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
case "$JOBS" in ''|*[!0-9]*) JOBS=4 ;; esac
[ "$JOBS" -le 8 ] || JOBS=8
# The matrix size, PINNED AS LITERALS. A VARIANTS entry dropped or a `continue`
# filter widened shrinks the matrix, and every per-worker accounting check below
# compares the matrix to ITSELF, so only a literal notices. Derivation: 15
# variants, 2 of them exact. Each of the 13 others crosses settings (2) x owned
# {none, tracked} (2) with no non-owned hook = 4 states (52). Each exact variant
# crosses settings (2) x owned (4) = 8 states, plus the non-owned hook where the
# owned set is none or untracked (2 more per settings value) = 12 (24). 52 + 24 =
# 76 states, two targets each = 152 rows.
WANT_VARIANTS=15; WANT_STATES=76; WANT_ROWS=152
STATE_LIST=()
# build_state_list <variants> — STATE_LIST for that variant list.
build_state_list() {
    local v s o n exact
    STATE_LIST=()
    for v in $1; do
        exact=0; case "$v" in local-exact|committed-exact) exact=1 ;; esac
        for s in tracked untracked; do
            for o in none tracked untracked flag; do
                # Every variant crosses settings x {none, tracked}; the two exact
                # variants (the only ones that can be AT a target) cross the full
                # owned set and the non-owned hook, where each adds a distinct case.
                if [ "$exact" -eq 0 ] && [ "$o" != none ] && [ "$o" != tracked ]; then continue; fi
                for n in 0 1; do
                    if [ "$n" = 1 ] && { [ "$exact" -eq 0 ] || { [ "$o" != none ] && [ "$o" != untracked ]; }; }; then continue; fi
                    STATE_LIST+=("$v $s $o $n")
                done
            done
        done
    done
}
# matrix_literals <variant count> <states> <rows> — the literals, as assertions.
matrix_literals() {
    expect "matrix: $WANT_VARIANTS variants" "$1" "$WANT_VARIANTS"
    expect "matrix: $WANT_STATES states" "$2" "$WANT_STATES"
    expect "matrix: $WANT_ROWS rows" "$3" "$WANT_ROWS"
}
build_state_list "$VARIANTS"
R_STATES=0; R_ROWS=0
BATCH=(); BPIDS=(); COUNTED=0
flush() {
    local k i out p f r line c rc
    for k in "${!BATCH[@]}"; do
        i="${BATCH[$k]}"
        wait "${BPIDS[$k]}"; rc=$?
        out="$WORK/out.$i"; c=0
        while IFS= read -r line; do
            case "$line" in
                "@@counts "*) c=$((c + 1)); read -r _ p f r <<<"$line"; PASS=$((PASS + p)); FAIL=$((FAIL + f)); R_ROWS=$((R_ROWS + r)) ;;
                *) [ "$QUIET" -eq 1 ] || echo "$line" ;;
            esac
        done < "$out"
        [ "$rc" -eq 0 ] || bad "row worker $i exited $rc"
        if [ "$c" -ne 1 ]; then bad "row worker $i printed $c counts lines, want exactly 1"; else COUNTED=$((COUNTED + 1)); fi
    done
    BATCH=(); BPIDS=()
}
# run_rows <max states, 0 = all> <worker index that exits before reporting, 0 = none>
run_rows() {
    local maxn="$1" dieat="$2" entry v s o n launched=0
    R_STATES=0; R_ROWS=0; COUNTED=0; BATCH=(); BPIDS=()
    for entry in "${STATE_LIST[@]}"; do
        [ "$maxn" -eq 0 ] || [ "$launched" -lt "$maxn" ] || break
        launched=$((launched + 1))
        read -r v s o n <<<"$entry"
        (   PASS=0; FAIL=0; rows=0
            run_state "$launched" "[$v/$s/$o/n$n]" "$v" "$s" "$o" "$n"
            [ "$launched" -ne "$dieat" ] || exit 9
            echo "@@counts $PASS $FAIL $rows"
        ) > "$WORK/out.$launched" 2>&1 &
        BATCH+=("$launched"); BPIDS+=("$!")
        [ "${#BATCH[@]}" -lt "$JOBS" ] || flush
    done
    flush
    R_STATES="$launched"
    [ "$COUNTED" -eq "$launched" ] || bad "only $COUNTED of $launched row workers reported"
    [ "$R_ROWS" -eq $((launched * 2)) ] || bad "rows total $R_ROWS, want $((launched * 2)) (two targets per state)"
}
echo "tracking-state rows"
run_rows 0 0
echo "  ($R_STATES states, $R_ROWS rows)"
read -ra VLIST <<<"$VARIANTS"
matrix_literals "${#VLIST[@]}" "$R_STATES" "$R_ROWS"
ok "every one of $R_STATES row workers reported once, with $R_ROWS rows (2 per state)"

# --- cross-skill dependency: every path that names tracking-state.sh must exist --
echo "script references"
refs=0; setup_hooks_refs=0
for f in "$REPO_ROOT"/skills/*/SKILL.md; do
    while IFS= read -r line; do
        rest="$line"
        while [[ "$rest" =~ (skills/[A-Za-z0-9_-]+/scripts/tracking-state\.sh) ]]; do
            ref="${BASH_REMATCH[1]}"; refs=$((refs + 1))
            [ -f "$REPO_ROOT/$ref" ] && ok "${f#"$REPO_ROOT"/}: $ref resolves" || bad "${f#"$REPO_ROOT"/} names $ref, which does not exist"
            case "$f" in */setup-hooks/SKILL.md) setup_hooks_refs=$((setup_hooks_refs + 1)) ;; esac
            rest="${rest#*"$ref"}"
        done
    done < "$f"
done
[ "$setup_hooks_refs" -gt 0 ] && ok "setup-hooks names the script by path (the check is not vacuous: $refs references)" || bad "setup-hooks no longer names skills/setup-config/scripts/tracking-state.sh by path, or this check lost its reach"

# --- 2. the named scenarios ---------------------------------------------------------
echo "named scenarios"
for sc in $SCENARIOS; do "$sc"; done

# --- 3. each mutant must turn its scenario red --------------------------------------
echo "mutants (each must be caught by the scenario that owns it)"
mutate() { # <name> <out>
    local name="$1" out="$2"
    case "$name" in
        dropowned) awk '/done <<<"\$SETTINGS"/ && !d { sub(/"\$OWNED"$/, "\"\""); d = 1 } { print }' "$SCRIPT" > "$out" ;;
        dropsassy) sed -e 's/\[ -z "\$L_S" \]/false/' -e 's/! ignored "\$PROBE_CONFIG" ||/true ||/' "$SCRIPT" > "$out" ;;
        droporder) sed -e 's/\[ "\$L_NS" -gt "\$L_W" \]/true/' -e 's/\[ "\$L_NH" -gt "\$L_W" \]/true/' -e 's/\[ "\$L_HW" -gt "\$L_NH" \]/true/' -e 's/\[ "\$L_HN" -gt "\$L_HW" \]/true/' -e 's/\[ "\$L_HD" -gt "\$L_HN" \]/true/' "$SCRIPT" > "$out" ;;
        tie) sed -e 's/\[ "\$cn" -lt "\$ln" \]/[ "$cn" -le "$ln" ]/' "$SCRIPT" > "$out" ;;
        dropsafe) awk '/^safe_path\(\) \{/ { print "safe_path() { return 0; }"; next } { print }' "$SCRIPT" > "$out" ;;
        dropsymlink) sed -e '/is a symlink; it is never read or written through/d' "$SCRIPT" > "$out" ;;
        dropfail) awk '/^        exit 2$/ { print "        :"; next } { print }' "$SCRIPT" > "$out" ;;
        droprefuse) sed -e '/refusing to apply, nothing was written/d' "$SCRIPT" > "$out" ;;
        droprule) sed -e '/an ignore rule outside the managed lines would leave/d' "$SCRIPT" > "$out" ;;
        hidecause) sed -e 's|2>"\$TMPD/ck.err"|2>/dev/null|' "$SCRIPT" > "$out" ;;
    esac
}
# mutant_scenarios <name> — the scenarios that own it.
mutant_scenarios() {
    case "$1" in
        dropowned) echo s_r3_2 ;; dropsassy) echo s_r3_3 ;; droporder) echo s_order ;;
        tie) echo s_tie ;; dropsafe) echo s_hostile ;; dropsymlink) echo s_symlink ;; dropfail) echo s_corrupt ;; droprefuse) echo "s_hostile s_ownedlink s_nested s_indexkinds" ;;
        droprule) echo s_rulesrc ;; hidecause) echo s_claudelink ;;
    esac
}
for m in dropowned dropsassy droporder tie dropsafe dropsymlink dropfail droprefuse droprule hidecause; do
    mut="$WORK/mut-$m.sh"
    mutate "$m" "$mut"
    if cmp -s "$mut" "$SCRIPT"; then bad "mutant $m changed nothing (the mutation did not apply)"; continue; fi
    if ! bash -n "$mut" 2>/dev/null; then bad "mutant $m is not valid bash, so it proves nothing"; continue; fi
    mkstate "$WORK/base" local-exact untracked none 0
    if ! ( cd "$WORK/base" && bash "$mut" derive 2>/dev/null | jq -e .state >/dev/null 2>&1 ); then bad "mutant $m does not emit valid derive JSON, so it proves nothing"; continue; fi
    TS="$mut"; before="$FAIL"; pbefore="$PASS"; QUIET=1
    for sc in $(mutant_scenarios "$m"); do "$sc"; done
    QUIET=0; after="$FAIL"; TS="$SCRIPT"
    if [ "$after" -gt "$before" ]; then
        FAIL="$before"; PASS="$pbefore"; ok "mutant $m is caught ($((after - before)) assertion(s) went red)"
    else
        bad "mutant $m SURVIVED — its scenario did not notice"
    fi
done

# killrow: the harness itself. A row worker that exits before reporting must turn
# the accounting red; run three states with worker 2 forced to exit.
before="$FAIL"; pbefore="$PASS"; QUIET=1
run_rows 3 2
QUIET=0; after="$FAIL"
if [ "$after" -gt "$before" ]; then
    FAIL="$before"; PASS="$pbefore"; ok "mutant killrow is caught ($((after - before)) accounting failure(s): a dead row worker is not silently dropped)"
else
    bad "mutant killrow SURVIVED — a row worker that dies reads as a pass"
fi

# shrinkmatrix: the matrix size literals. Drop one VARIANTS entry, rebuild the
# state list, and the literals must go red (the list is built, not run).
before="$FAIL"; pbefore="$PASS"; QUIET=1
build_state_list "${VARIANTS#* }"
read -ra VLIST <<<"${VARIANTS#* }"
matrix_literals "${#VLIST[@]}" "${#STATE_LIST[@]}" $((${#STATE_LIST[@]} * 2))
QUIET=0; after="$FAIL"
if [ "$after" -gt "$before" ]; then
    FAIL="$before"; PASS="$pbefore"; ok "mutant shrinkmatrix is caught ($((after - before)) literal(s) went red when one VARIANTS entry was dropped)"
else
    bad "mutant shrinkmatrix SURVIVED — a shrunk matrix reads as a pass"
fi

echo "tracking-state: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "tracking-state tests: all green" >&2; exit 0; }
echo "tracking-state tests: FAILURES above" >&2
exit 1
