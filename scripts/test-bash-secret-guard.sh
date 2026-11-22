#!/usr/bin/env bash
# test-bash-secret-guard.sh — pins hooks/bash-secret-guard.{sh,py}, the PreToolUse(Bash)
# hook the plugin ships through hooks/hooks.json (#641).
#
# Why this exists: the failure it guards is silent. `doppler secrets get NAME` prints the
# live value into the transcript, the command text contains no credential, and a hook cannot
# see output, so the only defence is a rule about WHICH commands may run. A classifier that
# quietly allows a printing form, or denies the forms people legitimately use until the hook
# is switched off, gives no signal in either direction. Every case below is one of the two.
#
# History that shaped the design (three review rounds on #643): the first versions parsed the
# shell and classified piped, captured and wrapped forms as safe; every round found a new
# spelling that slipped through (reserved words, wrapper option values, flag values read as
# the subcommand, `>f 1<&2`, `xargs doppler {}`, python -c strings, DOPPLER on a
# case-insensitive filesystem, $'doppler', bash <<<"..."). The shell parser is gone. The rule
# is now a WHOLE-COMMAND ALLOW LIST matched on the raw string: if the command mentions doppler
# in any spelling the text can show (case-folded, escapes decoded, quotes/backslashes/braces/
# brackets/wildcards stripped), the ENTIRE command must be exactly one of the allowed forms
# (--only-names; `doppler run -- <cmd>`; get/download/substitute redirected to a literal file;
# a bare non-printing subcommand; and the two narrow forms the plugin's own skills emit, the
# eval bootstrap and `get --plain | gh secret set`), or it is denied. A false deny costs a bypass token; a false
# allow costs a secret in a transcript.
#
# Asserted, by piping the harness's event JSON into the hook exactly as Claude Code does.
# Every deny case asserts a fragment of the expected message (the Doppler text, or the
# literal-password text), so a denial for the wrong reason is red:
#   - the plain printing forms (get, download, substitute, bare, --raw, --json, --plain),
#     --silent, `--only-names=<value>` and `secrets set/delete/upload` as not allowed
#   - EVERY command review rounds 1-3 listed, as a deny: reserved words, wrappers and their
#     option values, shell strings (bash -c, fish/pwsh/csh -c, eval, `| bash`, here-strings
#     attached or spaced, `bash <(...)`, `source <(...)`), consumers and captures (| wc,
#     | sed p, | grep -ec, $(...) under X=, export, declare, env, curl -H, echo, bash -c "echo
#     $(...)", ${x:-$(...)}), redirect tricks (/dev/fd/*, //dev, /dev/./fd, /dev/../dev,
#     /tmp/../dev, /dev//stdout, /dev/console, /proc/self/fd, /dev/pts, > >(cat), >f >&2,
#     >f 1>&2, >f 1<&2, >f 1<>/dev/fd/2, <>path, $F, ../ climbs, fd/1, cd /dev && ...), flag
#     values read as the subcommand (-p run, --dashboard-host run, --dns-resolver-address -h or
#     --only-names), a subcommand that is not a literal (xargs/parallel/$(echo secrets)/$S),
#     interpreter strings (python3, perl, ruby, node, osascript), non-literal command names
#     (DOPPLER, Doppler, $'doppler', $"doppler", $'\x64oppler', {doppler,}, doppl[e]r, d*ppler,
#     $(which doppler), ${X}pler), and `doppler configure get`, `--all`, `--print-config`,
#     `configs tokens create`
#   - the allowed forms, with realistic arguments: --only-names (with -p/-c/--json and the
#     wc/head/grep suffixes), `doppler run -- <cmd>` (including `bash -c '...$SECRET...'` and
#     --command), get/download/substitute redirected to a literal path, bare non-printing
#     subcommands, an unrelated command that never mentions doppler
#   - the literal credentialed URL rule: each scheme, +driver suffixes, an empty user, upper
#     case; a URL without a password, host:port, https, and an unquoted env-var password
#     ($PW, ${PW}) allowed; a single-quoted literal `$ecret` denied
#   - the per-command bypass variables, one per rule, work only as a LEADING unquoted assignment
#     on a single simple command (and then cover the strings it runs), never by substring,
#     quoting, another stage, or the hook's own environment
#   - every unclassifiable input fails open WITH a stderr message and exit 1 (never 0, never
#     2): empty stdin, whitespace, malformed JSON, a non-object, a Bash event with no command,
#     a non-string command, python3 missing from PATH, and an internal classifier fault
#     (injected by importing the module and making analyze raise). A non-Bash tool is exit 0
#   - hooks/hooks.json parses, declares one PreToolUse/Bash command hook, and the command it
#     declares, with ${CLAUDE_PLUGIN_ROOT} substituted as the harness does, denies a real
#     printing command (exit 2) and allows a real safe one (exit 0)
#   - review 4 (five Blocking findings), each with committed cases: a backslash-newline or
#     backslash-CRLF joining the halves of the command name; `\u` with 1-4 and `\U` with 1-8 hex
#     digits and `\x` with an upper-case digit, on a subcommand that is NOT a keyword so only the
#     decoder can catch it; `\e`; a glob or expansion in the command NAME (`dop*ler`, `dopp?er`,
#     `${X}pler`, `d${X}oppler`, `"$D"`, `$D`) before a bare secrets/configure/run/me argument, with
#     `ls $HOME/secrets`, `gh run view $ID` and `echo "$HOME" && gh run list` allowed so the rule
#     cannot grow into a ban on `run`; /DEV, /Dev, /PROC, /Sys and a relative DEV/ or Fd/
#     redirect target; and the forms the plugin's own skills emit, with their near misses as
#     denies (the `eval "$(doppler secrets download --no-file ...)"` bootstrap, and
#     `get NAME --plain | gh secret set NAME`; review 6 cut the bootstrap's `&&` tail)
#   - review 5 (four Blocking findings), each with committed cases: the bootstrap's `&&` tail
#     (since cut by review 6, see below); the bootstrap is exactly `--no-file --format env` (no --format json/dotnet-json/
#     env-no-quotes/docker, no --name-transformer with or without `=`, no global --json/--debug/
#     --api-host); the subcommand word is found with quotes and backslashes removed and on
#     segments split outside quotes (`sec''rets`, `s"e"crets`, `\configure`, `r''un`, `\me`,
#     `--scope=';' secrets`); a relative redirect is resolved against the event's `cwd` (cwd /dev
#     then `> 1`, `> out.txt`, a symlink to /dev, /DEV, /proc/self); the decoder cases (octal,
#     `\e`, `\E`, `\c`, NFKC before decoding, NFKC on plain text); RecursionError from
#     json.loads fails open (injected, since newer Pythons parse any depth); and the sweep below
#     checks every line of a fenced block that mentions doppler, with a fixture holding the OLD
#     bulk-sync text that must still be flagged
#   - review 6 (two Blocking bypasses in the code that let the plugin's own skills pass; the
#     operator cut the surface): the bootstrap's `&&` compound form and its tail checker are
#     removed, so the bootstrap is allowed only as the whole command (`&&`, `;`, `|`, `||`, `&`,
#     newline, a redirect or any text after it denies; the follow-up runs as `doppler run -- cmd`,
#     which is allowed and pinned); an `&` beside `>` or `<` is a redirect and no longer splits a
#     segment (`dop?ler 2>&1 secrets`, `"$D" >&2 secrets`, `$D 2>&1 configure`, `${D} 1>&2 secrets`,
#     `dop?ler >&2 run --command set`, `&>`, `<&`); a command word that holds an expansion or glob
#     triggers on its own, past leading assignments and redirections (`dop?ler s?crets`,
#     `A=1 $D projects`, `>out $D projects`), with `[`, `[[`, `ls $HOME/secrets`, `gh run view $ID`,
#     `gh api .../actions/secrets` and `2>&1` on ordinary commands allowed
#   - a sweep: every `doppler` command in a tracked file under skills/ or agents/ (every non-comment
#     line of a fenced block that mentions doppler at all, and inline code spans holding
#     `doppler <word>`) must be allowed by the guard or carry the bypass, so the
#     guard cannot again deny what the plugin tells an agent to run. A prose mention inside a
#     code span counts: write it without `doppler <word>` in backticks. The extractor must find
#     commands, and each known site (scope-hierarchy, config-contract, interview, detection)
#     must be among them, so a broken extraction cannot pass by finding nothing
#   - speed: a 0.5-2 MB command (many credential URLs, a leading quote plus many URLs, an
#     expansion plus 100k words, a plain command) classifies in under 5 s with the expected
#     exit code; a hook timeout fails open without a word
# Equivalent or unreachable by text, NOT asserted: `\c` and `\e` produce control characters, which
# cannot spell a letter, so the decoder only matters when the control character is stripped and
# joins a word (the `dopp\eler` cases pin that, a deliberate over-trigger).
# Documented limits are NOT asserted as caught: aliases and functions, a command name built at
# run time from pieces the text never spells (printf formatting), symlinked redirect targets,
# reading a redirected file back, `doppler run -- env` / `printenv` (the child decides),
# `password=` URL forms, the two-step symlink rename (`ln -s <doppler> /tmp/dp`, then
# `/tmp/dp secrets`: each command text is innocent alone). See the module docstring.
#
# Mutations run against hooks/bash-secret-guard.py after the rewrite, each making cases red
# (failing-case count in parentheses), then reverted:
#   trigger:   drop the case-fold (3); drop the strip-normalise step (4); drop the expansion
#              trigger (3); drop escape decoding AND the expansion trigger together (5, each
#              alone is covered by the other); trigger on a leading command word only, i.e. no
#              interpreter/commit-message/ssh strings (119)
#   form 1:    --only-names not required (3); pipe tail unchecked (2)
#   form 2:    child may itself trigger (2); child unchecked (8); child may chain with ; (8)
#   form 3:    get without a redirect (14); no-file download without a redirect (2);
#              substitute with neither redirect nor --output (3); /dev, /proc, /sys prefix
#              refusal dropped (10); relative device segment refusal dropped (2); dot-segment
#              refusal dropped (3); `$` allowed in path and strict charsets (1)
#   form 4:    `configure` added to the bare list (1); `me` accepting flags (1)
#   flags:     unknown flags allowed (5); a value may start with `-` (2)
#   bypass:    honoured as a substring (4); honoured without the single-command check (7)
#   URL:       any `$` password exempt (2); case-sensitive scheme (1)
#   review 4 (each against the review-4 cases; failing-case count in parentheses):
#              line-continuation strip dropped (3); `\u` four digits only (1); `\u` not decoded
#              (4); `\U` not decoded (2); `\U` four digits only (2); case folded before decoding,
#              which turns `\U` into `\u` (1); `\x` lower-case digits only (1); command-name
#              keyword rule dropped (14); path prefix check not folded (6); relative device
#              segment not folded (2); bootstrap form not allowed (7); bootstrap without `--no-file` allowed (1); gh pipe not allowed (4);
#              gh pipe allows `--body` (1); gh pipe without `--plain` allowed (1); decoded reading
#              only, which drops the letter after `\e` (1); quote scan restarted per URL match,
#              i.e. quadratic (2); scope-hierarchy.md's old bulk-sync loop restored (1);
#              interview.md's prose span `doppler secrets download` restored (1)
#   review 5 (failing-case count in parentheses): bootstrap
#              `--format` not required to be env (6); `--name-transformer` allowed (2); global
#              --json/--debug/--api-host allowed in the bootstrap (4); `--debug` back on the
#              global list (1); `--api-host` back on the global list (1); segment text not
#              stripped of quotes and backslashes (6); keyword phrases (`secrets get`) matched on
#              raw text (1); segments split naively on a quoted `;` (5); ANSI-C backslash not
#              honoured in the splitter (1); octal escapes not decoded (2); `\c` not decoded (1);
#              `\e` not decoded (1); `\E` not decoded (1); no NFKC on plain text (1); cwd ignored
#              (8); cwd symlinks not resolved (1); cwd not case-folded (1); RecursionError not
#              caught (1, the injected case); the sweep matching only `doppler <word>` lines in
#              fenced blocks (1)
#   review 6 (failing-case count in parentheses): the bootstrap accepts text after the eval (23);
#              the segment splitter splits at every `&` (2); only an `&` BEFORE `>`/`<` is
#              spared (1); only an `&` AFTER `>`/`<` is spared (1); command-word trigger dropped
#              (5); leading assignments not skipped (2); leading redirections not skipped (2);
#              `[`/`[[`/`{` not exempt (2). The first-word rule also covers the splitter probes
#              by itself, which is why the splitter has its own `> out $D 2>&1 secrets` cases.
#              The deleted tail code's mutants (tail check off, `$`, env/proc text, dumpers) went
#              with it.
#
# Safe beside every other gate: own mktemp -d, no fixed path, no network, no repo mutation.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/bash-secret-guard.sh"
PY="$REPO_ROOT/hooks/bash-secret-guard.py"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass_n=0
fail_n=0
ok() { pass_n=$((pass_n + 1)); echo "  ok   - $1"; }
bad() { fail_n=$((fail_n + 1)); echo "  FAIL - $1"; }

