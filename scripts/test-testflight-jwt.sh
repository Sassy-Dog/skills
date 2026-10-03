#!/usr/bin/env bash
# test-testflight-jwt.sh — pins the testflight skill's App Store Connect JWT
# signer: one implementation (openssl), no Python dependency, fails closed.
#
# The bug it guards. appstore-connect.sh used to sign with PyJWT when
# `python3 -c "import jwt"` succeeded and fall back to openssl otherwise, and
# its warning told the operator to `pip3 install pyjwt cryptography`. On a
# PEP 668 Python — Homebrew's, and current Debian/Ubuntu — that command is
# refused without `--break-system-packages`, and a user-site install made with
# that flag is dropped by the next minor Python upgrade. So the advice could not
# be followed cleanly, and two signers meant the code that ran depended on
# which machine ran it. The openssl path was already correct and already in
# use wherever PyJWT was absent; it is now the only path.
#
# Four things are pinned:
#
#   1. asc_der_to_raw turns an openssl DER ECDSA signature into JWT ES256's raw
#      R||S, including the two shapes DER produces that are not 32 bytes, on
#      BOTH integers: a 33-byte integer (a 0x00 sign byte, high bit set) and a
#      short one (DER strips leading zero bytes). Fixed vectors, because a
#      random signature hits a short integer only about 1 time in 128 — the
#      8-token round trip below does not reliably catch a padding regression.
#   2. Signing fails CLOSED. A missing or garbage key, or DER that is not an
#      ECDSA signature, makes asc_jwt / asc_der_to_raw return non-zero and print
#      nothing. Before this, a failed `openssl dgst -sign` still produced a
#      `header.payload.` token with an empty signature, and App Store Connect's
#      401 sent the operator off to regenerate a key that was never the fault.
#   3. asc_jwt's output verifies: a throwaway P-256 key signs several tokens,
#      each signature is re-encoded to DER and checked with `openssl dgst
#      -verify`, and a tampered signature must FAIL that check (otherwise the
#      verification proves nothing).
#   4. appstore-connect.sh signs only through asc-jwt.sh, neither script calls
#      Python, and the SKILL.md no longer tells an agent to install PyJWT.
#
# Proving mutations: delete either padding loop in asc_der_to_raw (the short-R
# or short-S vectors fail); delete asc_jwt's empty-signature return (the bad-key
# cases fail); delete asc_der_to_raw's structure check (the malformed-DER cases
# fail).
#
# Needs openssl, xxd, jq and base64. A local run without them SKIPs; CI
# (CI set) fails instead, since it must never pass by not running.
#
# No gh, no network, no real credentials: the key is generated per run.
#
# Wired into scripts/preflight.sh; run directly:
#   bash scripts/test-testflight-jwt.sh
set -uo pipefail
export LC_ALL=C

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -z "$REPO_ROOT" ] && { echo "test-testflight-jwt: not in a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

missing=""
for t in openssl xxd jq base64; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
    if [ -n "${CI:-}" ]; then
        echo "test-testflight-jwt: FAILED — missing in CI:$missing" >&2
        exit 1
    fi
    echo "test-testflight-jwt: SKIP — missing locally:$missing (CI still enforces)" >&2
    exit 0
fi

SCRIPT="skills/testflight/scripts/appstore-connect.sh"
LIB="skills/testflight/scripts/asc-jwt.sh"
SKILL="skills/testflight/SKILL.md"

fails=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

echo "TestFlight JWT signer: openssl only, fails closed, verifiable ES256"

for f in "$SCRIPT" "$LIB" "$SKILL"; do
    [ -r "$f" ] || bad "missing file: $f"
done
[ "$fails" -eq 0 ] || { echo "test-testflight-jwt: FAILED" >&2; exit 1; }

# shellcheck source=../skills/testflight/scripts/asc-jwt.sh
. "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hex_of() { xxd -p | tr -d '\n'; }
rep()    { local out="" i; for ((i = 0; i < $2; i++)); do out="$out$1"; done; printf '%s' "$out"; }
b64url_decode() {
    local s
    s="$(printf '%s' "$1" | tr '_-' '/+')"
    while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
    printf '%s' "$s" | base64 --decode
}
# Test-only inverse of asc_der_to_raw, so openssl can verify a JWT signature.
raw_to_der() {
    local hex r s body
    hex="$(hex_of)"
    r="$(der_int "${hex:0:64}")"
    s="$(der_int "${hex:64:64}")"
    body="$r$s"
    printf '30%02x%s' $(( ${#body} / 2 )) "$body" | xxd -r -p
}
der_int() {
    local h="$1"
    while [ "${h:0:2}" = "00" ] && [ "${#h}" -gt 2 ]; do h="${h:2}"; done
    [ $(( 16#${h:0:2} )) -ge 128 ] && h="00$h"
    printf '02%02x%s' $(( ${#h} / 2 )) "$h"
}

# --- 1. DER -> raw R||S on fixed vectors ---------------------------------------

R32="$(rep 11 32)"; S32="$(rep 22 32)"
RHI="$(rep 81 32)"; SHI="$(rep 82 32)"
R31="$(rep 44 31)"; S31="$(rep 33 31)"

check_vector() {
    local label="$1" der="$2" want="$3" got
    got="$(printf '%s' "$der" | xxd -r -p | asc_der_to_raw | hex_of)"
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (got ${got:0:16}…, ${#got} hex chars)"; fi
}

check_vector "32-byte R and S pass through" \
    "3044""0220$R32""0220$S32"         "$R32$S32"
check_vector "33-byte R (sign byte) is trimmed to 32" \
    "3045""022100$RHI""0220$S32"       "$RHI$S32"
check_vector "33-byte S (sign byte) is trimmed to 32" \
    "3045""0220$R32""022100$SHI"       "$R32$SHI"
check_vector "31-byte R (stripped zero) is left-padded to 32" \
    "3043""021f$R31""0220$S32"         "00$R31$S32"
check_vector "31-byte S (stripped zero) is left-padded to 32" \
    "3043""0220$R32""021f$S31"         "${R32}00$S31"
check_vector "31-byte R and 31-byte S together" \
    "3042""021f$R31""021f$S31"         "00${R31}00$S31"
check_vector "33-byte R and 31-byte S together" \
    "3044""022100$RHI""021f$S31"       "${RHI}00$S31"

# --- 2. fails closed ----------------------------------------------------------

check_rejects_der() {
    local label="$1" der="$2" out rc
    out="$(printf '%s' "$der" | xxd -r -p | asc_der_to_raw 2>/dev/null | hex_of)"
    # An empty rc means the function crashed its shell (a bash arithmetic error)
    # rather than returning — that is not a clean refusal, so it is a FAIL too.
    rc="$(printf '%s' "$der" | xxd -r -p | { asc_der_to_raw >/dev/null 2>&1; echo $?; })"
    if [[ "$rc" =~ ^[1-9][0-9]*$ ]] && [ -z "$out" ]; then ok "$label"; else bad "$label (rc=${rc:-crashed}, ${#out} hex chars out)"; fi
}

check_rejects_der "empty input is rejected"            ""
check_rejects_der "a non-SEQUENCE prefix is rejected"  "3144""0220$R32""0220$S32"
check_rejects_der "a non-INTEGER R tag is rejected"    "3044""0320$R32""0220$S32"
check_rejects_der "a truncated signature is rejected"  "3044""0220$R32""0220${S32:0:40}"

printf 'not a key\n' > "$TMP/garbage.p8"
for case in "garbage key:$TMP/garbage.p8" "missing key:$TMP/absent.p8"; do
    label="${case%%:*}"; key="${case#*:}"
    out="$(asc_jwt KEYID123 issuer-uuid "$key" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
        ok "a $label makes asc_jwt fail with no token"
    else
        bad "a $label still produced a token (rc=$rc, '${out:0:40}…')"
    fi
done

# --- 3. asc_jwt round-trips through openssl -verify ----------------------------

openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/ec.pem" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$TMP/ec.pem" -out "$TMP/key.p8" 2>/dev/null
openssl ec -in "$TMP/ec.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null

verified=0
if [ -s "$TMP/key.p8" ] && [ -s "$TMP/pub.pem" ]; then
    for _ in 1 2 3 4 5 6 7 8; do
        jwt="$(asc_jwt KEYID123 issuer-uuid "$TMP/key.p8")"
        IFS=. read -r h p sig extra <<<"$jwt"
        if [ -z "$h" ] || [ -z "$p" ] || [ -z "$sig" ] || [ -n "$extra" ]; then
            bad "asc_jwt did not print three dot-separated segments"; break
        fi
        printf '%s' "$h.$p" > "$TMP/input"
        b64url_decode "$sig" > "$TMP/sig.raw"
        if [ "$(wc -c < "$TMP/sig.raw" | tr -d ' ')" != 64 ]; then
            bad "signature is not 64 raw bytes"; break
        fi
        raw_to_der < "$TMP/sig.raw" > "$TMP/sig.der"
        if openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/sig.der" "$TMP/input" >/dev/null 2>&1; then
            verified=$((verified + 1))
        else
            bad "a signature failed openssl -verify"; break
        fi
    done
else
    bad "could not generate a throwaway P-256 key"
fi

# Everything below reads the last token, so it runs only on a clean round trip;
# otherwise it would report against files that were never written.
if [ "$verified" -eq 8 ]; then
    ok "8 of 8 tokens verify against the public key"

    # A flipped bit must fail, or the loop above proves nothing. XOR rather than
    # overwrite, so the byte always changes.
    sig_hex="$(hex_of < "$TMP/sig.raw")"
    printf '%s%02x' "${sig_hex:0:126}" $(( 16#${sig_hex:126:2} ^ 1 )) | xxd -r -p > "$TMP/bad.raw"
    raw_to_der < "$TMP/bad.raw" > "$TMP/bad.der"
    if openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/bad.der" "$TMP/input" >/dev/null 2>&1; then
        bad "a tampered signature still verified — the round-trip check is vacuous"
    else
        ok "a tampered signature is rejected"
    fi

    header="$(b64url_decode "$h")"
    payload="$(b64url_decode "$p")"
    if jq -e '.alg == "ES256" and .kid == "KEYID123" and .typ == "JWT"' <<<"$header" >/dev/null 2>&1; then
        ok "header carries alg ES256, kid and typ"
    else
        bad "header is wrong: $header"
    fi
    if jq -e '.iss == "issuer-uuid" and .aud == "appstoreconnect-v1" and (.exp - .iat) == 1200' <<<"$payload" >/dev/null 2>&1; then
        ok "payload carries iss, aud and a 20-minute expiry"
    else
        bad "payload is wrong: $payload"
    fi
fi

# --- 4. one signer, no Python --------------------------------------------------

# Scripts are checked on code lines only: asc-jwt.sh's header comment says why
# there is no PyJWT path, and that note is what stops one being re-added.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }
script_code="$(code_of "$SCRIPT")"
lib_code="$(code_of "$LIB")"

if grep -qE '^\. ".*/asc-jwt\.sh"$' <<<"$script_code" && grep -qE 'asc_jwt ' <<<"$script_code"; then
    ok "appstore-connect.sh sources asc-jwt.sh and signs with asc_jwt"
else
    bad "appstore-connect.sh does not sign through asc-jwt.sh"
fi
if grep -qE 'openssl[[:space:]].*-sign' <<<"$script_code"; then
    bad "appstore-connect.sh carries its own openssl signer — the lib must be the only one"
else
    ok "appstore-connect.sh has no second signer"
fi
PY_CODE='python[0-9.]*([[:space:]]|$)|pyjwt|import jwt|from jwt'
for f in "$SCRIPT" "$LIB"; do
    code="$(code_of "$f")"
    if grep -qiE "$PY_CODE" <<<"$code"; then
        bad "$f still calls Python or PyJWT"
    else
        ok "$f has no Python or PyJWT code"
    fi
done
# The SKILL.md is instructions an agent follows: no Python to run, nothing to install.
if grep -qiE 'python3|pyjwt|pip3? install|import jwt' "$SKILL"; then
    bad "$SKILL still tells the agent to run Python or install PyJWT"
else
    ok "$SKILL has no Python or PyJWT instruction"
fi
[ -n "$lib_code" ] || bad "$LIB has no code lines"

if [ "$fails" -ne 0 ]; then
    echo "test-testflight-jwt: FAILED ($fails)" >&2
    exit 1
fi
echo "TestFlight JWT tests: all green"
