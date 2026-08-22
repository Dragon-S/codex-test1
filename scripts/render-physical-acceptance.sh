#!/bin/zsh

set -euo pipefail

if (( $# != 4 )); then
  print -u2 "用法：${0:t} <输出文件> <候选提交> <可执行文件 SHA-256> <构建时间 UTC>"
  exit 64
fi

repository_root="${0:A:h:h}"
output="$1"
commit="$2"
build_id="$3"
built_at="$4"
template="$repository_root/docs/internal-mvp-physical-acceptance-template.md"

fail() {
  print -u2 "物理验收清单生成失败：$1"
  exit 1
}

[[ -f "$template" ]] || fail "缺少模板 $template"
print -r -- "$commit" | grep -Eq '^[0-9a-f]{40}$' \
  || fail "候选提交必须是 40 位小写十六进制 SHA"
print -r -- "$build_id" | grep -Eq '^[0-9a-f]{64}$' \
  || fail "构建身份必须是 64 位小写十六进制 SHA-256"
print -r -- "$built_at" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' \
  || fail "构建时间必须使用 YYYYMMDDTHHMMSSZ"

mkdir -p "${output:A:h}"
sed \
  -e "s/{{COMMIT}}/$commit/g" \
  -e "s/{{BUILD_ID}}/$build_id/g" \
  -e "s/{{BUILT_AT}}/$built_at/g" \
  "$template" > "$output"

if grep -Eq '\{\{(COMMIT|BUILD_ID|BUILT_AT)\}\}' "$output"; then
  fail "输出仍包含未替换占位符"
fi
