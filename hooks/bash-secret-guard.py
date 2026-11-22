"""bash-secret-guard.py — PreToolUse(Bash) classifier for the sassy-dog plugin.

Reads the harness's JSON event on stdin. Exit 0 allows, exit 2 denies (the reason goes to
stderr, which the harness feeds to the model), exit 1 means "could not classify": the guard
FAILS OPEN there and says so on stderr (Claude Code shows stderr of any non-0/2 exit as a
non-blocking error). It never prints to stdout.

Two rules, both over the raw command text only (a PreToolUse hook cannot see output). There
is no shell parser anywhere: every shell-parsing classifier tried here lost to a new spelling,
so the Doppler rule is a WHOLE-COMMAND ALLOW LIST matched on the raw string, which cannot
disagree with itself about quoting.

1. Doppler value-printing guard, deny by construction.
   Trigger: the command mentions `doppler` in any spelling the text can show. The raw text is
   lower-cased, Unicode-folded and ANSI-C escapes are decoded; then `doppler` is looked for
   both as written and with every character that is not a letter, digit or whitespace removed
   (so `DOPPLER`, `$'\\x64oppler'`, `d"o"ppler`, `dopp\\ler`, `{doppler,}`, `doppl[e]r`,
   `dop*ler` all trigger; a backslash-newline is removed first, as the shell joins the lines;
   the ANSI-C escapes x, u, U, octal, c and e are decoded). A second trigger covers a command name the text does not
   spell (`${X}pler secrets get`): a shell expansion or glob character plus a value-printing
   doppler phrase (`secrets get|download|substitute`, `configure get|--all`, `configs
   tokens`, `--print-config`), or plus a bare `secrets`, `configure`, `run` or `me` argument
   later in the same simple command (`dop*ler secrets`, `"$D" run`; `ls $HOME/secrets` and
   `gh run view $ID` stay quiet). That search runs on text with quotes and backslashes removed
   (`dop*ler sec''rets`, `$D con''figure`, `$D \\me`) and on segments split quote-aware, so a
   quoted `;` (`"$D" --scope=';' secrets`) does not hide the subcommand from the glob.
   A triggered command is allowed only if the ENTIRE command is exactly one of:
     1. `doppler [global flags] secrets [flags] --only-names`, optionally followed by one of
        `| wc -l`, `| head -n N`, `| grep [-cqxFiwv] LITERAL` (names only, so nothing to leak)
     2. `doppler [global flags] run [flags] -- <rest>` or `run --command '<string>'`, where
        <rest> is a single simple command line that does not itself trigger and has no
        `$(`, backtick, `<(`, `>(`
     3. `doppler secrets get NAME... [flags] > <literal path>`, `secrets download --no-file
        [flags] > <literal path>`, `secrets download [flags] <literal path>`, and
        `secrets substitute <template> [flags] (> | --output) <literal path>`
     3b. `doppler secrets get NAME --plain | gh secret set NAME [--repo R ...]` (gh reads the
        value from stdin and prints none of it; no `--body`, no other consumer)
     3c. the secret_bootstrap shape `eval "$(doppler secrets download --no-file --format env
        [-p P] [-c C] [2>/dev/null])"` (exactly that: no other format, no --name-transformer,
        no global flag), alone or followed by `&& <one command>` that does not mention doppler,
        expands no variable (`$`) and does not dump the environment (env, printenv, set,
        declare, typeset, export, compgen, `environ`, /proc, also inside a `-c` string). The
        eval consumes the output, so the loaded secrets live in the shell: the tail is where
        they would print. The gate extracts every doppler command under skills/ and requires it
        to pass)
     4. a bare non-printing subcommand: login, logout, setup, configs, projects,
        environments, me, update, activity, changelog, open, settings, flags, help,
        --version, --help
   where "exactly one" means: a single simple command (no ; & | && || newline, backtick, $(,
   <(, >(, <<, <, >& ...), no environment prefix, no wrapper, the command word is the literal
   lower-case `doppler`, every flag is on an explicit per-subcommand allow list with a literal
   value that does not start with `-`, and an unknown flag denies (`--debug` and `--api-host`
   are on no list: one logs requests, the other would send the token to any host). A literal path has only
   [A-Za-z0-9._/~-], no `.`/`..` segment, is not under /dev, /proc or /sys (case-folded), and a relative
   path may not start with a device-like segment (fd, stdout, tty, ...); a relative path is also
   resolved against the event's `cwd` (a previous call may have done `cd /dev`).
2. Literal credentialed URL guard. The raw text embeds scheme://[user]:password@host (scheme
   postgres(ql)/mysql/mongodb/redis(s)/amqp(s), optional +driver, case-insensitive). A password
   that starts with an unquoted `$name`, `${` or `$(` is an environment reference and passes;
   inside single quotes `$` is literal and does not.

Per-command bypass: LEADING, unquoted `SASSYDOG_ALLOW_DOPPLER_PRINT=1` /
`SASSYDOG_ALLOW_CREDENTIAL_URL=1` assignments, honoured only when the rest of the command is a
single simple command (no ; & | newline, backtick, $(, <(, >( outside single quotes). Never by
substring, never from the hook's own environment.

Known limits (a seatbelt against the accident, not a sandbox): aliases and functions, a command
name assembled at run time from pieces the text never spells (printf formatting), symlinked
redirect targets, a redirected file that is read back afterwards, `doppler run -- env` /
`printenv` / `doppler run --command 'echo $X'` (a child can print its own environment: the
child decides), a bootstrap tail that runs a script which itself prints the environment, a
relative redirect when the event carries no `cwd`, `password=` / `?password=` URL forms, and false denies for any
text that merely mentions doppler (a commit message, a PR body): use the bypass.
"""

