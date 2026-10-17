import Foundation
import StudyCore
import UniformTypeIdentifiers

/// A message as the sync stores it: decoded headers, readable text, sanitized HTML, attachment
/// list. Untrusted content: the text is data, never instructions.
public struct ParsedMail: Hashable, Sendable {
    /// Message-ID without angle brackets; empty when missing.
    public var messageID: String
    public var inReplyTo: String
    public var references: [String]
    /// References[0], else In-Reply-To, else the own Message-ID (the sync prefers a stored
    /// parent's thread when there are no References).
    public var threadID: String
    public var from: MailAddress?
    public var replyTo: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String
    /// The Date header.
    public var date: Date?
    /// List-Id's inner id, lower-cased; empty when none.
    public var listID: String
    /// Selected other headers (lower-cased names) routing and extraction use.
    public var headers: [String: String]
    /// text/plain (format=flowed joined) when the mail has one, else the sanitized HTML's text;
    /// forwarded messages appended as quoted text.
    public var bodyText: String
    /// The sanitized HTML fragment (docs/plan-m2.md §2.8); empty when the mail has no HTML.
    public var sanitizedHTML: String
    /// The body came from a text/plain part.
    public var hasPlainText: Bool
    public var attachments: [ParsedAttachment]
    /// About 200 characters without quoted text and signature.
    public var snippet: String
    /// "de", "en" or "".
    public var language: String
}

/// An attachment or inline part (Content-ID) of a message.
public struct ParsedAttachment: Hashable, Sendable {
    /// MIME part path = IMAP section ("2", "1.2").
    public var part: String
    /// Sanitized: no path components, no control characters.
    public var fileName: String
    public var mimeType: String
    /// Decoded size in bytes (base64 estimated from its length).
    public var size: Int
    /// Without angle brackets; empty when none.
    public var contentID: String
    public var isInline: Bool
    /// Content-Transfer-Encoding of the part.
    public var encoding: String
}

public enum MIMEParserError: Error, Hashable, Sendable {
    case empty
    case partNotFound(String)
}

/// RFC 5322 / MIME parsing for the sync (docs/plan-m2.md §3 "Parsing"). Bump `version` when the
/// output changes: rows with an older `parse_version` are re-derived from their raw message.
public enum MIMEParser {
    public static let version = 1

    /// Largest raw message kept in the BlobStore (larger ones keep their text parts only).
    public static let maximumStoredRawSize = 25 * 1024 * 1024

    /// Header names copied into `ParsedMail.headers`.
    static let keptHeaders: Set<String> = [
        "auto-submitted", "precedence", "list-unsubscribe", "list-post", "list-archive", "x-mailer", "user-agent",
        "sender", "x-auto-response-suppress", "content-language", "organization", "x-priority", "importance",
        "x-original-to", "delivered-to", "x-spam-flag", "x-spam-status",
    ]

    static let maximumDepth = 20
    static let maximumParts = 500

    public static func parse(_ raw: Data) throws -> ParsedMail {
        guard !raw.isEmpty else { throw MIMEParserError.empty }
        let bytes = [UInt8](raw)
        var counter = 0
        let root = Entity.parse(bytes[...], section: "", isMessage: true, depth: 0, counter: &counter)
        var collector = BodyCollector()
        collector.walk(root, depth: 0)
        return assemble(root.headers, collector: collector)
    }

    /// The decoded bytes of one part (by IMAP section) of a raw message.
    public static func partData(_ raw: Data, part: String) throws -> Data {
        let bytes = [UInt8](raw)
        var counter = 0
        let root = Entity.parse(bytes[...], section: "", isMessage: true, depth: 0, counter: &counter)
        guard let entity = root.find(part) else { throw MIMEParserError.partNotFound(part) }
        return Data(TransferEncoding.decode(entity.body, encoding: entity.encoding))
    }

