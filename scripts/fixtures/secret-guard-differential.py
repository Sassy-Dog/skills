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

A corpus entry of kind "limit" (#666) is a KNOWN LIMIT: the hook must ALLOW it AND a declared shell must print,
so the pin has teeth and the prints-nothing rule for allowed rows does not apply to it; it takes the same
"[spec,...]" declaration as "bypass". A declared bound is only legal on a shell whose version find_shells()
reads (bash), with a minor version of at most 9 (check_spec).

A corpus entry of kind "bypass" must also PRINT under at least one shell, otherwise it proves
nothing (a bypass that no shell executes is not a bypass). A bypass row may DECLARE the shells it
prints under, in brackets after its kind: "bypass[zsh]", "bypass[bash,dash]", "bypass[bash<4]",
"bypass[bash>=5.3]" (comma-separated; a spec is a shell name, optionally followed by <MAJOR or
>=MAJOR[.MINOR]). Its teeth check then needs a print under at least one declared shell that is
PRESENT, and is SKIPPED, with a visible info line naming the row, where none is installed; it never
passes silently and never fails on a shell's absence. The hook-side deny runs for every row, on every
machine. self_test() proves the skip logic on synthetic inputs. GUARD_DIFF_HIDE_SHELLS="bash<4,zsh"
(comma-separated specs) hides such shells, to simulate a runner that has only bash 5 and dash. Shells tried: every one of bash,
/bin/bash, zsh, dash found on this machine, de-duplicated by real path and version; the shells
that ran are printed, a missing zsh is reported. With CI set, at least bash must be present.
Output: one `  ok   - ` or `  FAIL - ` line per check.

#649 rows (the expansion rules' prose exemption, see the hook docstring) spell the CLI by an expansion
or glob, so the shell environment carries D (its name), X (its first three letters) and SHELL (/bin/sh),
and a kind suffixed "@glob" runs with the working directory holding copies of the fake CLI, so a `*`
there matches it. Rows that need csh, tcsh, parallel, zsh or dash piping are "deny-only": those
programs are not on every machine, so the hook-side deny is asserted and no teeth are required.

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
# "bypass" (a command the hook must deny AND that really prints under a shell; "bypass[spec,...]"
# declares which shells it prints under, see the docstring), or "deny-only" (denied for safety, but
# no shell executes it, so there is nothing to print).
PRINT = f"{D} secrets get X --plain"
OV = "SASSYDOG_ALLOW_" + D.upper() + "_PRINT=1"  # the one-command override prefix
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
     f"git commit --allow-empty -m \"$(cat {H}\nx )\" ; {PRINT} ; : \"(\nEOF\n)\"", "deny", "bypass[bash<4]"),
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
    # KNOWN LIMITS (#666, carried from #663's review; README "Known limits"): the hook ALLOWS each and the
    # shell really runs the CLI. Kind "limit" asserts both halves (allowed, and prints under a declared
    # shell, so the pin has teeth); a change that starts denying one is a deliberate edit of this row.
    ("known limit: zsh (e) flag on a literal default in double quotes", 'echo "${(e):-\\$($D)}"', "allow", "limit[zsh]"),
    ("known limit: arithmetic subscript in let", "let 'a[$($D)]'", "allow", "limit[bash<4,bash>=5]"),
    ("known limit: arithmetic subscript in declare -i", "declare -i y='a[$($D)]'", "allow", "limit[bash<4,bash>=5]"),
    ("known limit: arithmetic subscript in printf -v (bash 3.2 does not run it)", "printf -v 'a[$($D)]' x", "allow", "limit[bash>=5]"),
    ("known limit: arithmetic subscript in test -v (bash 3.2 does not run it)", "test -v 'a[$($D)]'", "allow", "limit[bash>=5]"),
]

