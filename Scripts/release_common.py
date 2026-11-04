"""Honk 与 DAEDE 共用的正式发布、资产校验及纯文本配置解析。"""

from dataclasses import dataclass
import hashlib
import json
import os
import re
from urllib.request import Request, urlopen

REQUEST_TIMEOUT = 60


def require(condition, message):
    if not condition:
        raise ValueError(message)


def request_for(url):
    headers = {"User-Agent": "MT3600BE-release", "Cache-Control": "no-cache"}
    request = Request(url, headers=headers)
    # 中文：令牌仅发给 GitHub API，不发给资产下载主机，也不随重定向转发。
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/repos/"):
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    return request


def fetch_url(url):
    with urlopen(request_for(url), timeout=REQUEST_TIMEOUT) as response:
        return response.read()


@dataclass(frozen=True)
class ReleaseSource:
    slug: str
    tag_pattern: str

    @property
    def repository(self):
        return "https://github.com/" + self.slug

    @property
    def api(self):
        return "https://api.github.com/repos/" + self.slug

    def formal_tag(self, release):
        require(release.get("draft") is False and release.get("prerelease") is False,
                "Expected a published formal release, not a draft/prerelease")
        tag = release.get("tag_name", "")
        require(re.fullmatch(self.tag_pattern, tag), f"Unsupported formal release tag: {tag}")
        return tag

    def latest_tag(self, fetch):
        return self.formal_tag(json.loads(fetch(self.api + "/releases/latest")))

    def published_release(self, tag, fetch):
        require(re.fullmatch(self.tag_pattern, tag), f"Invalid formal release tag: {tag}")
        release = json.loads(fetch(f"{self.api}/releases/tags/{tag}"))
        require(self.formal_tag(release) == tag, "Release tag mismatch")
        return release

    def asset(self, release, name):
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name), "Invalid asset name")
        matches = [asset for asset in release["assets"] if asset["name"] == name]
        require(len(matches) == 1, f"Missing or duplicate release asset: {name}")
        asset = matches[0]
        digest = asset.get("digest") or ""
        require(re.fullmatch(r"sha256:[a-f0-9]{64}", digest), f"Missing SHA256: {name}")
        expected = f"{self.repository}/releases/download/{release['tag_name']}/{name}"
        require(asset["browser_download_url"] == expected, f"Unexpected asset URL: {name}")
        return asset

    def download_asset(self, release, name, *, fetch):
        asset = self.asset(release, name)
        payload = fetch(asset["browser_download_url"])
        require("sha256:" + hashlib.sha256(payload).hexdigest() == asset["digest"],
                f"SHA256 mismatch: {name}")
        return payload


def assignments(text, keys=None):
    values = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)\s*[:?]?=\s*(.*?)\s*", line)
        if not match or (keys is not None and match[1] not in keys):
            continue
        require(match[1] not in values, f"Duplicate assignment: {match[1]}")
        values[match[1]] = match[2]
    return values


def read_assignments(path, keys=None):
    return assignments(path.read_text(encoding="utf-8"), keys)
