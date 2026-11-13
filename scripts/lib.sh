#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables here are read by functions in lib.sh
# Shared helpers for the build scripts. Sourced, never run directly.
#
# Layout used by every script:
#   sources/            downloaded, verified source tarballs (git-ignored)
#   work/<platform>/    extracted sources, dependency prefix, staged output
#   dist/               finished zips, source bundle, manifest (git-ignored)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"

SOURCES_DIR="$ROOT/sources"
WORK_ROOT="$ROOT/work"
DIST_DIR="$ROOT/dist"
LOCK_FILE="$ROOT/sources.lock"

# The names Bun already uses for vendor/<os>-<arch>.
KNOWN_PLATFORMS="mac-arm64 mac-x64 linux-x64 win-x64"

log() { printf '\n==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

jobs_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }

release_name() { echo "ffmpeg-lgpl-${FFMPEG_VERSION}-${BUILD_REVISION}"; }

# One line per source: <name> <file> <url>
sources_list() {
  cat <<EOF
ffmpeg ffmpeg-${FFMPEG_VERSION}.tar.xz https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz
dav1d dav1d-${DAV1D_VERSION}.tar.xz https://download.videolan.org/pub/videolan/dav1d/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.xz
lame lame-${LAME_VERSION}.tar.gz https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz
zlib zlib-${ZLIB_VERSION}.tar.gz https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz
EOF
}

source_file() {
  sources_list | awk -v n="$1" '$1 == n { print $2 }'
}

check_platform() {
  case " $KNOWN_PLATFORMS " in
    *" $1 "*) ;;
    *) die "unknown platform '$1' (expected one of: $KNOWN_PLATFORMS)" ;;
  esac
}

# Sets WORK, PREFIX, SRC_DIR and STAGE for a platform and starts from a clean tree.
prepare_work() {
  PLATFORM="$1"
  check_platform "$PLATFORM"
  WORK="$WORK_ROOT/$PLATFORM"
  PREFIX="$WORK/prefix"
  SRC_DIR="$WORK/src"
  STAGE="$WORK/stage"
  rm -rf "$WORK"
  mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$SRC_DIR" "$STAGE"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  # Stops pkg-config from finding Homebrew or distro copies of our deps.
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
}

# Extracts a verified tarball into $SRC_DIR and prints the source directory.
extract_source() {
  local name="$1" file dir
  file="$(source_file "$name")"
  [ -f "$SOURCES_DIR/$file" ] || die "missing $SOURCES_DIR/$file (run scripts/fetch-sources.sh)"
  tar -xf "$SOURCES_DIR/$file" -C "$SRC_DIR"
  dir="$SRC_DIR/${file%.tar.*}"
  [ -d "$dir" ] || die "expected $dir after extracting $file"
  echo "$dir"
}

# --- Dependencies -----------------------------------------------------------

build_zlib_mingw() {
  log "Building zlib ${ZLIB_VERSION} (static, Windows)"
  local src
  src="$(extract_source zlib)"
  make -C "$src" -f win32/Makefile.gcc -j"$(jobs_count)" \
    PREFIX=x86_64-w64-mingw32- \
    BINARY_PATH="$PREFIX/bin" INCLUDE_PATH="$PREFIX/include" LIBRARY_PATH="$PREFIX/lib" \
    install
  # Leave only the static library so the linker can't pick the DLL.
  rm -f "$PREFIX/lib/libz.dll.a" "$PREFIX/bin/zlib1.dll"
}

# Extra arguments go to LAME's configure (e.g. --host=...).
build_lame() {
  log "Building LAME ${LAME_VERSION} (static)"
  local src automake_dir
  src="$(extract_source lame)"
  # LAME 3.100 ships 2017-era config.guess/config.sub that don't know
  # Apple Silicon; swap in the copies from the installed automake.
  automake_dir="$(automake --print-libdir)"
  cp "$automake_dir/config.guess" "$automake_dir/config.sub" "$src/"
  (
    cd "$src"
    ./configure --prefix="$PREFIX" --disable-shared --enable-static \
      --disable-frontend --disable-decoder --disable-dependency-tracking "$@"
    make -j"$(jobs_count)"
    make install
  )
}

# Extra arguments go to meson setup (e.g. --cross-file=...).
build_dav1d() {
  log "Building dav1d ${DAV1D_VERSION} (static)"
  local src
  src="$(extract_source dav1d)"
  meson setup "$WORK/dav1d-build" "$src" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false \
    "$@"
  meson install -C "$WORK/dav1d-build"
}

