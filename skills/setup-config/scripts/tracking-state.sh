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
#   apply  --target ... [--owned ...] --plan-id ID
#       Performs exactly the previewed plan. --plan-id is REQUIRED. It re-derives
#       immediately before acting and refuses (exit 3) when the repo no longer
#       plans that id, (exit 4) when a path it must `git add` does not exist as
#       a regular file, (exit 6) when .gitignore is a symlink or not a regular
#       file, (exit 7) when any owned-name entry is unsafe, nested, a directory
#       or a symlink. Both 6 and 7 refuse BEFORE the first write, and `plan`
#       prints `blocked: <each problem>` instead of actions; the way out is for
#       a human to rename or remove the entry (this script never deletes or
#       renames a user file). It never writes through a symlink.
#   verify --target ... [--owned ...]
#       Exit 0 iff the derived state equals the target; otherwise exit 1 and the
#       target's mismatches on stdout.
#   Exit 2 on every subcommand: a git probe FAILED ("unknown, not verified");
#   it never reads as ok. Exit 64: usage.
#
# END STATES (every negation must come after the pattern it re-includes):
#   local      .claude/*, !.claude/sassy-dog/ — and none of the committed-only
#              lines. settings.json and every owned script are untracked AND
#              ignored; a .claude/sassy-dog/<probe>.md is NOT ignored.
#   committed  .claude/*, !.claude/sassy-dog/, !.claude/settings.json,
#              !.claude/hooks/, .claude/hooks/*, !.claude/hooks/sassydog-*.sh,
#              .claude/hooks/sassydog-*.sh/ . settings.json and every owned
#              script are tracked AND not ignored; settings.local.json,
#              worktrees/, any non-owned hook and any directory NAMED like an
#              owned script stay ignored, so `git add -A` does not stage them.
#              That holds for a directory and for a name this script reached
#              through its own apply; it does NOT hold for an unsafe-named or
#              symlinked `sassydog-*.sh` entry in a repo that is ALREADY
#              committed: `!.claude/hooks/sassydog-*.sh` re-includes any such
#              name, so it is reported as mixed but `git add -A` can stage it.
#              `apply` refuses (exit 7) while one exists.
#   anything else is mixed (a missing or misordered line, a bare `.claude/`, an
#   owned script whose status disagrees with settings.json, no sassy-dog
#   negation, a symlinked .gitignore, an unsafe or nested hook path, ...).
#
# OWNED = every DIRECT-CHILD REGULAR FILE .claude/hooks/sassydog-<name>.sh, with
# <name> limited to [A-Za-z0-9._-], in the tree or the index, plus any --owned
# PATH the caller is about to render. `*` never spans `/`: a path nested under an
# owned-name entry (.claude/hooks/sassydog-d.sh/evil) is a mismatch, as is an
# owned-name directory or symlink, and an owned-name path with whitespace, a glob
# character, a quote, a backslash, `$` or a backtick is an "unsafe owned name":
# reported, never acted on, never printed as a runnable command, and `apply`
# refuses (exit 7) before its first write while one exists. A caller that
# renders a script after setup-config ran passes it here, so the derive sees it
# BEFORE it exists. setup-config itself passes none: it renders no script, and
# `apply` refuses (exit 4) a path that does not exist yet.
#
# DESTRUCTIVE SHAPE (CLAUDE.md: one call site, fresh verification in the same
# body, as align-labels.sh's migrate_delete_gate): the .gitignore rewrite, the
# `git rm --cached` and the `git add` each have exactly ONE call site, all inside
# mutate(), whose body re-derives and compares the plan id before the first
# mutation. Paths are acted on individually, never as a directory. The rewrite
# goes through a temp file in the same directory and `mv -f`, preserves every
# unrelated line and its order, and keeps the file's own line-ending convention.
#
# Pipelines into `grep -q` are avoided entirely (scripts/test-pipefail-grep.sh):
# every probe is captured into a variable or uses git's own exit status.
set -o pipefail
export LC_ALL=C

