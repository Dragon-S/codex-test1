import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import MediaPlayerCore
#else
@testable import MacMediaPlayer
#endif

@Test("假引擎履行基础 PlaybackEngine 契约")
func fakeEngineFulfillsBasicPlaybackContract() async throws {
    let engine = ContractFakePlaybackEngine()
    let media = LocalMedia(url: URL(fileURLWithPath: "/tmp/fake-media.mp4"))

    try await verifyBasicPlaybackEngineContract(engine: engine, media: media)
}

func verifyBasicPlaybackEngineContract(
    engine: some PlaybackEngine,
    media: LocalMedia
) async throws {
    let recorder = ContractEventRecorder(events: engine.events)

    try await Task.sleep(for: .milliseconds(100))
    #expect(!recorder.hasObserved(.playing))

    let initialLoadID = PlaybackLoadID(rawValue: 1)
    let initialLoadMark = recorder.mark()
    await engine.load(media, loadID: initialLoadID)
    try await recorder.wait(for: .loading, after: initialLoadMark)
    try await recorder.wait(for: .playing, after: initialLoadMark)

    let firstPauseMark = recorder.mark()
    await engine.pause()
    try await recorder.wait(for: .paused, after: firstPauseMark)

    await engine.seek(to: 0.5)
    try await recorder.waitForPosition(0.5, loadID: initialLoadID)
    await engine.setPlaybackRate(1.25)
    await engine.setPlayerVolume(0.4)
    await engine.setMuted(true)
    await engine.setMuted(false)
    try await recorder.waitForSettings(
        PlaybackSettings(rate: 1.25, volume: 0.4, isMuted: false),
        loadID: initialLoadID
    )

    let playMark = recorder.mark()
    await engine.play()
    try await recorder.wait(for: .playing, after: playMark)

    let secondPauseMark = recorder.mark()
    await engine.pause()
    try await recorder.wait(for: .paused, after: secondPauseMark)

    let reloadMark = recorder.mark()
    await engine.load(media, loadID: PlaybackLoadID(rawValue: 2))
    try await recorder.wait(for: .loading, after: reloadMark)
    try await recorder.wait(for: .playing, after: reloadMark)
    #expect(!recorder.hasObserved(.stopped, after: reloadMark))

    let stopMark = recorder.mark()
    await engine.stop()
    try await recorder.wait(for: .stopped, after: stopMark)
}

