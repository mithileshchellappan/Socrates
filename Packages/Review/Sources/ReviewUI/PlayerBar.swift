import Review
import StudyCore
import StudyUI
import SwiftUI

/// The floating glass player: back 15, play/pause, forward 15, "37:27 / 1:08:13", the scrubber
/// with slide ticks and flag / off-slide marks, the speed menu and Follow.
///
/// The bar itself reads nothing that changes while playing; the time label and the scrubber
/// read the clock in their own views.
struct PlayerBar: View {
    let model: ReviewModel
    let player: LecturePlayer
    let timeline: SlideTimeline

    private let flagsQuery: FetchAll<SlideEvent>
    private var flags: [SlideEvent] { flagsQuery.wrappedValue }

    init(model: ReviewModel, player: LecturePlayer, timeline: SlideTimeline) {
        self.model = model
        self.player = player
        self.timeline = timeline
        let recordingID = model.recording?.id ?? UUID()
        flagsQuery = FetchAll(
            SlideEvent.where { $0.recordingID.eq(recordingID) && $0.kind.eq(SlideEventKind.flag) },
            database: model.services.database
        )
    }

    var body: some View {
        let session = model.session
        let rate = model.recording?.sampleRate ?? 48_000
        HStack(spacing: 6) {
            PlayerButton("Back 15 Seconds", systemImage: "gobackward.15") {
                session.skip(by: -LecturePlayer.skipInterval)
            }
            PlayPauseButton(session: session, player: player)
            PlayerButton("Forward 15 Seconds", systemImage: "goforward.15") {
                session.skip(by: LecturePlayer.skipInterval)
            }
            PlayerTime(player: player)
                .padding(.leading, 4)
            Scrubber(
                session: session,
                player: player,
                ticks: timeline.boundaries,
                flags: flags.compactMap { AnchorEditor.time(of: $0, sampleRate: rate) },
                offStretches: timeline.offStretches.map(\.start)
            )
            .padding(.horizontal, 6)
            SpeedMenu(player: player)
            if session.canFollow {
                FollowButton(session: session)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 44)
        .reviewGlass(in: Capsule())
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
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 14))
                .frame(minWidth: 30, minHeight: 28)
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
                .font(.system(size: 17))
                .frame(minWidth: 30, minHeight: 28)
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
            .font(.system(size: 11, design: .monospaced))
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

    @State private var width: CGFloat = 0

    var body: some View {
        let duration = max(player.duration, 1)
        let progress = min(1, max(0, player.time / duration))
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.quaternary)
                .frame(height: 3)
                .offset(y: 8)
            Capsule()
                .fill(.tint)
                .frame(width: max(0, width * progress), height: 3)
                .offset(y: 8)
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, time in
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: 7)
                    .offset(x: x(time, duration), y: 6)
            }
            ForEach(Array(offStretches.enumerated()), id: \.offset) { _, time in
                mark(.gray, at: time, duration: duration)
            }
            ForEach(Array(flags.enumerated()), id: \.offset) { _, time in
                mark(.red, at: time, duration: duration)
            }
            Circle()
                .fill(.white)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                .offset(x: width * progress - 6.5, y: 3)
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

    private func x(_ time: Double, _ duration: Double) -> CGFloat {
        width * min(1, max(0, time / duration))
    }

    private func mark(_ color: Color, at time: Double, duration: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .offset(x: x(time, duration) - 3.5, y: -1)
    }
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
                .font(.system(size: 11.5, design: .monospaced))
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

    var body: some View {
        let on = session.isFollowing
        Button {
            session.toggleFollowing()
        } label: {
            Label("Follow", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 13))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background(on ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Follow Playback"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
