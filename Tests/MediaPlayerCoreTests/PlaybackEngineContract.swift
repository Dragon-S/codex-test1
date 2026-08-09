import Foundation
import Testing

#if SWIFT_PACKAGE
@testable import MediaPlayerCore
#else
@testable import MacMediaPlayer
#endif

func waitUntilTestCondition(
    for timeout: Duration,
    pollingEvery pollingInterval: Duration,
    isolation: isolated (any Actor)? = #isolation,
    condition: () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try await Task.sleep(for: pollingInterval)
    }
    return await condition()
}

@Test("假引擎履行基础 PlaybackEngine 契约")
func fakeEngineFulfillsBasicPlaybackContract() async throws {
    let engine = ContractFakePlaybackEngine()
    let media = LocalMedia(url: URL(fileURLWithPath: "/tmp/fake-media.mp4"))

    try await verifyBasicPlaybackEngineContract(engine: engine, media: media)

    let interruptedMedia = LocalMedia(url: URL(fileURLWithPath: "/tmp/interrupted-media.mp4"))
    let replacementEngine = ContractFakePlaybackEngine(mediaHeldPending: interruptedMedia)
    try await verifyLoadReplacementContract(
        engine: replacementEngine,
        interruptedMedia: interruptedMedia,
        replacementMedia: media
    )
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

    let reloadLoadID = PlaybackLoadID(rawValue: 2)
    let reloadMark = recorder.eventMark()
    await engine.load(media, loadID: reloadLoadID)
    try await recorder.waitForState(.loading, loadID: reloadLoadID, after: reloadMark)
    try await recorder.waitForState(.playing, loadID: reloadLoadID, after: reloadMark)
    #expect(!recorder.hasState(.stopped, loadID: reloadLoadID, after: reloadMark))

    let stopMark = recorder.mark()
    await engine.stop()
    try await recorder.wait(for: .stopped, after: stopMark)
}

func verifyLoadReplacementContract(
    engine: some PlaybackEngine,
    interruptedMedia: LocalMedia,
    replacementMedia: LocalMedia
) async throws {
    let recorder = ContractEventRecorder(events: engine.events)
    let interruptedLoadID = PlaybackLoadID(rawValue: 41)
    let replacementLoadID = PlaybackLoadID(rawValue: 42)

    await engine.load(interruptedMedia, loadID: interruptedLoadID)
    try await recorder.waitForState(.loading, loadID: interruptedLoadID)

    let replacementMark = recorder.eventMark()
    await engine.load(replacementMedia, loadID: replacementLoadID)
    try await recorder.waitForState(
        .stopped,
        loadID: interruptedLoadID,
        after: replacementMark
    )
    try await recorder.waitForState(.loading, loadID: replacementLoadID)
    try await recorder.waitForState(.playing, loadID: replacementLoadID)
    try await recorder.expectNoFailure(
        loadID: replacementLoadID,
        during: .milliseconds(250)
    )
}

