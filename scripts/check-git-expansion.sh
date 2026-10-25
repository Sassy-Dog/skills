#!/usr/bin/env bash
# check-git-expansion.sh FILE... — list every agent-run unit that runs `git` and
# also carries a shell expansion (issue #578; the rule behind preflight.sh's
# guard 3b). Prints one `path:line: ...` row per offending unit; exit 0 means the
# scan completed (an empty output is "clean"), nonzero means the scan itself
# failed. The CALLER decides on the captured output, never on this exit status
# alone: preflight treats non-empty output as a hit and any other nonzero as an
# error, never as clean.
#
# THE RULE, and its measured basis. A Claude Code session isolated in a git
# worktree refuses a Bash command that "names git in a form too complex to
# verify". Measured in a worktree-isolated session (#578, on top of #574, #576
# and #577), judging the WHOLE command string, not the statement that holds git:
#   refused   B=main; git merge-base "origin/${B}" HEAD         (`${`)
#   refused   printf 'x %s\n' "$PWD"; git status                (`$PWD`; git is a
#                                                                separate statement)
#   refused   an unset variable (`$X`) on a line before or after `git status`
#             in a two-line command, in BOTH orders
#   refused   `$(...)` anywhere in the string, with git inside it or beside it
#   allowed   echo "$HOME"; git status   (a variable the guard can resolve, here
#             an environment variable; also `B=main; git log "$B"`)
#   allowed   git status on one line and echo "$HOME" on the next, both orders
#   allowed   cd <literal worktree path>, then git status
# The guard resolves some plain `$NAME` expansions and refuses the rest, and an
# agent cannot know which kind its text will be, because a variable a skill
# prints in one Bash call is unset in the next (cwd and shell state reset between
# calls). So the rule is the conservative one: a UNIT that runs `git` contains no
# shell expansion at all. That is stricter than the guard on the allowed rows
# above, on purpose: those pass by coincidence of the environment.
#
# A UNIT is a fenced block (info string empty or bash/sh/shell/zsh; every other
# fence is skipped) or an inline code span on one line. It "runs git" when a
# command position holds `git` or `<path>/git`: the start of a line or of a
# statement after `;` `&` `|` `(` `{` backtick `$(` `<(`, past then/do/else/
# xargs/env/command/exec/sudo/time/nohup/`!` and any leading VAR=value words.
# It "carries an expansion" when it holds `$NAME`, `${`, `$(`, a positional
# (`$1`), `$@` `$*` `$?`, a backtick (inside a fenced block, or inside a
# double-backtick span), or `<(`; a backslash-escaped dollar is not one. Lines
# whose first non-space character is `#` are comments and count for neither half.
#
# NOT covered, named so nothing claims more than it checks: an inline span that
# wraps across two lines; indented (four-space) code blocks; a fence inside a
# blockquote (a "> ```bash" line is not recognised as an opener); the special
# parameters $$ $# $! $- and the quoting forms $'...' and $"..." (none is counted
# as an expansion); a `git` that only
# appears as a quoted string handed to another program (`bash -c '...'`, `ssh
# host git ...`); `git` reached through an alias or a variable holding its name;
# and a `git` whose command position the splitter misreads because a separator
# sits inside quotes (that errs toward a false hit, never a miss). Scripts under
# skills/*/scripts/ are exempt by construction: they run as `bash <script>`, and
# the guard does not see inside one (measured in #576).
#
# Portable awk: BSD awk (macOS) and mawk/gawk (CI). No interval expressions, no
# gensub, no \< \>.
set -uo pipefail
export LC_ALL=C

[ "$#" -gt 0 ] || { echo "check-git-expansion: no files given" >&2; exit 64; }

awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function has_expansion(s,   t) {
    t = s
    gsub(/\\\$/, "", t)
    if (t ~ /\$[A-Za-z_{(@*?0-9]/) return 1
    if (t ~ /<\(/) return 1
    if (index(t, "`") > 0) return 1
    return 0
}
# 1 when some statement of s starts with git (or <path>/git) as the command word.
function runs_git(s,   t, n, parts, i, w, k, words, nw) {
    t = s
    gsub(/\$\(|<\(|`/, ";", t)
    gsub(/[;&|(){}]/, ";", t)
    n = split(t, parts, ";")
    for (i = 1; i <= n; i++) {
        nw = split(trim(parts[i]), words, /[ \t]+/)
        k = 1
        while (k <= nw) {
            w = words[k]
            if (w ~ /^(then|do|else|if|while|until|xargs|env|command|exec|sudo|time|nohup|!)$/ || w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k++; continue }
            break
        }
        if (k <= nw && (words[k] == "git" || words[k] ~ /\/git$/)) return 1
    }
    return 0
}
function excerpt(s) { s = trim(s); if (length(s) > 110) s = substr(s, 1, 107) "..."; return s }
function emit_fence(name) {
    if (f_git && f_exp)
        printf "%s:%d: fenced block (opens line %d): git at line %d, shell expansion at line %d: %s\n", name, f_git, f_open, f_git, f_exp, excerpt(f_gitline)
}
function run_len(s, from, ch,   r) { r = 0; while (substr(s, from + r, 1) == ch) r++; return r }
function inline_spans(line, lineno,   i, n, run, j, rl, body, close_at) {
    n = length(line); i = 1
    while (i <= n) {
        if (substr(line, i, 1) != "`") { i++; continue }
        run = run_len(line, i, "`")
        close_at = 0
        j = i + run
        while (j <= n) {
            if (substr(line, j, 1) == "`") {
                rl = run_len(line, j, "`")
                if (rl == run) { close_at = j; break }
                j += rl
            } else j++
        }
        if (close_at == 0) { i += run; continue }
        body = substr(line, i + run, close_at - (i + run))
        if (runs_git(body) && has_expansion(body))
            printf "%s:%d: inline span: %s\n", FILENAME, lineno, excerpt("`" body "`")
        i = close_at + run
    }
}
# A fence still open when the previous file ended is reported under THAT file:
# awk has already advanced FILENAME here, and BSD awk has no ENDFILE.
FNR == 1 { if (in_fence && f_shell) emit_fence(prev_file); in_fence = 0 }
{ prev_file = FILENAME }
{
    line = $0
    t = trim(line)
    if (in_fence) {
        r = run_len(t, 1, f_char)
        if (r >= f_len && r == length(t)) {
            if (f_shell) emit_fence(FILENAME)
            in_fence = 0
            next
        }
        if (!f_shell) next
        if (t == "" || substr(t, 1, 1) == "#") next
        if (!f_git && runs_git(t)) { f_git = FNR; f_gitline = t }
        if (!f_exp && has_expansion(t)) f_exp = FNR
        next
    }
    c = substr(t, 1, 1)
    if ((c == "`" || c == "~") && run_len(t, 1, c) >= 3) {
        f_char = c; f_len = run_len(t, 1, c)
        info = trim(substr(t, f_len + 1))
        sub(/[ \t].*$/, "", info); info = tolower(info)
        if (c == "`" && index(info, "`") > 0) { inline_spans(line, FNR); next }
        f_shell = (info == "" || info == "bash" || info == "sh" || info == "shell" || info == "zsh")
        in_fence = 1; f_open = FNR; f_git = 0; f_exp = 0; f_gitline = ""
        next
    }
    inline_spans(line, FNR)
}
END { if (in_fence && f_shell) emit_fence(FILENAME) }
' "$@"
