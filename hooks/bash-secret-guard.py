"""bash-secret-guard.py — PreToolUse(Bash) classifier for the sassy-dog plugin.

Reads the harness's JSON event on stdin. Exit 0 allows, exit 2 denies (the reason goes to
stderr, which the harness feeds to the model), exit 1 means "could not classify": the guard
FAILS OPEN there and says so on stderr (Claude Code shows stderr of any non-0/2 exit as a
non-blocking error). It never prints to stdout.

Two rules, both over the raw command text only (a PreToolUse hook cannot see output). There
is no general shell parser (the two tokenizers, sanitize() and _inert_view(), each recognise a tiny
allow-listed grammar and give up on anything else): every shell-parsing classifier tried here lost to a new spelling,
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
   quoted `;` (`"$D" --scope=';' secrets`) does not hide the subcommand from the glob. An `&`
   next to `>` or `<` (`2>&1`, `>&2`, `&>`, `<&`) is a redirect, not a separator, so it does not
   split a segment either (`dop?ler 2>&1 secrets`). A command word (the first word of a segment,
   after leading `NAME=value` assignments and redirections) that holds an expansion or glob character triggers on
   its own, whatever follows: the allow list then decides (`"$D" >&2 secrets`, `dop?ler s?crets`).
   KNOWN LIMIT (accepted, pinned as allows in the gate): that trigger inspects ONLY the first word
   of a simple command. A doppler name produced by a glob or expansion and sitting behind a prefix
   word (`time`, `!`, `{`), inside a capture (`<(...)`, a here-string `<<< $(...)`), or after a
   detached redirect target (`< in "$D" $S`, `2> out $D $S`, `&< out ...`) is not caught, but only
   when the subcommand is not spelled literally too: the second trigger still denies
   `time dop?ler secrets`, `{ dop?ler secrets; }`, `< in "$D" secrets`,
   `cat <(dop?ler secrets get X)` and `! $D run`. The
   threat model is accidental printing; these are deliberate obfuscations, in the same class as
   aliases/functions, printf-assembled names, symlink targets and the two-step symlink rename, and
   a redirected file read back. A future change that closes or reopens them is a conscious decision.
   A triggered command is allowed only if the ENTIRE command is exactly one of:
     1. `doppler [global flags] secrets [flags] --only-names`, optionally followed by one of
        `| wc -l`, `| head -n N`, `| grep [-cqxFiwv] LITERAL` (names only, so nothing to leak)
     2. `doppler [global flags] run [flags] -- <rest>` or `run --command '<string>'`, where
        <rest> is a single simple command line that does not itself trigger and has no
        `$(`, backtick, `<(`, `>(`. (#655: `--no-fallback` and `--only-secrets A,B` or
        `--only-secrets=A,B` are accepted on `run` only, and run flags (these two and `--no-cache`, `--format`,
        ...) only AFTER the `run` word; before it only global flags and -p/-c. The value is a comma list of upper-case
        names, `[A-Z_][A-Z0-9_]*(?:,[A-Z_][A-Z0-9_]*)*`, checked by ONLY_SECRETS_RE; VALUE_RE is
        unchanged for every other flag. Both only narrow the child and print nothing; on a read
        subcommand `--only-secrets` stays denied.)
     3. `doppler secrets get NAME... [flags] > <literal path>`, `secrets download --no-file
        [flags] > <literal path>`, `secrets download [flags] <literal path>`, and
        `secrets substitute <template> [flags] (> | --output) <literal path>`
     3b. `doppler secrets get NAME --plain | gh secret set NAME [--repo R ...]` (gh reads the
        value from stdin and prints none of it; no `--body`, no other consumer)
     3c. the secret_bootstrap shape `eval "$(doppler secrets download --no-file --format env
        [-p P] [-c C] [2>/dev/null])"`, as the WHOLE command and nothing after it (exactly that:
        no other format, no --name-transformer, no global flag; `&&`, `;`, a pipe or a newline
        after it denies). Each Bash call is a fresh shell, so the eval only helps a caller that
        needs the loaded shell inside one call; a follow-up command runs as
        `doppler run [-p P] [-c C] -- <command>` (form 2). The gate extracts every doppler
        command under skills/ and requires it to pass)
     3d. WRITING a secret: `doppler [global flags] secrets set NAME [-p P] [-c C] < <literal path>`
        or `... set NAME="$(cat <literal path>)" ...`, in both cases ending in `>/dev/null 2>&1`
        or `>/dev/null 2>/dev/null` (a blank before the first `>` is required, after it optional; nothing after it). `set` prints a table with the values
        unless its output is discarded, and the value comes from a file, so it never appears in
        the command text. A value on the command line (`set NAME=value`) is not allowed
     4. a bare non-printing subcommand: login, logout, setup, configs, projects,
        environments, me, update, activity, changelog, open, settings, flags, help,
        --version, --help
   where "exactly one" means: a single simple command (no ; & | && || newline, backtick, $(,
   <(, >(, <<, <, >& ...; the one exception is the 3d write form, which carries its own `< path`,
   `$(cat <path>)` and `>/dev/null 2>&1`), no environment prefix, no wrapper, the command word is the literal
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
`SASSYDOG_ALLOW_CREDENTIAL_URL=1` assignments (the first thing in the command: a `cd x &&` before
it makes it an ordinary argument), honoured only when the rest of the command is a single simple
command (no ; & | newline, backtick, $(, <(, >(, << outside quotes; a plain redirect such as
`>/dev/null 2>&1` or `< file` is fine). Never by substring, never from the hook's own environment.

Inert text (#647): before the trigger runs, `sanitize()` blanks the text a command only CARRIES, so
the word in it does not deny. It is ONE left-to-right tokenizer over a tiny allow-listed grammar and
it fails closed: the whole input must tokenize as words (letters, digits, `_./:=,+@%-`),
single-quoted strings, double-quoted strings with no `$`, backtick or backslash, the operators
`; && || | & newline > >> < >& <&`, and at most one quoted-delimiter heredoc per owner line
(`<<'X'` as the last thing on its line, body to an exact terminator line). EVERY simple command in
the input must be an owner (`git commit|tag`, `gh issue create|edit|comment|close|reopen`, `gh pr
create|edit|comment|close|reopen|review|merge`, `gh release create|edit`, after assignments from a
closed list) or one of `git add`, `git status`, `cd`; an owner's options must be on an exact-spelling
allow list (git accepts any unique prefix of a long option, so `--edi` is `--edit` and no prefix is
listed; `-e`, `-c`, `-C`, `--amend`, `--fixup`, `--squash` are not listed) and a git owner must carry
`-m`/`-F` (a commit with no message opens an editor). Only an owner's own quoted strings and heredoc
bodies are blanked. Every separator and the end of a heredoc reset the state to "start of a new
command". Anything else (`$`, backtick, backslash, `#`, parentheses, a CR, `<<-`, `<<<`, `<(`, `>(`,
`"$(cat <<'X'` substitutions, an unterminated heredoc, a pipe after an owner, any other command in
the input such as `export`, `git config`, `alias`, `eval`, an assignment alone or an assignment
outside the closed list, ...) makes sanitize() return the raw text for the WHOLE input, i.e. strip
nothing, and the trigger then runs on all of it. The `"$(cat <<'X'` form is not accepted: bash ends
such a heredoc at a line `X)` and bash 3.2 at the first `)` in the body, so shells disagree about
where the text ends; the plain `-F - <<'X'` / `--body-file - <<'X'` form is read identically by every
shell. Under the override an `&>` is not a redirect (dash reads it as `&` then `>`); only `>&` and
`<&` are.

Inert data for the expansion triggers (#649): the second trigger above only GUESSES at a name the text
does not spell, so it is skipped (a spelled name is not) when the whole input is exactly ONE simple
command that the allow-list tokenizer _inert_view() recognises completely, and that command is a plain
`echo` of literals, quoted strings and `$NAME`/`${NAME}` (`echo '*' run`, `echo "$HOME" let me know`). No
pipe, redirect, fifo or earlier `exec >` can carry an echo's output to a shell when the echo is the whole
input, so a second command or any operator keeps the old reading; so does anything the tokenizer does
not recognise (an unbalanced quote, `$(`, a backtick, a backslash, a comment, a glob, `$'..'`, `{fd}>`,
`<<`, a CR). It never falls back to a weaker reading. Only echo is exempt: `printf -v 'a[$(...)]'`
runs the subscript, and an interpreter script (python) can build a command at run time from allowed
pieces, so neither is inert and both keep the old reading. Still denied, named in the README: an echo
that is not the whole input, any heredoc whose body holds an expansion character beside
`run`/`me`/`secrets`/`configure` unless the sanitizer blanks it (`git commit -F - <<'EOF'`,
`gh pr create --body-file - <<'EOF'`; the `-m "$(cat <<'EOF'...)"` form and a python heredoc are not).
A subcommand word followed by a closing `)`, backtick or `}`, or by a `;`, `|`, `&`, `<` or `>` (`echo
"$($D secrets)" x`, `echo "$($D secrets>&2)" x`), counts as a whole word for the expansion rule. False denies
that already existed: `echo "$(date)" me` and `echo "$(pwd)" run` (an expansion character, then `me`/`run`).
False denies this change adds: `echo "$x" run>out`, `echo "$(date)" secrets>notes.txt`, and quoted prose
after an expansion character such as a backtick commit message ending `run;`, `rg -n "$PAT" -e
"secrets|token" docs` or `echo "${PWD}" me>>log`. The override covers only a command without `$(` or a
backtick (`echo "$x" run>out`, the `rg` and `echo "${PWD}"` forms); for the rest put the word before the
substitution (`echo me "$(date)"`, `echo secrets "$(date)" >notes.txt`) or send a commit message or PR
body on stdin (`git commit -F - <<'EOF'`, `gh pr create --body-file - <<'EOF'`).

Known limits (a seatbelt against the accident, not a sandbox): aliases and functions, a command
name assembled at run time from pieces the text never spells (printf formatting), symlinked
redirect targets, a redirected file that is read back afterwards, `doppler run -- env` /
`printenv` / `doppler run --command 'echo $X'` (a child can print its own environment: the
child decides), a two-step symlink rename (`ln -s <doppler> /tmp/dp`, then `/tmp/dp secrets`:
each command text is innocent alone), a relative redirect when the event carries no `cwd`, `password=` / `?password=` URL forms, and false denies for any
text that mentions doppler outside the sanitized spots above (a `grep doppler docs/`, an `echo`): use the bypass.
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
    "mention doppler; `--no-fallback` and `--only-secrets NAME,NAME` (upper-case names only) are "
    "accepted on `run` and narrow it); `doppler secrets get NAME --plain > /literal/path` (also `download` and "
    "`substitute`; the file is yours, reading it back is your responsibility); "
    "`doppler secrets get NAME --plain | gh secret set NAME`; to WRITE a secret without printing it: "
    "`doppler secrets set NAME < /literal/path >/dev/null 2>&1` or `doppler secrets set "
    "NAME=\"$(cat /literal/path)\" >/dev/null 2>&1` (stdout and stderr must both be discarded); `eval \"$(doppler secrets download "
    "--no-file --format env 2>/dev/null)\"` (alone: nothing may follow it); a bare "
    "non-printing subcommand such as `doppler setup` or `doppler configs`."
)
DOPPLER_MSG = (
    "this command mentions doppler and is not one of the allowed Doppler forms, so it could "
    "print secret values to the transcript. " + SAFE_FORMS + " Quoted text in the arguments of "
    "`git commit|tag`, `gh issue|pr create|edit|comment|close|reopen|review|merge` and `gh release "
    "create|edit`, and the body of a quoted-delimiter `--body-file - <<'EOF'` / `-F - <<'EOF'` heredoc ending its line, is not scanned when the WHOLE command is plain words, quotes, "
    "`git add|status`, `cd` and those message commands with plain options (no `$(`, `$`, backtick, backslash, `#`, parentheses, `-e`/`--amend`, no `export` or `git config`); a message "
    "must be written `-m 'text'` or `-F - <<'EOF'`, not `-m \"$(cat <<'EOF'...)\"`; any other text that mentions the word is denied. Deliberate "
    "override for one single command: put SASSYDOG_ALLOW_DOPPLER_PRINT=1 as the very first thing in the "
    "command (before any `cd ... &&`); the rest must be one simple command (redirects are fine; no `;`, "
    "`&&`, pipe, `$(`, backtick or heredoc), or the override is ignored."
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


def _views(text):
    """(plain, decoded) readings of a command text: joined lines, NFKC, case-folded, ANSI-C decoded."""
    # A backslash-newline is a line continuation: the shell joins the halves of a word.
    text = LINE_CONTINUATION_RE.sub("", text)
    # Decode BEFORE folding case: `\U` and `\u` are different escapes (eight digits and four).
    plain = unicodedata.normalize("NFKC", text)
    decoded = unicodedata.normalize("NFKC", decode_escapes(plain)).lower()
    return plain.lower(), decoded


def triggered(text):
    plain, decoded = _views(text)
    # The inert view is decided on the RAW text, before the line-continuation join: a backslash-newline
    # inside a quoted-delimiter heredoc body is literal there, and joining it could move the terminator.
    inert = _inert_view(text)
    iplain, idecoded = (plain, decoded) if inert == text else _views(inert)
    # Both readings: a backslash before `e` or `c` is a plain letter outside `$'...'`, and the
    # decoder would turn it into a control character and drop the letter.
    return _mentions(plain, iplain) or (decoded != plain and _mentions(decoded, idecoded))


def _mentions(t, ti):
    """`t` is the whole text; `ti` is the same text with inert data blanked (see _inert_view).

    The rule that the name is SPELLED runs on all of `t`; the expansion rules, which only guess at a
    name the text does not spell, run on `ti`.
    """
    if "doppler" in t:
        return True
    if "doppler" in re.sub(r"[^a-z0-9\s]", "", t):
        return True
    if EXPANSION_RE.search(ti):
        n = QUOTES_RE.sub("", ti)
        w = lambda *names: all(re.search(r"\b" + x + r"\b", n) for x in names)  # noqa: E731
        if (w("secrets") and any(re.search(r"\b" + x + r"\b", n) for x in ("get", "download", "substitute"))) \
                or (w("configure") and (w("get") or "--all" in n)) \
                or w("configs", "tokens") or "print-config" in n:
            return True
        # An expansion or glob in a command NAME (`${X}pler secrets`, `dop*ler me`, `"$D" run`):
        # an expansion character, then later in the same simple command a Doppler subcommand as a
        # whole argument (not a path piece: `ls $HOME/secrets`, `/run/pw` stay quiet).
        for seg in split_segments(ti):
            seg = QUOTES_RE.sub("", seg)
            if _command_word_expands(seg):
                return True  # `sec''rets`, `s\\ecrets`, `"$D"` read as the shell reads them
            m = EXPANSION_RE.search(seg)
            if m and any(re.search(r"(?:^|\s)" + n + r"(?=$|[\s)`};|&<>])", seg[m.start():])
                         for n in SUBCOMMAND_WORDS):
                return True
    return False


_ASSIGN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
_REDIRECT_WORD_RE = re.compile(r"(?:[0-9]*|&)[<>]")
_SYNTAX_WORDS = {"[", "[[", "{", "}", "(", ")", "]]", "]"}


def _command_word_expands(seg):
    """True when the first word of a segment (after NAME=value prefixes) holds an expansion or glob.

    `[`, `[[` and `{` are shell syntax, not command names, so they stay quiet.
    """
    for w in seg.split():
        if _ASSIGN_RE.match(w) or _REDIRECT_WORD_RE.match(w):
            continue
        return w not in _SYNTAX_WORDS and EXPANSION_RE.search(w) is not None
    return False


def split_segments(s):
    """Split at ; & | newline outside quotes (an `&` beside `>` or `<` is a redirect), so `--scope=';' secrets` stays one simple command.

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
        elif c == "&" and ((i > 0 and s[i - 1] in "<>") or (i + 1 < len(s) and s[i + 1] in "<>")):
            pass  # a redirect (`2>&1`, `>&2`, `&>`, `<&`), not a separator
        elif c in ";&|\n":  # not \r: the shell does not split there, and splitting hides words
            segs.append(s[start:i])
            start = i + 1
        i += 1
    segs.append(s[start:])
    return segs


