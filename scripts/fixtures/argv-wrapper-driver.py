"""argv-wrapper-driver.py — the real-process half of scripts/test-argv-wrapper.sh (#670).

Usage: argv-wrapper-driver.py REPO_ROOT SCRATCH_DIR

Builds, inside SCRATCH_DIR only, a fake "real CLI" (records its argv, prints a marker to stdout) and a fake gh,
then runs the repo's real hooks/shim/doppler against them with file descriptors shaped like each stdout the
wrapper can be handed. Prints `  ok   - label` / `  FAIL - label (detail)` lines; exit status is 0 only when no
check failed.
"""

import importlib.util
import json
import os
import pty
import shutil
import socket
import subprocess
import sys

REPO, WORK = sys.argv[1], sys.argv[2]
SHIM_SRC = os.path.join(REPO, "hooks", "shim")
SESSION = os.path.join(REPO, "hooks", "session-path.sh")
MARK = "SECRETVALUE"
FAILED = 0
D = "dop" + "pler"  # the CLI's name, kept out of this file's own text where a spelled command would read it


def ok(label):
    print(f"  ok   - {label}")


def bad(label, detail=""):
    global FAILED
    FAILED += 1
    print(f"  FAIL - {label}" + (f" ({detail})" if detail else ""))


def check(cond, label, detail=""):
    ok(label) if cond else bad(label, detail)


def section(title):
    print(f"== {title} ==")


# ---- the scratch world ----------------------------------------------------------------------------------------

REAL = os.path.join(WORK, "real")
GHBIN = os.path.join(WORK, "ghbin")
PYBIN = os.path.join(WORK, "pybin")      # python3, bash and the few tools the shim uses; no real CLI, no gh
NOPY = os.path.join(WORK, "nopy")        # the same without python3
CWD = os.path.join(WORK, "cwd")
CALLS = os.path.join(WORK, "calls.log")
GHCALLS = os.path.join(WORK, "gh.log")
GHSTDIN = os.path.join(WORK, "gh.stdin")
CAP = os.path.join(WORK, "capture.txt")
for d in (REAL, GHBIN, PYBIN, NOPY, CWD):
    os.makedirs(d)

FAKE = """#!/bin/sh
printf 'CALL\\0' >> "$CALLS"
for a in "$@"; do printf '%s\\0' "$a" >> "$CALLS"; done
printf 'END\\0' >> "$CALLS"
printf '%s\\n' "${FAKE_OUT-SECRETVALUE $*}"
exit "${FAKE_EXIT:-0}"
"""
FAKEGH = """#!/bin/sh
printf 'CALL\\0' >> "$GHCALLS"
for a in "$@"; do printf '%s\\0' "$a" >> "$GHCALLS"; done
printf 'END\\0' >> "$GHCALLS"
cat > "$GHSTDIN"
exit "${GH_EXIT:-0}"
"""
for path, body in ((os.path.join(REAL, D), FAKE), (os.path.join(GHBIN, "gh"), FAKEGH)):
    with open(path, "w") as fh:
        fh.write(body)
    os.chmod(path, 0o755)

TOOLS = ["bash", "dirname", "readlink", "sed", "env", "xargs", "cat", "sh", "mkdir", "wc", "head", "grep", "tr", "rmdir"]
for t in TOOLS:
    src = shutil.which(t)
    for dst in (PYBIN, NOPY):
        if src:
            os.symlink(src, os.path.join(dst, t))
os.symlink(shutil.which("python3"), os.path.join(PYBIN, "python3"))
# A file named like the CLI in the working directory, so a glob spelling has a match to expand to.
open(os.path.join(CWD, D), "w").close()
open(os.path.join(CWD, "in.txt"), "w").write("value\n")
open(os.path.join(CWD, "tpl.txt"), "w").write("x\n")

SHIM = os.path.join(SHIM_SRC, D)


def path_env(shim_dir=SHIM_SRC, with_real=True, with_gh=True, base=PYBIN):
    parts = [shim_dir]
    if with_real:
        parts.append(REAL)
    if with_gh:
        parts.append(GHBIN)
    parts.append(base)
    return ":".join(parts)


def calls():
    """The recorded invocations of the fake real CLI: a list of argv lists."""
    try:
        data = open(CALLS, "rb").read().decode()
    except OSError:
        return []
    out, cur = [], None
    for tok in data.split("\0"):
        if tok == "CALL":
            cur = []
        elif tok == "END":
            out.append(cur)
            cur = None
        elif cur is not None:
            cur.append(tok)
    return out


def reset():
    for p in (CALLS, GHCALLS, GHSTDIN, CAP, os.path.join(WORK, "err.txt"), os.path.join(WORK, "out.txt")):
        try:
            os.remove(p)
        except OSError:
            pass


class Result:
    def __init__(self, rc, text, seen):
        self.rc, self.text, self.seen = rc, text, seen  # seen: everything any visible sink received


