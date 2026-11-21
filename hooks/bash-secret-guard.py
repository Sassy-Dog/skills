"""bash-secret-guard.py — PreToolUse(Bash) classifier for the sassy-dog plugin.

Reads the harness's JSON event on stdin. Exit 0 allows, exit 2 denies (the reason goes to
stderr, which the harness feeds to the model), exit 1 means "could not classify": the guard
FAILS OPEN there and says so on stderr (Claude Code shows stderr of any non-0/2 exit as a
non-blocking error). It never prints to stdout.

Two rules, both over the command text only (a PreToolUse hook cannot see output):

1. Doppler value-printing guard. `doppler secrets get|download|substitute` and bare
   `doppler secrets` print secret values in their default output. Allowed only when the
   invocation cannot put a value in the transcript: --only-names, --silent, any
   `doppler run -- <cmd>` (the child decides what prints), stdout redirected to a real
   file, or --plain whose output is consumed in the same command (a pipe into a counting,
   hashing or totally-redacting stage, or a $(...) capture whose parent is a bare
   assignment, export/local/declare, a test or a hasher). A capture inside any other
   command (echo, curl, bash -c) may be printed by that command and is judged as printed.
2. Literal credentialed URL guard. A command whose text embeds scheme://user:password@host.

Per-command bypass: put the variable in the command itself, e.g.
`SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X` or
`SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql ...`. The hook's own environment is never consulted,
so the bypass is visible in the transcript and cannot be left on by accident.

The shell is parsed by a small lexer (quotes, escapes, ; & | newline, $(...), backticks,
bash/sh/zsh -c and eval strings, ${...} bodies, reserved words, wrapper commands and
their option values), not by a shell. It is a seatbelt against the accident that motivated
it, not a sandbox: heredoc bodies, aliases, functions and variable indirection are out of
scope.
"""

import json
import os
import re
import sys

URL_RE = re.compile(
    r"(postgres(ql)?|mysql|mongodb(\+srv)?|redis(s)?|amqps?)://[^:@/\s]+:[^@/\s]+@[^/\s]+"
)
BYPASS_DOPPLER = "SASSYDOG_ALLOW_DOPPLER_PRINT=1"
BYPASS_URL_RE = re.compile(r"(?:^|[;&|(\s])SASSYDOG_ALLOW_CREDENTIAL_URL=1(?=\s)")

