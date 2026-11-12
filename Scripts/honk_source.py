#!/usr/bin/env python3
"""验证 Honk 打包主线指定的核心、Doona 与素材；失败时不使用旧版兜底。"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
from release_common import ReleaseSource, assignments, fetch_url, read_assignments, require
from honk_lifecycle import patch_lifecycle

# 中文：只复用资产校验，不通过全仓库 Latest 选择核心或前端版本。
SOURCE = ReleaseSource("kenzok8/openwrt-honk", r"source-[0-9A-Za-z._-]+")
REPOSITORY = SOURCE.repository
API = SOURCE.api
METADATA_FILES = (
    "honk/generated-stage.mk",
    "honk/generated-provenance.json",
    "luci-app-honk/generated-doona-stage.mk",
)


def load_bundle(tag, fetch):
    require(re.fullmatch(SOURCE.tag_pattern, tag), "Invalid source bundle tag")
    source = json.loads(fetch(f"{API}/releases/tags/{tag}"))
    # 中文：Makefile 引用的 source-* 是素材批次，可以是预发布，不能改取全仓库 Latest。
    require(source["tag_name"] == tag and source.get("draft") is False,
            "Source bundle is missing or unpublished")
    files = {name: SOURCE.download_asset(source, Path(name).name, fetch=fetch) for name in METADATA_FILES}
    return {"tag": tag, "source": source, "files": files}


def validate_pins(repo, pins):
    for key in ("CORE_COMMIT", "DOONA_COMMIT"):
        require(re.fullmatch(r"[a-f0-9]{40}", pins[key]), f"Invalid upstream commit: {key}")
    for key in ("CORE_REPOSITORY", "DOONA_REPOSITORY"):
        require(re.fullmatch(r"https://github.com/[\w.-]+/[\w.-]+\.git", pins[key]),
                f"Invalid upstream source: {key}")
    require(pins["CORE_BRANCH"] == "main", "Expected main core lane, not a kernel-floor experiment")
    patch_path = (repo / pins["DOONA_PATCH"]).resolve()
    require(patch_path.is_relative_to(repo.resolve()), "Doona patch must be inside package checkout")
    require(hashlib.sha256(patch_path.read_bytes()).hexdigest() == pins["DOONA_PATCH_SHA256"],
            "Doona build patch SHA256 mismatch")


def validate_core(bundle, makefile, pins):
    stage = assignments(bundle["files"]["honk/generated-stage.mk"].decode())
    url = f"{REPOSITORY}/releases/download/{bundle['tag']}"
    require(stage["PKG_SOURCE_URL"].rstrip("/") == url, "Core source URL mismatch")
    require(makefile["CORE_COMMIT"] == pins["CORE_COMMIT"], "Core Makefile pin mismatch")
    for arch in ("X86_64", "AARCH64", "ARMV7"):
        name = f"honk-core-{pins['CORE_COMMIT']}-{arch.lower()}.tar.gz"
        require(stage[f"HONK_ASSET_{arch}"] == name, f"Core archive mismatch: {arch}")
        digest = SOURCE.asset(bundle["source"], name)["digest"].removeprefix("sha256:")
        require(stage[f"HONK_HASH_{arch}"] == makefile[f"HONK_HASH_{arch}"] == digest,
                f"Core archive SHA256 mismatch: {arch}")
    provenance = json.loads(bundle["files"]["honk/generated-provenance.json"])["core"]
    require(provenance["commit"] == pins["CORE_COMMIT"], "Core provenance commit mismatch")
    require(provenance["repository"] == pins["CORE_REPOSITORY"], "Core provenance repository mismatch")
    require(provenance["lane"] == "stable", "Core provenance lane mismatch")


def validate_doona(bundle, makefile, pins):
    stage = assignments(bundle["files"]["luci-app-honk/generated-doona-stage.mk"].decode())
    url = f"{REPOSITORY}/releases/download/{bundle['tag']}"
    require(stage["PKG_SOURCE_URL"].rstrip("/") == url, "Doona source URL mismatch")
    require(stage["PKG_SOURCE_SUBDIR"] == "doona", "Unexpected Doona archive directory")
    name = pins["DOONA_ARCHIVE"]
    require(stage["PKG_SOURCE"] == makefile["PKG_SOURCE"] == name, "Doona archive mismatch")
    digest = SOURCE.asset(bundle["source"], name)["digest"].removeprefix("sha256:")
    require(stage["PKG_HASH"] == makefile["PKG_HASH"] == digest,
            "Doona archive SHA256 mismatch")


def validate_doona_provenance(payload, pins):
    # 中文：只读取归档内的来源说明，不解压到文件系统，也不执行其中的脚本。
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        matches = [item for item in archive.getmembers() if item.name == "doona/SOURCE"]
        require(len(matches) == 1 and matches[0].isfile(), "Missing or invalid Doona SOURCE")
        with archive.extractfile(matches[0]) as source:
            lines = source.read().decode("utf-8").splitlines()
    provenance = {}
    for line in lines:
        key, separator, value = line.partition(": ")
        if not separator:
            continue
        require(key not in provenance, f"Duplicate Doona SOURCE field: {key}")
        provenance[key] = value
    for field, pin in (("Repository", "DOONA_REPOSITORY"), ("Commit", "DOONA_COMMIT"),
                       ("Version", "DOONA_VERSION"), ("Build patch SHA256", "DOONA_PATCH_SHA256")):
        require(provenance.get(field) == pins[pin], f"Doona SOURCE {field} mismatch")


def read_makefiles(repo):
    core_keys = ("CORE_COMMIT", "HONK_SOURCE_TAG", "HONK_HASH_X86_64",
                 "HONK_HASH_AARCH64", "HONK_HASH_ARMV7")
    doona_keys = ("HONK_SOURCE_TAG", "PKG_SOURCE", "PKG_HASH")
    core = read_assignments(repo / "honk/Makefile", core_keys)
    doona = read_assignments(repo / "luci-app-honk/Makefile", doona_keys)
    require(core["HONK_SOURCE_TAG"] == doona["HONK_SOURCE_TAG"], "Core/Doona source tag mismatch")
    return core, doona


def write_metadata(repo, bundle):
    # 中文：所有文件校验通过后再覆盖旧生成文件，避免 vendor 目录复用时混入旧批次。
    for name in METADATA_FILES:
        target = repo / name
        temporary = target.with_suffix(target.suffix + ".download")
        temporary.write_bytes(bundle["files"][name])
        temporary.replace(target)


def prepare(repo, expected_commit):
    require(re.fullmatch(r"[a-f0-9]{40}", expected_commit), "Invalid package commit")
    commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    require(commit == expected_commit, "Package checkout commit mismatch")
    pins = read_assignments(repo / "ci/pins.env")
    validate_pins(repo, pins)
    core, doona = read_makefiles(repo)
    bundle = load_bundle(core["HONK_SOURCE_TAG"], fetch_url)
    validate_core(bundle, core, pins)
    validate_doona(bundle, doona, pins)
    archive = SOURCE.download_asset(bundle["source"], pins["DOONA_ARCHIVE"], fetch=fetch_url)
    validate_doona_provenance(archive, pins)
    patch_lifecycle(repo / "honk/files/lifecycle.sh")
    write_metadata(repo, bundle)
    print(f"Verified Honk packaging main: {commit}")
    print(f"Honk source: {pins['CORE_REPOSITORY']} @ {pins['CORE_COMMIT']}")
    print(f"Doona source: {pins['DOONA_REPOSITORY']} @ {pins['DOONA_COMMIT']} ({pins['DOONA_VERSION']})")
    print(f"Verified source bundle: {bundle['tag']}; metadata/archive SHA256 matched")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare")
    preparation.add_argument("repo", type=Path)
    preparation.add_argument("commit")
    args = parser.parse_args()
    prepare(args.repo, args.commit)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        sys.exit(f"Honk main source verification failed: {error}")
