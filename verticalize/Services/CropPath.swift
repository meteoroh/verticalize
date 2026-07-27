//
//  CropPath.swift
//  verticalize
//
//  Turns a scattered list of sightings into the motion of a virtual camera:
//  interpolate, smooth, then drive it like an operator who only moves the rig
//  when the subject actually leaves the sweet spot.
//

import CoreGraphics
import Foundation

nonisolated struct CropPath: Sendable {
    /// Samples per second of the position track.
    let rate: Double
    /// Crop centres in normalized display space, top-left origin.
    let centers: [CGPoint]
    /// Crop window in display pixels. Constant for the whole clip.
    let cropSize: CGSize
    let displaySize: CGSize
    let renderSize: CGSize
    let duration: Double

    var normalizedCropSize: CGSize {
        CGSize(
            width: cropSize.width / displaySize.width,
            height: cropSize.height / displaySize.height
        )
    }

    func center(at time: Double) -> CGPoint {
        guard !centers.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let position = max(time, 0) * rate
        let lower = Int(position.rounded(.down))
        guard lower < centers.count - 1 else { return centers[centers.count - 1] }
        let t = position - Double(lower)
        let a = centers[lower], b = centers[lower + 1]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Crop window in display pixels, top-left origin.
    func rect(at time: Double) -> CGRect {
        rect(forCenter: center(at: time))
    }

    func rect(forCenter center: CGPoint) -> CGRect {
        CGRect(
            x: center.x * displaySize.width - cropSize.width / 2,
            y: center.y * displaySize.height - cropSize.height / 2,
            width: cropSize.width,
            height: cropSize.height
        )
    }

    /// Crop window normalized to the display frame — what the overlay draws.
    func normalizedRect(at time: Double) -> CGRect {
        let size = normalizedCropSize
        let center = center(at: time)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

nonisolated enum CropPathBuilder {

    /// Where in a person's bounding box the camera should aim. Faces read best
    /// slightly above centre, the way a human operator would frame a shot.
    private static let subjectAnchorY = 0.38
    /// Time constant of the virtual camera head, in seconds.
    private static let responseTime = 0.28

    static func build(
        sightings: [Sighting],
        source: VideoSource,
        settings: FramingSettings,
        renderHeight: Double = 1920
    ) -> CropPath {
        let display = source.displaySize
        let renderSize = settings.aspect.renderSize(maxHeight: renderHeight)
        let cropSize = cropSize(display: display, settings: settings)

        let rate = min(max(source.frameRate, 1), 30)
        let duration = max(source.duration, 1.0 / rate)
        let count = max(Int((duration * rate).rounded(.up)) + 1, 2)

        let halfW = cropSize.width / display.width / 2
        let halfH = cropSize.height / display.height / 2

        guard !sightings.isEmpty else {
            let centered = CGPoint(x: 0.5, y: 0.5)
            return CropPath(
                rate: rate,
                centers: Array(repeating: centered, count: count),
                cropSize: cropSize,
                displaySize: display,
                renderSize: renderSize,
                duration: duration
            )
        }

        // 1 — where the subject is, resampled onto a uniform grid.
        let times = sightings.map(\.time)
        let anchorsX = sightings.map { Double($0.box.midX) }
        let anchorsY = sightings.map {
            Double($0.box.minY) + Double($0.box.height) * subjectAnchorY
                + settings.verticalBias * Double(halfH)
        }
        var targetsX = resample(times: times, values: anchorsX, rate: rate, count: count)
        var targetsY = resample(times: times, values: anchorsY, rate: rate, count: count)

        // 2 — knock the detector's per-frame jitter off the target.
        let window = Int((settings.smoothing * rate).rounded())
        targetsX = smooth(targetsX, window: window)
        targetsY = smooth(targetsY, window: window)

        // 3 — drive the rig: hold still inside the deadzone, ease out of it,
        //     and never whip faster than a real pan.
        let deadzoneX = settings.deadzone * Double(cropSize.width / display.width)
        let deadzoneY = settings.deadzone * Double(cropSize.height / display.height)
        let xs = drive(targetsX, rate: rate, deadzone: deadzoneX,
                       maxSpeed: settings.maxPanSpeed,
                       low: Double(halfW), high: 1 - Double(halfW))
        let ys = drive(targetsY, rate: rate, deadzone: deadzoneY,
                       maxSpeed: settings.maxPanSpeed,
                       low: Double(halfH), high: 1 - Double(halfH))

        return CropPath(
            rate: rate,
            centers: zip(xs, ys).map { CGPoint(x: $0.0, y: $0.1) },
            cropSize: cropSize,
            displaySize: display,
            renderSize: renderSize,
            duration: duration
        )
    }

    /// The crop window, in display pixels, for the requested aspect and zoom.
    static func cropSize(display: CGSize, settings: FramingSettings) -> CGSize {
        var height = display.height / max(settings.zoom, 1)
        var width = height * settings.aspect.ratio
        if width > display.width {
            width = display.width
            height = width / settings.aspect.ratio
        }
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    // MARK: - Signal plumbing

    private static func resample(
        times: [Double], values: [Double], rate: Double, count: Int
    ) -> [Double] {
        guard let first = values.first, let last = values.last else {
            return Array(repeating: 0.5, count: count)
        }
        var out = [Double](repeating: first, count: count)
        var cursor = 0
        for i in 0..<count {
            let t = Double(i) / rate
            while cursor + 1 < times.count, times[cursor + 1] < t { cursor += 1 }
            if t <= times[0] {
                out[i] = first
            } else if t >= times[times.count - 1] {
                out[i] = last
            } else {
                let t0 = times[cursor], t1 = times[cursor + 1]
                let span = t1 - t0
                let u = span > 0 ? (t - t0) / span : 0
                out[i] = values[cursor] + (values[cursor + 1] - values[cursor]) * u
            }
        }
        return out
    }

    /// Centred triangular moving average — cheap, phase-free, no overshoot.
    private static func smooth(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 2 else { return values }
        let radius = max(window / 2, 1)
        var out = [Double](repeating: 0, count: values.count)
        for i in values.indices {
            var sum = 0.0
            var weightSum = 0.0
            for offset in -radius...radius {
                let j = min(max(i + offset, 0), values.count - 1)
                let weight = Double(radius + 1 - abs(offset))
                sum += values[j] * weight
                weightSum += weight
            }
            out[i] = sum / weightSum
        }
        return out
    }

    private static func drive(
        _ targets: [Double], rate: Double, deadzone: Double,
        maxSpeed: Double, low: Double, high: Double
    ) -> [Double] {
        guard !targets.isEmpty else { return targets }
        // A crop wider than the source can't move; park it in the middle.
        guard low <= high else { return targets.map { _ in 0.5 } }

        let dt = 1 / rate
        let alpha = 1 - exp(-dt / responseTime)
        let maxStep = maxSpeed * dt

        var position = min(max(targets[0], low), high)
        var out = [Double](repeating: position, count: targets.count)
        for i in targets.indices {
            let error = targets[i] - position
            if abs(error) > deadzone {
                let slack = error > 0 ? error - deadzone : error + deadzone
                let step = min(max(slack * alpha, -maxStep), maxStep)
                position += step
            }
            position = min(max(position, low), high)
            out[i] = position
        }
        return out
    }
}
