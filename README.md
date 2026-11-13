# bun-toolkits

LGPL builds of **FFmpeg** (`ffmpeg` + `ffprobe`) for macOS, Windows and Linux,
built in the open by GitHub Actions and published as GitHub Releases.

This repository contains **only build scripts**. It has no application code.
Apps download a release zip, check its SHA-256, and run the binaries as
separate programs.

| Platform | Runner | Notes |
|---|---|---|
| `mac-arm64` | `macos-26` | VideoToolbox / AudioToolbox encoders, macOS 11+ |
| `mac-x64` | `macos-26-intel` | Same, Intel |
| `win-x64` | `ubuntu-24.04` (mingw-w64 cross-compile) | Media Foundation encoders, fully static `.exe` |
| `linux-x64` | `ubuntu-22.04` | glibc 2.35+, system `libz.so.1` |

Each build includes FFmpeg 9.0.2, **dav1d** 1.5.4 (AV1 decoding), **LAME** 3.100
(MP3 encoding) and, on Windows, a static **zlib** 1.3.1. Versions are pinned in
[`versions.env`](versions.env).

## What's in a release

```
ffmpeg-lgpl-9.0.2-1-mac-arm64.zip
ffmpeg-lgpl-9.0.2-1-mac-x64.zip
ffmpeg-lgpl-9.0.2-1-linux-x64.zip
ffmpeg-lgpl-9.0.2-1-win-x64.zip
ffmpeg-lgpl-9.0.2-1-source.tar.gz   ← corresponding source for all of the above
manifest.json                       ← URLs, sizes, SHA-256 per platform
SHA256SUMS
```

Every zip has the same layout:

```
bin/ffmpeg(.exe)
bin/ffprobe(.exe)
licenses/          FFmpeg LGPL text + LAME, dav1d, zlib licences
BUILDINFO.json     versions, licence, full configure line, commit
NOTICE.md          what this is and where the source is
```

## Licence compliance

These are the steps FFmpeg's [legal checklist](https://ffmpeg.org/legal.html)
asks of anyone distributing FFmpeg binaries. Each one is covered here:

- **LGPL only.** `configure` runs without `--enable-gpl`, `--enable-nonfree` or
  `--enable-version3`. The build **fails** if `config.h` shows GPL or nonfree,
  and native builds also check that `ffmpeg -L` reports the LGPL.
- **No surprise libraries.** `--disable-autodetect` is used, and only LGPL- or
  BSD-compatible libraries are enabled. Each platform script then fails if the
  binary links anything users won't have.
- **Exact source.** Every release ships `…-source.tar.gz`: the exact upstream
  tarballs (FFmpeg's GPG signature included), the scripts, `versions.env`,
  `sources.lock` and the workflow. FFmpeg is unmodified.
- **Integrity.** FFmpeg tarballs are checked against the FFmpeg release
  signing key. All tarballs are checked against `sources.lock`.
- **Notices.** Licence texts and `NOTICE.md` ship inside every zip.

**Patents are a separate question from the licence.** These builds don't
include x264, x265 or OpenH264. H.264, HEVC and AAC encoding should go through
the OS encoders (`h264_videotoolbox`, `aac_at`, `h264_mf`, `aac_mf`), which
Apple and Microsoft license. FFmpeg's own native AAC encoder is still built in.
Set `DISABLE_ENCODERS="aac"` in `versions.env` if you'd rather leave it out.
Linux builds have no H.264/HEVC encoder. This isn't legal advice.

## First-time setup

1. Create the repo in your GitHub org (public, so the source is easy to reach)
   and push these files.
2. On any Mac or Linux machine with `curl`, `gpg` and `xz`:
   ```sh
   ./scripts/fetch-sources.sh --update-lock
   ```
   Check the hashes it prints against the upstream release pages, then commit
   `sources.lock`.
3. Optional: add repository secrets for macOS signing and notarization. Without
   them, macOS builds are still produced, just unsigned.

   | Secret | Value |
   |---|---|
   | `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Your Org (TEAMID)` |
   | `MACOS_CERT_P12_BASE64` | `base64 -i cert.p12` of the Developer ID certificate |
   | `MACOS_CERT_PASSWORD` | its password |
   | `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | for `notarytool` |

4. Open a pull request. CI builds all four platforms without publishing.

## Publishing a release

```sh
# after changing versions.env (and refreshing sources.lock if versions changed)
git tag ffmpeg-9.0.2-1
git push origin ffmpeg-9.0.2-1
```

The tag must be `ffmpeg-<FFMPEG_VERSION>-<BUILD_REVISION>`. The workflow
refuses to publish if it doesn't match `versions.env`. To rebuild the same
FFmpeg version with different flags, bump `BUILD_REVISION`.

## Building locally

```sh
./scripts/fetch-sources.sh
./scripts/build-macos.sh mac-arm64     # or build-linux.sh linux-x64 / build-windows.sh win-x64
./scripts/package.sh mac-arm64         # → dist/ffmpeg-lgpl-…-mac-arm64.zip
```

Tools needed:

- **macOS:** `brew install nasm meson ninja pkgconf automake`
- **Linux / Windows cross-compile:** `apt install build-essential nasm meson ninja-build pkg-config automake autoconf libtool zip zlib1g-dev mingw-w64`

## Using a release from an app

- Read `manifest.json` to find the zip for the current platform, but **pin
  each zip's `sha256` in the app itself**. Then a changed manifest can't make
  the app install a binary you didn't ship.
- After extracting, run `bin/ffmpeg -hide_banner -L` and confirm it reports
  the LGPL before switching to the new version.
- Show the licences from `licenses/` in the app's About or Licences screen.
  The app's EULA must not forbid reverse engineering of these components.
