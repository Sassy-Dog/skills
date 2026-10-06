#!/usr/bin/env bash
# tracking-state.sh — derive, plan, apply and verify the public-repo tracking
# end state of `.claude/settings.json` and the owned hook scripts (issue #475).
# AUTHORITATIVE for the rules: setup-config's "Tracking choice in the plan"
# documents the two end states and calls this script; setup-hooks calls it too.
# Pure bash plus git, no network, no visibility input — the caller decides the
# target (visibility is read once, in setup-config Phase 0, and never here).
#
# Run from the target repo (it cd's to the work tree root).
#
#   derive [--owned PATH ...]
#       JSON {"state":"local|committed|mixed","mismatches":[...],"owned":[...],
#       "non_owned_hooks":[...]}; exit 0. A mixed state names what disagrees
#       with the NEARER end state (ties go to local).
#   plan   --target local|committed [--owned PATH ...]
#       Prints, writing nothing: the .gitignore edits, the exact git add / git rm
#       --cached paths, warnings, and a `plan-id`. Prints `nothing to do` when
#       the derived state already equals the target.
#   apply  --target ... [--owned ...] [--plan-id ID]
#       Performs exactly the plan. Re-derives immediately before acting and
#       refuses (exit 3) when the state is not the one the plan was made for.
#   verify --target ... [--owned ...]
#       Exit 0 iff the derived state equals the target; otherwise exit 1 and the
#       target's mismatches on stdout.
#
# END STATES (every negation must come after the pattern it re-includes):
#   local      .claude/*, !.claude/sassy-dog/ — and none of the committed-only
#              lines. settings.json and every owned script are untracked AND
#              ignored; a .claude/sassy-dog/<probe>.md is NOT ignored.
#   committed  .claude/*, !.claude/sassy-dog/, !.claude/settings.json,
#              !.claude/hooks/, .claude/hooks/*, !.claude/hooks/sassydog-*.sh.
#              settings.json and every owned script are tracked AND not
#              ignored; settings.local.json, worktrees/ and any non-owned hook
#              stay ignored, so `git add -A` can never stage them.
#   anything else is mixed (a missing or misordered line, a bare `.claude/`, an
#   owned script whose status disagrees with settings.json, no sassy-dog
#   negation, ...).
#
# OWNED = every .claude/hooks/sassydog-*.sh in the tree or the index, plus any
# --owned PATH the caller is about to render. A caller that renders a script
# after setup-config ran passes it here, so the derive sees it BEFORE it exists.
#
# DESTRUCTIVE SHAPE (CLAUDE.md: one call site, fresh verification in the same
# body, as align-labels.sh's migrate_delete_gate): the .gitignore rewrite, the
# `git rm --cached` and the `git add` each have exactly ONE call site, all inside
# mutate(), whose body re-derives and compares the plan id before the first
# mutation. Paths are acted on individually, never as a directory.
#
# Pipelines into `grep -q` are avoided entirely (scripts/test-pipefail-grep.sh):
# every probe is captured into a variable or uses git's own exit status.
set -o pipefail

usage() { echo "usage: tracking-state.sh derive|plan|apply|verify [--target local|committed] [--owned PATH ...] [--plan-id ID]" >&2; exit 64; }

W='.claude/*'
S='!.claude/sassy-dog/'
NS='!.claude/settings.json'
NH='!.claude/hooks/'
HW='.claude/hooks/*'
HN='!.claude/hooks/sassydog-*.sh'
SETTINGS='.claude/settings.json'
PROBE_CONFIG='.claude/sassy-dog/zz-probe.md'
PROBE_NONOWNED='.claude/hooks/zz-non-owned-probe.sh'
PROBES_IGNORED='.claude/settings.local.json .claude/worktrees/zz-probe/f'
GI='.gitignore'

top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "tracking-state.sh: not inside a git work tree" >&2; exit 64; }
cd "$top" || exit 64

CMD="${1:-}"; [ -n "$CMD" ] || usage
shift
TARGET=""; EXTRA=""; EXPECT_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 || usage ;;
        --owned)
            [ -n "${2:-}" ] || usage
            case "$2" in
                .claude/hooks/sassydog-*.sh) ;;
                *) echo "tracking-state.sh: --owned must be .claude/hooks/sassydog-*.sh, got '$2'" >&2; exit 64 ;;
            esac
            EXTRA+="$2"$'\n'; shift 2 ;;
        --plan-id) EXPECT_ID="${2:-}"; shift 2 || usage ;;
        *) usage ;;
    esac