# #649: text that merely carries an expansion character and a common word is data, but ONLY as the
# whole input of a single plain `echo` (printf and python heredocs are NOT exempt; see the rows). The
# name is not spelled in any of these ($D, a glob, a variable), so only the expansion rules see it.
# Suffix "@glob" on a kind runs the shell with its cwd holding copies of the fake CLI (so `*` matches
# it) and the environment variables D (the CLI's name), X (its first three letters) and SHELL (sh).
CORPUS += [
    ("echo of a glob literal, then run", "echo '*' run", "allow", "msg"),
    ("echo of a glob literal, then secrets (glob dir)", "echo '*' secrets", "allow", "msg@glob"),
    ("echo of a variable, then prose", 'echo "$HOME" let me know', "allow", "msg"),
    ("echo of an unquoted variable, then run", "echo $HOME run the tests", "allow", "msg"),
    ("commit -F heredoc with backticks and run", "git commit -F - <<'EOF'\nfix: `x` a run that never starts, tell me\nEOF", "allow", "msg"),
    ("gh pr create body-file heredoc with bold and run", "gh pr create --title t --body-file - <<'EOF'\n**Summary** let me know, run it\nEOF", "allow", "msg"),
    # --- class 1 of the blocked attempt: an unbalanced quote later (an apostrophe in a comment), quoted values
    ("env, quoted option value with a blank, apostrophe in a trailing comment", "env \"$D\" -p 'a b' secrets # don't", "deny", "bypass"),
    ("env, quoted redirect target with a blank, apostrophe in a comment", "env \"$D\" 2>'a b' secrets # don't", "deny", "bypass"),
    ("nohup, quoted option value with a blank, apostrophe in a comment", "nohup \"$D\" --config-dir '/tmp/a b' secrets # it's fine", "deny", "bypass"),
    ("an escaped dollar before a quote that looks ANSI-C", "env \"$D\" -p \\$'a b\\' secrets #'", "deny", "bypass"),
    ("a doubled dollar before a quote that looks ANSI-C", "env \"$D\" -p $$'a b' secrets", "deny", "bypass"),
    # --- class 2: one shell word that reads as two
    ("command substitution carrying an option", 'env "$D" -p $(echo app) secrets', "deny", "bypass"),
    ("parameter default carrying an option", 'env "$D" ${P:--p app} secrets', "deny", "bypass"),
    ("xargs with a here-string that carries the arguments", 'xargs "$D" <<< "-p app secrets"', "deny", "bypass"),
    ("a {fd} redirect between the name and the subcommand", 'env "$D" {fd}> /dev/null secrets', "deny", "bypass"),
    ("a variable that holds an option, word-split", 'F=-p; env "$D" $F app secrets', "deny", "bypass"),
    # --- class 3: a glob literal re-read by something that is not on a shell list (the shim dir is the cwd)
    ("echo glob literal piped to sh", "echo '*' secrets | sh", "deny", "bypass@glob"),
    ("echo glob literal piped to bash", "echo '*' run | bash", "deny", "bypass@glob"),
    ("echo glob literal piped to env $SHELL", "echo '*' secrets | env $SHELL", "deny", "bypass@glob"),
    ("echo glob literal piped to awk system()", "echo '*' secrets | awk '{system($0)}'", "deny", "bypass@glob"),
    ("echo glob literal piped to perl system()", "echo '*' secrets | perl -e 'system(<STDIN>)'", "deny", "bypass@glob"),
    ("echo glob literal piped to python3 -c (python3 may be a shim that changes directory: no teeth required)",
     "echo '*' secrets | python3 -c 'import os,sys;os.system(sys.stdin.read())'", "deny", "deny-only"),
    ("echo glob literal piped to a dot-source of stdin", "echo '*' secrets | . /dev/stdin", "deny", "bypass@glob"),
    ("echo glob literal written to a file, then sourced", "echo '*' secrets > f; . ./f", "deny", "bypass@glob"),
    ("echo glob literal written to a file, then run by sh", "echo '*' secrets > f && sh f", "deny", "bypass@glob"),
    ("a fifo read by a shell, stdout redirected into it, then echo", "mkfifo p; sh <p & exec >p; echo '*' secrets", "deny", "bypass@glob"),
    ("echo glob literal piped to csh (not installed everywhere)", "echo '*' secrets | csh", "deny", "deny-only"),
    ("echo glob literal piped to tcsh (not installed everywhere)", "echo '*' secrets | tcsh", "deny", "deny-only"),
    ("echo glob literal piped to parallel (not installed everywhere)", "echo '*' secrets | parallel", "deny", "deny-only"),
    ("echo glob literal piped to zsh (not installed everywhere)", "echo '*' secrets | zsh", "deny", "deny-only"),
    ("echo glob literal piped to dash (not installed everywhere)", "echo '*' secrets | dash", "deny", "deny-only"),
    # --- the python exemption is the whole input, with no shell-out
    ("python heredoc after a fifo redirect", "mkfifo p; sh <p & exec >p; python3 -I - <<'EOF'\nprint('\"$D\" run')\nEOF", "deny", "bypass"),
    ("python heredoc, os.system", "python3 -I - <<'EOF'\nimport os\nos.system('\"$D\" run')\nEOF", "deny", "bypass"),
    ("python heredoc, subprocess shell=True", "python3 -I - <<'EOF'\nimport subprocess\nsubprocess.run('\"$D\" run', shell=True)\nEOF", "deny", "bypass"),
    ("python heredoc, __import__", "python3 -I - <<'EOF'\n__import__('os').system('\"$D\" run')\nEOF", "deny", "bypass"),
    ("python heredoc, from os import system", "python3 -I - <<'EOF'\nfrom os import system\nsystem('\"$D\" run')\nEOF", "deny", "bypass"),
    ("python heredoc, sys.modules", "python3 -I - <<'EOF'\nimport sys\nsys.modules['os'].system('\"$D\" run')\nEOF", "deny", "bypass"),
    ("python heredoc, then a command after the terminator", "python3 -I - <<'EOF'\nprint(1)\nEOF\n\"$D\" run", "deny", "bypass"),
    ("python heredoc, a backslash-newline before the first EOF line", "python3 -I - <<'EOF'\na\\\nEOF\n\"$D\" run\nEOF", "deny", "bypass"),
    ("echo with a backtick substitution that runs the name, then secrets", 'echo "`$D`" secrets', "deny", "bypass"),
    ("echo with a $( substitution that runs the name, then secrets", 'echo "$($D)" secrets', "deny", "bypass"),
    ('printf -v, quoted subscript with a substitution', 'printf -v \'a[$("$D" secrets get X --plain >&2)]\' x', "deny", "bypass"),
    ('printf -v, a second argument and run', 'printf -v \'a[$("$D" secrets get X --plain 1>&2)]\' \'%s\' run', "deny", "bypass"),
    ('printf -v, backtick subscript', 'printf -v \'a[`"$D" secrets get X --plain >&2`]\' x', "deny", "bypass"),
    ('printf -v, name glued to a quote', 'printf -v a\'[$("$D" secrets get X >&2)]\' x', "deny", "bypass"),
    ('printf with a quoted -v', 'printf \'-v\' \'a[$("$D" secrets get X >&2)]\' x', "deny", "bypass"),
    ('printf with a split-quoted -v', 'printf "-"v \'a[$("$D" secrets get X >&2)]\' x', "deny", "bypass"),
    ('printf with -v glued to the name', 'printf -va\'[$("$D" secrets get X >&2)]\' x', "deny", "bypass"),
    ('printf of a glob literal and me (printf is not exempt)', "printf '%s\\n' '*' me", "deny", "deny-only"),
    ('python heredoc, route (a): attrgetter on typing, names built from strings', 'python3 -I - <<\'EOF\'\nimport operator, typing; g = operator.attrgetter; o = g(\'s\'+\'ys.mod\'+\'ules\')(typing)[\'o\'+\'s\']; g(\'sy\'+\'stem\')(o)(\'"$D" secrets get X\')\nEOF', "deny", "bypass"),
    ('python heredoc, route (b): get_type_hints evaluating an annotation string', 'python3 -I - <<\'EOF\'\nimport typing\ndef f(x: chr(95)*2+\'imp\'+\'ort\'+chr(95)*2+"(\'o\'+\'s\').sy"+"stem(\'$D secrets get X\')"): pass\ntyping.get_type_hints(f)\nEOF', "deny", "bypass"),
    ('python heredoc, route (c): Formatter.get_field walking to os', 'python3 -I - <<\'EOF\'\nimport string, argparse; u=\'_\'*2; p=u+\'init\'+u+\'.\'+u+\'glob\'+\'als\'+u+\'[\'+\'_\'+\'o\'+\'s\'+\'].\'+\'sy\'+\'stem\'; string.Formatter().get_field(\'0.\'+p,(argparse.ArgumentParser,),{})[0](\'"$D" secrets get X\')\nEOF', "deny", "bypass"),
    ('python heredoc, f-string braces first on a line, and me (denied again: use a script file or the override)', 'python3 -I - <<\'EOF\'\nname = \'x\'\nprint(f"{name:18} me")\nEOF', "deny", "deny-only"),
    ('python heredoc, a slice, run, and a json import', "python3 -I - <<'EOF'\nimport json, sys\nrows = [1, 2, 3, 4]\nprint(rows[:3], 'then run')\nEOF", "deny", "deny-only"),
    ("echo, backslash CR LF, then a second command that runs (not a line continuation)", "echo x\\\r\n\"$D\" run", "deny", "bypass"),
    ("echo, backslash CR LF, then a second command, secrets get", "echo x\\\r\n\"$D\" secrets get X --plain", "deny", "bypass"),
    ("subcommand glued to the closing paren", 'echo "$($D secrets)" x', "deny", "bypass"),
    ("subcommand glued to the closing backtick", 'echo "`$D secrets`" x', "deny", "bypass"),
    ("subcommand glued to the closing paren, ls", 'ls "$($D secrets)"', "deny", "bypass"),
    ("glued subcommand with get --plain", 'echo "$($D secrets get X --plain)" x', "deny", "bypass"),
    ("subcommand then >&2 in a quoted substitution", 'echo "$($D secrets>&2)" x', "deny", "bypass"),
    ("subcommand then <&- in a substitution", 'echo $($D secrets<&-)', "deny", "bypass"),
    ("subcommand then a quoted ;", 'echo "$($D secrets;)" x', "deny", "bypass"),
    ("subcommand then a pipe in a substitution", 'echo "$($D secrets|cat)" x', "deny", "bypass"),
    ("subcommand then & in a substitution", 'echo "$($D secrets&)" x', "deny", "bypass"),
    ("subcommand then >&2 inside backticks", 'echo `$D secrets>&2` x', "deny", "bypass"),
    ("subcommand then >&2 under eval", 'eval "$D secrets>&2"', "deny", "bypass"),
    ("subcommand then >&2 under sh -c", 'sh -c "$D secrets>&2"', "deny", "bypass"),
    ("subcommand glued to a closing paren inside a brace default", 'echo "${Y:-$($D secrets)}" x', "deny", "bypass"),
    ("a shell reads the heredoc", "sh <<'EOF'\n\"$D\" run\nEOF", "deny", "bypass"),
    ("cat heredoc piped to a shell", "cat <<'EOF' | sh\n\"$D\" run\nEOF", "deny", "bypass"),
    # #655: the narrowing flags on the run subcommand never enable a printing flag. The fake prints
    # on every call, so these show the denied spellings really would print; the ALLOWED spellings
    # cannot be shown silent by the fake (it prints whatever its arguments) and are pinned in the
    # gate only.
    ("run --only-secrets then --print-config", f"{D} run --only-secrets A,B --print-config -- ./cmd", "deny", "bypass"),
    ("run --only-secrets with --print-config as its value", f"{D} run --only-secrets --print-config -- ./cmd", "deny", "bypass"),
    ("run --no-fallback with --debug", f"{D} run --no-fallback --only-secrets A,B --debug -- ./cmd", "deny", "bypass"),
    ("secrets get with --only-secrets", f"{D} secrets get X --plain --only-secrets A,B", "deny", "bypass"),
    # #659: the one-command override reads the command as ONE simple command through single_simple().
    # Before the fix these were ALLOWED on main and printed under bash 5, bash 3.2 and zsh (dash reads
    # `$'` as `$` then a quote and does not print, so it is not the shell that gives them teeth; the
    # comment rows print under dash too).
    ("override, ANSI-C quote hides a second command", f"{OV} echo $'\\'' ; {PRINT} ; echo \\'", "deny", "bypass"),
    ("override, ANSI-C quote glued to a word", f"{OV} echo a$'\\'' ; {PRINT} ; echo \\'", "deny", "bypass"),
    ("override, ANSI-C quote, a redirect on the tail", f"{OV} echo $'\\'' | cat ; {PRINT} ; echo \\' >/dev/null", "deny", "bypass"),
    # a comment ends at the newline but a quote opened inside it runs on, so the next line looked quoted
    ("override, a quote opened in a comment hides the next line", f"{OV} echo a #'\n{PRINT} #'", "deny", "bypass"),
    ("override, a double quote opened in a comment hides the next line", f'{OV} echo a #"\n{PRINT} #"', "deny", "bypass"),
    ("override, a spaced comment quote hides the next line", f"{OV} echo a # '\n{PRINT} # '", "deny", "bypass"),
    # a `#` that some shell reads as text, not as a comment: the shell side of the comment rule
    ("override, a hash after an escaped blank is text", f"{OV} echo a\\ #;{PRINT}", "deny", "bypass"),
    ("override, a hash after an escaped tab is text", f"{OV} echo a\\\t#;{PRINT}", "deny", "bypass"),
    ("override, a hash after an escaped blank, redirect target", f"{OV} {PRINT} > /tmp/f\\ #;{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter default", f"{OV} echo ${{x:- #}};{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter alternative", f"{OV} echo ${{x:+ #}};{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter strip", f"{OV} echo ${{x%% #}};{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter default after text", f"{OV} echo ${{x:-a #b}};{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter default, then a background operator", f"{OV} echo ${{x:- #}}&{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter default, then a pipe", f"{OV} echo ${{x:- #}}|{PRINT}", "deny", "bypass"),
    ("override, a hash inside a parameter default in the child of run", f"{OV} {D} run -- echo ${{x:- #}};{PRINT}", "deny", "bypass"),
    ("override, a hash inside an array subscript (bash only)", f"{OV} x[ #]=1 echo hi;{PRINT}", "deny", "bypass"),
    ("override, a backslash-newline before a hash", f"{OV} echo a\\\n#;{PRINT}", "deny", "bypass"),
    # a quote nested in a parameter expansion inside double quotes swaps the scan's quote state
    ("override, nested quote in a parameter default, two copies rebalance",
     f"{OV} echo \"${{x:-\"'\"}}\" ; {PRINT} ; echo \"${{x:-\"'\"}}\"", "deny", "bypass"),
    ("override, a quote in a parameter strip, two copies rebalance",
     f"{OV} echo \"${{x#'\"'}}\" ; {PRINT} ; echo \"${{x#'\"'}}\"", "deny", "bypass"),
    # arithmetic expansion `$[..]` is not modelled by the scan: a `}` or a quote inside it fools the brace and
    # quote counts (zsh also reads an unquoted quote inside it as part of the expression)
    ("override, arithmetic expansion hides a brace in a double-quoted parameter, background form",
     OV + ' echo "${x:-$[}"]}" & ' + PRINT + ' & echo "${x:-$[}"]}"', "deny", "bypass[zsh]"),
    ("override, arithmetic expansion under a parameter alternative",
     OV + ' echo "${x:+$[}"]}" & ' + PRINT + ' & echo "${x:+$[}"]}"', "deny", "bypass[zsh]"),
    ("override, arithmetic expansion nested in a second parameter",
     OV + ' echo "${x:-${z:-$[}"]}}" & ' + PRINT + ' & echo "${x:-${z:-$[}"]}}"', "deny", "bypass[zsh]"),
    ("override, arithmetic expansion in the child of run",
     f"{OV} {D} run -- " + 'echo "${x:-$[}"]}" & ' + PRINT + ' & echo "${x:-$[}"]}"', "deny", "bypass[zsh,dash]"),
    ("override, unquoted arithmetic expansion with a quote inside (zsh)",
     OV + ' echo $["] ; ' + PRINT + ' ; echo $["]', "deny", "bypass[zsh]"),
    # the same class with a quote after the closing brace, which bash 5 (not only zsh) reads as the shell
    # does, so these carry teeth on a runner with bash 5 and no zsh
    ("override, arithmetic expansion hides a brace and a quote, background form",
     OV + ' echo "${x:-$[}"\'"]}" & ' + PRINT + ' & echo "${x:-$[}"\'"]}"', "deny", "bypass[bash>=5,zsh]"),
    ("override, arithmetic expansion hides a brace and a quote, newline form",
     OV + ' echo "${x:-$[}"\'"]}"\n' + PRINT + '\necho "${x:-$[}"\'"]}"', "deny", "bypass[bash>=5]"),
    ("override, arithmetic expansion hides a brace and a quote under a parameter alternative",
     OV + ' echo "${x:+$[}"\'"]}" & ' + PRINT + ' & echo "${x:+$[}"\'"]}"', "deny", "bypass[bash>=5,zsh]"),
    ("override, arithmetic expansion hides a brace and a quote in the child of run",
     f"{OV} {D} run -- " + 'echo "${x:-$[}"\'"]}" & ' + PRINT + ' & echo "${x:-$[}"\'"]}"', "deny", "bypass[bash>=5,zsh,dash]"),
    # bash 5.3 runs the text of `${ cmd; }` and `${| cmd; }` as a command: inside double quotes the scan
    # sees a quoted string, so the `;` there hid a second command
    ("override, bash 5.3 command substitution `${ cmd; }` in double quotes",
     OV + ' echo "${ ' + PRINT + '; }"', "deny", "bypass[bash>=5.3]"),
    ("override, bash 5.3 command substitution with a newline as its terminator",
     OV + ' echo "${ ' + PRINT + '\n}"', "deny", "bypass[bash>=5.3]"),
    ("override, bash 5.3 command substitution opened by a tab",
     OV + ' echo "${\t' + PRINT + '; }"', "deny", "bypass[bash>=5.3]"),
    ("override, bash 5.3 command substitution opened by a newline",
     OV + ' echo "${\n' + PRINT + '; }"', "deny", "bypass[bash>=5.3]"),
    ("override, bash 5.3 value substitution `${| cmd; }` in double quotes",
     OV + ' echo "${| ' + PRINT + '; }"', "deny", "bypass[bash>=5.3]"),
    ("override, bash 5.3 command substitution as an assignment value",
     OV + ' x="${ ' + PRINT + '; }"', "deny", "bypass[bash>=5.3]"),
    ("override, bash 5.3 command substitution in the child of run",
     f"{OV} {D} run -- " + 'echo "${ ' + PRINT + '; }"', "deny", "bypass[bash>=5.3]"),
    # a backslash-newline pair is deleted by the shell before it parses, so it can hide an opener from the scan
    ("override, backslash-newline hides an ANSI-C opener",
     OV + " echo $\\\n'\\'' ; " + PRINT + " ; echo \\'", "deny", "bypass[bash,zsh]"),
    ("override, backslash-newline hides an arithmetic opener (zsh)",
     OV + ' echo $\\\n["] ; ' + PRINT + ' ; echo $\\\n["]', "deny", "bypass[zsh]"),
    ("override, backslash-newline hides a nested quote in a parameter",
     OV + ' echo "$\\\n{x:-"\'"}" ; ' + PRINT + ' ; echo "$\\\n{x:-"\'"}"', "deny", "bypass[bash,dash]"),
    ("override, a comment holding a separator is refused", f"{OV} echo a # x;{PRINT}", "deny", "deny-only"),
    ("override, a parameter in double quotes and a comment with an apostrophe", f"{OV} {PRINT} >/dev/null 2>&1 \"${{PWD}}\" # it's why, see x", "allow", "msg"),
    # locale quoting: no shell here reads it differently from a plain double quote (no teeth), refused anyway
    ("override, a locale-quoted target (refused, no differential found)", f'{OV} {PRINT} > $"/tmp/f"', "deny", "deny-only"),
    # the override still covers the ordinary single command: nothing prints under a shell here
    ("override, a discarded print, stdout and stderr", f"{OV} {PRINT} >/dev/null 2>&1", "allow", "msg"),
    ("override, a discarded print, a trailing comment with an apostrophe", f"{OV} {PRINT} >/dev/null 2>&1 # it's why", "allow", "msg"),
    ("override, a discarded print, a comment mark inside a word", f"{OV} {PRINT} >/dev/null 2>&1 a#b", "allow", "msg"),
]

