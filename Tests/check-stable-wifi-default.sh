#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manual_workflow="${project_root}/.github/workflows/MT3600BE.yml"
test_workflow="${project_root}/.github/workflows/MT3600BE-TEST.yml"
auto_workflow="${project_root}/.github/workflows/Auto-Build.yml"
mt76_link_id_patch="${project_root}/Patches/mt76-known-good/004-pass-link-id-to-beacon-template-helpers.patch"
mt76_action_frame_patch="${project_root}/Patches/mt76-known-good/005-update-action-frame-api.patch"
stable_wifi_description='        description: "使用已验证的稳定版 mt76 WiFi 驱动（推荐；取消勾选则使用 OpenWrt 主线驱动）"'

# 中文：日常完整构建必须默认使用已验证 mt76；手动取消勾选仍可测试主线驱动。
grep -A4 '^      pin_mt76_known_good:' "${manual_workflow}" | grep -qx '        default: true'
grep -Fqx "      pin_mt76_known_good: \${{ github.event_name == 'workflow_dispatch' && inputs.pin_mt76_known_good || github.event_name == 'push' }}" "${manual_workflow}"
grep -A4 '^      pin_mt76_known_good:' "${test_workflow}" | grep -qx '        default: true'
grep -Fqx '      pin_mt76_known_good: true' "${auto_workflow}"

# 中文：引号可防止 YAML 把说明中的特殊字符当作注释，两个运行页面必须显示完整标签。
grep -Fqx "${stable_wifi_description}" "${manual_workflow}"
grep -Fqx "${stable_wifi_description}" "${test_workflow}"

# 中文：普通运行页面只保留源码分支、可选引用和稳定 WiFi 三项；高级二分参数不再干扰日常使用。
manual_inputs="$(sed -n '/^    inputs:/,/^  push:/p' "${manual_workflow}")"
test_inputs="$(sed -n '/^    inputs:/,/^permissions:/p' "${test_workflow}")"
test "$(printf '%s\n' "${manual_inputs}" | grep -Ec '^      [a-z0-9_]+:$')" -eq 3
test "$(printf '%s\n' "${test_inputs}" | grep -Ec '^      [a-z0-9_]+:$')" -eq 3

for removed_input in feeds_profile mt76_source_date mt76_source_version mt76_mirror_hash mt76_apply_known_good_patches cleanup_runner publish_release; do
	if printf '%s\n' "${manual_inputs}" | grep -Eq "^      ${removed_input}:$"; then
		echo "MT3600BE 运行页面仍包含无用选项：${removed_input}"
		exit 1
	fi
	if printf '%s\n' "${test_inputs}" | grep -Eq "^      ${removed_input}:$"; then
		echo "MT3600BE-TEST 运行页面仍包含无用选项：${removed_input}"
		exit 1
	fi
done

# 中文：隐藏选项改为流程固定策略，完整构建发布，测试构建不发布。
grep -Fqx '      feeds_profile: immortalwrt-compatible' "${manual_workflow}"
grep -Fqx '      cleanup_runner: true' "${manual_workflow}"
grep -Fqx '      publish_release: true' "${manual_workflow}"
grep -Fqx '      feeds_profile: immortalwrt-compatible' "${test_workflow}"
grep -Fqx '      cleanup_runner: true' "${test_workflow}"
grep -Fqx '      publish_release: false' "${test_workflow}"

# 中文：稳定 mt76 必须适配当前 mac80211 模板接口要求的 link_id 参数。
test -f "${mt76_link_id_patch}"
grep -Fq 'ieee80211_get_fils_discovery_tmpl(hw, vif,' "${mt76_link_id_patch}"
grep -Fq 'ieee80211_get_unsol_bcast_probe_resp_tmpl(hw, vif,' "${mt76_link_id_patch}"
test "$(grep -Fc 'link_conf->link_id);' "${mt76_link_id_patch}")" -eq 2

# 中文：完整回移植 action frame API 变更，避免公共 connac 代码随后再次编译失败。
test -f "${mt76_action_frame_patch}"
grep -Fq 'd49721c205c457bcff30ad8609663e9c965ff05d' "${mt76_action_frame_patch}"
grep -Fq -- '--- a/mt76_connac_mac.c' "${mt76_action_frame_patch}"
grep -Fq -- '--- a/mt7925/mac.c' "${mt76_action_frame_patch}"
grep -Fq -- '--- a/mt7996/mac.c' "${mt76_action_frame_patch}"
grep -Fq 'IEEE80211_MIN_ACTION_SIZE(action_code)' "${mt76_action_frame_patch}"
grep -Fq 'mgmt->u.action.action_code == WLAN_ACTION_ADDBA_REQ' "${mt76_action_frame_patch}"

printf '%s\n' '稳定 WiFi 默认策略检查通过。'
