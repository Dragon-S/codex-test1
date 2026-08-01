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
