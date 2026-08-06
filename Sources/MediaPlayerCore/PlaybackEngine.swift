import Foundation

public struct LocalMedia: Equatable, Sendable {
    public let url: URL
    public let referenceID: LocalMediaReferenceID
    public let bookmark: Data?
    public let fileIdentity: LocalFileIdentity?
    public let availability: LocalMediaAvailability

    public init(
        url: URL,
        referenceID: LocalMediaReferenceID = LocalMediaReferenceID(),
        bookmark: Data? = nil,
        fileIdentity: LocalFileIdentity? = nil,
        availability: LocalMediaAvailability = .available
    ) {
        self.url = url
        self.referenceID = referenceID
        self.bookmark = bookmark
        self.fileIdentity = fileIdentity
        self.availability = availability
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case failed(PlaybackFailure)
}

public enum PlaybackFailure: Equatable, Sendable {
    case unreadable
    case unsupported
    case corrupted
    case decoderInitializationFailed
    case engineUnavailable
}

public enum PlaybackFailureRecoveryAction: Equatable, Sendable {
    case retry
    case revealInFinder
    case removeEntryFromList
    case skip
}

public struct PlaybackFailureRecovery: Equatable, Sendable {
    public let failure: PlaybackFailure
    public let entryID: PlaylistEntryID
    public let mediaURL: URL
    public let actions: [PlaybackFailureRecoveryAction]

    public init(
        failure: PlaybackFailure,
        entryID: PlaylistEntryID,
        mediaURL: URL,
        actions: [PlaybackFailureRecoveryAction]
    ) {
        self.failure = failure
        self.entryID = entryID
        self.mediaURL = mediaURL
        self.actions = actions
    }
}

public enum PlaybackFailureNotice: Equatable, Sendable {
    case none
    case recovery(PlaybackFailureRecovery)
    case exhausted([PlaybackFailureRecovery])
}

public enum PlaybackQualityNotice: Equatable, Sendable {
    case none
    case softwareDecodingFallback
    case softwareDecodingFallbackFor4K
    case softwareDecodingFallbackRequiresFullQualityGate
}

public struct PlaybackLoadID: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct PlaybackSettings: Equatable, Sendable {
    public let rate: Double
    public let volume: Double
    public let isMuted: Bool

    public init(rate: Double, volume: Double, isMuted: Bool) {
        self.rate = rate
        self.volume = volume
        self.isMuted = isMuted
    }
}

public struct AudioTrackID: Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct EmbeddedSubtitleTrackID: Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TrackPreference: Equatable, Codable, Sendable {
    public let languageCode: String?
    public let title: String?
    public let ordinal: Int

    public init(languageCode: String?, title: String?, ordinal: Int) {
        self.languageCode = languageCode
        self.title = title
        self.ordinal = ordinal
    }
}

public struct AudioTrackOption: Equatable, Identifiable, Sendable {
    public let id: AudioTrackID
    public let languageCode: String?
    public let title: String?
    public let ordinal: Int
    public let isDefault: Bool

    public var preference: TrackPreference {
        TrackPreference(languageCode: languageCode, title: title, ordinal: ordinal)
    }

    public var displayName: String {
        title ?? languageCode ?? "音轨 \(ordinal)"
    }

    public init(
        id: AudioTrackID,
        languageCode: String?,
        title: String?,
        ordinal: Int,
        isDefault: Bool
    ) {
        self.id = id
        self.languageCode = languageCode
        self.title = title
        self.ordinal = ordinal
        self.isDefault = isDefault
    }
}

public struct EmbeddedSubtitleTrackOption: Equatable, Identifiable, Sendable {
    public let id: EmbeddedSubtitleTrackID
    public let languageCode: String?
    public let title: String?
    public let ordinal: Int
    public let isDefault: Bool
    public let isForced: Bool

    public var preference: TrackPreference {
        TrackPreference(languageCode: languageCode, title: title, ordinal: ordinal)
    }

    public var displayName: String {
        title ?? languageCode ?? "字幕 \(ordinal)"
    }

    public init(
        id: EmbeddedSubtitleTrackID,
        languageCode: String?,
        title: String?,
        ordinal: Int,
        isDefault: Bool,
        isForced: Bool
    ) {
        self.id = id
        self.languageCode = languageCode
        self.title = title
        self.ordinal = ordinal
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

public struct TrackCatalog: Equatable, Sendable {
    public let audioTracks: [AudioTrackOption]
    public let embeddedSubtitleTracks: [EmbeddedSubtitleTrackOption]

    public init(
        audioTracks: [AudioTrackOption],
        embeddedSubtitleTracks: [EmbeddedSubtitleTrackOption]
    ) {
        self.audioTracks = audioTracks
        self.embeddedSubtitleTracks = embeddedSubtitleTracks
    }
}

public enum PlaybackMediaKind: Equatable, Sendable {
    case audio
    case video
}

public struct VideoDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
    }
}

public struct PlaybackMediaPresentation: Equatable, Sendable {
    public let kind: PlaybackMediaKind
    public let title: String
    public let artist: String?
    public let album: String?
    public let hasArtwork: Bool
    public let videoDimensions: VideoDimensions?

    public init(
        kind: PlaybackMediaKind,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        hasArtwork: Bool = false,
        videoDimensions: VideoDimensions? = nil
    ) {
        self.kind = kind
        self.title = title
        self.artist = artist
        self.album = album
        self.hasArtwork = hasArtwork
        self.videoDimensions = videoDimensions
    }
}

public enum SubtitleSelection: Equatable, Sendable {
    case off
    case embedded(EmbeddedSubtitleTrackID)
}

public enum ExternalSubtitleLoadResult: Equatable, Sendable {
    case loaded
    case missing
    case damaged
}

public enum PlaybackEngineEvent: Equatable, Sendable {
    case playbackStateChanged(PlaybackState, loadID: PlaybackLoadID)
    case timelineChanged(position: TimeInterval, duration: TimeInterval, loadID: PlaybackLoadID)
    case settingsChanged(PlaybackSettings, loadID: PlaybackLoadID)
    case playbackEnded(loadID: PlaybackLoadID)
    case trackCatalogChanged(TrackCatalog, loadID: PlaybackLoadID)
    case mediaPresentationChanged(PlaybackMediaPresentation, loadID: PlaybackLoadID)
}

public protocol PlaybackEngine: Sendable {
    var events: AsyncStream<PlaybackEngineEvent> { get }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) async
    func loadUsingSoftwareDecoding(_ media: LocalMedia, loadID: PlaybackLoadID) async
    func play() async
    func pause() async
    func stop() async
    func seek(to position: TimeInterval) async
    func setPlaybackRate(_ rate: Double) async
    func setPlayerVolume(_ volume: Double) async
    func setMuted(_ isMuted: Bool) async
    func selectAudioTrack(_ id: AudioTrackID) async -> Bool
    func selectSubtitle(_ selection: SubtitleSelection) async -> Bool
    func loadExternalSubtitle(_ subtitle: LocalExternalSubtitle) async -> ExternalSubtitleLoadResult
}

public extension PlaybackEngine {
    func loadUsingSoftwareDecoding(_ media: LocalMedia, loadID: PlaybackLoadID) async {
        await load(media, loadID: loadID)
    }

    func selectAudioTrack(_ id: AudioTrackID) async -> Bool { false }
    func selectSubtitle(_ selection: SubtitleSelection) async -> Bool { false }
    func loadExternalSubtitle(_ subtitle: LocalExternalSubtitle) async -> ExternalSubtitleLoadResult {
        .damaged
    }
}