final class ContractEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PlaybackState] = []
    private var observedEvents: [PlaybackEngineEvent] = []
    private var streamFinished = false
    private var eventTask: Task<Void, Never>?

    init(events: AsyncStream<PlaybackEngineEvent>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                append(event)
            }
            self?.markStreamFinished()
        }
    }

    func wait(for expected: PlaybackState, after index: Int = 0) async throws {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: { self.snapshot().dropFirst(index).contains(expected) }
        ) {
            return
        }
        throw ContractTimeout(expected: expected, observed: snapshot())
    }

    func mark() -> Int {
        snapshot().count
    }

    func hasObserved(_ state: PlaybackState, after index: Int = 0) -> Bool {
        snapshot().dropFirst(index).contains(state)
    }

    func waitForState(
        _ state: PlaybackState,
        loadID: PlaybackLoadID,
        after index: Int = 0
    ) async throws {
        let expected = PlaybackEngineEvent.playbackStateChanged(state, loadID: loadID)
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: { self.eventSnapshot().dropFirst(index).contains(expected) }
        ) {
            return
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

    func hasState(
        _ state: PlaybackState,
        loadID: PlaybackLoadID,
        after index: Int = 0
    ) -> Bool {
        eventSnapshot().dropFirst(index).contains(.playbackStateChanged(state, loadID: loadID))
    }

    func expectNoFailure(
        loadID: PlaybackLoadID,
        during duration: Duration
    ) async throws {
        if try await waitUntilTestCondition(
            for: duration,
            pollingEvery: .milliseconds(20),
            condition: { self.hasFailure(loadID: loadID) }
        ) {
            throw UnexpectedContractFailure(loadID: loadID, observed: eventSnapshot())
        }
    }

    func waitForCompletion() async throws {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: { self.lock.withLock { self.streamFinished } }
        ) {
            return
        }
        throw ContractStreamCompletionTimeout(observed: eventSnapshot())
    }

    func eventMark() -> Int {
        eventSnapshot().count
    }

    func waitForPosition(_ position: TimeInterval, loadID: PlaybackLoadID) async throws {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: {
                self.eventSnapshot().contains { event in
                guard case let .timelineChanged(observed, _, eventLoadID) = event else { return false }
                return eventLoadID == loadID && abs(observed - position) < 0.2
                }
            }
        ) {
            return
        }
        throw ContractTimelineTimeout(expected: position, observed: eventSnapshot())
    }

    func waitForSettings(_ settings: PlaybackSettings, loadID: PlaybackLoadID) async throws {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: {
                self.eventSnapshot().contains(.settingsChanged(settings, loadID: loadID))
            }
        ) {
            return
        }
        throw ContractSettingsTimeout(expected: settings, observed: eventSnapshot())
    }

    func waitForTrackCatalog(loadID: PlaybackLoadID) async throws -> TrackCatalog {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: { self.trackCatalog(loadID: loadID) != nil }
        ), let catalog = trackCatalog(loadID: loadID) {
            return catalog
        }
        throw TrackCatalogTimeout(loadID: loadID, observed: eventSnapshot())
    }

    func waitForMediaPresentation(loadID: PlaybackLoadID) async throws -> PlaybackMediaPresentation {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: { self.mediaPresentation(loadID: loadID) != nil }
        ), let presentation = mediaPresentation(loadID: loadID) {
            return presentation
        }
        throw MediaPresentationTimeout(loadID: loadID, observed: eventSnapshot())
    }

    func waitForVideoPresentationWithDimensions(
        loadID: PlaybackLoadID
    ) async throws -> PlaybackMediaPresentation {
        if try await waitUntilTestCondition(
            for: .seconds(5),
            pollingEvery: .milliseconds(20),
            condition: { self.videoPresentationWithDimensions(loadID: loadID) != nil }
        ), let presentation = videoPresentationWithDimensions(loadID: loadID) {
            return presentation
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

    private func markStreamFinished() {
        lock.withLock {
            streamFinished = true
        }
    }

    private func snapshot() -> [PlaybackState] {
        lock.withLock { states }
    }

    private func eventSnapshot() -> [PlaybackEngineEvent] {
        lock.withLock { observedEvents }
    }

    private func trackCatalog(loadID: PlaybackLoadID) -> TrackCatalog? {
        firstEventValue { event -> TrackCatalog? in
            guard case let .trackCatalogChanged(catalog, eventLoadID) = event,
                  eventLoadID == loadID else {
                return nil
            }
            return catalog
        }
    }

    private func mediaPresentation(loadID: PlaybackLoadID) -> PlaybackMediaPresentation? {
        firstEventValue { event -> PlaybackMediaPresentation? in
            guard case let .mediaPresentationChanged(presentation, eventLoadID) = event,
                  eventLoadID == loadID else {
                return nil
            }
            return presentation
        }
    }

    private func videoPresentationWithDimensions(
        loadID: PlaybackLoadID
    ) -> PlaybackMediaPresentation? {
        firstEventValue { event -> PlaybackMediaPresentation? in
            guard case let .mediaPresentationChanged(presentation, eventLoadID) = event,
                  eventLoadID == loadID,
                  presentation.kind == .video,
                  presentation.videoDimensions != nil else {
                return nil
            }
            return presentation
        }
    }

    private func firstEventValue<Value>(
        _ transform: (PlaybackEngineEvent) -> Value?
    ) -> Value? {
        eventSnapshot().lazy.compactMap(transform).first
    }
}

private struct UnexpectedContractFailure: Error, CustomStringConvertible {
    let loadID: PlaybackLoadID
    let observed: [PlaybackEngineEvent]

    var description: String {
        "加载 \(loadID) 不应失败，已观察事件：\(observed)"
    }
}

private struct ContractStreamCompletionTimeout: Error, CustomStringConvertible {
    let observed: [PlaybackEngineEvent]

    var description: String {
        "等待 PlaybackEngine 事件流结束超时，已观察事件：\(observed)"
    }
}

private actor ContractFakePlaybackEngine: PlaybackEngine {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>
    private let continuation: AsyncStream<PlaybackEngineEvent>.Continuation
    private let mediaHeldPending: LocalMedia?
    private var currentLoadID: PlaybackLoadID?
    private var settings = PlaybackSettings(rate: 1, volume: 1, isMuted: false)

    init(mediaHeldPending: LocalMedia? = nil) {
        (events, continuation) = AsyncStream.makeStream()
        self.mediaHeldPending = mediaHeldPending
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {
        if let currentLoadID {
            continuation.yield(.playbackStateChanged(.stopped, loadID: currentLoadID))
        }
        currentLoadID = loadID
        continuation.yield(.playbackStateChanged(.loading, loadID: loadID))
        if media != mediaHeldPending {
            continuation.yield(.playbackStateChanged(.playing, loadID: loadID))
        }
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