import json
import os
import re
import sys
import unicodedata

URL_RE = re.compile(
    r"(?:postgres(?:ql)?|mysql|mongodb|redis|rediss|amqps?)(?:\+[a-z0-9.+-]+)?"
    r"://[^:@/\s]*:([^@/\s]+)@[^/\s]+",
    re.I,
)
BYPASS_DOPPLER = "SASSYDOG_ALLOW_DOPPLER_PRINT=1"
BYPASS_URL = "SASSYDOG_ALLOW_CREDENTIAL_URL=1"
BYPASS_PREFIX_RE = re.compile(
    r"^\s*((?:(?:SASSYDOG_ALLOW_DOPPLER_PRINT|SASSYDOG_ALLOW_CREDENTIAL_URL)=1[ \t]+)+)"
)

SAFE_FORMS = (
    "Allowed forms (the whole command, nothing else): `doppler secrets --only-names`; "
    "`doppler run -- <cmd>` (the child reads values from its environment; the child may not "
    "mention doppler); `doppler secrets get NAME --plain > /literal/path` (also `download` and "
    "`substitute`; the file is yours, reading it back is your responsibility); "
    "`doppler secrets get NAME --plain | gh secret set NAME`; `eval \"$(doppler secrets download "
    "--no-file --format env 2>/dev/null)\"` (alone, or before `&& <command>` that expands no "
    "variable and dumps no environment); a bare "
    "non-printing subcommand such as `doppler setup` or `doppler configs`."
)
DOPPLER_MSG = (
    "this command mentions doppler and is not one of the allowed Doppler forms, so it could "
    "print secret values to the transcript. " + SAFE_FORMS + " Text that merely mentions the "
    "word (a commit message, a PR body) is denied too. Deliberate override for one single "
    "command: prefix it with SASSYDOG_ALLOW_DOPPLER_PRINT=1."
)
URL_MSG = (
    "the command embeds a URL with a literal password (scheme://user:password@host). "
    "Pass the value through the environment instead (`doppler run -- <cmd>` and read the "
    "variable in the child). Deliberate override for one single command: prefix it with "
    "SASSYDOG_ALLOW_CREDENTIAL_URL=1."
)

# ---- trigger -------------------------------------------------------------------------------

EXPANSION_RE = re.compile(r"[$`{*?\[]")
# Words that make a command that Doppler's CLI would run, for a command NAME the text does not spell.
SUBCOMMAND_WORDS = ("secrets", "configure", "run", "me")
QUOTES_RE = re.compile(r"['\"\\]")
LINE_CONTINUATION_RE = re.compile(r"\\\r?\n")


def _chr(code):
    try:
        return chr(code)
    except (ValueError, OverflowError):
        return "\ufffd"


