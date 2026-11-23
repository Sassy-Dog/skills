"""Differential corpus and driver for scripts/test-bash-secret-guard.sh (#647).

usage: secret-guard-differential.py <hook .sh> <scratch dir>

The hook's sanitizer decides, from text alone, that a quoted string or heredoc body is inert.
This driver checks that decision against what REAL shells do. For every corpus command it
(1) pipes the harness event into the real hook and compares the exit code with the corpus
expectation, and (2) runs the command under each available shell with a FAKE `doppler` on PATH
that prints a marker to stdout and stderr (fake `git` and `gh` shims, no network, no real repo,
everything inside the scratch directory), and asserts the invariant:

    whenever the hook ALLOWS a command, the marker did not reach stdout or stderr.

A corpus entry of kind "bypass" must also PRINT under at least one shell, otherwise it proves
nothing (a bypass that no shell executes is not a bypass). Shells tried: every one of bash,
/bin/bash, zsh, dash found on this machine, de-duplicated by real path and version; a missing
zsh is reported, not hidden. Output: one `  ok   - ` or `  FAIL - ` line per check.
"""

import itertools
import json
import os
import shutil
import subprocess
import sys

D = "dop" + "pler"  # the fake command's name, spelled apart so this file is not itself a mention
MARKER = "SECRET_MARKER_PRINTED_BY_FAKE_" + D.upper()

# ---- corpus: (label, command, expectation, kind) ----------------------------------------------
# expectation: "allow" | "deny". kind: "msg" (a benign message that merely mentions the word),
# "bypass" (a command the hook must deny AND that really prints under a shell), or "deny-only"
# (denied for safety, but no shell executes it, so there is nothing to print).
PRINT = f"{D} secrets get X --plain"
H = "<<'EOF'"