# ---- inert text (#647): ONE tokenizer, an allow list ------------------------------------------

# What an unquoted word may hold. Everything else outside quotes (`$`, backtick, backslash, `#`,
# parentheses, braces, globs, `!`, `\r`, any other whitespace or non-ASCII character) is not
# recognised, and an unrecognised character makes sanitize() return the raw text.
WORD_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=,+@%-")
# Assignment prefixes that may precede an owner command. A closed list: an EDITOR, PAGER or
# command-valued variable (GIT_EDITOR, GIT_SSH_COMMAND, ...) makes git/gh run the text. Any other
# assignment, and an assignment with no command after it, makes sanitize() return the raw text.
OWNER_ASSIGN_RE = re.compile(
    r"(?:GIT_(?:AUTHOR|COMMITTER)_(?:NAME|EMAIL|DATE)|GH_REPO|GH_PROMPT_DISABLED|NO_COLOR)=[A-Za-z0-9_./:@+,%-]*\Z"
)
# The ONLY commands that may appear in an input whose message text is blanked: an owner (a command
# whose message arguments are text, never run by the command itself) and three that set no state
# (`git add`, `git status`, `cd`). Any other simple command (`export`, `git config`, an assignment
# alone, `alias`, `eval`, `sh`, ...) makes sanitize() return the raw text for the WHOLE input, so
# editor state or an alias set in an earlier command cannot turn a blanked message into code.
OWNER_NEXT = {
    "git": {"commit": "git_commit", "tag": "git_tag", "add": "safe", "status": "safe"},
    "gh": {"issue": "gh_issue", "pr": "gh_pr", "release": "gh_release"},
    "gh_issue": {v: "gh_args" for v in ("create", "edit", "comment", "close", "reopen")},
    "gh_pr": {v: "gh_args" for v in ("create", "edit", "comment", "close", "reopen", "review", "merge")},
    "gh_release": {"create": "gh_args", "edit": "gh_args"},
}
ARGS = frozenset(("git_commit", "git_tag", "gh_args"))
# Positive allow list of option spellings, exact (git accepts any unique prefix of a long option, so
# `--edi` is `--edit`: a prefix is NOT listed, and neither is -e, -c, -C, --amend, --fixup, --squash).
GIT_SHORT_RE = {"git_commit": re.compile(r"-[ansqv]*(?:[mF].*)?\Z"), "git_tag": re.compile(r"-[asf]*(?:[mF].*)?\Z")}
GIT_LONG = {
    "git_commit": frozenset(("--message", "--file", "--all", "--no-verify", "--signoff", "--no-edit",
                             "--allow-empty", "--allow-empty-message", "--quiet", "--author", "--date",
                             "--no-gpg-sign")),
    "git_tag": frozenset(("--message", "--file", "--annotate", "--force")),
}
GH_SHORT = frozenset(("-t", "-b", "-F", "-R", "-l", "-a", "-m", "-B", "-H", "-d", "-r", "-n"))
GH_LONG = frozenset(("--title", "--body", "--body-file", "--repo", "--label", "--assignee", "--milestone",
                     "--base", "--head", "--draft", "--squash", "--merge", "--rebase", "--delete-branch",
                     "--comment", "--notes", "--notes-file", "--subject", "--auto", "--approve",
                     "--request-changes", "--reason", "--prerelease", "--latest", "--target"))
