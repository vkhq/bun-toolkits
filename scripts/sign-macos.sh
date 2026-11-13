#!/usr/bin/env bash
# Signs the staged macOS binaries with a Developer ID and the hardened runtime.
#   ./scripts/sign-macos.sh <platform>
#
# Env:
#   APPLE_SIGNING_IDENTITY   e.g. "Developer ID Application: Your Org (TEAMID)"
#   MACOS_CERT_P12_BASE64    optional: base64 .p12 to import (CI)
#   MACOS_CERT_PASSWORD      password for that .p12

source "$(dirname "$0")/lib.sh"

PLATFORM="${1:?usage: sign-macos.sh mac-arm64|mac-x64}"
STAGE="$WORK_ROOT/$PLATFORM/stage"
: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is not set}"

if [ -n "${MACOS_CERT_P12_BASE64:-}" ]; then
  log "Importing signing certificate into a temporary keychain"
  KEYCHAIN="$WORK_ROOT/signing.keychain-db"
  KEYCHAIN_PASSWORD="$(uuidgen)"
  rm -f "$KEYCHAIN"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$WORK_ROOT/cert.p12"
  security import "$WORK_ROOT/cert.p12" -k "$KEYCHAIN" -P "${MACOS_CERT_PASSWORD:-}" \
    -T /usr/bin/codesign
  rm -f "$WORK_ROOT/cert.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  # shellcheck disable=SC2046 # existing keychain list is meant to be split
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
fi

for bin in "$STAGE"/bin/*; do
  log "Signing $(basename "$bin")"
  codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$bin"
  codesign --verify --strict --verbose=2 "$bin"
done
