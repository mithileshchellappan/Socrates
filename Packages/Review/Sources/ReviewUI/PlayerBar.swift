import Review
import StudyCore
import StudyUI
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The floating glass player: back 15, play/pause, forward 15, "37:27 / 1:08:13", the scrubber
/// with slide ticks and flag, exam hint and said-in-class (else off-slide) marks, the speed menu
/// and Follow.
///
/// The bar itself reads nothing that changes while playing; the time label and the scrubber
/// read the clock in their own views.
struct PlayerBar: View {
    let model: ReviewModel
    let player: LecturePlayer
    let timeline: SlideTimeline

    static let height: CGFloat = 44

    private let flagsQuery: FetchAll<SlideEvent>
    private var flags: [SlideEvent] { flagsQuery.wrappedValue }
    /// Exam hints and said-in-class items (M4).
    private let annotationsQuery: FetchAll<Annotation>

    init(model: ReviewModel, player: LecturePlayer, timeline: SlideTimeline) {
        self.model = model
        self.player = player
        self.timeline = timeline
        let recordingID = model.recording?.id ?? UUID()
        flagsQuery = FetchAll(
            SlideEvent.where { $0.recordingID.eq(recordingID) && $0.kind.eq(SlideEventKind.flag) },
            database: model.services.database
        )
        annotationsQuery = .studyItems(of: model)
    }

    var body: some View {
        let session = model.session
        let rate = model.recording?.sampleRate ?? 48_000
        let items = StudyItems(annotationsQuery.wrappedValue)
        let recordingID = model.recording?.id
        let examHints = items.onRecording(items.examHints, recordingID).compactMap(\.startTime)
        let saidInClass = items.onRecording(items.saidInClass, recordingID).compactMap(\.startTime)
        HStack(spacing: 8) {
            PlayerButton("Back 15 Seconds", systemImage: "gobackward.15") {
                session.skip(by: -LecturePlayer.skipInterval)
            }
            PlayPauseButton(session: session, player: player)
            PlayerButton("Forward 15 Seconds", systemImage: "goforward.15") {
                session.skip(by: LecturePlayer.skipInterval)
            }
            PlayerTime(player: player)
            Scrubber(
                session: session,
                player: player,
                ticks: timeline.boundaries,
                flags: flags.compactMap { AnchorEditor.time(of: $0, sampleRate: rate) },
                offStretches: timeline.offStretches.map(\.start),
                examHints: examHints,
                saidInClass: saidInClass
            )
            .padding(.horizontal, 6)
            SpeedMenu(player: player)
            if session.canFollow {
                FollowButton(session: session)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .reviewGlass(in: Capsule(), floating: true)
    }
}

private struct PlayerButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // ±15: the mockup's 16 pt icon box, lighter than the play glyph between them.
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .regular))
                .frame(minWidth: 40, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
    }
}

private struct PlayPauseButton: View {
    let session: ReviewSession
    let player: LecturePlayer

    var body: some View {
        let playing = player.isPlaying
        Button {
            session.togglePlayPause()
        } label: {
            Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(minWidth: 40, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!player.hasAudio)
        .opacity(player.hasAudio ? 1 : 0.35)
    }
}

/// "37:27 / 1:08:13" in SF Mono.
private struct PlayerTime: View {
    let player: LecturePlayer

    var body: some View {
        Text(verbatim: "\(TimeText.clock(player.time)) / \(TimeText.clock(player.duration))")
            .font(.subheadline.monospaced())
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel(Text("\(TimeText.clock(player.time)) of \(TimeText.clock(player.duration))"))
    }
}

/// The recording timeline: progress, slide ticks, red flags, grey off-slide marks, the head.
/// Dragging or clicking scrubs (Follow off, paused).
private struct Scrubber: View {
    let session: ReviewSession
    let player: LecturePlayer
    let ticks: [Double]
    let flags: [Double]
    let offStretches: [Double]
    let examHints: [Double]
    let saidInClass: [Double]

    @State private var width: CGFloat = 0