# --- FFmpeg -----------------------------------------------------------------

# Set by the platform script before calling build_ffmpeg:
#   FF_REQUIRED_FEATURES  autodetect features that must be enabled (array)
#   FF_OPTIONAL_FEATURES  enabled only if this FFmpeg version still has them (array)
#   FF_EXTRA_FLAGS        any other configure flags (array)
#   EXTRA_CFLAGS / EXTRA_LDFLAGS  strings
#   EXE                   ".exe" on Windows, empty elsewhere
FF_REQUIRED_FEATURES=()
FF_OPTIONAL_FEATURES=()
FF_EXTRA_FLAGS=()
EXTRA_CFLAGS=""
EXTRA_LDFLAGS=""
EXE=""

# True when configure knows --enable-NAME / --disable-NAME.
ff_has_option() {
  grep -Eq -- "--(enable|disable)-$1([[:space:]]|$)" "$FF_SRC/.configure-help"
}

build_ffmpeg() {
  log "Configuring FFmpeg ${FFMPEG_VERSION}"
  FF_SRC="$(extract_source ffmpeg)"
  cd "$FF_SRC"
  ./configure --help > .configure-help

  local flags=(
    --prefix="$PREFIX/ffmpeg"
    --extra-version="bun-toolkits-${BUILD_REVISION}"
    # Never pull in libraries we didn't ask for (keeps the binary portable
    # and the licence predictable). Wanted OS features are enabled below.
    --disable-autodetect
    --disable-debug
    --disable-doc
    --disable-ffplay
    --disable-shared
    --enable-static
    --enable-libdav1d
    --enable-libmp3lame
    --pkg-config-flags=--static
    --extra-cflags="-I$PREFIX/include ${EXTRA_CFLAGS}"
    --extra-ldflags="-L$PREFIX/lib ${EXTRA_LDFLAGS}"
  )
  # NOTE: there is deliberately no --enable-gpl, --enable-nonfree or
  # --enable-version3 here. check_ffmpeg_license fails the build if any of
  # them sneak in.

  local f
  for f in "${FF_REQUIRED_FEATURES[@]+"${FF_REQUIRED_FEATURES[@]}"}"; do
    ff_has_option "$f" || die "FFmpeg ${FFMPEG_VERSION} has no '$f' option"
    flags+=("--enable-$f")
  done
  for f in "${FF_OPTIONAL_FEATURES[@]+"${FF_OPTIONAL_FEATURES[@]}"}"; do
    if ff_has_option "$f"; then
      flags+=("--enable-$f")
    else
      warn "FFmpeg ${FFMPEG_VERSION} has no '$f' option; skipping it"
    fi
  done
  for f in $DISABLE_ENCODERS; do
    flags+=("--disable-encoder=$f")
  done
  flags+=("${FF_EXTRA_FLAGS[@]+"${FF_EXTRA_FLAGS[@]}"}")

  ./configure "${flags[@]}" || { tail -n 80 ffbuild/config.log >&2; die "FFmpeg configure failed"; }
  check_ffmpeg_license

  log "Building FFmpeg ${FFMPEG_VERSION}"
  make -j"$(jobs_count)"
  [ -f "ffmpeg$EXE" ] && [ -f "ffprobe$EXE" ] || die "ffmpeg$EXE / ffprobe$EXE were not built"
}

# Fails unless configure produced an LGPL-only build. Sets FF_LICENSE and FF_CONFIGURATION.
check_ffmpeg_license() {
  grep -q '^#define CONFIG_GPL 0' config.h || die "build is GPL; refusing to continue"
  grep -q '^#define CONFIG_NONFREE 0' config.h || die "build is nonfree (not redistributable); refusing to continue"
  if grep -q '^#define CONFIG_VERSION3 1' config.h; then
    FF_LICENSE="LGPL-3.0-or-later"
  else
    FF_LICENSE="LGPL-2.1-or-later"
  fi
  FF_CONFIGURATION="$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h)"
  log "Licence check passed: $FF_LICENSE"
}

# Runs the built binary (native builds only) and confirms it reports LGPL.
check_runtime_license() {
  "$FF_SRC/ffmpeg$EXE" -hide_banner -L 2>&1 | grep -q "Lesser General Public License" \
    || die "ffmpeg -L does not report the LGPL"
  "$FF_SRC/ffmpeg$EXE" -hide_banner -version
}

