// How separable is the appearance embedding on real footage?
//
// Labels come from geometry, not annotation:
//   POSITIVE — two detections chained across consecutive frames by high IoU.
//              At 12fps that is the same person with near-certainty.
//   NEGATIVE — two detections in the SAME frame. One person cannot be in two
//              places, so these are definitely different people.
//
// No ground truth needed, and no tracker involved — this measures the embedding
// alone, independent of every association decision the app makes.

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleRate = 12.0
let maxSeconds = Double(CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 120 : 120)

// MARK: - Crop styles under test

enum CropStyle: String, CaseIterable {
    /// What the app does today: head and torso, the top half of the box.
    case topHalf = "top-half (current)"
    /// What ReID models are trained on: the whole person.
    case fullBody = "full-body"

    func region(_ box: CGRect) -> CGRect {
        switch self {
        case .topHalf:
            var r = box
            r.origin.y += r.height * 0.5      // CIImage is bottom-left origin
            r.size.height *= 0.5
            return r
        case .fullBody:
            return box
        }
    }
}

struct Detection {
    var frame: Int
    var time: Double
    var box: CGRect                       // normalized, top-left origin
    var prints: [CropStyle: FeaturePrintObservation]
}

func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
    let overlap = Double(i.width * i.height)
    let union = Double(a.width * a.height) + Double(b.width * b.height) - overlap
    return union > 0 ? overlap / union : 0
}

// MARK: - Collect

let asset = AVURLAsset(url: videoURL)
let duration = try await asset.load(.duration).seconds
let span = min(duration, maxSeconds)
let interval = 1 / sampleRate
let count = Int(span / interval)
let times = (0..<count).map { CMTime(seconds: Double($0) * interval, preferredTimescale: 600) }

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.apertureMode = .encodedPixels
generator.maximumSize = CGSize(width: 1280, height: 1280)
generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)

var humanRequest = DetectHumanRectanglesRequest()
humanRequest.upperBodyOnly = false
let printRequest = GenerateImageFeaturePrintRequest()
let context = CIContext(options: [.cacheIntermediates: false])

FileHandle.standardError.write("scanning \(String(format: "%.0f", span))s at \(Int(sampleRate))fps…\n".data(using: .utf8)!)

var byFrame: [Int: [Detection]] = [:]
var processed = 0

for await element in generator.images(for: times) {
    processed += 1
    if processed % 120 == 0 {
        FileHandle.standardError.write("  \(processed)/\(count)\n".data(using: .utf8)!)
    }
    guard let cgImage = try? element.image else { continue }
    let time = element.requestedTime.seconds
    let frame = Int((time / interval).rounded())
    let size = CGSize(width: cgImage.width, height: cgImage.height)
    let ciImage = CIImage(cgImage: cgImage)

    let humans = (try? await humanRequest.perform(on: cgImage)) ?? []
    for human in humans where human.confidence >= 0.35 {
        let n = human.boundingBox.cgRect
        guard n.height >= 0.06 else { continue }
        let pixels = CGRect(x: n.minX * size.width, y: n.minY * size.height,
                            width: n.width * size.width, height: n.height * size.height)

        var prints: [CropStyle: FeaturePrintObservation] = [:]
        for style in CropStyle.allCases {
            var region = style.region(pixels)
            region = region.insetBy(dx: -region.width * 0.08, dy: -region.height * 0.08)
                .intersection(ciImage.extent)
            guard region.width > 8, region.height > 8 else { continue }
            let crop = ciImage.cropped(to: region).transformed(
                by: CGAffineTransform(translationX: -region.minX, y: -region.minY)
            )
            guard let cg = context.createCGImage(
                crop, from: CGRect(origin: .zero, size: region.size)
            ) else { continue }
            if let p = try? await printRequest.perform(on: cg) { prints[style] = p }
        }
        guard prints.count == CropStyle.allCases.count else { continue }

        let topLeft = CGRect(x: n.minX, y: 1 - n.maxY, width: n.width, height: n.height)
        byFrame[frame, default: []].append(
            Detection(frame: frame, time: time, box: topLeft, prints: prints)
        )
    }
}

let frames = byFrame.keys.sorted()
let totalDetections = byFrame.values.reduce(0) { $0 + $1.count }
FileHandle.standardError.write("collected \(totalDetections) detections over \(frames.count) frames\n".data(using: .utf8)!)

// MARK: - Chain into tracklets by motion only

var trackletOf: [Int: [Int: Int]] = [:]   // frame → detection index → tracklet id
var nextTracklet = 0
for (n, frame) in frames.enumerated() {
    let here = byFrame[frame]!
    var assigned: [Int: Int] = [:]
    if n > 0, frames[n - 1] == frame - 1, let previous = byFrame[frame - 1] {
        var pairs: [(Double, Int, Int)] = []
        for (i, a) in previous.enumerated() {
            for (j, b) in here.enumerated() {
                let overlap = iou(a.box, b.box)
                if overlap > 0.6 { pairs.append((overlap, i, j)) }
            }
        }
        var usedPrev = Set<Int>(), usedHere = Set<Int>()
        for (_, i, j) in pairs.sorted(by: { $0.0 > $1.0 }) {
            guard !usedPrev.contains(i), !usedHere.contains(j) else { continue }
            usedPrev.insert(i); usedHere.insert(j)
            if let t = trackletOf[frame - 1]?[i] { assigned[j] = t }
        }
    }
    for j in here.indices where assigned[j] == nil {
        assigned[j] = nextTracklet
        nextTracklet += 1
    }
    trackletOf[frame] = assigned
}

