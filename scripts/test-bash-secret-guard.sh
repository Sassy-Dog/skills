#!/usr/bin/env bash
# test-bash-secret-guard.sh — pins hooks/bash-secret-guard.{sh,py}, the PreToolUse(Bash)
# hook the plugin ships through hooks/hooks.json (#641).
#
# Why this exists: the failure it guards is silent. `doppler secrets get NAME` prints the
# live value into the transcript, the command text contains no credential, and a hook cannot
# see output, so the only defence is a rule about WHICH invocations may print. A classifier
# that quietly allows a printing form, or denies the forms people legitimately use until the
# hook is switched off, gives no signal in either direction. Every case below is one of the
# two.
#
# History that shaped the design: the first version classified piped, captured and wrapped
# forms as safe (a consumer table, a $(...) trust rule, a per-wrapper option table). Review
# kept finding a new spelling that slipped through (reserved words, sudo -u root, env -iS,
# >//dev/fd/1, sed p, grep -e -c ...), so that logic was removed. The rule is now: EVERY word
# whose basename is `doppler`, wherever it sits, is classified; a value-printing subcommand is
# allowed only by (a) `doppler run`, (b) --only-names, (c) stdout to a real file, (d) a
# non-printing subcommand. --plain, --silent, pipes into wc/sed/grep/head/hashers and $(...)
# captures buy nothing.
#
# Asserted, by piping the harness's event JSON into the hook exactly as Claude Code does.
# Every deny case asserts a fragment of the expected message (the Doppler text, or the
# literal-password text), so a denial for the wrong reason is red:
#   - the plain printing forms (get, download, substitute, bare, --raw, --json, --plain),
#     --silent and a false-valued --only-names (=0 =false =f) as not safe
#   - every spelling the review listed: reserved words (for/while/until/if/else/!), wrappers
#     and their option values (sudo -u, env -u/-iS/-S, nice, timeout, stdbuf, xargs, doas,
#     setsid, watch, flock, ionice, taskset, strace, ssh, find -exec, docker exec), shell
#     strings (bash -c, bash -c --, sh -ec, bash -o pipefail -c, fish/pwsh/csh -c, eval,
#     `echo ... | bash`, here-string, source <(...)), nested `doppler run -- doppler ...`,
#     `doppler run --command`
#   - every consumer and capture the first design trusted: | wc, | sha256sum, | sed d / p /
#     -n p / a multi-command script, | grep -ec / -e -c, | head -c0 -n5, wc --files0-from=-,
#     | xargs wc, X=$(...), export/declare/env/sha256sum with $(...), [ "$(...)" -eq 1 ], echo,
#     printf, curl -H, bash -c "echo $(...)", ${x:-$(...)}, backticks, set -x; X=$(...)
#   - redirects that are not a real file: >&2 | wc, 1>&2 | sha256sum, a later >&2, >//dev/fd/1,
#     >/dev/./fd/1, >/dev/../dev/fd/1, >/tmp/../dev/fd/1, >/dev//stdout, >/dev/console,
#     /proc/self/fd/1, /dev/pts/0, /dev/tty, `> >(cat)`, an unresolved $VAR target, ../ climbs
#   - the allowed forms: --only-names (bare, =true, =1), `doppler run -- <cmd>` (and its
#     `bash -c '...$SECRET...'` child), a redirect to a real file or /dev/null (with a trailing
#     2>&1, appended, &>), non-printing subcommands (set, configs, projects, login, setup),
#     and commands that merely carry the words in one quoted string
#   - the literal credentialed URL rule: each scheme, +driver suffixes, an empty user,
#     upper case; a URL without a password, host:port, https, and an environment-variable
#     password ($PW, ${PW}) allowed
#   - the per-command bypass variables, one per rule, work only as a LEADING unquoted
#     assignment on the stage they apply to (inherited by strings that stage runs), never
#     by substring, quoting, another stage, or the hook's own environment
#   - every unclassifiable input fails open WITH a stderr message and exit 1 (never 0, never
#     2): empty stdin, whitespace, malformed JSON, a non-object, a Bash event with no command,
#     a non-string command, python3 missing from PATH, and an internal classifier fault
#     (injected by importing the module and making analyze raise). A non-Bash tool is exit 0.
#     Ten levels of nested `bash -c` are denied, not guessed
#   - hooks/hooks.json parses, declares one PreToolUse/Bash command hook, and the command it
#     declares, with ${CLAUDE_PLUGIN_ROOT} substituted as the harness does, denies a real
#     printing command (exit 2) and allows a real safe one (exit 0)
# Documented limits are NOT asserted as caught: aliases, functions, variable
# indirection, symlinked redirect targets, a quoted command string handed to ssh/docker/su,
# and `doppler run -- env` / `printenv` (the child decides). See the module docstring.
#
# Mutations run against hooks/bash-secret-guard.py after the rewrite, each making cases red
# (failing-case count in parentheses), then reverted:
#   - doppler classified only as the first word (wrapper-table style) (38)
#   - --only-names=<anything> counts as on (4)
#   - redirect target not normalised (2)
#   - /dev and /proc targets count as files (13)
#   - a later dup to stderr ignored (2)
#   - unresolved variable target counts as a file (1)
#   - shell -c scripts not analysed (12)
#   - env -S strings not analysed (4)
#   - text piped into a shell not analysed (2)
#   - here-strings not analysed (1)
#   - doppler run --command not analysed (1)
#   - command substitutions not analysed (22)
#   - unknown secrets word allowed (fail-open) (2)
#   - bypass matched as a substring (1)
#   - bypass honoured when not leading (3)
#   - quoted bypass honoured (1)
#   - bypass not inherited by nested strings (1)
#   - URL: $ password not exempt (2)
#   - URL: case-sensitive (1)
#   - URL: empty user not allowed (1)
#   - nesting ceiling removed (1)
#   - raw-text URL fallback removed (1)
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
            *) frag='prints secret values' ;;
        esac
    fi
    run_cmd "$2"
    if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qF -- "$frag"; then
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
    if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'fail open'; then
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
deny "unknown word after secrets fails closed" 'doppler secrets frobnicate'
deny "unknown flag value read as subcommand fails closed" 'doppler secrets --weird val get X'
deny "--plain" 'doppler secrets get X --plain'
deny "--raw --plain" 'doppler secrets get X --raw --plain'
deny "--silent is not a safe form" 'doppler secrets get X --silent'
deny "--silent=0" 'doppler secrets get X --silent=0'
deny "--silent on bare secrets" 'doppler secrets --silent'
deny "--only-names=0" 'doppler secrets get X --only-names=0'
deny "--only-names=false" 'doppler secrets get X --only-names=false'
deny "--only-names=f" 'doppler secrets get X --only-names=f'
deny "--only-names then switched off" 'doppler secrets get X --only-names --only-names=false'
deny "denial text names the safe forms" 'doppler secrets get X'
case "$err" in
    *--only-names*"doppler run"*"real file"*SASSYDOG_ALLOW_DOPPLER_PRINT*) ok "the denial message names the safe forms and the bypass" ;;
    *) bad "the denial message names the safe forms and the bypass (got: $err)" ;;
