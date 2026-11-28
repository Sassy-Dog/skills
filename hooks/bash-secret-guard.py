"""bash-secret-guard.py — PreToolUse(Bash) classifier for the sassy-dog plugin.

Reads the harness's JSON event on stdin. Exit 0 allows, exit 2 denies (the reason goes to
stderr, which the harness feeds to the model), exit 1 means "could not classify": the guard
FAILS OPEN there and says so on stderr (Claude Code shows stderr of any non-0/2 exit as a
non-blocking error). It never prints to stdout.

Two rules, both over the raw command text only (a PreToolUse hook cannot see output). There
is no general shell parser: every shell-parsing classifier tried here lost to a new spelling, so
the Doppler rule is a WHOLE-COMMAND ALLOW LIST matched on the raw string, which cannot disagree
with itself about quoting. The one tokenizer left, sanitize(), recognises a tiny allow-listed
grammar and gives up on anything else.

This hook is the FIRST of two layers (#670). It decides only what the text SPELLS. A command name
the text does not spell (`$D secrets get X`, `dop*ler me`, `${X}pler secrets`) is the second
layer's job: `hooks/shim/doppler`, a wrapper that sits first on the agent's PATH, applies the same allow
list to argv AFTER the shell has parsed, so quoting, glob and expansion spellings have already
resolved. The wrapper (hooks/doppler-wrapper.py, entered through hooks/shim/doppler) shares this module's
flag tables and parsers. The expansion and glob triggers and the inert-view tokenizer that used to
guess at those names here are deleted: they were a treadmill (#649 to #654, #659) and they
false-denied prose (#652, #657). A new expansion form found in review is a Known limit, not a rule.

1. Doppler value-printing guard, deny by construction.
   Trigger: the command mentions `doppler` in any spelling the text can show. The raw text is
   lower-cased, Unicode-folded and ANSI-C escapes are decoded; then `doppler` is looked for
   both as written and with every character that is not a letter, digit or whitespace removed
   (so `DOPPLER`, `$'\\x64oppler'`, `d"o"ppler`, `dopp\\ler`, `{doppler,}`, `doppl[e]r`,
   all trigger; a backslash-newline is removed first, as the shell joins the lines;
   the ANSI-C escapes x, u, U, octal, c and e are decoded). That is the whole trigger: a name
   the text does not spell is not guessed at.
   A triggered command is allowed only if the ENTIRE command is exactly one of:
     1. `doppler [global flags] secrets [flags] --only-names`, optionally followed by one of
        `| wc -l`, `| head -n N`, `| grep [-cqxFiwv] LITERAL` (names only, so nothing to leak)
     2. `doppler [global flags] run [flags] -- <rest>` or `run --command '<string>'`, where
        <rest> is a single simple command line that does not itself trigger and has no
        `$(`, backtick, `<(`, `>(`, `$'`, `$"` or `$[`, and nothing else the override scan refuses (#659). (#655: `--no-fallback` and `--only-secrets A,B` or
        `--only-secrets=A,B` are accepted on `run` only, and run flags (these two and `--no-cache`, `--format`,
        ...) only AFTER the `run` word; before it only global flags and -p/-c. The value is a comma list of upper-case
        names, `[A-Z_][A-Z0-9_]*(?:,[A-Z_][A-Z0-9_]*)*`, checked by ONLY_SECRETS_RE; VALUE_RE is
        unchanged for every other flag. Both only narrow the child and print nothing; on a read
        subcommand `--only-secrets` stays denied.)
     3. `doppler secrets get NAME... [flags] > <literal path>`, `secrets download --no-file
        [flags] > <literal path>`, `secrets download [flags] <literal path>`, and
        `secrets substitute <template> [flags] (> | --output) <literal path>`
     3b. `doppler sassydog-gh-secret-set NAME [-p P] [-c C] [--repo R | --env E | --app A | --org O |
        --visibility V | --no-store]`, a subcommand the WRAPPER provides (#670). It runs the real
        `secrets get NAME --plain`, holds the value in memory and feeds it to `gh secret set NAME` on
        gh's stdin, so the value never crosses a pipe the wrapper cannot see. The old text pipe
        `secrets get NAME --plain | gh secret set NAME` is gone: a wrapper cannot tell that pipe from
        a capture pipe, so it denies it, and this text rule must not allow what the wrapper denies
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
`>/dev/null 2>&1` or `< file` is fine; and, #659, no `$'`, `$"`, `$[` or backslash-newline (the shell deletes the pair before it parses, so it can hide an opener from this scan) anywhere, no `${` followed by a blank, tab, newline or `|` (bash 5.3 runs that text as a command), no quote
character inside `${...}`, and no `#` except mid-word or as a certain comment (after an unescaped blank, outside
`${...}` and `[...]`, its text free of `; & | < > ( )`, a backtick and a CR): single_simple() did not
model ANSI-C quoting, nested quotes in `${...}`, or a `#` that a shell reads as text, and the shells
read those as a second command where the scan saw one. Locale quoting is refused too, though no shell
here reads it differently. The refusal is wider than that text: `'$'` in single quotes and a comment
such as `# see (x)` lose the override too, and the same scan decides the child of `doppler run --
<child>`).
Never by substring, never from the hook's own environment.

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

Tools (#661): hooks.json matches `Bash` only, and must stay `Bash`. Per the hooks documentation, a `Bash`
matcher also runs on Monitor commands (Claude Code v2.1.314+), delivered as a Bash call (`tool_name`
"Bash", command in `tool_input.command`); verified live on Claude Code 2.1.332, where exit 2 blocks
them. Under `Bash|Monitor` (or `.*`, or no matcher) the call arrives with `tool_name` "Monitor", and the
`tool_name != "Bash"` exit 0 below would leave Monitor commands unguarded unless this classifier gained
a reviewed Monitor branch. See the README.

Known limits (a seatbelt against the accident, not a sandbox). This layer: a command name the text does not
spell (`$D secrets get X`, `dop*ler me`, `${X}pler secrets`, a subcommand word built by an expansion, xargs or
eval) is NOT matched here; that is the wrapper's job, and where the wrapper is not first on PATH (a harness
that does not run the SessionStart hook, a shell that resets PATH, `PATH=` on the command, `env -i`,
`command -p`, `hash -p`, an absolute path to the real binary) NEITHER layer catches it: the text layer
cannot spell-check the name and the shim is not in the way. The base text guard denied those spellings, so
this is a regression against it, accepted because the rules that denied them were guesses. The gate pins a sample of those spellings as allows (a known limit, not a feature), so a change
that starts denying one is a deliberate edit. Not modelled either (the override scan does not look for them;
they sit beside eval and bash -c, the strings a command runs): an
expansion that evaluates text as code, `${x@P}` in bash and zsh's `(e)` flag on any word (`${(e)x}`, or a
literal default in double quotes such as `"${(e):-\\$(...)}"`, which prints under zsh 5.9); and bash's
arithmetic-subscript evaluation inside builtins (`let 'a[$(...)]'`, `declare -i y='a[$(...)]'`, `printf -v
'a[$(...)]' x`, `test -v 'a[$(...)]'`; let and declare -i run it on bash 3.2 and 5, printf -v and test -v
on bash 5 only). Out of scope too:
on-disk scripts and Makefiles, an encoded payload piped to a shell, a name split inside an interpreter string
(implicit or spaced concatenation passes, unspaced `"a"+"b"` denies), credential-file reads (.env, the CLI token
file), tools other than Bash and Monitor (Monitor is covered via the Bash matcher, see Tools above; Read, Grep,
PowerShell and MCP shell tools are not).
The deny messages do not name either override and do not offer the file form (#666): the overrides are
for a human or a skill a human wrote, documented in the README, and an agent that is denied is told to stop
and ask the user. The override is still only a speed bump, not protection against an injected instruction.
Also: aliases and functions, a command
name assembled at run time from pieces the text never spells (printf formatting), symlinked
redirect targets, a redirected file that is read back afterwards, `doppler run -- env` /
`printenv` / `doppler run --command 'echo $X'` (a child can print its own environment: the
child decides), a two-step symlink rename (`ln -s <doppler> /tmp/dp`, then `/tmp/dp secrets`:
each command text is innocent alone), a relative redirect when the event carries no `cwd`, `password=` / `?password=` URL forms, and false denies for any
text that mentions doppler outside the sanitized spots above (a `grep doppler docs/`, an `echo`): a human can use the bypass; an agent that is denied stops and asks.
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

# #666: the deny messages name NEITHER override and do not offer the file form (`get`, `download` and
# `substitute` redirected to a literal path). Only the agent reads a message, and naming an override hands
# the bypass to every agent the guard stops, and to an injected instruction; the file form leaves the value
# on disk and the next step, reading the file back, puts it in the transcript. Both stay (the overrides for
# humans, the file form as an ALLOWED form) and are documented in the README, which is why SAFE_FORMS lists
# the forms that keep values out of the transcript, run first (the write form needs the value in a file
# you already hold, but never prints it). ASK_USER is written once, by main(), after the bullets, whichever
# rules fired. The gate pins the message against the allow decisions, the README and the absence of either
# override name.
ASK_USER = "If you believe this is a false deny, stop and ask the user; do not look for a way around it."
SAFE_FORMS = (
    "Allowed forms (the whole command, nothing else): "
    "`doppler run [flags] -- <cmd>` (the child reads values from its environment; the child may not "
    "mention doppler; `--no-fallback` and `--only-secrets NAME,NAME` (upper-case names only) are "
    "accepted on `run` and narrow it; run flags go AFTER the `run` word, only global flags and "
    "-p/-c before it); `doppler secrets --only-names`; "
    "a bare non-printing subcommand such as `doppler setup` or `doppler configs`; "
    "`doppler sassydog-gh-secret-set NAME [--repo R]` (the plugin's wrapper reads the value and hands it "
    "to `gh secret set`); to WRITE a secret without printing it: "
    "`doppler secrets set NAME < /literal/path >/dev/null 2>&1` or `doppler secrets set "
    "NAME=\"$(cat /literal/path)\" >/dev/null 2>&1` (stdout and stderr must both be discarded); `eval \"$(doppler secrets download "
    "--no-file --format env 2>/dev/null)\"` (alone: nothing may follow it)."
)
DOPPLER_MSG = (
    "this command mentions doppler and is not one of the allowed Doppler forms, so it could "
    "print secret values to the transcript. " + SAFE_FORMS + " Quoted text in the arguments of "
    "`git commit|tag`, `gh issue|pr create|edit|comment|close|reopen|review|merge` and `gh release "
    "create|edit`, and the body of a quoted-delimiter `--body-file - <<'EOF'` / `-F - <<'EOF'` heredoc ending its line, is not scanned when the WHOLE command is plain words, quotes, "
    "`git add|status`, `cd` and those message commands with plain options (no `$(`, `$`, backtick, backslash, `#`, parentheses, `-e`/`--amend`, no `export` or `git config`); a message "
    "must be written `-m 'text'` or `-F - <<'EOF'`, not `-m \"$(cat <<'EOF'...)\"`; any other text that mentions the word is denied."
)
URL_MSG = (
    "the command embeds a URL with a literal password (scheme://user:password@host). "
    "Pass the value through the environment instead (`doppler run -- <cmd>` and read the "
    "variable in the child)."
)

# ---- trigger -------------------------------------------------------------------------------

LINE_CONTINUATION_RE = re.compile(r"\\\r?\n")
# #657: the shell deletes an UNESCAPED backslash-newline pair before it parses, so a recipe written over
# several lines is one command and the allow list reads it joined. Only a bare LF counts (a backslash CR LF is
# not a continuation) and only when the backslash is not itself escaped (`\\` + newline is a literal backslash
# and then a second command, which must stay a second command).
UNESCAPED_CONTINUATION_RE = re.compile(r"(?<!\\)((?:\\\\)*)\\\n")


def join_continuations(text):
    return UNESCAPED_CONTINUATION_RE.sub(r"\1", text)


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
    """True when the text SPELLS the CLI's name in any reading the shell could join or decode."""
    plain, decoded = _views(text)
    # Both readings: a backslash before `e` or `c` is a plain letter outside `$'...'`, and the
    # decoder would turn it into a control character and drop the letter.
    return _mentions(plain) or (decoded != plain and _mentions(decoded))


