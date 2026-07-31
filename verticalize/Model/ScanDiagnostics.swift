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

    /// A pair of tracks the merge pass declined to join. If one person is
    /// listed twice they are in here, together with the reason — which is the
    /// part that says what to change.
    struct NearMiss: Sendable {
        enum Reason: Sendable {
            /// Compared on appearance and judged different people.
            case tooFarApart(robust: Double, nearest: Double)
            /// One of them never learned an appearance model, so no comparison
            /// was possible. Usually a short track born in a crowded frame.
            case noComparableDescriptors
            /// They appeared in the same frame, so they cannot be one person —
            /// unless the detector double-reported somebody, which is why the
            /// overlap is measured rather than merely tested.
            case sharedFrames(count: Int, fractionOfShorter: Double)
        }

        var a: UUID
        var b: UUID
        var reason: Reason

        var sortKey: Double {
            switch reason {
            case .tooFarApart(let robust, _): robust
            case .sharedFrames(_, let fraction): 10 + fraction
            case .noComparableDescriptors: 100
            }
        }

        var describe: String {
            switch reason {
            case .tooFarApart(let robust, let nearest):
                String(format: "robust %.3f   nearest %.3f", robust, nearest)
            case .noComparableDescriptors:
                "no appearance model on one side"
            case .sharedFrames(let count, let fraction):
                String(format: "shared %d frames (%.1f%% of the shorter track)",
                       count, fraction * 100)
            }
        }
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
    var overlapTolerance = 0.0

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
        // Guarding with leastNonzeroMagnitude used to overflow the reciprocal to
        // infinity and print "inf fps" — the same class of sentinel leak that
        // once hid a real finding behind a 309-digit number.
        let rate = sampleInterval > 0 ? String(format: "%.1f", 1 / sampleInterval) : "—"
        out.append("  rate            \(rate) fps"
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
            out.append("MERGES DECLINED  (why each pair stayed two people)")
            out.append("  threshold       \(String(format: "%.2f", mergeThreshold))"
                       + "   online re-ID \(String(format: "%.2f", reidDistance))"
                       + "   overlap allowance \(String(format: "%.0f%%", overlapTolerance * 100))")
            for miss in nearMisses.sorted(by: { $0.sortKey < $1.sortKey }).prefix(14) {
                let a = (labels[miss.a] ?? "?").padding(toLength: 10, withPad: " ", startingAt: 0)
                let b = (labels[miss.b] ?? "?").padding(toLength: 10, withPad: " ", startingAt: 0)
                out.append("  \(a) \(b) \(miss.describe)")
            }
            if nearMisses.count > 14 {
                out.append("  … and \(nearMisses.count - 14) more")
            }
        }

        if !people.isEmpty {
            out.append("")
            out.append("PEOPLE")
            for person in people {
                let label = person.label.padding(toLength: 10, withPad: " ", startingAt: 0)
                out.append(String(
                    format: "  %@ %5.1fs on screen  %4d sightings  %2d gap(s)  %@",
                    label, person.screenTime, person.sightings.count,
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
