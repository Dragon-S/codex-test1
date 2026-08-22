import AppKit
import Combine
import SwiftUI

@MainActor
final class DisplayAccessibilityPreferences: ObservableObject {
    @Published private(set) var isReduceMotionEnabled: Bool

    private let reduceMotionProvider: @MainActor () -> Bool
    private var displayOptionsCancellable: AnyCancellable?

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        reduceMotionProvider: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.reduceMotionProvider = reduceMotionProvider
        isReduceMotionEnabled = reduceMotionProvider()
        displayOptionsCancellable = notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .sink { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        isReduceMotionEnabled = reduceMotionProvider()
    }
}

private enum PlaybackKeyCode {
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let p: UInt16 = 35
}

enum PlaybackKeyboardShortcut: Equatable {
    case togglePlayback
    case skipBackward
    case skipForward
    case increasePlayerVolume
    case decreasePlayerVolume
    case toggleFullScreen
    case togglePlaylist
    case openMedia

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if modifiers.isEmpty {
            switch event.keyCode {
            case PlaybackKeyCode.space: self = .togglePlayback
            case PlaybackKeyCode.leftArrow: self = .skipBackward
            case PlaybackKeyCode.rightArrow: self = .skipForward
            case PlaybackKeyCode.upArrow: self = .increasePlayerVolume
            case PlaybackKeyCode.downArrow: self = .decreasePlayerVolume
            case PlaybackKeyCode.p where characters == "p": self = .togglePlaylist
            default: return nil
            }
            return
        }
        if modifiers == [.control, .command], characters == "f" {
            self = .toggleFullScreen
        } else if modifiers == .command, characters == "o" {
            self = .openMedia
        } else {
            return nil
        }
    }
}

final class PlaybackViewController: NSViewController {
    enum EscapeKeyResult: Equatable {
        case dismissedPlaylist
        case dismissedControls
        case exitFullScreen
        case ignored
    }

    let videoView: PlaybackCanvasView
    private(set) var isPlaylistVisible = true
    private(set) var isFullScreen = false
    private(set) var isControlsVisible = true
    var isCanvasUsingFullWidth: Bool {
        canvasFullWidthConstraint?.isActive == true
    }

    private let controlsView: NSHostingView<DisplayAccessibleRoot<PlaybackControlsView>>
    private let audioNowPlayingView: NSHostingView<DisplayAccessibleRoot<AudioNowPlayingView>>
    private let nowPlayingListView: FocusableHostingView<DisplayAccessibleRoot<NowPlayingListView>>
    private let coordinator: PlaybackCoordinator
    private let openMedia: () -> Void
    private let localization: AppLocalization
    private let displayPreferences: DisplayAccessibilityPreferences
    private let playlistToggleButton = NSButton()
    private var canvasBesidePlaylistConstraint: NSLayoutConstraint?
    private var canvasFullWidthConstraint: NSLayoutConstraint?
    private var controlsAutoHideWorkItem: DispatchWorkItem?
    private var accessibilityCancellables: Set<AnyCancellable> = []

    init(
        coordinator: PlaybackCoordinator,
        openMedia: @escaping () -> Void,
        openExternalSubtitle: @escaping () -> Void,
        relocateExternalSubtitle: @escaping () -> Void,
        addMediaToPlaylist: @escaping (PlaylistID) -> Void,
        importFolderToPlaylist: @escaping (PlaylistID) -> Void = { _ in },
        relocateMissingMedia: @escaping (LocalMediaReferenceID) -> Void,
        confirmMediaReplacement: @escaping (LocalMediaReferenceID) -> Void,
        cancelMediaReplacement: @escaping () -> Void,
        videoView: PlaybackCanvasView,
        displayPreferences: DisplayAccessibilityPreferences = DisplayAccessibilityPreferences(),
        localization: AppLocalization = .live
    ) {
        self.videoView = videoView
        self.coordinator = coordinator
        self.openMedia = openMedia
        self.localization = localization
        self.displayPreferences = displayPreferences
        controlsView = NSHostingView(
            rootView: DisplayAccessibleRoot(
                content: PlaybackControlsView(
                    coordinator: coordinator,
                    openMedia: openMedia,
                    openExternalSubtitle: openExternalSubtitle,
                    relocateExternalSubtitle: relocateExternalSubtitle,
                    localization: localization
                ),
                preferences: displayPreferences
            )
        )
        audioNowPlayingView = NSHostingView(
            rootView: DisplayAccessibleRoot(
                content: AudioNowPlayingView(
                    coordinator: coordinator,
                    localization: localization
                ),
                preferences: displayPreferences
            )
        )
        nowPlayingListView = FocusableHostingView(
            rootView: DisplayAccessibleRoot(
                content: NowPlayingListView(
                    coordinator: coordinator,
                    addMediaToPlaylist: addMediaToPlaylist,
                    importFolderToPlaylist: importFolderToPlaylist,
                    relocateMissingMedia: relocateMissingMedia,
                    confirmMediaReplacement: confirmMediaReplacement,
                    cancelMediaReplacement: cancelMediaReplacement,
                    localization: localization
                ),
                preferences: displayPreferences
            )
        )
        super.init(nibName: nil, bundle: nil)
        observeAccessibilityAnnouncements()
    }

