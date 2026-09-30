#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/Config}"
GENERAL_CONFIG_FILE="${GENERAL_CONFIG_FILE:-${CONFIG_DIR}/GENERAL.txt}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/openwrt-${WRT_CONFIG,,}}"
VENDOR_ROOT="${VENDOR_ROOT:-${WORK_ROOT}/openwrt-vendor}"
WRT_THEME="${WRT_THEME:-aurora}"

config_package_enabled() {
  local package_name="$1"
  [[ -f "${GENERAL_CONFIG_FILE}" ]] && grep -Eq "^CONFIG_PACKAGE_${package_name}=y$" "${GENERAL_CONFIG_FILE}"
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

sync_git_repo() {
  local repo_url="$1"
  local repo_branch="$2"
  local repo_dir="$3"

  if [[ ! -d "${repo_dir}/.git" ]]; then
    git clone --depth 1 --single-branch --branch "${repo_branch}" "${repo_url}" "${repo_dir}"
    return
  fi

  git -C "${repo_dir}" remote set-url origin "${repo_url}"
  git -C "${repo_dir}" fetch origin "${repo_branch}" --depth 1
  git -C "${repo_dir}" checkout -B "${repo_branch}" "origin/${repo_branch}"
}

copy_package_dir() {
  local src_dir="$1"
  local dst_dir="$2"

  if [[ ! -d "${src_dir}" ]]; then
    echo "Package directory was not found: ${src_dir}"
    exit 1
  fi

  rm -rf "${dst_dir}"
  mkdir -p "${dst_dir}"
  cp -a "${src_dir}/." "${dst_dir}/"
  rm -rf "${dst_dir}/.git"
}

read_daede_pin() {
  local pins_file="$1"
  local key="$2"

  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${pins_file}"
}

validate_daede_runtime_contract() {
  local repo_dir="$1"
  local widgets="${repo_dir}/luci-app-daede/htdocs/luci-static/resources/view/daede/widgets.js"
  local backend_config marker

  [[ -f "${widgets}" ]] || { echo "DAE/DAED backend switcher was not found: ${widgets}"; exit 1; }
  for marker in "rejectIfOtherRunning" "stopIfRunning" "backend.detectRunning()"; do
    grep -Fq "${marker}" "${widgets}" || { echo "DAE/DAED mutual exclusion marker is missing: ${marker}"; exit 1; }
  done

  for backend_config in "${repo_dir}/dae/files/dae.config" "${repo_dir}/daed/files/daed.config"; do
    [[ -f "${backend_config}" ]] || { echo "Backend default config was not found: ${backend_config}"; exit 1; }
    grep -Fq "option enabled '0'" "${backend_config}" || { echo "Backend must be disabled by default: ${backend_config}"; exit 1; }
  done
}

validate_daede_source() {
  local repo_dir="$1"
  local pins_file="${repo_dir}/ci/pins.env"
  local dae_workflow="${repo_dir}/.github/workflows/assemble-dae-src.yml"
  local daed_workflow="${repo_dir}/.github/workflows/assemble-daed-src.yml"
  local dae_version daed_version dae_package_version daed_package_version
  local core_commit core_upstream_commit required_file workflow

  for required_file in \
    "${repo_dir}/dae/Makefile" \
    "${repo_dir}/daed/Makefile" \
    "${repo_dir}/luci-app-daede/Makefile" \
    "${pins_file}" "${dae_workflow}" "${daed_workflow}"; do
    [[ -f "${required_file}" ]] || { echo "DAE/DAED source file was not found: ${required_file}"; exit 1; }
  done

  dae_version="$(read_daede_pin "${pins_file}" "DAE_VERSION")"
  daed_version="$(read_daede_pin "${pins_file}" "DAED_VERSION")"
  core_commit="$(read_daede_pin "${pins_file}" "CORE_COMMIT")"
  core_upstream_commit="$(read_daede_pin "${pins_file}" "CORE_UPSTREAM_COMMIT")"
  [[ -n "${dae_version}" && -n "${daed_version}" && -n "${core_commit}" && -n "${core_upstream_commit}" ]] || {
    echo "DAE/DAED source pins are incomplete: ${pins_file}"
    exit 1
  }

  dae_package_version="$(sed -n 's/^PKG_VERSION:=//p' "${repo_dir}/dae/Makefile")"
  daed_package_version="$(sed -n 's/^PKG_VERSION:=//p' "${repo_dir}/daed/Makefile")"
  [[ "${dae_package_version}" == "${dae_version}" ]] || { echo "DAE PKG_VERSION does not match ci/pins.env"; exit 1; }
  [[ "${daed_package_version}" == "${daed_version}" ]] || { echo "DAED PKG_VERSION does not match ci/pins.env"; exit 1; }

  for workflow in "${dae_workflow}" "${daed_workflow}"; do
    grep -Fq '$CORE_COMMIT' "${workflow}" || { echo "CORE_COMMIT is not used by ${workflow}"; exit 1; }
    grep -Fq '$CORE_UPSTREAM_COMMIT' "${workflow}" || { echo "CORE_UPSTREAM_COMMIT is not used by ${workflow}"; exit 1; }
  done

  validate_daede_runtime_contract "${repo_dir}"
  echo "Verified DAE ${dae_version} and DAED ${daed_version}: performance core ${core_commit}, upstream core ${core_upstream_commit}."
}

run_vendor_hook() {
  local repo_dir="$1"
  local hook="${2:-}"
  local openclash_po2lmo_dir
  local tailscale_makefile

  case "${hook}" in
    ""|none)
      ;;
    po2lmo)
      if command -v po2lmo >/dev/null 2>&1; then
        return
      fi
      openclash_po2lmo_dir="${repo_dir}/luci-app-openclash/tools/po2lmo"
      if [[ ! -d "${openclash_po2lmo_dir}" ]]; then
        echo "OpenClash po2lmo directory was not found: ${openclash_po2lmo_dir}"
        exit 1
      fi
      make -C "${openclash_po2lmo_dir}"
      export PATH="${openclash_po2lmo_dir}/src:${PATH}"
      ;;
    tailscale-compat)
      for tailscale_makefile in \
        "${BUILD_ROOT}/feeds/packages/net/tailscale/Makefile" \
        "${BUILD_ROOT}/package/feeds/packages/tailscale/Makefile"; do
        if [[ -f "${tailscale_makefile}" ]]; then
          sed -i '\|/etc/init.d/tailscale|d;\|/etc/config/tailscale|d' "${tailscale_makefile}"
          echo "Patched tailscale package for luci-app-tailscale compatibility: ${tailscale_makefile}"
        fi
      done
      ;;
    luci-mk-compat)
      while IFS= read -r -d '' luci_makefile; do
        sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|g' "${luci_makefile}"
        echo "Patched LuCI make include for standalone package: ${luci_makefile}"
      done < <(find "${repo_dir}" -type f -name Makefile -print0)
      ;;
    daede-modern)
      # 中文：使用维护中的 openwrt-daede 源，同时清理 feeds 和旧 vendor 留下的同名包。
      rm -rf \
        "${BUILD_ROOT}/feeds/luci/applications/luci-app-dae" \
        "${BUILD_ROOT}/feeds/luci/applications/luci-app-daed" \
        "${BUILD_ROOT}/package/feeds/luci/luci-app-dae" \
        "${BUILD_ROOT}/package/feeds/luci/luci-app-daed" \
        "${BUILD_ROOT}/feeds/luci/applications/luci-app-daede" \
        "${BUILD_ROOT}/package/feeds/luci/luci-app-daede" \
        "${BUILD_ROOT}/feeds/packages/net/dae" \
        "${BUILD_ROOT}/feeds/packages/net/daed" \
        "${BUILD_ROOT}/package/feeds/packages/dae" \
        "${BUILD_ROOT}/package/feeds/packages/daed" \
        "${BUILD_ROOT}/package/luci-app-dae" \
        "${BUILD_ROOT}/package/luci-app-daed"
      ;;
    *)
      echo "Unknown vendor hook: ${hook}"
      exit 1
      ;;
  esac
}

