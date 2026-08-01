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
        #expect(restoredAfterReopen.playlists.map(\.name) == ["周末电影"])
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
                audioTrackID: "audio-2",
                embeddedSubtitleTrackID: "subtitle-4"
            )
        )
        let duplicateEntry = PlaylistEntry(
            id: PlaylistEntryID(),
            media: firstEntry.media,
            resumePosition: 7,
            playbackPreferences: EntryPlaybackPreferences(audioTrackID: "audio-1")
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

        let renamedAndReordered = Playlist(
            id: playlist.id,
            name: "周末电影",
            entries: [
                refreshed.playlists[0].entries[1],
                refreshed.playlists[0].entries[0],
            ],
            currentEntryID: firstEntry.id
        )
        try await store.commit(PlaylistLibrary(
            playlists: [renamedAndReordered],
            activePlaylistID: playlist.id
        ))

        let edited = try await store.loadLibrary()
        #expect(edited.playlists == [renamedAndReordered])
        #expect(edited.activePlaylistID == playlist.id)
    }
}

@MainActor
@Suite("命名 Playlist 应用行为")
struct NamedPlaylistCoordinatorTests {
    @Test("创建空 Playlist 后可重命名，重名失败不改变已提交状态")
    func createsAndRenamesPlaylistAtomically() async throws {
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store
        )

        let first = try await coordinator.createPlaylist(named: "电影")
        let second = try await coordinator.createPlaylist(named: "音乐")
        try await coordinator.renamePlaylist(id: second.id, to: "原声")

        do {
            try await coordinator.renamePlaylist(id: second.id, to: "电影")
            Issue.record("重名重命名本应失败")
        } catch let error as PlaylistStoreError {
            #expect(error == .nameAlreadyExists("电影"))
        }

