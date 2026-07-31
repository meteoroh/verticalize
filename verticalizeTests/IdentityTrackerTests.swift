//
//  IdentityTrackerTests.swift
//  verticalizeTests
//
//  The behaviour these cover is the whole point of the app: keep following the
//  person the user picked, through crossings, occlusions and exits from frame.
//  Several carry a deliberate negative control, because a test that passes both
//  before and after a change proves nothing about that change.
//

import CoreGraphics
import Foundation
import Testing
@testable import verticalize

@Suite("Identity tracking")
struct IdentityTrackerTests {

    // MARK: - Crossings

    /// Confirms one track per person and that none of them ever switched.
    private func expectCleanIdentities(
        _ scenario: Scenario, _ tracker: IdentityTracker,
        _ label: Comment, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let report = scenario.identityReport(tracker)
        #expect(
            tracker.tracks.count == scenario.actors.count,
            label, sourceLocation: sourceLocation
        )
        #expect(
            Set(report.map(\.person)).count == scenario.actors.count,
            label, sourceLocation: sourceLocation
        )
        for row in report {
            #expect(
                row.total > 0 && row.onTarget == row.total,
                "\(label) — person \(row.person): \(row.onTarget)/\(row.total) on target",
                sourceLocation: sourceLocation
            )
        }
    }

    private func crossing(
        merged: Set<Int> = [], missing: [Int: Set<Int>] = [:]
    ) -> Scenario {
        Scenario(
            actors: [
                Actor(person: 0, from: 0.15, to: 0.75, frames: 16),
                Actor(person: 1, from: 0.75, to: 0.15, frames: 16),
            ],
            frames: 16, mergedFrames: merged, missing: missing
        )
    }

    @Test("Two people cross, both visible throughout")
    func plainCrossing() {
        let scenario = crossing()
        expectCleanIdentities(scenario, scenario.run(), "crossing")
    }

    @Test("The detector merges both people into one box mid-crossing")
    func occludedCrossing() {
        let scenario = crossing(merged: [7, 8])
        expectCleanIdentities(scenario, scenario.run(), "occluded crossing")
    }

    @Test("One person is lost entirely for three frames")
    func dropoutCrossing() {
        let scenario = crossing(missing: [1: [7, 8, 9]])
        expectCleanIdentities(scenario, scenario.run(), "dropout crossing")
    }

    @Test("Two people who look alike cross")
    func lookalikeCrossing() {
        let scenario = crossing()
        expectCleanIdentities(
            scenario, scenario.run(different: 0.40), "lookalike crossing"
        )
    }

    @Test("Two people pass at different heights")
    func staggeredCrossing() {
        var a = Actor(person: 0, from: 0.15, to: 0.75, frames: 16)
        var b = Actor(person: 1, from: 0.75, to: 0.15, frames: 16)
        a.width = 0.14
        b.y = 0.28
        b.height = 0.5
        let scenario = Scenario(actors: [a, b], frames: 16)
        expectCleanIdentities(scenario, scenario.run(), "staggered crossing")
    }

    @Test("Three people milling around")
    func threeWay() {
        let scenario = Scenario(
            actors: [
                Actor(person: 0, from: 0.10, to: 0.80, frames: 20),
                Actor(person: 1, from: 0.80, to: 0.10, frames: 20),
                Actor(person: 2, from: 0.45, to: 0.50, frames: 20),
            ],
            frames: 20
        )
        expectCleanIdentities(scenario, scenario.run(), "three-way")
    }

    // MARK: - Cases motion prediction cannot solve
    //
    // The crossings above are all solvable by velocity prediction alone. These
    // two are not, which is what makes them the tests that actually exercise
    // the appearance term. Each asserts that motion-only *fails*, so the test
    // cannot quietly stop testing what it claims to.

    private var bounce: Scenario {
        // They close to almost touching, then each turns back the way they
        // came, so every velocity prediction points at the other person.
        Scenario(
            actors: [
                Actor(person: 0, xs: ramp(0.15, 0.47, 8) + ramp(0.47, 0.15, 8)),
                Actor(person: 1, xs: ramp(0.79, 0.49, 8) + ramp(0.49, 0.79, 8)),
            ],
            frames: 16
        )
    }

    private var huddle: Scenario {
        Scenario(
            actors: [
                Actor(person: 0, xs: ramp(0.15, 0.45, 6) + hold(0.45, 6) + ramp(0.45, 0.80, 8)),
                Actor(person: 1, xs: ramp(0.75, 0.47, 6) + hold(0.47, 6) + ramp(0.47, 0.12, 8)),
            ],
            frames: 20, mergedFrames: [7, 8, 9]
        )
    }

    @Test("They meet, then both reverse — prediction points the wrong way")
    func bounceHoldsIdentities() {
        let scenario = bounce
        expectCleanIdentities(scenario, scenario.run(), "bounce")
        #expect(
            !scenario.identitiesHeld(scenario.run(withDescriptors: false)),
            "motion alone must fail here, or this test proves nothing"
        )
    }

    @Test("They stand together, then leave in swapped directions")
    func huddleHoldsIdentities() {
        let scenario = huddle
        expectCleanIdentities(scenario, scenario.run(), "huddle")
        #expect(
            !scenario.identitiesHeld(scenario.run(withDescriptors: false)),
            "motion alone must fail here too"
        )
    }

    @Test("The hard cases still hold on a denser frame grid")
    func hardCasesAtHigherFrameRate() {
        for (name, source) in [("bounce", bounce), ("huddle", huddle)] {
            let dense = Scenario(
                actors: source.actors.map {
                    Actor(person: $0.person, xs: densify($0.xs, factor: 3))
                },
                frames: densify(source.actors[0].xs, factor: 3).count,
                dt: source.dt / 3,
                mergedFrames: Set(source.mergedFrames.flatMap { (($0 * 3)...($0 * 3 + 2)) })
            )
            expectCleanIdentities(dense, dense.run(), "\(name) at 3x frame rate")
        }
    }

    // MARK: - Occlusion and coasting

    @Test("A coasting track does not drift away from where it vanished")
    func coastingDoesNotDrift() {
        let tracker = IdentityTracker(appearanceDistance: Appearance.distance())
        for frame in 0..<10 {
            tracker.update(time: Double(frame) * 0.083, sampleIndex: frame, observations: [
                .init(box: CGRect(x: 0.2 + 0.02 * Double(frame), y: 0.2, width: 0.12, height: 0.6),
                      confidence: 0.9, descriptor: frame)
            ])
        }
        let track = try! #require(tracker.tracks.first)
        let parked = track.box.midX
        for frame in 10..<25 {
            tracker.update(time: Double(frame) * 0.083, sampleIndex: frame, observations: [])
        }
        #expect(
            abs(Double(track.box.midX - parked)) < 1e-9,
            "15 unmatched frames must not move the confirmed position"
        )
        // Last confirmed frame is 9 at x = 0.38, so the centre is 0.44.
        #expect(abs(Double(track.box.midX) - 0.44) < 0.02)
    }

    @Test("A track born in a crowded frame still learns an appearance model")
    func contestedTrackIsStillIdentifiable() {
        let tracker = IdentityTracker(appearanceDistance: Appearance.distance())
        // Overlapping heavily, so every crop is contested.
        for frame in 0..<6 {
            tracker.update(time: Double(frame) / 12, sampleIndex: frame, observations: [
                .init(box: CGRect(x: 0.40, y: 0.2, width: 0.12, height: 0.6),
                      confidence: 0.9, descriptor: frame),
                .init(box: CGRect(x: 0.44, y: 0.2, width: 0.12, height: 0.6),
                      confidence: 0.9, descriptor: 1000 + frame),
            ])
        }
        #expect(tracker.tracks.count == 2)
        #expect(
            tracker.tracks.allSatisfy { !$0.descriptors.isEmpty },
            "a track with no model can never be merged or re-identified"
        )
        #expect(tracker.tracks.allSatisfy { !$0.hasCleanDescriptor })

        // Once they separate, a real model replaces the provisional one.
        for frame in 6..<12 {
            tracker.update(time: Double(frame) / 12, sampleIndex: frame, observations: [
                .init(box: CGRect(x: 0.10, y: 0.2, width: 0.12, height: 0.6),
                      confidence: 0.9, descriptor: frame),
                .init(box: CGRect(x: 0.70, y: 0.2, width: 0.12, height: 0.6),
                      confidence: 0.9, descriptor: 1000 + frame),
            ])
        }
        #expect(tracker.tracks.allSatisfy { $0.hasCleanDescriptor })
        #expect(
            tracker.tracks.allSatisfy { $0.descriptors.count <= 6 },
            "provisional descriptors are discarded, not appended to"
        )
    }

    // MARK: - Leaving and re-entering frame

    @Test("Someone who walks out of frame and back is one track, not two")
    func reEntryStaysOneTrack() {
        var frames: [[(person: Int, x: Double)]] = []
        for i in 0..<12 { frames.append([(0, 0.5 - 0.04 * Double(i))]) }   // exits left
        for _ in 0..<40 { frames.append([]) }                              // gone ~3.3s
        for i in 0..<12 { frames.append([(0, 0.04 + 0.04 * Double(i))]) }  // returns left
        #expect(runTimeline(frames).tracks.count == 1)
    }

    @Test("Re-entry while a lookalike holds the frame")
    func reEntryWithLookalikePresent() {
        var frames: [[(person: Int, x: Double)]] = []
        for i in 0..<12 { frames.append([(0, 0.45 - 0.035 * Double(i)), (1, 0.75)]) }
        for _ in 0..<30 { frames.append([(1, 0.75)]) }
        for i in 0..<12 { frames.append([(0, 0.04 + 0.03 * Double(i)), (1, 0.75)]) }

        let tracker = runTimeline(frames, different: 0.30)   // deliberately tempting
        #expect(tracker.tracks.count == 2)
        #expect(
            tracker.tracks.contains { track in
                track.sightings.allSatisfy { abs(Double($0.box.midX) - 0.75) < 0.02 }
            },
            "the person who never moved was never claimed by the returning track"
        )
    }

    @Test("A stranger arriving mid-frame does not inherit an exited track")
    func midFrameArrivalStartsItsOwnTrack() {
        var frames: [[(person: Int, x: Double)]] = []
        for i in 0..<12 { frames.append([(0, 0.45 - 0.035 * Double(i))]) }   // exits left
        for _ in 0..<20 { frames.append([]) }
        for _ in 0..<12 { frames.append([(1, 0.5)]) }                        // appears mid-frame
        #expect(runTimeline(frames, different: 0.30).tracks.count == 2)

        // Control: the identical arrival at the edge IS allowed through, which
        // shows the gate keys on where somebody appears, not how they look.
        var edgeFrames = Array(frames.prefix(32))
        for _ in 0..<12 { edgeFrames.append([(1, 0.06)]) }
        #expect(runTimeline(edgeFrames, different: 0.30).tracks.count == 1)
    }

    @Test("A different person appearing later gets their own track")
    func strangerGetsOwnTrack() {
        var frames: [[(person: Int, x: Double)]] = []
        for _ in 0..<6 { frames.append([(0, 0.2)]) }
        for _ in 0..<14 { frames.append([]) }
        for _ in 0..<6 { frames.append([(1, 0.7)]) }
        #expect(runTimeline(frames).tracks.count == 2)
    }

    // MARK: - Appearance model hygiene

    @Test("No track learns a descriptor from an overlapping crop")
    func appearanceModelIsNotContaminated() {
        let tracker = crossing().run()
        for track in tracker.tracks {
            #expect(
                Set(track.descriptors.map { $0 / 1000 }).count <= 1,
                "a model built from more than one person is worse than none"
            )
        }
        #expect(tracker.tracks.allSatisfy { !$0.descriptors.isEmpty })
    }
}
