#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables here are read by functions in lib.sh
# Builds LGPL ffmpeg + ffprobe for Linux x64.
#   ./scripts/build-linux.sh linux-x64
# Build on the oldest Ubuntu you support (glibc is linked dynamically).
# Needs: build-essential, nasm, meson, ninja-build, pkg-config, automake, zlib1g-dev.

source "$(dirname "$0")/lib.sh"

PLATFORM="${1:-linux-x64}"
[ "$PLATFORM" = "linux-x64" ] && [ "$(uname -m)" = "x86_64" ] \
  || die "linux-x64 must be built on an x86_64 Linux machine"

prepare_work "$PLATFORM"
EXTRA_LDFLAGS="-static-libgcc"

build_lame
build_dav1d

# zlib comes from the system (libz.so.1 is on every desktop distro);
# FFmpeg finds it with -lz, not pkg-config.
FF_REQUIRED_FEATURES=(zlib)
# No H.264/HEVC encoder on Linux: there is no OS encoder to borrow and the
# software ones are GPL (x264/x265) or carry patent royalties (OpenH264
# built from source). VP9/AV1/Opus/MP3/FLAC still work.
build_ffmpeg
check_runtime_license

log "Checking linked libraries"
for bin in ffmpeg ffprobe; do
  ldd "$FF_SRC/$bin"
  if ldd "$FF_SRC/$bin" | grep -Eq 'libdav1d|libmp3lame|not found'; then
    die "$bin is dynamically linked to a bundled dependency or a missing library"
  fi
done

stage_output
log "Done: $STAGE"