        #expect(first.entries.isEmpty)
        #expect(coordinator.playlists.map(\.name) == ["电影", "原声"])
        #expect(coordinator.browsingPlaylistID == second.id)
        #expect(coordinator.activePlaylistID == nil)
        #expect((await store.loadLibrary()).playlists == coordinator.playlists)
    }

    @Test("重复条目身份独立，浏览不切换来源，重排实时影响播放顺序")
    func separatesBrowsingFromPlayingAndReordersLiveSource() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playingPlaylist = try await coordinator.createPlaylist(named: "正在播放")
        let sharedMedia = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/shared.mkv"),
            referenceID: LocalMediaReferenceID(),
            bookmark: Data([0x21])
        )
        let otherMedia = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/other.mp3"),
            bookmark: Data([0x22])
        )
        let first = try await coordinator.add(sharedMedia, to: playingPlaylist.id)
        let second = try await coordinator.add(otherMedia, to: playingPlaylist.id)
        let duplicate = try await coordinator.duplicateEntry(first.id, in: playingPlaylist.id)
        let browsingPlaylist = try await coordinator.createPlaylist(named: "只浏览")

        try await coordinator.playEntry(first.id, in: playingPlaylist.id)
        coordinator.browsePlaylist(browsingPlaylist.id)
        try await coordinator.moveEntry(duplicate.id, in: playingPlaylist.id, to: 1)

        #expect(first.id != duplicate.id)
        #expect(first.media.id == duplicate.media.id)
        #expect(duplicate.resumePosition == nil)
        #expect(duplicate.playbackPreferences == EntryPlaybackPreferences())
        #expect(coordinator.activePlaylistID == playingPlaylist.id)
        #expect(coordinator.browsingPlaylistID == browsingPlaylist.id)
        #expect(coordinator.nowPlayingList.entries.map(\.id) == [first.id, duplicate.id, second.id])
        #expect(coordinator.nowPlayingList.currentMedia == sharedMedia)
        #expect(await engine.commands == [.load])
    }

    @Test("重复选择同一磁盘文件会共享本地媒体引用但创建独立条目")
    func reusesMediaReferenceForTheSameFileIdentity() async throws {
        let coordinator = PlaybackCoordinator(engine: PlaylistFakePlaybackEngine())
        let playlist = try await coordinator.createPlaylist(named: "重复媒体")
        let fileIdentity = Data([0xF1, 0x1E])
        let first = try await coordinator.add(
            LocalMedia(
                url: URL(fileURLWithPath: "/tmp/original-name.mkv"),
                referenceID: LocalMediaReferenceID(),
                bookmark: Data([0x51]),
                fileIdentity: fileIdentity
            ),
            to: playlist.id
        )
        let duplicate = try await coordinator.add(
            LocalMedia(
                url: URL(fileURLWithPath: "/tmp/renamed-file.mkv"),
                referenceID: LocalMediaReferenceID(),
                bookmark: Data([0x52]),
                fileIdentity: fileIdentity
            ),
            to: playlist.id
        )

        #expect(first.id != duplicate.id)
        #expect(first.media.id == duplicate.media.id)
        #expect(coordinator.playlists[0].entries.map(\.media.lastKnownPath) == [
            "/tmp/renamed-file.mkv", "/tmp/renamed-file.mkv",
        ])
    }

    @Test("移除当前条目后媒体脱离列表继续，结束后从原位置推进")
    func detachesRemovedCurrentEntryAndAdvancesFromItsFormerPosition() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        let playlist = try await coordinator.createPlaylist(named: "连续播放")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0x31), to: playlist.id)
        let current = try await coordinator.add(bookmarkedMedia("current.mp4", 0x32), to: playlist.id)
        let next = try await coordinator.add(bookmarkedMedia("next.mp4", 0x33), to: playlist.id)
        let last = try await coordinator.add(bookmarkedMedia("last.mp4", 0x34), to: playlist.id)
        try await coordinator.playEntry(current.id, in: playlist.id)

        try await coordinator.removeEntry(current.id, from: playlist.id)
        try await coordinator.removeEntry(next.id, from: playlist.id)

        #expect(coordinator.detachedNowPlayingEntry?.id == current.id)
        #expect(coordinator.nowPlayingList.entries.map(\.id) == [first.id, last.id])
        #expect(coordinator.nowPlayingList.currentIndex == nil)
        #expect(await engine.commands == [.load])

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.nowPlayingList.currentMedia?.url.lastPathComponent == "last.mp4" }

        #expect(coordinator.detachedNowPlayingEntry == nil)
        #expect(coordinator.nowPlayingList.currentIndex == 1)
        #expect(await engine.commands == [.load, .load])
        let persisted = await store.loadLibrary()
        #expect(persisted.playlists[0].entries.map(\.id) == [first.id, last.id])
        #expect(persisted.playlists[0].currentEntryID == last.id)
    }

    @Test("删除正在使用的 Playlist 需确认，当前媒体结束后停止且重启不恢复")
    func confirmsDeletionOfPlayingPlaylistAndDoesNotRestoreIt() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        let playlist = try await coordinator.createPlaylist(named: "待删除")
        let current = try await coordinator.add(bookmarkedMedia("current.flac", 0x41), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("next.flac", 0x42), to: playlist.id)
        try await coordinator.playEntry(current.id, in: playlist.id)

        do {
            try await coordinator.deletePlaylist(playlist.id, confirmed: false)
            Issue.record("删除正在使用的 Playlist 本应要求确认")
        } catch let error as PlaylistPersistenceError {
            #expect(error == .deletionConfirmationRequired(playlist.id))
        }
        #expect(coordinator.playlists.count == 1)

        try await coordinator.deletePlaylist(playlist.id, confirmed: true)

        #expect(coordinator.playlists.isEmpty)
        #expect(coordinator.activePlaylistID == nil)
        #expect(coordinator.browsingPlaylistID == nil)
        #expect(coordinator.detachedNowPlayingEntry?.id == current.id)
        #expect(await engine.commands == [.load])

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.state == .stopped }
        #expect(await engine.commands == [.load])

        let restoredEngine = PlaylistFakePlaybackEngine()
        let restored = PlaybackCoordinator(engine: restoredEngine, playlistStore: store)
        try await restored.restorePersistentState()
        #expect(restored.playlists.isEmpty)
        #expect(restored.nowPlayingList.entries.isEmpty)
        #expect(await restoredEngine.commands.isEmpty)
    }

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
                playbackPreferences: EntryPlaybackPreferences(audioTrackID: "commentary")
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
        #expect(saved.entries.last?.playbackPreferences.audioTrackID == "commentary")
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

private func bookmarkedMedia(_ name: String, _ bookmarkByte: UInt8) -> LocalMedia {
    LocalMedia(
        url: URL(fileURLWithPath: "/tmp/\(name)"),
        bookmark: Data([bookmarkByte])
    )
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("等待协调层状态更新超时")
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
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private var loadIDs: [PlaybackLoadID] = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        commands.append(.load)
        loadIDs.append(loadID)
    }
    func play() { commands.append(.play) }
    func pause() { commands.append(.pause) }
    func stop() { commands.append(.stop) }

    func sendPlaybackEnded() {
        guard let loadID = loadIDs.last else { return }
        continuation.yield(.playbackEnded(loadID: loadID))
    }
}
