"""bash-secret-guard.py — PreToolUse(Bash) classifier for the sassy-dog plugin.

Reads the harness's JSON event on stdin. Exit 0 allows, exit 2 denies (the reason goes to
stderr, which the harness feeds to the model), exit 1 means "could not classify": the guard
FAILS OPEN there and says so on stderr (Claude Code shows stderr of any non-0/2 exit as a
non-blocking error). It never prints to stdout.

Two rules, both over the command text only (a PreToolUse hook cannot see output):

1. Doppler value-printing guard, DENY BY DEFAULT with a short allow list. Every word whose
   basename is `doppler`, anywhere in any pipeline stage, is classified, whatever precedes it
   (sudo, ssh, find -exec, docker exec, a for loop...): there is no wrapper table. If a
   value-printing subcommand follows (`secrets get|download|substitute`, bare `secrets`, or an
   unrecognised word after `secrets`), the invocation is allowed only when
     (a) it is `doppler run ...` (the child decides what prints; the child's own
         `doppler secrets get` is a separate doppler word and is still denied), or
     (b) it carries `--only-names` (bare, or an explicit true value), or
     (c) stdout of that stage goes to a real file (normalised path; /dev/* other than
         /dev/null, /proc/*, process substitution, a later dup to &1/&2 and unresolved
         variables are not files), or
     (d) the subcommand does not print values (`secrets set`, `configs`, `setup`, ...).
   Nothing else is trusted: not --plain, not --silent, not a pipe into wc/sed/grep, not a
   $(...) capture. Command strings are looked into wherever they hide: `$(...)`, backticks,
   `${...}`, `<(...)`, `bash -c` (any shell, `--` included), `eval`, `env -S`, here-strings
   and strings piped to a shell.
2. Literal credentialed URL guard. A word embedding scheme://[user]:password@host (a password
   starting with `$` is an environment-variable reference and passes).

Per-command bypass: a LEADING, unquoted assignment on the stage it applies to, e.g.
`SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X` or
`SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql ...`. The hook's own environment and any other position
are never consulted, so the bypass is visible in the transcript and cannot be left on.

Known limits (a seatbelt against the accident, not a sandbox): aliases, functions, variable
indirection, symlinked redirect targets, a quoted command string handed to ssh/docker/su, and that `doppler run -- env` / `printenv` print everything because the child
decides. Heredoc bodies are read as ordinary command lines, so a heredoc that only quotes
`doppler secrets get X` is denied too.
"""

import json
import os
import posixpath
import re
import sys

URL_RE = re.compile(
    r"(?:postgres(?:ql)?|mysql|mongodb|redis|rediss|amqps?)(?:\+[a-z0-9.+-]+)?"
    r"://[^:@/\s]*:(?!\$)[^@/\s]+@[^/\s]+",
    re.I,
)
BYPASS_DOPPLER = "SASSYDOG_ALLOW_DOPPLER_PRINT=1"
BYPASS_URL = "SASSYDOG_ALLOW_CREDENTIAL_URL=1"

SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ash", "fish", "pwsh", "csh", "tcsh"}
KEYWORDS = {"if", "then", "elif", "else", "do", "while", "until", "!", "{"}
PRINT_SUBCMDS = {"get", "download", "substitute"}
OTHER_SECRETS_SUBCMDS = {"set", "delete", "upload", "names", "notes", "update", "help"}
# Doppler global flags that take a separate value (so the value is not the subcommand).
VALUE_FLAGS = {"-p", "--project", "-c", "--config", "--token", "-t", "--scope", "--api-host",
               "--configuration", "--config-dir"}
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_DEPTH = 8