event() { # <command> -> Bash PreToolUse event JSON
    python3 -I -B -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

event_cwd() { # <cwd> <command> -> Bash PreToolUse event JSON carrying the harness's cwd
    python3 -I -B -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$1" "$2"
}

# run_event <json> -> sets rc, err
run_event() {
    err="$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null)"
    rc=$?
}
run_cmd() { run_event "$(event "$1")"; }

deny() { # <label> <command> [message fragment; default picked from the command]
    local frag="${3:-}"
    if [ -z "$frag" ]; then
        case "$2" in
            *://*:*@*) frag='literal password' ;;
            *) frag='allowed Doppler forms' ;;
        esac
    fi
    run_cmd "$2"
    if [ "$rc" -eq 2 ] && grep -qF -- "$frag" <<<"$err"; then
        ok "denied: $1"
    else
        bad "denied: $1 (rc=$rc, wanted message containing '$frag', err=${err:-<none>})"
    fi
}
allow() {
    run_cmd "$2"
    if [ "$rc" -eq 0 ]; then ok "allowed: $1"; else bad "allowed: $1 (rc=$rc err=${err:-<none>})"; fi
}
failopen() { # <label> <raw stdin>
    run_event "$2"
    if [ "$rc" -eq 1 ] && grep -q 'fail open' <<<"$err"; then
        ok "fails open and says so: $1"
    else
        bad "fails open and says so: $1 (rc=$rc err=${err:-<none>})"
    fi
}

echo "== preconditions =="
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }
[ -f "$HOOK" ] && [ -f "$PY" ] && [ -f "$HOOKS_JSON" ] && ok "hook files exist" || { bad "hook files exist"; exit 1; }

echo "== plain printing forms =="
deny "secrets get" 'doppler secrets get DATABASE_URL'
deny "secrets get with project flags" 'doppler secrets get DATABASE_URL -p app -c prd'
deny "global flags before secrets" 'doppler -p app secrets get X'
deny "secrets get --raw" 'doppler secrets get DATABASE_URL --raw'
deny "secrets get --json" 'doppler secrets get DATABASE_URL --json'
deny "bare secrets" 'doppler secrets'
deny "bare secrets with flags and values" 'doppler secrets -p app -c prd --json'
deny "secrets download" 'doppler secrets download --no-file'
deny "secrets substitute" 'doppler secrets substitute template.yaml'
deny "unknown word after secrets" 'doppler secrets frobnicate'
deny "unknown flag" 'doppler secrets --weird val get X'
deny "--plain" 'doppler secrets get X --plain'
deny "--raw --plain" 'doppler secrets get X --raw --plain'
deny "--silent is not a safe form" 'doppler secrets get X --silent'
deny "--silent=0" 'doppler secrets get X --silent=0'
deny "--silent on bare secrets" 'doppler secrets --silent'
deny "--only-names=0" 'doppler secrets get X --only-names=0'
deny "--only-names=false" 'doppler secrets --only-names=false'
deny "--only-names=true (must be a bare flag)" 'doppler secrets --only-names=true'
deny "--only-names=1" 'doppler secrets --only-names=1'
deny "--only-names then switched off" 'doppler secrets get X --only-names --only-names=false'
deny "get with --only-names is not an allowed form" 'doppler secrets get X --only-names'
deny "secrets set" 'doppler secrets set X value'
deny "secrets delete" 'doppler secrets delete X'
deny "secrets upload" 'doppler secrets upload .env'
deny "--copy" 'doppler secrets get X --copy > /tmp/f'
deny "token on the command line" 'doppler secrets get X --token dp.st.x > /tmp/f'
deny "denial text names the safe forms" 'doppler secrets get X'
case "$err" in
    *--only-names*"doppler run"*"/literal/path"*"reading it back"*SASSYDOG_ALLOW_DOPPLER_PRINT*) ok "the denial message names the safe forms and the bypass" ;;
    *) bad "the denial message names the safe forms and the bypass (got: $err)" ;;
esac

