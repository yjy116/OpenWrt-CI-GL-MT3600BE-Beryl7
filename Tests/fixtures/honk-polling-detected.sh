#!/bin/sh
# 中文：摘录上游 2df7440 的检测和轮询；仅将核心就绪探测替换为时间点。
HONK_LIFECYCLE_HAVE_TIMEOUT=$(command -v timeout 2>/dev/null)

HONK_LIFECYCLE_TICKS=1
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

honk_lifecycle_pause() {
	if [ "$HONK_LIFECYCLE_TICKS" -gt 1 ]; then
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
		[ "$hlp_tick" -lt "$HONK_LIFECYCLE_TICKS" ] || { hlp_tick=0; hlp_timeout=$((hlp_timeout - 1)); }
	done
	return 1
}
