import Combine
import Foundation

private struct LocalMediaReferenceIndex {
    private var byFileIdentity: [LocalFileIdentity: PersistentLocalMediaReference] = [:]
    private var byStandardizedPath: [String: PersistentLocalMediaReference] = [:]

    init(references: some Sequence<PersistentLocalMediaReference>) {
        for reference in references {
            insert(reference)
        }
    }

    func reference(matching media: LocalMedia) -> PersistentLocalMediaReference? {
        if let fileIdentity = media.fileIdentity {
            if let reference = byFileIdentity[fileIdentity] {
                return reference
            }
            guard let pathReference = byStandardizedPath[standardizedPath(media.url)],
                  pathReference.fileIdentity == nil else {
                return nil
            }
            return pathReference
        }
        return byStandardizedPath[standardizedPath(media.url)]
    }

    mutating func insert(_ reference: PersistentLocalMediaReference) {
        if let fileIdentity = reference.fileIdentity {
            byFileIdentity[fileIdentity] = reference
        }
        byStandardizedPath[standardizedPath(reference.lastKnownPath)] = reference
    }
}

private func standardizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path
}

private func standardizedPath(_ path: String) -> String {
    standardizedPath(URL(fileURLWithPath: path))
}

public protocol PlaybackTimeSource: Sendable {
    var now: TimeInterval { get }
}

public struct SystemPlaybackTimeSource: PlaybackTimeSource {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public protocol PlaylistRandomizer: Sendable {
    func shuffled(_ entryIDs: [PlaylistEntryID]) -> [PlaylistEntryID]
}

public struct SystemPlaylistRandomizer: PlaylistRandomizer {
    public init() {}

    public func shuffled(_ entryIDs: [PlaylistEntryID]) -> [PlaylistEntryID] {
        entryIDs.shuffled()
    }
}

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

public enum MissingMediaNotice: Equatable, Sendable {
    case none
    case recoveryRequired(entryID: PlaylistEntryID, referenceID: LocalMediaReferenceID)
    case noPlayableEntries(missingCount: Int)
    case replacementConfirmationRequired(MediaReplacementImpact)
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
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var playbackRate: Double = 1
    @Published public private(set) var playerVolume: Double = 1
    @Published public private(set) var isMuted = false
    @Published public private(set) var seekStep: TimeInterval
    @Published public private(set) var availableAudioTracks: [AudioTrackOption] = []
    @Published public private(set) var availableEmbeddedSubtitleTracks: [EmbeddedSubtitleTrackOption] = []
    @Published public private(set) var trackSelection = TrackSelectionState()
    @Published public private(set) var trackNotice: TrackNotice = .none
    @Published public private(set) var missingMediaNotice: MissingMediaNotice = .none
    @Published public private(set) var mediaPresentation: PlaybackMediaPresentation?

    public var missingMediaCount: Int {
        nowPlayingList.entries.count(where: \.isMediaMissing)
    }

    private let engine: any PlaybackEngine
    private let playlistStore: any PlaylistStore
    private let persistentMediaAccess: any PersistentMediaAccess
    private let timeSource: any PlaybackTimeSource
    private let externalSubtitleAccess: any PersistentExternalSubtitleAccess
    private let defaultTrackRules: DefaultTrackRules
    private let randomizer: any PlaylistRandomizer
    private let mediaReplacementAssessor: any MediaReplacementAssessing
    private var eventTask: Task<Void, Never>?
    private var isFindingFirstPlayableMedia = false
    private var isRestoredMediaPendingLoad = false
    private var activeLoadID: PlaybackLoadID?
    private var nextLoadID: UInt64 = 0
    private var lastPersistedPosition: TimeInterval?
    private var lastProgressSaveTime: TimeInterval
    private var lastConfirmedPosition: TimeInterval = 0
    private var pendingSeekTarget: TimeInterval?
    private var detachedSuccessorEntryIDs: [PlaylistEntryID] = []
    private var randomAutomaticLoadIDs: Set<PlaybackLoadID> = []
    private var automaticLoadIDs: Set<PlaybackLoadID> = []

