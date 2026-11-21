#!/usr/bin/env bash
# test-release-lag.sh — actual detector against isolated Git histories (#382).
# A version-line grep misses reformatted releases; last-manifest-touch mistakes
# metadata for releases; earliest-change/last-change ages both fail per-path
# revert/reintroduction. These fixtures discriminate those plausible algorithms,
# plus elapsed threshold boundaries, integration time, normalization and unknown
# evidence. No copied detector, source-text assertions, network or real writes.
# Fixed UTC clocks, private HOME/config and signing disabled isolate user state.
# Every detector call snapshots refs, HEAD, index and worktree bytes/modes, so a
# checker that stamps, repairs history or checks out its ref fails observably.
# The due exit is exercised here, never propagated into the required ci job.
# Run: bash scripts/test-release-lag.sh (also a literal preflight if-bash gate).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$SCRIPT_DIR/check-release-lag.sh" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

CHECKER = sys.argv[1]
UTC = dt.timezone.utc
START = dt.datetime(2026, 9, 1, tzinfo=UTC)
PLUGIN = ".claude-plugin/plugin.json"
MARKET = ".claude-plugin/marketplace.json"


def date(hours):
    return (START + dt.timedelta(hours=hours)).isoformat().replace("+00:00", "Z")


with tempfile.TemporaryDirectory(prefix="release-lag-") as scratch:
    root = Path(scratch)
    home = root / "home"
    home.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home), GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0", LC_ALL="C",
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")

    def git(repo, *args, data=None, hours=0, author_hours=None):
        call_env = dict(env, GIT_AUTHOR_DATE=date(hours if author_hours is None else author_hours),
                        GIT_COMMITTER_DATE=date(hours))
        result = subprocess.run(["git", "-C", str(repo), "-c", "commit.gpgsign=false",
                                 "-c", "tag.gpgsign=false", *args], env=call_env, input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise AssertionError(f"fixture git {args}: {result.stderr.decode()}")
        return result.stdout

    def put(repo, path, value):
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def commit(repo, hours, author_hours=None):
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "--allow-empty", "-m", "fixture", hours=hours,
            author_hours=author_hours)
        return git(repo, "rev-parse", "HEAD").decode().strip()

    def make(name):
        repo = root / name
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main", "--template=")
        git(repo, "config", "core.hooksPath", os.devnull)
        put(repo, PLUGIN, json.dumps(dict(name="fixture", version="2026.9.1", nested={"version": "keep"})))
        put(repo, MARKET, json.dumps(dict(name="market", plugins=[dict(name="fixture", source="./")])))
        for path in ("skills/a/SKILL.md", "agents/a.md", "hooks/a.sh", "scripts/align-labels.sh"):
            put(repo, path, "base\n")
        return repo, commit(repo, 0)

    def snapshot(repo):
        files = {}
        for path in repo.rglob("*"):
            rel = path.relative_to(repo)
            if rel.parts[0] == ".git" or (path.is_dir() and not path.is_symlink()):
                continue
            files[str(rel)] = (stat.S_IMODE(path.lstat().st_mode),
                               os.readlink(path) if path.is_symlink() else path.read_bytes())
        index = repo / ".git/index"
        return (git(repo, "for-each-ref"), git(repo, "rev-parse", "HEAD"),
                (repo / ".git/HEAD").read_bytes(), index.read_bytes() if index.exists() else None, files)

    def invoke(repo, *arguments):
        before = snapshot(repo)
        result = subprocess.run(["bash", CHECKER, "--repo", str(repo), *arguments],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert snapshot(repo) == before, "checker mutated refs/index/worktree"
        return result

    def check(repo, status, now=100, ref="HEAD", baseline=None, paths=None, age=None,
              extra=()):
        result = invoke(repo, "--ref", ref, "--now", date(now), *extra)
        expected_exit = {"clean": 0, "pending": 0, "due": 3, "error": 1}[status]
        assert result.returncode == expected_exit, (status, result.returncode, result.stdout, result.stderr)
        report = json.loads(result.stdout)
        assert report["status"] == status, report
        if baseline is not None:
            assert report["baseline_sha"] == baseline, report
        if paths is not None:
            assert {row["path"]: row["status"] for row in report["changed_paths"]} == paths, report
        assert report["oldest_pending_age_seconds"] == age, report
        if status == "error":
            assert report["error"] and report["changed_paths"] is None, report
        else:
            assert report["error"] is None, report
        print(f"  ok    {repo.name}: {status}, ref {ref}, observation {date(now)}")
        return report

    repo, base = make("normalization-and-age")
    check(repo, "clean", baseline=base, paths={})
    put(repo, "README.md", "repo docs")
    put(repo, "scripts/test-build.sh", "repo gate")
    put(repo, ".github/workflows/example.yml", "repo ci")
    commit(repo, 1)
    # Whitespace, order and same-value plugin writes do not release. Optional
    # marketplace versions disappear; its array ordering remains significant.
    put(repo, PLUGIN, '{"nested": {"version": "keep"},\n"version": "2026.9.1", "name": "fixture"}')
    put(repo, MARKET, '{"plugins":[{"version":"2099.1.9","source":"./","name":"fixture"}],"name":"market"}')
    commit(repo, 2)
    check(repo, "clean", now=24 * 40, baseline=base, paths={})
    put(repo, "skills/a/SKILL.md", "first change")
    first = commit(repo, 10)
    below = check(repo, "pending", now=82 - 1 / 3600, baseline=base,
                  paths={"skills/a/SKILL.md": "modified"}, age=259199)
    assert below["changed_paths"][0]["first_pending_sha"] == first
    assert below["changed_paths"][0]["first_pending_date"] == date(10)
    check(repo, "due", now=82, baseline=base, paths={"skills/a/SKILL.md": "modified"}, age=259200)
    check(repo, "due", now=11, baseline=base, age=3600, extra=("--due-after-hours", "1"))
    put(repo, "skills/a/SKILL.md", "later partial edit")
    commit(repo, 80)
    later = check(repo, "due", now=82, baseline=base, age=259200)
    assert later["changed_paths"][0]["first_pending_sha"] == first
    # A dirty/staged malformed manifest cannot affect committed analysis.
    put(repo, PLUGIN, "not json")
    git(repo, "add", PLUGIN)
    put(repo, PLUGIN, "different unstaged bytes")
    check(repo, "due", now=82, baseline=base, age=259200)
    check(repo, "clean", now=82, ref=base, baseline=base, paths={})
    put(repo, PLUGIN, git(repo, "show", "HEAD:" + PLUGIN).decode())
    put(repo, "skills/a/SKILL.md", "base\n")
    commit(repo, 83)
    check(repo, "clean", now=84, baseline=base, paths={})
    put(repo, "skills/a/SKILL.md", "reintroduced")
    restarted = commit(repo, 90)
    reintroduced = check(repo, "pending", now=100, baseline=base, age=36000)
    assert reintroduced["changed_paths"][0]["first_pending_sha"] == restarted
    put(repo, PLUGIN, '{\n"version"\n:\n"2026.9.2", "name":"fixture", "nested":{"version":"keep"}}')
    release = commit(repo, 101)
    check(repo, "clean", now=102, baseline=release, paths={})
    put(repo, "agents/a.md", "after release")
    post_release = commit(repo, 103)
    post = check(repo, "pending", now=104, baseline=release, age=3600)
    assert post["changed_paths"][0]["first_pending_sha"] == post_release

    repo, base = make("reverted-old-path")
    put(repo, "skills/a/SKILL.md", "old")
    commit(repo, 1)
    put(repo, "agents/a.md", "new outstanding")
    recent = commit(repo, 90)
    put(repo, "skills/a/SKILL.md", "base\n")
    commit(repo, 95)
    report = check(repo, "pending", baseline=base, paths={"agents/a.md": "modified"}, age=36000)
    assert report["changed_paths"][0]["first_pending_sha"] == recent

    repo, base = make("runtime-inventory")
    put(repo, "skills/a/references/example.md", "reference")
    put(repo, "skills/a/templates/example.yml", "template")
    put(repo, "skills/a/scripts/example.sh", "script")
    (repo / "agents/a.md").unlink()
    put(repo, "hooks/a.sh", "changed hook")
    (repo / "scripts/align-labels.sh").chmod(0o755)
    put(repo, PLUGIN, '{"version":"2026.9.1","name":"renamed","nested":{"version":"changed"}}')
    put(repo, MARKET, '{"name":"market","plugins":[{"name":"fixture","source":"other"}]}')
    commit(repo, 10)
    check(repo, "pending", now=11, baseline=base, age=3600, paths={
        "skills/a/references/example.md": "added", "skills/a/templates/example.yml": "added",
        "skills/a/scripts/example.sh": "added", "agents/a.md": "deleted", "hooks/a.sh": "modified",
        "scripts/align-labels.sh": "modified", PLUGIN: "modified", MARKET: "modified"})
    (repo / "skills/a/SKILL.md").unlink()
    (repo / "skills/a/SKILL.md").symlink_to("../elsewhere")
    commit(repo, 12)
    report = check(repo, "pending", now=13, baseline=base, age=10800)
    assert any(row["path"] == "skills/a/SKILL.md" and row["age_seconds"] == 3600
               for row in report["changed_paths"])

    repo, base = make("array-and-nested-metadata")
    put(repo, MARKET, '{"name":"market","plugins":[{"name":"fixture","source":"./","config":{"version":1}},{"name":"second"}]}')
    put(repo, PLUGIN, '{"name":"fixture","version":"2026.9.2","nested":{"version":"keep"}}')
    release = commit(repo, 1)
    put(repo, MARKET, '{"name":"market","plugins":[{"name":"second"},{"name":"fixture","source":"./","config":{"version":1}}]}')
    commit(repo, 2)
    check(repo, "pending", now=3, baseline=release, age=3600, paths={MARKET: "modified"})
    put(repo, MARKET, '{"name":"market","plugins":[{"name":"fixture","source":"./","config":{"version":2}},{"name":"second"}]}')
    commit(repo, 3)
    check(repo, "pending", now=4, baseline=release, age=7200, paths={MARKET: "modified"})

    repo, base = make("first-parent-integration")
    git(repo, "checkout", "-q", "-b", "side")
    put(repo, "skills/a/SKILL.md", "branch work")
    side = commit(repo, 1, author_hours=-500)
    git(repo, "checkout", "-q", "main")
    commit(repo, 80)
    git(repo, "merge", "--no-ff", "-m", "integrate", "side", hours=90, author_hours=-500)
    integrated = git(repo, "rev-parse", "HEAD").decode().strip()
    report = check(repo, "pending", now=100, baseline=base, age=36000)
    assert report["changed_paths"][0]["first_pending_sha"] == integrated
    assert report["changed_paths"][0]["first_pending_sha"] != side
    check(repo, "due", now=162, baseline=base, age=259200)
    git(repo, "checkout", "-q", "-b", "release-side")
    put(repo, PLUGIN, '{"name":"fixture","version":"2026.9.2"}')
    commit(repo, 91)
    git(repo, "checkout", "-q", "main")
    git(repo, "merge", "--no-ff", "-m", "release integration", "release-side", hours=101)
    merged_release = git(repo, "rev-parse", "HEAD").decode().strip()
    report = check(repo, "clean", now=102, baseline=merged_release, paths={})
    assert report["baseline_date"] == date(101) and report["release_version"] == "2026.9.2"

    for name, path, value in (("missing-plugin", PLUGIN, None), ("missing-market", MARKET, None),
                              ("malformed-plugin", PLUGIN, "{"), ("malformed-market", MARKET, "[]"),
                              ("invalid-calver", PLUGIN, '{"version":"0.1.0"}'),
                              ("missing-version", PLUGIN, '{}')):
        repo, base = make(name)
        if value is None:
            (repo / path).unlink()
        else:
            put(repo, path, value)
        commit(repo, 1)
        check(repo, "error")

    repo, base = make("malformed-intermediate")
    put(repo, MARKET, "not json")
    commit(repo, 1)
    put(repo, MARKET, git(repo, "show", base + ":" + MARKET).decode())
    commit(repo, 2)
    check(repo, "error")

    repo, base = make("future-pending-time")
    put(repo, "skills/a/SKILL.md", "future")
    commit(repo, 200)
    check(repo, "error", now=100)
    check(repo, "error", ref="missing-ref")
    result = invoke(repo, "--due-after-hours", "0")
    assert result.returncode == 64

    repo, base = make("invalid-pending-time")
    put(repo, "skills/a/SKILL.md", "invalid time")
    commit(repo, 1)
    raw = git(repo, "cat-file", "commit", "HEAD")
    lines = raw.splitlines(keepends=True)
    lines = [b"committer Fixture <fixture@example.invalid> broken +0000\n"
             if line.startswith(b"committer ") else line for line in lines]
    invalid = git(repo, "hash-object", "--literally", "-t", "commit", "-w", "--stdin",
                  data=b"".join(lines)).decode().strip()
    git(repo, "update-ref", "refs/heads/main", invalid)
    check(repo, "error")

    repo, base = make("missing-object")
    put(repo, "skills/a/SKILL.md", "missing blob")
    commit(repo, 1)
    blob = git(repo, "rev-parse", "HEAD:skills/a/SKILL.md").decode().strip()
    (repo / ".git/objects" / blob[:2] / blob[2:]).unlink()
    check(repo, "error")
    # Same computed Markdown remains available on analysis error.
    result = invoke(repo, "--format", "markdown", "--now", date(100))
    assert result.returncode == 1 and result.stdout.startswith(b"# Release lag: error\n")

    repo, base = make("missing-history")
    commit(repo, 1)
    (repo / ".git/objects" / base[:2] / base[2:]).unlink()
    check(repo, "error")

    repo, base = make("shallow-source")
    put(repo, "skills/a/SKILL.md", "pending")
    commit(repo, 1)
    shallow = root / "shallow"
    git(root, "clone", "-q", "--depth", "1", "--no-local", repo.as_uri(), str(shallow))
    check(shallow, "error")
    # Reports are preserved on overdue exits too, not only success.
    result = invoke(repo, "--format", "markdown", "--now", date(100))
    assert result.returncode == 3 and result.stdout.startswith(b"# Release lag: due\n")
    assert b"skills/a/SKILL.md" in result.stdout and base.encode() in result.stdout
    print("release-lag: all behavioral histories passed")
PY