GIT_MSG_RE = re.compile(r"-[a-z]*[mF]|--(?:message|file)(?:=|\Z)")
# An operator token. `<<` is handled apart (heredoc); `<<<`, `<(`, `>(`, `>|`, `<>` are unknown.
# `&>` and `&>>` are deliberately absent: dash reads `&>f` as `&` then `>f`, bash as one redirect.
REDIR_RE = re.compile(r">>|>&|<&|>|<")
SEPARATORS = ("&&", "||", "|", ";", "&", "\n")
HEREDOC_RE = re.compile(r"<<[ \t]*(['\"])([A-Za-z0-9_]+)\1\n")


def _heredoc_end(text, i, delim):
    """Index just past the terminator line (exactly `delim`) of a body starting at text[i]; None if unterminated."""
    n = len(text)
    while i < n:
        j = text.find("\n", i)
        end = n if j < 0 else j
        nxt = n if j < 0 else j + 1
        if text[i:end] == delim:
            return nxt
        i = nxt
    return None


def _read_word(text, i):
    """Parse the word starting at text[i]: (end index, plain text, raw text, shown text, has_quote).

    Raises ValueError on anything not positively recognised. `shown` is the word with every quoted
    string blanked to an empty pair of quotes; the caller shows it only for an owner's arguments.
    """
    n = len(text)
    plain, raw, shown, quoted = [], [], [], False
    while i < n:
        c = text[i]
        if c in WORD_CHARS:
            plain.append(c); raw.append(c); shown.append(c)
            i += 1
        elif c in "'\"":
            j = text.find(c, i + 1)
            if j < 0:
                raise ValueError("unbalanced quote")
            body = text[i + 1:j]
            if c == '"' and any(x in body for x in "$`\\"):
                raise ValueError("expansion or escape inside double quotes")
            plain.append(body); raw.append(text[i:j + 1]); shown.append(c + c)
            quoted = True
            i = j + 1
        else:
            break
    return i, "".join(plain), "".join(raw), "".join(shown), quoted


