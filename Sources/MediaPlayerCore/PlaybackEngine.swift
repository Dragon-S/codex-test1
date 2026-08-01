import Foundation

public struct LocalMedia: Equatable, Sendable {
    public let url: URL
    public let referenceID: LocalMediaReferenceID
    public let bookmark: Data?

    public init(
        url: URL,
        referenceID: LocalMediaReferenceID = LocalMediaReferenceID(),
        bookmark: Data? = nil
    ) {
        self.url = url
        self.referenceID = referenceID
        self.bookmark = bookmark
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

public enum PlaybackEngineEvent: Equatable, Sendable {
    case playbackStateChanged(PlaybackState, loadID: PlaybackLoadID)
    case playbackEnded(loadID: PlaybackLoadID)
}

public protocol PlaybackEngine: Sendable {
    var events: AsyncStream<PlaybackEngineEvent> { get }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) async
    func play() async
    func pause() async
    func stop() async
}
