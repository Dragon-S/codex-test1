import Combine

public struct NowPlayingList: Equatable, Sendable {
    public let entries: [LocalMedia]
    public let currentIndex: Int?

    public var currentMedia: LocalMedia? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    public init(entries: [LocalMedia] = [], currentIndex: Int? = nil) {
        self.entries = entries
        self.currentIndex = currentIndex
    }
}

@MainActor
public final class PlaybackCoordinator: ObservableObject {
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var nowPlayingList = NowPlayingList()

    private let engine: any PlaybackEngine
    private var eventTask: Task<Void, Never>?
    private var isFindingFirstPlayableMedia = false

    public init(engine: any PlaybackEngine) {
        self.engine = engine
        eventTask = Task { [weak self, events = engine.events] in
            for await event in events {
                guard let self else { return }
                await receive(event)
            }
        }
    }

    public func open(_ media: LocalMedia) async {
        await open([media])
    }

    public func open(_ media: [LocalMedia]) async {
        guard let first = media.first else { return }
        nowPlayingList = NowPlayingList(entries: media, currentIndex: 0)
        isFindingFirstPlayableMedia = true
        await engine.load(first)
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

    public func next() async {
        isFindingFirstPlayableMedia = false
        await move(by: 1)
    }

    public func previous() async {
        isFindingFirstPlayableMedia = false
        await move(by: -1)
    }

    private func move(by offset: Int) async {
        guard let currentIndex = nowPlayingList.currentIndex else {
            await engine.stop()
            return
        }
        let destination = currentIndex + offset
        guard nowPlayingList.entries.indices.contains(destination) else {
            await engine.stop()
            return
        }
        let entries = nowPlayingList.entries
        nowPlayingList = NowPlayingList(entries: entries, currentIndex: destination)
        await engine.load(entries[destination])
    }

    private func receive(_ event: PlaybackEngineEvent) async {
        switch event {
        case let .playbackStateChanged(state):
            self.state = state
            switch state {
            case .playing, .paused:
                isFindingFirstPlayableMedia = false
            case .failed where isFindingFirstPlayableMedia:
                if let currentIndex = nowPlayingList.currentIndex,
                   nowPlayingList.entries.indices.contains(currentIndex + 1) {
                    await move(by: 1)
                } else {
                    isFindingFirstPlayableMedia = false
                }
            default:
                break
            }
        case .playbackEnded:
            isFindingFirstPlayableMedia = false
            guard let currentIndex = nowPlayingList.currentIndex else {
                state = .stopped
                return
            }
            if nowPlayingList.entries.indices.contains(currentIndex + 1) {
                await move(by: 1)
            } else {
                state = .stopped
            }
        }
    }
}
