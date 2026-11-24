"""Differential corpus and driver for scripts/test-bash-secret-guard.sh (#647).

usage: secret-guard-differential.py <hook .sh> <scratch dir>

The hook's sanitizer decides, from text alone, that a quoted string or heredoc body is inert.
This driver checks that decision against what REAL shells do. For every corpus command it
(1) pipes the harness event into the real hook and compares the exit code with the corpus
expectation, and (2) runs the command under each available shell with a FAKE secret-printing
command on PATH that prints a marker to stdout and stderr (plus fake `git` and `gh` shims, no
network, no real repo, everything inside a fresh scratch directory per run), and asserts:

    whenever the hook ALLOWS a command, the marker did not reach stdout or stderr, and no shell
    run of it timed out.

A corpus entry of kind "bypass" must also PRINT under at least one shell, otherwise it proves
nothing (a bypass that no shell executes is not a bypass). A case listed in NEEDS (bash 3.2's
early end of a heredoc substitution) is checked only against a matching shell and its teeth check is
SKIPPED, with a visible info line naming the case, where none is installed; the hook-side deny always
runs. self_test() proves the skip logic on synthetic inputs. GUARD_DIFF_HIDE_SHELLS="bash<4" hides
such shells, to simulate a runner that has only bash 5 and dash. Shells tried: every one of bash,
/bin/bash, zsh, dash found on this machine, de-duplicated by real path and version; the shells
that ran are printed, a missing zsh is reported. With CI set, at least bash must be present.
Output: one `  ok   - ` or `  FAIL - ` line per check.

The git shim imitates what real git does with an editor, because that is how message text became
code: it runs the editor (GIT_EDITOR, else `git config core.editor`, else VISUAL, else EDITOR) on a
file holding the arguments when the command is a commit or an annotated tag and it has no -m/-F/-C,
or has -e/--edit or ANY unique long-option prefix of it (--ed, --edi), or -c, --reedit-message,
--fixup=amend:/reword:; a re-edit reuses the text of earlier messages (it keeps them in a file).
`git config K V` is recorded and honoured. The gh shim echoes its stdin and every file it is handed.
It is a model of those behaviours, not real git.
"""

