import AppKit
import Foundation
import OpenGL.GL3
import Testing
@testable import MacMediaPlayer

@MainActor
@Suite(.serialized)
struct LibMPVPlaybackEngineContractTests {
    @Test("真实适配器将 libmpv 失败映射为稳定领域错误")
    func realAdapterMapsFailuresToDomainErrors() {
        #expect(LibMPVPlaybackEngine.failure(for: .unreadable) == .unreadable)
        #expect(LibMPVPlaybackEngine.failure(for: .unsupported) == .unsupported)
        #expect(LibMPVPlaybackEngine.failure(for: .corrupted) == .corrupted)
        #expect(LibMPVPlaybackEngine.failure(for: .decoderInitialization) == .decoderInitializationFailed)
        #expect(LibMPVPlaybackEngine.failure(for: .engineUnavailable) == .engineUnavailable)
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
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let loadID = PlaybackLoadID(rawValue: 17)

        await engine.loadUsingSoftwareDecoding(
            LocalMedia(url: mediaURL),
            loadID: loadID
        )

        try await recorder.waitForState(.playing, loadID: loadID)
        let presentation = try await recorder.waitForVideoPresentationWithDimensions(loadID: loadID)
        #expect(presentation.kind == .video)
        #expect(presentation.videoDimensions == VideoDimensions(width: 64, height: 64))
        #expect(!recorder.hasFailure(loadID: loadID))

        await engine.stop()
        try await recorder.waitForState(.stopped, loadID: loadID)
    }

    @Test("真实适配器通过 VideoToolbox 硬件解码加载视频")
    func realAdapterLoadsVideoUsingVideoToolboxHardwareDecoding() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let loadID = PlaybackLoadID(rawValue: 18)

        await engine.load(LocalMedia(url: mediaURL), loadID: loadID)

        try await recorder.waitForState(.playing, loadID: loadID)
        let presentation = try await recorder.waitForVideoPresentationWithDimensions(loadID: loadID)
        #expect(presentation.kind == .video)
        #expect(presentation.videoDimensions == VideoDimensions(width: 64, height: 64))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!recorder.hasFailure(loadID: loadID))

        await engine.stop()
        try await recorder.waitForState(.stopped, loadID: loadID)
    }

    @Test("真实适配器关闭后不执行迟到的硬件解码探测")
    func realAdapterCancelsDelayedHardwareProbeOnShutdown() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let mediaURL = try makeRedMP4()
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let loadID = PlaybackLoadID(rawValue: 19)

        await engine.load(LocalMedia(url: mediaURL), loadID: loadID)
        try await recorder.waitForState(.playing, loadID: loadID)
        _ = try await recorder.waitForVideoPresentationWithDimensions(loadID: loadID)

        await engine.stop()
        try await recorder.waitForState(.stopped, loadID: loadID)
        engine.shutdown()
        try await Task.sleep(for: .milliseconds(200))
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

    @Test("真实适配器不会把被替换媒体的迟到事件标记为新加载")
    func realAdapterKeepsEventsAssociatedWithTheirLoad() async throws {
        let videoView = PlaybackCanvasView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let engine = LibMPVPlaybackEngine(videoView: videoView)
        let recorder = ContractEventRecorder(events: engine.events)
        let availableURL = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: availableURL) }
        let oldLoadID = PlaybackLoadID(rawValue: 41)
        let newLoadID = PlaybackLoadID(rawValue: 42)

        await engine.load(
            LocalMedia(url: URL(fileURLWithPath: "/tmp/replaced-missing-media.mp4")),
            loadID: oldLoadID
        )
        await engine.load(LocalMedia(url: availableURL), loadID: newLoadID)
        try await recorder.waitForState(.playing, loadID: newLoadID)

        #expect(!recorder.hasFailure(loadID: newLoadID))
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
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-frame-\(UUID().uuidString).mp4")
        try data.write(to: url, options: .atomic)
        return url
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