    static func assemble(_ headers: HeaderBlock, collector: BodyCollector) -> ParsedMail {
        let messageID = MessageIDs.single(headers["message-id"])
        let inReplyTo = MessageIDs.single(headers["in-reply-to"])
        let references = MessageIDs.list(headers["references"])
        let subject = EncodedWords.decode(headers["subject"] ?? "")
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        var sanitized = ""
        if !collector.html.isEmpty {
            sanitized = HTMLSanitizer.sanitize(collector.html.joined(separator: "\n"))
        }
        var body: String
        if !collector.plain.isEmpty {
            body = collector.plain.joined(separator: "\n\n")
        } else if !sanitized.isEmpty {
            body = HTMLSanitizer.text(fromSanitized: sanitized)
        } else {
            body = ""
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for forwarded in collector.forwarded {
            body += (body.isEmpty ? "" : "\n\n") + forwarded
        }

        var kept: [String: String] = [:]
        for field in headers.fields where keptHeaders.contains(field.name) || field.name.hasPrefix("x-lms") {
            if kept[field.name] == nil {
                kept[field.name] = String(EncodedWords.decode(field.value).prefix(500))
            }
        }

        let threadID = references.first ?? (inReplyTo.isEmpty ? messageID : inReplyTo)
        return ParsedMail(
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            threadID: threadID,
            from: AddressList.parse(headers["from"] ?? "").first,
            replyTo: AddressList.parse(headers["reply-to"] ?? ""),
            to: AddressList.parse(headers["to"] ?? ""),
            cc: AddressList.parse(headers["cc"] ?? ""),
            bcc: AddressList.parse(headers["bcc"] ?? ""),
            subject: subject,
            date: MailDate.parse(headers["date"]),
            listID: MessageIDs.listID(headers["list-id"]),
            headers: kept,
            bodyText: body,
            sanitizedHTML: sanitized,
            hasPlainText: !collector.plain.isEmpty,
            attachments: collector.attachments,
            snippet: MailText.snippet(body),
            language: MailText.language(subject: subject, body: body)
        )
    }

    /// A file name without path components or control characters, at most 200 characters;
    /// "Attachment" (+ an extension for the type) when nothing usable is left.
    static func sanitizedFileName(_ raw: String?, mimeType: String) -> String {
        var name = (raw ?? "")
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/").last ?? ""
        name = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !"<>:\"|?*".unicodeScalars.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            name = String(stem.prefix(190)) + (ext.isEmpty ? "" : "." + String(ext.prefix(9)))
        }
        if name.isEmpty {
            let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension
            name = "Attachment" + (ext.map { "." + $0 } ?? "")
        }
        return name
    }
}

// MARK: - Entities

/// One MIME entity: headers, the encoded body, children (multipart) or an embedded message
/// (message/rfc822), and its IMAP section.
struct Entity {
    var headers: HeaderBlock
    var contentType: HeaderValue
    var disposition: HeaderValue?
    var encoding: String?
    var body: ArraySlice<UInt8>
    var children: [Entity] = []
    var embedded: [Entity] = []
    /// IMAP section of this part ("1", "2.1"); "" for a top-level message / embedded message root.
    var section: String

    var mimeType: String { contentType.value.isEmpty ? "text/plain" : contentType.value }
    var isMultipart: Bool { mimeType.hasPrefix("multipart/") }
    var isMessage: Bool { mimeType == "message/rfc822" || mimeType == "message/global" }
    var contentID: String { MessageIDs.single(headers["content-id"]) }

    var fileName: String? {
        if let name = disposition?.parameters["filename"], !name.isEmpty { return EncodedWords.decode(name) }
        if let name = contentType.parameters["name"], !name.isEmpty { return EncodedWords.decode(name) }
        return nil
    }

    var isAttachmentDisposition: Bool { disposition?.value == "attachment" }

    static func join(_ prefix: String, _ index: Int) -> String {
        prefix.isEmpty ? "\(index)" : "\(prefix).\(index)"
    }

