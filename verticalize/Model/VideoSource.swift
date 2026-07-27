//
//  VideoSource.swift
//  verticalize
//

import AVFoundation
import CoreGraphics
import Foundation

/// Everything we need to know about an imported clip, resolved up front so the
/// rest of the app never has to `await` basic geometry questions.
nonisolated struct VideoSource: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    /// Size of the encoded frames, before the track's preferred transform.
    let naturalSize: CGSize
    /// Maps natural coordinates into display coordinates (handles rotated clips).
    let preferredTransform: CGAffineTransform
    let duration: Double
    let frameRate: Double
    let hasAudio: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        duration: Double,
        frameRate: Double,
        hasAudio: Bool
    ) {
        self.id = id
        self.url = url
        self.naturalSize = naturalSize
        self.preferredTransform = preferredTransform
        self.duration = duration
        self.frameRate = frameRate
        self.hasAudio = hasAudio
    }

    /// Size the viewer actually sees, i.e. natural size with rotation applied.
    var displaySize: CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
    }

    var filename: String { url.lastPathComponent }

    var isLandscape: Bool { displaySize.width > displaySize.height }

    var formattedDuration: String { Self.timecode(duration) }

    var resolutionLabel: String {
        let s = displaySize
        return "\(Int(s.width)) × \(Int(s.height))"
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

nonisolated enum VideoLoader {
    enum LoadError: LocalizedError {
        case noVideoTrack
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "That file doesn't contain a video track."
            case .unreadable: "That file couldn't be read as a video."
            }
        }
    }

    static func load(url: URL) async throws -> VideoSource {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard try await asset.load(.isReadable) else { throw LoadError.unreadable }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LoadError.noVideoTrack
        }
        let (naturalSize, transform, nominalRate) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        return VideoSource(
            url: url,
            naturalSize: naturalSize,
            preferredTransform: transform,
            duration: max(duration.seconds, 0),
            frameRate: nominalRate > 0 ? Double(nominalRate) : 30,
            hasAudio: !audioTracks.isEmpty
        )
    }
}