def decode_escapes(s):
    """Decode the ANSI-C escapes a `$'...'` word can carry (over-applied to the whole text)."""
    s = re.sub(r"\\x([0-9a-fA-F]{1,2})", lambda m: _chr(int(m.group(1), 16)), s)
    s = re.sub(r"\\u([0-9a-fA-F]{1,4})", lambda m: _chr(int(m.group(1), 16)), s)
    s = re.sub(r"\\U([0-9a-fA-F]{1,8})", lambda m: _chr(int(m.group(1), 16)), s)
    s = re.sub(r"\\([0-7]{1,3})", lambda m: _chr(int(m.group(1), 8) & 0xFF), s)
    s = re.sub(r"\\c(.)", lambda m: _chr(ord(m.group(1)) & 0x1F), s, flags=re.S)
    s = s.replace("\\e", "\x1b").replace("\\E", "\x1b")
    return s


def triggered(text):
    # A backslash-newline is a line continuation: the shell joins the halves of a word.
    text = LINE_CONTINUATION_RE.sub("", text)
    # Decode BEFORE folding case: `\U` and `\u` are different escapes (eight digits and four).
    plain = unicodedata.normalize("NFKC", text)
    decoded = unicodedata.normalize("NFKC", decode_escapes(plain)).lower()
    plain = plain.lower()
    # Both readings: a backslash before `e` or `c` is a plain letter outside `$'...'`, and the
    # decoder would turn it into a control character and drop the letter.
    return _mentions(plain) or (decoded != plain and _mentions(decoded))


def _mentions(t):
    if "doppler" in t:
        return True
    if "doppler" in re.sub(r"[^a-z0-9\s]", "", t):
        return True
    if EXPANSION_RE.search(t):
        n = QUOTES_RE.sub("", t)
        w = lambda *names: all(re.search(r"\b" + x + r"\b", n) for x in names)  # noqa: E731
        if (w("secrets") and any(re.search(r"\b" + x + r"\b", n) for x in ("get", "download", "substitute"))) \
                or (w("configure") and (w("get") or "--all" in n)) \
                or w("configs", "tokens") or "print-config" in n:
            return True
        # An expansion or glob in a command NAME (`${X}pler secrets`, `dop*ler me`, `"$D" run`):
        # an expansion character, then later in the same simple command a Doppler subcommand as a
        # whole argument (not a path piece: `ls $HOME/secrets`, `/run/pw` stay quiet).
        for seg in split_segments(t):
            seg = QUOTES_RE.sub("", seg)  # `sec''rets`, `s\\ecrets`, `"$D"` read as the shell reads them
            m = EXPANSION_RE.search(seg)
            if m and any(re.search(r"(?:^|\s)" + n + r"(?=$|\s)", seg[m.start():])
                         for n in SUBCOMMAND_WORDS):
                return True
    return False


def split_segments(s):
    """Split at ; & | newline outside quotes, so `--scope=';' secrets` stays one simple command.

    Quote-aware on purpose: splitting inside a quote hid the later subcommand word from the
    earlier glob. `$'...'` honours a backslash. An unbalanced quote runs to the end, which keeps
    more text together and so can only trigger more, never less.
    """
    segs, start, quote, i, ansi_c = [], 0, None, 0, False
    while i < len(s):
        c = s[i]
        if quote == "'":
            if c == "\\" and ansi_c:
                i += 1
            elif c == "'":
                quote = None
        elif quote == '"':
            if c == "\\":
                i += 1
            elif c == '"':
                quote = None
        elif c == "\\":
            i += 1
        elif c in "'\"":
            quote = c
            ansi_c = c == "'" and i > 0 and s[i - 1] == "$"
        elif c in ";&|\n\r":
            segs.append(s[start:i])
            start = i + 1
        i += 1
    segs.append(s[start:])
    return segs


# ---- single simple command, quote-aware ------------------------------------------------------


def single_simple(s):
    """True when s has no control operator outside single quotes (and no unbalanced quote)."""
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        nxt = s[i + 1] if i + 1 < len(s) else ""
        if quote == "'":
            if c == "'":
                quote = None
        elif quote == '"':
            if c == "\\":
                i += 1
            elif c == '"':
                quote = None
            elif c == "`" or (c == "$" and nxt == "("):
                return False
        else:
            if c == "\\":
                i += 1
            elif c in "'\"":
                quote = c
            elif c in ";&|<>()\n\r`" or (c == "$" and nxt == "("):
                return False
        i += 1
    return quote is None


