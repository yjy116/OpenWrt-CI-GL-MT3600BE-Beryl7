#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manual_workflow="${project_root}/.github/workflows/MT3600BE.yml"
test_workflow="${project_root}/.github/workflows/MT3600BE-TEST.yml"
auto_workflow="${project_root}/.github/workflows/Auto-Build.yml"
mt76_link_id_patch="${project_root}/Patches/mt76-known-good/004-pass-link-id-to-beacon-template-helpers.patch"

# 中文：日常完整构建必须默认使用已验证 mt76；手动取消勾选仍可测试主线驱动。
grep -A4 '^      pin_mt76_known_good:' "${manual_workflow}" | grep -qx '        default: true'
grep -Fqx "      pin_mt76_known_good: \${{ github.event_name == 'workflow_dispatch' && inputs.pin_mt76_known_good || github.event_name == 'push' }}" "${manual_workflow}"
grep -A4 '^      pin_mt76_known_good:' "${test_workflow}" | grep -qx '        default: true'
grep -Fqx '      pin_mt76_known_good: true' "${auto_workflow}"

# 中文：稳定 mt76 必须适配当前 mac80211 模板接口要求的 link_id 参数。
test -f "${mt76_link_id_patch}"
grep -Fq 'ieee80211_get_fils_discovery_tmpl(hw, vif,' "${mt76_link_id_patch}"
grep -Fq 'ieee80211_get_unsol_bcast_probe_resp_tmpl(hw, vif,' "${mt76_link_id_patch}"
test "$(grep -Fc 'link_conf->link_id);' "${mt76_link_id_patch}")" -eq 2

printf '%s\n' '稳定 WiFi 默认策略检查通过。'