    /// Parses `bytes` (headers + body). `isMessage`: a whole message whose leaf body is section
    /// "<prefix>.1" ("1" at the top), as IMAP numbers them.
    static func parse(_ bytes: ArraySlice<UInt8>, section: String, isMessage: Bool, depth: Int, counter: inout Int,
                      defaultType: String = "text/plain") -> Entity {
        counter += 1
        let (headerBytes, body) = splitHeader(bytes)
        let headers = HeaderBlock(bytes: headerBytes)
        var contentType = HeaderValue(headers["content-type"] ?? defaultType)
        if contentType.value.isEmpty || !contentType.value.contains("/") { contentType = HeaderValue(defaultType) }
        var entity = Entity(
            headers: headers,
            contentType: contentType,
            disposition: headers["content-disposition"].map(HeaderValue.init),
            encoding: headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces),
            body: body,
            section: isMessage ? section : section
        )
        let limitsReached = depth >= MIMEParser.maximumDepth || counter >= MIMEParser.maximumParts
        if entity.isMultipart, !limitsReached, let boundary = contentType.parameters["boundary"], !boundary.isEmpty {
            let childDefault = entity.mimeType == "multipart/digest" ? "message/rfc822" : "text/plain"
            for (index, part) in splitMultipart(body, boundary: boundary).enumerated() {
                if counter >= MIMEParser.maximumParts { break }
                entity.children.append(parse(
                    part, section: join(section, index + 1), isMessage: false, depth: depth + 1, counter: &counter,
                    defaultType: childDefault
                ))
            }
            return entity
        }
        if isMessage {
            // A non-multipart message: its body is part "1" (or "<section>.1" when embedded).
            entity.section = join(section, 1)
        }
        if entity.isMessage, !limitsReached {
            let decoded = TransferEncoding.decode(body, encoding: entity.encoding)
            entity.embedded = [parse(decoded[...], section: entity.section, isMessage: true, depth: depth + 1, counter: &counter)]
        }
        return entity
    }

    /// Headers up to the first blank line, and the body after it.
    static func splitHeader(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var index = bytes.startIndex
        // A part starting with a blank line has no headers.
        if index < bytes.endIndex, bytes[index] == 0x0A { return (bytes[index..<index], bytes[(index + 1)...]) }
        if index + 1 < bytes.endIndex, bytes[index] == 0x0D, bytes[index + 1] == 0x0A {
            return (bytes[index..<index], bytes[(index + 2)...])
        }
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                let next = index + 1
                if next < bytes.endIndex, bytes[next] == 0x0A { return (bytes[bytes.startIndex..<index], bytes[(next + 1)...]) }
                if next + 1 < bytes.endIndex, bytes[next] == 0x0D, bytes[next + 1] == 0x0A {
                    return (bytes[bytes.startIndex..<index], bytes[(next + 2)...])
                }
            }
            index += 1
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    /// The parts between "--boundary" lines (the preamble and epilogue dropped).
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var index = body.startIndex
        while index < body.endIndex {
            let atLineStart = index == body.startIndex || body[index - 1] == 0x0A
            if atLineStart, body[index] == 0x2D, body.endIndex - index >= delimiter.count, matches(body, delimiter, at: index) {
                var after = index + delimiter.count
                let isClose = after + 1 < body.endIndex && body[after] == 0x2D && body[after + 1] == 0x2D
                if let start = partStart {
                    // The line break before the delimiter belongs to it.
                    var end = index
                    if end > start, body[end - 1] == 0x0A { end -= 1 }
                    if end > start, body[end - 1] == 0x0D { end -= 1 }
                    parts.append(body[start..<end])
                }
                if isClose { return parts }
                // Skip to the end of the delimiter line.
                while after < body.endIndex, body[after] != 0x0A { after += 1 }
                partStart = min(after + 1, body.endIndex)
                index = partStart ?? body.endIndex
                continue
            }
            // Jump to the next line.
            while index < body.endIndex, body[index] != 0x0A { index += 1 }
            index += 1
        }
        if let start = partStart, start < body.endIndex { parts.append(body[start..<body.endIndex]) }
        return parts
    }

    private static func matches(_ body: ArraySlice<UInt8>, _ pattern: [UInt8], at index: Int) -> Bool {
        for offset in 0..<pattern.count where body[index + offset] != pattern[offset] { return false }
        return true
    }

    /// The entity with IMAP section `part`.
    func find(_ part: String) -> Entity? {
        if section == part, !isMultipart { return self }
        for child in children {
            if let found = child.find(part) { return found }
        }
        for message in embedded {
            if let found = message.find(part) { return found }
        }
        return nil
    }

    /// The decoded text of a text part (charset fallbacks, format=flowed joined).
    func decodedText() -> String {
        let bytes = TransferEncoding.decode(body, encoding: encoding)
        var charset = contentType.parameters["charset"]
        if charset == nil, mimeType == "text/html" { charset = Self.sniffHTMLCharset(bytes) }
        var text = MailText.normalizeLineEndings(Charset.decode(bytes, declared: charset))
        if mimeType == "text/plain", contentType.parameters["format"]?.lowercased() == "flowed" {
            text = MailText.unflow(text, delSp: contentType.parameters["delsp"]?.lowercased() == "yes")
        }
        return text
    }

    /// `<meta charset=…>` / `content="text/html; charset=…"` in the first 2 KB.
    static func sniffHTMLCharset(_ bytes: [UInt8]) -> String? {
        let head = String(decoding: bytes.prefix(2_048), as: UTF8.self).lowercased()
        guard let range = head.range(of: "charset=") else { return nil }
        let value = head[range.upperBound...]
            .drop(while: { $0 == "\"" || $0 == "'" || $0 == " " })
            .prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return value.isEmpty ? nil : String(value)
    }
}

// MARK: - Body selection

/// Walks the MIME tree: picks text/plain and text/html bodies (alternative, related, mixed),
/// lists attachments and inline parts, and turns forwarded messages into quoted text.
struct BodyCollector {
    var plain: [String] = []
    var html: [String] = []
    var forwarded: [String] = []
    var attachments: [ParsedAttachment] = []

