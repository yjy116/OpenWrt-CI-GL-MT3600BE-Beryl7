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