usage() { echo "usage: tracking-state.sh derive|plan|apply|verify [--target local|committed] [--owned PATH ...] [--plan-id ID (required for apply)]" >&2; exit 64; }

W='.claude/*'
S='!.claude/sassy-dog/'
NS='!.claude/settings.json'
NH='!.claude/hooks/'
HW='.claude/hooks/*'
HN='!.claude/hooks/sassydog-*.sh'
HD='.claude/hooks/sassydog-*.sh/'
SETTINGS='.claude/settings.json'
PROBE_CONFIG='.claude/sassy-dog/zz-probe.md'
PROBE_NONOWNED='.claude/hooks/zz-non-owned-probe.sh'
PROBE_OWNEDDIR='.claude/hooks/sassydog-zz-probe.sh/f'
PROBES_IGNORED='.claude/settings.local.json .claude/worktrees/zz-probe/f'
GI='.gitignore'

# safe_path: only [A-Za-z0-9._/-] — nothing a shell, a glob or a line split can read.
safe_path() { case "$1" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac; return 0; }
# safe_owned: a direct-child .claude/hooks/sassydog-<safe>.sh.
safe_owned() {
    local n
    case "$1" in .claude/hooks/sassydog-*.sh) ;; *) return 1 ;; esac
    n="${1#.claude/hooks/}"
    case "$n" in */*) return 1 ;; esac
    safe_path "$n"
}
in_list() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

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
            safe_owned "$2" || { echo "tracking-state.sh: --owned must be a safe .claude/hooks/sassydog-<name>.sh ([A-Za-z0-9._-] only), refusing '$2'" >&2; exit 64; }
            EXTRA+="$2"$'\n'; shift 2 ;;
        --plan-id) EXPECT_ID="${2:-}"; shift 2 || usage ;;
        *) usage ;;
    esac
done
case "$CMD" in derive) ;; plan|apply|verify) case "$TARGET" in local|committed) ;; *) usage ;; esac ;; *) usage ;; esac
[ "$CMD" != apply ] || [ -n "$EXPECT_ID" ] || usage

TMPD="$(mktemp -d)" || exit 64
trap 'rm -rf "$TMPD"' EXIT

# --- gather ------------------------------------------------------------------
TRK=""; IGN=""; FAILED=""; OWNED=""; NONOWNED=""; PROBLEMS=""
tracked() { in_list "$1" "$TRK"; }
ignored() { in_list "$1" "$IGN"; }

# note_hook <path> <regular|dir|symlink> — classify one path found under
# .claude/hooks (index or disk).
note_hook() {
    local p="$1" kind="$2" rel first q
    rel="${p#.claude/hooks/}"; first="${rel%%/*}"
    case "$first" in
        sassydog-*.sh)
            q="$(printf '%q' "$p")"
            if ! safe_path "$p"; then
                in_list "unsafe owned name: $q" "$PROBLEMS" || PROBLEMS+="unsafe owned name: $q"$'\n'
            elif [ "$rel" != "$first" ]; then
                in_list "nested path under an owned-name entry: $p" "$PROBLEMS" || PROBLEMS+="nested path under an owned-name entry: $p"$'\n'
            elif [ "$kind" != regular ]; then
                in_list "$p is not a regular file ($kind)" "$PROBLEMS" || PROBLEMS+="$p is not a regular file ($kind)"$'\n'
            else
                in_list "$p" "$OWNED" || OWNED+="$p"$'\n'
            fi ;;
        *)
            [ "$kind" = regular ] && safe_path "$p" && { in_list "$p" "$NONOWNED" || NONOWNED+="$p"$'\n'; } ;;
    esac
    return 0
}

collect() {
    local rec mode p kind rc paths x
    OWNED=""; NONOWNED=""; PROBLEMS=""; TRK=""; IGN=""; FAILED=""
    git ls-files -s -z -- .claude > "$TMPD/ls" 2>"$TMPD/ls.err" || FAILED+="git ls-files failed: $(tr '\n' ' ' < "$TMPD/ls.err"); "
    while IFS= read -r -d '' rec; do
        mode="${rec%% *}"; p="${rec#*$'\t'}"
        safe_path "$p" && TRK+="$p"$'\n'
        case "$p" in .claude/hooks/*)
            kind=regular; [ "$mode" = 120000 ] && kind=symlink; [ "$mode" = 160000 ] && kind=dir
            note_hook "$p" "$kind" ;;
        esac
    done < "$TMPD/ls"
    if [ -d .claude/hooks ]; then
        find .claude/hooks -mindepth 1 -print0 > "$TMPD/find" 2>/dev/null
        while IFS= read -r -d '' p; do
            if [ -L "$p" ]; then kind=symlink; elif [ -d "$p" ]; then kind=dir; else kind=regular; fi
            case "$kind" in
                dir) case "${p#.claude/hooks/}" in sassydog-*.sh|sassydog-*.sh/*) note_hook "$p" dir ;; esac ;;
                *) note_hook "$p" "$kind" ;;
            esac
        done < "$TMPD/find"
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        in_list "$p" "$OWNED" || OWNED+="$p"$'\n'
    done <<<"$EXTRA"
    OWNED="$(printf '%s' "$OWNED" | sort)"
    NONOWNED="$(printf '%s' "$NONOWNED" | sort)"
    paths=""
    for x in "$SETTINGS" "$PROBE_CONFIG" "$PROBE_NONOWNED" "$PROBE_OWNEDDIR" $PROBES_IGNORED; do paths+="$x"$'\n'; done
    while IFS= read -r p; do [ -z "$p" ] || paths+="$p"$'\n'; done <<<"$OWNED"$'\n'"$NONOWNED"
    # $paths ends in a newline already; a here-string would add an empty last
    # line, which check-ignore rejects as an empty pathspec. Exit 0/1 = answered
    # (some / none ignored); anything else is a failed probe, never "not ignored".
    IGN="$(printf '%s' "$paths" | git check-ignore --no-index --stdin 2>/dev/null)"; rc=$?
    [ "$rc" -le 1 ] || FAILED+="git check-ignore failed (exit $rc); "
    if [ -n "$FAILED" ]; then
        echo "tracking-state.sh: unknown, not verified: $FAILED" >&2
        exit 2
    fi
}

# scan_gi — one pass over .gitignore: the LAST line number of every managed line
# (the one that wins), and whether the file uses CRLF. A symlink or a non-regular
# file is never read.
L_W=""; L_S=""; L_NS=""; L_NH=""; L_HW=""; L_HN=""; L_HD=""; L_B1=""; L_B2=""
GI_BAD=""; GI_CRLF=0
scan_gi() {
    local n=0 l t
    L_W=""; L_S=""; L_NS=""; L_NH=""; L_HW=""; L_HN=""; L_HD=""; L_B1=""; L_B2=""; GI_BAD=""; GI_CRLF=0
    if [ -L "$GI" ]; then GI_BAD="$GI is a symlink; it is never read or written through"; return 0; fi
    if [ -e "$GI" ] && [ ! -f "$GI" ]; then GI_BAD="$GI is not a regular file"; return 0; fi
    [ -f "$GI" ] || return 0
    while IFS= read -r l || [ -n "$l" ]; do
        n=$((n + 1))
        case "$l" in *$'\r') GI_CRLF=1; t="${l%$'\r'}" ;; *) t="$l" ;; esac
        case "$t" in
            "$W") L_W="$n" ;; "$S") L_S="$n" ;; "$NS") L_NS="$n" ;; "$NH") L_NH="$n" ;;
            "$HW") L_HW="$n" ;; "$HN") L_HN="$n" ;; "$HD") L_HD="$n" ;;
            '.claude/') L_B1="$n" ;; '.claude') L_B2="$n" ;;
        esac
    done < "$GI"
}
# ln_of <exact managed line> — sets LN to its last line number (no subshell).
LN=""
ln_of() {
    case "$1" in
        "$W") LN="$L_W" ;; "$S") LN="$L_S" ;; "$NS") LN="$L_NS" ;; "$NH") LN="$L_NH" ;;
        "$HW") LN="$L_HW" ;; "$HN") LN="$L_HN" ;; "$HD") LN="$L_HD" ;; *) LN="" ;;
    esac
}

# mm_for <local|committed> — mismatches against that end state, one per line.
mm_for() {
    local t="$1" out="" p
    [ -z "$GI_BAD" ] || out+="$GI_BAD"$'\n'
    out+="$PROBLEMS"
    [ -n "$L_W" ] || out+="$GI lacks '$W'"$'\n'
    if [ -z "$L_S" ]; then out+="$GI lacks '$S' (new config would be ignored)"$'\n'
    elif [ -n "$L_W" ] && [ "$L_S" -le "$L_W" ]; then out+="'$S' does not come after '$W'"$'\n'; fi
    [ -z "$L_B1" ] || out+="bare '.claude/' line in $GI defeats the re-include"$'\n'
    [ -z "$L_B2" ] || out+="bare '.claude' line in $GI defeats the re-include"$'\n'
    if [ "$t" = local ]; then
        [ -z "$L_NS" ] || out+="committed-only line '$NS' is present"$'\n'
        [ -z "$L_NH" ] || out+="committed-only line '$NH' is present"$'\n'
        [ -z "$L_HW" ] || out+="committed-only line '$HW' is present"$'\n'
        [ -z "$L_HN" ] || out+="committed-only line '$HN' is present"$'\n'
        [ -z "$L_HD" ] || out+="committed-only line '$HD' is present"$'\n'
    else
        [ -n "$L_NS" ] || out+="$GI lacks '$NS'"$'\n'
        [ -n "$L_NH" ] || out+="$GI lacks '$NH'"$'\n'
        [ -n "$L_HW" ] || out+="$GI lacks '$HW'"$'\n'
        [ -n "$L_HN" ] || out+="$GI lacks '$HN'"$'\n'
        [ -n "$L_HD" ] || out+="$GI lacks '$HD'"$'\n'
        [ -z "$L_NS" ] || [ -z "$L_W" ] || [ "$L_NS" -gt "$L_W" ] || out+="'$NS' does not come after '$W'"$'\n'
        [ -z "$L_NH" ] || [ -z "$L_W" ] || [ "$L_NH" -gt "$L_W" ] || out+="'$NH' does not come after '$W'"$'\n'
        [ -z "$L_HW" ] || [ -z "$L_NH" ] || [ "$L_HW" -gt "$L_NH" ] || out+="'$HW' does not come after '$NH'"$'\n'
        [ -z "$L_HN" ] || [ -z "$L_HW" ] || [ "$L_HN" -gt "$L_HW" ] || out+="'$HN' does not come after '$HW'"$'\n'
        [ -z "$L_HD" ] || [ -z "$L_HN" ] || [ "$L_HD" -gt "$L_HN" ] || out+="'$HD' does not come after '$HN'"$'\n'
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ "$t" = local ]; then
            ! tracked "$p" || out+="$p is tracked"$'\n'
            ignored "$p" || out+="$p is not ignored"$'\n'
        else
            tracked "$p" || out+="$p is untracked"$'\n'
            ! ignored "$p" || out+="$p is ignored"$'\n'
        fi
    done <<<"$SETTINGS"$'\n'"$OWNED"
    ! ignored "$PROBE_CONFIG" || out+="$PROBE_CONFIG would be ignored (new config not committable)"$'\n'
    ignored "$PROBE_OWNEDDIR" || out+="$PROBE_OWNEDDIR is not ignored (a directory named like an owned script could be staged)"$'\n'
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        ignored "$p" || out+="$p is not ignored"$'\n'
    done <<<"${PROBES_IGNORED// /$'\n'}"$'\n'"$PROBE_NONOWNED"$'\n'"$NONOWNED"
    printf '%s' "$out"
}

STATE=""; MM=""
derive() {
    local lm cm ln cn
    collect; scan_gi
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
managed() { case "$1" in "$W"|"$S"|"$NS"|"$NH"|"$HW"|"$HN"|"$HD"|'.claude/'|'.claude') return 0 ;; esac; return 1; }

build_plan() {
    local t="$1" want l n p gi_ok=1 x m t2 q restore
    derive
    PLAN=""; GI_REMOVE_N=""; GI_APPEND=""; ADD=""; RMC=""; NOTHING=0
    if [ "$STATE" = "$t" ]; then NOTHING=1; PLAN="state: $STATE  target: $t"$'\n'"nothing to do"$'\n'; PLAN_ID="$(printf '%s' "$PLAN" | cksum | cut -d' ' -f1)"; return 0; fi
    PLAN="state: $STATE  target: $t"$'\n'
    m="$(mm_for "$t")"
    while IFS= read -r x; do [ -z "$x" ] || PLAN+="mismatch: $x"$'\n'; done <<<"$m"
    # Blocked: nothing is planned, so there is nothing to half-apply.
    if [ -n "$GI_BAD" ] || [ -n "$PROBLEMS" ]; then
        [ -z "$GI_BAD" ] || PLAN+="blocked: $GI_BAD"$'\n'
        while IFS= read -r x; do [ -z "$x" ] || PLAN+="blocked: $x"$'\n'; done <<<"$PROBLEMS"
        PLAN+="blocked: rename or remove the entry yourself; this script never deletes or renames a file"$'\n'
        PLAN_ID="$(printf '%s' "$PLAN" | cksum | cut -d' ' -f1)"
        return 0
    fi
    if [ "$t" = local ]; then want="$W"$'\n'"$S"; else want="$W"$'\n'"$S"$'\n'"$NS"$'\n'"$NH"$'\n'"$HW"$'\n'"$HN"$'\n'"$HD"; fi
    # .gitignore edit needed? Only when a wanted line is missing/misordered, an
    # unwanted managed line is present, or a bare `.claude/` line exists.
    case "$m" in *"$GI lacks"*|*"does not come after"*|*"committed-only line"*|*"bare '"*|*"would be ignored"*|*"is not ignored (a directory"*) gi_ok=0 ;; esac
    if [ "$gi_ok" -eq 0 ]; then
        # Keep each wanted line that already sits after the previous kept one;
        # from the first that does not, re-append it and every later wanted line
        # at the end, so the result is in end-state order. Unwanted managed
        # lines (committed-only lines for a local target, a bare `.claude/`) go.
        local cursor=0 broke=0
        while IFS= read -r l; do
            ln_of "$l"
            if [ "$broke" -eq 0 ] && [ -n "$LN" ] && [ "$LN" -gt "$cursor" ]; then cursor="$LN"
            else broke=1; GI_APPEND+="$l"$'\n'; fi
        done <<<"$want"
        n=0
        if [ -f "$GI" ]; then
            while IFS= read -r l || [ -n "$l" ]; do
                n=$((n + 1))
                t2="${l%$'\r'}"
                managed "$t2" || continue
                if ! in_list "$t2" "$want" || in_list "$t2" "$GI_APPEND"; then
                    GI_REMOVE_N+="$n"$'\n'; PLAN+="gitignore-remove line $n: $t2"$'\n'
                fi
            done < "$GI"
        fi
        while IFS= read -r l; do
            [ -z "$l" ] || PLAN+="gitignore-append (end of $GI, in this order): $l"$'\n'
        done <<<"$GI_APPEND"
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
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
    done <<<"$SETTINGS"$'\n'"$OWNED"
    if [ -n "$RMC" ]; then
        restore=""
        while IFS= read -r p; do [ -z "$p" ] || restore+="$(printf '%q ' "$p")"; done <<<"$RMC"
        PLAN+="warn: after the untracking commit lands, every collaborator who pulls has these files DELETED from their working tree (their plugin declaration and any hand-added PreToolUse push guard go with .claude/settings.json)"$'\n'
        PLAN+="warn: if .claude/settings.json holds keys beyond extraKnownMarketplaces, enabledPlugins and hook entries whose command contains .claude/hooks/sassydog-, those shared team settings stop being shared"$'\n'
        PLAN+="restore (run right after pulling): git restore --source=<untrack-commit>^ --worktree -- $restore"$'\n'
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        q="$(printf '%q' "$p")"
        if tracked "$p"; then PLAN+="non-owned: $q (tracked; stays tracked, never auto-untracked)"$'\n'
        elif [ "$t" = committed ]; then PLAN+="non-owned: $q (stays ignored; never auto-added)"$'\n'
        else PLAN+="non-owned: $q (untouched)"$'\n'; fi
    done <<<"$NONOWNED"
    PLAN_ID="$(printf '%s' "$PLAN" | cksum | cut -d' ' -f1)"
}

# mutate <target> — the ONLY place anything is written. Its body re-derives and
# compares the result to the plan-id the caller previewed before the first write.
mutate() {
    local t="$1" l p new n cr tmp
    build_plan "$t"
    if [ "$NOTHING" -eq 1 ]; then echo "nothing to do"; return 0; fi
    if [ "$PLAN_ID" != "$EXPECT_ID" ]; then
        echo "tracking-state.sh: refusing to apply: plan-id $EXPECT_ID was previewed but the repo now plans $PLAN_ID; re-run plan" >&2
        return 3
    fi
    if [ -n "$GI_BAD" ]; then echo "tracking-state.sh: refusing to apply: $GI_BAD" >&2; return 6; fi
    if [ -n "$PROBLEMS" ]; then echo "tracking-state.sh: refusing to apply, nothing was written: an owned-name entry is unsafe, nested, a directory or a symlink (rename or remove it yourself): $(printf '%s' "$PROBLEMS" | tr '\n' ';')" >&2; return 7; fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        { [ -f "$p" ] && [ ! -L "$p" ]; } || { echo "tracking-state.sh: refusing to apply: $p does not exist as a regular file yet; write or render it first" >&2; return 4; }
    done <<<"$ADD"
    if [ -n "$GI_APPEND" ] || [ -n "$GI_REMOVE_N" ]; then
        new=""; n=0; cr=""; [ "$GI_CRLF" -eq 1 ] && cr=$'\r'
        if [ -f "$GI" ]; then
            while IFS= read -r l || [ -n "$l" ]; do
                n=$((n + 1))
                in_list "$n" "$GI_REMOVE_N" && continue
                case "$l" in *$'\r') ;; *) l+="$cr" ;; esac
                new+="$l"$'\n'
            done < "$GI"
        fi
        while IFS= read -r l; do [ -z "$l" ] || new+="$l$cr"$'\n'; done <<<"$GI_APPEND"
        tmp="$(mktemp "$GI.tmp.XXXXXX")" || return 6
        if [ -f "$GI" ]; then cp -p "$GI" "$tmp" || { rm -f "$tmp"; return 6; }; else chmod 644 "$tmp"; fi
        printf '%s' "$new" > "$tmp" || { rm -f "$tmp"; return 6; }
        mv -f "$tmp" "$GI" || { rm -f "$tmp"; return 6; }
    fi
    while IFS= read -r p; do [ -z "$p" ] || git rm --cached -q -- "$p" || return 5; done <<<"$RMC"
    while IFS= read -r p; do [ -z "$p" ] || git add -- "$p" || return 5; done <<<"$ADD"
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
        mutate "$TARGET" || exit $?
        derive
        if [ "$STATE" = "$TARGET" ]; then echo "applied: state is now $STATE"; exit 0; fi
        echo "applied, but the state is $STATE, not $TARGET:" >&2
        mm_for "$TARGET" >&2
        exit 1 ;;
    verify)
        collect; scan_gi
        m="$(mm_for "$TARGET")"
        if [ -z "$m" ]; then echo "ok: $TARGET"; exit 0; fi
        printf '%s\n' "$m"
        exit 1 ;;
esac
