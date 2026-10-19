import Deadlines
import Foundation
import StudyCore
#if os(macOS)
import UserNotifications
#endif

/// The agent's reminders (docs/plan-agent.md §4 "Reminders"): `agent_reminder` rows delivered as
/// macOS local notifications at `fire_at` (title = the item as Today names it, body = "Wed 21
/// Oct, 23:59 · Data Centers"); no UI of their own. Inert on iOS.
///
/// - Planned on their own (through the change log, so they are listed and undoable): an item
///   relevant for exam admission gets reminders 24 h and 2 h before it closes; a registration
///   window (a deadline whose title or details say register / Anmeldung) the day before.
/// - Authorization is asked when the first reminder is due to be scheduled.
/// - Cancelled reminders (Undo of their change, the item done, moved or undone) never fire.
/// - `AppAgent` follows `agent_reminder` (a reminder set, moved or cancelled anywhere checks
///   again); the timer always waits for the next reminder, however far away.
/// - Never stale: a reminder more than an hour late (the Mac was off), or whose item is no longer
///   open, has no date, closes before it, or (an automatic one) moved since it was planned, is
///   cancelled instead of shown.
actor ReminderCenter {
    let services: StudyServices
    let changeLog: ChangeLog
    let now: @Sendable () -> Date
    private var timer: Task<Void, Never>?
    private var authorized: Bool?
    /// One check at a time (wake, the `agent_reminder` observation its own writes fire, and the
    /// timer all call it); a call meanwhile runs it once more after.
    private var checking = false
    private var checkAgain = false
    /// Reminders being handed to the notification center (never added twice).
    private var delivering: Set<AgentReminder.ID> = []

    init(services: StudyServices, changeLog: ChangeLog, now: @escaping @Sendable () -> Date) {
        self.services = services
        self.changeLog = changeLog
        self.now = now
    }

    var reminders: AgentReminderRepository { AgentReminderRepository(store: services.records) }

    /// The source kind of the reminders planned here (their change rows).
    static let automatic = SourceRef.Kind(rawValue: "agent")
    /// The planned offsets before an item's date (exam admission: both; a registration: the day).
    static let offsets: [TimeInterval] = [24 * 3_600, 2 * 3_600]
    /// A reminder later than this is not shown any more.
    static let lateness: TimeInterval = 3_600

    /// Plans the automatic reminders, delivers what is due and sleeps until the next one.
    func check() async {
        #if os(macOS)
        if checking {
            checkAgain = true
            return
        }
        checking = true
        repeat {
            checkAgain = false
            do {
                try await planAutomatic()
                try await deliverDue()
                try await scheduleNext()
            } catch {
                AppAgentModule.log.error("Reminders failed: \(String(describing: error), privacy: .public)")
            }
        } while checkAgain
        checking = false
        #endif
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Planning

    /// Exam-admission items: 24 h and 2 h before; registration windows: the day before.
    func planAutomatic() async throws {
        let date = now()
        let rows = try await services.database.read { db in
            (
                items: try TrackedItem
                    .where { $0.status.eq(TrackedItemStatus.open) && $0.dueAt.gt(Date?.some(date)) }
                    .fetchAll(db),
                reminders: try AgentReminder.where { $0.trackedItemID.isNot(nil) }.fetchAll(db),
                undone: try AgentChange
                    .where { $0.targetTable.eq(AgentChangeTarget.reminder) && $0.undoneAt.isNot(nil) }
                    .fetchAll(db).compactMap(\.targetID),
                courses: try Course.all.fetchAll(db)
            )
        }
        let names = Dictionary(rows.courses.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // A reminder the student undid is never planned again; one cancelled because its item
        // moved, was done or undone may be planned again when the item comes back to that moment.
        let undone = Set(rows.undone)
        let standing = rows.reminders.filter { $0.cancelledAt == nil || undone.contains($0.id) }
        let existing = Dictionary(grouping: standing, by: { $0.trackedItemID })
        for item in rows.items where !item.kind.isSessionChange && !item.kind.isSessionProposal {
            guard let due = item.dueAt else { continue }
            var offsets: [TimeInterval] = []
            if item.relevance == .examAdmission { offsets = [24 * 3_600, 2 * 3_600] }
            let words = TextFolding.fold(item.title + " " + item.details)
            if offsets.isEmpty, item.kind.isDue, ["regist", "anmeld", "einschreib"].contains(where: words.contains) { offsets = [24 * 3_600] }
            guard !offsets.isEmpty else { continue }
            let known = existing[item.id] ?? []
            for offset in offsets {
                let fire = due.addingTimeInterval(-offset)
                guard fire > date.addingTimeInterval(60) else { continue }
                // Planned once per moment: a cancelled one (Undo) is never planned again.
                guard !known.contains(where: { abs($0.fireAt.timeIntervalSince(fire)) < 60 }) else { continue }
                let body = ChangeSummary.dayTime(due, allDay: item.isAllDay) + (item.courseID.flatMap { names[$0] }.map { " · \($0)" } ?? "")
                let quote = item.sourceQuote.isEmpty ? item.title : item.sourceQuote
                let origin = ChangeLog.Origin(source: .external(Self.automatic, reference: item.id.uuidString.lowercased()), sourceDate: date, model: "")
                _ = try await changeLog.apply(
                    .reminder(itemID: item.id, courseID: item.courseID, title: item.title, body: body, fireAt: fire), quote: quote, origin: origin
                )
            }
        }
    }

    // MARK: Delivery

    func deliverDue() async throws {
        let date = now()
        var due: [AgentReminder] = []
        for reminder in try await reminders.pending(before: date.addingTimeInterval(30)) {
            if try await isStale(reminder, now: date) {
                try await reminders.cancel(reminder.id)
            } else {
                due.append(reminder)
            }
        }
        guard !due.isEmpty else { return }
        #if os(macOS)
        guard await authorize() else { return }
        let center = UNUserNotificationCenter.current()
        for reminder in due where !delivering.contains(reminder.id) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: reminder.notificationID, content: content, trigger: nil)
            // Held before the notification is added: no other pass adds it meanwhile.
            delivering.insert(reminder.id)
            defer { delivering.remove(reminder.id) }
            do {
                try await center.add(request)
                try await reminders.markDelivered(reminder.id)
            } catch {
                AppAgentModule.log.error("A reminder could not be shown: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    /// Whether a due reminder should not be shown any more (it is cancelled instead).
    func isStale(_ reminder: AgentReminder, now date: Date) async throws -> Bool {
        if date.timeIntervalSince(reminder.fireAt) > Self.lateness { return true }
        guard let itemID = reminder.trackedItemID else { return false }
        let reminderID = reminder.id
        let rows = try await services.database.read { db in
            (
                item: try TrackedItem.find(itemID).fetchOne(db),
                change: try AgentChange
                    .where { $0.targetTable.eq(AgentChangeTarget.reminder) && $0.targetID.eq(UUID?.some(reminderID)) }
                    .fetchOne(db)
            )
        }
        guard let item = rows.item, item.status == .open, let due = item.dueAt, due > reminder.fireAt else { return true }
        // An automatic reminder fires a planned time before the item's date: else the item moved.
        if rows.change?.sourceKind == Self.automatic {
            return !Self.offsets.contains { abs(due.addingTimeInterval(-$0).timeIntervalSince(reminder.fireAt)) < 60 }
        }
        return false
    }

    /// Asks for notification permission once (the first time a reminder is due).
    func authorize() async -> Bool {
        #if os(macOS)
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .denied:
            authorized = false
        default:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return authorized ?? false
        #else
        return false
        #endif
    }

    /// Sleeps until the next pending reminder still to come, however far away (a reminder that
    /// could not be shown waits for the next check, never a busy timer).
    func scheduleNext() async throws {
        let date = now()
        let next = try await reminders.pending(before: .distantFuture).first { $0.fireAt > date }
        // Replaced after the await, right before the new one is set: one timer at a time.
        timer?.cancel()
        timer = nil
        guard let next else { return }
        let delay = max(1, next.fireAt.timeIntervalSince(date))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // In a task of its own: the check's scheduleNext replaces this timer, not the check.
            Task { await self.check() }
        }
    }
}