final class ContractEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PlaybackState] = []
    private var observedEvents: [PlaybackEngineEvent] = []
    private var eventTask: Task<Void, Never>?

    init(events: AsyncStream<PlaybackEngineEvent>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                append(event)
            }
        }
    }

    func wait(for expected: PlaybackState, after index: Int = 0) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if snapshot().dropFirst(index).contains(expected) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ContractTimeout(expected: expected, observed: snapshot())
    }

    func mark() -> Int {
        snapshot().count
    }

    func hasObserved(_ state: PlaybackState, after index: Int = 0) -> Bool {
        snapshot().dropFirst(index).contains(state)
    }

    func waitForState(_ state: PlaybackState, loadID: PlaybackLoadID) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        let expected = PlaybackEngineEvent.playbackStateChanged(state, loadID: loadID)
        while ContinuousClock.now < deadline {
            if eventSnapshot().contains(expected) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ContractEventTimeout(expected: expected, observed: eventSnapshot())
    }

    func hasFailure(loadID: PlaybackLoadID) -> Bool {
        eventSnapshot().contains { event in
            if case let .playbackStateChanged(.failed, eventLoadID) = event {
                return eventLoadID == loadID
            }
            return false
        }
    }

    func waitForPosition(_ position: TimeInterval, loadID: PlaybackLoadID) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if eventSnapshot().contains(where: { event in
                guard case let .timelineChanged(observed, _, eventLoadID) = event else { return false }
                return eventLoadID == loadID && abs(observed - position) < 0.2
            }) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ContractTimelineTimeout(expected: position, observed: eventSnapshot())
    }

    func waitForSettings(_ settings: PlaybackSettings, loadID: PlaybackLoadID) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if eventSnapshot().contains(.settingsChanged(settings, loadID: loadID)) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ContractSettingsTimeout(expected: settings, observed: eventSnapshot())
    }

    func waitForTrackCatalog(loadID: PlaybackLoadID) async throws -> TrackCatalog {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            for event in eventSnapshot() {
                if case let .trackCatalogChanged(catalog, eventLoadID) = event,
                   eventLoadID == loadID {
                    return catalog
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TrackCatalogTimeout(loadID: loadID, observed: eventSnapshot())
    }

    func waitForMediaPresentation(loadID: PlaybackLoadID) async throws -> PlaybackMediaPresentation {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            for event in eventSnapshot() {
                if case let .mediaPresentationChanged(presentation, eventLoadID) = event,
                   eventLoadID == loadID {
                    return presentation
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MediaPresentationTimeout(loadID: loadID, observed: eventSnapshot())
    }

    func waitForVideoPresentationWithDimensions(
        loadID: PlaybackLoadID
    ) async throws -> PlaybackMediaPresentation {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            for event in eventSnapshot() {
                if case let .mediaPresentationChanged(presentation, eventLoadID) = event,
                   eventLoadID == loadID,
                   presentation.kind == .video,
                   presentation.videoDimensions != nil {
                    return presentation
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MediaPresentationTimeout(loadID: loadID, observed: eventSnapshot())
    }

    func trackCatalogCount(loadID: PlaybackLoadID) -> Int {
        eventSnapshot().count { event in
            if case let .trackCatalogChanged(_, eventLoadID) = event {
                return eventLoadID == loadID
            }
            return false
        }
    }

    private func append(_ event: PlaybackEngineEvent) {
        lock.withLock {
            observedEvents.append(event)
            if case let .playbackStateChanged(state, _) = event {
                states.append(state)
            }
        }
    }

    private func snapshot() -> [PlaybackState] {
        lock.withLock { states }
    }

    private func eventSnapshot() -> [PlaybackEngineEvent] {
        lock.withLock { observedEvents }
    }
}

private actor ContractFakePlaybackEngine: PlaybackEngine {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private var currentLoadID: PlaybackLoadID?
    private var settings = PlaybackSettings(rate: 1, volume: 1, isMuted: false)

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        currentLoadID = loadID
        continuation.yield(.playbackStateChanged(.loading, loadID: loadID))
        continuation.yield(.playbackStateChanged(.playing, loadID: loadID))
    }

    func play() {
        guard let currentLoadID else { return }
        continuation.yield(.playbackStateChanged(.playing, loadID: currentLoadID))
    }

    func pause() {
        guard let currentLoadID else { return }
        continuation.yield(.playbackStateChanged(.paused, loadID: currentLoadID))
    }

    func stop() {
        guard let currentLoadID else { return }
        continuation.yield(.playbackStateChanged(.stopped, loadID: currentLoadID))
    }

    func seek(to position: TimeInterval) {
        guard let currentLoadID else { return }
        continuation.yield(.timelineChanged(position: position, duration: 2, loadID: currentLoadID))
    }

    func setPlaybackRate(_ rate: Double) {
        settings = PlaybackSettings(rate: rate, volume: settings.volume, isMuted: settings.isMuted)
        reportSettings()
    }

    func setPlayerVolume(_ volume: Double) {
        settings = PlaybackSettings(rate: settings.rate, volume: volume, isMuted: settings.isMuted)
        reportSettings()
    }

    func setMuted(_ isMuted: Bool) {
        settings = PlaybackSettings(rate: settings.rate, volume: settings.volume, isMuted: isMuted)
        reportSettings()
    }

    private func reportSettings() {
        guard let currentLoadID else { return }
        continuation.yield(.settingsChanged(settings, loadID: currentLoadID))
    }
}

private struct ContractTimeout: Error, CustomStringConvertible {
    let expected: PlaybackState
    let observed: [PlaybackState]

    var description: String {
        "等待 \(expected) 超时；已观察到 \(observed)"
    }
}

private struct ContractEventTimeout: Error {
    let expected: PlaybackEngineEvent
    let observed: [PlaybackEngineEvent]
}

private struct ContractTimelineTimeout: Error {
    let expected: TimeInterval
    let observed: [PlaybackEngineEvent]
}

private struct ContractSettingsTimeout: Error {
    let expected: PlaybackSettings
    let observed: [PlaybackEngineEvent]
}

private struct TrackCatalogTimeout: Error {
    let loadID: PlaybackLoadID
    let observed: [PlaybackEngineEvent]
}

private struct MediaPresentationTimeout: Error {
    let loadID: PlaybackLoadID
    let observed: [PlaybackEngineEvent]
}
