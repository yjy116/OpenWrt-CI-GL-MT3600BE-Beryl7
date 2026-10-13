#!/usr/bin/env bash

# 中文：固定已完成上游 SDK 矩阵构建的同一批发布，核心与前端都使用真实 SHA256。
# 与 GENERAL.txt 中的 v2026.10.12-r38236606118 标签同步更新。
HONK_PACKAGE_COMMIT=52ecdb1bb26e04be782bcb368973fd54d4a44af6
HONK_SOURCE_TAG=source-38236606118

HONK_REQUIRED_CONFIG_SYMBOLS=(
  "CONFIG_PACKAGE_honk=y"
  "CONFIG_PACKAGE_luci-app-honk=y"
  "CONFIG_PACKAGE_kmod-veth=y"
  "CONFIG_PACKAGE_kmod-nft-queue=y"
  "CONFIG_PACKAGE_ip-full=y"
  "CONFIG_PACKAGE_sqlite3-cli=y"
  "CONFIG_PACKAGE_v2ray-geoip=y"
  "CONFIG_PACKAGE_v2ray-geosite=y"
  "CONFIG_BPF_TOOLCHAIN_HOST=y"
  "CONFIG_DWARVES=y"
  "CONFIG_USE_LLVM_HOST=y"
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

validate_honk_config_symbols() {
  local requested_config="$1" final_config="$2"
  local missing=() symbol

  grep -Fqx 'CONFIG_PACKAGE_luci-app-honk=y' "${requested_config}" || return 0
  for symbol in "${HONK_REQUIRED_CONFIG_SYMBOLS[@]}"; do
    if ! grep -Fqx "${symbol}" "${final_config}"; then
      missing+=("${symbol}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "WARNING: Honk required config symbols are missing after defconfig:"
    printf '  %s\n' "${missing[@]}"
  fi
}

fetch_honk_metadata() {
  local destination="$1" expected_hash="$2"
  local source_url="https://github.com/kenzok8/openwrt-honk/releases/download/${HONK_SOURCE_TAG}/${destination##*/}"

  curl --fail --location --silent --show-error \
    --output "${destination}.download" "${source_url}" || return 1
  printf '%s  %s\n' "${expected_hash}" "${destination}.download" | sha256sum --check - || return 1
  mv -f "${destination}.download" "${destination}"
}

prepare_honk_source() {
  local repo_dir="$1"

  [[ "$(git -C "${repo_dir}" rev-parse HEAD)" == "${HONK_PACKAGE_COMMIT}" ]] || {
    echo "Honk package revision does not match the verified release metadata." >&2
    return 1
  }

  # 中文：必须在复制包、解析 Makefile 之前取得生成文件，不回退到 staging/SKIP。
  fetch_honk_metadata "${repo_dir}/honk/generated-stage.mk" \
    534de1bc50183577d57ec91f0b8b3ba499722b1be6815dbf422bca26fe90b121 || return 1
  fetch_honk_metadata "${repo_dir}/honk/generated-provenance.json" \
    04c168b50801644b630e355fe9baceee061f246e3194e8897f5e136bff22eb46 || return 1
  fetch_honk_metadata "${repo_dir}/luci-app-honk/generated-doona-stage.mk" \
    c5013b4707959ec09e28b75e09a01ab4fcc3087ac4b7eada784c7903884f5e4c || return 1

  echo "Verified Honk/Doona release metadata: ${HONK_SOURCE_TAG} (${HONK_PACKAGE_COMMIT})."
}
