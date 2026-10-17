import AVFoundation
import Foundation
import Observation
import StudyCore

/// The one playback clock of a lecture review: an `AVPlayer` over the recording's segment files
/// (`LectureComposition`), so second N of the player is second N of the recording clock.
///
/// Publishes `time` about ten times a second while playing (for the scrubber and time label),
/// but `currentSegmentID` and `currentPage` only when they change, so the transcript, rail and
/// slide redraw only when the line or slide does. Without audio (no segment file yet) it is
/// still a clock: seeks move `time`, nothing plays.
@MainActor
@Observable
public final class LecturePlayer {
    /// A transcript line on the clock, for `currentSegmentID`.
    public struct Cue: Sendable, Hashable {
        public var id: UUID
        public var start: Double
        public var end: Double

        public init(id: UUID, start: Double, end: Double) {
            self.id = id
            self.start = start
            self.end = end
        }

        public init(_ segment: TranscriptSegment) {
            self.init(id: segment.id, start: segment.startTime, end: segment.endTime)
        }
    }

    /// Speeds offered in the speed menu.
    public static let rates: [Float] = [1, 1.25, 1.5, 2]
    /// Back / forward step.
    public static let skipInterval: Double = 15
    /// How often `time` is published while playing.
    public static let tickInterval: Duration = .milliseconds(100)

    /// Seconds on the recording clock.
    public private(set) var time: Double = 0
    public private(set) var duration: Double
    public private(set) var isPlaying = false
    /// The chosen speed (kept while paused).
    public private(set) var rate: Float = 1
    /// The transcript line at the playhead (the last one starting at or before it).
    public private(set) var currentSegmentID: UUID?
    /// The slide to show at the playhead (`SlideTimeline.displayPage`).
    public private(set) var currentPage: Int?
    /// True once segment audio is loaded and can play.
    public private(set) var hasAudio = false

    /// Called on main with the playhead after every tick and seek (review state, autosave).
    @ObservationIgnored public var onTick: ((Double) -> Void)?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var cues: [Cue] = []
    @ObservationIgnored private var cueStarts: [Double] = []
    @ObservationIgnored private var timeline: SlideTimeline = .empty
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var seeksInFlight = 0

    public init(duration: Double) {
        self.duration = max(0, duration)
    }

    // MARK: - Loading

    /// Loads the recording's files onto the clock. Playback starts paused at the current time.
    public func load(_ sources: [PlaybackSource]) async throws {
        guard !sources.isEmpty else { return }
        let composition = try await LectureComposition.make(sources)
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.defaultRate = rate
        player.isMuted = isMuted
        self.player = player
        hasAudio = true
        if time > 0 {
            await seekPlayer(to: time)
        }
    }

    /// Mutes output (tests, previews).
    public var isMuted = false {
        didSet { player?.isMuted = isMuted }
    }

    // MARK: - What the clock points at

    /// The transcript lines (any order).
    public func setCues(_ cues: [Cue]) {
        self.cues = cues.sorted { $0.start < $1.start }
        cueStarts = self.cues.map(\.start)
        updateCursor()
    }

    /// The slide timeline (after alignment or a manual anchor).
    public func setTimeline(_ timeline: SlideTimeline) {
        self.timeline = timeline
        updateCursor()
    }

    public func setDuration(_ duration: Double) {
        guard duration > 0, duration != self.duration else { return }
        self.duration = duration
    }

    // MARK: - Transport

    public func play() {
        guard let player, !isPlaying else { return }
        #if os(iOS)
        activateAudioSession()
        #endif
        if duration > 0, time >= duration - 0.05 {
            Task { await seek(to: 0); self.play() }
            return
        }
        player.defaultRate = rate
        player.play()
        isPlaying = true
        startTicker()
    }

    public func pause() {
        guard isPlaying || player?.rate != 0 else { return }
        player?.pause()
        isPlaying = false
        stopTicker()
        if let player, seeksInFlight == 0 { setTime(player.currentTime().seconds) }
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Moves the playhead. `time` (and the line and slide at it) update at once; the audio
    /// follows when the seek lands.
    public func seek(to seconds: Double) async {
        let target = clamped(seconds)
        setTime(target)
        await seekPlayer(to: target)
    }

    /// ±15 s (or any step) from the playhead.
    public func skip(by delta: Double) {
        let target = clamped(time + delta)
        Task { await seek(to: target) }
    }

    public func setRate(_ rate: Float) {
        guard rate > 0 else { return }
        self.rate = rate
        player?.defaultRate = rate
        if isPlaying { player?.rate = rate }
    }

    /// The next speed in `rates` (wrapping).
    public func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        setRate(Self.rates[(index + 1) % Self.rates.count])
    }

    /// Where the audio itself is (the AVPlayer's own clock); nil without audio.
    var audioPosition: Double? {
        player?.currentTime().seconds
    }

    // MARK: - Private

    private func seekPlayer(to target: Double) async {
        guard let player else { return }
        seeksInFlight += 1
        let time = CMTime(seconds: target, preferredTimescale: 48_000)
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                continuation.resume(returning: finished)
            }
        }
        seeksInFlight -= 1
        if seeksInFlight == 0, isPlaying {
            setTime(player.currentTime().seconds)
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        if seeksInFlight == 0 {
            setTime(player.currentTime().seconds)
        }
        // Reached the end (`actionAtItemEnd = .pause`), or the system paused us (route change,
        // interruption). A player still waiting for its item to be ready keeps its rate.
        if player.rate == 0, seeksInFlight == 0 {
            isPlaying = false
            stopTicker()
        }
    }

    private func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
    }

    private func setTime(_ seconds: Double) {
        let value = clamped(seconds)
        if value != time { time = value }
        updateCursor()
        onTick?(value)
    }

    /// Republishes the line and slide only when they change.
    private func updateCursor() {
        let segment = cueIndex(at: time).map { cues[$0].id }
        if segment != currentSegmentID { currentSegmentID = segment }
        let page = timeline.displayPage(at: time)
        if page != currentPage { currentPage = page }
    }

    private func cueIndex(at time: Double) -> Int? {
        guard let first = cueStarts.first, time >= first else { return nil }
        var low = 0
        var high = cueStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if cueStarts[middle] <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    #if os(iOS)
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            ReviewLog.logger.error("Audio session: \(String(describing: error), privacy: .public)")
        }
    }
    #endif
}
