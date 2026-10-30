#!/usr/bin/env python3
"""抽取真实 WED 分配/回收函数，编译并执行主机故障注入测试。"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
TIMEOUT = 60
FUNCTIONS = ("mtk_wed_amsdu_buffer_alloc", "mtk_wed_amsdu_free_buffer",
             "mtk_wed_rx_buffer_alloc", "mtk_wed_free_rx_buffer")


def extract_functions(source):
    result = []
    for name in FUNCTIONS:
        match = re.search(rf"static (?:int|void)\n{name}\(.*?\n\}}", source, re.S)
        if not match:
            raise AssertionError(f"未找到真实函数 {name}")
        result.append(match.group())
    return "\n\n".join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--compiler", default="cc")
    parser.add_argument("--msvc", action="store_true")
    options = parser.parse_args()
    functions = extract_functions(options.source.read_text(encoding="utf-8"))
    fixture = (ROOT / "fixtures/wed-cleanup-harness.c").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="wed-cleanup-") as name:
        directory = Path(name)
        source, executable = directory / "test.c", directory / "test.exe"
        source.write_text(fixture.replace("/* WED_FUNCTIONS */", functions), encoding="utf-8")
        if options.msvc:
            # 中文：Windows long 为 32 位，测试页句柄始终为 1..4，不执行真实指针截断。
            command = [options.compiler, "/nologo", "/utf-8", "/WX", "/wd4311", "/wd4312",
                       "/TC", str(source), f"/Fe:{executable}"]
        else:
            command = [options.compiler, "-Werror", str(source), "-o", str(executable)]
        subprocess.run(command, cwd=directory, check=True, timeout=TIMEOUT)
        subprocess.run([str(executable)], cwd=directory, check=True, timeout=TIMEOUT)
    print("WED 分配失败、重复释放和 RX 失败传播的主机测试通过。")


if __name__ == "__main__":
    main()
