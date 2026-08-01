import Combine
import Foundation

public struct NowPlayingList: Equatable, Sendable {
    public let entries: [NowPlayingEntry]
    public let currentIndex: Int?

    public var currentMedia: LocalMedia? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex].media
    }

    public init(entries: [NowPlayingEntry] = [], currentIndex: Int? = nil) {
        self.entries = entries
        self.currentIndex = currentIndex
    }

    public init(entries: [LocalMedia], currentIndex: Int? = nil) {
        self.init(entries: entries.map { NowPlayingEntry(media: $0) }, currentIndex: currentIndex)
    }

    func moving(by offset: Int) -> NowPlayingList? {
        guard let currentIndex else { return nil }
        let destination = currentIndex + offset
        guard entries.indices.contains(destination) else { return nil }
        return NowPlayingList(entries: entries, currentIndex: destination)
    }
}

public enum SubtitleAutoPolicy: Equatable, Codable, Sendable {
    case automatic
    case always
    case never
}

public struct DefaultTrackRules: Equatable, Codable, Sendable {
    public let preferredAudioLanguages: [String]
    public let preferredSubtitleLanguages: [String]
    public let subtitleAutoPolicy: SubtitleAutoPolicy

    public init(
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        subtitleAutoPolicy: SubtitleAutoPolicy = .automatic
    ) {
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.subtitleAutoPolicy = subtitleAutoPolicy
    }
}

public enum ActiveSubtitleSelection: Equatable, Sendable {
    case off
    case embedded(EmbeddedSubtitleTrackID)
    case external(ExternalSubtitleReferenceID)
}

public struct TrackSelectionState: Equatable, Sendable {
    public let audioTrackID: AudioTrackID?
    public let subtitle: ActiveSubtitleSelection

    public init(audioTrackID: AudioTrackID? = nil, subtitle: ActiveSubtitleSelection = .off) {
        self.audioTrackID = audioTrackID
        self.subtitle = subtitle
    }
}

