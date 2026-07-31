# PROTOTYPE — libmpv 原生画中画探针

这是回答“libmpv 渲染的视频能否经 `AVSampleBufferDisplayLayer` 驱动
macOS 原生画中画”的一次性技术探针，不是产品实现。

## 运行

前置条件：

```sh
brew install mpv pkg-config
```

启动：

```sh
./run-pip-probe.sh /绝对路径/测试视频.mkv
```

脚本会先用 SwiftPM 构建，再包装成带独立 bundle identifier 的最小 `.app`，
以便 macOS 正确识别系统级画中画会话。

窗口会显示画面、当前媒体时间、单帧 CPU 渲染耗时、音轨/字幕选择、源色彩信息，
以及画中画是否可启动。请用至少以下语料各运行一次：

- 带音频的 SDR H.264；
- MKV 内嵌字幕与外部 ASS 字幕；
- 4K HEVC；
- HDR10（BT.2020/PQ）。

观察主窗口与画中画的播放/暂停、前后跳转、音频是否连续、字幕是否出现，以及
HDR 画面是否被压成 SDR。

## 探针刻意暴露的边界

- libmpv 的软件 Render API 把字幕/OSD 合成进 8-bit BGRA 帧，再包装成
  `CMSampleBuffer`。
- `AVSampleBufferRenderSynchronizer` 以 libmpv 的媒体时间驱动显示层；
  libmpv 仍独立输出音频。
- 软件 Render API 官方定义为很慢，且明确警告 HDR 可能不能正确工作。本探针
  因而验证原生 PiP 接线与系统控制，也直接测出这条具体桥接路径的性能和色彩上限。
- GPU 零拷贝、HDR 元数据传递、音频设备时钟对齐和 App Sandbox 后台音频能力
  不在这份最小探针中；若要保留 MVP 的高质量 PiP，它们需要另一条实现策略。

## 2026-07-31 本机冒烟结果

环境：Apple M5 MacBook Pro、24 GB 内存、macOS 26.5.2、mpv 0.41.0。
数值为最近 120 帧的软件 Render API 调用耗时；已关闭 libmpv 内部的目标时刻
等待，展示时序交给 `AVSampleBufferRenderSynchronizer`。

- 720p30 H.264 + AAC + ASS：平均 1.98 ms，P95 3.22 ms；字幕可见。
- 4K30 H.264 + AAC，桥接输出限制为 1080p：平均 2.37 ms，P95 2.98 ms；
  播放期间整个进程约占一个 CPU 核心的 67%–73%，RSS 约 454 MiB。
- 原生 PiP 可启动；进入后主窗口出现系统的“正在画中画播放”占位，PiP
  渲染尺寸回调为 960×540。
- PiP 播放/暂停、跳转、进入/退出时的音频连续性仍需人工操作和听感确认。
- GPU 成本未被单独量化；软件桥仍经过 AVFoundation/WindowServer 合成。
- HDR 不能通过：桥固定为 8-bit BGRA SDR，没有 10-bit 像素格式、HDR
  色彩附件或逐帧动态元数据。

这些结果只支持“原生 PiP 接线可行”，不支持“当前软件桥是合格的 MVP
实现”。最终选择应在以下三者中作出：保留 PiP 并更换桥接策略、接受 SDR
与额外资源成本、或把 PiP 移出 MVP。

## 依据

- [Apple：用 sample buffer display layer 创建 PiP content source](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init%28samplebufferdisplaylayer%3Aplaybackdelegate%3A%29)
- [Apple：display layer 的 timebase 解释样本时间戳](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/controltimebase)
- [mpv：软件 Render API 很慢且 HDR 可能无法正确工作](https://github.com/mpv-player/mpv/blob/master/include/mpv/render.h)
