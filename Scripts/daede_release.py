#!/usr/bin/env python3
"""按同一个正式标签获取 DAE、DAED、DAEDE 并核验发布清单及源码归档。"""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

from release_common import ReleaseSource, fetch_url, read_assignments, require

SOURCE = ReleaseSource("kenzok8/openwrt-daede", r"v\d{4}\.\d{2}\.\d{2}-[a-f0-9]{7,40}")
PACKAGES = ("dae", "daed", "luci-app-daede")
CORE_PINS = ("CORE_COMMIT", "CORE_UPSTREAM_COMMIT", "DAED_COMMIT", "WING_COMMIT")
MAKE_KEYS = ("PKG_NAME", "PKG_VERSION", "PKG_RELEASE", "PKG_SOURCE", "PKG_SOURCE_URL", "PKG_HASH")


def load_bundle(tag, fetch):
    release = SOURCE.published_release(tag, fetch)
    manifest = json.loads(SOURCE.download_asset(release, "manifest.json", fetch=fetch))
    sources = {}
    for backend in ("dae", "daed"):
        source_tag = backend + "-src"
        source = json.loads(fetch(f"{SOURCE.api}/releases/tags/{source_tag}"))
        require(source.get("tag_name") == source_tag and source.get("draft") is False,
                f"Source bundle is missing or unpublished: {source_tag}")
        sources[backend] = source
    return {"tag": tag, "release": release, "manifest": manifest, "sources": sources}


def validate_package(makefile, bundle):
    name = makefile["PKG_NAME"]
    version = f"{makefile['PKG_VERSION']}-r{makefile['PKG_RELEASE']}"
    prefix = re.escape(name)
    version_pattern = re.escape(version)
    pattern = rf"{prefix}(?:-{version_pattern}-[\w.+-]+\.apk|_{version_pattern}_[\w.+-]+\.ipk)"
    entries = [entry for entry in bundle["manifest"]["files"]
               if PurePosixPath(entry["path"]).parent.as_posix() == "release"
               and re.fullmatch(pattern, PurePosixPath(entry["path"]).name)]
    require(entries, f"Missing release manifest package: {name} {version}")
    paths = [entry["path"] for entry in entries]
    require(len(set(paths)) == len(paths), f"Duplicate release manifest package: {name}")
    for entry in entries:
        asset = SOURCE.asset(bundle["release"], PurePosixPath(entry["path"]).name)
        require(asset["digest"] == "sha256:" + entry["sha256"], f"Package SHA256 mismatch: {name}")
    return version


def validate_archive(makefile, bundle, pins):
    name = makefile["PKG_NAME"]
    require(makefile["PKG_VERSION"] == pins[f"{name.upper()}_VERSION"], f"Backend pin mismatch: {name}")
    digest = makefile["PKG_HASH"]
    require(re.fullmatch(r"[a-f0-9]{64}", digest), f"Invalid source SHA256: {name}")
    expected_url = f"{SOURCE.repository}/releases/download/{name}-src"
    require(makefile["PKG_SOURCE_URL"].rstrip("/") == expected_url, f"Unexpected source URL: {name}")
    archive = SOURCE.asset(bundle["sources"][name], makefile["PKG_SOURCE"])
    require(archive["digest"] == "sha256:" + digest, f"Source archive SHA256 mismatch: {name}")


def validate_bundle(repo, bundle, commit):
    expected = bundle["manifest"]["candidate_sha"]
    require(re.fullmatch(r"[a-f0-9]{40}", expected) and commit == expected,
            "Release package commit mismatch")
    pins = read_assignments(repo / "ci/pins.env")
    for key in CORE_PINS:
        require(re.fullmatch(r"[a-f0-9]{40}", pins[key]), f"Invalid DAEDE source pin: {key}")
    packages = {}
    for package in PACKAGES:
        makefile = read_assignments(repo / package / "Makefile", MAKE_KEYS)
        require(makefile["PKG_NAME"] == package, f"Package identity mismatch: {package}")
        packages[package] = validate_package(makefile, bundle)
        if package in ("dae", "daed"):
            validate_archive(makefile, bundle, pins)
    return pins, packages


def prepare(repo, tag):
    bundle = load_bundle(tag, fetch_url)
    commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    pins, packages = validate_bundle(repo, bundle, commit)
    print(f"Verified DAE/DAED/DAEDE formal release: {tag} ({commit})")
    for name, version in packages.items():
        print(f"Verified release package: {name} {version}")
    for key in CORE_PINS:
        print(f"Verified DAEDE source {key}={pins[key]}")
    print("DAE/DAED source archive SHA256 matched release assets and tagged Makefiles.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("resolve")
    preparation = commands.add_parser("prepare")
    preparation.add_argument("repo", type=Path)
    preparation.add_argument("tag")
    args = parser.parse_args()
    if args.command == "resolve":
        print(SOURCE.latest_tag(fetch_url))
    else:
        prepare(args.repo, args.tag)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        sys.exit(f"DAEDE release verification failed: {error}")
