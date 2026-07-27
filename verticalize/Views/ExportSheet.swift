//
//  ExportSheet.swift
//  verticalize
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var useHEVC = false

    private var settings: VideoExporter.Settings {
        useHEVC ? .hevc : .h264
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export vertical video")
                .font(.system(size: 16, weight: .semibold))

            summary

            Picker("Codec", selection: $useHEVC) {
                Text("H.264 — plays everywhere").tag(false)
                Text("HEVC — smaller file").tag(true)
            }
            .pickerStyle(.radioGroup)
            .disabled(model.isExporting)

            if model.isExporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.exportProgress)
                    Text("Rendering… \(Int(model.exportProgress * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if let url = model.lastExportURL {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved to \(url.lastPathComponent)")
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.1)))
            }

            HStack {
                if model.isExporting {
                    Button("Cancel Export", role: .cancel) { model.cancelExport() }
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(model.lastExportURL == nil ? "Export…" : "Export Again…") {
                    presentSavePanel()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isExporting)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var summary: some View {
        let size = model.path?.renderSize ?? model.settings.aspect.renderSize()
        return VStack(alignment: .leading, spacing: 6) {
            row("Subject", model.selectedPerson?.label ?? "—")
            row("Aspect", model.settings.aspect.rawValue)
            row("Resolution", "\(Int(size.width)) × \(Int(size.height))")
            row("Duration", VideoSource.timecode(model.source?.duration ?? 0))
            row("Audio", (model.source?.hasAudio ?? false) ? "Included" : "None in source")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Export Vertical Video"
        panel.nameFieldStringValue =
            "\(model.suggestedExportName).\(settings.fileExtension)"
        panel.allowedContentTypes = [settings.fileType == .mov ? .quickTimeMovie : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let exportSettings = settings
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                model.export(to: url, settings: exportSettings)
            }
        }
    }
}
