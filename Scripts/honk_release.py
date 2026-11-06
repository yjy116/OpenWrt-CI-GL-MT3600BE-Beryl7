#!/usr/bin/env python3
"""解析 Honk 正式发布并验证同批核心、Doona 与源码；失败时不使用旧版兜底。"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from release_common import ReleaseSource, assignments, fetch_url, read_assignments, require
from honk_lifecycle import patch_lifecycle

SOURCE = ReleaseSource("kenzok8/openwrt-honk", r"v\d{4}\.\d{2}\.\d{2}-r\d+")
REPOSITORY = SOURCE.repository
API = SOURCE.api
METADATA_FILES = (
    "honk/generated-stage.mk",
    "honk/generated-provenance.json",
    "luci-app-honk/generated-doona-stage.mk",
)


def load_bundle(tag, fetch):
    release = SOURCE.published_release(tag, fetch)
    manifest = json.loads(SOURCE.download_asset(release, "release-manifest.json", fetch=fetch))
    source_tag = manifest["source_tag"]
    require(re.fullmatch(r"source-\d+", source_tag), "Invalid source bundle tag")
    source = json.loads(fetch(f"{API}/releases/tags/{source_tag}"))
    # 中文：正式包引用的 source-* 是素材批次，上游将它标为预发布；不能按正式标签后缀推算。
    require(source["tag_name"] == source_tag and source.get("draft") is False,
            "Source bundle is missing or unpublished")
    files = {name: SOURCE.download_asset(source, Path(name).name, fetch=fetch) for name in METADATA_FILES}
    return {"tag": tag, "manifest": manifest, "source": source, "files": files}


def validate_revision(pins, manifest, commit):
    require(re.fullmatch(r"[a-f0-9]{40}", manifest["candidate_sha"]), "Invalid package commit")
    require(commit == manifest["candidate_sha"], "Release package commit mismatch")
    for key in ("core", "doona"):
        value = manifest[f"{key}_commit"]
        require(re.fullmatch(r"[a-f0-9]{40}", value), f"Invalid {key} commit")
        require(pins[f"{key.upper()}_COMMIT"] == value, f"{key} pin/manifest mismatch")
    for key in ("CORE_REPOSITORY", "DOONA_REPOSITORY"):
        require(re.fullmatch(r"https://github.com/[\w.-]+/[\w.-]+\.git", pins[key]),
                f"Invalid upstream source: {key}")
    require(pins["DOONA_ARCHIVE"] == manifest["doona_archive"], "Doona archive pin mismatch")


def validate_core(bundle, makefile):
    manifest = bundle["manifest"]
    stage = assignments(bundle["files"]["honk/generated-stage.mk"].decode())
    url = f"{REPOSITORY}/releases/download/{manifest['source_tag']}"
    require(stage["PKG_SOURCE_URL"].rstrip("/") == url, "Core source URL mismatch")
    require(makefile["CORE_COMMIT"] == manifest["core_commit"], "Core Makefile pin mismatch")
    require(makefile["HONK_SOURCE_TAG"] == manifest["source_tag"], "Core source tag mismatch")
    for arch in ("X86_64", "AARCH64", "ARMV7"):
        name = f"honk-core-{manifest['core_commit']}-{arch.lower()}.tar.gz"
        require(stage[f"HONK_ASSET_{arch}"] == name, f"Core archive mismatch: {arch}")
        digest = SOURCE.asset(bundle["source"], name)["digest"].removeprefix("sha256:")
        require(stage[f"HONK_HASH_{arch}"] == makefile[f"HONK_HASH_{arch}"] == digest,
                f"Core archive SHA256 mismatch: {arch}")


def validate_doona(bundle, makefile):
    manifest = bundle["manifest"]
    stage = assignments(bundle["files"]["luci-app-honk/generated-doona-stage.mk"].decode())
    url = f"{REPOSITORY}/releases/download/{manifest['source_tag']}"
    require(stage["PKG_SOURCE_URL"].rstrip("/") == url, "Doona source URL mismatch")
    require(makefile["HONK_SOURCE_TAG"] == manifest["source_tag"], "Doona source tag mismatch")
    require(stage["PKG_SOURCE_SUBDIR"] == "doona", "Unexpected Doona archive directory")
    name = manifest["doona_archive"]
    require(stage["PKG_SOURCE"] == makefile["PKG_SOURCE"] == name, "Doona archive mismatch")
    digest = SOURCE.asset(bundle["source"], name)["digest"].removeprefix("sha256:")
    require(stage["PKG_HASH"] == makefile["PKG_HASH"] == manifest["doona_archive_sha256"] == digest,
            "Doona archive SHA256 mismatch")


def validate_bundle(repo, bundle, commit):
    pins = read_assignments(repo / "ci/pins.env")
    validate_revision(pins, bundle["manifest"], commit)
    core_keys = ("CORE_COMMIT", "HONK_SOURCE_TAG", "HONK_HASH_X86_64",
                 "HONK_HASH_AARCH64", "HONK_HASH_ARMV7")
    validate_core(bundle, read_assignments(repo / "honk/Makefile", core_keys))
    doona_keys = ("HONK_SOURCE_TAG", "PKG_SOURCE", "PKG_HASH")
    validate_doona(bundle, read_assignments(repo / "luci-app-honk/Makefile", doona_keys))
    provenance = json.loads(bundle["files"]["honk/generated-provenance.json"])["core"]
    require(provenance["commit"] == pins["CORE_COMMIT"], "Core provenance commit mismatch")
    require(provenance["repository"] == pins["CORE_REPOSITORY"], "Core provenance repository mismatch")
    return pins


def write_metadata(repo, bundle):
    # 中文：所有文件校验通过后再覆盖旧生成文件，避免 vendor 目录复用时混入旧批次。
    for name in METADATA_FILES:
        target = repo / name
        temporary = target.with_suffix(target.suffix + ".download")
        temporary.write_bytes(bundle["files"][name])
        temporary.replace(target)


def prepare(repo, tag):
    bundle = load_bundle(tag, fetch_url)
    commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    pins = validate_bundle(repo, bundle, commit)
    patch_lifecycle(repo / "honk/files/lifecycle.sh")
    write_metadata(repo, bundle)
    print(f"Verified Honk formal release: {tag} ({commit})")
    print(f"Honk source: {pins['CORE_REPOSITORY']} @ {pins['CORE_COMMIT']}")
    print(f"Doona source: {pins['DOONA_REPOSITORY']} @ {pins['DOONA_COMMIT']} ({pins['DOONA_VERSION']})")
    print(f"Verified source bundle: {bundle['manifest']['source_tag']}; metadata/archive SHA256 matched")


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
        sys.exit(f"Honk release verification failed: {error}")
