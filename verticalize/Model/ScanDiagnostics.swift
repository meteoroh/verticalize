//
//  ScanDiagnostics.swift
//  verticalize
//
//  Everything the scanner learned about its own run. The point is to answer
//  "which layer is failing?" with numbers instead of inference — particularly
//  the near-miss merges, which say exactly how far off the appearance
//  thresholds are on real footage.
//

import Foundation

nonisolated struct ScanDiagnostics: Sendable {

    /// Two tracks that never shared a frame but were judged different people.
    /// If one person is listed twice, they are in here, and their distances
    /// say precisely where the threshold would have had to be.
    struct NearMiss: Sendable {
        var a: UUID
        var b: UUID
        /// Mean of the nearest few descriptor distances — what the merge used.
        var robustDistance: Double
        /// Single closest descriptor pair — what the old rule used.
        var nearestDistance: Double
    }

    var sampleInterval: Double = 0
    var requestedFrames = 0
    var decodedFrames = 0
    /// Frames where nobody at all was detected.
    var emptyFrames = 0
    var totalDetections = 0
    /// Detections sharing a frame with somebody overlapping them.
    var contestedDetections = 0
    /// Detections Vision returned that fell below `minConfidence`.
    var rejectedByConfidence = 0
    /// Detections that passed confidence but were too small.
    var rejectedBySize = 0
    /// Confidence histogram in ten 0.1-wide buckets, before any filtering.
    var confidenceBuckets = [Int](repeating: 0, count: 10)
    /// Detection-count histogram: index 0 = frames with 0 people, capped at 8.
    var detectionsPerFrame = [Int](repeating: 0, count: 9)

    var tracksCreated = 0
    var tracksBelowMinimum = 0
    var mergesApplied = 0
    var nearMisses: [NearMiss] = []

    var minSightings = 0
    var mergeThreshold = 0.0
    var reidDistance = 0.0

    var finalPeopleCount = 0

    /// A paste-ready summary. This is the artefact worth sending to whoever is
    /// tuning the thresholds — it is the whole run in twenty lines.
    func report(people: [PersonCandidate]) -> String {
        let labels = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.label) })
        var out: [String] = []
        out.append("VERTICALIZE SCAN REPORT")
        out.append(String(repeating: "=", count: 46))

        out.append("")
        out.append("SAMPLING")
        out.append("  rate            \(String(format: "%.1f", 1 / max(sampleInterval, .leastNonzeroMagnitude))) fps"
                   + "  (\(decodedFrames)/\(requestedFrames) frames decoded)")

        out.append("")
        out.append("DETECTION")
        out.append("  detections      \(totalDetections) kept, "
                   + "\(rejectedByConfidence) below confidence, \(rejectedBySize) too small")
        out.append("  empty frames    \(emptyFrames) of \(decodedFrames)"
                   + percent(emptyFrames, of: decodedFrames))
        out.append("  contested       \(contestedDetections) of \(totalDetections)"
                   + percent(contestedDetections, of: totalDetections))
        out.append("  per frame       " + histogram(
            detectionsPerFrame, labels: (0...8).map { $0 == 8 ? "8+" : "\($0)" }
        ))
        out.append("  confidence      " + histogram(
            confidenceBuckets, labels: (0..<10).map { String(format: "%.1f", Double($0) / 10) }
        ))

        out.append("")
        out.append("TRACKS")
        out.append("  created         \(tracksCreated)")
        out.append("  dropped         \(tracksBelowMinimum) (under \(minSightings) sightings)")
        out.append("  merged          \(mergesApplied)")
        out.append("  final           \(finalPeopleCount) people")

        if !nearMisses.isEmpty {
            out.append("")
            out.append("NEAR-MISS MERGES  (never co-occurred, judged different)")
            out.append("  threshold       \(String(format: "%.2f", mergeThreshold))"
                       + "   online re-ID \(String(format: "%.2f", reidDistance))")
            for miss in nearMisses.prefix(12) {
                let a = labels[miss.a] ?? "?"
                let b = labels[miss.b] ?? "?"
                out.append(String(
                    format: "  %-10s %-10s robust %.3f   nearest %.3f",
                    (a as NSString).utf8String!, (b as NSString).utf8String!,
                    miss.robustDistance, miss.nearestDistance
                ))
            }
            if nearMisses.count > 12 {
                out.append("  … and \(nearMisses.count - 12) more")
            }
        }

        if !people.isEmpty {
            out.append("")
            out.append("PEOPLE")
            for person in people {
                out.append(String(
                    format: "  %-10s %5.1fs on screen  %3d sightings  %d gap(s)  %@",
                    (person.label as NSString).utf8String!,
                    person.screenTime, person.sightings.count,
                    person.absenceCount(threshold: sampleInterval * 3),
                    "\(VideoSource.timecode(person.firstSeen))–\(VideoSource.timecode(person.lastSeen))"
                ))
            }
        }
        return out.joined(separator: "\n")
    }

    private func percent(_ n: Int, of total: Int) -> String {
        guard total > 0 else { return "" }
        return String(format: "  (%.0f%%)", Double(n) / Double(total) * 100)
    }

    private func histogram(_ counts: [Int], labels: [String]) -> String {
        let total = max(counts.reduce(0, +), 1)
        return zip(labels, counts)
            .filter { $0.1 > 0 }
            .map { "\($0.0):\(Int(Double($0.1) / Double(total) * 100))%" }
            .joined(separator: " ")
    }
}

extension PersonCandidate {
    /// How many times this person left and came back, which is the event that
    /// makes identity hard.
    func absenceCount(threshold: Double) -> Int {
        guard sightings.count > 1, threshold > 0 else { return 0 }
        var count = 0
        for i in 1..<sightings.count
        where sightings[i].time - sightings[i - 1].time > threshold {
            count += 1
        }
        return count
    }
}
