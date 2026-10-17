#!/usr/bin/env bash
# test-preflight-wiring.sh — preflight runs every scripts/test-*.sh EXACTLY ONCE,
# and its parallel runner keeps the contract the serial script had (issue #567).
#
# WHY THIS GATE EXISTS. preflight.sh used to be 53 hand-written `if bash
# scripts/test-X.sh; then` blocks, and nothing checked that a new test was
# added to it: a suite that is never invoked is green forever, which is the
# quietest way for a gate to stop gating. Parallelising made the question sharper
# (a test could now be launched but never collected, or collected twice), so the
# wiring is checked rather than assumed.
#
# WHAT IS CHECKED, in three layers.
#  1. WIRING (source-level). For every tracked scripts/test-*.sh, preflight.sh
#     carries exactly ONE non-comment line of the form `if|elif pg_gate
#     scripts/test-X.sh; then` (or `pg_gate_serial`), and no non-comment line runs
#     it by a bare `bash`/`sh`/`source`/`./` call (that is a second invocation, and
#     a copy that skips the runner is a launched-but-never-collected gate; the
#     path inside a PASS/FAIL label is text, not an invocation).
#     The reverse holds too: a wired name that is not a tracked test is a typo,
#     and a tracked test whose path contains whitespace is refused, because the
#     launch list is split on whitespace. Each of those is proved by a MUTANT:
#     the real preflight.sh is copied, edited to commit exactly that sin, and
#     must be rejected with its own reason (unwired, double-wired, a stale
#     `bash` form, a typo, whitespace in a name), while the unedited copy passes.
#     CI's separate template-actionlint step does not change this: preflight
#     still wires that gate once and skips it at run time under CI=true.
#  2. THE RUNNER (behavioural, lib-parallel-gates.sh against stub scripts). At
#     most JOBS run at once and more than one does; an exit status and the
#     captured output of the right script come back from the right gate; the
#     JOBS=1 path runs inline; a script the runner was never given still runs
#     (inline) rather than being skipped.
#  3. END TO END (a scratch git repo holding the real preflight.sh and runner
#     over stub test scripts, two of which fail). preflight exits non-zero and
#     NAMES both failing gates in its closing list and none of the passing ones;
#     every gate's output is contiguous, never interleaved with a neighbour's;
#     and PREFLIGHT_JOBS=1 and a parallel run print the same PASS/FAIL/SKIP
#     lines in the same order. npx and shellcheck are stubbed and CI=true is set,
#     so the run needs no network and no pinned tool.
#
# NOT CHECKED HERE, and stated so a later reader does not assume it: that the
# real suites are safe to run side by side. That is an audit of each script's
# scratch space and git usage, recorded in PR #568
# (https://github.com/Sassy-Dog/skills/pull/568); this gate only guarantees the
# wiring and the runner's own behaviour.
# No gh, no network.
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1
PREFLIGHT="scripts/preflight.sh"
LIB="scripts/lib-parallel-gates.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/preflight-wiring.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*" >&2; }

# ---------------------------------------------------------------------------
# 1. wiring
# ---------------------------------------------------------------------------
# wiring_violations <preflight-file> <tests-list-file> : one reason per line;
# empty output means clean.
wiring_violations() {
    local pf="$1" list="$2" t n code
    code=$(grep -vE '^[[:space:]]*#' "$pf")
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        case "$t" in *[[:space:]]*) echo "test path contains whitespace: '$t' (the launch list is split on whitespace)"; continue ;; esac
        n=$(printf '%s\n' "$code" | grep -cE "^(if|elif) pg_gate(_serial)? ${t//./\\.}; then\$" || true)
        [ "$n" = 1 ] || echo "$t is wired $n times through pg_gate/pg_gate_serial (must be exactly 1)"
        n=$(printf '%s\n' "$code" | grep -cE "(^|[[:space:];&|(])(bash|sh|source|\\.)[[:space:]]+\"?${t//./\\.}|(^|[[:space:];&|(])\\./${t//./\\.}" || true)
        [ "$n" = 0 ] || echo "$t is invoked $n times outside the runner (a bare bash/sh/source/./ call is a second invocation)"
    done <"$list"
    # the reverse: every wired name is a tracked test
    printf '%s\n' "$code" | sed -nE 's/^(if|elif) pg_gate(_serial)? (scripts\/test-[^ ;]+); then$/\3/p' | while IFS= read -r w; do
        grep -qxF "$w" "$list" || echo "$w is wired but is not a tracked scripts/test-*.sh"
    done
}

