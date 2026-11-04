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
for package in luci-app-dae luci-app-daed; do
  require_line "CONFIG_PACKAGE_${package}=n" "${general_config}"
done
require_line '# @vendor luci-app-honk|https://github.com/kenzok8/openwrt-honk.git|latest-stable|honk:package/honk;luci-app-honk:package/luci-app-honk|honk-release' "${general_config}"
test ! -e "${project_root}/files/lib/upgrade/keep.d/daed"
require_line '/etc/honk/' "${project_root}/files/lib/upgrade/keep.d/honk"

# 中文：Honk 自带中文翻译，不能凭 po 目录添加不存在的独立语言包。
source "${project_root}/Scripts/Settings.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
BUILD_ROOT="${test_dir}/source"
mkdir -p "${BUILD_ROOT}/package/luci-app-honk/po/zh-cn" "${BUILD_ROOT}/feeds"
mkdir -p "${BUILD_ROOT}/package/luci-app-daede/po/zh-cn"
cd "${test_dir}"
touch .config
append_auto_i18n_for_package luci-app-honk
append_auto_i18n_for_package luci-app-daede
test ! -s .config

# 中文：Honk 缺少运行依赖时沿用项目宽松模式，必须明确显示警告。
validate_honk_config_symbols "${general_config}" .config > missing-config.log
grep -Fq 'CONFIG_KERNEL_DEBUG_INFO_BTF=y' missing-config.log
grep -Fq 'CONFIG_PACKAGE_honk=y' missing-config.log
printf '%s\n' "${HONK_REQUIRED_CONFIG_SYMBOLS[@]}" > .config
test -z "$(validate_honk_config_symbols "${general_config}" .config)"

source "${project_root}/Scripts/Packages.sh"
# 中文：调用方检查返回值时 Bash 不会自动中止；fetch 失败不能继续使用旧 FETCH_HEAD。
(
  mkdir -p "${test_dir}/reused/.git"
  git() {
    case "$3" in
      fetch) return 128 ;;
      checkout) touch "${test_dir}/stale-checkout" ;;
    esac
  }
  if sync_git_repo https://github.com/kenzok8/openwrt-honk.git test-tag "${test_dir}/reused"; then
    echo 'Failed fetch was hidden by a stale checkout.' >&2
    exit 1
  fi
  test ! -e "${test_dir}/stale-checkout"
)

# 中文：可选真实上游源码验证；离线校验异常场景由 check-honk-release.py 覆盖。
if [[ -n "${HONK_SOURCE_DIR:-}" ]]; then
  sync_honk_release https://github.com/kenzok8/openwrt-honk.git latest-stable "${HONK_SOURCE_DIR}"
  grep -Fq 'honk.zh-cn.lmo' "${HONK_SOURCE_DIR}/luci-app-honk/Makefile"
  grep -Fq "option enabled '0'" "${HONK_SOURCE_DIR}/honk/files/honk.config"
  grep -Fq "option boot_enabled '0'" "${HONK_SOURCE_DIR}/honk/files/honk.config"
  grep -Fq 'for process in dae daed clashoo mihomo sing-box' "${HONK_SOURCE_DIR}/honk/files/control.sh"
  grep -Fq 'check_conflicts && check_port' "${HONK_SOURCE_DIR}/honk/files/control.sh"
fi

echo 'Honk/Doona package selection and integrated Chinese translation checks passed.'
