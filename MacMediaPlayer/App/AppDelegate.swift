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
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: makePlaylistStore(),
            persistentMediaAccess: SecurityScopedMediaAccess()
        )
        self.coordinator = coordinator

        let viewController = PlaybackViewController(
            coordinator: coordinator,
            openMedia: { [weak self] in self?.openMedia() },
            addMediaToPlaylist: { [weak self] playlistID in
                self?.addMedia(to: playlistID)
            },
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

        Task {
            try? await coordinator.restorePersistentState()
        }

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
        let media = urls.map { url in
            let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return LocalMedia(
                url: url,
                bookmark: bookmark,
                fileIdentity: Self.fileIdentity(for: url)
            )
        }
        releaseSecurityScope()
        securityScopedURLs = newSecurityScopedURLs
        guard let coordinator else { return }
        Task { await coordinator.open(media) }
    }

    private func addMedia(to playlistID: PlaylistID) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "向 Playlist 添加本地媒体"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedMediaTypes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, let coordinator else { return }
                guard let url = panel.urls.first else { return }
                if url.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(url)
                }
                let bookmark = try? url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                _ = try? await coordinator.add(
                    LocalMedia(
                        url: url,
                        bookmark: bookmark,
                        fileIdentity: Self.fileIdentity(for: url)
                    ),
                    to: playlistID
                )
            }
        }
    }

    private static func fileIdentity(for url: URL) -> Data? {
        guard let identifier = try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier else { return nil }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: identifier,
            requiringSecureCoding: false
        )
    }

    private func makePlaylistStore() -> any PlaylistStore {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport.appending(
                path: Bundle.main.bundleIdentifier ?? "MacMediaPlayer",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return try SQLitePlaylistStore(databaseURL: directory.appending(path: "playlists.sqlite"))
        } catch {
            return UnavailablePlaylistStore(message: "无法打开 Playlist 存储：\(error.localizedDescription)")
        }
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