done
case "$CMD" in derive) ;; plan|apply|verify) case "$TARGET" in local|committed) ;; *) usage ;; esac ;; *) usage ;; esac

# --- probes ------------------------------------------------------------------
# One `git ls-files` and one `git check-ignore --stdin` per derive, captured into
# variables (prime), so each probe is a membership test, not a process.
TRK=""; IGN=""
tracked() { in_list "$1" "$TRK"; }
ignored() { in_list "$1" "$IGN"; }
prime() {
    local p paths=""
    TRK="$(git ls-files -- .claude)"
    for p in "$SETTINGS" "$PROBE_CONFIG" "$PROBE_NONOWNED" $PROBES_IGNORED $OWNED $NONOWNED; do paths+="$p"$'\n'; done
    # $paths ends in a newline already; a here-string would add an empty last
    # line, which check-ignore rejects as an empty pathspec.
    IGN="$(printf '%s' "$paths" | git check-ignore --no-index --stdin 2>/dev/null)"
}

# last_of <exact line> — the LAST line number holding exactly that text (the
# one that wins in gitignore), empty when absent.
last_of() {
    local n=0 hit="" l
    [ -r "$GI" ] || return 0
    while IFS= read -r l || [ -n "$l" ]; do
        n=$((n + 1))
        [ "$l" = "$1" ] && hit="$n"
    done < "$GI"
    printf '%s' "$hit"
}

in_list() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

# --- derive ------------------------------------------------------------------
OWNED=""; NONOWNED=""; STATE=""; MM=""
collect() {
    local idx disk p
    OWNED=""; NONOWNED=""
    idx="$(git ls-files -- .claude/hooks)"
    disk="$(find .claude/hooks -type f 2>/dev/null)"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
            .claude/hooks/sassydog-*.sh) in_list "$p" "$OWNED" || OWNED+="$p"$'\n' ;;
            *) in_list "$p" "$NONOWNED" || NONOWNED+="$p"$'\n' ;;
        esac
    done <<<"$idx"$'\n'"$disk"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        in_list "$p" "$OWNED" || OWNED+="$p"$'\n'
    done <<<"$EXTRA"
    OWNED="$(printf '%s' "$OWNED" | sort)"
    NONOWNED="$(printf '%s' "$NONOWNED" | sort)"
    prime
}

# mm_for <local|committed> — mismatches against that end state, one per line.
mm_for() {
    local t="$1" out="" x p wl sl nsl nhl hwl hnl
    wl="$(last_of "$W")"; sl="$(last_of "$S")"; nsl="$(last_of "$NS")"
    nhl="$(last_of "$NH")"; hwl="$(last_of "$HW")"; hnl="$(last_of "$HN")"
    [ -n "$wl" ] || out+="$GI lacks '$W'"$'\n'
    if [ -z "$sl" ]; then out+="$GI lacks '$S' (new config would be ignored)"$'\n'
    elif [ -n "$wl" ] && [ "$sl" -le "$wl" ]; then out+="'$S' does not come after '$W'"$'\n'; fi
    for x in '.claude/' '.claude'; do
        [ -z "$(last_of "$x")" ] || out+="bare '$x' line in $GI defeats the re-include"$'\n'
    done
    if [ "$t" = local ]; then
        for x in "$NS" "$NH" "$HW" "$HN"; do
            [ -z "$(last_of "$x")" ] || out+="committed-only line '$x' is present"$'\n'
        done
    else
        [ -n "$nsl" ] || out+="$GI lacks '$NS'"$'\n'
        [ -n "$nhl" ] || out+="$GI lacks '$NH'"$'\n'
        [ -n "$hwl" ] || out+="$GI lacks '$HW'"$'\n'
        [ -n "$hnl" ] || out+="$GI lacks '$HN'"$'\n'
        [ -z "$nsl" ] || [ -z "$wl" ] || [ "$nsl" -gt "$wl" ] || out+="'$NS' does not come after '$W'"$'\n'
        [ -z "$nhl" ] || [ -z "$wl" ] || [ "$nhl" -gt "$wl" ] || out+="'$NH' does not come after '$W'"$'\n'
        [ -z "$hwl" ] || [ -z "$nhl" ] || [ "$hwl" -gt "$nhl" ] || out+="'$HW' does not come after '$NH'"$'\n'
        [ -z "$hnl" ] || [ -z "$hwl" ] || [ "$hnl" -gt "$hwl" ] || out+="'$HN' does not come after '$HW'"$'\n'
    fi
    for p in "$SETTINGS" $OWNED; do
        if [ "$t" = local ]; then
            ! tracked "$p" || out+="$p is tracked"$'\n'
            ignored "$p" || out+="$p is not ignored"$'\n'
        else
            tracked "$p" || out+="$p is untracked"$'\n'
            ! ignored "$p" || out+="$p is ignored"$'\n'
        fi
    done
    ! ignored "$PROBE_CONFIG" || out+="$PROBE_CONFIG would be ignored (new config not committable)"$'\n'
    for p in $PROBES_IGNORED "$PROBE_NONOWNED" $NONOWNED; do
        ignored "$p" || out+="$p is not ignored"$'\n'
    done
    printf '%s' "$out"
}