def _option_ok(owner, w):
    if not w.startswith("-") or w == "-":
        return True
    name = w.split("=", 1)[0] if w.startswith("--") else w
    if owner == "gh_args":
        return name in GH_LONG or w in GH_SHORT
    if w.startswith("--"):
        return name in GIT_LONG[owner]
    return GIT_SHORT_RE[owner].match(w) is not None


def sanitize(text):
    """The text with the message text of git/gh message commands blanked, else the text itself.

    A single left-to-right pass over a tiny grammar, an ALLOW LIST: the input must tokenize
    completely as words (letters, digits and `_./:=,+@%-`), single-quoted strings, double-quoted
    strings with no `$`, backtick or backslash, the operators `; && || | & newline > >> < >& <&`,
    and at most one quoted-delimiter heredoc per owner line (`<<'X'` as the last thing on its line,
    body to an exact terminator line). Every simple command in the input must be an owner or one of
    `git add`, `git status`, `cd`; an owner's options must be on the exact-spelling allow list and a
    git owner must carry a message (`-m`/`-F`). Anything else is NOT recognised, and an unrecognised
    input returns the raw text unchanged, so the trigger runs on all of it. State is per simple
    command: `start`, then the owner's own words, then an args state where quoted strings are
    blanked. Every separator, and the end of a heredoc, goes back to `start`, so the text after a
    terminator line is a NEW command and is held to the same rules.
    """
    try:
        return _sanitize(text)
    except ValueError:
        return text