copy_vendor_specs() {
  local repo_dir="$1"
  local copy_specs="$2"
  local spec src_rel dst_rel src_dir dst_dir

  IFS=';' read -r -a specs <<< "${copy_specs}"
  for spec in "${specs[@]}"; do
    spec="$(trim_whitespace "${spec}")"
    [[ -n "${spec}" ]] || continue

    if [[ "${spec}" != *:* ]]; then
      echo "Invalid vendor copy spec: ${spec}"
      exit 1
    fi

    src_rel="$(trim_whitespace "${spec%%:*}")"
    dst_rel="$(trim_whitespace "${spec#*:}")"

    if [[ "${src_rel}" == "." ]]; then
      src_dir="${repo_dir}"
    else
      src_dir="${repo_dir}/${src_rel}"
    fi

    dst_dir="${BUILD_ROOT}/${dst_rel}"
    copy_package_dir "${src_dir}" "${dst_dir}"
  done
}

prepare_theme_packages() {
  local theme_repo_dir
  local theme_config_repo_dir

  case "${WRT_THEME}" in
    ""|bootstrap)
      return
      ;;
    aurora)
      theme_repo_dir="${VENDOR_ROOT}/luci-theme-aurora"
      theme_config_repo_dir="${VENDOR_ROOT}/luci-app-aurora-config"
      sync_git_repo "https://github.com/eamonxg/luci-theme-aurora.git" "master" "${theme_repo_dir}"
      copy_package_dir "${theme_repo_dir}" "${BUILD_ROOT}/package/luci-theme-aurora"
      sync_git_repo "https://github.com/eamonxg/luci-app-aurora-config.git" "master" "${theme_config_repo_dir}"
      copy_package_dir "${theme_config_repo_dir}" "${BUILD_ROOT}/package/luci-app-aurora-config"
      ;;
    *)
      echo "Unsupported WRT_THEME: ${WRT_THEME}"
      exit 1
      ;;
  esac
}