echo "== pipes into consumers buy nothing =="
deny "| wc -c" 'doppler secrets get X --plain | wc -c'
deny "| sha256sum" 'doppler secrets get X --raw --plain | sha256sum'
deny "| grep -c" 'doppler secrets get X --plain | grep -c .'
deny "| grep -ec" 'doppler secrets get X --plain | grep -ec .'
deny "| grep -e -c" 'doppler secrets get X --plain | grep -e -c'
deny "| head -c0" 'doppler secrets get X --plain | head -c0'
deny "| head -c0 -n5" 'doppler secrets get X --plain | head -c0 -n5'
deny "| wc --files0-from=-" 'doppler secrets get X --plain | wc -c --files0-from=-'
deny "| xargs wc" 'doppler secrets get X --plain | xargs wc'
deny "| sed d" 'doppler secrets get X --plain | sed d'
deny "| sed p" 'doppler secrets get X --plain | sed p'
deny "| sed -n p" 'doppler secrets get X --plain | sed -n p'
deny "| sed multi-command script" "doppler secrets get X --plain | sed 's/.*/x/;N;s/a/a/'"
deny "| tee" 'doppler secrets get X --plain | tee out.txt'
deny "| cat" 'doppler secrets get X --plain | cat'
deny ">&2 | wc -c" 'doppler secrets get X --plain >&2 | wc -c'
deny "1>&2 | sha256sum" 'doppler secrets get X --plain 1>&2 | sha256sum'
deny "--only-names piped to something else" 'doppler secrets --only-names | tee /tmp/names'
deny "--only-names piped twice" 'doppler secrets --only-names | wc -l | cat'
deny "--only-names piped to sh" 'doppler secrets --only-names | sh'

echo "== captures buy nothing =="
deny "assignment capture" 'TOKEN=$(doppler secrets get X --plain)'
deny "assignment capture, stderr dup" 'X=$(doppler secrets get X --plain >&2)'
deny "set -x then capture" 'set -x; X=$(doppler secrets get X --plain)'
deny "export capture" 'export TOKEN=$(doppler secrets get X --plain)'
deny "export with a bare capture" 'export $(doppler secrets get X --plain)'
deny "declare capture" 'declare -p X=$(doppler secrets get X --plain)'
deny "env capture" 'env X=$(doppler secrets get X --plain) true'
deny "sha256sum capture" 'sha256sum $(doppler secrets get X --plain)'
deny "test capture" '[ -n "$(doppler secrets get X --plain)" ] && echo set'
deny "[ ] -eq capture" '[ "$(doppler secrets get X --plain)" -eq 1 ]'
deny "[[ ]] capture" '[[ -n "$(doppler secrets get X --plain)" ]]'
deny "echo capture" 'echo "$(doppler secrets get X --plain)"'
deny "printf capture" 'printf "%s\n" $(doppler secrets get X --plain)'
deny "curl header capture" 'curl -H "A: $(doppler secrets get T --plain)" https://example.com'
deny "bash -c double-quoted capture" 'bash -c "echo $(doppler secrets get X --plain)"'
deny "bash -c single-quoted capture" "bash -c 'echo \$(doppler secrets get X --plain)'"
deny "default-value expansion" 'echo ${x:-$(doppler secrets get X --plain)}'
deny "quoted default-value expansion" 'echo "${x:-$(doppler secrets get X --plain)}"'
deny "backticks" 'echo `doppler secrets get X --plain`'
deny "capture as the command word" '$(doppler secrets get X --plain)'
deny "command-prefix capture" 'V=$(doppler secrets get X --plain) printenv V'
deny "process substitution" 'cat <(doppler secrets get X --plain)'

echo "== reserved words and separators =="
deny "for loop" 'for x in A B; do doppler secrets get $x; done'
deny "while loop" 'while read x; do doppler secrets get $x; done < names.txt'
deny "until loop" 'until false; do doppler secrets get X; done'
deny "if/then" 'if true; then doppler secrets get X; fi'
deny "else branch" 'if false; then :; else doppler secrets get X; fi'
deny "negation" '! doppler secrets get X'
deny "second segment after ;" 'echo start; doppler secrets get X'
deny "second segment after &&" 'cd /tmp && doppler secrets get X'
deny "an allowed form followed by a second command" 'doppler secrets --only-names; doppler secrets get X'
deny "an allowed form joined by &&" 'doppler secrets --only-names && doppler secrets get X'
deny "an allowed form joined by ||" 'doppler secrets --only-names || doppler secrets get X'
deny "an allowed form joined by newline" $'doppler secrets --only-names\ndoppler secrets get X'
deny "an allowed form in the background" 'doppler secrets --only-names & doppler secrets get X'
deny "doppler run followed by a second command" 'doppler run -- ./deploy.sh; doppler secrets get X'
deny "doppler run piped into doppler" 'doppler run -- ./deploy.sh | doppler secrets get X'

echo "== wrappers: nothing depends on knowing them =="
deny "absolute doppler path" '/usr/local/bin/doppler secrets get X'
deny "sudo" 'sudo doppler secrets get X'
deny "sudo -u value" 'sudo -u root doppler secrets get X'
deny "sudo -g value" 'sudo -g wheel doppler secrets get X'
deny "env assignment" 'env FOO=1 doppler secrets get X'
deny "env -u value" 'env -u FOO doppler secrets get X'
deny "env -C value" 'env -C /tmp doppler secrets get X'
deny "env -S command string" "env -S 'doppler secrets get X'"
deny "env -iS cluster" "env -iS 'doppler secrets get X'"
deny "env -S attached" "env -S'doppler secrets get X'"
deny "env --split-string=" "env --split-string='doppler secrets get X'"
deny "nice -n" 'nice -n 5 doppler secrets get X'
deny "timeout -s and duration" 'timeout -s KILL 5 doppler secrets get X'
deny "stdbuf -o" 'stdbuf -o L doppler secrets get X'
deny "xargs -I" 'echo X | xargs -I {} doppler secrets get {}'
deny "xargs -n" 'echo X | xargs -n 1 doppler secrets get'
deny "doas" 'doas doppler secrets get X'
deny "setsid" 'setsid doppler secrets get X'
deny "watch" 'watch doppler secrets get X'
deny "flock" 'flock /tmp/f doppler secrets get X'
deny "ionice -c3" 'ionice -c3 doppler secrets get X'
deny "taskset 1" 'taskset 1 doppler secrets get X'
deny "strace" 'strace doppler secrets get X'
deny "ssh host" 'ssh host doppler secrets get X'
deny "ssh host quoted string" "ssh host 'doppler secrets get X'"
deny "find -exec" 'find . -exec doppler secrets get X \;'
deny "docker exec" 'docker exec c doppler secrets get X'
deny "stacked wrappers" 'sudo -u root env -u A nice -n 3 doppler secrets get X'
deny "an invented wrapper with an invented option" 'frobnicate --level 9 doppler secrets get X'

echo "== command strings =="
deny "bash -c" "bash -c 'doppler secrets get X'"
deny "bash -c --" "bash -c -- 'doppler secrets get X'"
deny "sh -ec" "sh -ec 'doppler secrets get X'"
deny "bash -o pipefail -c" "bash -o pipefail -c 'doppler secrets get X'"
deny "sudo -u root bash -c" "sudo -u root bash -c 'doppler secrets get X'"
deny "fish -c" "fish -c 'doppler secrets get X'"
deny "csh -c" "csh -c 'doppler secrets get X'"
deny "tcsh -c" "tcsh -c 'doppler secrets get X'"
deny "pwsh -Command" "pwsh -Command 'doppler secrets get X'"
deny "eval" 'eval "doppler secrets get X"'
deny "echo piped to bash" "echo 'doppler secrets get X' | bash"
deny "printf piped to sh" "printf '%s' 'doppler secrets get X' | sh"
deny "here-string to bash, spaced" "bash <<< 'doppler secrets get X'"
deny "here-string to bash, attached double-quoted" 'bash <<<"doppler secrets get X"'
deny "here-string to sh, attached single-quoted" "sh <<<'doppler secrets get X'"
deny "bash <(echo ...)" "bash <(echo 'doppler secrets get X')"
deny ". <(echo ...)" ". <(echo 'doppler secrets get X')"
deny "cat <(echo ...) | bash" 'cat <(echo "doppler secrets get X") | bash'
deny "source of a process substitution" 'source <(echo doppler secrets get X)'
deny "dot of a process substitution, bare words" '. <(echo doppler secrets get X)'
deny "nested under doppler run" 'doppler run -- doppler secrets get X'
deny "doppler run child shell" "doppler run -- bash -c 'doppler secrets get X'"
deny "doppler run --command string" "doppler run --command 'doppler secrets get X'"
deny "doppler run --command= string" "doppler run --command='doppler secrets get X'"
deny "doppler run child chained with a semicolon" 'doppler run -- ls; echo hi'
deny "doppler run child chained with &&" 'doppler run -- ls && echo hi'
deny "doppler run child piped" 'doppler run -- ls | cat'
deny "doppler run child with a redirect" 'doppler run -- ls > /tmp/f'
deny "doppler run child with a capture" 'doppler run -- echo $(id)'
deny "doppler run child with a backtick" 'doppler run -- echo `id`'
deny "doppler run child with a process substitution" 'doppler run -- cat <(id)'
deny "inside a dollar-paren" 'echo $(doppler secrets get X)'