# Wrapper commands skipped to reach the real command word, with the options that take a
# separate VALUE (that value is not the command). Anything this table does not understand is
# caught by the fail-closed backstop in check_stage: it scans the wrapper's words for a
# shell/eval/doppler word rather than trusting the parse.
WRAPPER_OPTS = {
    "env": {"-u", "-C", "-S", "-P", "--unset", "--chdir", "--split-string"},
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-T", "-D",
             "--user", "--group", "--host", "--prompt", "--chdir", "--role", "--type"},
    "command": set(),
    "exec": {"-a"},
    "time": {"-f", "-o", "--format", "--output"},
    "nohup": set(),
    "builtin": set(),
    "nice": {"-n", "--adjustment"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "xargs": {"-I", "-n", "-L", "-P", "-s", "-d", "-a", "-E",
              "--max-args", "--max-lines", "--max-procs", "--max-chars", "--delimiter",
              "--arg-file", "--replace", "--eof"},
}
WRAPPERS = set(WRAPPER_OPTS)
# Shell reserved words that precede a command: `do doppler ...`, `then doppler ...`, `! doppler ...`.
KEYWORDS = {"if", "then", "elif", "else", "do", "while", "until", "!", "{", "coproc"}
TEST_CMDS = {"[", "[[", "test"}
DECLARERS = {"export", "local", "declare", "readonly", "typeset"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
PRINT_SUBCMDS = {"get", "download", "substitute"}
OTHER_SECRETS_SUBCMDS = {"set", "delete", "upload", "names", "notes", "update", "help"}
HASHERS = {"wc", "sha1sum", "sha256sum", "sha512sum", "shasum", "md5sum", "md5", "cksum"}
GREPS = {"grep", "egrep", "fgrep", "rg"}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_DEPTH = 8

SAFE_FORMS = (
    "Safe forms: `doppler secrets --only-names`, `doppler run -- <cmd>` (the child reads the "
    "value from its environment), `--plain` piped into a counting or redacting stage "
    "(wc, grep -c, sha256sum, `sed d`, `sed 's/.*//'`, head -c0), or captured by a bare assignment "
    "(TOKEN=$(...)) or a test, or a redirect to a file."
)


class Word(str):
    """A shell word; `.q` is True when any part of it was quoted or escaped."""

    q = False


def mkword(text, quoted):
    w = Word(text)
    w.q = quoted
    return w


class Seg:
    def __init__(self):
        self.words = []
        self.sep = None
        self.subs = []


def match_paren(s, i):
    """Index of the ')' closing the '(' whose body starts at s[i]; len(s) if unterminated."""
    depth = 1
    quote = None
    while i < len(s):
        c = s[i]
        if c == "\\" and quote != "'":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(s)


def extract_subs(text):
    """Inner strings of every $(...) and `...` inside text (used for ${...} bodies)."""
    found = []
    i = 0
    while i < len(text):
        if text.startswith("$(", i) and not text.startswith("$((", i):
            j = match_paren(text, i + 2)
            found.append(text[i + 2:j])
            i = j + 1
        elif text[i] == "`":
            j = text.find("`", i + 1)
            j = len(text) if j < 0 else j
            found.append(text[i + 1:j])
            i = j + 1
        else:
            i += 1
    return found


def lex(s):
    segs = []
    seg = Seg()
    cur = []
    has = False
    quoted = False
    i = 0
    n = len(s)

    def end_word():
        nonlocal cur, has, quoted
        if has or cur:
            seg.words.append(mkword("".join(cur), quoted))
        cur, has, quoted = [], False, False

    def end_seg(sep):
        nonlocal seg
        end_word()
        seg.sep = sep
        if seg.words or seg.subs:
            segs.append(seg)
        seg = Seg()

    while i < n:
        c = s[i]
        nxt = s[i + 1] if i + 1 < n else ""
        if c == "\\":
            if nxt == "\n":
                i += 2
                continue
            if nxt:
                cur.append(nxt)
                has = quoted = True
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            cur.append(s[i + 1:j])
            has = quoted = True
            i = j + 1
        elif c == '"':
            has = quoted = True
            i += 1
            while i < n and s[i] != '"':
                d = s[i]
                if d == "\\" and i + 1 < n:
                    cur.append(s[i + 1])
                    i += 2
                elif d == "$" and s[i + 1:i + 2] == "(" and s[i + 1:i + 3] != "((":
                    j = match_paren(s, i + 2)
                    seg.subs.append(s[i + 2:j])
                    cur.append("\0")
                    i = j + 1
                elif d == "`":
                    j = s.find("`", i + 1)
                    j = n if j < 0 else j
                    seg.subs.append(s[i + 1:j])
                    cur.append("\0")
                    i = j + 1
                else:
                    cur.append(d)
                    i += 1
            i += 1
        elif c == "$" and nxt == "(" and s[i + 1:i + 3] != "((":
            j = match_paren(s, i + 2)
            seg.subs.append(s[i + 2:j])
            cur.append("\0")
            has = True
            i = j + 1
        elif c == "$" and nxt == "{":
            j = s.find("}", i + 2)
            j = n - 1 if j < 0 else j
            body = s[i:j + 1]
            seg.subs.extend(extract_subs(body))
            cur.append(body)
            has = True
            i = j + 1
        elif c == "`":
            j = s.find("`", i + 1)
            j = n if j < 0 else j
            seg.subs.append(s[i + 1:j])
            cur.append("\0")
            has = True
            i = j + 1
        elif c in ";\n(){}":
            end_seg(";")
            i += 1
        elif c == "|":
            if nxt == "|":
                end_seg("||")
                i += 2
            else:
                end_seg("|")
                i += 2 if nxt == "&" else 1
        elif c == "&":
            if (cur and cur[-1] == ">") or nxt == ">":
                cur.append(c)
                has = True
                i += 1
            elif nxt == "&":
                end_seg("&&")
                i += 2
            else:
                end_seg("&")
                i += 1
        elif c in " \t\r":
            end_word()
            i += 1
        elif c == "#" and not cur and not has:
            j = s.find("\n", i)
            i = n if j < 0 else j
        else:
            cur.append(c)
            has = True
            i += 1
    end_seg(None)
    return segs


def cmd_pos(words):
    """(command index or None, bypass flag, first wrapper index or None, inner strings).

    Skips assignments, reserved words and wrappers (with their option values). `inner` holds
    strings that are themselves commands (env -S 'cmd ...')."""
    bypass = False
    wrap_start = None
    inner = []
    i = 0
    while i < len(words):
        w = words[i]
        if ASSIGN_RE.match(w) and not w.q:
            bypass = bypass or w == BYPASS_DOPPLER
            i += 1
            continue
        if not w.q and w in KEYWORDS:
            i += 1
            continue
        name = os.path.basename(w)
        if name in WRAPPERS:
            if wrap_start is None:
                wrap_start = i
            takes = WRAPPER_OPTS[name]
            i += 1
            while i < len(words):
                a = words[i]
                if a == "--":
                    i += 1
                    break
                if a.startswith("-") and len(a) > 1:
                    if a in takes and i + 1 < len(words):
                        if a in ("-S", "--split-string"):
                            inner.append(words[i + 1])
                        i += 2
                    else:
                        if a.startswith("--split-string="):
                            inner.append(a.split("=", 1)[1])
                        i += 1
                    continue
                if name == "timeout" and re.match(r"^\d+(\.\d+)?[smhd]?$", a):
                    i += 1
                    continue
                if ASSIGN_RE.match(a) and name == "env":
                    bypass = bypass or a == BYPASS_DOPPLER
                    i += 1
                    continue
                break
            continue
        return i, bypass, wrap_start, inner
    return None, bypass, wrap_start, inner


def flag_on(args, flag):
    return any(a == flag or (a.startswith(flag + "=") and not a.endswith("=false")) for a in args)


NOT_A_FILE = ("/dev/stdout", "/dev/stderr", "/dev/tty", "/dev/fd/", "/proc/", "/dev/pts/", "/dev/ptmx")


def stdout_to_file(words):
    """True when, after every redirect in order, stdout ends up in a regular file (or closed).

    A later dup of stdout onto another descriptor (`>file >&2`), or a target that is the
    terminal, a descriptor path, a pty or a process substitution, puts it back in view."""
    dest = "term"
    for i, w in enumerate(words):
        if w.q:
            continue
        m = re.match(r"^(\d*|&)>>?(.*)$", w)
        if not m:
            continue
        fd, target = m.group(1), m.group(2)
        if fd not in ("", "1", "&"):
            continue
        if not target:
            nxt = words[i + 1] if i + 1 < len(words) else ""
            if not nxt or nxt.startswith(("&", ">", "<")):
                continue  # `>` ending the line is `>(...)`: process substitution, not a file
            target = nxt
        if target.startswith("&"):
            dup = target[1:]
            if dup == "1":
                continue
            dest = "file" if dup == "-" else "term"
            continue
        dest = "term" if target.startswith(NOT_A_FILE) or "\0" in target else "file"
    return dest == "file"


SED_TOTAL_RE = (
    re.compile(r"^d$"),
    re.compile(r"^s(?P<d>[/|#,])\.\*(?P=d)[^&\\]*(?P=d)g?$"),
    re.compile(r"^s(?P<d>[/|#,])\.(?P=d)[^&\\]*(?P=d)g$"),
)


def sed_is_total_redaction(args):
    """Only a sed whose single script provably replaces every input line/char counts."""
    scripts = []
    k = 0
    while k < len(args):
        a = args[k]
        if a == "-e" and k + 1 < len(args):
            scripts.append(args[k + 1])
            k += 2
        elif a in ("-n", "-E", "-r", "--quiet", "--silent", "--regexp-extended", "-u", "--unbuffered"):
            k += 1
        elif a.startswith("-") and len(a) > 1:
            return False  # -f, -i, -s, -z, clusters, anything not understood
        else:
            scripts.append(a)
            k += 1
    if len(scripts) != 1:
        return False
    return any(r.match(scripts[0]) for r in SED_TOTAL_RE)


def is_consumer(words):
    """True when this pipeline stage swallows (counts, hashes, totally redacts) its input."""
    i, _, _, _ = cmd_pos(words)
    if i is None:
        return False
    name = os.path.basename(words[i])
    args = words[i + 1:]
    if name == "sed":
        return sed_is_total_redaction(args)
    if name in HASHERS:
        return True
    if name in GREPS:
        return any(
            (a.startswith("-") and not a.startswith("--") and re.search(r"[cq]", a))
            or a in ("--count", "--quiet", "--silent")
            for a in args
        )
    if name == "head":
        return any(a in ("-c0", "-n0") for a in args) or any(
            a in ("-c", "-n") and k + 1 < len(args) and args[k + 1] == "0" for k, a in enumerate(args)
        )
    return False


def check_stage(words, sink, depth):
    """Violations for one simple command. sink is 'file', 'consumed' or None."""
    i, bypass, wrap_start, inner = cmd_pos(words)
    out = []
    for text in inner:
        out += analyze(text, sink is not None, depth + 1)
    if i is None and wrap_start is None:
        return out
    name = os.path.basename(words[i]) if i is not None else ""
    if wrap_start is not None and name not in SHELLS and name not in ("eval", "doppler"):
        # Fail-closed backstop: the wrapper's option table may not understand its arguments
        # (`sudo -u root doppler ...` read `root` as the command). Look for the real command.
        for j in range(wrap_start, len(words)):
            if os.path.basename(words[j]) in SHELLS or words[j] in ("eval", "doppler") or \
                    os.path.basename(words[j]) == "doppler":
                i, name = j, os.path.basename(words[j])
                break
    if i is None:
        return out
    args = words[i + 1:]
    if name in SHELLS:
        for j, a in enumerate(args):
            if a.startswith("-") and not a.startswith("--") and "c" in a and j + 1 < len(args):
                out += analyze(args[j + 1], sink is not None, depth + 1)
                break
        return out
    if name == "eval":
        return out + analyze(" ".join(args), sink is not None, depth + 1)
    if name != "doppler" or bypass:
        return out
    for j, a in enumerate(args):
        if a == "run":
            for k, b in enumerate(args[j + 1:], j + 1):
                if b == "--command" and k + 1 < len(args):
                    out += analyze(args[k + 1], sink is not None, depth + 1)
                elif b.startswith("--command="):
                    out += analyze(b[len("--command="):], sink is not None, depth + 1)
            if "--" in args[j + 1:]:
                tail = args[args.index("--", j + 1) + 1:]
                out += check_stage(tail, sink, depth + 1) if tail else []
            return out
        if a == "secrets":
            rest = args[j + 1:]
            sub = next((r for r in rest if r in PRINT_SUBCMDS), None)
            if sub is None and any(r in OTHER_SECRETS_SUBCMDS for r in rest):
                return []
            if "--help" in rest or "-h" in rest:
                return []
            if flag_on(rest, "--only-names") or flag_on(rest, "--silent"):
                return []
            if sink == "file":
                return []
            if sink == "consumed" and flag_on(rest, "--plain"):
                return []
            shown = "doppler secrets " + (sub or "(bare)")
            return [
                f"`{shown}` prints secret values to the transcript. {SAFE_FORMS} "
                "Deliberate override for one command: prefix it with SASSYDOG_ALLOW_DOPPLER_PRINT=1."
            ]
    return []


def analyze(s, captured=False, depth=0):
    if depth > MAX_DEPTH:
        return ["command nests too deeply to classify; denied rather than guessed. " + SAFE_FORMS]
    out = []
    segs = lex(s)
    k = 0
    while k < len(segs):
        pipeline = [segs[k]]
        while pipeline[-1].sep == "|" and k + len(pipeline) < len(segs):
            pipeline.append(segs[k + len(pipeline)])
        k += len(pipeline)
        for idx, seg in enumerate(pipeline):
            last = idx == len(pipeline) - 1
            to_file = stdout_to_file(seg.words)
            if to_file:
                sink = "file"
            elif last:
                sink = "consumed" if captured else None
            else:
                sink = "consumed" if is_consumer(pipeline[idx + 1].words) else None
            out += check_stage(seg.words, sink, depth)
            pos, _, _, _ = cmd_pos(seg.words)
            parent = os.path.basename(seg.words[pos]) if pos is not None else ""
            # A $(...) capture is trusted only when its parent cannot show it: a bare
            # assignment, export/local/declare, a test, a hasher, or stdout sent to a file.
            # Any other parent (echo, curl, bash -c ...) may print it, so the inner command
            # must be safe by itself.
            trusted = bool(seg.words) and (
                pos is None or parent in DECLARERS or parent in TEST_CMDS or parent in HASHERS
            ) or to_file
            for sub in seg.subs:
                out += analyze(sub, trusted, depth + 1)
    return out


def notice(msg):
    sys.stderr.write(f"bash-secret-guard: {msg}; command NOT checked (fail open)\n")
    return 1


def main():
    try:
        raw = sys.stdin.read()
    except (OSError, UnicodeDecodeError) as exc:
        return notice(f"cannot read the hook event ({exc.__class__.__name__})")
    if not raw.strip():
        return notice("empty hook event on stdin")
    try:
        event = json.loads(raw)
    except ValueError:
        return notice("hook event is not valid JSON")
    if not isinstance(event, dict):
        return notice("hook event is not a JSON object")
    if event.get("tool_name") != "Bash":
        return 0
    tool_input = event.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        return notice("Bash event carries no command string")
    try:
        problems = analyze(command)
        if URL_RE.search(command) and not BYPASS_URL_RE.search(command):
            problems.append(
                "the command embeds a URL with a literal password (scheme://user:password@host). "
                "Pass the value through the environment instead (`doppler run -- <cmd>` and read "
                "the variable in the child). Deliberate override for one command: prefix it with "
                "SASSYDOG_ALLOW_CREDENTIAL_URL=1."
            )
    except Exception as exc:  # noqa: BLE001 - any classifier fault must be reported, not swallowed
        return notice(f"internal error while classifying ({exc.__class__.__name__})")
    if problems:
        sys.stderr.write("bash-secret-guard: BLOCKED.\n")
        for p in dict.fromkeys(problems):
            sys.stderr.write(f"- {p}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
