#!/bin/sh
# 中文：摘录上游 b970dce 的等待逻辑；仅将核心就绪探测替换为外部输入的时间点。
HONK_LIFECYCLE_HAVE_TIMEOUT=$(command -v timeout 2>/dev/null)

# 启动轮询用 0.25 秒粒度，核心就绪后尽快返回；没有 timeout 命令时退回 1 秒。
honk_lifecycle_pause() {
	if [ -n "$HONK_LIFECYCLE_HAVE_TIMEOUT" ]; then
		timeout 0.25 sleep 1 2>/dev/null
		return 0
	fi
	sleep 1
}

poll_until_ready() {
	hlp_timeout=$1
	hlp_tick=0
	while [ "$hlp_timeout" -gt 0 ]; do
		[ "$SECONDS" -lt "$READY_AT" ] || return 0
		honk_lifecycle_pause
		hlp_tick=$((hlp_tick + 1))
		[ "$hlp_tick" -lt 4 ] || { hlp_tick=0; hlp_timeout=$((hlp_timeout - 1)); }
	done
	return 1
}
