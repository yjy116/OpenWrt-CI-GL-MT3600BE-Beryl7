#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${project_root}/Scripts/Packages.sh"

make_fixture() {
  local root="$1"
  local core_owns_scanner="$2"
  local feed_is_fixed="$3"

  mkdir -p \
    "${root}/package/system/hardware-support" \
    "${root}/feeds/packages/utils/sane-backends"

  if [[ "${core_owns_scanner}" == "yes" ]]; then
    printf '%s\n' 'define Package/scanner-support' '  USERID:=:scanner=47' 'endef' \
      > "${root}/package/system/hardware-support/Makefile"
  else
    printf '%s\n' '# scanner-support 尚未进入旧主线' \
      > "${root}/package/system/hardware-support/Makefile"
  fi

  if [[ "${feed_is_fixed}" == "yes" ]]; then
    printf '%s\n' 'PKG_RELEASE:=2' 'define Package/sane-daemon' \
      '  DEPENDS:=scanner-support +libsane' '  USERID:=saned:scanner=47' 'endef' \
      > "${root}/feeds/packages/utils/sane-backends/Makefile"
  else
    printf '%s\n' 'PKG_RELEASE:=1' 'define Package/sane-daemon' \
      '  DEPENDS:=+libsane' '  USERID:=saned:scanner' 'endef' \
      > "${root}/feeds/packages/utils/sane-backends/Makefile"
  fi
}

assert_line() {
  local expected="$1"
  local file="$2"

  grep -Fqx "${expected}" "${file}" || {
    echo "缺少预期行：${expected}" >&2
    exit 1
  }
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "${tmp_root}"' EXIT

old_feed_root="${tmp_root}/old-feed"
make_fixture "${old_feed_root}" yes no
BUILD_ROOT="${old_feed_root}"
patch_sane_scanner_group_collision
old_feed_makefile="${old_feed_root}/feeds/packages/utils/sane-backends/Makefile"
assert_line 'PKG_RELEASE:=2' "${old_feed_makefile}"
assert_line '  DEPENDS:=scanner-support +libsane' "${old_feed_makefile}"
assert_line '  USERID:=saned:scanner=47' "${old_feed_makefile}"

fixed_feed_root="${tmp_root}/fixed-feed"
make_fixture "${fixed_feed_root}" yes yes
fixed_before="$(sha256sum "${fixed_feed_root}/feeds/packages/utils/sane-backends/Makefile")"
BUILD_ROOT="${fixed_feed_root}"
patch_sane_scanner_group_collision
fixed_after="$(sha256sum "${fixed_feed_root}/feeds/packages/utils/sane-backends/Makefile")"
[[ "${fixed_before}" == "${fixed_after}" ]] || { echo '已修复 feed 不应再次改写。' >&2; exit 1; }

old_core_root="${tmp_root}/old-core"
make_fixture "${old_core_root}" no no
old_core_before="$(sha256sum "${old_core_root}/feeds/packages/utils/sane-backends/Makefile")"
BUILD_ROOT="${old_core_root}"
patch_sane_scanner_group_collision
old_core_after="$(sha256sum "${old_core_root}/feeds/packages/utils/sane-backends/Makefile")"
[[ "${old_core_before}" == "${old_core_after}" ]] || { echo '旧主线不应套用新兼容修复。' >&2; exit 1; }

echo 'SANE scanner 组兼容修复检查通过。'