# A bypass row declares the shells it prints under in its kind ("bypass[bash<4]"). The hook-side
# assertion always runs; only the "really prints under a shell" check is skipped, visibly, where no
# declared shell is installed. The one pre-existing declaration: bash 3.2 (macOS /bin/bash) ends a
# heredoc substitution at the first `)` in the body; bash 4+ does not, so a CI runner with bash 5 and
# dash cannot reproduce that leak. The case stays as the regression pin for it. The #659 rows declare
# zsh where only zsh runs the second command, and a CI-available shell where one does.

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


VERSIONS = {}  # shell path -> (major, minor), or None when the shell has no `version N.M` in --version
SPEC = re.compile(r"^([A-Za-z0-9_.+-]+)(?:<(\d+)|>=(\d+)(?:\.(\d+))?)?$")


def matches(path, spec):
    """spec is "<name>", "<name><MAJOR" or "<name>>=MAJOR[.MINOR]": the shell is called <name> and,
    when a bound is given, its version is below MAJOR / at least MAJOR.MINOR (a shell with no known
    version never satisfies a bound)."""
    m = SPEC.match(spec)
    if not m:
        raise ValueError(f"bad shell spec {spec!r}")
    if os.path.basename(path) != m.group(1):
        return False
    version = VERSIONS.get(path)
    if m.group(2) is not None:
        return version is not None and version[0] < int(m.group(2))
    if m.group(3) is not None:
        return version is not None and version >= (int(m.group(3)), int(m.group(4) or 0))
    return True


