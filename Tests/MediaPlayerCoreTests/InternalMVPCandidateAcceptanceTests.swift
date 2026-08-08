import Foundation
import Testing
@testable import MediaPlayerCore

@Suite("离线内部 MVP 候选数据状态验收")
struct InternalMVPCandidateAcceptanceTests {
    @Test("全新用户数据从 SQLite 恢复为空且保持安全默认值")
    func freshUserDataStartsEmpty() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "fresh-candidate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLitePlaylistStore(databaseURL: databaseURL)
        let library = try await store.loadLibrary()

        #expect(library.playlists.isEmpty)
        #expect(library.activePlaylistID == nil)
        #expect(library.playerVolume == 1)
        #expect(!library.isMuted)
    }

    @Test("已填充状态跨 SQLite 重启保留多个 Playlist、重复项、续播、轨道偏好和文件缺失")
    func populatedUserDataSurvivesRestart() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "populated-candidate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let sharedMedia = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x01, 0x02]),
            lastKnownPath: "/Users/example/Movies/feature.mkv"
        )
        let missingMedia = PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([0x03, 0x04]),
            lastKnownPath: "/Users/example/Music/missing.flac",
            availability: .missing
        )
        let preferredEntry = PlaylistEntry(
            media: sharedMedia,
            resumePosition: 84,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: TrackPreference(languageCode: "ja", title: "日本語", ordinal: 2),
                subtitle: .embedded(
                    TrackPreference(languageCode: "zh-Hans", title: "简体中文", ordinal: 3)
                )
            )
        )
        let duplicateEntry = PlaylistEntry(media: sharedMedia, resumePosition: 12)
        let missingEntry = PlaylistEntry(media: missingMedia)
        let movies = Playlist(
            name: "周末电影",
            entries: [preferredEntry, duplicateEntry],
            currentEntryID: preferredEntry.id
        )
        let music = Playlist(
            name: "通勤音乐",
            entries: [missingEntry],
            currentEntryID: missingEntry.id
        )
        let expected = PlaylistLibrary(
            playlists: [movies, music],
            activePlaylistID: movies.id,
            playerVolume: 0.65,
            isMuted: false,
            seekStep: 15
        )

        let store = try SQLitePlaylistStore(databaseURL: databaseURL)
        try await store.commit(expected)
        let reopenedStore = try SQLitePlaylistStore(databaseURL: databaseURL)
        let restored = try await reopenedStore.loadLibrary()

        #expect(restored == expected)
        #expect(restored.playlists.count == 2)
        #expect(restored.playlists[0].entries.map(\.media.id) == [sharedMedia.id, sharedMedia.id])
        #expect(restored.playlists[0].entries[0].resumePosition == 84)
        #expect(restored.playlists[0].entries[0].playbackPreferences == preferredEntry.playbackPreferences)
        #expect(restored.playlists[1].entries[0].media.availability == .missing)
    }
}