class QuoteScanner:
    """Quote state at ascending positions in one pass (one scan per command, not one per match)."""

    def __init__(self, s):
        self.s, self.i, self.quote = s, 0, None

    def in_single(self, pos):
        s = self.s
        while self.i < pos:
            c = s[self.i]
            if self.quote == "'":
                if c == "'":
                    self.quote = None
            elif self.quote == '"':
                if c == "\\":
                    self.i += 1
                elif c == '"':
                    self.quote = None
            else:
                if c == "\\":
                    self.i += 1
                elif c in "'\"":
                    self.quote = c
            self.i += 1
        return self.quote == "'"


# ---- the allow list --------------------------------------------------------------------------

STRICT_RE = re.compile(r"[A-Za-z0-9._/@:=,+~ \t|>-]*")
VALUE_RE = re.compile(r"[A-Za-z0-9._/@:-]+")
NAME_RE = re.compile(r"[A-Za-z0-9_]+")
PATH_RE = re.compile(r"[A-Za-z0-9._/~-]+")
DEVLIKE = {"fd", "stdin", "stdout", "stderr", "tty", "console", "pts", "ptmx", "self", "dev",
           "proc", "sys", "null"}
PIPE_OK_RE = re.compile(
    r"wc -l|head -n [0-9]+|grep(?: -[cqxFiwv]+)? [A-Za-z0-9_.-]+"
)
# `doppler secrets get NAME --plain | gh secret set NAME [...]`: gh reads the value from its
# stdin and prints nothing of it. No `-b/--body` (it would replace stdin) and no other consumer.
GH_SET_RE = re.compile(
    r"gh secret set [A-Za-z_][A-Za-z0-9_]*"
    r"(?: (?:-R|--repo|-e|--env|-a|--app|-o|--org|-v|--visibility) [A-Za-z0-9._/@:-]+| --no-store)*"
)
# The secret_bootstrap shape: `eval "$(doppler secrets download --no-file ...)"`. The shell
# consumes the output, nothing prints it. Only `2>/dev/null` may ride inside the substitution.
BOOTSTRAP_RE = re.compile(
    r'eval "\$\((doppler[ \t][A-Za-z0-9._/@:=, \t-]*?)(?:[ \t]+2>/dev/null)?\)"'
)

# Flags are taken from `doppler --help`, `doppler help secrets [get|download|substitute]` and
# `doppler run --help` (CLI v3.76). Left out on purpose: -t/--token and --passphrase (a
# credential on the command line), --copy, --print-config, --no-verify-tls, --mount, --fallback,
# --debug (it logs requests) and --api-host (it would send the token to any host).
GLOBAL_BOOL = {"--json", "--no-check-version", "--no-read-env", "--no-timeout",
               "--enable-dns-resolver", "--silent"}
GLOBAL_VAL = {"--attempts", "--config-dir", "--dashboard-host",
              "--dns-resolver-address", "--dns-resolver-proto", "--dns-resolver-timeout",
              "--scope", "--timeout"}
PC_VAL = {"-p", "--project", "-c", "--config"}
SECRETS_BOOL = {"--only-names", "--raw", "--type", "--visibility"}
GET_BOOL = {"--plain", "--raw", "--type", "--visibility", "--no-exit-on-missing-secret"}
DOWNLOAD_BOOL = {"--no-file", "--no-cache", "--no-fallback", "--no-exit-on-write-failure"}
DOWNLOAD_VAL = {"--format", "--name-transformer", "--dynamic-ttl"}
SUBST_VAL = {"--use-env", "--dynamic-ttl", "--output"}
RUN_BOOL = {"--no-cache"}
RUN_VAL = {"--name-transformer", "--format", "--dynamic-ttl"}
BARE_SUBS = {
    "login": (set(), set()),
    "logout": (set(), set()),
    "setup": ({"--no-interactive", "--no-save-token"}, PC_VAL),
    "configs": (set(), {"-p", "--project", "-e", "--environment", "-n", "--number", "--page"}),
    "projects": (set(), {"-n", "--number", "--page"}),
    "environments": (set(), {"-p", "--project", "-n", "--number", "--page"}),
    "me": (set(), set()),
    "update": (set(), set()),
    "activity": (set(), {"-n", "--number", "--page"}),
    "changelog": (set(), set()),
    "open": (set(), set()),
    "settings": (set(), set()),
    "flags": (set(), set()),
}
INFO_FLAGS = {"--version", "-v", "--help", "-h"}