public enum TrackNotice: Equatable, Sendable {
    case none
    case preferenceUnavailable(String)
    case selectionFailed(String)
    case externalSubtitleMissing(String)
    case externalSubtitleDamaged(String)
}

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var nowPlayingList = NowPlayingList()
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var activePlaylistID: PlaylistID?
    @Published public private(set) var persistenceNotice: PlaylistPersistenceNotice = .none
    @Published public private(set) var availableAudioTracks: [AudioTrackOption] = []
    @Published public private(set) var availableEmbeddedSubtitleTracks: [EmbeddedSubtitleTrackOption] = []
    @Published public private(set) var trackSelection = TrackSelectionState()
    @Published public private(set) var trackNotice: TrackNotice = .none

    private let engine: any PlaybackEngine
    private let playlistStore: any PlaylistStore
    private let persistentMediaAccess: any PersistentMediaAccess
    private let externalSubtitleAccess: any PersistentExternalSubtitleAccess
    private let defaultTrackRules: DefaultTrackRules
    private var eventTask: Task<Void, Never>?
    private var isFindingFirstPlayableMedia = false
    private var isRestoredMediaPendingLoad = false
    private var activeLoadID: PlaybackLoadID?
    private var nextLoadID: UInt64 = 0

    public init(
        engine: any PlaybackEngine,
        playlistStore: any PlaylistStore = InMemoryPlaylistStore(),
        persistentMediaAccess: any PersistentMediaAccess = LastKnownPathMediaAccess(),
        externalSubtitleAccess: any PersistentExternalSubtitleAccess = LastKnownPathExternalSubtitleAccess(),
        defaultTrackRules: DefaultTrackRules = DefaultTrackRules()
    ) {
        self.engine = engine
        self.playlistStore = playlistStore
        self.persistentMediaAccess = persistentMediaAccess
        self.externalSubtitleAccess = externalSubtitleAccess
        self.defaultTrackRules = defaultTrackRules
        eventTask = Task { [weak self, events = engine.events] in
            for await event in events {
                guard let self else { return }
                await receive(event)
            }
        }
    }

    public func open(_ media: LocalMedia) async {
        await open([media])
    }

    public func open(_ mediaItems: [LocalMedia]) async {
        await open(mediaItems.map { NowPlayingEntry(media: $0) })
    }

    public func open(_ entries: [NowPlayingEntry]) async {
        guard let first = entries.first else { return }
        nowPlayingList = NowPlayingList(entries: entries, currentIndex: 0)
        activePlaylistID = nil
        persistenceNotice = .none
        isRestoredMediaPendingLoad = false
        isFindingFirstPlayableMedia = true
        await load(first.media)
    }

    @discardableResult
    public func saveNowPlayingList(as requestedName: String) async throws -> Playlist {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            persistenceNotice = .failed("Playlist 名称不能为空")
            throw PlaylistPersistenceError.emptyName
        }
        guard !nowPlayingList.entries.isEmpty else {
            persistenceNotice = .failed("没有可存储的正在播放列表")
            throw PlaylistPersistenceError.emptyNowPlayingList
        }

        let entries = try nowPlayingList.entries.map { entry in
            guard let bookmark = entry.media.bookmark else {
                persistenceNotice = .failed("无法持久保存 \(entry.media.url.lastPathComponent) 的只读访问权限")
                throw PlaylistPersistenceError.missingBookmark(entry.media.url.path)
            }
            return PlaylistEntry(
                id: entry.id,
                media: PersistentLocalMediaReference(
                    id: entry.media.referenceID,
                    bookmark: bookmark,
                    lastKnownPath: entry.media.url.path
                ),
                resumePosition: entry.resumePosition,
                playbackPreferences: entry.playbackPreferences
            )
        }
        let currentEntryID = nowPlayingList.currentIndex.flatMap { index in
            entries.indices.contains(index) ? entries[index].id : nil
        }
        let playlist = Playlist(name: name, entries: entries, currentEntryID: currentEntryID)

        do {
            try await playlistStore.create(playlist)
            playlists.append(playlist)
            activePlaylistID = playlist.id
            persistenceNotice = .saved(name)
            return playlist
        } catch let error as PlaylistStoreError {
            switch error {
            case let .nameAlreadyExists(conflictingName):
                persistenceNotice = .nameAlreadyExists(conflictingName)
            case let .unavailable(message):
                persistenceNotice = .failed(message)
            }
            throw error
        } catch {
            persistenceNotice = .failed(error.localizedDescription)
            throw error
        }
    }

    public func restorePersistentState() async throws {
        do {
            let library = try await playlistStore.loadLibrary()
            playlists = library.playlists
            activePlaylistID = library.activePlaylistID
            guard let activeID = library.activePlaylistID,
                  let activePlaylist = library.playlists.first(where: { $0.id == activeID }) else {
                return
            }
            var restoredEntries: [NowPlayingEntry] = []
            var refreshedReferences: [PersistentLocalMediaReference] = []
            for entry in activePlaylist.entries {
                let media = try await persistentMediaAccess.restore(entry.media)
                if let bookmark = media.bookmark, bookmark != entry.media.bookmark {
                    refreshedReferences.append(PersistentLocalMediaReference(
                        id: entry.media.id,
                        bookmark: bookmark,
                        lastKnownPath: media.url.path
                    ))
                }
                restoredEntries.append(NowPlayingEntry(
                    id: entry.id,
                    media: media,
                    resumePosition: entry.resumePosition,
                    playbackPreferences: entry.playbackPreferences
                ))
            }
            try await playlistStore.updateMediaReferences(refreshedReferences)
            let currentIndex = activePlaylist.currentEntryID.flatMap { currentID in
                restoredEntries.firstIndex(where: { $0.id == currentID })
            }
            nowPlayingList = NowPlayingList(entries: restoredEntries, currentIndex: currentIndex)
            if currentIndex != nil {
                state = .paused
                isRestoredMediaPendingLoad = true
            }
            persistenceNotice = .none
        } catch let error as PlaylistStoreError {
            if case let .unavailable(message) = error {
                persistenceNotice = .failed(message)
            }
            throw error
        } catch {
            persistenceNotice = .failed(error.localizedDescription)
            throw error
        }
    }

    public func play() async {
        if isRestoredMediaPendingLoad, let media = nowPlayingList.currentMedia {
            isRestoredMediaPendingLoad = false
            await load(media)
            return
        }
        await engine.play()
    }

    public func pause() async {
        await engine.pause()
    }

    public func stop() async {
        await engine.stop()
    }

    public func selectAudioTrack(_ id: AudioTrackID) async {
        guard let option = availableAudioTracks.first(where: { $0.id == id }) else { return }
        guard await engine.selectAudioTrack(id) else {
            trackNotice = .selectionFailed("无法切换到 \(option.displayName)")
            return
        }
        trackSelection = TrackSelectionState(
            audioTrackID: id,
            subtitle: trackSelection.subtitle
        )
        let saved = await updateCurrentPreferences { current in
            EntryPlaybackPreferences(audioTrack: option.preference, subtitle: current.subtitle)
        }
        if saved { trackNotice = .none }
    }

    public func selectEmbeddedSubtitle(_ id: EmbeddedSubtitleTrackID) async {
        guard let option = availableEmbeddedSubtitleTracks.first(where: { $0.id == id }) else {
            return
        }
        guard await engine.selectSubtitle(.embedded(id)) else {
            trackNotice = .selectionFailed("无法切换到 \(option.displayName)")
            return
        }
        trackSelection = TrackSelectionState(
            audioTrackID: trackSelection.audioTrackID,
            subtitle: .embedded(id)
        )
        let saved = await updateCurrentPreferences { current in
            EntryPlaybackPreferences(audioTrack: current.audioTrack, subtitle: .embedded(option.preference))
        }
        if saved { trackNotice = .none }
    }

    public func selectExternalSubtitle(_ subtitle: LocalExternalSubtitle) async {
        let existingReferenceID = currentExternalSubtitleReferenceID
        switch await engine.loadExternalSubtitle(subtitle) {
        case .loaded:
            guard let bookmark = subtitle.bookmark else {
                trackNotice = .selectionFailed("无法持久保存外部字幕的只读访问权限")
                return
            }
            let reference = PersistentExternalSubtitleReference(
                id: subtitle.referenceID,
                bookmark: bookmark,
                lastKnownPath: subtitle.url.path
            )
            trackSelection = TrackSelectionState(
                audioTrackID: trackSelection.audioTrackID,
                subtitle: .external(subtitle.referenceID)
            )
            let saved = if existingReferenceID == reference.id {
                await relocateExternalSubtitle(reference)
            } else {
                await updateCurrentPreferences { current in
                    EntryPlaybackPreferences(
                        audioTrack: current.audioTrack,
                        subtitle: .external(reference)
                    )
                }
            }
            if saved { trackNotice = .none }
        case .missing:
            trackNotice = .externalSubtitleMissing(subtitle.url.lastPathComponent)
        case .damaged:
            trackNotice = .externalSubtitleDamaged(subtitle.url.lastPathComponent)
        }
    }

    public var currentExternalSubtitleReferenceID: ExternalSubtitleReferenceID? {
        guard case let .external(reference) = currentPreferences.subtitle else { return nil }
        return reference.id
    }

    public var currentExternalSubtitleName: String? {
        guard case let .external(reference) = currentPreferences.subtitle else { return nil }
        return URL(fileURLWithPath: reference.lastKnownPath).lastPathComponent
    }

    public func disableSubtitles() async {
        guard await engine.selectSubtitle(.off) else {
            trackNotice = .selectionFailed("无法停用字幕")
            return
        }
        trackSelection = TrackSelectionState(
            audioTrackID: trackSelection.audioTrackID,
            subtitle: .off
        )
        let saved = await updateCurrentPreferences { current in
            EntryPlaybackPreferences(audioTrack: current.audioTrack, subtitle: .off)
        }
        if saved { trackNotice = .none }
    }

    public func next() async {
        isFindingFirstPlayableMedia = false
        await move(by: 1)
    }

    public func previous() async {
        isFindingFirstPlayableMedia = false
        await move(by: -1)
    }

    private func move(by offset: Int) async {
        guard let destination = nowPlayingList.moving(by: offset),
              let media = destination.currentMedia else {
            await engine.stop()
            return
        }
        nowPlayingList = destination
        await load(media)
    }

    private func load(_ media: LocalMedia) async {
        nextLoadID &+= 1
        let loadID = PlaybackLoadID(rawValue: nextLoadID)
        activeLoadID = loadID
        availableAudioTracks = []
        availableEmbeddedSubtitleTracks = []
        trackSelection = TrackSelectionState()
        trackNotice = .none
        await engine.load(media, loadID: loadID)
    }

    private func receive(_ event: PlaybackEngineEvent) async {
        switch event {
        case let .playbackStateChanged(state, loadID):
            guard loadID == activeLoadID else { return }
            self.state = state
            switch state {
            case .playing, .paused:
                isFindingFirstPlayableMedia = false
            case .failed where isFindingFirstPlayableMedia:
                if let currentIndex = nowPlayingList.currentIndex,
                   nowPlayingList.entries.indices.contains(currentIndex + 1) {
                    await move(by: 1)
                } else {
                    isFindingFirstPlayableMedia = false
                }
            default:
                break
            }
        case let .playbackEnded(loadID):
            guard loadID == activeLoadID else { return }
            isFindingFirstPlayableMedia = false
            guard let currentIndex = nowPlayingList.currentIndex else {
                state = .stopped
                return
            }
            if nowPlayingList.entries.indices.contains(currentIndex + 1) {
                await move(by: 1)
            } else {
                state = .stopped
            }
        case let .trackCatalogChanged(catalog, loadID):
            guard loadID == activeLoadID else { return }
            await applyTrackCatalog(catalog)
        }
    }

    private func applyTrackCatalog(_ catalog: TrackCatalog) async {
        availableAudioTracks = catalog.audioTracks
        availableEmbeddedSubtitleTracks = catalog.embeddedSubtitleTracks
        let preferences = currentPreferences

        let preferredAudio = preferences.audioTrack.flatMap { preference in
            catalog.audioTracks.first(where: { $0.preference == preference })
        }
        let selectedAudio = preferredAudio ?? defaultAudioTrack(in: catalog.audioTracks)
        if let selectedAudio, await engine.selectAudioTrack(selectedAudio.id) {
            trackSelection = TrackSelectionState(
                audioTrackID: selectedAudio.id,
                subtitle: trackSelection.subtitle
            )
            if preferences.audioTrack != nil, preferredAudio == nil {
                trackNotice = .preferenceUnavailable(
                    "原音轨不可用，已改用 \(selectedAudio.displayName)"
                )
            }
        }

        switch preferences.subtitle {
        case let .embedded(preference):
            if let preferred = catalog.embeddedSubtitleTracks.first(where: {
                $0.preference == preference
            }), await engine.selectSubtitle(.embedded(preferred.id)) {
                setSelectedSubtitle(.embedded(preferred.id))
            } else {
                await applyDefaultSubtitle(catalog, selectedAudio: selectedAudio)
                let fallbackName = selectedSubtitleName(in: catalog) ?? "关闭字幕"
                trackNotice = .preferenceUnavailable("原字幕不可用，已改用 \(fallbackName)")
            }
        case let .external(reference):
            do {
                let subtitle = try await externalSubtitleAccess.restore(reference)
                switch await engine.loadExternalSubtitle(subtitle) {
                case .loaded:
                    setSelectedSubtitle(.external(reference.id))
                case .missing:
                    await fallBackFromExternalSubtitle(
                        reference: reference,
                        catalog: catalog,
                        selectedAudio: selectedAudio,
                        damaged: false
                    )
                case .damaged:
                    await fallBackFromExternalSubtitle(
                        reference: reference,
                        catalog: catalog,
                        selectedAudio: selectedAudio,
                        damaged: true
                    )
                }
            } catch {
                await fallBackFromExternalSubtitle(
                    reference: reference,
                    catalog: catalog,
                    selectedAudio: selectedAudio,
                    damaged: false
                )
            }
        case .off:
            await applyDefaultSubtitle(catalog, selectedAudio: selectedAudio)
        }
    }

    private func fallBackFromExternalSubtitle(
        reference: PersistentExternalSubtitleReference,
        catalog: TrackCatalog,
        selectedAudio: AudioTrackOption?,
        damaged: Bool
    ) async {
        await applyDefaultSubtitle(catalog, selectedAudio: selectedAudio)
        let name = URL(fileURLWithPath: reference.lastKnownPath).lastPathComponent
        trackNotice = damaged
            ? .externalSubtitleDamaged(name)
            : .externalSubtitleMissing(name)
    }

    private func applyDefaultSubtitle(
        _ catalog: TrackCatalog,
        selectedAudio: AudioTrackOption?
    ) async {
        let selected: EmbeddedSubtitleTrackOption?
        switch defaultTrackRules.subtitleAutoPolicy {
        case .never:
            selected = nil
        case .always:
            if let forced = catalog.embeddedSubtitleTracks.first(where: { $0.isForced }) {
                selected = forced
            } else {
                selected = preferredSubtitle(in: catalog.embeddedSubtitleTracks)
                    ?? catalog.embeddedSubtitleTracks.first(where: { $0.isDefault })
                    ?? catalog.embeddedSubtitleTracks.first
            }
        case .automatic:
            if let forced = catalog.embeddedSubtitleTracks.first(where: { $0.isForced }) {
                selected = forced
            } else {
                let audioMatchesPreference = selectedAudio.map { audio in
                    language(audio.languageCode, matchesAny: defaultTrackRules.preferredAudioLanguages)
                } ?? false
                selected = audioMatchesPreference
                    ? nil
                    : preferredSubtitle(in: catalog.embeddedSubtitleTracks)
            }
        }

        let engineSelection = selected.map { SubtitleSelection.embedded($0.id) } ?? .off
        if await engine.selectSubtitle(engineSelection) {
            let activeSelection = selected.map { ActiveSubtitleSelection.embedded($0.id) } ?? .off
            setSelectedSubtitle(activeSelection)
        }
    }

    private func defaultAudioTrack(in tracks: [AudioTrackOption]) -> AudioTrackOption? {
        for languageCode in defaultTrackRules.preferredAudioLanguages {
            if let match = tracks.first(where: { language($0.languageCode, matches: languageCode) }) {
                return match
            }
        }
        return tracks.first(where: { $0.isDefault }) ?? tracks.first
    }

    private func preferredSubtitle(
        in tracks: [EmbeddedSubtitleTrackOption]
    ) -> EmbeddedSubtitleTrackOption? {
        for languageCode in defaultTrackRules.preferredSubtitleLanguages {
            if let match = tracks.first(where: { language($0.languageCode, matches: languageCode) }) {
                return match
            }
        }
        return nil
    }

    private func language(_ actual: String?, matches expected: String) -> Bool {
        guard let actual else { return false }
        return normalizedLanguage(actual) == normalizedLanguage(expected)
    }

    private func language(_ actual: String?, matchesAny expected: [String]) -> Bool {
        expected.contains { language(actual, matches: $0) }
    }

    private func normalizedLanguage(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private var currentPreferences: EntryPlaybackPreferences {
        guard let index = nowPlayingList.currentIndex,
              nowPlayingList.entries.indices.contains(index) else {
            return EntryPlaybackPreferences()
        }
        return nowPlayingList.entries[index].playbackPreferences
    }

    @discardableResult
    private func updateCurrentPreferences(
        _ update: (EntryPlaybackPreferences) -> EntryPlaybackPreferences
    ) async -> Bool {
        guard let index = nowPlayingList.currentIndex,
              nowPlayingList.entries.indices.contains(index) else { return false }
        var entries = nowPlayingList.entries
        let entry = entries[index]
        let updatedPreferences = update(entry.playbackPreferences)
        if let activePlaylistID {
            do {
                try await playlistStore.updateEntryPlaybackPreferences(
                    playlistID: activePlaylistID,
                    entryID: entry.id,
                    preferences: updatedPreferences
                )
            } catch {
                trackNotice = .selectionFailed(
                    "选择已应用，但条目偏好未能保存：\(error.localizedDescription)"
                )
                return false
            }
        }
        entries[index] = NowPlayingEntry(
            id: entry.id,
            media: entry.media,
            resumePosition: entry.resumePosition,
            playbackPreferences: updatedPreferences
        )
        nowPlayingList = NowPlayingList(entries: entries, currentIndex: index)
        if let activePlaylistID,
           let playlistIndex = playlists.firstIndex(where: { $0.id == activePlaylistID }),
           let entryIndex = playlists[playlistIndex].entries.firstIndex(where: {
               $0.id == entry.id
           }) {
            let playlist = playlists[playlistIndex]
            var persistentEntries = playlist.entries
            let persistentEntry = persistentEntries[entryIndex]
            persistentEntries[entryIndex] = PlaylistEntry(
                id: persistentEntry.id,
                media: persistentEntry.media,
                resumePosition: persistentEntry.resumePosition,
                playbackPreferences: updatedPreferences
            )
            playlists[playlistIndex] = Playlist(
                id: playlist.id,
                name: playlist.name,
                entries: persistentEntries,
                currentEntryID: playlist.currentEntryID
            )
        }
        return true
    }

    private func relocateExternalSubtitle(
        _ reference: PersistentExternalSubtitleReference
    ) async -> Bool {
        if activePlaylistID != nil {
            do {
                try await playlistStore.updateExternalSubtitleReferences([reference])
            } catch {
                trackNotice = .selectionFailed(
                    "字幕已切换，但重新定位未能保存：\(error.localizedDescription)"
                )
                return false
            }
        }
        nowPlayingList = NowPlayingList(
            entries: nowPlayingList.entries.map {
                replacingExternalSubtitleReference(reference, in: $0)
            },
            currentIndex: nowPlayingList.currentIndex
        )
        playlists = playlists.map { playlist in
            Playlist(
                id: playlist.id,
                name: playlist.name,
                entries: playlist.entries.map { entry in
                    replacingExternalSubtitleReference(reference, in: entry)
                },
                currentEntryID: playlist.currentEntryID
            )
        }
        return true
    }

    private func replacingExternalSubtitleReference(
        _ reference: PersistentExternalSubtitleReference,
        in entry: NowPlayingEntry
    ) -> NowPlayingEntry {
        guard case let .external(existing) = entry.playbackPreferences.subtitle,
              existing.id == reference.id else { return entry }
        return NowPlayingEntry(
            id: entry.id,
            media: entry.media,
            resumePosition: entry.resumePosition,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: entry.playbackPreferences.audioTrack,
                subtitle: .external(reference)
            )
        )
    }

    private func replacingExternalSubtitleReference(
        _ reference: PersistentExternalSubtitleReference,
        in entry: PlaylistEntry
    ) -> PlaylistEntry {
        guard case let .external(existing) = entry.playbackPreferences.subtitle,
              existing.id == reference.id else { return entry }
        return PlaylistEntry(
            id: entry.id,
            media: entry.media,
            resumePosition: entry.resumePosition,
            playbackPreferences: EntryPlaybackPreferences(
                audioTrack: entry.playbackPreferences.audioTrack,
                subtitle: .external(reference)
            )
        )
    }

    private func setSelectedSubtitle(_ selection: ActiveSubtitleSelection) {
        trackSelection = TrackSelectionState(
            audioTrackID: trackSelection.audioTrackID,
            subtitle: selection
        )
    }

    private func selectedSubtitleName(in catalog: TrackCatalog) -> String? {
        guard case let .embedded(id) = trackSelection.subtitle else { return nil }
        return catalog.embeddedSubtitleTracks.first(where: { $0.id == id })?.displayName
    }
}
