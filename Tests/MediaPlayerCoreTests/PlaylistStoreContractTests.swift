import Foundation
import Testing
@testable import MediaPlayerCore

@Suite("Playlist 存储契约")
struct PlaylistStoreContractTests {
    @Test("内存存储履行提交、冲突回滚与恢复契约")
    func memoryStoreContract() async throws {
        try await verifyPlaylistStoreContract(store: InMemoryPlaylistStore())
    }

    @Test("SQLite 存储履行提交、冲突回滚与恢复契约")
    func sqliteStoreContract() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "playlist-store-\(UUID().uuidString).sqlite")
        let store = try SQLitePlaylistStore(databaseURL: databaseURL)

        try await verifyPlaylistStoreContract(store: store)

        let reopenedStore = try SQLitePlaylistStore(databaseURL: databaseURL)
        let restoredAfterReopen = try await reopenedStore.loadLibrary()
        #expect(restoredAfterReopen.playlists.map(\.name) == ["Weekend Movies"])
    }

    private func verifyPlaylistStoreContract(store: some PlaylistStore) async throws {
        let sharedReferenceID = LocalMediaReferenceID()
        let firstEntry = PlaylistEntry(
            id: PlaylistEntryID(),
            media: PersistentLocalMediaReference(
                id: sharedReferenceID,
                bookmark: Data([0x01, 0x02, 0x03]),
                lastKnownPath: "/tmp/movie.mkv"
            ),
            resumePosition: 42.5,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: TrackPreference(languageCode: "en", title: "Commentary", ordinal: 2),
                subtitle: .embedded(
                    TrackPreference(languageCode: "zh-Hans", title: "简体中文", ordinal: 4)
                )
            )
        )
        let duplicateEntry = PlaylistEntry(
            id: PlaylistEntryID(),
            media: firstEntry.media,
            resumePosition: 7,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: TrackPreference(languageCode: "en", title: nil, ordinal: 1)
            )
        )
        let playlist = Playlist(
            id: PlaylistID(),
            name: "Weekend Movies",
            entries: [firstEntry, duplicateEntry],
            currentEntryID: duplicateEntry.id
        )

        try await store.create(playlist)

        do {
            try await store.create(Playlist(name: "WEEKEND MOVIES", entries: []))
            Issue.record("忽略大小写的重名创建本应失败")
        } catch let error as PlaylistStoreError {
            #expect(error == .nameAlreadyExists("WEEKEND MOVIES"))
        }

        let restored = try await store.loadLibrary()
        #expect(restored.playlists == [playlist])
        #expect(restored.activePlaylistID == playlist.id)
        #expect(restored.playlists[0].entries.map(\.media.id) == [sharedReferenceID, sharedReferenceID])

        let refreshedReference = PersistentLocalMediaReference(
            id: sharedReferenceID,
            bookmark: Data([0xAA, 0xBB]),
            lastKnownPath: "/tmp/moved-movie.mkv"
        )
        try await store.updateMediaReferences([refreshedReference, refreshedReference])
        let refreshed = try await store.loadLibrary()
        #expect(refreshed.playlists[0].entries.map(\.media) == [
            refreshedReference, refreshedReference,
        ])

        let updatedPreferences = EntryPlaybackPreferences(
            audioTrack: TrackPreference(languageCode: "ja", title: "日本語", ordinal: 2),
            subtitle: .off
        )
        try await store.updateEntryPlaybackPreferences(
            playlistID: playlist.id,
            entryID: duplicateEntry.id,
            preferences: updatedPreferences
        )
        let preferencesUpdated = try await store.loadLibrary()
        #expect(preferencesUpdated.playlists[0].entries[0].playbackPreferences == firstEntry.playbackPreferences)
        #expect(preferencesUpdated.playlists[0].entries[1].playbackPreferences == updatedPreferences)
    }
}

