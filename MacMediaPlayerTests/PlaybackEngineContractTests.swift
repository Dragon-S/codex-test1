import AppKit
import Foundation
import OpenGL.GL3
import Testing
@testable import MacMediaPlayer

@MainActor
@Suite(.serialized)
struct LibMPVPlaybackEngineContractTests {
    @Test("内部资格记录器默认关闭")
    func qualificationRecorderIsDisabledWithoutMarker() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appending(path: "qualification-disabled-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        #expect(InternalQualificationRecorder.enabledRecorder(
            applicationSupportDirectory: supportDirectory
        ) == nil)
    }

    @Test("未启用内部资格记录时不安装采样 handler")
    func qualificationSamplingHandlerIsAbsentWithoutRecorder() {
        #expect(LibMPVPlaybackEngine.qualificationEventHandler(for: nil) == nil)
    }

    @Test("内部资格记录只入队而不在调用线程同步写盘")
    func qualificationRecorderEnqueuesWritesOffTheCallingThread() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "qualification-queued-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appending(path: InternalQualificationRecorder.logName)
        let writerQueue = DispatchQueue(label: "qualification-recorder-test-writer")
        writerQueue.suspend()
        var writerQueueIsSuspended = true
        defer {
            if writerQueueIsSuspended {
                writerQueue.resume()
            }
        }
        let recorder = try InternalQualificationRecorder(
            fileURL: logURL,
            writerQueue: writerQueue
        )

        recorder.recordSubtitleFrame(
            fileName: "qualification-subtitle-frame-0001.png",
            capture: MPVClientScreenshotCapture(succeeded: true, loadID: 7, position: 12.5)
        )
        #expect(try Data(contentsOf: logURL).isEmpty)

        writerQueue.resume()
        writerQueueIsSuspended = false
        await recorder.flush()

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("\"kind\":\"session_started\""))
        #expect(log.contains("\"kind\":\"subtitle_frame_captured\""))
    }

    @Test("显式启用的内部资格记录器只写脱敏播放指标")
    func qualificationRecorderWritesPrivacySafeRealEngineMetrics() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appending(path: "qualification-enabled-\(UUID().uuidString)", directoryHint: .isDirectory)
        let recorderDirectory = supportDirectory
            .appending(path: "MacMediaPlayer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: recorderDirectory,
            withIntermediateDirectories: true
        )
        let marker = recorderDirectory.appending(path: InternalQualificationRecorder.enableMarkerName)
        _ = FileManager.default.createFile(atPath: marker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let recorder = try #require(InternalQualificationRecorder.enabledRecorder(
            applicationSupportDirectory: supportDirectory
        ))
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = NSWindow(
            contentRect: videoView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = videoView
        window.orderFront(nil)
        let engine = LibMPVPlaybackEngine(
            videoView: videoView,
            qualificationRecorder: recorder
        )
        let eventRecorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let loadID = PlaybackLoadID(rawValue: 411)

        await engine.loadUsingSoftwareDecoding(LocalMedia(url: mediaURL), loadID: loadID)
        try await eventRecorder.waitForState(.playing, loadID: loadID)
        _ = try await eventRecorder.waitForVideoPresentationWithDimensions(loadID: loadID)
        await engine.seek(to: 1)
        try await Task.sleep(for: .milliseconds(300))
        await recorder.flush()

        let logURL = recorderDirectory.appending(path: InternalQualificationRecorder.logName)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("\"kind\":\"session_started\""))
        #expect(log.contains("\"kind\":\"load_requested\""))
        #expect(log.contains("\"kind\":\"file_loaded\""))
        #expect(log.contains("\"kind\":\"playback_restart\""))
        #expect(log.contains("\"kind\":\"first_frame_rendered\""))
        #expect(log.contains("\"kind\":\"seek_requested\""))
        #expect(log.contains("\"kind\":\"steady_state_sample\""))
        #expect(!log.contains(mediaURL.lastPathComponent))
        #expect(!log.contains(mediaURL.path))

        let frameURL = recorder.nextSubtitleFrameURL()
        #expect(frameURL.deletingLastPathComponent() == recorderDirectory)
        #expect(frameURL.lastPathComponent == "qualification-subtitle-frame-0001.png")
        recorder.recordSubtitleFrame(
            fileName: frameURL.lastPathComponent,
            capture: MPVClientScreenshotCapture(
                succeeded: true,
                loadID: loadID.rawValue,
                position: 1
            )
        )
        await recorder.flush()
        let updatedLog = try String(contentsOf: logURL, encoding: .utf8)
        #expect(updatedLog.contains("\"kind\":\"subtitle_frame_captured\""))
        #expect(updatedLog.contains("\"fileName\":\"qualification-subtitle-frame-0001.png\""))
        #expect(updatedLog.contains("\"loadID\":411"))
        #expect(updatedLog.contains("\"positionSeconds\":1"))
        #expect(!updatedLog.contains(supportDirectory.path))
    }

    @Test("真实适配器将 libmpv 失败映射为稳定领域错误")
    func realAdapterMapsFailuresToDomainErrors() {
        #expect(LibMPVPlaybackEngine.failure(for: .unreadable) == .unreadable)
        #expect(LibMPVPlaybackEngine.failure(for: .unsupported) == .unsupported)
        #expect(LibMPVPlaybackEngine.failure(for: .corrupted) == .corrupted)
        #expect(LibMPVPlaybackEngine.failure(for: .decoderInitialization) == .decoderInitializationFailed)
        #expect(LibMPVPlaybackEngine.failure(for: .engineUnavailable) == .engineUnavailable)
    }

    @Test("真实适配器在交给 libmpv 前把不可读文件分类为无法读取")
    func realAdapterClassifiesUnreadableFileBeforeLoading() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let media = PermissionMediaFixture(url: try makeSilentWAV())
        defer { media.cleanup() }
        try media.revokeReadAccess()
        let loadID = PlaybackLoadID(rawValue: 16)

        await engine.load(LocalMedia(url: media.url), loadID: loadID)

        try await recorder.waitForState(.loading, loadID: loadID)
        try await recorder.waitForState(.failed(.unreadable), loadID: loadID)
    }

    @Test("真实适配器在成功加载后仍识别被撤销权限的文件")
    func realAdapterClassifiesFileMadeUnreadableAfterLoading() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let media = PermissionMediaFixture(url: try makeSilentWAV())
        defer { media.cleanup() }
        let initialLoadID = PlaybackLoadID(rawValue: 17)
        let revokedLoadID = PlaybackLoadID(rawValue: 18)

        await engine.load(LocalMedia(url: media.url), loadID: initialLoadID)
        try await recorder.waitForState(.playing, loadID: initialLoadID)
        try media.revokeReadAccess()

        await engine.load(LocalMedia(url: media.url), loadID: revokedLoadID)

        try await recorder.waitForState(.loading, loadID: revokedLoadID)
        try await recorder.waitForState(.failed(.unreadable), loadID: revokedLoadID)
    }

    @Test("真实适配器接受由 ACL 授权读取的本地媒体")
    func realAdapterLoadsFileReadableThroughACL() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let media = PermissionMediaFixture(url: try makeSilentWAV())
        defer { media.cleanup() }
        try media.revokeReadAccess()
        try media.grantCurrentUserReadACL()
        let loadID = PlaybackLoadID(rawValue: 19)

        #expect(FileManager.default.isReadableFile(atPath: media.url.path))
        await engine.load(LocalMedia(url: media.url), loadID: loadID)

        try await recorder.waitForState(.playing, loadID: loadID)
        try await recorder.expectNoFailure(loadID: loadID, during: .milliseconds(150))
    }

    @Test("真实 libmpv 适配器履行基础 PlaybackEngine 契约")
    func realAdapterFulfillsBasicPlaybackContract() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let window = NSWindow(contentRect: videoView.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = videoView
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let mediaURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        try await verifyBasicPlaybackEngineContract(
            engine: engine,
            media: LocalMedia(url: mediaURL)
        )
    }

    @Test("真实 libmpv 适配器可显式使用软件解码加载视频")
    func realAdapterLoadsVideoUsingSoftwareDecoding() async throws {
        try await verifyVideoLoad(loadID: PlaybackLoadID(rawValue: 17)) { engine, media, loadID in
            await engine.loadUsingSoftwareDecoding(media, loadID: loadID)
        }
    }

    @Test("真实适配器通过 VideoToolbox 硬件解码加载视频")
    func realAdapterLoadsVideoUsingVideoToolboxHardwareDecoding() async throws {
        try await verifyVideoLoad(loadID: PlaybackLoadID(rawValue: 18)) { engine, media, loadID in
            await engine.load(media, loadID: loadID)
        }
    }

    @Test("真实适配器在加载期间释放后结束事件流")
    func realAdapterFinishesEventsWhenReleasedDuringActiveLoad() async throws {
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        for iteration in 0..<10 {
            let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
            var engine: LibMPVPlaybackEngine? = LibMPVPlaybackEngine(videoView: videoView)
            let events = try #require(engine?.events)
            let recorder = ContractEventRecorder(events: events)
            let loadID = PlaybackLoadID(rawValue: UInt64(100 + iteration))

            await engine?.load(LocalMedia(url: mediaURL), loadID: loadID)
            try await recorder.waitForState(.loading, loadID: loadID)
            engine = nil

            try await recorder.waitForCompletion()
        }
    }

    @Test("真实 libmpv 适配器把首帧输出到 AppKit 画布")
    func realAdapterRendersFirstFrameToAppKitCanvas() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = NSWindow(contentRect: videoView.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = videoView
        window.orderFront(nil)
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let loadID = PlaybackLoadID(rawValue: 1)
        await engine.loadUsingSoftwareDecoding(
            LocalMedia(url: mediaURL),
            loadID: loadID
        )
        try await recorder.waitForState(.playing, loadID: loadID)
        _ = try await recorder.waitForVideoPresentationWithDimensions(loadID: loadID)
        try await expectRedCenterPixel(in: videoView)
    }

    @Test("真实适配器用新加载取消被替换的旧加载")
    func realAdapterCancelsReplacedLoad() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let availableURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: availableURL) }

        try await verifyLoadReplacementContract(
            engine: engine,
            interruptedMedia: LocalMedia(url: availableURL),
            replacementMedia: LocalMedia(url: availableURL)
        )
    }

    @Test("真实适配器发布领域轨道目录并支持音轨与外部字幕选择")
    func realAdapterFulfillsTrackSelectionContract() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeSilentWAV()
        let subtitleURL = FileManager.default.temporaryDirectory
            .appending(path: "external-subtitle-\(UUID().uuidString).srt")
        try "1\n00:00:00,000 --> 00:00:01,000\n测试字幕\n".write(
            to: subtitleURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: mediaURL)
            try? FileManager.default.removeItem(at: subtitleURL)
        }
        let loadID = PlaybackLoadID(rawValue: 73)
        await engine.load(LocalMedia(url: mediaURL), loadID: loadID)
        let catalog = try await recorder.waitForTrackCatalog(loadID: loadID)
        let audioTrack = try #require(catalog.audioTracks.first)
        let catalogCountBeforeExternalSubtitle = recorder.trackCatalogCount(loadID: loadID)

        #expect(await engine.selectAudioTrack(audioTrack.id))
        #expect(await engine.selectSubtitle(.off))
        let result = await engine.loadExternalSubtitle(LocalExternalSubtitle(url: subtitleURL))
        guard case .loaded = result else {
            Issue.record("有效外部字幕本应成功加载，实际为 \(result)")
            return
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.trackCatalogCount(loadID: loadID) == catalogCountBeforeExternalSubtitle)
    }

    @Test("真实适配器把已选择的内嵌 SSA 字幕渲染到 AppKit 画布")
    func realAdapterRendersSelectedEmbeddedSSASubtitleToAppKitCanvas() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let window = NSWindow(
            contentRect: videoView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = videoView
        window.orderFront(nil)
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeEmbeddedSSAMKV()
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: mediaURL)
        }
        let loadID = PlaybackLoadID(rawValue: 75)

        await engine.load(LocalMedia(url: mediaURL), loadID: loadID)
        try await recorder.waitForState(.playing, loadID: loadID)
        let catalog = try await recorder.waitForTrackCatalog(loadID: loadID)
        let subtitleTrack = try #require(catalog.embeddedSubtitleTracks.first)
        await engine.seek(to: 1)
        await engine.pause()
        try await recorder.waitForState(.paused, loadID: loadID)
        videoView.openGLContext?.makeCurrentContext()
        let brightPixelBaseline = brightNeutralPixelCount(in: videoView)

        #expect(await engine.selectSubtitle(.embedded(subtitleTrack.id)))
        try await expectBrightSubtitlePixel(in: videoView, exceeding: brightPixelBaseline)
    }

    @Test("真实适配器发布音频标题与基础元数据并标记封面可用性")
    func realAdapterPublishesAudioPresentation() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeTaggedSilentWAV()
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let loadID = PlaybackLoadID(rawValue: 91)

        await engine.load(LocalMedia(url: mediaURL), loadID: loadID)
        let presentation = try await recorder.waitForMediaPresentation(loadID: loadID)

        #expect(presentation.kind == .audio)
        #expect(presentation.title == "夜航")
        #expect(presentation.artist == "测试艺人")
        #expect(presentation.album == "测试专辑")
        #expect(!presentation.hasArtwork)
    }

    private func verifyVideoLoad(
        loadID: PlaybackLoadID,
        load: (LibMPVPlaybackEngine, LocalMedia, PlaybackLoadID) async -> Void
    ) async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        await load(engine, LocalMedia(url: mediaURL), loadID)

        try await recorder.waitForState(.playing, loadID: loadID)
        let presentation = try await recorder.waitForVideoPresentationWithDimensions(loadID: loadID)
        #expect(presentation.kind == .video)
        #expect(presentation.videoDimensions == VideoDimensions(width: 64, height: 64))
        try await recorder.expectNoFailure(loadID: loadID, during: .milliseconds(150))

        await engine.stop()
        try await recorder.waitForState(.stopped, loadID: loadID)
    }

    private func makeSilentWAV() throws -> URL {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = sampleRate * 2
        let dataSize = sampleCount * 2
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(36 + dataSize)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-contract-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func expectRedCenterPixel(in videoView: PlaybackCanvasView) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            videoView.openGLContext?.makeCurrentContext()
            let frontRed = redComponent(atCenterOf: GLenum(GL_FRONT))
            let backRed = redComponent(atCenterOf: GLenum(GL_BACK))
            if max(frontRed, backRed) > 127 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("等待真实 libmpv 首帧超时")
    }

    private func expectBrightSubtitlePixel(
        in videoView: PlaybackCanvasView,
        exceeding baseline: Int
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            videoView.openGLContext?.makeCurrentContext()
            let brightPixelCount = brightNeutralPixelCount(in: videoView)
            if brightPixelCount > baseline + 100 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("已选择的 SSA 字幕没有渲染到真实 AppKit 画布")
    }

    private func brightNeutralPixelCount(in view: PlaybackCanvasView) -> Int {
        brightNeutralPixelCount(in: GLenum(GL_FRONT), view: view)
            + brightNeutralPixelCount(in: GLenum(GL_BACK), view: view)
    }

    private func brightNeutralPixelCount(in buffer: GLenum, view: PlaybackCanvasView) -> Int {
        glReadBuffer(buffer)
        let backingBounds = view.convertToBacking(view.bounds)
        let width = Int(backingBounds.width)
        let height = Int(backingBounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        glReadPixels(
            0,
            0,
            GLsizei(width),
            GLsizei(height),
            GLenum(GL_RGBA),
            GLenum(GL_UNSIGNED_BYTE),
            &pixels
        )
        return stride(from: 0, to: pixels.count, by: 4).count { index in
            pixels[index] > 180 && pixels[index + 1] > 180 && pixels[index + 2] > 180
        }
    }

    private func redComponent(atCenterOf buffer: GLenum) -> UInt8 {
        glReadBuffer(buffer)
        var pixel: [UInt8] = [0, 0, 0, 0]
        glReadPixels(160, 90, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
        return pixel[0]
    }

    private func makeTaggedSilentWAV() throws -> URL {
        let sampleRate: UInt32 = 8_000
        let sampleCount: UInt32 = sampleRate / 4
        let audioDataSize = sampleCount * 2
        var info = Data()
        info.appendASCII("INFO")
        info.appendRIFFInfo(tag: "INAM", value: "夜航")
        info.appendRIFFInfo(tag: "IART", value: "测试艺人")
        info.appendRIFFInfo(tag: "IPRD", value: "测试专辑")

        var data = Data()
        data.appendASCII("RIFF")
        let riffSize = UInt32(4 + 24 + 8) + audioDataSize + UInt32(8 + info.count)
        data.appendLittleEndian(riffSize)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(audioDataSize)
        data.append(Data(repeating: 0, count: Int(audioDataSize)))
        data.appendASCII("LIST")
        data.appendLittleEndian(UInt32(info.count))
        data.append(info)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-presentation-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeRedMP4() throws -> URL {
        let base64 = """
        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
        """
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-frame-\(UUID().uuidString).mp4")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeEmbeddedSSAMKV() throws -> URL {
        let base64 = """
        GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAOAxFNm3TAv4QI5ew8TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB
        8U27jFOrhBJUw2dTrIIDfE27jFOrhBxTu2tTrIINhOwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsu/hF6Q+5cq17GDD0JATYCNTGF2ZjYyLjEyLjEwMldBjUxhdmY2Mi4xMi4xMDJzpJBY33zt
        Q0EwqrAze5vqsMORRImIQOyQgAAAAAAWVK5rQoW/hLu6HsKuAQAAAAAAAHPXgQFzxYhjKJsbY2k5yJyBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OB
        ASPjg4QB/KBV4ImwgUC6gUCagQJV7oEA7AEAAAAAAAACAABjop8BZAAL/+EADCdkAAusVoMN4EGEUAEABCjuPLD9+PgArgEAAAAAAAH614ECc8WIq39ez7mC
        +i2cgQAitZyDdW5kiIEAhopTX1RFWFQvQVNTg4ERVe6BAGOiQchbU2NyaXB0IEluZm9dClNjcmlwdFR5cGU6IHY0LjAwClBsYXlSZXNYOiAxOTIwClBsYXlS
        ZXNZOiAxMDgwCgpbVjQgU3R5bGVzXQpGb3JtYXQ6IE5hbWUsIEZvbnRuYW1lLCBGb250c2l6ZSwgUHJpbWFyeUNvbG91ciwgU2Vjb25kYXJ5Q29sb3VyLCBU
        ZXJ0aWFyeUNvbG91ciwgQmFja0NvbG91ciwgQm9sZCwgSXRhbGljLCBCb3JkZXJTdHlsZSwgT3V0bGluZSwgU2hhZG93LCBBbGlnbm1lbnQsIE1hcmdpbkws
        IE1hcmdpblIsIE1hcmdpblYsIEFscGhhTGV2ZWwsIEVuY29kaW5nClN0eWxlOiBEZWZhdWx0LEFyaWFsLDU0LCZIMDBGRkZGRkYsJkgwMDAwRkZGRiwmSDAw
        MDAwMDAwLCZIODAwMDAwMDAsMCwwLDEsMywxLDIsNDAsNDAsNTAsMCwxCgpbRXZlbnRzXQpGb3JtYXQ6IE1hcmtlZCwgU3RhcnQsIEVuZCwgU3R5bGUsIE5h
        bWUsIE1hcmdpbkwsIE1hcmdpblIsIE1hcmdpblYsIEVmZmVjdCwgVGV4dAoSVMNnQOO/hDC15SBzc6BjwIBnyJpFo4dFTkNPREVSRIeNTGF2ZjYyLjEyLjEw
        MnNz4WPAi2PFiGMomxtjaTnIZ8isRaOHRU5DT0RFUkSHn0xhdmM2Mi4yOC4xMDIgaDI2NF92aWRlb3Rvb2xib3hnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAy
        LjAwMDAwMDAwMABzc9NjwItjxYirf17PuYL6LWfInkWjh0VOQ09ERVJEh5FMYXZjNjIuMjguMTAyIGFzc2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6NTguNTAw
        MDAwMDAwAB9DtnVJGb+ErtZw4ueBAKNAjYEAAIAAAAA6BgUyR1ZK3FxMQz+U78URPNFDqAEAAAMAAQMAAAMAAQIAAMNQCwAAAwAAAwAAIvYMA4koAQ3/////
        gAAAAEcluCACP7oU/JH/v0bD0BtzHxUD5OV2AEEyXzAEHXUQmkWOKVVCg/grzFDfgbR5lVsS/23snQB0MXeggEGFXQo7c2fGMMaX86OogQAhAAAAACAh4QRN
        /7tleCQXIC9EPCVI5Gk9fR0GUT+cAAAcWW8roKOfgQBDAAAAABch4ghJ/wfo4tROaPBpbGRjlYAMT46EoKOegQBkAAAAABYh4wxXBPbkSefFdCit3C4IAAWv
        76Loo5mBAIUAAAAAESHkEH8DkeDmFMIXaAApJ5dYo5mBAKcAAAAAESHlFH8DkeDmFMIXaAApJ5dYo5mBAMgAAAAAESHmGH8DkeDmFMIXaAApJ5dYo5mBAOkA
        AAAAESHnHH8DkeDmFMIXaAApJ5dYo5mBAQsAAAAAESHoIH8DkeDmFMIXaAApJ5dYo5mBASwAAAAAESHpJH8DkeDmFMIXaAApJ5dYo5mBAU0AAAAAESHqKH8D
        keDmFMIXaAApJ5dYo5mBAW8AAAAAESHrLH8DkeDmFMIXaAApJ5dYo/KBAZCAAAAAGgYFFUdWStxcTEM/lO/FETzRQ6gDAAADAAGAAAAATCW4EAf/3gjjxv+E
        rpibd4OQa0O8PYKbL+gAh6ZzuakwJ9myzYorV69D/m8fYi/T1WuOQ5oMFbryHgAbCtzzATwlC/Cs4GBqRCJTFeCjqYEBsQAAAAAhIeEEf83040C1lJWweuTY
        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
        """
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-ssa-\(UUID().uuidString).mkv")
        try data.write(to: url, options: .atomic)
        return url
    }
}

private final class PermissionMediaFixture {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func revokeReadAccess() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: url.path
        )
    }

    func grantCurrentUserReadACL() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(NSUserName()) allow read", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ACLTestSetupFailure(status: process.terminationStatus)
        }
    }

    func cleanup() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try? FileManager.default.removeItem(at: url)
    }
}

private struct ACLTestSetupFailure: Error, CustomStringConvertible {
    let status: Int32

    var description: String {
        "为测试媒体添加当前用户读取 ACL 失败，chmod 退出码：\(status)"
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendRIFFInfo(tag: String, value: String) {
        appendASCII(tag)
        var encoded = value.data(using: .utf8)!
        encoded.append(0)
        appendLittleEndian(UInt32(encoded.count))
        append(encoded)
        if !encoded.count.isMultiple(of: 2) {
            append(0)
        }
    }
}
