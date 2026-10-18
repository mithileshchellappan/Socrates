import AVFoundation
import Capture
import CaptureUI
import Foundation
import Observation
import StudyCore
import SwiftUI

/// Plays one sentence of a lecture (the professor's quote under a practice question: Space):
/// an `AVAudioPlayer` over the recording's segment file that holds `start`, stopped at `end`.
/// No Review dependency and no shared clock: the practice screen only needs a few seconds.
@MainActor
@Observable
final class SentencePlayer {
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopper: Task<Void, Never>?

    /// Plays `recordingID` from `start` to `end` (or 12 s on); a second call while playing stops.
    func play(recordingID: Recording.ID, from start: Double, to end: Double?, services: StudyServices) {
        if isPlaying {
            stop()
            return
        }
        let blobs = services.blobs
        let records = services.records
        stopper = Task { [weak self] in
            do {
                let recording = try await records.fetch(Recording.self, id: recordingID)
                let segments = try await RecordingRepository(store: records).segments(recordingID: recordingID)
                let rate = (recording?.sampleRate ?? 0) > 0 ? recording?.sampleRate ?? 48_000 : 48_000
                guard let segment = segments.last(where: { Double($0.startSample) / rate <= start }) ?? segments.first,
                      let blob = segment.blob
                else { return }
                let offset = max(0, start - Double(segment.startSample) / rate)
                let length = max(1, min(30, (end ?? start + 12) - start))
                try self?.start(url: blobs.url(for: blob), at: offset, for: length)
            } catch {
                CoachUILog.ui.error("Sentence playback failed: \(error.localizedDescription, privacy: .public)")
                self?.stop()
            }
        }
    }

    func stop() {
        stopper?.cancel()
        stopper = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func start(url: URL, at offset: Double, for length: Double) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.currentTime = min(offset, max(0, player.duration - 0.1))
        player.prepareToPlay()
        guard player.play() else { return }
        self.player = player
        isPlaying = true
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 0.3))
            guard !Task.isCancelled else { return }
            self?.player?.stop()
            self?.player = nil
            self?.isPlaying = false
        }
    }
}

/// Opens a deck's PDF off the main actor (opening reads every page box).
enum SlideDeckOpener {
    @concurrent
    static func open(_ deck: Deck, services: StudyServices) async -> SlideDeck? {
        guard let blob = deck.blob else { return nil }
        return try? SlideDeck(
            url: services.blobs.url(for: blob),
            sha256: deck.blobSHA256,
            cacheDirectory: services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory),
            memoryBudgetBytes: 8 << 20
        )
    }
}

/// The slide a question shows (`SlideImageView`), its deck opened on demand; a blank white card
/// of the slide's shape until it is ready.
struct QuestionSlide: View {
    let deck: Deck
    let page: Int

    @Environment(\.studyServices) private var services
    @State private var opened: SlideDeck?

    var body: some View {
        Group {
            if let opened {
                SlideImageView(deck: opened, page: page, pixelWidth: SlideWidth.thumbnail * 2, cornerRadius: 6)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.black.opacity(0.1), lineWidth: 0.5)
                    }
            }
        }
        // The slide's one exception to "no hand-drawn shadows" (DESIGN §3.4).
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .task(id: deck.id) {
            guard let services, opened?.sha256 != deck.blobSHA256 else { return }
            opened = await SlideDeckOpener.open(deck, services: services)
        }
    }
}