SAFE_FORMS = (
    "Safe forms: `doppler secrets --only-names`, `doppler run -- <cmd>` (the child reads the "
    "value from its environment; the child's own `doppler secrets get` is still denied), or a "
    "redirect of stdout to a real file (`> /tmp/f`; /dev/*, /proc/*, process substitution and "
    "a later >&2 are not files)."
)
DOPPLER_MSG = (
    "`doppler secrets {shown}` prints secret values to the transcript. " + SAFE_FORMS +
    " Deliberate override for one command: prefix it with SASSYDOG_ALLOW_DOPPLER_PRINT=1."
)
URL_MSG = (
    "the command embeds a URL with a literal password (scheme://user:password@host). "
    "Pass the value through the environment instead (`doppler run -- <cmd>` and read the "
    "variable in the child). Deliberate override for one command: prefix it with "
    "SASSYDOG_ALLOW_CREDENTIAL_URL=1."
)
DEEP_MSG = "command nests too deeply to classify; denied rather than guessed. " + SAFE_FORMS


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
                    e = s[i + 1]
                    if e == "\n":
                        pass
                    elif e in '$`"\\':
                        cur.append(e)
                    else:
                        cur.append(d + e)
                    i += 2
                elif d == "$" and s[i + 1:i + 2] == "(" and s[i + 1:i + 3] != "((":
                    j = match_paren(s, i + 2)
                    seg.subs.append(s[i + 2:j])
                    cur.append("\0")
                    i = j + 1
                elif d == "$" and s[i + 1:i + 2] == "{":
                    j = s.find("}", i + 2)
                    j = n - 1 if j < 0 else j
                    body = s[i:j + 1]
                    seg.subs.extend(extract_subs(body))
                    cur.append(body)
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


def leading_bypass(words):
    """(doppler bypass, url bypass) from LEADING unquoted assignments of this stage only."""
    d = u = False
    for w in words:
        if not w.q and w in KEYWORDS:
            continue
        if ASSIGN_RE.match(w) and not w.q:
            d = d or w == BYPASS_DOPPLER
            u = u or w == BYPASS_URL
            continue
        break
    return d, u


def real_file(target):
    """True when a redirect target is a regular file (or /dev/null), judged on a normalised path."""
    if not target or "$" in target or "\0" in target or "`" in target:
        return False  # cannot be resolved here; fail closed
    t = re.sub(r"/+", "/", target)
    t = posixpath.normpath(t)
    if t.startswith(".."):
        return False  # climbs out of an unknown cwd
    if t == "/dev/null":
        return True
    return not (t == "/dev" or t.startswith("/dev/") or t == "/proc" or t.startswith("/proc/"))


def stdout_to_file(words):
    """True when, after every redirect in order, stdout ends up in a real file."""
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
                continue  # `>` ending the stage is `>(...)`: process substitution, not a file
            target = nxt
        if target.startswith("&"):
            dup = target[1:]
            if dup == "1":
                continue
            if dup == "-":
                dest = "file"
            elif dup.isdigit():
                dest = "term"
            else:  # `>&word` redirects stdout and stderr to the file `word`
                dest = "file" if real_file(dup) else "term"
            continue
        dest = "file" if real_file(target) else "term"
    return dest == "file"


def only_names(rest):
    state = False
    for a in rest:
        if a == "--only-names":
            state = True
        elif a.startswith("--only-names="):
            state = a.split("=", 1)[1].lower() in ("true", "1", "t")
    return state


def subcommand(rest):
    """First positional word that is not a flag or a known flag's value; None when absent."""
    k = 0
    while k < len(rest):
        a = rest[k]
        if a.startswith("-") and len(a) > 1:
            k += 2 if a in VALUE_FLAGS else 1
            continue
        return a
    return None


def classify_doppler(words, k, byp):
    """Violations for the doppler word at words[k]."""
    if byp[0]:
        return []
    args = words[k + 1:]
    first = next((a for a in args if a in ("run", "secrets")), None)
    if first != "secrets":
        return []  # `doppler run ...` (the child is not classified) or a non-printing command
    rest = args[args.index("secrets") + 1:]
    sub = subcommand(rest)
    if sub in OTHER_SECRETS_SUBCMDS:
        return []
    if "--help" in rest or "-h" in rest:
        return []
    if only_names(rest) or stdout_to_file(words):
        return []
    return [DOPPLER_MSG.format(shown=sub if sub in PRINT_SUBCMDS else ("(bare)" if sub is None else sub))]