echo "== interpreter strings =="
deny "python3 -c os.system" "python3 -c \"import os; os.system('doppler secrets get X')\""
deny "python3 -c subprocess" "python3 -c 'subprocess.run([\"doppler\",\"secrets\",\"get\",\"X\"])'"
deny "perl -e" "perl -e 'system(\"doppler secrets get X\")'"
deny "ruby -e" "ruby -e 'system(\"doppler secrets get X\")'"
deny "node -e" "node -e 'execSync(\"doppler secrets get X\")'"
deny "osascript -e" "osascript -e 'do shell script \"doppler secrets get X\"'"
deny "python string concatenation" "python3 -c 'import os; os.system(\"dopp\"+\"ler secrets get X\")'"
deny "a commit message that mentions the phrase" 'git commit -m "doppler secrets get is dangerous"'
deny "a PR body that mentions doppler" "gh pr create --body 'uses doppler for secrets'"
deny "grep for the words" 'grep -rn "doppler secrets" docs/'

echo "== command names the text does not spell literally =="
deny "upper case" 'DOPPLER secrets get X'
deny "capitalised" 'Doppler secrets get X'
deny "upper case absolute path" '/opt/homebrew/bin/DOPPLER secrets get X'
deny "ANSI-C quoted" "\$'doppler' secrets get X"
deny "locale quoted" '$"doppler" secrets get X'
deny "ANSI-C hex escape" "\$'\\x64oppler' secrets get X"
deny "ANSI-C octal escape" "\$'\\144oppler' secrets get X"
deny "brace expansion" '{doppler,} secrets get X'
deny "bracket glob" '/opt/homebrew/bin/doppl[e]r secrets get X'
deny "star glob" 'd*ppler secrets get X'
deny "question-mark glob" 'd?ppler secrets get X'
deny "split by quotes" "dopp''ler secrets get X"
deny "split by double quotes" 'd"o"ppler secrets get X'
deny "split by a backslash" 'dopp\ler secrets get X'
deny "command substitution naming it" '$(which doppler) secrets get X'
deny "backticks naming it" '`which doppler` secrets get X'
deny "variable holding a part of the name" '${X}pler secrets get Y'
deny "variable holding the subcommand" 'S=secrets; doppler $S get X'
deny "subcommand from a capture" 'doppler "$(echo secrets)" get X'
deny "subcommand from printf" 'doppler $(printf secrets) get X'
deny "subcommand fed by xargs" 'echo secrets get X | xargs doppler'
deny "subcommand fed by xargs and a here-string" 'xargs -I{} doppler {} get X <<< secrets'
deny "subcommand fed by parallel" 'parallel doppler {} get X ::: secrets'

echo "== flag values and unknown flags =="
deny "-p read as the subcommand" 'doppler -p run secrets get X'
deny "--dashboard-host read as the subcommand" 'doppler --dashboard-host run secrets get X'
deny "--dashboard-host value is a subcommand name" 'doppler secrets --dashboard-host set get X'
deny "--dns-resolver-address value is a flag" 'doppler secrets get X --dns-resolver-address -h'
deny "--dns-resolver-address swallows --only-names" 'doppler secrets get X --dns-resolver-address --only-names'
deny "--dashboard-host swallows --only-names" 'doppler secrets --dashboard-host --only-names'
deny "a value flag with no value" 'doppler secrets --only-names -p'
deny "an unknown flag next to an allowed form" 'doppler secrets --only-names --frobnicate'
deny "a value with a shell metacharacter" 'doppler secrets --only-names -p a$b'
deny "a flag value that is itself a flag" 'doppler secrets --only-names -p --json'
deny "a flag value that is a short flag" 'doppler secrets --only-names --dashboard-host -x'
deny "a value with a space-less semicolon" 'doppler secrets --only-names -p a;b'

echo "== non-printing look-alikes that print credentials =="
deny "configure get" 'doppler configure get token --plain'
deny "configure --all" 'doppler configure --all'
deny "configure" 'doppler configure'
deny "--print-config" 'doppler --print-config'
deny "configs tokens create" 'doppler configs tokens create foo --plain'
deny "configs tokens" 'doppler configs tokens'
deny "me --json" 'doppler me --json'
deny "configs get" 'doppler configs get'

echo "== redirects that are not a literal file =="
deny "/dev/fd/1" 'doppler secrets get X --plain > /dev/fd/1'
deny "/dev/fd/2 attached" 'doppler secrets get X --plain >/dev/fd/2'
deny "//dev/fd/1" 'doppler secrets get X --plain >//dev/fd/1'
deny "/dev/./fd/1" 'doppler secrets get X --plain >/dev/./fd/1'
deny "/dev/../dev/fd/1" 'doppler secrets get X --plain >/dev/../dev/fd/1'
deny "/tmp/../dev/fd/1" 'doppler secrets get X --plain >/tmp/../dev/fd/1'
deny "/dev//stdout" 'doppler secrets get X --plain >/dev//stdout'
deny "/dev/stdout" 'doppler secrets get X --plain > /dev/stdout'
deny "/dev/console" 'doppler secrets get X --plain >/dev/console'
deny "/dev/tty" 'doppler secrets get X --plain > /dev/tty'
deny "/dev/pts/0" 'doppler secrets get X --plain > /dev/pts/0'
deny "/dev/null" 'doppler secrets get X --plain > /dev/null'
deny "/proc/self/fd/1" 'doppler secrets get X --plain > /proc/self/fd/1'
deny "/tmp/../proc/self/fd/1" 'doppler secrets get X --plain > /tmp/../proc/self/fd/1'
deny "relative climb" 'doppler secrets get X --plain > ../../../../dev/fd/1'
deny "relative ../../dev/fd/1" 'doppler secrets get X --plain > ../../dev/fd/1'
deny "relative fd/1" 'doppler secrets get X --plain > fd/1'
deny "relative stdout" 'doppler secrets get X --plain > stdout'
deny "cd /dev first" 'cd /dev && doppler secrets get X --plain > stdout'
deny "unresolved variable target" 'doppler secrets get X --plain > $F'
deny "unresolved braced variable target" 'doppler secrets get X --plain > ${F}'
deny "quoted target" 'doppler secrets get X --plain > "/tmp/f"'
deny "process substitution target" 'doppler secrets get X --plain > >(cat)'
deny "file then dup to stderr" 'doppler secrets get X --plain > key.txt >&2'
deny "file then 1>&2" 'doppler secrets get X --plain > key.txt 1>&2'
deny "file then 1<&2" 'doppler secrets get X >/tmp/f 1<&2'
deny "file then 1<>/dev/fd/2" 'doppler secrets get X >/tmp/f 1<>/dev/fd/2'
deny "read-write redirect" 'doppler secrets get X --plain <>path'
deny "only stderr redirected" 'doppler secrets get X --plain 2> err.txt'
deny "stdout sent to stderr" 'doppler secrets get X --plain >&2'
deny "file then 2>&1" 'doppler secrets get X --plain > key.txt 2>&1'
deny "appended redirect" 'doppler secrets get X --plain >> key.txt'
deny "clobber redirect" 'doppler secrets get X --plain >| key.txt'
deny "redirect not last" 'doppler secrets get X --plain > /tmp/f --json'
deny "two redirects" 'doppler secrets get X --plain > /tmp/f > /tmp/g'
deny "target in a hidden dir under /dev" 'doppler secrets get X --plain > /dev/shm/x'
deny "target under /sys" 'doppler secrets get X --plain > /sys/x'
deny "home-relative with a tilde elsewhere" 'doppler secrets get X --plain > /tmp/~/x'
deny "target starting with a dash" 'doppler secrets get X --plain > -'
deny "download --no-file without a redirect" 'doppler secrets download --no-file --format env'
deny "download without --no-file or a path" 'doppler secrets download --format env'
deny "download to /dev/fd/1" 'doppler secrets download --format env /dev/fd/1'
deny "substitute with neither redirect nor --output" 'doppler secrets substitute tpl.yaml'
deny "substitute with both" 'doppler secrets substitute tpl.yaml --output out.yaml > out2.yaml'
deny "substitute to /dev/stdout" 'doppler secrets substitute tpl.yaml --output /dev/stdout'
deny "get with no names" 'doppler secrets get > /tmp/f'
deny "get with a name that is not a plain identifier" 'doppler secrets get X.Y > /tmp/f'

