#!/usr/bin/env bash

read_daede_pin() {
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

validate_daede_backend() {
  local repo="$1" backend="$2" key="${2^^}_VERSION" version makefile workflow
  makefile="${repo}/${backend}/Makefile"
  workflow="${repo}/.github/workflows/assemble-${backend}-src.yml"
  version="$(read_daede_pin "${repo}/ci/pins.env" "${key}")"
  [[ -n "${version}" ]] && grep -Fqx "PKG_VERSION:=${version}" "${makefile}" || {
    echo "DAEDE ${backend} version differs from ci/pins.env" >&2; return 1;
  }
  grep -Eq '^PKG_HASH:=[0-9a-f]{64}$' "${makefile}" &&
    grep -Fq '$CORE_COMMIT' "${workflow}" &&
    grep -Fq '$CORE_UPSTREAM_COMMIT' "${workflow}" &&
    grep -Fq "option enabled '0'" "${repo}/${backend}/files/${backend}.config" || {
      echo "DAEDE ${backend} source/default contract changed" >&2; return 1;
    }
}

validate_daede_source() {
  local repo="$1" key value marker
  local widgets="${1}/luci-app-daede/htdocs/luci-static/resources/view/daede/widgets.js"
  for key in CORE_COMMIT CORE_UPSTREAM_COMMIT DAED_COMMIT WING_COMMIT; do
    value="$(read_daede_pin "${repo}/ci/pins.env" "${key}")"
    [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid DAEDE source pin: ${key}" >&2; return 1; }
    echo "DAEDE source ${key}=${value}"
  done
  validate_daede_backend "${repo}" dae || return 1
  validate_daede_backend "${repo}" daed || return 1
  for marker in rejectIfOtherRunning stopIfRunning 'backend.detectRunning()'; do
    grep -Fq "${marker}" "${widgets}" || { echo "Missing DAEDE switching contract: ${marker}" >&2; return 1; }
  done
  grep -Fq 'daede.zh-cn.lmo' "${repo}/luci-app-daede/Makefile" || {
    echo 'DAEDE integrated Chinese translation is missing' >&2; return 1;
  }
}

remove_daede_feed_duplicates() {
  local package
  # 中文：统一使用同一维护源，删除的仅是下载源码树中 feeds/旧 vendor 的重复定义。
  for package in dae daed vmlinux-btf; do
    rm -rf "${BUILD_ROOT}/feeds/packages/net/${package}" "${BUILD_ROOT}/package/feeds/packages/${package}"
  done
  for package in luci-app-dae luci-app-daed luci-app-daede; do
    rm -rf "${BUILD_ROOT}/feeds/luci/applications/${package}" "${BUILD_ROOT}/package/feeds/luci/${package}"
  done
  rm -rf "${BUILD_ROOT}/package/luci-app-dae" "${BUILD_ROOT}/package/luci-app-daed"
}

validate_daede_config_symbols() {
  local requested="$1" final="$2" symbol
  grep -Fqx 'CONFIG_PACKAGE_luci-app-daede=y' "${requested}" || return 0
  for symbol in CONFIG_PACKAGE_dae CONFIG_PACKAGE_daed CONFIG_PACKAGE_luci-app-daede \
    CONFIG_DAE_USE_KERNEL_BTF CONFIG_DAED_USE_KERNEL_BTF CONFIG_KERNEL_DEBUG_INFO_BTF CONFIG_PACKAGE_flock; do
    grep -Fqx "${symbol}=y" "${final}" || echo "WARNING: DAEDE config missing after defconfig: ${symbol}=y"
  done
}
