#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

output="$fixture_root/PHYSICAL-ACCEPTANCE.md"
commit="f01bed34bcc2a24982c194c64a46c42dacd23e1e"
build_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
built_at="20260809T151500Z"

"$repository_root/scripts/render-physical-acceptance.sh" \
  "$output" \
  "$commit" \
  "$build_id" \
  "$built_at"

grep -Fq -- "- 提交：\`$commit\`" "$output"
grep -Fq -- "- 构建身份（可执行文件 SHA-256）：\`$build_id\`" "$output"
grep -Fq -- "- 构建时间（UTC）：\`$built_at\`" "$output"
grep -Fq -- '- 当前状态：`AUTOMATED_PASS_PHYSICAL_PENDING`' "$output"

for scenario in Q34-P01 Q34-P02 Q34-P03 Q34-P04 Q34-P05 Q34-P06 Q34-P07 \
                Q34-B01 Q34-B02 Q34-B03 Q34-B04 Q34-B05 Q34-B06 Q34-B07; do
  grep -Fq "$scenario" "$output"
done

for field in 初始状态 操作 预期 恢复 候选构建 macOS 设备 语言 外观 \
             辅助功能设置 证据 结果; do
  grep -Fq "$field" "$output"
done

if grep -Eq '\{\{(COMMIT|BUILD_ID|BUILT_AT)\}\}|40cdeaee6edcd9d3f5be871e87f79db554ad1393' "$output"; then
  print -u2 "物理验收清单仍包含未替换占位符或旧候选身份"
  exit 1
fi
