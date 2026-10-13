#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${project_root}/Scripts/Packages.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
BUILD_ROOT="${test_dir}/source"

for backend in dae daed honk; do
  config_package_enabled "${backend}"
  init_file="${BUILD_ROOT}/package/${backend}/files/${backend}.init"
  mkdir -p "$(dirname "${init_file}")"
  cp "${project_root}/Tests/fixtures/proxy.init" "${init_file}"
done
config_package_enabled luci-app-daede
config_package_enabled luci-app-honk
config_package_enabled flock
grep -Fqx CONFIG_DAE_USE_KERNEL_BTF=y "${GENERAL_CONFIG_FILE}"
grep -Fqx CONFIG_DAED_USE_KERNEL_BTF=y "${GENERAL_CONFIG_FILE}"
grep -Fqx CONFIG_PACKAGE_vmlinux-btf=n "${GENERAL_CONFIG_FILE}"

prepare_proxy_services
for backend in dae daed honk; do
  init_file="${BUILD_ROOT}/package/${backend}/files/${backend}.init"
  cp "${init_file}" "${test_dir}/${backend}.once"
  patch_proxy_service "${backend}" "${init_file}"
  cmp "${test_dir}/${backend}.once" "${init_file}"
  bash -n "${init_file}"
  # 中文：只有运行类动作加载 guard，构建包时 enable 不依赖尚未合入 rootfs 的 overlay。
  action=enable source "${init_file}"
  test "$(grep -Fc 'proxy_guard_enter' "${init_file}")" == 1
done
printf 'unexpected init layout\n' > "${test_dir}/invalid.init"
if patch_proxy_service dae "${test_dir}/invalid.init" > "${test_dir}/error" 2>&1; then
  echo 'Unknown upstream init layout was accepted.' >&2
  exit 1
fi
grep -Fq 'Unsupported dae init layout' "${test_dir}/error"

# 中文：默认值脚本保留数据库，仅关掉服务和自启；测试用临时路径，不操作宿主服务。
mkdir -p "${test_dir}/etc/init.d"
for backend in dae daed honk; do
  printf '#!/bin/sh\n[ "$1" = disable ]\n' > "${test_dir}/etc/init.d/${backend}"
  chmod +x "${test_dir}/etc/init.d/${backend}"
done
sed "s|/etc/init.d|${test_dir}/etc/init.d|g" \
  "${project_root}/files/etc/uci-defaults/99-proxy-backends-disabled" > "${test_dir}/defaults"
uci() { printf '%s\n' "$*" >> "${test_dir}/uci.log"; }
(source "${test_dir}/defaults")
for setting in dae.config.enabled daed.config.enabled honk.main.enabled honk.main.boot_enabled; do
  grep -Fqx "set ${setting}=0" "${test_dir}/uci.log"
done
test "$(grep -c '^commit ' "${test_dir}/uci.log")" == 3

# 中文：可选真实上游校验，构建入口也始终执行来源检查和服务补丁。
if [[ -n "${DAEDE_SOURCE_DIR:-}" ]]; then
  validate_daede_source "${DAEDE_SOURCE_DIR}"
  for backend in dae daed; do
    cp "${DAEDE_SOURCE_DIR}/${backend}/files/${backend}.init" "${test_dir}/${backend}.real"
    patch_proxy_service "${backend}" "${test_dir}/${backend}.real"
    bash -n "${test_dir}/${backend}.real"
  done
fi
if [[ -n "${HONK_SOURCE_DIR:-}" ]]; then
  cp "${HONK_SOURCE_DIR}/honk/files/honk.init" "${test_dir}/honk.real"
  patch_proxy_service honk "${test_dir}/honk.real"
  grep -Fq 'procd_set_param command /usr/bin/honk-core' "${test_dir}/honk.real"
  bash -n "${test_dir}/honk.real"
fi
if [[ "${VERIFY_PROXY_VENDORS:-0}" == 1 ]]; then
  # 中文：真实拉取两套 vendor 并重复准备，验证入口接线而非只测试单个补丁函数。
  awk '/^# @vendor luci-app-(honk|daede)\|/ || /^CONFIG_PACKAGE_(honk|dae|daed|luci-app-honk|luci-app-daede)=y$/' \
    "${GENERAL_CONFIG_FILE}" > "${test_dir}/proxy-general.txt"
  GENERAL_CONFIG_FILE="${test_dir}/proxy-general.txt"
  VENDOR_ROOT="${test_dir}/vendor"
  WRT_THEME=bootstrap
  mkdir -p "${BUILD_ROOT}/feeds/packages/net/dae" "${BUILD_ROOT}/feeds/luci/applications/luci-app-daed"
  prepare_custom_packages
  prepare_custom_packages
  test ! -e "${BUILD_ROOT}/feeds/packages/net/dae"
  test ! -e "${BUILD_ROOT}/feeds/luci/applications/luci-app-daed"
  test -s "${BUILD_ROOT}/package/vmlinux-btf/Makefile"
  for backend in dae daed honk; do
    init_file="${BUILD_ROOT}/package/${backend}/files/${backend}.init"
    test "$(grep -Fc 'proxy_guard_enter' "${init_file}")" == 1
    bash -n "${init_file}"
  done
fi
echo 'Proxy package selection, init patching and disabled defaults passed.'
