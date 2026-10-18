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
/// - Cancelled reminders (Undo of their change, the item done or undone) never fire.
actor ReminderCenter {
    let services: StudyServices
    let changeLog: ChangeLog
    let now: @Sendable () -> Date
    private var timer: Task<Void, Never>?
    private var authorized: Bool?

    init(services: StudyServices, changeLog: ChangeLog, now: @escaping @Sendable () -> Date) {
        self.services = services
        self.changeLog = changeLog
        self.now = now
    }

    var reminders: AgentReminderRepository { AgentReminderRepository(store: services.records) }

    /// Plans the automatic reminders, delivers what is due and sleeps until the next one.
    func check() async {
        do {
            try await planAutomatic()
            try await deliverDue()
            try await scheduleNext()
        } catch {
            AppAgentModule.log.error("Reminders failed: \(String(describing: error), privacy: .public)")
        }
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
                courses: try Course.all.fetchAll(db)
            )
        }
        let names = Dictionary(rows.courses.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let existing = Dictionary(grouping: rows.reminders, by: { $0.trackedItemID })
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
                let origin = ChangeLog.Origin(source: .external(SourceRef.Kind(rawValue: "agent"), reference: item.id.uuidString.lowercased()), sourceDate: date, model: "")
                _ = try await changeLog.apply(
                    .reminder(itemID: item.id, courseID: item.courseID, title: item.title, body: body, fireAt: fire), quote: quote, origin: origin
                )
            }
        }
    }

    // MARK: Delivery

    func deliverDue() async throws {
        let due = try await reminders.pending(before: now().addingTimeInterval(30))
        guard !due.isEmpty else { return }
        #if os(macOS)
        guard await authorize() else { return }
        let center = UNUserNotificationCenter.current()
        for reminder in due {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: reminder.notificationID, content: content, trigger: nil)
            do {
                try await center.add(request)
                try await reminders.markDelivered(reminder.id)
            } catch {
                AppAgentModule.log.error("A reminder could not be shown: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
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

    /// Sleeps until the next pending reminder (at most a day; a wake plans again).
    func scheduleNext() async throws {
        timer?.cancel()
        let next = try await reminders.pending(before: now().addingTimeInterval(86_400)).first
        guard let next else { return }
        let delay = max(1, next.fireAt.timeIntervalSince(now()))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }
}
