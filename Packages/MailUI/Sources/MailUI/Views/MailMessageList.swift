import StudyCore
import StudyUI
import SwiftUI

/// The message list (mockup 05, about 318 pt): sender and time, subject with the course dot at
/// the end, a one-line snippet, an unread dot, and at most one extra line where there is
/// something to act on. ↑/↓ select, ↩ opens (moves focus to the reader), Delete archives.
struct MailMessageList: View {
    let rows: [MailListItem]
    @Binding var selection: UUID?
    let now: Date
    let dates: MailDateText
    var isFocused: FocusState<Bool>.Binding
    let actions: MailListActions

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                MailListRow(row: row, now: now, dates: dates, actions: actions)
                    .tag(row.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .focused(isFocused)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                actions.menu(row)
            }
        } primaryAction: { ids in
            if let id = ids.first { actions.open(id) }
        }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            actions.open(selection)
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard let selection, actions.canArchive else { return .ignored }
            actions.archive(selection)
            return .handled
        }
    }
}

/// What the list's rows and keys can do (the screen's actions on one row).
@MainActor
struct MailListActions {
    var canArchive: Bool
    var open: (UUID) -> Void
    var archive: (UUID) -> Void
    var reply: (UUID) -> Void
    var toggleFlag: (MailListItem) -> Void
    var toggleSeen: (MailListItem) -> Void
    var confirmProposal: (TrackedItem.ID) -> Void
    var discardProposal: (TrackedItem.ID) -> Void
    var openLecture: (Lecture.ID) -> Void
    var changeFiling: (Filing.ID) -> Void
    /// No Reply Needed: clears the row's reply marker.
    var clearNeedsReply: (UUID) -> Void

    @ViewBuilder
    func menu(_ row: MailListItem) -> some View {
        if canArchive {
            Button("Reply") { reply(row.id) }
            if row.needsReply {
                Button("No Reply Needed") { clearNeedsReply(row.id) }
            }
            Divider()
            Button(row.isUnread ? "Mark as Read" : "Mark as Unread") { toggleSeen(row) }
            Button(row.isFlagged ? "Unflag" : "Flag") { toggleFlag(row) }
            Divider()
            Button("Archive") { archive(row.id) }
        }
    }
}

struct MailListRow: View {
    let row: MailListItem
    let now: Date
    let dates: MailDateText
    let actions: MailListActions

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(row.isUnread ? AnyShapeStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)) : AnyShapeStyle(.clear))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityLabel(row.isUnread ? Text("Unread") : Text(verbatim: ""))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.sender.isEmpty ? String(localized: "New Message") : row.sender)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.needsReply {
                        // Quiet: tertiary, no chip and no copy (the mail asks the student something).
                        Image(systemName: "arrowshape.turn.up.left")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(Text("Needs Reply"))
                    }
                    if row.isFlagged {
                        Image(systemName: "flag.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Flagged"))
                    }
                    time
                }
                HStack(spacing: 8) {
                    Text(row.subject.isEmpty ? String(localized: "No Subject") : row.subject)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let color = row.courseColor {
                        CourseDot(hex: color, size: 7)
                            .overlay {
                                if selected { Circle().strokeBorder(.white, lineWidth: 1.5).padding(-1.5) }
                            }
                    }
                }
                if !row.snippet.isEmpty {
                    Text(row.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let extra = row.extra {
                    ExtraLine(extra: extra, dates: dates, actions: actions)
                        .padding(.top, 3)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 9)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }

    private var time: some View {
        let label = dates.listLabel(row.date, now: now)
        return Text(label.text)
            .font(label.isClock ? .mailMono(11.5) : .system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The one extra line: a proposal chip, the lecture an LMS file went into, or why a draft
/// was not sent.
private struct ExtraLine: View {
    let extra: MailListExtra
    let dates: MailDateText
    let actions: MailListActions

    var body: some View {
        switch extra {
        case .proposal(let itemID, let kind, let room, let title):
            Menu {
                Button("Confirm") { actions.confirmProposal(itemID) }
                Button("Discard") { actions.discardProposal(itemID) }
            } label: {
                Label(Self.question(kind: kind, room: room, title: title), systemImage: "calendar")
                    .font(.system(size: 11))
            }
            .menuStyle(.button)
            .buttonStyle(ChipButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
        case .filed(let filingID, let lectureID, let number, let title, let date):
            HStack(spacing: 5) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(.tertiary)
                Menu {
                    Button("Open \(Self.lectureName(number: number, title: title))") { actions.openLecture(lectureID) }
                    Button("Change…") { actions.changeFiling(filingID) }
                } label: {
                    PickLabel(text: Self.lectureLabel(number: number, title: title, date: date, dates: dates))
                }
                .quietMenu()
            }
            .font(.system(size: 12))
        case .failed(let reason):
            Label(reason.isEmpty ? String(localized: "Not sent") : reason, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    static func question(kind: TrackedItemKind, room: String?, title: String) -> String {
        if kind == .roomChange, let room, !room.isEmpty { return String(localized: "Move to \(room)?") }
        return title
    }

    static func lectureName(number: Int?, title: String) -> String {
        if let number { return String(localized: "Lecture \(number)") }
        return title
    }

    /// "Lecture 2 · Tue 13 Oct".
    static func lectureLabel(number: Int?, title: String, date: Date?, dates: MailDateText) -> String {
        let name = lectureName(number: number, title: title)
        guard let date else { return name }
        return "\(name) · \(dates.day(date))"
    }
}

/// The quiet grey capsule of mockup 05's chips.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .labelStyle(ChipLabelStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(configuration.isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: Capsule())
    }
}

private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