def _mentions(t):
    return "doppler" in t or "doppler" in re.sub(r"[^a-z0-9\s]", "", t)


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


# ---- single simple command, quote-aware ------------------------------------------------------


def single_simple(s, redirects=False):
    """True when s has no control operator outside single quotes (and no unbalanced quote).

    With redirects=True a plain redirect (`>f`, `2>&1`, `< f`, `>>f`) is not an operator; process
    substitution (`<(`, `>(`) and heredocs / here-strings (`<<`) still are. Only an UNESCAPED,
    unquoted `<` or `>` makes the `&` after it a redirect: a backslash-escaped `>` is a literal
    character, and the `&` after it is a background operator.

    Fails closed (#659) on what this scan does not model:
    - `$'` (ANSI-C) and `$"` (locale) anywhere in the text: bash and zsh read `$'\\''` as one quoted
      quote where this scan reads three quote characters and so sees the wrong word boundaries.
    - `$[` (arithmetic expansion) anywhere: a `}` or a quote inside it is read by the shell as part of
      the expression, so this scan closes `${` early or opens a quote the shell never saw, and two
      quoted copies rebalance around a second command (also unquoted, on zsh).
    - a quote character inside `${...}`, in or out of double quotes: the shells nest quotes there and
      this scan swaps its quote state, so two quoted copies can rebalance around a second command.
      (`${...}` is tracked only by counting `${` and `}`; `$[` is refused so that count cannot be
      fooled, and `$(` and `((` are refused as operators.)
    - `${` followed by a blank, tab, newline or `|`, in or out of quotes: bash 5.3 runs the text inside
      as a command (`${ cmd; }`, `${| cmd; }`), so a `;` there, inside double quotes, would run a
      second command while this scan sees a quoted string. No other shell accepts `${ `.
    - a backslash-newline pair anywhere: the shell deletes it before it parses, so it can split `$` from
      the quote, bracket, brace or parenthesis it opens and hide that opener from the checks above.
    - a comment is modelled only when it is certain: an unquoted `#` right after a real (unescaped)
      blank, outside any `${...}` and `[...]`, runs to the newline and is not scanned (a quote inside
      it opens nothing). Its text must not hold `; & | < > ( )`, a backtick or a CR. Every other
      `#` that is not mid-word (after an escaped blank, an operator, a quote, inside `${...}` or
      `[...]`) is refused, because a shell may read it as text and run what follows on the line.
    """
    if "$'" in s or '$"' in s or "$[" in s or "\\\n" in s:
        return False
    if any("${" + c in s for c in " \t\n|"):
        return False
    quote = None
    i = 0
    last_op = -2  # index of the last unescaped, unquoted `<` or `>` taken as a redirect
    esc = -2  # index of the character a backslash just escaped
    brace = 0  # open `${` count
    bracket = 0  # open `[` count (unquoted)
    while i < len(s):
        c = s[i]
        nxt = s[i + 1] if i + 1 < len(s) else ""
        if quote == "'":
            if c == "'":
                quote = None
        elif quote == '"':
            if c == "\\":
                i += 1
            elif brace and c in "'\"":
                return False
            elif c == '"':
                quote = None
            elif c == "`" or (c == "$" and nxt == "("):
                return False
            elif c == "$" and nxt == "{":
                brace += 1
            elif c == "}" and brace:
                brace -= 1
        else:
            if c == "\\":
                esc = i + 1
                i += 1
            elif c in "'\"":
                if brace:
                    return False
                quote = c
            elif c == "#" and (brace or bracket):
                return False
            elif c == "#" and i and s[i - 1] in " \t" and esc != i - 1:
                # a certain comment: its text is not scanned (a quote in it opens nothing); the
                # newline that ends it is an operator below, so a second command is refused
                end = s.find("\n", i)
                end = len(s) if end < 0 else end
                if any(ch in s[i:end] for ch in ";&|<>()`\r"):
                    return False
                i = end
                continue
            elif c == "#" and (i == 0 or not (s[i - 1].isalnum() or s[i - 1] in "_./:=,+@%-")):
                return False  # a `#` a shell may read as text (escaped blank, operator, quote, start)
            elif c == "$" and nxt == "{":
                brace += 1
            elif c == "}" and brace:
                brace -= 1
            elif c == "[":
                bracket += 1
            elif c == "]" and bracket:
                bracket -= 1
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
# The wrapper's own subcommand (#670): `sassydog-gh-secret-set NAME [-p P] [-c C] [gh flags]` runs the
# real `secrets get NAME --plain` and feeds the value to `gh secret set NAME` on gh's stdin. No `-b/--body`
# (it would replace stdin) and no other consumer. The value crosses a pipe only the wrapper holds.
GH_SET_SUB = "sassydog-gh-secret-set"
GH_SET_BOOL = {"--no-store"}
GH_SET_VAL = {"-R", "--repo", "-e", "--env", "-a", "--app", "-o", "--org", "-v", "--visibility"}
GH_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
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
    return run_head_ok(toks)


