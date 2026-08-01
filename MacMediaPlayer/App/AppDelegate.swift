import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var coordinator: PlaybackCoordinator?
    private var selectedURL: URL?
    private var hasSecurityScope = false

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
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedMediaTypes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.play(url)
            }
        }
    }

    private func play(_ url: URL) {
        releaseSecurityScope()
        selectedURL = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
        guard let coordinator else { return }
        Task { await coordinator.open(LocalMedia(url: url)) }
    }

    private func releaseSecurityScope() {
        if hasSecurityScope {
            selectedURL?.stopAccessingSecurityScopedResource()
        }
        selectedURL = nil
        hasSecurityScope = false
    }

    private static let supportedMediaTypes = [
        "mp4", "mov", "mkv", "webm",
        "mp3", "m4a", "aac", "alac", "flac", "wav", "ogg", "opus",
    ].compactMap { UTType(filenameExtension: $0) }
}
