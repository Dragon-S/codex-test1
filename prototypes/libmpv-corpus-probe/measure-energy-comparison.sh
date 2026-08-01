#!/bin/bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
  echo "用法: $0 <标签> <PID> <输出 JSONL> [秒数，默认 1800] [采样间隔，默认 60]" >&2
  exit 64
fi

LABEL="$1"
TARGET_PID="$2"
OUTPUT_PATH="$3"
DURATION_SECONDS="${4:-1800}"
INTERVAL_SECONDS="${5:-60}"

if ! kill -0 "$TARGET_PID" 2>/dev/null; then
  echo "错误：PID $TARGET_PID 不存在" >&2
  exit 66
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
: > "$OUTPUT_PATH"

read_battery_field() {
  local field="$1"
  ioreg -r -n AppleSmartBattery |
    sed -n "s/.*\"${field}\" = \([0-9][0-9]*\).*/\1/p" |
    head -1
}

read_system_energy() {
  ioreg -r -n AppleSmartBattery |
    sed -n 's/.*"AccumulatedSystemEnergyConsumed"=\([0-9][0-9]*\).*/\1/p' |
    head -1
}

START_EPOCH="$(date +%s)"
while true; do
  NOW_EPOCH="$(date +%s)"
  ELAPSED="$((NOW_EPOCH - START_EPOCH))"
  TARGET_ALIVE=true
  if kill -0 "$TARGET_PID" 2>/dev/null; then
    PROCESS_STATS="$(ps -p "$TARGET_PID" -o %cpu=,rss=,time=,state= | xargs)"
  else
    TARGET_ALIVE=false
    PROCESS_STATS=""
  fi

  SYSTEM_ENERGY="$(read_system_energy)"
  BATTERY_TEMPERATURE="$(read_battery_field Temperature)"
  LOAD_AVERAGE="$(sysctl -n vm.loadavg)"
  THERMAL_STATUS="$(pmset -g therm | tr '\n' ';')"

  jq -cn \
    --arg label "$LABEL" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg process_stats "$PROCESS_STATS" \
    --arg load_average "$LOAD_AVERAGE" \
    --arg thermal_status "$THERMAL_STATUS" \
    --argjson elapsed "$ELAPSED" \
    --argjson target_alive "$TARGET_ALIVE" \
    --argjson system_energy "${SYSTEM_ENERGY:-null}" \
    --argjson battery_temperature_centi_celsius "${BATTERY_TEMPERATURE:-null}" \
    '{kind:"sample", label:$label, timestamp:$timestamp,
      elapsed_seconds:$elapsed, target_alive:$target_alive,
      process_stats:(if $process_stats == "" then null else $process_stats end),
      system_energy_counter:$system_energy,
      battery_temperature_centi_celsius:$battery_temperature_centi_celsius,
      load_average:$load_average, thermal_status:$thermal_status}' >> "$OUTPUT_PATH"

  if [[ "$TARGET_ALIVE" == false ]]; then
    if (( ELAPSED >= DURATION_SECONDS )); then
      break
    fi
    exit 1
  fi
  if (( ELAPSED >= DURATION_SECONDS )); then
    break
  fi
  REMAINING="$((DURATION_SECONDS - ELAPSED))"
  if (( REMAINING < INTERVAL_SECONDS )); then
    sleep "$REMAINING"
  else
    sleep "$INTERVAL_SECONDS"
  fi
done
