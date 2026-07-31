//
//  ScanDiagnosticsTests.swift
//  verticalizeTests
//
//  The report is a debugging tool, so its failure mode is quiet nonsense rather
//  than a crash — as when a sentinel distance printed as 1.79e308 and hid the
//  finding underneath it. These exercise the formatting paths a scan of
//  people-free footage would never reach.
//

import CoreGraphics
import Foundation
import Testing
@testable import verticalize

@Suite("Scan report")
struct ScanDiagnosticsTests {

    private func person(_ index: Int, screenTime: Double, first: Double, last: Double) -> PersonCandidate {
        var sightings: [Sighting] = []
        var t = first
        while t < last {
            sightings.append(
                Sighting(time: t, box: CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.6),
                         confidence: 0.8)
            )
            t += 1.0 / 12
        }
        return PersonCandidate(
            id: UUID(), index: index, sightings: sightings, thumbnail: nil,
            screenTime: screenTime, clipDuration: 120
        )
    }

    private var populated: (ScanDiagnostics, [PersonCandidate]) {
        var d = ScanDiagnostics()
        d.sampleInterval = 1.0 / 12
        d.requestedFrames = 1440
        d.decodedFrames = 1438
        d.emptyFrames = 61
        d.totalDetections = 3902
        d.contestedDetections = 511
        d.confidenceBuckets = [0, 0, 40, 200, 380, 620, 900, 1100, 700, 202]
        d.detectionsPerFrame = [61, 220, 610, 420, 110, 17, 0, 0, 0]
        d.tracksCreated = 11
        d.tracksBelowMinimum = 3
        d.mergesApplied = 1
        d.minSightings = 24
        d.mergeThreshold = 0.65
        d.reidDistance = 0.50
        d.overlapTolerance = 0.04

        let people = [
            person(1, screenTime: 74.2, first: 0, last: 96),
            person(2, screenTime: 51.8, first: 4, last: 110),
            person(3, screenTime: 22.0, first: 30, last: 61),
        ]
        d.finalPeopleCount = people.count
        d.nearMisses = [
            .init(a: people[0].id, b: people[2].id,
                  reason: .tooFarApart(robust: 0.712, nearest: 0.611)),
            .init(a: people[1].id, b: people[2].id, reason: .noComparableDescriptors),
            .init(a: people[0].id, b: people[1].id,
                  reason: .sharedFrames(count: 476, fractionOfShorter: 0.494)),
        ]
        return (d, people)
    }

    @Test("Report renders every section without losing data")
    func reportRendersFully() {
        let (diagnostics, people) = populated
        let report = diagnostics.report(people: people)

        #expect(report.contains("VERTICALIZE SCAN REPORT"))
        #expect(report.contains("12.0 fps"))
        #expect(report.contains("3902 kept"))
        #expect(report.contains("MERGES DECLINED"))
        #expect(report.contains("PEOPLE"))
        // Each person appears in the table with their label.
        for person in people {
            #expect(report.contains(person.label))
        }
    }

    @Test("Each decline reason states what it means, with its numbers")
    func declineReasonsAreLegible() {
        let (diagnostics, people) = populated
        let report = diagnostics.report(people: people)
        #expect(report.contains("robust 0.712"))
        #expect(report.contains("nearest 0.611"))
        #expect(report.contains("no appearance model"))
        #expect(report.contains("shared 476 frames"))
        #expect(report.contains("49.4%"))
    }

    @Test("No sentinel or non-finite value ever reaches the report")
    func reportContainsNoSentinels() {
        let (diagnostics, people) = populated
        let report = diagnostics.report(people: people)
        // greatestFiniteMagnitude renders as a 309-digit integer; infinity and
        // NaN render as words. All three mean a bug upstream leaked through.
        #expect(!report.contains("e+"))
        #expect(!report.contains("inf"))
        #expect(!report.contains("nan"))
        for line in report.split(separator: "\n") {
            #expect(line.count < 200, "runaway line: \(line.prefix(80))…")
        }
    }

    @Test("Absence counting sees the gaps that make identity hard")
    func absenceCount() {
        var sightings: [Sighting] = []
        let box = CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.6)
        for t in stride(from: 0.0, to: 2.0, by: 1.0 / 12) {
            sightings.append(Sighting(time: t, box: box, confidence: 0.9))
        }
        for t in stride(from: 10.0, to: 12.0, by: 1.0 / 12) {
            sightings.append(Sighting(time: t, box: box, confidence: 0.9))
        }
        let candidate = PersonCandidate(
            id: UUID(), index: 1, sightings: sightings, thumbnail: nil,
            screenTime: 4, clipDuration: 20
        )
        #expect(candidate.absenceCount(threshold: 0.25) == 1)
        #expect(candidate.absenceCount(threshold: 100) == 0)
    }

    @Test("An empty report still renders")
    func emptyReport() {
        let report = ScanDiagnostics().report(people: [])
        #expect(report.contains("VERTICALIZE SCAN REPORT"))
        #expect(!report.contains("inf"))
    }
}
