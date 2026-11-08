"""离线模拟上游发布数据，仅供测试，不接入构建下载逻辑。"""

import hashlib
import json

REPO = "https://github.com/kenzok8/openwrt-honk"
API = "https://api.github.com/repos/kenzok8/openwrt-honk"
TAG = "v2026.11.03-r41604962306"
SOURCE = "source-41594075839"
PACKAGE_COMMIT = "a" * 40
CORE_COMMIT = "b" * 40
DOONA_COMMIT = "c" * 40
DOONA_ARCHIVE = "doona-test.tar.gz"
CORE_REPO = "https://github.com/daeuniverse/honk.git"
SOURCE_URL = f"{REPO}/releases/download/{SOURCE}"


def encoded(value):
    return json.dumps(value).encode()


def asset(name, payload, tag=SOURCE):
    return {"name": name, "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
            "browser_download_url": f"{REPO}/releases/download/{tag}/{name}"}


def fixture(tag=TAG):
    payloads = {DOONA_ARCHIVE: b"doona archive"}
    core_make = f"CORE_COMMIT:={CORE_COMMIT}\nHONK_SOURCE_TAG?={SOURCE}\n"
    stage = f"PKG_SOURCE_URL:={SOURCE_URL}/\n"
    for arch in ("x86_64", "aarch64", "armv7"):
        name = f"honk-core-{CORE_COMMIT}-{arch}.tar.gz"
        payloads[name] = arch.encode()
        digest = hashlib.sha256(payloads[name]).hexdigest()
        stage += f"HONK_ASSET_{arch.upper()}:={name}\nHONK_HASH_{arch.upper()}:={digest}\n"
        core_make += f"HONK_HASH_{arch.upper()}?={digest}\n"
    doona_hash = hashlib.sha256(payloads[DOONA_ARCHIVE]).hexdigest()
    doona_make = (f"HONK_SOURCE_TAG?={SOURCE}\nPKG_SOURCE:={DOONA_ARCHIVE}\n"
                  f"PKG_HASH:={doona_hash}\n")
    payloads["generated-stage.mk"] = stage.encode()
    payloads["generated-doona-stage.mk"] = (
        f"PKG_SOURCE:={DOONA_ARCHIVE}\nPKG_SOURCE_URL:={SOURCE_URL}\n"
        f"PKG_SOURCE_SUBDIR:=doona\nPKG_HASH:={doona_hash}\n").encode()
    payloads["generated-provenance.json"] = encoded({
        "core": {"commit": CORE_COMMIT, "repository": CORE_REPO, "version": "0.1.0"}})
    manifest = {"candidate_sha": PACKAGE_COMMIT, "source_tag": SOURCE,
                "core_commit": CORE_COMMIT, "doona_commit": DOONA_COMMIT,
                "doona_archive": DOONA_ARCHIVE, "doona_archive_sha256": doona_hash}
    manifest_data = encoded(manifest)
    release = {"tag_name": tag, "draft": False, "prerelease": False,
               "assets": [asset("release-manifest.json", manifest_data, tag)]}
    source = {"tag_name": SOURCE, "draft": False, "prerelease": True,
              "assets": [asset(name, payload) for name, payload in payloads.items()]}
    urls = {f"{SOURCE_URL}/{name}": payload for name, payload in payloads.items()}
    urls[f"{REPO}/releases/download/{tag}/release-manifest.json"] = manifest_data
    urls[f"{API}/releases/latest"] = encoded(release)
    urls[f"{API}/releases/tags/{tag}"] = encoded(release)
    urls[f"{API}/releases/tags/{SOURCE}"] = encoded(source)
    pins = (f"CORE_COMMIT={CORE_COMMIT}\nCORE_REPOSITORY={CORE_REPO}\n"
            f"DOONA_COMMIT={DOONA_COMMIT}\nDOONA_REPOSITORY=https://github.com/Zakkaus/doona.git\n"
            f"DOONA_VERSION=0.1.0-rc.5\nDOONA_ARCHIVE={DOONA_ARCHIVE}\n")
    files = {"ci/pins.env": pins, "honk/Makefile": core_make,
             "luci-app-honk/Makefile": doona_make}
    return {"urls": urls, "files": files, "release": release, "source": source}
