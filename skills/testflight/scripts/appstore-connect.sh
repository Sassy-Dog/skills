#!/usr/bin/env bash

# App Store Connect API query tool
# Generates an ES256 JWT and queries TestFlight-related endpoints.
#
# Requirements: openssl, xxd, base64, curl, jq
# Env vars (canonical APPLE_ASC_* names; APPLE_APP_STORE_CONNECT_* still accepted):
#   APPLE_ASC_API_KEY_ID
#   APPLE_ASC_ISSUER_ID
#   APPLE_ASC_API_KEY_BASE64

set -euo pipefail

BUNDLE_ID="${1:?Usage: $0 <bundle-id> [feedback|testers|builds|groups|raw <path>]}"
COMMAND="${2:-feedback}"

# --- Resolve & validate env vars ---
# Canonical names are APPLE_ASC_*; APPLE_APP_STORE_CONNECT_* is accepted as a
# legacy fallback so older Doppler configs keep working.
KEY_ID="${APPLE_ASC_API_KEY_ID:-${APPLE_APP_STORE_CONNECT_API_KEY_ID:-}}"
ISSUER_ID="${APPLE_ASC_ISSUER_ID:-${APPLE_APP_STORE_CONNECT_ISSUER_ID:-}}"
API_KEY_BASE64="${APPLE_ASC_API_KEY_BASE64:-${APPLE_APP_STORE_CONNECT_API_KEY_BASE64:-}}"

missing=()
[[ -z "$KEY_ID" ]] && missing+=("APPLE_ASC_API_KEY_ID")
[[ -z "$ISSUER_ID" ]] && missing+=("APPLE_ASC_ISSUER_ID")
[[ -z "$API_KEY_BASE64" ]] && missing+=("APPLE_ASC_API_KEY_BASE64")
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌ Missing Apple App Store Connect credentials: ${missing[*]}" >&2
    echo "   Add them to Doppler, then: direnv allow" >&2
    exit 1
fi

# --- Decode key to temp file ---
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

API_KEY_FILE="$TEMP_DIR/AuthKey_${KEY_ID}.p8"
echo "$API_KEY_BASE64" | base64 --decode > "$API_KEY_FILE"

# --- Generate JWT (ES256, 20-min expiry) ---
# shellcheck source=./asc-jwt.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/asc-jwt.sh"
JWT=$(asc_jwt "$KEY_ID" "$ISSUER_ID" "$API_KEY_FILE") || {
    echo "❌ Could not sign the App Store Connect JWT — APPLE_ASC_API_KEY_BASE64 must decode to the .p8 key" >&2
    exit 1
}

# --- API helper ---
API_BASE="https://api.appstoreconnect.apple.com"

asc_get() {
    local url="$1"
    local response http_code body

    # -g disables curl's URL globbing (brackets in filter[field] params)
    response=$(curl -sg -w "\n%{http_code}" -H "Authorization: Bearer $JWT" "$url")
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "❌ HTTP $http_code from: $url" >&2
        echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
        return 1
    fi

    echo "$body"
}

# --- Resolve app ID ---
echo "===> Looking up app: $BUNDLE_ID" >&2
APP_RESPONSE=$(asc_get "$API_BASE/v1/apps?filter[bundleId]=$BUNDLE_ID")
APP_ID=$(echo "$APP_RESPONSE" | jq -r '.data[0].id // empty')

if [[ -z "$APP_ID" ]]; then
    echo "❌ No app found with bundle ID: $BUNDLE_ID" >&2
    echo "Available apps:" >&2
    ALL_APPS=$(asc_get "$API_BASE/v1/apps?limit=50" 2>/dev/null || true)
    echo "$ALL_APPS" | jq -r '.data[]? | "  \(.attributes.bundleId) — \(.attributes.name)"' 2>/dev/null >&2
    exit 1
fi

APP_NAME=$(echo "$APP_RESPONSE" | jq -r '.data[0].attributes.name')
echo "    Found: $APP_NAME (ID: $APP_ID)" >&2
echo "" >&2

# --- Commands ---
case "$COMMAND" in
    feedback)
        echo "===> TestFlight Builds" >&2
        BUILDS=$(asc_get "$API_BASE/v1/builds?filter[app]=$APP_ID&sort=-uploadedDate&limit=10")
        echo "$BUILDS" | jq -r '.data[] | "  v\(.attributes.version) (\(.attributes.uploadedDate[:10])) — \(.attributes.processingState)"' >&2
        echo "" >&2

        # Fetch screenshot feedback (shake-to-report with screenshots)
        echo "===> Beta Feedback (Screenshots)" >&2
        SCREENSHOT_FB=$(asc_get "$API_BASE/v1/apps/$APP_ID/betaFeedbackScreenshotSubmissions?limit=25" 2>/dev/null || echo '{"data":[]}')
        SCREENSHOT_COUNT=$(echo "$SCREENSHOT_FB" | jq '.data | length' 2>/dev/null || echo 0)
        echo "    $SCREENSHOT_COUNT screenshot submission(s)" >&2

        # Fetch crash feedback (shake-to-report with crash logs)
        echo "===> Beta Feedback (Crashes)" >&2
        CRASH_FB=$(asc_get "$API_BASE/v1/apps/$APP_ID/betaFeedbackCrashSubmissions?limit=25" 2>/dev/null || echo '{"data":[]}')
        CRASH_COUNT=$(echo "$CRASH_FB" | jq '.data | length' 2>/dev/null || echo 0)
        echo "    $CRASH_COUNT crash submission(s)" >&2

        TOTAL=$((SCREENSHOT_COUNT + CRASH_COUNT))
        if [[ "$TOTAL" -gt 0 ]]; then
            # Merge both feedback types into a single response
            jq -n --argjson screenshots "$SCREENSHOT_FB" --argjson crashes "$CRASH_FB" \
                '{ screenshotSubmissions: $screenshots.data, crashSubmissions: $crashes.data }'
        else
            echo "No beta feedback found." >&2
            echo '{"screenshotSubmissions":[],"crashSubmissions":[]}'
        fi
        ;;

    testers)
        echo "===> Beta Testers" >&2
        TESTERS=$(asc_get "$API_BASE/v1/betaTesters?filter[apps]=$APP_ID&limit=200")
        echo "$TESTERS" | jq '.'
        ;;

    builds)
        echo "===> Recent Builds" >&2
        BUILDS=$(asc_get "$API_BASE/v1/builds?filter[app]=$APP_ID&sort=-uploadedDate&limit=20")
        echo "$BUILDS" | jq '.'
        ;;

    groups)
        echo "===> Beta Groups" >&2
        BETA_GROUPS=$(asc_get "$API_BASE/v1/apps/$APP_ID/betaGroups")
        echo "$BETA_GROUPS" | jq '.'
        ;;

    raw)
        RAW_PATH="${3:?Usage: $0 <bundle-id> raw <api-path>}"
        # Replace {appId} placeholder with resolved app ID
        RAW_PATH="${RAW_PATH//\{appId\}/$APP_ID}"
        echo "===> GET $RAW_PATH" >&2
        asc_get "$API_BASE$RAW_PATH"
        ;;

    *)
        echo "Usage: $0 <bundle-id> [feedback|testers|builds|groups|raw <path>]" >&2
        exit 1
        ;;
esac
