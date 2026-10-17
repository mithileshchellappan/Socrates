import StudyCore
import StudyUI
import SwiftUI

/// The reading pane (mockup 05): subject; avatar, sender and date; the To line with the route
/// as a menu; what was found (one quiet block with one sparkle); the body; attachments; and the
/// inline reply when a draft for this message is open.
///
/// Observes only this message's rows; the body is rendered once per message version (a sync
/// burst touching other mail re-reads the rows without parsing HTML again).
struct MailReaderView: View {
    let messageID: MailMessage.ID
    let now: Date
    let dates: MailDateText

    @Fetch private var data: MailReaderData
    private let database: (any DatabaseReader)?

    init(messageID: MailMessage.ID, blobRoot: URL?, now: Date, dates: MailDateText, database: (any DatabaseReader)?) {
        self.database = database
        self.messageID = messageID
        self.now = now
        self.dates = dates
        _data = Fetch(wrappedValue: MailReaderData(), MailReaderRequest(messageID: messageID, blobRoot: blobRoot), database: database)
    }

    var body: some View {
        if let message = data.message {
            ReaderScroll {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message.subject.isEmpty ? String(localized: "No Subject") : message.subject)
                        .font(.system(size: 17, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ReaderHeader(message: message, courses: data.courses, now: now, dates: dates)
                    if !data.found.isEmpty {
                        FoundBlock(rows: data.found, dates: dates)
                    }
                    MailBodyView(mailBody: data.body)
                    if !data.attachments.isEmpty {
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(data.attachments) { attachment in
                                AttachmentChip(attachment: attachment)
                            }
                        }
                    }
                    DraftSlot(replyingTo: message.id, database: database)
                }
                .padding(.top, 4)
                .padding(.horizontal, 26)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }
}

/// The reader's scroll view; focusable from the list (↩), where ↑/↓ and Space scroll it and
/// Escape goes back to the list.
private struct ReaderScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.mailFocus) private var focus
    @FocusState private var isFocused: Bool
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.contentOffset.y, height: geometry.containerSize.height)
        } action: { _, value in
            offset = value.width
            viewport = value.height
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: focus?.readerRequest) { _, request in
            if request != nil { isFocused = true }
        }
        .onKeyPress(.downArrow) { scroll(by: 40) }
        .onKeyPress(.upArrow) { scroll(by: -40) }
        .onKeyPress(.space) { scroll(by: max(40, viewport - 40)) }
        .onKeyPress(.escape) {
            focus?.listRequest = UUID()
            return .handled
        }
    }

    private func scroll(by amount: CGFloat) -> KeyPress.Result {
        position.scrollTo(y: max(0, offset + amount))
        return .handled
    }
}

/// Avatar, sender and date; To line and the route menu.
private struct ReaderHeader: View {
    let message: MailMessage
    let courses: [Course]
    let now: Date
    let dates: MailDateText

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(MailText.initials(message.fromName, address: message.fromAddress))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.from.displayName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if !message.fromName.isEmpty, !message.fromAddress.isEmpty {
                        Text(message.fromAddress)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(dates.readerLabel(message.sentAt ?? message.receivedAt, now: now))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    if !message.to.isEmpty {
                        Text("To: \(message.to.map(\.displayName).joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    RouteMenu(message: message, courses: courses)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// Where the message belongs, as a menu: one click to correct (the router learns a rule).
private struct RouteMenu: View {
    let message: MailMessage
    let courses: [Course]
    @Environment(\.mailActions) private var actions

    var body: some View {
        Menu {
            ForEach(courses) { course in
                Toggle(isOn: binding(.course(course.id))) {
                    Text(course.name)
                }
            }
            Divider()
            ForEach(MailCategory.routable, id: \.self) { category in
                Toggle(category.title, isOn: binding(.category(category)))
            }
        } label: {
            HStack(spacing: 5) {
                if let course = currentCourse {
                    CourseDot(course: course, size: 8)
                }
                Text(label)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    private var currentCourse: Course? {
        message.courseID.flatMap { id in courses.first { $0.id == id } }
    }

    private var label: String {
        if let currentCourse { return currentCourse.name }
        if let route = message.route, case .category(let category) = route { return category.title }
        return String(localized: "No Course")
    }

    private func binding(_ route: MailRoute) -> Binding<Bool> {
        Binding {
            message.route == route
        } set: { isOn in
            guard isOn, message.route != route else { return }
            let actions = actions
            let id = message.id
            Task {
                do {
                    try await actions.route(id, route)
                } catch {
                    Log.mail.error("Route correction failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}
