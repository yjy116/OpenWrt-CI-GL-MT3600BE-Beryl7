#!/usr/bin/env python3
"""以真实等待验证 BusyBox 小数 timeout 失败时不会提前耗尽启动预算。"""

import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import honk_release as release
import honk_release_fixture as fixtures

FIXTURE = Path(__file__).resolve().parent / "fixtures/honk-polling.sh"


class HonkLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.data = fixtures.fixture()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        for name, content in self.data["files"].items():
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        self.lifecycle = self.repo / "honk/files/lifecycle.sh"
        self.lifecycle.parent.mkdir(parents=True, exist_ok=True)
        self.lifecycle.write_bytes(FIXTURE.read_bytes())

    def prepare(self):
        with patch.object(release, "fetch_url", side_effect=self.data["urls"].__getitem__), \
                patch.object(release.subprocess, "check_output", return_value=fixtures.PACKAGE_COMMIT), \
                contextlib.redirect_stdout(io.StringIO()):
            release.prepare(self.repo, fixtures.TAG)

    def poll(self, ready_at, fail_sleep=False):
        # 中文：只替换 BusyBox 不支持小数的命令边界；sleep 使用真实系统等待。
        script = '''
timeout() { return 1; }
source ./honk/files/lifecycle.sh
SECONDS=0
if [ "$FAIL_SLEEP" = 1 ]; then sleep() { return 1; }; fi
poll_until_ready 3
'''
        start = time.monotonic()
        result = subprocess.run([os.environ.get("TEST_BASH", "bash"), "-c", script],
                                cwd=self.repo, env=dict(os.environ, READY_AT=str(ready_at),
                                                       FAIL_SLEEP=str(int(fail_sleep))),
                                capture_output=True, text=True, timeout=10)
        return result, time.monotonic() - start

    def test_core_ready_after_two_seconds_can_start(self):
        self.prepare()
        result, elapsed = self.poll(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(elapsed, 1.8)

    def test_failed_core_waits_the_original_budget(self):
        self.prepare()
        result, elapsed = self.poll(100)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertGreaterEqual(elapsed, 2.8)
        self.assertLess(elapsed, 6)

    def test_repeated_prepare_does_not_change_a_fixed_script(self):
        self.prepare()
        fixed = self.lifecycle.read_bytes()
        self.prepare()
        self.assertEqual(self.lifecycle.read_bytes(), fixed)

    def test_upstream_without_the_bug_is_not_rewritten(self):
        upstream = b'#!/bin/sh\nhonk_lifecycle_pause() { sleep 1; }\n'
        self.lifecycle.write_bytes(upstream)
        self.prepare()
        self.assertEqual(self.lifecycle.read_bytes(), upstream)

    def test_changed_buggy_structure_fails_without_partial_write(self):
        changed = self.lifecycle.read_text(encoding="utf-8").replace('"$hlp_tick" -lt 4',
                                                                      '"$hlp_tick" -lt 5')
        self.lifecycle.write_text(changed, encoding="utf-8")
        original = self.lifecycle.read_bytes()
        with self.assertRaisesRegex(ValueError, "review upstream"):
            self.prepare()
        self.assertEqual(self.lifecycle.read_bytes(), original)

    def test_sleep_failure_is_reported_not_hidden(self):
        self.prepare()
        result, elapsed = self.poll(2, fail_sleep=True)
        self.assertEqual(result.returncode, 1)
        self.assertLess(elapsed, 1.8)


if __name__ == "__main__":
    unittest.main()
