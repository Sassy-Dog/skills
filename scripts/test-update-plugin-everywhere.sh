#!/usr/bin/env bash
# test-update-plugin-everywhere.sh — executes scripts/update-plugin-everywhere.sh
# against a stubbed `claude` and a scratch HOME holding a fixture
# installed_plugins.json (#590). Before this gate nothing exercised the script.
#
# WHY A LINKED-WORKTREE CASE EXISTS. `claude plugin update --scope project` run
# from inside a linked git worktree resolves to the MAIN checkout's registry
# entry, prints "already at the latest version" and leaves the worktree's own
# entry stale forever; the script's old prune step removed only entries whose
# directory was gone. Measured 2026-10-25 on two real worktrees (2026.10.52 and
# 2026.10.64 beside a 2026.10.101 current). The fix prunes a linked-worktree pin
# like a dead one, after the backup, and the dry run counts it separately.
#
# THE DECISION THAT READS LIKE DRIFT. Detection is "git dir differs from common
# dir", not "common dir is not <path>/.git". A submodule's `.git` is a file too,
# but its git dir and common dir are the same directory, so the stricter test
# keeps a submodule pin on the update path. The fixture includes one.
#
# Fixture: a marketplace clone, a current cache and an older one, and four
# project entries (dead path, normal checkout, linked worktree, submodule) beside
# the user entry. `claude` is a PATH stub that logs "<cwd> <args>" and prints
# the sort of line the real one does; nothing here reaches the network, the real
# ~/.claude, or this checkout (every git call targets a scratch directory, and
# GIT_* environment is cleared).
#
# Mutants: each changes one construct in a COPY of the script and the same suite
# must then fail, so a case that cannot see its construct is reported as vacuous.
#
# Parallel-safe (CLAUDE.md): one mktemp -d, scratch HOME, no fixed path, no write
# inside the checkout, no port.
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-update-plugin-everywhere: not in a git repo" >&2; exit 1; }
SCRIPT="$REPO_ROOT/scripts/update-plugin-everywhere.sh"
[ -f "$SCRIPT" ] || { echo "test-update-plugin-everywhere: $SCRIPT not found" >&2; exit 1; }
for t in jq git diff python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "test-update-plugin-everywhere: $t is required" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

fail=0
ok() { echo "  ok    $1" >&2; }
bad() { echo "  FAIL  $1" >&2; fail=1; }

echo "update-plugin-everywhere tests (work: $WORK)" >&2

PLUGIN="sassy-dog@skills"

# A scratch git with no inherited identity, config or repo.
sgit() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        HOME="$WORK/githome" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        git "$@"
}
mkdir -p "$WORK/githome"

# --- fixture builder: a fresh scratch HOME per scenario ------------------------
build() { # <home dir>
    local h="$1" repos="$1/repos" cache="$1/cache" clone="$1/.claude/plugins/marketplaces/skills" d
    mkdir -p "$repos" "$cache" "$clone/.claude-plugin" "$h/bin"
    for d in skills agents scripts; do
        mkdir -p "$clone/$d" "$cache/cur/$d" "$cache/old/$d"
        echo "current $d" >"$clone/$d/f.txt"
        echo "current $d" >"$cache/cur/$d/f.txt"
        echo "STALE $d" >"$cache/old/$d/f.txt"
    done
    echo '{"version":"2026.10.101"}' >"$clone/.claude-plugin/plugin.json"
    mkdir -p "$repos/main" "$repos/sub-src"
    sgit -C "$repos/main" init -q
    sgit -C "$repos/main" commit -q --allow-empty -m init
    sgit -C "$repos/main" worktree add -q "$repos/wt" -b wt-branch
    sgit -C "$repos/sub-src" init -q
    sgit -C "$repos/sub-src" commit -q --allow-empty -m init
    sgit -C "$repos/main" -c protocol.file.allow=always submodule add -q "$repos/sub-src" sub >/dev/null 2>&1
    jq -n --arg p "$PLUGIN" --arg r "$repos" --arg c "$cache" '
      {version:2, plugins:{($p):[
        {scope:"user", version:"2026.10.101", installPath:($c+"/cur")},
        {scope:"project", projectPath:($r+"/main"), version:"2026.10.101", installPath:($c+"/cur")},
        {scope:"project", projectPath:($r+"/wt"), version:"2026.10.52", installPath:($c+"/old")},
        {scope:"project", projectPath:($r+"/main/sub"), version:"2026.10.101", installPath:($c+"/cur")},
        {scope:"project", projectPath:($r+"/gone"), version:"2026.9.4", installPath:($c+"/old")}
      ]}}' >"$h/.claude/plugins/installed_plugins.json"
    cat >"$h/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd -P)" "$*" >>"$STUB_CALLS"
case "$*" in
    "plugin marketplace update"*) echo "marketplace refreshed" ;;
    "plugin update"*) echo "already at the latest version (2026.10.101)" ;;
