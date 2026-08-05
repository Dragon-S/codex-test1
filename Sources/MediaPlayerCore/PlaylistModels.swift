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

public struct LocalFileIdentity: Hashable, Codable, Sendable {
    public let rawValue: Data

    public init(rawValue: Data) {
        self.rawValue = rawValue
    }
}

public enum LocalMediaAvailability: String, Equatable, Codable, Sendable {
    case available
    case missing
}

public enum MVPSelectableMediaFormats {
    private enum ContainerSignature {
        case isoBaseMedia
        case ebml
        case mp3
        case adts
        case alac
        case flac
        case wave
        case ogg
    }

    private static let formats: [(filenameExtension: String, signature: ContainerSignature)] = [
        ("mp4", .isoBaseMedia),
        ("mov", .isoBaseMedia),
        ("mkv", .ebml),
        ("webm", .ebml),
        ("mp3", .mp3),
        ("m4a", .isoBaseMedia),
        ("aac", .adts),
        ("alac", .alac),
        ("flac", .flac),
        ("wav", .wave),
        ("ogg", .ogg),
        ("opus", .ogg),
    ]

    public static let filenameExtensions = formats.map(\.filenameExtension)

    public static func allows(filenameExtension: String) -> Bool {
        formats.contains { $0.filenameExtension == filenameExtension.lowercased() }
    }

    static func matchesContainerSignature(
        _ header: Data,
        filenameExtension: String
    ) -> Bool {
        guard let signature = formats.first(where: {
            $0.filenameExtension == filenameExtension.lowercased()
        })?.signature else {
            return false
        }
        switch signature {
        case .isoBaseMedia:
            guard header.count >= 8 else { return false }
            let atomType = Data(header[4..<8])
            return ["ftyp", "moov", "mdat", "wide", "free", "skip"]
                .map { Data($0.utf8) }
                .contains(atomType)
        case .ebml:
            return header.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
        case .mp3:
            return header.starts(with: Data("ID3".utf8)) || hasMPEGAudioFrameSync(header)
        case .adts:
            return hasADTSFrameSync(header)
        case .alac:
            return header.starts(with: Data("caff".utf8))
                || (header.count >= 8 && Data(header[4..<8]) == Data("ftyp".utf8))
        case .flac:
            return header.starts(with: Data("fLaC".utf8))
        case .wave:
            return header.count >= 12
                && header.starts(with: Data("RIFF".utf8))
                && Data(header[8..<12]) == Data("WAVE".utf8)
        case .ogg:
            return header.starts(with: Data("OggS".utf8))
        }
    }

    private static func hasMPEGAudioFrameSync(_ header: Data) -> Bool {
        guard header.count >= 2, header[header.startIndex] == 0xFF else { return false }
        let secondByte = header[header.index(after: header.startIndex)]
        return secondByte & 0xE0 == 0xE0 && secondByte & 0x06 != 0
    }

    private static func hasADTSFrameSync(_ header: Data) -> Bool {
        guard header.count >= 2, header[header.startIndex] == 0xFF else { return false }
        let secondByte = header[header.index(after: header.startIndex)]
        return secondByte & 0xF6 == 0xF0
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
    public let bookmark: Data?

    public init(
        url: URL,
        bookmark: Data? = nil
    ) {
        self.url = url
        self.bookmark = bookmark
    }
}

public enum SubtitlePreference: Equatable, Codable, Sendable {
    case automatic
    case off
    case embedded(TrackPreference)
    case external(PersistentExternalSubtitleReference)
}

public struct EntryPlaybackPreferences: Equatable, Codable, Sendable {
    public let audioTrack: TrackPreference?
    public let subtitle: SubtitlePreference

    public init(
        audioTrack: TrackPreference? = nil,
        subtitle: SubtitlePreference = .automatic
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
        subtitle = try container.decodeIfPresent(SubtitlePreference.self, forKey: .subtitle)
            ?? .automatic
    }
}

public struct PersistentLocalMediaReference: Equatable, Codable, Sendable {
    public let id: LocalMediaReferenceID
    public let bookmark: Data
    public let lastKnownPath: String
    public let fileIdentity: LocalFileIdentity?
    public let availability: LocalMediaAvailability

