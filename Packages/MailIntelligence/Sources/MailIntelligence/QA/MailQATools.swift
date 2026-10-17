import ClaudeKit
import Foundation
import GRDB
import StudyCore

/// Read-only tools over the student's mail for Q&A (PRD #35; the tutor chat of M5 uses them).
/// Results are §2.9 `<mail>` envelopes (ids are message UUIDs). Nothing here writes a row, marks
/// mail read, drafts or sends: a conversation that reads mail gets no write tools.
public enum MailQATools {
    public static let searchName = "search_mail"
    public static let readName = "read_mail"
    public static let listName = "list_mail"

    /// At most this many hits per search.
    public static let searchLimit = 10
    /// At most this many messages per listing.
    public static let listLimit = 20

    public static var tools: [Tool] {
        [
            .custom(
                name: searchName,
                description: """
                    Search the student's university mail by keywords (German or English; word beginnings and \
                    inflected forms match). Use it whenever a question may be answered by a mail: deadlines, \
                    rooms, announcements, what a lecturer wrote. Returns the best matching messages as <mail> \
                    elements with a short excerpt; read one in full with read_mail.
                    """,
                inputSchema: Schemas.object([
                    "query": ["type": "string", "description": "Keywords, e.g. \"Abgabe Blatt 2\" or \"exam registration\"."],
                    "course": Schemas.nullable(["type": "string", "description": "Course name or short name to search in."]),
                    "from": Schemas.nullable(["type": "string", "description": "Part of the sender's name or address."]),
                    "since": Schemas.nullable(["type": "string", "description": "Only mail received on or after this day, YYYY-MM-DD."]),
                    "until": Schemas.nullable(["type": "string", "description": "Only mail received before this day, YYYY-MM-DD."]),
                    "limit": Schemas.nullable(["type": "integer", "description": "At most 10."]),
                ])
            ),
            .custom(
                name: readName,
                description: """
                    Read one mail in full by its id (from search_mail or list_mail). Use it before answering from \
                    a message whose excerpt is not enough.
                    """,
                inputSchema: Schemas.object([
                    "id": ["type": "string", "description": "The id attribute of a <mail> element."]
                ])
            ),
            .custom(
                name: listName,
                description: """
                    List the newest mail, optionally of one course, since a day, or unread only. Use it for \
                    questions like "what came from Data Centers this week".
                    """,
                inputSchema: Schemas.object([
                    "course": Schemas.nullable(["type": "string", "description": "Course name or short name."]),
                    "since": Schemas.nullable(["type": "string", "description": "YYYY-MM-DD."]),
                    "unread_only": Schemas.nullable(["type": "boolean"]),
                ])
            ),
        ]
    }

    struct SearchInput: Decodable {
        var query: String
        var course: String?
        var from: String?
        var since: String?
        var until: String?
        var limit: Int?
    }

    struct ReadInput: Decodable {
        var id: String
    }

    struct ListInput: Decodable {
        var course: String?
        var since: String?
        var unreadOnly: Bool?

        enum CodingKeys: String, CodingKey {
            case course, since
            case unreadOnly = "unread_only"
        }
    }

    /// The handler for the three tools. It only reads.
    public static func handler(services: StudyServices, timeZone: TimeZone = MailIntelligenceModule.timeZone) -> ToolHandler {
        let database: any DatabaseReader = services.database
        return { call in
            switch call.name {
            case searchName:
                let input = try call.decodeInput(SearchInput.self)
                return try await search(input, database: database, timeZone: timeZone)
            case readName:
                let input = try call.decodeInput(ReadInput.self)
                return try await read(input, database: database)
            case listName:
                let input = try call.decodeInput(ListInput.self)
                return try await list(input, database: database, timeZone: timeZone)
            default:
                return .error("Unknown tool \(call.name)")
            }
        }
    }

    // MARK: - Tools

