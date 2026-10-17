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
#   pg_stop                       kill the scheduler and its jobs, remove capture.
#                                 Idempotent; call from an EXIT/INT/TERM trap.

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

pg_start() {
    PG_JOBS="$1"; shift
    case "$PG_JOBS" in ''|*[!0-9]*|0) PG_JOBS=1 ;; esac
    [ "$PG_JOBS" -gt 1 ] || return 0
    PG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preflight-gates.XXXXXX") || { PG_JOBS=1; PG_DIR=""; return 0; }
    local s
    for s in "$@"; do PG_LAUNCHED="$PG_LAUNCHED$s "; done
    (
        # The scheduler. It owns the capture directory's writers; the parent only
        # reads. Liveness is "launched minus rc files present", never `kill -0`,
        # so a recycled pid cannot make a finished job look running.
        trap 'kill $(jobs -p) 2>/dev/null; exit 143' TERM INT
        launched=0
        for s in "$@"; do
            while :; do
                done_n=$(find "$PG_DIR" -maxdepth 1 -name '*.rc' 2>/dev/null | wc -l | tr -d ' ')
                [ $((launched - done_n)) -lt "$PG_JOBS" ] && break
                sleep 0.2
            done
            k=$(pg_key "$s")
            (
                t0=$(date +%s)
                bash "$s" >"$PG_DIR/$k.out" 2>&1 </dev/null
                rc=$?
                echo "$(($(date +%s) - t0))" >"$PG_DIR/$k.time"
                echo "$rc" >"$PG_DIR/$k.rc.tmp" && mv "$PG_DIR/$k.rc.tmp" "$PG_DIR/$k.rc"
            ) &
            launched=$((launched + 1))
        done
        wait
    ) </dev/null >/dev/null 2>&1 &
    PG_SCHED_PID=$!
}

pg_gate_serial() { bash "$1"; }

pg_gate() {
    local s="$1" k rc
    case "$PG_LAUNCHED" in *" $s "*) ;; *) bash "$s"; return $? ;; esac
    [ "$PG_JOBS" -gt 1 ] || { bash "$s"; return $?; }
    k=$(pg_key "$s")
    while [ ! -f "$PG_DIR/$k.rc" ]; do
        if ! kill -0 "$PG_SCHED_PID" 2>/dev/null; then
            # The scheduler is gone. Its last act is `wait`, so every job it
            # started has written its rc; re-check once for the race between
            # our test and its exit, then call the gate what it is.
            [ -f "$PG_DIR/$k.rc" ] && break
            echo "preflight: $s never ran — the parallel scheduler exited before launching it" >&2
            return 1
        fi
        sleep 0.2
    done
    rc=$(cat "$PG_DIR/$k.rc")
    # One header line per captured block: where a gate's output starts, and how
    # long it took (the next long pole is visible in every CI log).
    echo "--- $s ($(cat "$PG_DIR/$k.time" 2>/dev/null || echo '?')s) ---" >&2
    cat "$PG_DIR/$k.out" >&2
    return "$rc"
}

pg_stop() {
    if [ -n "$PG_SCHED_PID" ]; then
        kill "$PG_SCHED_PID" 2>/dev/null
        wait "$PG_SCHED_PID" 2>/dev/null
        PG_SCHED_PID=""
    fi
    if [ -n "$PG_DIR" ]; then
        rm -rf "$PG_DIR"
        PG_DIR=""
    fi
}
