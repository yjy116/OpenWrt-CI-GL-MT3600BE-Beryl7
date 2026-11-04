"""DAEDE 正式发布的离线测试数据，不用于生产下载或失败兜底。"""

import hashlib
import json

REPO = "https://github.com/kenzok8/openwrt-daede"
API = "https://api.github.com/repos/kenzok8/openwrt-daede"
TAG = "v2026.10.30-6ac53cb"
COMMIT = "6ac53cb" + "a" * 33
VERSION = "2026.10.30"


def encoded(data):
    return json.dumps(data).encode()


def asset(name, payload, tag=TAG):
    return {"name": name, "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
            "browser_download_url": f"{REPO}/releases/download/{tag}/{name}"}


def fixture():
    records, assets, urls, files = [], [], {}, {}
    for package in ("dae", "daed", "luci-app-daede"):
        version = "1.15" if package == "luci-app-daede" else VERSION
        revision = "13" if package == "luci-app-daede" else "1"
        name = f"{package}-{version}-r{revision}-aarch64_cortex-a53.apk"
        binary = asset(name, package.encode())
        assets.append(binary)
        records.append({"path": "release/" + name, "sha256": binary["digest"][7:]})
        make = f"PKG_NAME:={package}\nPKG_VERSION:={version}\nPKG_RELEASE:={revision}\n"
        if package != "luci-app-daede":
            payload = f"{package} source archive".encode()
            digest = hashlib.sha256(payload).hexdigest()
            archive = f"{package}-src-{version}-{digest[:12]}.tar.gz"
            source = {"tag_name": package + "-src", "draft": False, "prerelease": False,
                      "assets": [asset(archive, payload, package + "-src")]}
            urls[f"{API}/releases/tags/{package}-src"] = encoded(source)
            make += (f"PKG_SOURCE:={archive}\nPKG_HASH:={digest}\n"
                     f"PKG_SOURCE_URL:={REPO}/releases/download/{package}-src\n")
        files[f"{package}/Makefile"] = make
    manifest = {"candidate_sha": COMMIT, "files": records}
    payload = encoded(manifest)
    assets.append(asset("manifest.json", payload))
    release = {"tag_name": TAG, "draft": False, "prerelease": False, "assets": assets}
    urls[f"{API}/releases/latest"] = encoded(release)
    urls[f"{API}/releases/tags/{TAG}"] = encoded(release)
    urls[f"{REPO}/releases/download/{TAG}/manifest.json"] = payload
    files["ci/pins.env"] = (f"DAE_VERSION={VERSION}\nDAED_VERSION={VERSION}\n"
                            + "\n".join(f"{key}={'b' * 40}" for key in
                                        ("CORE_COMMIT", "CORE_UPSTREAM_COMMIT", "DAED_COMMIT", "WING_COMMIT")))
    return {"urls": urls, "files": files, "manifest": manifest, "release": release}
