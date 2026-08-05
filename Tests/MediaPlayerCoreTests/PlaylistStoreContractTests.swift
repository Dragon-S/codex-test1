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
            lastKnownPath: "/tmp/moved-movie.mkv",
            availability: .missing
        )
        try await store.updateMediaReferences([refreshedReference, refreshedReference])
        let refreshed = try await store.loadLibrary()
        #expect(refreshed.playlists[0].entries.map(\.media) == [
            refreshedReference, refreshedReference,
        ])
        #expect(refreshed.playlists[0].entries.map(\.resumePosition) == [42.5, 73])
        #expect(refreshed.playlists[0].entries.map(\.isCompleted) == [true, false])
        #expect(refreshed.playlists[0].entries.allSatisfy {
            $0.media.availability == .missing
        })
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

    @Test("存储包含文件缺失条目的当前列表会保留缺失状态")
    func savingCurrentListPreservesMissingMediaAvailability() async throws {
        let available = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x4A]),
            lastKnownPath: "/tmp/available.mp4"
        ))
        let missing = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x4B]),
            lastKnownPath: "/tmp/missing.mp4",
            availability: .missing
        ))
        let source = Playlist(
            name: "含缺失条目",
            entries: [available, missing],
            currentEntryID: available.id
        )
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [source],
            activePlaylistID: source.id
        ))
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store
        )
        try await coordinator.restorePersistentState()

        let saved = try await coordinator.saveNowPlayingList(as: "含缺失条目副本")

        #expect(saved.entries[1].media.availability == .missing)
        let persisted = await store.loadLibrary()
        #expect(persisted.playlists.last?.entries[1].media.availability == .missing)
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

    @Test("启动恢复无法定位文件时保留共享引用、条目状态并标记缺失")
    func preservesEntriesAndStateWhenSharedMediaIsMissingDuringRestore() async throws {
        let store = InMemoryPlaylistStore()
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x61]),
            lastKnownPath: "/tmp/moved-shared.mkv",
            fileIdentity: LocalFileIdentity(rawValue: Data([0xF1]))
        )
        let first = PlaylistEntry(
            media: reference,
            resumePosition: 42,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: TrackPreference(languageCode: "ja", title: "日本語", ordinal: 2)
            )
        )
        let second = PlaylistEntry(
            media: reference,
            resumePosition: 7,
            isCompleted: true,
            playbackPreferences: EntryPlaybackPreferences(subtitle: .off)
        )
        let playlist = Playlist(
            name: "共享缺失",
            entries: [first, second],
            currentEntryID: first.id
        )
        try await store.create(playlist)
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store,
            persistentMediaAccess: MissingMediaAccess()
        )

        try await coordinator.restorePersistentState()

        #expect(coordinator.playlists[0].entries.map(\.id) == [first.id, second.id])
        #expect(coordinator.playlists[0].entries.map(\.resumePosition) == [42, 7])
        #expect(coordinator.playlists[0].entries.map(\.isCompleted) == [false, true])
        #expect(coordinator.playlists[0].entries.map(\.playbackPreferences) == [
            first.playbackPreferences, second.playbackPreferences,
        ])
        #expect(coordinator.playlists[0].entries.allSatisfy { $0.media.availability == .missing })
        #expect(coordinator.nowPlayingList.entries.allSatisfy { $0.isMediaMissing })
        #expect(coordinator.missingMediaCount == 2)
        let persisted = await store.loadLibrary()
        #expect(persisted.playlists[0].entries.allSatisfy { $0.media.availability == .missing })
    }

    @Test("自动推进跳过缺失条目并加载下一项可播放媒体")
    func automaticProgressionSkipsMissingEntries() async throws {
        let first = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x71]),
            lastKnownPath: "/tmp/first.mp4"
        ))
        let missing = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x72]),
            lastKnownPath: "/tmp/missing.mp4",
            availability: .missing
        ))
        let third = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x73]),
            lastKnownPath: "/tmp/third.mp4"
        ))
        let playlist = Playlist(
            name: "跳过缺失",
            entries: [first, missing, third],
            currentEntryID: first.id
        )
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [playlist],
            activePlaylistID: playlist.id
        ))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        await coordinator.play()

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 2 }

        #expect(await engine.loadedMediaNames == ["first.mp4", "third.mp4"])
        #expect(coordinator.missingMediaNotice == .none)
    }

    @Test("自动推进没有可播放条目时停止并显示缺失数量且不循环")
    func automaticProgressionStopsAfterFiniteMissingScan() async throws {
        let first = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x74]),
            lastKnownPath: "/tmp/only-playable.mp4"
        ))
        let missingEntries = [UInt8(0x75), UInt8(0x76)].map { bookmark in
            PlaylistEntry(media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([bookmark]),
                lastKnownPath: "/tmp/missing-\(bookmark).mp4",
                availability: .missing
            ))
        }
        let playlist = Playlist(
            name: "有限跳过",
            entries: [first] + missingEntries,
            currentEntryID: first.id
        )
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [playlist],
            activePlaylistID: playlist.id
        ))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        await coordinator.play()

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.state == .stopped }

        #expect(coordinator.missingMediaNotice == .noPlayableEntries(missingCount: 2))
        #expect(coordinator.nowPlayingList.currentIndex == 0)
        #expect(await engine.loadedMediaNames == ["only-playable.mp4"])
    }

    @Test("顺序自动加载期间才失去访问权限会标记缺失并继续推进")
    func sequentialProgressionMarksNewlyUnreadableMediaMissingAndContinues() async throws {
        let first = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x77]),
            lastKnownPath: "/tmp/before-missing.mp4"
        ))
        let newlyMissing = PlaylistEntry(
            media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([0x78]),
                lastKnownPath: "/tmp/newly-missing.mp4"
            ),
            resumePosition: 48,
            playbackPreferences: EntryPlaybackPreferences(subtitle: .off)
        )
        let third = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x79]),
            lastKnownPath: "/tmp/after-missing.mp4"
        ))
        let playlist = Playlist(
            name: "播放期间缺失",
            entries: [first, newlyMissing, third],
            currentEntryID: first.id
        )
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [playlist],
            activePlaylistID: playlist.id
        ))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        await coordinator.play()
        await engine.sendPlaybackEnded()
        try await waitUntilAsync { await engine.loadedMediaNames.count == 2 }

        await engine.sendState(.failed(.unreadable))
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 2 }

        #expect(await engine.loadedMediaNames == [
            "before-missing.mp4", "newly-missing.mp4", "after-missing.mp4",
        ])
        let persisted = await store.loadLibrary()
        let missingEntry = persisted.playlists[0].entries[1]
        #expect(missingEntry.media.availability == .missing)
        #expect(missingEntry.resumePosition == 48)
        #expect(missingEntry.playbackPreferences == newlyMissing.playbackPreferences)
    }

    @Test("列表循环的末项自动加载失败后跳过缺失并有限回绕")
    func repeatPlaylistWrapsAfterLastEntryBecomesUnreadable() async throws {
        let first = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x7A]),
            lastKnownPath: "/tmp/repeat-first.mp4"
        ))
        let last = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x7B]),
            lastKnownPath: "/tmp/repeat-last.mp4"
        ))
        let playlist = Playlist(
            name: "循环期间缺失",
            entries: [first, last],
            currentEntryID: first.id,
            repeatMode: .playlist
        )
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [playlist],
            activePlaylistID: playlist.id
        ))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        await coordinator.play()
        await engine.sendPlaybackEnded()
        try await waitUntilAsync { await engine.loadedMediaNames.count == 2 }

        await engine.sendState(.failed(.unreadable))
        try await waitUntilAsync { await engine.loadedMediaNames.count == 3 }

        #expect(await engine.loadedMediaNames == [
            "repeat-first.mp4", "repeat-last.mp4", "repeat-first.mp4",
        ])
        #expect(coordinator.nowPlayingList.currentIndex == 0)
        #expect(coordinator.missingMediaCount == 1)
    }

    @Test("手动选择缺失条目提供恢复流程且取消不改变数据")
    func manualSelectionOffersRecoveryAndCancellationIsNonMutating() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x81]),
            lastKnownPath: "/tmp/manual-missing.mkv",
            availability: .missing
        )
        let entry = PlaylistEntry(media: reference, resumePosition: 28)
        let playlist = Playlist(name: "手动恢复", entries: [entry])
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(playlists: [playlist]))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        let before = await store.loadLibrary()

        try await coordinator.playEntry(entry.id, in: playlist.id)

        #expect(coordinator.missingMediaNotice == .recoveryRequired(
            entryID: entry.id,
            referenceID: reference.id
        ))
        #expect(await engine.commands.isEmpty)

        coordinator.cancelMissingMediaRecovery()

        #expect(coordinator.missingMediaNotice == .none)
        #expect(await store.loadLibrary() == before)
        #expect(coordinator.playlists == before.playlists)
    }

    @Test("缺失条目恢复流程可移除应用内条目但不改变其他共享条目")
    func missingRecoveryCanRemoveOneEntryOnly() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x85]),
            lastKnownPath: "/tmp/shared-for-removal.mkv",
            availability: .missing
        )
        let first = PlaylistEntry(media: reference, resumePosition: 5)
        let second = PlaylistEntry(media: reference, resumePosition: 25)
        let playlist = Playlist(name: "移除缺失", entries: [first, second])
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(playlists: [playlist]))
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store
        )
        try await coordinator.restorePersistentState()
        try await coordinator.playEntry(first.id, in: playlist.id)

        try await coordinator.removeEntry(first.id, from: playlist.id)

        let persisted = await store.loadLibrary()
        #expect(persisted.playlists[0].entries.map(\.id) == [second.id])
        #expect(persisted.playlists[0].entries[0].resumePosition == 25)
        #expect(persisted.playlists[0].entries[0].media == reference)
        #expect(coordinator.missingMediaNotice == .none)
    }

    @Test("播放时才发现文件无法定位会保留状态并标记共享引用缺失")
    func playbackDiscoveryOfMissingFilePreservesStateAndReference() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x82]),
            lastKnownPath: "/tmp/discovered-missing.mkv",
            fileIdentity: LocalFileIdentity(rawValue: Data([0x83]))
        )
        let entry = PlaylistEntry(
            media: reference,
            resumePosition: 36,
            isCompleted: true,
            playbackPreferences: EntryPlaybackPreferences(subtitle: .off)
        )
        let playlist = Playlist(name: "稍后发现", entries: [entry])
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(playlists: [playlist]))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            persistentMediaAccess: MissingMediaAccess()
        )
        try await coordinator.restorePersistentState()

        try await coordinator.playEntry(entry.id, in: playlist.id)

        #expect(await engine.commands.isEmpty)
        #expect(coordinator.missingMediaNotice == .recoveryRequired(
            entryID: entry.id,
            referenceID: reference.id
        ))
        let persisted = try #require((await store.loadLibrary()).playlists[0].entries.first)
        #expect(persisted.media.id == reference.id)
        #expect(persisted.media.availability == .missing)
        #expect(persisted.resumePosition == 36)
        #expect(persisted.isCompleted)
        #expect(persisted.playbackPreferences == entry.playbackPreferences)
    }

    @Test("启动恢复的当前文件已缺失时播放会进入恢复流程而不加载引擎")
    func playingRestoredMissingEntryOffersRecoveryWithoutLoadingEngine() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x84]),
            lastKnownPath: "/tmp/restored-missing.mkv",
            availability: .missing
        )
        let entry = PlaylistEntry(media: reference, resumePosition: 19)
        let playlist = Playlist(name: "启动缺失", entries: [entry], currentEntryID: entry.id)
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [playlist],
            activePlaylistID: playlist.id
        ))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()

        await coordinator.play()

        #expect(await engine.commands.isEmpty)
        #expect(coordinator.missingMediaNotice == .recoveryRequired(
            entryID: entry.id,
            referenceID: reference.id
        ))
        #expect(coordinator.state == .paused)
    }

    @Test("重定位到原文件会恢复共享引用的全部条目并保持各自状态")
    func relocatingOriginalFileRestoresSharedEntriesWithoutResettingState() async throws {
        let identity = LocalFileIdentity(rawValue: Data([0x91]))
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x92]),
            lastKnownPath: "/tmp/old-shared.mkv",
            fileIdentity: identity,
            availability: .missing
        )
        let first = PlaylistEntry(
            media: reference,
            resumePosition: 63,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: TrackPreference(languageCode: "en", title: "Commentary", ordinal: 3)
            )
        )
        let second = PlaylistEntry(
            media: reference,
            resumePosition: 11,
            isCompleted: true,
            playbackPreferences: EntryPlaybackPreferences(subtitle: .off)
        )
        let firstPlaylist = Playlist(name: "电影", entries: [first], currentEntryID: first.id)
        let secondPlaylist = Playlist(name: "收藏", entries: [second])
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [firstPlaylist, secondPlaylist],
            activePlaylistID: firstPlaylist.id
        ))
        let coordinator = PlaybackCoordinator(engine: PlaylistFakePlaybackEngine(), playlistStore: store)
        try await coordinator.restorePersistentState()
        let relocated = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/new-shared.mp4"),
            referenceID: LocalMediaReferenceID(),
            bookmark: Data([0x93]),
            fileIdentity: identity
        )

        let result = try await coordinator.relocateMissingMedia(
            referenceID: reference.id,
            to: relocated
        )

        #expect(result == .relocated)
        let persisted = await store.loadLibrary()
        let entries = persisted.playlists.flatMap(\.entries)
        #expect(entries.map(\.media.id) == [reference.id, reference.id])
        #expect(entries.allSatisfy { $0.media.lastKnownPath == "/tmp/new-shared.mp4" })
        #expect(entries.allSatisfy { $0.media.bookmark == Data([0x93]) })
        #expect(entries.allSatisfy { $0.media.availability == .available })
        #expect(entries.map(\.resumePosition) == [63, 11])
        #expect(entries.map(\.isCompleted) == [false, true])
        #expect(entries.map(\.playbackPreferences) == [
            first.playbackPreferences, second.playbackPreferences,
        ])
        #expect(coordinator.nowPlayingList.entries[0].media.url.path == "/tmp/new-shared.mp4")
        #expect(!coordinator.nowPlayingList.entries[0].isMediaMissing)
    }

    @Test("明显不同文件先报告共享影响范围且确认后重置关联状态")
    func replacingWithDifferentFileRequiresConfirmationAndResetsSharedState() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0xA1]),
            lastKnownPath: "/tmp/original.mkv",
            fileIdentity: LocalFileIdentity(rawValue: Data([0xA2])),
            availability: .missing
        )
        let first = PlaylistEntry(
            media: reference,
            resumePosition: 90,
            isCompleted: true,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: TrackPreference(languageCode: "fr", title: "Français", ordinal: 2),
                subtitle: .off
            )
        )
        let second = PlaylistEntry(
            media: reference,
            resumePosition: 14,
            playbackPreferences: EntryPlaybackPreferences(
                subtitle: .embedded(TrackPreference(
                    languageCode: "zh-Hans",
                    title: "简体中文",
                    ordinal: 1
                ))
            )
        )
        let firstPlaylist = Playlist(name: "第一处", entries: [first], currentEntryID: first.id)
        let secondPlaylist = Playlist(name: "第二处", entries: [second])
        let originalLibrary = PlaylistLibrary(
            playlists: [firstPlaylist, secondPlaylist],
            activePlaylistID: firstPlaylist.id
        )
        let store = InMemoryPlaylistStore(library: originalLibrary)
        let coordinator = PlaybackCoordinator(engine: PlaylistFakePlaybackEngine(), playlistStore: store)
        try await coordinator.restorePersistentState()
        let differentFile = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/replacement.mkv"),
            bookmark: Data([0xA3]),
            fileIdentity: LocalFileIdentity(rawValue: Data([0xA4]))
        )
        let impact = MediaReplacementImpact(
            referenceID: reference.id,
            affectedEntryCount: 2,
            affectedPlaylistCount: 2
        )

        let pending = try await coordinator.relocateMissingMedia(
            referenceID: reference.id,
            to: differentFile
        )

        #expect(pending == .confirmationRequired(impact))
        #expect(coordinator.missingMediaNotice == .replacementConfirmationRequired(impact))
        #expect(await store.loadLibrary() == originalLibrary)

        let confirmed = try await coordinator.relocateMissingMedia(
            referenceID: reference.id,
            to: differentFile,
            confirmedReplacement: true
        )

        #expect(confirmed == .relocated)
        let replacedEntries = (await store.loadLibrary()).playlists.flatMap(\.entries)
        #expect(replacedEntries.allSatisfy { $0.media.id == reference.id })
        #expect(replacedEntries.allSatisfy { $0.media.lastKnownPath == "/tmp/replacement.mkv" })
        #expect(replacedEntries.allSatisfy { $0.resumePosition == nil })
        #expect(replacedEntries.allSatisfy { !$0.isCompleted })
        #expect(replacedEntries.allSatisfy {
            $0.playbackPreferences == EntryPlaybackPreferences()
        })
        #expect(coordinator.missingMediaNotice == .none)
    }

    @Test("没有文件身份时文件名与容器格式明显不同仍要求确认替换影响")
    func replacementWithDifferentMediaTypeRequiresConfirmationWithoutFileIdentity() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0xA5]),
            lastKnownPath: "/tmp/legacy-video.mkv",
            availability: .missing
        )
        let entry = PlaylistEntry(media: reference, resumePosition: 51)
        let playlist = Playlist(name: "旧引用", entries: [entry])
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(playlists: [playlist]))
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store
        )
        try await coordinator.restorePersistentState()

        let result = try await coordinator.relocateMissingMedia(
            referenceID: reference.id,
            to: LocalMedia(
                url: URL(fileURLWithPath: "/tmp/different-video.mp4"),
                bookmark: Data([0xA6])
            )
        )

        #expect(result == .confirmationRequired(MediaReplacementImpact(
            referenceID: reference.id,
            affectedEntryCount: 1,
            affectedPlaylistCount: 1
        )))
        #expect(await store.loadLibrary() == PlaylistLibrary(playlists: [playlist]))
    }

    @Test("播放协调层通过媒体替换判断端口决定是否要求确认")
    func coordinatorUsesInjectedMediaReplacementAssessor() async throws {
        let reference = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0xA7]),
            lastKnownPath: "/tmp/original.mkv",
            availability: .missing
        )
        let entry = PlaylistEntry(media: reference)
        let playlist = Playlist(name: "注入判断", entries: [entry])
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(playlists: [playlist]))
        let coordinator = PlaybackCoordinator(
            engine: PlaylistFakePlaybackEngine(),
            playlistStore: store,
            mediaReplacementAssessor: AlwaysDifferentMediaReplacementAssessor()
        )
        try await coordinator.restorePersistentState()

        let result = try await coordinator.relocateMissingMedia(
            referenceID: reference.id,
            to: LocalMedia(
                url: URL(fileURLWithPath: "/tmp/candidate.mkv"),
                bookmark: Data([0xA8])
            )
        )

        #expect(result == .confirmationRequired(MediaReplacementImpact(
            referenceID: reference.id,
            affectedEntryCount: 1,
            affectedPlaylistCount: 1
        )))
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

    @Test("顺序循环自动推进会在一轮内有限跳过并汇总全部失败")
    func exhaustsSequentialFailuresWithoutLooping() async throws {
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let playlist = try await coordinator.createPlaylist(named: "顺序全失败")
        let first = try await coordinator.add(bookmarkedMedia("first.mp4", 0xC1), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("second.mp4", 0xC2), to: playlist.id)
        _ = try await coordinator.add(bookmarkedMedia("third.mp4", 0xC3), to: playlist.id)
        try await coordinator.setRepeatMode(.playlist, for: playlist.id)
        try await coordinator.playEntry(first.id, in: playlist.id)

        await coordinator.next()
        await engine.sendState(.loading)
        await engine.sendState(.failed(.unsupported))
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 2 }

        await engine.sendState(.loading)
        await engine.sendState(.failed(.corrupted))
        try await waitUntil { coordinator.nowPlayingList.currentIndex == 0 }

        await engine.sendState(.loading)
        await engine.sendState(.failed(.unreadable))
        try await waitUntil { coordinator.state == .stopped }

        guard case let .exhausted(failures) = coordinator.playbackFailureNotice else {
            Issue.record("整轮失败后应发布汇总")
            return
        }
        #expect(failures.map(\.failure) == [.unsupported, .corrupted, .unreadable])
        #expect(failures.map(\.mediaURL.lastPathComponent) == [
            "second.mp4", "third.mp4", "first.mp4",
        ])
        #expect(await engine.commands == [.load, .load, .load, .load])
    }

    @Test("随机自动推进同样跳过已知缺失条目且不会开启空轮次")
    func randomProgressionSkipsKnownMissingEntries() async throws {
        let current = PlaylistEntry(media: PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0xB4]),
            lastKnownPath: "/tmp/random-current.mp4"
        ))
        let missing = [UInt8(0xB5), UInt8(0xB6)].map { bookmark in
            PlaylistEntry(media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([bookmark]),
                lastKnownPath: "/tmp/random-missing-\(bookmark).mp4",
                availability: .missing
            ))
        }
        let playlist = Playlist(
            name: "随机缺失",
            entries: [current] + missing,
            currentEntryID: current.id,
            playbackOrder: .random
        )
        let store = InMemoryPlaylistStore(library: PlaylistLibrary(
            playlists: [playlist],
            activePlaylistID: playlist.id
        ))
        let engine = PlaylistFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: store,
            randomizer: ReversePlaylistRandomizer()
        )
        try await coordinator.restorePersistentState()
        await coordinator.play()

        await engine.sendPlaybackEnded()
        try await waitUntil { coordinator.state == .stopped }

        #expect(await engine.loadedMediaNames == ["random-current.mp4"])
        #expect(coordinator.missingMediaNotice == .noPlayableEntries(missingCount: 2))
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

private struct AlwaysDifferentMediaReplacementAssessor: MediaReplacementAssessing {
    func isObviousReplacement(
        existing: PersistentLocalMediaReference,
        candidate: LocalMedia
    ) -> Bool {
        true
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

private struct MissingMediaAccess: PersistentMediaAccess {
    func restore(_ reference: PersistentLocalMediaReference) throws -> LocalMedia {
        throw PersistentMediaAccessError.missing(reference.lastKnownPath)
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
    private(set) var loadedMediaNames: [String] = []
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private var loadIDs: [PlaybackLoadID] = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        commands.append(.load)
        loadedMediaNames.append(media.url.lastPathComponent)
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
