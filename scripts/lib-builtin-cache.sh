#!/usr/bin/env bash
# shellcheck shell=bash
# lib-builtin-cache.sh — the ONE built-in-cache check for the setup-deps
# workflow templates (#551). Sourced, never executed, by
# test-lockfile-sync-policy.sh and test-deps-cadence-policy.sh; a fix lands here
# once instead of in two copies.
#
# builtin_cache_violations <file> [want_bun want_node]
#   Prints one line per problem and returns 0 only when it printed nothing.
#   - oven-sh/setup-bun needs `no-cache: true`; actions/setup-node needs
#     `package-manager-cache: false`; subosito/flutter-action and
#     dtolnay/rust-toolchain must set no `*cache*:` input at all (flutter's
#     `cache:` defaults to false; rust-toolchain has no cache).
#   - A step is recognised by a `uses:` on ANY of its lines, so the name-first
#     form (`- name: X` then `uses: ...`) is checked too. Comment lines are
#     ignored. A step ends at the next line at or left of its own `- ` indent,
#     so a later job cannot satisfy an earlier step.
#   - want_bun / want_node, when given, are the exact number of such steps the
#     template must contain. Without them a renamed action would classify zero
#     steps and the gate would go green on nothing.
builtin_cache_violations() {
    local out
    out="$(grep -Ev '^[[:space:]]*#' "$1" | awk -v want_bun="${2-}" -v want_node="${3-}" '
        function ind(s) { match(s, /^ */); return RLENGTH }
        function fin() {
            if (kind == "bun" && !ok) print "setup-bun step without `no-cache: true`: " name
            if (kind == "node" && !ok) print "setup-node step without `package-manager-cache: false`: " name
            if ((kind == "flutter" || kind == "rust") && bad) print kind " step sets a cache input: " name
            kind = ""
        }
        /^[[:space:]]*$/ { next }
        {
            if (kind != "" && ind($0) <= dash) fin()
            if ($0 ~ /^[[:space:]]*- /) { dash = ind($0); kind = ""; ok = 0; bad = 0; name = $0; open = 1 }
            if (open && kind == "" && $0 ~ /(^|[[:space:]-])uses:[[:space:]]*/) {
                if ($0 ~ /uses:[[:space:]]*oven-sh\/setup-bun@/) { kind = "bun"; nb++ }
                else if ($0 ~ /uses:[[:space:]]*actions\/setup-node@/) { kind = "node"; nn++ }
                else if ($0 ~ /uses:[[:space:]]*subosito\/flutter-action@/) kind = "flutter"
                else if ($0 ~ /uses:[[:space:]]*dtolnay\/rust-toolchain@/) kind = "rust"
                if (kind != "") name = $0
            }
            if (kind == "bun" && $0 ~ /^[[:space:]]+no-cache:[[:space:]]*true[[:space:]]*$/) ok = 1
            if (kind == "node" && $0 ~ /^[[:space:]]+package-manager-cache:[[:space:]]*false[[:space:]]*$/) ok = 1
            if ((kind == "flutter" || kind == "rust") && $0 ~ /^[[:space:]]+[A-Za-z_-]*cache[A-Za-z_-]*:/) bad = 1
        }
        END {
            fin()
            if (want_bun != "" && nb + 0 != want_bun + 0) print "expected " want_bun " setup-bun steps, found " nb + 0
            if (want_node != "" && nn + 0 != want_node + 0) print "expected " want_node " setup-node steps, found " nn + 0
        }')" || { echo "builtin_cache_violations: the scan of $1 failed"; return 1; }
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"
    return 1
}
