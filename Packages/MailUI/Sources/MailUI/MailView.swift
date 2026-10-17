import StudyCore
import StudyUI
import SwiftUI

/// The Mail screen (PRD #30–#35, mockup 05): the message list (about 318 pt) and the reader,
/// with the toolbar's Reply / Archive / Flag and New Message. Reads rows itself; every effect
/// goes through `\.mailActions` (the screen never sends or talks to a server). The app installs
/// `\.mailActions`, `\.studyServices`, SQLiteData's default database and `MailCommands`.
///
/// - `scope`: Inbox, a course (Inbox + Archive), University, Newsletters, Drafts, Sent.
/// - `selection`: the selected message (in Drafts, the selected draft's id).
/// - `query`: the window's search field ("Search mail"); filters through `MailActions.search`.
/// - `now`: a fixed "now" (snapshots); nil follows the clock.
///
/// Without a mail account it shows only Set Up Mail…. Selecting an unread message marks it read
/// after a short dwell. Keys: ↑/↓ select, ↩ moves focus into the reader (↑/↓ and Space scroll,
/// Escape goes back), Delete archives; the Message menu (`MailCommands`) has the rest.
public struct MailView: View {
    private let scope: MailScope
    @Binding private var selection: MailMessage.ID?
    private let query: String
    private let fixedNow: Date?

    @Fetch private var list: MailListData
    private let coursesQuery: FetchAll<Course>
    private var courses: [Course] { coursesQuery.wrappedValue }
    @State private var loadedRequest: MailListRequest
    @State private var searchIDs: [UUID]?
    /// A new message being written (shown in the reader zone).
    @State private var composingDraftID: MailDraft.ID?
    @State private var clock = Date()
    @State private var focus = MailFocus()
    @FocusState private var listFocused: Bool

    @Environment(\.mailActions) private var actions
    /// The database the screen was created with (SQLiteData's default): child views read it too.
    @Dependency(\.defaultDatabase) private var database
    @Environment(\.studyServices) private var services
    @Environment(\.mailChrome) private var chrome
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    @Environment(\.openDestination) private var openDestination
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Seconds a selected unread message stays selected before it is marked read.
    static let readDwell: Duration = .milliseconds(800)

    public init(scope: MailScope, selection: Binding<MailMessage.ID?>, query: String = "", now: Date? = nil) {
        self.scope = scope
        _selection = selection
        self.query = query
        fixedNow = now
        let request = MailListRequest(scope: scope, searchIDs: nil)
        _list = Fetch(wrappedValue: MailListData(), request)
        _loadedRequest = State(initialValue: request)
        coursesQuery = FetchAll(Course.order { ($0.sortOrder, $0.name) })
    }

