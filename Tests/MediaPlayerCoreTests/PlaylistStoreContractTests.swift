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
            isCompleted: true,
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
            currentEntryID: duplicateEntry.id,
            playbackOrder: .random,
            repeatMode: .playlist,
            randomRound: RandomPlaybackRound(
                order: [duplicateEntry.id, firstEntry.id],
                playedEntryIDs: [duplicateEntry.id],
                unavailableEntryIDs: [firstEntry.id]
            )
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

        try await store.savePlaybackSnapshot(PlaybackPersistenceSnapshot(
            playlistID: playlist.id,
            entryID: duplicateEntry.id,
            resumePosition: 73,
            isCompleted: false,
            playbackRate: 1.5,
            playerVolume: 0.4,
            isMuted: true
        ))
        let playbackState = try await store.loadLibrary()
        #expect(playbackState.playlists[0].entries.map(\.resumePosition) == [42.5, 73])
        #expect(playbackState.playlists[0].playbackRate == 1.5)
        #expect(playbackState.playlists[0].playbackOrder == .random)
        #expect(playbackState.playlists[0].repeatMode == .playlist)
        #expect(playbackState.playlists[0].randomRound == playlist.randomRound)
        #expect(playbackState.playerVolume == 0.4)
        #expect(playbackState.isMuted)

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
        #expect(refreshed.playlists[0].entries.map(\.resumePosition) == [42.5, 73])
        #expect(refreshed.playlists[0].entries.map(\.isCompleted) == [true, false])
        #expect(refreshed.playlists[0].playbackRate == 1.5)
        #expect(refreshed.playerVolume == 0.4)
        #expect(refreshed.isMuted)

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
        #expect(preferencesUpdated.playlists[0].entries.map(\.isCompleted) == [true, false])
        #expect(preferencesUpdated.playlists[0].playbackRate == 1.5)
        #expect(preferencesUpdated.playerVolume == 0.4)
        #expect(preferencesUpdated.isMuted)

        let sharedExternalSubtitle = PersistentExternalSubtitleReference(
            id: ExternalSubtitleReferenceID(),
            bookmark: Data([0x20]),
            lastKnownPath: "/tmp/old-shared.srt"
        )
        let sharedSubtitlePreferences = EntryPlaybackPreferences(
            subtitle: .external(sharedExternalSubtitle)
        )
        try await store.updateEntryPlaybackPreferences(
            playlistID: playlist.id,
            entryID: firstEntry.id,
            preferences: sharedSubtitlePreferences
        )
        try await store.updateEntryPlaybackPreferences(
            playlistID: playlist.id,
            entryID: duplicateEntry.id,
            preferences: sharedSubtitlePreferences
        )
        let relocatedExternalSubtitle = PersistentExternalSubtitleReference(
            id: sharedExternalSubtitle.id,
            bookmark: Data([0x21]),
            lastKnownPath: "/tmp/new-shared.srt"
        )
        try await store.updateExternalSubtitleReferences([relocatedExternalSubtitle])
        let externalSubtitleUpdated = try await store.loadLibrary()
        #expect(externalSubtitleUpdated.playlists[0].entries.allSatisfy {
            $0.playbackPreferences.subtitle == .external(relocatedExternalSubtitle)
        })
        #expect(externalSubtitleUpdated.playlists[0].entries.map(\.isCompleted) == [true, false])
        #expect(externalSubtitleUpdated.playlists[0].playbackRate == 1.5)
        #expect(externalSubtitleUpdated.playerVolume == 0.4)
        #expect(externalSubtitleUpdated.isMuted)

        let renamedAndReordered = Playlist(
            id: playlist.id,
            name: "周末电影",
            entries: [
                externalSubtitleUpdated.playlists[0].entries[1],
                externalSubtitleUpdated.playlists[0].entries[0],
            ],
            currentEntryID: firstEntry.id,
            playbackOrder: .random,
            repeatMode: .playlist,
            randomRound: playlist.randomRound
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
        let fileIdentity = LocalFileIdentity(rawValue: Data([0xF1, 0x1E]))
        let first = try await coordinator.add(
            LocalMedia(
                url: URL(fileURLWithPath: "/tmp/original-name.mkv"),
                referenceID: LocalMediaReferenceID(),
                bookmark: Data([0x51])
            ),
            to: playlist.id
        )
        let upgradedLegacyReference = try await coordinator.add(
            LocalMedia(
                url: URL(fileURLWithPath: "/tmp/original-name.mkv"),
                referenceID: LocalMediaReferenceID(),
                bookmark: Data([0x52]),
                fileIdentity: fileIdentity
            ),
            to: playlist.id
        )
        let duplicateAfterRename = try await coordinator.add(
            LocalMedia(
                url: URL(fileURLWithPath: "/tmp/renamed-file.mkv"),
                referenceID: LocalMediaReferenceID(),
                bookmark: Data([0x53]),
                fileIdentity: fileIdentity
            ),
            to: playlist.id
        )

        #expect(first.id != upgradedLegacyReference.id)
        #expect(upgradedLegacyReference.id != duplicateAfterRename.id)
        #expect(first.media.id == upgradedLegacyReference.media.id)
        #expect(first.media.id == duplicateAfterRename.media.id)
        #expect(coordinator.playlists[0].entries.map(\.media.lastKnownPath) == [
            "/tmp/renamed-file.mkv", "/tmp/renamed-file.mkv", "/tmp/renamed-file.mkv",
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

@MainActor
@Suite("播放顺序、重复方式与随机轮次")
struct PlaylistProgressionTests {
    @Test("顺序播放分别在边界停止、循环列表或重复单条")
    func advancesSequentiallyForEveryRepeatMode() async throws {
        let noRepeat = try await makeProgressionFixture(repeatMode: .none)
        await noRepeat.engine.sendPlaybackEnded()
        try await waitUntil { noRepeat.coordinator.nowPlayingList.currentIndex == 1 }
        await noRepeat.engine.sendPlaybackEnded()
        try await waitUntil { noRepeat.coordinator.state == .stopped }
        #expect(noRepeat.coordinator.nowPlayingList.currentIndex == 1)

        let repeatPlaylist = try await makeProgressionFixture(repeatMode: .playlist)
        await repeatPlaylist.engine.sendPlaybackEnded()
        try await waitUntil { repeatPlaylist.coordinator.nowPlayingList.currentIndex == 1 }
        await repeatPlaylist.engine.sendPlaybackEnded()
        try await waitUntil { repeatPlaylist.coordinator.nowPlayingList.currentIndex == 0 }

        let repeatEntry = try await makeProgressionFixture(repeatMode: .entry)
        await repeatEntry.engine.sendPlaybackEnded()
        try await waitUntilAsync { await repeatEntry.engine.commands.count == 2 }
        #expect(repeatEntry.coordinator.nowPlayingList.currentIndex == 0)
    }

    @Test("随机不重复会按持久轮次选完所有条目，重启后继续而不早重复")
    func persistsRandomRoundAcrossRestartWithoutPrematureRepeats() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            randomizer: ReversePlaylistRandomizer()
        )
        let playlist = try await coordinator.createPlaylist(named: "随机")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0x71), to: playlist.id)
        let second = try await coordinator.add(bookmarkedMedia("second.mp4", 0x72), to: playlist.id)
        let third = try await coordinator.add(bookmarkedMedia("third.mp4", 0x73), to: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 2 }

        let persistedRound = try #require((await store.loadLibrary()).playlists[0].randomRound)
        #expect(persistedRound.order == [first.id, third.id, second.id])
        #expect(persistedRound.playedEntryIDs == [first.id, third.id])

        let restoredEngine = PlaylistFakePlaybackEngine()
        let restored = PlaybackCoordinator(
            engine: restoredEngine,
            playlistStore: store,
            randomizer: ReversePlaylistRandomizer()
        )
        try await restored.restorePersistentState()
        #expect(restored.nowPlayingList.currentIndex == 2)
        await restored.play()
        await restoredEngine.sendPlaybackEnded()
        try await waitUntil { restored.nowPlayingList.currentIndex == 1 }
        await restoredEngine.sendPlaybackEnded()
        try await waitUntil { restored.state == .stopped }

        let completedRound = try #require((await store.loadLibrary()).playlists[0].randomRound)
        #expect(completedRound.playedEntryIDs == [first.id, third.id, second.id])
    }

    @Test("随机轮次吸收新增、移除删除且不受重排影响，关闭后回到实时顺序")
    func reconcilesPlaylistEditsAndLeavesRandomAtLivePosition() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            randomizer: ReversePlaylistRandomizer()
        )
        let playlist = try await coordinator.createPlaylist(named: "编辑随机轮次")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0x81), to: playlist.id)
        let second = try await coordinator.add(bookmarkedMedia("second.mp4", 0x82), to: playlist.id)
        let third = try await coordinator.add(bookmarkedMedia("third.mp4", 0x83), to: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)

        let initialRound = try #require(coordinator.playlists[0].randomRound)
        let fourth = try await coordinator.add(bookmarkedMedia("fourth.mp4", 0x84), to: playlist.id)
        let afterAdd = try #require(coordinator.playlists[0].randomRound)
        #expect(afterAdd.order.contains(fourth.id))
        #expect(!afterAdd.playedEntryIDs.contains(fourth.id))

        try await coordinator.moveEntry(second.id, in: playlist.id, to: 0)
        #expect(coordinator.playlists[0].randomRound == afterAdd)

        try await coordinator.removeEntry(third.id, from: playlist.id)
        let afterRemove = try #require(coordinator.playlists[0].randomRound)
        #expect(!afterRemove.order.contains(third.id))
        #expect(!afterRemove.playedEntryIDs.contains(third.id))
        #expect(afterRemove.order.filter { $0 != fourth.id } == initialRound.order.filter { $0 != third.id })

        try await coordinator.setPlaybackOrder(.sequential, for: playlist.id)
        #expect(coordinator.playlists[0].randomRound == nil)
        #expect(coordinator.nowPlayingList.currentIndex == 1)
        await coordinator.next()
        #expect(coordinator.nowPlayingList.currentIndex == 2)
        #expect(coordinator.nowPlayingList.currentMedia?.url.lastPathComponent == "fourth.mp4")
    }

    @Test("随机下一首使用轮次，上一首回到已播放历史")
    func navigatesRandomRoundAndHistory() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            randomizer: ReversePlaylistRandomizer()
        )
        let playlist = try await coordinator.createPlaylist(named: "随机导航")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0x91), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("second.mp4", 0x92), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("third.mp4", 0x93), to: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)

        await coordinator.next()
        #expect(coordinator.nowPlayingList.currentIndex == 2)
        await coordinator.previous()
        #expect(coordinator.nowPlayingList.currentIndex == 0)
    }

    @Test("随机播放在空列表和单条列表的三种重复边界都有限终止")
    func handlesEmptyAndSingleEntryRandomBoundaries() async throws {
        let emptyEngine = PlaylistFakePlaybackEngine()
        let empty = PlaybackCoordinator(engine: emptyEngine)
        let emptyPlaylist = try await empty.createPlaylist(named: "空")
        try await empty.setPlaybackOrder(.random, for: emptyPlaylist.id)
        try await empty.setRepeatMode(.playlist, for: emptyPlaylist.id)
        await empty.next()
        #expect(await emptyEngine.commands == [.stop])

        let noRepeat = try await makeSingleEntryRandomFixture(repeatMode: .none)
        await noRepeat.engine.sendPlaybackEnded()
        try await waitUntil { noRepeat.coordinator.state == .stopped }
        #expect(await noRepeat.engine.commands == [.load])

        let repeatPlaylist = try await makeSingleEntryRandomFixture(repeatMode: .playlist)
        await repeatPlaylist.engine.sendPlaybackEnded()
        try await waitUntilAsync { await repeatPlaylist.engine.commands.count == 2 }
        #expect(repeatPlaylist.coordinator.nowPlayingList.currentIndex == 0)

        let repeatEntry = try await makeSingleEntryRandomFixture(repeatMode: .entry)
        await repeatEntry.engine.sendPlaybackEnded()
        try await waitUntilAsync { await repeatEntry.engine.commands.count == 2 }
        #expect(repeatEntry.coordinator.nowPlayingList.currentIndex == 0)
    }

    @Test("随机轮次删除当前条目后不会再次自动选择脱离状态的后继条目")
    func removesCurrentEntryFromRandomRoundWithoutRepeatingItsSuccessor() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            randomizer: ReversePlaylistRandomizer()
        )
        let playlist = try await coordinator.createPlaylist(named: "删除当前随机条目")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0xA1), to: playlist.id)
        let second = try await coordinator.add(bookmarkedMedia("second.mp4", 0xA2), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("third.mp4", 0xA3), to: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)

        try await coordinator.removeEntry(first.id, from: playlist.id)
        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 0 }
        #expect(coordinator.nowPlayingList.entries[0].id == second.id)

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 1 }
        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.state == .stopped }
        #expect(await engine.commands == [.load, .load, .load])
    }

    @Test("随机自动推进会有限跳过失败条目且不把它们算作已播放")
    func exhaustsFailedRandomEntriesWithoutCountingThemAsPlayed() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            randomizer: ReversePlaylistRandomizer()
        )
        let playlist = try await coordinator.createPlaylist(named: "全不可播放")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0xB1), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("second.mp4", 0xB2), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("third.mp4", 0xB3), to: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)

        await engine.sendPlaybackEnded()
        try await waitUntilAsync { await engine.commands.count == 2 }
        await engine.sendState(.failed(.unreadable))
        try await waitUntilAsync { await engine.commands.count == 3 }
        await engine.sendState(.failed(.corrupted))
        try await waitUntil { coordinator.state == .stopped }

        let round = try #require((await store.loadLibrary()).playlists[0].randomRound)
        #expect(round.playedEntryIDs == [first.id])
        #expect(round.unavailableEntryIDs.count == 2)
        #expect(await engine.commands == [.load, .load, .load])
    }

    private func makeProgressionFixture(
        repeatMode: PlaylistRepeatMode
    ) async throws -> ProgressionFixture {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        let playlist = try await coordinator.createPlaylist(named: "推进")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0x61), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("second.mp4", 0x62), to: playlist.id)
        try await coordinator.setRepeatMode(repeatMode, for: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)
        return ProgressionFixture(coordinator: coordinator, engine: engine, store: store)
    }

    private func makeSingleEntryRandomFixture(
        repeatMode: PlaylistRepeatMode
    ) async throws -> ProgressionFixture {
        let engine = PlaylistFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            randomizer: ReversePlaylistRandomizer()
        )
        let playlist = try await coordinator.createPlaylist(named: "单条")
        let entry = try await coordinator.add(bookmarkedMedia("only.mp4", 0x94), to: playlist.id)
        try await coordinator.playEntry(entry.id, in: playlist.id)
        try await coordinator.setPlaybackOrder(.random, for: playlist.id)
        try await coordinator.setRepeatMode(repeatMode, for: playlist.id)
        return ProgressionFixture(coordinator: coordinator, engine: engine, store: store)
    }
}

private struct ReversePlaylistRandomizer: PlaylistRandomizer {
    func shuffled(_ entryIDs: [PlaylistEntryID]) -> [PlaylistEntryID] {
        entryIDs.reversed()
    }
}

private struct ProgressionFixture {
    let coordinator: PlaybackCoordinator
    let engine: PlaylistFakePlaybackEngine
    let store: InMemoryPlaylistStore
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

@MainActor
private func waitUntilAsync(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("等待协调层异步状态更新超时")
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
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) {}
    func setMuted(_ isMuted: Bool) {}

    func sendPlaybackEnded() {
        guard let loadID = loadIDs.last else { return }
        continuation.yield(.playbackEnded(loadID: loadID))
    }

    func sendState(_ state: PlaybackState) {
        guard let loadID = loadIDs.last else { return }
        continuation.yield(.playbackStateChanged(state, loadID: loadID))
    }
}
