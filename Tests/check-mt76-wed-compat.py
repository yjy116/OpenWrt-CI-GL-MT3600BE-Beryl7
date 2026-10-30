#!/usr/bin/env python3
"""用真实稳定 mt76 源码验证 PPE 补丁及新旧 WED 接口，不代表完整内核编译。"""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISION = "018f60316d4dd6b4e741874eda40e2dfaa29df3b"
PATCH = ROOT / "Patches/mt76-known-good/006-support-wed-ppe-station-index.patch"
COMMAND_TIMEOUT = 30


def run(args, directory):
    subprocess.run(args, cwd=directory, check=True, timeout=COMMAND_TIMEOUT)


def prepare_sources(directory):
    paths = set()
    for patch in sorted(PATCH.parent.glob("*.patch")):
        paths.update(re.findall(r"^--- a/(.+)$", patch.read_text(encoding="utf-8"), re.M))
    for path in sorted(paths):
        target = directory / path
        target.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://raw.githubusercontent.com/openwrt/mt76/{REVISION}/{path}"
        with urllib.request.urlopen(url, timeout=COMMAND_TIMEOUT) as response:
            target.write_bytes(response.read())


def compiler_command(options, file):
    if options.msvc:
        return [options.compiler, "/nologo", "/utf-8", "/WX", "/TC", "/c", str(file)]
    return [options.compiler, "-Werror", "-fsyntax-only", str(file)]


def apply_patches(directory):
    for patch in sorted(PATCH.parent.glob("*.patch")):
        # 中文：模拟 Linux checkout 的 LF，避免 Windows autocrlf 污染补丁上下文。
        normalized = directory / patch.name
        normalized.write_text(patch.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
        run(["git", "apply", "--check", "--whitespace=error-all", str(normalized)], directory)
        run(["git", "apply", "--whitespace=error-all", str(normalized)], directory)


def check_original_failure(options, directory):
    # 中文：原始源码必须在新接口上失败，避免测试没有覆盖本次实际错误。
    file = directory / "original.c"
    body = ppe_function(directory, "mt7996")
    file.write_text(TYPES + macro_header(True, True) + body, encoding="utf-8")
    result = subprocess.run(compiler_command(options, file), cwd=directory,
                            capture_output=True, timeout=COMMAND_TIMEOUT)
    if result.returncode == 0 or b"mtk_wed_device_ppe_check" not in result.stdout + result.stderr:
        raise AssertionError("未复现原始稳定 mt76 的 PPE 宏参数错误")
    print("已复现原始稳定 mt76 在五参数 PPE 接口上的失败。")


def ppe_function(directory, driver):
    source = (directory / driver / "mac.c").read_text(encoding="utf-8")
    pattern = rf"static void\n{driver}_wed_check_ppe\(.*?\n\}}"
    match = re.search(pattern, source, re.S)
    if not match:
        raise AssertionError(f"没有找到 {driver} 的真实 PPE 函数")
    return match.group()


# 中文：只替代与 ABI 无关的类型，调用体来自实际应用补丁后的上游源码。
TYPES = """
typedef unsigned int u32;
struct wireless_dev { void *netdev; };
struct ieee80211_vif { int drv_priv; };
struct sk_buff { void *dev; };
struct mt76_queue { int unused; };
struct wcid { unsigned short idx; };
struct mt7915_vif { struct ieee80211_vif *vif; };
struct mt7915_sta { struct mt7915_vif *vif; struct wcid wcid; };
struct mt7996_sta_link { struct wcid wcid; };
struct mt7996_sta { void *vif; int deflink_id; };
struct mt76_dev { struct { int wed; } mmio; };
struct mt7915_dev { struct mt76_dev mt76; };
struct mt7996_dev { struct mt76_dev mt76; };
struct wireless_dev *ieee80211_vif_to_wdev(struct ieee80211_vif *vif);
struct mt7996_sta_link *mt7996_sta_link(struct mt7996_sta *sta, int link);
int mt76_queue_is_wed_rx(struct mt76_queue *q);
#define container_of(ptr, type, field) ((type *)(ptr))
#define FIELD_GET(mask, value) (value)
#define MT_DMA_INFO_PPE_VLD 1
void check_old(int *, struct sk_buff *, u32, u32);
void check_new(int *, struct sk_buff *, u32, u32, unsigned short);
"""


def macro_header(new_api, enabled):
    marker = "#define mtk_wed_device_flow_flush(...) 0\n" if new_api else ""
    args = "dev, skb, reason, hash" + (", wcid" if new_api else "")
    call = f"check_{'new' if new_api else 'old'}({args})" if enabled else "do {} while (0)"
    return marker + f"#define mtk_wed_device_ppe_check({args}) {call}\n"


def check_abi(options, directory, driver):
    body = ppe_function(directory, driver)
    expected_wcid = "msta_link->wcid.idx" if driver == "mt7996" else "msta->wcid.idx"
    if expected_wcid not in body:
        raise AssertionError(f"{driver} 没有传递真实 WCID")
    for new_api in (False, True):
        for enabled in (False, True):
            file = directory / f"{driver}-{int(new_api)}-{int(enabled)}.c"
            header = macro_header(new_api, enabled)
            file.write_text(TYPES + header + body + "\n", encoding="utf-8")
            run(compiler_command(options, file), directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="cc")
    parser.add_argument("--msvc", action="store_true")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mt76-wed-abi-") as name:
        directory = Path(name)
        prepare_sources(directory)
        check_original_failure(options, directory)
        apply_patches(directory)
        for driver in ("mt7915", "mt7996"):
            check_abi(options, directory, driver)
    print("真实稳定 mt76 补丁及新旧 WED ABI 的 8 种组合检查通过。")


if __name__ == "__main__":
    main()
