# Mac Media Player 构建与测试

产品目标使用 `prototypes/lgpl-packaging-proof` 已锁定并验证的 LGPL-only
通用 libmpv 动态闭包。先按该原型的 [`BUILD.md`](../prototypes/lgpl-packaging-proof/BUILD.md)
生成包含 `include/`、`lib/` 与 `notices/` 的通用目录，再把目录传给
`ENGINE_ROOT`。

## 测试

播放协调层与假引擎接缝：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

真实 libmpv 契约与首帧渲染：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MacMediaPlayer/MacMediaPlayer.xcodeproj \
  -scheme MacMediaPlayer \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test ENGINE_ROOT=/path/to/universal
```

## 通用签名归档

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MacMediaPlayer/MacMediaPlayer.xcodeproj \
  -scheme MacMediaPlayer \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /path/to/MacMediaPlayer.xcarchive \
  archive ENGINE_ROOT=/path/to/universal \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
```

目标默认启用 App Sandbox、Hardened Runtime、library validation，以及
`com.apple.security.files.user-selected.read-only`。嵌入脚本会复制完整动态
依赖闭包及第三方声明，并使用与宿主相同的签名身份逐个签名 dylib。

当前锁定的 libmpv 闭包只提供 OpenGL 渲染后端，因此产品画布使用
`NSOpenGLView` 接入 render API。该平台 API 已弃用，但在迁移到经资格验证的
Metal/libplacebo 构建前，它是本切片与现有 LGPL 打包证明一致的静态装配路径。

## 离线内部 MVP 候选

候选构建必须从干净提交运行，并使用可用的 Apple 开发团队签名。默认入口会
从 `sources.lock` 下载并构建锁定的双架构引擎闭包：

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
scripts/build-internal-candidate.sh
```

若要复用已经由同一流程构建且逐文件哈希相符的闭包，可额外传入
`ENGINE_ROOT=/path/to/universal`。单独生成闭包可运行
`scripts/build-locked-engine.sh /path/to/output`，产物位于输出目录的
`universal/`。

该入口验证源码、头文件、已验证动态闭包与许可材料的 SHA-256 锁、LGPL-only 功能
开关、安全权限和禁止项，
运行 SwiftPM 与 Xcode 全套契约测试，生成并启动通用 Release 归档。输出位于
`.build/internal-candidate/<commit>-<timestamp>/`，其中
`candidate-record.json` 绑定提交、构建身份、最低 macOS 版本和自动化结果，
`PHYSICAL-ACCEPTANCE.md` 保持未完成物理机清单。自动化通过只表示
`AUTOMATED_PASS_PHYSICAL_PENDING`，不代表公开发布或 App Store 资格。
动态库输入锁在计算哈希前会移除代码签名，并清零链接器生成的 `LC_UUID` 与 Swift
模块时间戳符号；候选记录仍另外保存实际签名产物的闭包清单哈希，以绑定本次可执行
构建。
