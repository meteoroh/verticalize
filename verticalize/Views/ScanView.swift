//
//  ScanView.swift
//  verticalize
//

import SwiftUI

struct ScanView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(model.scanProgress, 0.01))
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: model.scanProgress)

                VStack(spacing: 2) {
                    Text("\(Int(model.scanProgress * 100))%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(VideoSource.timecode(model.scanTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)

            VStack(spacing: 6) {
                Text(model.isScanning ? "Scanning for people…" : "Scan complete")
                    .font(.system(size: 16, weight: .medium))
                Text(peopleLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.scanPeopleFound)
            }

            if let source = model.source {
                HStack(spacing: 8) {
                    MetaChip(symbol: "film", text: source.filename)
                    MetaChip(symbol: "aspectratio", text: source.resolutionLabel)
                    MetaChip(symbol: "clock", text: source.formattedDuration)
                }
            }

            if model.isScanning {
                Button("Cancel", role: .cancel) { model.cancelScan() }
                    .controlSize(.regular)
            } else if !model.isScanning && model.candidates.isEmpty {
                VStack(spacing: 10) {
                    Text("No people were found in this clip.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Scan Again") { model.startScan() }
                        Button("Choose Another Video") { model.reset() }
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var peopleLabel: String {
        switch model.scanPeopleFound {
        case 0: "No one spotted yet"
        case 1: "1 person so far"
        default: "\(model.scanPeopleFound) people so far"
        }
    }
}
