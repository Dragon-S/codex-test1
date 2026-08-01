import Foundation

public struct PlaylistID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PlaylistEntryID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct LocalMediaReferenceID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct EntryPlaybackPreferences: Equatable, Codable, Sendable {
    public let audioTrackID: String?
    public let embeddedSubtitleTrackID: String?
    public let externalSubtitleReferenceID: LocalMediaReferenceID?

    public init(
        audioTrackID: String? = nil,
        embeddedSubtitleTrackID: String? = nil,
        externalSubtitleReferenceID: LocalMediaReferenceID? = nil
    ) {
        self.audioTrackID = audioTrackID
        self.embeddedSubtitleTrackID = embeddedSubtitleTrackID
        self.externalSubtitleReferenceID = externalSubtitleReferenceID
    }
}

public struct PersistentLocalMediaReference: Equatable, Codable, Sendable {
    public let id: LocalMediaReferenceID
    public let bookmark: Data
    public let lastKnownPath: String

    public init(id: LocalMediaReferenceID, bookmark: Data, lastKnownPath: String) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
    }
}

public struct PlaylistEntry: Equatable, Codable, Sendable, Identifiable {
    public let id: PlaylistEntryID
    public let media: PersistentLocalMediaReference
    public let resumePosition: TimeInterval?
    public let isCompleted: Bool
    public let playbackPreferences: EntryPlaybackPreferences

    public init(
        id: PlaylistEntryID = PlaylistEntryID(),
        media: PersistentLocalMediaReference,
        resumePosition: TimeInterval? = nil,
        isCompleted: Bool = false,
        playbackPreferences: EntryPlaybackPreferences = EntryPlaybackPreferences()
    ) {
        self.id = id
        self.media = media
        self.resumePosition = resumePosition
        self.isCompleted = isCompleted
        self.playbackPreferences = playbackPreferences
    }
}

public struct Playlist: Equatable, Codable, Sendable, Identifiable {
    public let id: PlaylistID
    public let name: String
    public let entries: [PlaylistEntry]
    public let currentEntryID: PlaylistEntryID?
    public let playbackRate: Double

    public init(
        id: PlaylistID = PlaylistID(),
        name: String,
        entries: [PlaylistEntry],
        currentEntryID: PlaylistEntryID? = nil,
        playbackRate: Double = 1
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.currentEntryID = currentEntryID
        self.playbackRate = playbackRate
    }
}

public struct PlaylistLibrary: Equatable, Codable, Sendable {
    public let playlists: [Playlist]
    public let activePlaylistID: PlaylistID?
    public let playerVolume: Double
    public let isMuted: Bool
    public let seekStep: TimeInterval

    public init(
        playlists: [Playlist] = [],
        activePlaylistID: PlaylistID? = nil,
        playerVolume: Double = 1,
        isMuted: Bool = false,
        seekStep: TimeInterval = 10
    ) {
        self.playlists = playlists
        self.activePlaylistID = activePlaylistID
        self.playerVolume = playerVolume
        self.isMuted = isMuted
        self.seekStep = seekStep
    }
}

public struct NowPlayingEntry: Equatable, Sendable, Identifiable {
    public let id: PlaylistEntryID
    public let media: LocalMedia
    public let resumePosition: TimeInterval?
    public let isCompleted: Bool
    public let playbackPreferences: EntryPlaybackPreferences

    public init(
        id: PlaylistEntryID = PlaylistEntryID(),
        media: LocalMedia,
        resumePosition: TimeInterval? = nil,
        isCompleted: Bool = false,
        playbackPreferences: EntryPlaybackPreferences = EntryPlaybackPreferences()
    ) {
        self.id = id
        self.media = media
        self.resumePosition = resumePosition
        self.isCompleted = isCompleted
        self.playbackPreferences = playbackPreferences
    }
}

public struct PlaybackPersistenceSnapshot: Equatable, Sendable {
    public let playlistID: PlaylistID?
    public let entryID: PlaylistEntryID?
    public let resumePosition: TimeInterval?
    public let isCompleted: Bool
    public let playbackRate: Double
    public let playerVolume: Double
    public let isMuted: Bool
    public let seekStep: TimeInterval