    public init(
        engine: any PlaybackEngine,
        playlistStore: any PlaylistStore = InMemoryPlaylistStore(),
        persistentMediaAccess: any PersistentMediaAccess = LastKnownPathMediaAccess(),
        seekStep: TimeInterval = 10,
        timeSource: any PlaybackTimeSource = SystemPlaybackTimeSource(),
        externalSubtitleAccess: any PersistentExternalSubtitleAccess = LastKnownPathExternalSubtitleAccess(),
        defaultTrackRules: DefaultTrackRules = DefaultTrackRules(),
        randomizer: any PlaylistRandomizer = SystemPlaylistRandomizer(),
        mediaReplacementAssessor: any MediaReplacementAssessing = DefaultMediaReplacementAssessor()
    ) {
        self.engine = engine
        self.playlistStore = playlistStore
        self.persistentMediaAccess = persistentMediaAccess
        self.seekStep = max(1, seekStep)
        self.timeSource = timeSource
        lastProgressSaveTime = timeSource.now
        self.externalSubtitleAccess = externalSubtitleAccess
        self.defaultTrackRules = defaultTrackRules
        self.randomizer = randomizer
        self.mediaReplacementAssessor = mediaReplacementAssessor
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
        if activePlaylistID != nil {
            await persistCurrentState(force: true)
        }
        nowPlayingList = NowPlayingList(entries: entries, currentIndex: 0)
        activePlaylistID = nil
        detachedNowPlayingEntry = nil
        detachedSuccessorEntryIDs = []
        persistenceNotice = .none
        isRestoredMediaPendingLoad = false
        isFindingFirstPlayableMedia = true
        resetTimeline(for: first)
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

    public func setRepeatMode(
        _ repeatMode: PlaylistRepeatMode,
        for playlistID: PlaylistID
    ) async throws {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let playlist = playlists[playlistIndex]
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = playlist.replacingPlaybackPolicy(
            order: playlist.playbackOrder,
            repeatMode: repeatMode,
            randomRound: playlist.randomRound
        )
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
    }

    public func setPlaybackOrder(
        _ order: PlaybackOrder,
        for playlistID: PlaylistID
    ) async throws {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let playlist = playlists[playlistIndex]
        guard playlist.playbackOrder != order else { return }
        let round = order == .random ? makeRandomRound(for: playlist) : nil
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = playlist.replacingPlaybackPolicy(
            order: order,
            repeatMode: playlist.repeatMode,
            randomRound: round
        )
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
    }

    @discardableResult
    public func add(_ media: LocalMedia, to playlistID: PlaylistID) async throws -> PlaylistEntry {
        try await appendMedia([media], to: playlistID)[0]
    }

    @discardableResult
    public func importFolder(
        _ folder: URL,
        into playlistID: PlaylistID,
        duplicatePolicy: FolderImportDuplicatePolicy = .skipExisting,
        traverser: any FolderTraversing = FileSystemFolderTraverser(),
        mediaProbe: any FolderMediaProbing = FileSystemFolderMediaProbe()
    ) async throws -> FolderImportReport {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        let files = try await traverser.files(in: folder).sorted(by: folderImportNaturalLessThan)
        var mediaItems: [LocalMedia] = []
        var refreshedMediaItems: [LocalMedia] = []
        var skippedCount = 0
        var failedCount = 0
        var targetMediaIndex = LocalMediaReferenceIndex(
            references: playlists[playlistIndex].entries.map(\.media)
        )

        for file in files {
            try Task.checkCancellation()
            switch try await mediaProbe.probe(file) {
            case let .supported(media):
                guard let bookmark = media.bookmark else {
                    failedCount += 1
                    continue
                }
                if duplicatePolicy == .skipExisting,
                   targetMediaIndex.reference(matching: media) != nil {
                    skippedCount += 1
                    refreshedMediaItems.append(media)
                    continue
                }
                mediaItems.append(media)
                targetMediaIndex.insert(PersistentLocalMediaReference(
                    id: media.referenceID,
                    bookmark: bookmark,
                    lastKnownPath: media.url.path,
                    fileIdentity: media.fileIdentity
                ))
            case .unsupported:
                skippedCount += 1
            case .failed:
                failedCount += 1
            }
        }

        try Task.checkCancellation()
        let entries = try await appendMedia(
            mediaItems,
            refreshing: refreshedMediaItems,
            to: playlistID
        )
        return FolderImportReport(
            addedCount: entries.count,
            skippedCount: skippedCount,
            failedCount: failedCount
        )
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
        var updatedPlaylist = playlist.replacingEntries(
            entries,
            currentEntryID: playlist.currentEntryID
        )
        if let round = playlist.randomRound {
            updatedPlaylist = updatedPlaylist.replacingRandomRound(
                round.addingUnplayed(duplicate.id)
            )
        }
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
        var updatedPlaylist = playlist.replacingEntries(
            entries,
            currentEntryID: removedCurrentEntry || detachedNowPlayingEntry != nil
                ? successorID
                : playlist.currentEntryID
        )
        if let round = playlist.randomRound {
            updatedPlaylist = updatedPlaylist.replacingRandomRound(round.removing(entryID))
        }
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = updatedPlaylist
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        if case let .recoveryRequired(recoveryEntryID, _) = missingMediaNotice,
           recoveryEntryID == entryID {
            missingMediaNotice = .none
        }

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
        let selectedEntry = playlist.entries[currentIndex]
        guard selectedEntry.media.availability != .missing else {
            missingMediaNotice = .recoveryRequired(
                entryID: selectedEntry.id,
                referenceID: selectedEntry.media.id
            )
            return
        }
        missingMediaNotice = .none
        var restoredEntries: [NowPlayingEntry] = []
        var restoredMediaByReferenceID: [LocalMediaReferenceID: LocalMedia] = [:]
        for entry in playlist.entries {
            let media: LocalMedia
            if let restored = restoredMediaByReferenceID[entry.media.id] {
                media = restored
            } else if entry.media.availability == .missing {
                media = missingLocalMedia(for: entry.media)
            } else {
                do {
                    media = try await persistentMediaAccess.restore(entry.media)
                } catch {
                    try await markMediaReferenceMissing(entry.media)
                    media = missingLocalMedia(for: entry.media)
                }
                restoredMediaByReferenceID[entry.media.id] = media
            }
            restoredEntries.append(NowPlayingEntry(
                id: entry.id,
                media: media,
                resumePosition: entry.resumePosition,
                isCompleted: entry.isCompleted,
                playbackPreferences: entry.playbackPreferences
            ))
        }
        guard !restoredEntries[currentIndex].isMediaMissing else {
            missingMediaNotice = .recoveryRequired(
                entryID: entryID,
                referenceID: selectedEntry.media.id
            )
            return
        }
        let refreshedPlaylist = playlists.first(where: { $0.id == playlistID }) ?? playlist
        var playingPlaylist = refreshedPlaylist.replacingEntries(
            refreshedPlaylist.entries,
            currentEntryID: entryID
        )
        if playlist.playbackOrder == .random {
            let round = (playlist.randomRound ?? makeRandomRound(for: playingPlaylist))
                .recording(entryID)
            playingPlaylist = playingPlaylist.replacingRandomRound(round)
        }
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

    public func cancelMissingMediaRecovery() {
        missingMediaNotice = .none
    }

    @discardableResult
    public func relocateMissingMedia(
        referenceID: LocalMediaReferenceID,
        to media: LocalMedia,
        confirmedReplacement: Bool = false
    ) async throws -> MediaRelocationResult {
        let affectedPlaylists = playlists.filter { playlist in
            playlist.entries.contains(where: { $0.media.id == referenceID })
        }
        guard let existingReference = affectedPlaylists.lazy
            .flatMap(\.entries)
            .first(where: { $0.media.id == referenceID })?
            .media else {
            throw PlaylistPersistenceError.mediaReferenceNotFound(referenceID)
        }
        guard let bookmark = media.bookmark else {
            throw PlaylistPersistenceError.missingBookmark(media.url.path)
        }
        let impact = MediaReplacementImpact(
            referenceID: referenceID,
            affectedEntryCount: affectedPlaylists.reduce(0) { count, playlist in
                count + playlist.entries.count(where: { $0.media.id == referenceID })
            },
            affectedPlaylistCount: affectedPlaylists.count
        )
        let isObviousReplacement = mediaReplacementAssessor.isObviousReplacement(
            existing: existingReference,
            candidate: media
        )
        guard !isObviousReplacement || confirmedReplacement else {
            missingMediaNotice = .replacementConfirmationRequired(impact)
            return .confirmationRequired(impact)
        }
        let replacement = PersistentLocalMediaReference(
            id: referenceID,
            bookmark: bookmark,
            lastKnownPath: media.url.path,
            fileIdentity: media.fileIdentity ?? existingReference.fileIdentity,
            availability: .available
        )
        let updatedPlaylists = playlists.map { playlist in
            let entries = playlist.entries.map { entry in
                guard entry.media.id == referenceID else { return entry }
                return PlaylistEntry(
                    id: entry.id,
                    media: replacement,
                    resumePosition: isObviousReplacement ? nil : entry.resumePosition,
                    isCompleted: isObviousReplacement ? false : entry.isCompleted,
                    playbackPreferences: isObviousReplacement
                        ? EntryPlaybackPreferences()
                        : entry.playbackPreferences
                )
            }
            return playlist.replacingEntries(entries, currentEntryID: playlist.currentEntryID)
        }
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        let replacementMedia = LocalMedia(
            url: media.url,
            referenceID: referenceID,
            bookmark: bookmark,
            fileIdentity: replacement.fileIdentity,
            availability: .available
        )
        nowPlayingList = NowPlayingList(
            entries: nowPlayingList.entries.map { entry in
                guard entry.media.referenceID == referenceID else { return entry }
                return NowPlayingEntry(
                    id: entry.id,
                    media: replacementMedia,
                    resumePosition: isObviousReplacement ? nil : entry.resumePosition,
                    isCompleted: isObviousReplacement ? false : entry.isCompleted,
                    playbackPreferences: isObviousReplacement
                        ? EntryPlaybackPreferences()
                        : entry.playbackPreferences
                )
            },
            currentIndex: nowPlayingList.currentIndex
        )
        missingMediaNotice = .none
        return .relocated
    }

    private func markMediaReferenceMissing(
        _ reference: PersistentLocalMediaReference
    ) async throws {
        let missingReference = PersistentLocalMediaReference(
            id: reference.id,
            bookmark: reference.bookmark,
            lastKnownPath: reference.lastKnownPath,
            fileIdentity: reference.fileIdentity,
            availability: .missing
        )
        try await playlistStore.updateMediaReferences([missingReference])
        let library = PlaylistLibrary(
            playlists: playlists,
            activePlaylistID: activePlaylistID,
            playerVolume: playerVolume,
            isMuted: isMuted,
            seekStep: seekStep
        ).replacingMediaReferences([missingReference])
        playlists = library.playlists
        nowPlayingList = NowPlayingList(
            entries: nowPlayingList.entries.map { entry in
                guard entry.media.referenceID == reference.id else { return entry }
                return NowPlayingEntry(
                    id: entry.id,
                    media: missingLocalMedia(for: missingReference),
                    resumePosition: entry.resumePosition,
                    isCompleted: entry.isCompleted,
                    playbackPreferences: entry.playbackPreferences
                )
            },
            currentIndex: nowPlayingList.currentIndex
        )
    }

    private func missingLocalMedia(
        for reference: PersistentLocalMediaReference
    ) -> LocalMedia {
        LocalMedia(
            url: URL(fileURLWithPath: reference.lastKnownPath),
            referenceID: reference.id,
            bookmark: reference.bookmark,
            fileIdentity: reference.fileIdentity,
            availability: .missing
        )
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
                    fileIdentity: entry.media.fileIdentity,
                    availability: entry.media.availability
                ),
                resumePosition: entry.resumePosition,
                isCompleted: entry.isCompleted,
                playbackPreferences: entry.playbackPreferences
            )
        }
        let currentEntryID = nowPlayingList.currentIndex.flatMap { index in
            entries.indices.contains(index) ? entries[index].id : nil
        }
        let playlist = Playlist(
            name: name,
            entries: entries,
            currentEntryID: currentEntryID,
            playbackRate: playbackRate
        )

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
            playerVolume = library.playerVolume
            isMuted = library.isMuted
            seekStep = library.seekStep
            browsingPlaylistID = library.activePlaylistID ?? library.playlists.first?.id
            guard let activeID = library.activePlaylistID,
                  let activePlaylist = library.playlists.first(where: { $0.id == activeID }) else {
                return
            }
            playbackRate = activePlaylist.playbackRate
            var restoredEntries: [NowPlayingEntry] = []
            var refreshedReferences: [PersistentLocalMediaReference] = []
            var restoredMediaByReferenceID: [LocalMediaReferenceID: LocalMedia] = [:]
            for entry in activePlaylist.entries {
                let media: LocalMedia
                if let restored = restoredMediaByReferenceID[entry.media.id] {
                    media = restored
                } else {
                    do {
                        media = try await persistentMediaAccess.restore(entry.media)
                    } catch {
                        media = missingLocalMedia(for: entry.media)
                    }
                    restoredMediaByReferenceID[entry.media.id] = media
                }
                if let bookmark = media.bookmark, bookmark != entry.media.bookmark {
                    refreshedReferences.append(PersistentLocalMediaReference(
                        id: entry.media.id,
                        bookmark: bookmark,
                        lastKnownPath: media.url.path,
                        fileIdentity: media.fileIdentity ?? entry.media.fileIdentity,
                        availability: media.availability
                    ))
                } else if media.availability != entry.media.availability {
                    refreshedReferences.append(PersistentLocalMediaReference(
                        id: entry.media.id,
                        bookmark: entry.media.bookmark,
                        lastKnownPath: entry.media.lastKnownPath,
                        fileIdentity: entry.media.fileIdentity,
                        availability: media.availability
                    ))
                }
                restoredEntries.append(NowPlayingEntry(
                    id: entry.id,
                    media: media,
                    resumePosition: entry.resumePosition,
                    isCompleted: entry.isCompleted,
                    playbackPreferences: entry.playbackPreferences
                ))
            }
            try await playlistStore.updateMediaReferences(refreshedReferences)
            if !refreshedReferences.isEmpty {
                playlists = library.replacingMediaReferences(refreshedReferences).playlists
            }
            let currentIndex = activePlaylist.currentEntryID.flatMap { currentID in
                restoredEntries.firstIndex(where: { $0.id == currentID })
            }
            nowPlayingList = NowPlayingList(entries: restoredEntries, currentIndex: currentIndex)
            if currentIndex != nil {
                state = .paused
                isRestoredMediaPendingLoad = true
                if let entry = currentEntry {
                    resetTimeline(for: entry)
                }
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
        if let entry = currentEntry, entry.isMediaMissing {
            missingMediaNotice = .recoveryRequired(
                entryID: entry.id,
                referenceID: entry.media.referenceID
            )
            return
        }
        if isRestoredMediaPendingLoad, let media = nowPlayingList.currentMedia {
            isRestoredMediaPendingLoad = false
            await load(media)
            return
        }
        await engine.play()
    }

