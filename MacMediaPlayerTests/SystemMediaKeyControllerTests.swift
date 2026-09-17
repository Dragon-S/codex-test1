import Foundation
import MediaPlayer
import Testing
@testable import MacMediaPlayer

@MainActor
@Suite(.serialized)
struct SystemMediaKeyControllerTests {
    @Test("系统正在播放状态跟随播放、暂停与停止")
    func publishesPlaybackStateToSystem() async throws {
        let center = MPNowPlayingInfoCenter.default()
        let originalInfo = center.nowPlayingInfo
        let originalState = center.playbackState
        defer {
            center.nowPlayingInfo = originalInfo
            center.playbackState = originalState
        }
        let engine = MediaKeyFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = SystemMediaKeyController(
            coordinator: coordinator,
            commandCenter: nil,
            nowPlayingInfoCenter: center
        )
        await coordinator.open(LocalMedia(url: URL(fileURLWithPath: "/tmp/media-key-state.wav")))
        await engine.sendState(.playing)
        try await wait(for: .playing, coordinator: coordinator)
        #expect(center.playbackState == .playing)

        await coordinator.pause()
        await engine.sendState(.paused)
        try await wait(for: .paused, coordinator: coordinator)
        #expect(center.playbackState == .paused)

        await coordinator.stop()
        await engine.sendState(.stopped)
        try await wait(for: .stopped, coordinator: coordinator)
        #expect(center.playbackState == .stopped)
        withExtendedLifetime(controller) {}
    }

    @Test("停止系统媒体控制时清除播放会话且不再发布更新")
    func invalidationEndsNowPlayingSession() async throws {
        let center = MPNowPlayingInfoCenter.default()
        let originalInfo = center.nowPlayingInfo
        let originalState = center.playbackState
        defer {
            center.nowPlayingInfo = originalInfo
            center.playbackState = originalState
        }
        let engine = MediaKeyFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = SystemMediaKeyController(
            coordinator: coordinator,
            commandCenter: nil,
            nowPlayingInfoCenter: center
        )
        await coordinator.open(LocalMedia(url: URL(fileURLWithPath: "/tmp/media-key-session.wav")))
        await engine.sendState(.playing)
        try await wait(for: .playing, coordinator: coordinator)
        #expect(center.playbackState == .playing)

        controller.invalidate()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
        await engine.sendState(.paused)
        try await wait(for: .paused, coordinator: coordinator)
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    @Test("媒体键没有当前条目时不动作")
    func ignoresMediaKeysWithoutCurrentEntry() async {
        let engine = MediaKeyFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = SystemMediaKeyController(
            coordinator: coordinator,
            commandCenter: nil,
            nowPlayingInfoCenter: nil
        )

        #expect(await controller.perform(.togglePlayback) == .noActionableNowPlayingItem)
        #expect(await controller.perform(.previous) == .noActionableNowPlayingItem)
        #expect(await controller.perform(.next) == .noActionableNowPlayingItem)
        #expect(await engine.commands.isEmpty)
    }

    @Test("媒体键不会把文件缺失条目发布为可操作当前项")
    func ignoresMediaKeysForMissingCurrentEntry() async {
        let engine = MediaKeyFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = SystemMediaKeyController(
            coordinator: coordinator,
            commandCenter: nil,
            nowPlayingInfoCenter: nil
        )
        await coordinator.open(LocalMedia(
            url: URL(fileURLWithPath: "/tmp/missing.mp4"),
            availability: .missing
        ))
        let commandsBeforeMediaKey = await engine.commands

        #expect(await controller.perform(.togglePlayback) == .noActionableNowPlayingItem)
        #expect(await controller.perform(.previous) == .noActionableNowPlayingItem)
        #expect(await controller.perform(.next) == .noActionableNowPlayingItem)
        #expect(await engine.commands == commandsBeforeMediaKey)
    }

    @Test("加载或失败状态下播放媒体键不会伪报成功")
    func rejectsToggleMediaKeyWhenPlaybackCannotToggle() async throws {
        let engine = MediaKeyFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = SystemMediaKeyController(
            coordinator: coordinator,
            commandCenter: nil,
            nowPlayingInfoCenter: nil
        )
        await coordinator.open(LocalMedia(url: URL(fileURLWithPath: "/tmp/loading.mp4")))
        await engine.sendState(.loading)
        try await wait(for: .loading, coordinator: coordinator)
        let commandsBeforeMediaKey = await engine.commands

        #expect(await controller.perform(.togglePlayback) == .commandFailed)
        #expect(await engine.commands == commandsBeforeMediaKey)
    }

    @Test("媒体键通过协调层切换播放并遵循 Playlist 上一首与下一首")
    func routesMediaKeysThroughPlaylistRules() async throws {
        let engine = MediaKeyFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let controller = SystemMediaKeyController(
            coordinator: coordinator,
            commandCenter: nil,
            nowPlayingInfoCenter: nil
        )
        let media = [
            LocalMedia(url: URL(fileURLWithPath: "/tmp/first.mp4")),
            LocalMedia(url: URL(fileURLWithPath: "/tmp/second.mp4")),
        ]
        await coordinator.open(media)
        await engine.sendState(.playing)
        try await wait(for: .playing, coordinator: coordinator)

        #expect(await controller.perform(.togglePlayback) == .success)
        #expect(await controller.perform(.next) == .success)
        #expect(await controller.perform(.previous) == .success)

        #expect(await engine.commands == [
            .load(media[0]),
            .pause,
            .load(media[1]),
            .load(media[0]),
        ])
    }

    private func wait(
        for expected: PlaybackState,
        coordinator: PlaybackCoordinator
    ) async throws {
        for _ in 0..<100 where coordinator.state != expected {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.state == expected)
    }
}

private enum MediaKeyEngineCommand: Equatable, Sendable {
    case load(LocalMedia)
    case play
    case pause
    case stop
}

private actor MediaKeyFakePlaybackEngine: PlaybackEngine {
    private(set) var commands: [MediaKeyEngineCommand] = []
    private var loadID: PlaybackLoadID?
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        commands.append(.load(media))
        self.loadID = loadID
    }

    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() { commands.append(.stop) }
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) {}
    func setMuted(_ isMuted: Bool) {}

    func sendState(_ state: PlaybackState) {
        guard let loadID else { return }
        continuation.yield(.playbackStateChanged(state, loadID: loadID))
    }
}
