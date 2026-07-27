//
//  PersonCandidate.swift
//  verticalize
//

import CoreGraphics
import Foundation

/// One detection of one person at one instant.
///
/// `box` is normalized to the *display* frame (rotation already applied) with a
/// top-left origin, which is the convention the crop math and the overlay views
/// both use.
nonisolated struct Sighting: Hashable, Sendable {
    var time: Double
    var box: CGRect
    var confidence: Float

    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// A person the scanner believes appears in the clip, with every moment we saw them.
nonisolated struct PersonCandidate: Identifiable, @unchecked Sendable {
    let id: UUID
    var index: Int
    var sightings: [Sighting]
    /// Best-looking crop of this person, for the picker grid.
    var thumbnail: CGImage?
    /// Seconds of footage this person is visible for.
    var screenTime: Double
    /// Duration of the clip, so the timeline bar knows its scale.
    var clipDuration: Double

    var label: String { "Person \(index)" }
    var firstSeen: Double { sightings.first?.time ?? 0 }
    var lastSeen: Double { sightings.last?.time ?? 0 }

    var coverage: Double {
        guard clipDuration > 0 else { return 0 }
        return min(screenTime / clipDuration, 1)
    }

    var screenTimeLabel: String {
        screenTime < 1
            ? String(format: "%.1fs on screen", screenTime)
            : "\(VideoSource.timecode(screenTime)) on screen"
    }

    /// Sighting nearest a given time, used to draw the source-frame overlay.
    func sighting(nearest time: Double) -> Sighting? {
        guard !sightings.isEmpty else { return nil }
        var best = sightings[0]
        var bestDelta = abs(best.time - time)
        for s in sightings.dropFirst() {
            let delta = abs(s.time - time)
            if delta < bestDelta {
                best = s
                bestDelta = delta
            }
        }
        return bestDelta <= 1.0 ? best : nil
    }
}

/// Output shape options. Vertical is the point of the app; 4:5 and 1:1 come free.
nonisolated enum OutputAspect: String, CaseIterable, Identifiable, Sendable {
    case nineSixteen = "9:16"
    case fourFive = "4:5"
    case square = "1:1"

    var id: String { rawValue }

    /// width / height
    var ratio: Double {
        switch self {
        case .nineSixteen: 9.0 / 16.0
        case .fourFive: 4.0 / 5.0
        case .square: 1.0
        }
    }

    var subtitle: String {
        switch self {
        case .nineSixteen: "Reels · Shorts · TikTok"
        case .fourFive: "Feed post"
        case .square: "Square"
        }
    }

    /// Render size that keeps the long edge at a sane 1080-class resolution.
    func renderSize(maxHeight: Double = 1920) -> CGSize {
        let height = maxHeight
        let width = (height * ratio).rounded(.toNearestOrEven)
        // Encoders are happiest with even dimensions.
        return CGSize(width: width.rounded(.toNearestOrEven), height: height)
    }
}

/// The knobs the user gets over how the virtual camera behaves.
nonisolated struct FramingSettings: Equatable, Sendable {
    var aspect: OutputAspect = .nineSixteen
    /// Seconds of temporal averaging applied to the subject's position.
    var smoothing: Double = 0.9
    /// Fraction of the crop width the subject can drift before the camera moves.
    var deadzone: Double = 0.08
    /// How tight the crop is. 1.0 uses the full source height.
    var zoom: Double = 1.0
    /// Where the subject sits vertically in frame when zoomed in. 0 = centered.
    var verticalBias: Double = 0.0
    /// Maximum pan speed as a fraction of source width per second.
    var maxPanSpeed: Double = 0.55

    static let `default` = FramingSettings()
}
