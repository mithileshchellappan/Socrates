import Capture
import SwiftUI

/// Which part of the live screen has keyboard focus. (Flag text is edited in a popover, which
/// is its own window on the Mac; its editing state travels as `isEditingFlag` instead.)
enum LiveField: Hashable {
    case canvas
    case note
}

/// The live-lecture inspector: input, provisional captions, quick notes for the slide on
/// screen, and the stamps list.
///
/// The level meter and the captions change several times a second; each reads the session in
/// its own view, so those updates never re-run this body (the notes editor, the stamps).
struct LiveInspector: View {
    let session: LiveLectureSession
    var focus: FocusState<LiveField?>.Binding
    /// True while a flag's text popover is open, so slide keys stay off while typing in it.
    @Binding var isEditingFlag: Bool

    @State private var showsAllStamps = false

    /// Lines the editor's text up with the section label (the text view's line fragment padding).
    #if os(macOS)
    private static let textEditorInsetCorrection: CGFloat = -5
    #else
    private static let textEditorInsetCorrection: CGFloat = -4
    #endif

    var body: some View {
        VStack(spacing: 0) {
            InputHeader(session: session)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LiveCaptions(session: session)
                    notes
                    Divider()
                    stamps
                }
                .padding(12)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var notes: some View {
        let page = session.currentPage
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Notes")
            TextEditor(text: Binding(
                get: { session.note(forPage: page) },
                set: { session.setNote($0, forPage: page) }
            ))
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Self.textEditorInsetCorrection)
            .frame(minHeight: 96)
            .disabled(!session.acceptsNotes)
            .focused(focus, equals: .note)
            .onKeyPress(.escape) {
                focus.wrappedValue = .canvas
                return .handled
            }
            .accessibilityLabel(Text("Notes for slide \(page)"))
        }
    }

    private var stamps: some View {
        let all = session.stamps
        let visible = showsAllStamps ? all : Array(all.suffix(3))
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Stamps") {
                Spacer()
                if all.count > 3 {
                    Button(showsAllStamps ? "Show less" : "Show all") {
                        showsAllStamps.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                }
            }
            VStack(spacing: 1) {
                ForEach(visible) { event in
                    if event.kind == .flag {
                        FlagRow(session: session, event: event, focus: focus, isEditingFlag: $isEditingFlag)
                    } else {
                        SlideStampRow(
                            event: event,
                            title: event.page.map { session.title(ofPage: $0) } ?? "",
                            time: session.time(of: event),
                            isCurrent: event.id == session.currentStampID
                        )
                    }
                }
            }
            .padding(.horizontal, -6)
        }
    }
}

/// Microphone and level meter. Reads `session.level` (updated with every audio chunk) here only.
private struct InputHeader: View {
    let session: LiveLectureSession

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: session.isInputAvailable ? "mic" : "mic.slash")
                .foregroundStyle(session.isInputAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .help(session.inputName ?? "")
                .accessibilityLabel(Text(session.inputName ?? "Microphone"))
            LevelMeter(level: session.level, isActive: session.isRecording && session.isInputAvailable)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

/// The captions section while captions run. Reads `session.captions` here only.
private struct LiveCaptions: View {
    let session: LiveLectureSession

    var body: some View {
        if let captions = session.captions {
            CaptionsSection(transcript: captions)
            Divider()
        }
    }
}

private struct SlideStampRow: View {
    let event: LectureEvent
    let title: String
    let time: TimeInterval?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            label
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            TimeChip(seconds: time)
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var label: Text {
        let page = event.page ?? 0
        if title.isEmpty {
            return Text("Slide \(page)")
        }
        return Text("Slide \(page) \(Text("· \(title)").foregroundStyle(.secondary))")
    }
}

/// A flag in the stamps list; click to add or edit its text.
private struct FlagRow: View {
    let session: LiveLectureSession
    let event: LectureEvent
    var focus: FocusState<LiveField?>.Binding
    @Binding var isEditingFlag: Bool

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = event.text ?? ""
            isEditing = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(event.text ?? String(localized: "Flag"))
                    .foregroundStyle(event.text == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                TimeChip(seconds: session.time(of: event))
            }
            .font(.system(size: 12.5))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.acceptsNotes)
        .popover(isPresented: $isEditing, arrowEdge: .leading) {
            FlagTextField(text: $draft, commit: commit)
        }
        .onChange(of: isEditing) { _, editing in
            isEditingFlag = editing
        }
    }

    /// Runs on Return and again when the popover closes (also when it is clicked away).
    private func commit() {
        session.setFlagText(draft, for: event.id)
        isEditing = false
        // Back to the slide, unless the click that closed the popover went into the notes.
        if focus.wrappedValue != .note {
            focus.wrappedValue = .canvas
        }
    }
}

/// The popover's text field. It owns its focus: the popover is a separate window on the Mac,
/// where a focus binding from the live screen does not reach.
private struct FlagTextField: View {
    @Binding var text: String
    let commit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Flag", text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit(commit)
            .frame(width: 240)
            .padding(10)
            .onAppear { isFocused = true }
            .onDisappear(perform: commit)
    }
}

private struct CaptionsSection: View {
    let transcript: CaptionTranscript

    var body: some View {
        let lines = Array(transcript.allLines.suffix(3))
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Captions") {
                Text(transcript.languageCode)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines) { line in
                    let isNow = line.id == lines.last?.id
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ClockText.string(line.start))
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(isNow ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .frame(width: 38, alignment: .leading)
                        Text(Self.attributed(line))
                            .font(.system(size: 12.5))
                            .lineSpacing(1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        isNow ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, -6)
        }
    }

    /// Low-confidence words dotted; text still settling in grey.
    static func attributed(_ line: CaptionTranscript.Line) -> AttributedString {
        var result = AttributedString()
        for run in line.runs {
            var part = AttributedString(run.text)
            if run.isLowConfidence {
                part.underlineStyle = Text.LineStyle(pattern: .dot, color: .secondary)
            }
            if !line.isFinal {
                part.foregroundColor = .secondary
            }
            result += part
        }
        return result
    }
}
