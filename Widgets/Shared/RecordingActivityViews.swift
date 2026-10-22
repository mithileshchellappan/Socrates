#if os(iOS)
import AppIntents
import RecorderActivity
import RecorderContract
import SwiftUI

// The recording's Live Activity views (M7, mockup 09, DESIGN 8.5), compiled into the widget
// extension and the app (the app's parity screen draws the Lock Screen view). Three buttons,
// Pause/Resume, Next Slide and Stop Recording (PRD "iPhone recording"); each acts only on the
// recording and the state the activity was drawn for, and only what the state accepts is a
// button.

/// Lock Screen (and the expanded Dynamic Island's content): course dot and name, "Slide 17 of
/// 88 · DC Lecture 2" ("Paused · Slide 17 of 88" while paused), the elapsed time in SF Mono,
/// [⏸] [Next Slide] [Stop Recording].
struct RecordingLockScreenView: View {
    let state: RecordingActivityState
    let recordingID: RecordingID

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                RecordingTitle(state: state)
                Spacer(minLength: 8)
                RecordingElapsed(state: state, size: 24)
            }
            RecordingButtons(state: state, recordingID: recordingID)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
    }
}

/// ● Data Centers / Slide 17 of 88 · DC Lecture 2; paused: **Paused** · Slide 17 of 88.
struct RecordingTitle: View {
    let state: RecordingActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Circle()
                    .fill(RecordingActivityStyle.color(hex: state.courseColorHex))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(state.courseName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            Group {
                if state.isPaused {
                    Text("\(Text("Paused").fontWeight(.semibold).foregroundStyle(.primary)) · \(state.slideText)")
                } else {
                    Text(state.detailLine)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The red dot and the elapsed time, counting by itself (no updates); paused, the time stands
/// still in the secondary colour without the dot; frozen once stopped.
struct RecordingElapsed: View {
    let state: RecordingActivityState
    let size: CGFloat
    var weight: Font.Weight = .medium

    var body: some View {
        HStack(spacing: 7) {
            if !state.isPaused {
                Circle()
                    .fill(.red)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .accessibilityHidden(true)
            }
            Text(timerInterval: state.timerRange, pauseTime: state.timerPauseTime, countsDown: false, showsHours: true)
                .font(.system(size: size, weight: weight, design: .monospaced))
                .monospacedDigit()
                .tracking(-size * 0.02)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(state.isPaused ? .secondary : .primary)
        }
    }
}

/// [⏸] (leftmost, away from Stop: Stop on the Lock Screen cannot be undone), [Next Slide]
/// (accent, the wide one) and [Stop Recording]. Each button's intent carries the snapshot
/// sequence it was drawn for; Next Slide also the slide on show. A command the state does not
/// accept is drawn dimmed and is not a button (Next Slide while paused, at the deck's end).
struct RecordingButtons: View {
    let state: RecordingActivityState
    let recordingID: RecordingID
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            pauseButton
            if state.accepts.contains(.nextSlide) {
                Button(intent: NextSlideIntent(recordingID: recordingID, slide: state.slide, sequence: state.sequence)) {
                    nextSlideLabel
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                // Not a button (a disabled widget button is not reliable): VoiceOver hears a
                // dimmed Next Slide that does nothing, not one that opens the app.
                nextSlideLabel
                    .foregroundStyle(.tertiary)
                    .background(RecordingActivityStyle.fill2(colorScheme), in: Capsule())
                    .accessibilityRepresentation {
                        Button("Next Slide") {}
                            .disabled(true)
                    }
            }
            Button(intent: StopRecordingIntent(recordingID: recordingID, sequence: state.sequence)) {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text("Stop Recording")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(RecordingActivityStyle.fill2(colorScheme), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Pause while recording (on fill 2), Resume while paused (white on the accent).
    @ViewBuilder
    private var pauseButton: some View {
        if state.accepts.contains(.resume) {
            Button(intent: ResumeRecordingIntent(recordingID: recordingID, sequence: state.sequence)) {
                circle("play.fill")
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Resume Recording"))
        } else if state.accepts.contains(.pause) {
            Button(intent: PauseRecordingIntent(recordingID: recordingID, sequence: state.sequence)) {
                circle("pause.fill")
                    .foregroundStyle(.primary)
                    .background(RecordingActivityStyle.fill2(colorScheme), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Pause Recording"))
        } else {
            circle(state.isPaused ? "play.fill" : "pause.fill")
                .foregroundStyle(.tertiary)
                .background(RecordingActivityStyle.fill2(colorScheme), in: Circle())
                .accessibilityHidden(true)
        }
    }

    private func circle(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 42, height: 42)
    }

    private var nextSlideLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
            Text("Next Slide")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 15, weight: .semibold))
        .frame(maxWidth: .infinity)
        .frame(height: 42)
    }
}

enum RecordingActivityStyle {
    /// The course's colour from "#rrggbb" (the accent when unreadable). The widget extension
    /// does not link StudyUI, so it reads the hex itself.
    static func color(hex: String) -> Color {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .accentColor }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// The mockups' fill 2: rgb(120,120,128) at 17 % (30 % in dark), the Stop button.
    static func fill2(_ scheme: ColorScheme) -> Color {
        Color(.sRGB, red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(scheme == .dark ? 0.30 : 0.17)
    }
}

#if DEBUG
/// Debug builds (parity): the Lock Screen view on the system's Live Activity shape, for a
/// screenshot without a Lock Screen (radius 26, the regular material).
struct RecordingLockScreenParityCard: View {
    let state: RecordingActivityState
    let recordingID: RecordingID

    var body: some View {
        RecordingLockScreenView(state: state, recordingID: recordingID)
            .frame(width: 366)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
#endif
#endif
