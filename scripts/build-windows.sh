#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables here are read by functions in lib.sh
# Cross-compiles LGPL ffmpeg.exe + ffprobe.exe for Windows x64 on Linux.
#   ./scripts/build-windows.sh win-x64
# Needs: mingw-w64, nasm, meson, ninja-build, pkg-config, automake.

source "$(dirname "$0")/lib.sh"

PLATFORM="${1:-win-x64}"
[ "$PLATFORM" = "win-x64" ] || die "only win-x64 is supported"
command -v x86_64-w64-mingw32-gcc >/dev/null || die "mingw-w64 is not installed"

prepare_work "$PLATFORM"
EXE=".exe"
# Fully static: no libgcc/winpthread/zlib DLLs next to the exe.
EXTRA_LDFLAGS="-static"

CROSS_FILE="$WORK/mingw64.cross"
cat > "$CROSS_FILE" <<'EOF'
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'
nasm = 'nasm'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

build_zlib_mingw
build_lame --host=x86_64-w64-mingw32
build_dav1d --cross-file="$CROSS_FILE"

FF_EXTRA_FLAGS=(
  --enable-cross-compile
  --target-os=mingw32
  --arch=x86_64
  --cross-prefix=x86_64-w64-mingw32-
  --pkg-config=pkg-config
)
FF_REQUIRED_FEATURES=(zlib)
# Media Foundation gives OS-licensed H.264/HEVC/AAC encoders (h264_mf, aac_mf);
# Schannel gives TLS; the rest is hardware decoding.
FF_OPTIONAL_FEATURES=(mediafoundation schannel d3d11va dxva2)
build_ffmpeg
# The .exe can't run here, so the licence check is the config.h one only.

log "Checking DLL imports"
for bin in ffmpeg.exe ffprobe.exe; do
  dlls="$(x86_64-w64-mingw32-objdump -p "$FF_SRC/$bin" | awk '/DLL Name:/ {print $3}')"
  echo "$bin imports: $(echo "$dlls" | tr '\n' ' ')"
  if echo "$dlls" | grep -Eiq 'libwinpthread|libgcc|libstdc|zlib1|libdav1d|libmp3lame'; then
    die "$bin needs a DLL that won't exist on users' machines"
  fi
done

stage_output
log "Done: $STAGE"
