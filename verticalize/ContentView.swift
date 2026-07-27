//
//  ContentView.swift
//  verticalize
//

import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            Group {
                switch model.stage {
                case .importVideo: ImportView(model: model)
                case .scan: ScanView(model: model)
                case .cast: CastView(model: model)
                case .frame: FrameView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 640)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoBack)
            .opacity(model.canGoBack ? 1 : 0.3)

            HStack(spacing: 7) {
                Image(systemName: "rectangle.portrait.rotate")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Verticalize")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }

            if let source = model.source {
                Text(source.filename)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)
            }

            Spacer()

            StageBar(current: model.stage)

            Spacer()

            Button("New") { model.reset() }
                .controlSize(.small)
                .disabled(model.source == nil || model.isExporting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.background.secondary)
    }
}

#Preview {
    ContentView()
}