sanitize_homeproxy_i18n_conflict() {
  local duplicate_menu_file

  if ! config_package_enabled "luci-app-homeproxy"; then
    return
  fi

  for duplicate_menu_file in \
    "${BUILD_ROOT}/feeds/luci/applications/luci-app-homeproxy/po/zh_Hans/root/usr/share/luci/menu.d/luci-app-homeproxy.json" \
    "${BUILD_ROOT}/feeds/luci/applications/luci-app-homeproxy/po/zh_Hans/usr/share/luci/menu.d/luci-app-homeproxy.json" \
    "${BUILD_ROOT}/package/feeds/luci/luci-app-homeproxy/po/zh_Hans/root/usr/share/luci/menu.d/luci-app-homeproxy.json" \
    "${BUILD_ROOT}/package/feeds/luci/luci-app-homeproxy/po/zh_Hans/usr/share/luci/menu.d/luci-app-homeproxy.json"; do
    if [[ -f "${duplicate_menu_file}" ]]; then
      rm -f "${duplicate_menu_file}"
      echo "Removed duplicate HomeProxy i18n menu file: ${duplicate_menu_file}"
    fi
  done
}

patch_sane_scanner_group_collision() {
  local core_makefile="${BUILD_ROOT}/package/system/hardware-support/Makefile"
  local sane_makefile="${BUILD_ROOT}/feeds/packages/utils/sane-backends/Makefile"

  [[ -f "${core_makefile}" && -f "${sane_makefile}" ]] || return 0
  grep -Fqx '  USERID:=:scanner=47' "${core_makefile}" || return 0

  if grep -Fqx '  USERID:=saned:scanner=47' "${sane_makefile}" && \
    grep -Fqx '  DEPENDS:=scanner-support +libsane' "${sane_makefile}"; then
    echo "SANE scanner-support compatibility is already present."
    return 0
  fi

  if ! grep -Fqx '  USERID:=saned:scanner' "${sane_makefile}" || \
    ! grep -Fqx '  DEPENDS:=+libsane' "${sane_makefile}"; then
    echo "Unknown sane-daemon scanner identity layout: ${sane_makefile}" >&2
    return 1
  fi

  # 中文：回移 OpenWrt packages 官方修复，scanner 组由主线 scanner-support 统一持有。
  sed -i \
    -e 's/^PKG_RELEASE:=1$/PKG_RELEASE:=2/' \
    -e 's/^  DEPENDS:=+libsane$/  DEPENDS:=scanner-support +libsane/' \
    -e 's/^  USERID:=saned:scanner$/  USERID:=saned:scanner=47/' \
    "${sane_makefile}"

  grep -Fqx '  DEPENDS:=scanner-support +libsane' "${sane_makefile}" && \
    grep -Fqx '  USERID:=saned:scanner=47' "${sane_makefile}" || {
      echo "Failed to apply sane-daemon scanner-support compatibility." >&2
      return 1
    }
  echo "Applied sane-daemon scanner-support compatibility: ${sane_makefile}"
}

