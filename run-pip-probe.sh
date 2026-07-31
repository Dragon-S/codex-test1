#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "用法：./run-pip-probe.sh /绝对路径/视频文件"
  exit 64
fi

if [[ ! -f "$1" ]]; then
  print -u2 "视频文件不存在：$1"
  exit 66
fi

if ! pkg-config --exists mpv 2>/dev/null; then
  print -u2 "缺少 libmpv。请先运行：brew install mpv pkg-config"
  exit 69
fi

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product pip-probe

binary_dir="$(swift build --show-bin-path)"
app_dir="$binary_dir/LibmpvNativePiPProbe.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/pip-probe" "$app_dir/Contents/MacOS/pip-probe"
cp App/Info.plist "$app_dir/Contents/Info.plist"

exec "$app_dir/Contents/MacOS/pip-probe" "$1"