esac
exit 0
STUB
    chmod +x "$h/bin/claude"
    : >"$h/calls"
}

OUT=""; RC=0
run() { # <script> <home> [args…]
    local sc="$1" h="$2"; shift 2
    OUT="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE HOME="$h" PATH="$h/bin:$PATH" STUB_CALLS="$h/calls" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null bash "$sc" "$@" 2>&1)"
    RC=$?
}

FAILED=""
expect() { # <label> <condition rc: 0 holds>
    [ "$2" = 0 ] || FAILED="$FAILED|$1"
}
has() { grep -qF -- "$1" <<<"$OUT"; }
registry_paths() { jq -r --arg p "$PLUGIN" '.plugins[$p][] | select(.scope=="project") | .projectPath' "$1/.claude/plugins/installed_plugins.json" | sort; }

suite() { # <script>
    local sc="$1" h="$WORK/h-$RANDOM-$RANDOM" repos
    FAILED=""
    build "$h"; repos="$h/repos"

    # --- dry run: reports, counts the worktree pin on its own, changes nothing --
    cp "$h/.claude/plugins/installed_plugins.json" "$h/orig.json"
    run "$sc" "$h"
    expect "dry run: exit 0" "$([ "$RC" = 0 ]; echo $?)"
    expect "dry run: the table marks the linked worktree WORKTREE" "$(grep -qE "^project +2026.10.52 +WORKTREE +$repos/wt\$" <<<"$OUT"; echo $?)"
    expect "dry run: the table marks the missing path DEAD" "$(grep -qE "^project +2026.9.4 +DEAD +$repos/gone\$" <<<"$OUT"; echo $?)"
    expect "dry run: the normal checkout and the submodule are compared by content, not marked" \
        "$(grep -E "^project .*($repos/main|$repos/main/sub)\$" <<<"$OUT" | grep -qE 'current' && ! grep -E "^project .*($repos/main|$repos/main/sub)\$" <<<"$OUT" | grep -qE 'WORKTREE|DEAD'; echo $?)"
    expect "dry run: reports 2 live (main, submodule), 1 dead, 1 linked-worktree pin separately" \
        "$(has "would update user scope + 2 live project scope(s), prune 1 dead entr(y|ies) and 1 linked-worktree pin(s)"; echo $?)"
    expect "dry run: the registry is untouched" "$(cmp -s "$h/orig.json" "$h/.claude/plugins/installed_plugins.json"; echo $?)"
    expect "dry run: no backup written" "$(! ls "$h"/.claude/plugins/installed_plugins.json.bak-* >/dev/null 2>&1; echo $?)"
    expect "dry run: no plugin update ran" "$(! grep -q 'plugin update' "$h/calls"; echo $?)"

    # --- apply ---------------------------------------------------------------
    : >"$h/calls"
    run "$sc" "$h" --apply
    expect "apply: exit 0, every surviving copy current" "$([ "$RC" = 0 ]; echo $?)"
    expect "apply: a timestamped backup equal to the original exists" \
        "$(b="$(ls "$h"/.claude/plugins/installed_plugins.json.bak-* 2>/dev/null | head -1)"; [ -n "$b" ] && cmp -s "$b" "$h/orig.json"; echo $?)"
    expect "apply: the linked-worktree pin is pruned and reported as a worktree pin" \
        "$(has "removed worktree pin: $repos/wt (2026.10.52)"; echo $?)"
    expect "apply: the dead entry is pruned and reported" "$(has "removed: $repos/gone (2026.9.4)"; echo $?)"
    expect "apply: the registry keeps exactly the normal checkout and the submodule" \
        "$([ "$(registry_paths "$h")" = "$(printf '%s\n%s' "$repos/main" "$repos/main/sub" | sort)" ]; echo $?)"
    expect "apply: the user entry survives" \
        "$([ "$(jq -r --arg p "$PLUGIN" '[.plugins[$p][] | select(.scope=="user")] | length' "$h/.claude/plugins/installed_plugins.json")" = 1 ]; echo $?)"
    expect "apply: user scope was updated" "$(grep -q 'plugin update sassy-dog@skills --scope user' "$h/calls"; echo $?)"
    expect "apply: the normal checkout was updated from inside it" \
        "$(grep -qF "$repos/main plugin update sassy-dog@skills --scope project" "$h/calls"; echo $?)"
    expect "apply: the submodule was updated from inside it (it is not a worktree)" \
        "$(grep -qF "$repos/main/sub plugin update sassy-dog@skills --scope project" "$h/calls"; echo $?)"
    expect "apply: no update ran inside the linked worktree" "$(! grep -qF "$repos/wt plugin update" "$h/calls"; echo $?)"
    expect "apply: no update ran at the dead path" "$(! grep -qF "$repos/gone plugin update" "$h/calls"; echo $?)"
    expect "apply: the closing restart notice is printed" "$(has "RESTART REQUIRED"; echo $?)"

    # --- a stale surviving copy still fails the run, by content ----------------
    jq --arg p "$PLUGIN" --arg c "$h/cache" '.plugins[$p] += [{scope:"project", projectPath:"'"$repos"'/main", version:"2026.10.101", installPath:($c+"/old")}]' \
        "$h/.claude/plugins/installed_plugins.json" >"$h/stale.json" && cp "$h/stale.json" "$h/.claude/plugins/installed_plugins.json"
    run "$sc" "$h" --apply
    expect "a surviving stale copy still exits 1" "$([ "$RC" = 1 ]; echo $?)"
}

