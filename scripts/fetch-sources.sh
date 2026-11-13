#!/usr/bin/env bash
# Downloads every source tarball into sources/ and verifies it.
#
#   ./scripts/fetch-sources.sh               verify against sources.lock (CI)
#   ./scripts/fetch-sources.sh --update-lock record hashes for new versions
#
# FFmpeg is also checked against the FFmpeg release signing key, so even a
# first --update-lock run can't record a tampered FFmpeg tarball.

source "$(dirname "$0")/lib.sh"

UPDATE_LOCK=0
[ "${1:-}" = "--update-lock" ] && UPDATE_LOCK=1

missing=()
for tool in curl gpg tar xz; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  pkgs="${missing[*]}"
  pkgs="${pkgs/gpg/gnupg}"
  case "$(uname -s)" in
    Darwin) hint="brew install $pkgs" ;;
    *) hint="sudo apt-get install ${pkgs/xz/xz-utils}  (or your distro's equivalent)" ;;
  esac
  die "missing required tools: ${missing[*]}. Install them with: $hint"
fi

mkdir -p "$SOURCES_DIR"
touch "$LOCK_FILE"

download() {
  local url="$1" out="$2"
  if [ -f "$out" ]; then
    return
  fi
  log "Downloading $url"
  curl -fL --retry 3 --retry-delay 5 -o "$out.part" "$url"
  mv "$out.part" "$out"
}

verify_ffmpeg_signature() {
  local file="$1" gnupg
  log "Verifying FFmpeg signature"
  download "https://ffmpeg.org/releases/${file}.asc" "$SOURCES_DIR/${file}.asc"
  download "https://ffmpeg.org/ffmpeg-devel.asc" "$SOURCES_DIR/ffmpeg-devel.asc"
  gnupg="$(mktemp -d)"
  GNUPGHOME="$gnupg" gpg --batch --quiet --import "$SOURCES_DIR/ffmpeg-devel.asc"
  if ! GNUPGHOME="$gnupg" gpg --batch --status-fd 1 --verify \
      "$SOURCES_DIR/${file}.asc" "$SOURCES_DIR/$file" 2>/dev/null \
    | grep -q "^\[GNUPG:\] VALIDSIG ${FFMPEG_GPG_FINGERPRINT} "; then
    rm -rf "$gnupg"
    die "$file is not signed by the FFmpeg release key ${FFMPEG_GPG_FINGERPRINT}"
  fi
  rm -rf "$gnupg"
  echo "ok  $file signature (key ${FFMPEG_GPG_FINGERPRINT})"
}

new_lock="$(mktemp)"
trap 'rm -f "$new_lock"' EXIT

while read -r name file url; do
  download "$url" "$SOURCES_DIR/$file"
  [ "$name" = "ffmpeg" ] && verify_ffmpeg_signature "$file"

  actual="$(sha256_of "$SOURCES_DIR/$file")"
  expected="$(awk -v f="$file" '$2 == f { print $1 }' "$LOCK_FILE")"

  if [ "$UPDATE_LOCK" = 1 ]; then
    [ -n "$expected" ] && [ "$expected" != "$actual" ] \
      && warn "$file hash changed: $expected -> $actual"
    printf '%s  %s\n' "$actual" "$file" >> "$new_lock"
  elif [ -z "$expected" ]; then
    die "$file is not in sources.lock. Run './scripts/fetch-sources.sh --update-lock' locally, review, and commit."
  elif [ "$expected" != "$actual" ]; then
    die "$file hash mismatch: expected $expected, got $actual"
  else
    echo "ok  $file"
  fi
done < <(sources_list)

if [ "$UPDATE_LOCK" = 1 ]; then
  sort -k2 "$new_lock" > "$LOCK_FILE"
  log "Wrote $LOCK_FILE. Review the hashes before committing:"
  cat "$LOCK_FILE"
fi
