"""Behavioral tests for the shipped checkout guard, using real processes and Git.

No model, network, GitHub, operator configuration, or source-text assertions.
The model-driven dispatcher evidence lives in docs/HARNESS-PORTABILITY.md.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "skills/pr-shepherd/scripts/checkout-guard.sh"


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="checkout-guard-test-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / "consumer"
        self.remote = self.home / "remote.git"
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0")
        self.env.pop("SASSY_DOG_CHECKOUT_TOKEN", None)
        self.git("init", "--bare", str(self.remote), cwd=self.home)
        self.git("init", "-b", "main", str(self.repo), cwd=self.home)
        self.git("config", "user.name", "Scratch")
        self.git("config", "user.email", "scratch@example.invalid")
        (self.repo / "payload").write_text("base\n")
        self.git("add", "payload")
        self.git("commit", "-m", "base")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-u", "origin", "main")
        self.children = []
        self.addCleanup(self.stop_children)

    def git(self, *args, cwd=None):
        return subprocess.check_output(["git", *args], cwd=cwd or self.repo,
                                       env=self.env, stderr=subprocess.DEVNULL, text=True).strip()

    def call(self, command, *args, repo=None, guard=None, env=None):
        return subprocess.run(["bash", str(guard or GUARD), command, "--repo", str(repo or self.repo), *args],
                              env=env or self.env, capture_output=True, text=True, timeout=20)

    def acquire(self):
        result = self.call("acquire", "--owner", self.id())
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return json.loads(result.stdout)["token"]

    def denied(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def worker(self, token, branch="fix/one", push=True, exit_code=0, blocking=False):
        marker = self.home / (branch.replace("/", "-") + ".started")
        proceed = self.home / (branch.replace("/", "-") + ".continue")
        script = self.home / (branch.replace("/", "-") + ".py")
        script.write_text("import pathlib, subprocess, time, sys\n"
                          "def git(*a): subprocess.run(['git', *a], check=True)\n"
                          f"git('switch', '-c', {branch!r}, 'origin/main')\n"
                          "pathlib.Path('payload').write_text('worker commit\\n')\n"
                          "git('add', 'payload')\ngit('commit', '-m', 'worker')\n"
                          f"pathlib.Path({str(marker)!r}).write_text('running')\n"
                          + (f"while not pathlib.Path({str(proceed)!r}).exists(): time.sleep(.02)\n" if blocking else "")
                          + (f"git('push', '-u', 'origin', {branch!r})\n" if push else "")
                          + f"sys.exit({exit_code})\n")
        process = subprocess.Popen(["bash", str(GUARD), "run", "--repo", str(self.repo),
                                    "--token", token, "--branch", branch, "--", sys.executable,
                                    str(script)], env=self.env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        self.children.append(process)
        return process, marker, proceed

    def state_path(self):
        return Path(self.git("rev-parse", "--absolute-git-dir")) / "sassy-dog-checkout-guard" / "state.json"

    def tamper(self, **fields):
        path = self.state_path()
        state = json.loads(path.read_text())
        state.update(fields)
        path.write_text(json.dumps(state))
        return state

    def identity_of(self, pid):
        # Parsed exactly as the guard parses `ps`, so the recorded identity matches.
        for line in subprocess.check_output(["ps", "-ax", "-o", "pid=", "-o", "ppid=", "-o", "pgid=",
                                             "-o", "stat=", "-o", "lstart="], text=True).splitlines():
            fields = line.split(None, 4)
            if int(fields[0]) == pid:
                return {"pid": pid, "started": fields[4]}
        self.fail(f"pid {pid} not in the process table")

    def wait_for(self, path, process):
        deadline = time.monotonic() + 15
        while not path.exists():
            if process.poll() is not None:
                self.fail(f"worker exited {process.returncode} before {path}")
            if time.monotonic() > deadline:
                self.fail(f"worker never reached {path}")
            time.sleep(.02)

    def stop_children(self):
        # Only test-owned supervisor processes. Worker scripts have a bounded
        # unblock path; interrupted-supervisor tests explicitly release them.
        for process in self.children:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


class Ownership(Scratch):
    def test_published_behind_default_can_reconcile_under_ownership(self):
        old = self.git("rev-parse", "HEAD")
        publisher = self.home / "publisher"
        self.git("clone", "--branch", "main", str(self.remote), str(publisher), cwd=self.home)
        self.git("config", "user.name", "Publisher", cwd=publisher)
        self.git("config", "user.email", "publisher@example.invalid", cwd=publisher)
        (publisher / "payload").write_text("new upstream\n")
        self.git("commit", "-am", "upstream", cwd=publisher)
        self.git("push", "origin", "main", cwd=publisher)
        token = self.acquire()
        self.assertEqual(self.git("rev-parse", "HEAD"), old)
        self.git("fetch", "origin")
        self.git("merge", "--ff-only", "origin/main")
        self.assertEqual((self.repo / "payload").read_text(), "new upstream\n")
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_archived_worker_epoch_survives_server_branch_deletion(self):
        token = self.acquire()
        process, _, _ = self.worker(token)
        self.assertEqual(process.wait(timeout=20), 0)
        self.assertEqual(self.call("verify", "--token", token).returncode, 0)
        self.git("switch", "main")
        receipt = self.call("release", "--token", token)
        self.assertEqual(receipt.returncode, 0, receipt.stdout + receipt.stderr)
        token = self.acquire()
        # Server auto-deletion must not erase the new merge epoch's evidence.
        self.git("push", "origin", "--delete", "fix/one")
        self.assertEqual(self.call("release", "--token", token).returncode, 0)
        token = self.acquire()
        self.assertEqual(self.git("branch", "--show-current"), "main")
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_acquisition_excludes_other_worktree_before_reconciliation(self):
        sibling = self.home / "sibling"
        self.git("worktree", "add", "-b", "other", str(sibling))
        token = self.acquire()
        before = self.git("rev-parse", "HEAD")
        self.denied(self.call("acquire", "--owner", "other-tick", repo=sibling))
        self.assertEqual(before, self.git("rev-parse", "HEAD"))
        self.assertEqual(self.git("branch", "--show-current"), "main")
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_dirty_checkout_never_acquired_or_cleaned(self):
        (self.repo / "payload").write_text("operator work\n")
        self.denied(self.call("acquire", "--owner", "tick"))
        self.assertEqual((self.repo / "payload").read_text(), "operator work\n")

    def test_token_cannot_be_substituted(self):
        token = self.acquire()
        self.denied(self.call("release", "--token", "not-the-owner"))
        self.denied(self.call("acquire", "--owner", "second"))
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_verified_push_releases_for_subsequent_tick(self):
        for branch in ("fix/first", "fix/second"):
            token = self.acquire()
            process, _, _ = self.worker(token, branch)
            self.assertEqual(process.wait(timeout=20), 0)
            local = self.git("rev-parse", f"refs/heads/{branch}")
            remote = self.git("ls-remote", "origin", f"refs/heads/{branch}").split()[0]
            self.assertEqual(local, remote)
            verify = self.call("verify", "--token", token)
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
            self.git("switch", "main")
            result = self.call("release", "--token", token)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unpushed_success_report_retains_only_copy(self):
        token = self.acquire()
        process, _, _ = self.worker(token, push=False)
        process.wait(timeout=20)
        tip = self.git("rev-parse", "HEAD")
        self.denied(self.call("release", "--token", token))
        self.denied(self.call("acquire", "--owner", "next"))
        self.assertEqual(tip, self.git("rev-parse", "HEAD"))
        self.assertEqual(self.git("branch", "--show-current"), "fix/one")
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/fix/one"), "")

    def test_remote_branch_presence_is_not_tip_verification(self):
        token = self.acquire()
        process, _, _ = self.worker(token)
        process.wait(timeout=20)
        # A branch exists remotely, but the worker's newest commit isn't there.
        (self.repo / "payload").write_text("unpublished second commit\n")
        self.git("commit", "-am", "not pushed")
        self.denied(self.call("release", "--token", token))
        self.assertEqual((self.repo / "payload").read_text(), "unpublished second commit\n")

    def test_dirty_failure_is_not_reset_or_switched(self):
        token = self.acquire()
        process, _, _ = self.worker(token, exit_code=1)
        process.wait(timeout=20)
        (self.repo / "payload").write_text("failed unfinished work\n")
        self.denied(self.call("release", "--token", token))
        self.assertEqual(self.git("branch", "--show-current"), "fix/one")
        self.assertEqual((self.repo / "payload").read_text(), "failed unfinished work\n")


    def test_failed_acquire_rolls_back_its_guard(self):
        # A local-only branch fails the post-publish ancestry probe.
        self.git("switch", "-c", "local-only")
        self.denied(self.call("acquire", "--owner", "probe-refused"))
        self.assertEqual(json.loads(self.call("status").stdout)["ownership"], "free")
        self.git("switch", "main")
        self.assertEqual(self.call("release", "--token", self.acquire()).returncode, 0)

    def test_unreachable_origin_acquire_rolls_back(self):
        url = self.git("remote", "get-url", "origin")
        self.git("remote", "set-url", "origin", str(self.home / "missing.git"))
        failed = self.call("acquire", "--owner", "network-blip")
        self.assertEqual(failed.returncode, 6, failed.stdout + failed.stderr)
        self.assertEqual(json.loads(self.call("status").stdout)["ownership"], "free")
        self.git("remote", "set-url", "origin", url)
        self.assertEqual(self.call("release", "--token", self.acquire()).returncode, 0)

    def test_concurrent_acquires_admit_exactly_one_owner(self):
        start = self.home / "go"
        script = ("import os, pathlib, subprocess, sys, time\n"
                  f"while not pathlib.Path({str(start)!r}).exists(): time.sleep(.005)\n"
                  "sys.exit(subprocess.run(['bash', sys.argv[1], 'acquire', '--repo', sys.argv[2],"
                  " '--owner', sys.argv[3]], stdout=subprocess.DEVNULL,"
                  " stderr=subprocess.DEVNULL).returncode)\n")
        racers = [subprocess.Popen([sys.executable, "-c", script, str(GUARD), str(self.repo),
                                    f"racer-{n}"], env=self.env) for n in range(6)]
        self.children.extend(racers)
        time.sleep(.3)
        start.touch()
        codes = sorted(racer.wait(timeout=30) for racer in racers)
        self.assertEqual(codes, [0, 3, 3, 3, 3, 3])

    def test_operator_abandons_owner_that_lost_its_token(self):
        self.acquire()  # the coordinator dies here; its token is gone with it
        self.denied(self.call("acquire", "--owner", "next-tick"))
        self.assertEqual(self.call("abandon").returncode, 64)
        self.assertEqual(self.call("abandon", "--reason", "  ").returncode, 64)
        result = self.call("abandon", "--reason", "owning session closed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["result"], "abandoned")
        self.assertNotIn("token", report)
        receipt = json.loads((Path(report["receipt"]) / "state.json").read_text())
        self.assertEqual((receipt["phase"], receipt["abandoned_from"]), ("abandoned", "held"))
        self.assertEqual(receipt["abandoned_reason"], "owning session closed")
        self.assertEqual(json.loads(self.call("status").stdout)["ownership"], "free")
        self.assertEqual(self.call("release", "--token", self.acquire()).returncode, 0)

    def test_abandon_requires_positive_evidence(self):
        self.acquire()
        (self.repo / "payload").write_text("operator work\n")
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 5)
        self.assertEqual((self.repo / "payload").read_text(), "operator work\n")
        self.git("commit", "-am", "local only")
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 5)
        self.assertEqual(json.loads(self.call("status").stdout)["ownership"], "held")
        self.git("push", "origin", "main")
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 0)

    def test_abandon_phase_predicate_decides_a_run_free_guard(self):
        # With no runs, evidence() has nothing to refuse, so only the phase
        # predicate separates an acquire that died mid-probe from other phases.
        self.acquire()
        state_path = Path(self.git("rev-parse", "--absolute-git-dir")) / "sassy-dog-checkout-guard" / "state.json"
        state = json.loads(state_path.read_text())
        for phase, expected in (("timed-out", 4), ("interrupted", 4), ("uncertain", 0)):
            state_path.write_text(json.dumps(dict(state, phase=phase)))
            result = self.call("abandon", "--reason", "acquire died mid-probe")
            self.assertEqual(result.returncode, expected, phase + ": " + result.stdout)

    def test_caller_directory_cannot_shadow_the_guards_imports(self):
        planted = self.home / "planted"
        planted.mkdir()
        (planted / "uuid.py").write_text("import sys\nsys.exit(99)\n")
        result = subprocess.run(["bash", str(GUARD), "status", "--repo", str(self.repo)],
                                cwd=planted, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["ownership"], "free")

    def test_abandon_on_free_checkout_changes_nothing(self):
        result = self.call("abandon", "--reason", "nothing held")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["result"], "free")


    def test_worker_failing_before_branching_does_not_lock_checkout(self):
        token = self.acquire()
        result = self.call("run", "--token", token, "--branch", "fix/never-created", "--",
                           sys.executable, "-c", "raise SystemExit(1)")
        self.assertEqual(result.returncode, 20, result.stdout + result.stderr)
        verify = self.call("verify", "--token", token)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        self.assertEqual(json.loads(verify.stdout)["verified_branches"][0]["created"], False)
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_branch_that_existed_before_launch_must_still_verify(self):
        self.git("branch", "fix/pre")
        self.git("push", "origin", "fix/pre")
        token = self.acquire()
        result = self.call("run", "--token", token, "--branch", "fix/pre", "--",
                           "git", "branch", "-D", "fix/pre")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.call("verify", "--token", token).returncode, 5)
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 5)

    def test_unpushed_run_branch_commit_blocks_after_switch_to_default(self):
        token = self.acquire()
        process, _, _ = self.worker(token)
        self.assertEqual(process.wait(timeout=20), 0)
        (self.repo / "payload").write_text("later commit, never pushed\n")
        self.git("commit", "-am", "unpushed on run branch")
        self.git("switch", "main")
        # Only the per-branch tip check sees this: the current branch is published.
        self.assertEqual(self.call("verify", "--token", token).returncode, 5)
        self.assertEqual(self.call("release", "--token", token).returncode, 5)
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 5)
        self.assertEqual(self.call("abandon", "--reason", "gone", "--investigated").returncode, 5)
        self.assertNotEqual(self.git("rev-parse", "fix/one"),
                            self.git("ls-remote", "origin", "refs/heads/fix/one").split()[0])

    def test_acquire_refuses_unfinished_operation_detached_head_and_local_upstream(self):
        merge_head = Path(self.git("rev-parse", "--absolute-git-dir")) / "MERGE_HEAD"
        merge_head.write_text(self.git("rev-parse", "HEAD") + "\n")
        self.assertEqual(self.call("acquire", "--owner", "mid-merge").returncode, 5)
        merge_head.unlink()
        self.git("switch", "--detach", "HEAD")
        self.assertEqual(self.call("acquire", "--owner", "detached").returncode, 5)
        self.git("switch", "-c", "tracker", "--track", "main")
        self.assertEqual(self.call("acquire", "--owner", "local-upstream").returncode, 5)
        self.assertEqual(json.loads(self.call("status").stdout)["ownership"], "free")

    def test_verify_phase_gate_and_live_evidence_checks(self):
        token = self.acquire()
        process, _, _ = self.worker(token)
        self.assertEqual(process.wait(timeout=20), 0)
        original = json.loads(self.state_path().read_text())
        run = original["runs"][0]
        # A completed run whose recorded group is (still) live is not verified.
        self.tamper(runs=[dict(run, process_groups=run["process_groups"] + [os.getpgrp()])])
        self.assertEqual(self.call("verify", "--token", token).returncode, 4)
        # Nor is one whose recorded descendant identity is alive.
        alive = self.identity_of(os.getpid())
        self.tamper(runs=[dict(run, observed_descendants=[alive])])
        self.assertEqual(self.call("verify", "--token", token).returncode, 4)
        # With no runs, only the phase gate stops verify on an uncertain guard.
        self.tamper(runs=[], phase="uncertain")
        self.assertEqual(self.call("verify", "--token", token).returncode, 4)
        self.state_path().write_text(json.dumps(original))
        self.assertEqual(self.call("verify", "--token", token).returncode, 0)

    def test_abandon_stays_in_its_own_worktree(self):
        sibling = self.home / "sibling"
        self.git("worktree", "add", "-b", "other", str(sibling))
        self.git("push", "-u", "origin", "other", cwd=sibling)
        result = self.call("acquire", "--owner", "sibling", repo=sibling)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 4)
        self.assertEqual(self.call("abandon", "--reason", "gone", "--investigated").returncode, 4)
        self.assertEqual(self.call("abandon", "--reason", "gone", repo=sibling).returncode, 0)

    def test_unreadable_guard_needs_investigated_abandon(self):
        self.acquire()
        self.state_path().write_text("{not json")
        status = json.loads(self.call("status").stdout)
        self.assertEqual(status["ownership"], "unresolved")
        self.assertEqual(self.call("abandon", "--reason", "corrupt").returncode, 4)
        (self.repo / "payload").write_text("operator work\n")
        self.assertEqual(self.call("abandon", "--reason", "corrupt", "--investigated").returncode, 5)
        self.git("checkout", "--", "payload")
        result = self.call("abandon", "--reason", "corrupt, inspected", "--investigated")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        note = json.loads((Path(json.loads(result.stdout)["receipt"]) / "abandon.json").read_text())
        self.assertEqual((note["abandoned_from"], note["investigated"]), ("unreadable", True))
        self.assertEqual(self.call("release", "--token", self.acquire()).returncode, 0)


class Check(Scratch):
    """`check` is the read-only gate other local-checkout mutators call (#486)."""

    def check(self, token=None, *args, guard=None):
        env = dict(self.env, SASSY_DOG_CHECKOUT_TOKEN=token) if token is not None else None
        return self.call("check", *args, env=env, guard=guard)

    def mutant(self, old, new):
        source = GUARD.read_text()
        self.assertEqual(source.count(old), 1, "mutant anchor drifted: " + old)
        path = self.home / "mutant-guard.sh"
        path.write_text(source.replace(old, new))
        return path

    def snapshot(self):
        git_dir = Path(self.git("rev-parse", "--git-common-dir"))
        git_dir = git_dir if git_dir.is_absolute() else self.repo / git_dir
        return sorted((str(p.relative_to(git_dir)), p.stat().st_mtime_ns)
                      for p in git_dir.rglob("*") if p.is_file())

    def test_no_guard_passes_and_writes_nothing(self):
        before = self.snapshot()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["check"], "no-guard")
        self.assertEqual(self.snapshot(), before)

    def test_matching_environment_token_passes_and_writes_nothing(self):
        token = self.acquire()
        before = self.snapshot()
        result = self.check(token)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_missing_or_wrong_token_is_refused(self):
        token = self.acquire()
        for result in (self.check(), self.check("not-the-owner"), self.check("")):
            self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["ownership"], "held")
            self.assertTrue(report["guard"].endswith("sassy-dog-checkout-guard"))
            self.assertNotIn(token, result.stdout)
        # A mutant that skips the token comparison would admit the stranger.
        mutant = self.mutant("if not token or not hmac.compare_digest(self.state[\"token\"], token):",
                             "if False:")
        self.assertEqual(self.check("not-the-owner", guard=mutant).returncode, 0)
        self.assertEqual(self.check(guard=mutant).returncode, 0)

    def test_token_on_argv_is_ignored(self):
        token = self.acquire()
        result = self.check(None, "--token", token)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        # The environment still wins when both are present and disagree.
        result = self.check("not-the-owner", "--token", token)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        # A mutant that honours argv would accept the first call.
        mutant = self.mutant('token = os.environ.get("SASSY_DOG_CHECKOUT_TOKEN", "")',
                             'token = (sys.argv[sys.argv.index("--token") + 1] if "--token" in sys.argv else "")')
        self.assertEqual(self.check(None, "--token", token, guard=mutant).returncode, 0)

    def test_live_worker_is_refused_even_for_the_holder(self):
        token = self.acquire()
        process, marker, proceed = self.worker(token, blocking=True)
        self.wait_for(marker, process)
        branch = self.git("branch", "--show-current")
        result = self.check(token)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["ownership"], "active")
        self.assertEqual(self.git("branch", "--show-current"), branch)
        # Without the live-writer refusal the code is no longer 3 (the phase
        # gate still refuses, as unresolved), so the distinction is the check's.
        mutant = self.mutant('raise Refusal(3, "checkout active writer: a recorded worker is running", extra)',
                             "pass")
        self.assertNotEqual(self.check(token, guard=mutant).returncode, 3)
        proceed.touch()
        self.assertEqual(process.wait(timeout=20), 0)
        self.assertEqual(self.check(token).returncode, 0)

    def test_unresolved_state_is_refused_even_with_the_token(self):
        token = self.acquire()
        self.tamper(phase="timed-out")
        result = self.check(token)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["ownership"], "unresolved")
        self.state_path().write_text("not json")
        result = self.check(token)
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)


