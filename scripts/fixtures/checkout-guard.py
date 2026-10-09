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
GUARD = ROOT / "skills/take-it/scripts/checkout-guard.sh"


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="checkout-guard-test-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / "consumer"
        self.remote = self.home / "remote.git"
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0")
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

    def call(self, command, *args, repo=None):
        return subprocess.run(["bash", str(GUARD), command, "--repo", str(repo or self.repo), *args],
                              env=self.env, capture_output=True, text=True, timeout=20)

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


if __name__ == "__main__":
    unittest.main()
