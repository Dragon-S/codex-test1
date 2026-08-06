import Foundation
import Testing
@testable import MediaPlayerCore

@MainActor
@Suite("续播、已播完和基础播放设置")
struct ResumeAndPlaybackSettingsTests {
    @Test("播放超过十秒后约每五秒保存，并在暂停前保存最后位置")
    func periodicallySavesValidResumePositionAndSavesBeforePause() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1)

        await fixture.engine.sendTimeline(position: 9, duration: 120)
        try await waitUntil { fixture.coordinator.position == 9 }
        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == nil)

        await fixture.engine.sendTimeline(position: 11, duration: 120)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).resumePosition == 11
        }
        await fixture.engine.sendTimeline(position: 15, duration: 120)
        try await Task.sleep(for: .milliseconds(10))
        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == 11)

        fixture.timeSource.advance(by: 4)
        await fixture.engine.sendTimeline(position: 17, duration: 120)
        try await Task.sleep(for: .milliseconds(10))
        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == 11)
        fixture.timeSource.advance(by: 1)
        await fixture.engine.sendTimeline(position: 19, duration: 120)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).resumePosition == 19
        }
        await fixture.coordinator.pause()

        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == 19)
        #expect(await fixture.engine.commands.last == .pause)
    }

    @Test("接近结尾会标记已播完，并在下次恢复时从头开始")
    func completedEntryRestartsFromBeginning() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1)

        await fixture.engine.sendTimeline(position: 96, duration: 100)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).isCompleted
        }
        await fixture.coordinator.prepareToTerminate()

        let restartedEngine = ProgressFakePlaybackEngine()
        let restarted = PlaybackCoordinator(engine: restartedEngine, playlistStore: fixture.store)
        try await restarted.restorePersistentState()
        await restarted.play()

        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == nil)
        #expect(await restartedEngine.commands.contains(.seek(to: 0)))
    }

    @Test("用户主动回到开头后退出会清除续播位置")
    func seekingToBeginningClearsResumePosition() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1, resumePositions: [48])

        await fixture.coordinator.seek(to: 0)
        await fixture.engine.sendTimeline(position: 0, duration: 120)
        await fixture.coordinator.prepareToTerminate()

        let entry = try await storedEntry(in: fixture.store, at: 0)
        #expect(entry.resumePosition == nil)
        #expect(!entry.isCompleted)
    }

    @Test("定位失败不会清除已保存的续播状态")
    func failedSeekKeepsPersistedProgress() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1, resumePositions: [48])

        await fixture.coordinator.seek(to: 0)
        await fixture.engine.sendState(.failed(.engineUnavailable))
        try await waitUntil { fixture.coordinator.state == .failed(.engineUnavailable) }

        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == 48)
        #expect(fixture.coordinator.position == 48)
    }

    @Test("播放中途失败会保存最后有效续播位置")
    func playbackFailurePersistsLastConfirmedPosition() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1)

        await fixture.engine.sendTimeline(position: 11, duration: 120)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).resumePosition == 11
        }
        await fixture.engine.sendTimeline(position: 27, duration: 120)
        try await waitUntil { fixture.coordinator.position == 27 }
        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == 11)

        await fixture.engine.sendState(.failed(.corrupted))
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).resumePosition == 27
        }

        #expect(fixture.coordinator.state == .failed(.corrupted))
        #expect(fixture.coordinator.position == 27)
    }

    @Test("连续拖动只把最新定位目标确认为最终保存位置")
    func consecutiveSeeksPersistLatestConfirmedTarget() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1, resumePositions: [48])

        await fixture.coordinator.seek(to: 0)
        await fixture.coordinator.seek(to: 30)
        await fixture.engine.sendTimeline(position: 0, duration: 120)
        try await Task.sleep(for: .milliseconds(10))
        #expect(fixture.coordinator.position == 30)
        #expect(try await storedEntry(in: fixture.store, at: 0).resumePosition == 48)

        await fixture.engine.sendTimeline(position: 30, duration: 120)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).resumePosition == 30
        }
    }

    @Test("退出前保存失败会拒绝终止并保留可见错误")
    func failedTerminationSaveCancelsTermination() async throws {
        let entry = PlaylistEntry(
            media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([0x01]),
                lastKnownPath: "/tmp/termination.mp4"
            ),
            resumePosition: 21
        )
        let playlist = Playlist(name: "退出保存", entries: [entry], currentEntryID: entry.id)
        let store = FailingSnapshotStore(
            library: PlaylistLibrary(playlists: [playlist], activePlaylistID: playlist.id)
        )
        let coordinator = PlaybackCoordinator(
            engine: ProgressFakePlaybackEngine(),
            playlistStore: store
        )
        try await coordinator.restorePersistentState()

        #expect(!(await coordinator.prepareToTerminate()))
        #expect(coordinator.persistenceNotice == .failed("退出保存失败"))
    }

    @Test("同一本地媒体的不同条目保存互不影响")
    func duplicateMediaEntriesKeepIndependentProgress() async throws {
        let sharedReferenceID = LocalMediaReferenceID()
        let fixture = try await makePersistentFixture(
            entryCount: 2,
            sharedReferenceID: sharedReferenceID
        )

        await fixture.engine.sendTimeline(position: 21, duration: 200)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 0).resumePosition == 21
        }
        await fixture.coordinator.next()
        #expect(await fixture.store.loadLibrary().playlists[0].currentEntryID
            == fixture.coordinator.nowPlayingList.entries[1].id)
        await fixture.engine.sendTimeline(position: 44, duration: 200)
        try await waitUntil {
            try await storedEntry(in: fixture.store, at: 1).resumePosition == 44
        }

        let library = await fixture.store.loadLibrary()
        #expect(library.playlists[0].entries.map(\.media.id) == [sharedReferenceID, sharedReferenceID])
        #expect(library.playlists[0].entries.map(\.resumePosition) == [21, 44])
    }

    @Test("定位步长、Playlist 速度和应用级音量静音会发往引擎并持久化")
    func controlsSeekRateAndApplicationAudioSettings() async throws {
        let fixture = try await makePersistentFixture(entryCount: 1)
        await fixture.engine.sendTimeline(position: 40, duration: 100)
        try await waitUntil { fixture.coordinator.position == 40 }

        await fixture.coordinator.setSeekStep(30)
        await fixture.coordinator.skipForward()
        await fixture.coordinator.skipBackward()
        await fixture.coordinator.setPlaybackRate(1.5)
        await fixture.coordinator.setPlayerVolume(0.35)
        await fixture.coordinator.setMuted(true)
        let activePlaylistID = try #require(fixture.coordinator.activePlaylistID)
        try await fixture.coordinator.renamePlaylist(id: activePlaylistID, to: "保留播放设置")

        #expect(await fixture.engine.commands.suffix(5) == [
            .seek(to: 70), .seek(to: 40), .setRate(1.5), .setVolume(0.35), .setMuted(true),
        ])
        let library = await fixture.store.loadLibrary()
        #expect(library.playlists[0].playbackRate == 1.5)
        #expect(library.playlists[0].name == "保留播放设置")
        #expect(library.playerVolume == 0.35)
        #expect(library.isMuted)
        #expect(library.seekStep == 30)

        let restoredEngine = ProgressFakePlaybackEngine()
        let restored = PlaybackCoordinator(engine: restoredEngine, playlistStore: fixture.store)
        try await restored.restorePersistentState()
        #expect(restored.playbackRate == 1.5)
        #expect(restored.playerVolume == 0.35)
        #expect(restored.isMuted)
        #expect(restored.seekStep == 30)
        #expect(restored.state == .paused)
        await restored.play()
        #expect(await restoredEngine.commands == [
            .load, .setRate(1.5), .setVolume(0.35), .setMuted(true), .seek(to: 40),
        ])
    }

    @Test("基础设置持久化失败时回滚用户可见状态和引擎设置")
    func rollsBackSettingsWhenPersistenceFails() async {
        let engine = ProgressFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: UnavailablePlaylistStore(message: "磁盘不可用")
        )

        await coordinator.setPlayerVolume(0.25)
        await coordinator.setMuted(true)
        await coordinator.setSeekStep(30)

        #expect(coordinator.playerVolume == 1)
        #expect(!coordinator.isMuted)
        #expect(coordinator.seekStep == 10)
        #expect(coordinator.persistenceNotice == .failed("磁盘不可用"))
        #expect(await engine.commands == [
            .setVolume(0.25), .setVolume(1), .setMuted(true), .setMuted(false),
        ])
    }

    private func makePersistentFixture(
        entryCount: Int,
        resumePositions: [TimeInterval?] = [],
        sharedReferenceID: LocalMediaReferenceID? = nil
    ) async throws -> PersistentFixture {
        let entries = (0..<entryCount).map { index in
            PlaylistEntry(
                media: PersistentLocalMediaReference(
                    id: sharedReferenceID ?? LocalMediaReferenceID(),
                    bookmark: Data([UInt8(index)]),
                    lastKnownPath: "/tmp/item-\(index).mp4"
                ),
                resumePosition: resumePositions.indices.contains(index) ? resumePositions[index] : nil
            )
        }
        let playlist = Playlist(
            name: "测试 Playlist",
            entries: entries,
            currentEntryID: entries.first?.id
        )
        let store = InMemoryPlaylistStore()
        try await store.create(playlist)
        let engine = ProgressFakePlaybackEngine()
        let timeSource = MutablePlaybackTimeSource()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            timeSource: timeSource
        )
        try await coordinator.restorePersistentState()
        await coordinator.play()
        return PersistentFixture(
            coordinator: coordinator,
            engine: engine,
            store: store,
            timeSource: timeSource
        )
    }

    private func storedEntry(
        in store: InMemoryPlaylistStore,
        at index: Int
    ) async throws -> PlaylistEntry {
        let library = await store.loadLibrary()
        return try #require(library.playlists.first?.entries[index])
    }

    private func waitUntil(
        _ condition: @escaping @MainActor @Sendable () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("等待协调层公开状态或持久化结果超时")
    }
}

