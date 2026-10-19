import Capture
import CaptureUI
import Recorder
import StudyCore
import StudyUI
import SwiftUI

/// The iPhone recorder (mockup 09 left, DESIGN 8.5): the course menu and Stop, the timer, the
/// session line, the waveform with stamp lines, the slide, the 88 pt Next slide button, Previous
/// and Flag. Before recording the same layout with one red Record button; after Stop the capture
/// with Share and the outbox. The app presents it full screen; recording goes on when it closes
/// or the phone locks.
public struct RecorderScreen: View {
    let recorder: PhoneRecorder

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var confirmsStop = false
    @State private var showsOutbox = false
    @State private var failure: LiveLectureSession.Failure?

    public init(recorder: PhoneRecorder) {
        self.recorder = recorder
    }

    public var body: some View {
        Group {
            if recorder.finished != nil || showsOutbox {
                OutboxView(recorder: recorder, finished: recorder.finished) {
                    if recorder.finished != nil { dismiss() } else { showsOutbox = false }
                }
            } else {
                recording
            }
        }
        .background(Color.contentSurface.ignoresSafeArea())
        .task { await recorder.prepare() }
        .onChange(of: recorder.session?.phase) { _, phase in
            if case .failed(let reason)? = phase { failure = reason }
        }
        .onChange(of: recorder.finished?.id) { _, id in
            if id != nil { showsOutbox = false }
        }
        .alert(
            failure.map(LiveLectureView.title(for:)) ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { failure in
            if failure == .microphoneDenied {
                Button("Open Settings") { openURL(LiveLectureView.privacySettingsURL) }
            }
            Button("OK", role: .cancel) {}
        } message: { failure in
            if let message = LiveLectureView.message(for: failure) { Text(message) }
        }
    }

    // MARK: - Recording layout

    private var isCapturing: Bool { recorder.session?.isCapturing == true }

    private var recording: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 4)
            RecorderTimer(recorder: recorder)
                .padding(.top, 36)
            Text(recorder.sessionLine)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            RecorderWaveform(
                session: recorder.session,
                isPreview: recorder.isPreview,
                isActive: scenePhase == .active
            )
            .frame(height: 70)
            .padding(.top, 30)
            SlideBlock(session: recorder.session)
                .padding(.top, 20)
            Spacer(minLength: 16)
            if isCapturing {
                capturingButtons
            } else {
                recordButton
            }
        }
        .padding(.horizontal, 16)
        .confirmationDialog("Stop recording?", isPresented: $confirmsStop) {
            Button("Stop", role: .destructive) {
                Task { await recorder.stop() }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, -12)
            .accessibilityLabel(isCapturing ? Text("Hide Recorder") : Text("Close"))

            CourseMenu(recorder: recorder)
            Spacer(minLength: 8)
            if isCapturing {
                StopCapsule(isEnabled: recorder.session?.isRecording == true) { confirmsStop = true }
            } else if !recorder.captures.isEmpty {
                Button {
                    showsOutbox = true
                } label: {
                    Image(systemName: "tray.full")
                        .font(.system(size: 17))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(QuietFill(), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Recordings"))
            }
        }
        .frame(height: 44)
    }

    /// Next slide where the thumb rests, then Previous and Flag.
    private var capturingButtons: some View {
        let session = recorder.session
        let isRecording = session?.isRecording == true
        return VStack(spacing: 10) {
            BigButton(title: "Next slide", systemImage: "chevron.right", color: .accentColor) {
                recorder.next()
            }
            .disabled(!isRecording || session?.canGoNext != true)
            HStack(spacing: 10) {
                SecondaryButton(title: "Previous", systemImage: "chevron.left", glyphColor: .primary) {
                    recorder.previous()
                }
                .disabled(!isRecording || session?.canGoPrevious != true)
                SecondaryButton(title: "Flag", systemImage: "flag", glyphColor: .red) {
                    recorder.flag()
                }
                .disabled(!isRecording)
            }
        }
    }

    /// Before recording: one red Record button where Next slide will be (the row under it stays
    /// empty, so nothing moves when recording starts).
    private var recordButton: some View {
        VStack(spacing: 10) {
            BigButton(title: "Record", systemImage: "circle.fill", color: .red) {
                Task { await recorder.start() }
            }
            .disabled(!recorder.canRecord)
            Color.clear.frame(height: 54)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Parts

extension Color {
    /// The phone's content surface (`--win`): white, #1e1e20 in dark.
    static var contentSurface: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }

    /// Red at 12 % (20 % in dark): the Stop capsule (DESIGN 3.1, red soft).
    static func redSoft(_ scheme: ColorScheme) -> Color {
        Color.red.opacity(scheme == .dark ? 0.20 : 0.12)
    }
}

/// [● Data Centers ⌄]: the course the recording is for, as a menu of the courses that may
/// record. While recording it re-files the recording (the manifest and the Live Activity follow).
struct CourseMenu: View {
    let recorder: PhoneRecorder

    var body: some View {
        let course = recorder.course
        let color = Color.course(course)
        Menu {
            Picker(selection: Binding(
                get: { recorder.course?.id },
                set: { id in
                    guard let picked = recorder.courses.first(where: { $0.id == id }) else { return }
                    Task { await recorder.select(picked) }
                }
            )) {
                ForEach(recorder.courses) { course in
                    Text(course.name).tag(Optional(course.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 7) {
                if course != nil {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(course?.name ?? String(localized: "No Course"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(course == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(course == nil ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(color.opacity(0.14)), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .disabled(recorder.courses.isEmpty || recorder.isPreview)
        .accessibilityLabel(Text("Course"))
        .accessibilityValue(Text(course?.name ?? ""))
    }
}

/// [■ Stop]: the red-soft capsule (asks first).
struct StopCapsule: View {
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                Text("Stop")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.red)
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .frame(height: 34)
            .background(Color.redSoft(colorScheme), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// The 76 pt SF Mono light timer with the recording dot to its left.
struct RecorderTimer: View {
    let recorder: PhoneRecorder

    var body: some View {
        let isRecording = recorder.session?.isRecording == true
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(ClockText.string(recorder.elapsed(at: timeline.date)))
                .font(.system(size: 76, weight: .light, design: .monospaced))
                .monospacedDigit()
                .tracking(-3)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .overlay(alignment: .leading) {
                    if isRecording {
                        PulsingDot()
                            .offset(x: -26)
                    }
                }
        }
        .accessibilityLabel(Text("Recording time"))
    }
}

/// The recording dot: pulses on a 1.6 s cycle, still under Reduce Motion.
struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle().fill(.red).frame(width: 12, height: 12).accessibilityHidden(true)
        if reduceMotion {
            dot
        } else {
            dot.phaseAnimator([1.0, 0.35]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
        }
    }
}

/// "Slide 17 of 88" over the slide; without a deck "Slide 17" and no image.
struct SlideBlock: View {
    let session: LiveLectureSession?

    var body: some View {
        let page = session?.currentPage ?? 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Slide \(page)")
                    .font(.system(size: 15, weight: .semibold))
                if let session, session.hasDeck {
                    Text("of \(session.pageCount)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 2)
            .accessibilityElement(children: .combine)
            if let deck = session?.deck {
                SlideImageView(deck: deck, page: page, pixelWidth: SlideWidth.display, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The 88 pt button where the thumb rests (radius 26): Next slide (accent) or Record (red).
struct BigButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.4)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, 26)
            .padding(.trailing, 22)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(color, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// [‹ Previous] [Flag]: 54 pt on the quiet fill (radius 18).
struct SecondaryButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let glyphColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(glyphColor)
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(QuietFill(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

/// Dims while pressed and when disabled.
struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
