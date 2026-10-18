import Notes
import StudyCore
import StudyUI
import SwiftUI

/// One note, Apple Notes-style (DESIGN 8.4, docs/plan-m6.md §5.1): text with images, sketches
/// and slide clips inside the text, Title / Heading / Subheading / Body, lists and checklists,
/// character styles, links, slide and time chips, professor quotes.
///
/// On the Mac it is an `NSTextView` on TextKit 2; on iOS a read-only rendering. It writes through
/// its `NoteSession` (nothing on open; 500 ms after typing stops and on leaving). Give it an `.id`
/// per note: a new note is a new editor with its own undo steps.
public struct NoteEditor: View {
    private let session: NoteSession?
    private let readOnlyNote: Note?
    private let style: NoteEditorStyle
    private let startsWith: NoteParagraphKind
    private let controller: NoteEditorController?
    private let professor: String?
    private let lectureID: Lecture.ID?
    private let trailingTime: Double?
    private let focusRequest: Int
    private let startsFocused: Bool
    private let onFocusChange: ((Bool) -> Void)?
    private let onLink: ((NoteLink) -> Bool)?

    @State private var ownController = NoteEditorController()
    @State private var context: NoteEditorContext
    @State private var height: CGFloat = 18

    /// An editable note.
    /// - Parameters:
    ///   - startsWith: the format of an empty note's first line (Notes screen: Title; Review: Body).
    ///   - controller: the toolbar's and Format menu's handle on this editor.
    ///   - professor: the by-line of professor quotes ("Prof. Example").
    ///   - lectureID: the lecture chips without one of their own open.
    ///   - trailingTime: a time chip after the last word (Review: the note's moment).
    ///   - focusRequest: bump to put the caret in the editor.
    ///   - startsFocused: the caret is in the editor when it appears (a new note).
    ///   - onLink: a chip was clicked; return true when the host handled it (else it navigates).
    public init(
        session: NoteSession,
        style: NoteEditorStyle,
        startsWith: NoteParagraphKind = .body,
        controller: NoteEditorController? = nil,
        professor: String? = nil,
        lectureID: Lecture.ID? = nil,
        trailingTime: Double? = nil,
        focusRequest: Int = 0,
        startsFocused: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        onLink: ((NoteLink) -> Bool)? = nil
    ) {
        self.session = session
        readOnlyNote = nil
        self.style = style
        self.startsWith = startsWith
        self.controller = controller
        self.professor = professor
        self.lectureID = lectureID
        self.trailingTime = trailingTime
        self.focusRequest = focusRequest
        self.startsFocused = startsFocused
        self.onFocusChange = onFocusChange
        self.onLink = onLink
        _context = State(initialValue: NoteEditorContext(metrics: NoteMetrics(style: style)))
    }

    /// A note shown read-only (Review's Whole lecture: the notes of the slides).
    public init(note: Note, style: NoteEditorStyle, professor: String? = nil, onLink: ((NoteLink) -> Bool)? = nil) {
        session = nil
        readOnlyNote = note
        self.style = style
        startsWith = .body
        controller = nil
        self.professor = professor
        lectureID = note.lectureID
        trailingTime = nil
        focusRequest = 0
        startsFocused = false
        onFocusChange = nil
        self.onLink = onLink
        _context = State(initialValue: NoteEditorContext(metrics: NoteMetrics(style: style)))
    }

    private var blocks: [NoteBlock] {
        session?.blocks ?? readOnlyNote?.blocks ?? []
    }

    public var body: some View {
        let context = context
        context.professor = professor
        context.lectureID = lectureID ?? session?.note?.lectureID ?? readOnlyNote?.lectureID
        context.handleLink = onLink
        #if os(macOS)
        var editor = NoteTextEditor(
            session: session,
            blocks: blocks,
            stamp: style == .document ? stamp : nil,
            style: style,
            startsWith: startsWith,
            controller: controller ?? ownController,
            context: context,
            trailingTime: trailingTime,
            focusRequest: focusRequest,
            onFocus: onFocusChange,
            onHeight: style == .inspector ? { height = $0 } : nil
        )
        editor.startsFocused = startsFocused
        return Group {
            if style == .inspector {
                editor.frame(height: height)
            } else {
                editor
            }
        }
        #else
        return NoteReadOnlyView(blocks: blocks, style: style, context: context)
        #endif
    }

    /// "16 October 2026 at 09:41" (DESIGN 3.2: a date stamp, proportional with tabular digits).
    private var stamp: String {
        let date = session?.note?.updatedAt ?? readOnlyNote?.updatedAt ?? Date()
        return NoteStamp.text(date)
    }
}

/// The document's date stamp.
enum NoteStamp {
    static func text(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let day = date.formatted(Date.VerbatimFormatStyle(
            format: "\(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits)",
            locale: locale, timeZone: timeZone, calendar: Calendar(identifier: .gregorian)
        ))
        let time = DayText.time(date, timeZone: timeZone)
        return String(localized: "\(day) at \(time)")
    }
}
