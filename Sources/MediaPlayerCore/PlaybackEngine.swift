import Foundation

public struct LocalMedia: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
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

public enum PlaybackEngineEvent: Equatable, Sendable {
    case playbackStateChanged(PlaybackState)
}

public protocol PlaybackEngine: Sendable {
    var events: AsyncStream<PlaybackEngineEvent> { get }

    func load(_ media: LocalMedia) async
    func play() async
    func pause() async
    func stop() async
}