CWD = None  # the event's working directory, set per command by analyze()


def literal_path(p):
    if not PATH_RE.fullmatch(p) or p.startswith("-"):
        return False
    if not p.startswith(("/", "~")) and CWD and not _cwd_ok(p):
        return False
    if "~" in p and not (p.startswith("~/") and p.count("~") == 1):
        return False
    segs = p.split("/")
    for k, seg in enumerate(segs):
        if seg in (".", "..") or (seg == "" and k != 0):
            return False
    # Folded: on a case-insensitive filesystem `/DEV/stdout` is `/dev/stdout`.
    low = p.lower()
    if p.startswith("/"):
        return not any(low == r or low.startswith(r + "/") for r in ("/dev", "/proc", "/sys"))
    return segs[0].lower() not in DEVLIKE


def _cwd_ok(p):
    """A relative target resolved against the shell's cwd (a previous call may have done `cd /dev`)."""
    low = os.path.realpath(os.path.join(CWD, p)).lower()
    return not any(low == r or low.startswith(r + "/") for r in ("/dev", "/proc", "/sys"))


def parse_args(toks, i, bools, vals):
    """Flags (from the given sets) and positionals starting at toks[i]; None on anything else."""
    flags = {}
    pos = []
    while i < len(toks):
        t = toks[i]
        if t.startswith("-"):
            name, eq, val = t.partition("=")
            if name in bools and not eq:
                flags[name] = True
                i += 1
            elif name in vals:
                if eq:
                    v = val
                    i += 1
                elif i + 1 < len(toks):
                    v = toks[i + 1]
                    i += 2
                else:
                    return None
                if not VALUE_RE.fullmatch(v) or v.startswith("-"):
                    return None
                flags[name] = v
            else:
                return None
        else:
            pos.append(t)
            i += 1
    return flags, pos


def parse_global(toks):
    """Leading global flags after `doppler`: (index of the subcommand, flags) or None."""
    i = 1
    glob = {}
    while i < len(toks) and toks[i].startswith("-"):
        name, eq, val = toks[i].partition("=")
        if name in GLOBAL_BOOL and not eq:
            glob[name] = True
            i += 1
        elif name in GLOBAL_VAL:
            if eq:
                v = val
                i += 1
            elif i + 1 < len(toks):
                v = toks[i + 1]
                i += 2
            else:
                return None
            if not VALUE_RE.fullmatch(v) or v.startswith("-"):
                return None
            glob[name] = v
        else:
            return None
    return i, glob


def split_redirect(toks):
    """(tokens without the redirect, path or None); None when a `>` is anywhere but last-but-one."""
    n = toks.count(">")
    if n == 0:
        return toks, None
    if n != 1 or len(toks) < 2 or toks[-2] != ">":
        return None
    return toks[:-2], toks[-1]


def check_rest(rest):
    """The child of `doppler run --`: one simple command line that cannot name doppler."""
    if not rest.strip() or "\n" in rest or "\r" in rest:
        return False
    if any(x in rest for x in ("$(", "`", "<(", ">(")):
        return False
    return single_simple(rest) and not triggered(rest)


def allowed_run(cmd):
    m = re.fullmatch(r"(doppler[ \t][A-Za-z0-9._/@:=, \t-]*?)[ \t]--command[ \t]'([^']*)'", cmd)
    if m:
        head, string = m.group(1), m.group(2)
        if not check_string(string):
            return False
    else:
        head, sep, rest = cmd.partition(" -- ")
        if not sep or not check_rest(rest):
            return False
    if not STRICT_RE.fullmatch(head) or any(c in head for c in "|>"):
        return False
    toks = head.split()
    if not toks or toks[0] != "doppler":
        return False
    parsed = parse_args(toks, 1, GLOBAL_BOOL | RUN_BOOL, GLOBAL_VAL | PC_VAL | RUN_VAL)
    return bool(parsed) and parsed[1] == ["run"]


