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
    @Environment(\.pixelLength) private var pixelLength

    /// Lines the editor's text up with the section label (the text view's line fragment padding).
    #if os(macOS)
    private static let textEditorInsetCorrection: CGFloat = -5
    #else
    private static let textEditorInsetCorrection: CGFloat = -4
    #endif

    /// Note text: 13 pt with a 1.45 line height (mockup 02).
    private static let noteFont = Font.system(size: 13)
    private static let noteLineSpacing: CGFloat = 3

    var body: some View {
        // The sections follow the header with 12 pt between every part (mockup 02).
        VStack(spacing: 0) {
            #if os(iOS)
            InputHeader(session: session)
                .padding(.horizontal, 12)
                .frame(height: 52)
            #endif
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LiveCaptions(session: session)
                    notes
                    Hairline()
                    stamps
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
        }
        // Opaque, with a hairline along its leading edge from the top of the window down:
        // nothing of the main column shows through.
        .background(Color.inspectorBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.separator)
                .frame(width: pixelLength)
                .ignoresSafeArea()
        }
        #if os(macOS)
        // On the Mac the header shares the toolbar's row, over the inspector; the main column's
        // controls then end at the inspector's edge.
        .toolbar {
            ToolbarItem {
                InputHeader(session: session)
                    .padding(.horizontal, 2)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        }
        #endif
    }

    private var notes: some View {
        let page = session.currentPage
        let text = Binding(
            get: { session.note(forPage: page) },
            set: { session.setNote($0, forPage: page) }
        )
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Notes")
            // As tall as the note plus a line for the caret (the hidden copy sets the height),
            // so Stamps follows closely; a long note scrolls inside the editor.
            // An empty note is one caret line (mockup 02: no placeholder, Stamps close below).
            Text(verbatim: text.wrappedValue.isEmpty ? " " : text.wrappedValue + "\n ")
                .font(Self.noteFont)
                .lineSpacing(Self.noteLineSpacing)
                .frame(maxWidth: .infinity, minHeight: 19, maxHeight: 320, alignment: .topLeading)
                .hidden()
                .overlay {
                    TextEditor(text: text)
                        .font(Self.noteFont)
                        .lineSpacing(Self.noteLineSpacing)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Self.textEditorInsetCorrection)
                        .disabled(!session.acceptsNotes)
                        .focused(focus, equals: .note)
                        .onKeyPress(.escape) {
                            focus.wrappedValue = .canvas
                            return .handled
                        }
                        .accessibilityLabel(Text("Notes for slide \(page)"))
                }
        }
    }

    private var stamps: some View {
        let all = session.stamps
        let visible = showsAllStamps ? all : Array(all.suffix(3))
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Stamps") {
                Spacer()
                if all.count > 3 {
                    Button(showsAllStamps ? "Show less" : "Show all") {
                        showsAllStamps.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(LiveFont.sectionAction)
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
                .font(.system(size: 13))
                .foregroundStyle(session.isInputAvailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .help(session.inputName ?? "")
                .accessibilityLabel(Text(session.inputName ?? "Microphone"))
            LevelMeter(level: session.level, isActive: session.isRecording && session.isInputAvailable)
            #if os(iOS)
            Spacer()
            #endif
        }
    }
}

/// The captions section while captions run. Reads `session.captions` here only.
private struct LiveCaptions: View {
    let session: LiveLectureSession

    var body: some View {
        if let captions = session.captions {
            CaptionsSection(transcript: captions)
            Hairline()
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
            // The mockup's thin outline monitor: SF's display at 10 pt, one flat layer.
            Image(systemName: "display")
                .font(.system(size: 10))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
            label
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            TimeChip(seconds: time)
        }
        .font(.system(size: 12.5))
        .frame(minHeight: StampMetrics.lineHeight)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            isCurrent ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear),
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
            .frame(minHeight: StampMetrics.lineHeight)
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

/// Stamp and flag rows: a 17.5 pt line in 4 pt padding, 1 pt apart (a 26.5 pt step).
private enum StampMetrics {
    static let lineHeight: CGFloat = 17.5
}

private struct CaptionsSection: View {
    let transcript: CaptionTranscript

    var body: some View {
        let rows = transcript.rows()
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Captions") {
                Text(transcript.languageCode)
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.38)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    let isNow = row.id == rows.last?.id
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ClockText.string(row.start))
                            .font(.system(size: 10.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(isNow ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .frame(width: 34, alignment: .leading)
                        Text(Self.attributed(row))
                            .font(.system(size: 12.5))
                            .lineSpacing(2.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // The mockup's 1.42 line height at 12.5 pt puts half the leading above the
                    // first line and below the last: one-line rows 25.75 pt, as tall as stamps.
                    .padding(.vertical, 5.375)
                    .padding(.horizontal, 6)
                    .background(
                        isNow ? AnyShapeStyle(.accentSoft) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, -6)
        }
    }

    /// Settled words in the primary colour, the words still settling lighter after them;
    /// low-confidence words dotted.
    static func attributed(_ row: CaptionRow) -> AttributedString {
        var result = AttributedString()
        for (run, isSettling) in row.settled.map({ ($0, false) }) + row.settling.map({ ($0, true) }) {
            var part = AttributedString(run.text)
            if run.isLowConfidence {
                part.underlineStyle = Text.LineStyle(pattern: .dot, color: .tertiaryLabel)
            }
            if isSettling {
                part.foregroundColor = .tertiaryLabel
            }
            result += part
        }
        return result
    }
}
