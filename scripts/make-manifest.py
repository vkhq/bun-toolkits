#!/usr/bin/env python3
"""Writes dist/manifest.json and dist/SHA256SUMS for a release.

    python3 scripts/make-manifest.py --repo my-org/bun-toolkits --tag ffmpeg-9.0.2-1

manifest.json is what the app reads to offer the "media" toolkit. The app
should still pin each build's sha256 in its own code, so a changed manifest
can't push an unexpected binary.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PLATFORMS = ["mac-arm64", "mac-x64", "linux-x64", "win-x64"]


def read_versions():
    versions = {}
    for line in (ROOT / "versions.env").read_text().splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            versions[m.group(1)] = m.group(2).strip().strip('"')
    return versions


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def describe(path, repo, tag):
    return {
        "file": path.name,
        "url": f"https://github.com/{repo}/releases/download/{tag}/{path.name}",
        "sha256": sha256(path),
        "size": path.stat().st_size,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="owner/name of this GitHub repo")
    parser.add_argument("--tag", required=True, help="release tag, e.g. ffmpeg-9.0.2-1")
    parser.add_argument("--dist", default=str(ROOT / "dist"))
    parser.add_argument("--allow-missing", action="store_true",
                        help="don't fail when a platform zip is missing (testing only)")
    args = parser.parse_args()

    v = read_versions()
    release = f"ffmpeg-lgpl-{v['FFMPEG_VERSION']}-{v['BUILD_REVISION']}"
    expected_tag = f"ffmpeg-{v['FFMPEG_VERSION']}-{v['BUILD_REVISION']}"
    if args.tag != expected_tag:
        sys.exit(f"tag {args.tag} doesn't match versions.env (expected {expected_tag})")

    dist = pathlib.Path(args.dist)
    source = dist / f"{release}-source.tar.gz"
    if not source.exists():
        sys.exit(f"missing {source}")

    builds = {}
    licenses = set()
    for platform in PLATFORMS:
        zip_path = dist / f"{release}-{platform}.zip"
        if not zip_path.exists():
            if args.allow_missing:
                print(f"warning: no build for {platform}", file=sys.stderr)
                continue
            sys.exit(f"missing {zip_path}")
        with zipfile.ZipFile(zip_path) as z:
            info = json.loads(z.read("BUILDINFO.json"))
            names = set(z.namelist())
        if info["platform"] != platform:
            sys.exit(f"{zip_path.name} says it is for {info['platform']}")
        for binary in info["binaries"]:
            if binary not in names:
                sys.exit(f"{zip_path.name} is missing {binary}")
        licenses.add(info["license"])
        builds[platform] = {
            **describe(zip_path, args.repo, args.tag),
            "binaries": info["binaries"],
            "license": info["license"],
            "components": info["components"],
        }

    if not builds:
        sys.exit("no builds found")

    manifest = {
        "schema": 1,
        "id": "media",
        "name": "FFmpeg (LGPL)",
        "release": release,
        "tag": args.tag,
        "version": v["FFMPEG_VERSION"],
        "revision": int(v["BUILD_REVISION"]),
        "license": " / ".join(sorted(licenses)),
        "source": describe(source, args.repo, args.tag),
        "builds": builds,
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    (dist / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    files = sorted(p for p in dist.iterdir() if p.is_file() and p.name != "SHA256SUMS")
    (dist / "SHA256SUMS").write_text("".join(f"{sha256(p)}  {p.name}\n" for p in files))
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
