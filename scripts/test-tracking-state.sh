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
# new config was ignored. Each came from deriving "the state" from one or two of
# the facts that define it. A script that derives from ALL of them, and a gate
# that enumerates their combinations, replaces re-reading prose for what it
# forgot.
#
# WHAT IT RUNS. Temp `git init` repos only: no network, no gh, nothing in this
# repo's own .claude/ or .gitignore. The ROWS enumerate the derived input state
# (the .gitignore variant x settings.json tracked/untracked x an owned script
# none/tracked/untracked/passed-only-via---owned x a non-owned hook present or
# not) against BOTH targets. For every row the gate asserts, against an ORACLE
# written independently of the script (it reads the row's own parameters, never
# the script's output): the derived state; that `plan` then `apply` reaches the
# target and `verify` passes; that a second `plan` proposes nothing; that
# `git add -A -n` stages no non-owned hook and no settings.local.json; and, with
# `git check-ignore --no-index` and `git ls-files` rather than the script's own
# probes, the end state's tracked/ignored facts. A row already AT its target must
# plan nothing and leave the index and .gitignore byte-identical.
#
# NAMED REPROS (each also a row-shaped assertion, so the report names it): the
# round-2 chain, round-3 failures 1-3, and the plan-id refusal (apply must
# refuse when the repo changed after the plan it was shown).
#
# NON-VACUOUS BY CONSTRUCTION. The gate mutates a COPY of the script and runs the
# named repros against it; each mutant must turn at least one repro red, or the
# gate fails ("mutant survived"). The two required mutations, also recorded here
# because a gate that cannot show it fires is the failure mode this repo keeps
# paying for:
#   dropowned   removes the owned scripts from derive's status checks. Caught by
#               round-3 failure 2 (a tracked owned script under local lines
#               derives as local and passes).
#   dropsassy   removes BOTH `!.claude/sassy-dog/` checks (the missing-line
#               check and the probe that a new config path is not ignored).
#               Caught by round-3 failure 3. Dropping only one is not enough on
#               purpose: the other still catches it, which is why both go.
# `droporder` (committed negations no longer have to follow `.claude/*`) is a
# third, caught by the misordered-variant rows.
#
# CLAUDE.md names the pipeline-into-grep rule (test-pipefail-grep.sh): every
# probe here captures into a variable and matches with a here-string.
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

TS="$SCRIPT"
ts() { if [ "$QUIET" -eq 1 ]; then bash "$TS" "$@" 2>/dev/null; else bash "$TS" "$@"; fi; }

G='.claude/hooks/sassydog-artifact-guard.sh'
NONOWNED='.claude/hooks/mine.sh'
W='.claude/*'; S='!.claude/sassy-dog/'; NS='!.claude/settings.json'; NH='!.claude/hooks/'
HW='.claude/hooks/*'; HN='!.claude/hooks/sassydog-*.sh'

# gi_variant <name> — the .gitignore body for a variant, to stdout.
gi_variant() {
    case "$1" in
        local-exact)       printf '%s\n' "$W" "$S" ;;
        committed-exact)   printf '%s\n' "$W" "$S" "$NS" "$NH" "$HW" "$HN" ;;
        local-no-sassy)    printf '%s\n' "$W" ;;
        committed-no-sassy) printf '%s\n' "$W" "$NS" "$NH" "$HW" "$HN" ;;
        committed-no-NS)   printf '%s\n' "$W" "$S" "$NH" "$HW" "$HN" ;;
        committed-no-NH)   printf '%s\n' "$W" "$S" "$NS" "$HW" "$HN" ;;
        committed-no-HW)   printf '%s\n' "$W" "$S" "$NS" "$NH" "$HN" ;;
        committed-no-HN)   printf '%s\n' "$W" "$S" "$NS" "$NH" "$HW" ;;
        committed-NS-first) printf '%s\n' "$NS" "$W" "$S" "$NH" "$HW" "$HN" ;;
        committed-HN-first) printf '%s\n' "$W" "$S" "$NS" "$NH" "$HN" "$HW" ;;
        round2-negs-only)  printf '%s\n' "$W" "$S" "$NS" "$NH" ;;
        bare-claude)       printf '%s\n' '.claude/' "$S" ;;
        empty)             : ;;
    esac
}
VARIANTS="local-exact committed-exact local-no-sassy committed-no-sassy committed-no-NS committed-no-NH committed-no-HW committed-no-HN committed-NS-first committed-HN-first round2-negs-only bare-claude empty"

