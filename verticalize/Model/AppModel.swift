//
//  AppModel.swift
//  verticalize
//

import AppKit
import AVFoundation
import Observation
import SwiftUI

@Observable
final class AppModel {

    enum Stage: Int, CaseIterable, Identifiable {
        case importVideo, scan, cast, frame

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .importVideo: "Import"
            case .scan: "Scan"
            case .cast: "Cast"
            case .frame: "Frame"
            }
        }
        var symbol: String {
            switch self {
            case .importVideo: "square.and.arrow.down"
            case .scan: "person.crop.rectangle.badge.magnifyingglass"
            case .cast: "person.2"
            case .frame: "rectangle.portrait.and.arrow.right"
            }
        }
    }

    // MARK: - State

    var stage: Stage = .importVideo
    private(set) var source: VideoSource?

    private(set) var isScanning = false
    private(set) var scanProgress: Double = 0
    private(set) var scanPeopleFound = 0
    private(set) var scanTime: Double = 0
    private(set) var candidates: [PersonCandidate] = []
    private(set) var diagnostics: ScanDiagnostics?
    /// Draws every tracked person over the source, not just the subject.
    var showsTrackOverlay = false

    var selectedPersonID: UUID? {
        didSet { if selectedPersonID != oldValue { rebuildPath(immediately: true) } }
    }

    var settings = FramingSettings.default {
        didSet { if settings != oldValue { rebuildPath() } }
    }

    private(set) var path: CropPath?
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    /// Preview volume. Export is unaffected — the source audio is copied
    /// through at its original level.
    var volume: Double = 1.0 {
        didSet { player.volume = Float(min(max(volume, 0), 1)) }
    }
    var isMuted = false {
        didSet { player.isMuted = isMuted }
    }
    /// Preview playback rate. Also preview-only: the export always renders at
    /// the source's own timing.
    var playbackRate: Double = 1.0 {
        didSet { if isPlaying { applyRate() } }
    }

    static let playbackRates: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0]

    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0
    private(set) var lastExportURL: URL?

    var errorMessage: String?

    // MARK: - Playback

    /// Renders the 9:16 result.
    let player = AVPlayer()
    /// Renders the untouched landscape frame, for the crop overlay.
    let sourcePlayer = AVPlayer()

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var scanTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var scopedURL: URL?
    private var lastDriftCorrection: Double = 0

    var selectedPerson: PersonCandidate? {
        candidates.first { $0.id == selectedPersonID }
    }

    var canGoBack: Bool { stage != .importVideo && !isScanning && !isExporting }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Import

    func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            open(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func open(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        Task {
            do {
                let loaded = try await VideoLoader.load(url: url)
                reset()
                if accessed {
                    scopedURL = url
                }
                source = loaded
                preparePlayers(for: loaded)
                stage = .scan
                startScan()
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                errorMessage = error.localizedDescription
            }
        }
    }

    func reset() {
        scanTask?.cancel()
        rebuildTask?.cancel()
        exportTask?.cancel()
        pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        sourcePlayer.replaceCurrentItem(with: nil)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        source = nil
        candidates = []
        diagnostics = nil
        selectedPersonID = nil
        path = nil
        currentTime = 0
        scanProgress = 0
        scanPeopleFound = 0
        scanTime = 0
        isScanning = false
        isExporting = false
        exportProgress = 0
        lastExportURL = nil
        settings = .default
        playbackRate = 1.0
        stage = .importVideo
    }

    private func preparePlayers(for source: VideoSource) {
        let asset = AVURLAsset(url: source.url)
        let item = AVPlayerItem(asset: asset)
        // Keeps voices intelligible at 0.5x and 2x instead of chipmunking them.
        item.audioTimePitchAlgorithm = .spectral
        playerItem = item
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        player.volume = Float(volume)
        player.isMuted = isMuted
        sourcePlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        sourcePlayer.actionAtItemEnd = .pause
        sourcePlayer.isMuted = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func tick(_ time: CMTime) {
        currentTime = max(time.seconds, 0)
        isPlaying = player.rate != 0
        guard isPlaying else { return }
        // Two players decoding the same file drift a little; nudge occasionally.
        let drift = sourcePlayer.currentTime().seconds - currentTime
        if abs(drift) > 0.15, currentTime - lastDriftCorrection > 1.5 {
            lastDriftCorrection = currentTime
            sourcePlayer.seek(
                to: time,
                toleranceBefore: CMTime(value: 1, timescale: 30),
                toleranceAfter: CMTime(value: 1, timescale: 30)
            )
        }
    }

    // MARK: - Scan

    func startScan() {
        guard let source else { return }
        scanTask?.cancel()
        isScanning = true
        scanProgress = 0
        scanPeopleFound = 0
        scanTime = 0
        candidates = []
        diagnostics = nil

        scanTask = Task { [weak self] in
            do {
                let found = try await PersonScanner.scan(source: source) { progress in
                    Task { @MainActor [weak self] in
                        self?.scanProgress = progress.fraction
                        self?.scanPeopleFound = progress.peopleFound
                        self?.scanTime = progress.currentTime
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.candidates = found.people
                self.diagnostics = found.diagnostics
                self.isScanning = false
                self.scanProgress = 1
                self.stage = .cast
                if let first = found.people.first {
                    self.selectedPersonID = first.id
                }
            } catch is CancellationError {
                self?.isScanning = false
            } catch {
                guard let self else { return }
                self.isScanning = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Framing

    func choose(_ candidate: PersonCandidate) {
        selectedPersonID = candidate.id
        stage = .frame
    }

    private func rebuildPath(immediately: Bool = false) {
        guard let source, let person = selectedPerson else { return }
        rebuildTask?.cancel()
        let settings = settings
        rebuildTask = Task { [weak self] in
            if !immediately {
                // Let slider drags settle before recomputing.
                try? await Task.sleep(for: .milliseconds(90))
                if Task.isCancelled { return }
            }
            let sightings = person.sightings
            let built = await Task.detached(priority: .userInitiated) {
                CropPathBuilder.build(
                    sightings: sightings, source: source, settings: settings
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            self.path = built
            await self.applyComposition(built, source: source)
        }
    }

    private func applyComposition(_ path: CropPath, source: VideoSource) async {
        guard let item = playerItem else { return }
        let asset = item.asset
        guard let composition = try? await VerticalComposition.make(
            asset: asset, source: source, path: path
        ) else { return }
        guard !Task.isCancelled else { return }
        item.videoComposition = composition
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard source != nil else { return }
        if let duration = source?.duration, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        sourcePlayer.seek(
            to: player.currentTime(),
            toleranceBefore: CMTime(value: 1, timescale: 30),
            toleranceAfter: CMTime(value: 1, timescale: 30)
        )
        applyRate()
        isPlaying = true
    }

    func pause() {
        player.pause()
        sourcePlayer.pause()
        isPlaying = false
    }

    /// Setting `rate` is what starts playback at a speed; `play()` would reset
    /// it to 1. Both players move together so the two panes stay in step.
    private func applyRate() {
        let rate = Float(playbackRate)
        player.rate = rate
        sourcePlayer.rate = rate
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        currentTime = max(seconds, 0)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        sourcePlayer.seek(
            to: time,
            toleranceBefore: CMTime(value: 1, timescale: 30),
            toleranceAfter: CMTime(value: 1, timescale: 30)
        )
    }

    func step(by seconds: Double) {
        guard let source else { return }
        seek(to: min(max(currentTime + seconds, 0), source.duration))
    }

    // MARK: - Export

    func export(to url: URL, settings exportSettings: VideoExporter.Settings) {
        guard let source, let path else { return }
        pause()
        exportTask?.cancel()
        isExporting = true
        exportProgress = 0
        lastExportURL = nil

        exportTask = Task { [weak self] in
            do {
                try await VideoExporter.export(
                    source: source, path: path, to: url, settings: exportSettings
                ) { fraction in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = fraction
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.isExporting = false
                self.exportProgress = 1
                self.lastExportURL = url
            } catch is CancellationError {
                self?.isExporting = false
            } catch {
                guard let self else { return }
                self.isExporting = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
    }

    var suggestedExportName: String {
        guard let source else { return "verticalize.mp4" }
        let base = source.url.deletingPathExtension().lastPathComponent
        return "\(base) — vertical"
    }

    // MARK: - Navigation

    /// Paste-ready scan summary, for tuning against real footage.
    var diagnosticsReport: String? {
        diagnostics?.report(people: candidates)
    }

    func copyDiagnosticsToPasteboard() {
        guard let report = diagnosticsReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func goBack() {
        switch stage {
        case .importVideo: break
        case .scan: reset()
        case .cast: stage = .scan
        case .frame: stage = .cast
        }
    }
}
