import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum ExternalSubtitlePanelAction {
        case selectNew
        case relocate
    }

    private var window: NSWindow?
    private var coordinator: PlaybackCoordinator?
    private var securityScopedURLs: [URL] = []
    private var pendingMediaReplacement: (referenceID: LocalMediaReferenceID, media: LocalMedia)?
    private var isPreparingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let videoView = PlaybackCanvasView(frame: .zero)
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let fileAccess = SecurityScopedMediaAccess()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            playlistStore: makePlaylistStore(),
            persistentMediaAccess: fileAccess,
            externalSubtitleAccess: fileAccess,
            defaultTrackRules: DefaultTrackRules(
                preferredAudioLanguages: Locale.preferredLanguages,
                preferredSubtitleLanguages: Locale.preferredLanguages,
                subtitleAutoPolicy: .automatic
            )
        )
        self.coordinator = coordinator

        let viewController = PlaybackViewController(
            coordinator: coordinator,
            openMedia: { [weak self] in self?.openMedia() },
            openExternalSubtitle: { [weak self] in self?.openExternalSubtitle(.selectNew) },
            relocateExternalSubtitle: { [weak self] in
                self?.openExternalSubtitle(.relocate)
            },
            addMediaToPlaylist: { [weak self] playlistID in
                self?.addMedia(to: playlistID)
            },
            relocateMissingMedia: { [weak self] referenceID in
                self?.relocateMedia(referenceID: referenceID)
            },
            confirmMediaReplacement: { [weak self] referenceID in
                self?.confirmMediaReplacement(referenceID: referenceID)
            },
            cancelMediaReplacement: { [weak self] in
                self?.pendingMediaReplacement = nil
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingTermination else { return .terminateNow }
        guard let coordinator else { return .terminateNow }
        isPreparingTermination = true
        Task { @MainActor [weak self] in
            let didSave = await coordinator.prepareToTerminate()
            if didSave {
                self?.releaseSecurityScope()
            } else {
                self?.isPreparingTermination = false
                self?.window?.makeKeyAndOrderFront(nil)
            }
            sender.reply(toApplicationShouldTerminate: didSave)
        }
        return .terminateLater
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
        let media = urls.map(localMedia(for:))
        releaseSecurityScope()
        securityScopedURLs = newSecurityScopedURLs
        guard let coordinator else { return }
        Task { await coordinator.open(media) }
    }

    private func openExternalSubtitle(_ action: ExternalSubtitlePanelAction) {
        guard let window, let coordinator else { return }
        if case .relocate = action,
           coordinator.currentExternalSubtitleReferenceID == nil {
            return
        }
        let panel = NSOpenPanel()
        panel.title = switch action {
        case .selectNew: "选择外部字幕"
        case .relocate: "重新定位外部字幕"
        }
        panel.prompt = "选择"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedSubtitleTypes
        panel.beginSheetModal(for: window) { [weak self, weak coordinator] response in
            guard response == .OK, let url = panel.url, let coordinator else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if url.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(url)
                }
                let bookmark = try? url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                let subtitle = LocalExternalSubtitle(
                    url: url,
                    bookmark: bookmark
                )
                switch action {
                case .relocate:
                    await coordinator.relocateExternalSubtitle(subtitle)
                case .selectNew:
                    await coordinator.selectExternalSubtitle(subtitle)
                }
            }
        }
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
                _ = try? await coordinator.add(
                    localMedia(for: url),
                    to: playlistID
                )
            }
        }
    }

    private func relocateMedia(referenceID: LocalMediaReferenceID) {
        guard let window, let coordinator else { return }
        let panel = NSOpenPanel()
        panel.title = "重新定位本地媒体"
        panel.prompt = "选择"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedMediaTypes
        panel.beginSheetModal(for: window) { [weak self, weak coordinator] response in
            guard response == .OK,
                  let self,
                  let coordinator,
                  let url = panel.url else { return }
            Task { @MainActor in
                if url.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(url)
                }
                let media = localMedia(for: url)
                guard let result = try? await coordinator.relocateMissingMedia(
                    referenceID: referenceID,
                    to: media
                ) else { return }
                if case .confirmationRequired = result {
                    pendingMediaReplacement = (referenceID, media)
                } else {
                    pendingMediaReplacement = nil
                }
            }
        }
    }

    private func confirmMediaReplacement(referenceID: LocalMediaReferenceID) {
        guard let coordinator,
              let pendingMediaReplacement,
              pendingMediaReplacement.referenceID == referenceID else { return }
        self.pendingMediaReplacement = nil
        Task {
            _ = try? await coordinator.relocateMissingMedia(
                referenceID: referenceID,
                to: pendingMediaReplacement.media,
                confirmedReplacement: true
            )
        }
    }

    private func localMedia(for url: URL) -> LocalMedia {
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

    private static func fileIdentity(for url: URL) -> LocalFileIdentity? {
        guard let identifier = try? url.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier else { return nil }
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: identifier,
            requiringSecureCoding: false
        ) else { return nil }
        return LocalFileIdentity(rawValue: data)
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

    private static let supportedSubtitleTypes = ["srt", "ass", "ssa", "sup"]
        .compactMap { UTType(filenameExtension: $0) }
}