def _sanitize(text):
    n, i = len(text), 0
    out = []
    state = "start"
    target = False    # the next word is a redirect target, not part of the command
    assigned = False  # the current command has had an assignment word
    has_msg = False   # the current git owner carries -m / -F

    def close():
        # End of a simple command: it must be complete, then the state resets to a new command.
        if state in ("git_commit", "git_tag") and not has_msg:
            raise ValueError("no message: an editor could open")
        if state not in ARGS and state not in ("start", "safe"):
            raise ValueError("incomplete command")
        if state == "start" and assigned:
            raise ValueError("assignment with no command")

    while i < n:
        c = text[i]
        if c in " \t":
            out.append(c)
            i += 1
            continue
        if text.startswith("<<", i):
            m = HEREDOC_RE.match(text, i)
            if not m or state not in ARGS:
                raise ValueError("heredoc not allowed here")
            end = _heredoc_end(text, m.end(), m.group(2))
            if end is None:
                raise ValueError("unterminated heredoc")
            out.append("<<''\n")
            close()
            i, state, target, assigned, has_msg = end, "start", False, False, False
            continue
        m = REDIR_RE.match(text, i)
        if m:
            if text[m.end():m.end() + 1] in ("<", ">", "(", "|", "&"):
                raise ValueError("unknown operator")
            out.append(m.group())
            i = m.end()
            target = True
            continue
        sep = next((s for s in SEPARATORS if text.startswith(s, i)), None)
        if sep:
            if sep == "|" and state in ARGS:
                raise ValueError("a message command's output is piped on")
            close()
            out.append(sep)
            i += len(sep)
            state, target, assigned, has_msg = "start", False, False, False
            continue
        end, plain, raw, shown, quoted = _read_word(text, i)
        if end == i:
            raise ValueError("character not recognised")
        if target:
            out.append(shown if state in ARGS else raw)
            target = False
        elif state in ARGS:
            if not _option_ok(state, plain):
                raise ValueError("option not on the allow list")
            if state != "gh_args" and GIT_MSG_RE.match(plain):
                has_msg = True
            out.append(shown)
        else:
            out.append(raw)
            if state == "safe":
                pass
            elif quoted:
                raise ValueError("quoted word where a command word belongs")
            elif state == "start":
                if OWNER_ASSIGN_RE.match(plain):
                    assigned = True
                elif plain in ("git", "gh"):
                    state = plain
                elif plain == "cd":
                    state = "safe"
                else:
                    raise ValueError("command not on the allow list")
            else:
                nxt = OWNER_NEXT.get(state, {}).get(plain)
                if nxt is None:
                    raise ValueError("subcommand not on the allow list")
                state = nxt
        i = end
    close()
    return "".join(out)


