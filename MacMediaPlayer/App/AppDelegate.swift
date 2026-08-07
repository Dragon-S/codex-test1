import AppKit
import UniformTypeIdentifiers

extension NSWindow {
    @MainActor
    @discardableResult
    func focusForAccessibility(_ responder: NSResponder) -> Bool {
        if let view = responder as? NSView {
            guard view.window === self, view.acceptsFirstResponder else { return false }
        }
        guard makeFirstResponder(responder), firstResponder === responder else { return false }
        if let view = responder as? NSView {
            NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
        }
        return true
    }
}

@MainActor
private protocol AccessibilityFocusElement: AnyObject {
    func accessibilityTopLevelUIElement() -> Any?
    func setAccessibilityFocused(_ accessibilityFocused: Bool)
    func isAccessibilityFocused() -> Bool
}

extension NSView: AccessibilityFocusElement {}
extension NSAccessibilityElement: AccessibilityFocusElement {}
extension NSCell: AccessibilityFocusElement {}

@MainActor
final class WindowAccessibilityFocusReturn {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private weak var accessibilityElement: (any AccessibilityFocusElement)?

    init(
        window: NSWindow,
        accessibilityFocusedElement: Any? = NSApp.accessibilityApplicationFocusedUIElement()
    ) {
        self.window = window
        responder = window.firstResponder
        accessibilityElement = accessibilityFocusedElement as? any AccessibilityFocusElement
    }

    @discardableResult
    func restore() -> Bool {
        guard let window else { return false }
        if let accessibilityElement,
           restoreAccessibilityFocus(to: accessibilityElement, in: window) {
            return true
        }
        guard let responder else { return false }
        return window.focusForAccessibility(responder)
    }

    private func restoreAccessibilityFocus(
        to element: any AccessibilityFocusElement,
        in window: NSWindow
    ) -> Bool {
        if let view = element as? NSView,
           window.focusForAccessibility(view) {
            return true
        }
        guard belongsToWindow(element.accessibilityTopLevelUIElement(), window: window) else {
            return false
        }
        element.setAccessibilityFocused(true)
        guard element.isAccessibilityFocused() else { return false }
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        return true
    }

