#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_URL="${REPO_URL:-https://github.com/openwrt/openwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
FEEDS_PROFILE="${FEEDS_PROFILE:-immortalwrt-compatible}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/openwrt-${WRT_CONFIG,,}}"
VENDOR_ROOT="${VENDOR_ROOT:-${WORK_ROOT}/openwrt-vendor}"
CACHE_ROOT="${CACHE_ROOT:-${WORK_ROOT}/cache}"
DL_DIR="${DL_DIR:-${CACHE_ROOT}/dl}"
CCACHE_DIR="${CCACHE_DIR:-${CACHE_ROOT}/ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
DEVICE_NAME="${DEVICE_NAME:-glinet_gl-mt3600be}"
DEVICE_DTS="${DEVICE_DTS:-mt7987a-glinet-gl-mt3600be}"
WRT_THEME="${WRT_THEME:-aurora}"
JOBS="${JOBS:-$(nproc)}"
TEST_ONLY="${TEST_ONLY:-0}"
BUILD_VERBOSE="${BUILD_VERBOSE:-0}"
PIN_MT76_KNOWN_GOOD="${PIN_MT76_KNOWN_GOOD:-1}"
MT76_PIN_SOURCE_DATE="${MT76_PIN_SOURCE_DATE:-2026-03-21}"
MT76_PIN_SOURCE_VERSION="${MT76_PIN_SOURCE_VERSION:-018f60316d4dd6b4e741874eda40e2dfaa29df3b}"
MT76_PIN_MIRROR_HASH="${MT76_PIN_MIRROR_HASH:-54a8125453a6fe04c89cf5335bdf0ea16c409361e1e5a79fb339d67cee26df0e}"
BUILD_MODE="${1:-build}"

source "${PROJECT_ROOT}/Scripts/Settings.sh"
source "${PROJECT_ROOT}/Scripts/Packages.sh"

run_git_with_retry() {
  local max_try="${1:-5}"
  shift
  local try

  for ((try=1; try<=max_try; try++)); do
    if "$@"; then
      return 0
    fi
    if [[ "${try}" -lt "${max_try}" ]]; then
      echo "Git command failed on attempt ${try}/${max_try}, retrying ..."
      sleep $((try * 15))
    fi
  done

  echo "Git command failed after ${max_try} attempts: $*"
  return 1
}

prepare_build_tree() {
  mkdir -p "${WORK_ROOT}"

  if [[ ! -d "${BUILD_ROOT}/.git" ]]; then
    rm -rf "${BUILD_ROOT}"
    run_git_with_retry 5 git -c http.version=HTTP/1.1 clone --depth 1 --single-branch --branch "${REPO_BRANCH}" "${REPO_URL}" "${BUILD_ROOT}"
    return
  fi

  cd "${BUILD_ROOT}"
  git remote set-url origin "${REPO_URL}"

  if ! git diff --quiet --ignore-submodules HEAD -- || ! git diff --cached --quiet --ignore-submodules --; then
    echo "Existing build tree is dirty: ${BUILD_ROOT}"
    exit 1
  fi

  run_git_with_retry 5 git -c http.version=HTTP/1.1 fetch origin "${REPO_BRANCH}" --depth 1
  git checkout -B "${REPO_BRANCH}" "origin/${REPO_BRANCH}"
}

pin_mt76_known_good_snapshot() {
  local mt76_makefile="${BUILD_ROOT}/package/kernel/mt76/Makefile"

  if [[ "${PIN_MT76_KNOWN_GOOD}" != "1" ]]; then
    echo "Skipping mt76 known-good snapshot pin."
    return
  fi

  if [[ ! -f "${mt76_makefile}" ]]; then
    echo "mt76 Makefile was not found, cannot pin wireless driver snapshot: ${mt76_makefile}"
    exit 1
  fi

  # 中文：OpenWrt main 在 304525e..f5d928e 之间把 mt76 从 2026-03-21 升到 2026-06-23；
  # 中文：GL-MT3600BE 的 mt7996 WiFi 在新快照上出现连接后异常，默认锁定到 #35 已验证版本。
  sed -i \
    -e "s|^PKG_SOURCE_DATE:=.*|PKG_SOURCE_DATE:=${MT76_PIN_SOURCE_DATE}|" \
    -e "s|^PKG_SOURCE_VERSION:=.*|PKG_SOURCE_VERSION:=${MT76_PIN_SOURCE_VERSION}|" \
    -e "s|^PKG_MIRROR_HASH:=.*|PKG_MIRROR_HASH:=${MT76_PIN_MIRROR_HASH}|" \
    "${mt76_makefile}"

  echo "Pinned mt76 snapshot for MT3600BE WiFi stability:"
  grep -E '^(PKG_SOURCE_DATE|PKG_SOURCE_VERSION|PKG_MIRROR_HASH):=' "${mt76_makefile}"
}