    var isReduceMotionEnabled: Bool {
        displayPreferences.isReduceMotionEnabled
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func loadView() {
        let container = TheaterContainerView(localization: localization)
        container.pointerActivity = { [weak self] in self?.handlePointerActivity() }
        container.escapeKeyDown = { [weak self] in
            guard let self else { return false }
            return handleEscapeKey() != .ignored
        }
        container.keyboardShortcut = { [weak self] shortcut in
            Task { await self?.performKeyboardShortcut(shortcut) }
        }
        videoView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        audioNowPlayingView.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingListView.translatesAutoresizingMaskIntoConstraints = false
        playlistToggleButton.translatesAutoresizingMaskIntoConstraints = false
        playlistToggleButton.title = localization.text("playlist.hide")
        playlistToggleButton.bezelStyle = .texturedRounded
        playlistToggleButton.target = self
        playlistToggleButton.action = #selector(togglePlaylist)
        updatePlaylistToggleAccessibility()
        nowPlayingListView.setAccessibilityRole(.group)
        nowPlayingListView.setAccessibilityLabel(localization.text("accessibility.playlistSidebar"))
        videoView.setAccessibilityLabel(localization.text("accessibility.playbackCanvas"))
        container.addSubview(videoView)
        container.addSubview(audioNowPlayingView)
        container.addSubview(controlsView)
        container.addSubview(nowPlayingListView)
        container.addSubview(playlistToggleButton)

        let canvasBesidePlaylistConstraint = videoView.trailingAnchor.constraint(
            equalTo: nowPlayingListView.leadingAnchor
        )
        let canvasFullWidthConstraint = videoView.trailingAnchor.constraint(
            equalTo: container.trailingAnchor
        )
        self.canvasBesidePlaylistConstraint = canvasBesidePlaylistConstraint
        self.canvasFullWidthConstraint = canvasFullWidthConstraint

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvasBesidePlaylistConstraint,
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            audioNowPlayingView.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            audioNowPlayingView.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            audioNowPlayingView.topAnchor.constraint(equalTo: videoView.topAnchor),
            audioNowPlayingView.bottomAnchor.constraint(equalTo: videoView.bottomAnchor),
            controlsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            nowPlayingListView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nowPlayingListView.topAnchor.constraint(equalTo: container.topAnchor),
            nowPlayingListView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            nowPlayingListView.widthAnchor.constraint(equalToConstant: 320),
            playlistToggleButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            playlistToggleButton.trailingAnchor.constraint(equalTo: videoView.trailingAnchor, constant: -12),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.acceptsMouseMovedEvents = true
        view.window?.makeFirstResponder(view)
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: view.window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: view.window
        )
    }

    override func viewWillDisappear() {
        NotificationCenter.default.removeObserver(self)
        controlsAutoHideWorkItem?.cancel()
        super.viewWillDisappear()
    }

    override func cancelOperation(_ sender: Any?) {
        if handleEscapeKey() == .ignored {
            super.cancelOperation(sender)
        }
    }

    func setPlaylistVisible(_ isVisible: Bool) {
        guard isPlaylistVisible != isVisible else { return }
        isPlaylistVisible = isVisible
        updateTheaterLayout()
        if isVisible {
            view.window?.focusForAccessibility(nowPlayingListView)
        } else {
            view.window?.focusForAccessibility(playlistToggleButton)
        }
    }

    func setFullScreenMode(_ isFullScreen: Bool) {
        guard self.isFullScreen != isFullScreen else { return }
        self.isFullScreen = isFullScreen
        setControlsVisible(true)
        updateTheaterLayout()
        scheduleControlsAutoHide()
    }

    @discardableResult
    func handleEscapeKey() -> EscapeKeyResult {
        guard isFullScreen else { return .ignored }
        if isPlaylistVisible {
            setPlaylistVisible(false)
            return .dismissedPlaylist
        }
        if isControlsVisible {
            setControlsVisible(false)
            return .dismissedControls
        }
        view.window?.toggleFullScreen(nil)
        return .exitFullScreen
    }