def run(argv, kind="capture", *, shell=None, env=None, cwd=CWD, path=None, stdin=None):
    """Run `argv` (or the bash string `shell`) with stdout shaped as `kind`; returns a Result.

    capture       one O_APPEND regular file as fd 1 and fd 2, the Claude Code Bash tool's shape
    capture-pipe  one pipe as fd 1 and fd 2
    file          fd 1 a fresh regular file (a `> path` redirect), fd 2 the capture file
    append        fd 1 the O_APPEND capture file, fd 2 another file (`2>err`)
    pipe          fd 1 a pipe, fd 2 the capture file (a `$(...)` or a pipe stage)
    devnull       fd 1 /dev/null, fd 2 the capture file;  devnull2 both
    tty           fd 1 a pty, fd 2 the capture file
    socket        fd 1 a socket, fd 2 the capture file
    closed        fd 1 closed, fd 2 the capture file
    """
    reset()
    e = dict(os.environ)
    for k in list(e):
        if k.startswith(("FAKE_", "GH_", "SASSYDOG")):
            del e[k]
    e.update(CALLS=CALLS, GHCALLS=GHCALLS, GHSTDIN=GHSTDIN, PATH=path or path_env(), TERM="dumb")
    if env:
        e.update(env)
    cmd = ["bash", "-c", shell] if shell is not None else argv
    cap_fd = os.open(CAP, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    extra, closers, reader = [], [], None
    err_path = os.path.join(WORK, "err.txt")
    out_path = os.path.join(WORK, "out.txt")
    if kind == "capture":
        so, se = cap_fd, cap_fd
    elif kind == "capture-pipe":
        r, w = os.pipe()
        so, se, reader = w, w, r
        closers.append(w)
    elif kind == "file":
        so, se = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), cap_fd
        closers.append(so)
    elif kind == "append":
        so, se = cap_fd, os.open(err_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        closers.append(se)
    elif kind == "pipe":
        r, w = os.pipe()
        so, se, reader = w, cap_fd, r
        closers.append(w)
    elif kind in ("devnull", "devnull2"):
        dn = os.open(os.devnull, os.O_WRONLY)
        so, se = dn, (dn if kind == "devnull2" else cap_fd)
        closers.append(dn)
    elif kind == "tty":
        master, slave = pty.openpty()
        so, se = slave, cap_fd
        closers += [slave]
        extra.append(master)
    elif kind == "socket":
        a, b = socket.socketpair()
        so, se = a.fileno(), cap_fd
        extra += [a, b]
    elif kind == "closed":
        cmd = ["sh", "-c", '"$@" >&-', "sh"] + (cmd)
        so, se = cap_fd, cap_fd
    else:
        raise ValueError(kind)
    sin = subprocess.DEVNULL
    if stdin is not None:
        sin = os.open(os.path.join(cwd, stdin), os.O_RDONLY)
        closers.append(sin)
    if kind == "closed":
        # fd 1 closed by the shell wrapper; fd 2 stays the capture file
        so = cap_fd
    p = subprocess.Popen(cmd, stdin=sin, stdout=so, stderr=se, env=e, cwd=cwd, close_fds=True)
    for c in closers:
        try:
            os.close(c)
        except OSError:
            pass
    try:
        rc = p.wait(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
        rc = -9
    piped = ""
    if reader is not None:
        piped = os.read(reader, 1 << 20).decode(errors="replace")
        os.close(reader)
    os.close(cap_fd)
    for x in extra:
        if isinstance(x, int):
            os.close(x)
        else:
            x.close()
    try:
        cap = open(CAP, errors="replace").read()
    except OSError:
        cap = ""
    seen = cap + piped
    for p_ in (err_path,):
        try:
            seen += open(p_, errors="replace").read()
        except OSError:
            pass
    return Result(rc, cap + piped, seen)


def allowed(label, argv=None, kind="capture", **kw):
    r = run(argv, kind, **kw)
    n = calls()
    check(r.rc == 0 and len(n) >= 1, f"allowed: {label}", f"rc={r.rc} calls={n} out={r.text[:200]!r}")
    return r


def denied(label, argv=None, kind="capture", *, rc126=True, quiet=False, **kw):
    """A refusal: the real CLI never ran, no marker was printed, the banner was said (unless `quiet`: stderr
    was redirected by the command itself) and the exit status is 126 (unless `rc126` is off: a pipeline's or a
    substitution's own status is its consumer's)."""
    r = run(argv, kind, **kw)
    n = calls()
    seen_ok = quiet or kind == "devnull2" or "BLOCKED" in r.seen
    check((r.rc == 126 or not rc126) and not n and seen_ok and MARK not in r.seen,
          f"denied: {label}", f"rc={r.rc} calls={n} text={r.text[:200]!r}")
    return r


def sh_allowed(label, cmd, kind="capture", **kw):
    return allowed(label, shell=cmd, kind=kind, **kw)


def sh_denied(label, cmd, kind="capture", **kw):
    quiet = "2>" in cmd
    return denied(label, shell=cmd, kind=kind, rc126=not any(x in cmd for x in ("|", "$(", "`", "<(", "xargs", "eval", "bash -c", "sh -c", "&&", "time ", "f()", "(%s" % "doppler", "<<'EOF'")), quiet=quiet, **kw)


S = [SHIM]  # argv prefix: the shim run directly (PATH below it holds the real CLI and gh)

# ---- the allow list on argv ------------------------------------------------------------------------------------

section("printing forms are denied on every stdout that is not a file the shell opened")
for kind in ("capture", "capture-pipe", "append", "pipe", "tty", "socket", "closed", "devnull"):
    for label, argv in (
        ("secrets get", ["secrets", "get", "DATABASE_URL"]),
        ("secrets get --plain", ["secrets", "get", "X", "--plain"]),
        ("secrets get with flags", ["secrets", "get", "X", "--raw", "-p", "app", "-c", "prd"]),
        ("secrets download --no-file", ["secrets", "download", "--no-file"]),
        ("secrets download --no-file --format json", ["secrets", "download", "--no-file", "--format", "json"]),
        ("secrets substitute", ["secrets", "substitute", "tpl.txt"]),
        ("bare secrets", ["secrets"]),
    ):
        denied(f"{label} on a {kind} stdout", S + argv, kind)

section("the file form is allowed on a regular file that is not the capture")
allowed("secrets get > file", S + ["secrets", "get", "X", "--plain"], "file")
allowed("secrets get several names > file", S + ["secrets", "get", "A", "B"], "file")
allowed("secrets get with -p/-c > file", S + ["secrets", "get", "X", "-p", "app", "-c", "prd"], "file")
allowed("download --no-file > file", S + ["secrets", "download", "--no-file", "--format", "env"], "file")
allowed("substitute template > file", S + ["secrets", "substitute", "tpl.txt"], "file")
denied("secrets get to /dev/null is not a file form", S + ["secrets", "get", "X"], "devnull")
denied("a flag that is not on the list, on a file", S + ["secrets", "get", "X", "--copy"], "file")
denied("--token on a file", S + ["secrets", "get", "X", "--token", "dp.st.x"], "file")
denied("--debug on a file", S + ["--debug", "secrets", "get", "X"], "file")
denied("--api-host on a file", S + ["--api-host", "evil.example", "secrets", "get", "X"], "file")
denied("a name that is not a name, on a file", S + ["secrets", "get", "X;id"], "file")
denied("get with no name, on a file", S + ["secrets", "get"], "file")
denied("download without --no-file and without a path, on a file", S + ["secrets", "download"], "file")
denied("substitute with two templates, on a file", S + ["secrets", "substitute", "a", "b"], "file")
denied("secrets delete on a file", S + ["secrets", "delete", "X"], "file")
denied("secrets upload on a file", S + ["secrets", "upload", "tpl.txt"], "file")
denied("secrets set on a file stdout", S + ["secrets", "set", "X"], "file")
denied("configure get on a file", S + ["configure", "get"], "file")
denied("configure --all on a file", S + ["configure", "--all"], "file")
denied("--print-config on a file", S + ["--print-config"], "file")
denied("configs tokens on a file", S + ["configs", "tokens", "create", "x"], "file")

section("the capture stays a capture whatever else is redirected")
denied("get, stderr to a file (the capture is then 'append')", S + ["secrets", "get", "X"], "append")
denied("get, stdout and stderr both the capture file", S + ["secrets", "get", "X"], "capture")
sh_denied("get 2>/dev/null", "%s secrets get X --plain 2>/dev/null" % SHIM)
sh_denied("get 2>err", "%s secrets get X --plain 2>err.txt" % SHIM)
sh_denied("get >&2", "%s secrets get X --plain >&2" % SHIM)
sh_denied("get > /dev/stdout", "%s secrets get X --plain > /dev/stdout" % SHIM)
sh_denied("get > /dev/fd/2", "%s secrets get X --plain > /dev/fd/2" % SHIM)
sh_denied("get >> file (append is not the file form)", "%s secrets get X --plain >> out2.txt" % SHIM)
sh_denied("get > file 2>&1 (stdout and stderr are one file)", "%s secrets get X --plain > out3.txt 2>&1" % SHIM)
sh_denied("get piped to cat", "%s secrets get X --plain | cat" % SHIM)
sh_denied("get piped to a consumer that prints", "%s secrets get X --plain | sed p" % SHIM)
sh_denied("get in $(...) echoed", 'echo "$(%s secrets get X --plain)"' % SHIM)
sh_denied("get in backticks", "echo `%s secrets get X --plain`" % SHIM)
sh_denied("get in a here-string consumer", 'cat <<< "$(%s secrets get X --plain)"' % SHIM)
sh_denied("get through process substitution", "cat <(%s secrets get X --plain)" % SHIM)
sh_allowed("get > file under a real shell", "%s secrets get X --plain > got.txt" % SHIM)
sh_allowed("download --no-file > file under a real shell", "%s secrets download --no-file --format env > got.env" % SHIM)
sh_allowed("get > file with stderr to the capture", "%s secrets get X --plain > got.txt 2>&1 >got2.txt" % SHIM)

section("the bootstrap shape, on a pipe only")
allowed("bootstrap on a pipe", S + ["secrets", "download", "--no-file", "--format", "env"], "pipe")
allowed("bootstrap with -p/-c on a pipe", S + ["secrets", "download", "--no-file", "--format", "env", "-p", "a", "-c", "b"], "pipe")
allowed("bootstrap under eval", shell='eval "$(%s secrets download --no-file --format env)"' % SHIM, env={"FAKE_OUT": "true"})
allowed("bootstrap under eval with 2>/dev/null", shell='eval "$(%s secrets download --no-file --format env 2>/dev/null)"' % SHIM, env={"FAKE_OUT": "true"})
denied("bootstrap on a capture", S + ["secrets", "download", "--no-file", "--format", "env"], "capture")
denied("bootstrap on an append", S + ["secrets", "download", "--no-file", "--format", "env"], "append")
denied("bootstrap on a tty", S + ["secrets", "download", "--no-file", "--format", "env"], "tty")
denied("bootstrap with --format json on a pipe", S + ["secrets", "download", "--no-file", "--format", "json"], "pipe")
denied("bootstrap with a name transformer on a pipe", S + ["secrets", "download", "--no-file", "--format", "env", "--name-transformer", "dotnet-env"], "pipe")
denied("bootstrap without --no-file on a pipe", S + ["secrets", "download", "--format", "env"], "pipe")
denied("bootstrap with a global --json on a pipe", S + ["--json", "secrets", "download", "--no-file", "--format", "env"], "pipe")
denied("secrets get on a pipe", S + ["secrets", "get", "X", "--plain"], "pipe")

section("names only, run, bare subcommands and the path forms print nothing and take any stdout")
for kind in ("capture", "pipe", "append", "devnull2", "closed", "tty", "file"):
    allowed(f"--only-names on {kind}", S + ["secrets", "--only-names"], kind)
    allowed(f"run -- cmd on {kind}", S + ["run", "--", "echo", "hi"], kind)
    allowed(f"setup on {kind}", S + ["setup", "--no-interactive"], kind)
allowed("--only-names with flags", S + ["--json", "secrets", "--only-names", "-p", "app", "-c", "prd"])
allowed("--version", S + ["--version"])
allowed("-h", S + ["-h"])
allowed("help secrets", S + ["help", "secrets"])
allowed("run --help", S + ["run", "--help"])
for sub in ("login", "logout", "configs", "projects", "environments", "me", "update", "activity", "changelog", "open", "settings", "flags"):
    allowed(f"bare {sub}", S + [sub])
allowed("configs with -p", S + ["configs", "-p", "app"])
allowed("download PATH (writes the file itself)", S + ["secrets", "download", "out.env"])
allowed("download PATH with --format", S + ["secrets", "download", "--format", "env", "out.env"])
allowed("substitute --output", S + ["secrets", "substitute", "tpl.txt", "--output", "out.txt"])
allowed("substitute --output=", S + ["secrets", "substitute", "tpl.txt", "--output=out.txt"])
denied("download PATH under /dev", S + ["secrets", "download", "/dev/stdout"])
denied("download PATH with a dot segment", S + ["secrets", "download", "../x"])
denied("download PATH that is device-like", S + ["secrets", "download", "fd/1"])
denied("substitute --output /dev/stdout", S + ["secrets", "substitute", "tpl.txt", "--output", "/dev/stdout"])
denied("substitute --output /proc/self/fd/1", S + ["secrets", "substitute", "tpl.txt", "--output", "/proc/self/fd/1"])
denied("me with a flag", S + ["me", "--json"])
denied("unknown subcommand", S + ["frobnicate"])
denied("no arguments", S)
denied("only global flags", S + ["--json"])
denied("--only-names=false", S + ["secrets", "--only-names=false"])
denied("--only-names with a name", S + ["secrets", "--only-names", "X"])
denied("secrets with an unknown flag", S + ["secrets", "--weird", "--only-names"])
denied("--only-names on a get", S + ["secrets", "get", "X", "--only-names"])
denied("-p run (a flag value spelled like a subcommand)", S + ["-p", "run", "secrets", "get", "X"])
denied("a flag value starting with a dash", S + ["-p", "--json", "secrets", "--only-names"])
denied("a project name with a space", S + ["-p", "my app", "secrets", "--only-names"])

section("run: flags, the child and --command")
allowed("run with -p/-c", S + ["-p", "app", "-c", "prd", "run", "--", "env"])
allowed("run --no-fallback", S + ["run", "--no-fallback", "--", "true"])
allowed("run --only-secrets A,B", S + ["run", "--only-secrets", "A,B", "--", "true"])
allowed("run --only-secrets=A,B", S + ["run", "--only-secrets=A,B", "--", "true"])
allowed("run --no-cache --format env", S + ["run", "--no-cache", "--format", "env", "--", "true"])
allowed("run with a child that has spaces and empty words", S + ["run", "--", "sh", "-c", "echo $X", "", "a b"])
allowed("run --command", S + ["run", "--command", "echo $X"])
allowed("run --command=", S + ["run", "--command=echo $X"])
allowed("run -p a -c b --command", S + ["-p", "a", "-c", "b", "run", "--command", "echo hi"])
allowed("a child that itself names the CLI (its own call reaches the wrapper)", S + ["run", "--", "sh", "-c", D + " --version"])
denied("run with no child", S + ["run"])
denied("run -- with no child", S + ["run", "--"])
denied("run -- with an empty child word", S + ["run", "--", ""])
denied("run --command with an empty string", S + ["run", "--command", ""])
denied("run --command with no value", S + ["run", "--command"])
denied("run --command and --", S + ["run", "--command", "x", "--", "y"])
denied("--only-secrets on a read subcommand", S + ["secrets", "get", "X", "--only-secrets", "A"], "file")
denied("--only-secrets before run", S + ["--only-secrets", "A", "run", "--", "true"])
denied("--no-fallback before run", S + ["--no-fallback", "run", "--", "true"])
denied("--only-secrets with lower case", S + ["run", "--only-secrets", "a,b", "--", "true"])
denied("--only-secrets with an empty member", S + ["run", "--only-secrets", "A,,B", "--", "true"])
denied("--only-secrets with $X", S + ["run", "--only-secrets", "$X", "--", "true"])
denied("run with an unknown flag", S + ["run", "--debug", "--", "true"])
denied("run with --token", S + ["run", "--token", "dp.st.x", "--", "true"])
denied("-- before run", S + ["--", "run", "true"])
denied("secrets get after --", S + ["secrets", "get", "X", "--", "y"], "file")

section("secrets set: only with stdout AND stderr discarded")
allowed("set NAME, both discarded", S + ["secrets", "set", "NAME"], "devnull2", stdin="in.txt")
allowed("set NAME=value, both discarded (the value came from a file in the shell)", S + ["secrets", "set", "NAME=abc def"], "devnull2")
allowed("set with -p/-c, both discarded", S + ["secrets", "set", "NAME", "-p", "a", "-c", "b"], "devnull2", stdin="in.txt")
denied("set on a capture", S + ["secrets", "set", "NAME"], "capture", stdin="in.txt")
denied("set with stdout discarded only", S + ["secrets", "set", "NAME"], "devnull", stdin="in.txt")
denied("set on a pipe", S + ["secrets", "set", "NAME"], "pipe", stdin="in.txt")
denied("set with two names", S + ["secrets", "set", "A", "B"], "devnull2")
denied("set with no name", S + ["secrets", "set"], "devnull2")
denied("set with a bad name", S + ["secrets", "set", "1BAD"], "devnull2")
denied("set with an unknown flag", S + ["secrets", "set", "NAME", "--raw"], "devnull2")
sh_allowed("set under a real shell with < file >/dev/null 2>&1", "%s secrets set NAME < in.txt >/dev/null 2>&1" % SHIM)
sh_denied("set under a real shell with stdout discarded only", "%s secrets set NAME < in.txt >/dev/null" % SHIM)
sh_allowed("set NAME=\"$(cat file)\" both discarded", '%s secrets set NAME="$(cat in.txt)" >/dev/null 2>&1' % SHIM)

# ---- spellings the text hook cannot see ------------------------------------------------------------------------

section("spellings the shell resolves before the wrapper sees them (the acceptance item)")
spellings = [
    ("$D", 'D=%s; $D secrets get X --plain' % D),
    ('"$D"', 'D=%s; "$D" secrets get X --plain' % D),
    ("${D}", 'D=%s; ${D} secrets get X --plain' % D),
    ("${D:-name}", '${NOPE:-%s} secrets get X --plain' % D),
    ("${X}pler", 'X=dop; ${X}pler secrets get X --plain'),
    ("$(echo name)", '$(echo %s) secrets get X --plain' % D),
    ("quoted pieces", "dop'pl'er secrets get X --plain"),
    ("double-quoted pieces", 'd"o"ppler secrets get X --plain'),
    ("backslashed", "dopp\\ler secrets get X --plain"),
    ("ANSI-C quoting", "$'\\x64oppler' secrets get X --plain"),
    ("ANSI-C octal", "$'\\144oppler' secrets get X --plain"),
    ("glob *", "dop*ler secrets get X --plain"),
    ("glob ?", "d?ppler secrets get X --plain"),
    ("glob [d]", "[d]oppler secrets get X --plain"),
    ("glob in the subcommand word", "%s sec*ets get X --plain" % D),
    ("subcommand in a variable", 'S=secrets; %s $S get X --plain' % D),
    ("subcommand glued to an expansion", 'S=sec; %s ${S}rets get X --plain' % D),
    ("subcommand in quotes", "%s 'secrets' \"get\" X --plain" % D),
    ("brace expansion", "{%s,} secrets get X --plain" % D),
    ("command", "command %s secrets get X --plain" % D),
    ("env", "env %s secrets get X --plain" % D),
    ("env with an assignment", "env A=1 %s secrets get X --plain" % D),
    ("exec", "exec %s secrets get X --plain" % D),
    ("time", "time %s secrets get X --plain" % D),
    ("xargs", "echo secrets get X --plain | xargs %s" % D),
    ("eval", 'eval "%s secrets get X --plain"' % D),
    ("eval of a variable", 'C="%s secrets get X --plain"; eval "$C"' % D),
    ("bash -c", "bash -c '%s secrets get X --plain'" % D),
    ("sh -c", "sh -c '%s secrets get X --plain'" % D),
    ("a leading assignment", "A=1 %s secrets get X --plain" % D),
    ("a subshell", "(%s secrets get X --plain)" % D),
    ("a group", "{ %s secrets get X --plain; }" % D),
    ("&&", "true && %s secrets get X --plain" % D),
    ("a function", "f() { %s secrets get X --plain; }; f" % D),
    ("an alias-free here-doc to bash", "bash <<'EOF'\n%s secrets get X --plain\nEOF" % D),
    ("after cd", "cd /tmp && %s secrets get X --plain" % D),
    ("download --no-file", 'D=%s; $D secrets download --no-file' % D),
    ("substitute", 'D=%s; $D secrets substitute tpl.txt' % D),
    ("configure get", 'D=%s; $D configure get token' % D),
    ("configs tokens", 'D=%s; $D configs tokens create x' % D),
    ("bare secrets", 'D=%s; $D secrets' % D),
]
for label, cmd in spellings:
    sh_denied(f"{label}: secrets get on a capture", cmd)
sh_allowed("$D run -- cmd", 'D=%s; $D run -- echo hi' % D)
sh_allowed('"$D" run -- cmd', 'D=%s; "$D" run -- echo hi' % D)
sh_allowed("glob name, run -- cmd", "dop*ler run -- echo hi")
sh_allowed("quoted name, secrets --only-names", "dop'pl'er secrets --only-names")
sh_allowed("env spelling, --only-names", "env %s secrets --only-names" % D)
sh_allowed("xargs spelling, --only-names", "echo secrets --only-names | xargs %s" % D)
sh_allowed("a variable subcommand that resolves to --only-names", 'O=--only-names; %s secrets $O' % D)
sh_allowed("get to a file through a variable name", 'D=%s; $D secrets get X --plain > viaD.txt' % D)
sh_denied("a variable name and a glob after the redirect is moved to stderr", 'D=%s; $D secrets get X --plain 2>e.txt' % D)

# ---- the shim's own failure paths --------------------------------------------------------------------------------

section("the real CLI's status, argv and the PATH walk")
r = run(S + ["run", "--", "sh", "-c", "exit 3"], env={"FAKE_EXIT": "42"})
check(r.rc == 42, "the real CLI's own exit status passes through", f"rc={r.rc}")
r = run(S + ["run", "--", "sh", "-c", "echo $X", "", "a b"])
check(calls() == [["run", "--", "sh", "-c", "echo $X", "", "a b"]], "the real CLI gets the exact argv (spaces, an empty word, a dollar sign)", repr(calls()))
r = run(S + ["--version"], path=path_env(with_real=False, with_gh=False))
check(r.rc == 127 and "no real doppler CLI found" in r.text and not calls(), "no real CLI on PATH: exit 127, said, nothing run", f"rc={r.rc} {r.text!r}")
link_dir = os.path.join(WORK, "linkdir")
os.makedirs(link_dir)
os.symlink(SHIM, os.path.join(link_dir, D))
r = run(None, shell=D + " --version", path=link_dir + ":" + PYBIN)
check(r.rc == 127 and "no real doppler CLI found" in r.text, "the shim reached through a symlink skips itself (no recursion)", f"rc={r.rc} {r.text!r}")
r = run(None, shell=D + " --version", path=":".join([link_dir, SHIM_SRC, REAL, PYBIN]))
check(r.rc == 0 and calls() == [["--version"]], "the shim on PATH twice, once by symlink, still finds the real CLI", f"rc={r.rc} {r.text!r} {calls()}")
r = run(None, shell=D + " --version", path=":".join(["", SHIM_SRC, "", REAL, PYBIN]))
check(r.rc == 0 and calls() == [["--version"]], "empty PATH entries are skipped", f"rc={r.rc} {r.text!r}")
rel_cwd = os.path.join(WORK, "relcwd")
os.makedirs(rel_cwd)
shutil.copy(os.path.join(REAL, D), os.path.join(rel_cwd, D))
r = run(None, shell=D + " --version", path=":".join([SHIM_SRC, "relcwd", PYBIN]), cwd=WORK)
check(r.rc == 0 and calls() == [["--version"]], "a relative PATH entry is honoured against the cwd", f"rc={r.rc} {r.text!r}")

section("failures that fail open, loudly (the classifier cannot give a verdict)")
r = run(S + ["secrets", "get", "X"], path=path_env(base=NOPY))
check(r.rc == 0 and "python3 not found on PATH" in r.text and "fail open" in r.text and len(calls()) == 1,
      "python3 missing: said, fails open, the real CLI runs", f"rc={r.rc} {r.text!r} {calls()}")
tree = os.path.join(WORK, "tree")
os.makedirs(os.path.join(tree, "hooks"))
shutil.copytree(SHIM_SRC, os.path.join(tree, "hooks", "shim"))
shim2 = os.path.join(tree, "hooks", "shim")
r = run([os.path.join(shim2, D), "secrets", "get", "X"], path=path_env(shim_dir=shim2))
check(r.rc == 0 and "is missing or unreadable" in r.text and "fail open" in r.text and len(calls()) == 1,
      "classifier file missing: said, fails open, the real CLI runs", f"rc={r.rc} {r.text!r}")
for label, body, frag in (
    ("a syntax error", "def (:\n", "classifier crashed"),
    ("an exit 7", "raise SystemExit(7)\n", "classifier crashed (exit 7)"),
    ("an exit 2 (a usage error)", "raise SystemExit(2)\n", "classifier crashed (exit 2)"),
    ("a traceback", "raise RuntimeError('boom')\n", "classifier crashed"),
):
    open(os.path.join(tree, "hooks", "doppler-wrapper.py"), "w").write(body)
    r = run([os.path.join(shim2, D), "secrets", "get", "X"], path=path_env(shim_dir=shim2))
    check(r.rc == 0 and frag in r.text and "fail open" in r.text and len(calls()) == 1,
          f"classifier crash ({label}): said, fails open, the real CLI runs", f"rc={r.rc} {r.text!r}")
shutil.copy(os.path.join(REPO, "hooks", "doppler-wrapper.py"), os.path.join(tree, "hooks", "doppler-wrapper.py"))
r = run([os.path.join(shim2, D), "secrets", "get", "X"], path=path_env(shim_dir=shim2))
check(r.rc == 0 and "classifier crashed" in r.text and len(calls()) == 1,
      "the guard module missing next to the classifier: a crash, so fail open, said", f"rc={r.rc} {r.text[:200]!r}")

section("sassydog-gh-secret-set")
GS = S + ["sassydog-gh-secret-set"]


def gh_calls():
    try:
        data = open(GHCALLS, "rb").read().decode()
    except OSError:
        return []
    return [c.split("\0")[:-2] for c in data.split("CALL\0") if c]


r = run(GS + ["MY_SECRET", "--repo", "org/repo"], "capture", env={"FAKE_OUT": "s3cr3t-value"})
gc = gh_calls()
check(r.rc == 0 and calls() == [["secrets", "get", "MY_SECRET", "--plain"]], "reads the value with secrets get NAME --plain", f"rc={r.rc} {calls()} {r.text!r}")
check(gc and gc[0][:4] == ["secret", "set", "MY_SECRET", "--repo"] and gc[0][4] == "org/repo", "runs gh secret set NAME with the gh flags", repr(gc))
check(open(GHSTDIN).read() == "s3cr3t-value\n" if os.path.exists(GHSTDIN) else False, "the value reaches gh on stdin")
check("s3cr3t-value" not in r.seen, "the value is printed nowhere", r.seen)
r = run(GS + ["MY_SECRET", "-p", "app", "-c", "prd", "--env", "prod", "--no-store"], env={"FAKE_OUT": "v"})
check(calls() == [["secrets", "get", "MY_SECRET", "--plain", "-p", "app", "-c", "prd"]], "forwards -p/-c to the read, after the subcommand", repr(calls()))
check(gh_calls()[0] == ["secret", "set", "MY_SECRET", "--env", "prod", "--no-store"], "forwards the gh flags to gh", repr(gh_calls()))
for kind in ("capture", "pipe", "devnull2", "closed", "file"):
    r = run(GS + ["N"], kind, env={"FAKE_OUT": "v"})
    check(r.rc == 0 and gh_calls(), f"works on a {kind} stdout (it never prints the value)", f"rc={r.rc} {r.text!r}")
r = run(GS + ["N"], env={"FAKE_OUT": "v", "FAKE_EXIT": "5"})
check(r.rc == 5 and not gh_calls() and "nothing was set" in r.text, "the CLI fails: its status, gh never run, said", f"rc={r.rc} {r.text!r}")
r = run(GS + ["N"], env={"FAKE_OUT": ""})
check(r.rc == 1 and not gh_calls() and "is empty" in r.text, "an empty value: gh never run, said", f"rc={r.rc} {r.text!r}")
r = run(GS + ["N"], env={"FAKE_OUT": "  \t "})
check(r.rc == 1 and not gh_calls(), "a blank value: gh never run", f"rc={r.rc}")
r = run(GS + ["N"], env={"FAKE_OUT": "v", "GH_EXIT": "9"})
check(r.rc == 9 and len(gh_calls()) == 1, "gh fails: its status", f"rc={r.rc}")
r = run(GS + ["N"], env={"FAKE_OUT": "v"}, path=path_env(with_gh=False))
check(r.rc == 127 and "gh was not found" in r.text and not calls(), "gh missing: 127, said, the secret is not even read", f"rc={r.rc} {r.text!r} {calls()}")
for label, argv in (
    ("a name with a shell character", ["A;B"]),
    ("a name starting with a digit", ["1A"]),
    ("no name", []),
    ("two names", ["A", "B"]),
    ("--body", ["A", "--body", "x"]),
    ("-b", ["A", "-b", "x"]),
    ("--debug", ["--debug", "A"]),
    ("--token", ["A", "--token", "t"]),
    ("a flag value starting with a dash", ["A", "--repo", "-x"]),
):
    denied(f"sassydog-gh-secret-set with {label}", GS + argv, env={"FAKE_OUT": "v"})
    check(not gh_calls(), f"... and gh never ran ({label})")
sh_denied("the old text pipe into gh secret set (a wrapper cannot tell it from a capture)", "%s secrets get X --plain | gh secret set X" % SHIM)
sh_allowed("sassydog-gh-secret-set through a spelling the text hook cannot see", 'D=%s; $D sassydog-gh-secret-set N --repo o/r' % D, env={"FAKE_OUT": "v"})

# ---- the SessionStart hook ----------------------------------------------------------------------------------------


def session(env_file=None, path=None, script=SESSION, extra_env=None):
    e = {"PATH": path or (REAL + ":" + PYBIN), "HOME": WORK}
    if env_file is not None:
        e["CLAUDE_ENV_FILE"] = env_file
    if extra_env:
        e.update(extra_env)
    return subprocess.run(["bash", script], env=e, capture_output=True, text=True, stdin=subprocess.DEVNULL)


section("session-path.sh: the PATH line the agent's shell sources")
envf = os.path.join(WORK, "claude-env.sh")
p = session(envf)
line = open(envf).read() if os.path.exists(envf) else ""
check(p.returncode == 0 and p.stdout == "" and line.strip() != "", "writes one line to CLAUDE_ENV_FILE, exit 0, prints nothing", f"rc={p.returncode} {p.stderr!r}")
probe = subprocess.run(["bash", "-c", 'export PATH="%s"; . "$1"; printf "%%s" "${PATH%%%%:*}"' % (REAL + ":" + PYBIN), "x", envf],
                       capture_output=True, text=True)
check(probe.stdout == SHIM_SRC, "sourcing it puts hooks/shim first on PATH", repr(probe.stdout))
probe = subprocess.run(["bash", "-c", 'export PATH="%s"; . "$1"; . "$1"; printf "%%s" "$PATH"' % (REAL + ":" + PYBIN), "x", envf],
                       capture_output=True, text=True)
check(probe.stdout.count(SHIM_SRC) == 1, "sourcing it twice leaves one copy", repr(probe.stdout))
p = session(envf)
probe = subprocess.run(["bash", "-c", 'export PATH="%s"; . "$1"; printf "%%s" "$PATH"' % (REAL + ":" + PYBIN), "x", envf],
                       capture_output=True, text=True)
check(probe.stdout.count(SHIM_SRC) == 1, "a second SessionStart (two lines in the file) still leaves one copy", repr(probe.stdout))
probe = subprocess.run(["bash", "-c", 'export PATH="%s:%s"; . "$1"; printf "%%s" "$PATH"' % (REAL, SHIM_SRC), "x", envf],
                       capture_output=True, text=True)
check(probe.stdout.startswith(SHIM_SRC + ":") and probe.stdout.count(SHIM_SRC) == 2, "a shim entry later on PATH is moved in FRONT (the harness appends bin/ dirs late)", repr(probe.stdout))
check(p.returncode == 0, "the second run exits 0")
probe = subprocess.run(["bash", "-c", 'export PATH="%s"; . "$1"; command -v %s' % (REAL + ":" + PYBIN, D), "x", envf],
                       capture_output=True, text=True)
check(probe.stdout.strip() == os.path.join(SHIM_SRC, D), "after sourcing, the bare name resolves to the shim", repr(probe.stdout))

envf2 = os.path.join(WORK, "empty-env.sh")
p = session(envf2, path=PYBIN)
check(p.returncode == 0 and p.stderr == "" and not os.path.exists(envf2), "no real CLI on PATH: exit 0, nothing written, PATH untouched",
      f"rc={p.returncode} {p.stderr!r}")
p = session(envf2, path=os.path.join(SHIM_SRC) + ":" + PYBIN)
check(p.returncode == 0 and not os.path.exists(envf2), "only the shim itself on PATH counts as no real CLI", f"rc={p.returncode} {p.stderr!r}")
p = session(None)
check(p.returncode == 1 and "CLAUDE_ENV_FILE is not set" in p.stderr and "NOT guarded" in p.stderr, "no CLAUDE_ENV_FILE: exit 1, said", f"rc={p.returncode} {p.stderr!r}")
p = session(os.path.join(WORK, "no-such-dir", "env.sh"))
check(p.returncode == 1 and "cannot write CLAUDE_ENV_FILE" in p.stderr, "an unwritable CLAUDE_ENV_FILE: exit 1, said", f"rc={p.returncode} {p.stderr!r}")
bare = os.path.join(WORK, "bare")
os.makedirs(os.path.join(bare, "hooks"))
shutil.copy(SESSION, os.path.join(bare, "hooks", "session-path.sh"))
p = session(os.path.join(WORK, "e3.sh"), script=os.path.join(bare, "hooks", "session-path.sh"))
check(p.returncode == 1 and "missing or not executable" in p.stderr, "a missing shim: exit 1, said", f"rc={p.returncode} {p.stderr!r}")
odd = os.path.join(WORK, "a b'c")
shutil.copytree(os.path.join(REPO, "hooks"), os.path.join(odd, "hooks"), ignore=shutil.ignore_patterns("__pycache__"))
envf3 = os.path.join(WORK, "odd-env.sh")
p = session(envf3, script=os.path.join(odd, "hooks", "session-path.sh"))
probe = subprocess.run(["bash", "-c", 'export PATH="%s"; . "$1"; printf "%%s" "${PATH%%%%:*}"' % (REAL + ":" + PYBIN), "x", envf3],
                       capture_output=True, text=True)
check(p.returncode == 0 and os.path.realpath(probe.stdout) == os.path.realpath(os.path.join(odd, "hooks", "shim")), "a shim path with a space and a quote survives the quoting", f"rc={p.returncode} {probe.stdout!r} {p.stderr!r}")
r = subprocess.run([os.path.join(odd, "hooks", "shim", D), "secrets", "get", "X"], env={**os.environ, "PATH": path_env(shim_dir=os.path.join(odd, "hooks", "shim")),
                   "CALLS": CALLS}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
check(r.returncode == 126, "the shim also works from a path with a space and a quote", f"rc={r.returncode} {r.stdout[:100]!r}")

section("the text hook and the wrapper agree on every form the plugin allows")
spec = importlib.util.spec_from_file_location("guard", os.path.join(REPO, "hooks", "bash-secret-guard.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
os.makedirs(os.path.join(CWD, "sub"), exist_ok=True)
corpus = [
    "D secrets --only-names", "D secrets --only-names -p app -c prd", "D secrets --only-names | wc -l",
    "D secrets --only-names | head -n 5", "D secrets --only-names | grep -c true", "D run -- echo hi",
    "D -p a -c b run -- env", "D run --no-fallback -- echo hi", "D run --only-secrets A,B -- true",
    "D run --command 'echo $X'", "D run -- sh -c 'echo $X'", "D setup", "D configs", "D projects", "D me",
    "D --version", "D --help", "D help secrets", "D run --help",
    "D secrets get X --plain > out.txt", "D secrets get A B -p a -c b > out.txt", "D secrets download --no-file --format env > out.env",
    "D secrets download out.env", "D secrets substitute tpl.txt > out.txt", "D secrets substitute tpl.txt --output out.txt",
    'eval "$(D secrets download --no-file --format env)"', 'eval "$(D secrets download --no-file --format env -p a -c b 2>/dev/null)"',
    "D secrets set NAME < in.txt >/dev/null 2>&1", 'D secrets set NAME="$(cat in.txt)" >/dev/null 2>&1',
    "D secrets set NAME -p a -c b < in.txt >/dev/null 2>/dev/null",
    "D sassydog-gh-secret-set NAME", "D sassydog-gh-secret-set NAME --repo o/r -p a -c b",
]
for tmpl in corpus:
    cmd = tmpl.replace("D ", D + " ", 1) if tmpl.startswith("D ") else tmpl.replace("(D ", "(" + D + " ")
    problems = guard.analyze(cmd, CWD)
    check(not problems, f"the text hook allows: {tmpl}", repr(problems))
    shell_cmd = cmd
    r = run(None, "capture", shell=shell_cmd, env={"FAKE_OUT": "true"})
    n = calls()
    check(r.rc == 0 and len(n) >= 1 and "BLOCKED" not in r.text,
          f"... and the wrapper lets it reach the real CLI: {tmpl}", f"rc={r.rc} {r.text[:300]!r} {n}")
for tmpl in ("D secrets get X --plain | gh secret set X", "D secrets get X", "D secrets get X --plain", "D secrets download --no-file"):
    cmd = tmpl.replace("D ", D + " ", 1)
    check(bool(guard.analyze(cmd, CWD)), f"the text hook denies: {tmpl}")

section("a decided deny never becomes a crash (closed descriptors, a deleted working directory)")
# The classifier prints its refusal by file descriptor and returns the deny status whatever fails around it. If
# it raised instead, the entry point would read the exit as a crash and run the real CLI (fail open): a
# secret in the capture with no message. Each case spells the name by an expansion, so only the wrapper decides.
for label, shell in (
        ("stderr closed", 'A=dop; ${A}pler secrets get X --plain 2>&-'),
        ("stdout closed", 'A=dop; ${A}pler secrets get X --plain >&-'),
        ("stdout and stderr closed", 'A=dop; ${A}pler secrets get X --plain >&- 2>&-'),
        ("stdin, stdout and stderr closed", 'A=dop; ${A}pler secrets get X --plain <&- >&- 2>&-'),
        ("stderr discarded", 'A=dop; ${A}pler secrets get X --plain 2>/dev/null'),
        ("the working directory deleted", 'mkdir gone; cd gone; rmdir ../gone; A=dop; ${A}pler secrets get X --plain'),
        ("the working directory deleted and stderr closed",
         'mkdir gone2; cd gone2; rmdir ../gone2; A=dop; ${A}pler secrets get X --plain 2>&-')):
    r = run(None, "capture", shell=shell)
    check(r.rc == 126 and calls() == [] and MARK not in r.seen,
          f"denied with the real CLI never run: {label}", f"rc={r.rc} calls={calls()} {r.text[:200]!r}")
r = run(None, "capture", shell='A=dop; ${A}pler secrets get X --plain 2>&-')
check(MARK not in r.text, "closed stderr: no secret value reached the capture")

section("two copies of the shim on PATH reach the real CLI instead of each other")
copy = os.path.join(WORK, "copyB")
os.makedirs(os.path.join(copy, "hooks", "shim"))
for rel in ("hooks/shim/" + D, "hooks/doppler-wrapper.py", "hooks/bash-secret-guard.py"):
    shutil.copy(os.path.join(REPO, rel), os.path.join(copy, rel))
copy_shim = os.path.join(copy, "hooks", "shim")
for label, order in (("copy B before the repo's", [copy_shim, SHIM_SRC]), ("the repo's before copy B", [SHIM_SRC, copy_shim])):
    pth = ":".join(order + [REAL, GHBIN, PYBIN])
    r = run(None, "capture", shell=f"{D} secrets --only-names", path=pth)
    check(r.rc == 0 and len(calls()) == 1 and calls()[0][:2] == ["secrets", "--only-names"],
          f"an allowed form reaches the real CLI once: {label}", f"rc={r.rc} calls={calls()} {r.text[:200]!r}")
    r = run(None, "capture", shell=f"{D} secrets get X --plain", path=pth)
    check(r.rc == 126 and calls() == [], f"a printing form is still denied: {label}", f"rc={r.rc} calls={calls()}")
pth = ":".join([copy_shim, SHIM_SRC, GHBIN, PYBIN])
r = run(None, "capture", shell=f"{D} secrets --only-names", path=pth)
check(r.rc == 127 and "no real" in r.text, "two copies and no real CLI: 127 with the message, no loop", f"rc={r.rc} {r.text[:200]!r}")
# session-path.sh does not take a second shim for the real CLI either
envf5 = os.path.join(WORK, "two-copies-env.sh")
r5 = subprocess.run(["bash", os.path.join(copy, "hooks", "session-path.sh")] if os.path.exists(os.path.join(copy, "hooks", "session-path.sh")) else ["bash", SESSION],
                    env={"PATH": copy_shim + ":" + PYBIN, "CLAUDE_ENV_FILE": envf5}, capture_output=True, text=True)
check(r5.returncode == 0 and not os.path.exists(envf5), "session-path.sh: another copy's shim is not mistaken for the real CLI (nothing written)",
      f"rc={r5.returncode} {r5.stderr!r}")

section("session-path.sh: an env file whose last line has no trailing newline")
envf6 = os.path.join(WORK, "nonl-env.sh")
with open(envf6, "w") as fh:
    fh.write("export KEEP=1")
r6 = subprocess.run(["bash", SESSION], env={"PATH": REAL + ":" + PYBIN, "CLAUDE_ENV_FILE": envf6}, capture_output=True, text=True)
src6 = subprocess.run(["bash", "-c", f'. "{envf6}"; printf "%s|%s" "$KEEP" "${{PATH%%:*}}"'], env={"PATH": REAL + ":" + PYBIN},
                      capture_output=True, text=True)
check(r6.returncode == 0 and src6.stdout == "1|" + SHIM_SRC, "the old last line and the new PATH line both survive", f"{src6.stdout!r} {src6.stderr!r}")

section("hooks.json")
hj = json.load(open(os.path.join(REPO, "hooks", "hooks.json")))
ss = hj["hooks"].get("SessionStart", [])
check(len(ss) == 1 and len(ss[0]["hooks"]) == 1 and ss[0]["hooks"][0]["type"] == "command"
      and "${CLAUDE_PLUGIN_ROOT}/hooks/session-path.sh" in ss[0]["hooks"][0]["command"],
      "declares one SessionStart command hook that runs hooks/session-path.sh")
check("matcher" not in ss[0], "the SessionStart hook has no matcher (every start, resume, clear and compact)")
declared = ss[0]["hooks"][0]["command"].replace("${CLAUDE_PLUGIN_ROOT}", REPO)
envf4 = os.path.join(WORK, "decl-env.sh")
p = subprocess.run(["bash", "-c", declared], env={"PATH": REAL + ":" + PYBIN, "CLAUDE_ENV_FILE": envf4}, capture_output=True, text=True)
check(p.returncode == 0 and os.path.exists(envf4), "the declared command, run as the harness runs it, writes the env file", f"rc={p.returncode} {p.stderr!r}")

print()
sys.exit(1 if FAILED else 0)
