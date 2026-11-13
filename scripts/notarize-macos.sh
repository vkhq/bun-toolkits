#!/usr/bin/env bash
# Sends a packaged macOS zip to Apple's notary service and waits for the result.
#   ./scripts/notarize-macos.sh dist/<release>-mac-arm64.zip
#
# Env (same names as Bun's Forge config): APPLE_ID,
# APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID.
#
# Bare command-line binaries can't be stapled; Gatekeeper looks the ticket up
# online. Bun downloads toolkits itself (no quarantine flag), so this mainly
# matters if someone downloads the zip in a browser.

source "$(dirname "$0")/lib.sh"

ZIP="${1:?usage: notarize-macos.sh <zip>}"
: "${APPLE_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}" "${APPLE_TEAM_ID:?}"

log "Notarizing $(basename "$ZIP")"
result="$(xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" \
  --wait --output-format json)"
echo "$result"
status="$(echo "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
[ "$status" = "Accepted" ] || die "notarization status: ${status:-unknown}"
