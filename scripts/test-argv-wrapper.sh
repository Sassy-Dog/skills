#!/usr/bin/env bash
# test-argv-wrapper.sh — pins the plugin's SECOND secret-guard layer (#670): the argv wrapper
# hooks/shim/doppler (+ hooks/doppler-wrapper.py) and the SessionStart hook hooks/session-path.sh that puts it
# first on the agent's Bash PATH. The text hook is pinned by test-bash-secret-guard.sh; this gate runs REAL
# processes: the real shim, a fake "real CLI" and a fake gh in a mktemp -d, real bash spellings, and file
# descriptors built to look like each stdout the wrapper can be handed.
#
# Why a second layer, and why this file exists: the text hook classifies the command BEFORE the shell
# expands it, so every spelling the text does not show (`$D secrets get X`, `dop*ler me`, `"$D" run`) was a
# new rule, and each round of review found another (#649 to #654, #659). The wrapper sees ARGV, the words the
# shell already produced. The expansion and glob rules and the inert-view tokenizer are deleted from the hook
# (its gate no longer holds them); this gate is where those spellings are pinned instead, on argv.
#
# What the wrapper cannot see is a redirection, only the file descriptor it was handed. So the allow list gets
# one more input, the kind of stdout (see doppler-wrapper.py): capture (fd 1 is fd 2's file or pipe, or a tty),
# file (a regular file that is not fd 2's and not O_APPEND), append, pipe, devnull, other, closed. The
# decisions this gate pins:
#   - the file form (`get`/`download --no-file`/`substitute` without --output) is allowed ONLY on a "file"
#     stdout; on Claude Code 2.1.332 the harness capture is one O_APPEND regular file shared by fd 1 and fd 2
#     (measured on 2026-11-28 with fstat and F_GETPATH; the measurement is not re-runnable here), so a plain
#     `doppler secrets get X` is a capture and denied, `> out` is a file and allowed, and `2>err` (stdout still
#     the capture, now different from fd 2) is "append" and denied;
#   - a pipe is never allowed for a printing form, because a wrapper cannot tell `| gh secret set` from `| cat`:
#     the pipe form is replaced by the wrapper's own subcommand `sassydog-gh-secret-set`, which reads the value
#     into memory and hands it to gh on stdin itself (failure paths: no gh, the CLI fails, an empty value, gh
#     fails: none of them sets a secret);
#   - the bootstrap shape (`secrets download --no-file --format env [-p P] [-c C]`) is allowed on a "pipe"
#     (what `eval "$(...)"` hands it) and nowhere a capture is; `secrets set` only with fd 1 AND fd 2 on
#     /dev/null; `--only-names`, `run`, bare subcommands, `download PATH` and `substitute --output` print
#     nothing and are allowed on any stdout.
#
# Asserted, each a committed case:
#   - SPELLINGS (the acceptance item): the printing form `secrets get X` reached through `$D`, `"$D"`, `${D}`,
#     `${D:-name}`, `$(echo name)`, a split or quoted or backslashed name, ANSI-C quoting, glob (`dop*ler`, `d?ppler`,
#     `[d]oppler`), `command`, `env`, `xargs`, `exec`, `time`, `eval`, `bash -c`, and a leading assignment, each
#     DENIED on a capture and the real CLI never called; and the same spellings of `run -- cmd` ALLOWED.
#   - the allowed-form corpus, every form the text hook allows (and the plugin's own skills emit) still reaches
#     the real CLI through the wrapper in the sink the text form implies: this is the "every form allowed
#     today is still allowed" check, with the text hook asked too so the two layers cannot drift;
#   - every printing form denied on every non-file sink (capture file, capture pipe, tty, append, pipe, socket,
#     closed, devnull) with the banner, exit 126, the real CLI never called and no secret in any captured output;
#   - the denies of the allow list on argv: unknown flags, run flags before `run`, `--only-secrets` on a read
#     subcommand, `--debug`/`--api-host`/`--token`, `secrets delete|upload`, `configure get`, `--print-config`,
#     `configs tokens`, no arguments, a device path, `secrets set` with only stdout discarded;
#   - the wrapper's failure paths, each said on stderr: no real CLI on PATH (127), the shim reached through a
#     symlink or twice (no recursion), python3 missing, the classifier missing, the classifier crashing: the last
#     three FAIL OPEN, loudly, and the real CLI runs; the real CLI's exit status and exact argv (spaces,
#     empty words) pass through;
#   - sassydog-gh-secret-set: success (value reaches gh's stdin, flags forwarded, nothing printed), the real
#     CLI missing, gh missing, the CLI failing (its status, gh never run), an empty value (gh never run), gh
#     failing (its status), a bad name or flag (denied at classify, nothing run);
#   - session-path.sh: no CLAUDE_ENV_FILE, an unwritable one, a missing shim (each exit 1 with a message), no
#     real CLI on PATH (exit 0, nothing written), the written line putting the shim first, idempotent when
#     sourced twice, and a shim path holding a space and a quote;
#   - hooks.json declares the SessionStart entry beside the PreToolUse one.
#
# NOT covered, and named so the header claims no more than the cases prove:
#   - the harness: whether a given harness puts hooks/shim first (Claude Code does, through CLAUDE_ENV_FILE, and a
#     nested `claude -p --plugin-dir` run on 2.1.332 showed the shim first on the Bash PATH and a `$D secrets get`
#     denied; that run is not repeatable here), and whether another harness's capture looks like the kinds above;
#   - the real binary by absolute path, a PATH that omits the shim, `env -i`, `command -p`;
#   - a harness whose capture is a regular file opened WITHOUT O_APPEND and different from stderr, or two
#     separate pipes (either looks like a legitimate redirect or `$(...)`); `get X > /dev/stdout 2>err` where
#     the platform reopens the capture without O_APPEND; the bootstrap argv into `echo "$(...)"` or `| cat`;
#   - the real Doppler CLI: the fake only records argv and prints a marker, so that `--plain` really prints
#     the bare value and `gh secret set` really reads stdin is not proved here.
#
# Safe beside every other gate: own mktemp -d, no fixed path, no network, no repo mutation, no port.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }
for f in hooks/shim/doppler hooks/doppler-wrapper.py hooks/session-path.sh hooks/bash-secret-guard.py hooks/hooks.json; do
    [ -f "$REPO_ROOT/$f" ] || { echo "  FAIL - $f exists"; echo "argv-wrapper: 0 passed, 1 failed"; exit 1; }
done

out="$(python3 -I -B "$REPO_ROOT/scripts/fixtures/argv-wrapper-driver.py" "$REPO_ROOT" "$WORK" 2>&1)"
rc=$?
printf '%s\n' "$out"
pass_n="$(printf '%s\n' "$out" | grep -c '^  ok   - ')"
fail_n="$(printf '%s\n' "$out" | grep -c '^  FAIL - ')"
if [ "$rc" -ne 0 ] && [ "$fail_n" -eq 0 ]; then
    echo "  FAIL - the driver exited $rc without reporting a failure"
    fail_n=1
fi
# A driver that crashed or stopped early must not pass by reporting nothing.
if [ "$pass_n" -lt 350 ]; then
    echo "  FAIL - the driver reported only $pass_n passing checks (at least 350 expected)"
    fail_n=$((fail_n + 1))
fi
echo
echo "argv-wrapper: $pass_n passed, $fail_n failed"
[ "$fail_n" -eq 0 ]