echo "== allowed =="
allow "--only-names" 'doppler secrets --only-names'
allow "--only-names with -p and -c" 'doppler secrets -p app -c prd --only-names'
allow "--only-names with --project and --config=" 'doppler secrets --project app --config=prd --only-names'
allow "--only-names with a global flag first" 'doppler --json secrets --only-names'
deny "--only-names with --api-host sends the token to any host" 'doppler --api-host https://api.doppler.com secrets --only-names'
allow "--only-names | wc -l" 'doppler secrets --only-names | wc -l'
allow "--only-names | head -n 5" 'doppler secrets --only-names | head -n 5'
allow "--only-names | grep -x NAME" 'doppler secrets --only-names | grep -x DATABASE_URL'
allow "--only-names | grep -c NAME" 'doppler secrets --only-names | grep -c DATABASE'
allow "doppler run" 'doppler run -- ./deploy.sh'
allow "doppler run with flags" 'doppler run -p app -c prd -- npm test'
allow "doppler run with a global flag first" 'doppler --silent run -p app -- npm test'
allow "doppler run, child shell reading \$SECRET" "doppler run -- bash -c 'echo \$SECRET | wc -c'"
allow "doppler run, child psql" "doppler run -- bash -c 'psql \"\$DATABASE_URL\" -c select1'"
allow "doppler run, unquoted child variable" 'doppler run -- echo $HOME'
allow "doppler run --command" "doppler run --command 'echo hi && ls'"
allow "doppler run --command with flags" "doppler run -p app -c prd --command 'npm test'"
allow "get redirected to a file" 'doppler secrets get X --plain > /tmp/f'
allow "get, several names, flags" 'doppler secrets get X Y -p app -c prd --json > out.json'
allow "get redirected to a relative file" 'doppler secrets get X > .env'
allow "get redirected under home" 'doppler secrets get X --plain > ~/.keys/x'
allow "download --no-file redirected" 'doppler secrets download --no-file --format env > .env'
allow "download to a path" 'doppler secrets download --format env /tmp/secrets.env'
allow "download --format=env to a path" 'doppler secrets download --format=env -p app -c prd secrets.env'
allow "substitute redirected" 'doppler secrets substitute tpl.yaml > out.yaml'
allow "substitute --output" 'doppler secrets substitute tpl.yaml --output out.yaml'
allow "doppler setup" 'doppler setup --no-interactive -p app -c prd'
allow "doppler configs" 'doppler configs'
allow "doppler configs with flags" 'doppler configs -p app -n 10'
allow "doppler projects" 'doppler projects'
allow "doppler environments" 'doppler environments -p app'
allow "doppler login" 'doppler login'
allow "doppler logout" 'doppler logout'
allow "doppler me" 'doppler me'
allow "doppler update" 'doppler update'
allow "doppler --version" 'doppler --version'
allow "doppler --help" 'doppler --help'
allow "doppler help secrets" 'doppler help secrets'
allow "doppler run --help" 'doppler run --help'
allow "ordinary command" 'ls -la'
allow "a pipeline that never mentions doppler" 'ps aux | grep sshd | wc -l'
allow "empty command" ''
allow "words that only look like it" 'echo dopple secrets get'
allow "secrets and get without any doppler or expansion" 'git log --grep=secrets --oneline'
allow "shell expansion with secrets but no get" 'ls $HOME/secrets'
allow "gh api on the secrets endpoint" 'gh api repos/$R/actions/secrets'

echo "== literal credentialed URL rule =="
deny "postgres" 'psql postgres://app:hunter2@db.example.com:5432/app'
deny "postgresql" 'psql postgresql://app:hunter2@db.example.com/app'
deny "postgresql+asyncpg" 'python -c x postgresql+asyncpg://app:hunter2@db/app'
deny "mysql" 'mysql mysql://root:pw@127.0.0.1/db'
deny "mongodb" 'mongosh mongodb://u:p@host/db'
deny "mongodb+srv" 'mongosh "mongodb+srv://u:p@cluster.example.net/db"'
deny "redis" 'redis-cli -u redis://default:pw@cache.example.com:6379'
deny "redis, empty user" 'redis-cli -u redis://:pw@cache.example.com:6379'
deny "rediss" 'redis-cli -u rediss://default:pw@cache.example.com:6379'
deny "amqp" 'curl amqp://guest:guest@broker/vhost'
deny "amqps" 'curl amqps://guest:guest@broker/vhost'
deny "upper case scheme" 'psql POSTGRES://app:hunter2@db/app'
deny "inside a quoted string" "echo 'postgres://app:hunter2@db/app'"
deny "inside a bash -c string" "bash -c 'psql postgres://app:hunter2@db/app'"
deny "inside a command substitution" 'echo $(psql postgres://app:hunter2@db/app)'
deny "in a heredoc body" $'cat <<EOF\npostgres://app:hunter2@db/app\nEOF'
deny "in a comment" 'ls # postgres://app:hunter2@db/app'
deny "single-quoted literal dollar password" "psql 'postgres://u:\$ecret@h/db'"
deny "backslash-escaped dollar password" 'psql postgres://u:\$ecret@h/db'
deny "password starting with a dollar and a digit" 'psql postgres://u:$1pass@h/db'
deny "password that merely contains a dollar later" 'psql postgres://u:pa$$word@h/db'
allow "no password" 'psql postgres://app@db.example.com/app'
allow "host and port, no userinfo" 'psql postgres://db.example.com:5432/app'
allow "https URL with userinfo" 'curl https://user:pw@example.com/x'
allow "env var instead of a URL" 'doppler run -- psql "$DATABASE_URL"'
allow "password is an env var reference" 'psql "postgres://u:$PW@h/db"'
allow "password is a braced env var reference" 'psql "postgres://u:${PW}@h/db"'
allow "password is a command substitution" 'psql "postgres://u:$(cat /run/pw)@h/db"'

echo "== per-command bypass: a leading unquoted assignment on a single simple command =="
allow "doppler bypass written in the command" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
allow "doppler bypass, text mentioning the phrase" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 git commit -m "doppler secrets get is dangerous"'
allow "URL bypass written in the command" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql postgres://a:b@h/d'
allow "bypass covers the strings its command runs" "SASSYDOG_ALLOW_DOPPLER_PRINT=1 bash -c 'doppler secrets get X'"
allow "both bypasses together" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 SASSYDOG_ALLOW_CREDENTIAL_URL=1 echo doppler postgres://a:b@h/d'
allow "URL bypass with a comment URL" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 ls # postgres://app:hunter2@db/app'
deny "the doppler bypass does not unlock the URL rule" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 psql postgres://a:b@h/d'
deny "the URL bypass does not unlock the doppler rule" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 doppler secrets get X'
deny "bypass set to a different value" 'SASSYDOG_ALLOW_DOPPLER_PRINT=0 doppler secrets get X'
deny "bypass quoted is a command name, not an assignment" '"SASSYDOG_ALLOW_DOPPLER_PRINT=1" doppler secrets get X'
deny "bypass as an argument, not leading" 'echo SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
deny "bypass after the command word" 'doppler secrets get X SASSYDOG_ALLOW_DOPPLER_PRINT=1'
deny "bypass behind another assignment" 'A=1 SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
deny "bypass on a first command, doppler on a second" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 echo hi; doppler secrets get X'
deny "bypass with a pipe" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X | cat'
deny "bypass with a capture" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 echo $(doppler secrets get X)'
deny "bypass with a backtick" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 echo `doppler secrets get X`'
deny "bypass with a newline" $'SASSYDOG_ALLOW_DOPPLER_PRINT=1 echo hi\ndoppler secrets get X'
deny "bypass as a substring of a longer name" 'XSASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
deny "bypass inside a comment" 'doppler secrets get X # SASSYDOG_ALLOW_DOPPLER_PRINT=1'
deny "URL bypass as an argument" 'echo SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql postgres://a:b@h/d'
deny "URL bypass on another command" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 echo hi; psql postgres://a:b@h/d'
deny "URL bypass with a pipe" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql postgres://a:b@h/d | cat'
err="$(printf '%s' "$(event 'doppler secrets get X')" | SASSYDOG_ALLOW_DOPPLER_PRINT=1 SASSYDOG_ALLOW_CREDENTIAL_URL=1 bash "$HOOK" 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -eq 2 ]; then ok "the hook's own environment is not a bypass"; else bad "the hook's own environment is not a bypass (rc=$rc)"; fi