derive() {
    local lm cm ln cn
    collect
    lm="$(mm_for local)"; cm="$(mm_for committed)"
    if [ -z "$lm" ]; then STATE=local; MM=""
    elif [ -z "$cm" ]; then STATE=committed; MM=""
    else
        STATE=mixed
        ln="$(printf '%s\n' "$lm" | wc -l)"; cn="$(printf '%s\n' "$cm" | wc -l)"
        if [ "$cn" -lt "$ln" ]; then MM="$cm"; else MM="$lm"; fi
    fi
}

jstr() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
jarr() {
    local first=1 x
    printf '['
    while IFS= read -r x; do
        [ -n "$x" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0; jstr "$x"
    done <<<"$1"
    printf ']'
}

# --- plan --------------------------------------------------------------------
PLAN=""; PLAN_ID=""; GI_REMOVE_N=""; GI_APPEND=""; ADD=""; RMC=""; NOTHING=0
managed() { case "$1" in "$W"|"$S"|"$NS"|"$NH"|"$HW"|"$HN"|'.claude/'|'.claude') return 0 ;; esac; return 1; }

build_plan() {
    local t="$1" want l n p gi_ok=1 x m
    derive
    PLAN=""; GI_REMOVE_N=""; GI_APPEND=""; ADD=""; RMC=""; NOTHING=0
    if [ "$STATE" = "$t" ]; then NOTHING=1; PLAN="state: $STATE  target: $t"$'\n'"nothing to do"$'\n'; PLAN_ID="$(printf '%s' "$PLAN" | cksum | cut -d' ' -f1)"; return 0; fi
    PLAN="state: $STATE  target: $t"$'\n'
    while IFS= read -r x; do [ -n "$x" ] && PLAN+="mismatch: $x"$'\n'; done <<<"$(mm_for "$t")"
    if [ "$t" = local ]; then want="$W"$'\n'"$S"; else want="$W"$'\n'"$S"$'\n'"$NS"$'\n'"$NH"$'\n'"$HW"$'\n'"$HN"; fi
    # .gitignore edit needed? Only when a wanted line is missing/misordered, an
    # unwanted managed line is present, or a bare `.claude/` line exists.
    m="$(mm_for "$t")"
    case "$m" in *"$GI lacks"*|*"does not come after"*|*"committed-only line"*|*"bare '"*|*"would be ignored"*) gi_ok=0 ;; esac
    if [ "$gi_ok" -eq 0 ]; then
        # Keep each wanted line that already sits after the previous kept one;
        # from the first that does not, re-append it and every later wanted line
        # at the end, so the result is in end-state order. Unwanted managed
        # lines (committed-only lines for a local target, a bare `.claude/`) go.
        local cursor=0 broke=0 lw
        while IFS= read -r l; do
            lw="$(last_of "$l")"
            if [ "$broke" -eq 0 ] && [ -n "$lw" ] && [ "$lw" -gt "$cursor" ]; then cursor="$lw"
            else broke=1; GI_APPEND+="$l"$'\n'; fi
        done <<<"$want"
        n=0
        if [ -r "$GI" ]; then
            while IFS= read -r l || [ -n "$l" ]; do
                n=$((n + 1))
                managed "$l" || continue
                if ! in_list "$l" "$want" || in_list "$l" "$GI_APPEND"; then
                    GI_REMOVE_N+="$n"$'\n'; PLAN+="gitignore-remove line $n: $l"$'\n'
                fi
            done < "$GI"
        fi
        while IFS= read -r l; do
            [ -z "$l" ] || PLAN+="gitignore-append (end of $GI, in this order): $l"$'\n'
        done <<<"$GI_APPEND"
    fi
    for p in "$SETTINGS" $OWNED; do
        if [ "$t" = local ]; then
            if tracked "$p"; then RMC+="$p"$'\n'; PLAN+="git-rm-cached: $p"$'\n'; fi
        else
            if ! tracked "$p"; then
                ADD+="$p"$'\n'
                # Identical whether or not the file exists yet, so a plan previewed
                # before a generator renders it keeps its plan-id after it does.
                PLAN+="git-add: $p"$'\n'
            fi
        fi
    done
    if [ -n "$RMC" ]; then
        PLAN+="warn: after the untracking commit lands, every collaborator who pulls has these files DELETED from their working tree (their plugin declaration and any hand-added PreToolUse push guard go with .claude/settings.json)"$'\n'
        PLAN+="warn: if .claude/settings.json holds keys beyond extraKnownMarketplaces, enabledPlugins and hook entries whose command contains .claude/hooks/sassydog-, those shared team settings stop being shared"$'\n'
        PLAN+="restore (run right after pulling): git restore --source=<untrack-commit>^ --worktree -- $(printf '%s' "$RMC" | tr '\n' ' ')"$'\n'
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if tracked "$p"; then PLAN+="non-owned: $p (tracked; stays tracked, never auto-untracked)"$'\n'
        elif [ "$t" = committed ]; then PLAN+="non-owned: $p (stays ignored; never auto-added)"$'\n'
        else PLAN+="non-owned: $p (untouched)"$'\n'; fi
    done <<<"$NONOWNED"
    PLAN_ID="$(printf '%s' "$PLAN" | cksum | cut -d' ' -f1)"
}

