#!/usr/bin/env bash
# checkout-guard.sh — cooperative, durable checkout ownership and foreground runner.
#
# Usage:
#   acquire --repo PATH --owner UNIQUE_COORDINATOR_ID
#   status  --repo PATH
#   check   --repo PATH                (read-only gate for other local-checkout mutators;
#                                       the caller's token comes from SASSY_DOG_CHECKOUT_TOKEN)
#   run     --repo PATH --token TOKEN --branch BRANCH [--timeout SECONDS] -- CMD ARGS...
#   verify  --repo PATH --token TOKEN
#   release --repo PATH --token TOKEN
#   abandon --repo PATH --reason TEXT [--investigated]   (operator only; never a coordinator)
#
# Requires Bash, Python 3, Git and POSIX ps (macOS/Linux); no third-party modules.
# Python runs isolated (-I): a module in the caller's directory cannot shadow
# the standard library and turn every status read into an unverified tick.
# One JSON object goes to stdout. Worker stdout and stderr both go to stderr;
# worker stdin is /dev/null. CMD is executed directly, never interpreted by a
# shell. run is synchronous and never accepts a reported RESULT as exit proof.
#
# Lifecycle: acquire BEFORE any checkout mutation, retain its secret token, run
# a foreground worker, verify BEFORE switching away from its branch, finish any
# coordinator mutations under ownership, then release. Acquisition requires a
# clean named branch whose local tip is present on its fresh upstream remote
# (origin's same-name branch when no upstream exists). A behind branch is safe;
# dirty/unpushed work is never moved aside. run records BRANCH but never
# creates/switches/pushes it. verify
# and release require clean state and every recorded run branch's local commit
# to equal a fresh `git ls-remote origin refs/heads/BRANCH` result. Zero-worker
# completion is supported. A proven nonzero worker exit remains in the record
# and can be verified/released if its work is clean and independently pushed.
#
# The guard covers the Git COMMON directory, conservatively excluding other
# worktrees too. mkdir and an advisory flock on a NEVER-unlinked mutex serialize
# cooperating callers. The private guard holds an fsync'd, atomically replaced
# state.json. A child waits behind a pipe until its launch/identity is durable;
# EOF before authorization cannot start the worker. The runner uses a separate
# process group, observes descendants, waits/reaps the actual child, and proves
# no live observed group member or descendant remains before marking completed.
# Foreground tool subprocesses may create their own groups; those are tracked too.
# A successful release atomically archives the guard into
# <common-dir>/sassy-dog-checkout-history/<token>; results are not discarded.
#
# Supported workers MUST remain foreground and MUST NOT detach, daemonize, or
# submit opaque asynchronous tasks. This is a cooperative lifecycle guard, not a
# sandbox: portable ps cannot prove absence of a double-fork escaping between
# observations. A surviving observed group or descendant, or an inspection
# failure, makes termination uncertain. Callers must use the supervised
# foreground CLI, not a task handle or self-report.
#
# Timeout/SIGINT/SIGTERM/SIGHUP records a durable hold BEFORE signalling the
# worker's own group (TERM, then KILL after five seconds while the worker is
# unreaped). Other observed groups are not signalled; any live member is
# recorded in remaining_processes and keeps the guard held, a fail-safe hold
# the operator runbook resolves. The runner reaps when it can, but
# interrupted/timed-out/uncertain phases cannot be verified/released.
# SIGKILL or a crash can leave a launching/running record and surviving worker;
# subsequent callers refuse it even if its PID later disappears. There is no
# TTL, force unlock, or automatic crash recovery. Such a hold requires operator
# investigation of the recorded identities, process tree and retained work;
# this command intentionally provides no shortcut that guesses termination.
# A failed acquire archives its own guard: it published ownership before its
# ancestry probe, but no token or worker exists yet, so nothing can be lost
# and leaving it would wedge every later caller behind an ownerless record.
# abandon is the operator's route for a coordinator that died holding the only
# token. It needs positive evidence, not a token: phase held/completed, or
# uncertain with no runs (an acquire that died mid-probe), from the guard's
# own worktree, then every check verify makes. Launching, running, timed-out,
# interrupted and other uncertain guards, and a guard whose state is unreadable,
# need --investigated: the operator's attestation that they inspected the
# recorded processes and retained work. It replaces only the durable proof of
# termination, never the live checks: every recorded supervisor, child,
# process group and descendant must be gone now, and the tree must be clean
# with exact pushed tips. An unreadable record names no processes, branches or
# worktree, so only a clean tree and a published current branch stand behind
# that form. Neither form can tell a dead owner from a live one;
# that judgement is why only a human runs it.
# A run records whether its branch existed before launch. A worker that failed
# before creating it committed nothing, so verify/release/abandon skip that
# branch's tip check rather than holding the checkout forever.
# Status is read-only, never reveals the token, and reports an incomplete or
# unreadable record as ownership=unresolved. A token alone proves no exit.
# check is the read-only gate the OTHER local-checkout mutators call before
# they touch the checkout (pr-shepherd's teardown.sh and merge-shepherd.sh; the
# repo-cleanup prose uses status). It exits 0 when no guard exists, or when the
# guard is in phase held/completed AND the token in the environment variable
# SASSY_DOG_CHECKOUT_TOKEN matches it for this checkout. The token is read from
# the environment and never from argv, so it is not visible in `ps`; a --token
# on argv is accepted and ignored on purpose, so a caller cannot believe it
# authenticated by passing one. It takes no mutex and writes nothing (the mutex
# file is created on open). A live writer exits 3 whatever token is presented,
# since even the holder must not move the checkout under its own worker; every
# other refusal (no/wrong token, unresolved or unreadable state) exits 4. The
# refusal JSON carries ownership, phase and the guard path, never the token.
# `run` removes SASSY_DOG_CHECKOUT_TOKEN from the worker's environment, so a caller
# that exported it still does not hand the worker the way past the gate. Callers
# should scope it per call anyway (`SASSY_DOG_CHECKOUT_TOKEN=... bash teardown.sh`).
# Without Python 3, `check` and `status` still answer "no guard" (a filesystem
# fact) with the same JSON; a guard that exists fails closed, exit 4.
#
# Exit codes:
#   0  command succeeded (status may report held/unresolved; inspect its JSON)
#   3  checkout active writer / existing ownership / concurrent guard operation
#      (check: a live writer only)
#   4  checkout ownership unresolved, wrong token/checkout, or unsafe lifecycle
#      (check: no token, wrong token, or unresolved state)
#   5  dirty, in-progress Git operation, missing branch, or unpushed work
#   6  Git/process/filesystem inspection failed; no safety proof obtained
#  20  worker exited nonzero, with termination positively verified
#  21  timeout: guard retained, regardless of subsequent worker termination
#  22  interruption: guard retained, regardless of subsequent worker termination
#  64  invalid usage (including unavailable Python 3)
# No command stashes, resets, deletes branches, switches or pushes. An object
# fetch under durable ownership may establish remote ancestry before a later ff.
set -euo pipefail
# The guard's directory name is owned HERE and handed to the Python below, so the
# no-Python fallback and the real implementation cannot disagree about it.
export CHECKOUT_GUARD_DIR_NAME="sassy-dog-checkout-guard"
if ! command -v python3 >/dev/null 2>&1; then
  # Without Python 3 the guard cannot be read, but whether one EXISTS is a plain
  # filesystem fact. `check` and `status` answer that much so a host with no
  # Python and no guard behaves exactly as before the guard existed; a guard that
  # is present there fails closed (exit 4), never open. Everything else is 64.
  json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  sub="${1:-}" repo=""
  if [ "$sub" = check ] || [ "$sub" = status ]; then
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:-}"; shift 2 || break ;;
        --token) shift 2 || break ;;
        *) shift ;;
      esac
    done
    top="" common=""
    if [ -n "$repo" ] && top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
       && common="$(git -C "$top" rev-parse --git-common-dir 2>/dev/null)"; then
      case "$common" in /*) : ;; *) common="$top/$common" ;; esac
      if common="$(cd -P "$common" 2>/dev/null && pwd -P)"; then
        top="$(cd -P "$top" && pwd -P)"
        guard="$common/$CHECKOUT_GUARD_DIR_NAME"
        if [ -L "$guard" ] || [ -e "$guard" ]; then
          printf '{"exit_code":4,"guard":"%s","ownership":"unresolved","reason":"checkout ownership unresolved: a guard exists but Python 3 is required to read it","repo":"%s","result":"refused"}\n' \
            "$(json_str "$guard")" "$(json_str "$top")"
          exit 4
        fi
        if [ "$sub" = check ]; then
          printf '{"check":"no-guard","guard":"%s","ownership":"free","repo":"%s","result":"ok"}\n' \
            "$(json_str "$guard")" "$(json_str "$top")"
        else
          printf '{"guard":"%s","ownership":"free","repo":"%s","result":"free"}\n' \
            "$(json_str "$guard")" "$(json_str "$top")"
        fi
        exit 0
      fi
    fi
  fi
  printf '%s\n' '{"result":"refused","reason":"Python 3 is required","exit_code":64}'
  exit 64
fi
exec python3 -I - "$@" <<'PY'
import argparse
import errno
import fcntl
import hmac
import json
import math
import os
import select
import signal
import stat
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager


class Refusal(Exception):
    def __init__(self, code, reason, extra=None):
        self.code = code
        self.reason = reason
        self.extra = extra or {}
        super().__init__(reason)


def same_token(recorded, presented):
    # Bytes, not str: compare_digest raises TypeError on a non-ASCII str, and an
    # environment token is attacker-shaped input. surrogateescape round-trips
    # whatever the OS handed over, so no input can crash the comparison.
    return hmac.compare_digest(recorded.encode("utf-8", "surrogateescape"),
                               presented.encode("utf-8", "surrogateescape"))


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal(64, message)


def arguments():
    parser = Parser(description="Durable checkout ownership; no force unlock")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("acquire", "status", "check", "run", "verify", "release", "abandon"):
        command = commands.add_parser(name)
        command.add_argument("--repo", required=True)
        if name == "acquire":
            command.add_argument("--owner", required=True)
        if name == "check":
            # Accepted and never read: the token comes from the environment only.
            command.add_argument("--token", help=argparse.SUPPRESS)
        if name in ("run", "verify", "release"):
            command.add_argument("--token", required=True)
        if name == "abandon":
            command.add_argument("--reason", required=True)
            command.add_argument("--investigated", action="store_true")
        if name == "run":
            command.add_argument("--branch", required=True)
            command.add_argument("--timeout", type=float)
            command.add_argument("worker", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == "acquire" and not args.owner.strip():
        raise Refusal(64, "--owner must be a unique nonempty coordinator identity")
    if args.command == "abandon" and not args.reason.strip():
        raise Refusal(64, "--reason must say why the owner is known to be gone")
    if args.command == "run":
        if not args.worker or args.worker[0] != "--" or len(args.worker) == 1:
            raise Refusal(64, "run requires -- followed by an actual foreground command")
        args.worker = args.worker[1:]
        if args.timeout is not None and (not math.isfinite(args.timeout) or args.timeout <= 0):
            raise Refusal(64, "--timeout must be a positive finite number of seconds")
    return args


def command(argv, cwd=None, accepted=(0,)):
    environment = dict(os.environ, LC_ALL="C", GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    try:
        result = subprocess.run(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                encoding="utf-8", errors="strict", timeout=30)
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        raise Refusal(6, "inspection failed: {}: {}".format(argv[0], error)) from error
    if result.returncode not in accepted:
        raise Refusal(6, "inspection failed: {}: {}".format(" ".join(argv), result.stderr.strip()))
    return result


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def require_directory(path):
    if not stat.S_ISDIR(os.lstat(path).st_mode):
        raise Refusal(4, "checkout ownership unresolved: not a real directory: " + path)


def processes():
    text = command(["ps", "-ax", "-o", "pid=", "-o", "ppid=", "-o", "pgid=",
                    "-o", "stat=", "-o", "lstart="]).stdout
    rows = {}
    try:
        for line in text.splitlines():
            fields = line.split(None, 4)
            if len(fields) != 5 or not fields[3] or not fields[4]:
                raise ValueError("incomplete process row")
            pid, parent, group = map(int, fields[:3])
            rows[pid] = {"pid": pid, "ppid": parent, "pgid": group,
                         "stat": fields[3], "started": fields[4]}
    except ValueError as error:
        raise Refusal(6, "process inspection returned an unreadable process table") from error
    if os.getpid() not in rows:
        raise Refusal(6, "process inspection omitted the supervisor")
    return rows


def identity(row):
    return {"pid": row["pid"], "started": row["started"]}


def live(row):
    return row is not None and not row["stat"].startswith("Z")


class Guard:
    def __init__(self, repo):
        self.repo = command(["git", "-C", repo, "rev-parse", "--show-toplevel"]).stdout.strip()
        self.repo = os.path.realpath(self.repo)
        common = self.git("rev-parse", "--git-common-dir").stdout.strip()
        self.common = os.path.realpath(os.path.join(self.repo, common))
        name = os.environ["CHECKOUT_GUARD_DIR_NAME"]
        self.path = os.path.join(self.common, name)
        self.state_path = os.path.join(self.path, "state.json")
        self.mutex_path = os.path.join(self.common, name + ".lock")
        self.state = None

    def git(self, *argv, accepted=(0,)):
        return command(["git", "-C", self.repo] + list(argv), accepted=accepted)

    @contextmanager
    def mutex(self):
        descriptor = os.open(self.mutex_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise Refusal(4, "checkout ownership unresolved: invalid mutex")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno in (errno.EACCES, errno.EAGAIN):
                    raise Refusal(3, "checkout active writer: guard operation is in progress") from error
                raise
            # CLOEXEC prevents a foreground worker from inheriting ownership.
            yield descriptor
        finally:
            os.close(descriptor)

    def read_state(self):
        require_directory(self.path)
        descriptor = os.open(self.state_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise Refusal(4, "checkout ownership unresolved: invalid state file")
            with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
                descriptor = None
                state = json.load(stream)
        except (ValueError, UnicodeError) as error:
            raise Refusal(4, "checkout ownership unresolved: unreadable state") from error
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if (not isinstance(state, dict) or state.get("version") != 1
                or not isinstance(state.get("token"), str)
                or not isinstance(state.get("repo"), str)
                or not isinstance(state.get("owner"), str)
                or not isinstance(state.get("runs"), list)
                or state.get("phase") not in ("held", "launching", "running", "completed",
                                              "interrupted", "timed-out", "uncertain", "released")):
            raise Refusal(4, "checkout ownership unresolved: invalid state schema")
        self.state = state
        return state

    def save(self):
        self.state["updated_at"] = time.time()
        temporary = os.path.join(self.path, "state.tmp-" + uuid.uuid4().hex)
        descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(self.state, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.state_path)
        sync_directory(self.path)

    def public(self):
        return {key: value for key, value in self.state.items() if key != "token"}

    def authenticate(self, token):
        try:
            self.read_state()
        except OSError as error:
            raise Refusal(4, "checkout ownership unresolved: guard state is unavailable") from error
        if not same_token(self.state["token"], token):
            raise Refusal(4, "checkout ownership unresolved: token does not own this guard")
        if self.state["repo"] != self.repo:
            raise Refusal(4, "checkout ownership belongs to another worktree: " + self.state["repo"])

    def clean(self):
        for name in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge",
                     "rebase-apply", "sequencer", "BISECT_LOG", "index.lock"):
            path = self.git("rev-parse", "--git-path", name).stdout.strip()
            if os.path.lexists(os.path.join(self.repo, path)):
                raise Refusal(5, "checkout has an unfinished Git operation: " + name)
        if self.git("status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none").stdout:
            raise Refusal(5, "checkout is dirty; retained without stash, reset or cleanup")

    def local_tip(self, branch):
        result = self.git("rev-parse", "--verify", "refs/heads/" + branch + "^{commit}", accepted=(0, 128))
        if result.returncode:
            raise Refusal(5, "recorded local branch is missing: " + branch)
        return result.stdout.strip()

    def remote_tip(self, remote, ref):
        result = self.git("ls-remote", "--exit-code", "--refs", remote, ref, accepted=(0, 2))
        matches = [line.split() for line in result.stdout.splitlines()]
        matches = [parts for parts in matches if len(parts) == 2 and parts[1] == ref]
        if result.returncode == 2 or len(matches) != 1:
            raise Refusal(5, "no unique fresh remote tip for " + remote + " " + ref)
        return matches[0][0]

    def current_pushed(self):
        result = self.git("symbolic-ref", "--quiet", "--short", "HEAD", accepted=(0, 1))
        if result.returncode:
            raise Refusal(5, "detached checkout is not a verified pushed starting branch")
        branch = result.stdout.strip()
        upstream = self.git("for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)",
                            "refs/heads/" + branch).stdout.rstrip("\n").split("\0")
        if len(upstream) != 2:
            raise Refusal(6, "cannot determine checkout upstream")
        remote, ref = upstream
        if not remote and not ref:
            remote, ref = "origin", "refs/heads/" + branch
        if not remote or remote == "." or not ref.startswith("refs/heads/"):
            raise Refusal(5, "checkout has no independently verifiable remote upstream")
        local = self.local_tip(branch)
        fresh = self.remote_tip(remote, ref)
        if local != fresh:
            known = self.git("cat-file", "-e", fresh + "^{commit}", accepted=(0, 1, 128))
            if known.returncode:
                self.git("fetch", "--no-tags", "--no-write-fetch-head", "--refmap=",
                         "--no-recurse-submodules", remote, ref)
                fresh = self.remote_tip(remote, ref)
            published = self.git("merge-base", "--is-ancestor", local, fresh, accepted=(0, 1))
            if published.returncode:
                raise Refusal(5, "checkout contains unpublished/diverged commits; retained branch " + branch)
        return {"branch": branch, "local": local, "remote": fresh, "upstream": remote + "/" + ref}

    def verify(self):
        if self.state["phase"] not in ("held", "completed"):
            raise Refusal(4, "checkout ownership unresolved: phase " + self.state["phase"]
                          + "; operator investigation required, not elapsed-time reclamation")
        return self.evidence()

    @staticmethod
    def recorded_identities(run):
        identities = [run[key] for key in ("supervisor", "child") if run.get(key) is not None]
        for key in ("observed_descendants", "remaining_processes"):
            value = run.get(key, [])
            if not isinstance(value, list):
                raise Refusal(4, "checkout ownership unresolved: invalid " + key)
            identities.extend(value)
        for value in identities:
            if (not isinstance(value, dict) or not isinstance(value.get("pid"), int)
                    or not isinstance(value.get("started"), str)):
                raise Refusal(4, "checkout ownership unresolved: invalid process identity")
        return identities

    def evidence(self, attested=False):
        rows = processes()
        branches = []
        for run in self.state["runs"]:
            if attested:
                # The operator attests to termination; the live checks remain.
                if not isinstance(run, dict) or not isinstance(run.get("branch"), str):
                    raise Refusal(4, "checkout ownership unresolved: invalid run record")
                groups = run.get("process_groups", [])
                if (not isinstance(groups, list)
                        or any(not isinstance(group, int) or group <= 1 for group in groups)):
                    raise Refusal(4, "checkout ownership unresolved: invalid process group")
                if any(live(row) and row["pgid"] in groups for row in rows.values()):
                    raise Refusal(4, "checkout active writer: recorded worker process group exists")
                for recorded in self.recorded_identities(run):
                    row = rows.get(recorded["pid"])
                    if live(row) and identity(row) == recorded:
                        raise Refusal(4, "checkout active writer: recorded process is alive: "
                                      + str(recorded["pid"]))
                if run["branch"] not in branches:
                    branches.append(run["branch"])
                continue
            if (not isinstance(run, dict) or run.get("phase") != "completed"
                    or run.get("termination_verified") is not True
                    or not isinstance(run.get("worker_exit"), int)
                    or not isinstance(run.get("branch"), str)
                    or not isinstance(run.get("process_groups"), list)
                    or not run["process_groups"]
                    or any(not isinstance(group, int) or group <= 1
                           for group in run["process_groups"])
                    or not isinstance(run.get("observed_descendants"), list)):
                raise Refusal(4, "checkout ownership unresolved: no durable worker termination proof")
            if any(live(row) and row["pgid"] in run["process_groups"] for row in rows.values()):
                raise Refusal(4, "checkout active writer: recorded worker process group exists")
            for descendant in run["observed_descendants"]:
                if not isinstance(descendant, dict) or not isinstance(descendant.get("pid"), int):
                    raise Refusal(4, "checkout ownership unresolved: invalid descendant identity")
                row = rows.get(descendant["pid"])
                if live(row) and identity(row) == descendant:
                    raise Refusal(4, "checkout active writer: recorded descendant is alive")
            if run["branch"] not in branches:
                branches.append(run["branch"])
        self.clean()
        verified = []
        for branch in branches:
            present = self.git("rev-parse", "--verify", "--quiet",
                               "refs/heads/" + branch + "^{commit}", accepted=(0, 1))
            runs = [run for run in self.state["runs"] if run.get("branch") == branch]
            if present.returncode and all("branch_before" in run and run["branch_before"] is None
                                          for run in runs):
                # Absent before every launch and absent now: nothing was committed.
                verified.append({"branch": branch, "local": None, "remote": None,
                                 "created": False})
                continue
            local = self.local_tip(branch)
            fresh = self.remote_tip("origin", "refs/heads/" + branch)
            if local != fresh:
                raise Refusal(5, "unpushed or diverged work retained on branch " + branch)
            verified.append({"branch": branch, "local": local, "remote": fresh})
        # Also protect coordinator commits and zero-worker completion.
        current = self.current_pushed()
        return {"verified_branches": verified, "current_branch": current}

    def acquire(self, owner):
        with self.mutex():
            if os.path.lexists(self.path):
                raise Refusal(3, "checkout active writer or checkout ownership unresolved: existing guard")
            self.clean()
            # Publish durable ownership before an ancestry probe can fetch.
            os.mkdir(self.path, 0o700)
            sync_directory(self.common)
            self.state = {"version": 1, "repo": self.repo, "guard": self.path, "owner": owner,
                          "token": uuid.uuid4().hex + uuid.uuid4().hex, "phase": "uncertain",
                          "created_at": time.time(), "initial_branch": None, "runs": []}
            self.save()
            try:
                initial = self.current_pushed()
            except Refusal as refusal:
                # No token has left this process and no worker exists, so the
                # rollback loses nothing; a retained ownerless guard would refuse
                # every later caller with nobody able to release it.
                receipt = self.archive(phase="acquire-refused", refused_at=time.time(),
                                       refused_reason=refusal.reason)
                self.state = None
                raise Refusal(refusal.code, refusal.reason + "; guard rolled back to "
                              + receipt) from refusal
            self.state.update(phase="held", initial_branch=initial)
            self.save()
            emit(dict(self.state, result="acquired"))

    def ownership(self):
        phase = self.state["phase"]
        ownership = "held" if phase in ("held", "completed") else "unresolved"
        if phase in ("launching", "running") and self.state["runs"]:
            supervisor = self.state["runs"][-1].get("supervisor", {})
            row = processes().get(supervisor.get("pid"))
            if live(row) and identity(row) == supervisor:
                ownership = "active"
        return ownership

    def check(self):
        if not os.path.lexists(self.path):
            emit({"result": "ok", "check": "no-guard", "ownership": "free",
                  "repo": self.repo, "guard": self.path})
            return
        unresolved = {"ownership": "unresolved"}
        try:
            self.read_state()
            ownership = self.ownership()
        except (Refusal, OSError, ValueError, TypeError, AttributeError) as error:
            raise Refusal(4, "checkout ownership unresolved: guard state is unavailable: "
                          + str(error), unresolved) from error
        extra = {"ownership": ownership}
        if ownership == "active":
            raise Refusal(3, "checkout active writer: a recorded worker is running", extra)
        token = os.environ.get("SASSY_DOG_CHECKOUT_TOKEN", "")
        if not token or not same_token(self.state["token"], token):
            raise Refusal(4, "checkout ownership held: SASSY_DOG_CHECKOUT_TOKEN is missing or"
                          " does not own this guard", extra)
        if self.state["repo"] != self.repo:
            raise Refusal(4, "checkout ownership belongs to another worktree: "
                          + self.state["repo"], extra)
        if self.state["phase"] not in ("held", "completed"):
            raise Refusal(4, "checkout ownership unresolved: phase " + self.state["phase"], extra)
        emit({"result": "ok", "check": "token-owner", "ownership": ownership,
              "phase": self.state["phase"], "repo": self.repo, "guard": self.path})

    def status(self):
        if not os.path.lexists(self.path):
            emit({"result": "free", "ownership": "free", "repo": self.repo, "guard": self.path})
            return
        try:
            self.read_state()
            ownership = self.ownership()
            created = self.state.get("created_at")
            age = (round(time.time() - created)
                   if isinstance(created, (int, float)) and math.isfinite(created) else None)
            emit(dict(self.public(), result="held", ownership=ownership, age_seconds=age))
        except (Refusal, OSError, ValueError, TypeError, AttributeError) as error:
            emit({"result": "held", "ownership": "unresolved", "repo": self.repo,
                  "guard": self.path, "reason": str(error)})

    def history(self):
        history = os.path.join(self.common, "sassy-dog-checkout-history")
        try:
            os.mkdir(history, 0o700)
        except FileExistsError:
            require_directory(history)
        return history

    def archive(self, **fields):
        history = self.history()
        receipt = os.path.join(history, self.state["token"])
        if os.path.lexists(receipt):
            raise Refusal(4, "checkout ownership unresolved: receipt already exists")
        self.state.update(fields)
        self.save()
        # Same filesystem + mutex: there is no partially removed reusable guard.
        os.rename(self.path, receipt)
        sync_directory(history)
        sync_directory(self.common)
        return receipt

    def release(self):
        verified = self.verify()
        receipt = self.archive(phase="released", released_at=time.time(), **verified)
        emit(dict(self.public(), result="released", receipt=receipt))

    def abandon(self, reason, investigated):
        with self.mutex():
            if not os.path.lexists(self.path):
                emit({"result": "free", "ownership": "free", "repo": self.repo, "guard": self.path})
                return
            try:
                self.read_state()
            except (Refusal, OSError) as error:
                if not investigated:
                    raise Refusal(4, "checkout ownership unresolved: guard state is unreadable;"
                                  " investigate, then abandon --investigated") from error
                self.abandon_unreadable(reason, str(error))
                return
            phase = self.state["phase"]
            orphaned_acquire = phase == "uncertain" and not self.state["runs"]
            if phase not in ("held", "completed") and not orphaned_acquire and not investigated:
                raise Refusal(4, "checkout ownership unresolved: phase " + phase
                              + " needs investigation of the recorded processes and retained"
                              " work, then abandon --investigated")
            if self.state["repo"] != self.repo:
                raise Refusal(4, "checkout ownership belongs to another worktree: "
                              + self.state["repo"])
            evidence = self.evidence(attested=investigated)
            receipt = self.archive(phase="abandoned", abandoned_from=phase,
                                   abandoned_reason=reason, investigated=investigated,
                                   abandoned_at=time.time(), **evidence)
            emit(dict(self.public(), result="abandoned", receipt=receipt))

    def abandon_unreadable(self, reason, cause):
        # No identities can be checked, so only the operator's attestation,
        # a clean tree and a published current branch stand behind this.
        require_directory(self.path)
        self.clean()
        current = self.current_pushed()
        receipt = os.path.join(self.history(), "unreadable-" + uuid.uuid4().hex)
        note = {"phase": "abandoned", "abandoned_from": "unreadable", "unreadable_cause": cause,
                "abandoned_reason": reason, "investigated": True, "abandoned_at": time.time(),
                "current_branch": current, "repo": self.repo}
        temporary = os.path.join(self.path, "abandon.tmp-" + uuid.uuid4().hex)
        descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(note, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, os.path.join(self.path, "abandon.json"))
        sync_directory(self.path)
        os.rename(self.path, receipt)
        sync_directory(os.path.dirname(receipt))
        sync_directory(self.common)
        emit(dict(note, result="abandoned", receipt=receipt, guard=self.path))

    def run(self, args, mutex_descriptor):
        self.verify()
        if args.branch.startswith("-") or args.branch == "HEAD":
            raise Refusal(64, "--branch must name an ordinary local branch")
        if self.git("check-ref-format", "refs/heads/" + args.branch, accepted=(0, 1)).returncode:
            raise Refusal(64, "--branch is not a valid branch name")
        before = self.git("rev-parse", "--verify", "--quiet",
                          "refs/heads/" + args.branch + "^{commit}", accepted=(0, 1))
        branch_before = before.stdout.strip() if before.returncode == 0 else None
        supervisor = identity(processes()[os.getpid()])
        interrupted = []

        def on_signal(number, _frame):
            if not interrupted:
                interrupted.append(number)

        previous = {}
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[number] = signal.signal(number, on_signal)
        run = {"branch": args.branch, "branch_before": branch_before,
               "phase": "launching", "supervisor": supervisor,
               "command": args.worker, "started_at": time.time(), "termination_verified": False,
               "observed_descendants": [], "process_groups": []}
        self.state["runs"].append(run)
        self.state["phase"] = "launching"
        self.save()
        authorize_read, authorize_write = os.pipe()
        ready_read, ready_write = os.pipe()
        child = None
        reaped = False
        started = time.monotonic()
        deadline = started + args.timeout if args.timeout is not None else None
        cause = None
        stop_at = None
        kill_sent = False
        known = {}
        worker_exit = None
        try:
            child = os.fork()
            if child == 0:
                try:
                    os.close(authorize_write)
                    os.close(ready_read)
                    os.close(mutex_descriptor)
                    for number in previous:
                        signal.signal(number, signal.SIG_DFL)
                    # The holder's check token must not reach the worker it supervises.
                    os.environ.pop("SASSY_DOG_CHECKOUT_TOKEN", None)
                    os.setsid()
                    os.write(ready_write, b"R")
                    os.close(ready_write)
                    authorization = os.read(authorize_read, 1)
                    os.close(authorize_read)
                    if authorization != b"G":
                        os._exit(125)
                    os.chdir(self.repo)
                    descriptor = os.open(os.devnull, os.O_RDONLY)
                    os.dup2(descriptor, 0)
                    os.close(descriptor)
                    os.dup2(2, 1)
                    os.execvp(args.worker[0], args.worker)
                except BaseException as error:
                    os.write(2, ("checkout-guard: worker launch failed: " + str(error) + "\n").encode())
                    os._exit(127)
            os.close(authorize_read)
            authorize_read = None
            os.close(ready_write)
            ready_write = None
            ready = False
            while not ready:
                if interrupted:
                    cause = "interrupted"
                    break
                if deadline is not None and time.monotonic() >= deadline:
                    cause = "timed-out"
                    break
                if select.select([ready_read], [], [], 0.1)[0]:
                    if os.read(ready_read, 1) != b"R":
                        raise Refusal(4, "worker could not establish a supervised process group")
                    ready = True
            if ready:
                rows = processes()
                row = rows.get(child)
                if not live(row) or row["pgid"] != child:
                    raise Refusal(4, "worker launch identity could not be verified")
                run.update(child=identity(row), pgid=child, process_groups=[child], phase="running")
                self.state["phase"] = "running"
                self.save()
                if not interrupted and (deadline is None or time.monotonic() < deadline):
                    os.write(authorize_write, b"G")
                else:
                    cause = "interrupted" if interrupted else "timed-out"
            os.close(authorize_write)
            authorize_write = None
            while True:
                now = time.monotonic()
                if cause is None:
                    if interrupted:
                        cause = "interrupted"
                    elif deadline is not None and now >= deadline:
                        cause = "timed-out"
                if cause is not None and stop_at is None:
                    run.update(phase=cause, interruption_signal=interrupted[0] if interrupted else None)
                    self.state["phase"] = cause
                    self.save()
                    stop_at = now
                    try:
                        # Before readiness the child is still gated: address only
                        # the unreaped child, never the coordinator's own group.
                        if ready:
                            os.killpg(child, signal.SIGTERM)
                        else:
                            os.kill(child, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                rows = processes()
                descendants = {child} | {pid for pid, row in rows.items()
                                         if row["pgid"] in run["process_groups"]}
                changed = True
                while changed:
                    changed = False
                    for pid, row in rows.items():
                        if row["ppid"] in descendants and pid not in descendants:
                            descendants.add(pid)
                            changed = True
                changed = False
                for pid in descendants:
                    row = rows.get(pid)
                    if row is not None and pid != child:
                        key = (pid, row["started"])
                        if key not in known:
                            known[key] = identity(row)
                            changed = True
                        if row["pgid"] not in run["process_groups"]:
                            run["process_groups"].append(row["pgid"])
                            changed = True
                if changed:
                    run["observed_descendants"] = list(known.values())
                    self.save()
                waited, status = os.waitpid(child, os.WNOHANG)
                if waited:
                    reaped = True
                    worker_exit = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
                    break
                if stop_at is not None and now - stop_at >= 5 and not kill_sent:
                    if ready:
                        os.killpg(child, signal.SIGKILL)
                    else:
                        os.kill(child, signal.SIGKILL)
                    kill_sent = True
                time.sleep(0.1)
            rows = processes()
            remaining = [identity(row) for row in rows.values()
                         if live(row) and (row["pgid"] in run["process_groups"]
                                          or (row["pid"], row["started"]) in known)]
            terminated = not remaining
            if interrupted and cause is None:
                cause = "interrupted"
            phase = cause or ("completed" if terminated else "uncertain")
            run.update(phase=phase, worker_exit=worker_exit, reaped=True,
                       termination_verified=terminated, remaining_processes=remaining,
                       finished_at=time.time())
            self.state["phase"] = phase
            self.save()
            if phase != "completed":
                code = {"timed-out": 21, "interrupted": 22}.get(phase, 4)
                raise Refusal(code, "checkout ownership unresolved: " + phase
                              + "; guard and work retained for operator investigation")
            emit(dict(self.public(), result="completed" if worker_exit == 0 else "worker-failed",
                      worker_exit=worker_exit, termination_verified=True))
            return 0 if worker_exit == 0 else 20
        except BaseException:
            if self.state["phase"] in ("launching", "running"):
                run.update(phase="uncertain", reaped=reaped, worker_exit=worker_exit)
                self.state["phase"] = "uncertain"
                self.save()
            raise
        finally:
            for descriptor in (authorize_read, authorize_write, ready_read, ready_write):
                if descriptor is not None:
                    os.close(descriptor)
            for number, handler in previous.items():
                signal.signal(number, handler)


def main():
    guard = None
    try:
        args = arguments()
        guard = Guard(args.repo)
        if args.command == "status":
            guard.status()
        elif args.command == "check":
            guard.check()
        elif args.command == "acquire":
            guard.acquire(args.owner)
        elif args.command == "abandon":
            guard.abandon(args.reason, args.investigated)
        else:
            with guard.mutex() as descriptor:
                guard.authenticate(args.token)
                if args.command == "run":
                    return guard.run(args, descriptor)
                if args.command == "verify":
                    emit(dict(guard.public(), result="verified", **guard.verify()))
                else:
                    guard.release()
        return 0
    except (Refusal, OSError, ValueError) as error:
        code = error.code if isinstance(error, Refusal) else 6
        report = {"result": "refused", "reason": str(error), "exit_code": code}
        if isinstance(error, Refusal):
            report.update(error.extra)
        if guard is not None:
            report.update(repo=guard.repo, guard=guard.path)
            if guard.state is not None:
                report.update(phase=guard.state["phase"], runs=guard.state["runs"])
        emit(report)
        return code


sys.exit(main())
PY
