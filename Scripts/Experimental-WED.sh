#!/usr/bin/env bash
# 中文：仅供独立实验工作流使用，日常构建默认不进入此路径。

WED_EXPERIMENT_OPENWRT=5700101d7c85381889d890dc1d3d001d0b4b6446
WED_EXPERIMENT_MT76=018f60316d4dd6b4e741874eda40e2dfaa29df3b

experimental_wed_enabled() {
  case "${EXPERIMENTAL_MT7987_WED:-0}" in
    0) return 1 ;;
    1) return 0 ;;
    *) echo 'ERROR: EXPERIMENTAL_MT7987_WED 只能为 0 或 1。' >&2; exit 2 ;;
  esac
}

validate_experimental_wed_source() {
  local actual_revision
  if [[ "${DEVICE_NAME}" != glinet_gl-mt3600be || "${PIN_MT76_KNOWN_GOOD}" != 1 ||
        "${REPO_REF}" != "${WED_EXPERIMENT_OPENWRT}" ]]; then
    echo 'ERROR: WED 实验版要求 MT3600BE、稳定 mt76 和本轮固定的 OpenWrt 提交。' >&2
    return 1
  fi
  actual_revision="$(git -C "${BUILD_ROOT}" rev-parse HEAD)"
  if [[ "${actual_revision}" != "${WED_EXPERIMENT_OPENWRT}" ||
        "${BUILD_LABEL}" != *WED-EXPERIMENTAL* ]]; then
    echo 'ERROR: 实验源码提交或固件实验标识不匹配。' >&2
    return 1
  fi
  if ! grep -qxF "PKG_SOURCE_VERSION:=${WED_EXPERIMENT_MT76}" "${BUILD_ROOT}/package/kernel/mt76/Makefile" ||
     ! grep -qxF 'LINUX_VERSION-6.18 = .55' "${BUILD_ROOT}/target/linux/generic/kernel-6.18"; then
    echo 'ERROR: 实验 mt76 或 Linux 版本不匹配。' >&2
    return 1
  fi
}

install_experimental_wed() {
  experimental_wed_enabled || return 0
  validate_experimental_wed_source || return 1
  python3 "${PROJECT_ROOT}/Tests/check-wed-source.py" --openwrt-tree "${BUILD_ROOT}"
  local patch_root="${PROJECT_ROOT}/Patches/wed-experimental"
  local package_file="${BUILD_ROOT}/package/kernel/mt76/Makefile"
  # 中文：仅在构建树添加配套补丁，不修改公共 Config 或日常 files 覆盖层。
  cp "${patch_root}/kernel/"*.patch "${BUILD_ROOT}/target/linux/mediatek/patches-6.18/"
  mkdir -p "${BUILD_ROOT}/package/kernel/mt76/patches"
  cp "${patch_root}/mt76/"*.patch "${BUILD_ROOT}/package/kernel/mt76/patches/"
  if [[ "$(grep -Fc 'AUTOLOAD:=$(call AutoProbe,mt7996e)' "${package_file}")" != 1 ]]; then
    echo 'ERROR: 无法唯一定位 mt7996e 模块加载配置。' >&2
    return 1
  fi
  # 中文：沿用 MediaTek 的 MODPARAMS 方式，只让实验固件请求 WED。
  sed -i '/AUTOLOAD:=$(call AutoProbe,mt7996e)/a\  MODPARAMS.mt7996e:=wed_enable=1' "${package_file}"
  cp "${patch_root}/README.md" "${BUILD_ROOT}/files/etc/mt7987-wed-experiment.txt"
  echo 'MT7987 WED 实验补丁已安装；需要后续真实内核、mt76 编译与实机验证。'
}

validate_experimental_wed_config() {
  experimental_wed_enabled || return 0
  local symbol
  for symbol in CONFIG_TARGET_mediatek_filogic_DEVICE_glinet_gl-mt3600be \
                CONFIG_PACKAGE_kmod-mt7996e CONFIG_PACKAGE_kmod-mt7990-firmware \
                CONFIG_PACKAGE_kmod-nft-offload; do
    if ! grep -qxF "${symbol}=y" "${BUILD_ROOT}/.config"; then
      echo "ERROR: 实验必需配置未生效：${symbol}" >&2
      return 1
    fi
  done
  if ! grep -qxF 'CONFIG_NET_MEDIATEK_SOC_WED=y' "${BUILD_ROOT}/target/linux/mediatek/filogic/config-6.18"; then
    echo 'ERROR: filogic 内核未启用 WED。' >&2
    return 1
  fi
}

compile_experimental_wed() {
  experimental_wed_enabled || return 0
  # 中文：先编译真实工具链、内核、mac80211 和 mt76，接口错误不能被配置测试掩盖。
  make -j"${JOBS}" tools/install toolchain/install V=s
  make -j"${JOBS}" target/linux/compile V=s
  make -j"${JOBS}" package/kernel/mac80211/compile V=s
  make -j"${JOBS}" package/kernel/mt76/compile V=s
}
