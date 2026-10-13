#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${project_root}/files/usr/share/mt3600be/proxy-guard.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
source "${guard}"

# 中文：仅替换系统 I/O，运行真实互斥逻辑；不把这些测试替身装入固件。
fixture_snapshot='{}'
ubus() { [[ "${probe_error:-0}" == 0 ]] && printf '%s\n' "$fixture_snapshot"; }
logger() { printf '%s\n' "$*" >> "${test_dir}/syslog"; }
pidof() {
  local name
  for name in "$@"; do
    if [[ " ${processes:-} " == *" $name "* ]]; then printf '123\n'; return 0; fi
  done
  return 1
}
jsonfilter() {
  [[ "$1" == -s ]] || return 2
  [[ "$2" != invalid ]] || return 2
  if [[ "$3" == -t && "$4" == '@' ]]; then
    [[ "$2" != '[]' ]] || { printf 'array\n'; return 0; }
    printf 'object\n'; return 0
  fi
  [[ "$3" == -e ]] || return 2
  local peer
  for peer in dae daed honk; do
    [[ "$4" == "@[\"${peer}\"].instances.*" ]] || continue
    [[ "$2" == *"\"${peer}\""* ]] || return 1
    printf '{"running":false,"command":["/usr/bin/test-fixture"]}\n'
    return 0
  done
  return 2
}

expect_blocked() {
  if (proxy_guard_enter "$1" "$2" "${test_dir}/proxy.lock") > "${test_dir}/error" 2>&1; then
    echo "Unexpected admission: $1 $2, ${fixture_snapshot}, ${processes:-}" >&2
    exit 1
  fi
  grep -Fq "$3" "${test_dir}/error"
}

test_admission_matrix() {
  local owner peer action
  for owner in dae daed honk; do
    for peer in dae daed honk; do
      [[ "$owner" != "$peer" ]] || continue
      fixture_snapshot="{\"$peer\":{\"instances\":{\"main\":{\"running\":false}}}}"
      for action in start boot restart reload hot_reload stop shutdown trace; do
        expect_blocked "$owner" "$action" "$peer"
      done
    done
  done
}

test_process_and_error_paths() {
  fixture_snapshot='{}'
  local owner peer binary
  for owner in dae daed honk; do
    for peer in dae daed honk; do
      [[ "$owner" != "$peer" ]] || continue
      binary="$peer"
      [[ "$peer" != honk ]] || binary=honk-core
      processes="$binary"
      expect_blocked "$owner" start "$peer"
    done
  done
  processes=daed-guard
  expect_blocked honk start daed
  expect_blocked dae start daed
  processes=''
  probe_error=1
  expect_blocked dae start 'ubus'
  probe_error=0
  fixture_snapshot=invalid
  expect_blocked daed start 'JSON'
  fixture_snapshot='[]'
  expect_blocked honk start 'JSON'
  fixture_snapshot='{}'
}

test_allowed_paths() {
  local owner action
  for owner in dae daed honk; do
    fixture_snapshot="{\"$owner\":{\"instances\":{\"main\":{\"running\":true}}}}"
    processes="$owner"
    for action in start restart stop reload; do
      (proxy_guard_enter "$owner" "$action" "${test_dir}/proxy.lock")
    done
  done
  probe_error=1
  for action in status running enabled enable disable help; do
    (proxy_guard_enter dae "$action" "${test_dir}/proxy.lock")
  done
  probe_error=0
  processes=''
  fixture_snapshot='{}'
}

# 中文：Windows Git Bash 没有 flock；只替换锁 I/O 做准入单测，Linux CI 必须使用真实锁。
if [[ "$(uname -s)" != Linux ]]; then
  flock() { [[ "$1" == -n && "$2" == 9 ]]; }
  echo 'NOTE: real flock concurrency is not available on Windows; Linux CI runs it.'
else
  command -v flock >/dev/null
fi
test_admission_matrix
test_process_and_error_paths
test_allowed_paths
expect_blocked unknown start 'Unknown'

if [[ "$(uname -s)" == Linux ]]; then
  # 中文：锁在准入函数返回后仍须持有，直到整个 init/procd 登记事务结束。
  mkfifo "${test_dir}/release"
  (
    proxy_guard_enter dae start "${test_dir}/proxy.lock"
    touch "${test_dir}/locked"
    read -r _ < "${test_dir}/release"
  ) &
  owner_pid=$!
  until [[ -e "${test_dir}/locked" ]]; do sleep 0.01; done
  expect_blocked honk start 'busy'
  expect_blocked daed start 'busy'
  printf 'release\n' > "${test_dir}/release"
  wait "${owner_pid}"
  (proxy_guard_enter honk start "${test_dir}/proxy.lock")
  echo 'Real flock transaction serialization and release passed.'
fi

echo 'Proxy service bidirectional exclusion and error-path checks passed.'