git ls-files 'scripts/test-*.sh' >"$WORK/tests.txt"
[ -s "$WORK/tests.txt" ] || { echo "no tracked scripts/test-*.sh found — the gate would cover nothing" >&2; exit 1; }
# This file is a test too; if it is not tracked yet (a fresh checkout of a PR
# branch always has it tracked), count it so the wiring check is not vacuous.
grep -qxF "scripts/test-preflight-wiring.sh" "$WORK/tests.txt" || echo "scripts/test-preflight-wiring.sh" >>"$WORK/tests.txt"

v=$(wiring_violations "$PREFLIGHT" "$WORK/tests.txt")
if [ -z "$v" ]; then ok "every tracked scripts/test-*.sh is wired into preflight exactly once"; else bad "wiring: $v"; fi

# expect_reason <label> <mutated-preflight> <tests-list> <reason-substring>
expect_reason() {
    local label="$1" pf="$2" list="$3" want="$4" out
    out=$(wiring_violations "$pf" "$list")
    if [ -z "$out" ]; then bad "mutant '$label' was NOT detected"
    elif grep -qF -- "$want" <<<"$out"; then ok "mutant '$label' rejected: $want"
    else bad "mutant '$label' rejected for the wrong reason (wanted '$want'): $out"; fi
}

VICTIM="scripts/test-versioning.sh"
grep -qxF "$VICTIM" "$WORK/tests.txt" || { bad "mutation victim $VICTIM is not a tracked test"; VICTIM=$(sed -n 1p "$WORK/tests.txt"); }
LINE_RE="^if pg_gate ${VICTIM//./\\.}; then\$"

# the victim's whole if/else/fi block, as a line range
start=$(grep -nE "$LINE_RE" "$PREFLIGHT" | head -1 | cut -d: -f1)
if [ -z "$start" ]; then
    bad "cannot find the wiring line for $VICTIM in $PREFLIGHT; the mutants below prove nothing"
else
    end=$(awk -v s="$start" 'NR>s && /^fi$/ {print NR; exit}' "$PREFLIGHT")

    # unwired: the whole block deleted
    sed "${start},${end}d" "$PREFLIGHT" >"$WORK/m-unwired.sh"
    expect_reason "test never invoked" "$WORK/m-unwired.sh" "$WORK/tests.txt" "$VICTIM is wired 0 times"

    # double-wired: the block duplicated
    { sed -n "1,${end}p" "$PREFLIGHT"; sed -n "${start},${end}p" "$PREFLIGHT"; sed -n "$((end + 1)),\$p" "$PREFLIGHT"; } >"$WORK/m-double.sh"
    expect_reason "test invoked twice" "$WORK/m-double.sh" "$WORK/tests.txt" "$VICTIM is wired 2 times"

    # a second, runner-bypassing invocation beside the wired one
    { sed -n "1,${end}p" "$PREFLIGHT"; printf 'bash %s\n' "$VICTIM"; sed -n "$((end + 1)),\$p" "$PREFLIGHT"; } >"$WORK/m-bypass.sh"
    expect_reason "extra bare 'bash' invocation" "$WORK/m-bypass.sh" "$WORK/tests.txt" "$VICTIM is invoked 1 times outside the runner"

    # reverted to the pre-runner shape: launched by the scheduler, never collected
    sed "${start}s/pg_gate/bash/" "$PREFLIGHT" >"$WORK/m-stale.sh"
    expect_reason "wiring line reverted to a bare 'bash'" "$WORK/m-stale.sh" "$WORK/tests.txt" "$VICTIM is wired 0 times"

    # a typo in the wired name
    sed "${start}s/test-versioning/test-versionin/" "$PREFLIGHT" >"$WORK/m-typo.sh"
    expect_reason "typo in a wired name" "$WORK/m-typo.sh" "$WORK/tests.txt" "scripts/test-versionin.sh is wired but is not a tracked"

    # the wiring only in a comment
    sed "${start}s/^/# /" "$PREFLIGHT" >"$WORK/m-comment.sh"
    expect_reason "wiring line commented out" "$WORK/m-comment.sh" "$WORK/tests.txt" "$VICTIM is wired 0 times"

    # serial wiring is wiring (the legitimate escape hatch), exactly once
    sed "${start}s/pg_gate/pg_gate_serial/" "$PREFLIGHT" >"$WORK/m-serial.sh"
    out=$(wiring_violations "$WORK/m-serial.sh" "$WORK/tests.txt")
    if [ -z "$out" ]; then ok "pg_gate_serial counts as wiring"; else bad "pg_gate_serial was rejected as wiring: $out"; fi