    private func belongsToWindow(_ topLevelElement: Any?, window: NSWindow) -> Bool {
        if let view = topLevelElement as? NSView {
            return view.window === window
        }
        return topLevelElement as AnyObject? === window
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum ExternalSubtitlePanelAction {
        case selectNew
        case relocate
    }

    private var window: NSWindow?
    private var coordinator: PlaybackCoordinator?
    private var systemMediaKeyController: SystemMediaKeyController?
    private var securityScopedURLs: [URL] = []
    private var pendingMediaReplacement: (referenceID: LocalMediaReferenceID, media: LocalMedia)?
    private let localMediaFactory = FileSystemLocalMediaFactory()
    private var isPreparingTermination = false
    private let localization: AppLocalization

    init(localization: AppLocalization = .live) {
        self.localization = localization
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
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
            ),
            messages: localization
        )
        self.coordinator = coordinator
        systemMediaKeyController = SystemMediaKeyController(coordinator: coordinator)

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
            importFolderToPlaylist: { [weak self] playlistID in
                self?.importFolder(to: playlistID)
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
            videoView: videoView,
            localization: localization
        )
        let window = PlaybackWindow(contentViewController: viewController)
        viewController.installKeyboardHandling(on: window)
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
        systemMediaKeyController?.invalidate()
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

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenu = NSMenu(title: "Mac Media Player")
        let applicationItem = NSMenuItem(title: "Mac Media Player", action: nil, keyEquivalent: "")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        applicationMenu.addItem(
            withTitle: localization.text("menu.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let quitItem = applicationMenu.addItem(
            withTitle: localization.text("menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command

        let fileMenu = NSMenu(title: localization.text("menu.file"))
        let fileItem = NSMenuItem(title: localization.text("menu.file"), action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let openItem = fileMenu.addItem(
            withTitle: localization.text("action.open"),
            action: #selector(openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        openItem.keyEquivalentModifierMask = .command

        let editMenu = NSMenu(title: localization.text("menu.edit"))
        let editItem = NSMenuItem(title: localization.text("menu.edit"), action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        addResponderMenuItem(to: editMenu, title: localization.text("menu.undo"), action: "undo:", key: "z")
        addResponderMenuItem(
            to: editMenu,
            title: localization.text("menu.redo"),
            action: "redo:",
            key: "Z",
            modifiers: [.command, .shift]
        )
        editMenu.addItem(.separator())
        addResponderMenuItem(to: editMenu, title: localization.text("menu.cut"), action: "cut:", key: "x")
        addResponderMenuItem(to: editMenu, title: localization.text("menu.copy"), action: "copy:", key: "c")
        addResponderMenuItem(to: editMenu, title: localization.text("menu.paste"), action: "paste:", key: "v")
        addResponderMenuItem(to: editMenu, title: localization.text("menu.selectAll"), action: "selectAll:", key: "a")

        let viewMenu = NSMenu(title: localization.text("menu.view"))
        let viewItem = NSMenuItem(title: localization.text("menu.view"), action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let fullScreenItem = viewMenu.addItem(
            withTitle: localization.text("menu.enterFullScreen"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]

        return mainMenu
    }

    @objc private func openDocument(_ sender: Any?) {
        openMedia()
    }

    private func addResponderMenuItem(
        to menu: NSMenu,
        title: String,
        action: String,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) {
        let item = menu.addItem(
            withTitle: title,
            action: Selector(action),
            keyEquivalent: key
        )
        item.keyEquivalentModifierMask = modifiers
    }

    private func openMedia() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = localization.text("panel.openMedia.title")
        panel.prompt = localization.text("action.openPlain")
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
        let media = urls.map(localMediaFactory.media(for:))
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
        case .selectNew: localization.text("panel.selectSubtitle.title")
        case .relocate: localization.text("panel.relocateSubtitle.title")
        }
        panel.prompt = localization.text("action.choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedSubtitleTypes
        let focusReturn = WindowAccessibilityFocusReturn(window: window)
        panel.beginSheetModal(for: window) { [weak self, weak coordinator] response in
            defer { focusReturn.restore() }
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
        panel.title = localization.text("panel.addMedia.title")
        panel.prompt = localization.text("action.add")
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
                    localMediaFactory.media(for: url),
                    to: playlistID
                )
            }
        }
    }

    private func importFolder(to playlistID: PlaylistID) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = localization.text("panel.importFolder.title")
        panel.prompt = localization.text("action.choose")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.chooseFolderImportPolicy(for: folder, playlistID: playlistID)
        }
    }

    private func chooseFolderImportPolicy(for folder: URL, playlistID: PlaylistID) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = localization.text("folderImport.duplicates.title")
        alert.informativeText = localization.text("folderImport.duplicates.message")
        alert.addButton(withTitle: localization.text("folderImport.duplicates.skip"))
        alert.addButton(withTitle: localization.text("folderImport.duplicates.allow"))
        alert.addButton(withTitle: localization.text("action.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            let policy: FolderImportDuplicatePolicy
            switch response {
            case .alertFirstButtonReturn:
                policy = .skipExisting
            case .alertSecondButtonReturn:
                policy = .allowDuplicates
            default:
                return
            }
            self?.performFolderImport(folder, playlistID: playlistID, policy: policy)
        }
    }

    private func performFolderImport(
        _ folder: URL,
        playlistID: PlaylistID,
        policy: FolderImportDuplicatePolicy
    ) {
        guard let coordinator else { return }
        if folder.startAccessingSecurityScopedResource() {
            securityScopedURLs.append(folder)
        }
        Task { @MainActor [weak self] in
            do {
                let report = try await coordinator.importFolder(
                    folder,
                    into: playlistID,
                    duplicatePolicy: policy
                )
                self?.showFolderImportResult(report)
            } catch is CancellationError {
            } catch {
                self?.showFolderImportFailure(error)
            }
        }
    }

    private func showFolderImportResult(_ report: FolderImportReport) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = localization.text("folderImport.complete.title")
        alert.informativeText = localization.format(
            "folderImport.complete.summary",
            localization.integer(report.addedCount),
            localization.integer(report.skippedCount),
            localization.integer(report.failedCount)
        )
        alert.addButton(withTitle: localization.text("action.ok"))
        alert.beginSheetModal(for: window)
    }

    private func showFolderImportFailure(_ error: any Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = localization.text("folderImport.failed.title")
        alert.informativeText = localization.text("folderImport.failed.message")
        alert.addButton(withTitle: localization.text("action.ok"))
        alert.beginSheetModal(for: window)
    }

    private func relocateMedia(referenceID: LocalMediaReferenceID) {
        guard let window, let coordinator else { return }
        let panel = NSOpenPanel()
        panel.title = localization.text("panel.relocateMedia.title")
        panel.prompt = localization.text("action.choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedMediaTypes
        let focusReturn = WindowAccessibilityFocusReturn(window: window)
        panel.beginSheetModal(for: window) { [weak self, weak coordinator] response in
            defer { focusReturn.restore() }
            guard response == .OK,
                  let self,
                  let coordinator,
                  let url = panel.url else { return }
            Task { @MainActor in
                if url.startAccessingSecurityScopedResource() {
                    securityScopedURLs.append(url)
                }
                let media = localMediaFactory.media(for: url)
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
            return try SQLitePlaylistStore(
                databaseURL: directory.appending(path: "playlists.sqlite"),
                messages: localization
            )
        } catch {
            return UnavailablePlaylistStore(message: localization.text("error.openPlaylistStore"))
        }
    }

    private func releaseSecurityScope() {
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedURLs = []
    }

    private static let supportedMediaTypes = MVPSelectableMediaFormats.filenameExtensions
        .compactMap { UTType(filenameExtension: $0) }

    private static let supportedSubtitleTypes = ["srt", "ass", "ssa", "sup"]
        .compactMap { UTType(filenameExtension: $0) }
}
