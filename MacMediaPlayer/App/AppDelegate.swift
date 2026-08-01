import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var coordinator: PlaybackCoordinator?
    private var securityScopedURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let videoView = PlaybackCanvasView(frame: .zero)
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let coordinator = PlaybackCoordinator(engine: engine)
        self.coordinator = coordinator

        let viewController = PlaybackViewController(
            coordinator: coordinator,
            openMedia: { [weak self] in self?.openMedia() },
            videoView: videoView
        )
        let window = NSWindow(contentViewController: viewController)
        window.title = "Mac Media Player"
        window.setContentSize(NSSize(width: 960, height: 600))
        window.minSize = NSSize(width: 640, height: 400)
        window.styleMask.insert(.resizable)
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseSecurityScope()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func openMedia() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "打开本地媒体"
        panel.prompt = "打开"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedMediaTypes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.play(panel.urls)
            }
        }
    }

    private func play(_ urls: [URL]) {
        let newSecurityScopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        releaseSecurityScope()
        securityScopedURLs = newSecurityScopedURLs
        guard let coordinator else { return }
        Task { await coordinator.open(urls.map(LocalMedia.init(url:))) }
    }

    private func releaseSecurityScope() {
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedURLs = []
    }

    private static let supportedMediaTypes = [
        "mp4", "mov", "mkv", "webm",
        "mp3", "m4a", "aac", "alac", "flac", "wav", "ogg", "opus",
    ].compactMap { UTType(filenameExtension: $0) }
}