echo "== unclassifiable input fails open, loudly =="
failopen "empty stdin" ''
failopen "whitespace only" '   '
failopen "malformed JSON" '{"tool_name": "Bash", '
failopen "a JSON array" '[1,2]'
failopen "a JSON string" '"doppler secrets get X"'
failopen "Bash event without tool_input" '{"tool_name":"Bash"}'
failopen "Bash event without a command" '{"tool_name":"Bash","tool_input":{}}'
failopen "Bash event with a non-string command" '{"tool_name":"Bash","tool_input":{"command":["doppler","secrets","get","X"]}}'
run_event '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
if [ "$rc" -eq 0 ]; then ok "a non-Bash tool is allowed without comment"; else bad "a non-Bash tool is allowed without comment (rc=$rc)"; fi

mkdir -p "$WORK/nopython"
ln -s "$(command -v dirname)" "$WORK/nopython/dirname"
err="$(printf '%s' "$(event 'doppler secrets get X')" | PATH="$WORK/nopython" "$(command -v bash)" "$HOOK" 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'python3 not found.*fail open' <<<"$err"; then
    ok "python3 missing from PATH fails open and names python3"
else
    bad "python3 missing from PATH fails open and names python3 (rc=$rc err=${err:-<none>})"
fi

err="$(printf '%s' "$(event 'ls')" | python3 -I -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def boom(*a, **k):
    raise RuntimeError("injected")
m.analyze = boom
sys.exit(m.main())
' "$PY" 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'internal error.*fail open' <<<"$err"; then
    ok "an internal classifier fault fails open and says so"
else
    bad "an internal classifier fault fails open and says so (rc=$rc err=${err:-<none>})"
fi

echo "== review 4: line continuations, wide escapes, globs in the command name, folded paths =="
deny "backslash-newline inside the command name" $'dop\\\npler secrets get X'
deny "backslash-newline, secrets" $'dop\\\npler secrets'
deny "backslash-CRLF inside the command name" $'dop\\\r\npler secrets'
deny "backslash-newline inside a subcommand's host word" $'doppler secrets get \\\nX'
deny "\\u with one hex digit pair" "\$'\\u64'oppler secrets"
deny "\\u with four hex digits" "\$'\\u0064'oppler secrets"
deny "\\U with eight hex digits" "\$'\\U00000064'oppler secrets"
deny "\\U with two hex digits" "\$'\\U64'oppler secrets"
deny "\\u escape on a non-keyword subcommand (only the decoder can see it)" "\$'\\u64'oppler projects"
deny "\\u with four digits, non-keyword subcommand" "\$'\\u0064'oppler projects"
deny "\\U with eight digits, non-keyword subcommand" "\$'\\U00000064'oppler projects"
deny "\\U with two digits, non-keyword subcommand" "\$'\\U64'oppler login"
deny "\\x with an upper-case hex digit, non-keyword subcommand" "d\$'\\x6F'ppler projects"
deny "\\e in a doppler word" "doppl\\er secrets"
deny "\\c escape beside a doppler word" "\$'\\cA'doppler secrets"
deny "glob in the command name: dop*ler" '/opt/homebrew/bin/dop*ler secrets'
deny "glob in the command name: dopp?er" 'dopp?er secrets'
deny "glob in the command name: doppl?r" 'doppl?r secrets'
deny "glob in the command name: bracket class" 'dopp[l]er secrets'
deny "expansion prefix: \${X}pler secrets" '${X}pler secrets'
deny "expansion infix: d\${X}oppler secrets" 'd${X}oppler secrets'
deny "quoted expansion as the command name" '"$D" secrets'
deny "unquoted expansion as the command name" '$D secrets'
deny "expansion command name, configure" '"$D" configure'
deny "expansion command name, run" '"$D" run -- env'
deny "glob command name, me" 'dop*ler me'
deny "expansion command name with a global flag first" '"$D" --json secrets'
deny "expansion command name behind an env assignment" 'A=1 "$D" secrets'
allow "an expansion after the word is a path, not a doppler command" 'ls $HOME/secrets'
allow "gh run with an expansion argument" 'gh run view $RUN_ID'
allow "gh run list" 'gh run list --limit 5'
allow "a separate command carries the expansion" 'echo "$HOME" && gh run list'
deny "a different case, the path is folded: /DEV/stdout" 'doppler secrets get X --plain > /DEV/stdout'
deny "a different case: /Dev/fd/1" 'doppler secrets get X --plain > /Dev/fd/1'
deny "a different case: /PROC/self/fd/1" 'doppler secrets get X --plain > /PROC/self/fd/1'
deny "a different case: /Sys/x" 'doppler secrets get X --plain > /Sys/x'
deny "a different case, relative: DEV/stdout" 'doppler secrets get X --plain > DEV/stdout'
deny "a different case, relative: Fd/1" 'doppler secrets get X --plain > Fd/1'
deny "a different case: download to /DEV/stderr" 'doppler secrets download --no-file > /DEV/stderr'
deny "a different case: substitute --output" 'doppler secrets substitute t.yaml --output /DEV/stdout'

echo "== review 6: a redirect ampersand does not split the command, and a command word that expands triggers =="
deny "2>&1 before the subcommand, globbed name" '/opt/homebrew/bin/dop?ler 2>&1 secrets'
deny "\"\$D\" >&2 secrets" '"$D" >&2 secrets'
deny "\$D 2>&1 configure" '$D 2>&1 configure'
deny "\${D} 1>&2 secrets" '${D} 1>&2 secrets'
deny ">&2 run --command set" '/opt/homebrew/bin/dop?ler >&2 run --command set'
deny "&> before the subcommand" '$D &> /dev/null secrets'
deny "<&0 before the subcommand" '$D <&0 secrets'
deny "glob in the subcommand word too" '/opt/homebrew/bin/dop?ler s?crets'
deny "glob in the subcommand word, expanded name" '$D s*ets get X'
deny "command word expands, subcommand not a keyword" '/opt/homebrew/bin/dop?ler projects'
deny "command word expands behind an assignment" 'A=1 $D projects'
deny "expanded command word after a separator" 'echo hi && $D projects'
deny "redirect-ampersand alone must not split: > out, then an expansion name, 2>&1, subcommand" '> out $D 2>&1 secrets'
deny "redirect-ampersand alone must not split: &> before the subcommand" '> out $D &> x secrets'
deny "an attached leading redirect does not hide the command word" '>out $D projects'
deny "a leading fd redirect does not hide the command word" '2>/dev/null "$D" projects'
allow "2>&1 on an ordinary command" 'ls /nonexistent 2>&1'
allow "2>&1 then a path argument named secrets" 'ls 2>&1 secrets'
allow ">&2 on an ordinary command with a variable path" 'echo hi >&2 && ls $HOME/secrets'
allow "gh run view with 2>&1" 'gh run view $ID 2>&1'
allow "gh api actions/secrets" 'gh api repos/a/b/actions/secrets'
allow "gh api actions/secrets with 2>&1" 'gh api repos/$R/actions/secrets 2>&1'
allow "a test bracket is syntax, not a command word" '[ -n "$HOME" ] && echo ok'
allow "a double bracket is syntax" '[[ -n "$HOME" ]] && echo ok'
allow "an assignment prefix on an ordinary command" 'FOO=$HOME ls'

