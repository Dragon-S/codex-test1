import AppKit

final class LibMPVPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>

    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private let client: MPVClient

    init(videoView: PlaybackCanvasView) {
        (events, continuation) = AsyncStream.makeStream()
        client = MPVClient(videoView: videoView)
        client.stateHandler = { [continuation] state, rawLoadID in
            let loadID = PlaybackLoadID(rawValue: rawLoadID)
            continuation.yield(.playbackStateChanged(Self.state(for: state), loadID: loadID))
        }
        client.failureHandler = { [continuation] failure, rawLoadID in
            let loadID = PlaybackLoadID(rawValue: rawLoadID)
            continuation.yield(.playbackStateChanged(.failed(Self.failure(for: failure)), loadID: loadID))
        }
        client.playbackEndedHandler = { [continuation] rawLoadID in
            continuation.yield(.playbackEnded(loadID: PlaybackLoadID(rawValue: rawLoadID)))
        }
        client.timelineHandler = { [continuation] position, duration, rawLoadID in
            continuation.yield(.timelineChanged(
                position: position,
                duration: duration,
                loadID: PlaybackLoadID(rawValue: rawLoadID)
            ))
        }
    }

    deinit {
        client.shutdown()
        continuation.finish()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) async {
        client.load(media.url, loadID: loadID.rawValue)
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

    func seek(to position: TimeInterval) async {
        client.seek(to: position)
    }

    func setPlaybackRate(_ rate: Double) async {
        client.setPlaybackRate(rate)
    }

    func setPlayerVolume(_ volume: Double) async {
        client.setPlayerVolume(volume)
    }

    func setMuted(_ isMuted: Bool) async {
        client.setMuted(isMuted)
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
