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
    @Published public private(set) var browsingPlaylistID: PlaylistID?
    @Published public private(set) var detachedNowPlayingEntry: NowPlayingEntry?
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
    private var detachedSuccessorEntryIDs: [PlaylistEntryID] = []

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
        detachedNowPlayingEntry = nil
        detachedSuccessorEntryIDs = []
        persistenceNotice = .none
        isRestoredMediaPendingLoad = false
        isFindingFirstPlayableMedia = true
        await load(first.media)
    }

    @discardableResult
    public func createPlaylist(named requestedName: String) async throws -> Playlist {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            persistenceNotice = .failed("Playlist 名称不能为空")
            throw PlaylistPersistenceError.emptyName
        }
        let playlist = Playlist(name: name, entries: [])
        try await commit(playlists + [playlist], activePlaylistID: activePlaylistID)
        browsingPlaylistID = playlist.id
        persistenceNotice = .saved(name)
        return playlist
    }

    public func renamePlaylist(id: PlaylistID, to requestedName: String) async throws {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            persistenceNotice = .failed("Playlist 名称不能为空")
            throw PlaylistPersistenceError.emptyName
        }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else {
            throw PlaylistPersistenceError.playlistNotFound(id)
        }
        let existing = playlists[index]
        let renamed = existing.renamed(to: name)
        var updatedPlaylists = playlists
        updatedPlaylists[index] = renamed
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        browsingPlaylistID = id
        persistenceNotice = .saved(name)
    }

    public func browsePlaylist(_ id: PlaylistID) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        browsingPlaylistID = id
    }

    @discardableResult
    public func add(_ media: LocalMedia, to playlistID: PlaylistID) async throws -> PlaylistEntry {
        guard let bookmark = media.bookmark else {
            persistenceNotice = .failed("无法持久保存 \(media.url.lastPathComponent) 的只读访问权限")
            throw PlaylistPersistenceError.missingBookmark(media.url.path)
        }
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let sharedReference = playlists.lazy
            .flatMap(\.entries)
            .map(\.media)
            .first { reference in
                if let fileIdentity = media.fileIdentity,
                   let referenceIdentity = reference.fileIdentity {
                    return referenceIdentity == fileIdentity
                }
                return URL(fileURLWithPath: reference.lastKnownPath).standardizedFileURL
                    == media.url.standardizedFileURL
            }
        let persistentReference = PersistentLocalMediaReference(
            id: sharedReference?.id ?? media.referenceID,
            bookmark: bookmark,
            lastKnownPath: media.url.path,
            fileIdentity: media.fileIdentity ?? sharedReference?.fileIdentity
        )
        let entry = PlaylistEntry(media: persistentReference)
        var updatedPlaylists = playlists.map { playlist in
            playlist.replacingEntries(
                playlist.entries.map { existingEntry in
                    guard existingEntry.media.id == persistentReference.id else { return existingEntry }
                    return PlaylistEntry(
                        id: existingEntry.id,
                        media: persistentReference,
                        resumePosition: existingEntry.resumePosition,
                        playbackPreferences: existingEntry.playbackPreferences
                    )
                },
                currentEntryID: playlist.currentEntryID
            )
        }
        let playlist = updatedPlaylists[playlistIndex]
        let updatedPlaylist = playlist.replacingEntries(
            playlist.entries + [entry],
            currentEntryID: playlist.currentEntryID
        )
        updatedPlaylists[playlistIndex] = updatedPlaylist
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        if activePlaylistID == playlistID {
            let normalizedMedia = LocalMedia(
                url: media.url,
                referenceID: persistentReference.id,
                bookmark: persistentReference.bookmark,
                fileIdentity: persistentReference.fileIdentity
            )
            let refreshedEntries = nowPlayingList.entries.map { nowPlayingEntry in
                guard nowPlayingEntry.media.referenceID == persistentReference.id else {
                    return nowPlayingEntry
                }
                return NowPlayingEntry(
                    id: nowPlayingEntry.id,
                    media: normalizedMedia,
                    resumePosition: nowPlayingEntry.resumePosition,
                    playbackPreferences: nowPlayingEntry.playbackPreferences
                )
            }
            nowPlayingList = NowPlayingList(
                entries: refreshedEntries + [NowPlayingEntry(id: entry.id, media: normalizedMedia)],
                currentIndex: nowPlayingList.currentIndex
            )
        }
        browsingPlaylistID = playlistID
        return entry
    }

    @discardableResult
    public func duplicateEntry(
        _ entryID: PlaylistEntryID,
        in playlistID: PlaylistID
    ) async throws -> PlaylistEntry {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let playlist = playlists[playlistIndex]
        guard let sourceIndex = playlist.entries.firstIndex(where: { $0.id == entryID }) else {
            throw PlaylistPersistenceError.entryNotFound(entryID)
        }
        let source = playlist.entries[sourceIndex]
        let duplicate = PlaylistEntry(media: source.media)
        var entries = playlist.entries
        entries.insert(duplicate, at: sourceIndex + 1)
        let updatedPlaylist = playlist.replacingEntries(
            entries,
            currentEntryID: playlist.currentEntryID
        )
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = updatedPlaylist
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        if activePlaylistID == playlistID,
           let sourceNowPlaying = nowPlayingList.entries.first(where: { $0.id == entryID }) {
            var nowPlayingEntries = nowPlayingList.entries
            nowPlayingEntries.insert(
                NowPlayingEntry(id: duplicate.id, media: sourceNowPlaying.media),
                at: sourceIndex + 1
            )
            let currentID = nowPlayingList.currentIndex.flatMap { index in
                nowPlayingList.entries.indices.contains(index) ? nowPlayingList.entries[index].id : nil
            }
            nowPlayingList = NowPlayingList(
                entries: nowPlayingEntries,
                currentIndex: currentID.flatMap { id in
                    nowPlayingEntries.firstIndex(where: { $0.id == id })
                }
            )
        }
        browsingPlaylistID = playlistID
        return duplicate
    }

    public func moveEntry(
        _ entryID: PlaylistEntryID,
        in playlistID: PlaylistID,
        to destination: Int
    ) async throws {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let playlist = playlists[playlistIndex]
        guard playlist.entries.indices.contains(destination) else {
            throw PlaylistPersistenceError.invalidDestination(destination)
        }
        guard let source = playlist.entries.firstIndex(where: { $0.id == entryID }) else {
            throw PlaylistPersistenceError.entryNotFound(entryID)
        }
        var entries = playlist.entries
        let moved = entries.remove(at: source)
        entries.insert(moved, at: destination)
        let updatedPlaylist = playlist.replacingEntries(
            entries,
            currentEntryID: playlist.currentEntryID
        )
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = updatedPlaylist
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        if activePlaylistID == playlistID {
            reorderNowPlayingEntries(toMatch: entries)
        }
    }

    public func removeEntry(_ entryID: PlaylistEntryID, from playlistID: PlaylistID) async throws {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let playlist = playlists[playlistIndex]
        guard let removedIndex = playlist.entries.firstIndex(where: { $0.id == entryID }) else {
            throw PlaylistPersistenceError.entryNotFound(entryID)
        }
        let currentNowPlayingEntry = nowPlayingList.currentIndex.flatMap { index in
            nowPlayingList.entries.indices.contains(index) ? nowPlayingList.entries[index] : nil
        }
        var entries = playlist.entries
        entries.remove(at: removedIndex)
        let removedCurrentEntry = activePlaylistID == playlistID
            && currentNowPlayingEntry?.id == entryID
        let detachedCandidates = removedCurrentEntry
            ? Array(entries.dropFirst(removedIndex)).map(\.id)
            : detachedSuccessorEntryIDs.filter { candidate in
                entries.contains(where: { $0.id == candidate })
            }
        let successorID = entries.first(where: { detachedCandidates.contains($0.id) })?.id
        let updatedPlaylist = playlist.replacingEntries(
            entries,
            currentEntryID: removedCurrentEntry || detachedNowPlayingEntry != nil
                ? successorID
                : playlist.currentEntryID
        )
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = updatedPlaylist
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)

        guard activePlaylistID == playlistID else { return }
        if removedCurrentEntry {
            detachedNowPlayingEntry = currentNowPlayingEntry
            detachedSuccessorEntryIDs = detachedCandidates
        } else if detachedNowPlayingEntry != nil {
            detachedSuccessorEntryIDs = detachedCandidates
        }
        reorderNowPlayingEntries(toMatch: entries)
    }

    public func deletePlaylist(_ playlistID: PlaylistID, confirmed: Bool) async throws {
        guard playlists.contains(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let deletesPlayingSource = activePlaylistID == playlistID
        guard !deletesPlayingSource || confirmed else {
            throw PlaylistPersistenceError.deletionConfirmationRequired(playlistID)
        }
        let currentEntry = deletesPlayingSource
            ? (nowPlayingList.currentIndex.flatMap { index in
                nowPlayingList.entries.indices.contains(index) ? nowPlayingList.entries[index] : nil
            } ?? detachedNowPlayingEntry)
            : nil
        let remainingPlaylists = playlists.filter { $0.id != playlistID }
        try await commit(
            remainingPlaylists,
            activePlaylistID: deletesPlayingSource ? nil : activePlaylistID
        )

        if browsingPlaylistID == playlistID {
            browsingPlaylistID = remainingPlaylists.first?.id
        }
        guard deletesPlayingSource else { return }
        activePlaylistID = nil
        detachedNowPlayingEntry = currentEntry
        detachedSuccessorEntryIDs = []
        nowPlayingList = NowPlayingList()
        isRestoredMediaPendingLoad = false
    }

    public func playEntry(_ entryID: PlaylistEntryID, in playlistID: PlaylistID) async throws {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let playlist = playlists[playlistIndex]
        guard let currentIndex = playlist.entries.firstIndex(where: { $0.id == entryID }) else {
            throw PlaylistPersistenceError.entryNotFound(entryID)
        }
        var restoredEntries: [NowPlayingEntry] = []
        for entry in playlist.entries {
            let media = try await persistentMediaAccess.restore(entry.media)
            restoredEntries.append(NowPlayingEntry(
                id: entry.id,
                media: media,
                resumePosition: entry.resumePosition,
                playbackPreferences: entry.playbackPreferences
            ))
        }
        let playingPlaylist = playlist.replacingEntries(
            playlist.entries,
            currentEntryID: entryID
        )
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = playingPlaylist
        try await commit(updatedPlaylists, activePlaylistID: playlistID)
        activePlaylistID = playlistID
        browsingPlaylistID = playlistID
        detachedNowPlayingEntry = nil
        detachedSuccessorEntryIDs = []
        nowPlayingList = NowPlayingList(entries: restoredEntries, currentIndex: currentIndex)
        isRestoredMediaPendingLoad = false
        isFindingFirstPlayableMedia = false
        await load(restoredEntries[currentIndex].media)
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
                    lastKnownPath: entry.media.url.path,
                    fileIdentity: entry.media.fileIdentity
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
            browsingPlaylistID = playlist.id
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
            browsingPlaylistID = library.activePlaylistID ?? library.playlists.first?.id
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
                        lastKnownPath: media.url.path,
                        fileIdentity: media.fileIdentity ?? entry.media.fileIdentity
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
        await applyExternalSubtitle(
            subtitle,
            referenceID: ExternalSubtitleReferenceID(),
            relocatingSharedReference: false
        )
    }

    public func relocateExternalSubtitle(_ subtitle: LocalExternalSubtitle) async {
        guard let referenceID = currentExternalSubtitleReferenceID else {
            trackNotice = .selectionFailed("没有可重新定位的外部字幕")
            return
        }
        await applyExternalSubtitle(
            subtitle,
            referenceID: referenceID,
            relocatingSharedReference: true
        )
    }

    private func applyExternalSubtitle(
        _ subtitle: LocalExternalSubtitle,
        referenceID: ExternalSubtitleReferenceID,
        relocatingSharedReference: Bool
    ) async {
        switch await engine.loadExternalSubtitle(subtitle) {
        case .loaded:
            guard let bookmark = subtitle.bookmark else {
                trackNotice = .selectionFailed("无法持久保存外部字幕的只读访问权限")
                return
            }
            let reference = PersistentExternalSubtitleReference(
                id: referenceID,
                bookmark: bookmark,
                lastKnownPath: subtitle.url.path
            )
            trackSelection = TrackSelectionState(
                audioTrackID: trackSelection.audioTrackID,
                subtitle: .external(referenceID)
            )
            let saved = if relocatingSharedReference {
                await updateExternalSubtitleReference(reference)
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

    public var preferredExternalSubtitleName: String? {
        guard case let .external(reference) = currentPreferences.subtitle else { return nil }
        return URL(fileURLWithPath: reference.lastKnownPath).lastPathComponent
    }

    public var isPreferredExternalSubtitleActive: Bool {
        guard let referenceID = currentExternalSubtitleReferenceID else { return false }
        return trackSelection.subtitle == .external(referenceID)
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
            if state == .stopped {
                detachedNowPlayingEntry = nil
                detachedSuccessorEntryIDs = []
            }
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
            if detachedNowPlayingEntry != nil {
                let successorIndex = nowPlayingList.entries.firstIndex { entry in
                    detachedSuccessorEntryIDs.contains(entry.id)
                }
                detachedNowPlayingEntry = nil
                detachedSuccessorEntryIDs = []
                if let successorIndex {
                    nowPlayingList = NowPlayingList(
                        entries: nowPlayingList.entries,
                        currentIndex: successorIndex
                    )
                    await load(nowPlayingList.entries[successorIndex].media)
                } else {
                    state = .stopped
                }
                return
            }
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
        let defaultAudio = defaultAudioTrack(in: catalog.audioTracks)
        var selectedAudio: AudioTrackOption?
        if let preferredAudio, await engine.selectAudioTrack(preferredAudio.id) {
            selectedAudio = preferredAudio
        } else if let defaultAudio,
                  defaultAudio.id != preferredAudio?.id,
                  await engine.selectAudioTrack(defaultAudio.id) {
            selectedAudio = defaultAudio
            if preferences.audioTrack != nil {
                trackNotice = .preferenceUnavailable(
                    "原音轨不可用，已改用 \(defaultAudio.displayName)"
                )
            }
        } else if preferences.audioTrack != nil {
            trackNotice = .preferenceUnavailable("原音轨不可用，且没有可用回退音轨")
        }
        if let selectedAudio {
            trackSelection = TrackSelectionState(
                audioTrackID: selectedAudio.id,
                subtitle: trackSelection.subtitle
            )
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
        case .automatic:
            await applyDefaultSubtitle(catalog, selectedAudio: selectedAudio)
        case .off:
            if await engine.selectSubtitle(.off) {
                setSelectedSubtitle(.off)
            } else {
                trackNotice = .selectionFailed("无法恢复关闭字幕偏好")
            }
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

    private func updateExternalSubtitleReference(
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

    private func record(_ error: PlaylistStoreError) {
        switch error {
        case let .nameAlreadyExists(name):
            persistenceNotice = .nameAlreadyExists(name)
        case let .unavailable(message):
            persistenceNotice = .failed(message)
        }
    }

    private func commit(
        _ updatedPlaylists: [Playlist],
        activePlaylistID: PlaylistID?
    ) async throws {
        let library = PlaylistLibrary(
            playlists: updatedPlaylists,
            activePlaylistID: activePlaylistID
        )
        do {
            try await playlistStore.commit(library)
            playlists = updatedPlaylists
            persistenceNotice = .none
        } catch let error as PlaylistStoreError {
            record(error)
            throw error
        }
    }

    private func reorderNowPlayingEntries(toMatch entries: [PlaylistEntry]) {
        let currentID = nowPlayingList.currentIndex.flatMap { index in
            nowPlayingList.entries.indices.contains(index) ? nowPlayingList.entries[index].id : nil
        }
        let byID = Dictionary(uniqueKeysWithValues: nowPlayingList.entries.map { ($0.id, $0) })
        let reordered = entries.compactMap { byID[$0.id] }
        nowPlayingList = NowPlayingList(
            entries: reordered,
            currentIndex: currentID.flatMap { id in
                reordered.firstIndex(where: { $0.id == id })
            }
        )
    }
}
