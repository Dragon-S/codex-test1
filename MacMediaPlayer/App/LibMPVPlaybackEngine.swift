import AppKit

private struct InternalQualificationRecord: Encodable, Sendable {
    enum Kind: String, Encodable, Sendable {
        case sessionStarted = "session_started"
        case loadRequested = "load_requested"
        case fileLoaded = "file_loaded"
        case playbackRestart = "playback_restart"
        case firstFrameRendered = "first_frame_rendered"
        case seekRequested = "seek_requested"
        case steadyStateSample = "steady_state_sample"
        case subtitleFrameCaptured = "subtitle_frame_captured"
        case unknown
    }

    let kind: Kind
    let monotonicMilliseconds: Double
    let loadID: UInt64?
    let positionSeconds: Double?
    let decoderDroppedFrames: Int64?
    let outputDroppedFrames: Int64?
    let mistimedFrames: Int64?
    let avSyncSeconds: Double?
    let fileName: String?
    let succeeded: Bool?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case monotonicMilliseconds
        case loadID
        case positionSeconds
        case decoderDroppedFrames
        case outputDroppedFrames
        case mistimedFrames
        case avSyncSeconds
        case fileName
        case succeeded
    }

    static func sessionStarted(monotonicMilliseconds: Double) -> Self {
        Self(
            kind: .sessionStarted,
            monotonicMilliseconds: monotonicMilliseconds,
            loadID: nil,
            positionSeconds: nil,
            decoderDroppedFrames: nil,
            outputDroppedFrames: nil,
            mistimedFrames: nil,
            avSyncSeconds: nil,
            fileName: nil,
            succeeded: nil
        )
    }

    static func playbackEvent(_ event: MPVClientQualificationEvent) -> Self {
        Self(
            kind: kind(for: event.kind),
            monotonicMilliseconds: event.monotonicMilliseconds,
            loadID: event.loadID,
            positionSeconds: event.position,
            decoderDroppedFrames: event.decoderDroppedFrames,
            outputDroppedFrames: event.outputDroppedFrames,
            mistimedFrames: event.mistimedFrames,
            avSyncSeconds: event.avSyncSeconds.isFinite ? event.avSyncSeconds : nil,
            fileName: nil,
            succeeded: nil
        )
    }

    static func subtitleFrameCaptured(
        fileName: String,
        succeeded: Bool,
        loadID: UInt64,
        positionSeconds: Double,
        monotonicMilliseconds: Double
    ) -> Self {
        Self(
            kind: .subtitleFrameCaptured,
            monotonicMilliseconds: monotonicMilliseconds,
            loadID: loadID,
            positionSeconds: positionSeconds,
            decoderDroppedFrames: nil,
            outputDroppedFrames: nil,
            mistimedFrames: nil,
            avSyncSeconds: nil,
            fileName: fileName,
            succeeded: succeeded
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(monotonicMilliseconds, forKey: .monotonicMilliseconds)
        switch kind {
        case .sessionStarted:
            break
        case .subtitleFrameCaptured:
            try container.encode(fileName, forKey: .fileName)
            try container.encode(succeeded, forKey: .succeeded)
            try container.encode(loadID, forKey: .loadID)
            try container.encode(positionSeconds, forKey: .positionSeconds)
        case .loadRequested, .fileLoaded, .playbackRestart, .firstFrameRendered,
             .seekRequested, .steadyStateSample, .unknown:
            try container.encode(loadID, forKey: .loadID)
            try container.encode(positionSeconds, forKey: .positionSeconds)
            try container.encode(decoderDroppedFrames, forKey: .decoderDroppedFrames)
            try container.encode(outputDroppedFrames, forKey: .outputDroppedFrames)
            try container.encode(mistimedFrames, forKey: .mistimedFrames)
            try container.encode(avSyncSeconds, forKey: .avSyncSeconds)
        }
    }

    private static func kind(for kind: MPVClientQualificationEventKind) -> Kind {
        switch kind {
        case .loadRequested: .loadRequested
        case .fileLoaded: .fileLoaded
        case .playbackRestart: .playbackRestart
        case .firstFrameRendered: .firstFrameRendered
        case .seekRequested: .seekRequested
        case .steadyStateSample: .steadyStateSample
        @unknown default: .unknown
        }
    }
}

private final class InternalQualificationLogWriterState: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder

    init(fileURL: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: fileURL.path) {
            _ = fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func write(_ record: InternalQualificationRecord) {
        guard let data = try? encoder.encode(record) else { return }
        try? fileHandle.write(contentsOf: data)
        try? fileHandle.write(contentsOf: Data([0x0A]))
    }

    func synchronize() {
        try? fileHandle.synchronize()
    }

    func close() {
        synchronize()
        try? fileHandle.close()
    }
}