    static func search(_ input: SearchInput, database: any DatabaseReader, timeZone: TimeZone) async throws -> ToolOutput {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .error("query is empty") }
        var place = MailSearchScope.Place.all
        if let name = input.course?.nilIfBlank {
            guard let course = try await course(named: name, database: database) else { return .error("No course named \(name)") }
            place = .course(course.id)
        }
        let scope = MailSearchScope(
            place, from: input.from?.nilIfBlank,
            since: day(input.since, timeZone: timeZone), until: day(input.until, timeZone: timeZone)
        )
        let limit = min(max(input.limit ?? searchLimit, 1), searchLimit)
        let hits = try await MailSearch(database: database).search(query, in: scope, limit: limit)
        guard !hits.isEmpty else { return .text("No mail found.") }
        let messages = try await database.read { db in
            try MailMessage.where { $0.id.in(hits.map(\.messageID)) }.fetchAll(db)
        }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let envelopes = hits.compactMap { hit in
            byID[hit.messageID].map {
                MailEnvelope.render($0, id: $0.id.uuidString.lowercased(), budget: MailEnvelope.Budget.snippet, body: hit.snippet)
            }
        }
        return .text(envelopes.joined(separator: "\n\n"))
    }

    static func read(_ input: ReadInput, database: any DatabaseReader) async throws -> ToolOutput {
        guard let id = UUID(uuidString: input.id.trimmingCharacters(in: .whitespaces)) else { return .error("Not a mail id") }
        let found = try await database.read { db -> (MailMessage, [MailAttachment])? in
            guard let message = try MailMessage.find(id).fetchOne(db) else { return nil }
            let attachments = try MailAttachment.where { $0.mailMessageID.eq(id) && !$0.isInline }.fetchAll(db)
            return (message, attachments)
        }
        guard let (message, attachments) = found else { return .error("No mail with that id") }
        let names = attachments.map(\.fileName).filter { !$0.isEmpty }
        let attributes: KeyValuePairs<String, String> = names.isEmpty ? [:] : ["attachments": names.joined(separator: ", ")]
        return .text(MailEnvelope.render(
            message, id: message.id.uuidString.lowercased(), budget: MailEnvelope.Budget.drafting, extraAttributes: attributes
        ))
    }

    static func list(_ input: ListInput, database: any DatabaseReader, timeZone: TimeZone) async throws -> ToolOutput {
        var courseID: Course.ID?
        if let name = input.course?.nilIfBlank {
            guard let course = try await course(named: name, database: database) else { return .error("No course named \(name)") }
            courseID = course.id
        }
        let since = day(input.since, timeZone: timeZone) ?? .distantPast
        let unreadOnly = input.unreadOnly ?? false
        let course = courseID
        let messages = try await database.read { db -> [MailMessage] in
            let synced = try Mailbox.where { $0.role.in([MailboxRole?.some(.inbox), MailboxRole?.some(.archive)]) }.select(\.id).fetchAll(db)
            return try MailMessage
                .where { $0.mailboxID.in(synced) && $0.receivedAt.gte(since) }
                .order { $0.receivedAt.desc() }
                .limit(400)
                .fetchAll(db)
                .filter { (course == nil || $0.courseID == course) && (!unreadOnly || !$0.isSeen) }
        }
        guard !messages.isEmpty else { return .text("No mail.") }
        let envelopes = messages.prefix(listLimit).map {
            MailEnvelope.render($0, id: $0.id.uuidString.lowercased(), budget: MailEnvelope.Budget.snippet, body: $0.snippet.isEmpty ? $0.bodyText : $0.snippet)
        }
        return .text(envelopes.joined(separator: "\n\n"))
    }

    // MARK: - Helpers

    static func course(named name: String, database: any DatabaseReader) async throws -> Course? {
        let folded = Folding.fold(name)
        let courses = try await database.read { db in try Course.all.fetchAll(db) }
        if let id = UUID(uuidString: name), let course = courses.first(where: { $0.id == id }) { return course }
        return courses.first { Folding.fold($0.name) == folded || Folding.fold($0.shortName) == folded }
            ?? courses.first { Folding.fold($0.name).contains(folded) }
    }

    static func day(_ text: String?, timeZone: TimeZone) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), let day = CalendarDay(rawValue: text) else { return nil }
        return day.start(in: timeZone)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