    public func pause() async {
        await persistCurrentState(force: true)
        await engine.pause()
    }

    public func stop() async {
        await persistCurrentState(force: true)
        await engine.stop()
    }

    public func seek(to requestedPosition: TimeInterval) async {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        position = min(max(0, requestedPosition), upperBound)
        pendingSeekTarget = position
        await engine.seek(to: position)
    }

    public func skipForward() async {
        await seek(to: position + seekStep)
    }

    public func skipBackward() async {
        await seek(to: position - seekStep)
    }

    public func setPlaybackRate(_ requestedRate: Double) async {
        let previousRate = playbackRate
        playbackRate = min(max(requestedRate, 0.25), 4)
        await engine.setPlaybackRate(playbackRate)
        if activePlaylistID != nil, !(await persistCurrentState(force: true)) {
            playbackRate = previousRate
            await engine.setPlaybackRate(previousRate)
        }
    }

    public func setPlayerVolume(_ requestedVolume: Double) async {
        let previousVolume = playerVolume
        playerVolume = min(max(requestedVolume, 0), 1)
        await engine.setPlayerVolume(playerVolume)
        if !(await persistCurrentState(force: true)) {
            playerVolume = previousVolume
            await engine.setPlayerVolume(previousVolume)
        }
    }

    public func setMuted(_ muted: Bool) async {
        let wasMuted = isMuted
        isMuted = muted
        await engine.setMuted(muted)
        if !(await persistCurrentState(force: true)) {
            isMuted = wasMuted
            await engine.setMuted(wasMuted)
        }
    }