// MARK: - Build labelled pairs

struct Pair { var distance: Double; var gap: Double }

var positives: [CropStyle: [Pair]] = [:]
var negatives: [CropStyle: [Pair]] = [:]

// Flatten to (tracklet → [detection]) for positive sampling.
var byTracklet: [Int: [Detection]] = [:]
for frame in frames {
    for (j, d) in byFrame[frame]!.enumerated() {
        if let t = trackletOf[frame]?[j] { byTracklet[t, default: []].append(d) }
    }
}

// Deterministic stride sampling keeps the pair count manageable without bias.
for style in CropStyle.allCases {
    var pos: [Pair] = []
    for (_, list) in byTracklet where list.count > 1 {
        let stride = max(list.count / 40, 1)
        var i = 0
        while i < list.count {
            var j = i + stride
            while j < list.count {
                if let a = list[i].prints[style], let b = list[j].prints[style],
                   let d = try? a.distance(to: b) {
                    pos.append(Pair(distance: d, gap: abs(list[j].time - list[i].time)))
                }
                j += stride * 4
            }
            i += stride
        }
    }
    positives[style] = pos

    var neg: [Pair] = []
    for frame in frames {
        let here = byFrame[frame]!
        guard here.count > 1 else { continue }
        for i in here.indices {
            for j in here.indices where j > i {
                if let a = here[i].prints[style], let b = here[j].prints[style],
                   let d = try? a.distance(to: b) {
                    neg.append(Pair(distance: d, gap: 0))
                }
            }
        }
    }
    negatives[style] = neg
}

// MARK: - Report

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let index = min(max(Int(p * Double(sorted.count - 1)), 0), sorted.count - 1)
    return sorted[index]
}

/// Probability a random positive scores below a random negative.
func auc(_ pos: [Double], _ neg: [Double]) -> Double {
    guard !pos.isEmpty, !neg.isEmpty else { return .nan }
    let sortedNeg = neg.sorted()
    var total = 0.0
    for p in pos {
        var lo = 0, hi = sortedNeg.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedNeg[mid] <= p { lo = mid + 1 } else { hi = mid }
        }
        total += Double(sortedNeg.count - lo)
    }
    return total / Double(pos.count * neg.count)
}

/// Threshold minimising (false merges + missed merges).
func bestThreshold(_ pos: [Double], _ neg: [Double]) -> (t: Double, fpr: Double, fnr: Double) {
    var best = (t: 0.0, err: Double.greatestFiniteMagnitude, fpr: 0.0, fnr: 0.0)
    var t = 0.0
    while t <= 2.0 {
        let fn = Double(pos.filter { $0 > t }.count) / Double(max(pos.count, 1))
        let fp = Double(neg.filter { $0 <= t }.count) / Double(max(neg.count, 1))
        if fn + fp < best.err { best = (t, fn + fp, fp, fn) }
        t += 0.005
    }
    return (best.t, best.fpr, best.fnr)
}

print("APPEARANCE EMBEDDING SEPARATION — Vision GenerateImageFeaturePrintRequest")
print(String(repeating: "=", count: 68))
print("clip           \(videoURL.lastPathComponent)  (\(String(format: "%.0f", span))s @ \(Int(sampleRate))fps)")
print("detections     \(totalDetections) over \(frames.count) frames, \(byTracklet.count) motion tracklets")

for style in CropStyle.allCases {
    let pos = positives[style]!.map(\.distance)
    let neg = negatives[style]!.map(\.distance)
    let best = bestThreshold(pos, neg)
    print("")
    print("CROP: \(style.rawValue)")
    print("  pairs         \(pos.count) same-person, \(neg.count) different-person")
    print(String(format: "  same person   p50 %.3f   p90 %.3f   p99 %.3f",
                 percentile(pos, 0.50), percentile(pos, 0.90), percentile(pos, 0.99)))
    print(String(format: "  different     p1  %.3f   p10 %.3f   p50 %.3f",
                 percentile(neg, 0.01), percentile(neg, 0.10), percentile(neg, 0.50)))
    print(String(format: "  separability  AUC %.4f   (1.0 = perfect, 0.5 = useless)", auc(pos, neg)))
    print(String(format: "  best split    %.3f  →  %.1f%% false merges, %.1f%% missed merges",
                 best.t, best.fpr * 100, best.fnr * 100))
    let overlap = percentile(pos, 0.90) - percentile(neg, 0.10)
    print(String(format: "  overlap       same-p90 %.3f vs different-p10 %.3f  →  %@",
                 percentile(pos, 0.90), percentile(neg, 0.10),
                 overlap > 0 ? String(format: "OVERLAPPING by %.3f", overlap) : "separated"))

    // How the embedding decays as the two views get further apart in time.
    let buckets: [(String, ClosedRange<Double>)] = [
        ("<0.5s", 0...0.5), ("0.5-2s", 0.5...2), ("2-10s", 2...10), (">10s", 10...1e9),
    ]
    let rows = buckets.compactMap { name, range -> String? in
        let subset = positives[style]!.filter { range.contains($0.gap) }.map(\.distance)
        guard subset.count > 20 else { return nil }
        return String(format: "%@ p90 %.3f (n=%d)", name, percentile(subset, 0.90), subset.count)
    }
    if !rows.isEmpty { print("  by time gap   " + rows.joined(separator: "   ")) }
}

print("")
print("Current thresholds: reID 0.62, merge 0.80, ceiling 1.05")
