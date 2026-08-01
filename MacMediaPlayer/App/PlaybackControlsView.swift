import Foundation
import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let openMedia: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("后退 \(Int(coordinator.seekStep)) 秒") {
                    Task { await coordinator.skipBackward() }
                }
                .accessibilityLabel("后退 \(Int(coordinator.seekStep)) 秒")
                Text(timeText(coordinator.position))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { coordinator.position },
                        set: { value in Task { await coordinator.seek(to: value) } }
                    ),
                    in: 0...max(coordinator.duration, 1)
                )
                .disabled(coordinator.duration <= 0)
                .accessibilityLabel("播放位置")
                .accessibilityValue("\(timeText(coordinator.position))，总时长 \(timeText(coordinator.duration))")
                Text(timeText(coordinator.duration))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .leading)
                Button("前进 \(Int(coordinator.seekStep)) 秒") {
                    Task { await coordinator.skipForward() }
                }
                .accessibilityLabel("前进 \(Int(coordinator.seekStep)) 秒")
            }

            HStack(spacing: 12) {
                Button("打开…", action: openMedia)
                    .keyboardShortcut("o")
                Button("播放") { Task { await coordinator.play() } }
                Button("暂停") { Task { await coordinator.pause() } }
                Button("停止") { Task { await coordinator.stop() } }
                Button("上一首") { Task { await coordinator.previous() } }
                Button("下一首") { Task { await coordinator.next() } }
                Picker("速度", selection: Binding(
                    get: { coordinator.playbackRate },
                    set: { rate in Task { await coordinator.setPlaybackRate(rate) } }
                )) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                }
                .frame(width: 105)
                Picker("跳转", selection: Binding(
                    get: { coordinator.seekStep },
                    set: { step in Task { await coordinator.setSeekStep(step) } }
                )) {
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                }
                .frame(width: 100)
                Button(coordinator.isMuted ? "取消静音" : "静音") {
                    Task { await coordinator.setMuted(!coordinator.isMuted) }
                }
                Slider(
                    value: Binding(
                        get: { coordinator.playerVolume },
                        set: { volume in Task { await coordinator.setPlayerVolume(volume) } }
                    ),
                    in: 0...1
                )
                .frame(width: 90)
                .accessibilityLabel("播放器音量")
                .accessibilityValue("\(Int(coordinator.playerVolume * 100))%")
                Spacer()
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("播放状态")
                    .accessibilityValue(statusText)
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func timeText(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
        }
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle: "尚未打开媒体"
        case .loading: "正在载入"
        case .playing: "正在播放"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case let .failed(failure): failureText(failure)
        }
    }

    private func failureText(_ failure: PlaybackFailure) -> String {
        switch failure {
        case .unreadable: "无法读取文件"
        case .unsupported: "不支持此媒体"
        case .corrupted: "媒体内容已损坏"
        case .decoderInitializationFailed: "解码器初始化失败"
        case .engineUnavailable: "播放引擎不可用"
        }
    }
}

struct NowPlayingListView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    @State private var playlistName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正在播放列表")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            HStack {
                TextField("Playlist 名称", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
                Button("存储") {
                    Task {
                        if (try? await coordinator.saveNowPlayingList(as: playlistName)) != nil {
                            playlistName = ""
                        }
                    }
                }
                .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || coordinator.nowPlayingList.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            persistenceNotice
                .padding(.horizontal, 12)
            List(Array(coordinator.nowPlayingList.entries.enumerated()), id: \.element.id) { index, entry in
                HStack {
                    Image(systemName: index == coordinator.nowPlayingList.currentIndex ? "play.fill" : "circle")
                        .accessibilityHidden(true)
                    Text(entry.media.url.lastPathComponent)
                        .lineLimit(1)
                }
                .accessibilityLabel(entry.media.url.lastPathComponent)
                .accessibilityValue(index == coordinator.nowPlayingList.currentIndex ? "当前播放" : "")
            }
        }
        .frame(minWidth: 220, idealWidth: 260)
    }

    @ViewBuilder
    private var persistenceNotice: some View {
        switch coordinator.persistenceNotice {
        case .none:
            EmptyView()
        case let .saved(name):
            Label("已存储为 \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .nameAlreadyExists(name):
            Label("名称“\(name)”已存在，原数据未更改", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}