    public init(
        id: LocalMediaReferenceID,
        bookmark: Data,
        lastKnownPath: String,
        fileIdentity: LocalFileIdentity? = nil,
        availability: LocalMediaAvailability = .available
    ) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.fileIdentity = fileIdentity
        self.availability = availability
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookmark, lastKnownPath, fileIdentity, availability
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(LocalMediaReferenceID.self, forKey: .id),
            bookmark: try values.decode(Data.self, forKey: .bookmark),
            lastKnownPath: try values.decode(String.self, forKey: .lastKnownPath),
            fileIdentity: try values.decodeIfPresent(LocalFileIdentity.self, forKey: .fileIdentity),
            availability: try values.decodeIfPresent(
                LocalMediaAvailability.self,
                forKey: .availability
            ) ?? .available
        )
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

public enum PlaybackOrder: String, Equatable, Codable, Sendable {
    case sequential
    case random
}

public enum PlaylistRepeatMode: String, Equatable, Codable, Sendable {
    case none
    case playlist
    case entry
}

public struct RandomPlaybackRound: Equatable, Codable, Sendable {
    public let order: [PlaylistEntryID]
    public let playedEntryIDs: [PlaylistEntryID]
    public let unavailableEntryIDs: [PlaylistEntryID]

    public init(
        order: [PlaylistEntryID],
        playedEntryIDs: [PlaylistEntryID] = [],
        unavailableEntryIDs: [PlaylistEntryID] = []
    ) {
        self.order = order
        self.playedEntryIDs = playedEntryIDs
        self.unavailableEntryIDs = unavailableEntryIDs
    }

    func addingUnplayed(_ entryID: PlaylistEntryID) -> RandomPlaybackRound {
        guard !order.contains(entryID) else { return self }
        return RandomPlaybackRound(
            order: order + [entryID],
            playedEntryIDs: playedEntryIDs,
            unavailableEntryIDs: unavailableEntryIDs
        )
    }

    func removing(_ entryID: PlaylistEntryID) -> RandomPlaybackRound {
        RandomPlaybackRound(
            order: order.filter { $0 != entryID },
            playedEntryIDs: playedEntryIDs.filter { $0 != entryID },
            unavailableEntryIDs: unavailableEntryIDs.filter { $0 != entryID }
        )
    }

    func recording(_ entryID: PlaylistEntryID) -> RandomPlaybackRound {
        let updatedOrder = order.contains(entryID) ? order : order + [entryID]
        let updatedHistory = playedEntryIDs.contains(entryID)
            ? playedEntryIDs
            : playedEntryIDs + [entryID]
        return RandomPlaybackRound(
            order: updatedOrder,
            playedEntryIDs: updatedHistory,
            unavailableEntryIDs: unavailableEntryIDs.filter { $0 != entryID }
        )
    }

    func markingUnavailable(_ entryID: PlaylistEntryID) -> RandomPlaybackRound {
        RandomPlaybackRound(
            order: order,
            playedEntryIDs: playedEntryIDs.filter { $0 != entryID },
            unavailableEntryIDs: unavailableEntryIDs.contains(entryID)
                ? unavailableEntryIDs
                : unavailableEntryIDs + [entryID]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case order, playedEntryIDs, unavailableEntryIDs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            order: try values.decode([PlaylistEntryID].self, forKey: .order),
            playedEntryIDs: try values.decodeIfPresent(
                [PlaylistEntryID].self,
                forKey: .playedEntryIDs
            ) ?? [],
            unavailableEntryIDs: try values.decodeIfPresent(
                [PlaylistEntryID].self,
                forKey: .unavailableEntryIDs
            ) ?? []
        )
    }
}

public struct Playlist: Equatable, Codable, Sendable, Identifiable {
    public let id: PlaylistID
    public let name: String
    public let entries: [PlaylistEntry]
    public let currentEntryID: PlaylistEntryID?
    public let playbackRate: Double
    public let playbackOrder: PlaybackOrder
    public let repeatMode: PlaylistRepeatMode
    public let randomRound: RandomPlaybackRound?

    public init(
        id: PlaylistID = PlaylistID(),
        name: String,
        entries: [PlaylistEntry],
        currentEntryID: PlaylistEntryID? = nil,
        playbackRate: Double = 1,
        playbackOrder: PlaybackOrder = .sequential,
        repeatMode: PlaylistRepeatMode = .none,
        randomRound: RandomPlaybackRound? = nil
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.currentEntryID = currentEntryID
        self.playbackRate = playbackRate
        self.playbackOrder = playbackOrder
        self.repeatMode = repeatMode
        self.randomRound = randomRound
    }