def matches_any(path, specs):
    """specs is a comma-separated list of specs: the shell matches at least one of them."""
    return any(matches(path, sp) for sp in specs.split(","))


KNOWN_SHELLS = ("bash", "zsh", "dash")  # the shells find_shells() can ever return
VERSIONED_SHELLS = ("bash",)  # only bash prints `version N.M`; VERSIONS is None for zsh and dash
MAX_MINOR = 9  # no bash minor version here is above this; `bash>=5.33` would skip everywhere
MAX_MAJOR = 9  # no shell here has a major version above this; `bash>=53` for `bash>=5.3` would skip everywhere


def check_spec(spec):
    """A declared shell spec must be well formed, name a shell find_shells() can find, and carry a bound
    that a real version can meet. Syntax alone is not enough: `bypass[zhs]` and `bypass[bash>=53]` parse,
    match no machine, and so turn a row's teeth check into a SKIP on every machine while the gate is green."""
    m = SPEC.match(spec)
    if not m:
        raise ValueError(f"bad shell spec {spec!r}")
    if m.group(1) not in KNOWN_SHELLS:
        raise ValueError(f"shell spec {spec!r} names {m.group(1)!r}, not one of {KNOWN_SHELLS}")
    has_bound = any(m.group(i) is not None for i in (2, 3))
    if has_bound and m.group(1) not in VERSIONED_SHELLS:
        raise ValueError(f"shell spec {spec!r}: find_shells() reads no version for {m.group(1)!r}, so a bound never matches")
    for bound in (m.group(2), m.group(3)):
        if bound is not None and int(bound) > MAX_MAJOR:
            raise ValueError(f"shell spec {spec!r} has major version {bound}, above {MAX_MAJOR}: a typo?")
    if m.group(4) is not None and int(m.group(4)) > MAX_MINOR:
        raise ValueError(f"shell spec {spec!r} has minor version {m.group(4)}, above {MAX_MINOR}: a typo?")


