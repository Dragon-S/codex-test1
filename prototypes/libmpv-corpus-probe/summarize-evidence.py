#!/usr/bin/env python3
"""把一次或多次探针 JSONL 汇总成可贴到决策票的 Markdown。"""

from __future__ import annotations

import json
import math
import pathlib
import sys
from collections import defaultdict


def percentile95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]


def format_number(value: float | None, suffix: str = "") -> str:
    return "—" if value is None else f"{value:.3f}{suffix}"


if len(sys.argv) < 2:
    raise SystemExit(f"用法: {sys.argv[0]} <probe-*.jsonl> [更多 JSONL]")

records: list[dict] = []
for argument in sys.argv[1:]:
    path = pathlib.Path(argument)
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: JSON 无效：{error}") from error

latencies: dict[str, list[float]] = defaultdict(list)
resume_errors: list[float] = []
resident_mib: list[float] = []
decoder_drops: list[int] = []
output_drops: list[int] = []
failures: list[str] = []
samples = sorted(
    {
        record.get("sample_id") or record.get("media")
        for record in records
        if record.get("kind") == "session_started"
        and (record.get("sample_id") or record.get("media"))
    }
)

for record in records:
    if record.get("kind") == "mpv_event":
        action = record.get("trigger_action")
        latency = record.get("action_to_restart_ms")
        if action and isinstance(latency, (int, float)):
            latencies[action].append(float(latency))
        if isinstance(record.get("resume_error_seconds"), (int, float)):
            resume_errors.append(float(record["resume_error_seconds"]))
        if record.get("event") == "end-file" and record.get("raw_error") not in (
            None,
            "success",
        ):
            failures.append(
                f"{record.get('raw_error')} → {record.get('suggested_domain_error', '未分类')}"
            )
    elif record.get("kind") == "action":
        result = record.get("result")
        if isinstance(result, int) and result < 0:
            failures.append(
                f"{record.get('action')}：{record.get('error', '未知错误')}"
            )

    state = record.get("state") or {}
    if isinstance(state.get("resident_mib"), (int, float)):
        resident_mib.append(float(state["resident_mib"]))
    if isinstance(state.get("decoder_dropped_frames"), int):
        decoder_drops.append(state["decoder_dropped_frames"])
    if isinstance(state.get("output_dropped_frames"), int):
        output_drops.append(state["output_dropped_frames"])

print("# libmpv 语料探针证据摘要")
print()
print(f"- 会话：{sum(1 for record in records if record.get('kind') == 'session_started')}")
print(f"- 样本：{len(samples)}")
print(f"- 记录：{len(records)}")
print(f"- 最大观测 RSS：{format_number(max(resident_mib) if resident_mib else None, ' MiB')}")
print(
    f"- 最大解码/输出掉帧计数："
    f"{max(decoder_drops) if decoder_drops else '—'}/"
    f"{max(output_drops) if output_drops else '—'}"
)
print(
    f"- 最大续播误差："
    f"{format_number(max(resume_errors) if resume_errors else None, ' 秒')}"
)
print()
print("## 操作到播放恢复")
print()
print("| 操作 | 次数 | P95 | 单次最大 |")
print("| --- | ---: | ---: | ---: |")
for action in sorted(latencies):
    values = latencies[action]
    print(
        f"| `{action}` | {len(values)} | "
        f"{format_number(percentile95(values), ' ms')} | "
        f"{format_number(max(values), ' ms')} |"
    )

print()
print("## 失败")
print()
if failures:
    for failure in sorted(set(failures)):
        print(f"- {failure}")
else:
    print("- 本批 JSONL 未记录命令或播放失败。")

print()
print("## 样本")
print()
for sample in samples:
    print(f"- `{sample}`")
