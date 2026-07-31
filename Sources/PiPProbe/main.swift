import AppKit
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import MPVProbeBridge

private final class VideoSurfaceView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }
}

private final class MPVBridge: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let renderQueue = DispatchQueue(
        label: "prototype.libmpv-pip.render",
        qos: .userInteractive
    )

    private(set) var handle: OpaquePointer?
    private var latestRenderMilliseconds = 0.0
    private var renderedFrames = 0
    private var renderSamples: [Double] = []
    private var renderPending = false
    private var clockStarted = false
    private var formatDescription: CMVideoFormatDescription?
    private var formatSize = (width: 0, height: 0)

    var onFrame: (() -> Void)?

    var renderMetrics: (
        frames: Int,
        latest: Double,
        average: Double,
        p95: Double
    ) {
        renderQueue.sync {
            let sorted = renderSamples.sorted()
            let average = sorted.isEmpty
                ? 0
                : sorted.reduce(0, +) / Double(sorted.count)
            let p95Index = sorted.isEmpty
                ? 0
                : min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
            return (
                renderedFrames,
                latestRenderMilliseconds,
                average,
                sorted.isEmpty ? 0 : sorted[p95Index]
            )
        }
    }

    init(path: String, displayLayer: AVSampleBufferDisplayLayer) throws {
        self.displayLayer = displayLayer

        var error = [CChar](repeating: 0, count: 512)
        handle = path.withCString { pathPointer in
            mpv_probe_create(pathPointer, &error, error.count)
        }
        guard let handle else {
            let message = String(
                decoding: error.prefix { $0 != 0 }.map(UInt8.init),
                as: UTF8.self
            )
            throw NSError(
                domain: "PiPProbe",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        mpv_probe_set_render_callback(
            handle,
            pip_probe_render_requested,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        if let handle {
            mpv_probe_set_render_callback(handle, nil, nil)
            mpv_probe_destroy(handle)
        }
    }

    func requestRender() {
        renderQueue.async { [weak self] in
            guard let self, !self.renderPending else {
                return
            }
            self.renderPending = true
            defer { self.renderPending = false }
            self.renderFrame()
        }
    }

    func pollEvents() {
        if let handle {
            mpv_probe_poll_events(handle)
        }
    }

    var currentTime: Double {
        handle.map(mpv_probe_time) ?? 0
    }

    var duration: Double {
        handle.map(mpv_probe_duration) ?? 0
    }

    var isPaused: Bool {
        handle.map(mpv_probe_is_paused) ?? true
    }

    func setPaused(_ paused: Bool) {
        guard let handle else {
            return
        }
        mpv_probe_set_paused(handle, paused)
        syncClock(force: true)
    }

    func seek(by seconds: Double) {
        guard let handle else {
            return
        }
        mpv_probe_seek_relative(handle, seconds)
        clockStarted = false
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
    }

    func property(_ name: String) -> String {
        guard let handle else {
            return ""
        }
        var output = [CChar](repeating: 0, count: 256)
        name.withCString { namePointer in
            mpv_probe_copy_property(
                handle,
                namePointer,
                &output,
                output.count
            )
        }
        return String(
            decoding: output.prefix { $0 != 0 }.map(UInt8.init),
            as: UTF8.self
        )
    }

    private func renderFrame() {
        guard let handle else {
            return
        }

        let sourceWidth = Int(mpv_probe_video_width(handle))
        let sourceHeight = Int(mpv_probe_video_height(handle))
        guard sourceWidth > 0, sourceHeight > 0 else {
            return
        }

        let width = min(sourceWidth, 1920)
        let height = max(2, Int(
            (Double(sourceHeight) * Double(width) / Double(sourceWidth))
                .rounded()
        ) & ~1)

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let start = ContinuousClock.now
        let renderStatus = mpv_probe_render(
            handle,
            CVPixelBufferGetBaseAddress(pixelBuffer),
            Int32(width),
            Int32(height),
            CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        let elapsed = start.duration(to: ContinuousClock.now).components
        latestRenderMilliseconds =
            Double(elapsed.seconds) * 1_000 +
            Double(elapsed.attoseconds) / 1_000_000_000_000_000
        renderSamples.append(latestRenderMilliseconds)
        if renderSamples.count > 120 {
            renderSamples.removeFirst(renderSamples.count - 120)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard renderStatus >= 0 else {
            return
        }

        if formatDescription == nil ||
            formatSize.width != width ||
            formatSize.height != height {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            formatDescription = description
            formatSize = (width, height)
        }
        guard let formatDescription else {
            return
        }

        let mediaTime = currentTime
        let presentationTime = CMTime(
            seconds: mediaTime,
            preferredTimescale: 600
        )
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            return
        }

        syncClock(force: false)
        if displayLayer.sampleBufferRenderer.isReadyForMoreMediaData {
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            renderedFrames += 1
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?()
            }
        }
    }

    private func syncClock(force: Bool) {
        let target = CMTime(seconds: currentTime, preferredTimescale: 600)
        let current = synchronizer.currentTime()
        let drift = abs(CMTimeGetSeconds(current - target))
        if force || !clockStarted || drift > 0.150 {
            synchronizer.setRate(
                isPaused ? 0 : 1,
                time: target,
                atHostTime: CMClockGetTime(CMClockGetHostTimeClock())
            )
            clockStarted = true
        }
    }
}

@_cdecl("pip_probe_render_requested")
private func pip_probe_render_requested(_ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }
    Unmanaged<MPVBridge>
        .fromOpaque(context)
        .takeUnretainedValue()
        .requestRender()
}

private final class PiPPlaybackDelegate:
    NSObject,
    AVPictureInPictureSampleBufferPlaybackDelegate
{
    weak var bridge: MPVBridge?

    init(bridge: MPVBridge) {
        self.bridge = bridge
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        bridge?.setPaused(!playing)
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let bridge, bridge.duration > 0 else {
            return .invalid
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(
                seconds: bridge.duration,
                preferredTimescale: 600
            )
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        bridge?.isPaused ?? true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        print(
            "PiP 渲染尺寸变为 \(newRenderSize.width)×\(newRenderSize.height)"
        )
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion handler: @escaping () -> Void
    ) {
        bridge?.seek(by: CMTimeGetSeconds(skipInterval))
        handler()
        pictureInPictureController.invalidatePlaybackState()
    }
}

private final class ProbeViewController: NSViewController {
    private let surface = VideoSurfaceView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在载入…")
    private let playButton = NSButton(title: "暂停", target: nil, action: nil)
    private let pipButton = NSButton(
        title: "进入画中画",
        target: nil,
        action: nil
    )

    private var bridge: MPVBridge!
    private var playbackDelegate: PiPPlaybackDelegate!
    private var pipController: AVPictureInPictureController!
    private var timer: Timer?

    init(path: String) throws {
        super.init(nibName: nil, bundle: nil)
        bridge = try MPVBridge(
            path: path,
            displayLayer: surface.displayLayer
        )
        playbackDelegate = PiPPlaybackDelegate(bridge: bridge)
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: surface.displayLayer,
            playbackDelegate: playbackDelegate
        )
        pipController = AVPictureInPictureController(contentSource: source)
        bridge.onFrame = { [weak self] in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func loadView() {
        let root = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        playButton.translatesAutoresizingMaskIntoConstraints = false
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        pipButton.target = self
        pipButton.action = #selector(togglePiP)

        let controls = NSStackView(
            views: [playButton, pipButton]
        )
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(surface)
        root.addSubview(controls)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.heightAnchor.constraint(
                equalTo: surface.widthAnchor,
                multiplier: 9.0 / 16.0
            ),
            controls.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: 16
            ),
            controls.topAnchor.constraint(
                equalTo: surface.bottomAnchor,
                constant: 12
            ),
            statusLabel.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: 16
            ),
            statusLabel.trailingAnchor.constraint(
                equalTo: root.trailingAnchor,
                constant: -16
            ),
            statusLabel.topAnchor.constraint(
                equalTo: controls.bottomAnchor,
                constant: 12
            ),
            statusLabel.bottomAnchor.constraint(
                equalTo: root.bottomAnchor,
                constant: -16
            )
        ])

        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timer = .scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bridge.pollEvents()
                self?.refresh()
            }
        }
    }

    @objc private func togglePlayback() {
        bridge.setPaused(!bridge.isPaused)
        pipController.invalidatePlaybackState()
        refresh()
    }

    @objc private func togglePiP() {
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
        refresh()
    }

    private func refresh() {
        let time = bridge.currentTime
        let duration = bridge.duration
        let primaries = bridge.property("video-params/primaries")
        let transfer = bridge.property("video-params/gamma")
        let subtitle = bridge.property("sid")
        let audio = bridge.property("aid")
        let metrics = bridge.renderMetrics
        playButton.title = bridge.isPaused ? "播放" : "暂停"
        pipButton.title = pipController.isPictureInPictureActive
            ? "退出画中画"
            : "进入画中画"
        pipButton.isEnabled = pipController.isPictureInPicturePossible
        statusLabel.stringValue = """
        媒体时间 \(String(format: "%.2f", time)) / \
        \(String(format: "%.2f", duration)) 秒
        帧 \(metrics.frames)，CPU 渲染 最近/平均/P95 \
        \(String(format: "%.2f", metrics.latest)) / \
        \(String(format: "%.2f", metrics.average)) / \
        \(String(format: "%.2f", metrics.p95)) ms
        音轨 \(audio.isEmpty ? "无" : audio)，字幕 \
        \(subtitle.isEmpty ? "无" : subtitle)
        源色彩 \(primaries.isEmpty ? "未知" : primaries) / \
        \(transfer.isEmpty ? "未知" : transfer)
        桥接输出：8-bit BGRA SDR；字幕由 libmpv 合成进画面
        PiP 支持 \(AVPictureInPictureController.isPictureInPictureSupported())，\
        当前可启动 \(pipController.isPictureInPicturePossible)
        """
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2 else {
            presentFatal("用法：pip-probe /绝对路径/视频文件")
            return
        }

        let path = CommandLine.arguments[1]
        do {
            let controller = try ProbeViewController(path: path)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable
                ],
                backing: .buffered,
                defer: false
            )
            window.title = "PROTOTYPE — libmpv 原生画中画探针"
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 960, height: 700))
            window.minSize = NSSize(width: 720, height: 540)
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            presentFatal(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "无法启动 PiP 探针"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
