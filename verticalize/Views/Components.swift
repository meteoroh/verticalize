//
//  Components.swift
//  verticalize
//

import SwiftUI

// MARK: - Stage bar

struct StageBar: View {
    let current: AppModel.Stage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(AppModel.Stage.allCases.enumerated()), id: \.element.id) { index, stage in
                if index > 0 {
                    Rectangle()
                        .fill(stage.rawValue <= current.rawValue
                              ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25))
                        .frame(width: 22, height: 1.5)
                }
                stagePill(stage)
            }
        }
        .animation(.snappy(duration: 0.25), value: current)
    }

    @ViewBuilder
    private func stagePill(_ stage: AppModel.Stage) -> some View {
        let done = stage.rawValue < current.rawValue
        let active = stage == current
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark" : stage.symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 12)
            Text(stage.title)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(active ? Color.accentColor : (done ? .secondary : Color.secondary.opacity(0.6)))
        .background {
            Capsule().fill(active ? Color.accentColor.opacity(0.14) : .clear)
        }
    }
}

// MARK: - Presence bar

/// Where in the clip a person is on screen.
struct PresenceBar: View {
    let sightings: [Sighting]
    let duration: Double
    var height: Double = 5
    var bucketCount: Int = 90

    private var buckets: [Bool] {
        guard duration > 0 else { return [] }
        var filled = [Bool](repeating: false, count: bucketCount)
        for sighting in sightings {
            let index = Int((sighting.time / duration) * Double(bucketCount))
            if index >= 0, index < bucketCount { filled[index] = true }
        }
        return filled
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width / Double(bucketCount)
            HStack(spacing: 0) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, on in
                    Rectangle()
                        .fill(on ? Color.accentColor : Color.secondary.opacity(0.18))
                        .frame(width: width)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

// MARK: - Crop overlay

/// Dims everything outside the crop window and outlines the subject.
struct CropOverlay: View {
    /// Normalized to the display frame, top-left origin.
    let cropRect: CGRect
    let subjectRect: CGRect?
    /// Every other tracked person, for diagnosing who the camera is following.
    var otherTracks: [(label: String, rect: CGRect)] = []

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let crop = scaled(cropRect, in: size)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .reverseMask {
                        Rectangle()
                            .frame(width: crop.width, height: crop.height)
                            .position(x: crop.midX, y: crop.midY)
                    }

                ForEach(Array(otherTracks.enumerated()), id: \.offset) { _, track in
                    let box = scaled(track.rect, in: size)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.orange.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .overlay(alignment: .topLeading) {
                            Text(track.label)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.orange))
                                .foregroundStyle(.black)
                                .position(x: box.minX + 20, y: box.minY - 7)
                        }
                }

                if let subjectRect {
                    let subject = scaled(subjectRect, in: size)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.white.opacity(0.75), lineWidth: 1.5)
                        .frame(width: subject.width, height: subject.height)
                        .position(x: subject.midX, y: subject.midY)
                }

                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
            }
            .animation(nil, value: cropRect)
        }
        .allowsHitTesting(false)
    }

    private func scaled(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }
}

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

// MARK: - Scrubber

struct Scrubber: View {
    let value: Double
    let duration: Double
    var markers: [Double] = []
    let onScrub: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = duration > 0 ? min(max(value / duration, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))

                ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 1.5)
                        .offset(x: duration > 0 ? (marker / duration) * width : 0)
                }

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: progress * width)

                Circle()
                    .fill(.white)
                    .shadow(radius: 1.5, y: 0.5)
                    .frame(width: isDragging ? 14 : 11)
                    .offset(x: progress * width - (isDragging ? 7 : 5.5))
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let fraction = min(max(drag.location.x / width, 0), 1)
                        onScrub(fraction * duration)
                    }
                    .onEnded { _ in isDragging = false }
            )
            .animation(.snappy(duration: 0.15), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Small pieces

struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

struct LabeledSlider: View {
    let title: String
    let caption: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
