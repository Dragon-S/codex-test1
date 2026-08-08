#!/bin/zsh

set -euo pipefail

if (( $# != 2 )); then
  print -u2 "用法：${0:t} <ENGINE_ROOT> <快照目录>"
  exit 64
fi

source_root="${1:A}"
snapshot_root="${2:A}"

fail() {
  print -u2 "引擎输入快照失败：$1"
  exit 1
}

[[ ! -e "$snapshot_root" ]] || fail "目标已存在：$snapshot_root"
for directory in include lib notices; do
  [[ -d "$source_root/$directory" ]] || fail "源目录缺少 $directory"
done

mkdir -p "$snapshot_root"
for directory in include lib notices; do
  ditto "$source_root/$directory" "$snapshot_root/$directory"
done
chmod -R a-w "$snapshot_root"
