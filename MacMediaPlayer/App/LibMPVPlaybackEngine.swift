import AppKit

final class LibMPVPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>

    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private let client: MPVClient

    init(videoView: PlaybackCanvasView) {
        (events, continuation) = AsyncStream.makeStream()
        client = MPVClient(videoView: videoView)
        client.stateHandler = { [continuation] state in
            continuation.yield(.playbackStateChanged(Self.state(for: state)))
        }
        client.failureHandler = { [continuation] failure in
            continuation.yield(.playbackStateChanged(.failed(Self.failure(for: failure))))
        }
        client.playbackEndedHandler = { [continuation] in
            continuation.yield(.playbackEnded)
        }
    }

    deinit {
        client.shutdown()
        continuation.finish()
    }

    func load(_ media: LocalMedia) async {
        client.load(media.url)
    }

    func play() async {
        client.play()
    }

    func pause() async {
        client.pause()
    }

    func stop() async {
        client.stop()
    }

    private static func state(for state: MPVClientPlaybackState) -> PlaybackState {
        switch state {
        case .loading: .loading
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        @unknown default: .failed(.engineUnavailable)
        }
    }

    private static func failure(for failure: MPVClientFailure) -> PlaybackFailure {
        switch failure {
        case .unreadable: .unreadable
        case .unsupported: .unsupported
        case .corrupted: .corrupted
        case .decoderInitialization: .decoderInitializationFailed
        case .engineUnavailable: .engineUnavailable
        @unknown default: .engineUnavailable
        }
    }
}
