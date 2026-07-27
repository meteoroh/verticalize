//
//  VideoExporter.swift
//  verticalize
//
//  Reader → video composition → writer. Going through AVAssetWriter instead of
//  AVAssetExportSession means the output resolution is exactly the render size
//  we asked for, rather than whatever a preset decides.
//

import AVFoundation
import CoreMedia
import Foundation

nonisolated enum VideoExporter {

    struct Settings: Sendable {
        var codec: AVVideoCodecType = .h264
        var fileType: AVFileType = .mp4
        /// Bits per pixel per frame. 0.15 is visually transparent for H.264.
        var bitsPerPixel: Double = 0.15

        static let h264 = Settings()
        static let hevc = Settings(codec: .hevc, fileType: .mp4, bitsPerPixel: 0.09)

        var fileExtension: String { fileType == .mov ? "mov" : "mp4" }
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case cannotWrite(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The clip has no video track to export."
            case .cannotWrite(let reason): "Couldn't start writing the file. \(reason)"
            case .failed(let reason): reason
            }
        }
    }

    /// Boxed reader/writer so the cancellation handler can reach them.
    private final class Session: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        private let lock = NSLock()
        private var cancelled = false

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true
            lock.unlock()
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    static func export(
        source: VideoSource,
        path: CropPath,
        to outputURL: URL,
        settings: Settings = .h264,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: source.url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let composition = VerticalComposition.make(
            track: videoTrack, duration: duration, source: source, path: path
        )

        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.failed("This clip's video track can't be re-composed.")
        }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.fileType)
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(for: path, settings: settings)
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.cannotWrite("The chosen codec isn't available.")
        }
        writer.add(videoInput)

        // Audio rides along untouched apart from a re-encode to AAC.
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let layout = try await audioLayout(of: audioTrack)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVSampleRateKey: layout.sampleRate,
                    AVNumberOfChannelsKey: layout.channels,
                ]
            )
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: layout.sampleRate,
                    AVNumberOfChannelsKey: layout.channels,
                    AVEncoderBitRateKey: layout.channels > 1 ? 192_000 : 96_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPair = (output, input)
            }
        }

        let session = Session(reader: reader, writer: writer)

        guard writer.startWriting() else {
            throw ExportError.cannotWrite(
                writer.error?.localizedDescription ?? "Unknown writer error."
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ExportError.failed(
                reader.error?.localizedDescription ?? "Unknown reader error."
            )
        }
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = max(duration.seconds, 0.001)

        try await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(
                        input: videoInput, output: videoOutput, session: session,
                        label: "verticalize.export.video"
                    ) { time in
                        onProgress(min(max(time / totalSeconds, 0), 1))
                    }
                }
                if let (output, input) = audioPair {
                    group.addTask {
                        await pump(
                            input: input, output: output, session: session,
                            label: "verticalize.export.audio"
                        ) { _ in }
                    }
                }
                await group.waitForAll()
            }

            if session.isCancelled {
                try? FileManager.default.removeItem(at: outputURL)
                throw CancellationError()
            }
            if reader.status == .failed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw ExportError.failed(
                    reader.error?.localizedDescription ?? "Reading the source failed."
                )
            }

            await writer.finishWriting()

            if writer.status != .completed {
                try? FileManager.default.removeItem(at: outputURL)
                throw ExportError.failed(
                    writer.error?.localizedDescription ?? "Writing the file failed."
                )
            }
            onProgress(1)
        } onCancel: {
            session.cancel()
        }
    }

    // MARK: - Plumbing

    private static func pump(
        input: AVAssetWriterInput,
        output: AVAssetReaderOutput,
        session: Session,
        label: String,
        onSample: @Sendable @escaping (Double) -> Void
    ) async {
        let queue = DispatchQueue(label: label)
        await withCheckedContinuation { continuation in
            let box = FinishBox(continuation)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if session.isCancelled {
                        box.finish()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        box.finish()
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if !input.append(sample) {
                        input.markAsFinished()
                        box.finish()
                        return
                    }
                    if time.isFinite { onSample(time) }
                }
            }
        }
    }

    /// `requestMediaDataWhenReady` can re-enter; the continuation must not.
    private final class FinishBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            guard let c = continuation else { return }
            continuation = nil
            c.resume()
        }
    }

    private static func videoSettings(
        for path: CropPath, settings: Settings
    ) -> [String: any Sendable] {
        let width = Int(path.renderSize.width)
        let height = Int(path.renderSize.height)
        let fps = max(path.rate.rounded(), 1)
        let bitrate = Int(
            Double(width * height) * fps * settings.bitsPerPixel
        )
        var compression: [String: any Sendable] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
            AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
            AVVideoAllowFrameReorderingKey: true,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: settings.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static func audioLayout(
        of track: AVAssetTrack
    ) async throws -> (sampleRate: Double, channels: Int) {
        let descriptions = try await track.load(.formatDescriptions)
        guard let asbd = descriptions.first.flatMap({
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }) else {
            return (44_100, 2)
        }
        let rate = asbd.mSampleRate > 0 ? min(max(asbd.mSampleRate, 8_000), 48_000) : 44_100
        let channels = min(max(Int(asbd.mChannelsPerFrame), 1), 2)
        return (rate, channels)
    }
}