def shell_script(words, k):
    """The -c script string of the shell at words[k], or None when it has no -c."""
    for j in range(k + 1, len(words)):
        a = words[j]
        if not (a.startswith("-") and len(a) > 1):
            continue
        if (not a.startswith("--") and "c" in a[1:]) or a.lower() == "-command":
            j += 1
            while j < len(words) and words[j] == "--":
                j += 1
            return words[j] if j < len(words) else None
    return None


def env_strings(words, k):
    """Command strings handed to `env -S` / `--split-string` (clusters and attached forms)."""
    vals = []
    for j in range(k + 1, len(words)):
        a = words[j]
        if a.startswith("--split-string="):
            vals.append(a.split("=", 1)[1])
        elif a == "--split-string" and j + 1 < len(words):
            vals.append(words[j + 1])
        elif a.startswith("-") and not a.startswith("--") and "S" in a[1:]:
            idx = a.index("S", 1)
            rest = a[idx + 1:]
            if rest:
                vals.append(rest)
            elif j + 1 < len(words):
                vals.append(words[j + 1])
    return vals


def is_shellish(words):
    return any(os.path.basename(w) in SHELLS or w in ("source", ".", "eval") for w in words)


def scan_stage(seg, depth, byp, ctx):
    words = seg.words
    d, u = leading_bypass(words)
    byp = (byp[0] or d, byp[1] or u)
    out = []
    for sub in seg.subs:
        out += analyze(sub, depth + 1, byp, ctx)
    for w in words:
        if URL_RE.search(w):
            ctx["url_seen"] += 1
            if not byp[1]:
                out.append(URL_MSG)
    shellish = is_shellish(words)
    for k, w in enumerate(words):
        name = os.path.basename(w)
        if name == "doppler":
            out += classify_doppler(words, k, byp)
        elif name in SHELLS:
            script = shell_script(words, k)
            if script is not None:
                out += analyze(script, depth + 1, byp, ctx)
        elif name == "env":
            for text in env_strings(words, k):
                out += analyze(text, depth + 1, byp, ctx)
        elif w == "eval":
            out += analyze(" ".join(words[k + 1:]), depth + 1, byp, ctx)
        if name == "doppler":
            for j in range(k + 1, len(words)):
                if words[j] == "--command" and j + 1 < len(words):
                    out += analyze(words[j + 1], depth + 1, byp, ctx)
                elif words[j].startswith("--command="):
                    out += analyze(words[j].split("=", 1)[1], depth + 1, byp, ctx)
        if w == "<<<" and not w.q and shellish and k + 1 < len(words):
            out += analyze(words[k + 1], depth + 1, byp, ctx)
    return out


def analyze(text, depth, byp, ctx):
    if depth > MAX_DEPTH:
        return [DEEP_MSG]
    out = []
    segs = lex(text)
    k = 0
    while k < len(segs):
        pipeline = [segs[k]]
        while pipeline[-1].sep == "|" and k + len(pipeline) < len(segs):
            pipeline.append(segs[k + len(pipeline)])
        k += len(pipeline)
        last_shell = max((j for j, st in enumerate(pipeline) if j > 0 and is_shellish(st.words)),
                         default=0)
        for idx, seg in enumerate(pipeline):
            out += scan_stage(seg, depth, byp, ctx)
            if idx < last_shell:
                # Text piped into a shell is a command: `echo 'doppler secrets get X' | bash`.
                out += analyze(" ".join(seg.words), depth + 1, byp, ctx)
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
        ctx = {"url_seen": 0}
        problems = analyze(command, 0, (False, False), ctx)
        if URL_RE.search(command) and ctx["url_seen"] == 0:
            # A URL in text no stage word carries (a comment): no stage to anchor a bypass
            # on, so only a leading bypass on the command's first stage clears it.
            first = lex(command)
            if not (first and leading_bypass(first[0].words)[1]):
                problems.append(URL_MSG)
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
