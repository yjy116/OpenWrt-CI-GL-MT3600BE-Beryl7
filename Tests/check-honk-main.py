#!/usr/bin/env python3
"""验证 main 快照及同批素材，不依赖全仓库 Latest 指针。"""

import contextlib
import hashlib
import io
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import honk_source as source
import honk_source_fixture as fixtures
from release_common import request_for


class HonkMainTests(unittest.TestCase):
    def setUp(self):
        self.data = fixtures.fixture()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        for name, content in self.data["files"].items():
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")

    def prepare(self, *, commit=fixtures.PACKAGE_COMMIT, fetch=None):
        output = io.StringIO()
        with patch.object(source, "fetch_url", side_effect=fetch or self.data["urls"].__getitem__), \
                patch.object(source.subprocess, "check_output", return_value=commit), \
                contextlib.redirect_stdout(output):
            source.prepare(self.repo, fixtures.PACKAGE_COMMIT)
        return output.getvalue()

    def change_file(self, name, old, new):
        path = self.repo / name
        path.write_text(path.read_text(encoding="utf-8").replace(old, new), encoding="utf-8")

    def test_main_snapshot_prepares_without_latest_or_formal_release(self):
        # 中文：测试 URL 仅包含当前源码引用的 source-*，查询 Latest 会直接失败。
        output = self.prepare()
        self.assertIn(fixtures.PACKAGE_COMMIT, output)
        self.assertIn(fixtures.CORE_COMMIT, output)
        self.assertIn(fixtures.DOONA_COMMIT, output)
        self.assertEqual((self.repo / "honk/generated-stage.mk").read_bytes(),
                         self.data["urls"][f"{fixtures.SOURCE_URL}/generated-stage.mk"])

    def test_checkout_mismatch_is_rejected_before_download(self):
        with self.assertRaisesRegex(ValueError, "commit mismatch"):
            self.prepare(commit="d" * 40, fetch=lambda _: self.fail("Unexpected download"))

    def test_source_tags_follow_upstream_safe_character_contract(self):
        for tag in ("source-42975766273-r2", "source-main.2026_11-12"):
            with self.subTest(tag=tag):
                self.data = fixtures.fixture(source_tag=tag)
                for name, content in self.data["files"].items():
                    (self.repo / name).write_text(content, encoding="utf-8")
                self.assertIn(tag, self.prepare())

    def test_non_source_or_unsafe_tag_is_rejected_before_download(self):
        for tag in ("main", "linux66-2026.11.09.1", "source-", "source-a/b", "source-a?x=1"):
            with self.subTest(tag=tag):
                with self.assertRaisesRegex(ValueError, "Invalid source bundle tag"):
                    source.load_bundle(tag, lambda _: self.fail("Unexpected download"))

    def test_mixed_source_batches_are_rejected(self):
        self.change_file("luci-app-honk/Makefile", fixtures.SOURCE, "source-1")
        with self.assertRaisesRegex(ValueError, "source tag mismatch"):
            self.prepare()

    def test_source_batch_must_be_published_and_match_requested_tag(self):
        for changes in ({"draft": True}, {"tag_name": "source-1"}):
            with self.subTest(changes=changes):
                self.data["urls"][f"{fixtures.API}/releases/tags/{fixtures.SOURCE}"] = fixtures.encoded(
                    dict(self.data["source"], **changes))
                with self.assertRaisesRegex(ValueError, "unpublished"):
                    self.prepare()

    def test_failed_download_does_not_use_stale_generated_files(self):
        stale = self.repo / "honk/generated-stage.mk"
        stale.write_bytes(b"stale")
        def unavailable(url):
            raise HTTPError(url, 404, "Not Found", {}, None)
        with self.assertRaises(HTTPError):
            self.prepare(fetch=unavailable)
        self.assertEqual(stale.read_bytes(), b"stale")

    def test_metadata_and_archive_tampering_are_rejected(self):
        for name in ("generated-stage.mk", "generated-doona-stage.mk",
                     "generated-provenance.json", fixtures.DOONA_ARCHIVE):
            with self.subTest(name=name):
                self.data = fixtures.fixture()
                self.data["urls"][f"{fixtures.SOURCE_URL}/{name}"] += b"tampered"
                with self.assertRaisesRegex(ValueError, "SHA256"):
                    self.prepare()

    def test_makefile_and_pin_mismatches_are_rejected(self):
        changes = (("honk/Makefile", fixtures.CORE_COMMIT, "d" * 40),
                   ("ci/pins.env", fixtures.DOONA_COMMIT, "d" * 40),
                   ("ci/pins.env", fixtures.CORE_REPO, "https://github.com/other/core.git"),
                   ("ci/pins.env", fixtures.DOONA_REPO, "https://github.com/other/ui.git"),
                   ("ci/pins.env", "CORE_BRANCH=main", "CORE_BRANCH=kernel-floor-6.6"),
                   ("ci/patches/doona-openwrt.patch", "test patch", "changed patch"))
        for name, old, new in changes:
            with self.subTest(name=name, old=old):
                path = self.repo / name
                original = path.read_bytes()
                self.change_file(name, old, new)
                with self.assertRaises(ValueError):
                    self.prepare()
                path.write_bytes(original)

    def test_different_archive_hash_in_makefile_is_rejected(self):
        digest = hashlib.sha256(self.data["urls"][f"{fixtures.SOURCE_URL}/{fixtures.DOONA_ARCHIVE}"]).hexdigest()
        self.change_file("luci-app-honk/Makefile", digest, "0" * 64)
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.prepare()

    def test_unverified_release_asset_is_rejected(self):
        for field, value in (("digest", None), ("browser_download_url", "https://example.org/file")):
            with self.subTest(field=field):
                self.data = fixtures.fixture()
                self.data["source"]["assets"][0][field] = value
                self.data["urls"][f"{fixtures.API}/releases/tags/{fixtures.SOURCE}"] = fixtures.encoded(self.data["source"])
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_valid_metadata_replaces_stale_files(self):
        path = self.repo / "honk/generated-stage.mk"
        path.write_bytes(b"stale")
        self.prepare()
        self.assertEqual(path.read_bytes(), self.data["urls"][f"{fixtures.SOURCE_URL}/generated-stage.mk"])

    def test_core_provenance_must_match_pins_and_standard_lane(self):
        bundle = source.load_bundle(fixtures.SOURCE, self.data["urls"].__getitem__)
        pins = source.read_assignments(self.repo / "ci/pins.env")
        core, _ = source.read_makefiles(self.repo)
        valid = {"commit": fixtures.CORE_COMMIT, "repository": fixtures.CORE_REPO, "lane": "stable"}
        for field, value in (("commit", "d" * 40), ("repository", fixtures.DOONA_REPO), ("lane", "linux66")):
            with self.subTest(field=field):
                bundle["files"]["honk/generated-provenance.json"] = fixtures.encoded({
                    "core": dict(valid, **{field: value})})
                with self.assertRaisesRegex(ValueError, "provenance"):
                    source.validate_core(bundle, core, pins)

    def test_doona_source_must_match_all_selected_pins(self):
        pins = source.read_assignments(self.repo / "ci/pins.env")
        for key in ("DOONA_COMMIT", "DOONA_REPOSITORY", "DOONA_VERSION", "DOONA_PATCH_SHA256"):
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, "Doona SOURCE"):
                    source.validate_doona_provenance(fixtures.doona_archive(), dict(pins, **{key: "different"}))

    def test_doona_source_must_be_unique_regular_file(self):
        pins = source.read_assignments(self.repo / "ci/pins.env")
        for options in ({"copies": 0}, {"copies": 2}, {"member_type": tarfile.SYMTYPE}):
            with self.subTest(options=options):
                with self.assertRaisesRegex(ValueError, "Doona SOURCE"):
                    source.validate_doona_provenance(fixtures.doona_archive(**options), pins)
        with self.assertRaisesRegex(ValueError, "Duplicate Doona"):
            source.validate_doona_provenance(fixtures.doona_archive("Commit: a\nCommit: b\n"), pins)

    def test_duplicate_pins_and_external_patch_path_are_rejected(self):
        self.change_file("ci/pins.env", "CORE_BRANCH=main", "CORE_BRANCH=main\nCORE_BRANCH=other")
        with self.assertRaisesRegex(ValueError, "Duplicate assignment"):
            self.prepare()
        self.change_file("ci/pins.env", "CORE_BRANCH=main\nCORE_BRANCH=other", "CORE_BRANCH=main")
        self.change_file("ci/pins.env", "ci/patches/doona-openwrt.patch", "../outside.patch")
        with self.assertRaisesRegex(ValueError, "inside package checkout"):
            self.prepare()

    def test_redirect_does_not_send_token_to_asset_host(self):
        with patch.dict(os.environ, {"GH_TOKEN": "test"}):
            request = request_for(fixtures.API + "/releases/tags/" + fixtures.SOURCE)
            asset_request = request_for(fixtures.SOURCE_URL + "/generated-stage.mk")
        self.assertEqual(request.get_header("Authorization"), "Bearer test")
        self.assertIsNone(asset_request.get_header("Authorization"))
        redirected = HTTPRedirectHandler().redirect_request(
            request, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/test")
        self.assertIsNone(redirected.get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
