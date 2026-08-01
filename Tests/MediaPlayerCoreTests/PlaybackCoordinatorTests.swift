import Foundation
import Testing
@testable import MediaPlayerCore

@MainActor
struct PlaybackCoordinatorTests {
    @Test("打开本地媒体后等待真实引擎状态")
    func waitsForEngineStateAfterOpeningLocalMedia() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = LocalMedia(url: URL(fileURLWithPath: "/tmp/example.mp4"))

        await coordinator.open(media)

        #expect(await engine.commands == [.load(media)])
        #expect(coordinator.state == .idle)

        engine.send(.playbackStateChanged(.playing))
        try await wait(for: .playing, coordinator: coordinator)

        #expect(coordinator.state == .playing)
    }

    @Test("播放、暂停与停止由协调层转发并由引擎事件确认")
    func forwardsPlaybackControlsAndReflectsEngineEvents() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)

        await coordinator.play()
        await coordinator.pause()
        await coordinator.stop()

        #expect(await engine.commands == [.play, .pause, .stop])
        #expect(coordinator.state == .idle)

        engine.send(.playbackStateChanged(.paused))
        try await wait(for: .paused, coordinator: coordinator)
        #expect(coordinator.state == .paused)

        engine.send(.playbackStateChanged(.stopped))
        try await wait(for: .stopped, coordinator: coordinator)
        #expect(coordinator.state == .stopped)
    }

    private func wait(for expected: PlaybackState, coordinator: PlaybackCoordinator) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if coordinator.state == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CoordinatorStateTimeout(expected: expected, observed: coordinator.state)
    }
}

private struct CoordinatorStateTimeout: Error {
    let expected: PlaybackState
    let observed: PlaybackState
}

private enum PlaybackEngineCommand: Equatable, Sendable {
    case load(LocalMedia)
    case play
    case pause
    case stop
}

private actor FakePlaybackEngine: PlaybackEngine {
    private(set) var commands: [PlaybackEngineCommand] = []
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia) {
        commands.append(.load(media))
    }

    func play() {
        commands.append(.play)
    }

    func pause() {
        commands.append(.pause)
    }

    func stop() {
        commands.append(.stop)
    }

    nonisolated func send(_ event: PlaybackEngineEvent) {
        continuation.yield(event)
    }
}
