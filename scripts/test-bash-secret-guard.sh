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
# Asserted, by piping the harness's event JSON into the hook exactly as Claude Code does:
#   - each denied Doppler form: get, download, substitute, bare `secrets`, --plain
#     un-consumed, --raw alone, --plain into tee, --plain inside echo "$(...)", an absolute
#     doppler path, a sudo/env wrapper, `bash -c`/eval strings, a nested
#     `doppler run -- doppler secrets get`, a doppler in a later `;`/`&&` segment
#   - each allowed form: --only-names, --silent, `doppler run -- <cmd>` (including the
#     `bash -c '...$SECRET...'` child), --plain into sed/wc/grep -c/sha256sum/head -c0, a
#     $(...) capture into an assignment, a redirect to a file (even without --plain),
#     `secrets set`, and non-doppler commands that merely mention the words
#   - the literal credentialed URL rule: each scheme denied, a URL without a password, a
#     host:port URL and a bare `user@host` URL allowed
#   - the per-command bypass variables, one per rule, work only when written in the command;
#     the hook's own environment does not bypass
#   - every unclassifiable input fails open WITH a stderr message and exit 1 (never 0, never
#     2): empty stdin, whitespace, malformed JSON, a non-object, a Bash event with no command,
#     a non-string command, python3 missing from PATH, and an internal classifier fault
#     (injected by importing the module and making analyze raise). A non-Bash tool is exit 0
#   - hooks/hooks.json parses, declares one PreToolUse/Bash command hook, and the command it
#     declares, with ${CLAUDE_PLUGIN_ROOT} substituted as the harness does, denies a real
#     printing command (exit 2) and allows a real safe one (exit 0)
# Documented limits are NOT asserted as caught: heredoc bodies, process substitution, aliases
# and variable indirection (see the module docstring). `sed` is trusted to redact.
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
    python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# run_event <json> -> sets rc, err
run_event() {
    err="$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null)"
    rc=$?
}
run_cmd() { run_event "$(event "$1")"; }

deny() { # <label> <command>
    run_cmd "$2"
    if [ "$rc" -eq 2 ] && [ -n "$err" ]; then ok "denied: $1"; else bad "denied: $1 (rc=$rc err=${err:-<none>})"; fi
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

echo "== denied Doppler forms =="
deny "secrets get" 'doppler secrets get DATABASE_URL'
deny "secrets get with project flags" 'doppler secrets get DATABASE_URL -p app -c prd'
deny "secrets get --raw alone" 'doppler secrets get DATABASE_URL --raw'
deny "secrets get --json" 'doppler secrets get DATABASE_URL --json'
deny "bare secrets" 'doppler secrets'
deny "bare secrets with flags" 'doppler secrets -p app -c prd --json'
deny "secrets download" 'doppler secrets download --no-file'
deny "secrets substitute" 'doppler secrets substitute template.yaml'
deny "--plain with nothing consuming it" 'doppler secrets get X --plain'
deny "--raw --plain with nothing consuming it" 'doppler secrets get X --raw --plain'
deny "--plain into tee" 'doppler secrets get X --plain | tee out.txt'
deny "--plain into cat" 'doppler secrets get X --plain | cat'
deny "--plain printed by echo" 'echo "$(doppler secrets get X --plain)"'
deny "--plain printed by printf" 'printf "%s\n" $(doppler secrets get X --plain)'
deny "table form captured then not consumed" 'X=$(doppler secrets get X); echo hi'
deny "stdout sent to stderr" 'doppler secrets get X --plain >&2'
deny "absolute doppler path" '/usr/local/bin/doppler secrets get X'
deny "sudo wrapper" 'sudo doppler secrets get X'
deny "env wrapper" 'env FOO=1 doppler secrets get X'
deny "second segment after ;" 'echo start; doppler secrets get X'
deny "second segment after &&" 'cd /tmp && doppler secrets get X'
deny "inside bash -c" "bash -c 'doppler secrets get X'"
deny "inside eval" 'eval "doppler secrets get X"'
deny "inside backticks" 'echo `doppler secrets get X --plain`'
deny "nested under doppler run" 'doppler run -- doppler secrets get X'
deny "doppler run --command string" "doppler run --command 'doppler secrets get X'"
deny "global flags before secrets" 'doppler -p app secrets get X'
deny "quoted > is an argument not a redirect" 'doppler secrets get X --plain ">" out'
deny "denial text names the safe forms" 'doppler secrets get X'
case "$err" in
    *--only-names*"doppler run"*SASSYDOG_ALLOW_DOPPLER_PRINT*) ok "the denial message names the safe forms and the bypass" ;;
    *) bad "the denial message names the safe forms and the bypass (got: $err)" ;;
