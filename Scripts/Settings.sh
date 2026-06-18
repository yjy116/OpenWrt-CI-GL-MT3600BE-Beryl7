#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/Config}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
WRT_CONFIG_FILE="${WRT_CONFIG_FILE:-${CONFIG_DIR}/${WRT_CONFIG}.txt}"
GENERAL_CONFIG_FILE="${GENERAL_CONFIG_FILE:-${CONFIG_DIR}/GENERAL.txt}"
KERNEL_CONFIG_FILE="${KERNEL_CONFIG_FILE:-${CONFIG_DIR}/${WRT_CONFIG}.kernel.txt}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/openwrt-${WRT_CONFIG,,}}"
DEVICE_NAME="${DEVICE_NAME:-glinet_gl-mt3600be}"
DEVICE_DTS="${DEVICE_DTS:-mt7987a-glinet-gl-mt3600be}"
WRT_THEME="${WRT_THEME:-aurora}"
FEEDS_PROFILE="${FEEDS_PROFILE:-immortalwrt-compatible}"
LANGUAGE_CORE_PACKAGES=(
  "CONFIG_PACKAGE_luci=y"
  "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
  "CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y"
)
COMPAT_LANGUAGE_PACKAGES=(
  "CONFIG_PACKAGE_default-settings-chn=y"
)
REQUIRED_CONFIG_SYMBOLS=(
  "CONFIG_PACKAGE_luci=y"
  "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
)
DAED_REQUIRED_CONFIG_SYMBOLS=(
  "CONFIG_PACKAGE_daed=y"
  "CONFIG_PACKAGE_daed-geoip=y"
  "CONFIG_PACKAGE_daed-geosite=y"
  "CONFIG_PACKAGE_luci-app-daed=y"
  "CONFIG_BPF_TOOLCHAIN_BUILD_LLVM=y"
  "CONFIG_DWARVES=y"
  "CONFIG_KERNEL_DEBUG_KERNEL=y"
  "CONFIG_KERNEL_DEBUG_INFO=y"
  "CONFIG_KERNEL_CGROUPS=y"
  "CONFIG_KERNEL_DEBUG_INFO_BTF=y"
  "CONFIG_KERNEL_DEBUG_INFO_BTF_MODULES=y"
  "CONFIG_KERNEL_BPF_EVENTS=y"
  "CONFIG_KERNEL_CGROUP_BPF=y"
  "CONFIG_KERNEL_KPROBES=y"
  "CONFIG_KERNEL_KPROBE_EVENTS=y"
  "CONFIG_KERNEL_XDP_SOCKETS=y"
  "CONFIG_KERNEL_ARM64_BRBE=y"
  "CONFIG_PACKAGE_kmod-sched-bpf=y"
  "CONFIG_PACKAGE_kmod-sched-core=y"
  "CONFIG_PACKAGE_kmod-xdp-sockets-diag=y"
)

is_windows_mount_path() {
  local path="$1"
  [[ "${path}" =~ ^/mnt/[A-Za-z](/|$) ]]
}

append_config_line_if_missing() {
  local line="$1"
  grep -qxF "${line}" .config || echo "${line}" >> .config
}

general_config_package_enabled() {
  local package_name="$1"
  [[ -f "${GENERAL_CONFIG_FILE}" ]] && grep -Eq "^CONFIG_PACKAGE_${package_name}=y$" "${GENERAL_CONFIG_FILE}"
}

source_package_has_zh_translation() {
  local package_name="$1"
  local package_dir

  while IFS= read -r -d '' package_dir; do
    if [[ -d "${package_dir}/po/zh_Hans" || -d "${package_dir}/po/zh-cn" || -d "${package_dir}/po/zh_CN" ]]; then
      return 0
    fi
  done < <(find "${BUILD_ROOT}/feeds" "${BUILD_ROOT}/package" -type d -name "${package_name}" -print0 2>/dev/null)

  return 1
}

validate_host_environment() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script must run inside Linux or WSL2."
    exit 1
  fi

  if is_windows_mount_path "${PWD}" || is_windows_mount_path "${PROJECT_ROOT}" || is_windows_mount_path "${WORK_ROOT}" || is_windows_mount_path "${BUILD_ROOT}"; then
    cat <<'EOF'
Do not build OpenWrt from a Windows-mounted path such as /mnt/c.
Use a native Linux path like:
  export WORK_ROOT=$HOME/work
EOF
    exit 1
  fi

  command -v git >/dev/null 2>&1 || { echo "git is required. Run Scripts/bootstrap-ubuntu.sh first."; exit 1; }
  command -v make >/dev/null 2>&1 || { echo "make is required. Run Scripts/bootstrap-ubuntu.sh first."; exit 1; }

  [[ -f "${WRT_CONFIG_FILE}" ]] || { echo "Device config not found: ${WRT_CONFIG_FILE}"; exit 1; }
  [[ -f "${GENERAL_CONFIG_FILE}" ]] || { echo "General config not found: ${GENERAL_CONFIG_FILE}"; exit 1; }
}

validate_device_support() {
  if ! grep -Rqs "define Device/${DEVICE_NAME}" target/linux/mediatek/image/filogic.mk; then
    echo "Device profile ${DEVICE_NAME} was not found in OpenWrt source."
    exit 2
  fi

  if [[ ! -f "target/linux/mediatek/dts/${DEVICE_DTS}.dts" ]]; then
    echo "Device DTS ${DEVICE_DTS}.dts was not found in OpenWrt source."
    exit 2
  fi
}

append_core_luci_language_packages() {
  local line

  for line in "${LANGUAGE_CORE_PACKAGES[@]}"; do
    append_config_line_if_missing "${line}"
  done

  if [[ "${FEEDS_PROFILE}" == "immortalwrt-compatible" ]]; then
    for line in "${COMPAT_LANGUAGE_PACKAGES[@]}"; do
      append_config_line_if_missing "${line}"
    done
  fi
}

