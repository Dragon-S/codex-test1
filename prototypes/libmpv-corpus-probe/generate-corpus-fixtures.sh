#!/bin/bash
set -euo pipefail

OUTPUT_DIR="${1:-/private/tmp/codex-test1-generated-corpus}"
FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg || true)}"

if [[ -z "$FFMPEG_BIN" ]]; then
  echo "错误：需要可用的 ffmpeg 来生成无版权测试样本" >&2
  exit 69
fi

mkdir -p "$OUTPUT_DIR"

# 生成内容只包含测试图案、合成正弦波与静音，不引用第三方媒体。
"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=60000/1001:duration=6" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -b:v 5M \
  -pix_fmt yuv420p -c:a libopus -b:a 128k -shortest \
  "$OUTPUT_DIR/webm-vp9-opus-1080p5994.webm"

"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=60:duration=12" \
  -vf "select='if(lt(t,4),not(mod(n,2)),if(lt(t,8),not(mod(n,3)),1))'" \
  -fps_mode vfr -c:v libx264 -preset ultrafast -crf 23 -pix_fmt yuv420p \
  "$OUTPUT_DIR/video-vfr-h264.mkv"

"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=12" \
  -c:v libx264 -preset ultrafast -crf 23 -g 240 -keyint_min 240 \
  -sc_threshold 0 -pix_fmt yuv420p "$OUTPUT_DIR/video-long-gop-h264.mkv"

"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=5" \
  -c:a libmp3lame -b:a 192k "$OUTPUT_DIR/audio-mp3.mp3"
"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=5" \
  -c:a aac -b:a 192k "$OUTPUT_DIR/audio-aac.m4a"
"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=5" \
  -c:a alac "$OUTPUT_DIR/audio-alac.m4a"
"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=5" \
  -c:a flac "$OUTPUT_DIR/audio-flac.flac"
"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=5" \
  -c:a pcm_s24le "$OUTPUT_DIR/audio-wav-24bit.wav"
"$FFMPEG_BIN" -hide_banner -loglevel warning -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=5" \
  -c:a libopus -b:a 128k "$OUTPUT_DIR/audio-opus.ogg"

dd if="$OUTPUT_DIR/webm-vp9-opus-1080p5994.webm" \
  of="$OUTPUT_DIR/damaged-truncated.webm" bs=1024 count=128 status=none
cp "$OUTPUT_DIR/audio-mp3.mp3" "$OUTPUT_DIR/forged-extension.mp4"
dd if=/dev/zero of="$OUTPUT_DIR/not-media.mp4" bs=1024 count=4 status=none

for fixture in "$OUTPUT_DIR"/*; do
  shasum -a 256 "$fixture"
done