    func renamed(to name: String) -> Playlist {
        Playlist(
            id: id,
            name: name,
            entries: entries,
            currentEntryID: currentEntryID,
            playbackRate: playbackRate,
            playbackOrder: playbackOrder,
            repeatMode: repeatMode,
            randomRound: randomRound
        )
    }

    func replacingEntries(
        _ entries: [PlaylistEntry],
        currentEntryID: PlaylistEntryID?
    ) -> Playlist {
        Playlist(
            id: id,
            name: name,
            entries: entries,
            currentEntryID: currentEntryID,
            playbackRate: playbackRate,
            playbackOrder: playbackOrder,
            repeatMode: repeatMode,
            randomRound: randomRound
        )
    }

    func replacingPlaybackPolicy(
        order: PlaybackOrder,
        repeatMode: PlaylistRepeatMode,
        randomRound: RandomPlaybackRound? = nil
    ) -> Playlist {
        Playlist(
            id: id,
            name: name,
            entries: entries,
            currentEntryID: currentEntryID,
            playbackRate: playbackRate,
            playbackOrder: order,
            repeatMode: repeatMode,
            randomRound: randomRound
        )
    }

    func replacingProgression(
        currentEntryID: PlaylistEntryID?,
        randomRound: RandomPlaybackRound?
    ) -> Playlist {
        Playlist(
            id: id,
            name: name,
            entries: entries,
            currentEntryID: currentEntryID,
            playbackRate: playbackRate,
            playbackOrder: playbackOrder,
            repeatMode: repeatMode,
            randomRound: randomRound
        )
    }

    func replacingRandomRound(_ randomRound: RandomPlaybackRound?) -> Playlist {
        Playlist(
            id: id,
            name: name,
            entries: entries,
            currentEntryID: currentEntryID,
            playbackRate: playbackRate,
            playbackOrder: playbackOrder,
            repeatMode: repeatMode,
            randomRound: randomRound
        )
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

    public var isMediaMissing: Bool { media.availability == .missing }

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
                playbackRate: snapshot.playbackRate,
                playbackOrder: playlist.playbackOrder,
                repeatMode: playlist.repeatMode,
                randomRound: playlist.randomRound
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
        case playbackOrder, repeatMode, randomRound
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(PlaylistID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            entries: try values.decode([PlaylistEntry].self, forKey: .entries),
            currentEntryID: try values.decodeIfPresent(PlaylistEntryID.self, forKey: .currentEntryID),
            playbackRate: try values.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1,
            playbackOrder: try values.decodeIfPresent(PlaybackOrder.self, forKey: .playbackOrder)
                ?? .sequential,
            repeatMode: try values.decodeIfPresent(PlaylistRepeatMode.self, forKey: .repeatMode)
                ?? .none,
            randomRound: try values.decodeIfPresent(RandomPlaybackRound.self, forKey: .randomRound)
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
    case playlistNotFound(PlaylistID)
    case entryNotFound(PlaylistEntryID)
    case mediaReferenceNotFound(LocalMediaReferenceID)
    case deletionConfirmationRequired(PlaylistID)
    case invalidDestination(Int)
}

public struct MediaReplacementImpact: Equatable, Sendable {
    public let referenceID: LocalMediaReferenceID
    public let affectedEntryCount: Int
    public let affectedPlaylistCount: Int

    public init(
        referenceID: LocalMediaReferenceID,
        affectedEntryCount: Int,
        affectedPlaylistCount: Int
    ) {
        self.referenceID = referenceID
        self.affectedEntryCount = affectedEntryCount
        self.affectedPlaylistCount = affectedPlaylistCount
    }
}

public enum MediaRelocationResult: Equatable, Sendable {
    case relocated
    case confirmationRequired(MediaReplacementImpact)
}

public protocol PersistentMediaAccess: Sendable {
    func restore(_ reference: PersistentLocalMediaReference) async throws -> LocalMedia
}

public enum PersistentMediaAccessError: Error, Equatable, Sendable {
    case missing(String)
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
            bookmark: reference.bookmark,
            fileIdentity: reference.fileIdentity,
            availability: reference.availability
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
            bookmark: reference.bookmark
        )
    }
}
