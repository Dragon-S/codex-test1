# 公开语料登记与短时验证

本文件只登记公开语料的来源、校验值和验证结论，不提交媒体文件。短时验证用于
证明探针能回答格式兼容与错误恢复问题；它不能替代 `CORPUS.md` 要求的重复操作
和 10 分钟稳态门槛。2 小时与 8 小时视频边界当前已单独记录为 deferred。

## Matroska Test Files Wave 1.1

- 官方说明：https://www.matroska.org/downloads/test_suite.html
- 下载：https://sourceforge.net/projects/matroska/files/test_files/matroska_test_w1_1.zip/download
- 下载日期：2026-07-31
- 压缩包 SHA-256：`d86f96e165e695e6cf5324ebca184f2df723872f02965b565820d265b53004eb`
- 使用说明：套件自述声明它用于验证 Matroska 播放器与解析器；样本素材来自
  Big Buck Bunny 与 Elephant Dreams 开放项目。保留随包 `Release.txt` 作为
  特性说明；对外再分发前仍须单独核对各素材许可。
- 本机位置：仓库外临时目录，不作为可复现的长期缓存承诺。

| 样本 ID | 文件 SHA-256 | 官方测试目的 | M5 短时结果 |
| --- | --- | --- | --- |
| `matroska-w1-test5` | `92acdc33bb0b5d7a4d9b0d6ca792230a78c786a30179dc9999cee41c28642842` | 多音轨与七种内嵌字幕 | 正常播放；音轨和字幕切换成功；续播误差 0 秒 |
| `matroska-w1-test6` | `7cad84b434116e023d340dd584ac833b93f03fb1bd7ea2727fa45de50af0abb9` | 无 Cues 的定位与不同 EBML 长度 | 任意拖动恢复，未记录播放失败 |
| `matroska-w1-test7` | `95b21c92ad5a4fe00914ff5009e2a64f12fd4c5fb9cb1c3c888ab50bf0ffe483` | 未知元素、垃圾数据和损坏片段 | 记录损坏与重同步日志后继续播放，可拖动到文件末段 |
| `matroska-w1-test8` | `9dddcd1550b814dae44d62e2b9f27c0eca31d5e190df2220cbf7492e3d6c63da` | 6.019–6.360 秒的音频帧间隙 | 连续播放越过间隙，未停止或记录播放失败 |

四次短时会话合计 7,197 条 JSONL 记录：最大加载到播放恢复 396.341 ms，最大
任意拖动恢复 297.435 ms，最大观测 RSS 148.500 MiB，最大解码/输出掉帧计数
0/1。掉帧计数包含启动阶段，且本轮未执行规定时长与轮次，因此不据此声明完整
质量门槛通过。

## FFmpeg PGS 样本

- 来源目录：https://samples.ffmpeg.org/sub/PGS/
- 下载：https://samples.ffmpeg.org/sub/PGS/supsample.mkv
- 下载日期：2026-07-31
- SHA-256：`e6c8f93f57d0371603704d7e7b16933e6c4c5df669da42b42a2a84de881e0f27`
- 使用边界：只用于本地兼容测试，不提交或再分发；来源页未提供足以支持再分发的
  独立许可声明。
- 内容：10.010 秒 Matroska，H.264 视频与一条 `S_HDMV/PGS` 字幕轨。
- M5 短时结果：正常播放并通过 AppKit OpenGL 帧缓冲截图确认 PGS 位图字幕可见；
  样本要求的红色文字实际显示为红色而非蓝色。

## 尚待补齐

- 24 小时独立音频时长边界。
- 核心格式的重复操作；10 分钟稳态三轮已由匿名私有样本完成。