# ---- inert data for the expansion rules (#649): a whole-input tokenizer that fails closed ----------
#
# The expansion rules guess at a Doppler name the text does not spell, so they over-trigger on prose
# (`echo "$HOME" let me know`). _inert_view() blanks the arguments of exactly ONE shape, and only when
# the WHOLE input is that one simple command: `echo` as the literal first word, with arguments that are
# literals, quoted strings, or simple `$NAME` / `${NAME}` expansions, and nothing else: no redirect, pipe,
# separator, heredoc, comment, glob, `$(`, backtick.
# Why the whole input: a command's output, or a redirect set up by an earlier command
# (`mkfifo p; sh <p & exec >p; echo '*' secrets`), is read again by a shell, which expands the glob and
# runs the CLI. With ONE command, no operator and no redirect, nothing can carry the text anywhere.
# Why only echo: `printf -v NAME` evaluates an array subscript in NAME (`a[$(...)]`) and runs it, and a
# script handed to an interpreter (python) can build a command at run time from allowed pieces, so
# neither is inert; echo only prints.
# Why a tokenizer: the shape is decided on the exact words the shell sees, never on a regex over text.
# It is the same allow-list stance as sanitize(): a character or construct it does not positively
# recognise (an unbalanced quote, `$(`, a backslash, `{fd}>`, `<<`, `#`, a CR, `$'..'`, a glob, any
# operator) raises, and the caller then keeps the whole text, i.e. the old, stricter reading.


