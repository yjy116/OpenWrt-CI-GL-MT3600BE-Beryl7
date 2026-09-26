#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
general_config="${project_root}/Config/GENERAL.txt"
packages_script="${project_root}/Scripts/Packages.sh"
settings_script="${project_root}/Scripts/Settings.sh"
upgrade_keep_file="${project_root}/files/lib/upgrade/keep.d/daed"

require_line() {
  local expected="$1"
  local file="$2"

  if ! grep -Fqx "${expected}" "${file}"; then
    echo "Missing required line in ${file}: ${expected}" >&2
    exit 1
  fi
}

require_line '# @vendor luci-app-daede|https://github.com/kenzok8/openwrt-daede.git|main|daed:package/daed;luci-app-daede:package/luci-app-daede|daede-modern' "${general_config}"
require_line 'CONFIG_PACKAGE_daed=y' "${general_config}"
require_line 'CONFIG_PACKAGE_luci-app-daede=y' "${general_config}"
require_line 'CONFIG_PACKAGE_luci-app-daede_daed=y' "${general_config}"
require_line 'CONFIG_DAED_USE_KERNEL_BTF=y' "${general_config}"

if grep -Fq 'QiuSimons/luci-app-daed' "${general_config}"; then
  echo 'Archived QiuSimons DAED source must not be used.' >&2
  exit 1
fi

if grep -Fqx 'CONFIG_PACKAGE_luci-app-daed=y' "${general_config}"; then
  echo 'Legacy luci-app-daed must be replaced by luci-app-daede.' >&2
  exit 1
fi

require_line '    daede-modern)' "${packages_script}"
grep -Fq 'CONFIG_PACKAGE_luci-app-daede=y' "${settings_script}"
grep -Fq 'CONFIG_PACKAGE_luci-app-daede_daed=y' "${settings_script}"
grep -Fq 'CONFIG_DAED_USE_KERNEL_BTF=y' "${settings_script}"
require_line '/etc/daed/wing.db-wal' "${upgrade_keep_file}"

if grep -Fq 'daed-kix-compat' "${packages_script}"; then
  echo 'Legacy DAED kix compatibility hook must be removed.' >&2
  exit 1
fi

echo 'DAED source and integrated BTF configuration checks passed.'