def parse_kind(kind):
    """"bypass[bash,zsh]@glob" -> ("bypass", "bash,zsh" or None, True)."""
    m = re.match(r"^([a-z-]+)(?:\[([^\]]+)\])?(@glob)?$", kind)
    if not m:
        raise ValueError(f"bad corpus kind {kind!r}")
    for sp in (m.group(2) or "").split(",") if m.group(2) else []:
        check_spec(sp)
    return m.group(1), m.group(2), bool(m.group(3))


def teeth(printed, need):
    """"ok" | "fail" | "skip" for the check that a bypass case really prints under a shell.

    A case with no declaration needs ANY shell to print. A case that declares shells is checked
    only against the present shells that match a declaration, and is skipped only when none is present.
    """
    pool = [sh for sh in printed if need is None or matches_any(sh, need)]
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
        m = re.search(r"version (\d+)\.(\d+)", ver[0]) if ver else None
        VERSIONS[path] = (int(m.group(1)), int(m.group(2))) if m else None
        key = (os.path.realpath(path), tuple(ver))
        if key in seen or (hide and matches_any(path, hide)):
            continue
        seen.add(key)
        found.append(path)
    return found


def self_test():
    """The skip logic, on synthetic inputs: it must skip only a case whose declared shells are all absent."""
    fails = 0
    fake = {"/fake/bash": (3, 2), "/fake5/bash": (5, 3), "/fake/dash": None, "/fake/zsh": None}
    saved = dict(VERSIONS)
    VERSIONS.update(fake)
    try:
        silent = {"/fake/bash": False, "/fake/dash": False}
        fails += not out(teeth(silent, "bash<0") == "skip",
                         "self-test: a case requiring a shell that is not present is SKIPPED, not failed")
        fails += not out(teeth(silent, None) == "fail",
                         "self-test: a case with no shell requirement that prints nowhere still FAILS")
        fails += not out(teeth(silent, "bash<4") == "fail",
                         "self-test: a required shell that is present and does not print FAILS (skip only when absent)")
        fails += not out(teeth({"/fake/bash": True, "/fake/dash": False}, "bash<4") == "ok",
                         "self-test: a required shell that is present and prints passes")
        fails += not out(teeth({"/fake/dash": True}, "bash<4") == "skip",
                         "self-test: dash printing does not satisfy a bash<4 requirement; with no bash<4 it is skipped")
        fails += not out(teeth(silent, "zsh") == "skip",
                         "self-test: a zsh-only case on a machine with no zsh is SKIPPED")
        fails += not out(teeth({"/fake/dash": True, "/fake/zsh": False}, "zsh") == "fail",
                         "self-test: a zsh-only case with zsh present and silent FAILS even though dash printed")
        fails += not out(teeth({"/fake/dash": False, "/fake/zsh": True}, "zsh") == "ok",
                         "self-test: a zsh-only case with zsh present and printing passes")
        fails += not out(teeth({"/fake/dash": True, "/fake/zsh": False}, "zsh,dash") == "ok",
                         "self-test: a case declaring two shells passes when either present one prints")
        fails += not out(teeth({"/fake/bash": False, "/fake5/bash": False}, "bash>=5.3") == "fail",
                         "self-test: a bash>=5.3 case with a bash 5.3 present and silent FAILS")
        fails += not out(teeth({"/fake/bash": True}, "bash>=5.3") == "skip",
                         "self-test: a bash 3.2 that prints does not satisfy bash>=5.3; with no newer bash it is SKIPPED")
        fails += not out(not matches("/fake5/bash", "bash>=5.4") and matches("/fake5/bash", "bash>=5.3")
                         and matches("/fake5/bash", "bash>=5") and not matches("/fake/dash", "dash>=0"),
                         "self-test: version bounds compare major and minor, and an unversioned shell never meets a bound")
        for typo in ("bypass[zhs]", "bypass[bash>=53]", "bypass[bash<40]", "bypass[bash,zhs]", "bypass[bash>=5.3,dsh]",
                     "bypass[bash>=5.33]", "bypass[bash>=5.99]", "bypass[zsh>=5.9]", "bypass[dash>=0]", "bypass[zsh<6]"):
            try:
                parse_kind(typo)
                rejected = False
            except ValueError:
                rejected = True
            fails += not out(rejected, f"self-test: a declaration typo {typo!r} is rejected, not silently skipped")
        fails += not out(all(parse_kind(k)[1] for k in ("bypass[zsh]", "bypass[bash>=5.3]", "bypass[bash<4]",
                                                       "bypass[bash>=5,zsh]", "bypass[zsh,dash]")),
                         "self-test: every declaration the corpus uses is still accepted")
    finally:
        VERSIONS.clear()
        VERSIONS.update(saved)
    return fails


