#!/usr/bin/env bash
# lib-parallel-gates.sh — the bounded parallel runner behind scripts/preflight.sh's
# test gates (issue #567). SOURCED, never executed. Bash 3.2 compatible (macOS):
# no `wait -n`, no associative arrays, no `${arr[@]}` of a possibly-empty array
# under `set -u`.
#
# THE SHAPE, AND WHY IT IS THIS SHAPE. preflight.sh is a linear script whose gates
# print PASS/FAIL where they sit, and its serial gates (shellcheck, frontmatter,
# guards, manifests, markdownlint) are cheap, order-dependent or both. Only the
# `scripts/test-*.sh` suites are expensive, and each is a self-contained process
# with its own scratch space. So the runner does not reorder anything: a
# BACKGROUND SCHEDULER starts the test gates up front, at most JOBS at a time,
# each with stdout+stderr captured to its own file; preflight then reaches each
# gate at its usual place and calls `pg_gate scripts/test-X.sh`, which waits for
# that one gate, prints its captured output WHOLE (never interleaved with a
# neighbour's), and returns its exit status. PASS/FAIL lines, their order, and
# the "all gates run even after a failure" accumulate-and-report contract are
# therefore exactly what they were; only the wall-clock changed.
#
# JOBS=1 IS THE OLD BEHAVIOUR, not an emulation of it: no scheduler, no capture;
# `pg_gate` runs the script in the foreground at its place, as the `if bash …`
# it replaced did.
#
# A gate that cannot be run in parallel is run with `pg_gate_serial` (inline,
# at its place, never launched). The list of such gates and the reason for each
# is in preflight.sh's header; there is deliberately no escape hatch beyond that
# function, and test-preflight-wiring.sh pins that every test is wired through
# exactly one of the two.
#
# API (all state in PG_* globals):
#   pg_cpu_count                  print the CPU count (getconf/nproc/sysctl, else 1)
#   pg_start JOBS SCRIPT...       JOBS<=1: record serial mode. Otherwise start the
#                                 scheduler over SCRIPT... (launch order = argument
#                                 order) and return immediately.
#   pg_gate SCRIPT                wait for, print and return the status of SCRIPT.
#                                 Parallel mode prints a `--- SCRIPT (Ns) ---`
#                                 header line, then the captured output whole.
#                                 A script pg_start was not given runs inline.
#   pg_gate_serial SCRIPT         run SCRIPT inline, now.
#   pg_stop                       kill the scheduler, every gate and everything
#                                 they started (the whole process tree), remove
#                                 the capture. Idempotent; call from an
#                                 EXIT/INT/TERM trap.
#
# FAILURE MODES, each named rather than left to spin: a gate that exits by signal
# returns its 128+N status (non-zero); a runner killed before it recorded a
# result is reported as FAILED, "exited without recording a result", and frees
# its slot; a scheduler that died before launching a gate fails that gate. A
# gate with an empty capture and status 0 passes.
#
# CONCURRENCY IS NOT EXACTLY JOBS. JOBS bounds the gates THIS scheduler starts.
# A gate may fork workers of its own: test-deps-cadence-policy.sh shards itself
# into min(JOBS, 8) processes, which are outside the slot count. Total
# concurrency can therefore exceed JOBS (by at most that gate's shard count). That
# was chosen over capping: the shards are what keep the longest gate from being
# the floor of the whole run, and the host's CPU count, not JOBS, is the real
# limit on throughput.


PG_JOBS=1
PG_DIR=""
PG_SCHED_PID=""
PG_LAUNCHED=" "

pg_cpu_count() {
    local n=""
    n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
    case "$n" in ''|*[!0-9]*) n=$(nproc 2>/dev/null) || n="" ;; esac
    case "$n" in ''|*[!0-9]*) n=$(sysctl -n hw.ncpu 2>/dev/null) || n="" ;; esac
    case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
    printf '%s\n' "$n"
}

# A script path as a file-name-safe key.
pg_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# pg_killtree PID — kill PID and every descendant, leaves first, so a parent
# cannot spawn a replacement between its child's death and its own. Walks `ps`
# rather than using pgrep or a process group: both ship on macOS and Linux, and
# macOS has no setsid.
pg_killtree() {
    local p="$1" c
    for c in $(ps -eo pid=,ppid= 2>/dev/null | while read -r a b; do [ "$b" = "$p" ] && echo "$a"; done); do
        pg_killtree "$c"
    done
    kill "$p" 2>/dev/null
    return 0
}

