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
        client.settingsHandler = { [continuation] rate, volume, isMuted, rawLoadID in
            continuation.yield(.settingsChanged(
                PlaybackSettings(rate: rate, volume: volume, isMuted: isMuted),
                loadID: PlaybackLoadID(rawValue: rawLoadID)
            ))
        }
        client.trackCatalogHandler = { [continuation] audioTracks, subtitleTracks, rawLoadID in
            let audioOptions = audioTracks.map { track in
                AudioTrackOption(
                    id: AudioTrackID(rawValue: track.identifier as UUID),
                    languageCode: track.languageCode,
                    title: track.title,
                    ordinal: track.ordinal,
                    isDefault: track.isDefault
                )
            }
            let subtitleOptions = subtitleTracks.map { track in
                EmbeddedSubtitleTrackOption(
                    id: EmbeddedSubtitleTrackID(rawValue: track.identifier as UUID),
                    languageCode: track.languageCode,
                    title: track.title,
                    ordinal: track.ordinal,
                    isDefault: track.isDefault,
                    isForced: track.isForced
                )
            }
            continuation.yield(.trackCatalogChanged(
                TrackCatalog(
                    audioTracks: audioOptions,
                    embeddedSubtitleTracks: subtitleOptions
                ),
                loadID: PlaybackLoadID(rawValue: rawLoadID)
            ))
        }
        client.mediaPresentationHandler = { [continuation] presentation, rawLoadID in
            let mediaKind: PlaybackMediaKind = switch presentation.kind {
            case .audio: .audio
            case .video: .video
            @unknown default: .video
            }
            let dimensions = presentation.pixelWidth > 0 && presentation.pixelHeight > 0
                ? VideoDimensions(
                    width: presentation.pixelWidth,
                    height: presentation.pixelHeight
                )
                : nil
            continuation.yield(.mediaPresentationChanged(
                PlaybackMediaPresentation(
                    kind: mediaKind,
                    title: presentation.title,
                    artist: presentation.artist,
                    album: presentation.album,
                    hasArtwork: presentation.hasArtwork,
                    videoDimensions: dimensions
                ),
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

    func loadUsingSoftwareDecoding(_ media: LocalMedia, loadID: PlaybackLoadID) async {
        client.loadURL(usingSoftwareDecoding: media.url, loadID: loadID.rawValue)
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

    func selectAudioTrack(_ id: AudioTrackID) async -> Bool {
        await withCheckedContinuation { continuation in
            client.selectAudioTrack(id.rawValue) { success in
                continuation.resume(returning: success)
            }
        }
    }

    func selectSubtitle(_ selection: SubtitleSelection) async -> Bool {
        let identifier: UUID?
        switch selection {
        case .off:
            identifier = nil
        case let .embedded(id):
            identifier = id.rawValue
        }
        return await withCheckedContinuation { continuation in
            client.selectSubtitleTrack(identifier) { success in
                continuation.resume(returning: success)
            }
        }
    }

    func loadExternalSubtitle(_ subtitle: LocalExternalSubtitle) async -> ExternalSubtitleLoadResult {
        await withCheckedContinuation { continuation in
            client.loadExternalSubtitleURL(subtitle.url) { result, identifier in
                switch result {
                case .loaded:
                    guard identifier != nil else {
                        continuation.resume(returning: .damaged)
                        return
                    }
                    continuation.resume(returning: .loaded)
                case .missing:
                    continuation.resume(returning: .missing)
                case .damaged:
                    continuation.resume(returning: .damaged)
                @unknown default:
                    continuation.resume(returning: .damaged)
                }
            }
        }
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

    static func failure(for failure: MPVClientFailure) -> PlaybackFailure {
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
