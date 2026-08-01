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
    public let playbackPreferences: EntryPlaybackPreferences

    public init(
        id: PlaylistEntryID = PlaylistEntryID(),
        media: PersistentLocalMediaReference,
        resumePosition: TimeInterval? = nil,
        playbackPreferences: EntryPlaybackPreferences = EntryPlaybackPreferences()
    ) {
        self.id = id
        self.media = media
        self.resumePosition = resumePosition
        self.playbackPreferences = playbackPreferences
    }
}

public struct Playlist: Equatable, Codable, Sendable, Identifiable {
    public let id: PlaylistID
    public let name: String
    public let entries: [PlaylistEntry]
    public let currentEntryID: PlaylistEntryID?

    public init(
        id: PlaylistID = PlaylistID(),
        name: String,
        entries: [PlaylistEntry],
        currentEntryID: PlaylistEntryID? = nil
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.currentEntryID = currentEntryID
    }
}

public struct PlaylistLibrary: Equatable, Codable, Sendable {
    public let playlists: [Playlist]
    public let activePlaylistID: PlaylistID?

    public init(playlists: [Playlist] = [], activePlaylistID: PlaylistID? = nil) {
        self.playlists = playlists
        self.activePlaylistID = activePlaylistID
    }
}

public struct NowPlayingEntry: Equatable, Sendable, Identifiable {
    public let id: PlaylistEntryID
    public let media: LocalMedia
    public let resumePosition: TimeInterval?
    public let playbackPreferences: EntryPlaybackPreferences

    public init(
        id: PlaylistEntryID = PlaylistEntryID(),
        media: LocalMedia,
        resumePosition: TimeInterval? = nil,
        playbackPreferences: EntryPlaybackPreferences = EntryPlaybackPreferences()
    ) {
        self.id = id
        self.media = media
        self.resumePosition = resumePosition
        self.playbackPreferences = playbackPreferences
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
    case playlistNotFound(PlaylistID)
    case entryNotFound(PlaylistEntryID)
    case deletionConfirmationRequired(PlaylistID)
    case invalidDestination(Int)
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
