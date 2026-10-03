---
name: testflight
description: >
  This skill should be used when the user asks to "check TestFlight feedback", "query TestFlight",
  "list beta testers", "show TestFlight builds", "get beta feedback", "check App Store Connect",
  "query app store connect API", "list TestFlight groups", "show build status",
  or any task involving TestFlight feedback, beta testers, builds, or App Store Connect API queries.
---

# TestFlight & App Store Connect

Query TestFlight feedback, beta testers, builds, and beta groups via the App Store Connect API using a bundled script.

## Prerequisites

Three environment variables must be available (typically from Doppler via direnv).
The canonical `APPLE_ASC_*` names are preferred; the legacy `APPLE_APP_STORE_CONNECT_*`
names are still accepted as a fallback.

| Variable (canonical) | Legacy fallback | Source |
|----------------------|-----------------|--------|
| `APPLE_ASC_API_KEY_ID` | `APPLE_APP_STORE_CONNECT_API_KEY_ID` | Apple Developer > Keys |
| `APPLE_ASC_ISSUER_ID` | `APPLE_APP_STORE_CONNECT_ISSUER_ID` | Apple Developer > Keys |
| `APPLE_ASC_API_KEY_BASE64` | `APPLE_APP_STORE_CONNECT_API_KEY_BASE64` | `.p8` file, base64-encoded |

If missing, prompt the user to add them to Doppler and run `direnv allow`.

## Usage

The bundled script `scripts/appstore-connect.sh` handles JWT generation and API calls.

### Available Commands

```bash
# TestFlight feedback (default)
bash ${SKILL_DIR}/scripts/appstore-connect.sh <bundle-id> feedback

# List beta testers
bash ${SKILL_DIR}/scripts/appstore-connect.sh <bundle-id> testers

# Recent builds
bash ${SKILL_DIR}/scripts/appstore-connect.sh <bundle-id> builds

# Beta groups
bash ${SKILL_DIR}/scripts/appstore-connect.sh <bundle-id> groups

# Raw API query (any App Store Connect endpoint path)
bash ${SKILL_DIR}/scripts/appstore-connect.sh <bundle-id> raw /v1/apps/{appId}/betaAppLocalizations
```

### Bundle IDs

Look up the bundle ID from the project's iOS config. Common locations:

- Flutter: `ios/Runner.xcodeproj/project.pbxproj` or `ios/Runner/Info.plist`
- Xcode: target > General > Bundle Identifier
- If unknown, run with any bundle ID — the script lists available apps on auth errors

### Workflow

1. Verify env vars are set: check `APPLE_APP_STORE_CONNECT_API_KEY_ID` exists in environment
2. Determine the bundle ID from project config
3. Run the appropriate command via the bundled script
4. Parse and present the JSON output to the user in a readable format

### Interpreting Results

- **feedback**: Returns `screenshotSubmissions` and `crashSubmissions` arrays from Apple's v1 beta feedback endpoints. Screenshot submissions include tester comments, device info, and screenshot URLs (with expiration dates). Crash submissions include crash logs.
- **testers**: Email, name, invite type, device info, and installed build version for all beta testers.
- **builds**: Version, upload date, processing state, and expiration status.
- **groups**: Beta group names, whether internal, and public link status.

### Error Handling

| Error | Action |
|-------|--------|
| Missing env vars | Tell user to add Apple credentials to Doppler |
| Could not sign the JWT | `APPLE_ASC_API_KEY_BASE64` does not decode to a valid `.p8` key — re-encode it (`base64 < AuthKey_<id>.p8`) and update Doppler. No request was sent |
| HTTP 401 | API key may be revoked — regenerate in Apple Developer portal |
| HTTP 403 | API key role insufficient — needs App Manager or Admin |
| No app found | Bundle ID is wrong — try `raw /v1/apps` to list all apps |

## Additional Resources

### Reference Files

- **`references/api-endpoints.md`** — Full App Store Connect API endpoint reference for TestFlight-related resources, field descriptions, and filter parameters

### Scripts

- **`scripts/appstore-connect.sh`** — Bundled query script with JWT generation, multi-command support, and error handling. Requires `curl`, `jq`, `openssl`, `base64` and `xxd`; no Python.
- **`scripts/asc-jwt.sh`** — The ES256 JWT signer the query script sources: `openssl` plus a DER-to-raw signature conversion, and the only signer.