# mkrepo <dir> <gi variant> <settings tracked|untracked> <owned none|tracked|untracked|flag> <nonowned 0|1>
mkrepo() {
    local d="$1" v="$2" s="$3" o="$4" n="$5"
    rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" || exit 1
      git init -q .
      mkdir -p .claude/sassy-dog .claude/hooks .claude/worktrees/x
      echo '---' > .claude/sassy-dog/send-it.md
      git add -f .claude/sassy-dog
      git commit -qm base
      gi_variant "$v" > .gitignore
      git add .gitignore
      echo '{}' > .claude/settings.json
      echo '{}' > .claude/settings.local.json
      echo w > .claude/worktrees/x/f
      [ "$s" = tracked ] && git add -f .claude/settings.json
      case "$o" in
          tracked)   printf '#!/bin/sh\n' > "$G"; git add -f "$G" ;;
          untracked) printf '#!/bin/sh\n' > "$G" ;;
      esac
      [ "$n" = 1 ] && printf '#!/bin/sh\n' > "$NONOWNED"
      git commit -qm gi --allow-empty ) >/dev/null 2>&1
}

# oracle <variant> <settings> <owned> — the state the row MUST derive, from the
# row's own parameters only.
oracle() {
    local v="$1" s="$2" o="$3"
    if [ "$v" = committed-exact ] && [ "$s" = tracked ] && { [ "$o" = none ] || [ "$o" = tracked ]; }; then echo committed
    elif [ "$v" = local-exact ] && [ "$s" = untracked ] && { [ "$o" = none ] || [ "$o" = untracked ] || [ "$o" = flag ]; }; then echo local
    else echo mixed; fi
}

OWNFLAG=()
set_flags() { OWNFLAG=(); [ "$1" = flag ] && OWNFLAG=(--owned "$G"); true; }

# end_state_facts <dir> <target> <owned> <label> — independent of the script.
end_state_facts() {
    local d="$1" t="$2" o="$3" lbl="$4" p tr ig staged
    ( cd "$d" || exit 1
      for p in .claude/settings.json "$G"; do
          [ "$p" = "$G" ] && [ "$o" = none ] && continue
          tr=n; git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && tr=y
          ig=n; git check-ignore --no-index -q -- "$p" && ig=y
          if [ "$t" = local ]; then
              [ "$tr" = n ] && [ "$ig" = y ] || { echo "$p tracked=$tr ignored=$ig, want untracked+ignored" >&2; exit 1; }
          else
              [ "$tr" = y ] && [ "$ig" = n ] || { echo "$p tracked=$tr ignored=$ig, want tracked+not ignored" >&2; exit 1; }
          fi
      done
      ! git check-ignore --no-index -q -- .claude/sassy-dog/zz.md || { echo "config would be ignored" >&2; exit 1; }
      git check-ignore --no-index -q -- .claude/settings.local.json || { echo "settings.local.json not ignored" >&2; exit 1; }
      git check-ignore --no-index -q -- .claude/worktrees/x/f || { echo "worktrees not ignored" >&2; exit 1; }
      staged="$(git add -A -n 2>&1)"
      case "$staged" in *mine.sh*|*settings.local.json*|*worktrees*) echo "git add -A -n would stage: $staged" >&2; exit 1 ;; esac
    ) >"$WORK/facts.err" 2>&1 && ok "$lbl: end-state facts hold ($t)" || { bad "$lbl: end-state facts ($t): $(tr '\n' ' ' < "$WORK/facts.err")"; }
}

