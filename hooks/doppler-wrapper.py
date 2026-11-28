"""doppler-wrapper.py — the argv classifier behind hooks/shim/doppler, the plugin's second layer (#670).

hooks/shim/doppler is a bash entry point that sits FIRST on the agent's PATH (hooks/session-path.sh puts
it there at SessionStart; a plugin bin/ is not used, it lands last on PATH). It finds the real CLI further down PATH, asks this file whether the
call is allowed, and then either `exec`s the real CLI or refuses. This file sees ARGV, which the
shell has already parsed, so quoting, glob and expansion spellings (`$D secrets get X`, `dop*ler`,
`"$D" run`) have resolved to the words the CLI would receive. That is what the text guard
(bash-secret-guard.py) could never do, and why its expansion rules are deleted.

Two modes, one process each (the entry point reads the exit code):
  classify REAL ARGV...      exit 0 allow (the entry point execs REAL), 3 deny (banner on stderr),
                             4 "this is the wrapper's own subcommand, run it". Any other exit, or a
                             missing python3 or file, is a crash and the entry point FAILS OPEN, loudly,
                             as the hook does.
  gh-secret-set REAL ARGV... performs `sassydog-gh-secret-set`: runs the real `secrets get NAME
                             --plain`, holds the value in memory, feeds it to `gh secret set NAME` on gh's
                             stdin. Its failure paths exit non-zero and never set a secret.

The allow list is the text guard's, not a copy: the flag tables, parse_global, parse_args,
run_head_ok, bootstrap_toks_ok and allowed_simple are imported from bash-secret-guard.py. What is NEW
here is the stdout question, because a wrapper cannot see redirections, only the file descriptor it was
handed. Kinds, from fstat on fd 1 and fd 2:
  capture  fd 1 is the same file or pipe as fd 2, or a tty. The harness's own capture: on Claude Code
           2.1.332 the Bash tool hands a command ONE regular file, opened O_APPEND, as both stdout and
           stderr (measured: same device and inode, flags include O_APPEND). Anything printed here
           reaches the transcript.
  file     fd 1 is a regular file that is not fd 2's and was not opened for append: the shell opened it
           for a `> path` redirect. The only sink a printing form (`secrets get`, `download --no-file`,
           `substitute` without `--output`) may have.
  append   a regular file opened O_APPEND that is not fd 2's. Denied: it is how a harness capture looks
           when the command also redirected stderr (`doppler secrets get X 2>err`), and `>>` is not an
           allowed form anyway.
  pipe     a FIFO that is not fd 2's: a `$(...)` substitution or a pipe stage. Only the bootstrap shape
           (`secrets download --no-file --format env [-p P] [-c C]`, which `eval "$(...)"` consumes) may
           have it. A wrapper cannot tell `eval "$(...)"` from `echo "$(...)"`, and a pipe into `gh
           secret set` from a pipe into `cat`: the second is why sassydog-gh-secret-set exists.
  devnull  fd 1 is /dev/null. `secrets set NAME` is allowed only with BOTH fd 1 and fd 2 on /dev/null,
           because `set` prints a table with the values it wrote.
Forms that print nothing (`--only-names`, `run`, bare subcommands, `--version`, `help`, `download PATH`,
`substitute --output PATH`) are allowed with any sink.

NOT covered, named so nothing here reads as a claim of more:
  - the real binary called by absolute path, or by a PATH that does not put hooks/shim first (a harness
    that does not run the SessionStart hook, a shell that resets PATH, `PATH=` on the command, `env -i`,
    `command -p`, `hash -p`). A name the text guard cannot spell-check (`/opt/homebrew/bin/dop?ler`) PLUS
    one of these is caught by NEITHER layer: the base text guard denied it, this change does not. That is
    a regression against the text guard alone, accepted because the deleted rules were guesses;
  - the CLI's own environment variables (its API host, dashboard host, TLS-verify and config-dir
    settings, each prefixed with the CLI's name): the wrapper does not inspect the environment, so one
    can redirect the real CLI. The base text guard denied the `export` spelling: a regression;
  - the bootstrap argv is allowed into ANY pipe (`download --no-file --format env | cat`), not only an
    eval: also a regression against the base, where the whole-command shape had to be an eval;
  - a harness whose capture is a regular file opened WITHOUT O_APPEND and DIFFERENT from stderr's, or a
    capture that is two separate pipes: both look like a legitimate redirect or a `$(...)` to this file.
    Claude Code 2.1.332 is neither (the README records the measurement); other harnesses are unmeasured;
  - `doppler secrets get X > /dev/stdout 2>err` where the platform re-opens the capture by path without
    O_APPEND (Linux): fd 1 then looks like a file. The same-inode test denies it while fd 2 is the capture;
    only a redirect of stderr elsewhere defeats it;
  - the bootstrap argv into a pipe that is not eval (`echo "$($D secrets download --no-file --format
    env)"`, `... | cat`): allowed, because the shape is the one the plugin's own config emits;
  - a child of `run` printing its own environment (`run -- env`): the child decides;
  - everything the text guard names as out of scope (a symlink rename, an on-disk script, a redirected
    file read back).
"""