    mutating func walk(_ entity: Entity, depth: Int) {
        guard depth <= MIMEParser.maximumDepth else { return }
        let type = entity.mimeType
        if entity.isMultipart {
            switch type {
            case "multipart/alternative": walkAlternative(entity, depth: depth)
            case "multipart/related": walkRelated(entity, depth: depth)
            default: for child in entity.children { walk(child, depth: depth + 1) }
            }
            return
        }
        if entity.isMessage, let inner = entity.embedded.first {
            addForwarded(inner, depth: depth)
            return
        }
        addLeaf(entity, inline: false)
    }

    private mutating func walkAlternative(_ entity: Entity, depth: Int) {
        // The richest text/plain and text/html among the alternatives (last wins, RFC 2046).
        let bodies = entity.children.filter { !$0.isAttachmentDisposition }
        if let plainPart = bodies.last(where: { $0.mimeType == "text/plain" }) {
            plain.append(plainPart.decodedText())
        }
        if let htmlPart = bodies.last(where: { $0.mimeType == "text/html" || $0.mimeType == "multipart/related" || $0.mimeType == "multipart/mixed" }) {
            if htmlPart.isMultipart {
                var nested = BodyCollector()
                nested.walk(htmlPart, depth: depth + 1)
                html += nested.html
                if plain.isEmpty { plain += nested.plain }
                attachments += nested.attachments
                forwarded += nested.forwarded
            } else {
                html.append(htmlPart.decodedText())
            }
        }
        // Anything else (text/calendar invitations, …) is an attachment.
        for child in entity.children where !["text/plain", "text/html", "multipart/related", "multipart/mixed"].contains(child.mimeType) {
            if child.isMultipart {
                walk(child, depth: depth + 1)
            } else {
                addAttachment(child, inline: false)
            }
        }
        if plain.isEmpty, html.isEmpty, let first = bodies.first, first.mimeType.hasPrefix("text/") {
            plain.append(first.decodedText())
        }
    }

    private mutating func walkRelated(_ entity: Entity, depth: Int) {
        guard !entity.children.isEmpty else { return }
        let start = MessageIDs.single(entity.contentType.parameters["start"])
        let rootIndex = start.isEmpty ? 0 : entity.children.firstIndex { $0.contentID == start } ?? 0
        for (index, child) in entity.children.enumerated() {
            if index == rootIndex {
                walk(child, depth: depth + 1)
            } else if child.isMultipart {
                walk(child, depth: depth + 1)
            } else {
                addAttachment(child, inline: !child.isAttachmentDisposition)
            }
        }
    }

    private mutating func addLeaf(_ entity: Entity, inline: Bool) {
        let type = entity.mimeType
        let isBodyText = (type == "text/plain" || type == "text/html") && !entity.isAttachmentDisposition && entity.fileName == nil
        if isBodyText {
            if type == "text/plain" { plain.append(entity.decodedText()) } else { html.append(entity.decodedText()) }
        } else {
            let isInline = inline || (!entity.contentID.isEmpty && !entity.isAttachmentDisposition && entity.disposition?.value != nil)
                || (!entity.contentID.isEmpty && entity.disposition == nil && type.hasPrefix("image/"))
            addAttachment(entity, inline: isInline)
        }
    }

    private mutating func addAttachment(_ entity: Entity, inline: Bool) {
        let type = entity.mimeType
        let size: Int = entity.encoding == "base64"
            ? TransferEncoding.base64DecodedCount(entity.body)
            : entity.body.count
        attachments.append(ParsedAttachment(
            part: entity.section,
            fileName: MIMEParser.sanitizedFileName(entity.fileName, mimeType: type),
            mimeType: type,
            size: size,
            contentID: entity.contentID,
            isInline: inline,
            encoding: entity.encoding ?? "7bit"
        ))
    }

    /// A forwarded message: its header lines and text as quoted text ("> "); its attachments are
    /// listed with the outer message's.
    private mutating func addForwarded(_ message: Entity, depth: Int) {
        var inner = BodyCollector()
        inner.walk(message, depth: depth + 1)
        let parsed = MIMEParser.assemble(message.headers, collector: inner)
        var lines: [String] = ["---------- Forwarded message ----------"]
        if let from = parsed.from {
            lines.append("From: " + (from.name.isEmpty ? from.address : "\(from.name) <\(from.address)>"))
        }
        if let date = message.headers["date"] { lines.append("Date: " + date) }
        if !parsed.subject.isEmpty { lines.append("Subject: " + parsed.subject) }
        if !parsed.to.isEmpty { lines.append("To: " + parsed.to.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", ")) }
        lines.append("")
        lines += parsed.bodyText.components(separatedBy: "\n")
        forwarded.append(lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
        attachments += inner.attachments
    }
}
