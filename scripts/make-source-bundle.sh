#!/usr/bin/env bash
# Packs the corresponding source for a release: every tarball the binaries
# were built from (plus the FFmpeg signature), the build scripts, the
# pinned versions and the CI workflow.
#   ./scripts/make-source-bundle.sh

source "$(dirname "$0")/lib.sh"

mkdir -p "$DIST_DIR"
OUT="$DIST_DIR/$(release_name)-source.tar.gz"

while read -r _ file _; do
  [ -f "$SOURCES_DIR/$file" ] || die "missing $SOURCES_DIR/$file"
done < <(sources_list)

tar -czf "$OUT" -C "$ROOT" \
  sources scripts versions.env sources.lock README.md LICENSE .github
log "Wrote $OUT ($(sha256_of "$OUT"))"
