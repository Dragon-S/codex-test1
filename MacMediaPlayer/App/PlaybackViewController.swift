import AppKit
import SwiftUI

final class PlaybackViewController: NSViewController {
    let videoView: PlaybackCanvasView

    private let controlsView: NSHostingView<PlaybackControlsView>

    init(coordinator: PlaybackCoordinator, openMedia: @escaping () -> Void, videoView: PlaybackCanvasView) {
        self.videoView = videoView
        controlsView = NSHostingView(
            rootView: PlaybackControlsView(coordinator: coordinator, openMedia: openMedia)
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
        container.addSubview(videoView)
        container.addSubview(controlsView)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            controlsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
}
