//
//  PersonScanner.swift
//  verticalize
//
//  Walks the clip once, detects every human in the sampled frames, and groups
//  those detections into distinct people using motion continuity first and
//  Vision feature prints as the re-identification fallback.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

nonisolated struct PersonScanner {

    struct Options: Sendable {
        /// Frames analysed per second of footage.
        var samplesPerSecond: Double = 5
        /// Longest edge handed to Vision. Smaller is faster, and detection
        /// quality plateaus well before full resolution.
        var analysisMaxEdge: Double = 1280
        var minConfidence: Float = 0.35
        /// Boxes smaller than this fraction of the frame height are noise.
        var minBoxHeight: Double = 0.06
        /// A cluster can be extended by motion alone for this long.
        var motionGap: Double = 0.8
        var motionIoU: Double = 0.32
        /// Feature-print distance below which two crops are the same person.
        var reidDistance: Double = 0.62
        /// Looser threshold used when merging clusters that never co-occur.
        var mergeDistance: Double = 0.55
        /// Clusters seen fewer times than this are discarded.
        var minSightings: Int = 3
    }

    struct Progress: Sendable {
        var fraction: Double
        var peopleFound: Int
        var currentTime: Double
    }

    enum ScanError: LocalizedError {
        case noVideoTrack
        case noFramesDecoded

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The clip has no video track to scan."
            case .noFramesDecoded: "No frames could be decoded from this clip."
            }
        }
    }

    // MARK: - Internal clustering state

    private final class Cluster {
        let id = UUID()
        var sightings: [Sighting] = []
        var prints: [FeaturePrintObservation] = []
        var thumbnail: CGImage?
        var thumbnailScore: Double = -.greatestFiniteMagnitude
        var lastTime: Double = -.greatestFiniteMagnitude
        var lastBox: CGRect = .zero
        /// Sample times this cluster was seen at, for the co-occurrence check.
        var times: Set<Int> = []
    }

    /// One human found in one frame, plus the lazily-computed feature print.
    private struct Detection {
        var box: CGRect          // normalized, top-left origin
        var ciRect: CGRect       // pixel rect in CIImage space (bottom-left origin)
        var cgRect: CGRect       // pixel rect in CGImage space (top-left origin)
        var confidence: Float
        var print: FeaturePrintObservation?
        var printAttempted = false
    }

    // MARK: - Entry point

    static func scan(
        source: VideoSource,
        options: Options = Options(),
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [PersonCandidate] {
        let asset = AVURLAsset(url: source.url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ScanError.noVideoTrack
        }

        let interval = 1.0 / max(options.samplesPerSecond, 0.5)
        let sampleCount = max(Int((source.duration / interval).rounded(.down)), 1)
        let times = (0..<sampleCount).map {
            CMTime(seconds: Double($0) * interval, preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Encoded pixels, so the frames we measure share a coordinate space with
        // `displaySize` — and therefore with the crop the composition applies.
        generator.apertureMode = .encodedPixels
        generator.maximumSize = CGSize(
            width: options.analysisMaxEdge, height: options.analysisMaxEdge
        )
        // We only need a frame "around" each sample point, and letting the
        // generator snap to the nearest sync-adjacent frame is far faster.
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var humanRequest = DetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        let printRequest = GenerateImageFeaturePrintRequest()
        let ciContext = CIContext(options: [.cacheIntermediates: false])

        var clusters: [Cluster] = []
        var processed = 0
        var decodedAny = false

        for await element in generator.images(for: times) {
            try Task.checkCancellation()
            processed += 1

            guard let cgImage = try? element.image else { continue }
            decodedAny = true
            let time = element.requestedTime.seconds
            let sampleIndex = Int((time / interval).rounded())
            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            let ciImage = CIImage(cgImage: cgImage)

            let humans = (try? await humanRequest.perform(on: cgImage)) ?? []
            var detections = humans.compactMap { human -> Detection? in
                guard human.confidence >= options.minConfidence else { return nil }
                let normalized = human.boundingBox.cgRect
                guard normalized.height >= options.minBoxHeight else { return nil }
                let topLeft = CGRect(
                    x: normalized.minX,
                    y: 1 - normalized.maxY,
                    width: normalized.width,
                    height: normalized.height
                )
                return Detection(
                    box: topLeft,
                    // CIImage is bottom-left origin, so Vision's rect maps straight across.
                    ciRect: pixelRect(normalized, in: imageSize),
                    // CGImage.cropping is top-left origin, so use the flipped rect.
                    cgRect: pixelRect(topLeft, in: imageSize),
                    confidence: human.confidence
                )
            }

            // Pass 1 — extend existing tracks by motion continuity.
            var claimedCluster = Set<Int>()
            var claimedDetection = Set<Int>()
            var motionPairs: [(cost: Double, cluster: Int, detection: Int)] = []
            for (ci, cluster) in clusters.enumerated() {
                guard time - cluster.lastTime <= options.motionGap else { continue }
                for (di, detection) in detections.enumerated() {
                    let overlap = iou(cluster.lastBox, detection.box)
                    if overlap >= options.motionIoU {
                        motionPairs.append((1 - overlap, ci, di))
                    }
                }
            }
            assign(motionPairs, &claimedCluster, &claimedDetection) { ci, di in
                record(detections[di], at: time, index: sampleIndex, into: clusters[ci])
            }

            // Pass 2 — re-identify anyone who left and came back.
            if claimedDetection.count < detections.count {
                var reidPairs: [(cost: Double, cluster: Int, detection: Int)] = []
                for di in detections.indices where !claimedDetection.contains(di) {
                    await ensurePrint(
                        &detections[di], ciImage: ciImage,
                        request: printRequest, context: ciContext
                    )
                    guard let probe = detections[di].print else { continue }
                    for ci in clusters.indices where !claimedCluster.contains(ci) {
                        let distance = clusters[ci].prints
                            .compactMap { try? probe.distance(to: $0) }
                            .min() ?? .greatestFiniteMagnitude
                        if distance <= options.reidDistance {
                            reidPairs.append((distance, ci, di))
                        }
                    }
                }
                assign(reidPairs, &claimedCluster, &claimedDetection) { ci, di in
                    record(detections[di], at: time, index: sampleIndex, into: clusters[ci])
                }
            }

            // Pass 3 — anyone still unclaimed is someone new.
            for di in detections.indices where !claimedDetection.contains(di) {
                await ensurePrint(
                    &detections[di], ciImage: ciImage,
                    request: printRequest, context: ciContext
                )
                let cluster = Cluster()
                record(detections[di], at: time, index: sampleIndex, into: cluster)
                clusters.append(cluster)
            }

            // Keep every track's appearance model fresh enough to re-identify with.
            for ci in claimedCluster where clusters[ci].prints.count < 4 {
                guard let di = detections.firstIndex(where: {
                    $0.box == clusters[ci].lastBox
                }) else { continue }
                await ensurePrint(
                    &detections[di], ciImage: ciImage,
                    request: printRequest, context: ciContext
                )
                if let p = detections[di].print { clusters[ci].prints.append(p) }
            }

            // Thumbnails: prefer big, confident, front-facing-ish crops.
            for cluster in clusters where cluster.lastTime == time {
                let score = Double(cluster.sightings.last?.confidence ?? 0)
                    * (cluster.lastBox.height * 2)
                if score > cluster.thumbnailScore,
                   let crop = cgImage.cropping(
                       to: detections.first { $0.box == cluster.lastBox }?.cgRect
                           ?? .zero
                   ) {
                    cluster.thumbnail = crop
                    cluster.thumbnailScore = score
                }
            }

            onProgress(
                Progress(
                    fraction: Double(processed) / Double(times.count),
                    peopleFound: clusters.filter { $0.sightings.count >= options.minSightings }.count,
                    currentTime: time
                )
            )
        }

        try Task.checkCancellation()
        guard decodedAny else { throw ScanError.noFramesDecoded }

        let merged = mergeDuplicates(clusters, options: options)
        return finalize(merged, interval: interval, source: source, options: options)
    }

    // MARK: - Clustering helpers

    private static func record(
        _ detection: Detection, at time: Double, index: Int, into cluster: Cluster
    ) {
        cluster.sightings.append(
            Sighting(time: time, box: detection.box, confidence: detection.confidence)
        )
        cluster.lastTime = time
        cluster.lastBox = detection.box
        cluster.times.insert(index)
        if let p = detection.print, cluster.prints.count < 8 {
            cluster.prints.append(p)
        }
    }

    /// Greedy lowest-cost-first matching with one-to-one exclusivity.
    private static func assign(
        _ pairs: [(cost: Double, cluster: Int, detection: Int)],
        _ claimedCluster: inout Set<Int>,
        _ claimedDetection: inout Set<Int>,
        _ apply: (Int, Int) -> Void
    ) {
        for pair in pairs.sorted(by: { $0.cost < $1.cost }) {
            guard !claimedCluster.contains(pair.cluster),
                  !claimedDetection.contains(pair.detection) else { continue }
            claimedCluster.insert(pair.cluster)
            claimedDetection.insert(pair.detection)
            apply(pair.cluster, pair.detection)
        }
    }

    private static func ensurePrint(
        _ detection: inout Detection,
        ciImage: CIImage,
        request: GenerateImageFeaturePrintRequest,
        context: CIContext
    ) async {
        guard !detection.printAttempted else { return }
        detection.printAttempted = true
        // The head and torso carry the identity; legs are mostly background.
        var region = detection.ciRect
        region.origin.y += region.height * 0.5
        region.size.height *= 0.5
        region = region.insetBy(dx: -region.width * 0.08, dy: -region.height * 0.08)
            .intersection(ciImage.extent)
        guard region.width > 8, region.height > 8 else { return }
        let crop = ciImage.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        guard let cg = context.createCGImage(
            crop, from: CGRect(origin: .zero, size: region.size)
        ) else { return }
        detection.print = try? await request.perform(on: cg)
    }

    /// Two tracks that never share a frame and look alike are the same person
    /// walking out of shot and back in.
    private static func mergeDuplicates(_ clusters: [Cluster], options: Options) -> [Cluster] {
        var working = clusters.filter { $0.sightings.count >= options.minSightings }
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in working.indices {
                for j in working.indices where j > i {
                    let a = working[i], b = working[j]
                    guard a.times.isDisjoint(with: b.times) else { continue }
                    let distance = a.prints
                        .flatMap { pa in b.prints.compactMap { try? pa.distance(to: $0) } }
                        .min() ?? .greatestFiniteMagnitude
                    guard distance <= options.mergeDistance else { continue }
                    a.sightings = (a.sightings + b.sightings).sorted { $0.time < $1.time }
                    a.times.formUnion(b.times)
                    a.prints = Array((a.prints + b.prints).prefix(8))
                    if b.thumbnailScore > a.thumbnailScore {
                        a.thumbnail = b.thumbnail
                        a.thumbnailScore = b.thumbnailScore
                    }
                    a.lastTime = max(a.lastTime, b.lastTime)
                    working.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }
        return working
    }

    private static func finalize(
        _ clusters: [Cluster], interval: Double, source: VideoSource, options: Options
    ) -> [PersonCandidate] {
        clusters
            .filter { $0.sightings.count >= options.minSightings }
            .map { cluster in
                PersonCandidate(
                    id: cluster.id,
                    index: 0,
                    sightings: cluster.sightings.sorted { $0.time < $1.time },
                    thumbnail: cluster.thumbnail,
                    screenTime: Double(cluster.sightings.count) * interval,
                    clipDuration: source.duration
                )
            }
            .sorted { $0.screenTime > $1.screenTime }
            .enumerated()
            .map { offset, candidate in
                var copy = candidate
                copy.index = offset + 1
                return copy
            }
    }

    // MARK: - Geometry

    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let overlap = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - overlap
        return union > 0 ? overlap / union : 0
    }

    private static func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }
}