# run_row <label> <dir> <variant> <settings> <owned> <nonowned> <target>
run_row() {
    local lbl="$1" d="$2" v="$3" s="$4" o="$5" n="$6" t="$7" want got plan out gi0 st0 rc
    mkrepo "$d" "$v" "$s" "$o" "$n"
    set_flags "$o"
    want="$(oracle "$v" "$s" "$o")"
    got="$( cd "$d" && ts derive "${OWNFLAG[@]}" | jq -r .state )"
    [ "$got" = "$want" ] && ok "$lbl: derives $want" || bad "$lbl: derived '$got', oracle says $want"
    if [ "$want" = "$t" ]; then
        gi0="$(cat "$d/.gitignore")"; st0="$(cd "$d" && git status --porcelain)"
        plan="$( cd "$d" && ts plan --target "$t" "${OWNFLAG[@]}" )"
        case "$plan" in *"nothing to do"*) ok "$lbl: at target -> nothing to do" ;; *) bad "$lbl: at target but plan proposed: $plan" ;; esac
        [ "$gi0" = "$(cat "$d/.gitignore")" ] && [ "$st0" = "$(cd "$d" && git status --porcelain)" ] && ok "$lbl: at target, nothing changed" || bad "$lbl: at target but the repo changed"
        return 0
    fi
    # a late-rendered owned script exists by apply time (setup-hooks renders it first)
    ( cd "$d" && ts plan --target "$t" "${OWNFLAG[@]}" ) >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] && ok "$lbl: plan exits 0" || bad "$lbl: plan exit $rc"
    [ "$o" = flag ] && { mkdir -p "$d/.claude/hooks"; printf '#!/bin/sh\n' > "$d/$G"; }
    out="$( cd "$d" && ts apply --target "$t" "${OWNFLAG[@]}" 2>&1 )"; rc=$?
    [ "$rc" -eq 0 ] && ok "$lbl: apply reaches $t" || bad "$lbl: apply exit $rc: $out"
    ( cd "$d" && ts verify --target "$t" "${OWNFLAG[@]}" ) >/dev/null 2>&1 && ok "$lbl: verify passes" || bad "$lbl: verify fails after apply"
    plan="$( cd "$d" && ts plan --target "$t" "${OWNFLAG[@]}" )"
    case "$plan" in *"nothing to do"*) ok "$lbl: second plan proposes nothing" ;; *) bad "$lbl: second plan proposed: $plan" ;; esac
    end_state_facts "$d" "$t" "$o" "$lbl"
}

# --- the repros ---------------------------------------------------------------
# run_repros <tag> — the named regressions, against whatever $TS is.
run_repros() {
    local d="$WORK/repro-$1" st g2 id
    # round 2: local -> committed -> local -> committed
    mkrepo "$d" local-exact untracked none 0
    ( cd "$d" && ts apply --target committed >/dev/null 2>&1 && ts apply --target local >/dev/null 2>&1 )
    end_state_facts "$d" local none "round-2 chain, back at local"
    ( cd "$d" && ts apply --target committed >/dev/null 2>&1 )
    end_state_facts "$d" committed none "round-2 chain, committed again"
    # round 3, failure 1: setup-config adds settings.json; the guard is rendered LATER
    mkrepo "$d" local-exact untracked none 0
    ( cd "$d" && ts apply --target committed >/dev/null 2>&1 )
    printf '#!/bin/sh\n' > "$d/$G"
    st="$( cd "$d" && ts derive | jq -r .state )"
    [ "$st" = mixed ] && ok "round-3 #1: a script rendered after the settings.json add derives mixed" || bad "round-3 #1: late script derived '$st', want mixed"
    ( cd "$d" && ts apply --target committed >/dev/null 2>&1 )
    ( cd "$d" && ts verify --target committed >/dev/null 2>&1 ) && ok "round-3 #1: the next run adds the guard and verify passes" || bad "round-3 #1: verify still fails after the next run"
    # ... and via --owned before the file exists, so setup-hooks adds what it renders
    mkrepo "$d" local-exact untracked none 0
    st="$( cd "$d" && ts derive --owned "$G" | jq -r .state )"
    [ "$st" = local ] && ok "round-3 #1: --owned of an absent script keeps local derive local" || bad "round-3 #1: --owned derive gave '$st'"
    st="$( cd "$d" && ts plan --target committed --owned "$G" )"
    case "$st" in *"git-add: $G"*) ok "round-3 #1: plan names the not-yet-rendered guard" ;; *) bad "round-3 #1: plan omitted the --owned guard: $st" ;; esac
    # round 3, failure 2: local lines, settings untracked, owned script STILL tracked
    mkrepo "$d" local-exact untracked tracked 0
    st="$( cd "$d" && ts derive | jq -r .state )"
    [ "$st" = mixed ] && ok "round-3 #2: a tracked owned script under local lines derives mixed" || bad "round-3 #2: derived '$st', want mixed"
    ( cd "$d" && ts apply --target local >/dev/null 2>&1 )
    end_state_facts "$d" local tracked "round-3 #2, after apply"
    # round 3, failure 3: committed lines without !.claude/sassy-dog/
    mkrepo "$d" committed-no-sassy tracked none 0
    st="$( cd "$d" && ts derive | jq -r .state )"
    [ "$st" = mixed ] && ok "round-3 #3: committed lines without the sassy-dog negation derive mixed" || bad "round-3 #3: derived '$st', want mixed"
    ( cd "$d" && ts apply --target committed >/dev/null 2>&1 )
    end_state_facts "$d" committed none "round-3 #3, after apply"
    # apply must refuse a plan the repo has moved past
    mkrepo "$d" local-exact untracked none 0
    id="$( cd "$d" && ts plan --target committed | sed -n 's/^plan-id: //p' )"
    printf '#!/bin/sh\n' > "$d/$G"
    ( cd "$d" && ts apply --target committed --plan-id "$id" >/dev/null 2>&1 ); g2=$?
    [ "$g2" -eq 3 ] && ok "plan-id: apply refuses (exit 3) once the repo moved past the previewed plan" || bad "plan-id: apply exit $g2, want 3"
}

