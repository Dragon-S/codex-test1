#!/bin/bash
set -euo pipefail

usage() {
  echo "用法: $0 --engine-root <包含 include/ 与 lib/ 的目录> --media <本地媒体文件> [--sample-id <非敏感样本 ID>] [--evidence-dir <目录>] [--auto-exit-seconds <秒>] [--mute-audio] [--long-audio-check]"
}

ENGINE_ROOT=""
MEDIA_PATH=""
SAMPLE_ID="local-sample"
EVIDENCE_DIR="$(pwd)/prototypes/libmpv-corpus-probe/evidence"
AUTO_EXIT_SECONDS="0"
MUTE_AUDIO="no"
LONG_AUDIO_CHECK="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-root)
      ENGINE_ROOT="$2"
      shift 2
      ;;
    --media)
      MEDIA_PATH="$2"
      shift 2
      ;;
    --sample-id)
      SAMPLE_ID="$2"
      shift 2
      ;;
    --evidence-dir)
      EVIDENCE_DIR="$2"
      shift 2
      ;;
    --auto-exit-seconds)
      AUTO_EXIT_SECONDS="$2"
      shift 2
      ;;
    --mute-audio)
      MUTE_AUDIO="yes"
      shift
      ;;
    --long-audio-check)
      LONG_AUDIO_CHECK="yes"
      shift
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$ENGINE_ROOT" || -z "$MEDIA_PATH" ]]; then
  usage
  exit 64
fi

if [[ ! -f "$ENGINE_ROOT/include/mpv/client.h" || ! -f "$ENGINE_ROOT/lib/libmpv.2.dylib" ]]; then
  echo "错误：--engine-root 必须包含 include/mpv/client.h 和 lib/libmpv.2.dylib" >&2
  exit 66
fi

if [[ ! -f "$MEDIA_PATH" ]]; then
  echo "错误：媒体文件不存在：$MEDIA_PATH" >&2
  exit 66
fi

if MEDIA_SHA256="$(shasum -a 256 "$MEDIA_PATH" 2>/dev/null | awk '{print $1}')"; then
  :
else
  # 访问失败本身也是语料场景；让 libmpv 产生可观测错误，而不是被探针预处理拦截。
  MEDIA_SHA256="unavailable"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_DIR="$BUILD_DIR/LibmpvCorpusProbe.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
mkdir -p "$MACOS_DIR" "$EVIDENCE_DIR"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -DGL_SILENCE_DEPRECATION \
  -mmacosx-version-min=14.0 \
  -I"$ENGINE_ROOT/include" \
  "$SCRIPT_DIR/LibmpvCorpusProbe.m" \
  "$ENGINE_ROOT/lib/libmpv.2.dylib" \
  -framework Cocoa \
  -framework QuartzCore \
  -Wl,-rpath,"$ENGINE_ROOT/lib" \
  -o "$MACOS_DIR/LibmpvCorpusProbe"

exec "$MACOS_DIR/LibmpvCorpusProbe" \
  --media "$MEDIA_PATH" \
  --sample-id "$SAMPLE_ID" \
  --media-sha256 "$MEDIA_SHA256" \
  --evidence-dir "$EVIDENCE_DIR" \
  --auto-exit-seconds "$AUTO_EXIT_SECONDS" \
  --mute-audio "$MUTE_AUDIO" \
  --long-audio-check "$LONG_AUDIO_CHECK"
