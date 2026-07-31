# PROTOTYPE — libmpv MVP 语料探针

这是一份一次性原生 macOS 原型，用来回答
“锁定的 LGPL-only libmpv/FFmpeg 是否达到 MVP 播放质量门槛”。它不是播放器
实现，也不能用参考机成绩替代发布阻断基线机。

探针把视频嵌入 AppKit `NSView`，提供播放/暂停、精确前后 10 秒定位、任意拖动、
音轨/字幕切换、0.5–2.0 倍速、VideoToolbox/软件解码切换、续播往返与带字幕
截图。每次操作及关键 libmpv 事件都会把完整相关状态写入 JSONL，包括编解码器、
实际硬解路径、轨道、定位、掉帧、音画同步与进程常驻内存。

## 一条命令运行

```sh
./prototypes/libmpv-corpus-probe/run-probe.sh \
  --engine-root /path/to/pinned/universal \
  --media /path/to/corpus/sample.mkv \
  --sample-id private-video-01
```

`--engine-root` 必须是“Prove sandboxed App Store packaging for the LGPL
engine”所锁定构建产出的通用目录，包含 `include/mpv/client.h` 和
`lib/libmpv.2.dylib`。当前锁为 mpv `v0.41.0`（`-Dgpl=false`）与 FFmpeg
`n8.1.2`（GPL、nonfree、version3 关闭）。

默认把临时构建和证据写到本目录的 `.build/`、`evidence/`；两者都不会进入
Git。可通过 `--evidence-dir` 指向一次测试记录目录。

`--sample-id` 应使用不含私人信息的代号。探针运行时读取真实路径，但 JSONL
只记录样本 ID 和 SHA-256，不记录文件名或完整路径；因此证据可以独立分享。

稳态测试可加 `--auto-exit-seconds 600`，探针会在指定时间记录最终状态并正常
退出，避免人工关闭窗口。默认值为 `0`，表示不自动退出。加 `--mute-audio`
只静音输出，音轨仍会被加载和解码；JSONL 会记录这一设置。

汇总一次或多次运行：

```sh
python3 ./prototypes/libmpv-corpus-probe/summarize-evidence.py \
  /path/to/evidence/probe-*.jsonl
```

## 先验证原型是否回答了问题

1. 用一个视频、一个多轨/字幕样本和一个纯音频样本分别启动探针。
2. 确认画面和音频真实播放，按钮行为符合标签，状态栏的轨道与硬解路径会变化。
3. 点击“截图证据”，确认 PNG 包含当前字幕合成结果。
4. 在 30 秒以后点击“续播往返”，确认 JSONL 中
   `resume_error_seconds` 可衡量且画面回到原位置。
5. 打开 JSONL，确认每个 `action` 后都有 `state`，并可将
   `MPV_EVENT_PLAYBACK_RESTART` 与上一个动作配对计算响应延迟。

若这五项中任何一项不成立，应先调整原型的观测方法，不应开始大规模语料测试。

没有可公开测试视频时，可先生成一个五秒 H.264 无音频冒烟样本；它只能验证
渲染、定位和截图链路，不属于代表性语料：

```sh
swift ./prototypes/libmpv-corpus-probe/generate-smoke-video.swift \
  /tmp/libmpv-smoke.mov
```

若本机已有 `ffmpeg`，可以在仓库外生成 VP9/Opus 与常见独立音频边界样本：

```sh
./prototypes/libmpv-corpus-probe/generate-corpus-fixtures.sh \
  /private/tmp/codex-test1-generated-corpus
```

脚本只使用测试图案与合成音频。外部 SRT、ASS、SSA 文本样本位于
`fixtures/`；媒体生成物不进入 Git。

## 资格判定边界

当前内部 MVP 的 PASS/FAIL 按 [CORPUS.md](CORPUS.md) 在开发者的 M5
物理机上完成；通过后只表示引擎足以解除内部 MVP 的实现阻塞。M1 MacBook
Air 与 2018 Intel MacBook Air 的性能兼容门槛延后到首次公开发布前，不由
本原型票阻断。M5 结果不能外推成对全部 macOS 14+ 设备的兼容承诺。

自动化统计可以减少人工整理，但 ASS/SSA/PGS 视觉正确性、可见停顿、音频
中断、温度压力和 QuickTime 能耗对照仍需要人工观察。

软件解码回退按分辨率分层：4K 以 VideoToolbox 为完整质量路径，软件回退
只验证安全退出或明确降级；1080p 及以下的软件回退仍须满足完整门槛。这个
边界来自 M5 上 4K59.94 HEVC 实测：硬解可用，而强制软解超过资源门槛并
持续掉帧。

原型只保留 libmpv 原始错误与建议的领域错误。生产实现仍须由媒体探测层把
“无法读取”“格式或编码不受支持”“文件内容损坏”“解码器初始化失败”可靠地区分。
