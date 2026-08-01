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

public struct ExternalSubtitleReferenceID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PersistentExternalSubtitleReference: Equatable, Codable, Sendable {
    public let id: ExternalSubtitleReferenceID
    public let bookmark: Data
    public let lastKnownPath: String

    public init(
        id: ExternalSubtitleReferenceID,
        bookmark: Data,
        lastKnownPath: String
    ) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
    }
}

public struct LocalExternalSubtitle: Equatable, Sendable {
    public let url: URL
    public let referenceID: ExternalSubtitleReferenceID
    public let bookmark: Data?

    public init(
        url: URL,
        referenceID: ExternalSubtitleReferenceID = ExternalSubtitleReferenceID(),
        bookmark: Data? = nil
    ) {
        self.url = url
        self.referenceID = referenceID
        self.bookmark = bookmark
    }
}

public enum SubtitlePreference: Equatable, Codable, Sendable {
    case off
    case embedded(TrackPreference)
    case external(PersistentExternalSubtitleReference)
}

public struct EntryPlaybackPreferences: Equatable, Codable, Sendable {
    public let audioTrack: TrackPreference?
    public let subtitle: SubtitlePreference

    public init(
        audioTrack: TrackPreference? = nil,
        subtitle: SubtitlePreference = .off
    ) {
        self.audioTrack = audioTrack
        self.subtitle = subtitle
    }

    private enum CodingKeys: String, CodingKey {
        case audioTrack
        case subtitle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioTrack = try container.decodeIfPresent(TrackPreference.self, forKey: .audioTrack)
        subtitle = try container.decodeIfPresent(SubtitlePreference.self, forKey: .subtitle) ?? .off
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
}

public protocol PersistentMediaAccess: Sendable {
    func restore(_ reference: PersistentLocalMediaReference) async throws -> LocalMedia
}

public protocol PersistentExternalSubtitleAccess: Sendable {
    func restore(
        _ reference: PersistentExternalSubtitleReference
    ) async throws -> LocalExternalSubtitle
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

public enum ExternalSubtitleAccessError: Error, Equatable, Sendable {
    case missing(String)
}

public struct LastKnownPathExternalSubtitleAccess: PersistentExternalSubtitleAccess {
    public init() {}

    public func restore(
        _ reference: PersistentExternalSubtitleReference
    ) throws -> LocalExternalSubtitle {
        guard FileManager.default.isReadableFile(atPath: reference.lastKnownPath) else {
            throw ExternalSubtitleAccessError.missing(reference.lastKnownPath)
        }
        return LocalExternalSubtitle(
            url: URL(fileURLWithPath: reference.lastKnownPath),
            referenceID: reference.id,
            bookmark: reference.bookmark
        )
    }
}
