//
//  PersonScanner.swift
//  verticalize
//
//  Walks the clip once, detects every human in the sampled frames, and hands
//  those detections to `IdentityTracker` to be grouped into distinct people.
//  This file owns the video and Vision plumbing; the matching decisions — the
//  part that has to survive two people crossing — live in the tracker.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

nonisolated struct PersonScanner {

    struct Options: Sendable {
        /// Frames analysed per second of footage. Association quality depends
        /// on this more than on anything else: the further a person can travel
        /// between two samples, the less motion can say about who they are.
        var samplesPerSecond: Double = 12
        /// Ceiling on analysed frames, so a very long clip quietly lowers its
        /// sample rate instead of scanning for an hour.
        var maxSamples: Int = 9_000
        /// Longest edge handed to Vision. Smaller is faster, and detection
        /// quality plateaus well before full resolution.
        var analysisMaxEdge: Double = 1280
        var minConfidence: Float = 0.35
        /// Boxes smaller than this fraction of the frame height are noise.
        var minBoxHeight: Double = 0.06
        /// Looser threshold used when merging tracks that never co-occur.
        var mergeDistance: Double = 0.55
        /// Tracks on screen for less than this are noise. Expressed in seconds
        /// rather than sightings so the sample rate can change independently.
        var minScreenTime: Double = 0.6
        /// Keep an appearance model this big for each track, so re-acquisition
        /// after an occlusion has several angles to compare against.
        var descriptorTarget: Int = 3
        var tracking: IdentityTracker.Options = .default
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

    /// One human found in one frame.
    private struct Detection {
        var box: CGRect          // normalized, top-left origin
        var ciRect: CGRect       // pixel rect in CIImage space (bottom-left origin)
        var cgRect: CGRect       // pixel rect in CGImage space (top-left origin)
        var confidence: Float
    }

    /// Feature prints live here rather than inside the tracker, so the tracker
    /// stays free of Vision and can be tested with synthetic descriptors.
    /// Entries not referenced by a track are dropped after every frame.
    private final class DescriptorTable {
        private var prints: [Int: FeaturePrintObservation] = [:]
        private var nextID = 0

        func add(_ print: FeaturePrintObservation) -> Int {
            defer { nextID += 1 }
            prints[nextID] = print
            return nextID
        }

        func distance(_ a: Int, _ b: Int) -> Double? {
            guard let lhs = prints[a], let rhs = prints[b] else { return nil }
            return try? lhs.distance(to: rhs)
        }

        func retain(_ ids: Set<Int>) {
            prints = prints.filter { ids.contains($0.key) }
        }
    }

    /// A track plus the scan-time extras the tracker doesn't care about.
    private struct Candidate {
        var id: UUID
        var sightings: [Sighting]
        var descriptors: [Int]
        var sampleIndices: Set<Int>
        var thumbnail: CGImage?
        var thumbnailScore: Double
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

        // Honour the requested rate unless it would blow the frame budget.
        let interval = max(
            1.0 / max(options.samplesPerSecond, 0.5),
            source.duration / Double(max(options.maxSamples, 1))
        )
        let sampleCount = max(Int((source.duration / interval).rounded(.down)), 1)
        let minSightings = max(Int((options.minScreenTime / interval).rounded()), 2)
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

        let table = DescriptorTable()
        let tracker = IdentityTracker(options: options.tracking) { [table] a, b in
            table.distance(a, b)
        }
        var thumbnails: [UUID: (image: CGImage, score: Double)] = [:]
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
            let detections = humans.compactMap { human -> Detection? in
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

            var observations = detections.map {
                IdentityTracker.Observation(box: $0.box, confidence: $0.confidence)
            }

            // Feature prints are the expensive part, so only pay for them when
            // identity is actually at stake — or when a track is still building
            // the appearance model it will need the moment it is.
            let needsDescriptors = observations.count > 1
                || tracker.isContested(at: time, observations: observations)
                || tracker.tracks.contains {
                    time - $0.lastConfirmedTime <= options.tracking.coastTime
                        && $0.descriptors.count < options.descriptorTarget
                }
            if needsDescriptors {
                for index in observations.indices {
                    guard let print = await featurePrint(
                        for: detections[index], ciImage: ciImage,
                        request: printRequest, context: ciContext
                    ) else { continue }
                    observations[index].descriptor = table.add(print)
                }
            }

            let claimed = tracker.update(
                time: time, sampleIndex: sampleIndex, observations: observations
            )

            // A thumbnail should show one person, so reuse the tracker's view of
            // which crops had somebody else in them.
            for index in claimed.indices where !claimed[index].isContested {
                let detection = detections[index]
                let score = Double(detection.confidence) * Double(detection.box.height) * 2
                let track = claimed[index].track
                guard score > (thumbnails[track.id]?.score ?? -.greatestFiniteMagnitude),
                      let crop = cgImage.cropping(to: detection.cgRect) else { continue }
                thumbnails[track.id] = (crop, score)
            }

            table.retain(Set(tracker.tracks.flatMap(\.descriptors)))

            onProgress(
                Progress(
                    fraction: Double(processed) / Double(times.count),
                    peopleFound: tracker.tracks.filter {
                        $0.sightings.count >= minSightings
                    }.count,
                    currentTime: time
                )
            )
        }

        try Task.checkCancellation()
        guard decodedAny else { throw ScanError.noFramesDecoded }

        let candidates = tracker.tracks
            .filter { $0.sightings.count >= minSightings }
            .map { track in
                Candidate(
                    id: track.id,
                    sightings: track.sightings,
                    descriptors: track.descriptors,
                    sampleIndices: track.sampleIndices,
                    thumbnail: thumbnails[track.id]?.image,
                    thumbnailScore: thumbnails[track.id]?.score ?? -.greatestFiniteMagnitude
                )
            }

        let merged = mergeDuplicates(candidates, table: table, options: options)
        return finalize(merged, interval: interval, source: source)
    }

    // MARK: - Vision helpers

    private static func featurePrint(
        for detection: Detection,
        ciImage: CIImage,
        request: GenerateImageFeaturePrintRequest,
        context: CIContext
    ) async -> FeaturePrintObservation? {
        // The head and torso carry the identity; legs are mostly background.
        var region = detection.ciRect
        region.origin.y += region.height * 0.5
        region.size.height *= 0.5
        region = region.insetBy(dx: -region.width * 0.08, dy: -region.height * 0.08)
            .intersection(ciImage.extent)
        guard region.width > 8, region.height > 8 else { return nil }
        let crop = ciImage.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        guard let cgImage = context.createCGImage(
            crop, from: CGRect(origin: .zero, size: region.size)
        ) else { return nil }
        return try? await request.perform(on: cgImage)
    }

    // MARK: - Post-processing

    /// Two tracks that never share a frame and look alike are the same person
    /// walking out of shot and back in.
    private static func mergeDuplicates(
        _ candidates: [Candidate], table: DescriptorTable, options: Options
    ) -> [Candidate] {
        var working = candidates
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in working.indices {
                for j in working.indices where j > i {
                    guard working[i].sampleIndices.isDisjoint(with: working[j].sampleIndices)
                    else { continue }
                    let distance = working[i].descriptors
                        .flatMap { a in
                            working[j].descriptors.compactMap { table.distance(a, $0) }
                        }
                        .min() ?? .greatestFiniteMagnitude
                    guard distance <= options.mergeDistance else { continue }

                    let absorbed = working[j]
                    working[i].sightings = (working[i].sightings + absorbed.sightings)
                        .sorted { $0.time < $1.time }
                    working[i].sampleIndices.formUnion(absorbed.sampleIndices)
                    working[i].descriptors = Array(
                        (working[i].descriptors + absorbed.descriptors)
                            .prefix(options.tracking.maxDescriptors)
                    )
                    if absorbed.thumbnailScore > working[i].thumbnailScore {
                        working[i].thumbnail = absorbed.thumbnail
                        working[i].thumbnailScore = absorbed.thumbnailScore
                    }
                    working.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }
        return working
    }

    private static func finalize(
        _ candidates: [Candidate], interval: Double, source: VideoSource
    ) -> [PersonCandidate] {
        candidates
            .map { candidate in
                PersonCandidate(
                    id: candidate.id,
                    index: 0,
                    sightings: candidate.sightings.sorted { $0.time < $1.time },
                    thumbnail: candidate.thumbnail,
                    screenTime: Double(candidate.sightings.count) * interval,
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

    private static func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }
}
