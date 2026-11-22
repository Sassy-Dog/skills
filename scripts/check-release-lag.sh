#!/usr/bin/env bash
# check-release-lag.sh — read-only committed-payload release reminder (#382).
# Requires git and Python 3 (stdlib only). No fetch, CalVer resolver, index or
# worktree reads. See docs/VERSIONING.md for the fixed runtime inventory.
# Parsed first-parent version transitions define releases, not manifest touches.
# Each currently changed path keeps its uninterrupted divergence clock; returning
# to the baseline resets only that path. Committer time is integration time.
# --now <UTC ISO-8601 time> is the deterministic observation-clock seam.
# Exit: 0 clean/pending, 3 due, 1 unverified, 64 usage.
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
    echo 'release-lag: error: python3 is required; analysis unverified' >&2
    exit 1
fi
exec python3 - "$@" <<'PY'
import argparse
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys


class AnalysisError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(64, f"release-lag: {message}\n")


def positive(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("must be a positive integer")
    return int(value)


parser = Parser(description="Report committed runtime content awaiting release")
parser.add_argument("--repo", default=".")
parser.add_argument("--ref", default="HEAD")
parser.add_argument("--format", choices=("json", "markdown"), default="json")
parser.add_argument("--due-after-hours", type=positive, default=72)
parser.add_argument("--now", help="observation time, e.g. 2026-09-08T09:17:00Z")
args = parser.parse_args()
report = dict(status="error", analyzed_ref=args.ref, head_sha=None,
              release_version=None, baseline_sha=None, baseline_date=None,
              observation_time=None, due_after_hours=args.due_after_hours,
              threshold_seconds=args.due_after_hours * 3600,
              changed_paths=None, oldest_pending_age_seconds=None, error=None)
UTC = dt.timezone.utc
PLUGIN = ".claude-plugin/plugin.json"
MARKET = ".claude-plugin/marketplace.json"
# Disable lazy fetch and replacement objects: absence must remain unverified,
# and local replacement refs must not rewrite the committed evidence.
env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1",
           GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")


def git(*argv):
    result = subprocess.run(["git", "-C", args.repo, *argv], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise AnalysisError(f"git {' '.join(argv)}: " +
                            result.stderr.decode("utf-8", "replace").strip())
    return result.stdout


class Objects:
    """One object reader, with normalized manifests cached by blob identity."""
    def __init__(self):
        self.process = subprocess.Popen(
            ["git", "-C", args.repo, "cat-file", "--batch"], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.verified = set()
        self.manifests = {}

    def read(self, oid, expected):
        self.process.stdin.write(oid.encode("ascii") + b"\n")
        self.process.stdin.flush()
        fields = self.process.stdout.readline().split()
        if len(fields) != 3 or fields[1].decode() != expected:
            raise AnalysisError(f"unavailable {expected} object {oid}")
        size = int(fields[2])
        data = self.process.stdout.read(size)
        if len(data) != size or self.process.stdout.read(1) != b"\n":
            raise AnalysisError(f"incomplete object read {oid}")
        self.verified.add(oid)
        return data

    def close(self):
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.wait()


def strict_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"duplicate JSON key {key}")
        obj[key] = value
    return obj


def invalid_constant(value):
    raise ValueError(f"invalid JSON constant {value}")


def manifest(entries, path):
    entry = entries.get(path)
    if entry is None or entry[0] not in ("100644", "100755") or entry[1] != "blob":
        raise AnalysisError(f"missing or non-file required manifest {path}")
    key = (path, entry[2])
    if key not in objects.manifests:
        try:
            data = json.loads(objects.read(entry[2], "blob"),
                              object_pairs_hook=strict_object,
                              parse_constant=invalid_constant)
            if not isinstance(data, dict):
                raise ValueError("expected a JSON object")
            version = None
            if path == PLUGIN:
                version = data.pop("version", None)
                if not isinstance(version, str) or not version:
                    raise ValueError("missing/non-string top-level version")
            else:
                plugins = data.get("plugins")
                if not isinstance(plugins, list) or any(not isinstance(p, dict) for p in plugins):
                    raise ValueError("expected plugins array of objects")
                for plugin in plugins:
                    plugin.pop("version", None)
            normalized = json.dumps(data, sort_keys=True, separators=(",", ":"),
                                    ensure_ascii=True)
        except (ValueError, UnicodeError) as exc:
            raise AnalysisError(f"malformed {path}: {exc}") from exc
        objects.manifests[key] = (version, normalized)
    version, normalized = objects.manifests[key]
    return version, (entry[0], "json", normalized)


commits = {}
trees = {}
payloads = {}


def commit(sha):
    if sha not in commits:
        raw = objects.read(sha, "commit").split(b"\n\n", 1)[0].splitlines()
        tree = next((line[5:].decode("ascii") for line in raw if line.startswith(b"tree ")), None)
        committer = next((line for line in raw if line.startswith(b"committer ")), b"")
        # Do not let git's pretty-printer silently turn an invalid date into 0.
        match = re.search(rb"> (-?[0-9]+) [+-][0-9]{4}$", committer)
        timestamp = int(match[1]) if match else None
        if tree is None:
            raise AnalysisError(f"missing tree in commit {sha}")
        commits[sha] = (tree, timestamp)
    return commits[sha]


def entries(sha):
    tree, _ = commit(sha)
    if tree not in trees:
        listing = git("ls-tree", "-rz", "--full-tree", tree)
        found = {}
        for row in listing.split(b"\0"):
            if not row:
                continue
            metadata, path_bytes = row.split(b"\t", 1)
            path = path_bytes.decode("utf-8", "surrogateescape")
            if (path.startswith(("skills/", "agents/", "hooks/")) or
                    path in ("scripts/align-labels.sh", PLUGIN, MARKET)):
                found[path] = tuple(metadata.decode("ascii").split())
        trees[tree] = found
    return trees[tree]


def payload(sha):
    tree, _ = commit(sha)
    if tree not in payloads:
        result = dict(entries(sha))
        for path, entry in result.items():
            if path not in (PLUGIN, MARKET):
                # Read every selected ordinary object at least once; a tree
                # entry alone does not prove its blob is available locally.
                if entry[2] not in objects.verified:
                    objects.read(entry[2], entry[1])
        for path in (PLUGIN, MARKET):
            _, normalized = manifest(result, path)
            result[path] = normalized
        payloads[tree] = result
    return payloads[tree]


def iso(timestamp):
    try:
        return dt.datetime.fromtimestamp(timestamp, UTC).isoformat().replace("+00:00", "Z")
    except (ValueError, OverflowError, OSError, TypeError) as exc:
        raise AnalysisError(f"unusable commit timestamp {timestamp}") from exc


def pending_time(sha, now):
    timestamp = commit(sha)[1]
    date = iso(timestamp)
    if timestamp > now:
        raise AnalysisError(f"pending time {date} at {sha} is after observation clock")
    return timestamp, date


objects = None
try:
    observed = (dt.datetime.fromisoformat(args.now.replace("Z", "+00:00"))
                if args.now else dt.datetime.now(UTC).replace(microsecond=0))
    if observed.tzinfo is None or observed.utcoffset() != dt.timedelta(0):
        raise AnalysisError("observation time must include UTC timezone")
    now = observed.timestamp()
    report["observation_time"] = observed.isoformat().replace("+00:00", "Z")
    if git("rev-parse", "--is-shallow-repository").strip() != b"false":
        raise AnalysisError("complete non-shallow history is required")
    head = git("rev-parse", "--verify", "--end-of-options", args.ref + "^{commit}").decode().strip()
    report["head_sha"] = head
    history = git("rev-list", "--first-parent", head).decode().splitlines()
    if not history:
        raise AnalysisError("no first-parent history")
    objects = Objects()
    current, _ = manifest(entries(head), PLUGIN)
    report["release_version"] = current
    if not re.fullmatch(r"[0-9]{4}\.(?:[1-9]|1[0-2])\.[1-9][0-9]*", current):
        raise AnalysisError(f"invalid current CalVer {current!r}")
    baseline_index = None
    for index, sha in enumerate(history):
        version, _ = manifest(entries(sha), PLUGIN)
        if index + 1 == len(history):
            if not re.fullmatch(r"[0-9]{4}\.(?:[1-9]|1[0-2])\.[1-9][0-9]*", version):
                raise AnalysisError("history root does not introduce a valid release version")
            baseline_index = index
            break
        previous, _ = manifest(entries(history[index + 1]), PLUGIN)
        if version != previous:
            baseline_index = index
            break
    if baseline_index is None:
        raise AnalysisError("no verified release baseline")
    baseline = history[baseline_index]
    report["baseline_sha"] = baseline
    report["baseline_date"] = iso(commit(baseline)[1])
    base = payload(baseline)
    current_payload = payload(head)
    changed = sorted(path for path in base.keys() | current_payload.keys()
                     if base.get(path) != current_payload.get(path))
    # Walk integration order once, keeping clocks only for paths still pending.
    # Even for a clean head, required manifests throughout this interval must
    # remain readable/valid rather than hiding a failed read behind a revert.
    starts = {}
    for sha in reversed(history[:baseline_index]):
        state = payload(sha)
        for path in changed:
            if state.get(path) == base.get(path):
                starts.pop(path, None)
            elif path not in starts:
                starts[path] = sha
    rows = []
    for path in changed:
        start = starts[path]
        timestamp, date = pending_time(start, now)
        status = "added" if path not in base else "deleted" if path not in current_payload else "modified"
        rows.append(dict(path=path, status=status, first_pending_sha=start,
                         first_pending_date=date, age_seconds=now - timestamp))
    report["changed_paths"] = rows
    if rows:
        age = max(row["age_seconds"] for row in rows)
        report["oldest_pending_age_seconds"] = age
        report["status"] = "due" if age >= report["threshold_seconds"] else "pending"
    else:
        report["status"] = "clean"
except (AnalysisError, OSError, ValueError, KeyError) as exc:
    report["error"] = str(exc)
finally:
    if objects is not None:
        objects.close()


def text(value):
    if value is None:
        return "unknown"
    return html.escape(str(value)).replace("|", "&#124;").replace("\n", "&#10;").replace("\r", "&#13;")


if args.format == "json":
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
else:
    print(f"# Release lag: {report['status']}\n")
    for label, key in (("Analyzed ref", "analyzed_ref"), ("Head SHA", "head_sha"),
                       ("Committed release", "release_version"), ("Baseline SHA", "baseline_sha"),
                       ("Baseline date", "baseline_date"), ("Observation time", "observation_time"),
                       ("Due after hours (inclusive)", "due_after_hours"),
                       ("Threshold seconds", "threshold_seconds"),
                       ("Oldest pending age (seconds)", "oldest_pending_age_seconds")):
        print(f"- {label}: {text(report[key])}")
    if report["error"]:
        print(f"\nUnverified: {text(report['error'])}")
    elif report["status"] == "clean":
        print("\nNo net release-relevant payload difference.")
    else:
        print("\n| Path | Status | First pending SHA | First pending date | Age seconds |")
        print("|---|---|---|---|---|")
        for row in report["changed_paths"]:
            print("| " + " | ".join(text(row[key]) for key in
                  ("path", "status", "first_pending_sha", "first_pending_date", "age_seconds")) + " |")
        if report["status"] == "due":
            print("\nRelease due: follow the dedicated release PR procedure in docs/VERSIONING.md#releasing.")
        else:
            print("\nPending content has not reached the release threshold.")
    print("\nThis reports repository release lag, not consumer pins or running sessions. "
          "Use README.md#updating--troubleshooting for content/scope/restart diagnostics.")
sys.exit({"clean": 0, "pending": 0, "due": 3, "error": 1}[report["status"]])
PY