def check_string(s):
    return bool(s.strip()) and not any(x in s for x in ("$(", "`", "<(", ">(")) and not triggered(s)


def allowed_strict(cmd):
    """True when the whole command is exactly one of the allowed Doppler forms."""
    cmd = cmd.strip()
    if not cmd:
        return False
    if cmd.startswith("eval "):
        return allowed_bootstrap(cmd)
    if cmd.startswith("doppler ") and (" -- " in cmd or " --command " in cmd) and \
            re.match(r"doppler[ \t]+(?:[^ \t]+[ \t]+)*?run\b", cmd):
        return allowed_run(cmd)
    if not STRICT_RE.fullmatch(cmd):
        return False
    toks = cmd.split()
    for t in toks:
        if t not in ("|", ">") and ("|" in t or ">" in t):
            return False
    if not toks or toks[0] != "doppler":
        return False
    tail = None
    if "|" in toks:
        k = toks.index("|")
        toks, tail = toks[:k], toks[k + 1:]
        joined = " ".join(tail)
        if "|" in tail or ">" in tail or not (PIPE_OK_RE.fullmatch(joined) or GH_SET_RE.fullmatch(joined)):
            return False
    split = split_redirect(toks)
    if split is None:
        return False
    toks, redirect = split
    if redirect is not None and (tail is not None or not literal_path(redirect)):
        return False
    rest = toks[1:]
    # info
    if rest and (rest[0] in INFO_FLAGS or rest[0] == "help") and tail is None and redirect is None:
        return len(rest) == 1 or (rest[0] == "help" and len(rest) <= 3 and all(re.fullmatch(r"[a-z]+", x) for x in rest[1:]))
    if rest[:2] in (["run", "--help"], ["run", "-h"]) and len(rest) == 2:
        return tail is None and redirect is None
    # global flags, then the subcommand
    g = parse_global(toks)
    if g is None:
        return False
    i, glob = g
    if i >= len(toks):
        return False
    sub = toks[i]
    if sub == "secrets":
        return allowed_secrets(toks, i + 1, redirect, tail)
    if sub in BARE_SUBS and tail is None and redirect is None:
        bools, vals = BARE_SUBS[sub]
        if sub == "me":
            return i + 1 == len(toks) and not glob
        parsed = parse_args(toks, i + 1, GLOBAL_BOOL | bools, GLOBAL_VAL | vals)
        return bool(parsed) and not parsed[1]
    return False


ENV_DUMPERS = {"set", "declare", "typeset", "export", "readonly", "compgen", "local"}
WRAPPERS = {"eval", "exec", "command", "builtin", "sudo", "nice", "nohup", "time", "xargs", "then",
            "do", "else", "!"}


def tail_prints_env(rest):
    """True when the command after a bootstrap's `&&` could print the secrets it just loaded.

    The loaded values live in the environment, so the tail may not expand a variable (`$`) and
    may not dump the environment: `env`/`printenv`/`environ`/`ENV` anywhere in the text (also
    inside a `bash -c`, `python -c`, `perl -e` string), or `set`, `declare`, `typeset`, `export`,
    `readonly`, `compgen`, `local` where a command word stands (first word of a segment, or after
    a wrapper or a `-c` option). `gh secret set X` is not a command-word `set`.
    """
    n = QUOTES_RE.sub("", rest).lower()
    if "$" in n or "env" in n or "/proc" in n:
        return True
    for seg in re.split(r"[;&|(){}`\n\r]+", n):
        toks = seg.split()
        for k, tok in enumerate(toks):
            if tok.rsplit("/", 1)[-1] not in ENV_DUMPERS:
                continue
            prev = toks[k - 1] if k else None
            if prev is None or prev in WRAPPERS or (prev.startswith("-") and prev.endswith("c")):
                return True
    return False


