#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manual_workflow="${project_root}/.github/workflows/MT3600BE.yml"
test_workflow="${project_root}/.github/workflows/MT3600BE-TEST.yml"
auto_workflow="${project_root}/.github/workflows/Auto-Build.yml"

# 中文：日常完整构建必须默认使用已验证 mt76；手动取消勾选仍可测试主线驱动。
grep -A4 '^      pin_mt76_known_good:' "${manual_workflow}" | grep -qx '        default: true'
grep -Fqx "      pin_mt76_known_good: \${{ github.event_name == 'workflow_dispatch' && inputs.pin_mt76_known_good || github.event_name == 'push' }}" "${manual_workflow}"
grep -A4 '^      pin_mt76_known_good:' "${test_workflow}" | grep -qx '        default: true'
grep -Fqx '      pin_mt76_known_good: true' "${auto_workflow}"

printf '%s\n' '稳定 WiFi 默认策略检查通过。'