    var body: some View {
        let duration = max(player.duration, 1)
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.quaternary)
                .frame(height: 3)
                .offset(y: 8)
            ScrubberMarks(
                width: width, duration: duration, ticks: ticks, flags: flags, offStretches: offStretches,
                examHints: examHints, saidInClass: saidInClass
            )
            ScrubberProgress(player: player, width: width, duration: duration)
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard width > 0 else { return }
                    let time = min(1, max(0, value.location.x / width)) * duration
                    Task { await session.scrub(to: time) }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(Text("Recording"))
        .accessibilityValue(Text(TimeText.clock(player.time)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.skip(by: LecturePlayer.skipInterval)
            case .decrement: session.skip(by: -LecturePlayer.skipInterval)
            @unknown default: break
            }
        }
    }
}

/// Slide ticks; purple said-in-class marks (M4), or grey off-slide marks for a lecture without
/// them; amber exam hints; red flags. Marks of a kind closer than 0.5 % of the track merge. Does
/// not read the clock, so it is not redrawn ten times a second.
private struct ScrubberMarks: View {
    let width: CGFloat
    let duration: Double
    let ticks: [Double]
    let flags: [Double]
    let offStretches: [Double]
    let examHints: [Double]
    let saidInClass: [Double]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, time in
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: 7)
                    .offset(x: x(time), y: 6)
            }
            if saidInClass.isEmpty {
                // An off-slide stretch at the very start (the room settling before the first
                // slide) is no moment worth a mark, and would sit on the track's end.
                ForEach(Array(merged(offStretches.filter { $0 > duration * 0.01 }).enumerated()), id: \.offset) { _, time in
                    mark(.gray, at: time)
                }
            } else {
                ForEach(Array(merged(saidInClass).enumerated()), id: \.offset) { _, time in
                    mark(Color.ai, at: time)
                }
            }
            ForEach(Array(merged(examHints).enumerated()), id: \.offset) { _, time in
                mark(Color.professor, at: time)
            }
            ForEach(Array(merged(flags).enumerated()), id: \.offset) { _, time in
                mark(.red, at: time)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func x(_ time: Double) -> CGFloat {
        width * min(1, max(0, time / duration))
    }

    private func merged(_ times: [Double]) -> [Double] {
        ScrubberMoments.merged(times, duration: duration)
    }

    private func mark(_ color: Color, at time: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .offset(x: x(time) - 3.5, y: -1)
    }
}

/// The played part and the head.
private struct ScrubberProgress: View {
    let player: LecturePlayer
    let width: CGFloat
    let duration: Double

    var body: some View {
        let progress = min(1, max(0, player.time / duration))
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.tint)
                .frame(width: max(0, width * progress), height: 3)
                .offset(y: 8)
            Circle()
                .fill(Self.knob)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                .offset(x: width * progress - 6.5, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The head is the window's colour (white in light, near-black in dark), not always white.
    #if canImport(AppKit)
    static let knob = Color(nsColor: .windowBackgroundColor)
    #else
    static let knob = Color(uiColor: .systemBackground)
    #endif
}

/// "1×" with a menu of speeds.
private struct SpeedMenu: View {
    let player: LecturePlayer

    var body: some View {
        Menu {
            ForEach(LecturePlayer.rates, id: \.self) { rate in
                Button {
                    player.setRate(rate)
                } label: {
                    if rate == player.rate {
                        Label(Self.label(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.label(rate))
                    }
                }
            }
        } label: {
            Text(verbatim: Self.label(player.rate))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .accessibilityLabel(Text("Speed"))
    }

    static func label(_ rate: Float) -> String {
        let number = rate.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
        return "\(number)×"
    }
}

/// Follow playback: tinted while the slide tracks the playhead; click to re-sync.
private struct FollowButton: View {
    let session: ReviewSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let on = session.isFollowing
        Button {
            session.toggleFollowing()
        } label: {
            Label {
                Text("Follow")
            } icon: {
                // The mockup's outline monitor: one flat layer, no filled screen.
                Image(systemName: "display")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.monochrome)
            }
            .font(.body)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(on ? AnyShapeStyle(.tint.opacity(ReviewTint.soft(colorScheme))) : AnyShapeStyle(.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Follow Playback"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
