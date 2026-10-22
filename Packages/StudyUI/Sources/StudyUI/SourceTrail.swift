import Foundation
import StudyCore
import SwiftUI

// Sources as one quiet affordance (docs/DESIGN.md §4.6, §5.2): a faint glyph after a row's last
// line (`waveform` = a recording, `envelope` = a mail, `calendar` = a timetable file, `display` =
// a slide, together when they agree) that opens the full trail in a popover on hover (tap on iPad and iPhone), with the in-calendar check and Undo
// in its footer. Today and Calendar use the same pieces.

/// Words for source trail rows.
public enum SourceTrailText {
    /// "Example" from "Prof. Dr. Ada Example", "Demo" from "Dr. Cy Demo".
    public static func surname(_ professor: String) -> String {
        professor.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? professor
    }

    /// The row's name: "Lecture 2, Example" for a numbered lecture, a seminar meeting or an
    /// untitled lecture by its title ("Seminar intro"); the sender of a mail; "You" for what the
    /// student told the agent; the file's name for a timetable; "Slides" for a slide no lecture shows.
    public static func name(_ entry: SourceTrailEntry) -> String {
        switch entry.kind {
        case .timetable:
            let file = entry.source.rfcMessageID.trimmingCharacters(in: .whitespaces)
            return file.isEmpty ? String(localized: "Timetable") : file
        case .mail:
            let name = entry.senderName?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? (entry.senderAddress ?? String(localized: "Mail")) : name
        case .chat:
            return String(localized: "You")
        case .calendar:
            return String(localized: "Calendar")
        case .profile:
            return String(localized: "Profile")
        case .slide where entry.lectureNumber == nil && (entry.lectureTitle ?? "").isEmpty:
            return String(localized: "Slides")
        default:
            let title = entry.lectureTitle?.trimmingCharacters(in: .whitespaces) ?? ""
            let isLecture = entry.sessionKind == nil || entry.sessionKind == .lecture
            if let number = entry.lectureNumber, isLecture || title.isEmpty {
                if let professor = entry.professors.first {
                    return String(localized: "Lecture \(number), \(surname(professor))")
                }
                return String(localized: "Lecture \(number)")
            }
            return title.isEmpty ? String(localized: "Lecture") : title
        }
    }