class _Unrecognised(Exception):
    pass


_VAR_RE = re.compile(r"\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})")
DATA_COMMANDS = frozenset(("echo",))


def _read_token(text, i):
    """The word at text[i]: (end, raw text). Raises _Unrecognised on anything not allow-listed."""
    n, start = len(text), i
    while i < n:
        c = text[i]
        if c in WORD_CHARS:
            i += 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise _Unrecognised("unbalanced single quote")
            i = j + 1
        elif c == '"':
            i += 1
            while True:
                if i >= n:
                    raise _Unrecognised("unbalanced double quote")
                d = text[i]
                if d == '"':
                    break
                if d == "$":
                    m = _VAR_RE.match(text, i)
                    if not m:
                        raise _Unrecognised("expansion other than $NAME or ${NAME}")
                    i = m.end()
                    continue
                if d in "`\\":
                    raise _Unrecognised("backtick or backslash in double quotes")
                i += 1
            i += 1
        elif c == "$":
            m = _VAR_RE.match(text, i)
            if not m:
                raise _Unrecognised("expansion other than $NAME or ${NAME}")
            i = m.end()
        else:
            break
    if i == start:
        raise _Unrecognised("character not recognised")
    return i, text[start:i]


def _tokenize_one(text):
    """The raw words of ONE simple command that is the whole input.

    Only blanks and newlines may follow the last word. Any operator, redirect, heredoc, comment or
    second command raises.
    """
    n, i, words = len(text), 0, []
    while i < n:
        c = text[i]
        if c in " \t":
            i += 1
        elif c == "\n":
            if text[i:].strip(" \t\n"):
                raise _Unrecognised("a second command")
            return words
        else:
            i, raw = _read_token(text, i)
            words.append(raw)
    return words


def _inert_view(text):
    """`text` with the one command it holds reduced to its command word when it is an echo, else `text`."""
    try:
        words = _tokenize_one(text)
    except _Unrecognised:
        return text
    if words and words[0] in DATA_COMMANDS:
        return words[0]
    return text


# ---- single simple command, quote-aware ------------------------------------------------------


def single_simple(s, redirects=False):
    """True when s has no control operator outside single quotes (and no unbalanced quote).

    With redirects=True a plain redirect (`>f`, `2>&1`, `< f`, `>>f`) is not an operator; process
    substitution (`<(`, `>(`) and heredocs / here-strings (`<<`) still are. Only an UNESCAPED,
    unquoted `<` or `>` makes the `&` after it a redirect: a backslash-escaped `>` is a literal
    character, and the `&` after it is a background operator.
    """
    quote = None
    i = 0
    last_op = -2  # index of the last unescaped, unquoted `<` or `>` taken as a redirect
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
            elif redirects and c in "<>" and nxt != "(" and not (c == "<" and nxt == "<"):
                last_op = i
            elif redirects and c == "&" and last_op == i - 1:
                pass  # `>&2`, `<&0`; a bare `&>` is NOT accepted: dash reads it as `&` then `>`
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
RUN_BOOL = {"--no-cache", "--no-fallback"}
RUN_VAL = {"--name-transformer", "--format", "--dynamic-ttl", "--only-secrets"}
# `--only-secrets A,B` narrows the child's environment to the named secrets. Its value is a
# comma-separated list of upper-case names, a pattern of its own: VALUE_RE has no comma and
# stays as it is for every other flag. Only `run` passes it (RUN_VAL); no other call site does.
ONLY_SECRETS_RE = re.compile(r"[A-Z_][A-Z0-9_]*(?:,[A-Z_][A-Z0-9_]*)*")
RUN_VAL_PATTERNS = {"--only-secrets": ONLY_SECRETS_RE}
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


