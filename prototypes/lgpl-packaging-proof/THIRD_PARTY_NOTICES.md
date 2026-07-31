# 第三方软件声明

本探针只验证下列锁定源码构成的动态运行时闭包。发布产品必须把各项目
随源码提供的完整许可证文本一并放入应用资源和对应源码下载页；本文件是
索引，不替代完整许可证文本，也不是法律意见。

| 组件 | 本次采用的许可路径 | 对应源码 |
| --- | --- | --- |
| mpv / libmpv | `-Dgpl=false`，LGPL-2.1-or-later | <https://github.com/mpv-player/mpv/tree/v0.41.0> |
| FFmpeg | LGPL-2.1-or-later；GPL、nonfree、version3 均关闭 | <https://github.com/FFmpeg/FFmpeg/tree/n8.1.2> |
| libplacebo | LGPL-2.1-or-later | <https://github.com/haasn/libplacebo/tree/v6.338.2> |
| libass | ISC | <https://github.com/libass/libass/tree/0.17.4> |
| FreeType | FreeType License；未选择其 GPL 备选路径 | <https://github.com/freetype/freetype/tree/VER-2-13-3> |
| FriBidi | LGPL-2.1-or-later | <https://github.com/fribidi/fribidi/tree/v1.0.16> |
| HarfBuzz | Old MIT | <https://github.com/harfbuzz/harfbuzz/tree/8.5.0> |

应用内库全部保持为独立 dylib，安装名为 `@rpath/<库名>`，宿主通过
`@executable_path/../Frameworks` 解析它们。产品 EULA 不得禁止为调试
这些 LGPL 组件所必需的逆向工程；对应源码、补丁和完整构建说明应至少与
二进制使用同样方便的方式提供。