def hook_rc(hook, cmd):
    event = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    p = subprocess.run(["bash", hook], input=event, capture_output=True, text=True, timeout=30)
    return p.returncode


def run_shell(shell, bindir, scratch, cmd, glob=False):
    """True if the marker printed, False if not, TIMEOUT if the run did not finish.

    With glob=True the working directory holds copies of the shims, so a `*` there matches the fake
    CLI (the case a real glob would hit when a directory holds the real one).
    """
    work = tempfile.mkdtemp(dir=scratch)
    open(os.path.join(work, "x"), "w").close()
    if glob:
        for name in os.listdir(bindir):
            shutil.copy2(os.path.join(bindir, name), os.path.join(work, name))
    env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": work, "TMPDIR": work,
           "D": D, "X": D[:3], "SHELL": "/bin/sh"}
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
    skipped = 0
    for label, cmd, want, rowkind in CORPUS:
        kind, need, glob = parse_kind(rowkind)
        rc = hook_rc(hook, cmd)
        got = "allow" if rc == 0 else "deny" if rc == 2 else f"rc={rc}"
        fails += not out(got == want, f"corpus {want}: {label}" + ("" if got == want else f" (hook said {got})"))
        printed = {s: run_shell(s, bindir, scratch, cmd, glob) for s in shells}
        if got == "allow" and kind != "limit":
            bad = [os.path.basename(s) for s, p in printed.items() if p is True]
            slow = [os.path.basename(s) for s, p in printed.items() if p == TIMEOUT]
            fails += not out(not bad and not slow, f"corpus allow prints nothing under any shell: {label}"
                             + (f" (printed under {bad})" if bad else "") + (f" (timed out under {slow})" if slow else ""))
        if kind in ("bypass", "limit") and shells:
            verdict = teeth(printed, need)
            if verdict == "skip":
                skipped += 1
                print(f"  info - SKIPPED the teeth check of '{label}': it needs a shell matching "
                      f"{need} and none is installed here (the hook-side deny still ran)")
            else:
                fails += not out(verdict == "ok",
                                 f"corpus {kind} really prints under a shell (the case has teeth): {label}")
    if skipped:
        print(f"  info - {skipped} bypass row(s) had their teeth check skipped on this machine (listed above)")
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
