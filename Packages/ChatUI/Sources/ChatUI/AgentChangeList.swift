import StudyCore
import StudyUI
import SwiftUI

// The activity log in an answer (ma, docs/plan-agent.md §6, mockup §3): each `[[change …]]` the
// agent cites is one row [the item as Today and Calendar name it | grey "Moved to Room 5 · Wed 21
// Oct" + the source glyph | the time it was applied, mono]; hovering a row opens its source with
// the exact quote and Undo. A marker that names no change (or two) is left out.

/// One cited change with its source as the popover shows it.
struct AgentChangeRow: Hashable, Sendable {
    var change: AgentChange
    var entry: SourceTrailEntry
}

/// The changes a run of markers names, by key; read again when the log changes (Undo).
struct AgentChangeRowsRequest: FetchKeyRequest {
    let keys: [String]

    func fetch(_ db: Database) throws -> [String: AgentChangeRow] {
        var rows: [String: AgentChangeRow] = [:]
        for key in keys {
            let key = key.lowercased()
            guard key.count == 8, key.allSatisfy(\.isHexDigit) else { continue }
            // GLOB (case-sensitive; ids are stored lowercased) lets SQLite use the primary key's
            // index for the prefix; LIKE scanned the whole log.
            let ids = try String.fetchAll(db, sql: #"SELECT "id" FROM "agent_change" WHERE "id" GLOB ? LIMIT 2"#, arguments: [key + "*"])
            guard ids.count == 1, let id = UUID(uuidString: ids[0]), let change = try AgentChange.find(id).fetchOne(db) else { continue }
            rows[key] = AgentChangeRow(change: change, entry: try Self.entry(change, db: db))
        }
        return rows
    }

    /// The change's source: the item source written with it (its full popover facts), else one
    /// built from the change's own columns.
    static func entry(_ change: AgentChange, db: Database) throws -> SourceTrailEntry {
        if let sourceID = change.trackedItemSourceID, let source = try TrackedItemSource.find(sourceID).fetchOne(db),
           var entry = try TrackedItemRepository.trails(itemIDs: [source.trackedItemID], in: db)[source.trackedItemID]?.first(where: { $0.id == sourceID }) {
            // An undone change still shows what it was read from.
            entry.source.undoneAt = nil
            return entry
        }
        let source = TrackedItemSource(
            id: change.id, trackedItemID: change.targetID ?? change.id, kind: change.sourceKind, mailMessageID: change.mailMessageID,
            rfcMessageID: change.rfcMessageID, lectureID: change.lectureID, recordingID: change.recordingID, time: change.time,
            quote: change.quote, confidence: change.confidence, conversationID: change.conversationID,
            createdAt: change.appliedAt, updatedAt: change.updatedAt
        )
        var entry = SourceTrailEntry(source: source)
        if change.sourceKind == .mail {
            let rfcID = change.rfcMessageID
            let message: MailMessage? = if let id = change.mailMessageID {
                try MailMessage.find(id).fetchOne(db)
            } else if !rfcID.isEmpty {
                try MailMessage.where { $0.rfcMessageID.eq(rfcID) }.fetchOne(db)
            } else {
                nil
            }
            if let message {
                entry.senderName = message.fromName
                entry.senderAddress = message.fromAddress
                entry.receivedAt = message.receivedAt
            }
        }
        if let lectureID = change.lectureID, let lecture = try Lecture.find(lectureID).fetchOne(db) {
            entry.lectureNumber = lecture.number
            entry.lectureTitle = lecture.title
            entry.lectureHeldAt = lecture.heldAt
            entry.professors = try Course.find(lecture.courseID).fetchOne(db)?.professors ?? []
        }
        return entry
    }
}

/// A run of change markers as one list: ONE sparkle in its own column (when the list starts the
/// answer; else the rows' text starts at the answer's text edge), rows separated by hairlines.
struct AgentChangeList: View {
    let keys: [String]
    let showsSparkle: Bool
    let now: Date

    @Fetch private var rows: [String: AgentChangeRow]
    @State private var hovered: AgentChange.ID?

    init(keys: [String], showsSparkle: Bool, now: Date) {
        self.keys = keys
        self.showsSparkle = showsSparkle
        self.now = now
        _rows = Fetch(wrappedValue: [:], AgentChangeRowsRequest(keys: keys))
    }