    public func setSeekStep(_ requestedStep: TimeInterval) async {
        let previousStep = seekStep
        seekStep = min(max(requestedStep, 1), 300)
        if !(await persistCurrentState(force: true)) {
            seekStep = previousStep
        }
    }

    @discardableResult
    public func prepareToTerminate() async -> Bool {
        guard activePlaylistID != nil else { return true }
        return await persistCurrentState(force: true)
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
            action: .selectNew
        )
    }

    public func relocateExternalSubtitle(_ subtitle: LocalExternalSubtitle) async {
        guard let referenceID = currentExternalSubtitleReferenceID else {
            trackNotice = .selectionFailed("没有可重新定位的外部字幕")
            return
        }
        await applyExternalSubtitle(
            subtitle,
            action: .relocate(referenceID)
        )
    }

    private enum ExternalSubtitleAction {
        case selectNew
        case relocate(ExternalSubtitleReferenceID)
    }

    private func applyExternalSubtitle(
        _ subtitle: LocalExternalSubtitle,
        action: ExternalSubtitleAction
    ) async {
        switch await engine.loadExternalSubtitle(subtitle) {
        case .loaded:
            guard let bookmark = subtitle.bookmark else {
                trackNotice = .selectionFailed("无法持久保存外部字幕的只读访问权限")
                return
            }
            let referenceID = switch action {
            case .selectNew: ExternalSubtitleReferenceID()
            case let .relocate(referenceID): referenceID
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
            let saved = switch action {
            case .selectNew:
                await updateCurrentPreferences { current in
                    EntryPlaybackPreferences(
                        audioTrack: current.audioTrack,
                        subtitle: .external(reference)
                    )
                }
            case .relocate:
                await updateExternalSubtitleReference(reference)
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
        await persistCurrentState(force: true)
        if activePlaylist?.playbackOrder == .random {
            await advanceRandom(stopEngineAtBoundary: true)
            return
        }
        await move(by: 1)
    }

    public func previous() async {
        isFindingFirstPlayableMedia = false
        await persistCurrentState(force: true)
        if let playlist = activePlaylist,
           playlist.playbackOrder == .random,
           let currentEntryID = currentEntry?.id,
           let historyIndex = playlist.randomRound?.playedEntryIDs.firstIndex(of: currentEntryID),
           historyIndex > 0,
           let destination = nowPlayingList.entries.firstIndex(where: {
               $0.id == playlist.randomRound?.playedEntryIDs[historyIndex - 1]
           }) {
            await move(to: destination, automaticallySelected: true)
            return
        }
        await move(by: -1)
    }

    private func move(by offset: Int) async {
        guard let currentIndex = nowPlayingList.currentIndex else {
            await engine.stop()
            return
        }
        let indices: any Sequence<Int> = offset >= 0
            ? AnySequence((currentIndex + 1)..<nowPlayingList.entries.count)
            : AnySequence(stride(from: currentIndex - 1, through: 0, by: -1))
        guard let destination = indices.first(where: {
            !nowPlayingList.entries[$0].isMediaMissing
        }) else {
            reportMissingProgressionBoundary()
            await engine.stop()
            return
        }
        missingMediaNotice = .none
        await move(to: destination, automaticallySelected: true)
    }

    private func move(
        to index: Int,
        advancesRandomAfterFailure: Bool = false,
        automaticallySelected: Bool = false
    ) async {
        guard nowPlayingList.entries.indices.contains(index) else {
            await engine.stop()
            return
        }
        nowPlayingList = NowPlayingList(entries: nowPlayingList.entries, currentIndex: index)
        let entry = nowPlayingList.entries[index]
        resetTimeline(for: entry)
        await load(
            entry.media,
            advancesRandomAfterFailure: advancesRandomAfterFailure,
            automaticallySelected: automaticallySelected
        )
        await persistCurrentState(force: true)
    }

    private func load(
        _ media: LocalMedia,
        advancesRandomAfterFailure: Bool = false,
        automaticallySelected: Bool = false
    ) async {
        nextLoadID &+= 1
        let loadID = PlaybackLoadID(rawValue: nextLoadID)
        activeLoadID = loadID
        randomAutomaticLoadIDs.removeAll(keepingCapacity: true)
        automaticLoadIDs.removeAll(keepingCapacity: true)
        if advancesRandomAfterFailure {
            randomAutomaticLoadIDs.insert(loadID)
        }
        if automaticallySelected || advancesRandomAfterFailure {
            automaticLoadIDs.insert(loadID)
        }
        availableAudioTracks = []
        availableEmbeddedSubtitleTracks = []
        trackSelection = TrackSelectionState()
        trackNotice = .none
        mediaPresentation = nil
        await engine.load(media, loadID: loadID)
        await engine.setPlaybackRate(playbackRate)
        await engine.setPlayerVolume(playerVolume)
        await engine.setMuted(isMuted)
        await engine.seek(to: currentEntry?.isCompleted == true ? 0 : (currentEntry?.resumePosition ?? 0))
    }

    private func receive(_ event: PlaybackEngineEvent) async {
        switch event {
        case let .playbackStateChanged(state, loadID):
            guard loadID == activeLoadID else { return }
            if case .failed = state, pendingSeekTarget != nil {
                position = lastConfirmedPosition
                pendingSeekTarget = nil
            }
            self.state = state
            let wasAutomaticallySelected = automaticLoadIDs.remove(loadID) != nil
            if case .failed(.unreadable) = state,
               let entry = currentEntry,
               let reference = activePlaylist?.entries.first(where: { $0.id == entry.id })?.media {
                do {
                    try await markMediaReferenceMissing(reference)
                } catch {
                    self.state = .stopped
                    return
                }
                if wasAutomaticallySelected {
                    if activePlaylist?.playbackOrder == .random {
                        guard await markRandomUnavailable(entry.id) else {
                            self.state = .stopped
                            return
                        }
                        await advanceRandom(advancesAfterFailure: true)
                    } else {
                        await advanceSequentialAutomatically()
                    }
                } else {
                    missingMediaNotice = .recoveryRequired(
                        entryID: entry.id,
                        referenceID: reference.id
                    )
                }
                return
            }
            if case .failed = state,
               randomAutomaticLoadIDs.remove(loadID) != nil,
               let entryID = currentEntry?.id {
                guard await markRandomUnavailable(entryID) else {
                    self.state = .stopped
                    return
                }
                await advanceRandom(advancesAfterFailure: true)
                return
            }
            if state == .stopped {
                detachedNowPlayingEntry = nil
                detachedSuccessorEntryIDs = []
            }
            switch state {
            case .playing, .paused:
                isFindingFirstPlayableMedia = false
                randomAutomaticLoadIDs.remove(loadID)
                automaticLoadIDs.remove(loadID)
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
        case let .timelineChanged(newPosition, newDuration, loadID):
            guard loadID == activeLoadID else { return }
            if let pendingSeekTarget,
               abs(newPosition - pendingSeekTarget) >= 0.5 {
                duration = max(0, newDuration)
                return
            }
            position = max(0, newPosition)
            duration = max(0, newDuration)
            lastConfirmedPosition = position
            let confirmsUserSeek = pendingSeekTarget != nil
            pendingSeekTarget = nil
            let wasCompleted = currentEntry?.isCompleted ?? false
            let completed = isAtCompletionThreshold
            updateCurrentEntryProgress(resumePosition: resumePosition, isCompleted: completed)
            await persistCurrentState(force: confirmsUserSeek || (completed && !wasCompleted))
        case .settingsChanged:
            break
        case let .playbackEnded(loadID):
            guard loadID == activeLoadID else { return }
            randomAutomaticLoadIDs.remove(loadID)
            automaticLoadIDs.remove(loadID)
            isFindingFirstPlayableMedia = false
            if detachedNowPlayingEntry != nil {
                let successorIndex = nowPlayingList.entries.firstIndex { entry in
                    detachedSuccessorEntryIDs.contains(entry.id)
                }
                detachedNowPlayingEntry = nil
                detachedSuccessorEntryIDs = []
                if let successorIndex {
                    let successor = nowPlayingList.entries[successorIndex]
                    guard await recordRandomSelectionIfNeeded(successor.id) else {
                        state = .stopped
                        return
                    }
                    nowPlayingList = NowPlayingList(
                        entries: nowPlayingList.entries,
                        currentIndex: successorIndex
                    )
                    await load(
                        successor.media,
                        advancesRandomAfterFailure: activePlaylist?.playbackOrder == .random,
                        automaticallySelected: true
                    )
                } else {
                    state = .stopped
                }
                return
            }
            updateCurrentEntryProgress(resumePosition: nil, isCompleted: true)
            await persistCurrentState(force: true)
            guard let currentIndex = nowPlayingList.currentIndex else {
                state = .stopped
                return
            }
            if activePlaylist?.repeatMode == .entry {
                await move(to: currentIndex, automaticallySelected: true)
                return
            }
            if activePlaylist?.playbackOrder == .random {
                await advanceRandom(advancesAfterFailure: true)
                return
            }
            await advanceSequentialAutomatically()
        case let .trackCatalogChanged(catalog, loadID):
            guard loadID == activeLoadID else { return }
            await applyTrackCatalog(catalog)
        case let .mediaPresentationChanged(presentation, loadID):
            guard loadID == activeLoadID else { return }
            mediaPresentation = presentation
        }
    }

    private var currentEntry: NowPlayingEntry? {
        guard let index = nowPlayingList.currentIndex,
              nowPlayingList.entries.indices.contains(index) else { return nil }
        return nowPlayingList.entries[index]
    }

    private var activePlaylist: Playlist? {
        guard let activePlaylistID else { return nil }
        return playlists.first(where: { $0.id == activePlaylistID })
    }

    private func makeRandomRound(for playlist: Playlist) -> RandomPlaybackRound {
        let entryIDs = playlist.entries.map(\.id)
        guard let currentEntryID = playlist.currentEntryID,
              entryIDs.contains(currentEntryID) else {
            return RandomPlaybackRound(order: randomizer.shuffled(entryIDs))
        }
        return RandomPlaybackRound(
            order: [currentEntryID] + randomizer.shuffled(entryIDs.filter { $0 != currentEntryID }),
            playedEntryIDs: [currentEntryID]
        )
    }

    private func advanceSequentialAutomatically() async {
        guard let currentIndex = nowPlayingList.currentIndex else {
            state = .stopped
            return
        }
        let forward = ((currentIndex + 1)..<nowPlayingList.entries.count).first(where: {
            !nowPlayingList.entries[$0].isMediaMissing
        })
        let wrapped = activePlaylist?.repeatMode == .playlist
            ? (0...currentIndex).first(where: { !nowPlayingList.entries[$0].isMediaMissing })
            : nil
        guard let destination = forward ?? wrapped else {
            state = .stopped
            reportMissingProgressionBoundary()
            return
        }
        missingMediaNotice = .none
        await move(to: destination, automaticallySelected: true)
    }

    private func advanceRandom(
        stopEngineAtBoundary: Bool = false,
        advancesAfterFailure: Bool = false
    ) async {
        guard let activePlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == activePlaylistID }) else {
            state = .stopped
            return
        }
        let playlist = playlists[playlistIndex]
        let existingIDs = Set(playlist.entries.map(\.id))
        let playableIDs = Set(playlist.entries.lazy.filter {
            $0.media.availability != .missing
        }.map(\.id))
        var round = playlist.randomRound ?? makeRandomRound(for: playlist)
        var candidate = round.order.first { id in
            playableIDs.contains(id)
                && !round.playedEntryIDs.contains(id)
                && !round.unavailableEntryIDs.contains(id)
        }
        let eligibleIDs = playableIDs.subtracting(round.unavailableEntryIDs)
        if candidate == nil, playlist.repeatMode == .playlist, !eligibleIDs.isEmpty {
            round = RandomPlaybackRound(
                order: randomizer.shuffled(playlist.entries.map(\.id)),
                unavailableEntryIDs: round.unavailableEntryIDs.filter(existingIDs.contains)
            )
            candidate = round.order.first(where: eligibleIDs.contains)
        }
        guard let candidate,
              let destination = nowPlayingList.entries.firstIndex(where: { $0.id == candidate }) else {
            state = .stopped
            reportMissingProgressionBoundary()
            if stopEngineAtBoundary {
                await engine.stop()
            }
            return
        }
        round = round.recording(candidate)
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = playlist.replacingProgression(
            currentEntryID: candidate,
            randomRound: round
        )
        do {
            try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        } catch {
            state = .stopped
            return
        }
        await move(
            to: destination,
            advancesRandomAfterFailure: advancesAfterFailure,
            automaticallySelected: true
        )
    }

    private func reportMissingProgressionBoundary() {
        missingMediaNotice = missingMediaCount > 0
            ? .noPlayableEntries(missingCount: missingMediaCount)
            : .none
    }

    private func recordRandomSelectionIfNeeded(_ entryID: PlaylistEntryID) async -> Bool {
        guard let activePlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == activePlaylistID }),
              playlists[playlistIndex].playbackOrder == .random else {
            return true
        }
        let playlist = playlists[playlistIndex]
        var round = playlist.randomRound ?? makeRandomRound(for: playlist)
        guard !round.playedEntryIDs.contains(entryID) else { return true }
        round = round.recording(entryID)
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = playlist.replacingProgression(
            currentEntryID: entryID,
            randomRound: round
        )
        do {
            try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
            return true
        } catch {
            return false
        }
    }

