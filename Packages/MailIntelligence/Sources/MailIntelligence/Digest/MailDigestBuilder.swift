import Foundation
import StudyCore

/// The day's mail, folded (PRD #33): unread counts and the items mail added, grouped by course,
/// each item once. Today renders it in M3 ("5 unread · 2 1 1 · 1 newsletter" plus the dated rows);
/// nothing here restates what the rows already say.
public struct MailDigest: Hashable, Sendable {
    /// Why an item is in the digest (an item can have several reasons; it appears once).
    public struct Reasons: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Read from mail within the last 24 hours.
        public static let added = Reasons(rawValue: 1 << 0)
        /// Due within the next 7 days.
        public static let dueSoon = Reasons(rawValue: 1 << 1)
        /// A room change or cancellation waiting for Confirm.
        public static let proposal = Reasons(rawValue: 1 << 2)
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var item: TrackedItem
        /// The newest mail source of the item (its quote, Undo).
        public var source: TrackedItemSource
        public var reasons: Reasons

        public var id: TrackedItem.ID { item.id }
    }

    /// One course's share (`courseID` nil: items without a course).
    public struct CourseDigest: Hashable, Sendable, Identifiable {
        public var courseID: Course.ID?
        /// Unread Inbox mail of the course.
        public var unread: Int
        /// Due order (undated last).
        public var entries: [Entry]

        public var id: String { courseID?.uuidString ?? "none" }
    }

    public var unread: MailUnreadCounts
    /// In course order; only courses with unread mail or entries; items without a course last.
    public var courses: [CourseDigest]

    /// Every entry once, in due order.
    public var entries: [Entry] {
        courses.flatMap(\.entries).sorted { ($0.item.dueAt ?? .distantFuture, $0.item.createdAt) < ($1.item.dueAt ?? .distantFuture, $1.item.createdAt) }
    }
}

/// Builds `MailDigest` from the library (data only).
public struct MailDigestBuilder: Sendable {
    public static let addedWindow: TimeInterval = 24 * 3_600
    public static let dueWindow: TimeInterval = 7 * 24 * 3_600

    let services: StudyServices

    public init(services: StudyServices) {
        self.services = services
    }

    public func digest(now: Date) async throws -> MailDigest {
        let unread = try await MailRepository(store: services.records).unreadCounts()
        let addedSince = now.addingTimeInterval(-Self.addedWindow)
        let dueUntil = now.addingTimeInterval(Self.dueWindow)
        let (courses, entries) = try await services.database.read { db -> ([Course], [MailDigest.Entry]) in
            let courses = try Course.order { ($0.sortOrder, $0.name) }.fetchAll(db)
            let sources = try TrackedItemSource
                .where { $0.kind.eq(SourceRef.Kind.mail) }
                .order { $0.createdAt.desc() }
                .fetchAll(db)
            var newest: [TrackedItem.ID: TrackedItemSource] = [:]
            var recentlyAdded: Set<TrackedItem.ID> = []
            for source in sources {
                if newest[source.trackedItemID] == nil { newest[source.trackedItemID] = source }
                if source.createdAt >= addedSince, source.undoneAt == nil { recentlyAdded.insert(source.trackedItemID) }
            }
            let items = try TrackedItem
                .where { $0.id.in(Array(newest.keys)) && $0.status.eq(TrackedItemStatus.open) }
                .fetchAll(db)
            var entries: [MailDigest.Entry] = []
            for item in items {
                guard let source = newest[item.id] else { continue }
                var reasons: MailDigest.Reasons = []
                if recentlyAdded.contains(item.id) { reasons.insert(.added) }
                if let due = item.dueAt, due >= now, due < dueUntil, !item.kind.isSessionProposal { reasons.insert(.dueSoon) }
                if item.kind.isSessionProposal { reasons.insert(.proposal) }
                if !reasons.isEmpty { entries.append(MailDigest.Entry(item: item, source: source, reasons: reasons)) }
            }
            return (courses, entries)
        }

        let byCourse = Dictionary(grouping: entries, by: \.item.courseID)
        var groups: [MailDigest.CourseDigest] = []
        func sorted(_ entries: [MailDigest.Entry]) -> [MailDigest.Entry] {
            entries.sorted { ($0.item.dueAt ?? .distantFuture, $0.item.createdAt) < ($1.item.dueAt ?? .distantFuture, $1.item.createdAt) }
        }
        for course in courses {
            let courseEntries = byCourse[course.id] ?? []
            let count = unread.byCourse[course.id] ?? 0
            guard count > 0 || !courseEntries.isEmpty else { continue }
            groups.append(MailDigest.CourseDigest(courseID: course.id, unread: count, entries: sorted(courseEntries)))
        }
        let known = Set(courses.map(\.id))
        let loose = entries.filter { $0.item.courseID.map { !known.contains($0) } ?? true }
        if !loose.isEmpty {
            groups.append(MailDigest.CourseDigest(courseID: nil, unread: 0, entries: sorted(loose)))
        }
        return MailDigest(unread: unread, courses: groups)
    }
}
