import StudyCore
import StudyUI
import SwiftUI

/// What the agent took from this mail: quiet rows under one sparkle (mockup 05). A deadline that
/// went into the calendar on its own shows "In Calendar" with Undo; one the mail did not confirm
/// well enough offers Add to Calendar; a room change or cancellation waits for Discard / Confirm;
/// an item tied to a session that is already in the calendar shows as in calendar, without Undo.
struct FoundBlock: View {
    let rows: [FoundRow]
    let dates: MailDateText

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AIMark()
                .frame(width: 16)
                .padding(.top, 7)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    FoundRowView(row: row, dates: dates)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FoundRowView: View {
    let row: FoundRow
    let dates: MailDateText

    @Environment(\.mailActions) private var actions
    @Environment(\.openDestination) private var openDestination
    @State private var isWorking = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(Self.text(for: row, dates: dates))
                    .foregroundStyle(isSettled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                if let lecture = row.lectureSource {
                    TimeChip(lecture.time, prefix: lecture.number.map { "L\($0)" }) {
                        openDestination(.lecture(lecture.lectureID, ReviewTarget(time: lecture.time, plays: true)))
                    }
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status
            trailing
                .frame(minWidth: 64, alignment: .trailing)
        }
        .frame(minHeight: 28)
        .disabled(isWorking)
    }

    private var isSettled: Bool {
        row.state == .undone || row.state == .discarded
    }

    @ViewBuilder
    private var status: some View {
        switch row.state {
        case .inCalendar:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                Text("In Calendar")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize()
        case .addable:
            FoundButton(title: "Add to Calendar", systemImage: "calendar.badge.plus") {
                try await actions.addToCalendar(row.item.id)
            }
        case .proposal:
            FoundButton(title: "Discard", systemImage: nil, prominent: false) {
                try await actions.discardProposal(row.item.id)
            }
        case .undone, .discarded, .info:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .inCalendar(undoable: true):
            FoundButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                try await actions.undo(row.source.id)
            }
        case .proposal:
            FoundButton(title: "Confirm", systemImage: nil) {
                try await actions.confirmProposal(row.item.id)
            }
        case .undone:
            FoundButton(title: "Restore", systemImage: "arrow.uturn.forward") {
                try await actions.restore(row.source.id)
            }
        default:
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// "CL exercise sheet 1 due **Thu 29 Oct, 23:59**", "Lecture 4 **Tue 20 Oct, 16:15** in Room 5".
    static func text(for row: FoundRow, dates: MailDateText) -> AttributedString {
        let item = row.item
        var prefix = item.title
        var suffix: String?
        let session = row.session.map { Self.sessionName($0) }
        switch item.kind {
        case .deadline, .exercise, .exam:
            if item.dueAt != nil { prefix = String(localized: "\(item.title) due") }
        case .roomChange:
            if let session, let room = item.room, !room.isEmpty {
                prefix = session
                suffix = String(localized: "in \(room)")
            }
        case .cancellation:
            if let session {
                prefix = session
                suffix = String(localized: "cancelled")
            }
        default:
            break
        }
        var text = AttributedString(prefix)
        if let due = item.dueAt {
            let parts = dates.due(due, allDay: item.isAllDay)
            text += AttributedString(" ")
            var day = AttributedString(parts.day)
            day.inlinePresentationIntent = .stronglyEmphasized
            text += day
            if let time = parts.time {
                var comma = AttributedString(", ")
                comma.inlinePresentationIntent = .stronglyEmphasized
                text += comma
                var clock = AttributedString(time)
                clock[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: 12, weight: .semibold, design: .monospaced)
                text += clock
            }
        }
        if let suffix { text += AttributedString(" \(suffix)") }
        if row.state == .undone || row.state == .discarded {
            for run in text.runs {
                text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.strikethrough)
            }
        }
        return text
    }

    /// "Lecture 4", "Tutorial 1", "Exercise" (no number).
    static func sessionName(_ session: LectureSession) -> String {
        let kind: String = switch session.kind {
        case .exercise: String(localized: "Exercise")
        case .tutorial: String(localized: "Tutorial")
        case .seminar: String(localized: "Seminar")
        default: String(localized: "Lecture")
        }
        guard let number = session.number else { return kind }
        return "\(kind) \(number)"
    }
}

/// A plain accent-coloured action of a found row; runs once at a time.
private struct FoundButton: View {
    let title: LocalizedStringKey
    let systemImage: String?
    var prominent = true
    let action: @Sendable () async throws -> Void

    @State private var isRunning = false

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                do {
                    try await action()
                } catch {
                    Log.mail.error("Found item action failed: \(error.localizedDescription, privacy: .private)")
                }
                isRunning = false
            }
        } label: {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
                Text(title)
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(isRunning)
    }
}