fi

# a new tracked test that preflight does not know
{ cat "$WORK/tests.txt"; echo "scripts/test-brand-new.sh"; } >"$WORK/tests-plus.txt"
expect_reason "new test added, not wired" "$PREFLIGHT" "$WORK/tests-plus.txt" "scripts/test-brand-new.sh is wired 0 times"

# a name with whitespace
{ cat "$WORK/tests.txt"; echo "scripts/test-has space.sh"; } >"$WORK/tests-ws.txt"
expect_reason "whitespace in a test path" "$PREFLIGHT" "$WORK/tests-ws.txt" "contains whitespace"

# ---------------------------------------------------------------------------
# 2. the runner
# ---------------------------------------------------------------------------
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
CONC="$WORK/conc"
mkdir -p "$CONC"
for i in 1 2 3 4 5 6; do
    cat >"$STUBS/c$i.sh" <<EOF
d="$CONC"
mkdir "\$d/run.\$\$"
ls -d "\$d"/run.* | wc -l | tr -d ' ' >>"\$d/max.log"
sleep 0.6
rmdir "\$d/run.\$\$"
echo "stub c$i output"
EOF
done
printf 'echo "stub-ok output"\nexit 0\n' >"$STUBS/ok.sh"
printf 'echo "stub-bad output"\nexit 3\n' >"$STUBS/bad.sh"
printf 'echo "never launched output"\nexit 0\n' >"$STUBS/unlaunched.sh"

(
    # shellcheck source=lib-parallel-gates.sh
    . "$LIB"
    pg_start 3 "$STUBS/c1.sh" "$STUBS/c2.sh" "$STUBS/c3.sh" "$STUBS/c4.sh" "$STUBS/c5.sh" "$STUBS/c6.sh" "$STUBS/ok.sh" "$STUBS/bad.sh"
    for i in 1 2 3 4 5 6; do pg_gate "$STUBS/c$i.sh" >/dev/null 2>&1 || echo "c$i failed"; done
    pg_gate "$STUBS/ok.sh" >"$WORK/r-ok.out" 2>&1; echo "$?" >"$WORK/r-ok.rc"
    pg_gate "$STUBS/bad.sh" >"$WORK/r-bad.out" 2>&1; echo "$?" >"$WORK/r-bad.rc"
    pg_gate "$STUBS/unlaunched.sh" >"$WORK/r-un.out" 2>&1; echo "$?" >"$WORK/r-un.rc"
    echo "$PG_DIR" >"$WORK/r-dir.txt"
    pg_stop
) >"$WORK/r-all.out" 2>&1

max=$(sort -n "$CONC/max.log" 2>/dev/null | tail -1)
if [ -n "$max" ] && [ "$max" -le 3 ]; then ok "never more than JOBS=3 scripts running at once (peak $max)"; else bad "concurrency bound broken or unmeasured (peak '${max:-none}', JOBS=3)"; fi
if [ -n "$max" ] && [ "$max" -ge 2 ]; then ok "scripts really ran side by side (peak $max)"; else bad "no parallelism observed (peak '${max:-none}')"; fi
[ "$(cat "$WORK/r-ok.rc" 2>/dev/null)" = 0 ] && grep -qF "stub-ok output" "$WORK/r-ok.out" && ok "a passing gate returns 0 and its own output" || bad "passing gate: rc/out wrong ($(cat "$WORK/r-ok.rc" 2>/dev/null))"
[ "$(cat "$WORK/r-bad.rc" 2>/dev/null)" = 3 ] && grep -qF "stub-bad output" "$WORK/r-bad.out" && ok "a failing gate returns its own status (3) and its own output" || bad "failing gate: rc/out wrong ($(cat "$WORK/r-bad.rc" 2>/dev/null))"
[ "$(cat "$WORK/r-un.rc" 2>/dev/null)" = 0 ] && grep -qF "never launched output" "$WORK/r-un.out" && ok "a script the scheduler was not given still runs, inline" || bad "an unlaunched script was skipped or failed"
if ! grep -q 'failed' "$WORK/r-all.out"; then ok "no c-stub gate reported failure"; else bad "unexpected failure: $(cat "$WORK/r-all.out")"; fi

