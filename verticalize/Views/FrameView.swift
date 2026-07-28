//
//  FrameView.swift
//  verticalize
//

import AVFoundation
import SwiftUI

struct FrameView: View {
    @Bindable var model: AppModel
    @State private var isExportPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previews
                Divider()
                inspector
            }
            Divider()
            transport
        }
        .sheet(isPresented: $isExportPresented) {
            ExportSheet(model: model)
        }
    }

    // MARK: - Previews

    private var previews: some View {
        HStack(spacing: 18) {
            if let source = model.source {
                VStack(spacing: 8) {
                    paneTitle("Source", source.resolutionLabel)
                    PlayerLayerView(player: model.sourcePlayer)
                        .aspectRatio(source.displaySize, contentMode: .fit)
                        .overlay {
                            if let path = model.path {
                                CropOverlay(
                                    cropRect: path.normalizedRect(at: model.currentTime),
                                    subjectRect: model.selectedPerson?
                                        .sighting(nearest: model.currentTime)?.box,
                                    otherTracks: model.showsTrackOverlay ? otherTracks : []
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 8) {
                    paneTitle("Vertical", renderLabel)
                    PlayerLayerView(player: model.player)
                        .aspectRatio(model.settings.aspect.ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: 340)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Everyone the scanner found except the subject, at the current instant.
    private var otherTracks: [(label: String, rect: CGRect)] {
        model.candidates.compactMap { candidate in
            guard candidate.id != model.selectedPersonID,
                  let sighting = candidate.sighting(nearest: model.currentTime)
            else { return nil }
            return (candidate.label, sighting.box)
        }
    }

    private func paneTitle(_ title: String, _ detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private var renderLabel: String {
        let size = model.path?.renderSize ?? model.settings.aspect.renderSize()
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let person = model.selectedPerson {
                    subjectSection(person)
                }

                section("Output") {
                    Picker("", selection: $model.settings.aspect) {
                        ForEach(OutputAspect.allCases) { aspect in
                            Text(aspect.rawValue).tag(aspect)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(model.settings.aspect.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                section("Camera") {
                    LabeledSlider(
                        title: "Smoothing",
                        caption: "Higher glides through quick movements.",
                        value: $model.settings.smoothing,
                        range: 0.1...3.0
                    ) { String(format: "%.1fs", $0) }

                    LabeledSlider(
                        title: "Deadzone",
                        caption: "How far the subject drifts before the camera moves.",
                        value: $model.settings.deadzone,
                        range: 0.0...0.35
                    ) { String(format: "%.0f%%", $0 * 100) }

                    LabeledSlider(
                        title: "Pan speed",
                        caption: "Caps how fast the frame can travel.",
                        value: $model.settings.maxPanSpeed,
                        range: 0.1...2.0
                    ) { String(format: "%.2f×", $0) }
                }

                section("Framing") {
                    LabeledSlider(
                        title: "Zoom",
                        caption: "1.0× keeps the full source height.",
                        value: $model.settings.zoom,
                        range: 1.0...2.5
                    ) { String(format: "%.2f×", $0) }

                    LabeledSlider(
                        title: "Vertical bias",
                        caption: "Nudges the subject up or down in frame.",
                        value: $model.settings.verticalBias,
                        range: -1.0...1.0
                    ) { String(format: "%+.2f", $0) }
                    .disabled(model.settings.zoom <= 1.001)
                    .opacity(model.settings.zoom <= 1.001 ? 0.45 : 1)
                }

                section("Diagnostics") {
                    Toggle("Show all tracks", isOn: $model.showsTrackOverlay)
                        .controlSize(.small)
                    Text("Outlines everyone the scan found, so you can see who "
                         + "the camera is following and when it changes its mind.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Button("Reset to Defaults") {
                    model.settings = .default
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .frame(width: 264)
        .background(.background.secondary)
    }

    private func subjectSection(_ person: PersonCandidate) -> some View {
        section("Subject") {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    if let thumbnail = person.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 44, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.label).font(.system(size: 12, weight: .semibold))
                    Text(person.screenTimeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("Change") { model.stage = .cast }
                        .controlSize(.mini)
                        .buttonStyle(.link)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])

            Text(VideoSource.timecode(model.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Scrubber(
                value: model.currentTime,
                duration: model.source?.duration ?? 0,
                markers: markers
            ) { model.seek(to: $0) }

            Text(VideoSource.timecode(model.source?.duration ?? 0))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .leading)

            Button {
                isExportPresented = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.path == nil)
            .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    /// Tick marks where the subject enters or leaves frame.
    private var markers: [Double] {
        guard let person = model.selectedPerson else { return [] }
        var result: [Double] = []
        var previous: Double?
        for sighting in person.sightings {
            if let previous, sighting.time - previous > 1.0 {
                result.append(sighting.time)
            }
            previous = sighting.time
        }
        return result
    }
}