def run_head_ok(toks):
    """The words of a `run` command up to its child (`doppler [flags] run [flags]`), as the wrapper also reads them.

    Run-local flags (`--no-cache`, `--no-fallback`, `--only-secrets`, ...) are accepted only AFTER
    the `run` word. Before it only global flags and -p/-c may stand: the first `run` token the
    prefix leaves over as the subcommand (a flag value spelled `run` is consumed by its flag).
    """
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
        if "|" in tail or ">" in tail or not PIPE_OK_RE.fullmatch(joined):
            return False
    split = split_redirect(toks)
    if split is None:
        return False
    toks, redirect = split
    if redirect is not None and (tail is not None or not literal_path(redirect)):
        return False
    return allowed_simple(toks, redirect, tail is not None)


def allowed_simple(toks, redirect, has_tail):
    """One command's words (`doppler ...`) against the allow list. `redirect` is the stdout target or None.

    The text guard calls this with the literal path it read after `>`; the wrapper calls it with a
    sentinel when its stdout is a regular file the shell opened for it. `has_tail` is a names-only
    pipe consumer, which only `secrets --only-names` accepts.
    """
    rest = toks[1:]
    # info
    if rest and (rest[0] in INFO_FLAGS or rest[0] == "help") and not has_tail and redirect is None:
        return len(rest) == 1 or (rest[0] == "help" and len(rest) <= 3 and all(re.fullmatch(r"[a-z]+", x) for x in rest[1:]))
    if rest[:2] in (["run", "--help"], ["run", "-h"]) and len(rest) == 2:
        return not has_tail and redirect is None
    # global flags, then the subcommand
    g = parse_global(toks)
    if g is None:
        return False
    i, glob = g
    if i >= len(toks):
        return False
    sub = toks[i]
    if sub == "secrets":
        return allowed_secrets(toks, i + 1, redirect, has_tail)
    if sub == GH_SET_SUB and not has_tail and redirect is None:
        return parse_gh_secret_set(toks, i + 1) is not None
    if sub in BARE_SUBS and not has_tail and redirect is None:
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
    return bootstrap_toks_ok(toks)


