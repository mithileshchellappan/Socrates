import CaptureUI
import Link
import RecorderContract
import StudyUI
import SwiftUI

/// The panel's recording (mockup 62b): the course dot and session, the timer with its mark and
/// the slide, "Paused" while paused, the controls, and a remote problem. Frozen, everything is
/// secondary and the controls are off. Stop… asks first ("Stop recording?"), as the phone's
/// screen does; on the Mac the question is a sheet from the window's top edge.
struct RemoteRecordingView: View {
    let link: PhoneLink
    let recording: RemoteRecording

    @State private var confirmsStop = false

    var body: some View {
        let mark = RemoteMark(recording)
        let snapshot = recording.snapshot
        let time = ClockText.string(recording.elapsed(at: link.now))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                CourseDot(hex: snapshot.course.colorHex, size: 8)
                    .opacity(mark == .frozen ? 0.5 : 1)
                Text(snapshot.sessionName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(mark == .frozen ? .secondary : .primary)
                    .lineLimit(1)
            }

            HStack(spacing: 9) {
                RemoteDot(mark: mark, size: 9)
                Text(time)
                    .font(.system(size: 28, weight: .light, design: .monospaced))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(mark == .recording ? .primary : .secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("Recording time"))
                    .accessibilityValue(Text(time))
                Spacer(minLength: 8)
                Text(slideText(snapshot))
                    .font(.system(size: 13))
                    .foregroundStyle(mark == .frozen ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .frame(height: 34)
            .padding(.top, 8)

            if snapshot.phase == .paused {
                Text("Paused")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(mark == .frozen ? .secondary : .primary)
                    .padding(.top, 1)
            }

            RemoteControls(link: link, phase: snapshot.phase, confirmStop: askToStop)
                .padding(.top, 12)

            if let problem = link.problem {
                RemoteProblemLine(problem: problem)
                    .padding(.top, 10)
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $confirmsStop, titleVisibility: .visible) {
            Button("Stop", role: .destructive, action: stop)
        }
    }

    /// "Slide 10 of 88"; "Slide 10" without a deck (the Live Activity's words).
    private func slideText(_ snapshot: RecorderSnapshot) -> String {
        if let count = snapshot.slideCount { return String(localized: "Slide \(snapshot.slide) of \(count)") }
        return String(localized: "Slide \(snapshot.slide)")
    }

    private func askToStop() {
        confirmsStop = true
    }

    private func stop() {
        link.send(.stop)
    }
}
