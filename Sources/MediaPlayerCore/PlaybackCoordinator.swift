import Combine

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var state: PlaybackState = .idle

    private let engine: any PlaybackEngine
    private var eventTask: Task<Void, Never>?

    public init(engine: any PlaybackEngine) {
        self.engine = engine
        eventTask = Task { [weak self, events = engine.events] in
            for await event in events {
                guard let self else { return }
                receive(event)
            }
        }
    }

    public func open(_ media: LocalMedia) async {
        await engine.load(media)
    }

    public func play() async {
        await engine.play()
    }

    public func pause() async {
        await engine.pause()
    }

    public func stop() async {
        await engine.stop()
    }

    private func receive(_ event: PlaybackEngineEvent) {
        switch event {
        case let .playbackStateChanged(state):
            self.state = state
        }
    }
}
