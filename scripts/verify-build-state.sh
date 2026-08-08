#!/bin/zsh

set -euo pipefail

if (( $# != 2 )); then
  print -u2 "用法：${0:t} <仓库根目录> <预期提交>"
  exit 64
fi

repository_root="${1:A}"
expected_commit="$2"

fail() {
  print -u2 "候选构建状态无效：$1"
  exit 1
}

[[ -d "$repository_root/.git" || -f "$repository_root/.git" ]] \
  || fail "仓库根目录无效"

actual_commit="$(git -C "$repository_root" rev-parse HEAD)"
[[ "$actual_commit" == "$expected_commit" ]] \
  || fail "构建期间 HEAD 已从 $expected_commit 变为 $actual_commit"

[[ -z "$(git -C "$repository_root" status --porcelain)" ]] \
  || fail "构建期间工作区产生了未提交或未跟踪内容"