# --- Output -----------------------------------------------------------------

stage_output() {
  log "Staging $PLATFORM output"
  mkdir -p "$STAGE/bin" "$STAGE/licenses"
  cp "$FF_SRC/ffmpeg$EXE" "$FF_SRC/ffprobe$EXE" "$STAGE/bin/"
  chmod 755 "$STAGE/bin/"*

  cp "$FF_SRC/LICENSE.md" "$STAGE/licenses/FFmpeg-LICENSE.md"
  cp "$FF_SRC/COPYING.LGPLv2.1" "$STAGE/licenses/FFmpeg-LGPL-2.1.txt"
  if [ "$FF_LICENSE" = "LGPL-3.0-or-later" ]; then
    cp "$FF_SRC/COPYING.LGPLv3" "$STAGE/licenses/FFmpeg-LGPL-3.0.txt"
  fi
  cp "$SRC_DIR/lame-${LAME_VERSION}/COPYING" "$STAGE/licenses/LAME-LGPL.txt"
  cp "$SRC_DIR/dav1d-${DAV1D_VERSION}/COPYING" "$STAGE/licenses/dav1d-BSD-2-Clause.txt"
  if [ -d "$SRC_DIR/zlib-${ZLIB_VERSION}" ]; then
    if [ -f "$SRC_DIR/zlib-${ZLIB_VERSION}/LICENSE" ]; then
      cp "$SRC_DIR/zlib-${ZLIB_VERSION}/LICENSE" "$STAGE/licenses/zlib-LICENSE.txt"
    else
      cp "$SRC_DIR/zlib-${ZLIB_VERSION}/README" "$STAGE/licenses/zlib-README.txt"
    fi
  fi

  local zlib_note="system"
  [ -d "$SRC_DIR/zlib-${ZLIB_VERSION}" ] && zlib_note="${ZLIB_VERSION}"

  PLATFORM="$PLATFORM" FF_LICENSE="$FF_LICENSE" FF_CONFIGURATION="$FF_CONFIGURATION" \
  ZLIB_NOTE="$zlib_note" EXE="$EXE" RELEASE="$(release_name)" \
  FFMPEG_VERSION="$FFMPEG_VERSION" DAV1D_VERSION="$DAV1D_VERSION" LAME_VERSION="$LAME_VERSION" \
  BUILD_REVISION="$BUILD_REVISION" python3 - "$STAGE/BUILDINFO.json" <<'PY'
import json, os, sys, datetime
e = os.environ
info = {
    "release": e["RELEASE"],
    "platform": e["PLATFORM"],
    "license": e["FF_LICENSE"],
    "components": {
        "ffmpeg": e["FFMPEG_VERSION"],
        "dav1d": e["DAV1D_VERSION"],
        "lame": e["LAME_VERSION"],
        "zlib": e["ZLIB_NOTE"],
    },
    "revision": int(e["BUILD_REVISION"]),
    "binaries": ["bin/ffmpeg" + e["EXE"], "bin/ffprobe" + e["EXE"]],
    "configuration": e["FF_CONFIGURATION"],
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "commit": e.get("GITHUB_SHA", "local"),
}
with open(sys.argv[1], "w") as f:
    json.dump(info, f, indent=2)
    f.write("\n")
PY

  cat > "$STAGE/NOTICE.md" <<EOF
# FFmpeg ${FFMPEG_VERSION} (LGPL build) for ${PLATFORM}

This archive contains \`ffmpeg\` and \`ffprobe\` from the FFmpeg project
(https://ffmpeg.org), built without any GPL or nonfree components.

- FFmpeg ${FFMPEG_VERSION}: ${FF_LICENSE} (see licenses/)
- LAME ${LAME_VERSION} (MP3 encoder): LGPL
- dav1d ${DAV1D_VERSION} (AV1 decoder): BSD-2-Clause
- zlib: ${zlib_note}

## Corresponding source

The complete source code for these binaries (the exact FFmpeg, LAME, dav1d
and zlib tarballs, plus the build scripts and configuration used) is
published alongside this archive in the same release, as
\`$(release_name)-source.tar.gz\`.

## Build configuration

\`\`\`
${FF_CONFIGURATION}
\`\`\`

You may replace these binaries with your own build of FFmpeg.
EOF
}
