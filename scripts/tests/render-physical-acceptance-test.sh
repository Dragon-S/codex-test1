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

physical_scenarios=(Q34-P01 Q34-P02 Q34-P03 Q34-P04 Q34-P05 Q34-P06 Q34-P07)
blocking_checks=(Q34-B01 Q34-B02 Q34-B03 Q34-B04 Q34-B05 Q34-B06 Q34-B07 Q34-B08)
metadata_scenarios=($physical_scenarios Q34-B02 Q34-B08)
required_scenario_fields=(初始状态 操作 预期 恢复 候选构建 macOS 设备 语言 外观 \
                          辅助功能设置 证据 结果)

section_body() {
  local heading="$1"
  awk -v heading="### $heading " '
    index($0, heading) == 1 { in_section = 1; next }
    in_section && /^### / { exit }
    in_section { print }
  ' "$output"
}

for scenario in $physical_scenarios $blocking_checks; do
  grep -Fq "$scenario" "$output"
done

for scenario in $metadata_scenarios; do
  section="$(section_body "$scenario")"

  for field in $required_scenario_fields; do
    grep -Fq -- "- $field：" <<< "$section"
  done
done

performance_section="$(section_body Q34-B03)"

for requirement in "1080p" "纯音频" "384 MiB" "4K" "512 MiB"; do
  grep -Fq -- "$requirement" <<< "$performance_section"
done

if grep -Eq '\{\{(COMMIT|BUILD_ID|BUILT_AT)\}\}|40cdeaee6edcd9d3f5be871e87f79db554ad1393' "$output"; then
  print -u2 "物理验收清单仍包含未替换占位符或旧候选身份"
  exit 1
fi
