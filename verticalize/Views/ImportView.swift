//
//  ImportView.swift
//  verticalize
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Bindable var model: AppModel
    @State private var isPickerPresented = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            VStack(spacing: 10) {
                Text("Verticalize")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Turn a landscape clip into a vertical one that follows a person.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            dropZone

            HStack(spacing: 22) {
                step(1, "Import", "square.and.arrow.down")
                step(2, "Scan for people", "person.crop.rectangle.badge.magnifyingglass")
                step(3, "Pick your subject", "person.2")
                step(4, "Preview & export", "square.and.arrow.up")
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            model.handlePickedFile(result)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 4) {
                Text("Drop a video here")
                    .font(.system(size: 15, weight: .medium))
                Text("MP4, MOV, M4V — landscape works best")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button("Choose Video…") { isPickerPresented = true }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: 460)
        .padding(.vertical, 44)
        .padding(.horizontal, 40)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(isTargeted ? 0.08 : 0.02))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
        }
        .animation(.snappy(duration: 0.2), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func step(_ number: Int, _ title: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}
