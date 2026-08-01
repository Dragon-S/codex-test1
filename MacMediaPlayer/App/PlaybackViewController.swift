import AppKit
import SwiftUI

final class PlaybackViewController: NSViewController {
    let videoView: PlaybackCanvasView

    private let controlsView: NSHostingView<PlaybackControlsView>
    private let nowPlayingListView: NSHostingView<NowPlayingListView>

    init(
        coordinator: PlaybackCoordinator,
        openMedia: @escaping () -> Void,
        openExternalSubtitle: @escaping () -> Void,
        addMediaToPlaylist: @escaping (PlaylistID) -> Void,
        videoView: PlaybackCanvasView
    ) {
        self.videoView = videoView
        controlsView = NSHostingView(
            rootView: PlaybackControlsView(
                coordinator: coordinator,
                openMedia: openMedia,
                openExternalSubtitle: openExternalSubtitle
            )
        )
        nowPlayingListView = NSHostingView(
            rootView: NowPlayingListView(
                coordinator: coordinator,
                addMediaToPlaylist: addMediaToPlaylist
            )
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func loadView() {
        let container = NSView()
        videoView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        nowPlayingListView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)
        container.addSubview(controlsView)
        container.addSubview(nowPlayingListView)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: nowPlayingListView.leadingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            controlsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            nowPlayingListView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nowPlayingListView.topAnchor.constraint(equalTo: container.topAnchor),
            nowPlayingListView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            nowPlayingListView.widthAnchor.constraint(equalToConstant: 260),
        ])
        view = container
    }
}