# --- 1. the enumerated rows ----------------------------------------------------
echo "tracking-state rows"
rows=0
for v in $VARIANTS; do
    exact=0; case "$v" in local-exact|committed-exact) exact=1 ;; esac
    for s in tracked untracked; do
        for o in none tracked untracked flag; do
            # Every variant crosses settings x {none, tracked}; the two exact
            # variants (the only ones that can be AT a target) cross the full
            # owned set and the non-owned hook, where each adds a distinct case.
            if [ "$exact" -eq 0 ] && [ "$o" != none ] && [ "$o" != tracked ]; then continue; fi
            for n in 0 1; do
                if [ "$n" = 1 ] && { [ "$exact" -eq 0 ] || { [ "$o" != none ] && [ "$o" != untracked ]; }; }; then continue; fi
                for t in local committed; do
                    rows=$((rows + 1))
                    run_row "[$v/$s/$o/n$n -> $t]" "$WORK/row" "$v" "$s" "$o" "$n" "$t"
                done
            done
        done
    done
done
echo "  ($rows rows)"

# --- 2. the named repros --------------------------------------------------------
echo "named repros"
run_repros real

# --- 3. a tracked non-owned hook is reported, never untracked or re-added -------
mkrepo "$WORK/nonowned" local-exact untracked none 0
( cd "$WORK/nonowned" && git add -f "$NONOWNED" 2>/dev/null; printf '#!/bin/sh\n' > "$NONOWNED"; git add -f "$NONOWNED" ) >/dev/null 2>&1
plan="$( cd "$WORK/nonowned" && ts plan --target committed )"
case "$plan" in *"non-owned: $NONOWNED (tracked; stays tracked"*) ok "a tracked non-owned hook is listed separately and left tracked" ;; *) bad "tracked non-owned hook not reported: $plan" ;; esac
case "$plan" in *"git-add: $NONOWNED"*|*"git-rm-cached: $NONOWNED"*) bad "a non-owned hook was planned for add/rm" ;; *) ok "no add/rm is planned for a non-owned hook" ;; esac

# --- 4. each mutant must turn a repro red ----------------------------------------
echo "mutants (each must be caught by a repro)"
mutate() { # <name> <awk-or-sed program via function body>
    local name="$1" out="$WORK/mut-$1.sh"
    case "$name" in
        dropowned) awk 'index($0, "for p in \"$SETTINGS\" $OWNED; do") && !d { sub(/ \$OWNED/, ""); d = 1 } { print }' "$SCRIPT" > "$out" ;;
        dropsassy) sed -e 's/\[ -z "\$sl" \]/false/' -e 's/! ignored "\$PROBE_CONFIG" ||/true ||/' "$SCRIPT" > "$out" ;;
        droporder) sed -e 's/\[ "\$nsl" -gt "\$wl" \]/true/' -e 's/\[ "\$nhl" -gt "\$wl" \]/true/' -e 's/\[ "\$hwl" -gt "\$nhl" \]/true/' -e 's/\[ "\$hnl" -gt "\$hwl" \]/true/' "$SCRIPT" > "$out" ;;
    esac
    printf '%s' "$out"
}
for m in dropowned dropsassy droporder; do
    mut="$(mutate "$m")"
    if cmp -s "$mut" "$SCRIPT"; then bad "mutant $m changed nothing (the mutation did not apply)"; continue; fi
    TS="$mut"; before="$FAIL"; pbefore="$PASS"; QUIET=1
    run_repros "$m"
    if [ "$m" = droporder ]; then
        run_row "mut" "$WORK/mutrow" committed-NS-first tracked none 0 committed
    fi
    QUIET=0; after="$FAIL"; TS="$SCRIPT"
    if [ "$after" -gt "$before" ]; then
        FAIL="$before"; PASS="$pbefore"; ok "mutant $m is caught ($((after - before)) assertion(s) went red)"
    else
        bad "mutant $m SURVIVED — no repro noticed it"
    fi
done

echo "tracking-state: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "tracking-state tests: all green" >&2; exit 0; }
echo "tracking-state tests: FAILURES above" >&2
exit 1
