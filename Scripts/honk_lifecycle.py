#!/usr/bin/env python3
"""修正上游已知的 BusyBox 小数 timeout 轮询问题，不改核心与服务准入。"""

from pathlib import Path
import sys

LEGACY_PAUSE = '''# 启动轮询用 0.25 秒粒度，核心就绪后尽快返回；没有 timeout 命令时退回 1 秒。
honk_lifecycle_pause() {
	if [ -n "$HONK_LIFECYCLE_HAVE_TIMEOUT" ]; then
		timeout 0.25 sleep 1 2>/dev/null
		return 0
	fi
	sleep 1
}'''
PORTABLE_PAUSE = '''# 中文：BusyBox timeout 不支持小数；使用整数秒等待，并同步按秒扣减原启动预算。
honk_lifecycle_pause() {
	sleep 1
}'''
REPLACEMENTS = (
    ('HONK_LIFECYCLE_HAVE_TIMEOUT=$(command -v timeout 2>/dev/null)\n', ''),
    (LEGACY_PAUSE, PORTABLE_PAUSE),
    ('\thlp_tick=0\n', ''),
    ('\t\thonk_lifecycle_pause\n\t\thlp_tick=$((hlp_tick + 1))\n'
     '\t\t[ "$hlp_tick" -lt 4 ] || { hlp_tick=0; hlp_timeout=$((hlp_timeout - 1)); }',
     '\t\thonk_lifecycle_pause || return 1\n\t\thlp_timeout=$((hlp_timeout - 1))'),
)

# 中文：上游 2df7440 已按实际耗时选择轮询粒度；检测、调用和预算扣减必须配套。
UPSTREAM_FIXED_BLOCKS = (
    r'''HONK_LIFECYCLE_TICKS=1
honk_lifecycle_detect_pause() {
	HONK_LIFECYCLE_TICKS=1
	[ -n "$HONK_LIFECYCLE_HAVE_TIMEOUT" ] || return 0
	pause_before=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
	[ -n "$pause_before" ] || return 0
	timeout 0.25 sleep 1 2>/dev/null
	pause_after=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
	[ -n "$pause_after" ] || return 0
	awk -v a="$pause_before" -v b="$pause_after" 'BEGIN { exit (b - a >= 0.15) ? 0 : 1 }' && \
		HONK_LIFECYCLE_TICKS=4
	return 0
}
honk_lifecycle_detect_pause
''',
    '''honk_lifecycle_pause() {
	if [ "$HONK_LIFECYCLE_TICKS" -gt 1 ]; then
		timeout 0.25 sleep 1 2>/dev/null
		return 0
	fi
	sleep 1
}''',
    '\t\thonk_lifecycle_pause\n\t\thlp_tick=$((hlp_tick + 1))\n'
    '\t\t[ "$hlp_tick" -lt "$HONK_LIFECYCLE_TICKS" ] || { hlp_tick=0; hlp_timeout=$((hlp_timeout - 1)); }',
)


def patch_lifecycle(path):
    original = path.read_text(encoding="utf-8")
    if 'timeout 0.25 sleep 1' not in original:
        print("Honk lifecycle: known fractional-timeout bug absent; left unchanged.")
        return False
    if all(original.count(block) == 1 for block in UPSTREAM_FIXED_BLOCKS):
        print("Honk lifecycle: upstream measured-timeout fix verified; left unchanged.")
        return False
    # 中文：只修正已核验的上游结构；结构变化时暴露差异，绝不猜测修改运行逻辑。
    for old, _ in REPLACEMENTS:
        if original.count(old) != 1:
            raise ValueError("Honk lifecycle changed around fractional timeout; review upstream first")
    updated = original
    for old, new in REPLACEMENTS:
        updated = updated.replace(old, new)
    path.write_text(updated, encoding="utf-8", newline="\n")
    print("Honk lifecycle: fixed BusyBox polling; original startup budget preserved.")
    return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: honk_lifecycle.py <lifecycle.sh>")
    try:
        patch_lifecycle(Path(sys.argv[1]))
    except (OSError, ValueError) as error:
        sys.exit(f"Honk lifecycle patch failed: {error}")
