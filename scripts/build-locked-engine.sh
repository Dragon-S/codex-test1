#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
  print -u2 "用法：${0:t} <空的输出目录>"
  exit 64
fi

repository_root="${0:A:h:h}"
artifact_root="${1:A}"
build_root="/private/tmp/Dragon-S-codex-test1-locked-engine-work"
source_lock="$repository_root/prototypes/lgpl-packaging-proof/sources.lock"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
jobs="$(sysctl -n hw.ncpu)"
source_cache="${LOCKED_ENGINE_SOURCE_CACHE:-}"

fail() {
  print -u2 "锁定引擎构建失败：$1"
  exit 1
}

[[ ! -e "$artifact_root" ]] || fail "输出目录已存在：$artifact_root"
[[ ! -e "$build_root" ]] || fail "固定构建目录已存在，请先保留或移走：$build_root"
mkdir -p "$build_root" "$build_root/build" "$build_root/prefix" "$build_root/downloads"

preserve_failed_build() {
  local exit_code=$?
  if (( exit_code != 0 )) && [[ -d "$build_root" ]]; then
    local failed_root="${artifact_root}.failed-$$"
    mv "$build_root" "$failed_root" 2>/dev/null || true
    print -u2 "失败现场已保留：$failed_root"
  fi
  return $exit_code
}
trap preserve_failed_build EXIT

lock_field() {
  awk -F '|' -v name="$1" -v field="$2" '$1 == name { print $field; exit }' "$source_lock"
}

fetch_git_source() {
  local name="$1"
  local url="$(lock_field "$name" 2)"
  local revision="$(lock_field "$name" 4)"
  if [[ -n "$source_cache" && -d "$source_cache/$name/.git" \
        && "$(git -C "$source_cache/$name" rev-parse HEAD 2>/dev/null)" == "$revision" ]]; then
    git clone -q --no-checkout "$source_cache/$name" "$build_root/$name"
    git -C "$build_root/$name" remote set-url origin "$url"
    git -C "$build_root/$name" checkout -q --detach "$revision"
    return
  fi
  git init -q "$build_root/$name"
  git -C "$build_root/$name" remote add origin "$url"
  local fetched=false
  for attempt in 1 2 3; do
    if git -C "$build_root/$name" fetch -q --depth 1 origin "$revision"; then
      fetched=true
      break
    fi
    print -u2 "$name 源码抓取失败（$attempt/3），准备重试"
  done
  [[ "$fetched" == true ]] || fail "$name 源码抓取连续失败"
  git -C "$build_root/$name" checkout -q --detach "$revision"
  [[ "$(git -C "$build_root/$name" rev-parse HEAD)" == "$revision" ]] \
    || fail "$name 源码提交不匹配"
}

for source_name in mpv ffmpeg libplacebo libass harfbuzz fribidi freetype pkgconf; do
  fetch_git_source "$source_name"
done

if [[ -n "$source_cache" && -e "$source_cache/libplacebo/3rdparty/Vulkan-Headers/.git" ]]; then
  for submodule_name in \
    '3rdparty/Vulkan-Headers' \
    '3rdparty/fast_float' \
    '3rdparty/glad' \
    '3rdparty/jinja' \
    '3rdparty/markupsafe'
  do
    git -C "$build_root/libplacebo" config "submodule.$submodule_name.url" \
      "$source_cache/libplacebo/$submodule_name"
  done
fi
git -c protocol.file.allow=always -C "$build_root/libplacebo" submodule update --init --depth 1 -- \
  3rdparty/Vulkan-Headers \
  3rdparty/fast_float \
  3rdparty/glad \
  3rdparty/jinja \
  3rdparty/markupsafe
for submodule in \
  'vulkan-headers:3rdparty/Vulkan-Headers' \
  'fast-float:3rdparty/fast_float' \
  'glad:3rdparty/glad' \
  'jinja:3rdparty/jinja' \
  'markupsafe:3rdparty/markupsafe'
do
  name="${submodule%%:*}"
  submodule_path="${submodule#*:}"
  [[ "$(git -C "$build_root/libplacebo/$submodule_path" rev-parse HEAD)" == "$(lock_field "$name" 4)" ]] \
    || fail "libplacebo 子模块 $name 提交不匹配"
done

