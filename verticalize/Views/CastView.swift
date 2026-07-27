//
//  CastView.swift
//  verticalize
//

import SwiftUI

struct CastView: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.candidates) { candidate in
                        PersonCard(
                            candidate: candidate,
                            isSelected: candidate.id == model.selectedPersonID
                        )
                        .onTapGesture { model.selectedPersonID = candidate.id }
                        .onTapGesture(count: 2) { model.choose(candidate) }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Rescan") { model.stage = .scan; model.startScan() }
                Spacer()
                if let person = model.selectedPerson {
                    Text("Tracking \(person.label)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button("Track & Preview") {
                    if let person = model.selectedPerson { model.choose(person) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedPerson == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Who should the camera follow?")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(model.candidates.count) \(model.candidates.count == 1 ? "person" : "people") found in this clip")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

private struct PersonCard: View {
    let candidate: PersonCandidate
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                if let thumbnail = candidate.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 150)
            .clipped()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(candidate.label)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 13))
                    }
                }

                PresenceBar(
                    sightings: candidate.sightings, duration: candidate.clipDuration
                )

                HStack(spacing: 6) {
                    Text(candidate.screenTimeLabel)
                    Text("·")
                    Text("\(Int(candidate.coverage * 100))% of clip")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(isSelected ? 0.14 : 0.06))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .animation(.snappy(duration: 0.18), value: isSelected)
    }
}