# the capture directory is removed by pg_stop
capdir=$(cat "$WORK/r-dir.txt" 2>/dev/null)
if [ -n "$capdir" ] && [ ! -e "$capdir" ]; then ok "pg_stop removed the capture directory"; else bad "capture directory '$capdir' missing from the record or outlived pg_stop"; fi

# JOBS=1: inline, no scheduler, no capture dir
(
    # shellcheck source=lib-parallel-gates.sh
    . "$LIB"
    pg_start 1 "$STUBS/ok.sh"
    [ -z "$PG_SCHED_PID" ] && [ -z "$PG_DIR" ] || echo "SCHEDULER-STARTED"
    pg_gate "$STUBS/bad.sh" >"$WORK/s-bad.out" 2>&1; echo "$?" >"$WORK/s-bad.rc"
) >"$WORK/s-all.out" 2>&1
if [ "$(cat "$WORK/s-bad.rc" 2>/dev/null)" = 3 ] && ! grep -q SCHEDULER-STARTED "$WORK/s-all.out"; then ok "JOBS=1 starts no scheduler and runs gates inline with their own status"; else bad "JOBS=1 is not serial/inline: $(cat "$WORK/s-all.out")"; fi

# ---------------------------------------------------------------------------
# 2b. failure modes of the runner, each with a mutant of the runner
# ---------------------------------------------------------------------------
# Four cases, run against a runner copy under a watchdog (a hang is a result, not
# a stuck test):
#   A  runners killed (kill -9) before they recorded a result, with every slot
#      taken: the killed gates must read as FAILED (never pass) and must free
#      their slots, or the gate queued behind them never starts and the run spins.
#   B  a gate that dies by signal returns non-zero.
#   C  a gate with an EMPTY capture and exit 0 passes (no "silent means broken").
#   D  pg_stop leaves no gate process and no grandchild alive.
CASE_DIR="$WORK/cases"
mkdir -p "$CASE_DIR"
cat >"$CASE_DIR/slow.sh" <<'EOF'
echo $$ >"$PIDS/$(basename "$0").pid"
sleep 60
EOF
printf 'exit 0\n' >"$CASE_DIR/quick.sh"
printf 'kill -9 $$\n' >"$CASE_DIR/sig.sh"
cp "$CASE_DIR/slow.sh" "$CASE_DIR/slow2.sh"
cat >"$CASE_DIR/tree.sh" <<'EOF'
sleep 60 &
echo $! >"$PIDS/tree-sleep.pid"
echo $$ >"$PIDS/tree.pid"
wait
EOF

