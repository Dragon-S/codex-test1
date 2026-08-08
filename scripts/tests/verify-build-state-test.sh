#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

git -C "$fixture_root" init -q
git -C "$fixture_root" config user.name "候选构建测试"
git -C "$fixture_root" config user.email "candidate-test@example.invalid"
print -r -- "基线" > "$fixture_root/tracked.txt"
git -C "$fixture_root" add tracked.txt
git -C "$fixture_root" commit -qm "建立基线"
expected_commit="$(git -C "$fixture_root" rev-parse HEAD)"

"$repository_root/scripts/verify-build-state.sh" "$fixture_root" "$expected_commit"

print -r -- "未跟踪" > "$fixture_root/untracked.txt"
if "$repository_root/scripts/verify-build-state.sh" "$fixture_root" "$expected_commit" >/dev/null 2>&1; then
  print -u2 "构建状态验证器错误接受了脏工作区"
  exit 1
fi
rm "$fixture_root/untracked.txt"

print -r -- "新提交" >> "$fixture_root/tracked.txt"
git -C "$fixture_root" add tracked.txt
git -C "$fixture_root" commit -qm "改变 HEAD"
if "$repository_root/scripts/verify-build-state.sh" "$fixture_root" "$expected_commit" >/dev/null 2>&1; then
  print -u2 "构建状态验证器错误接受了变化的 HEAD"
  exit 1
fi