esac

echo "== allowed Doppler forms =="
allow "--only-names" 'doppler secrets --only-names'
allow "get --only-names" 'doppler secrets get X --only-names'
allow "--silent" 'doppler secrets get X --silent'
allow "doppler run" 'doppler run -- ./deploy.sh'
allow "doppler run with flags" 'doppler run -p app -c prd -- npm test'
allow "doppler run bash -c child reading \$SECRET" "doppler run -- bash -c 'psql \"\$DATABASE_URL\" -c select1'"
allow "--plain into wc" 'doppler secrets get X --plain | wc -c'
allow "--raw --plain into sha256sum" 'doppler secrets get X --raw --plain | sha256sum'
allow "--plain into grep -c" 'doppler secrets get X --plain | grep -c .'
allow "--plain into sed" 'doppler secrets get X --plain | sed "s/./*/g"'
allow "--plain into head -c0" 'doppler secrets get X --plain | head -c0'
allow "--plain into head -c 0" 'doppler secrets get X --plain | head -c 0'
allow "--plain captured into an assignment" 'TOKEN=$(doppler secrets get X --plain)'
allow "--plain captured in a test" '[ -n "$(doppler secrets get X --plain)" ] && echo set'
allow "--plain captured as a header argument" 'curl -H "Authorization: Bearer $(doppler secrets get T --plain)" https://example.com'
allow "--plain redirected to a file" 'doppler secrets get X --plain > key.txt'
allow "download redirected to a file" 'doppler secrets download --no-file > .env'
allow "table form redirected with &>" 'doppler secrets get X &> /dev/null'
allow "secrets set" 'doppler secrets set X value'
allow "doppler setup" 'doppler setup --no-interactive'
allow "mentions the words without running doppler" 'git commit -m "doppler secrets get is dangerous"'
allow "grep for the words" 'grep -rn "doppler secrets" docs/'
allow "ordinary command" 'ls -la'
allow "empty command" ''

echo "== literal credentialed URL rule =="
deny "postgres" 'psql postgres://app:hunter2@db.example.com:5432/app'
deny "postgresql" 'psql postgresql://app:hunter2@db.example.com/app'
deny "mysql" 'mysql mysql://root:pw@127.0.0.1/db'
deny "mongodb" 'mongosh mongodb://u:p@host/db'
deny "mongodb+srv" 'mongosh "mongodb+srv://u:p@cluster.example.net/db"'
deny "redis" 'redis-cli -u redis://default:pw@cache.example.com:6379'
deny "rediss" 'redis-cli -u rediss://default:pw@cache.example.com:6379'
deny "amqp" 'curl amqp://guest:guest@broker/vhost'
deny "amqps" 'curl amqps://guest:guest@broker/vhost'
deny "inside a quoted string" "echo 'postgres://app:hunter2@db/app'"
allow "no password" 'psql postgres://app@db.example.com/app'
allow "host and port, no userinfo" 'psql postgres://db.example.com:5432/app'
allow "password-less https URL" 'curl https://user:pw@example.com/x'
allow "env var instead of a URL" 'doppler run -- psql "$DATABASE_URL"'

echo "== per-command bypass =="
allow "doppler bypass written in the command" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 doppler secrets get X'
allow "URL bypass written in the command" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 psql postgres://a:b@h/d'
deny "the doppler bypass does not unlock the URL rule" 'SASSYDOG_ALLOW_DOPPLER_PRINT=1 psql postgres://a:b@h/d'
deny "the URL bypass does not unlock the doppler rule" 'SASSYDOG_ALLOW_CREDENTIAL_URL=1 doppler secrets get X'
deny "bypass set to a different value" 'SASSYDOG_ALLOW_DOPPLER_PRINT=0 doppler secrets get X'
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
deny "ten levels of bash -c" "$deep"

echo "== hooks.json wiring, run as the harness runs it =="
python3 -I - "$HOOKS_JSON" <<'EOF' && ok "hooks.json declares exactly one PreToolUse Bash command hook" || bad "hooks.json declares exactly one PreToolUse Bash command hook"
import json, sys
d = json.load(open(sys.argv[1]))
pre = d["hooks"]["PreToolUse"]
assert len(pre) == 1 and pre[0]["matcher"] == "Bash", pre
hs = pre[0]["hooks"]
assert len(hs) == 1 and hs[0]["type"] == "command" and "${CLAUDE_PLUGIN_ROOT}/hooks/bash-secret-guard.sh" in hs[0]["command"], hs
assert set(d["hooks"]) == {"PreToolUse"}, list(d["hooks"])
EOF
declared="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$HOOKS_JSON")"
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
