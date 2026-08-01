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
