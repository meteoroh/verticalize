//
//  TrackerScenario.swift
//  verticalizeTests
//
//  Scripted detections for driving `IdentityTracker` without any video.
//
//  Labels come from the script, so every scenario has exact ground truth: we
//  know which person each detection belongs to and can assert that a track
//  never switched between them.
//

import CoreGraphics
import Foundation
@testable import verticalize

// MARK: - Appearance

/// Descriptors encode `person * 1000 + frame`, so distances can answer "same
/// person?" while still varying frame to frame.
///
/// Defaults come from measurement on real footage rather than invention:
/// full-body FeaturePrint distances have a same-person median of 0.24 and a
/// different-person median of 0.48. `different` sits above that median to
/// represent a clearly different pair, and above `reidDistance` so tests do not
/// balance exactly on the threshold.
enum Appearance {
    static let samePerson = 0.25
    static let differentPerson = 0.60
    /// A crop containing two people resembles neither.
    static let blobPerson = 9

    static func distance(
        same: Double = samePerson, different: Double = differentPerson
    ) -> (Int, Int) -> Double? {
        { a, b in
            let personA = a / 1000, personB = b / 1000
            if personA == blobPerson || personB == blobPerson { return 0.58 }
            return personA == personB ? same : different
        }
    }
}

// MARK: - Scripted world

struct Actor {
    var person: Int
    /// Centre x for every frame, so non-linear paths are expressible.
    var xs: [Double]
    var y: Double = 0.2
    var width: Double = 0.12
    var height: Double = 0.6

    init(person: Int, from: Double, to: Double, frames: Int) {
        self.person = person
        self.xs = (0..<frames).map {
            from + (to - from) * Double($0) / Double(max(frames - 1, 1))
        }
    }

    init(person: Int, xs: [Double]) {
        self.person = person
        self.xs = xs
    }

    func box(frame: Int) -> CGRect {
        let x = xs[min(max(frame, 0), xs.count - 1)]
        return CGRect(x: x - width / 2, y: y, width: width, height: height)
    }
}

/// Walks from `a` to `b` over `count` frames.
func ramp(_ a: Double, _ b: Double, _ count: Int) -> [Double] {
    (0..<count).map { a + (b - a) * Double($0) / Double(max(count - 1, 1)) }
}

/// Holds still for `count` frames.
func hold(_ x: Double, _ count: Int) -> [Double] {
    [Double](repeating: x, count: count)
}

/// Resamples a path onto a finer grid, so the same choreography can be replayed
/// at a different frame rate.
func densify(_ xs: [Double], factor: Int) -> [Double] {
    var out: [Double] = []
    for i in 0..<(xs.count - 1) {
        for step in 0..<factor {
            out.append(xs[i] + (xs[i + 1] - xs[i]) * Double(step) / Double(factor))
        }
    }
    out.append(xs[xs.count - 1])
    return out
}

struct Scenario {
    var actors: [Actor]
    var frames: Int
    var dt: Double = 0.2
    /// Frames where the actors are reported as one merged detection.
    var mergedFrames: Set<Int> = []
    /// Frames where a given person is missing from the detector output.
    var missing: [Int: Set<Int>] = [:]

    func observations(frame: Int) -> [(person: Int, box: CGRect, descriptor: Int)] {
        if mergedFrames.contains(frame) {
            let boxes = actors.map { $0.box(frame: frame) }
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            return [(person: -1, box: union, descriptor: Appearance.blobPerson * 1000 + frame)]
        }
        return actors.compactMap { actor in
            if missing[actor.person]?.contains(frame) == true { return nil }
            return (actor.person, actor.box(frame: frame), actor.person * 1000 + frame)
        }
    }

    func run(
        options: IdentityTracker.Options = .default,
        same: Double = Appearance.samePerson,
        different: Double = Appearance.differentPerson,
        withDescriptors: Bool = true
    ) -> IdentityTracker {
        let tracker = IdentityTracker(
            options: options,
            appearanceDistance: Appearance.distance(same: same, different: different)
        )
        for frame in 0..<frames {
            let observations = observations(frame: frame).map {
                IdentityTracker.Observation(
                    box: $0.box, confidence: 0.9,
                    descriptor: withDescriptors ? $0.descriptor : nil
                )
            }
            tracker.update(
                time: Double(frame) * dt, sampleIndex: frame, observations: observations
            )
        }
        return tracker
    }

    /// Which person's scripted box is nearest this sighting.
    func nearestPerson(to sighting: Sighting) -> Int {
        let frame = Int((sighting.time / dt).rounded())
        var best = -1
        var bestDistance = Double.greatestFiniteMagnitude
        for actor in actors {
            let d = abs(Double(actor.box(frame: frame).midX - sighting.box.midX))
            if d < bestDistance { bestDistance = d; best = actor.person }
        }
        return best
    }

    /// For each track: the person it mostly followed, how many of its sightings
    /// were on that person, and how many were judged at all. Frames where the
    /// two were reported as one blob are excluded — nobody can be right there.
    func identityReport(_ tracker: IdentityTracker) -> [(person: Int, onTarget: Int, total: Int)] {
        tracker.tracks.map { track in
            var counts: [Int: Int] = [:]
            for sighting in track.sightings {
                let frame = Int((sighting.time / dt).rounded())
                guard !mergedFrames.contains(frame) else { continue }
                counts[nearestPerson(to: sighting), default: 0] += 1
            }
            let dominant = counts.max { $0.value < $1.value }?.key ?? -1
            return (dominant, counts[dominant] ?? 0, counts.values.reduce(0, +))
        }
    }

    /// True when there is one track per person and none of them ever switched.
    func identitiesHeld(_ tracker: IdentityTracker) -> Bool {
        let report = identityReport(tracker)
        guard report.count == actors.count,
              Set(report.map(\.person)).count == actors.count else { return false }
        return report.allSatisfy { $0.total > 0 && $0.onTarget == $0.total }
    }
}

/// Feeds a tracker a timeline of (person, x) per frame. A person absent from a
/// frame's list is off-screen — which is how re-entry is scripted.
func runTimeline(
    _ frames: [[(person: Int, x: Double)]],
    dt: Double = 1.0 / 12,
    options: IdentityTracker.Options = .default,
    same: Double = Appearance.samePerson,
    different: Double = Appearance.differentPerson
) -> IdentityTracker {
    let tracker = IdentityTracker(
        options: options,
        appearanceDistance: Appearance.distance(same: same, different: different)
    )
    for (frame, people) in frames.enumerated() {
        let observations = people.map { entry in
            IdentityTracker.Observation(
                box: CGRect(x: entry.x - 0.06, y: 0.2, width: 0.12, height: 0.6),
                confidence: 0.9,
                descriptor: entry.person * 1000 + frame
            )
        }
        tracker.update(time: Double(frame) * dt, sampleIndex: frame, observations: observations)
    }
    return tracker
}