import importlib.util
import fcntl
import os
import re
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
DENY, ACTION = 3, 4


def load_guard():
    spec = importlib.util.spec_from_file_location("bash_secret_guard", os.path.join(HERE, "bash-secret-guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _stat(fd):
    try:
        return os.fstat(fd)
    except OSError:
        return None


def _same(a, b):
    return a is not None and b is not None and (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)


def _devnull(st):
    try:
        return st is not None and stat.S_ISCHR(st.st_mode) and os.path.samestat(st, os.stat("/dev/null"))
    except OSError:
        return False


def stdout_kind():
    """One of closed, tty, capture, file, append, pipe, devnull, other (see the module docstring)."""
    so, se = _stat(1), _stat(2)
    if so is None:
        return "closed"
    if os.isatty(1):
        return "tty"
    if _devnull(so):
        return "devnull"
    if _same(so, se):
        return "capture"
    if stat.S_ISREG(so.st_mode):
        try:
            flags = fcntl.fcntl(1, fcntl.F_GETFL)
        except OSError:
            return "other"
        return "append" if flags & os.O_APPEND else "file"
    if stat.S_ISFIFO(so.st_mode):
        return "pipe"
    return "other"


def run_form(g, argv):
    """True when argv is `[flags] run [flags] -- CHILD...` or `run [flags] --command STRING`, flags allowed."""
    head, child = argv, None
    if "--" in argv:
        k = argv.index("--")
        head, child = argv[:k], argv[k + 1:]
    if "--command" in head or any(t.startswith("--command=") for t in head):
        if child is not None:
            return False
        stripped, j = [], 0
        while j < len(head):
            t = head[j]
            if t == "--command":
                if j + 1 >= len(head) or not head[j + 1].strip():
                    return False
                j += 2
                continue
            if t.startswith("--command="):
                if not t.partition("=")[2].strip():
                    return False
                j += 1
                continue
            stripped.append(t)
            j += 1
        head = stripped
    elif child is None or not child or not child[0].strip():
        return False
    return g.run_head_ok(["doppler"] + head)


def secrets_set_form(g, toks):
    """True for `[global flags] secrets set NAME[=value] [-p P] [-c C]`: the sink rule is the caller's."""
    p = g.parse_global(toks)
    if p is None or p[0] + 1 >= len(toks) or toks[p[0]] != "secrets" or toks[p[0] + 1] != "set":
        return False
    parsed = g.parse_args(toks, p[0] + 2, g.GLOBAL_BOOL, g.GLOBAL_VAL | g.PC_VAL)
    return bool(parsed) and len(parsed[1]) == 1 and \
        re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:=.*)?", parsed[1][0], re.S) is not None


def gh_set_form(g, toks):
    """(index of the args after the subcommand, parsed args) when toks is the wrapper's own subcommand."""
    p = g.parse_global(toks)
    if p is None or p[0] >= len(toks) or toks[p[0]] != g.GH_SET_SUB:
        return None
    return g.parse_gh_secret_set(toks, p[0] + 1)


def decide(g, argv, kind, err_devnull):
    """(code, reason): code 0 allow, DENY, or ACTION. `reason` explains a deny."""
    toks = ["doppler"] + argv
    if run_form(g, argv):
        return 0, ""
    if gh_set_form(g, toks) is not None:
        return ACTION, ""
    if kind == "pipe" and g.bootstrap_toks_ok(toks):
        return 0, ""
    if secrets_set_form(g, toks):
        if kind == "devnull" and err_devnull:
            return 0, ""
        return DENY, ("`secrets set` prints a table holding the values it wrote unless BOTH stdout and stderr "
                      "go to /dev/null (`>/dev/null 2>&1`)")
    if g.allowed_simple(toks, None, False):
        return 0, ""
    if kind == "file" and g.allowed_simple(toks, "<stdout>", False):
        return 0, ""
    if g.allowed_simple(toks, "<stdout>", False):
        return DENY, ("this form prints secret values to its stdout, and its stdout here is "
                      f"{_DESCR[kind]}, not a file the shell opened for a `> /literal/path` redirect, so the "
                      "values would reach the transcript")
    return DENY, "this is not one of the allowed forms, so it could print secret values to the transcript"


_DESCR = {
    "closed": "closed", "tty": "a terminal", "capture": "the session transcript's own capture",
    "append": "a file opened for append (the transcript capture, with stderr redirected)",
    "pipe": "a pipe", "devnull": "/dev/null", "other": "not a plain file", "file": "a file",
}


def deny(g, reason):
    """Print the refusal and ALWAYS return DENY. A decided deny must never become a crash: with stderr closed
    (`2>&-`) sys.stderr is None, and a raise here would exit 1, which the entry point reads as a classifier
    crash and answers by running the real CLI. So write by file descriptor and swallow the error."""
    msg = f"doppler-wrapper: BLOCKED.\n- {reason}. {g.SAFE_FORMS}\n{g.ASK_USER}\n"
    try:
        os.write(2, msg.encode("utf-8", "replace"))
    except (OSError, ValueError):
        pass
    return DENY


def _cwd():
    try:
        cwd = os.getcwd()
    except OSError:  # the working directory was deleted: the guard module treats that as no cwd too
        return None
    return cwd if cwd.startswith("/") else None


def classify(real, argv):
    # Look at fd 1 and fd 2 BEFORE anything opens a file: with a descriptor closed, the next open() would
    # take its number and the kind would describe the classifier's own file.
    kind, err_devnull = stdout_kind(), _devnull(_stat(2))
    g = load_guard()
    g.CWD = _cwd()
    code, reason = decide(g, argv, kind, err_devnull)
    if code == DENY:
        return deny(g, reason)
    return code


def _flags(d):
    out = []
    for k, v in d.items():
        out += [k] if v is True else [k, v]
    return out


def _which(name):
    for d in os.environ.get("PATH", "").split(":"):
        if not d:
            continue
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def gh_secret_set(real, argv):
    g = load_guard()
    parsed = gh_set_form(g, ["doppler"] + argv)
    if parsed is None:
        sys.stderr.write("doppler-wrapper: sassydog-gh-secret-set arguments are not valid; nothing was set\n")
        return 2
    cli, gh_flags, name = parsed
    gh = _which("gh")
    if gh is None:
        sys.stderr.write("doppler-wrapper: gh was not found on PATH; nothing was set\n")
        return 127
    # -p/-c belong to the `secrets` command, after it; the global flags come before it (the allow list
    # refuses -p/-c before the subcommand, and the real CLI does not take them there).
    glob = {k: v for k, v in cli.items() if k in g.GLOBAL_BOOL or k in g.GLOBAL_VAL}
    scoped = {k: v for k, v in cli.items() if k not in glob}
    get = [real] + _flags(glob) + ["secrets", "get", name, "--plain"] + _flags(scoped)
    try:
        got = subprocess.run(get, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, check=False)
    except OSError as exc:
        sys.stderr.write(f"doppler-wrapper: cannot run the real CLI ({exc.__class__.__name__}); nothing was set\n")
        return 127
    if got.returncode != 0:
        sys.stderr.write(f"doppler-wrapper: reading {name} failed (exit {got.returncode}); nothing was set\n")
        return got.returncode
    if not got.stdout.strip():
        sys.stderr.write(f"doppler-wrapper: {name} is empty; nothing was set\n")
        return 1
    try:
        put = subprocess.run([gh, "secret", "set", name] + _flags(gh_flags), input=got.stdout, check=False)
    except OSError as exc:
        sys.stderr.write(f"doppler-wrapper: cannot run gh ({exc.__class__.__name__}); nothing was set\n")
        return 127
    return put.returncode


def main(args):
    if len(args) < 2 or args[0] not in ("classify", "gh-secret-set"):
        sys.stderr.write("doppler-wrapper: usage: doppler-wrapper.py classify|gh-secret-set REAL ARGV...\n")
        return 64
    mode, real, argv = args[0], args[1], args[2:]
    return classify(real, argv) if mode == "classify" else gh_secret_set(real, argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
