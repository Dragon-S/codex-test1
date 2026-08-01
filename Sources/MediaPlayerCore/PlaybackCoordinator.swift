import Combine
import Foundation

public protocol PlaybackTimeSource: Sendable {
    var now: TimeInterval { get }
}

public struct SystemPlaybackTimeSource: PlaybackTimeSource {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
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

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var nowPlayingList = NowPlayingList()
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var activePlaylistID: PlaylistID?
    @Published public private(set) var persistenceNotice: PlaylistPersistenceNotice = .none
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var playbackRate: Double = 1
    @Published public private(set) var playerVolume: Double = 1
    @Published public private(set) var isMuted = false
    @Published public private(set) var seekStep: TimeInterval

    private let engine: any PlaybackEngine
    private let playlistStore: any PlaylistStore
    private let persistentMediaAccess: any PersistentMediaAccess
    private let timeSource: any PlaybackTimeSource
    private var eventTask: Task<Void, Never>?
    private var isFindingFirstPlayableMedia = false
    private var isRestoredMediaPendingLoad = false
    private var activeLoadID: PlaybackLoadID?
    private var nextLoadID: UInt64 = 0
    private var lastPersistedPosition: TimeInterval?
    private var lastProgressSaveTime: TimeInterval
    private var lastConfirmedPosition: TimeInterval = 0
    private var pendingSeekTarget: TimeInterval?

    public init(
        engine: any PlaybackEngine,
        playlistStore: any PlaylistStore = InMemoryPlaylistStore(),
        persistentMediaAccess: any PersistentMediaAccess = LastKnownPathMediaAccess(),
        seekStep: TimeInterval = 10,
        timeSource: any PlaybackTimeSource = SystemPlaybackTimeSource()
    ) {
        self.engine = engine
        self.playlistStore = playlistStore
        self.persistentMediaAccess = persistentMediaAccess
        self.seekStep = max(1, seekStep)
        self.timeSource = timeSource
        lastProgressSaveTime = timeSource.now
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
        persistenceNotice = .none
        isRestoredMediaPendingLoad = false
        isFindingFirstPlayableMedia = true
        resetTimeline(for: first)
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
            guard let activeID = library.activePlaylistID,
                  let activePlaylist = library.playlists.first(where: { $0.id == activeID }) else {
                return
            }
            playbackRate = activePlaylist.playbackRate
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
                    isCompleted: entry.isCompleted,
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

    public func next() async {
        isFindingFirstPlayableMedia = false
        await persistCurrentState(force: true)
        await move(by: 1)
    }

    public func previous() async {
        isFindingFirstPlayableMedia = false
        await persistCurrentState(force: true)
        await move(by: -1)
    }

    private func move(by offset: Int) async {
        guard let destination = nowPlayingList.moving(by: offset),
              let media = destination.currentMedia else {
            await engine.stop()
            return
        }
        nowPlayingList = destination
        if let entry = currentEntry {
            resetTimeline(for: entry)
        }
        await load(media)
        await persistCurrentState(force: true)
    }

    private func load(_ media: LocalMedia) async {
        nextLoadID &+= 1
        let loadID = PlaybackLoadID(rawValue: nextLoadID)
        activeLoadID = loadID
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
            isFindingFirstPlayableMedia = false
            updateCurrentEntryProgress(resumePosition: nil, isCompleted: true)
            await persistCurrentState(force: true)
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

    private var currentEntry: NowPlayingEntry? {
        guard let index = nowPlayingList.currentIndex,
              nowPlayingList.entries.indices.contains(index) else { return nil }
        return nowPlayingList.entries[index]
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
}