    func handlePointerActivity() {
        guard isFullScreen else { return }
        setControlsVisible(true)
        scheduleControlsAutoHide()
    }

    func performKeyboardShortcut(_ shortcut: PlaybackKeyboardShortcut) async {
        switch shortcut {
        case .togglePlayback:
            await coordinator.togglePlayback()
        case .skipBackward:
            guard coordinator.nowPlayingList.currentMedia != nil else { return }
            await coordinator.skipBackward()
        case .skipForward:
            guard coordinator.nowPlayingList.currentMedia != nil else { return }
            await coordinator.skipForward()
        case .increasePlayerVolume:
            await coordinator.setPlayerVolume(coordinator.playerVolume + 0.05)
        case .decreasePlayerVolume:
            await coordinator.setPlayerVolume(coordinator.playerVolume - 0.05)
        case .toggleFullScreen:
            view.window?.toggleFullScreen(nil)
        case .togglePlaylist:
            togglePlaylist()
        case .openMedia:
            openMedia()
        }
    }

    func installKeyboardHandling(on window: PlaybackWindow) {
        window.playbackShortcutHandler = { [weak self] event, firstResponder in
            self?.handleKeyboardEquivalent(event, firstResponder: firstResponder) ?? false
        }
    }

    func handleKeyboardEquivalent(
        _ event: NSEvent,
        firstResponder: NSResponder?
    ) -> Bool {
        guard let shortcut = PlaybackKeyboardShortcut(event: event) else { return false }
        guard !shouldDefer(shortcut, to: firstResponder) else { return false }
        Task { await performKeyboardShortcut(shortcut) }
        return true
    }

    private func shouldDefer(
        _ shortcut: PlaybackKeyboardShortcut,
        to firstResponder: NSResponder?
    ) -> Bool {
        switch shortcut {
        case .openMedia, .toggleFullScreen:
            return false
        case .togglePlaylist:
            return firstResponder is NSTextView || firstResponder is NSTextField
        case .togglePlayback:
            return isTextEditor(firstResponder)
                || firstResponder is NSButton
                || isFocusedInsideLocalControls(firstResponder)
        case .skipBackward, .skipForward, .increasePlayerVolume, .decreasePlayerVolume:
            return isTextEditor(firstResponder)
                || firstResponder is NSControl
                || isFocusedInsideLocalControls(firstResponder)
        }
    }

    private func isTextEditor(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    private func isFocusedInsideLocalControls(_ responder: NSResponder?) -> Bool {
        guard let focusedView = responder as? NSView else { return false }
        return focusedView === controlsView
            || focusedView.isDescendant(of: controlsView)
            || focusedView === nowPlayingListView
            || focusedView.isDescendant(of: nowPlayingListView)
    }

    private func setControlsVisible(_ isVisible: Bool) {
        if !isVisible,
           let focusedView = view.window?.firstResponder as? NSView,
           focusedView === controlsView
            || focusedView.isDescendant(of: controlsView)
            || focusedView === playlistToggleButton {
            view.window?.makeFirstResponder(view)
        }
        isControlsVisible = isVisible
        controlsView.isHidden = isFullScreen && !isVisible
        playlistToggleButton.isHidden = isFullScreen && !isVisible
    }

    private func scheduleControlsAutoHide() {
        controlsAutoHideWorkItem?.cancel()
        guard isFullScreen, isControlsVisible else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isFullScreen else { return }
            self.setControlsVisible(false)
        }
        controlsAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func updateTheaterLayout() {
        nowPlayingListView.isHidden = !isPlaylistVisible
        playlistToggleButton.title = isPlaylistVisible
            ? localization.text("playlist.hide")
            : localization.text("playlist.show")
        updatePlaylistToggleAccessibility()
        let overlaysCanvas = isFullScreen || !isPlaylistVisible
        if overlaysCanvas {
            canvasBesidePlaylistConstraint?.isActive = false
            canvasFullWidthConstraint?.isActive = true
        } else {
            canvasFullWidthConstraint?.isActive = false
            canvasBesidePlaylistConstraint?.isActive = true
        }
        view.needsLayout = true
    }

    private func observeAccessibilityAnnouncements() {
        coordinator.$nowPlayingList
            .map { $0.currentMedia?.url.lastPathComponent }
            .removeDuplicates()
            .sink { [weak self] name in
                self?.videoView.setAccessibilityValue(
                    name ?? self?.localization.text("accessibility.noCurrentMedia")
                )
            }
            .store(in: &accessibilityCancellables)

        coordinator.$nowPlayingList
            .map { list in
                guard let index = list.currentIndex,
                      list.entries.indices.contains(index) else { return nil }
                let entry = list.entries[index]
                guard entry.media.availability != .missing else { return nil }
                return self.localization.format(
                    "accessibility.currentEntry",
                    entry.media.url.lastPathComponent,
                    index + 1,
                    list.entries.count
                )
            }
            .removeDuplicates()
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] message in self?.announceForAccessibility(message) }
            .store(in: &accessibilityCancellables)

