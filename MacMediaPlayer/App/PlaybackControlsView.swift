import Foundation
import SwiftUI

struct PlaybackControlsView: View {
    @ObservedObject var coordinator: PlaybackCoordinator
    let openMedia: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("打开…", action: openMedia)
                .keyboardShortcut("o")
            Button("播放") {
                Task { await coordinator.play() }
            }
            Button("暂停") {
                Task { await coordinator.pause() }
            }
            Button("停止") {
                Task { await coordinator.stop() }
            }
            Button("上一首") {
                Task { await coordinator.previous() }
            }
            Button("下一首") {
                Task { await coordinator.next() }
            }
            Spacer()
            Text(statusText)
                .foregroundStyle(.secondary)
                .accessibilityLabel("播放状态")
                .accessibilityValue(statusText)
        }
        .buttonStyle(.bordered)
        .padding(12)
        .background(.ultraThinMaterial)
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
