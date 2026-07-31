//
//  SyntheticClip.swift
//  verticalizeTests
//
//  A landscape clip whose pixels encode position: eight vertical colour bands
//  make the horizontal crop readable from the output, and a white top stripe
//  with a black bottom stripe makes vertical orientation readable. That is what
//  lets the composition tests assert on real rendered frames rather than on
//  arithmetic that merely agrees with itself.
//

import AVFoundation
import CoreGraphics
import Foundation

enum SyntheticClip {

    static let bands: [(CGFloat, CGFloat, CGFloat)] = [
        (1, 0, 0), (1, 0.5, 0), (1, 1, 0), (0, 1, 0),
        (0, 1, 1), (0, 0, 1), (0.5, 0, 1), (1, 0, 1),
    ]

    private static let lock = NSLock()
    private static var cached: [String: URL] = [:]

    /// Generated once per process and reused; writing a clip takes seconds.
    static func url(seconds: Double = 4, width: Int = 1280, height: Int = 720) throws -> URL {
        let key = "\(seconds)-\(width)x\(height)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = cached[key], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verticalize-fixture-\(key).mov")
        try write(to: url, seconds: seconds, width: width, height: height)
        cached[key] = url
        return url
    }

    private static func write(to url: URL, seconds: Double, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bandWidth = CGFloat(width) / CGFloat(bands.count)

        for frame in 0..<Int(Double(fps) * seconds) {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
            guard let buffer = pixelBuffer else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )!
            for (i, colour) in bands.enumerated() {
                context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
                context.fill(CGRect(x: CGFloat(i) * bandWidth, y: 0,
                                    width: bandWidth, height: CGFloat(height)))
            }
            // CGContext is bottom-left origin, so the white stripe drawn at the
            // top of the coordinate space is the visual top of the frame.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: CGFloat(height) * 0.9,
                                width: CGFloat(width), height: CGFloat(height) * 0.1))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.1))
            CVPixelBufferUnlockBaseAddress(buffer, [])

            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)
            )
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - Pixel probing

struct RGB: CustomStringConvertible {
    var r: Double, g: Double, b: Double

    func isNear(_ other: RGB, tolerance: Double = 0.14) -> Bool {
        abs(r - other.r) < tolerance
            && abs(g - other.g) < tolerance
            && abs(b - other.b) < tolerance
    }

    var description: String { String(format: "(%.2f, %.2f, %.2f)", r, g, b) }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)
    static func band(_ index: Int) -> RGB {
        let c = SyntheticClip.bands[index]
        return RGB(r: Double(c.0), g: Double(c.1), b: Double(c.2))
    }
}

enum Frames {
    static func image(of url: URL, at seconds: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil
        )
    }

    /// Samples at normalized coordinates with a top-left origin.
    static func sample(_ image: CGImage, x: Double, y: Double) -> RGB {
        let px = min(max(Int(x * Double(image.width)), 0), image.width - 1)
        let py = min(max(Int(y * Double(image.height)), 0), image.height - 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -px, y: -(image.height - 1 - py),
                                       width: image.width, height: image.height))
        return RGB(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
    }
}