    private var now: Date { fixedNow ?? clock }
    private var dates: MailDateText { MailDateText(locale: locale, timeZone: timeZone) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: MailListRequest {
        MailListRequest(scope: scope, searchIDs: trimmedQuery.isEmpty ? nil : searchIDs)
    }

    private var title: String {
        scope.title(courses: Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    private var selectedRow: MailListItem? {
        guard let selection else { return nil }
        return list.rows.first { $0.id == selection }
    }

    /// The selected row is a message (not a draft) the toolbar can act on.
    private var selectedMessage: MailListItem? {
        scope == .drafts || composingDraftID != nil ? nil : selectedRow
    }

    public var body: some View {
        content
            .screenTitle(title, leadingInset: ScreenTitleInset.firstItem)
            .toolbar { toolbar }
            .environment(\.mailFocus, focus)
            .focusedSceneValue(\.mailScreen, commands)
            .task(id: request) {
                guard request != loadedRequest else { return }
                loadedRequest = request
                _ = try? await $list.load(request, database: database)
            }
            .task(id: SearchKey(query: trimmedQuery, scope: scope)) { await search() }
            .task(id: selection) { await markReadAfterDwell() }
            .task(id: fixedNow == nil) { await followClock() }
            .onChange(of: scope) {
                composingDraftID = nil
            }
            .onChange(of: focus.listRequest) {
                listFocused = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch list.hasAccount {
        case nil:
            Color.clear
        case false?:
            noAccount
        case true?:
            VStack(spacing: 0) {
                if chrome == .snapshot {
                    SnapshotToolbar(title: title, isFlagged: selectedMessage?.isFlagged == true)
                }
                split
            }
        }
    }

    private var noAccount: some View {
        ContentUnavailableView {
            Image(systemName: "envelope")
        } actions: {
            Button("Set Up Mail…", action: setUpMail)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var split: some View {
        #if os(iOS)
        if sizeClass == .compact {
            messageList
                .navigationDestination(item: $selection) { _ in reader }
        } else {
            wideSplit
        }
        #else
        wideSplit
        #endif
    }

    private var wideSplit: some View {
        HStack(spacing: 0) {
            messageList
                .frame(width: 318)
            Divider()
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var messageList: some View {
        MailMessageList(
            rows: list.rows,
            selection: Binding(get: { selection }, set: { id in
                // A message asked for from elsewhere (a search hit, a deadline's source) may not
                // be among the rows yet (they load after the screen opens, or it is in another
                // list): the list's clearing of a selection it does not know is ignored.
                if id == nil, let current = selection, !list.rows.contains(where: { $0.id == current }) { return }
                composingDraftID = nil
                selection = id
            }),
            now: now,
            dates: dates,
            isFocused: $listFocused,
            actions: listActions
        )
        .overlay {
            if !trimmedQuery.isEmpty, searchIDs != nil, list.rows.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    @ViewBuilder
    private var reader: some View {
        if let composingDraftID {
            ScrollView {
                DraftSlot(draftID: composingDraftID, database: database)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
            }
            .id(composingDraftID)
        } else if scope == .drafts, let selection {
            DraftReader(draftID: selection, blobRoot: services?.blobs.root, now: now, dates: dates, database: database)
                .id(selection)
        } else if let selection {
            MailReaderView(messageID: selection, blobRoot: services?.blobs.root, now: now, dates: dates, database: database)
                .id(selection)
        } else {
            Color.clear
        }
    }

    // MARK: Toolbar and commands

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                if let id = selectedMessage?.id { reply(to: id) }
            }
            .disabled(selectedMessage == nil || scope == .sent)
            Button("Archive", systemImage: "archivebox") {
                if let id = selectedMessage?.id { archive(id) }
            }
            .disabled(!canArchive)
            Button(selectedMessage?.isFlagged == true ? "Unflag" : "Flag",
                   systemImage: selectedMessage?.isFlagged == true ? "flag.slash" : "flag") {
                if let row = selectedMessage { toggleFlag(row) }
            }
            .disabled(selectedMessage == nil)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("New Message", systemImage: "square.and.pencil", action: newMessage)
                .disabled(list.accountID == nil)
        }
    }

    private var canArchive: Bool {
        selectedMessage != nil && scope != .sent && scope != .drafts
    }

    private var commands: MailScreenCommands {
        let row = selectedMessage
        return MailScreenCommands(
            canCompose: list.accountID != nil,
            canReply: row != nil && scope != .sent,
            canArchive: canArchive,
            hasSelection: row != nil,
            isFlagged: row?.isFlagged == true,
            isUnread: row?.isUnread == true,
            isEditingText: focus.isEditingText || isSearchFieldFocused,
            newMessage: newMessage,
            getMail: { Task { await actions.syncNow() } },
            reply: { if let id = row?.id { reply(to: id) } },
            archive: { if let id = row?.id { archive(id) } },
            toggleFlag: { if let row { toggleFlag(row) } },
            toggleSeen: { if let row { toggleSeen(row) } }
        )
    }

    private var listActions: MailListActions {
        MailListActions(
            canArchive: scope != .sent && scope != .drafts,
            open: open,
            archive: archive,
            reply: reply(to:),
            toggleFlag: toggleFlag,
            toggleSeen: toggleSeen,
            confirmProposal: { id in perform { try await actions.confirmProposal(id) } },
            discardProposal: { id in perform { try await actions.discardProposal(id) } },
            openLecture: { id in openDestination(.lecture(id)) },
            changeFiling: { id in Task { await actions.changeFiling(id) } }
        )
    }

    // MARK: Actions

    /// ↩ or a double click: into the reader (a draft's editor in Drafts).
    private func open(_ id: UUID) {
        selection = id
        if scope == .drafts {
            focus.editorRequest = id
        } else {
            focus.readerRequest = UUID()
        }
    }

    private func archive(_ id: MailMessage.ID) {
        if selection == id { selection = neighbour(of: id) }
        perform { try await actions.archive(id) }
    }

    private func toggleFlag(_ row: MailListItem) {
        perform { try await actions.setFlagged(row.id, !row.isFlagged) }
    }

    private func toggleSeen(_ row: MailListItem) {
        perform { try await actions.setSeen([row.id], row.isUnread) }
    }

    /// Reply: the agent drafts into a new reply that appears under the message at once; without
    /// the agent (no key, not wired, an error) an empty reply opens for the student to write.
    private func reply(to id: MailMessage.ID) {
        let actions = actions
        let services = services
        let focus = focus
        Task {
            if let services, let open = try? await MailDraftRepository(store: services.records).openDraft(replyingTo: id) {
                focus.editorRequest = open.id
                return
            }
            do {
                focus.editorRequest = try await actions.draftReply(id)
            } catch {
                guard let services else { return }
                do {
                    focus.editorRequest = try await DraftFactory.reply(to: id, services: services)
                } catch {
                    Log.mail.error("Could not start a reply: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// New Message: an empty draft without the agent, written in the reader zone.
    private func newMessage() {
        guard let services, let accountID = list.accountID else { return }
        let focus = focus
        Task {
            do {
                let id = try await DraftFactory.newMessage(accountID: accountID, courseID: scope.courseID, services: services)
                composingDraftID = id
                focus.editorRequest = id
            } catch {
                Log.mail.error("Could not start a message: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func setUpMail() {
        if let open = actions.openAccountSettings {
            open()
            return
        }
        #if os(macOS)
        openSettings()
        #endif
    }

    private func perform(_ work: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                Log.mail.error("Mail action failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// The row after `id` (else before it), where the selection goes when `id` leaves the list.
    private func neighbour(of id: UUID) -> UUID? {
        guard let index = list.rows.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < list.rows.count { return list.rows[index + 1].id }
        return index > 0 ? list.rows[index - 1].id : nil
    }

    // MARK: Tasks

    private struct SearchKey: Hashable {
        var query: String
        var scope: MailScope
    }

    private func search() async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            searchIDs = nil
            return
        }
        do {
            let ids = try await actions.search(query, scope)
            guard !Task.isCancelled else { return }
            searchIDs = ids
        } catch {
            searchIDs = []
        }
    }

    private func markReadAfterDwell() async {
        guard scope != .drafts, let id = selection, selectedRow?.isUnread == true else { return }
        try? await Task.sleep(for: Self.readDwell)
        guard !Task.isCancelled, selection == id else { return }
        do {
            try await actions.setSeen([id], true)
        } catch {
            Log.mail.error("Marking read failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Keeps "13:37" / "Yesterday" right across midnight.
    private func followClock() async {
        guard fixedNow == nil else { return }
        while !Task.isCancelled {
            let current = Date()
            clock = current
            let tomorrow = CalendarDay(current, in: timeZone).adding(days: 1).start(in: timeZone)
            try? await Task.sleep(for: .seconds(max(1, tomorrow.timeIntervalSince(current) + 1)))
        }
    }
}

extension MailScope {
    /// The course of a course scope (a new message there is about it).
    var courseID: Course.ID? {
        if case .course(let id) = self { return id }
        return nil
    }
}

/// Drafts the screen writes itself (local rows; only the Send button sends).
enum DraftFactory {
    /// An empty reply the student writes alone: To = Reply-To ?? From, "Re: …", threading.
    static func reply(to messageID: MailMessage.ID, services: StudyServices) async throws -> MailDraft.ID? {
        guard let message = try await MailRepository(store: services.records).message(messageID) else { return nil }
        let recipients = message.replyTo.isEmpty ? [message.from] : message.replyTo
        let references = (message.referenceIDs + [message.rfcMessageID]).filter { !$0.isEmpty }
        let draft = try await services.records.save(MailDraft(
            accountID: message.accountID, mailMessageID: message.id, inReplyTo: message.rfcMessageID,
            referenceIDs: references, to: recipients, subject: MailText.replySubject(message.subject),
            courseID: message.courseID, state: .draft
        ))
        return draft.id
    }

    /// An empty new message.
    static func newMessage(accountID: MailAccount.ID, courseID: Course.ID?, services: StudyServices) async throws -> MailDraft.ID {
        try await services.records.save(MailDraft(accountID: accountID, courseID: courseID, state: .draft)).id
    }
}

/// A draft selected in Drafts: a reply shows under its message, a new message alone.
private struct DraftReader: View {
    let draftID: MailDraft.ID
    let blobRoot: URL?
    let now: Date
    let dates: MailDateText
    private let draftQuery: FetchAll<MailDraft>
    private let database: (any DatabaseReader)?

    init(draftID: MailDraft.ID, blobRoot: URL?, now: Date, dates: MailDateText, database: (any DatabaseReader)?) {
        self.database = database
        self.draftID = draftID
        self.blobRoot = blobRoot
        self.now = now
        self.dates = dates
        draftQuery = FetchAll(MailDraft.where { $0.id.eq(draftID) }, database: database)
    }

    var body: some View {
        if let draft = draftQuery.wrappedValue.first {
            if let messageID = draft.mailMessageID {
                MailReaderView(messageID: messageID, blobRoot: blobRoot, now: now, dates: dates, database: database)
            } else {
                ScrollView {
                    DraftSlot(draftID: draft.id, database: database)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                }
            }
        }
    }
}

/// The window toolbar drawn inline for snapshots (title, Reply / Archive / Flag, New Message,
/// the app's search field).
private struct SnapshotToolbar: View {
    let title: String
    let isFlagged: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 0) {
                glyph("arrowshape.turn.up.left")
                glyph("archivebox")
                glyph(isFlagged ? "flag.slash" : "flag")
            }
            .modifier(MailGlass(shape: Capsule()))
            glyph("square.and.pencil")
                .modifier(MailGlass(shape: Capsule()))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search mail")
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(width: 220, height: 30)
            .modifier(MailGlass(shape: Capsule()))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 34, height: 30)
    }
}
