//
//  CropPathTests.swift
//  verticalizeTests
//
//  The virtual camera: it should follow the subject without inheriting the
//  detector's jitter, and without moving faster than a real pan.
//

import CoreGraphics
import Foundation
import Testing
@testable import verticalize

@Suite("Virtual camera")
struct CropPathTests {

    private let source = VideoSource(
        url: URL(fileURLWithPath: "/dev/null"),
        naturalSize: CGSize(width: 1280, height: 720),
        preferredTransform: .identity,
        duration: 16,
        frameRate: 30,
        hasAudio: false
    )

    /// A subject walking left to right with per-frame jitter the camera should
    /// reject rather than chase.
    private var walkingSubject: [Sighting] {
        (0..<80).map { i in
            let x = 0.2 + 0.6 * (Double(i) / 79) + (i % 2 == 0 ? 0.012 : -0.012)
            return Sighting(
                time: Double(i) * 0.2,
                box: CGRect(x: x - 0.05, y: 0.2, width: 0.1, height: 0.6),
                confidence: 0.9
            )
        }
    }

    @Test("Crop is the requested aspect at full source height")
    func cropGeometry() {
        let size = CropPathBuilder.cropSize(display: source.displaySize, settings: .default)
        #expect(Int(size.height) == 720)
        #expect(abs(size.width - 720 * 9 / 16) < 2)
    }

    @Test("Zoom tightens the crop proportionally")
    func zoomHalvesTheCrop() {
        var settings = FramingSettings.default
        settings.zoom = 2.0
        let size = CropPathBuilder.cropSize(display: source.displaySize, settings: settings)
        #expect(Int(size.height) == 360)
    }

    @Test("A crop wider than the source is clamped to it")
    func cropNeverExceedsSource() {
        var settings = FramingSettings.default
        settings.aspect = .square
        let tall = VideoSource(
            url: source.url, naturalSize: CGSize(width: 400, height: 1000),
            preferredTransform: .identity, duration: 4, frameRate: 30, hasAudio: false
        )
        let size = CropPathBuilder.cropSize(display: tall.displaySize, settings: settings)
        #expect(size.width <= tall.displaySize.width)
        #expect(size.height <= tall.displaySize.height)
    }

    @Test("The camera follows the subject across the clip")
    func cameraFollows() {
        let path = CropPathBuilder.build(
            sightings: walkingSubject, source: source, settings: .default
        )
        let xs = path.centers.map { Double($0.x) }
        #expect(xs.first! < xs.last!)
    }

    @Test("Pan speed never exceeds the configured cap")
    func panSpeedIsCapped() {
        let settings = FramingSettings.default
        let path = CropPathBuilder.build(
            sightings: walkingSubject, source: source, settings: settings
        )
        let xs = path.centers.map { Double($0.x) }
        var maxStep = 0.0
        for i in 1..<xs.count { maxStep = max(maxStep, abs(xs[i] - xs[i - 1])) }
        #expect(maxStep <= settings.maxPanSpeed / path.rate + 1e-9)
    }

    @Test("The crop never leaves the source frame")
    func cropStaysInBounds() {
        let path = CropPathBuilder.build(
            sightings: walkingSubject, source: source, settings: .default
        )
        let halfWidth = Double(path.cropSize.width / path.displaySize.width) / 2
        for centre in path.centers {
            #expect(Double(centre.x) >= halfWidth - 1e-6)
            #expect(Double(centre.x) <= 1 - halfWidth + 1e-6)
        }
    }

    @Test("A stationary subject produces a locked-off shot")
    func stillSubjectDoesNotDrift() {
        let still = (0..<80).map {
            Sighting(
                time: Double($0) * 0.2,
                box: CGRect(x: 0.45, y: 0.2, width: 0.1, height: 0.6), confidence: 0.9
            )
        }
        let path = CropPathBuilder.build(sightings: still, source: source, settings: .default)
        let xs = path.centers.map { Double($0.x) }
        #expect((xs.max()! - xs.min()!) < 0.002, "the deadzone should hold the frame still")
    }

    @Test("With no sightings the crop parks in the middle")
    func emptySightingsCentre() {
        let path = CropPathBuilder.build(sightings: [], source: source, settings: .default)
        #expect(path.centers.allSatisfy { abs(Double($0.x) - 0.5) < 1e-9 })
    }

    @Test("Interpolation between grid points is continuous")
    func centreInterpolates() {
        let path = CropPathBuilder.build(
            sightings: walkingSubject, source: source, settings: .default
        )
        let a = path.center(at: 4.0)
        let b = path.center(at: 4.0 + 0.5 / path.rate)
        let c = path.center(at: 4.0 + 1.0 / path.rate)
        #expect(min(a.x, c.x) - 1e-9 <= b.x && b.x <= max(a.x, c.x) + 1e-9)
    }

    @Test("Requesting a time past the end holds the last framing")
    func pastEndHoldsLast() {
        let path = CropPathBuilder.build(
            sightings: walkingSubject, source: source, settings: .default
        )
        #expect(path.center(at: 1e6) == path.centers.last!)
    }
}
