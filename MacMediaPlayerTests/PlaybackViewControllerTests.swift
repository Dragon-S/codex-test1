import AppKit
import Testing
@testable import MacMediaPlayer

@MainActor
struct PlaybackViewControllerTests {
    @Test("普通窗口收起 Playlist 后画布恢复完整宽度")
    func collapsingPlaylistRestoresCanvasWidth() {
        let controller = makeController()
        let size = NSSize(width: 1_000, height: 700)
        let window = host(controller, size: size)
        layout(controller, in: window, size: size)
        #expect(!controller.isCanvasUsingFullWidth)

        controller.setPlaylistVisible(false)
        layout(controller, in: window, size: size)

        #expect(controller.isCanvasUsingFullWidth)
        #expect(!controller.isPlaylistVisible)
        #expect(window.contentView === controller.view)
    }

    @Test("全屏 Playlist 以覆盖层显示且不改变画布尺寸")
    func fullscreenPlaylistOverlaysCanvasWithoutResizingIt() {
        let controller = makeController()
        let size = NSSize(width: 1_200, height: 800)
        let window = host(controller, size: size)
        controller.setFullScreenMode(true)
        controller.setPlaylistVisible(false)
        layout(controller, in: window, size: size)
        let canvasFrameWithoutPlaylist = controller.videoView.frame

        controller.setPlaylistVisible(true)
        layout(controller, in: window, size: size)

        #expect(controller.videoView.frame == canvasFrameWithoutPlaylist)
        #expect(controller.videoView.frame == controller.view.bounds)
        _ = window
    }

    @Test("全屏 Esc 依次关闭 Playlist 与控制器后才退出全屏")
    func escapeDismissesOverlaysBeforeExitingFullscreen() {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.setFullScreenMode(true)

        #expect(controller.handleEscapeKey() == .dismissedPlaylist)
        #expect(!controller.isPlaylistVisible)
        #expect(controller.isControlsVisible)

        #expect(controller.handleEscapeKey() == .dismissedControls)
        #expect(!controller.isControlsVisible)

        controller.handlePointerActivity()
        #expect(controller.isControlsVisible)
        _ = controller.handleEscapeKey()
        #expect(controller.handleEscapeKey() == .exitFullScreen)
    }

    private func makeController() -> PlaybackViewController {
        let coordinator = PlaybackCoordinator(engine: LayoutFakePlaybackEngine())
        return PlaybackViewController(
            coordinator: coordinator,
            openMedia: {},
            openExternalSubtitle: {},
            relocateExternalSubtitle: {},
            addMediaToPlaylist: { _ in },
            relocateMissingMedia: { _ in },
            confirmMediaReplacement: { _ in },
            cancelMediaReplacement: {},
            videoView: PlaybackCanvasView(frame: .zero)
        )
    }

    private func host(_ controller: PlaybackViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.loadViewIfNeeded()
        window.contentView = controller.view
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func layout(
        _ controller: PlaybackViewController,
        in window: NSWindow,
        size: NSSize
    ) {
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        controller.view.setFrameSize(size)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
    }
}

private actor LayoutFakePlaybackEngine: PlaybackEngine {
    nonisolated let events: AsyncStream<PlaybackEngineEvent>

    init() {
        events = AsyncStream { _ in }
    }

    func load(_ media: LocalMedia, loadID: PlaybackLoadID) {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) {}
    func setPlaybackRate(_ rate: Double) {}
    func setPlayerVolume(_ volume: Double) {}
    func setMuted(_ isMuted: Bool) {}
}
