"""Honk 打包主线的离线数据，仅供来源校验测试。"""

import gzip
import hashlib
import io
import json
import tarfile

REPO = "https://github.com/kenzok8/openwrt-honk"
API = "https://api.github.com/repos/kenzok8/openwrt-honk"
SOURCE = "source-42975766273"
PACKAGE_COMMIT = "a" * 40
CORE_COMMIT = "b" * 40
DOONA_COMMIT = "c" * 40
DOONA_ARCHIVE = "doona-test.tar.gz"
CORE_REPO = "https://github.com/daeuniverse/honk.git"
DOONA_REPO = "https://github.com/Zakkaus/doona.git"
SOURCE_URL = f"{REPO}/releases/download/{SOURCE}"
PATCH = b"test patch"
PATCH_HASH = hashlib.sha256(PATCH).hexdigest()


def encoded(value):
    return json.dumps(value).encode()


def asset(name, payload, source_tag=SOURCE):
    return {"name": name, "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
            "browser_download_url": f"{REPO}/releases/download/{source_tag}/{name}"}


def doona_archive(source=None, *, member_type=tarfile.REGTYPE, copies=1):
    source = source if source is not None else (
        f"Repository: {DOONA_REPO}\nCommit: {DOONA_COMMIT}\nVersion: 0.1.0-rc.6\n"
        f"Build patch SHA256: {PATCH_HASH}\n")
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        member = tarfile.TarInfo("doona/SOURCE")
        member.type = member_type
        member.size = len(source.encode()) if member_type == tarfile.REGTYPE else 0
        member.linkname = "outside"
        for _ in range(copies):
            archive.addfile(member, io.BytesIO(source.encode()))
    return gzip.compress(output.getvalue(), mtime=0)


def core_payloads(source_tag=SOURCE):
    payloads = {}
    makefile = f"CORE_COMMIT:={CORE_COMMIT}\nHONK_SOURCE_TAG?={source_tag}\n"
    stage = f"PKG_SOURCE_URL:={REPO}/releases/download/{source_tag}/\n"
    for arch in ("x86_64", "aarch64", "armv7"):
        name = f"honk-core-{CORE_COMMIT}-{arch}.tar.gz"
        payloads[name] = arch.encode()
        digest = hashlib.sha256(payloads[name]).hexdigest()
        stage += f"HONK_ASSET_{arch.upper()}:={name}\nHONK_HASH_{arch.upper()}:={digest}\n"
        makefile += f"HONK_HASH_{arch.upper()}?={digest}\n"
    payloads["generated-stage.mk"] = stage.encode()
    payloads["generated-provenance.json"] = encoded({
        "core": {"commit": CORE_COMMIT, "repository": CORE_REPO, "lane": "stable"}})
    return payloads, makefile


def fixture(source_tag=SOURCE):
    payloads, core_make = core_payloads(source_tag)
    source_url = f"{REPO}/releases/download/{source_tag}"
    payloads[DOONA_ARCHIVE] = doona_archive()
    digest = hashlib.sha256(payloads[DOONA_ARCHIVE]).hexdigest()
    doona_make = (f"HONK_SOURCE_TAG?={source_tag}\nPKG_SOURCE:={DOONA_ARCHIVE}\nPKG_HASH:={digest}\n")
    payloads["generated-doona-stage.mk"] = (
        f"PKG_SOURCE:={DOONA_ARCHIVE}\nPKG_SOURCE_URL:={source_url}\n"
        f"PKG_SOURCE_SUBDIR:=doona\nPKG_HASH:={digest}\n").encode()
    source = {"tag_name": source_tag, "draft": False, "prerelease": True,
              "assets": [asset(name, value, source_tag) for name, value in payloads.items()]}
    urls = {f"{source_url}/{name}": value for name, value in payloads.items()}
    urls[f"{API}/releases/tags/{source_tag}"] = encoded(source)
    pins = (f"CORE_COMMIT={CORE_COMMIT}\nCORE_REPOSITORY={CORE_REPO}\nCORE_BRANCH=main\n"
            f"DOONA_COMMIT={DOONA_COMMIT}\nDOONA_REPOSITORY={DOONA_REPO}\n"
            f"DOONA_VERSION=0.1.0-rc.6\nDOONA_ARCHIVE={DOONA_ARCHIVE}\n"
            f"DOONA_PATCH=ci/patches/doona-openwrt.patch\nDOONA_PATCH_SHA256={PATCH_HASH}\n")
    files = {"ci/pins.env": pins, "honk/Makefile": core_make,
             "luci-app-honk/Makefile": doona_make, "ci/patches/doona-openwrt.patch": PATCH.decode(),
             "honk/files/lifecycle.sh": "#!/bin/sh\nhonk_lifecycle_pause() { sleep 1; }\n"}
    return {"urls": urls, "files": files, "source": source}
