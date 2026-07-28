//
//  IdentityTracker.swift
//  verticalize
//
//  Multi-object tracking with identity preservation. Deliberately free of
//  Vision and AVFoundation so the matching behaviour — especially what happens
//  when two people cross — can be exercised directly in tests.
//
//  Per frame it builds one cost matrix over (track, observation) pairs blending
//  predicted motion with appearance, then solves it optimally. Appearance takes
//  over the decision whenever the frame is ambiguous, which is exactly when
//  motion alone would flip two identities.
//

import CoreGraphics
import Foundation

nonisolated final class IdentityTracker {

    struct Options: Sendable {
        /// How long a track may be matched on motion after its last real sighting.
        var motionGap: Double = 0.8
        /// How long a track survives unmatched before it can only return by looks.
        var coastTime: Double = 1.5
        /// Minimum overlap with the predicted box for a motion-supported match.
        var minIoU: Double = 0.15
        /// Appearance's share of the cost when nothing overlaps…
        var appearanceWeightClean: Double = 0.35
        /// …and when it does, which is when identities actually get confused.
        var appearanceWeightAmbiguous: Double = 0.8
        /// No amount of overlap can justify a match beyond this far apart.
        var appearanceCeiling: Double = 1.05
        /// Appearance-only re-identification threshold.
        var reidDistance: Double = 0.62
        /// How many of a track's nearest descriptors are averaged to compare it
        /// with a detection. Comparing against the single nearest lets one
        /// lucky match pull in a stranger, and one unlucky set lose the real
        /// subject; averaging the closest few tightens both tails at once.
        var appearanceSampleCount: Int = 3
        /// A box within this fraction of the left or right edge counts as
        /// touching it. Top and bottom are deliberately excluded — a standing
        /// subject's box reaches the bottom of frame almost always.
        var frameEdgeMargin: Double = 0.05
        /// Require a re-identification to be the best match in both directions.
        /// An ambiguous re-entry then starts a new track instead of guessing,
        /// and the scanner's offline merge — which knows the two tracks never
        /// share a frame — resolves it with more evidence than exists here.
        var requireMutualBestReid: Bool = true
        /// Two boxes overlapping more than this make a frame ambiguous, and any
        /// crop taken from it unfit to learn an identity from.
        var contactIoU: Double = 0.12
        var minCleanConfidence: Float = 0.5
        var maxDescriptors: Int = 12
        /// Time constant of the velocity estimate. Expressed in seconds rather
        /// than as a fixed blend weight so that sampling more often smooths the
        /// estimate instead of making it noisier — dividing a smaller step by a
        /// smaller dt amplifies detector jitter.
        var velocitySmoothing: Double = 0.25
        /// Prediction decays over a gap rather than extrapolating off-screen.
        var velocityHalfLife: Double = 0.45

        static let `default` = Options()
    }

    struct Observation: Sendable {
        var box: CGRect
        var confidence: Float
        /// Opaque handle into the caller's appearance table. Optional because
        /// descriptors are only worth computing when the frame is contested.
        var descriptor: Int?

        init(box: CGRect, confidence: Float, descriptor: Int? = nil) {
            self.box = box
            self.confidence = confidence
            self.descriptor = descriptor
        }
    }

    final class Track {
        let id = UUID()
        fileprivate(set) var sightings: [Sighting] = []
        /// Last *confirmed* position. Never advanced by coasting: predictions
        /// always extrapolate from here, so a long occlusion decays to a
        /// bounded offset instead of walking the box off across the frame.
        fileprivate(set) var box: CGRect = .zero
        fileprivate(set) var velocity: CGVector = .zero
        fileprivate(set) var lastConfirmedTime: Double = -.greatestFiniteMagnitude
        /// Appearance descriptors, learned only from uncontested crops.
        fileprivate(set) var descriptors: [Int] = []
        /// Sample indices this track was seen at, for the co-occurrence check.
        fileprivate(set) var sampleIndices: Set<Int> = []
        /// Whether the last confirmed box was against the left or right edge.
        /// If it was, this person most likely walked out of shot rather than
        /// being occluded — and will walk back in at an edge, not materialise
        /// in the middle of the frame.
        fileprivate(set) var leftAtSideEdge = false
        /// Whether `descriptors` holds crops known to contain one person, or a
        /// provisional stand-in taken from a contested frame.
        fileprivate(set) var hasCleanDescriptor = false
        fileprivate var descriptorCursor = 0

        fileprivate func predictedBox(at time: Double, options: Options) -> CGRect {
            let dt = time - lastConfirmedTime
            guard dt > 0, dt.isFinite else { return box }
            let decay = exp(-dt / options.velocityHalfLife)
            return box.offsetBy(
                dx: velocity.dx * dt * decay, dy: velocity.dy * dt * decay
            )
        }
    }

    /// Cost assigned to a pair that must never be matched.
    fileprivate static let forbidden = 1e6

    private(set) var tracks: [Track] = []
    private let options: Options
    /// Distance between two descriptors, or nil when it can't be computed.
    private let appearanceDistance: (Int, Int) -> Double?

    init(
        options: Options = .default,
        appearanceDistance: @escaping (Int, Int) -> Double?
    ) {
        self.options = options
        self.appearanceDistance = appearanceDistance
    }

    /// True when identity is genuinely at stake this frame — people in contact,
    /// or one track that could plausibly claim more than one detection. Motion
    /// is the better signal when everyone is well separated, so this stays
    /// false then and appearance keeps only a minority vote.
    func isContested(at time: Double, observations: [Observation]) -> Bool {
        guard observations.count > 1 || tracks.count > 1 else { return false }
        if anyPairInContact(observations.map(\.box)) { return true }

        let predictions = tracks
            .filter { time - $0.lastConfirmedTime <= options.coastTime }
            .map { $0.predictedBox(at: time, options: options) }
        if predictions.count > 1, anyPairInContact(predictions) { return true }

        for prediction in predictions {
            let reachable = observations.filter {
                Geometry.iou(prediction, $0.box) >= options.minIoU
            }
            if reachable.count > 1 { return true }
        }
        return false
    }

    /// What happened to one observation this frame.
    struct Assignment {
        var track: Track
        /// Whether this detection is likely to contain more than one person,
        /// and so is unfit to learn an identity — or pick a thumbnail — from.
        var isContested: Bool
    }

    /// Advances every track by one frame.
    /// - Returns: for each observation, the track that claimed it.
    @discardableResult
    func update(
        time: Double, sampleIndex: Int, observations: [Observation]
    ) -> [Assignment] {
        let ambiguous = isContested(at: time, observations: observations)
        let predictions = tracks.map { $0.predictedBox(at: time, options: options) }
        let livePredictions = tracks.indices
            .filter { time - tracks[$0].lastConfirmedTime <= options.coastTime }
            .map { predictions[$0] }
        let contested = contestedFlags(observations, predictions: livePredictions)

        // Appearance is needed twice — once for the cost and once to decide
        // mutual-best — so compute the whole matrix up front.
        let appearances = tracks.map { track in
            observations.map { appearanceDistance(track: track, observation: $0) }
        }
        let mutualBest = mutualBestPairs(appearances, observationCount: observations.count)

        var costs = [[Double]](
            repeating: [Double](repeating: Self.forbidden, count: observations.count),
            count: tracks.count
        )
        for t in tracks.indices {
            for o in observations.indices {
                costs[t][o] = cost(
                    track: tracks[t], predicted: predictions[t],
                    observation: observations[o], appearance: appearances[t][o],
                    isMutualBest: mutualBest.contains(Pair(track: t, observation: o)),
                    time: time, ambiguous: ambiguous
                )
            }
        }

        let assignment = Hungarian.solve(
            costs, rows: tracks.count, cols: observations.count
        )

        var claimedBy = [Track?](repeating: nil, count: observations.count)
        var matchedTracks = Set<Int>()
        for t in tracks.indices {
            let o = assignment[t]
            guard o >= 0, costs[t][o] < Self.forbidden / 2 else { continue }
            matchedTracks.insert(t)
            claimedBy[o] = tracks[t]
            confirm(
                tracks[t], with: observations[o], at: time,
                sampleIndex: sampleIndex, contested: contested[o]
            )
        }

        // Unmatched tracks are left exactly as they were. `predictedBox` always
        // extrapolates from the last *confirmed* position, so an unmatched track
        // needs no bookkeeping — and crucially cannot accumulate drift.

        // Whatever is left is somebody new.
        for o in observations.indices where claimedBy[o] == nil {
            let track = Track()
            tracks.append(track)
            claimedBy[o] = track
            confirm(
                track, with: observations[o], at: time,
                sampleIndex: sampleIndex, contested: contested[o]
            )
        }

        return claimedBy.enumerated().map {
            Assignment(track: $0.element!, isContested: contested[$0.offset])
        }
    }

    // MARK: - Cost

    private func cost(
        track: Track, predicted: CGRect, observation: Observation,
        appearance: Double?, isMutualBest: Bool, time: Double, ambiguous: Bool
    ) -> Double {
        // A hard veto: no overlap, however perfect, outranks looking like
        // somebody else. This is what stops a swap at a crossing.
        if let appearance, appearance > options.appearanceCeiling {
            return Self.forbidden
        }

        let overlap = Geometry.iou(predicted, observation.box)
        let motionSupported = time - track.lastConfirmedTime <= options.motionGap
            && overlap >= options.minIoU

        // Re-identification: motion says nothing, so every other check applies.
        if !motionSupported {
            // Appearance has to be convincing on its own…
            guard let appearance, appearance <= options.reidDistance else {
                return Self.forbidden
            }
            // …and unambiguous. A contested re-entry is better left to start a
            // new track, which the offline merge can join up later.
            if options.requireMutualBestReid, !isMutualBest {
                return Self.forbidden
            }
            // Somebody who walked out of the side of frame walks back in at a
            // side. A detection appearing mid-frame is a different person.
            if track.leftAtSideEdge, !touchesSideEdge(observation.box) {
                return Self.forbidden
            }
        }

        // Motion cost saturates at 1 when there is no usable overlap, which puts
        // a re-identification on the same scale as a weak motion match rather
        // than behind every motion match however wrong that match looks. Ranking
        // re-ID strictly last is what let a coasting track get shoved onto the
        // wrong person the moment an occlusion cleared.
        let motion = motionSupported ? 1 - overlap : 1
        guard let appearance else { return motion }
        let weight = ambiguous
            ? options.appearanceWeightAmbiguous : options.appearanceWeightClean
        let normalized = min(appearance / options.appearanceCeiling, 1)
        return (1 - weight) * motion + weight * normalized
    }

    private func appearanceDistance(
        track: Track, observation: Observation
    ) -> Double? {
        guard let probe = observation.descriptor, !track.descriptors.isEmpty else {
            return nil
        }
        return AppearanceMetric.robust(
            track.descriptors.compactMap { appearanceDistance(probe, $0) },
            sampleCount: options.appearanceSampleCount
        )
    }

    /// Pairs that are each other's closest appearance match.
    private struct Pair: Hashable {
        var track: Int
        var observation: Int
    }

    private func mutualBestPairs(
        _ appearances: [[Double?]], observationCount: Int
    ) -> Set<Pair> {
        func argmin(_ values: [Double?]) -> Int? {
            var best: (index: Int, value: Double)?
            for (index, value) in values.enumerated() {
                guard let value else { continue }
                if best == nil || value < best!.value { best = (index, value) }
            }
            return best?.index
        }
        let bestObservation = appearances.map(argmin)
        let bestTrack = (0..<observationCount).map { o in
            argmin(appearances.map { $0[o] })
        }
        var pairs: Set<Pair> = []
        for t in appearances.indices {
            guard let o = bestObservation[t], bestTrack[o] == t else { continue }
            pairs.insert(Pair(track: t, observation: o))
        }
        return pairs
    }

    private func touchesSideEdge(_ box: CGRect) -> Bool {
        Double(box.minX) <= options.frameEdgeMargin
            || Double(box.maxX) >= 1 - options.frameEdgeMargin
    }

    // MARK: - Track updates

    private func confirm(
        _ track: Track, with observation: Observation, at time: Double,
        sampleIndex: Int, contested: Bool
    ) {
        let previousCenter = CGPoint(x: track.box.midX, y: track.box.midY)
        let dt = time - track.lastConfirmedTime
        let center = CGPoint(x: observation.box.midX, y: observation.box.midY)

        if dt > 0, dt <= options.motionGap, track.lastConfirmedTime > -.greatestFiniteMagnitude {
            let measured = CGVector(
                dx: (center.x - previousCenter.x) / dt,
                dy: (center.y - previousCenter.y) / dt
            )
            let blend = 1 - exp(-dt / options.velocitySmoothing)
            track.velocity = CGVector(
                dx: track.velocity.dx * (1 - blend) + measured.dx * blend,
                dy: track.velocity.dy * (1 - blend) + measured.dy * blend
            )
        } else if dt > options.motionGap {
            track.velocity = .zero
        }

        track.box = observation.box
        track.lastConfirmedTime = time
        track.leftAtSideEdge = touchesSideEdge(observation.box)
        track.sampleIndices.insert(sampleIndex)
        track.sightings.append(
            Sighting(time: time, box: observation.box, confidence: observation.confidence)
        )

        guard let descriptor = observation.descriptor else { return }
        let isClean = !contested && observation.confidence >= options.minCleanConfidence

        // Prefer to learn identity only from a crop containing one person. But
        // a track with no model at all can never be re-identified or merged —
        // a short track born in a crowded frame would be stranded as its own
        // person forever — so take a contested crop rather than nothing, and
        // discard it the moment something clean arrives.
        guard isClean || track.descriptors.isEmpty else { return }
        if isClean, !track.hasCleanDescriptor {
            track.descriptors.removeAll()
            track.hasCleanDescriptor = true
            track.descriptorCursor = 0
        } else if !isClean, track.hasCleanDescriptor {
            return
        }

        if track.descriptors.count < options.maxDescriptors {
            track.descriptors.append(descriptor)
        } else {
            // Keep the founding descriptor; rotate through the rest.
            track.descriptorCursor = (track.descriptorCursor + 1)
                % (options.maxDescriptors - 1)
            track.descriptors[1 + track.descriptorCursor] = descriptor
        }
    }

    // MARK: - Contact

    private func contestedFlags(
        _ observations: [Observation], predictions: [CGRect]
    ) -> [Bool] {
        var flags = [Bool](repeating: false, count: observations.count)
        for i in observations.indices {
            for j in observations.indices where j > i {
                if Geometry.iou(observations[i].box, observations[j].box) > options.contactIoU {
                    flags[i] = true
                    flags[j] = true
                }
            }
            // A single detection that more than one track is reaching for is
            // usually two people merged into one box. It looks uncontested from
            // the detections alone, which is how it used to poison the model of
            // whichever track happened to claim it.
            let claimants = predictions.filter {
                Geometry.iou($0, observations[i].box) >= options.minIoU
            }
            if claimants.count > 1 { flags[i] = true }
        }
        return flags
    }

    private func anyPairInContact(_ boxes: [CGRect]) -> Bool {
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                if Geometry.iou(boxes[i], boxes[j]) > options.contactIoU { return true }
            }
        }
        return false
    }
}