esac

echo "== pipes into consumers no longer buy anything =="
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

echo "== captures no longer buy anything =="
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

echo "== reserved words =="
deny "for loop" 'for x in A B; do doppler secrets get $x; done'
deny "while loop" 'while read x; do doppler secrets get $x; done < names.txt'
deny "until loop" 'until false; do doppler secrets get X; done'
deny "if/then" 'if true; then doppler secrets get X; fi'
deny "else branch" 'if false; then :; else doppler secrets get X; fi'
deny "negation" '! doppler secrets get X'
deny "second segment after ;" 'echo start; doppler secrets get X'
deny "second segment after &&" 'cd /tmp && doppler secrets get X'

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
deny "here-string to bash" "bash <<< 'doppler secrets get X'"
deny "source of a process substitution" 'source <(echo doppler secrets get X)'
deny "dot of a process substitution" '. <(echo doppler secrets get X)'
deny "nested under doppler run" 'doppler run -- doppler secrets get X'
deny "doppler run child shell" "doppler run -- bash -c 'doppler secrets get X'"
deny "doppler run --command string" "doppler run --command 'doppler secrets get X'"
deny "doppler run --command= string" "doppler run --command='doppler secrets get X'"
deny "inside a dollar-paren" 'echo $(doppler secrets get X)'

echo "== redirects that are not a real file =="
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
deny "/proc/self/fd/1" 'doppler secrets get X --plain > /proc/self/fd/1'
deny "/proc/../proc/self/fd/1" 'doppler secrets get X --plain > /tmp/../proc/self/fd/1'
deny "relative climb" 'doppler secrets get X --plain > ../../../../dev/fd/1'
deny "unresolved variable target" 'doppler secrets get X --plain > $OUT'
deny "process substitution target" 'doppler secrets get X --plain > >(cat)'
deny "file then dup to stderr" 'doppler secrets get X --plain > key.txt >&2'
deny "file then 1>&2" 'doppler secrets get X --plain > key.txt 1>&2'
deny "only stderr redirected" 'doppler secrets get X --plain 2> err.txt'
deny "stdout sent to stderr" 'doppler secrets get X --plain >&2'