    private func markRandomUnavailable(_ entryID: PlaylistEntryID) async -> Bool {
        guard let activePlaylistID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == activePlaylistID }),
              let round = playlists[playlistIndex].randomRound else {
            return true
        }
        let playlist = playlists[playlistIndex]
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = playlist.replacingRandomRound(
            round.markingUnavailable(entryID)
        )
        do {
            try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
            return true
        } catch {
            return false
        }
    }

    private var resumePosition: TimeInterval? {
        guard position >= 10, !isAtCompletionThreshold else { return nil }
        return position
    }

    private var isAtCompletionThreshold: Bool {
        guard duration > 0 else { return false }
        return duration - position <= min(30, duration * 0.05)
    }

    private func resetTimeline(for entry: NowPlayingEntry) {
        position = entry.isCompleted ? 0 : (entry.resumePosition ?? 0)
        lastConfirmedPosition = position
        duration = 0
        lastPersistedPosition = entry.resumePosition
        lastProgressSaveTime = timeSource.now
        pendingSeekTarget = nil
    }

    private func updateCurrentEntryProgress(
        resumePosition: TimeInterval?,
        isCompleted: Bool
    ) {
        guard let index = nowPlayingList.currentIndex,
              nowPlayingList.entries.indices.contains(index) else { return }
        var entries = nowPlayingList.entries
        let entry = entries[index]
        entries[index] = NowPlayingEntry(
            id: entry.id,
            media: entry.media,
            resumePosition: resumePosition,
            isCompleted: isCompleted,
            playbackPreferences: entry.playbackPreferences
        )
        nowPlayingList = NowPlayingList(entries: entries, currentIndex: index)
    }

    @discardableResult
    private func persistCurrentState(force: Bool) async -> Bool {
        let completed = currentEntry?.isCompleted ?? false
        let candidate: TimeInterval?
        if pendingSeekTarget != nil {
            candidate = completed ? nil : currentEntry?.resumePosition
        } else {
            candidate = completed ? nil : resumePosition
        }
        let crossedPeriodicBoundary = candidate.map { position in
            guard let lastPersistedPosition else { return true }
            return position != lastPersistedPosition && timeSource.now - lastProgressSaveTime >= 5
        } ?? false
        guard force || crossedPeriodicBoundary else { return true }

        let snapshot = PlaybackPersistenceSnapshot(
            playlistID: activePlaylistID,
            entryID: currentEntry?.id,
            resumePosition: candidate,
            isCompleted: completed,
            playbackRate: playbackRate,
            playerVolume: playerVolume,
            isMuted: isMuted,
            seekStep: seekStep
        )
        do {
            try await playlistStore.savePlaybackSnapshot(snapshot)
            lastPersistedPosition = candidate
            lastProgressSaveTime = timeSource.now
            applySnapshotLocally(snapshot)
            if case .failed = persistenceNotice {
                persistenceNotice = .none
            }
            return true
        } catch let error as PlaylistStoreError {
            if case let .unavailable(message) = error {
                persistenceNotice = .failed(message)
            }
            return false
        } catch {
            persistenceNotice = .failed(error.localizedDescription)
            return false
        }
    }

    private func applySnapshotLocally(_ snapshot: PlaybackPersistenceSnapshot) {
        playlists = PlaylistLibrary(
            playlists: playlists,
            activePlaylistID: activePlaylistID,
            playerVolume: playerVolume,
            isMuted: isMuted,
            seekStep: seekStep
        ).applying(snapshot).playlists
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
        guard let actualIdentity = languageIdentity(actual),
              let expectedIdentity = languageIdentity(expected) else {
            return normalizedLanguage(actual) == normalizedLanguage(expected)
        }
        guard actualIdentity.languageCode == expectedIdentity.languageCode else {
            return false
        }
        if let actualScript = actualIdentity.scriptCode,
           let expectedScript = expectedIdentity.scriptCode {
            return actualScript == expectedScript
        }
        return true
    }

    private func language(_ actual: String?, matchesAny expected: [String]) -> Bool {
        expected.contains { language(actual, matches: $0) }
    }

    private func normalizedLanguage(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func languageIdentity(_ value: String) -> (
        languageCode: String,
        scriptCode: String?
    )? {
        let normalized = normalizedLanguage(value)
        let components = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = components.first, !primary.isEmpty else { return nil }
        let terminologyPrimary = Self.bibliographicLanguageAliases[String(primary)]
            ?? String(primary)
        let identifier = ([terminologyPrimary] + components.dropFirst().map(String.init))
            .joined(separator: "-")
        let language = Locale.Language(identifier: identifier)
        guard let languageCode = language.languageCode?.identifier.lowercased() else {
            return nil
        }
        return (
            languageCode: languageCode,
            scriptCode: language.script?.identifier.lowercased()
        )
    }

    private static let bibliographicLanguageAliases = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya",
        "chi": "zho", "cze": "ces", "dut": "nld", "fre": "fra",
        "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd",
        "mao": "mri", "may": "msa", "per": "fas", "rum": "ron",
        "slo": "slk", "tib": "bod", "wel": "cym",
    ]

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
            isCompleted: entry.isCompleted,
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
                isCompleted: persistentEntry.isCompleted,
                playbackPreferences: updatedPreferences
            )
            playlists[playlistIndex] = playlist.replacingEntries(
                persistentEntries,
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
            playlist.replacingEntries(
                playlist.entries.map { entry in
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
            isCompleted: entry.isCompleted,
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
            isCompleted: entry.isCompleted,
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

    private func appendMedia(
        _ mediaItems: [LocalMedia],
        refreshing refreshedMediaItems: [LocalMedia] = [],
        to playlistID: PlaylistID
    ) async throws -> [PlaylistEntry] {
        guard !mediaItems.isEmpty || !refreshedMediaItems.isEmpty else { return [] }
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistPersistenceError.playlistNotFound(playlistID)
        }
        var referenceIndex = LocalMediaReferenceIndex(
            references: playlists.lazy.flatMap(\.entries).map(\.media)
        )
        var refreshedReferencesByID: [LocalMediaReferenceID: PersistentLocalMediaReference] = [:]
        func refreshedReference(for media: LocalMedia) throws -> PersistentLocalMediaReference {
            guard let bookmark = media.bookmark else {
                persistenceNotice = .failed("无法持久保存 \(media.url.lastPathComponent) 的只读访问权限")
                throw PlaylistPersistenceError.missingBookmark(media.url.path)
            }
            let sharedReference = referenceIndex.reference(matching: media)
            let reference = PersistentLocalMediaReference(
                id: sharedReference?.id ?? media.referenceID,
                bookmark: bookmark,
                lastKnownPath: media.url.path,
                fileIdentity: media.fileIdentity ?? sharedReference?.fileIdentity
            )
            referenceIndex.insert(reference)
            refreshedReferencesByID[reference.id] = reference
            return reference
        }
        for media in refreshedMediaItems {
            _ = try refreshedReference(for: media)
        }
        var entries = try mediaItems.map { media in
            PlaylistEntry(media: try refreshedReference(for: media))
        }
        entries = entries.map { entry in
            PlaylistEntry(
                id: entry.id,
                media: refreshedReferencesByID[entry.media.id] ?? entry.media
            )
        }
        var updatedPlaylists = playlists.map { playlist in
            playlist.replacingEntries(
                playlist.entries.map { entry in
                    guard let reference = refreshedReferencesByID[entry.media.id] else {
                        return entry
                    }
                    return PlaylistEntry(
                        id: entry.id,
                        media: reference,
                        resumePosition: entry.resumePosition,
                        isCompleted: entry.isCompleted,
                        playbackPreferences: entry.playbackPreferences
                    )
                },
                currentEntryID: playlist.currentEntryID
            )
        }
        let playlist = updatedPlaylists[playlistIndex]
        var updatedPlaylist = playlist.replacingEntries(
            playlist.entries + entries,
            currentEntryID: playlist.currentEntryID
        )
        if var round = playlist.randomRound {
            for entry in entries {
                round = round.addingUnplayed(entry.id)
            }
            updatedPlaylist = updatedPlaylist.replacingRandomRound(round)
        }
        updatedPlaylists[playlistIndex] = updatedPlaylist
        try await commit(updatedPlaylists, activePlaylistID: activePlaylistID)
        let refreshedNowPlayingEntries = nowPlayingList.entries.map { nowPlayingEntry in
            guard let reference = refreshedReferencesByID[nowPlayingEntry.media.referenceID]
            else {
                return nowPlayingEntry
            }
            return NowPlayingEntry(
                id: nowPlayingEntry.id,
                media: localMedia(for: reference),
                resumePosition: nowPlayingEntry.resumePosition,
                isCompleted: nowPlayingEntry.isCompleted,
                playbackPreferences: nowPlayingEntry.playbackPreferences
            )
        }
        let appendedNowPlayingEntries = activePlaylistID == playlistID
            ? entries.map {
                    NowPlayingEntry(id: $0.id, media: localMedia(for: $0.media))
                }
            : []
        nowPlayingList = NowPlayingList(
            entries: refreshedNowPlayingEntries + appendedNowPlayingEntries,
            currentIndex: nowPlayingList.currentIndex
        )
        browsingPlaylistID = playlistID
        return entries
    }

    private func localMedia(for reference: PersistentLocalMediaReference) -> LocalMedia {
        LocalMedia(
            url: URL(fileURLWithPath: reference.lastKnownPath),
            referenceID: reference.id,
            bookmark: reference.bookmark,
            fileIdentity: reference.fileIdentity
        )
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
            activePlaylistID: activePlaylistID,
            playerVolume: playerVolume,
            isMuted: isMuted,
            seekStep: seekStep
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
