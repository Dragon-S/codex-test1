# 沙盒 Mac App Store LGPL 引擎打包探针

## 结论

**当前门槛判定：FAIL；开发签名与 library validation 子门槛已由 Personal
Team 重试验证为 PASS。**

引擎本身的通用动态打包路径成立：精确锁定的 LGPL 路径源码可构建为
`arm64 + x86_64`，12 个第三方 dylib 可全部放入 `Contents/Frameworks`，
改写为 `@rpath`，并由 Xcode 26.6 成功生成通用 `.xcarchive`。探针启用了
App Sandbox、Hardened Runtime、用户所选文件只读访问和 app-scoped
bookmark，且没有 `disable-library-validation`、JIT、unsigned executable
memory 或临时例外权限。

首次运行时，这台机器没有 Apple 签名身份。ad-hoc 签名以及自签名证书都
没有 Apple Team ID；在 library validation 保持开启时，dyld 按预期拒绝
载入 `libmpv.2.dylib`，错误为宿主与映射库的 Team ID 不同。

用户随后在 Xcode 登录个人 Apple Account。使用 Xcode 的
`-allowProvisioningUpdates` 和 Personal Team 自动签名重试后：

- Xcode 自动创建了有效的 Apple Development 身份；
- 外层 App 和全部嵌套 dylib 获得相同 Team ID；
- `codesign --verify --deep --strict` 通过；
- 探针在 Hardened Runtime 与 library validation 保持开启时成功启动；
- 权限实测为 App Sandbox、用户所选文件只读访问、app-scoped bookmark
  开启，`disable-library-validation=false`。

因此，**同团队签名和 library validation 技术路径已经通过**。但 Personal
Team 仍不具备 Mac App Store 分发资格。`app-store-connect` 导出失败，
Xcode 报告该账号没有关联的 App Store Connect provider，并且找不到
`Mac App Distribution` 证书。因此整个 Mac App Store 门槛仍不能判定为
PASS。

## 已验证范围

- 宿主：macOS 26.5.2，Xcode 26.6（17F113），macOS SDK 26.5，部署目标
  macOS 14.0。
- `libmpv`：mpv `v0.41.0`，`-Dgpl=false`、`-Dcplayer=false`、
  `-Dlibmpv=true`、`-Dbuild-date=false`。
- FFmpeg：`n8.1.2`，`--disable-gpl --disable-nonfree
  --disable-version3 --disable-static --enable-shared --disable-autodetect
  --disable-programs --disable-network --enable-zlib --enable-videotoolbox
  --enable-audiotoolbox`。
- mpv 保留的能力：CoreAudio、OpenGL、VideoToolbox；禁用 Lua、JavaScript、
  Vulkan、shaderc、fontconfig、网络、光盘、归档和运行时插件等可选面。
- 运行时第三方闭包：
  `libmpv.2`、`libass.9`、`libavcodec.62`、`libavfilter.11`、
  `libavformat.62`、`libavutil.60`、`libplacebo.338`、
  `libswresample.6`、`libswscale.9`、`libfreetype.6`、
  `libfribidi.0`、`libharfbuzz.0`。
- 12 个 dylib 与宿主均由 `lipo` 验证为 `x86_64 arm64`；第三方闭包大小
  约 56 MiB。
- 所有第三方安装名和相互引用均改为 `@rpath/<库名>`，不存在构建目录绝对
  路径；这也保留了 LGPL 所需的动态替换路径。
- Xcode Archive 成功，归档内只有一个 `.app` 产品，App 与 12 个 dylib
  都在预期位置；`codesign --verify --deep --strict` 对测试签名结构通过。
- Personal Team 自动签名归档成功，宿主与 `libmpv` 的 Team ID 一致；
  library validation 启动冒烟测试通过。
- 已生成 CycloneDX 1.6 SBOM、第三方声明索引、完整许可证文本集合和包含
  所有锁定源码及 libplacebo 子模块的对应源码压缩包。该次源码包 SHA-256
  为 `26571c89efb4d609b85cfaddef7dddca133ec32ebaf9e993bce901f57e6bf385`
  （约 81 MiB）；正式发布必须把重新生成的包上传到稳定公开位置。