# mutate <target> — the ONLY place anything is written. Re-derives first.
mutate() {
    local t="$1" before="$PLAN_ID" l p new n
    build_plan "$t"
    if [ "$PLAN_ID" != "$before" ]; then
        echo "tracking-state.sh: refusing to apply: the repo state changed since the plan was made (plan-id $before -> $PLAN_ID); re-run plan" >&2
        return 3
    fi
    for p in $ADD; do
        [ -e "$p" ] || { echo "tracking-state.sh: refusing to apply: $p does not exist yet; write or render it first" >&2; return 4; }
    done
    if [ -n "$GI_APPEND" ] || [ -n "$GI_REMOVE_N" ]; then
        new=""; n=0
        if [ -r "$GI" ]; then
            while IFS= read -r l || [ -n "$l" ]; do
                n=$((n + 1))
                in_list "$n" "$GI_REMOVE_N" || new+="$l"$'\n'
            done < "$GI"
        fi
        new+="$GI_APPEND"
        printf '%s' "$new" > "$GI"
    fi
    for p in $RMC; do git rm --cached -q -- "$p" || return 5; done
    for p in $ADD; do git add -- "$p" || return 5; done
    return 0
}

case "$CMD" in
    derive)
        derive
        printf '{"state":"%s","mismatches":%s,"owned":%s,"non_owned_hooks":%s}\n' \
            "$STATE" "$(jarr "$MM")" "$(jarr "$OWNED")" "$(jarr "$NONOWNED")"
        exit 0 ;;
    plan)
        build_plan "$TARGET"
        printf '%s' "$PLAN"
        [ "$NOTHING" -eq 1 ] || echo "plan-id: $PLAN_ID"
        exit 0 ;;
    apply)
        build_plan "$TARGET"
        if [ "$NOTHING" -eq 1 ]; then echo "nothing to do"; exit 0; fi
        if [ -n "$EXPECT_ID" ] && [ "$EXPECT_ID" != "$PLAN_ID" ]; then
            echo "tracking-state.sh: refusing to apply: plan-id $EXPECT_ID was previewed but the repo now plans $PLAN_ID; re-run plan" >&2
            exit 3
        fi
        mutate "$TARGET" || exit $?
        derive
        if [ "$STATE" = "$TARGET" ]; then echo "applied: state is now $STATE"; exit 0; fi
        echo "applied, but the state is $STATE, not $TARGET:" >&2
        mm_for "$TARGET" >&2
        exit 1 ;;
    verify)
        collect
        m="$(mm_for "$TARGET")"
        if [ -z "$m" ]; then echo "ok: $TARGET"; exit 0; fi
        printf '%s' "$m"
        exit 1 ;;
esac
