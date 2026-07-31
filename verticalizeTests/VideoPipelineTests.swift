//
//  VideoPipelineTests.swift
//  verticalizeTests
//
//  End-to-end through the real composition and the real encoder, asserting on
//  rendered pixels. This is what pinned down the composition's coordinate
//  origin — a question no amount of reading the documentation settled.
//

import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import verticalize

@Suite("Video pipeline", .serialized)
struct VideoPipelineTests {

    private func fixture() async throws -> (URL, VideoSource) {
        let url = try SyntheticClip.url()
        return (url, try await VideoLoader.load(url: url))
    }

    private func staticPath(
        source: VideoSource, centre: CGPoint, settings: FramingSettings = .default
    ) -> CropPath {
        CropPath(
            rate: 30,
            centers: Array(repeating: centre, count: 121),
            cropSize: CropPathBuilder.cropSize(display: source.displaySize, settings: settings),
            displaySize: source.displaySize,
            renderSize: settings.aspect.renderSize(),
            duration: source.duration
        )
    }

    private func export(_ source: VideoSource, _ path: CropPath, named name: String) async throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("verticalize-test-\(name).mp4")
        try await VideoExporter.export(source: source, path: path, to: out)
        return out
    }

    @Test("The fixture itself is oriented as expected")
    func fixtureOrientation() async throws {
        let (url, _) = try await fixture()
        let frame = try Frames.image(of: url, at: 1)
        #expect(Frames.sample(frame, x: 0.5, y: 0.03).isNear(.white))
        #expect(Frames.sample(frame, x: 0.5, y: 0.97).isNear(.black))
    }

    @Test("Loader reports the display geometry")
    func loaderGeometry() async throws {
        let (_, source) = try await fixture()
        #expect(source.displaySize == CGSize(width: 1280, height: 720))
        #expect(source.isLandscape)
        #expect(abs(source.duration - 4) < 0.2)
    }

    @Test("A static crop lands on exactly the source pixels it names")
    func staticCropGeometry() async throws {
        let (_, source) = try await fixture()
        let path = staticPath(source: source, centre: CGPoint(x: 0.25, y: 0.5))
        let out = try await export(source, path, named: "static")
        let frame = try Frames.image(of: out, at: 1)

        #expect(frame.width == 1080 && frame.height == 1920)

        // Crop spans x 117.5…522.5 of 1280. Bands are 160px wide, so the left
        // edge falls in band 0 (red) and the right edge in band 3 (green).
        #expect(Frames.sample(frame, x: 0.05, y: 0.5).isNear(.band(0)))
        #expect(Frames.sample(frame, x: 0.95, y: 0.5).isNear(.band(3)))
    }

    @Test("Vertical orientation survives the composition")
    func verticalOrientationPreserved() async throws {
        let (_, source) = try await fixture()
        let path = staticPath(source: source, centre: CGPoint(x: 0.25, y: 0.5))
        let out = try await export(source, path, named: "orientation")
        let frame = try Frames.image(of: out, at: 1)
        #expect(Frames.sample(frame, x: 0.5, y: 0.02).isNear(.white))
        #expect(Frames.sample(frame, x: 0.5, y: 0.98).isNear(.black))
    }

    @Test("A zoomed crop pinned to the top of frame stays there")
    func zoomedCropRespectsVerticalPosition() async throws {
        let (_, source) = try await fixture()
        var settings = FramingSettings.default
        settings.zoom = 2.0
        let cropSize = CropPathBuilder.cropSize(display: source.displaySize, settings: settings)
        let halfHeight = Double(cropSize.height / source.displaySize.height) / 2
        let path = staticPath(
            source: source, centre: CGPoint(x: 0.5, y: halfHeight), settings: settings
        )
        let out = try await export(source, path, named: "zoomed")
        let frame = try Frames.image(of: out, at: 1)
        #expect(Frames.sample(frame, x: 0.5, y: 0.02).isNear(.white))
        #expect(!Frames.sample(frame, x: 0.5, y: 0.98).isNear(.black),
                "pinned to the top, the crop should not reach the black stripe")
    }

    @Test("A moving crop lands where the path says, at every instant")
    func movingCropTracksThePath() async throws {
        let (_, source) = try await fixture()
        let centers = (0...120).map { i in
            CGPoint(x: 0.2 + 0.6 * (Double(i) / 120), y: 0.5)
        }
        let path = CropPath(
            rate: 30, centers: centers,
            cropSize: CropPathBuilder.cropSize(display: source.displaySize, settings: .default),
            displaySize: source.displaySize,
            renderSize: OutputAspect.nineSixteen.renderSize(),
            duration: source.duration
        )
        let out = try await export(source, path, named: "moving")

        // Keyframes are decimated before reaching the composition, so this also
        // checks the decimation stayed within tolerance.
        for step in 0...11 {
            let t = 0.15 + Double(step) * (3.7 / 11)
            let centre = Double(path.rect(at: t).midX / source.displaySize.width)
            let position = centre * 8
            // Skip instants that straddle a band boundary, where a rounding of
            // a pixel or two could legitimately land either side.
            let withinBand = position.truncatingRemainder(dividingBy: 1)
            guard withinBand > 0.12, withinBand < 0.88 else { continue }

            let expected = RGB.band(min(Int(position), 7))
            let actual = Frames.sample(try Frames.image(of: out, at: t), x: 0.5, y: 0.5)
            #expect(actual.isNear(expected),
                    "t=\(String(format: "%.2f", t)): expected \(expected), got \(actual)")
        }
    }

    @Test("Export preserves duration")
    func exportDuration() async throws {
        let (_, source) = try await fixture()
        let path = staticPath(source: source, centre: CGPoint(x: 0.5, y: 0.5))
        let out = try await export(source, path, named: "duration")
        let exported = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(exported - source.duration) < 0.2)
    }

    @Test("Every output aspect renders at its declared size", arguments: OutputAspect.allCases)
    func aspectRenderSizes(_ aspect: OutputAspect) async throws {
        let (_, source) = try await fixture()
        var settings = FramingSettings.default
        settings.aspect = aspect
        let path = staticPath(source: source, centre: CGPoint(x: 0.5, y: 0.5), settings: settings)
        let out = try await export(source, path, named: "aspect-\(aspect.rawValue.replacingOccurrences(of: ":", with: "-"))")
        let frame = try Frames.image(of: out, at: 1)
        #expect(frame.width == Int(aspect.renderSize().width))
        #expect(frame.height == Int(aspect.renderSize().height))
    }

    @Test("Scanning footage with no people finds nobody and does not crash")
    func scanWithoutPeople() async throws {
        let (_, source) = try await fixture()
        var lastFraction = 0.0
        let result = try await PersonScanner.scan(source: source) { progress in
            lastFraction = progress.fraction
        }
        #expect(result.people.isEmpty, "no false positives on colour bands")
        #expect(lastFraction > 0.9, "progress reached the end")
        #expect(result.diagnostics.decodedFrames > 0)
        #expect(result.diagnostics.emptyFrames == result.diagnostics.decodedFrames)
    }
}