private final class InternalQualificationLogWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let state: InternalQualificationLogWriterState

    init(
        fileURL: URL,
        fileManager: FileManager,
        queue: DispatchQueue
    ) throws {
        self.queue = queue
        state = try InternalQualificationLogWriterState(
            fileURL: fileURL,
            fileManager: fileManager
        )
    }

    deinit {
        let state = state
        queue.async {
            state.close()
        }
    }

    func enqueue(_ record: InternalQualificationRecord) {
        let state = state
        queue.async {
            state.write(record)
        }
    }

    func flush() async {
        let state = state
        await withCheckedContinuation { continuation in
            queue.async {
                state.synchronize()
                continuation.resume()
            }
        }
    }
}

final class InternalQualificationRecorder: @unchecked Sendable {
    static let enableMarkerName = "EnableInternalQualificationEvidence"
    static let logName = "internal-qualification.jsonl"
    static let subtitleFramePrefix = "qualification-subtitle-frame"

    private let directory: URL
    private let writer: InternalQualificationLogWriter
    private let sequenceLock = NSLock()
    private var subtitleFrameSequence = 0

    static func enabledRecorder(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) -> InternalQualificationRecorder? {
        let supportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let supportDirectory else { return nil }
        let directory = supportDirectory.appending(path: "MacMediaPlayer", directoryHint: .isDirectory)
        let marker = directory.appending(path: enableMarkerName)
        guard fileManager.fileExists(atPath: marker.path) else { return nil }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try InternalQualificationRecorder(
                fileURL: directory.appending(path: logName),
                fileManager: fileManager
            )
        } catch {
            return nil
        }
    }

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        writerQueue: DispatchQueue = DispatchQueue(
            label: "com.dragon-s.MacMediaPlayer.internal-qualification-writer",
            qos: .utility
        )
    ) throws {
        directory = fileURL.deletingLastPathComponent()
        writer = try InternalQualificationLogWriter(
            fileURL: fileURL,
            fileManager: fileManager,
            queue: writerQueue
        )
        writer.enqueue(.sessionStarted(
            monotonicMilliseconds: ProcessInfo.processInfo.systemUptime * 1_000
        ))
    }

    func record(_ event: MPVClientQualificationEvent) {
        writer.enqueue(.playbackEvent(event))
    }

    func nextSubtitleFrameURL() -> URL {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        subtitleFrameSequence += 1
        let name = String(format: "%@-%04d.png", Self.subtitleFramePrefix, subtitleFrameSequence)
        return directory.appending(path: name)
    }

    func recordSubtitleFrame(
        fileName: String,
        capture: MPVClientScreenshotCapture
    ) {
        writer.enqueue(.subtitleFrameCaptured(
            fileName: fileName,
            succeeded: capture.succeeded,
            loadID: capture.loadID,
            positionSeconds: capture.position,
            monotonicMilliseconds: ProcessInfo.processInfo.systemUptime * 1_000
        ))
    }

    func flush() async {
        await writer.flush()
    }
}

final class LibMPVPlaybackEngine: PlaybackEngine, @unchecked Sendable {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>

    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private let client: MPVClient
    private let qualificationRecorder: InternalQualificationRecorder?

    init(
        videoView: PlaybackCanvasView,
        qualificationRecorder: InternalQualificationRecorder? = .enabledRecorder()
    ) {
        (events, continuation) = AsyncStream.makeStream()
        self.qualificationRecorder = qualificationRecorder
        client = MPVClient(videoView: videoView)
        client.qualificationEventHandler = Self.qualificationEventHandler(
            for: qualificationRecorder
        )
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

    static func qualificationEventHandler(
        for recorder: InternalQualificationRecorder?
    ) -> ((MPVClientQualificationEvent) -> Void)? {
        guard let recorder else { return nil }
        return { [recorder] event in
            recorder.record(event)
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
        let success = await withCheckedContinuation { continuation in
            client.selectSubtitleTrack(identifier) { success in
                continuation.resume(returning: success)
            }
        }
        if success,
           case .embedded = selection,
           let screenshotURL = qualificationRecorder?.nextSubtitleFrameURL() {
            let capture = await client.captureScreenshot(to: screenshotURL)
            qualificationRecorder?.recordSubtitleFrame(
                fileName: screenshotURL.lastPathComponent,
                capture: capture
            )
        }
        return success
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
