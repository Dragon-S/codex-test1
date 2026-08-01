import Foundation
import Testing
@testable import MediaPlayerCore

@MainActor
@Suite("轨道与字幕协调")
struct TrackSelectionCoordinatorTests {
    @Test("没有条目偏好时按首选语言选择音轨，并优先选择强制字幕")
    func appliesDeterministicDefaults() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            defaultTrackRules: DefaultTrackRules(
                preferredAudioLanguages: ["ja", "en"],
                preferredSubtitleLanguages: ["zh-Hans", "en"],
                subtitleAutoPolicy: .automatic
            )
        )
        await coordinator.open(localMedia("movie.mkv"))
        let loadID = try #require(await engine.loadIDs.last)
        let japanese = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "ja",
            title: "日本語",
            ordinal: 1,
            isDefault: false
        )
        let english = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "en",
            title: "English",
            ordinal: 2,
            isDefault: true
        )
        let forcedChinese = EmbeddedSubtitleTrackOption(
            id: EmbeddedSubtitleTrackID(),
            languageCode: "zh-Hans",
            title: "强制字幕",
            ordinal: 1,
            isDefault: false,
            isForced: true
        )

        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [english, japanese], embeddedSubtitleTracks: [forcedChinese]),
            loadID: loadID
        ))
        try await waitUntil { await engine.selectionCommands.count == 2 }

        #expect(await engine.selectionCommands == [
            .audio(japanese.id),
            .subtitle(.embedded(forcedChinese.id)),
        ])
        #expect(coordinator.trackSelection.audioTrackID == japanese.id)
        #expect(coordinator.trackSelection.subtitle == .embedded(forcedChinese.id))
    }

    @Test("区域首选语言可匹配 libmpv 的 ISO 三字母轨道语言")
    func matchesRegionalPreferencesToISOThreeLetterTrackLanguages() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            defaultTrackRules: DefaultTrackRules(
                preferredAudioLanguages: ["ja-JP", "en-US"],
                preferredSubtitleLanguages: ["zh-Hans"],
                subtitleAutoPolicy: .always
            )
        )
        await coordinator.open(localMedia("language-codes.mkv"))
        let loadID = try #require(await engine.loadIDs.last)
        let english = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "eng",
            title: "English",
            ordinal: 1,
            isDefault: true
        )
        let japanese = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "jpn",
            title: "日本語",
            ordinal: 2,
            isDefault: false
        )
        let simplifiedChinese = EmbeddedSubtitleTrackOption(
            id: EmbeddedSubtitleTrackID(),
            languageCode: "zho",
            title: "简体中文",
            ordinal: 1,
            isDefault: false,
            isForced: false
        )

        engine.send(.trackCatalogChanged(
            TrackCatalog(
                audioTracks: [english, japanese],
                embeddedSubtitleTracks: [simplifiedChinese]
            ),
            loadID: loadID
        ))
        try await waitUntil { await engine.selectionCommands.count == 2 }

        #expect(await engine.selectionCommands == [
            .audio(japanese.id),
            .subtitle(.embedded(simplifiedChinese.id)),
        ])
    }

    @Test("用户成功选择音轨后按条目保存语义偏好")
    func persistsSuccessfulAudioSelectionPerEntry() async throws {
        let engine = TrackFakePlaybackEngine()
        let store = InMemoryPlaylistStore()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        let media = LocalMedia(
            url: URL(fileURLWithPath: "/tmp/concert.mkv"),
            bookmark: Data([0x01])
        )
        await coordinator.open(media)
        let commentary = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "en",
            title: "Commentary",
            ordinal: 3,
            isDefault: false
        )
        let loadID = try #require(await engine.loadIDs.last)
        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [commentary], embeddedSubtitleTracks: []),
            loadID: loadID
        ))
        try await waitUntil { coordinator.availableAudioTracks == [commentary] }

        await coordinator.selectAudioTrack(commentary.id)

        let preference = try #require(coordinator.nowPlayingList.entries.first?.playbackPreferences.audioTrack)
        #expect(preference == commentary.preference)
        #expect(coordinator.trackSelection.audioTrackID == commentary.id)

        let saved = try await coordinator.saveNowPlayingList(as: "演唱会")
        #expect(saved.entries[0].playbackPreferences.audioTrack == commentary.preference)
    }

    @Test("失效条目偏好会提示回退并继续播放")
    func fallsBackWhenSavedPreferenceIsUnavailable() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            defaultTrackRules: DefaultTrackRules(
                preferredAudioLanguages: ["en"],
                preferredSubtitleLanguages: [],
                subtitleAutoPolicy: .never
            )
        )
        let missingPreference = TrackPreference(
            languageCode: "fr",
            title: "Français",
            ordinal: 2
        )
        await coordinator.open([
            NowPlayingEntry(
                media: localMedia("fallback.mkv"),
                playbackPreferences: EntryPlaybackPreferences(audioTrack: missingPreference)
            ),
        ])
        let available = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "en",
            title: "English",
            ordinal: 1,
            isDefault: true
        )
        let loadID = try #require(await engine.loadIDs.last)

        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [available], embeddedSubtitleTracks: []),
            loadID: loadID
        ))
        try await waitUntil { coordinator.trackNotice != .none }

        #expect(coordinator.state == .idle)
        #expect(coordinator.trackNotice == .preferenceUnavailable("原音轨不可用，已改用 English"))
        #expect(await engine.selectionCommands.contains(.audio(available.id)))
    }

    @Test("引擎拒绝已保存音轨时提示并改用默认音轨")
    func fallsBackWhenEngineRejectsSavedAudioTrack() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            defaultTrackRules: DefaultTrackRules(
                preferredAudioLanguages: ["en"],
                preferredSubtitleLanguages: [],
                subtitleAutoPolicy: .never
            )
        )
        let saved = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "fr",
            title: "Français",
            ordinal: 2,
            isDefault: false
        )
        let fallback = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "en",
            title: "English",
            ordinal: 1,
            isDefault: true
        )
        await coordinator.open([
            NowPlayingEntry(
                media: localMedia("rejected-preference.mkv"),
                playbackPreferences: EntryPlaybackPreferences(audioTrack: saved.preference)
            ),
        ])
        await engine.rejectAudioTrack(saved.id)
        let loadID = try #require(await engine.loadIDs.last)

        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [fallback, saved], embeddedSubtitleTracks: []),
            loadID: loadID
        ))
        try await waitUntil { coordinator.trackNotice != .none }

        #expect(await engine.selectionCommands.prefix(2) == [
            .audio(saved.id),
            .audio(fallback.id),
        ])
        #expect(coordinator.trackSelection.audioTrackID == fallback.id)
        #expect(coordinator.trackNotice == .preferenceUnavailable("原音轨不可用，已改用 English"))
    }

    @Test("外部字幕损坏时媒体继续播放并允许停用")
    func damagedExternalSubtitleDoesNotBlockPlayback() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await coordinator.open(localMedia("with-subtitle.mkv"))
        let loadID = try #require(await engine.loadIDs.last)
        engine.send(.playbackStateChanged(.playing, loadID: loadID))
        try await waitUntil { coordinator.state == .playing }
        await engine.setExternalSubtitleResult(.damaged)
        let subtitle = LocalExternalSubtitle(
            url: URL(fileURLWithPath: "/tmp/broken.ass"),
            bookmark: Data([0x02])
        )

        await coordinator.selectExternalSubtitle(subtitle)

        #expect(coordinator.state == .playing)
        #expect(coordinator.trackNotice == .externalSubtitleDamaged("broken.ass"))
        #expect(coordinator.nowPlayingList.entries[0].playbackPreferences.subtitle == .automatic)

        await coordinator.disableSubtitles()
        #expect(await engine.selectionCommands.last == .subtitle(.off))
    }

    @Test("命名 Playlist 的成功选择会立即持久化并在重启后恢复")
    func persistsNamedPlaylistSelectionAndRestoresIt() async throws {
        let store = InMemoryPlaylistStore()
        let entry = PlaylistEntry(
            media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([0x03]),
                lastKnownPath: "/tmp/named.mkv"
            )
        )
        let playlist = Playlist(name: "命名列表", entries: [entry], currentEntryID: entry.id)
        try await store.create(playlist)
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        await coordinator.play()
        let commentary = AudioTrackOption(
            id: AudioTrackID(),
            languageCode: "en",
            title: "Commentary",
            ordinal: 2,
            isDefault: false
        )
        let loadID = try #require(await engine.loadIDs.last)
        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [commentary], embeddedSubtitleTracks: []),
            loadID: loadID
        ))
        try await waitUntil { coordinator.availableAudioTracks == [commentary] }

        await coordinator.selectAudioTrack(commentary.id)

        let restored = await store.loadLibrary()
        #expect(restored.playlists[0].entries[0].playbackPreferences.audioTrack == commentary.preference)
    }

    @Test("成功选择外部字幕会保存独立引用而不是媒体引用")
    func persistsIndependentExternalSubtitleReference() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        await coordinator.open(LocalMedia(
            url: URL(fileURLWithPath: "/tmp/movie.mkv"),
            referenceID: LocalMediaReferenceID(),
            bookmark: Data([0x04])
        ))
        await engine.setExternalSubtitleResult(.loaded)
        let subtitle = LocalExternalSubtitle(
            url: URL(fileURLWithPath: "/tmp/movie.zh-Hans.ass"),
            bookmark: Data([0x05])
        )

        await coordinator.selectExternalSubtitle(subtitle)

        let preference = coordinator.nowPlayingList.entries[0].playbackPreferences.subtitle
        guard case let .external(reference) = preference else {
            Issue.record("预期保存外部字幕引用")
            return
        }
        #expect(reference.lastKnownPath == subtitle.url.path)
        #expect(coordinator.nowPlayingList.entries[0].media.referenceID != LocalMediaReferenceID(
            rawValue: reference.id.rawValue
        ))
    }

    @Test("从不自动显示字幕会覆盖强制字幕标记")
    func neverPolicyKeepsSubtitlesOff() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            defaultTrackRules: DefaultTrackRules(subtitleAutoPolicy: .never)
        )
        await coordinator.open(localMedia("forced.mkv"))
        let forced = EmbeddedSubtitleTrackOption(
            id: EmbeddedSubtitleTrackID(),
            languageCode: "en",
            title: "Forced",
            ordinal: 1,
            isDefault: true,
            isForced: true
        )
        let loadID = try #require(await engine.loadIDs.last)

        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [], embeddedSubtitleTracks: [forced]),
            loadID: loadID
        ))
        try await waitUntil { await engine.selectionCommands.contains(.subtitle(.off)) }

        #expect(coordinator.trackSelection.subtitle == .off)
    }

    @Test("用户显式关闭字幕后再次播放仍保持关闭")
    func explicitSubtitleOffSurvivesReplay() async throws {
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            defaultTrackRules: DefaultTrackRules(
                preferredSubtitleLanguages: ["zh-Hans"],
                subtitleAutoPolicy: .automatic
            )
        )
        await coordinator.open([
            NowPlayingEntry(
                media: localMedia("explicit-off.mkv"),
                playbackPreferences: EntryPlaybackPreferences(subtitle: .off)
            ),
        ])
        let forcedChinese = EmbeddedSubtitleTrackOption(
            id: EmbeddedSubtitleTrackID(),
            languageCode: "zh-Hans",
            title: "强制字幕",
            ordinal: 1,
            isDefault: true,
            isForced: true
        )
        let loadID = try #require(await engine.loadIDs.last)

        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [], embeddedSubtitleTracks: [forcedChinese]),
            loadID: loadID
        ))
        try await waitUntil { await engine.selectionCommands.contains(.subtitle(.off)) }

        #expect(!engineSelectionContains(
            await engine.selectionCommands,
            .subtitle(.embedded(forcedChinese.id))
        ))
        #expect(coordinator.trackSelection.subtitle == .off)
    }

    @Test("已保存外部字幕缺失时保持媒体状态并提示重新定位")
    func missingSavedExternalSubtitleFallsBackWithoutBlockingMedia() async throws {
        let store = InMemoryPlaylistStore()
        let reference = PersistentExternalSubtitleReference(
            id: ExternalSubtitleReferenceID(),
            bookmark: Data([0x06]),
            lastKnownPath: "/tmp/missing.zh-Hans.srt"
        )
        let entry = PlaylistEntry(
            media: PersistentLocalMediaReference(
                id: LocalMediaReferenceID(),
                bookmark: Data([0x07]),
                lastKnownPath: "/tmp/movie-with-missing-subtitle.mkv"
            ),
            playbackPreferences: EntryPlaybackPreferences(subtitle: .external(reference))
        )
        try await store.create(Playlist(name: "缺失字幕", entries: [entry], currentEntryID: entry.id))
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        await coordinator.play()
        let loadID = try #require(await engine.loadIDs.last)

        engine.send(.trackCatalogChanged(
            TrackCatalog(audioTracks: [], embeddedSubtitleTracks: []),
            loadID: loadID
        ))
        try await waitUntil { coordinator.trackNotice != .none }

        #expect(coordinator.state == .paused)
        #expect(coordinator.trackNotice == .externalSubtitleMissing("missing.zh-Hans.srt"))
        #expect(coordinator.currentExternalSubtitleReferenceID == reference.id)
        #expect(coordinator.preferredExternalSubtitleName == "missing.zh-Hans.srt")
        #expect(!coordinator.isPreferredExternalSubtitleActive)
        #expect(await engine.selectionCommands.contains(.subtitle(.off)))
    }

    @Test("重新定位共享外部字幕会更新所有引用者并显示当前文件名")
    func relocatesSharedExternalSubtitleForEveryEntry() async throws {
        let store = InMemoryPlaylistStore()
        let reference = PersistentExternalSubtitleReference(
            id: ExternalSubtitleReferenceID(),
            bookmark: Data([0x08]),
            lastKnownPath: "/tmp/old-shared.ass"
        )
        let preferences = EntryPlaybackPreferences(subtitle: .external(reference))
        let entries = [
            PlaylistEntry(
                media: persistentMedia("first.mkv", bookmark: 0x09),
                playbackPreferences: preferences
            ),
            PlaylistEntry(
                media: persistentMedia("second.mkv", bookmark: 0x0A),
                playbackPreferences: preferences
            ),
        ]
        try await store.create(Playlist(
            name: "共享字幕",
            entries: entries,
            currentEntryID: entries[0].id
        ))
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        let relocated = LocalExternalSubtitle(
            url: URL(fileURLWithPath: "/tmp/new-shared.ass"),
            bookmark: Data([0x0B])
        )

        await coordinator.relocateExternalSubtitle(relocated)

        let library = await store.loadLibrary()
        let references = library.playlists[0].entries.compactMap { entry -> PersistentExternalSubtitleReference? in
            guard case let .external(reference) = entry.playbackPreferences.subtitle else { return nil }
            return reference
        }
        #expect(references.count == 2)
        #expect(references.allSatisfy { $0.lastKnownPath == relocated.url.path })
        #expect(references.allSatisfy { $0.bookmark == Data([0x0B]) })
        #expect(coordinator.preferredExternalSubtitleName == "new-shared.ass")
        #expect(coordinator.isPreferredExternalSubtitleActive)
        #expect(coordinator.trackSelection.subtitle == .external(reference.id))
    }

    @Test("选择新外部字幕只改变当前条目的独立偏好")
    func selectingNewExternalSubtitleDoesNotRelocateSharedReference() async throws {
        let store = InMemoryPlaylistStore()
        let sharedReference = PersistentExternalSubtitleReference(
            id: ExternalSubtitleReferenceID(),
            bookmark: Data([0x0C]),
            lastKnownPath: "/tmp/shared-old.srt"
        )
        let entries = [
            PlaylistEntry(
                media: persistentMedia("first-new-subtitle.mkv", bookmark: 0x0D),
                playbackPreferences: EntryPlaybackPreferences(
                    subtitle: .external(sharedReference)
                )
            ),
            PlaylistEntry(
                media: persistentMedia("second-keeps-subtitle.mkv", bookmark: 0x0E),
                playbackPreferences: EntryPlaybackPreferences(
                    subtitle: .external(sharedReference)
                )
            ),
        ]
        try await store.create(Playlist(
            name: "独立字幕选择",
            entries: entries,
            currentEntryID: entries[0].id
        ))
        let engine = TrackFakePlaybackEngine()
        let coordinator = PlaybackCoordinator(engine: engine, playlistStore: store)
        try await coordinator.restorePersistentState()
        let newlySelected = LocalExternalSubtitle(
            url: URL(fileURLWithPath: "/tmp/new-for-first.ass"),
            bookmark: Data([0x0F])
        )

        await coordinator.selectExternalSubtitle(newlySelected)

        let library = await store.loadLibrary()
        guard case let .external(firstReference) = library.playlists[0].entries[0]
            .playbackPreferences.subtitle,
              case let .external(secondReference) = library.playlists[0].entries[1]
            .playbackPreferences.subtitle else {
            Issue.record("两个条目都应保留外部字幕偏好")
            return
        }
        #expect(firstReference.id != sharedReference.id)
        #expect(firstReference.lastKnownPath == newlySelected.url.path)
        #expect(secondReference == sharedReference)
    }

    private func localMedia(_ name: String) -> LocalMedia {
        LocalMedia(url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func persistentMedia(_ name: String, bookmark: UInt8) -> PersistentLocalMediaReference {
        PersistentLocalMediaReference(
            id: LocalMediaReferenceID(),
            bookmark: Data([bookmark]),
            lastKnownPath: "/tmp/\(name)"
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("等待协调层状态超时")
    }

    private func engineSelectionContains(
        _ commands: [TrackEngineCommand],
        _ expected: TrackEngineCommand
    ) -> Bool {
        commands.contains(expected)
    }
}

private enum TrackEngineCommand: Equatable, Sendable {
    case audio(AudioTrackID)
    case subtitle(SubtitleSelection)
}

private actor TrackFakePlaybackEngine: PlaybackEngine {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private(set) var loadIDs: [PlaybackLoadID] = []
    private(set) var selectionCommands: [TrackEngineCommand] = []
    private var externalSubtitleResult: ExternalSubtitleLoadResult = .loaded
    private var rejectedAudioTrackIDs: Set<AudioTrackID> = []

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) { loadIDs.append(loadID) }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) {}
    func setMuted(_ isMuted: Bool) {}

    func selectAudioTrack(_ id: AudioTrackID) -> Bool {
        selectionCommands.append(.audio(id))
        return !rejectedAudioTrackIDs.contains(id)
    }

    func selectSubtitle(_ selection: SubtitleSelection) -> Bool {
        selectionCommands.append(.subtitle(selection))
        return true
    }

    func loadExternalSubtitle(_ subtitle: LocalExternalSubtitle) -> ExternalSubtitleLoadResult {
        externalSubtitleResult
    }

    func setExternalSubtitleResult(_ result: ExternalSubtitleLoadResult) {
        externalSubtitleResult = result
    }

    func rejectAudioTrack(_ id: AudioTrackID) {
        rejectedAudioTrackIDs.insert(id)
    }

    nonisolated func send(_ event: PlaybackEngineEvent) {
        continuation.yield(event)
    }
}