def parse_args(toks, i, bools, vals, patterns=None):
    """Flags (from the given sets) and positionals starting at toks[i]; None on anything else.

    A flag named in `patterns` is checked against its own value pattern instead of VALUE_RE."""
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
                if not (patterns or {}).get(name, VALUE_RE).fullmatch(v) or v.startswith("-"):
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
    # Run-local flags (`--no-cache`, `--no-fallback`, `--only-secrets`, ...) are accepted only AFTER
    # the `run` word. Before it only global flags and -p/-c may stand: the first `run` token the
    # prefix leaves over as the subcommand (a flag value spelled `run` is consumed by its flag).
    for k in range(1, len(toks)):
        if toks[k] != "run":
            continue
        pre = parse_args(toks[:k], 1, GLOBAL_BOOL, GLOBAL_VAL | PC_VAL)
        if pre is None or pre[1]:
            continue
        post = parse_args(toks, k + 1, GLOBAL_BOOL | RUN_BOOL, GLOBAL_VAL | PC_VAL | RUN_VAL,
                          RUN_VAL_PATTERNS)
        return bool(post) and not post[1]
    return False


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
    if cmd.startswith("doppler ") and SECRETS_SET_RE.search(cmd):
        return allowed_set(cmd)
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


DISCARD_RE = re.compile(r"[ \t]+>[ \t]*/dev/null[ \t]+(?:2>&1|2>[ \t]*/dev/null)\Z")
STDIN_RE = re.compile(r"[ \t]+<[ \t]*([A-Za-z0-9._/~-]+)\Z")
SET_FILE_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="\$\(cat[ \t]+([A-Za-z0-9._/~-]+)\)"')
SECRETS_SET_RE = re.compile(r"secrets[ \t]+set\b")


def allowed_set(cmd):
    """`doppler secrets set NAME < file` / `set NAME="$(cat file)"`, output discarded (see docstring 3d)."""
    m = DISCARD_RE.search(cmd)
    if not m:
        return False
    body = cmd[:m.start()]
    stdin = None
    m2 = STDIN_RE.search(body)
    if m2:
        stdin, body = m2.group(1), body[:m2.start()]
    subs = list(SET_FILE_RE.finditer(body))
    if len(subs) > 1 or (subs and stdin is not None) or (not subs and stdin is None):
        return False
    path = stdin if stdin is not None else subs[0].group(2)
    if not literal_path(path):
        return False
    if subs:
        body = body[:subs[0].start()] + subs[0].group(1) + "=@FILE" + body[subs[0].end():]
    if not STRICT_RE.fullmatch(body) or any(c in body for c in "|>"):
        return False
    toks = body.split()
    if not toks or toks[0] != "doppler":
        return False
    g = parse_global(toks)
    if g is None or g[0] + 1 >= len(toks) or toks[g[0]] != "secrets" or toks[g[0] + 1] != "set":
        return False
    parsed = parse_args(toks, g[0] + 2, GLOBAL_BOOL, GLOBAL_VAL | PC_VAL)
    if not parsed or len(parsed[1]) != 1:
        return False
    name = parsed[1][0]
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=@FILE", name) if subs else NAME_RE.fullmatch(name))


def allowed_bootstrap(cmd):
    """`eval "$(doppler secrets download --no-file --format env ...)"` as the whole command.

    Exactly `secrets download --no-file --format env` plus -p/-c. Doppler's default format is
    json, and eval of json, env-no-quotes or a --name-transformer output prints the values in
    eval's own error text, so no other format, no transformer, no global flag rides here.
    Nothing may follow the eval: a tail runs in a shell that already holds the secrets.
    """
    m = BOOTSTRAP_RE.fullmatch(cmd)
    if not m:
        return False
    toks = m.group(1).split()
    # Defence in depth, deliberately unreachable today: BOOTSTRAP_RE only matches a command that
    # starts with `doppler`. Kept so a loosened regex cannot make this check silently permissive.
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
    if not single_simple(body, redirects=True):
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
    if not bd and triggered(sanitize(body)) and not allowed_strict(body):
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
