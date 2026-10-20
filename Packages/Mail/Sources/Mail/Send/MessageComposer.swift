import Foundation
import StudyCore

/// RFC 5322 bytes of a draft: From (display name + alias), To/Cc (Bcc only as recipients),
/// Subject (RFC 2047 when needed), Date, Message-ID, In-Reply-To, References, a text/plain UTF-8
/// body in quoted-printable, CRLF line endings, lines within 76 characters. Deterministic: the
/// same draft, date and id give the same bytes (the Sent copy saved later equals what was sent).
public enum MessageComposer {
    public static func compose(_ draft: MailDraft, from sender: MailAddress, date: Date, messageID: String) -> Data {
        var lines: [String] = []
        lines.append(folded("From", [address(sender)]))
        if !draft.to.isEmpty { lines.append(folded("To", draft.to.map(address))) }
        if !draft.cc.isEmpty { lines.append(folded("Cc", draft.cc.map(address))) }
        lines.append("Subject: " + unstructured(draft.subject, nameLength: "Subject: ".count))
        lines.append("Date: " + dateHeader(date))
        lines.append("Message-ID: <\(messageID)>")
        if MessageIDs.isValid(draft.inReplyTo) { lines.append("In-Reply-To: <\(draft.inReplyTo)>") }
        let references = referenceChain(draft)
        if !references.isEmpty { lines.append(folded("References", references.map { "<\($0)>" }, separator: "")) }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: quoted-printable")
        let header = lines.joined(separator: "\r\n")
        return Data((header + "\r\n\r\n" + quotedPrintable(draft.body) + "\r\n").utf8)
    }

    /// References of a reply: the draft's chain, ending with the message replied to.
    static func referenceChain(_ draft: MailDraft) -> [String] {
        var chain = draft.referenceIDs.filter(MessageIDs.isValid)
        if MessageIDs.isValid(draft.inReplyTo), chain.last != draft.inReplyTo { chain.append(draft.inReplyTo) }
        var seen: Set<String> = []
        return chain.filter { seen.insert($0).inserted }
    }

    /// A new Message-ID (without brackets) in the sender's domain.
    public static func newMessageID(for sender: String) -> String {
        let domain = sender.split(separator: "@").last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "socrates.invalid"
        return "\(UUID().uuidString.lowercased())@\(domain.lowercased())"
    }

    // MARK: - Dates

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Fri, 16 Oct 2026 15:02:00 +0200" (the university's time zone).
    static func dateHeader(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        let zone = MailClock.zone
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .day, .month, .year, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date) / 60
        let sign = offset < 0 ? "-" : "+"
        let zoneText = String(format: "%@%02d%02d", sign, abs(offset) / 60, abs(offset) % 60)
        return String(
            format: "%@, %d %@ %04d %02d:%02d:%02d %@",
            weekdays[(parts.weekday ?? 1) - 1], parts.day ?? 1, monthNames[(parts.month ?? 1) - 1], parts.year ?? 1970,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, zoneText
        )
    }

    // MARK: - Addresses

    private static let atext = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-/=?^_`{|}~ ")

    /// "Name <address>", the name quoted or RFC 2047-encoded when needed. Names and addresses
    /// come from received mail: line breaks and other control characters never reach the header.
    static func address(_ address: MailAddress) -> String {
        let name = MailText.headerSafe(address.name)
        let mailbox = String(address.address.unicodeScalars.filter { !MailText.isUnsafeInHeader($0) && !$0.properties.isWhitespace })
        guard !name.isEmpty else { return mailbox }
        return "\(phrase(name)) <\(mailbox)>"
    }

    static func phrase(_ raw: String) -> String {
        let name = MailText.headerSafe(raw)
        if !name.unicodeScalars.allSatisfy(\.isASCII) {
            return encodedWords(name, restricted: true, firstLineRoom: 60).joined(separator: " ")
        }
        if name.unicodeScalars.allSatisfy({ atext.contains($0) }) { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// "Name: a, b, …" folded so lines stay short.
    static func folded(_ name: String, _ items: [String], separator: String = ",") -> String {
        var output = name + ":"
        var lineLength = output.count
        for (index, item) in items.enumerated() {
            if index > 0 {
                output += separator
                lineLength += separator.count
                if lineLength + 1 + item.count > 76 {
                    output += "\r\n"
                    lineLength = 0
                }
            }
            output += " " + item
            lineLength += 1 + item.count
        }
        return output
    }

    // MARK: - RFC 2047

    /// Unstructured header text: as is when ASCII, else Q-encoded words folded on CRLF SP.
    static func unstructured(_ text: String, nameLength: Int) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.map { MailText.isUnsafeInHeader($0) ? " " : $0 }))
        if clean.unicodeScalars.allSatisfy(\.isASCII), !clean.contains("=?") { return clean }
        return encodedWords(clean, restricted: false, firstLineRoom: 76 - nameLength).joined(separator: "\r\n ")
    }

    /// Q-encoded words of at most 75 characters, never splitting a character.
    static func encodedWords(_ text: String, restricted: Bool, firstLineRoom: Int) -> [String] {
        let prefix = "=?UTF-8?Q?"
        let suffix = "?="
        var words: [String] = []
        var current = ""
        let limit = 75 - prefix.count - suffix.count
        for character in text {
            var encoded = ""
            for byte in String(character).utf8 {
                switch byte {
                case 0x20: encoded += "_"
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: encoded += String(UnicodeScalar(byte))
                case UInt8(ascii: "!"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "/"):
                    encoded += String(UnicodeScalar(byte))
                case UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "'"),
                     UInt8(ascii: "("), UInt8(ascii: ")"):
                    encoded += restricted ? String(format: "=%02X", byte) : String(UnicodeScalar(byte))
                default: encoded += String(format: "=%02X", byte)
                }
            }
            let room = words.isEmpty ? min(limit, max(10, firstLineRoom - prefix.count - suffix.count)) : limit
            if current.count + encoded.count > room, !current.isEmpty {
                words.append(prefix + current + suffix)
                current = ""
            }
            current += encoded
        }
        if !current.isEmpty || words.isEmpty { words.append(prefix + current + suffix) }
        return words
    }

    // MARK: - Body

    /// Quoted-printable (RFC 2045 §6.7) with CRLF line breaks: "=", non-ASCII, control
    /// characters, trailing whitespace, a leading "." and a leading "From " encoded; soft breaks
    /// keep lines within 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        let normalized = MailText.normalizeLineEndings(text)
        var outputLines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            let bytes = Array(line.utf8)
            var output = ""
            var length = 0
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                var needsEncoding = byte == UInt8(ascii: "=") || byte > 126 || (byte < 32 && byte != 9)
                if isLast, byte == 0x20 || byte == 0x09 { needsEncoding = true }
                if index == 0, byte == UInt8(ascii: ".") { needsEncoding = true }
                if index == 0, bytes.starts(with: Array("From ".utf8)) { needsEncoding = true }
                let token = needsEncoding ? String(format: "=%02X", byte) : String(UnicodeScalar(byte))
                if length + token.count > 75 {
                    output += "=\r\n"
                    length = 0
                }
                output += token
                length += token.count
            }
            outputLines.append(output)
        }
        return outputLines.joined(separator: "\r\n")
    }
}
