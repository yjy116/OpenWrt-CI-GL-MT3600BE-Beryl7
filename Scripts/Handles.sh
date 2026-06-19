#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/openwrt-${WRT_CONFIG,,}}"
RUNNER_TEMP="${RUNNER_TEMP:-${PROJECT_ROOT}/.tmp}"
TARGET_DIR="${TARGET_DIR:-${BUILD_ROOT}/bin/targets/mediatek/filogic}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${RUNNER_TEMP}/mt3600be-artifacts}"
WRT_NAME="${WRT_NAME:-GL-MT3600BE}"
WRT_DEVICE_LABEL="${WRT_DEVICE_LABEL:-GL.iNet GL-MT3600BE}"
DEVICE_NAME="${DEVICE_NAME:-glinet_gl-mt3600be}"
DEVICE_DTS="${DEVICE_DTS:-mt7987a-glinet-gl-mt3600be}"
REPO_BRANCH="${REPO_BRANCH:-main}"
FEEDS_PROFILE="${FEEDS_PROFILE:-immortalwrt-compatible}"
RELEASE_TAG_PREFIX="${RELEASE_TAG_PREFIX:-mt3600be-openwrt}"
TEST_ONLY="${TEST_ONLY:-0}"

collect_artifacts() {
  local file
  local files=()

  rm -rf "${ARTIFACT_DIR}"
  mkdir -p "${ARTIFACT_DIR}"

  files+=("${RUNNER_TEMP}/build.log")

  if [[ -f "${BUILD_ROOT}/.config" ]]; then
    cp -v "${BUILD_ROOT}/.config" "${ARTIFACT_DIR}/${WRT_CONFIG}.config"
  fi

  if [[ -f "${BUILD_ROOT}/tmp/dropped-packages.txt" ]]; then
    cp -v "${BUILD_ROOT}/tmp/dropped-packages.txt" "${ARTIFACT_DIR}/dropped-packages.txt"
    if [[ ! -s "${ARTIFACT_DIR}/dropped-packages.txt" ]]; then
      # 中文：GitHub Release 不能稳定上传 0 字节资产；用说明行表示没有被丢弃的请求包。
      printf '%s\n' '# 中文：没有被 defconfig 丢弃的请求包。' > "${ARTIFACT_DIR}/dropped-packages.txt"
    fi
  fi

  if [[ "${TEST_ONLY}" != "1" ]]; then
    files+=(
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*sysupgrade*.bin
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*initramfs*.bin
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*.itb
      "${TARGET_DIR}"/*"${DEVICE_DTS}"*.bin
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*.bin
      "${TARGET_DIR}"/*.buildinfo
      "${TARGET_DIR}"/*.json
      "${TARGET_DIR}"/*.manifest
    )
  fi

  for file in "${files[@]}"; do
    if [[ -f "${file}" ]]; then
      cp -v "${file}" "${ARTIFACT_DIR}/"
    fi
  done

  if ! find "${ARTIFACT_DIR}" -maxdepth 1 -type f | grep -q .; then
    echo "No artifacts were collected."
    exit 1
  fi

  (
    cd "${ARTIFACT_DIR}"
    sha256sum * > SHA256SUMS
    ls -lh
  )
}

detect_kernel_version() {
  local kernel_patchver=""
  local kernel_suffix=""
  local target_makefile="${BUILD_ROOT}/target/linux/mediatek/Makefile"
  local kernel_details_file

  if [[ -f "${target_makefile}" ]]; then
    kernel_patchver="$(awk -F':=' '/^[[:space:]]*KERNEL_PATCHVER[[:space:]]*:=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${target_makefile}")"
  fi

  if [[ -z "${kernel_patchver}" ]]; then
    echo "unknown"
    return 0
  fi

  kernel_details_file="${BUILD_ROOT}/target/linux/generic/kernel-${kernel_patchver}"
  if [[ -f "${kernel_details_file}" ]]; then
    kernel_suffix="$(awk -F'=' -v patchver="${kernel_patchver}" '$1 ~ "^[[:space:]]*LINUX_VERSION-" patchver "[[:space:]]*$" { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${kernel_details_file}")"
  fi

  echo "Linux ${kernel_patchver}${kernel_suffix}"
}

prepare_release_metadata() {
  local branch_slug
  local build_commit
  local build_time
  local kernel_version
  local tag
  local title
  local notes_file

  branch_slug="$(printf '%s' "${REPO_BRANCH}" | tr '/ ' '--' | tr -cd '[:alnum:]._-')"
  build_commit="$(git -C "${BUILD_ROOT}" rev-parse --short=12 HEAD)"
  build_time="$(date -u +'%Y%m%d-%H%M%S')"
  kernel_version="$(detect_kernel_version)"
  tag="${RELEASE_TAG_PREFIX}-${branch_slug}-${build_time}-run${GITHUB_RUN_NUMBER:-local}"
  title="${WRT_DEVICE_LABEL} OpenWrt ${branch_slug} ${build_time}"
  notes_file="${RUNNER_TEMP}/release-notes.md"

  {
    echo "# ${WRT_DEVICE_LABEL} automated OpenWrt build"
    echo
    echo "- Source: \`openwrt/openwrt\`"
    echo "- Branch: \`${REPO_BRANCH}\`"
    echo "- Feeds profile: \`${FEEDS_PROFILE}\`"
    echo "- Config: \`${WRT_CONFIG}\`"
    echo "- Kernel: \`${kernel_version}\`"
    echo "- Commit: \`${build_commit}\`"
    if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
      echo "- Workflow run: [#${GITHUB_RUN_NUMBER}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
    fi
    echo
    echo "Firmware files and checksums are attached below."
  } > "${notes_file}"

  {
    echo "tag=${tag}"
    echo "title=${title}"
    echo "notes_file=${notes_file}"
  } >> "${GITHUB_OUTPUT}"
}

case "${1:-}" in
  collect-artifacts)
    collect_artifacts
    ;;
  prepare-release-metadata)
    prepare_release_metadata
    ;;
  *)
    echo "Usage: $0 collect-artifacts|prepare-release-metadata"
    exit 1
    ;;
esac
