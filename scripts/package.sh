#!/usr/bin/env bash
# Zips the staged output of a platform build into dist/.
#   ./scripts/package.sh <platform>
# Run after build-*.sh (and after sign-macos.sh on macOS).
# Archive layout: bin/, licenses/, BUILDINFO.json, NOTICE.md at the root.

source "$(dirname "$0")/lib.sh"

PLATFORM="${1:?usage: package.sh <platform>}"
check_platform "$PLATFORM"
STAGE="$WORK_ROOT/$PLATFORM/stage"
[ -f "$STAGE/BUILDINFO.json" ] || die "nothing staged for $PLATFORM; run the build script first"

mkdir -p "$DIST_DIR"
ZIP="$DIST_DIR/$(release_name)-$PLATFORM.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -r -X -9 -q "$ZIP" .)
log "Wrote $ZIP ($(sha256_of "$ZIP"))"
echo "$ZIP"