echo "== review 4: the forms this plugin's own skills emit =="
allow "secret_bootstrap, as written in config-contract.md" 'eval "$(doppler secrets download --no-file --format env 2>/dev/null)"'
allow "secret_bootstrap without the stderr redirect" 'eval "$(doppler secrets download --no-file --format env)"'
allow "secret_bootstrap with project and config" 'eval "$(doppler secrets download --no-file --format env -p app -c dev)"'
deny "secret_bootstrap, then one later command (the tail is gone: use doppler run)" 'eval "$(doppler secrets download --no-file --format env 2>/dev/null)" && gh api user'
deny "bootstrap without --no-file writes a file the eval then reads as text" 'eval "$(doppler secrets download --format env)"'
deny "bootstrap that eval-s a printing get" 'eval "$(doppler secrets get X --plain)"'
deny "bootstrap that eval-s bare secrets" 'eval "$(doppler secrets)"'
deny "bootstrap with stderr merged into the eval" 'eval "$(doppler secrets download --no-file --format env 2>&1)"'
deny "bootstrap with a second command inside the substitution" 'eval "$(doppler secrets download --no-file --format env; echo hi)"'
deny "bootstrap, then a second doppler command" 'eval "$(doppler secrets download --no-file --format env)" && doppler secrets get X'
deny "bootstrap, then a chain" 'eval "$(doppler secrets download --no-file --format env)" && echo hi; cat x'
deny "bootstrap, then a capture" 'eval "$(doppler secrets download --no-file --format env)" && echo $(id)'
deny "bootstrap, then a pipe" 'eval "$(doppler secrets download --no-file --format env)" && env | cat'
deny "bootstrap with a token flag" 'eval "$(doppler secrets download --no-file --format env --token dp.st.x)"'
deny "bootstrap, then text after the closing quote" 'eval "$(doppler secrets download --no-file --format env)" x'
deny "bootstrap with a trailing redirect" 'eval "$(doppler secrets download --no-file --format env)" > /tmp/o'
deny "eval of an unquoted substitution" 'eval $(doppler secrets download --no-file --format env)'
allow "get --plain piped into gh secret set" 'doppler secrets get SECRET_NAME --plain | gh secret set SECRET_NAME'
allow "get --plain piped into gh secret set, repo and project flags" 'doppler secrets get X --plain -p app -c prd | gh secret set X --repo Sassy-Dog/skills'
allow "get --plain piped into gh secret set, environment secret" 'doppler secrets get X --plain | gh secret set X --env prd --app actions'
deny "gh secret set with --body" 'doppler secrets get X --plain | gh secret set X --body y'
deny "gh secret set with -b" 'doppler secrets get X --plain | gh secret set X -b y'
deny "get without --plain piped into gh" 'doppler secrets get X | gh secret set X'
deny "get piped into gh secret list" 'doppler secrets get X --plain | gh secret list'
deny "get piped into gh, then another stage" 'doppler secrets get X --plain | gh secret set X | cat'
deny "gh secret set name is a flag" 'doppler secrets get X --plain | gh secret set --body y'
deny "two names into one gh secret set" 'doppler secrets get X Y --plain | gh secret set X'
deny "gh secret set followed by a redirect" 'doppler secrets get X --plain | gh secret set X > /dev/stdout'
deny "download piped into gh" 'doppler secrets download --no-file --format env | gh secret set X'
deny "gh secret set with an unknown flag" 'doppler secrets get X --plain | gh secret set X --env-file /dev/stdin'
allow "download to a literal file, then gh reads it (the github-secrets bulk sync)" 'doppler secrets download --no-file --format env > /tmp/doppler-sync.env'

echo "== review 6: nothing may follow the bootstrap (the compound form is cut) =="
BOOT='eval "$(doppler secrets download --no-file --format env)"'
for tail in '&& gh auth status' '&& gh secret set NAME --repo a/b' '&& env' '&& echo $API_KEY' '; env' '; gh auth status' \
    '| cat' '|| true' '& env' $'\nenv' $'\ngh auth status' '&& printenv' "&& bash -c 'printenv'" '&& python3 -c "import os"' '2>&1' '> /tmp/o'; do
    deny "bootstrap, then: $tail" "$BOOT $tail"
done
allow "the bare bootstrap, alone" "$BOOT"
allow "the bare bootstrap with -p/-c and the stderr redirect" 'eval "$(doppler secrets download --no-file --format env -p app -c dev 2>/dev/null)"'
allow "doppler run carries the follow-up instead: gh auth status" 'doppler run -p app -c dev -- gh auth status'
allow "doppler run carries the follow-up instead: a TestFlight pull" 'doppler run -- bash /Users/me/.claude/plugins/sassy-dog/skills/testflight/scripts/appstore-connect.sh com.example.app feedback'

echo "== review 5: the bootstrap shape is exactly --no-file --format env =="
for v in 'secrets download --no-file' \
    'secrets download --no-file --format json' 'secrets download --no-file --format dotnet-json' \
    'secrets download --no-file --format env-no-quotes' 'secrets download --no-file --format docker' \
    'secrets download --no-file --format env --name-transformer lower-kebab' \
    'secrets download --no-file --format env --name-transformer=lower-kebab' \
    'secrets download --no-file --name-transformer lower-kebab' \
    '--json secrets download --no-file --format env' '--debug secrets download --no-file --format env' \
    '--api-host https://x secrets download --no-file --format env' '--api-host=https://x secrets download --no-file --format env' \
    'secrets download --no-file --format env --format json' 'secrets download --no-file --format env --no-cache'; do
    deny "bootstrap variant: doppler $v" "eval \"\$(doppler $v)\""
done
allow "bootstrap with --format=env and project flags" 'eval "$(doppler secrets download --no-file --format=env --project app --config dev)"'
deny "--debug on an allowed names-only form (it logs requests)" 'doppler --debug secrets --only-names'

echo "== review 5: the subcommand word is found on text with quotes and backslashes removed =="
deny "glob name, quote-split secrets, get --plain" "/opt/homebrew/bin/dop*ler sec''rets get API_KEY --plain"
deny "glob name, backslash inside secrets" 'dop*ler s\ecrets get X'
deny "glob name, quoted letter inside secrets" 'dop*ler s"e"crets'
deny "glob name, quoted whole subcommand" 'dop*ler "secrets" get X'
deny "expansion name, quote-split secrets" "\"\$D\" sec''rets get API_KEY --plain"
deny "expansion name, quoted letter, download" '"$D" s"ecrets" download --no-file'
deny "expansion name, backslash configure" '$D \configure'
deny "expansion name, quote-split configure" "\$D con''figure"
deny "expansion name, quote-split run" "\$D r''un -- printenv"
deny "expansion name, backslash me" '$D \me'
deny "expansion name, backslash secrets" '$D \secrets'
deny "expansion in one segment, quote-split keyword phrase in another" "\${X}pler \"\$A\"; sec''rets get Y"
deny "unsplit control: expansion name, plain secrets" '"$D" secrets'
deny "unsplit control: glob name, plain secrets" 'dop*ler secrets'
echo "== review 5: a quoted separator does not split the command =="
deny "quoted ; between the expansion name and the subcommand" "\"\$D\" --scope=';' secrets"
deny "quoted ; after a glob name" "/opt/homebrew/bin/dop*ler --scope=';' secrets"
deny "quoted & after an expansion name" "\$D --scope='&' secrets"
deny "double-quoted | after an expansion name" "\$D --scope=\"|\" configure"
deny "ANSI-C quoted ; with an escaped quote" "\$D --scope=\$'\\';' secrets"
deny "unsplit control: the same without the quoted separator" '"$D" --scope=x secrets'
allow "ls with an expansion and a path piece" 'ls $HOME/secrets'
allow "gh run with an expansion" 'gh run view $ID'
allow "gh api on the secrets endpoint" 'gh api repos/$R/actions/secrets'
allow "an unquoted ; really does separate the commands" 'echo --scope=$X; secrets'

echo "== review 5: decoder and fold cases that only the decoder can catch =="
deny "octal escape, non-keyword subcommand" "\$'\\144oppler' get FOO"
deny "octal escape, three digits, projects" "\$'\\144\\157ppler' projects"
deny "\\e between letters (the ESC is stripped, joining the word)" 'dopp\eler projects'
deny "\\E between letters" 'dopp\Eler projects'
deny "\\c between letters (the control character is stripped)" 'dopp\cAler projects'
deny "NFKC on plain text: a full-width d" 'ｄoppler projects'
deny "NFKC on plain text: a full-width word" 'ｄｏｐｐｌｅｒ projects'
deny "NFKC before the escape decoder: a full-width backslash" "\$'＼x64oppler' projects"

echo "== review 5: a relative redirect is resolved against the event's cwd =="
cwd_deny() { # <label> <cwd> <command>
    run_event "$(event_cwd "$2" "$3")"
    if [ "$rc" -eq 2 ] && grep -qF 'allowed Doppler forms' <<<"$err"; then ok "denied: $1"; else bad "denied: $1 (rc=$rc err=${err:-<none>})"; fi
}
cwd_allow() {
    run_event "$(event_cwd "$2" "$3")"
    if [ "$rc" -eq 0 ]; then ok "allowed: $1"; else bad "allowed: $1 (rc=$rc err=${err:-<none>})"; fi
}
mkdir -p "$WORK/plain"
ln -s /dev "$WORK/devlink"
cwd_deny "cwd /dev, target 1" /dev 'doppler secrets get X --plain > 1'
cwd_deny "cwd /dev, target out.txt (a name no heuristic knows)" /dev 'doppler secrets get X --plain > out.txt'
cwd_deny "cwd /dev/fd, target 1" /dev/fd 'doppler secrets get X --plain > 1'
cwd_deny "cwd /proc/self, target environ" /proc/self 'doppler secrets get X --plain > environ'
cwd_deny "cwd /DEV (case folded)" /DEV 'doppler secrets get X --plain > 1'
cwd_deny "cwd is a symlink to /dev" "$WORK/devlink" 'doppler secrets get X --plain > 1'
cwd_deny "cwd /dev, download to a relative path" /dev 'doppler secrets download --format env 1'
cwd_deny "cwd /dev, substitute --output" /dev 'doppler secrets substitute t.yaml --output 1'
cwd_allow "cwd /tmp, relative target" /tmp 'doppler secrets get X --plain > out.txt'
cwd_allow "an ordinary scratch cwd" "$WORK/plain" 'doppler secrets get X --plain > .env'
cwd_allow "cwd /dev does not matter to a home-relative target" /dev 'doppler secrets get X --plain > ~/.keys/x'
cwd_allow "a cwd that is not absolute is ignored" relative/dir 'doppler secrets get X --plain > out.txt'
cwd_allow "no doppler, cwd /dev" /dev 'ls'

