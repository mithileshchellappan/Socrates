import ClaudeKit
import Foundation
import GRDB
import StudyCore

/// Routes mail to courses (PRD #31): the student's own mail follows its thread, then `mail_rule`
/// rows decide (user rules, then learned ones), then Haiku in batches of up to 20. A correction
/// sets a `.user` route (never overwritten) and becomes a learned rule.
public struct MailRouter: Sendable {
    /// What one routing pass did.
    public struct Report: Sendable, Equatable {
        public var byRule = 0
        public var own = 0
        public var byModel = 0
        /// Left for the model (no key, cost guard, or a failed call).
        public var waiting = 0
        /// Model calls made.
        public var calls = 0

        public init() {}
    }

    let services: StudyServices
    let client: ClaudeClient?
    let now: @Sendable () -> Date
    var repository: MailRepository { MailRepository(store: services.records) }

    public init(services: StudyServices, client: ClaudeClient?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.client = client
        self.now = now
    }

    // MARK: - Pending mail

    /// Routes every unrouted message: rules first; the rest through the model when `useModel`
    /// (each batch only while `allowCall()` says so); the student's own mail last, by its thread.
    @discardableResult
    public func routePending(useModel: Bool = true, allowCall: @escaping @Sendable () async -> Bool = { true }) async throws -> Report {
        var report = Report()
        let database = services.database
        let ids = try await database.read { db in
            try MailMessage.where { $0.category.is(nil) }.order(by: \.receivedAt).select(\.id).fetchAll(db)
        }
        guard !ids.isEmpty else { return report }
        let mailboxes = try await MailboxDirectory.load(database)
        let matcher = RuleMatcher(rules: try await MailRuleRepository(store: services.records).rules())

        var forModel: [MailMessage] = []
        var own: [MailMessage] = []
        for page in ids.chunked(200) {
            let messages = try await fetch(Array(page))
            for message in messages {
                if mailboxes.isOwn(message) {
                    own.append(message)
                    continue
                }
                switch matcher.match(message) {
                case .rule(let rule, let confidence):
                    if let route = rule.route,
                       try await repository.setRoute(message.id, route, source: .rule, ruleID: rule.id, confidence: confidence, at: now()) {
                        report.byRule += 1
                    }
                case .conflict, .none:
                    forModel.append(message)
                }
            }
        }

        if useModel, let client, !forModel.isEmpty {
            for batch in forModel.chunked(RoutingPrompt.batchSize) {
                guard await allowCall() else { break }
                do {
                    report.calls += 1
                    report.byModel += try await routeWithModel(Array(batch), client: client)
                } catch is CancellationError {
                    throw CancellationError()
                } catch ClaudeError.missingAPIKey {
                    break
                } catch {
                    MailIntelligence.log.error("Routing call failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        for message in own {
            guard let route = try await threadRoute(of: message, mailboxes: mailboxes) else { continue }
            if try await repository.setRoute(message.id, route.route, source: .rule, confidence: route.confidence, at: now()) {
                report.own += 1
            }
        }
        report.waiting = try await database.read { db in try MailMessage.where { $0.category.is(nil) }.fetchCount(db) }
        return report
    }

    /// Asks Haiku where `messages` belong and writes its answers (an unknown course token or a
    /// confidence below 0.5 becomes "other"; a message it left out too). Returns how many routes it wrote.
    func routeWithModel(_ messages: [MailMessage], client: ClaudeClient) async throws -> Int {
        let courses = try await CourseDirectory.load(services.database)
        let tokens = messages.enumerated().map { (token: "m\($0.offset + 1)", message: $0.element) }
        let request = RoutingPrompt.request(messages: tokens, courses: courses)
        let caller = ModelCaller(client: client, database: services.database)
        let answer: ModelCaller.Answer<RoutingPrompt.Answer>
        do {
            answer = try await caller.structured(RoutingPrompt.Answer.self, request, purpose: MailIntelligence.Purpose.route)
        } catch let failure as CallFailure {
            MailIntelligence.log.error("Routing answer unusable: \(failure.description, privacy: .public)")
            return 0
        }
        var decided: [MailMessage.ID: (MailRoute, Double)] = [:]
        let byToken = Dictionary(tokens.map { ($0.token, $0.message) }, uniquingKeysWith: { first, _ in first })
        for result in answer.value.results {
            guard let message = byToken[result.message.trimmingCharacters(in: .whitespaces).lowercased()],
                  decided[message.id] == nil else { continue }
            decided[message.id] = Self.route(for: result, courses: courses)
        }
        var written = 0
        for message in messages {
            let (route, confidence) = decided[message.id] ?? (.category(.other), 0)
            if try await repository.setRoute(
                message.id, route, source: .model, confidence: confidence, apiCallID: answer.apiCallID, at: now()
            ) {
                written += 1
            }
        }
        return written
    }

    /// The route a model result stands for, validated: a known course token, a known category,
    /// confidence at least 0.5; anything else is "other".
    static func route(for result: RoutingPrompt.Answer.Result, courses: CourseDirectory) -> (MailRoute, Double) {
        let confidence = min(max(result.confidence.isFinite ? result.confidence : 0, 0), 1)
        guard confidence >= RoutingPrompt.minimumConfidence else { return (.category(.other), confidence) }
        let category = MailCategory(rawValue: result.category.trimmingCharacters(in: .whitespaces).lowercased())
        switch category {
        case .course:
            guard let course = courses.course(token: result.course) else { return (.category(.other), confidence) }
            return (.course(course.id), confidence)
        case .university, .newsletter, .personal, .other:
            return (.category(category), confidence)
        default:
            return (.category(.other), confidence)
        }
    }

    /// The student's own mail: the route of the message it answers (or of its thread); personal
    /// when the thread is unknown; nil (wait) while the parent is not routed yet.
    func threadRoute(of message: MailMessage, mailboxes: MailboxDirectory) async throws -> (route: MailRoute, confidence: Double?)? {
        let messageID = message.id
        let parentID = message.inReplyTo
        let threadID = message.threadID
        let related = try await services.database.read { db -> [MailMessage] in
            var related: [MailMessage] = []
            if !parentID.isEmpty {
                related += try MailMessage.where { $0.rfcMessageID.eq(parentID) }.fetchAll(db)
            }
            if !threadID.isEmpty {
                related += try MailMessage.where { $0.threadID.eq(threadID) }.order { $0.receivedAt.desc() }.fetchAll(db)
            }
            return related.filter { $0.id != messageID }
        }
        let others = related.filter { !mailboxes.isOwn($0) }
        if let routed = others.first(where: { $0.route != nil }), let route = routed.route {
            return (route, routed.routingConfidence)
        }
        if let routedOwn = related.first(where: { $0.route != nil && $0.routingSource == .user }), let route = routedOwn.route {
            return (route, 1)
        }
        if !others.isEmpty { return nil }
        return (.category(.personal), 1)
    }

    // MARK: - Corrections

    /// The student moved a message (the route menu): sets a `.user` route, learns a rule (the
    /// List-Id, else the LMS course, else a personal sender address; never a no-reply or LMS
    /// address; not when a user rule already covers the message) and re-routes the other mail
    /// that rule matches and the model had routed. Returns the learned rule, if any.
    @discardableResult
    public func correct(_ id: MailMessage.ID, to route: MailRoute) async throws -> MailRule? {
        guard let message = try await repository.message(id) else { return nil }
        try await repository.setRoute(id, route, source: .user, confidence: 1, at: now())
        let rules = try await MailRuleRepository(store: services.records).rules()
        let matcher = RuleMatcher(rules: rules)
        guard matcher.userRules(matching: message).isEmpty,
              let (kind, pattern) = Self.learnablePattern(for: message)
        else { return nil }

        let folded = Folding.fold(pattern)
        let store = services.records
        let rule = try await services.database.write { db -> MailRule in
            let learned = try MailRule.where { $0.origin.eq(MailRuleOrigin.learned) && $0.kind.eq(kind) }.fetchAll(db)
            if var existing = learned.first(where: { Folding.fold($0.pattern) == folded }) {
                existing.courseID = route.courseID
                existing.category = route.courseID == nil ? route.category : nil
                let updated = store.stamp(existing)
                try MailRule.upsert { updated }.execute(db)
                return updated
            }
            let siblings = try MailRule.all.fetchAll(db).filter { $0.courseID == route.courseID && (route.courseID != nil || $0.category == route.category) }
            let rule = store.stamp(MailRule(
                courseID: route.courseID,
                category: route.courseID == nil ? route.category : nil,
                kind: kind,
                pattern: pattern,
                origin: .learned,
                sortOrder: (siblings.map(\.sortOrder).max() ?? -1) + 1,
                createdAt: now()
            ))
            try MailRule.upsert { rule }.execute(db)
            return rule
        }
        MailIntelligence.log.info("Learned a \(kind.rawValue, privacy: .public) rule from a correction")

        // Other mail of that sender or list the model routed follows the new rule.
        let candidates = try await services.database.read { db in
            try MailMessage.where { $0.routingSource.eq(MailRoutingSource?.some(.model)) }.fetchAll(db)
        }
        let updatedMatcher = RuleMatcher(rules: try await MailRuleRepository(store: services.records).rules())
        for other in candidates where other.id != id && updatedMatcher.matches(rule, other) {
            guard case .rule(let decided, let confidence) = updatedMatcher.match(other), let decidedRoute = decided.route else { continue }
            try await repository.setRoute(other.id, decidedRoute, source: .rule, ruleID: decided.id, confidence: confidence, at: now())
        }
        return rule
    }

    /// What a correction of `message` teaches: (kind, pattern), or nil when nothing safe.
    static func learnablePattern(for message: MailMessage) -> (MailRuleKind, String)? {
        let listID = message.listID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !listID.isEmpty { return (.listID, listID) }
        let fields = RuleMatcher.Fields(message)
        if fields.isPlatform {
            if let title = PlatformCourseTitle.find(subject: message.subject, body: message.bodyText) { return (.platformCourse, title) }
            return nil
        }
        let address = message.from.normalizedAddress
        guard !address.isEmpty, !isSharedAddress(address) else { return nil }
        return (.sender, address)
    }

    /// No-reply, system and LMS addresses (shared by many courses): never a sender rule.
    static func isSharedAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        let local = parts.first ?? address
        let domain = parts.count > 1 ? parts[1] : ""
        let markers = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "mailer-daemon",
                       "postmaster", "bounce", "lms", "notification", "notify", "daemon"]
        return markers.contains { local.contains($0) } || domain.contains("lms")
    }

    // MARK: - Rule changes

    /// Re-runs the rules over rule- and model-routed mail after the rules changed (Course
    /// Settings): a matching rule routes it; rule-routed mail no rule matches any more becomes
    /// unrouted, so the next pass routes it again (rules, then the model). Never calls the model;
    /// never touches `.user` routes or the student's own mail. Returns how many routes changed.
    @discardableResult
    public func rerunRules() async throws -> Int {
        let database = services.database
        let ids = try await database.read { db in
            try MailMessage
                .where { $0.routingSource.in([MailRoutingSource?.some(.rule), MailRoutingSource?.some(.model)]) }
                .select(\.id)
                .fetchAll(db)
        }
        guard !ids.isEmpty else { return 0 }
        let mailboxes = try await MailboxDirectory.load(database)
        let matcher = RuleMatcher(rules: try await MailRuleRepository(store: services.records).rules())
        var changed = 0
        for page in ids.chunked(200) {
            for message in try await fetch(Array(page)) where !mailboxes.isOwn(message) {
                switch matcher.match(message) {
                case .rule(let rule, let confidence):
                    guard let route = rule.route, message.routingRuleID != rule.id || message.route != route else { continue }
                    if try await repository.setRoute(message.id, route, source: .rule, ruleID: rule.id, confidence: confidence, at: now()) {
                        changed += 1
                    }
                case .conflict, .none:
                    guard message.routingSource == .rule else { continue }
                    if try await repository.setRoute(message.id, nil, source: .rule, at: now()) { changed += 1 }
                }
            }
        }
        return changed
    }

    private func fetch(_ ids: [MailMessage.ID]) async throws -> [MailMessage] {
        try await services.database.read { db in
            try MailMessage.where { $0.id.in(ids) }.order(by: \.receivedAt).fetchAll(db)
        }
    }
}

/// The course title an LMS notification is about: its "[Course]" subject tag, else the course
/// path with a semester ("Data Centers (WS 2026/27)") in the body.
enum PlatformCourseTitle {
    static func find(subject: String, body: String) -> String? {
        if let path = bodyPath(body) { return path }
        if let open = subject.firstIndex(of: "["), let close = subject[open...].firstIndex(of: "]") {
            let tag = subject[subject.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty, Folding.fold(tag) != "lms" { return tag }
        }
        return nil
    }

    /// "… added to Data Centers (WS 2026/27) › Lecture Material." → "Data Centers (WS 2026/27)".
    static func bodyPath(_ body: String) -> String? {
        let text = String(body.prefix(RuleMatcher.bodyPrefix))
        for marker in ["(WS ", "(SoSe ", "(SS ", "(WiSe ", "(Wintersemester ", "(Sommersemester "] {
            guard let open = text.range(of: marker), let close = text[open.upperBound...].firstIndex(of: ")") else { continue }
            let before = text[..<open.lowerBound]
            let separators: [String] = ["\n", "›", ">", ":", " to ", " zu ", " Kurs ", " course "]
            var start = before.startIndex
            for separator in separators {
                if let range = before.range(of: separator, options: .backwards), range.upperBound > start {
                    start = range.upperBound
                }
            }
            let title = text[start...close].trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > marker.count + 2, title.count <= 120 { return title }
        }
        return nil
    }
}