pg_start() {
    PG_JOBS="$1"; shift
    case "$PG_JOBS" in ''|*[!0-9]*|0) PG_JOBS=1 ;; esac
    [ "$PG_JOBS" -gt 1 ] || return 0
    PG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preflight-gates.XXXXXX") || { PG_JOBS=1; PG_DIR=""; return 0; }
    local s
    for s in "$@"; do PG_LAUNCHED="$PG_LAUNCHED$s "; done
    (
        # The scheduler. It owns the capture directory's writers; the parent only
        # reads. A slot is held by a live wrapper (`jobs -r`, the shell's own
        # table, so a recycled pid cannot confuse it), NOT by a missing .rc file:
        # a wrapper killed before it wrote its result must free its slot or the
        # run spins until the job limit.
        j=""
        trap 'for j in $(jobs -p); do pg_killtree "$j"; done; exit 143' TERM INT
        for s in "$@"; do
            while :; do
                running=$(jobs -r | wc -l | tr -d ' ') # PG-SLOTS
                [ "$running" -lt "$PG_JOBS" ] && break
                sleep 0.2
            done
            k=$(pg_key "$s")
            (
                t0=$(date +%s)
                bash "$s" >"$PG_DIR/$k.out" 2>&1 </dev/null &
                c=$!
                trap 'pg_killtree "$c"; exit 143' TERM INT
                wait "$c"
                rc=$? # PG-RC
                echo "$(($(date +%s) - t0))" >"$PG_DIR/$k.time"
                echo "$rc" >"$PG_DIR/$k.rc.tmp" && mv "$PG_DIR/$k.rc.tmp" "$PG_DIR/$k.rc"
            ) &
            echo "$!" >"$PG_DIR/$k.wpid"
        done
        wait
    ) </dev/null >/dev/null 2>&1 &
    PG_SCHED_PID=$!
}

pg_gate_serial() { bash "$1"; }

pg_gate() {
    local s="$1" k rc wpid
    case "$PG_LAUNCHED" in *" $s "*) ;; *) bash "$s"; return $? ;; esac
    [ "$PG_JOBS" -gt 1 ] || { bash "$s"; return $?; }
    k=$(pg_key "$s")
    while [ ! -f "$PG_DIR/$k.rc" ]; do
        wpid=$(cat "$PG_DIR/$k.wpid" 2>/dev/null)
        if [ -n "$wpid" ] && ! kill -0 "$wpid" 2>/dev/null; then
            # The wrapper for THIS gate is gone. Re-check for the result it may
            # have written between our test and its exit; otherwise it was killed
            # before recording one, and a gate with no result is a FAILED gate.
            [ -f "$PG_DIR/$k.rc" ] && break
            echo "--- $s (no result) ---" >&2
            cat "$PG_DIR/$k.out" >&2 2>/dev/null
            echo "preflight: $s FAILED — its runner exited without recording a result (killed?)" >&2
            return 1 # PG-DEAD-WRAPPER
        fi
        if ! kill -0 "$PG_SCHED_PID" 2>/dev/null && [ -z "$wpid" ]; then
            # The scheduler is gone and never launched this gate.
            [ -f "$PG_DIR/$k.rc" ] && break
            echo "preflight: $s FAILED — the parallel scheduler exited before launching it" >&2
            return 1
        fi
        sleep 0.2
    done
    rc=$(cat "$PG_DIR/$k.rc") # PG-RCREAD
    # One header line per captured block: where a gate's output starts, and how
    # long it took (the next long pole is visible in every CI log).
    echo "--- $s ($(cat "$PG_DIR/$k.time" 2>/dev/null || echo '?')s) ---" >&2
    cat "$PG_DIR/$k.out" >&2
    return "$rc"
}

pg_stop() {
    if [ -n "$PG_SCHED_PID" ]; then
        # The whole tree: wrappers, the gates they run, and whatever those
        # started (a sharded suite's shards, a stub's sleep).
        pg_killtree "$PG_SCHED_PID"
        wait "$PG_SCHED_PID" 2>/dev/null
        PG_SCHED_PID=""
    fi
    if [ -n "$PG_DIR" ]; then
        rm -rf "$PG_DIR"
        PG_DIR=""
    fi
}
