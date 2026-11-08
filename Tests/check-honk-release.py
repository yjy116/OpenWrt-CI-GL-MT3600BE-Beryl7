#!/usr/bin/env python3
"""验证正式版选择、同批来源和校验失败，不需要网络。"""

import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import honk_release as release
import honk_release_fixture as fixtures
from release_common import request_for


class HonkReleaseTests(unittest.TestCase):
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
        return release.validate_bundle(self.repo, self.bundle(), fixtures.PACKAGE_COMMIT)

    def update_manifest(self, field, value):
        url = f"{fixtures.REPO}/releases/download/{fixtures.TAG}/release-manifest.json"
        manifest = json.loads(self.data["urls"][url])
        manifest[field] = value
        payload = fixtures.encoded(manifest)
        self.data["urls"][url] = payload
        self.data["release"]["assets"] = [fixtures.asset("release-manifest.json", payload, fixtures.TAG)]
        self.data["urls"][f"{fixtures.API}/releases/tags/{fixtures.TAG}"] = fixtures.encoded(self.data["release"])

    def test_latest_is_resolved_again_each_time(self):
        self.assertEqual(release.SOURCE.latest_tag(self.fetch), fixtures.TAG)
        newer = dict(self.data["release"], tag_name="v2026.11.04-r42000000000")
        self.data["urls"][f"{fixtures.API}/releases/latest"] = fixtures.encoded(newer)
        self.assertEqual(release.SOURCE.latest_tag(self.fetch), newer["tag_name"])

    def test_draft_and_prerelease_are_rejected(self):
        for field in ("draft", "prerelease"):
            with self.subTest(field=field):
                candidate = dict(self.data["release"], **{field: True})
                self.data["urls"][f"{fixtures.API}/releases/latest"] = fixtures.encoded(candidate)
                with self.assertRaisesRegex(ValueError, "formal release"):
                    release.SOURCE.latest_tag(self.fetch)

    def test_same_day_revision_resolves_and_validates_the_matched_bundle(self):
        for tag in ("v2026.11.08-r2", "v2026.11.08.1-r1", "v2026.11.08.12-r3"):
            with self.subTest(tag=tag):
                self.data = fixtures.fixture(tag=tag)
                self.assertEqual(release.SOURCE.latest_tag(self.fetch), tag)
                bundle = release.load_bundle(tag, self.fetch)
                release.validate_bundle(self.repo, bundle, fixtures.PACKAGE_COMMIT)

    def test_same_day_revision_does_not_admit_prereleases_or_malformed_tags(self):
        for tag in ("v2026.11.08.1-r1", "v2026.11.08.1.2-r1",
                    "v2026.11.08.-r1", "v2026.11.08.fix-r1", "v2026.11.08.1-r1-rc1"):
            with self.subTest(tag=tag):
                self.data = fixtures.fixture(tag=tag)
                if tag == "v2026.11.08.1-r1":
                    candidate = dict(self.data["release"], prerelease=True)
                    self.data["urls"][f"{fixtures.API}/releases/latest"] = fixtures.encoded(candidate)
                with self.assertRaises(ValueError):
                    release.SOURCE.latest_tag(self.fetch)

    def test_candidate_and_unsafe_tags_are_rejected(self):
        for tag in ("candidate-r123", "source-123", "main", "v1/../../main"):
            with self.subTest(tag=tag):
                candidate = dict(self.data["release"], tag_name=tag)
                self.data["urls"][f"{fixtures.API}/releases/latest"] = fixtures.encoded(candidate)
                with self.assertRaises(ValueError):
                    release.SOURCE.latest_tag(self.fetch)

    def test_missing_latest_has_no_fallback(self):
        def failed_fetch(url):
            raise HTTPError(url, 404, "Not Found", {}, None)
        with self.assertRaises(HTTPError):
            release.SOURCE.latest_tag(failed_fetch)

    def test_formal_bundle_may_reference_source_prerelease(self):
        self.assertNotEqual(fixtures.TAG.split("-r")[-1], fixtures.SOURCE.split("-")[-1])
        self.validate()

    def test_package_commit_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "package commit"):
            release.validate_bundle(self.repo, self.bundle(), "d" * 40)

    def test_manifest_hash_mismatch_is_rejected(self):
        url = f"{fixtures.REPO}/releases/download/{fixtures.TAG}/release-manifest.json"
        self.data["urls"][url] += b" "
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.bundle()

    def test_missing_or_unverified_asset_is_rejected(self):
        for mode in ("missing", "digest", "url"):
            with self.subTest(mode=mode):
                data = copy.deepcopy(self.data["release"])
                if mode == "missing":
                    data["assets"] = []
                elif mode == "digest":
                    data["assets"][0]["digest"] = None
                else:
                    data["assets"][0]["browser_download_url"] = "https://example.org/asset"
                self.data["urls"][f"{fixtures.API}/releases/tags/{fixtures.TAG}"] = fixtures.encoded(data)
                with self.assertRaises(ValueError):
                    self.bundle()

    def test_metadata_tamper_is_rejected(self):
        for name in ("generated-stage.mk", "generated-doona-stage.mk", "generated-provenance.json"):
            with self.subTest(name=name):
                url = f"{fixtures.SOURCE_URL}/{name}"
                original = self.data["urls"][url]
                self.data["urls"][url] += b" "
                with self.assertRaisesRegex(ValueError, "SHA256"):
                    self.bundle()
                self.data["urls"][url] = original

    def test_wrong_source_or_doona_commit_is_rejected(self):
        for field in ("core_commit", "doona_commit"):
            with self.subTest(field=field):
                self.data = fixtures.fixture()
                self.update_manifest(field, "e" * 40)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_makefile_source_tag_mismatch_is_rejected(self):
        path = self.repo / "luci-app-honk/Makefile"
        path.write_text(self.data["files"]["luci-app-honk/Makefile"].replace(fixtures.SOURCE, "source-1"))
        with self.assertRaises(ValueError):
            self.validate()

    def test_archive_digest_mismatch_is_rejected(self):
        source = copy.deepcopy(self.data["source"])
        source["assets"][0]["digest"] = "sha256:" + "0" * 64
        self.data["urls"][f"{fixtures.API}/releases/tags/{fixtures.SOURCE}"] = fixtures.encoded(source)
        with self.assertRaises(ValueError):
            self.validate()

    def test_provenance_mismatch_is_rejected(self):
        bundle = self.bundle()
        bundle["files"]["honk/generated-provenance.json"] = fixtures.encoded({
            "core": {"repository": fixtures.CORE_REPO, "commit": "f" * 40}})
        with self.assertRaises(ValueError):
            release.validate_bundle(self.repo, bundle, fixtures.PACKAGE_COMMIT)

    def test_duplicate_assignments_are_rejected(self):
        with self.assertRaises(ValueError):
            release.assignments("CORE_COMMIT=abc\nCORE_COMMIT=def\n")

    def test_writes_replace_old_generated_files(self):
        bundle = self.bundle()
        path = self.repo / "honk/generated-stage.mk"
        path.write_text("stale data")
        release.write_metadata(self.repo, bundle)
        self.assertEqual(path.read_bytes(), bundle["files"]["honk/generated-stage.mk"])

    def test_redirect_does_not_send_token_to_asset_host(self):
        with patch.dict(os.environ, {"GH_TOKEN": "test"}):
            request = request_for(fixtures.API + "/releases/latest")
            asset_request = request_for(fixtures.SOURCE_URL + "/generated-stage.mk")
        self.assertEqual(request.get_header("Authorization"), "Bearer test")
        self.assertIsNone(asset_request.get_header("Authorization"))
        redirected = HTTPRedirectHandler().redirect_request(
            request, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/test")
        self.assertIsNone(redirected.get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
