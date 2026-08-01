import AppKit
import Foundation
import OpenGL.GL3
import Testing
@testable import MacMediaPlayer

@MainActor
struct LibMPVPlaybackEngineContractTests {
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

        await engine.load(
            LocalMedia(url: mediaURL),
            loadID: PlaybackLoadID(rawValue: 1)
        )
        try await recorder.wait(for: .playing)
        try await Task.sleep(for: .milliseconds(200))

        videoView.openGLContext?.makeCurrentContext()
        glReadBuffer(GLenum(GL_FRONT))
        var pixel: [UInt8] = [0, 0, 0, 0]
        glReadPixels(160, 90, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
        #expect(pixel[0] > 127)
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
}