patch_tvheadend_dvb_group_collision() {
  local core_makefile="${BUILD_ROOT}/package/system/hardware-support/Makefile"
  local tvheadend_makefile="${BUILD_ROOT}/feeds/packages/multimedia/tvheadend/Makefile"
  local patched_makefile

  [[ -f "${core_makefile}" && -f "${tvheadend_makefile}" ]] || return 0
  grep -Fqx '  USERID:=:dvb=49' "${core_makefile}" || return 0

  if grep -Fqx '  USERID:=tvheadend:dvb=49' "${tvheadend_makefile}" && \
    grep -Fqx $'\tdvb-support \\' "${tvheadend_makefile}"; then
    echo "TVHeadend dvb-support compatibility is already present."
    return 0
  fi

  if ! grep -Fqx '  USERID:=tvheadend:dvb' "${tvheadend_makefile}" || \
    grep -Fqx $'\tdvb-support \\' "${tvheadend_makefile}"; then
    echo "Unknown TVHeadend DVB identity layout: ${tvheadend_makefile}" >&2
    return 1
  fi

  # 中文：回移 OpenWrt packages 官方修复，dvb 组由主线 dvb-support 统一持有。
  patched_makefile="${tvheadend_makefile}.compat"
  awk '
    $0 == "PKG_RELEASE:=1" { $0 = "PKG_RELEASE:=2" }
    $0 == "  USERID:=tvheadend:dvb" { $0 = "  USERID:=tvheadend:dvb=49" }
    { print }
    $0 == "  DEPENDS:= \\" { print "\tdvb-support \\" }
  ' "${tvheadend_makefile}" > "${patched_makefile}"
  mv -f "${patched_makefile}" "${tvheadend_makefile}"

  grep -Fqx '  USERID:=tvheadend:dvb=49' "${tvheadend_makefile}" && \
    grep -Fqx $'\tdvb-support \\' "${tvheadend_makefile}" || {
      echo "Failed to apply TVHeadend dvb-support compatibility." >&2
      return 1
    }
  echo "Applied TVHeadend dvb-support compatibility: ${tvheadend_makefile}"
}

prepare_custom_packages() {
  local line package_name repo_url repo_branch copy_specs hook repo_dir

  mkdir -p "${VENDOR_ROOT}"
  prepare_theme_packages

  while IFS= read -r line; do
    if [[ ! "${line}" =~ ^#[[:space:]]*@vendor[[:space:]]+([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)(\|(.*))?$ ]]; then
      continue
    fi

    package_name="$(trim_whitespace "${BASH_REMATCH[1]}")"
    repo_url="$(trim_whitespace "${BASH_REMATCH[2]}")"
    repo_branch="$(trim_whitespace "${BASH_REMATCH[3]}")"
    copy_specs="$(trim_whitespace "${BASH_REMATCH[4]}")"
    hook="$(trim_whitespace "${BASH_REMATCH[6]:-}")"

    if ! config_package_enabled "${package_name}"; then
      continue
    fi

    repo_dir="${VENDOR_ROOT}/${package_name}"
    sync_git_repo "${repo_url}" "${repo_branch}" "${repo_dir}"
    if [[ "${hook}" == "daede-modern" ]]; then
      validate_daede_source "${repo_dir}"
    fi
    run_vendor_hook "${repo_dir}" "${hook}"
    copy_vendor_specs "${repo_dir}" "${copy_specs}"
    run_vendor_hook "${repo_dir}" "${hook}"
  done < "${GENERAL_CONFIG_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    prepare)
      prepare_custom_packages
      ;;
    *)
      echo "Usage: $0 prepare"
      exit 1
      ;;
  esac
fi