echo "== allowed =="
allow "--only-names" 'doppler secrets --only-names'
allow "get --only-names" 'doppler secrets get X --only-names'
allow "--only-names=true" 'doppler secrets --only-names=true'
allow "--only-names=1" 'doppler secrets --only-names=1'
allow "doppler run" 'doppler run -- ./deploy.sh'
allow "doppler run with flags" 'doppler run -p app -c prd -- npm test'
allow "doppler run bash -c child reading \$SECRET" "doppler run -- bash -c 'psql \"\$DATABASE_URL\" -c select1'"
allow "doppler run under sudo -u" 'sudo -u root doppler run -- ./deploy.sh'
allow "get redirected to a file" 'doppler secrets get X --plain > /tmp/f'
allow "get redirected to a relative file" 'doppler secrets get X --plain > key.txt'
allow "table form redirected to a file" 'doppler secrets get X > key.txt'
allow "redirect with a trailing 2>&1" 'doppler secrets get X --plain > key.txt 2>&1'
allow "append redirect" 'doppler secrets get X --plain >> key.txt'
allow "download to .env" 'doppler secrets download --no-file > .env'
allow "&> /dev/null" 'doppler secrets get X &> /dev/null'
allow "> /dev/null" 'doppler secrets get X > /dev/null'
allow "dup after a file keeps the file" 'doppler secrets get X --plain > key.txt 2>&1'
allow "for loop, redirected" 'for x in A B; do doppler secrets get $x --plain >> keys.txt; done'
allow "for loop, --only-names" 'for x in A B; do doppler secrets --only-names; done'
allow "secrets set" 'doppler secrets set X value'
allow "secrets delete" 'doppler secrets delete X'
allow "doppler setup" 'doppler setup --no-interactive'
allow "doppler configs" 'doppler configs -p app'
allow "doppler projects" 'doppler projects'
allow "doppler login" 'doppler login'
allow "mentions the words in one quoted string" 'git commit -m "doppler secrets get is dangerous"'
allow "grep for the words" 'grep -rn "doppler secrets" docs/'
allow "ordinary command" 'ls -la'
allow "empty command" ''

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
deny "in a heredoc body (read as a stage)" $'cat <<EOF\npostgres://app:hunter2@db/app\nEOF'
deny "in a comment (raw-text fallback)" 'ls # postgres://app:hunter2@db/app'
allow "comment URL with the leading bypass on the first stage" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 ls # postgres://app:hunter2@db/app'
allow "no password" 'psql postgres://app@db.example.com/app'
allow "host and port, no userinfo" 'psql postgres://db.example.com:5432/app'
allow "https URL with userinfo" 'curl https://user:pw@example.com/x'
allow "env var instead of a URL" 'doppler run -- psql "$DATABASE_URL"'
allow "password is an env var reference" 'psql "postgres://u:$PW@h/db"'
allow "password is a braced env var reference" 'psql "postgres://u:${PW}@h/db"'

echo "== per-command bypass: a leading unquoted assignment on that stage only =="
allow "doppler bypass written in the command" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
allow "URL bypass written in the command" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql postgres://a:b@h/d'
allow "bypass is inherited by the strings its stage runs" "SASSYDOG_ALLOW_DOPPLER_PRINT=1 bash -c 'doppler secrets get X'"
allow "bypass among other leading assignments" 'A=1 SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
deny "the doppler bypass does not unlock the URL rule" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 psql postgres://a:b@h/d'
deny "the URL bypass does not unlock the doppler rule" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 doppler secrets get X'
deny "bypass set to a different value" 'SASSYDOG_ALLOW_DOPPLER_PRINT=0 doppler secrets get X'
deny "bypass quoted is a command name, not an assignment" '"SASSYDOG_ALLOW_DOPPLER_PRINT=1" doppler secrets get X'
deny "bypass as an argument, not leading" 'echo SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
deny "bypass after the command word" 'doppler secrets get X SASSYDOG_ALLOW_DOPPLER_PRINT=1'
deny "bypass on another stage" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 echo hi; doppler secrets get X'
deny "bypass as a substring of a longer name" 'XSASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
deny "bypass inside a comment" 'doppler secrets get X # SASSYDOG_ALLOW_DOPPLER_PRINT=1'
deny "URL bypass as an argument" 'echo SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql postgres://a:b@h/d'
deny "URL bypass on another stage" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 echo hi; psql postgres://a:b@h/d'
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
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'python3 not found.*fail open'; then
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
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'internal error.*fail open'; then
    ok "an internal classifier fault fails open and says so"
else
    bad "an internal classifier fault fails open and says so (rc=$rc err=${err:-<none>})"
fi

echo "== nesting ceiling denies rather than guessing =="
deep='doppler secrets get X'
for _ in 1 2 3 4 5 6 7 8 9 10; do deep="bash -c '$(printf '%s' "$deep" | sed "s/'/'\\\\''/g")'"; done
deny "ten levels of bash -c" "$deep" 'nests too deeply'

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
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'BLOCKED'; then ok "declared command denies a real printing command"; else bad "declared command denies a real printing command (rc=$rc)"; fi
printf '%s' "$(event 'doppler secrets --only-names')" | bash -c "$harness_cmd" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "declared command allows a real safe command"; else bad "declared command allows a real safe command (rc=$rc)"; fi

echo
echo "bash-secret-guard: $pass_n passed, $fail_n failed"
[ "$fail_n" -eq 0 ]