mkdir -p "$build_root/tooling/bin"
typeset -A tool_archives
for tool_name in meson ninja; do
  tool_url="$(lock_field "$tool_name" 2)"
  tool_hash="$(lock_field "$tool_name" 4)"
  archive="$build_root/downloads/${tool_url:t}"
  curl -fL --retry 3 --retry-all-errors "$tool_url" -o "$archive"
  [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$tool_hash" ]] \
    || fail "$tool_name 归档哈希不匹配"
  tool_archives[$tool_name]="$archive"
done

tar -xzf "${tool_archives[meson]}" -C "$build_root/build"
ln -s "$build_root/build/meson-$(lock_field meson 3)/meson.py" "$build_root/tooling/bin/meson"
tar -xzf "${tool_archives[ninja]}" -C "$build_root/build"
(
  cd "$build_root/build/ninja-$(lock_field ninja 3)/ninja-upstream"
  python3 configure.py --bootstrap
  cp ninja "$build_root/tooling/bin/ninja"
)

PATH="$build_root/tooling/bin:$PATH" meson setup "$build_root/build/pkgconf" "$build_root/pkgconf" \
  --prefix="$build_root/tooling" --buildtype=release -Dtests=disabled
PATH="$build_root/tooling/bin:$PATH" meson compile -C "$build_root/build/pkgconf"
PATH="$build_root/tooling/bin:$PATH" meson install -C "$build_root/build/pkgconf"

sdk="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
export DEVELOPER_DIR="$developer_dir"
export PATH="$build_root/tooling/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG="$build_root/tooling/bin/pkgconf"

for architecture in arm64 x86_64; do
  prefix="$build_root/prefix/$architecture"
  cross_file="$build_root/$architecture.cross"
  mkdir -p "$prefix"
  export CC="clang -arch $architecture -isysroot $sdk"
  export CXX="clang++ -arch $architecture -isysroot $sdk"
  export OBJC="clang -arch $architecture -isysroot $sdk"
  export CFLAGS='-mmacosx-version-min=14.0'
  export CXXFLAGS='-mmacosx-version-min=14.0'
  export OBJCFLAGS='-mmacosx-version-min=14.0'
  export LDFLAGS='-mmacosx-version-min=14.0'
  cpu_family="$architecture"
  [[ "$architecture" == arm64 ]] && cpu_family=aarch64
  meson env2mfile --cross --system darwin --subsystem macos --kernel xnu \
    --cpu "$architecture" --cpu-family "$cpu_family" --endian little -o "$cross_file"
  if [[ "$architecture" == x86_64 ]]; then
    sed -i '' '/\[properties\]/a\
needs_exe_wrapper = true
' "$cross_file"
  fi

  ffmpeg_build="$build_root/build/ffmpeg-$architecture"
  mkdir -p "$ffmpeg_build"
  ffmpeg_options=(
    --prefix="$prefix" --target-os=darwin --arch="$architecture"
    --cc="clang -arch $architecture" --sysroot="$sdk"
    --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0
    --disable-static --enable-shared --disable-gpl --disable-nonfree --disable-version3
    --disable-autodetect --disable-programs --disable-doc --disable-debug --disable-network
    --disable-x86asm --enable-zlib --enable-videotoolbox --enable-audiotoolbox
  )
  [[ "$architecture" == x86_64 ]] && ffmpeg_options+=(--enable-cross-compile)
  (cd "$ffmpeg_build" && "$build_root/ffmpeg/configure" $ffmpeg_options)
  grep -Eq '^#define CONFIG_GPL 0$' "$ffmpeg_build/config.h" || fail "FFmpeg GPL 未关闭"
  grep -Eq '^#define CONFIG_NONFREE 0$' "$ffmpeg_build/config.h" || fail "FFmpeg nonfree 未关闭"
  grep -Eq '^#define CONFIG_VERSION3 0$' "$ffmpeg_build/config.h" || fail "FFmpeg version3 未关闭"
  make -C "$ffmpeg_build" -j "$jobs"
  make -C "$ffmpeg_build" install

  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  common=(--cross-file="$cross_file" --prefix="$prefix" --buildtype=release --default-library=shared --wrap-mode=nodownload)

  meson setup "$build_root/build/freetype-$architecture" "$build_root/freetype" $common \
    -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dbrotli=disabled -Dharfbuzz=disabled -Dtests=disabled
  meson compile -C "$build_root/build/freetype-$architecture"
  meson install -C "$build_root/build/freetype-$architecture"

  meson setup "$build_root/build/fribidi-$architecture" "$build_root/fribidi" $common \
    -Ddocs=false -Dbin=false -Dtests=false -Ddeprecated=false
  meson compile -C "$build_root/build/fribidi-$architecture"
  meson install -C "$build_root/build/fribidi-$architecture"

  meson setup "$build_root/build/harfbuzz-$architecture" "$build_root/harfbuzz" $common \
    -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
    -Dgraphite=disabled -Dgraphite2=disabled -Dfreetype=enabled -Dgdi=disabled \
    -Ddirectwrite=disabled -Dcoretext=disabled -Dtests=disabled -Dintrospection=disabled \
    -Ddocs=disabled -Dutilities=disabled
  meson compile -C "$build_root/build/harfbuzz-$architecture"
  meson install -C "$build_root/build/harfbuzz-$architecture"

  meson setup "$build_root/build/libass-$architecture" "$build_root/libass" $common \
    -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled -Dlibunibreak=disabled \
    -Dasm=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled \
    -Dcheckasm=disabled
  meson compile -C "$build_root/build/libass-$architecture"
  meson install -C "$build_root/build/libass-$architecture"

  meson setup "$build_root/build/libplacebo-$architecture" "$build_root/libplacebo" $common \
    -Dvulkan=disabled -Dopengl=enabled -Dgl-proc-addr=enabled -Dd3d11=disabled \
    -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled -Ddovi=disabled \
    -Dlibdovi=disabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false \
    -Dunwind=disabled -Dxxhash=disabled
  meson compile -C "$build_root/build/libplacebo-$architecture"
  meson install -C "$build_root/build/libplacebo-$architecture"

  meson setup "$build_root/build/mpv-$architecture" "$build_root/mpv" $common \
    -Dgpl=false -Dcplayer=false -Dlibmpv=true -Dbuild-date=false \
    -Dcdda=disabled -Dcplugins=disabled -Ddvbin=disabled -Ddvdnav=disabled \
    -Diconv=enabled -Djavascript=disabled -Djpeg=disabled -Dlcms2=disabled \
    -Dlibarchive=disabled -Dlibavdevice=disabled -Dlibbluray=disabled -Dlua=disabled \
    -Drubberband=disabled -Duchardet=disabled -Dvapoursynth=disabled \
    -Dx11-clipboard=disabled -Dzimg=disabled -Dzlib=enabled -Daudiounit=disabled \
    -Davfoundation=disabled -Dcoreaudio=enabled -Djack=disabled -Dpipewire=disabled \
    -Dpulse=disabled -Dsndio=disabled -Dcaca=disabled -Dcocoa=enabled -Dd3d11=disabled \
    -Ddirect3d=disabled -Ddmabuf-wayland=disabled -Degl=disabled -Dgbm=disabled \
    -Dgl=enabled -Dgl-cocoa=enabled -Dplain-gl=enabled -Dshaderc=disabled \
    -Dsixel=disabled -Dspirv-cross=disabled -Dvdpau=disabled -Dvaapi=disabled \
    -Dvulkan=disabled -Dwayland=disabled -Dx11=disabled -Dxv=disabled \
    -Dcuda-hwaccel=disabled -Dcuda-interop=disabled -Dd3d-hwaccel=disabled \
    -Dd3d9-hwaccel=disabled -Dios-gl=disabled -Dvideotoolbox-gl=enabled \
    -Dvideotoolbox-pl=disabled -Dmacos-cocoa-cb=disabled -Dmacos-media-player=disabled \
    -Dmacos-touchbar=disabled -Dswift-build=enabled \
    -Dswift-flags="-target $architecture-apple-macos14.0" \
    -Dhtml-build=disabled -Dmanpage-build=disabled -Dpdf-build=disabled
  meson compile -C "$build_root/build/mpv-$architecture"
  meson install -C "$build_root/build/mpv-$architecture"
done

universal="$build_root/universal"
mkdir -p "$universal/lib" "$universal/include" "$universal/notices"
runtime_lock="$repository_root/prototypes/lgpl-packaging-proof/runtime-closure.sha256"
libraries=("${(@f)$(awk 'NF == 2 { print $2 }' "$runtime_lock")}")
for library in $libraries; do
  lipo -create "$build_root/prefix/arm64/lib/$library" "$build_root/prefix/x86_64/lib/$library" \
    -output "$universal/lib/$library"
  install_name_tool -id "@rpath/$library" "$universal/lib/$library"
done
for target in "$universal/lib"/*.dylib; do
  for dependency in $libraries; do
    install_name_tool -change "$build_root/prefix/arm64/lib/$dependency" "@rpath/$dependency" "$target" 2>/dev/null || true
    install_name_tool -change "$build_root/prefix/x86_64/lib/$dependency" "@rpath/$dependency" "$target" 2>/dev/null || true
  done
done
ditto "$build_root/prefix/arm64/include/mpv" "$universal/include/mpv"

ditto "$build_root/mpv/Copyright" "$universal/notices/mpv-Copyright.txt"
ditto "$build_root/mpv/LICENSE.LGPL" "$universal/notices/mpv-LGPL-2.1.txt"
ditto "$build_root/ffmpeg/LICENSE.md" "$universal/notices/FFmpeg-LICENSE.txt"
ditto "$build_root/ffmpeg/COPYING.LGPLv2.1" "$universal/notices/FFmpeg-LGPL-2.1.txt"
ditto "$build_root/libplacebo/LICENSE" "$universal/notices/libplacebo-LICENSE.txt"
ditto "$build_root/libass/COPYING" "$universal/notices/libass-COPYING.txt"
ditto "$build_root/harfbuzz/COPYING" "$universal/notices/HarfBuzz-COPYING.txt"
ditto "$build_root/fribidi/COPYING" "$universal/notices/FriBidi-COPYING.txt"
ditto "$build_root/freetype/LICENSE.TXT" "$universal/notices/FreeType-LICENSE.txt"

"$repository_root/scripts/verify-candidate-inputs.sh" "$universal" "$source_lock" "$repository_root"
mv "$build_root" "$artifact_root"
trap - EXIT
print -r -- "锁定引擎构建完成：$artifact_root/universal"