    /// A recording row's line: "Mon 12 Oct · slide 25", "Mon 12 Oct", or nil.
    public static func lectureLine(_ entry: SourceTrailEntry, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        var parts: [String] = []
        if let heldAt = entry.lectureHeldAt { parts.append(DayText.day(heldAt, locale: locale, timeZone: timeZone)) }
        if let page = entry.page { parts.append(String(localized: "slide \(page)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// When a mail came, as the mail reader writes it: "Today, 09:41", "Yesterday, 16:10",
    /// "Tue 13 Oct, 16:10".
    public static func mailWhen(_ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let day = CalendarDay(date, in: timeZone)
        let today = CalendarDay(now, in: timeZone)
        let time = DayText.time(date, timeZone: timeZone)
        if day == today { return String(localized: "Today, \(time)") }
        if day == today.adding(days: -1) { return String(localized: "Yesterday, \(time)") }
        return "\(DayText.day(date, locale: locale, timeZone: timeZone)), \(time)"
    }

    /// A mail's short time for a chip: "08:02" today, else the day.
    public static func mailChip(_ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        CalendarDay(date, in: timeZone) == CalendarDay(now, in: timeZone)
            ? DayText.time(date, timeZone: timeZone)
            : DayText.day(date, locale: locale, timeZone: timeZone)
    }

    /// The quote in curly quotes, at most `maxWords` words (no long quotes, docs/DESIGN.md §4.10).
    public static func quote(_ text: String, maxWords: Int = 15) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let shown = words.prefix(maxWords).joined(separator: " ")
        return "“\(shown)\(words.count > maxWords ? "…" : "")”"
    }

    /// The glyphs a row shows for these sources: a recording first, then a mail, then a timetable
    /// file, then a slide; undone sources and what the student typed have none.
    public static func glyphKinds(_ entries: [SourceTrailEntry]) -> [SourceRef.Kind] {
        let active = entries.filter(\.isActive)
        var kinds: [SourceRef.Kind] = []
        if active.contains(where: { $0.kind == .transcript }) { kinds.append(.transcript) }
        if active.contains(where: { $0.kind == .mail }) { kinds.append(.mail) }
        if active.contains(where: { $0.kind == .timetable }) { kinds.append(.timetable) }
        if active.contains(where: { $0.kind == .slide }) { kinds.append(.slide) }
        return kinds
    }
}

/// The faint source glyph(s): 14 pt tertiary; accent on accent soft while its row is hovered or
/// its popover is open.
public struct SourceGlyph: View {
    private let kinds: [SourceRef.Kind]
    private let highlighted: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(kinds: [SourceRef.Kind], highlighted: Bool = false) {
        self.kinds = kinds
        self.highlighted = highlighted
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds, id: \.self) { kind in
                Image(systemName: kind.symbol)
                    .font(.system(size: 11.5))
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .background(
            highlighted ? Color.accentSoft(colorScheme) : .clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        if kinds == [.timetable] { return String(localized: "Source: timetable") }
        if kinds == [.slide] { return String(localized: "Source: slides") }
        return switch (kinds.contains(.transcript), kinds.contains(.mail)) {
        case (true, true): String(localized: "Sources: recording and mail")
        case (true, false): String(localized: "Source: recording")
        case (false, true): String(localized: "Source: mail")
        case (false, false): String(localized: "Sources")
        }
    }
}

public extension SourceRef.Kind {
    /// The source's glyph wherever a row names where it came from (DESIGN 4.6): a recording, a
    /// mail, a timetable file or the calendar, a slide, what the student said, a web page.
    var symbol: String {
        switch self {
        case .transcript: "waveform"
        case .mail: "envelope"
        case .timetable, .calendar: "calendar"
        case .slide: "display"
        case .chat: "bubble.left"
        case .web: "globe"
        default: "doc.text"
        }
    }
}

/// The source popover's content (about 264 pt wide): one row per source — a recording with the
/// professor's pin and a jump-to-time chip, a mail with its sender, a short quote and its time,
/// what the student typed — then a footer with the green calendar check and Undo when the item
/// went into the calendar on its own.
public struct SourceTrailPopover: View {
    private let entries: [SourceTrailEntry]
    private let now: Date
    private let header: String?
    private let inCalendar: Bool
    private let undo: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - entries: the item's sources (undone ones are left out).
    ///   - inCalendar: the item is in the calendar: the footer shows the green check.
    ///   - undo: Undo of what a source did on its own; nil hides the button.
    public init(entries: [SourceTrailEntry], now: Date, header: String? = nil, inCalendar: Bool, undo: (@MainActor () -> Void)? = nil) {
        self.entries = entries.filter(\.isActive)
        self.now = now
        self.header = header
        self.inCalendar = inCalendar
        self.undo = undo
    }

    public static let width: CGFloat = 264

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 3)
            }
            SourceTrailRows(entries: entries, now: now)
            if inCalendar || undo != nil {
                Hairline()
                    .padding(.top, 3)
                HStack(spacing: 6) {
                    if inCalendar {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                            .accessibilityLabel(Text("In Calendar"))
                    }
                    Spacer(minLength: 8)
                    if let undo {
                        Button(action: undo) {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 12))
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .frame(width: Self.width, alignment: .leading)
    }
}

/// The rows of a source trail without the popover's header, footer and frame, hairlines between
/// them: a recording with the professor's pin and a jump-to-time chip, a mail with its sender, a
/// short quote and its time (opens the mail), a timetable file with its quote, what the student
/// typed. The source popover and Calendar's detail popover draw them.
public struct SourceTrailRows: View {
    private let entries: [SourceTrailEntry]
    private let now: Date
    @Environment(\.openDestination) private var openDestination
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    /// - Parameter entries: the item's sources (undone ones are left out).
    public init(entries: [SourceTrailEntry], now: Date) {
        self.entries = entries.filter(\.isActive)
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Hairline() }
                row(entry)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: SourceTrailEntry) -> some View {
        switch entry.kind {
        case .mail:
            mailRow(entry)
        case .timetable, .calendar:
            quoteRow(entry, glyph: "calendar")
        case .profile:
            // Not a lecture: no professor's pin.
            quoteRow(entry, glyph: "doc.text")
        case .slide:
            slideRow(entry)
        case .chat:
            HStack(alignment: .center, spacing: 9) {
                ProvenancePin(.user)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SourceTrailText.name(entry))
                        .font(.system(size: 12.5, weight: .medium))
                    Text(SourceTrailText.quote(entry.source.quote))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        default:
            HStack(alignment: .center, spacing: 9) {
                ProvenancePin(.professor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SourceTrailText.name(entry))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if let line = SourceTrailText.lectureLine(entry, locale: locale, timeZone: timeZone) {
                        Text(line)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let time = entry.source.time {
                    TimeChip(time) {
                        guard let lectureID = entry.source.lectureID else { return }
                        openDestination(.lecture(lectureID, ReviewTarget(time: time, plays: true, recordingID: entry.source.recordingID)))
                    }
                }
            }
        }
    }

    /// A slide: the professor's pin, the lecture that shows it (or "Slides") over the quote, and
    /// the slide chip that opens it there.
    private func slideRow(_ entry: SourceTrailEntry) -> some View {
        HStack(alignment: .center, spacing: 9) {
            ProvenancePin(.professor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(SourceTrailText.name(entry))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(SourceTrailText.quote(entry.source.quote))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if let page = entry.page, let lectureID = entry.source.lectureID {
                SlideChip(page: page) { openDestination(.lecture(lectureID, ReviewTarget(page: page))) }
            }
        }
    }

    /// A timetable file, the calendar or the profile: its glyph, its name, the quote.
    private func quoteRow(_ entry: SourceTrailEntry, glyph: String) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: glyph)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(SourceTrailText.name(entry))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SourceTrailText.quote(entry.source.quote))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// A short quote sits on the name's line with the time as a chip (mockup 01); a longer one
    /// gets its own full-width line under the time (mockup 06).
    @ViewBuilder
    private func mailRow(_ entry: SourceTrailEntry) -> some View {
        let quote = entry.source.quote
        let isShort = quote.split(whereSeparator: \.isWhitespace).count <= 8
        Button {
            if let messageID = entry.source.mailMessageID { openDestination(.mail(messageID)) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "envelope")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SourceTrailText.name(entry))
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        if isShort, !quote.isEmpty {
                            Text(SourceTrailText.quote(quote))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let received = entry.receivedAt {
                            Text(SourceTrailText.mailWhen(received, now: now, locale: locale, timeZone: timeZone))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 4)
                    if isShort, let received = entry.receivedAt {
                        Text(SourceTrailText.mailChip(received, now: now, locale: locale, timeZone: timeZone))
                            .font(.chip)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if !isShort {
                    Text(SourceTrailText.quote(quote))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The source glyph with its popover: opens while the pointer rests on the glyph or the popover
/// (macOS), or on tap (iPad, iPhone). Draws nothing when no source has a glyph.
public struct SourceTrailButton: View {
    private let entries: [SourceTrailEntry]
    private let now: Date
    private let header: String?
    private let inCalendar: Bool
    private let highlighted: Bool
    private let undo: (@MainActor () -> Void)?
    @State private var isPresented = false
    @State private var overGlyph = false
    @State private var overPopover = false
    @State private var pending: Task<Void, Never>?

    /// - Parameter highlighted: the row is hovered (the glyph turns accent).
    public init(
        entries: [SourceTrailEntry], now: Date, header: String? = nil, inCalendar: Bool, highlighted: Bool = false,
        undo: (@MainActor () -> Void)? = nil
    ) {
        self.entries = entries
        self.now = now
        self.header = header
        self.inCalendar = inCalendar
        self.highlighted = highlighted
        self.undo = undo
    }

    public var body: some View {
        let kinds = SourceTrailText.glyphKinds(entries)
        if !kinds.isEmpty {
            SourceGlyph(kinds: kinds, highlighted: highlighted || isPresented)
                .contentShape(Rectangle())
                .onTapGesture { isPresented.toggle() }
                #if os(macOS)
                .onHover { inside in
                    overGlyph = inside
                    settle()
                }
                #endif
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    SourceTrailPopover(entries: entries, now: now, header: header, inCalendar: inCalendar, undo: undo.map { undo in
                        { @MainActor @Sendable in undo(); isPresented = false }
                    })
                    #if os(macOS)
                    .onHover { inside in
                        overPopover = inside
                        settle()
                    }
                    #endif
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { isPresented.toggle() }
        }
    }

    /// Opens after a short rest on the glyph, closes a moment after the pointer left both.
    private func settle() {
        pending?.cancel()
        let wanted = overGlyph || overPopover
        guard wanted != isPresented else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: wanted ? .milliseconds(350) : .milliseconds(250))
            guard !Task.isCancelled else { return }
            isPresented = wanted
        }
    }
}
