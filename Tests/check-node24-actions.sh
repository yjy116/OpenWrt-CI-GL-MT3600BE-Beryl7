#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_dir="${project_root}/.github/workflows"
core_workflow="${workflow_dir}/WRT-CORE.yml"

# 中文：这些最低主版本默认使用 Node.js 24，避免 GitHub Actions 的 Node.js 20 弃用告警。
if grep -R -nE 'uses: actions/checkout@v[1-4]([[:space:]]|$)' "${workflow_dir}"; then
	printf '%s\n' '检测到仍使用 Node.js 20 的 actions/checkout。' >&2
	exit 1
fi

if grep -R -nE 'uses: actions/cache/(restore|save)@v[1-4]([[:space:]]|$)' "${workflow_dir}"; then
	printf '%s\n' '检测到仍使用 Node.js 20 的 actions/cache。' >&2
	exit 1
fi

if grep -R -nE 'uses: actions/upload-artifact@v[1-5]([[:space:]]|$)' "${workflow_dir}"; then
	printf '%s\n' '检测到仍使用 Node.js 20 的 actions/upload-artifact。' >&2
	exit 1
fi

# 中文：核心流程应完整覆盖签出、两组缓存的恢复与保存，以及构建产物上传。
grep -Fqx '        uses: actions/checkout@v5' "${core_workflow}"
test "$(grep -Fc 'uses: actions/cache/restore@v5' "${core_workflow}")" -eq 2
test "$(grep -Fc 'uses: actions/cache/save@v5' "${core_workflow}")" -eq 2
grep -Fqx '        uses: actions/upload-artifact@v6' "${core_workflow}"

printf '%s\n' 'GitHub Actions Node.js 24 运行时检查通过。'
