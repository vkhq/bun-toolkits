#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables here are read by functions in lib.sh
# Builds LGPL ffmpeg + ffprobe for macOS on a native runner.
#   ./scripts/build-macos.sh mac-arm64   (on Apple Silicon)
#   ./scripts/build-macos.sh mac-x64     (on Intel)
# Needs: Xcode command line tools, nasm, meson, ninja, pkgconf, automake.

source "$(dirname "$0")/lib.sh"

PLATFORM="${1:?usage: build-macos.sh mac-arm64|mac-x64}"
case "$PLATFORM:$(uname -m)" in
  mac-arm64:arm64 | mac-x64:x86_64) ;;
  *) die "$PLATFORM must be built on a matching Mac (this one is $(uname -m))" ;;
esac

prepare_work "$PLATFORM"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
EXTRA_CFLAGS="-mmacosx-version-min=${MACOS_MIN_VERSION}"
EXTRA_LDFLAGS="-mmacosx-version-min=${MACOS_MIN_VERSION}"

build_lame
build_dav1d -Dc_args="$EXTRA_CFLAGS" -Dc_link_args="$EXTRA_LDFLAGS"

# zlib from macOS itself; hardware H.264/HEVC/AAC encoders from the OS.
FF_REQUIRED_FEATURES=(zlib videotoolbox audiotoolbox)
# TLS for http(s) inputs, if this FFmpeg version still supports it.
FF_OPTIONAL_FEATURES=(securetransport)
build_ffmpeg
check_runtime_license

log "Checking linked libraries"
for bin in ffmpeg ffprobe; do
  bad="$(otool -L "$FF_SRC/$bin" | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  [ -z "$bad" ] || die "$bin links to libraries users won't have: $bad"
done

stage_output
log "Done: $STAGE"