class Lifecycle(Scratch):
    def test_foreground_tool_group_is_verified_after_exit(self):
        token = self.acquire()
        result = self.call("run", "--token", token, "--branch", "main", "--",
                           sys.executable, "-c",
                           "import subprocess, sys; subprocess.run([sys.executable, '-c', "
                           "'import time; time.sleep(.4)'], start_new_session=True, check=True)")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_surviving_tool_group_keeps_checkout_owned(self):
        token = self.acquire()
        pidfile = self.home / "survivor.pid"
        command = ("import subprocess, sys, pathlib, time; "
                   "p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], "
                   "start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                   f"pathlib.Path({str(pidfile)!r}).write_text(str(p.pid)); time.sleep(.4)")
        try:
            result = self.call("run", "--token", token, "--branch", "main", "--",
                               sys.executable, "-c", command)
            self.denied(result)
            self.denied(self.call("release", "--token", token))
            self.denied(self.call("acquire", "--owner", "next-tick"))
        finally:
            if pidfile.exists():
                os.kill(int(pidfile.read_text()), signal.SIGKILL)

    def test_live_worker_excludes_release_and_concurrent_tick(self):
        token = self.acquire()
        process, marker, proceed = self.worker(token, blocking=True)
        self.wait_for(marker, process)
        # Neither a terminal-failure comment nor a clean committed tree proves
        # that the worker exited; only the supervisor owns termination evidence.
        (self.repo / ".git" / "terminal-comment.json").write_text(
            '{"kind":"take-it-terminal-failure","recovery":"finished","pr":null}')
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.denied(self.call("release", "--token", token))
        self.denied(self.call("acquire", "--owner", "concurrent-tick"))
        self.assertEqual(self.git("branch", "--show-current"), "fix/one")
        proceed.touch()
        self.assertEqual(process.wait(timeout=20), 0)
        self.assertEqual(self.call("release", "--token", token).returncode, 0)

    def test_interrupted_supervisor_cannot_release_live_worker(self):
        token = self.acquire()
        process, marker, proceed = self.worker(token, blocking=True)
        self.wait_for(marker, process)
        process.kill()
        process.wait(timeout=10)
        self.denied(self.call("release", "--token", token))
        self.denied(self.call("acquire", "--owner", "later-tick"))
        self.assertEqual(self.git("branch", "--show-current"), "fix/one")
        proceed.touch()
        # Loss of the reaping supervisor is uncertain, even after the worker
        # appears gone. No elapsed-time unlock is allowed.
        self.denied(self.call("release", "--token", token))
        deadline = time.monotonic() + 15
        while not self.git("ls-remote", "origin", "refs/heads/fix/one"):
            if time.monotonic() > deadline:
                self.fail("orphaned worker did not finish its push")
            time.sleep(.02)
        self.denied(self.call("acquire", "--owner", "still-not-proven"))

    def test_timeout_signal_retains_guard(self):
        token = self.acquire()
        process, marker, proceed = self.worker(token, blocking=True)
        self.wait_for(marker, process)
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=10)
        self.denied(self.call("release", "--token", token))
        self.denied(self.call("acquire", "--owner", "timeout-retry"))
        proceed.touch()

    def test_elapsed_runner_timeout_never_expires_ownership(self):
        token = self.acquire()
        result = self.call("run", "--token", token, "--branch", "fix/timeout",
                           "--timeout", "0.4", "--", sys.executable, "-c",
                           "import time; time.sleep(60)")
        self.assertEqual(result.returncode, 21, result.stdout + result.stderr)
        state = json.loads(self.call("status").stdout)
        self.assertEqual(state["phase"], "timed-out")
        self.denied(self.call("release", "--token", token))
        self.denied(self.call("acquire", "--owner", "timer-expired"))

    def test_second_runner_cannot_start_under_same_token(self):
        token = self.acquire()
        process, marker, proceed = self.worker(token, blocking=True)
        self.wait_for(marker, process)
        marker2 = self.home / "second-worker"
        second = self.call("run", "--token", token, "--branch", "fix/two", "--",
                           sys.executable, "-c", f"open({str(marker2)!r}, 'w').write('unsafe')")
        self.denied(second)
        self.assertFalse(marker2.exists())
        proceed.touch()
        self.assertEqual(process.wait(timeout=20), 0)
        self.assertEqual(self.call("release", "--token", token).returncode, 0)


    def test_abandon_cannot_reach_a_live_worker(self):
        token = self.acquire()
        process, marker, proceed = self.worker(token, blocking=True)
        self.wait_for(marker, process)
        self.assertEqual(self.call("abandon", "--reason", "looks stuck").returncode, 3)
        status = json.loads(self.call("status").stdout)
        self.assertEqual(status["ownership"], "active")
        proceed.touch()
        self.assertEqual(process.wait(timeout=20), 0)

    def test_abandon_refuses_timed_out_guard(self):
        token = self.acquire()
        result = self.call("run", "--token", token, "--branch", "fix/timeout",
                           "--timeout", "0.4", "--", sys.executable, "-c",
                           "import time; time.sleep(60)")
        self.assertEqual(result.returncode, 21, result.stdout + result.stderr)
        self.assertEqual(self.call("abandon", "--reason", "timer elapsed").returncode, 4)
        self.assertEqual(json.loads(self.call("status").stdout)["phase"], "timed-out")

    def test_abandon_after_verified_worker_when_coordinator_died(self):
        token = self.acquire()
        process, _, _ = self.worker(token)
        self.assertEqual(process.wait(timeout=20), 0)
        # Coordinator dies before verify/release; the worker's push is real.
        result = self.call("abandon", "--reason", "coordinator crashed after the worker")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["abandoned_from"], "completed")
        self.assertEqual(self.git("branch", "--show-current"), "fix/one")


    def test_investigated_abandon_frees_a_dead_timed_out_run(self):
        token = self.acquire()
        result = self.call("run", "--token", token, "--branch", "fix/timeout",
                           "--timeout", "0.4", "--", sys.executable, "-c",
                           "import time; time.sleep(60)")
        self.assertEqual(result.returncode, 21, result.stdout + result.stderr)
        self.assertEqual(self.call("abandon", "--reason", "timed out").returncode, 4)
        freed = self.call("abandon", "--reason", "timed out; worker reaped", "--investigated")
        self.assertEqual(freed.returncode, 0, freed.stdout + freed.stderr)
        self.assertEqual(json.loads(freed.stdout)["abandoned_from"], "timed-out")
        self.assertEqual(self.call("release", "--token", self.acquire()).returncode, 0)

    def test_investigated_abandon_refuses_a_recorded_process_still_alive(self):
        token = self.acquire()
        process, _, _ = self.worker(token)
        self.assertEqual(process.wait(timeout=20), 0)
        self.git("switch", "main")
        survivor = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        self.children.append(survivor)
        run = json.loads(self.state_path().read_text())["runs"][0]
        # A supervisor killed mid-run leaves a running record naming its child.
        self.tamper(phase="running", runs=[dict(run, phase="running",
                                                child=self.identity_of(survivor.pid),
                                                termination_verified=False)])
        self.assertEqual(self.call("abandon", "--reason", "gone").returncode, 4)
        self.assertEqual(self.call("abandon", "--reason", "gone", "--investigated").returncode, 4)
        survivor.kill()
        survivor.wait()
        record = json.loads(self.state_path().read_text())["runs"][0]
        # A live recorded process GROUP refuses too, even with every pid gone.
        self.tamper(runs=[dict(record, process_groups=[os.getpgrp()])])
        self.assertEqual(self.call("abandon", "--reason", "gone", "--investigated").returncode, 4)
        self.tamper(runs=[record])
        result = self.call("abandon", "--reason", "child confirmed dead", "--investigated")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
