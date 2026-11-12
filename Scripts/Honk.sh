#!/usr/bin/env bash

# 中文：每次构建拉取打包主线，核心与 Doona 必须使用该提交指定的同一批资产。

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

sync_honk_main() {
  local repo_url="$1" branch="$2" repo_dir="$3" commit
  local verifier="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/honk_source.py"

  [[ "${repo_url}" == https://github.com/kenzok8/openwrt-honk.git && "${branch}" == main ]] || {
    echo 'Honk requires the kenzok8/openwrt-honk main packaging branch.' >&2
    return 1
  }
  sync_git_repo "${repo_url}" "${branch}" "${repo_dir}" || return 1
  commit="$(git -C "${repo_dir}" rev-parse HEAD)" || return 1
  echo "Selected Honk/Doona packaging main: ${commit}"
  python3 "${verifier}" prepare "${repo_dir}" "${commit}"
}
