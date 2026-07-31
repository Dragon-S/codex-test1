#!/usr/bin/env swift

import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "/tmp/libmpv-smoke.mov"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: outputURL)

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
let width = 640
let height = 360
let frameRate: Int32 = 30
let seconds = 5
let frameCount = Int(frameRate) * seconds

let videoInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_500_000,
            AVVideoMaxKeyFrameIntervalKey: 60,
        ],
    ]
)
videoInput.expectsMediaDataInRealTime = false

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoInput,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
)

guard writer.canAdd(videoInput) else {
    fatalError("AVAssetWriter 无法添加视频输入")
}
writer.add(videoInput)
guard writer.startWriting() else {
    fatalError("AVAssetWriter 启动失败：\(writer.error?.localizedDescription ?? "未知错误")")
}
writer.startSession(atSourceTime: .zero)

for frame in 0..<frameCount {
    while !videoInput.isReadyForMoreMediaData {
        Thread.sleep(forTimeInterval: 0.001)
    }

    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pixelBuffer = buffer else {
        fatalError("无法分配像素缓冲区")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
    )!

    let progress = CGFloat(frame) / CGFloat(frameCount - 1)
    context.setFillColor(
        red: 0.08 + 0.3 * progress,
        green: 0.12,
        blue: 0.35 + 0.4 * (1 - progress),
        alpha: 1
    )
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let barX = CGFloat(frame % width)
    context.setFillColor(red: 1, green: 0.75, blue: 0.15, alpha: 1)
    context.fill(CGRect(x: barX, y: 70, width: 24, height: 220))

    let frameText = "PROTOTYPE \(frame + 1)/\(frameCount)"
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: frameText, attributes: attributes)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(at: NSPoint(x: 34, y: 28))
    NSGraphicsContext.restoreGraphicsState()

    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let presentationTime = CMTime(value: Int64(frame), timescale: frameRate)
    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        fatalError("写入第 \(frame) 帧失败：\(writer.error?.localizedDescription ?? "未知错误")")
    }
}

videoInput.markAsFinished()
writer.finishWriting {
    if writer.status == .completed {
        print(outputPath)
        exit(0)
    }
    fputs("生成失败：\(writer.error?.localizedDescription ?? "未知错误")\n", stderr)
    exit(1)
}
RunLoop.current.run()
