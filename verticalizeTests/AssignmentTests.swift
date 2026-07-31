//
//  AssignmentTests.swift
//  verticalizeTests
//
//  Greedy matching is what let a crossing swap two identities. These check the
//  replacement is genuinely optimal, and that the appearance metric behaves the
//  way the calibration assumed.
//

import CoreGraphics
import Foundation
import Testing
@testable import verticalize

@Suite("Assignment and appearance")
struct AssignmentTests {

    @Test("Hungarian matches brute force on random matrices")
    func hungarianIsOptimal() {
        // Deterministic xorshift, so a failure is always reproducible.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 10_000) / 10_000
        }

        for trial in 0..<300 {
            let rows = Int(random() * 4) + 1
            let cols = Int(random() * 4) + 1
            let cost = (0..<rows).map { _ in (0..<cols).map { _ in random() } }

            let solved = Hungarian.solve(cost, rows: rows, cols: cols)
            var total = 0.0
            var usedColumns = Set<Int>()
            for r in 0..<rows where solved[r] >= 0 {
                total += cost[r][solved[r]]
                #expect(usedColumns.insert(solved[r]).inserted,
                        "trial \(trial): column assigned twice")
            }

            // Padding to a square forces a maximum-cardinality matching, so the
            // reference enumerates injective maps of exactly that size.
            let k = min(rows, cols)
            var best = Double.greatestFiniteMagnitude
            func permute(_ row: Int, _ assigned: Int, _ used: inout [Bool], _ running: Double) {
                if row == rows {
                    if assigned == k { best = min(best, running) }
                    return
                }
                if k - assigned <= rows - row - 1 {
                    permute(row + 1, assigned, &used, running)
                }
                for c in 0..<cols where !used[c] {
                    used[c] = true
                    permute(row + 1, assigned + 1, &used, running + cost[row][c])
                    used[c] = false
                }
            }
            var used = [Bool](repeating: false, count: cols)
            permute(0, 0, &used, 0)

            #expect(abs(total - best) < 1e-9, "trial \(trial): \(total) vs optimum \(best)")
            #expect(usedColumns.count == k, "trial \(trial): matched \(usedColumns.count) of \(k)")
        }
    }

    @Test("Averaging the nearest few beats the single nearest descriptor")
    func robustMetricResistsOutliers() {
        // A stranger sits far from the track's descriptors except for one
        // unlucky pair that looks like a match.
        func distance(_ a: Int, _ b: Int) -> Double? {
            if a / 1000 == b / 1000 { return Appearance.samePerson }
            return min(a, b) % 1000 == 3 ? 0.15 : 0.80
        }
        func trackCount(sampleCount: Int) -> Int {
            var options = IdentityTracker.Options.default
            options.appearanceSampleCount = sampleCount
            let tracker = IdentityTracker(options: options, appearanceDistance: distance)
            for frame in 0..<10 {
                tracker.update(time: Double(frame) / 12, sampleIndex: frame, observations: [
                    .init(box: CGRect(x: 0.4, y: 0.2, width: 0.12, height: 0.6),
                          confidence: 0.9, descriptor: frame)
                ])
            }
            for frame in 40..<50 {
                tracker.update(time: Double(frame) / 12, sampleIndex: frame, observations: [
                    .init(box: CGRect(x: 0.4, y: 0.2, width: 0.12, height: 0.6),
                          confidence: 0.9, descriptor: 1000 + frame)
                ])
            }
            return tracker.tracks.count
        }

        #expect(trackCount(sampleCount: 3) == 2, "averaging keeps two people apart")
        // Control: the old nearest-descriptor rule merges them, so the change
        // is doing real work.
        #expect(trackCount(sampleCount: 1) == 1, "the single-nearest rule does merge them")
    }

    @Test("Robust distance averages exactly the nearest k")
    func robustMetricArithmetic() {
        #expect(AppearanceMetric.robust([], sampleCount: 3) == nil)
        #expect(AppearanceMetric.robust([0.4], sampleCount: 3) == 0.4)
        let mean = try! #require(AppearanceMetric.robust([0.9, 0.1, 0.5, 0.3], sampleCount: 3))
        #expect(abs(mean - (0.1 + 0.3 + 0.5) / 3) < 1e-12)
    }

    @Test("The offline merge is never stricter than online re-identification")
    func mergeThresholdInvariant() {
        // A stricter merge can only re-reject what online matching already
        // rejected, which is how one person ended up listed twice.
        #expect(PersonScanner.Options().mergeDistance >= IdentityTracker.Options.default.reidDistance)
    }
}