    public init(
        playlistID: PlaylistID?,
        entryID: PlaylistEntryID?,
        resumePosition: TimeInterval?,
        isCompleted: Bool,
        playbackRate: Double,
        playerVolume: Double,
        isMuted: Bool,
        seekStep: TimeInterval = 10
    ) {
        self.playlistID = playlistID
        self.entryID = entryID
        self.resumePosition = resumePosition
        self.isCompleted = isCompleted
        self.playbackRate = playbackRate
        self.playerVolume = playerVolume
        self.isMuted = isMuted
        self.seekStep = seekStep
    }
}

extension PlaylistLibrary {
    func applying(_ snapshot: PlaybackPersistenceSnapshot) -> PlaylistLibrary {
        let updatedPlaylists = playlists.map { playlist in
            guard playlist.id == snapshot.playlistID else { return playlist }
            let updatedEntries = playlist.entries.map { entry in
                guard entry.id == snapshot.entryID else { return entry }
                return PlaylistEntry(
                    id: entry.id,
                    media: entry.media,
                    resumePosition: snapshot.resumePosition,
                    isCompleted: snapshot.isCompleted,
                    playbackPreferences: entry.playbackPreferences
                )
            }
            return Playlist(
                id: playlist.id,
                name: playlist.name,
                entries: updatedEntries,
                currentEntryID: snapshot.entryID ?? playlist.currentEntryID,
                playbackRate: snapshot.playbackRate
            )
        }
        return PlaylistLibrary(
            playlists: updatedPlaylists,
            activePlaylistID: activePlaylistID,
            playerVolume: snapshot.playerVolume,
            isMuted: snapshot.isMuted,
            seekStep: snapshot.seekStep
        )
    }
}

extension PlaylistEntry {
    enum CodingKeys: String, CodingKey {
        case id, media, resumePosition, isCompleted, playbackPreferences
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(PlaylistEntryID.self, forKey: .id),
            media: try values.decode(PersistentLocalMediaReference.self, forKey: .media),
            resumePosition: try values.decodeIfPresent(TimeInterval.self, forKey: .resumePosition),
            isCompleted: try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false,
            playbackPreferences: try values.decode(EntryPlaybackPreferences.self, forKey: .playbackPreferences)
        )
    }
}

extension Playlist {
    enum CodingKeys: String, CodingKey {
        case id, name, entries, currentEntryID, playbackRate
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(PlaylistID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            entries: try values.decode([PlaylistEntry].self, forKey: .entries),
            currentEntryID: try values.decodeIfPresent(PlaylistEntryID.self, forKey: .currentEntryID),
            playbackRate: try values.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        )
    }
}

extension PlaylistLibrary {
    enum CodingKeys: String, CodingKey {
        case playlists, activePlaylistID, playerVolume, isMuted, seekStep
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            playlists: try values.decode([Playlist].self, forKey: .playlists),
            activePlaylistID: try values.decodeIfPresent(PlaylistID.self, forKey: .activePlaylistID),
            playerVolume: try values.decodeIfPresent(Double.self, forKey: .playerVolume) ?? 1,
            isMuted: try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            seekStep: try values.decodeIfPresent(TimeInterval.self, forKey: .seekStep) ?? 10
        )
    }
}

public enum PlaylistPersistenceNotice: Equatable, Sendable {
    case none
    case saved(String)
    case nameAlreadyExists(String)
    case failed(String)
}

public enum PlaylistPersistenceError: Error, Equatable, Sendable {
    case emptyName
    case emptyNowPlayingList
    case missingBookmark(String)
}

public protocol PersistentMediaAccess: Sendable {
    func restore(_ reference: PersistentLocalMediaReference) async throws -> LocalMedia
}

public struct LastKnownPathMediaAccess: PersistentMediaAccess {
    public init() {}

    public func restore(_ reference: PersistentLocalMediaReference) -> LocalMedia {
        LocalMedia(
            url: URL(fileURLWithPath: reference.lastKnownPath),
            referenceID: reference.id,
            bookmark: reference.bookmark
        )
    }
}
