import Foundation

public struct LocalMedia: Equatable, Sendable {
    public let url: URL
    public let referenceID: LocalMediaReferenceID
    public let bookmark: Data?
    public let fileIdentity: LocalFileIdentity?

    public init(
        url: URL,
        referenceID: LocalMediaReferenceID = LocalMediaReferenceID(),
        bookmark: Data? = nil,
        fileIdentity: LocalFileIdentity? = nil
    ) {
        self.url = url
        self.referenceID = referenceID
        self.bookmark = bookmark
        self.fileIdentity = fileIdentity
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

public struct PlaybackLoadID: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
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
    case playbackEnded(loadID: PlaybackLoadID)
    case trackCatalogChanged(TrackCatalog, loadID: PlaybackLoadID)
}

public protocol PlaybackEngine: Sendable {
    var events: AsyncStream<PlaybackEngineEvent> { get }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) async
    func play() async
    func pause() async
    func stop() async
    func selectAudioTrack(_ id: AudioTrackID) async -> Bool
    func selectSubtitle(_ selection: SubtitleSelection) async -> Bool
    func loadExternalSubtitle(_ subtitle: LocalExternalSubtitle) async -> ExternalSubtitleLoadResult
}

public extension PlaybackEngine {
    func selectAudioTrack(_ id: AudioTrackID) async -> Bool { false }
    func selectSubtitle(_ selection: SubtitleSelection) async -> Bool { false }
    func loadExternalSubtitle(_ subtitle: LocalExternalSubtitle) async -> ExternalSubtitleLoadResult {
        .damaged
    }
}