@MainActor
@Suite("命名 Playlist 应用行为")
struct NamedPlaylistCoordinatorTests {
    @Test("存储为 Playlist 会原子迁移顺序、重复项、当前条目及条目状态")
    func savesTemporaryListAsNamedPlaylist() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        let sharedMedia = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/repeated.mkv"),
            referenceID: LocalMediaReferenceID(),
            bookmark: Data([0x0A, 0x0B])
        )
        let otherMedia = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/other.mp3"),
            referenceID: LocalMediaReferenceID(),
            bookmark: Data([0x0C])
        )
        await coordinator.open([
            NowPlayingEntry(media: sharedMedia, resumePosition: 31),
            NowPlayingEntry(media: otherMedia),
            NowPlayingEntry(
                media: sharedMedia,
                resumePosition: 9,
                playbackPreferences: EntryPlaybackPreferences(
                    audioTrack: TrackPreference(languageCode: "en", title: "Commentary", ordinal: 3)
                )
            ),
        ])
        await coordinator.next()
        await coordinator.next()

        let saved = try await coordinator.saveNowPlayingList(as: "收藏")

        #expect(saved.name == "收藏")
        #expect(saved.entries.map(\.media.id) == [
            sharedMedia.referenceID, otherMedia.referenceID, sharedMedia.referenceID,
        ])
        #expect(saved.entries.map(\.resumePosition) == [31, nil, 9])
        #expect(saved.entries.last?.playbackPreferences.audioTrack == TrackPreference(
            languageCode: "en",
            title: "Commentary",
            ordinal: 3
        ))
        #expect(saved.currentEntryID == saved.entries[2].id)
        #expect(coordinator.playlists == [saved])
        #expect(coordinator.persistenceNotice == .saved("收藏"))
    }

    @Test("重名或持久化失败会明确提示且不改变原状态")
    func reportsPersistenceFailureWithoutPretendingSuccess() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        let media = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/one.mp4"),
            bookmark: Data([0x01])
        )
        await coordinator.open([media])
        let originalList = coordinator.nowPlayingList
        _ = try await coordinator.saveNowPlayingList(as: "旅行 Trip")

        do {
            _ = try await coordinator.saveNowPlayingList(as: "旅行 TRIP")
            Issue.record("重名保存本应失败")
        } catch {}

        #expect(coordinator.nowPlayingList == originalList)
        #expect(coordinator.playlists.count == 1)
        #expect(coordinator.persistenceNotice == .nameAlreadyExists("旅行 TRIP"))
    }

    @Test("存储不可用时保留临时列表并显示可见错误")
    func keepsTemporaryListWhenStoreIsUnavailable() async {
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: UnavailablePlaylistStore(message: "磁盘写入失败")
        )
        let media = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/unsaved.mp4"),
            bookmark: Data([0x11])
        )
        await coordinator.open([media])
        let originalList = coordinator.nowPlayingList

        do {
            _ = try await coordinator.saveNowPlayingList(as: "未保存")
            Issue.record("不可用存储本应让保存失败")
        } catch {}

        #expect(coordinator.nowPlayingList == originalList)
        #expect(coordinator.playlists.isEmpty)
        #expect(coordinator.persistenceNotice == .failed("磁盘写入失败"))
    }

    @Test("重启恢复 Playlist 与当前条目但不向引擎发出自动播放命令")
    func restoresPersistentContextPaused() async throws {
        let store = InMemoryPlaylistStore()
        let entry = PlaylistEntry(
            media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([0x42]),
                lastKnownPath: "/tmp/restored.flac"
            )
        )
        let playlist = Playlist(name: "恢复列表", entries: [entry], currentEntryID: entry.id)
        try await store.create(playlist)
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)

        try await coordinator.restorePersistentState()

        #expect(coordinator.playlists == [playlist])
        #expect(coordinator.activePlaylistID == playlist.id)
        #expect(coordinator.nowPlayingList.currentMedia?.url.path == "/tmp/restored.flac")
        #expect(coordinator.state == .paused)
        #expect(await engine.commands.isEmpty)

        await coordinator.play()
        #expect(await engine.commands == [.load])
    }

    @Test("恢复层刷新书签时通过存储端口原子更新共享本地媒体引用")
    func persistsRefreshedBookmarkDuringRestore() async throws {
        let store = InMemoryPlaylistStore()
        let referenceID = LocalMediaReferenceID()
        let entry = PlaylistEntry(
            media: PersistentLocalMediaReference(
                id: referenceID,
                bookmark: Data([0x01]),
                lastKnownPath: "/tmp/old-path.mkv"
            )
        )
        try await store.create(Playlist(name: "书签刷新", entries: [entry], currentEntryID: entry.id))
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store,
            persistentMediaAccess: RefreshingMediaAccess()
        )

        try await coordinator.restorePersistentState()

        let restoredLibrary = await store.loadLibrary()
        #expect(restoredLibrary.playlists[0].entries[0].media.bookmark == Data([0x02]))
        #expect(restoredLibrary.playlists[0].entries[0].media.lastKnownPath == "/tmp/new-path.mkv")
    }
}

private struct RefreshingMediaAccess: PersistentMediaAccess {
    func restore(_ reference: PersistentLocalMediaReference) -> LocalMedia {
        LocalMedia(
            url: URL(fileURLWithPath: "/tmp/new-path.mkv"),
            referenceID: reference.id,
            bookmark: Data([0x02])
        )
    }
}

private enum PlaylistEngineCommand: Equatable, Sendable {
    case load
    case play
    case pause
    case stop
}

private actor PlaylistFakePlaybackEngine: PlaybackEngine {
    private(set) var commands: [PlaylistEngineCommand] = []
    nonisolated let events: AsyncStream<PlaybackEngineEvent>

    init() {
        events = AsyncStream { _ in }
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) { commands.append(.load) }
    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() { commands.append(.stop) }
}