import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

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
    ("commit allow-empty -F - heredoc", f"git commit --allow-empty -F - {H}\nfix: {PRINT}\nEOF", "allow", "msg"),
    ("add then commit", f'git add -A && git commit -m "{D} guard"', "allow", "msg"),
    ("message, then git status after the heredoc", f"gh issue comment 5 --body-file - {H}\n{D} is mentioned\nEOF\ngit status", "allow", "msg"),
    ("a CR before the newline is not a terminator: the rest is still body",
     f"gh issue comment 5 --body-file - {H}\nhi\nEOF\r\nsh -c '{PRINT}'\nEOF", "allow", "msg"),
    ("allowed assignment prefix", f'GIT_AUTHOR_NAME=bot git commit -m "{D}"', "allow", "msg"),
    ("redirect on a message command", f'git commit -m "{D}" >/dev/null 2>&1', "allow", "msg"),
    ("override with a discarded print", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 {PRINT} >/dev/null 2>&1", "allow", "msg"),
    # the "$(cat <<'X'" substitution is NOT in the grammar: shells disagree about where it ends
    ("heredoc substitution is outside the grammar", f"git commit -m \"$(cat {H}\nfix: {D}\nEOF\n)\"", "deny", "deny-only"),
    ("heredoc ended by a line EOF) inside the substitution (bash)",
     f"git commit --allow-empty -m \"$(cat {H}\nEOF)\" ; {PRINT} ; : \"\nEOF\n)\"", "deny", "bypass"),
    ("heredoc ended by a line EOF) inside gh pr create (bash)",
     f"gh pr create --title t --body \"$(cat {H}\nEOF)\" ; {PRINT} ; : \"\nEOF\n)\"", "deny", "bypass"),
    ("bash 3.2 ends the substitution at the first ) in the body",
     f"git commit --allow-empty -m \"$(cat {H}\nx )\" ; {PRINT} ; : \"(\nEOF\n)\"", "deny", "bypass"),
    ("commands after the cat heredoc terminator, inside the substitution",
     f"git commit -m \"$(cat {H}\nhi\nEOF\n:; sh -c '{PRINT}'\n)\"", "deny", "bypass"),
    ("double quote scan after a cat heredoc body", f"git commit -m \"$(cat {H}\nEOF\n: \"'\"; {PRINT}; : \"'\")\"", "deny", "bypass"),
    # editor state set by an EARLIER command, and git's unique-prefix long options (coordinator review)
    ("export GIT_EDITOR then --edi", f"export GIT_EDITOR=sh; git commit --allow-empty --edi -m '{PRINT}'", "deny", "bypass"),
    ("export GIT_EDITOR then --ed", f"export GIT_EDITOR=sh; git commit --allow-empty --ed -m '{PRINT}'", "deny", "bypass"),
    ("git config core.editor then --edi", f"git config core.editor sh; git commit --allow-empty --edi -m '{PRINT}'", "deny", "bypass"),
    ("export VISUAL then --edi", f"export VISUAL=sh; git commit --allow-empty --edi -m '{PRINT}'", "deny", "bypass"),
    ("export GIT_EDITOR, --edi, heredoc message", f"export GIT_EDITOR=sh; git commit --allow-empty --edi -F - {H}\n{PRINT}\nEOF", "deny", "bypass"),
    ("export GIT_EDITOR, annotated tag --edi", f"export GIT_EDITOR=sh; git tag -a v9 --edi -m '{PRINT}'", "deny", "bypass"),
    ("blank, then re-edit with -c HEAD", f"git commit --allow-empty -m '{PRINT}'; export GIT_EDITOR=sh; git commit -c HEAD", "deny", "bypass"),
    ("blank, then re-edit with --reedit-message", f"git commit --allow-empty -m '{PRINT}'; export GIT_EDITOR=sh; git commit --reedit-message=HEAD", "deny", "bypass"),
    ("blank, then re-edit with --fixup=amend:", f"git commit --allow-empty -m '{PRINT}'; export GIT_EDITOR=sh; git commit --fixup=amend:HEAD", "deny", "bypass"),
    ("assignment-only command sets the editor", f"GIT_EDITOR=sh; export GIT_EDITOR; git commit --allow-empty --edi -m '{PRINT}'", "deny", "bypass"),
    ("an alias in the text (bash does not expand it non-interactively)", f"alias git='sh -c'; git commit -m '{PRINT}'", "deny", "deny-only"),
    ("commit with no message (an editor could open): positional text is not a message", f"git commit -a '{D} note'", "deny", "deny-only"),
    # reviewer-reproduced bypasses (#648): each must be denied
    ("after a quoted heredoc: sh -c", f"gh issue comment 5 --body-file - {H}\nhi\nEOF\nsh -c '{PRINT}'", "deny", "bypass"),
    ("after a quoted heredoc (git): sh -c", f"git commit -F - {H}\nhi\nEOF\nsh -c '{PRINT}'", "deny", "bypass"),
    ("after a quoted heredoc: split word", f"gh issue comment 5 --body-file - {H}\nhi\nEOF\nd'oppler' secrets get X --plain", "deny", "bypass"),
    ("after a quoted heredoc: plain command", f"gh issue comment 5 --body-file - {H}\nhi\nEOF\n{PRINT}", "deny", "bypass"),
    ("escaped dollar then ANSI-C lookalike", f"git commit -m \\$'\\' 'a' ; {PRINT} ; : '\\'", "deny", "bypass"),
    ("dollar dollar ANSI-C lookalike", f"git commit -m $$'\\' 'a' ; {PRINT} ; : '\\'", "deny", "bypass"),
    ("bare CR as a separator (eval)", f"eval : \rgit commit \\; '{PRINT}'", "deny", "bypass"),
    ("bare CR as a separator (sh -c)", f"sh -c '$2' \rgit commit '{PRINT}'", "deny", "bypass"),
    ("a bare CR does not split a segment for the glob trigger (over-trigger, deliberate)", "echo $X\rsecrets", "deny", "deny-only"),
    ("escaped >& after a commit", f"git commit -m x \\>& sh -c '{PRINT}'", "deny", "bypass"),
    ("escaped >& then eval as a would-be positional of the commit", f"git commit -m x \\>& eval '{PRINT}'", "deny", "bypass"),
    ("escaped <& after a commit", f"git commit -m x \\<& sh -c '{PRINT}'", "deny", "bypass"),
    ("override prefix with an escaped >&", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 true \\>& {PRINT}", "deny", "bypass"),
    ("override prefix with a detached &<", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 true &<x {PRINT}", "deny", "bypass"),
    ("override prefix with &> (a background job under dash)", f"SASSYDOG_ALLOW_DOPPLER_PRINT=1 {PRINT} &>/dev/null", "deny", "deny-only"),
    # earlier ones that must stay denied
    ("command substitution in a message", f"git commit -m $(sh -c '{PRINT}')", "deny", "bypass"),
    ("process substitution with eval (no option to trip the allow list)", f"gh pr create --title t --body-file <(eval '{PRINT}')", "deny", "bypass"),
    ("backtick with eval in a message", f"git commit -m `eval '{PRINT}'`", "deny", "bypass"),
    ("a mention in a git add argument is not stripped (safe commands are shown raw)", f"git add '{D}.txt'", "deny", "deny-only"),
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

# Corpus cases whose teeth check needs a particular shell, keyed by label: "<name><<major>" means a shell
# called <name> whose major version is below <major>. The hook-side assertion always runs; only the
# "really prints under a shell" check is skipped, visibly, where no such shell is installed. The one
# entry: bash 3.2 (macOS /bin/bash) ends a heredoc substitution at the first `)` in the body; bash 4+
# does not, so a CI runner with bash 5 and dash cannot reproduce that leak. The case stays as the
# regression pin for it.
NEEDS = {"bash 3.2 ends the substitution at the first ) in the body": "bash<4"}

# ---- generated invariant-only matrix: head x joiner x tail ------------------------------------
HEADS = [
    f"git commit -m '{D} note'",
    f'gh pr create --title t --body "{D} note"',
    f"gh issue comment 5 --body-file - {H}\n{D} note\nEOF",
    f"git commit -F - {H}\n{D} note\nEOF",
    f"git tag -a v1 -m '{D} note'",
]
JOINERS = ["\n", "; ", " && ", " || ", " | ", " & ", "\n\n"]
TAILS = [
    PRINT,
    f"sh -c '{PRINT}'",
    "d'oppler' secrets get X --plain",
    f"\\{D} secrets get X --plain",
    f'bash -c "{PRINT}"',
    f"echo $({PRINT})",
    f"eval '{PRINT}'",
    f"export GIT_EDITOR=sh; git commit --allow-empty --edi -m '{PRINT}'",
    f"git config core.editor sh; git tag -a v2 --ed -m '{PRINT}'",
]
MATRIX = [(f"matrix {n}", h + j + t) for n, (h, j, t) in enumerate(itertools.product(HEADS, JOINERS, TAILS))]

# ---- driver -------------------------------------------------------------------------------------

TIMEOUT = "timeout"


def out(ok, text):
    print(("  ok   - " if ok else "  FAIL - ") + text)
    return ok


GIT_SHIM = r'''#!/bin/sh
# model of git's editor behaviour (see the driver docstring)
cmd="$1"; [ "$#" -gt 0 ] && shift
store="$HOME/.gitcfg"
if [ "$cmd" = config ]; then echo "$1=$2" >> "$store"; exit 0; fi
case "$cmd" in commit|tag) ;; *) cat 2>/dev/null; exit 0 ;; esac
msg=0; edit=0; annotated=0
for a in "$@"; do
  case "$a" in
    -m*|-F*|--message*|--file*|-C*|--reuse-message*) msg=1 ;;
  esac
  case "$a" in
    -e|--ed|--edi|--edit|--edit=*|-[a-zA-Z]*e*|-c|-c*|--reedit-message*|--fixup=amend:*|--fixup=reword:*) edit=1 ;;
    -a|-s|--annotate) annotated=1 ;;
  esac
done
[ "$cmd" = tag ] && [ "$annotated" = 0 ] && [ "$edit" = 0 ] && msg=1
[ "$msg" = 0 ] && edit=1
printf '%s\n' "$@" >> "$HOME/lastmsg"
cat 2>/dev/null | tee -a "$HOME/lastmsg"
if [ "$edit" = 1 ]; then
  ed="${GIT_EDITOR:-}"
  [ -z "$ed" ] && [ -f "$store" ] && ed="$(sed -n 's/^core.editor=//p' "$store" | tail -n 1)"
  [ -z "$ed" ] && ed="${VISUAL:-}"
  [ -z "$ed" ] && ed="${EDITOR:-}"
  [ -n "$ed" ] && sh -c "$ed \"\$@\"" sh "$HOME/lastmsg"
fi
exit 0
'''
GH_SHIM = '''#!/bin/sh
for a in "$@"; do [ -f "$a" ] || [ -p "$a" ] && cat "$a"; done
cat 2>/dev/null; exit 0
'''


def make_shims(scratch):
    bindir = os.path.join(scratch, "bin")
    os.makedirs(bindir)
    shims = {
        D: f'#!/bin/sh\necho "{MARKER}"\necho "{MARKER}" >&2\nexit 0\n',
        "git": GIT_SHIM,
        "gh": GH_SHIM,
    }
    for name, body in shims.items():
        path = os.path.join(bindir, name)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)
    return bindir


MAJORS = {}  # shell path -> major version, or None when the shell has no --version


def matches(path, need):
    """need is "<name><<major>": the shell is called <name> and its major version is below <major>."""
    name, _, limit = need.partition("<")
    major = MAJORS.get(path)
    return os.path.basename(path) == name and major is not None and major < int(limit)


def teeth(printed, need):
    """"ok" | "fail" | "skip" for the check that a bypass case really prints under a shell.

    A case with no requirement needs ANY shell to print. A case with a requirement is checked only
    against shells that match it, and is skipped only when none is present.
    """
    pool = [sh for sh in printed if need is None or matches(sh, need)]
    if not pool:
        return "skip"
    return "ok" if any(printed[sh] is True for sh in pool) else "fail"


def find_shells():
    found, seen = [], set()
    hide = os.environ.get("GUARD_DIFF_HIDE_SHELLS")  # test hook: pretend shells matching a need are absent
    for cand in ("bash", "/bin/bash", "zsh", "dash"):
        path = shutil.which(cand)
        if not path:
            continue
        try:
            ver = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10).stdout.splitlines()[:1]
        except (OSError, subprocess.SubprocessError):
            ver = []
        m = re.search(r"version (\d+)", ver[0]) if ver else None
        MAJORS[path] = int(m.group(1)) if m else None
        key = (os.path.realpath(path), tuple(ver))
        if key in seen or (hide and matches(path, hide)):
            continue
        seen.add(key)
        found.append(path)
    return found


def self_test():
    """The skip logic, on synthetic inputs: it must skip only a case whose required shell is absent."""
    fails = 0
    fake = {"/fake/bash": 3, "/fake/dash": None}
    saved = dict(MAJORS)
    MAJORS.update(fake)
    try:
        none_print = {"/fake/bash": False, "/fake/dash": False}
        fails += not out(teeth(none_print, "bash<0") == "skip",
                         "self-test: a case requiring a shell that is not present is SKIPPED, not failed")
        fails += not out(teeth(none_print, None) == "fail",
                         "self-test: a case with no shell requirement that prints nowhere still FAILS")
        fails += not out(teeth(none_print, "bash<4") == "fail",
                         "self-test: a required shell that is present and does not print FAILS (skip only when absent)")
        fails += not out(teeth({"/fake/bash": True, "/fake/dash": False}, "bash<4") == "ok",
                         "self-test: a required shell that is present and prints passes")
        fails += not out(teeth({"/fake/dash": True}, "bash<4") == "skip",
                         "self-test: dash printing does not satisfy a bash<4 requirement; with no bash<4 it is skipped")
    finally:
        MAJORS.clear()
        MAJORS.update(saved)
    return fails


def hook_rc(hook, cmd):
    event = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    p = subprocess.run(["bash", hook], input=event, capture_output=True, text=True, timeout=30)
    return p.returncode


def run_shell(shell, bindir, scratch, cmd):
    """True if the marker printed, False if not, TIMEOUT if the run did not finish."""
    work = tempfile.mkdtemp(dir=scratch)
    open(os.path.join(work, "x"), "w").close()
    env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": work, "TMPDIR": work}
    try:
        p = subprocess.run([shell, "-c", cmd], capture_output=True, text=True, timeout=20,
                           env=env, cwd=work, stdin=subprocess.DEVNULL, errors="replace")
    except subprocess.TimeoutExpired:
        return TIMEOUT
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return MARKER in (p.stdout or "") + (p.stderr or "")


def main():
    hook, scratch = sys.argv[1], sys.argv[2]
    bindir = make_shims(scratch)
    shells = find_shells()
    names = [os.path.basename(s) for s in shells]
    print(f"  info - shells under test: {', '.join(shells) or 'none'}")
    for want in ("zsh", "dash"):
        if want not in names:
            print(f"  info - {want} NOT covered on this machine (not installed)")
    fails = self_test()
    if os.environ.get("GUARD_DIFF_HIDE_SHELLS"):
        print("  info - test hook: some shells are hidden")
    if os.environ.get("CI") and "bash" not in names:
        fails += not out(False, "CI is set and no bash is available to run the corpus under")
    if not shells:
        print("  info - no shell found: only the hook's expectation is checked")
    for label, cmd, want, kind in CORPUS:
        rc = hook_rc(hook, cmd)
        got = "allow" if rc == 0 else "deny" if rc == 2 else f"rc={rc}"
        fails += not out(got == want, f"corpus {want}: {label}" + ("" if got == want else f" (hook said {got})"))
        printed = {s: run_shell(s, bindir, scratch, cmd) for s in shells}
        if got == "allow":
            bad = [os.path.basename(s) for s, p in printed.items() if p is True]
            slow = [os.path.basename(s) for s, p in printed.items() if p == TIMEOUT]
            fails += not out(not bad and not slow, f"corpus allow prints nothing under any shell: {label}"
                             + (f" (printed under {bad})" if bad else "") + (f" (timed out under {slow})" if slow else ""))
        if kind == "bypass" and shells:
            verdict = teeth(printed, NEEDS.get(label))
            if verdict == "skip":
                print(f"  info - SKIPPED the teeth check of '{label}': it needs a shell matching "
                      f"{NEEDS.get(label)} and none is installed here (the hook-side deny still ran)")
            else:
                fails += not out(verdict == "ok",
                                 f"corpus bypass really prints under a shell (the case has teeth): {label}")
    leaks, denied = 0, 0
    for label, cmd in MATRIX:
        rc = hook_rc(hook, cmd)
        if rc == 0:
            for s in shells:
                r = run_shell(s, bindir, scratch, cmd)
                if r is not False:
                    leaks += 1
                    out(False, f"{label}: hook allowed and {os.path.basename(s)} "
                        f"{'timed out' if r == TIMEOUT else 'printed the marker'}: {cmd!r}")
        else:
            denied += 1
    fails += leaks
    out(leaks == 0, f"matrix of {len(MATRIX)} head/joiner/tail combinations: the hook allowed {len(MATRIX) - denied}, none printed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