def bootstrap_toks_ok(toks):
    """`doppler secrets download --no-file --format env [-p P] [-c C]` as words (the wrapper reads argv the same way)."""
    parsed = parse_args(toks, 1, {"--no-file"}, PC_VAL | {"--format"})
    return bool(parsed) and parsed[1] == ["secrets", "download"] \
        and parsed[0].get("--no-file") is True and parsed[0].get("--format") == "env"


def parse_gh_secret_set(toks, i):
    """(doppler flags, gh flags, NAME) for the args of the wrapper's `sassydog-gh-secret-set` at toks[i:], else None."""
    parsed = parse_args(toks, i, GLOBAL_BOOL | GH_SET_BOOL, GLOBAL_VAL | PC_VAL | GH_SET_VAL)
    if parsed is None or len(parsed[1]) != 1 or not GH_NAME_RE.fullmatch(parsed[1][0]):
        return None
    flags, pos = parsed
    gh = {k: v for k, v in flags.items() if k in GH_SET_BOOL or k in GH_SET_VAL}
    cli = {k: v for k, v in flags.items() if k not in gh}
    return cli, gh, pos[0]


def allowed_secrets(toks, i, redirect, has_tail):
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
    if has_tail:
        return False
    if sub == "get":
        parsed = parse_args(toks, i, GLOBAL_BOOL | GET_BOOL, GLOBAL_VAL | PC_VAL)
        if not parsed or parsed[1][0] != "get" or len(parsed[1]) < 2:
            return False
        names_ok = all(NAME_RE.fullmatch(n) for n in parsed[1][1:])
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
    if not bd and triggered(sanitize(body)) and not allowed_strict(join_continuations(body)):
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
    # The wrapper runs this under `-X utf8`, which decodes stdin with surrogateescape, so the
    # UnicodeDecodeError arm cannot fire there; it stays for a direct run. Only an OSError is left.
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
        sys.stderr.write(ASK_USER + "\n")  # once, after the bullets, whichever rules fired (#666)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
