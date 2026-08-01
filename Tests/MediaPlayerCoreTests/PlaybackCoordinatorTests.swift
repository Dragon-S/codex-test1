import Foundation
import Testing
@testable import MediaPlayerCore

@MainActor
struct PlaybackCoordinatorTests {
    @Test("一次打开多个本地媒体会按选择顺序形成正在播放列表并加载首项")
    func opensMultipleLocalMediaInSelectionOrder() async {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = [
            LocalMedia(url: URL(fileURLWithPath: "/tmp/first.mp4")),
            LocalMedia(url: URL(fileURLWithPath: "/tmp/second.mp3")),
            LocalMedia(url: URL(fileURLWithPath: "/tmp/third.mkv")),
        ]

        await coordinator.open(media)

        #expect(coordinator.nowPlayingList.entries == media)
        #expect(coordinator.nowPlayingList.currentIndex == 0)
        #expect(coordinator.nowPlayingList.currentMedia == media[0])
        #expect(await engine.commands == [.load(media[0])])
    }

    @Test("新一次打开会整体替换旧正在播放列表并立即加载新首项")
    func replacesNowPlayingListWithNewSelection() async {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let oldMedia = [localMedia("old-first.mp4"), localMedia("old-second.mp4")]
        let newMedia = [localMedia("new-first.mp3"), localMedia("new-second.mkv")]

        await coordinator.open(oldMedia)
        await coordinator.open(newMedia)

        #expect(coordinator.nowPlayingList == NowPlayingList(entries: newMedia, currentIndex: 0))
        #expect(await engine.commands == [.load(oldMedia[0]), .load(newMedia[0])])
    }

    @Test("下一首与上一首按正在播放列表顺序加载相邻条目")
    func movesToNextAndPreviousMediaInOrder() async {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = [localMedia("first.mp4"), localMedia("second.mp3"), localMedia("third.mkv")]
        await coordinator.open(media)

        await coordinator.next()
        #expect(coordinator.nowPlayingList.currentIndex == 1)
        #expect(coordinator.nowPlayingList.currentMedia == media[1])

        await coordinator.previous()
        #expect(coordinator.nowPlayingList.currentIndex == 0)
        #expect(coordinator.nowPlayingList.currentMedia == media[0])
        #expect(await engine.commands == [.load(media[0]), .load(media[1]), .load(media[0])])
    }

    @Test("媒体自然结束后推进下一项并在列表边界停止")
    func advancesAfterNaturalEndAndStopsAtBoundary() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = [localMedia("first.mp4"), localMedia("second.mp3")]
        await coordinator.open(media)

        engine.send(.playbackEnded)
        try await wait(forCurrentIndex: 1, coordinator: coordinator)
        #expect(await engine.commands == [.load(media[0]), .load(media[1])])

        engine.send(.playbackEnded)
        try await wait(for: .stopped, coordinator: coordinator)
        #expect(coordinator.nowPlayingList.currentIndex == 1)
        #expect(await engine.commands == [.load(media[0]), .load(media[1])])
    }

    @Test("没有当前项或到达不重复边界时推进会请求安全停止")
    func safelyStopsWhenProgressionCannotSelectMedia() async {
        let emptyEngine = FakePlaybackEngine()
        let emptyCoordinator = PlaybackCoordinator(engine: emptyEngine)

        await emptyCoordinator.next()
        #expect(await emptyEngine.commands == [.stop])
        #expect(emptyCoordinator.nowPlayingList.currentMedia == nil)

        let boundaryEngine = FakePlaybackEngine()
        let boundaryCoordinator = PlaybackCoordinator(engine: boundaryEngine)
        let onlyMedia = localMedia("only.mp4")
        await boundaryCoordinator.open([onlyMedia])

        await boundaryCoordinator.next()
        #expect(await boundaryEngine.commands == [.load(onlyMedia), .stop])
        #expect(boundaryCoordinator.nowPlayingList.currentMedia == onlyMedia)
    }

    @Test("新打开的首项不可用时会继续尝试下一项")
    func skipsUnavailableMediaWhileFindingFirstPlayableItem() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = [localMedia("unreadable.mp4"), localMedia("available.mp3")]
        await coordinator.open(media)

        engine.send(.playbackStateChanged(.failed(.unreadable)))
        try await wait(forCurrentIndex: 1, coordinator: coordinator)

        #expect(coordinator.nowPlayingList.currentMedia == media[1])
        #expect(await engine.commands == [.load(media[0]), .load(media[1])])

        engine.send(.playbackStateChanged(.playing))
        try await wait(for: .playing, coordinator: coordinator)
    }

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

    private func localMedia(_ name: String) -> LocalMedia {
        LocalMedia(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func wait(forCurrentIndex expected: Int, coordinator: PlaybackCoordinator) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if coordinator.nowPlayingList.currentIndex == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CoordinatorListTimeout(
            expected: expected,
            observed: coordinator.nowPlayingList.currentIndex
        )
    }
}

private struct CoordinatorStateTimeout: Error {
    let expected: PlaybackState
    let observed: PlaybackState
}

private struct CoordinatorListTimeout: Error {
    let expected: Int
    let observed: Int?
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