apply_feeds_profile() {
  local feeds_file="${PROJECT_ROOT}/Config/feeds.${FEEDS_PROFILE}.conf"

  if [[ ! -f "${feeds_file}" ]]; then
    echo "Feeds profile was not found: ${feeds_file}"
    exit 1
  fi

  cp "${feeds_file}" "${BUILD_ROOT}/feeds.conf.default"
  echo "Using feeds profile: ${FEEDS_PROFILE}"
  cat "${BUILD_ROOT}/feeds.conf.default"
}

prepare_shared_cache_dirs() {
  mkdir -p "${DL_DIR}" "${CCACHE_DIR}"

  if [[ -e "${BUILD_ROOT}/dl" && ! -L "${BUILD_ROOT}/dl" ]]; then
    rm -rf "${BUILD_ROOT}/dl"
  fi

  ln -sfn "${DL_DIR}" "${BUILD_ROOT}/dl"

  if [[ -e "${BUILD_ROOT}/.ccache" && ! -L "${BUILD_ROOT}/.ccache" ]]; then
    rm -rf "${BUILD_ROOT}/.ccache"
  fi

  # 中文：OpenWrt 默认把 ccache 写到源码树 .ccache；这里链接到 Actions 恢复的持久缓存目录。
  ln -sfn "${CCACHE_DIR}" "${BUILD_ROOT}/.ccache"

  export CCACHE_DIR
  export CCACHE_BASEDIR="${BUILD_ROOT}"
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"

  if command -v ccache >/dev/null 2>&1; then
    ccache -M "${CCACHE_MAXSIZE}" >/dev/null 2>&1 || true
    ccache -s || true
  fi
}

sync_rootfs_overlay() {
  if [[ ! -d "${PROJECT_ROOT}/files" ]]; then
    return
  fi

  rm -rf "${BUILD_ROOT}/files"
  mkdir -p "${BUILD_ROOT}/files"
  cp -a "${PROJECT_ROOT}/files/." "${BUILD_ROOT}/files/"
}

prepare_build_workspace() {
  prepare_build_tree
  cd "${BUILD_ROOT}"
  pin_mt76_known_good_snapshot
  apply_feeds_profile
  sync_rootfs_overlay
  prepare_shared_cache_dirs
}

prepare_feeds_and_config() {
  ./scripts/feeds update -a
  prepare_custom_packages
  ./scripts/feeds install -a
  sanitize_homeproxy_i18n_conflict
  validate_device_support
  apply_config_fragments
}

run_make() {
  if [[ "${BUILD_VERBOSE}" == "1" ]]; then
    make -j"${JOBS}" V=s "$@"
  else
    make -j"${JOBS}" "$@"
  fi
}

run_full_build() {
  if run_make "$@"; then
    return 0
  fi

  if [[ "${BUILD_VERBOSE}" == "1" ]]; then
    return 1
  fi

  cat <<'EOF'

Parallel build failed.
Re-running once with single-thread verbose output so the real failing package is visible.

EOF
  make -j1 V=s "$@"
}

main() {
  validate_host_environment

  case "${BUILD_MODE}" in
    prepare-tree)
      prepare_build_tree
      ;;
    build)
      prepare_build_workspace
      prepare_feeds_and_config

      if [[ "${TEST_ONLY}" == "1" ]]; then
        echo "Test-only mode finished. Generated config: ${BUILD_ROOT}/.config"
        exit 0
      fi

      make download -j"${JOBS}"
      find dl -type f -size -1024c -delete
      run_full_build

      if command -v ccache >/dev/null 2>&1; then
        ccache -s || true
      fi
      ;;
    *)
      echo "Usage: $0 [build|prepare-tree]"
      exit 1
      ;;
  esac
}

main "$@"
