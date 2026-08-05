import AppKit
import SwiftUI

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

    private let controlsView: NSHostingView<PlaybackControlsView>
    private let audioNowPlayingView: NSHostingView<AudioNowPlayingView>
    private let nowPlayingListView: NSHostingView<NowPlayingListView>
    private let playlistToggleButton = NSButton()
    private var canvasBesidePlaylistConstraint: NSLayoutConstraint?
    private var canvasFullWidthConstraint: NSLayoutConstraint?
    private var controlsAutoHideWorkItem: DispatchWorkItem?

    init(
        coordinator: PlaybackCoordinator,
        openMedia: @escaping () -> Void,
        openExternalSubtitle: @escaping () -> Void,
        relocateExternalSubtitle: @escaping () -> Void,
        addMediaToPlaylist: @escaping (PlaylistID) -> Void,
        relocateMissingMedia: @escaping (LocalMediaReferenceID) -> Void,
        confirmMediaReplacement: @escaping (LocalMediaReferenceID) -> Void,
        cancelMediaReplacement: @escaping () -> Void,
        videoView: PlaybackCanvasView
    ) {
        self.videoView = videoView
        controlsView = NSHostingView(
            rootView: PlaybackControlsView(
                coordinator: coordinator,
                openMedia: openMedia,
                openExternalSubtitle: openExternalSubtitle,
                relocateExternalSubtitle: relocateExternalSubtitle
            )
        )
        audioNowPlayingView = NSHostingView(
            rootView: AudioNowPlayingView(coordinator: coordinator)
        )
        nowPlayingListView = NSHostingView(
            rootView: NowPlayingListView(
                coordinator: coordinator,
                addMediaToPlaylist: addMediaToPlaylist,
                relocateMissingMedia: relocateMissingMedia,
                confirmMediaReplacement: confirmMediaReplacement,
                cancelMediaReplacement: cancelMediaReplacement
            )
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func loadView() {
        let container = TheaterContainerView()
        container.pointerActivity = { [weak self] in self?.handlePointerActivity() }
        container.escapeKeyDown = { [weak self] in
            guard let self else { return false }
            return handleEscapeKey() != .ignored
        }
        videoView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        audioNowPlayingView.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingListView.translatesAutoresizingMaskIntoConstraints = false
        playlistToggleButton.translatesAutoresizingMaskIntoConstraints = false
        playlistToggleButton.title = "隐藏 Playlist"
        playlistToggleButton.bezelStyle = .texturedRounded
        playlistToggleButton.target = self
        playlistToggleButton.action = #selector(togglePlaylist)
        playlistToggleButton.setAccessibilityLabel("显示或隐藏 Playlist")
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
            nowPlayingListView.widthAnchor.constraint(equalToConstant: 260),
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

    private func setControlsVisible(_ isVisible: Bool) {
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
        playlistToggleButton.title = isPlaylistVisible ? "隐藏 Playlist" : "显示 Playlist"
        let overlaysCanvas = isFullScreen || !isPlaylistVisible
        canvasBesidePlaylistConstraint?.isActive = !overlaysCanvas
        canvasFullWidthConstraint?.isActive = overlaysCanvas
        view.needsLayout = true
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

private final class TheaterContainerView: NSView {
    var pointerActivity: (() -> Void)?
    var escapeKeyDown: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }

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
        if event.keyCode == 53, escapeKeyDown?() == true {
            return
        }
        super.keyDown(with: event)
    }
}
