#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cpuusage_script="${project_root}/files/sbin/cpuusage"
defaults_file="${project_root}/files/etc/uci-defaults/99-beryl7-defaults"
general_config="${project_root}/Config/GENERAL.txt"
settings_script="${project_root}/Scripts/Settings.sh"
ready_root="$(mktemp -d)"
unavailable_root="$(mktemp -d)"

cleanup() {
	rm -f "${ready_root}/ppe0/bind" "${ready_root}/ppe1/bind"
	rm -f "${ready_root}/wed_enable" "${ready_root}/conntrack"
	rmdir "${ready_root}/ppe0" 2>/dev/null || true
	rmdir "${ready_root}/ppe1" 2>/dev/null || true
	rmdir "${ready_root}" 2>/dev/null || true
	rmdir "${unavailable_root}" 2>/dev/null || true
}

trap cleanup EXIT

mkdir "${ready_root}/ppe0" "${ready_root}/ppe1"
printf '%s\n' \
	'00001 BND IPv4 5T orig=192.168.18.100:12345->1.1.1.1:443' \
	'00002 UNB IPv4 5T orig=192.168.18.101:12346->8.8.8.8:443' \
	> "${ready_root}/ppe0/bind"
printf '%s\n' \
	'00003 BND IPv6 5T orig=2001:db8::1:12347->2606:4700:4700::1111:443' \
	> "${ready_root}/ppe1/bind"

ready_status="$(PPE_DEBUGFS_ROOT="${ready_root}" sh "${cpuusage_script}" --ppe-status)"
test "${ready_status}" = 'Ready (2 Bound)'

: > "${ready_root}/ppe0/bind"
: > "${ready_root}/ppe1/bind"
zero_status="$(PPE_DEBUGFS_ROOT="${ready_root}" sh "${cpuusage_script}" --ppe-status)"
test "${zero_status}" = 'Ready (0 Bound)'

unavailable_status="$(PPE_DEBUGFS_ROOT="${unavailable_root}" sh "${cpuusage_script}" --ppe-status)"
test "${unavailable_status}" = 'Unavailable'

# 中文：WED 参数只是请求开关，不能当作挂接成功或实际流量命中。
printf 'N\n' > "${ready_root}/wed_enable"
test "$(WED_PARAMETER_FILE="${ready_root}/wed_enable" sh "${cpuusage_script}" --wed-status)" = 'Disabled'
printf 'Y\n' > "${ready_root}/wed_enable"
test "$(WED_PARAMETER_FILE="${ready_root}/wed_enable" sh "${cpuusage_script}" --wed-status)" = 'Requested'
test "$(WED_PARAMETER_FILE="${unavailable_root}/wed_enable" sh "${cpuusage_script}" --wed-status)" = 'Unavailable'
printf 'invalid\n' > "${ready_root}/wed_enable"
test "$(WED_PARAMETER_FILE="${ready_root}/wed_enable" sh "${cpuusage_script}" --wed-status)" = 'Unknown'

# 中文：缺少 conntrack 统计接口时不能声称硬件流为零。
test "$(CONNTRACK_FILE="${unavailable_root}/conntrack" sh "${cpuusage_script}" --conntrack-status)" = 'Software Flows Unavailable | Hardware Flows Unavailable'
# 中文：即使路径可读，实际读取失败也必须是未知状态而不是零命中。
test "$(CONNTRACK_FILE="${unavailable_root}" sh "${cpuusage_script}" --conntrack-status)" = 'Software Flows Unavailable | Hardware Flows Unavailable'
printf '%s\n' 'ipv4 2 tcp 6 [OFFLOAD]' 'ipv4 2 udp 17 [OFFLOAD] [HW_OFFLOAD]' > "${ready_root}/conntrack"
test "$(CONNTRACK_FILE="${ready_root}/conntrack" sh "${cpuusage_script}" --conntrack-status)" = 'Software Flows 1 | Hardware Flows 1'
: > "${ready_root}/conntrack"
test "$(CONNTRACK_FILE="${ready_root}/conntrack" sh "${cpuusage_script}" --conntrack-status)" = 'Software Flows 0 | Hardware Flows 0'

# 中文：有线 PPE 的内核模块与防火墙硬件卸载默认值必须保持启用。
grep -Fqx 'CONFIG_PACKAGE_kmod-nft-offload=y' "${general_config}"
grep -Fqx "set firewall.@defaults[0].flow_offloading='1'" "${defaults_file}"
grep -Fqx "set firewall.@defaults[0].flow_offloading_hw='1'" "${defaults_file}"

# 中文：不要为了增加 WiFi 流量的 PPE 命中数而重新强制开启不稳定的 WED。
if grep -R -Fq 'wed_enable=Y' "${project_root}/files"; then
	echo '检测到强制启用 mt7996 WED，可能重新引入 WiFi 假死。'
	exit 1
fi

# 中文：状态名称必须区分配置状态、软件流、硬件流和 PPE 实际绑定流。
grep -Fq "Connections %s | HW Offload %s | Software Flows %s | Hardware Flows %s | PPE %s" "${cpuusage_script}"
grep -Fq '| WiFi WED %s' "${cpuusage_script}"
grep -Fq "Ready (%s Bound)" "${cpuusage_script}"
grep -Fq "Unavailable" "${cpuusage_script}"

# 中文：不存在的 debugfs 通配路径不能再由 awk 静默转换成零命中。
grep -Fq '[ -r "${ppe_file}" ] || continue' "${cpuusage_script}"

# 中文：组合两个现有的 LuCI 翻译词条，使标题跟随系统语言切换。
grep -Fq "_('CPU usage (%)') + ' / ' + _('Hardware flow offloading')" "${defaults_file}"
test "$(grep -Fc 'Hardware flow offloading' "${defaults_file}")" -eq 2
grep -Fq 'CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y' "${settings_script}"

printf '%s\n' 'PPE 状态显示检查通过。'