append_auto_i18n_for_package() {
  local config_package="$1"
  local base_name
  local i18n_package

  case "${config_package}" in
    luci-app-*)
      base_name="${config_package#luci-app-}"
      ;;
    luci-proto-*)
      base_name="${config_package#luci-proto-}"
      ;;
    *)
      return
      ;;
  esac

  if ! source_package_has_zh_translation "${config_package}"; then
    return
  fi

  i18n_package="CONFIG_PACKAGE_luci-i18n-${base_name}-zh-cn=y"
  append_config_line_if_missing "${i18n_package}"
  echo "Auto-enable i18n: ${i18n_package}"
}

append_auto_i18n_packages_to_config() {
  local line
  local package_name

  while IFS= read -r line; do
    package_name="${line#CONFIG_PACKAGE_}"
    package_name="${package_name%=y}"
    append_auto_i18n_for_package "${package_name}"
  done < <(grep -E '^CONFIG_PACKAGE_(luci-app-|luci-proto-).*=y$' "${GENERAL_CONFIG_FILE}" | sort -u)
}

apply_default_luci_theme() {
  local collection_makefile

  [[ -n "${WRT_THEME}" ]] || return
  [[ "${WRT_THEME}" != "bootstrap" ]] || return

  while IFS= read -r -d '' collection_makefile; do
    sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" "${collection_makefile}"
  done < <(find ./feeds/luci/collections/ -type f -name "Makefile" -print0 2>/dev/null)
}

append_theme_packages_to_config() {
  [[ -n "${WRT_THEME}" ]] || return
  [[ "${WRT_THEME}" != "bootstrap" ]] || return

  append_config_line_if_missing "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
  append_config_line_if_missing "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"

  if source_package_has_zh_translation "luci-app-${WRT_THEME}-config"; then
    append_config_line_if_missing "CONFIG_PACKAGE_luci-i18n-${WRT_THEME}-config-zh-cn=y"
  fi
}

validate_device_profile_symbols() {
  local symbol

  while IFS= read -r symbol; do
    [[ -n "${symbol}" ]] || continue
    if ! grep -qxF "${symbol}" .config; then
      echo "ERROR: Device profile disappeared after defconfig: ${symbol}"
      exit 3
    fi
  done < <(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' "${WRT_CONFIG_FILE}" || true)
}

validate_required_config_symbols() {
  local missing=()
  local symbol
  local required_symbols=("${REQUIRED_CONFIG_SYMBOLS[@]}")

  if [[ "${FEEDS_PROFILE}" == "immortalwrt-compatible" ]]; then
    required_symbols+=("CONFIG_PACKAGE_default-settings-chn=y")
  fi

  if [[ -n "${WRT_THEME}" && "${WRT_THEME}" != "bootstrap" ]]; then
    required_symbols+=(
      "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
      "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"
    )
  fi

  for symbol in "${required_symbols[@]}"; do
    if ! grep -q "^${symbol}$" .config; then
      missing+=("${symbol}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "WARNING: Required LuCI/i18n config symbols are missing after defconfig:"
    printf '  %s\n' "${missing[@]}"
  fi
}

validate_daed_config_symbols() {
  local missing=()
  local symbol

  if ! general_config_package_enabled "luci-app-daed"; then
    return 0
  fi

  for symbol in "${DAED_REQUIRED_CONFIG_SYMBOLS[@]}"; do
    if ! grep -q "^${symbol}$" .config; then
      missing+=("${symbol}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "WARNING: daed required config symbols are missing after defconfig:"
    printf '  %s\n' "${missing[@]}"
  fi
}

report_dropped_requested_packages() {
  local requested_file="${BUILD_ROOT}/tmp/requested-packages.txt"
  local final_file="${BUILD_ROOT}/tmp/final-packages.txt"
  local dropped_file="${BUILD_ROOT}/tmp/dropped-packages.txt"

  mkdir -p "${BUILD_ROOT}/tmp"
  grep -E '^CONFIG_PACKAGE_[A-Za-z0-9_.+-]+=y$' "${GENERAL_CONFIG_FILE}" \
    | sed -E 's/^CONFIG_PACKAGE_//; s/=y$//' \
    | sort -u > "${requested_file}" || true
  grep -E '^CONFIG_PACKAGE_[A-Za-z0-9_.+-]+=y$' .config \
    | sed -E 's/^CONFIG_PACKAGE_//; s/=y$//' \
    | sort -u > "${final_file}" || true

  comm -23 "${requested_file}" "${final_file}" > "${dropped_file}" || true
  if [[ -s "${dropped_file}" ]]; then
    echo "WARNING: packages requested in Config/GENERAL.txt but not selected after defconfig:"
    sed 's/^/  - /' "${dropped_file}"
  fi
}

apply_config_fragments() {
  apply_default_luci_theme
  cat "${GENERAL_CONFIG_FILE}" "${WRT_CONFIG_FILE}" > .config

  if [[ -f "${KERNEL_CONFIG_FILE}" ]]; then
    cat "${KERNEL_CONFIG_FILE}" >> .config
  fi

  append_core_luci_language_packages
  append_theme_packages_to_config
  append_auto_i18n_packages_to_config

  if [[ -n "${EXTRA_CONFIG_FILE:-}" && -f "${EXTRA_CONFIG_FILE}" ]]; then
    cat "${EXTRA_CONFIG_FILE}" >> .config
  fi

  make defconfig

  validate_device_profile_symbols
  validate_required_config_symbols
  validate_daed_config_symbols
  report_dropped_requested_packages
}
