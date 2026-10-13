#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
general_config="${project_root}/Config/GENERAL.txt"

require_line() {
  local expected="$1" file="$2"
  grep -Fqx "${expected}" "${file}" || {
    echo "Missing required line in ${file}: ${expected}" >&2
    exit 1
  }
}

require_line 'CONFIG_PACKAGE_honk=y' "${general_config}"
require_line 'CONFIG_PACKAGE_luci-app-honk=y' "${general_config}"
for package in dae daed luci-app-dae luci-app-daed luci-app-daede; do
  require_line "CONFIG_PACKAGE_${package}=n" "${general_config}"
done
require_line '# @vendor luci-app-honk|https://github.com/kenzok8/openwrt-honk.git|v2026.10.12-r38236606118|honk:package/honk;luci-app-honk:package/luci-app-honk|honk-release' "${general_config}"
test ! -e "${project_root}/files/lib/upgrade/keep.d/daed"
require_line '/etc/honk/' "${project_root}/files/lib/upgrade/keep.d/honk"

# 中文：Honk 自带中文翻译，不能凭 po 目录添加不存在的独立语言包。
source "${project_root}/Scripts/Settings.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
BUILD_ROOT="${test_dir}/source"
mkdir -p "${BUILD_ROOT}/package/luci-app-honk/po/zh-cn" "${BUILD_ROOT}/feeds"
cd "${test_dir}"
touch .config
append_auto_i18n_for_package luci-app-honk
test ! -s .config

# 中文：旧后端不再选择；Honk 缺少运行依赖时沿用项目宽松模式，必须明确显示警告。
validate_honk_config_symbols "${general_config}" .config > missing-config.log
grep -Fq 'CONFIG_KERNEL_DEBUG_INFO_BTF=y' missing-config.log
grep -Fq 'CONFIG_PACKAGE_honk=y' missing-config.log
printf '%s\n' "${HONK_REQUIRED_CONFIG_SYMBOLS[@]}" > .config
test -z "$(validate_honk_config_symbols "${general_config}" .config)"

# 中文：可选真实上游源码验证；CI 在 Packages.sh 中始终执行元数据校验。
if [[ -n "${HONK_SOURCE_DIR:-}" ]]; then
  source "${project_root}/Scripts/Honk.sh"
  prepare_honk_source "${HONK_SOURCE_DIR}"
  grep -Fq 'HONK_HASH_AARCH64:=2d27b44969a5e6517484d92c503b5d9fd3a43b43fa3b094a165ff6513a5c2657' "${HONK_SOURCE_DIR}/honk/generated-stage.mk"
  grep -Fq 'honk.zh-cn.lmo' "${HONK_SOURCE_DIR}/luci-app-honk/Makefile"
  grep -Fq "option enabled '0'" "${HONK_SOURCE_DIR}/honk/files/honk.config"
  grep -Fq "option boot_enabled '0'" "${HONK_SOURCE_DIR}/honk/files/honk.config"
  grep -Fq 'for process in dae daed clashoo mihomo sing-box' "${HONK_SOURCE_DIR}/honk/files/control.sh"
  grep -Fq 'check_conflicts && check_port' "${HONK_SOURCE_DIR}/honk/files/control.sh"

  # 中文：错配源码或错误哈希必须暴露失败，不允许使用旧文件伪装成功。
  if (HONK_PACKAGE_COMMIT=invalid; prepare_honk_source "${HONK_SOURCE_DIR}") > wrong-revision.log 2>&1; then
    echo 'Mismatched Honk source revision was accepted.' >&2
    exit 1
  fi
  grep -Fq 'revision does not match' wrong-revision.log
  if fetch_honk_metadata "${test_dir}/generated-stage.mk" "$(printf '%064d' 0)" > wrong-hash.log 2>&1; then
    echo 'Invalid Honk metadata checksum was accepted.' >&2
    exit 1
  fi
  grep -Fq 'FAILED' wrong-hash.log
  test ! -e "${test_dir}/generated-stage.mk"
fi

echo 'Honk/Doona package selection and integrated Chinese translation checks passed.'
