#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
defaults_file="${project_root}/files/etc/uci-defaults/99-beryl7-defaults"

# 中文：检查首次启动配置的最终 LAN 地址，并阻止旧地址意外回归。
grep -Fqx "set network.lan.ipaddr='192.168.18.1'" "${defaults_file}"
if grep -Fq '192.168.16.1' "${defaults_file}"; then
  echo '检测到旧的默认 LAN 地址 192.168.16.1。'
  exit 1
fi

printf '%s\n' '默认 LAN IP 检查通过。'
