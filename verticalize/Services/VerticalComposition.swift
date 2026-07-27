//
//  VerticalComposition.swift
//  verticalize
//
//  Expresses the moving crop as a chain of affine transform ramps on a video
//  composition layer instruction. That keeps the whole thing on the hardware
//  path, and makes the preview player and the exporter render pixel-identical
//  frames from the same object.
//

import AVFoundation
import CoreGraphics
import Foundation

nonisolated enum VerticalComposition {

    enum CompositionError: LocalizedError {
        case noVideoTrack

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The clip has no video track to compose."
            }
        }
    }

    /// AVFoundation's composition space puts the origin at the top-left, which
    /// matches the coordinate space `CropPath` works in.
    private static let compositionOriginIsTopLeft = true

    static func make(
        asset: AVAsset, source: VideoSource, path: CropPath
    ) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompositionError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        return make(track: track, duration: duration, source: source, path: path)
    }

    static func make(
        track: AVAssetTrack, duration: CMTime, source: VideoSource, path: CropPath
    ) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = path.renderSize
        composition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(path.rate.rounded(), 1))
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let timescale: CMTimeScale = 600
        // A deadzoned camera sits still for most of a clip, so most grid points
        // lie on the line between their neighbours. Dropping them keeps the ramp
        // list short on long clips without moving the frame by a visible amount.
        let keyframes = simplify(path.centers, tolerance: subPixelTolerance(path))

        if keyframes.count < 2 {
            layer.setTransform(transform(for: path, at: 0, source: source), at: .zero)
        } else {
            for i in 0..<(keyframes.count - 1) {
                let from = keyframes[i], to = keyframes[i + 1]
                let start = CMTime(seconds: Double(from) / path.rate, preferredTimescale: timescale)
                let end = CMTime(seconds: Double(to) / path.rate, preferredTimescale: timescale)
                guard start < duration else { break }
                layer.setTransformRamp(
                    fromStart: transform(for: path, at: from, source: source),
                    toEnd: transform(for: path, at: to, source: source),
                    timeRange: CMTimeRange(start: start, end: min(end, duration))
                )
            }
            // Hold the last framing through any tail beyond the sampled grid.
            let tail = CMTime(
                seconds: Double(keyframes[keyframes.count - 1]) / path.rate,
                preferredTimescale: timescale
            )
            if tail < duration {
                layer.setTransform(
                    transform(for: path, at: keyframes[keyframes.count - 1], source: source),
                    at: tail
                )
            }
        }

        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    /// Half a source pixel, expressed in the normalized units `centers` uses.
    private static func subPixelTolerance(_ path: CropPath) -> CGSize {
        CGSize(
            width: 0.5 / max(path.displaySize.width, 1),
            height: 0.5 / max(path.displaySize.height, 1)
        )
    }

    /// Keeps the endpoints plus every point that a straight ramp from the last
    /// kept point would misplace by more than `tolerance`.
    private static func simplify(_ points: [CGPoint], tolerance: CGSize) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        // Bounding the run keeps this linear-ish on long clips and drops a
        // keyframe at least every few seconds, which players prefer.
        let maxRun = 240
        var kept = [0]
        var anchor = 0
        var candidate = 1
        while candidate < points.count - 1 {
            let next = candidate + 1
            var fits = next - anchor <= maxRun
            for i in (anchor + 1)..<next where fits {
                let u = Double(i - anchor) / Double(next - anchor)
                let x = points[anchor].x + (points[next].x - points[anchor].x) * u
                let y = points[anchor].y + (points[next].y - points[anchor].y) * u
                if abs(points[i].x - x) > tolerance.width
                    || abs(points[i].y - y) > tolerance.height {
                    fits = false
                    break
                }
            }
            if fits {
                candidate = next
            } else {
                kept.append(candidate)
                anchor = candidate
                candidate += 1
            }
        }
        kept.append(points.count - 1)
        return kept
    }

    /// natural pixels → preferred transform → shift the crop to the origin → scale to fill.
    private static func transform(
        for path: CropPath, at index: Int, source: VideoSource
    ) -> CGAffineTransform {
        let rect = path.rect(forCenter: path.centers[min(index, path.centers.count - 1)])
        let scale = path.renderSize.width / rect.width
        let offsetY = compositionOriginIsTopLeft
            ? -rect.minY
            : -(path.displaySize.height - rect.maxY)
        return source.preferredTransform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: offsetY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }
}
