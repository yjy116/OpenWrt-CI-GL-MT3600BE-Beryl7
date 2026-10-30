#!/usr/bin/env python3
"""对真实源码应用实验补丁并核对 WED 接口；不替代内核编译和实机测试。"""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PATCH_ROOT = ROOT / "Patches/wed-experimental"
OPENWRT = "5700101d7c85381889d890dc1d3d001d0b4b6446"
MT76 = "018f60316d4dd6b4e741874eda40e2dfaa29df3b"
LINUX = "v6.18.55"
TIMEOUT = 60
WED_DIR = "drivers/net/ethernet/mediatek/"
WED_HEADER = "include/linux/soc/mediatek/mtk_wed.h"
KERNEL_FILES = [WED_DIR + name for name in (
    "mtk_wed.c", "mtk_wed.h", "mtk_wed_regs.h", "mtk_wed_debugfs.c",
    "mtk_wed_mcu.c", "mtk_wed_wo.c", "mtk_wed_wo.h",
)] + [WED_HEADER]


def run(command, directory):
    return subprocess.run(command, cwd=directory, check=True, timeout=TIMEOUT,
                          capture_output=True, text=True, encoding="utf-8").stdout


def fetch(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
        destination.write_bytes(response.read())


def apply_patch(directory, patch, includes=()):
    normalized = directory / "input.patch"
    normalized.write_text(patch.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
    options = [f"--include={path}" for path in includes]
    run(["git", "apply", "--check", *options, str(normalized)], directory)
    run(["git", "apply", *options, str(normalized)], directory)
    normalized.unlink()


def prepare_kernel(directory, openwrt):
    actual = run(["git", "rev-parse", "HEAD"], openwrt).strip()
    if actual != OPENWRT:
        raise AssertionError(f"OpenWrt 版本不匹配：{actual}")
    for name in KERNEL_FILES:
        fetch(f"https://raw.githubusercontent.com/gregkh/linux/{LINUX}/{name}", directory / name)
    patch_dirs = [f"target/linux/generic/{kind}-6.18" for kind in ("backport", "pending", "hack")]
    patch_dirs += ["target/linux/mediatek/patches-6.18"]
    for folder in patch_dirs:
        for patch in sorted((openwrt / folder).glob("*.patch")):
            if (PATCH_ROOT / "kernel" / patch.name).exists():
                continue
            touched = set(re.findall(r"^\+\+\+ b/(.+)$", patch.read_text(encoding="utf-8"), re.M))
            selected = sorted(touched.intersection(KERNEL_FILES))
            if selected:
                apply_patch(directory, patch, selected)
    for patch in sorted((PATCH_ROOT / "kernel").glob("*.patch")):
        apply_patch(directory, patch)


def prepare_mt76(directory, openwrt):
    # 中文：与构建树复制顺序一致，不能遗漏 OpenWrt 自带的无线补丁。
    patch_dirs = [openwrt / "package/kernel/mt76/patches",
                  ROOT / "Patches/mt76-known-good", PATCH_ROOT / "mt76"]
    by_name = {patch.name: patch for folder in patch_dirs for patch in folder.glob("*.patch")}
    patches = [by_name[name] for name in sorted(by_name)]
    paths = set()
    for patch in patches:
        paths.update(re.findall(r"^--- a/(.+)$", patch.read_text(encoding="utf-8"), re.M))
    for name in sorted(paths):
        fetch(f"https://raw.githubusercontent.com/openwrt/mt76/{MT76}/{name}", directory / name)
    for patch in patches:
        apply_patch(directory, patch)


def check_register_definitions(kernel):
    texts = [(kernel / name).read_text(encoding="utf-8") for name in KERNEL_FILES]
    source = "\n".join(texts)
    uses = set(re.findall(r"\bMTK_(?:WED|WDMA)_[A-Z0-9_]+", source))
    definitions = set(re.findall(r"^\s*#define\s+(MTK_\w+)", source, re.M))
    definitions.update(re.findall(r"^\s*(MTK_\w+)\s*(?:=|,|$)", source, re.M))
    missing = uses - definitions
    if missing:
        raise AssertionError(f"缺失 WED/WDMA 寄存器定义：{sorted(missing)}")


def check_abi(kernel, mt76):
    header = (kernel / WED_HEADER).read_text(encoding="utf-8")
    source = (kernel / WED_DIR / "mtk_wed.c").read_text(encoding="utf-8")
    for marker in ("get_hw_version", "rro_3_1_rx_ring_setup", "MTK_WED_HW_V3_1",
                   "MTK_WED_HWRRO_V3_1", "wpdma_tx[MTK_WED_TX_QUEUES]", "flow_flush"):
        if marker not in header:
            raise AssertionError(f"内核 WED ABI 缺失：{marker}")
    if "MTK_WED_TX_BM_PKT_CNT_V3_1(dev)" not in source:
        raise AssertionError("TX BM 没有与稳定驱动的 token 数量匹配")
    for driver in ("mt7915", "mt7996"):
        mmio = (mt76 / driver / "mmio.c").read_text(encoding="utf-8")
        mac = (mt76 / driver / "mac.c").read_text(encoding="utf-8")
        if "wed->wlan.wpdma_tx =" in mmio:
            raise AssertionError(f"{driver} 仍使用旧标量 TX 地址")
        if "mtk_wed_device_flow_flush" not in mac:
            raise AssertionError(f"{driver} 的五参数 PPE 接口保护丢失")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openwrt-tree", type=Path, required=True)
    parser.add_argument("--compiler", default="cc")
    parser.add_argument("--msvc", action="store_true")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mt7987-wed-source-") as name:
        root = Path(name)
        kernel, mt76 = root / "kernel", root / "mt76"
        kernel.mkdir()
        mt76.mkdir()
        prepare_kernel(kernel, options.openwrt_tree.resolve())
        print("Linux 6.18.55 + OpenWrt 补丁 + WED 实验补丁应用通过。", flush=True)
        prepare_mt76(mt76, options.openwrt_tree.resolve())
        check_register_definitions(kernel)
        check_abi(kernel, mt76)
        cleanup = [sys.executable, str(ROOT / "Tests/check-wed-cleanup.py"),
                   "--source", str(kernel / WED_DIR / "mtk_wed.c"),
                   "--compiler", options.compiler]
        if options.msvc:
            cleanup.append("--msvc")
        subprocess.run(cleanup, check=True, timeout=TIMEOUT)
        print("稳定 mt76 配套补丁、寄存器定义及关键 ABI 检查通过；尚不代表编译或硬件验证。")


if __name__ == "__main__":
    main()
