#!/usr/bin/env bash

patch_proxy_service() {
  local backend="$1" init_file="$2" output="${2}.proxy-guard"
  local invocation="  proxy_guard_enter ${backend} \"\${action}\" || exit 1"
  [[ -f "${init_file}" ]] || { echo "Missing proxy init: ${init_file}" >&2; return 1; }
  if grep -Fqx "${invocation}" "${init_file}"; then
    return 0
  fi
  grep -Fqx '#!/bin/sh /etc/rc.common' "${init_file}" &&
    grep -Fqx 'USE_PROCD=1' "${init_file}" &&
    grep -Fqx 'start_service() {' "${init_file}" || {
      echo "Unsupported ${backend} init layout: ${init_file}" >&2; return 1;
    }
  # 中文：在 rc.common 获取各自 procd 锁之前取得公共锁；非运行操作不依赖根文件系统 overlay。
  awk -v invocation="${invocation}" '
    { print }
    NR == 1 {
      print "# 中文：共用网络资源的后端只能运行一个，停止操作同样不得清理其它后端。"
      print "case \"${action:-}\" in"
      print "start|boot|restart|reload|hot_reload|stop|shutdown|trace)"
      print "  . /usr/share/mt3600be/proxy-guard.sh || exit 1"
      print invocation
      print "  ;;"
      print "esac"
    }
  ' "${init_file}" > "${output}"
  mv "${output}" "${init_file}"
  echo "Installed service-layer mutual exclusion: ${backend}"
}

prepare_proxy_services() {
  local backend
  for backend in dae daed honk; do
    config_package_enabled "${backend}" || continue
    patch_proxy_service "${backend}" "${BUILD_ROOT}/package/${backend}/files/${backend}.init"
  done
}
