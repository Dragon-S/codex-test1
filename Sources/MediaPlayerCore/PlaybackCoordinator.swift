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

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var nowPlayingList = NowPlayingList()
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var activePlaylistID: PlaylistID?
    @Published public private(set) var browsingPlaylistID: PlaylistID?
    @Published public private(set) var detachedNowPlayingEntry: NowPlayingEntry?
    @Published public private(set) var persistenceNotice: PlaylistPersistenceNotice = .none

    private let engine: any PlaybackEngine
    private let playlistStore: any PlaylistStore
    private let persistentMediaAccess: any PersistentMediaAccess
    private var eventTask: Task<Void, Never>?
    private var isFindingFirstPlayableMedia = false
    private var isRestoredMediaPendingLoad = false
    private var activeLoadID: PlaybackLoadID?
    private var nextLoadID: UInt64 = 0
    private var detachedSuccessorEntryIDs: [PlaylistEntryID] = []

    public init(
        engine: any PlaybackEngine,
        playlistStore: any PlaylistStore = InMemoryPlaylistStore(),
        persistentMediaAccess: any PersistentMediaAccess = LastKnownPathMediaAccess()
    ) {
        self.engine = engine
        self.playlistStore = playlistStore
        self.persistentMediaAccess = persistentMediaAccess
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
                if let fileIdentity = media.fileIdentity {
                    return reference.fileIdentity == fileIdentity
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
        }
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