// MARK: - Appearance

nonisolated enum AppearanceMetric {
    /// Mean of the `sampleCount` smallest distances.
    ///
    /// Taking the raw minimum makes a comparison only as reliable as its single
    /// luckiest descriptor: one crop that happens to resemble a stranger pulls
    /// them in, and one unrepresentative set loses the real subject. Averaging
    /// the nearest few costs nothing and tightens both tails.
    static func robust(_ distances: [Double], sampleCount: Int) -> Double? {
        guard !distances.isEmpty else { return nil }
        let sorted = distances.sorted()
        let count = min(max(sampleCount, 1), sorted.count)
        return sorted.prefix(count).reduce(0, +) / Double(count)
    }
}

// MARK: - Geometry

nonisolated enum Geometry {
    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let overlap = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - overlap
        return union > 0 ? overlap / union : 0
    }
}

// MARK: - Assignment

/// Minimum-cost assignment via the shortest-augmenting-path Hungarian method.
/// Greedy matching is what lets a crossing swap two identities; this doesn't.
nonisolated enum Hungarian {

    /// - Returns: for each row, the column it was assigned, or -1.
    static func solve(_ cost: [[Double]], rows: Int, cols: Int) -> [Int] {
        guard rows > 0, cols > 0 else { return [Int](repeating: -1, count: rows) }
        let n = max(rows, cols)
        // Padding is as expensive as a forbidden pair, so real matches win.
        var c = [[Double]](
            repeating: [Double](repeating: IdentityTracker.forbidden, count: n + 1),
            count: n + 1
        )
        for i in 0..<rows {
            for j in 0..<cols { c[i + 1][j + 1] = cost[i][j] }
        }

        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1)
        var way = [Int](repeating: 0, count: n + 1)

        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .greatestFiniteMagnitude, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.greatestFiniteMagnitude
                var j1 = 0
                for j in 1...n where !used[j] {
                    let current = c[i0][j] - u[i0] - v[j]
                    if current < minv[j] {
                        minv[j] = current
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }

        var result = [Int](repeating: -1, count: rows)
        for j in 1...n {
            let row = p[j] - 1
            let col = j - 1
            if row >= 0, row < rows, col < cols { result[row] = col }
        }
        return result
    }
}
