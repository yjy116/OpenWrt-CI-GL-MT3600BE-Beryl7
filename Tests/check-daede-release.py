#!/usr/bin/env python3
"""检查 DAE/DAED/DAEDE 整套正式版、来源匹配和显式失败。"""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.error import HTTPError

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import daede_release as release
import daede_release_fixture as fixtures


class DaedeReleaseTests(unittest.TestCase):
    def setUp(self):
        self.data = fixtures.fixture()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        for name, content in self.data["files"].items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def fetch(self, url):
        return self.data["urls"][url]

    def bundle(self):
        return release.load_bundle(fixtures.TAG, self.fetch)

    def validate(self):
        return release.validate_bundle(self.repo, self.bundle(), fixtures.COMMIT)

    def rewrite(self, name, replacement):
        path = self.repo / name
        path.write_text(replacement(path.read_text(encoding="utf-8")), encoding="utf-8")

    def replace_manifest(self, manifest):
        payload = fixtures.encoded(manifest)
        url = f"{fixtures.REPO}/releases/download/{fixtures.TAG}/manifest.json"
        self.data["urls"][url] = payload
        response = dict(self.data["release"], assets=[a for a in self.data["release"]["assets"]
                                                    if a["name"] != "manifest.json"])
        response["assets"].append(fixtures.asset("manifest.json", payload))
        self.data["urls"][f"{fixtures.API}/releases/tags/{fixtures.TAG}"] = fixtures.encoded(response)

    def test_latest_queried_on_every_call(self):
        self.assertEqual(release.SOURCE.latest_tag(self.fetch), fixtures.TAG)
        response = dict(self.data["release"], tag_name="v2026.11.04-abcdef0")
        self.data["urls"][f"{fixtures.API}/releases/latest"] = fixtures.encoded(response)
        self.assertEqual(release.SOURCE.latest_tag(self.fetch), response["tag_name"])

    def test_drafts_candidates_and_source_tags_are_not_formal(self):
        variants = ({"draft": True}, {"prerelease": True}, {"tag_name": "candidate-123"},
                    {"tag_name": "dae-src"}, {"tag_name": "main"}, {"tag_name": "v1/../main"})
        for variant in variants:
            with self.subTest(variant=variant):
                response = dict(self.data["release"], **variant)
                self.data["urls"][f"{fixtures.API}/releases/latest"] = fixtures.encoded(response)
                with self.assertRaises(ValueError):
                    release.SOURCE.latest_tag(self.fetch)

    def test_api_failure_does_not_fall_back(self):
        def unavailable(url):
            raise HTTPError(url, 503, "Unavailable", {}, None)
        with self.assertRaises(HTTPError):
            release.SOURCE.latest_tag(unavailable)

    def test_tag_selection_is_not_repeated_during_validation(self):
        del self.data["urls"][f"{fixtures.API}/releases/latest"]
        pins, packages = self.validate()
        self.assertEqual(pins["DAE_VERSION"], fixtures.VERSION)
        self.assertEqual(set(packages), {"dae", "daed", "luci-app-daede"})

    def test_package_commit_mismatch_fails(self):
        with self.assertRaisesRegex(ValueError, "package commit"):
            release.validate_bundle(self.repo, self.bundle(), "d" * 40)

    def test_manifest_digest_mismatch_fails(self):
        self.data["urls"][f"{fixtures.REPO}/releases/download/{fixtures.TAG}/manifest.json"] += b" "
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.bundle()

    def test_missing_or_wrong_package_entries_fail(self):
        for package in ("dae", "daed", "luci-app-daede"):
            with self.subTest(package=package):
                manifest = dict(self.data["manifest"], files=[f for f in self.data["manifest"]["files"]
                                                           if not f["path"].startswith(f"release/{package}-")])
                self.replace_manifest(manifest)
                with self.assertRaisesRegex(ValueError, "manifest package"):
                    self.validate()

    def test_manifest_package_digest_mismatch_fails(self):
        manifest = dict(self.data["manifest"], files=[dict(f, sha256="0" * 64)
                                                    for f in self.data["manifest"]["files"]])
        self.replace_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.validate()

    def test_luci_version_from_other_release_fails(self):
        self.rewrite("luci-app-daede/Makefile", lambda text: text.replace("PKG_RELEASE:=13", "PKG_RELEASE:=99"))
        with self.assertRaisesRegex(ValueError, "manifest package"):
            self.validate()

    def test_backend_version_must_match_pins(self):
        self.rewrite("ci/pins.env", lambda text: text.replace("DAED_VERSION=" + fixtures.VERSION, "DAED_VERSION=2000.01.01"))
        with self.assertRaisesRegex(ValueError, "pin"):
            self.validate()

    def test_core_pins_must_be_complete_commits(self):
        self.rewrite("ci/pins.env", lambda text: text.replace("CORE_COMMIT=" + "b" * 40, "CORE_COMMIT=main"))
        with self.assertRaisesRegex(ValueError, "pin"):
            self.validate()

    def test_source_archive_hash_skip_is_rejected(self):
        self.rewrite("dae/Makefile", lambda text: "\n".join("PKG_HASH:=SKIP" if line.startswith("PKG_HASH:=")
                                                          else line for line in text.splitlines()))
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.validate()

    def test_source_archive_digest_mismatch_fails(self):
        url = f"{fixtures.API}/releases/tags/daed-src"
        source = json.loads(self.data["urls"][url])
        source["assets"][0]["digest"] = "sha256:" + "0" * 64
        self.data["urls"][url] = fixtures.encoded(source)
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.validate()

    def test_source_url_cannot_switch_to_other_source(self):
        self.rewrite("daed/Makefile", lambda text: text.replace("download/daed-src", "download/dae-src"))
        with self.assertRaisesRegex(ValueError, "source URL"):
            self.validate()

    def test_missing_or_unpublished_source_bundle_fails(self):
        url = f"{fixtures.API}/releases/tags/dae-src"
        source = json.loads(self.data["urls"][url])
        source["draft"] = True
        self.data["urls"][url] = fixtures.encoded(source)
        with self.assertRaises(ValueError):
            self.bundle()

    def test_duplicate_manifest_package_is_rejected(self):
        manifest = dict(self.data["manifest"], files=self.data["manifest"]["files"] * 2)
        self.replace_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