echo "== review 5: a pathologically nested event fails open, loudly =="
failopen "100000 nested arrays, balanced (json.loads raises RecursionError)" "$(python3 -I -B -c 'print("[" * 100000 + "]" * 100000)')"
# Newer Pythons parse any depth, so the nested document above cannot reach the RecursionError
# branch there: inject the error instead (the same shape as the internal-fault case above).
err="$(printf '%s' "$(event 'ls')" | python3 -I -B -c '
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def deep(*a, **k):
    raise RecursionError("injected")
json.loads = deep
sys.exit(m.main())
' "$PY" 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'not valid JSON.*fail open' <<<"$err"; then
    ok "a RecursionError from json.loads fails open and says so"
else
    bad "a RecursionError from json.loads fails open and says so (rc=$rc err=${err:-<none>})"
fi

echo "== review 4: every doppler command under skills/ and agents/ passes the guard =="
# A tracked skill or reference doc that tells an agent to run a Doppler command the guard denies
# makes the guard fight the plugin it ships in (review 4). Extracted from fenced code blocks
# (one command per line, a `secret_bootstrap:` key stripped) and inline code spans in every
# tracked file whose text mentions `doppler` followed by a lower-case subcommand word.
extract_out="$WORK/skill-doppler-commands.tsv"
cat >"$WORK/extract.py" <<'PYEOF'
import re, subprocess, sys
# usage: extract.py --tree <root> | extract.py --file <path>
mode, arg = sys.argv[1], sys.argv[2]
if mode == "--tree":
    files = [(f, f"{arg}/{f}") for f in subprocess.run(["git", "-C", arg, "ls-files", "skills", "agents"], capture_output=True, text=True, check=True).stdout.split("\n")]
else:
    files = [(arg, arg)]
CMD = re.compile(r"\bdoppler[ \t]+[a-z-]")
MENTION = re.compile(r"doppler", re.I)
for f, path in files:
    if not f or f.endswith(".json") or "/fixtures/" in f:
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    fenced = False
    for n, line in enumerate(text.split("\n"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        found = []
        if fenced:
            # Every command line of a fenced block that mentions doppler AT ALL (a path such as
            # /tmp/doppler-sync.env included), not only `doppler <subcommand>` lines: the guard
            # denies any command that mentions the word, and a full-line comment is not a command.
            l = re.sub(r"^\s*(?:secret_bootstrap:\s*)?", "", line)
            if l and not l.startswith("#") and MENTION.search(l):
                found.append(re.sub(r"\s+#\s.*$", "", l))
        else:
            for span in re.findall(r"`([^`]+)`", line):
                if CMD.search(span):
                    found.append(span)
        for c in found:
            print(f"{f}:{n}\t{c}")
PYEOF
python3 -I -B "$WORK/extract.py" --tree "$REPO_ROOT" >"$extract_out"
if [ -s "$extract_out" ]; then ok "the extractor found doppler commands in skills/ ($(wc -l <"$extract_out" | tr -d ' '))"; else bad "the extractor found doppler commands in skills/ (none: the extraction is vacuous)"; fi
while IFS=$'\t' read -r site cmd; do
    [ -n "$site" ] || continue
    run_cmd "$cmd"
    if [ "$rc" -eq 0 ]; then
        ok "plugin text allowed by the guard: $site"
    else
        run_cmd "SASSYDOG_ALLOW_DOPPLER_PRINT=1 $cmd"
        if [ "$rc" -eq 0 ] && grep -qF 'SASSYDOG_ALLOW_DOPPLER_PRINT=1' <<<"$cmd"; then
            ok "plugin text carries the bypass: $site"
        else
            bad "plugin text is denied by the guard and carries no bypass: $site: $cmd"
        fi
    fi
done <"$extract_out"
# The widened extractor must catch review 5's finding 4: the old bulk-sync example, whose follow-up
# lines (`gh secret set -f /tmp/doppler-sync.env`, `rm ...`) the guard denies because the PATH
# mentions doppler, and which the old `doppler <subcommand>` extractor never looked at.
mkdir -p "$WORK/oldtext"
cat >"$WORK/oldtext/scope-hierarchy.md" <<'MDEOF'
```bash
umask 077
doppler secrets download --no-file --format env > /tmp/doppler-sync.env
gh secret set -f /tmp/doppler-sync.env
rm /tmp/doppler-sync.env
```
MDEOF
python3 -I -B "$WORK/extract.py" --file "$WORK/oldtext/scope-hierarchy.md" >"$WORK/oldtext.tsv"
old_denied=0
while IFS=$'\t' read -r site cmd; do
    [ -n "$site" ] || continue
    run_cmd "$cmd"
    [ "$rc" -eq 2 ] && old_denied=$((old_denied + 1))
done <"$WORK/oldtext.tsv"
if [ "$old_denied" -eq 2 ]; then ok "the widened sweep flags the old bulk-sync text (its gh and rm lines are denied)"; else bad "the widened sweep flags the old bulk-sync text (denied lines: $old_denied, wanted 2)"; fi
for known in 'scope-hierarchy.md' 'config-contract.md' 'interview.md' 'detection.md'; do
    if grep -q "^skills/[^	]*$known:" "$extract_out"; then ok "the extractor reaches a known site: $known"; else bad "the extractor reaches a known site: $known"; fi
done

echo "== review 4: a very large command stays fast (a hook timeout fails open without a word) =="
big_time() { # <label> <expected rc> <python expression producing the command>
    # The event is built and piped inside one python process: a megabyte command does not fit argv.
    local out
    out="$(python3 -I -B - "$HOOK" "$2" "$3" <<'PYEOF'
import json, subprocess, sys, time
hook, want, expr = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cmd = eval(expr)
event = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
t0 = time.time()
p = subprocess.run(["bash", hook], input=event, capture_output=True, text=True)
dt = time.time() - t0
print(f"{p.returncode} {dt:.1f} {len(cmd)}")
sys.exit(0 if p.returncode == want and dt < 5 else 1)
PYEOF
)"
    if [ $? -eq 0 ]; then ok "stays fast and classifies (rc $2): $1 [$out]"; else bad "stays fast and classifies (rc $2): $1 [$out]"; fi
}
big_time "many literal credential URLs with an env password" 0 '"psql postgres://u:$p@h " * 30000'
big_time "a quote at the front and many URLs" 0 '"echo " + "\x27" * 100000 + "postgres://u:$p@h " * 20000'
big_time "many literal-password URLs" 2 '"psql postgres://u:pw@h " * 30000'
big_time "an expansion and many words, then secrets" 2 '"x $HOME " * 100000 + "secrets"'
big_time "a very long plain command" 0 '"echo a " * 300000'

echo "== hooks.json wiring, run as the harness runs it =="
python3 -I -B - "$HOOKS_JSON" <<'EOF' && ok "hooks.json declares exactly one PreToolUse Bash command hook" || bad "hooks.json declares exactly one PreToolUse Bash command hook"
import json, sys
d = json.load(open(sys.argv[1]))
pre = d["hooks"]["PreToolUse"]
assert len(pre) == 1 and pre[0]["matcher"] == "Bash", pre
hs = pre[0]["hooks"]
assert len(hs) == 1 and hs[0]["type"] == "command" and "${CLAUDE_PLUGIN_ROOT}/hooks/bash-secret-guard.sh" in hs[0]["command"], hs
assert set(d["hooks"]) == {"PreToolUse"}, list(d["hooks"])
EOF
declared="$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$HOOKS_JSON")"
harness_cmd="${declared//\$\{CLAUDE_PLUGIN_ROOT\}/$REPO_ROOT}"
err="$(printf '%s' "$(event 'doppler secrets get DATABASE_URL')" | bash -c "$harness_cmd" 2>&1 >/dev/null)"
rc=$?
if [ "$rc" -eq 2 ] && grep -q 'BLOCKED' <<<"$err"; then ok "declared command denies a real printing command"; else bad "declared command denies a real printing command (rc=$rc)"; fi
printf '%s' "$(event 'doppler secrets --only-names')" | bash -c "$harness_cmd" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "declared command allows a real safe command"; else bad "declared command allows a real safe command (rc=$rc)"; fi

echo
echo "bash-secret-guard: $pass_n passed, $fail_n failed"
[ "$fail_n" -eq 0 ]
