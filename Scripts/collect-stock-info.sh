#!/usr/bin/env bash

set -eu

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD/stock-info-$STAMP}"

mkdir -p "${OUT_DIR}"

save_cmd() {
  local name="$1"
  shift

  {
    echo "# $*"
    echo
    "$@" 2>&1
  } > "${OUT_DIR}/${name}.txt" || true
}

save_cmd board ubus call system board
save_cmd dmesg dmesg
save_cmd partitions cat /proc/mtd
save_cmd mounts mount
save_cmd block block info
save_cmd packages sh -c 'command -v apk >/dev/null 2>&1 && apk list --installed || opkg list-installed'
save_cmd wireless iwinfo
save_cmd ip_addr ip addr
save_cmd ip_route ip route
save_cmd env fw_printenv

for path in \
  /etc/config/network \
  /etc/config/wireless \
  /etc/config/firewall \
  /etc/config/system \
  /etc/config/dhcp \
  /etc/config/fstab
do
  if [ -f "${path}" ]; then
    cp "${path}" "${OUT_DIR}/$(basename "${path}").conf"
  fi
done

echo "Saved stock information to ${OUT_DIR}"