CORPUS = [
    # accepted grammar: the word is only text
    ("commit -m double-quoted", f'git commit -m "fix: {D} secrets get is blocked"', "allow", "msg"),
    ("commit -m single-quoted", f"git commit -m 'fix the {D} guard'", "allow", "msg"),
    ("commit -m glued", f'git commit -m"{D} guard"', "allow", "msg"),
    ("tag -a -m", f'git tag -a v1 -m "{D} guard"', "allow", "msg"),
    ("gh pr create", f"gh pr create --title 'a' --body 'uses {D}'", "allow", "msg"),
    ("gh issue comment body-file heredoc", f"gh issue comment 5 --body-file - {H}\n{PRINT}\nEOF", "allow", "msg"),
    ("commit -F - heredoc", f"git commit -F - {H}\nfix: {D}\nEOF", "allow", "msg"),
    ("commit heredoc substitution", f"git commit -m \"$(cat {H}\nfix: {PRINT}\nEOF\n)\"", "allow", "msg"),
    ("two heredoc substitutions", f"git commit -m \"$(cat <<'A'\n{D} one\nA\n)\" -m \"$(cat <<'B'\n{D} two\nB\n)\"", "allow", "msg"),
    ("heredoc substitution body with parens, quotes, backtick and a nested substitution",
     f"git commit -m \"$(cat {H}\nfix (#647) it's \"{D}\" `x` $(y) ) ( ' \"\nEOF\n)\"", "allow", "msg"),
    ("heredoc body with parens, quotes and a stray terminator lookalike",
     f"gh issue comment 5 --body-file - {H}\n) ( ' \" `{PRINT}` $({PRINT}) EOF2 EOF \nEOF", "allow", "msg"),
    ("a CR before the newline is not a terminator: the rest is still body",
     f"gh issue comment 5 --body-file - {H}\nhi\nEOF\r\nsh -c '{PRINT}'\nEOF", "allow", "msg"),
    ("add then commit", f'git add -A && git commit -m "{D} guard"', "allow", "msg"),
    ("message, then an innocent command after the heredoc", f"gh issue comment 5 --body-file - {H}\n{D} is mentioned\nEOF\nls", "allow", "msg"),
    ("allowed assignment prefix", f'GIT_AUTHOR_NAME=bot git commit -m "{D}"', "allow", "msg"),
    ("redirect on a message command", f'git commit -m "{D}" >/dev/null 2>&1', "allow", "msg"),
    ("override with a discarded print", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 {PRINT} >/dev/null 2>&1", "allow", "msg"),
    # reviewer-reproduced bypasses (#648): each must be denied
    ("after a quoted heredoc: sh -c", f"gh issue comment 5 --body-file - {H}\nhi\nEOF\nsh -c '{PRINT}'", "deny", "bypass"),
    ("after a quoted heredoc (git): sh -c", f"git commit -F - {H}\nhi\nEOF\nsh -c '{PRINT}'", "deny", "bypass"),
    ("after a quoted heredoc: split word", f"gh issue comment 5 --body-file - {H}\nhi\nEOF\nd'oppler' secrets get X --plain", "deny", "bypass"),
    ("after a quoted heredoc: plain command", f"gh issue comment 5 --body-file - {H}\nhi\nEOF\n{PRINT}", "deny", "bypass"),
    ("commands after the cat heredoc terminator, inside the substitution",
     f"git commit -m \"$(cat {H}\nhi\nEOF\n:; sh -c '{PRINT}'\n)\"", "deny", "bypass"),
    ("a bare CR does not split a segment for the glob trigger (over-trigger, deliberate)", "echo $X\rsecrets", "deny", "deny-only"),
    ("double quote scan after a cat heredoc body", f"git commit -m \"$(cat {H}\nEOF\n: \"'\"; {PRINT}; : \"'\")\"", "deny", "bypass"),
    ("escaped dollar then ANSI-C lookalike", f"git commit -m \\$'\\' 'a' ; {PRINT} ; : '\\'", "deny", "bypass"),
    ("dollar dollar ANSI-C lookalike", f"git commit -m $$'\\' 'a' ; {PRINT} ; : '\\'", "deny", "bypass"),
    ("bare CR as a separator (eval)", f"eval : \rgit commit \\; '{PRINT}'", "deny", "bypass"),
    ("bare CR as a separator (sh -c)", f"sh -c '$2' \rgit commit '{PRINT}'", "deny", "bypass"),
    ("escaped >& after a commit", f"git commit -m x \\>& sh -c '{PRINT}'", "deny", "bypass"),
    ("escaped <& after a commit", f"git commit -m x \\<& sh -c '{PRINT}'", "deny", "bypass"),
    ("override prefix with an escaped >&", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 true \\>& {PRINT}", "deny", "bypass"),
    ("override prefix with a detached &<", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 true &<x {PRINT}", "deny", "bypass"),
    # earlier ones that must stay denied
    ("command substitution in a message", f"git commit -m $(sh -c '{PRINT}')", "deny", "bypass"),
    ("backtick in a message", f"git commit -m `sh -c '{PRINT}'`", "deny", "bypass"),
    ("process substitution body-file", f"gh pr create --title t --body-file <(sh -c '{PRINT}')", "deny", "bypass"),
    ("cat heredoc piped to bash", f"cat {H} | bash\n{PRINT}\nEOF", "deny", "bypass"),
    ("bash heredoc", f"bash {H}\n{PRINT}\nEOF", "deny", "bypass"),
    ("quoted separator fools a segment start", f"bash -s \"; git commit x\" {H}\n{PRINT}\nEOF", "deny", "bypass"),
    ("heredoc operator inside a quoted message", f"git commit -m \"see {H}\"\n{PRINT}\nEOF", "deny", "bypass"),
    ("apostrophe in a comment", f"git commit -m 'a' # it's done\n{PRINT} # won't", "deny", "bypass"),
    ("editor assignment, IFS spelling", f"GIT_EDITOR='{D}${{IFS}}secrets${{IFS}}get${{IFS}}X;:' git commit", "deny", "bypass"),
    ("editor flag runs GIT_EDITOR on the message", f"GIT_EDITOR=sh git commit -e -m '{PRINT}'", "deny", "bypass"),
    ("long editor flag", f"GIT_EDITOR=sh git commit --edit -m '{PRINT}'", "deny", "bypass"),
    ("pager assignment (git pages only on a tty: no shell prints here)", f"GIT_PAGER='{PRINT}' git tag -l", "deny", "deny-only"),
    ("commit message then a real printer", f'git commit -m "{D}" && {PRINT}', "deny", "bypass"),
    ("commit message then a newline printer", f'git commit -m "{D}"\n{PRINT}', "deny", "bypass"),
    ("unterminated heredoc", f"gh issue comment 5 --body-file - {H}\n{PRINT}", "deny", "deny-only"),
    ("heredoc operator not last on its line", f"gh issue comment 5 --body-file - {H} | sh\n{PRINT}\nEOF", "deny", "bypass"),
    ("unquoted heredoc delimiter", f"gh issue comment 5 --body-file - <<EOF\n$({PRINT})\nEOF", "deny", "bypass"),
    ("unbalanced quote", f'git commit -m "{PRINT}', "deny", "deny-only"),
]

# ---- generated invariant-only matrix: head x joiner x tail ------------------------------------
HEADS = [
    f"git commit -m '{D} note'",
    f'gh pr create --title t --body "{D} note"',
    f"gh issue comment 5 --body-file - {H}\n{D} note\nEOF",
    f"git commit -m \"$(cat {H}\n{D} note\nEOF\n)\"",
]
JOINERS = ["\n", "; ", " && ", " || ", " | ", " & ", "\n\n"]
TAILS = [
    PRINT,
    f"sh -c '{PRINT}'",
    f"d'oppler' secrets get X --plain",
    f"\\{D} secrets get X --plain",
    f'bash -c "{PRINT}"',
    f"echo $({PRINT})",
    f"eval '{PRINT}'",
]
MATRIX = [(f"matrix {n}", h + j + t) for n, (h, j, t) in enumerate(itertools.product(HEADS, JOINERS, TAILS))]

# ---- driver -------------------------------------------------------------------------------------


def out(ok, text):
    print(("  ok   - " if ok else "  FAIL - ") + text)
    return ok


def make_shims(scratch):
    bindir = os.path.join(scratch, "bin")
    os.makedirs(bindir)
    shims = {
        D: f'#!/bin/sh\necho "{MARKER}"\necho "{MARKER}" >&2\nexit 0\n',
        # git runs GIT_EDITOR on the message when it has no -m/-F, or with -e/--edit, as real git
        # does; it echoes stdin (what a pipe after it would carry).
        "git": (
            "#!/bin/sh\n"
            'edit=1; for a in "$@"; do case "$a" in -m*|-F*|--message*|--file*) edit=0 ;; esac; done\n'
            'for a in "$@"; do case "$a" in -e|--edit|-[a-zA-Z]*e*) edit=1 ;; esac; done\n'
            'printf "%s\\n" "$@" > msgfile\n'
            '[ -n "${GIT_EDITOR:-}" ] && [ "$edit" = 1 ] && sh -c "$GIT_EDITOR \\"\\$@\\"" sh msgfile\n'
            "cat 2>/dev/null; exit 0\n"
        ),
        # gh echoes stdin and every readable file it is handed (a --body-file, a process
        # substitution), standing for what it would post or print.
        "gh": (
            "#!/bin/sh\n"
            'for a in "$@"; do [ -f "$a" ] || [ -p "$a" ] && cat "$a"; done\n'
            "cat 2>/dev/null; exit 0\n"
        ),
    }
    with open(os.path.join(scratch, "x"), "w") as f:
        f.write("")
    for name, body in shims.items():
        path = os.path.join(bindir, name)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)
    return bindir


def find_shells():
    found, seen = [], set()
    for cand in ("bash", "/bin/bash", "zsh", "dash"):
        path = shutil.which(cand)
        if not path:
            continue
        try:
            ver = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10).stdout.splitlines()[:1]
        except (OSError, subprocess.SubprocessError):
            ver = []
        key = (os.path.realpath(path), tuple(ver))
        if key in seen:
            continue
        seen.add(key)
        found.append(path)
    return found


def hook_rc(hook, cmd):
    event = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    p = subprocess.run(["bash", hook], input=event, capture_output=True, text=True, timeout=30)
    return p.returncode


def run_shell(shell, bindir, scratch, cmd):
    env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": scratch, "TMPDIR": scratch}
    try:
        p = subprocess.run([shell, "-c", cmd], capture_output=True, text=True, timeout=20,
                           env=env, cwd=scratch, stdin=subprocess.DEVNULL, errors="replace")
    except subprocess.TimeoutExpired:
        return False
    return MARKER in (p.stdout or "") + (p.stderr or "")


def main():
    hook, scratch = sys.argv[1], sys.argv[2]
    bindir = make_shims(scratch)
    shells = find_shells()
    names = [os.path.basename(s) for s in shells]
    print(f"  info - shells under test: {', '.join(shells) or 'none'}")
    if not any(n == "zsh" for n in names):
        print("  info - zsh NOT covered on this machine (not installed)")
    if not shells:
        print("  info - no shell found: only the hook's expectation is checked")
    fails = 0
    for label, cmd, want, kind in CORPUS:
        rc = hook_rc(hook, cmd)
        got = "allow" if rc == 0 else "deny" if rc == 2 else f"rc={rc}"
        fails += not out(got == want, f"corpus {want}: {label}" + ("" if got == want else f" (hook said {got})"))
        printed = {s: run_shell(s, bindir, scratch, cmd) for s in shells}
        if got == "allow":
            leaked = [s for s, p in printed.items() if p]
            fails += not out(not leaked, f"corpus allow prints nothing under any shell: {label}" + (f" (printed under {leaked})" if leaked else ""))
        if kind == "bypass" and shells:
            fails += not out(any(printed.values()), f"corpus bypass really prints under a shell (the case has teeth): {label}")
    leaks, denied = 0, 0
    for label, cmd in MATRIX:
        rc = hook_rc(hook, cmd)
        if rc == 0:
            for s in shells:
                if run_shell(s, bindir, scratch, cmd):
                    leaks += 1
                    out(False, f"{label}: hook allowed and {os.path.basename(s)} printed the marker: {cmd!r}")
        else:
            denied += 1
    fails += leaks
    out(leaks == 0, f"matrix of {len(MATRIX)} head/joiner/tail combinations: the hook allowed {len(MATRIX) - denied}, none printed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