## 可复现输入

[`sources.lock`](sources.lock) 锁定所有运行时源码、libplacebo 生成代码所用
子模块和构建工具；[`BUILD.md`](BUILD.md) 记录本次使用的完整功能开关。
两个架构使用同一个 Xcode SDK 和完全相同的功能开关，分别构建后再用
`lipo -create` 合并。Meson 组件统一使用：

```text
--buildtype=release --default-library=shared --wrap-mode=nodownload
C/C++/Objective-C: -arch <arch> -isysroot <SDK> -mmacosx-version-min=14.0
Swift: -target <arch>-apple-macos14.0
```

字体与着色依赖的收缩配置为：

```text
FreeType: zlib,bzip2,png,brotli,harfbuzz,tests = disabled
FriBidi: docs,bin,tests,deprecated = false
HarfBuzz: 仅 freetype；glib,gobject,cairo,icu,graphite,tests,docs,utilities = disabled
libass: coretext = enabled；fontconfig,libunibreak,asm,tests = disabled
libplacebo: opengl,gl-proc-addr = enabled；vulkan,shaderc,glslang,lcms,dovi = disabled
```

Xcode 探针工程位于
[`AppStoreProbe`](AppStoreProbe/AppStoreProbe.xcodeproj/project.pbxproj)，
由环境变量 `ENGINE_ROOT` 指向包含 `lib/`、`include/` 和 `notices/` 的通用
引擎目录。

## 尚需的凭据与人工门槛

1. 加入 Apple Developer Program，或获得一个已有组织团队的访问权限，并
   确保该 Apple Account 在 App Store Connect 中关联 provider；单纯的
   Personal Team 不够。
2. 明确正式 Bundle ID，并取得 Mac App Distribution / Apple Distribution
   证书私钥和对应的 Mac App Store provisioning profile；也可由 Xcode
   在有资格的团队下自动管理。
3. 使用该分发团队从干净构建重新归档；开发签名已证明可让宿主与全部嵌套
   dylib 获得相同 Team ID 并在 library validation 下启动，但分发签名仍须
   复核。
4. 执行 `xcodebuild -exportArchive` 的 Mac App Store 导出，再由 Xcode 或
   Transporter/App Store Connect 完成上传前校验。Apple 的正式流程要求从
   Xcode Archive 导出分发签名 App。
5. 法务逐项复核最终二进制图、mpv 的 LGPL 模式文件边界、FFmpeg 配置输出、
   完整许可证文本、对应源码/补丁提供方式、EULA 的逆向工程例外以及 App
   Store 协议。
6. 对启用的解码器和目标销售地区做独立的专利/商标审查，至少覆盖
   H.264/AVC、H.265/HEVC、AAC、MPEG-4 Part 2 和可能出现的 Dolby 格式。
7. 在提交前把 SBOM 从“源码与闭包清单”升级为对最终分发签名二进制重新
   计算的散列快照，并托管对应源码压缩包。

## 继续条件

取得具备 App Store Connect provider 的 Apple Developer Program 团队后，
应原样重跑分发签名、`exportArchive` 和 App Store Connect 校验。同团队
开发签名与 library validation 启动已通过，不必再把它们视为未知风险；
剩余分发步骤和法务审查全部通过后，才能把整体门槛从 FAIL 改为 PASS。

## 依据

- [Apple：App Sandbox 是 App Store 分发要求](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple：通过 Xcode Archive 导出分发签名 macOS App](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple：App Review Guidelines 2.4.5、2.5.2、5.2](https://developer.apple.com/app-store/review/guidelines/)
- [mpv：默认 GPL，`-Dgpl=false` 为 LGPL 路径](https://github.com/mpv-player/mpv#license)
- [FFmpeg：许可与 LGPL 合规清单](https://ffmpeg.org/legal.html)