        coordinator.$state
            .removeDuplicates()
            .dropFirst()
            .map { [localization] in
                PlaybackStatusText.announcement(for: $0, localization: localization)
            }
            .sink { [weak self] message in self?.announceForAccessibility(message) }
            .store(in: &accessibilityCancellables)

        coordinator.$isMuted
            .removeDuplicates()
            .dropFirst()
            .map { [localization] in
                localization.text($0 ? "accessibility.muted" : "accessibility.unmuted")
            }
            .sink { [weak self] message in self?.announceForAccessibility(message) }
            .store(in: &accessibilityCancellables)

        coordinator.$persistenceNotice
            .removeDuplicates()
            .dropFirst()
            .compactMap { notice -> String? in
                guard case let .failed(message) = notice else { return nil }
                return self.localization.format("accessibility.storageFailed", message)
            }
            .sink { [weak self] message in self?.announceForAccessibility(message) }
            .store(in: &accessibilityCancellables)

        coordinator.$missingMediaNotice
            .combineLatest(coordinator.$playlists)
            .map { [localization] notice, playlists in
                Self.accessibilityAnnouncement(
                    for: notice,
                    playlists: playlists,
                    localization: localization
                )
            }
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] message in self?.announceForAccessibility(message) }
            .store(in: &accessibilityCancellables)
    }

    private func announceForAccessibility(_ message: String) {
        (viewIfLoaded as? TheaterContainerView)?.announce(message)
    }

    private static func accessibilityAnnouncement(
        for notice: MissingMediaNotice,
        playlists: [Playlist],
        localization: AppLocalization
    ) -> String? {
        switch notice {
        case .none:
            return nil
        case let .recoveryRequired(entryID, _):
            let name = playlists.lazy.flatMap(\.entries)
                .first(where: { $0.id == entryID })
                .map { URL(fileURLWithPath: $0.media.lastKnownPath).lastPathComponent }
                ?? localization.text("media.selectedFile")
            return localization.format("accessibility.fileMissing", name)
        case let .noPlayableEntries(missingCount):
            return localization.format(
                "accessibility.noPlayableEntries",
                localization.integer(missingCount)
            )
        case let .replacementConfirmationRequired(impact):
            return localization.format(
                "accessibility.confirmReplacement",
                localization.integer(impact.affectedPlaylistCount),
                localization.integer(impact.affectedEntryCount)
            )
        }
    }

    private func updatePlaylistToggleAccessibility() {
        let action = localization.text(isPlaylistVisible ? "playlist.hide" : "playlist.show")
        playlistToggleButton.setAccessibilityLabel(action)
        playlistToggleButton.setAccessibilityValue(localization.text(
            isPlaylistVisible ? "accessibility.expanded" : "accessibility.collapsed"
        ))
    }

    @objc private func togglePlaylist() {
        setPlaylistVisible(!isPlaylistVisible)
        if isFullScreen {
            handlePointerActivity()
        }
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        setFullScreenMode(true)
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        setFullScreenMode(false)
    }
}

private final class FocusableHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
}

private final class TheaterContainerView: NSView {
    var pointerActivity: (() -> Void)?
    var escapeKeyDown: (() -> Bool)?
    var keyboardShortcut: ((PlaybackKeyboardShortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init(localization: AppLocalization) {
        super.init(frame: .zero)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(localization.text("accessibility.player"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 2, dy: 2)
    }

    override func drawFocusRingMask() {
        NSBezierPath(rect: focusRingMaskBounds).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        pointerActivity?()
        super.mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == PlaybackKeyCode.escape, escapeKeyDown?() == true {
            return
        }
        if window?.firstResponder === self,
           let shortcut = PlaybackKeyboardShortcut(event: event) {
            keyboardShortcut?(shortcut)
            return
        }
        super.keyDown(with: event)
    }

    func announce(_ message: String) {
        setAccessibilityValue(message)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

final class PlaybackWindow: NSWindow {
    var playbackShortcutHandler: ((NSEvent, NSResponder?) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if playbackShortcutHandler?(event, firstResponder) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
