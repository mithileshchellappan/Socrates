import Foundation
import StudyCore

/// ma: how the activity log (`agent_change`) words dates: "Wed 21 Oct", "Tue 20 Oct, 12:15"
/// (the university's time zone), as the panel's change rows and Today show them (DESIGN 9 strings).
public enum ChangeSummary {
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Wed 21 Oct".
    public static func day(_ date: Date, timeZone: TimeZone = DeadlinesModule.timeZone) -> String {
        let parts = Calendar.gregorian(in: timeZone).dateComponents([.weekday, .day, .month], from: date)
        return "\(weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]) \(parts.day ?? 1) \(months[((parts.month ?? 1) - 1 + 12) % 12])"
    }

    /// "Tue 20 Oct, 12:15", or the day alone for an all-day date.
    public static func dayTime(_ date: Date, allDay: Bool = false, timeZone: TimeZone = DeadlinesModule.timeZone) -> String {
        guard !allDay else { return day(date, timeZone: timeZone) }
        let minute = DateMentions.minute(of: date, timeZone: timeZone)
        return day(date, timeZone: timeZone) + String(format: ", %02d:%02d", minute / 60, minute % 60)
    }

    /// "10:15".
    public static func time(_ date: Date, timeZone: TimeZone = DeadlinesModule.timeZone) -> String {
        let minute = DateMentions.minute(of: date, timeZone: timeZone)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

/// ma: the activity-log row of what one `DeadlineMemory` write did, for the writers that record
/// findings in their own transaction (mail triage, transcript extraction, AppAgent's change log):
/// an item added ("Added · Mon 19 Oct, 12:00"), moved ("Moved to Tue 20 Oct, 12:15"), done or
/// updated. Undo of the row is the item source's Undo (`tracked_item_source_id`).
public enum ItemChangeRows {
    /// The row for `result` (nil when the write changed nothing: a repeat that only added a
    /// source, or this source had said it already).
    public static func change(
        for result: RecordResult, finding: ItemFinding, model: String, eventID: AgentEvent.ID? = nil, taskID: AgentTask.ID? = nil,
        now: Date
    ) -> AgentChange? {
        guard let source = result.source else { return nil }
        let item = result.item
        let kind: AgentChangeKind
        let summary: String
        let before: AgentChangeValues
        if result.created {
            kind = .itemAdd
            summary = item.dueAt.map { "Added · " + ChangeSummary.dayTime($0, allDay: item.isAllDay) } ?? "Added"
            before = AgentChangeValues(exists: false)
        } else if let previous = source.previous {
            before = AgentChangeValues(exists: true, item: previous)
            if previous.dueAt != item.dueAt || previous.isAllDay != item.isAllDay, let due = item.dueAt {
                kind = .itemMove
                summary = "Moved to " + ChangeSummary.dayTime(due, allDay: item.isAllDay)
            } else if previous.status != item.status, item.status == .done {
                kind = .itemDone
                summary = "Done"
            } else {
                kind = .itemUpdate
                summary = item.status == .open && previous.status != .open ? "Reopened" : "Updated"
            }
        } else {
            return nil
        }
        return row(
            kind: kind, item: item, summary: summary, before: before, finding: finding, source: source, model: model,
            eventID: eventID, taskID: taskID, now: now
        )
    }

    /// The row of a change to `item` written with `source`.
    public static func row(
        kind: AgentChangeKind, item: TrackedItem, summary: String, before: AgentChangeValues, finding: ItemFinding,
        source: TrackedItemSource?, model: String, eventID: AgentEvent.ID? = nil, taskID: AgentTask.ID? = nil, now: Date
    ) -> AgentChange {
        var change = AgentChange(
            kind: kind, targetTable: .item, targetID: item.id, title: item.title, summary: summary, before: before,
            after: AgentChangeValues(exists: true, item: TrackedItemSnapshot(item)), sourceKind: .chat, taskID: taskID,
            eventID: eventID, quote: finding.quote, confidence: finding.confidence, model: model, apiCallID: finding.apiCallID,
            trackedItemSourceID: source?.id, appliedAt: now, createdAt: now, updatedAt: now
        )
        apply(finding.source, to: &change)
        return change
    }

    /// The source columns of a change row from a finding's source.
    public static func apply(_ source: ItemFinding.Source, to change: inout AgentChange) {
        switch source {
        case .mail(let id, let rfcMessageID):
            change.sourceKind = .mail
            change.mailMessageID = id
            change.rfcMessageID = rfcMessageID
        case .transcript(let lectureID, let recordingID, let time):
            change.sourceKind = .transcript
            change.lectureID = lectureID
            change.recordingID = recordingID
            change.time = time
        case .chat(let conversationID):
            change.sourceKind = .chat
            change.conversationID = conversationID
        case .external(let kind, let reference):
            change.sourceKind = kind
            change.rfcMessageID = reference
        }
    }
}
