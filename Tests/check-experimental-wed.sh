#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${project_root}/Scripts/Experimental-WED.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

# 中文：关闭实验功能时，不能改动构建树或要求额外配置。
PROJECT_ROOT="${project_root}"
BUILD_ROOT="${test_root}/disabled"
EXPERIMENTAL_MT7987_WED=0
install_experimental_wed
validate_experimental_wed_config
test ! -e "${BUILD_ROOT}"

# 中文：实验参数不完整或源码版本错误必须暴露错误，不能偷偷降级成普通版。
EXPERIMENTAL_MT7987_WED=1
PIN_MT76_KNOWN_GOOD=0
DEVICE_NAME=glinet_gl-mt3600be
REPO_REF=invalid
if (install_experimental_wed) > "${test_root}/invalid.log" 2>&1; then
  echo '错误：实验配置不匹配却继续安装补丁。'
  exit 1
fi
grep -q 'ERROR:' "${test_root}/invalid.log"
mkdir -p "${BUILD_ROOT}"
printf 'CONFIG_TARGET_mediatek_filogic_DEVICE_glinet_gl-mt3600be=y\n' > "${BUILD_ROOT}/.config"
if (validate_experimental_wed_config) > "${test_root}/missing.log" 2>&1; then
  echo '错误：WED 内核/驱动配置缺失却通过校验。'
  exit 1
fi
grep -q 'ERROR:' "${test_root}/missing.log"

# 中文：基线检查仍覆盖日常版，实验构建必须显式隔离缓存和 Release。
workflow="${project_root}/.github/workflows/MT3600BE-WED-EXPERIMENTAL.yml"
core="${project_root}/.github/workflows/WRT-CORE.yml"
grep -Fq 'experiment/mt7987-wed-6.18' "${workflow}"
grep -Fq 'experimental_mt7987_wed: true' "${workflow}"
grep -Fq 'publish_release: false' "${workflow}"
test "$(grep -Fc 'if: ${{ !inputs.experimental_mt7987_wed }}' "${core}")" -eq 2
test "$(grep -Fc 'if: ${{ always() && !inputs.experimental_mt7987_wed }}' "${core}")" -eq 2
test "$(grep -Fc 'if: ${{ !inputs.experimental_mt7987_wed && !inputs.test_only && inputs.publish_release }}' "${core}")" -eq 2
printf '%s\n' '实验 WED 关闭路径、错误显露和 CI 隔离检查通过。'