suite "$SCRIPT"
if [ -z "$FAILED" ]; then ok "update-plugin-everywhere: every committed case holds"
else bad "update-plugin-everywhere cases failed:$FAILED"; fi

# --- mutants --------------------------------------------------------------------
MUT="$WORK/mut"; mkdir -p "$MUT"
mutant() { # <label> <old text, must occur once> <new text>
    local label="$1" f="$MUT/$1.sh"
    cp "$SCRIPT" "$f"
    if ! python3 -I -c '
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
' "$f" "$2" "$3"; then
        bad "mutant '$label' did not apply (its anchor moved)"; return
    fi
    suite "$f"
    if [ -n "$FAILED" ]; then ok "mutant '$label' fails the suite"
    else bad "mutant '$label' passes the suite — its case is vacuous"; fi
}
mutant worktree-never-detected '    [ "$gd" != "$cd_" ]' '    false'
mutant submodule-counted-as-worktree '    [ "$gd" != "$cd_" ]' '    [ -f "$p/.git" ]'
mutant worktree-still-updated '[ "$(project_kind "$ppath")" = live ] || continue' '[ -d "$ppath" ] || continue'
mutant worktree-not-pruned '    elif [ "$kind" = worktree ]; then
        echo "  removed worktree pin' '    elif false; then
        echo "  removed worktree pin'
mutant dead-not-pruned '    if [ "$kind" = dead ]; then' '    if false; then'
mutant dry-run-no-worktree-count 'worktree) wt=$((wt + 1)) ;;' 'worktree) live=$((live + 1)) ;;'
mutant table-no-worktree-mark 'worktree) st="WORKTREE" ;;' 'worktree) ;;'
mutant backup-skipped 'cp "$REGISTRY" "$REGISTRY.bak-$stamp" ||' 'true ||'

if [ "$fail" -eq 0 ]; then
    echo "update-plugin-everywhere tests: all green" >&2
    exit 0
else
    echo "update-plugin-everywhere tests: FAILURES above" >&2
    exit 1
fi
