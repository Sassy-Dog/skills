#!/usr/bin/env bash
# asc-jwt.sh — App Store Connect ES256 JWT signer, sourced by
# appstore-connect.sh and by scripts/test-testflight-jwt.sh.
#
# openssl is the only signer. There is deliberately no PyJWT path: on a PEP 668
# Python (Homebrew, current Debian/Ubuntu) `pip3 install pyjwt` is refused, and
# two signers meant the code that ran depended on the machine.
#
# Both functions fail closed: a bad key or a malformed signature returns
# non-zero and prints nothing, never a token with an empty signature.
#
# Requirements: openssl, xxd, base64.

asc_b64url_encode() { base64 | tr -d '=\n' | tr '/+' '_-'; }

# openssl dgst -sign emits a DER ECDSA signature; JWT ES256 needs raw R||S, two
# 32-byte integers. DER drops leading zero bytes from an integer and adds a 0x00
# sign byte when its high bit is set, so each one is left-padded, then trimmed,
# to exactly 32 bytes. P-256 lengths always fit DER's short form.
# stdin: DER signature; stdout: 64 raw bytes. Returns 1 on anything that is not
# that shape — including the empty input a failed `openssl dgst -sign` leaves.
asc_der_to_raw() {
    local hex r_len r_hex s_offset s_len s_hex
    hex=$(xxd -p | tr -d '\n')
    # DER: 30 <seq_len> 02 <r_len> <r_bytes> 02 <s_len> <s_bytes>
    # Shape is checked before any arithmetic, so bad input cannot crash the shell.
    [[ "$hex" =~ ^30[0-9a-f]{2}02[0-9a-f]{2} ]] || return 1
    (( 16#${hex:2:2} * 2 + 4 == ${#hex} )) || return 1
    r_len=$((16#${hex:6:2}))
    (( r_len >= 1 && r_len <= 33 )) || return 1
    r_hex=${hex:8:$((r_len * 2))}
    s_offset=$((8 + r_len * 2))
    [[ "${hex:$s_offset:4}" =~ ^02[0-9a-f]{2}$ ]] || return 1
    s_len=$((16#${hex:$((s_offset + 2)):2}))
    (( s_len >= 1 && s_len <= 33 && s_offset + 4 + s_len * 2 == ${#hex} )) || return 1
    s_hex=${hex:$((s_offset + 4)):$((s_len * 2))}
    while [ ${#r_hex} -lt 64 ]; do r_hex="00$r_hex"; done
    while [ ${#s_hex} -lt 64 ]; do s_hex="00$s_hex"; done
    r_hex=${r_hex: -64}
    s_hex=${s_hex: -64}
    echo -n "${r_hex}${s_hex}" | xxd -r -p
}

# Usage: asc_jwt <key-id> <issuer-id> <path-to-.p8>
# stdout: a JWT valid for 20 minutes. Returns 1, printing nothing, if signing fails.
asc_jwt() {
    local key_id="$1" issuer_id="$2" key_file="$3"
    local header payload signing_input signature iat exp

    header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$key_id" | asc_b64url_encode)
    iat=$(date +%s)
    exp=$((iat + 1200))
    payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' "$issuer_id" "$iat" "$exp" | asc_b64url_encode)
    signing_input="$header.$payload"
    signature=$(printf '%s' "$signing_input" | openssl dgst -binary -sha256 -sign "$key_file" | asc_der_to_raw | asc_b64url_encode)
    # The caller's pipefail is not assumed, so a failed stage need not fail this
    # assignment — but every failure upstream leaves the signature empty.
    [ -n "$signature" ] || return 1
    echo "$signing_input.$signature"
}