# run_cases <lib> — prints one result line: A1= A2= Aq= B= C= D=
run_cases() {
    local lib="$1" pids="$WORK/pids.$RANDOM" out="$WORK/cases.out.$RANDOM" i
    mkdir -p "$pids"
    (
        export PIDS="$pids"
        # shellcheck source=lib-parallel-gates.sh
        . "$lib"
        nz() { if [ "$1" = 0 ]; then echo 0; else echo nz; fi; }
        wait_for() { local n=0; while [ ! -s "$1" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done; }

        # A: both slots held by slow gates, a third queued; kill both runners.
        pg_start 2 "$CASE_DIR/slow.sh" "$CASE_DIR/slow2.sh" "$CASE_DIR/quick.sh"
        k1=$(pg_key "$CASE_DIR/slow.sh"); k2=$(pg_key "$CASE_DIR/slow2.sh")
        wait_for "$PG_DIR/$k1.wpid"; wait_for "$PG_DIR/$k2.wpid"
        wait_for "$pids/slow.sh.pid"; wait_for "$pids/slow2.sh.pid"
        kill -9 "$(cat "$PG_DIR/$k1.wpid")" "$(cat "$PG_DIR/$k2.wpid")" 2>/dev/null
        pg_gate "$CASE_DIR/slow.sh" >/dev/null 2>&1; a1=$?
        pg_gate "$CASE_DIR/slow2.sh" >/dev/null 2>&1; a2=$?
        pg_gate "$CASE_DIR/quick.sh" >/dev/null 2>&1; aq=$?
        # the orphaned gates outlive their killed runners; reap them here
        for f in "$pids/slow.sh.pid" "$pids/slow2.sh.pid"; do [ -s "$f" ] && pg_killtree "$(cat "$f")"; done
        pg_stop

        # B and C share a run.
        pg_start 2 "$CASE_DIR/sig.sh" "$CASE_DIR/quick.sh"
        pg_gate "$CASE_DIR/sig.sh" >/dev/null 2>&1; b=$?
        c_out=$(pg_gate "$CASE_DIR/quick.sh" 2>&1 >/dev/null); c=$?
        case "$c_out" in "--- "*) ;; *) c=99 ;; esac   # header only, nothing else
        pg_stop

        # D: a gate and its grandchild die with pg_stop.
        pg_start 2 "$CASE_DIR/tree.sh"
        wait_for "$pids/tree-sleep.pid"; wait_for "$pids/tree.pid"
        pg_stop
        sleep 1
        d=dead
        for f in "$pids/tree.pid" "$pids/tree-sleep.pid"; do
            if [ -s "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; then d=ALIVE; kill -9 "$(cat "$f")" 2>/dev/null; fi
        done
        echo "A1=$(nz $a1) A2=$(nz $a2) Aq=$(nz $aq) B=$(nz $b) C=$(nz $c) D=$d"
    ) >"$out" 2>&1 &
    local pid=$! n=0
    while kill -0 "$pid" 2>/dev/null && [ $n -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        pg_killtree_local() { local p="$1" c; for c in $(ps -eo pid=,ppid= | while read -r a b; do [ "$b" = "$p" ] && echo "$a"; done); do pg_killtree_local "$c"; done; kill -9 "$p" 2>/dev/null; }
        pg_killtree_local "$pid"
        for i in "$pids"/*.pid; do [ -s "$i" ] && kill -9 "$(cat "$i")" 2>/dev/null; done
        echo "TIMEOUT (the runner hung)"
    else
        tail -1 "$out"
    fi
}

WANT="A1=nz A2=nz Aq=0 B=nz C=0 D=dead"
got=$(run_cases "$LIB")
if [ "$got" = "$WANT" ]; then ok "runner failure modes: killed runners FAIL and free their slots; signal exit is non-zero; empty capture + exit 0 passes; pg_stop leaves no process alive"; else bad "runner failure modes: wanted '$WANT', got '$got'"; fi

# mutant_lib <name> <sed expression> <expected substring of the wrong result>
mutant_lib() {
    local name="$1" expr="$2" want="$3" m="$WORK/mlib.$RANDOM.sh" r
    sed "$expr" "$LIB" >"$m"
    if cmp -s "$m" "$LIB"; then bad "runner mutant '$name' changed nothing, so it proves nothing"; return; fi
    r=$(run_cases "$m")
    if [ "$r" = "$WANT" ]; then bad "runner mutant '$name' was NOT detected"
    elif grep -qF -- "$want" <<<"$r"; then ok "runner mutant '$name' detected ($want)"
    else bad "runner mutant '$name' detected, but not as '$want': $r"; fi
}
mutant_lib "a runner with no result reads as passing" 's/return 1 # PG-DEAD-WRAPPER/return 0/' "A1=0"
mutant_lib "slots held by a missing .rc, not a live runner" 's/running=.*# PG-SLOTS/running=$(( $(find "$PG_DIR" -maxdepth 1 -name "*.wpid" | wc -l) - $(find "$PG_DIR" -maxdepth 1 -name "*.rc" | wc -l) ))/' "TIMEOUT"
mutant_lib "signal exit normalised to success" 's/rc=.* # PG-RC/rc=0 # PG-RC/' "B=0"
mutant_lib "empty capture read as failure" 's/rc=.*# PG-RCREAD/rc=$(cat "$PG_DIR\/$k.rc"); [ -s "$PG_DIR\/$k.out" ] || rc=1/' "C=nz"
mutant_lib "pg_stop SIGKILLs the scheduler, orphaning the tree" 's/pg_killtree "\$PG_SCHED_PID"/kill -9 "$PG_SCHED_PID"/' "D=ALIVE"

# ---------------------------------------------------------------------------
# 3. end to end: the real preflight.sh over a stub tree
# ---------------------------------------------------------------------------
E2E="$WORK/e2e"
mkdir -p "$E2E/scripts" "$WORK/bin"
cp "$PREFLIGHT" "$E2E/scripts/preflight.sh"
cp "$LIB" "$E2E/scripts/lib-parallel-gates.sh"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/npx"; printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/shellcheck"
chmod +x "$WORK/bin/npx" "$WORK/bin/shellcheck"
FAILERS="scripts/test-versioning.sh scripts/test-stale-issues.sh"
while IFS= read -r t; do
    [ "$t" = "scripts/test-preflight-wiring.sh" ] && continue
    name=$(basename "$t" .sh)
    case " $FAILERS " in *" $t "*) status=1 ;; *) status=0 ;; esac
    {
        echo '#!/usr/bin/env bash'
        # A tagged block with a pause in the middle: interleaving would split it.
        echo "for i in 1 2 3 4 5 6 7 8; do echo \"BLOCK:$name:\$i\"; [ \$i = 4 ] && sleep 0.3; done"
        echo "exit $status"
    } >"$E2E/$t"
done <"$WORK/tests.txt"
# the wiring gate (this file) is a stub in the scratch tree as well
printf '#!/usr/bin/env bash\necho "BLOCK:test-preflight-wiring:1"\nexit 0\n' >"$E2E/scripts/test-preflight-wiring.sh"
(
    cd "$E2E" && git init -q . && git add -A
) >/dev/null 2>&1

run_e2e() { # <jobs> <outfile>
    ( cd "$E2E" && env CI=true PATH="$WORK/bin:$PATH" PREFLIGHT_JOBS="$1" bash scripts/preflight.sh ) >"$2" 2>&1
    echo "$?" >"$2.rc"
}
run_e2e 4 "$WORK/e2e-par.out"
run_e2e 1 "$WORK/e2e-ser.out"

for mode in par ser; do
    out="$WORK/e2e-$mode.out"
    [ "$(cat "$out.rc")" != 0 ] && ok "[$mode] preflight exits non-zero when gates fail" || bad "[$mode] preflight exited 0 with two failing gates"
    listed=$(sed -n '/^preflight: failed gates:/,$p' "$out")
    for f in $FAILERS; do
        if grep -qF "($f)" <<<"$listed"; then ok "[$mode] failing gate named in the closing list: $f"; else bad "[$mode] failing gate NOT named in the closing list: $f"; fi
    done
    if ! grep -qF "(scripts/test-ownership-matchers.sh)" <<<"$listed"; then ok "[$mode] a passing gate is not in the failed list"; else bad "[$mode] a passing gate was listed as failed"; fi
    # contiguity: a BLOCK tag may form one run only
    runs=$(grep -oE 'BLOCK:[a-z0-9-]+' "$out" | uniq)
    dupes=$(printf '%s\n' "$runs" | sort | uniq -d)
    if [ -z "$dupes" ] && [ -n "$runs" ]; then ok "[$mode] each gate's output is one contiguous block"; else bad "[$mode] gate output interleaved or absent: $dupes"; fi
    # every block complete (8 lines each, stub tests only)
    short=$(grep -oE 'BLOCK:[a-z0-9-]+:[0-9]+' "$out" | cut -d: -f2 | sort | uniq -c | awk '$1 != 8 && $2 != "test-preflight-wiring" {print $2}')
    if [ -z "$short" ]; then ok "[$mode] every gate's captured output arrived whole"; else bad "[$mode] truncated or duplicated output: $short"; fi
done
if diff <(grep -E '^(PASS|FAIL|SKIP)' "$WORK/e2e-par.out") <(grep -E '^(PASS|FAIL|SKIP)' "$WORK/e2e-ser.out") >"$WORK/e2e.diff"; then
    ok "PREFLIGHT_JOBS=4 and PREFLIGHT_JOBS=1 print the same PASS/FAIL/SKIP lines in the same order"
else
    bad "parallel and serial runs differ: $(head -5 "$WORK/e2e.diff" | tr '\n' ' ')"
fi
if ( cd "$E2E" && env CI=true PATH="$WORK/bin:$PATH" PREFLIGHT_JOBS=zero bash scripts/preflight.sh ) >/dev/null 2>"$WORK/e2e-bad.err"; then
    bad "a non-numeric PREFLIGHT_JOBS was accepted"
else
    grep -q 'PREFLIGHT_JOBS must be a positive integer' "$WORK/e2e-bad.err" && ok "a non-numeric PREFLIGHT_JOBS is refused with a message" || bad "bad PREFLIGHT_JOBS failed without the message"
fi

echo
echo "test-preflight-wiring: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
