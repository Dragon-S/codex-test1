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

        #expect(coordinator.nowPlayingList.entries.map(\.media) == media)
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

        #expect(coordinator.nowPlayingList.entries.map(\.media) == newMedia)
        #expect(coordinator.nowPlayingList.currentIndex == 0)
        #expect(await engine.commands == [.load(oldMedia[0]), .load(newMedia[0])])
    }

    @Test("新打开后忽略旧加载代次迟到的失败与结束事件")
    func ignoresStaleEventsAfterReplacingNowPlayingList() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let oldMedia = [localMedia("old-first.mp4"), localMedia("old-second.mp4")]
        let newMedia = [localMedia("new-first.mp3"), localMedia("new-second.mkv")]
        await coordinator.open(oldMedia)
        let oldLoadID = try #require(await engine.loadIDs.first)

        await coordinator.open(newMedia)
        let newLoadID = try #require(await engine.loadIDs.last)
        engine.send(.playbackStateChanged(.failed(.unreadable), loadID: oldLoadID))
        engine.send(.playbackEnded(loadID: oldLoadID))
        engine.send(.playbackStateChanged(.playing, loadID: newLoadID))
        try await wait(for: .playing, coordinator: coordinator)

        #expect(coordinator.nowPlayingList.entries.map(\.media) == newMedia)
        #expect(coordinator.nowPlayingList.currentIndex == 0)
        #expect(await engine.commands == [.load(oldMedia[0]), .load(newMedia[0])])
    }

    @Test("协调层只发布当前加载的音频标题、艺人、专辑与封面状态")
    func publishesAudioPresentationForCurrentLoadOnly() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await coordinator.open([localMedia("first.flac")])
        let firstLoadID = try #require(await engine.loadIDs.last)

        let expected = PlaybackMediaPresentation(
            kind: .audio,
            title: "夜航",
            artist: "测试艺人",
            album: "测试专辑",
            hasArtwork: true
        )
        engine.send(.mediaPresentationChanged(expected, loadID: firstLoadID))
        try await wait(for: expected, coordinator: coordinator)

        await coordinator.open([localMedia("second.mp4")])
        #expect(coordinator.mediaPresentation == nil)
        engine.send(.mediaPresentationChanged(
            PlaybackMediaPresentation(kind: .audio, title: "迟到标题"),
            loadID: firstLoadID
        ))
        try await Task.sleep(for: .milliseconds(10))

        #expect(coordinator.mediaPresentation == nil)
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

        await engine.sendPlaybackEnded()
        try await wait(forCurrentIndex: 1, coordinator: coordinator)
        #expect(await engine.commands == [.load(media[0]), .load(media[1])])

        await engine.sendPlaybackEnded()
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
        await boundaryCoordinator.previous()
        #expect(await boundaryEngine.commands == [.load(onlyMedia), .stop, .stop])
        #expect(boundaryCoordinator.nowPlayingList.currentMedia == onlyMedia)
        #expect(boundaryCoordinator.missingMediaNotice == .none)
    }

    @Test("新打开的首项不可用时会继续尝试下一项")
    func skipsUnavailableMediaWhileFindingFirstPlayableItem() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = [localMedia("unreadable.mp4"), localMedia("available.mp3")]
        await coordinator.open(media)

        await engine.sendState(.failed(.unreadable))
        try await wait(forCurrentIndex: 1, coordinator: coordinator)

        #expect(coordinator.nowPlayingList.currentMedia == media[1])
        #expect(await engine.commands == [.load(media[0]), .load(media[1])])

        await engine.sendState(.playing)
        try await wait(for: .playing, coordinator: coordinator)
    }

    @Test("新打开的所有条目都不可用时保留末项失败并停止尝试")
    func stopsTryingAfterAllNewMediaAreUnavailable() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = [localMedia("first-unreadable.mp4"), localMedia("second-corrupted.mkv")]
        await coordinator.open(media)

        await engine.sendState(.failed(.unreadable))
        try await wait(forCurrentIndex: 1, coordinator: coordinator)
        await engine.sendState(.failed(.corrupted))
        try await wait(for: .failed(.corrupted), coordinator: coordinator)

        #expect(coordinator.nowPlayingList.currentMedia == media[1])
        #expect(await engine.commands == [.load(media[0]), .load(media[1])])
    }

    @Test("打开本地媒体后等待真实引擎状态")
    func waitsForEngineStateAfterOpeningLocalMedia() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = LocalMedia(url: URL(fileURLWithPath: "/tmp/example.mp4"))

        await coordinator.open(media)

        #expect(await engine.commands == [.load(media)])
        #expect(coordinator.state == .idle)

        await engine.sendState(.playing)
        try await wait(for: .playing, coordinator: coordinator)

        #expect(coordinator.state == .playing)
    }

    @Test("播放、暂停与停止由协调层转发并由引擎事件确认")
    func forwardsPlaybackControlsAndReflectsEngineEvents() async throws {
        let engine = FakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let media = localMedia("controls.mp4")
        await coordinator.open(media)

        await coordinator.play()
        await coordinator.pause()
        await coordinator.stop()

        #expect(await engine.commands == [.load(media), .play, .pause, .stop])
        #expect(coordinator.state == .idle)

        await engine.sendState(.paused)
        try await wait(for: .paused, coordinator: coordinator)
        #expect(coordinator.state == .paused)

        await engine.sendState(.stopped)
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

    private func wait(
        for expected: PlaybackMediaPresentation,
        coordinator: PlaybackCoordinator
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if coordinator.mediaPresentation == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CoordinatorMediaPresentationTimeout(
            expected: expected,
            observed: coordinator.mediaPresentation
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

private struct CoordinatorMediaPresentationTimeout: Error {
    let expected: PlaybackMediaPresentation
    let observed: PlaybackMediaPresentation?
}

private enum PlaybackEngineCommand: Equatable, Sendable {
    case load(LocalMedia)
    case play
    case pause
    case stop
}

private actor FakePlaybackEngine: PlaybackEngine {
    private(set) var commands: [PlaybackEngineCommand] = []
    private(set) var loadIDs: [PlaybackLoadID] = []
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        commands.append(.load(media))
        loadIDs.append(loadID)
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

    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) {}
    func setMuted(_ isMuted: Bool) {}

    func sendState(_ state: PlaybackState) {
        guard let loadID = loadIDs.last else { return }
        continuation.yield(.playbackStateChanged(state, loadID: loadID))
    }

    func sendPlaybackEnded() {
        guard let loadID = loadIDs.last else { return }
        continuation.yield(.playbackEnded(loadID: loadID))
    }

    nonisolated func send(_ event: PlaybackEngineEvent) {
        continuation.yield(event)
    }
}