def allowed_bootstrap(cmd):
    """`eval "$(doppler secrets download --no-file --format env ...)"`, alone or before `&& <one command>`.

    Exactly `secrets download --no-file --format env` plus -p/-c. Doppler's default format is
    json, and eval of json, env-no-quotes or a --name-transformer output prints the values in
    eval's own error text, so no other format, no transformer, no global flag rides here.
    """
    m = BOOTSTRAP_RE.match(cmd)
    if not m:
        return False
    after = cmd[m.end():]
    if after.strip():
        mm = re.fullmatch(r"[ \t]+&&[ \t]+(.+)", after, re.S)
        if not mm or not check_rest(mm.group(1)) or tail_prints_env(mm.group(1)):
            return False
    toks = m.group(1).split()
    if toks[0] != "doppler":
        return False
    parsed = parse_args(toks, 1, {"--no-file"}, PC_VAL | {"--format"})
    return bool(parsed) and parsed[1] == ["secrets", "download"] \
        and parsed[0].get("--no-file") is True and parsed[0].get("--format") == "env"


def allowed_secrets(toks, i, redirect, tail):
    probe = parse_args(toks, i, GLOBAL_BOOL | SECRETS_BOOL | GET_BOOL | DOWNLOAD_BOOL | RUN_BOOL,
                       GLOBAL_VAL | PC_VAL | DOWNLOAD_VAL | SUBST_VAL)
    if probe is None:
        return False
    sub = probe[1][0] if probe[1] else None
    if sub is None:
        # form 1: names only
        parsed = parse_args(toks, i, GLOBAL_BOOL | SECRETS_BOOL, GLOBAL_VAL | PC_VAL)
        return bool(parsed) and parsed[0].get("--only-names") is True and not parsed[1] \
            and redirect is None
    if tail is not None and sub != "get":
        return False
    if sub == "get":
        parsed = parse_args(toks, i, GLOBAL_BOOL | GET_BOOL, GLOBAL_VAL | PC_VAL)
        if not parsed or parsed[1][0] != "get" or len(parsed[1]) < 2:
            return False
        names_ok = all(NAME_RE.fullmatch(n) for n in parsed[1][1:])
        if tail is not None:
            # only the gh pipe reaches here with a tail; one name, --plain, no redirect
            return GH_SET_RE.fullmatch(" ".join(tail)) is not None and names_ok \
                and len(parsed[1]) == 2 and parsed[0].get("--plain") is True and redirect is None
        return redirect is not None and names_ok
    if sub == "download":
        parsed = parse_args(toks, i, GLOBAL_BOOL | DOWNLOAD_BOOL, GLOBAL_VAL | PC_VAL | DOWNLOAD_VAL)
        if not parsed or parsed[1][0] != "download":
            return False
        flags, pos = parsed
        if flags.get("--no-file"):
            return len(pos) == 1 and redirect is not None
        return len(pos) == 2 and redirect is None and literal_path(pos[1])
    if sub == "substitute":
        parsed = parse_args(toks, i, GLOBAL_BOOL, GLOBAL_VAL | PC_VAL | SUBST_VAL)
        if not parsed or parsed[1][0] != "substitute" or len(parsed[1]) != 2:
            return False
        flags, pos = parsed
        if not literal_path(pos[1]):
            return False
        out = flags.get("--output")
        if (out is None) == (redirect is None):
            return False
        return out is None or literal_path(out)
    return False


# ---- bypass and URL --------------------------------------------------------------------------


def split_bypass(cmd):
    """(doppler bypass, url bypass, body): leading assignments count only on a single command."""
    m = BYPASS_PREFIX_RE.match(cmd)
    if not m:
        return False, False, cmd
    body = cmd[m.end():]
    if not single_simple(body):
        return False, False, cmd
    toks = m.group(1).split()
    return BYPASS_DOPPLER in toks, BYPASS_URL in toks, body


def url_violation(text):
    scan = QuoteScanner(text)
    for m in URL_RE.finditer(text):
        pw = m.group(1)
        if re.match(r"\$[A-Za-z_{(]", pw) and not scan.in_single(m.start(1)):
            continue
        return True
    return False


def analyze(command, cwd=None):
    global CWD
    CWD = cwd if isinstance(cwd, str) and cwd.startswith("/") else None
    bd, bu, body = split_bypass(command)
    problems = []
    if not bd and triggered(body) and not allowed_strict(body):
        problems.append(DOPPLER_MSG)
    if not bu and url_violation(body if (bd or bu) else command):
        problems.append(URL_MSG)
    return problems


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
    except (ValueError, RecursionError):  # RecursionError: a pathologically nested document
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
        problems = analyze(command, event.get("cwd"))
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
