#!/bin/sh
# 中文：由三个 init 脚本在 rc.common 分发动作前载入，不替换核心进程或 procd 命令。

proxy_guard_error() {
	printf 'Proxy service conflict: %s\n' "$*" >&2
	logger -t proxy-service-guard "$*"
	return 1
}

proxy_peer_processes() {
	case "$1" in
		dae) pidof dae ;;
		daed) pidof daed daed-guard ;;
		honk) pidof honk-core ;;
	esac
}

proxy_check_peers() {
	local owner="$1" snapshot="$2" peer instances pids
	for peer in dae daed honk; do
		[ "$peer" != "$owner" ] || continue
		# 中文：保留实例即占用，包含尚未获得 PID、退出清理和等待 respawn 的时间窗口。
		# 中文：退出码 1 表示没有匹配实例/进程；JSON 语法已在进入循环前验证。
		instances="$(jsonfilter -s "$snapshot" -e "@[\"$peer\"].instances.*")" || [ "$?" -eq 1 ] || {
			proxy_guard_error "Cannot inspect $peer instances"; return 1;
		}
		pids="$(proxy_peer_processes "$peer")" || [ "$?" -eq 1 ] || {
			proxy_guard_error "Cannot inspect $peer processes"; return 1;
		}
		if [ -n "$instances$pids" ]; then
			proxy_guard_error "$owner refused: $peer owns proxy resources; stop $peer and wait for cleanup first."
			return 1
		fi
	done
}

proxy_lock_transaction() {
	local lock_file="$1" dependency
	for dependency in flock ubus jsonfilter pidof logger; do
		command -v "$dependency" >/dev/null || {
			proxy_guard_error "Required command missing: $dependency"; return 1;
		}
	done
	# 中文：FD 9 持锁到整个 init 进程退出，覆盖 procd 登记；不可放入子 shell 或提前解锁。
	exec 9>"$lock_file" || { proxy_guard_error "Cannot open $lock_file"; return 1; }
	flock -n 9 || { proxy_guard_error 'Proxy transaction busy; wait for the current service operation.'; return 1; }
}

proxy_guard_enter() {
	local owner="$1" action="$2" lock_file="${3:-/var/lock/mt3600be-proxy.lock}" snapshot
	case "$owner" in
		dae|daed|honk) ;;
		*) proxy_guard_error "Unknown backend: $owner"; return 1 ;;
	esac
	case "$action" in
		start|boot|restart|reload|hot_reload|stop|shutdown|trace) ;;
		*) return 0 ;;
	esac
	proxy_lock_transaction "$lock_file" || return 1
	snapshot="$(ubus call service list)" || { proxy_guard_error 'Cannot query procd through ubus'; return 1; }
	[ "$(jsonfilter -s "$snapshot" -t '@')" = object ] || {
		proxy_guard_error 'Invalid procd JSON response'; return 1;
	}
	proxy_check_peers "$owner" "$snapshot"
}
