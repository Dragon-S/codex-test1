# 可复现构建参数

本文记录本次实际使用的完整功能开关。`<ROOT>` 是隔离构建目录，`<SDK>`
来自 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun
--sdk macosx --show-sdk-path`，`<ARCH>` 依次为 `arm64`、`x86_64`。

所有 Meson 项目共用：

```text
--cross-file=<ROOT>/<ARCH>.cross
--prefix=<ROOT>/prefix/<ARCH>
--buildtype=release
--default-library=shared
--wrap-mode=nodownload
```

cross file 的编译器和内建参数为：

```text
c    = clang   -arch <ARCH> -isysroot <SDK>
cpp  = clang++ -arch <ARCH> -isysroot <SDK>
objc = clang   -arch <ARCH> -isysroot <SDK>
c_args/cpp_args/objc_args = -mmacosx-version-min=14.0
c_link_args/cpp_link_args/objc_link_args = -mmacosx-version-min=14.0
```

`x86_64` cross file 另设 `needs_exe_wrapper = true`，构建过程不运行
`x86_64` 目标程序，因此不要求 Rosetta。

## FFmpeg

```text
configure
--prefix=<ROOT>/prefix/<ARCH>
--target-os=darwin
--arch=<ARCH>
--cc=clang -arch <ARCH>
--sysroot=<SDK>
--extra-cflags=-mmacosx-version-min=14.0
--extra-ldflags=-mmacosx-version-min=14.0
--disable-static
--enable-shared
--disable-gpl
--disable-nonfree
--disable-version3
--disable-autodetect
--disable-programs
--disable-doc
--disable-debug
--disable-network
--disable-x86asm
--enable-zlib
--enable-videotoolbox
--enable-audiotoolbox
```

`x86_64` 额外使用 `--enable-cross-compile`。构建后必须检查 `config.h`
中的 `CONFIG_GPL`、`CONFIG_NONFREE`、`CONFIG_VERSION3` 均为 `0`。

## 字幕与渲染依赖

```text
FreeType:
-Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dbrotli=disabled
-Dharfbuzz=disabled -Dtests=disabled

FriBidi:
-Ddocs=false -Dbin=false -Dtests=false -Ddeprecated=false

HarfBuzz:
-Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled
-Dicu=disabled -Dgraphite=disabled -Dgraphite2=disabled
-Dfreetype=enabled -Dgdi=disabled -Ddirectwrite=disabled
-Dcoretext=disabled -Dtests=disabled -Dintrospection=disabled
-Ddocs=disabled -Dutilities=disabled

libass:
-Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled
-Dlibunibreak=disabled -Dasm=disabled -Dtest=disabled
-Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

libplacebo:
-Dvulkan=disabled -Dopengl=enabled -Dgl-proc-addr=enabled
-Dd3d11=disabled -Dglslang=disabled -Dshaderc=disabled
-Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled
-Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
-Dunwind=disabled -Dxxhash=disabled
```

## mpv / libmpv

```text
-Dgpl=false -Dcplayer=false -Dlibmpv=true -Dbuild-date=false
-Dcdda=disabled -Dcplugins=disabled -Ddvbin=disabled -Ddvdnav=disabled
-Diconv=enabled -Djavascript=disabled -Djpeg=disabled -Dlcms2=disabled
-Dlibarchive=disabled -Dlibavdevice=disabled -Dlibbluray=disabled
-Dlua=disabled -Drubberband=disabled -Duchardet=disabled
-Dvapoursynth=disabled -Dx11-clipboard=disabled -Dzimg=disabled
-Dzlib=enabled
-Daudiounit=disabled -Davfoundation=disabled -Dcoreaudio=enabled
-Djack=disabled -Dpipewire=disabled -Dpulse=disabled -Dsndio=disabled
-Dcaca=disabled -Dcocoa=enabled -Dd3d11=disabled -Ddirect3d=disabled
-Ddmabuf-wayland=disabled -Degl=disabled -Dgbm=disabled
-Dgl=enabled -Dgl-cocoa=enabled -Dplain-gl=enabled
-Dshaderc=disabled -Dsixel=disabled -Dspirv-cross=disabled
-Dvdpau=disabled -Dvaapi=disabled -Dvulkan=disabled
-Dwayland=disabled -Dx11=disabled -Dxv=disabled
-Dcuda-hwaccel=disabled -Dcuda-interop=disabled
-Dd3d-hwaccel=disabled -Dd3d9-hwaccel=disabled
-Dios-gl=disabled -Dvideotoolbox-gl=enabled
-Dvideotoolbox-pl=disabled -Dmacos-cocoa-cb=disabled
-Dmacos-media-player=disabled -Dmacos-touchbar=disabled
-Dswift-build=enabled
-Dswift-flags=-target <ARCH>-apple-macos14.0
-Dhtml-build=disabled -Dmanpage-build=disabled -Dpdf-build=disabled
```

本次两侧配置最终都只启用：

```text
bsd-fstatfs cocoa coreaudio darwin ffmpeg gl gl-cocoa glob glob-posix
iconv libass libdl libplacebo mac-thread-name macos-10-15-4-features
macos-11-3-features macos-11-features macos-12-features posix posix-shm
swift vector videotoolbox-gl zlib
```

## 通用闭包与归档

每个第三方 dylib 分别执行：

```text
lipo -create <arm64-dylib> <x86_64-dylib> -output <universal-dylib>
install_name_tool -id @rpath/<name> <universal-dylib>
install_name_tool -change <old-absolute-dependency> @rpath/<dependency> \
  <universal-dylib>
```

必须对整个闭包运行 `otool -L`，确保没有 `<ROOT>` 绝对路径。Xcode 归档：

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project AppStoreProbe/AppStoreProbe.xcodeproj \
  -scheme AppStoreProbe \
  -configuration Release \
  -destination generic/platform=macOS \
  -archivePath <ROOT>/AppStoreProbe.xcarchive \
  archive \
  ENGINE_ROOT=<ROOT>/universal \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO
```

正式重跑不得使用 ad-hoc 或自签名身份。应让 Xcode 用真实 Apple 团队身份
对所有嵌套 dylib 与外层 App 同团队签名，然后检查：

```text
codesign --verify --deep --strict --verbose=4 <App>
codesign -dvvv <App>
codesign -d --entitlements :- <App>
otool -L <App>/Contents/MacOS/AppStoreProbe
xcodebuild -exportArchive ...
```