private struct PersistentFixture {
    let coordinator: PlaybackCoordinator
    let engine: ProgressFakePlaybackEngine
    let store: InMemoryPlaylistStore
    let timeSource: MutablePlaybackTimeSource
}

private final class MutablePlaybackTimeSource: PlaybackTimeSource, @unchecked Sendable {
    private(set) var now: TimeInterval = 0

    func advance(by interval: TimeInterval) {
        now += interval
    }
}

private actor FailingSnapshotStore: PlaylistStore {
    private let library: PlaylistLibrary

    init(library: PlaylistLibrary) {
        self.library = library
    }

    func create(_ playlist: Playlist) {}
    func commit(_ library: PlaylistLibrary) {}
    func loadLibrary() -> PlaylistLibrary { library }
    func updateMediaReferences(_ references: [PersistentLocalMediaReference]) {}
    func updateExternalSubtitleReferences(
        _ references: [PersistentExternalSubtitleReference]
    ) {}
    func updateEntryPlaybackPreferences(
        playlistID: PlaylistID,
        entryID: PlaylistEntryID,
        preferences: EntryPlaybackPreferences
    ) {}
    func savePlaybackSnapshot(_ snapshot: PlaybackPersistenceSnapshot) throws {
        throw PlaylistStoreError.unavailable("退出保存失败")
    }
}

private enum ProgressEngineCommand: Equatable, Sendable {
    case load
    case play
    case pause
    case stop
    case seek(to: TimeInterval)
    case setRate(Double)
    case setVolume(Double)
    case setMuted(Bool)
}

private actor ProgressFakePlaybackEngine: PlaybackEngine {
    private(set) var commands: [ProgressEngineCommand] = []
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private var loadID: PlaybackLoadID?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        self.loadID = loadID
        commands.append(.load)
    }

    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() { commands.append(.stop) }
    func seek(to position: TimeInterval) { commands.append(.seek(to: position)) }
    func setPlaybackRate(_ rate: Double) { commands.append(.setRate(rate)) }
    func setPlayerVolume(_ volume: Double) { commands.append(.setVolume(volume)) }
    func setMuted(_ isMuted: Bool) { commands.append(.setMuted(isMuted)) }

    func sendTimeline(position: TimeInterval, duration: TimeInterval) {
        guard let loadID else { return }
        continuation.yield(.timelineChanged(position: position, duration: duration, loadID: loadID))
    }

    func sendState(_ state: PlaybackState) {
        guard let loadID else { return }
        continuation.yield(.playbackStateChanged(state, loadID: loadID))
    }
}