    var body: some View {
        let shown = keys.compactMap { rows[$0.lowercased()] }
        if !shown.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                if showsSparkle {
                    AnswerSparkle()
                        .frame(width: 16)
                        .padding(.top, 4)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.change.id) { index, row in
                        let quiet = hovered == row.change.id || (index > 0 && hovered == shown[index - 1].change.id)
                        if index > 0 {
                            Hairline()
                                .padding(.horizontal, 8)
                                .opacity(quiet ? 0 : 1)
                        }
                        AgentChangeRowView(row: row, now: now, hovered: $hovered)
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

/// [title 13 primary | grey summary + source glyph | mono time]; hover (tap on iOS) opens the
/// source with the exact quote and Undo.
private struct AgentChangeRowView: View {
    let row: AgentChangeRow
    let now: Date
    @Binding var hovered: AgentChange.ID?

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @State private var isPresented = false
    @State private var overRow = false
    @State private var overPopover = false
    @State private var pending: Task<Void, Never>?

    private var change: AgentChange { row.change }
    private var isUndone: Bool { change.undoneAt != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: change.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isUndone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .strikethrough(isUndone)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: 18)
                HStack(spacing: 4) {
                    Self.summary(change.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(isUndone ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    Image(systemName: Self.glyph(change.sourceKind))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 3)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 16)
            }
            Spacer(minLength: 0)
            appliedText
                .foregroundStyle(.tertiary)
                .frame(minHeight: 18)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            hovered == change.id || isPresented ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { isPresented.toggle() }
        #if os(macOS)
        .onHover { inside in
            overRow = inside
            if inside {
                hovered = change.id
            } else if hovered == change.id {
                hovered = nil
            }
            settle()
        }
        #endif
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            SourceTrailPopover(entries: [row.entry], now: now, inCalendar: false, undo: isUndone ? nil : undo)
            #if os(macOS)
            .onHover { inside in
                overPopover = inside
                settle()
            }
            #endif
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isPresented.toggle() }
    }

    /// When it was applied, as the Notes list says it (DESIGN 9): "14:08" (mono) today, then
    /// "Yesterday", the weekday within the week, "Tue 13 Oct".
    private var appliedText: Text {
        let today = CalendarDay(now, in: timeZone)
        let day = CalendarDay(change.appliedAt, in: timeZone)
        if day.days(to: today) <= 0 {
            return Text(verbatim: DayText.time(change.appliedAt, timeZone: timeZone))
                .font(.mono(11))
                .monospacedDigit()
        }
        let title = HistoryDay.title(day, today: today, date: change.appliedAt, locale: locale, timeZone: timeZone)
        return Text(verbatim: title).font(.system(size: 11.5))
    }

    private var undo: @MainActor () -> Void {
        let actions = actions
        let id = change.id
        return {
            isPresented = false
            Task {
                do {
                    try await actions.undoChange(id)
                } catch {
                    ChatUILog.ui.error("Undoing a change failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Opens after a short rest on the row, closes a moment after the pointer left both.
    private func settle() {
        pending?.cancel()
        let wanted = overRow || overPopover
        guard wanted != isPresented else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: wanted ? .milliseconds(350) : .milliseconds(250))
            guard !Task.isCancelled else { return }
            isPresented = wanted
        }
    }

    /// The summary with its clock times in SF Mono ("Added · Mon 19 Oct, 12:00").
    static func summary(_ text: String) -> Text {
        var result = Text(verbatim: "")
        var rest = text[...]
        while let match = rest.firstMatch(of: /\d{1,2}:\d{2}/) {
            result = Text("\(result)\(Text(verbatim: String(rest[..<match.range.lowerBound])))\(Text(verbatim: String(match.output)).font(.mono(11.5)))")
            rest = rest[match.range.upperBound...]
        }
        return Text("\(result)\(Text(verbatim: String(rest)))").monospacedDigit()
    }

    /// The source's glyph: a mail, what the student said, a recording, a timetable or calendar.
    static func glyph(_ kind: SourceRef.Kind) -> String {
        switch kind {
        case .mail: "envelope"
        case .chat: "bubble.left"
        case .timetable, .calendar: "calendar"
        case .transcript: "waveform"
        case .slide: "display"
        default: "doc.text"
        }
    }
}
