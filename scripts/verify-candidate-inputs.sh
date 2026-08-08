#!/bin/zsh

set -euo pipefail

if (( $# != 3 )); then
  print -u2 "用法：${0:t} <ENGINE_ROOT> <sources.lock> <仓库根目录>"
  exit 64
fi

engine_root="${1:A}"
source_lock="${2:A}"
repository_root="${3:A}"

fail() {
  print -u2 "候选输入无效：$1"
  exit 1
}

[[ -f "$source_lock" ]] || fail "找不到源码锁文件 $source_lock"
[[ -d "$repository_root/.git" || -f "$repository_root/.git" ]] || fail "仓库根目录无效"
[[ -d "$engine_root/include/mpv" ]] || fail "缺少 libmpv 头文件目录"
[[ -d "$engine_root/lib" ]] || fail "缺少动态库目录"
[[ -d "$engine_root/notices" ]] || fail "缺少许可材料目录"

required_sources=(
  mpv ffmpeg libplacebo libass harfbuzz fribidi freetype
  vulkan-headers fast-float glad jinja markupsafe pkgconf meson ninja
)

for source_name in $required_sources; do
  line="$(awk -F '|' -v name="$source_name" '$1 == name { print; count += 1 } END { if (count != 1) exit 1 }' "$source_lock")" \
    || fail "源码锁必须且只能包含一个 $source_name"
  revision="${line##*|}"
  [[ "$revision" =~ '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ]] \
    || fail "$source_name 缺少 Git 提交或归档 SHA-256"
done

grep -q '^mpv|https://github.com/mpv-player/mpv.git|v0.41.0|41f6a645068483470267271e1d09966ca3b9f413$' "$source_lock" \
  || fail "mpv 必须锁定 v0.41.0"
grep -q '^ffmpeg|https://github.com/FFmpeg/FFmpeg.git|n8.1.2|38b88335f99e76ed89ff3c93f877fdefce736c13$' "$source_lock" \
  || fail "FFmpeg 必须锁定 n8.1.2"

build_proof="$repository_root/prototypes/lgpl-packaging-proof/BUILD.md"
runtime_lock="$repository_root/prototypes/lgpl-packaging-proof/runtime-closure.sha256"
notice_lock="$repository_root/prototypes/lgpl-packaging-proof/notices.sha256"
project_file="$repository_root/MacMediaPlayer/MacMediaPlayer.xcodeproj/project.pbxproj"
entitlements="$repository_root/MacMediaPlayer/App/MacMediaPlayer.entitlements"
client_header="$repository_root/MacMediaPlayer/App/MPVClient.h"

for required_flag in \
  '--wrap-mode=nodownload' \
  '--disable-gpl' \
  '--disable-nonfree' \
  '--disable-network' \
  '-Dgpl=false' \
  '-Dcplugins=disabled' \
  '-Djavascript=disabled' \
  '-Dlua=disabled'
do
  grep -Fq -- "$required_flag" "$build_proof" \
    || fail "构建证明缺少禁止项开关 $required_flag"
done

grep -Fq 'ENABLE_APP_SANDBOX = YES' "$project_file" || fail "目标未启用 App Sandbox"
grep -Fq 'ENABLE_HARDENED_RUNTIME = YES' "$project_file" || fail "目标未启用 Hardened Runtime"
grep -Fq 'ENABLE_LIBRARY_VALIDATION = YES' "$project_file" || fail "目标未启用 library validation"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements")" == true ]] \
  || fail "签名权限未启用 App Sandbox"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-only' "$entitlements")" == true ]] \
  || fail "签名权限未保持用户所选文件只读"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements" >/dev/null 2>&1; then
  fail "离线目标不得申请客户端网络权限"
fi
if grep -Eq 'performCommand|executeCommand|mpv_command' "$client_header"; then
  fail "MPVClient 公共头不得暴露通用 mpv 命令逃生口"
fi
if find "$repository_root/MacMediaPlayer/App" -type f \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) \
    -exec grep -El 'URLSession|NWConnection|Network\.framework' {} + | grep -q .; then
  fail "离线目标源码不得包含网络服务入口"
fi

required_dylibs=(
  libmpv.2.dylib
  libass.9.dylib
  libavcodec.62.dylib
  libavfilter.11.dylib
  libavformat.62.dylib
  libavutil.60.dylib
  libplacebo.338.dylib
  libswresample.6.dylib
  libswscale.9.dylib
  libfreetype.6.dylib
  libfribidi.0.dylib
  libharfbuzz.0.dylib
)

actual_dylibs="$(find "$engine_root/lib" -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | LC_ALL=C sort)"
expected_dylibs="$(printf '%s\n' $required_dylibs | LC_ALL=C sort)"
[[ "$actual_dylibs" == "$expected_dylibs" ]] \
  || fail "动态闭包必须精确包含锁定的 12 个 dylib"

required_notices=(
  mpv-Copyright.txt
  mpv-LGPL-2.1.txt
  FFmpeg-LICENSE.txt
  FFmpeg-LGPL-2.1.txt
  libplacebo-LICENSE.txt
  libass-COPYING.txt
  FreeType-LICENSE.txt
  FriBidi-COPYING.txt
  HarfBuzz-COPYING.txt
)

[[ -f "$engine_root/include/mpv/client.h" ]] || fail "缺少 mpv/client.h"
[[ -f "$engine_root/include/mpv/render_gl.h" ]] || fail "缺少 mpv/render_gl.h"

for notice in $required_notices; do
  [[ -s "$engine_root/notices/$notice" ]] || fail "缺少完整许可材料 $notice"
done

[[ -f "$runtime_lock" ]] || fail "缺少运行时闭包哈希锁"
[[ -f "$notice_lock" ]] || fail "缺少许可材料哈希锁"
(cd "$engine_root/lib" && shasum -a 256 -c "$runtime_lock" >/dev/null) \
  || fail "动态闭包内容与已验证哈希不一致"
(cd "$engine_root/notices" && shasum -a 256 -c "$notice_lock" >/dev/null) \
  || fail "许可材料内容与已验证哈希不一致"

for dylib_name in $required_dylibs; do
  dylib="$engine_root/lib/$dylib_name"
  architectures="$(lipo -archs "$dylib")" || fail "无法读取 $dylib_name 架构"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] \
    || fail "$dylib_name 必须同时包含 arm64 与 x86_64"

  install_name="$(otool -D "$dylib" | sed -n '2p')"
  [[ "$install_name" == "@rpath/$dylib_name" ]] \
    || fail "$dylib_name 安装名必须是 @rpath/$dylib_name"

  while IFS= read -r dependency; do
    dependency="${dependency#"${dependency%%[![:space:]]*}"}"
    [[ "$dependency" == *: ]] && continue
    dependency="${dependency%% *}"
    [[ -z "$dependency" ]] && continue
    case "$dependency" in
      @rpath/*.dylib)
        dependency_name="${dependency:t}"
        (( ${required_dylibs[(Ie)$dependency_name]} > 0 )) \
          || fail "$dylib_name 引用了闭包外动态库 $dependency_name"
        ;;
      /System/Library/*|/usr/lib/*) ;;
      *) fail "$dylib_name 含有非系统绝对依赖 $dependency" ;;
    esac
  done < <(otool -L "$dylib" | tail -n +2)
done

print -r -- "候选输入验证通过：mpv v0.41.0、FFmpeg n8.1.2、12 个双架构动态库及完整许可材料。"
