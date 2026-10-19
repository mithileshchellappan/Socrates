import Foundation
import StudyCore

// RFC 5322 headers: unfolding, RFC 2047 encoded words, RFC 2045/2231 parameters, address lists
// with groups and quoted names, Message-ID lists and dates.

/// A header block in order, names lower-cased, values unfolded (still RFC 2047-encoded).
struct HeaderBlock: Sendable {
    var fields: [(name: String, value: String)]

    init(fields: [(name: String, value: String)] = []) {
        self.fields = fields
    }

    /// Parses header bytes (up to the blank line). 8-bit header bytes are read as UTF-8 when
    /// valid, else as windows-1252, line by line.
    init(bytes: ArraySlice<UInt8>) {
        var fields: [(name: String, value: String)] = []
        var lines: [String] = []
        var lineStart = bytes.startIndex
        var index = bytes.startIndex
        func takeLine(_ end: Int) {
            var slice = bytes[lineStart..<end]
            if slice.last == 0x0D { slice = slice.dropLast() }
            let array = Array(slice)
            lines.append(Charset.strictUTF8(array) ?? String(bytes: array, encoding: .windowsCP1252) ?? String(decoding: array, as: UTF8.self))
        }
        while index < bytes.endIndex {
            if bytes[index] == 0x0A {
                takeLine(index)
                lineStart = index + 1
            }
            index += 1
        }
        if lineStart < bytes.endIndex { takeLine(bytes.endIndex) }

        var currentName: String?
        var currentValue = ""
        func flush() {
            if let name = currentName { fields.append((name, currentValue.trimmingCharacters(in: .whitespaces))) }
            currentName = nil
            currentValue = ""
        }
        for line in lines {
            if line.isEmpty { break }
            if let first = line.unicodeScalars.first, first == " " || first == "\t" {
                // Continuation: unfolding removes the CRLF only, keeping the whitespace.
                if currentName != nil { currentValue += line }
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { continue }
            currentName = name
            currentValue = String(line[line.index(after: colon)...])
        }
        flush()
        self.fields = fields
    }

    /// The first value of `name` (lower-case).
    subscript(name: String) -> String? {
        fields.first { $0.name == name }?.value
    }

    func all(_ name: String) -> [String] {
        fields.filter { $0.name == name }.map(\.value)
    }
}

// MARK: - RFC 2047

enum EncodedWords {
    /// Decodes `=?charset?Q?…?=` / `=?charset?B?…?=` words; whitespace between adjacent encoded
    /// words is dropped. Undecodable words stay as they are.
    static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var output = ""
        var rest = Substring(value)
        var pendingWhitespace = ""
        var previousWasEncoded = false
        while !rest.isEmpty {
            guard let start = rest.range(of: "=?") else {
                output += pendingWhitespace + rest
                pendingWhitespace = ""
                break
            }
            let before = rest[..<start.lowerBound]
            if let (decoded, end) = decodeWord(rest[start.lowerBound...]) {
                if previousWasEncoded, before.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    // Adjacent encoded words: the whitespace between them is not text.
                } else {
                    output += pendingWhitespace + before
                }
                pendingWhitespace = ""
                output += decoded
                previousWasEncoded = true
                rest = rest[end...]
            } else {
                output += pendingWhitespace + before + "=?"
                pendingWhitespace = ""
                previousWasEncoded = false
                rest = rest[start.upperBound...]
            }
        }
        return output
    }

    /// One encoded word at the start of `text`: the decoded text and where it ends.
    private static func decodeWord(_ text: Substring) -> (String, Substring.Index)? {
        // =?charset?enc?payload?=
        let afterOpen = text.index(text.startIndex, offsetBy: 2)
        guard let firstQ = text[afterOpen...].firstIndex(of: "?") else { return nil }
        let charsetField = text[afterOpen..<firstQ]
        let encodingStart = text.index(after: firstQ)
        guard encodingStart < text.endIndex else { return nil }
        let encoding = text[encodingStart]
        let secondQ = text.index(after: encodingStart)
        guard secondQ < text.endIndex, text[secondQ] == "?" else { return nil }
        let payloadStart = text.index(after: secondQ)
        guard let close = text[payloadStart...].range(of: "?=") else { return nil }
        let payload = text[payloadStart..<close.lowerBound]
        guard !payload.contains(" "), charsetField.count < 40 else { return nil }
        // RFC 2231 language suffix: "utf-8*de".
        let charset = charsetField.split(separator: "*", maxSplits: 1).first.map(String.init) ?? String(charsetField)
        let bytes: [UInt8]
        switch encoding {
        case "B", "b": bytes = TransferEncoding.base64(Array(payload.utf8))
        case "Q", "q": bytes = TransferEncoding.quotedPrintable(Array(payload.utf8), underscoreIsSpace: true)
        default: return nil
        }
        return (Charset.decode(bytes, declared: charset), close.upperBound)
    }
}

// MARK: - Parameters (RFC 2045, RFC 2231)

/// "text/plain; charset=utf-8; format=flowed" → value + parameters (names lower-cased).
struct HeaderValue: Sendable {
    var value: String
    var parameters: [String: String]

    init(_ raw: String) {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in raw {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && inQuotes { current.append(character); escaped = true; continue }
            if character == "\"" { inQuotes.toggle() }
            if character == ";" && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        value = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        var simple: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, value: String)]] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var name = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var parameterValue = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if parameterValue.hasPrefix("\""), parameterValue.hasSuffix("\""), parameterValue.count >= 2 {
                parameterValue = String(parameterValue.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            guard !name.isEmpty else { continue }
            if name.contains("*") {
                let encoded = name.hasSuffix("*")
                if encoded { name.removeLast() }
                let pieces = name.split(separator: "*", maxSplits: 1)
                // A name of asterisks only ("*=x", "**=x") has no base: not a parameter.
                guard let first = pieces.first, !first.isEmpty else { continue }
                let base = String(first)
                let index = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
                extended[base, default: []].append((index, encoded, parameterValue))
            } else {
                simple[name] = parameterValue
            }
        }
        for (name, pieces) in extended {
            let ordered = pieces.sorted { $0.index < $1.index }
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (offset, piece) in ordered.enumerated() {
                var text = piece.value
                if piece.encoded, offset == 0 {
                    // charset'language'value
                    let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        charset = fields[0].isEmpty ? "utf-8" : String(fields[0])
                        text = String(fields[2])
                    }
                }
                bytes += piece.encoded ? Self.percentDecoded(text) : Array(text.utf8)
            }
            simple[name] = Charset.decode(bytes, declared: charset)
        }
        parameters = simple
    }

    private static func percentDecoded(_ text: String) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
               let byte = UInt8(String(decoding: utf8[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(byte)
                index += 3
            } else {
                output.append(utf8[index])
                index += 1
            }
        }
        return output
    }
}

// MARK: - Addresses

enum AddressList {
    /// Parses an RFC 5322 address list: groups ("Team: a@x, b@y;" → members), quoted display
    /// names with commas, comments as names ("a@x (Name)"), RFC 2047 names, bare addresses.
    static func parse(_ raw: String) -> [MailAddress] {
        var result: [MailAddress] = []
        var phrase = ""
        var address: String?
        var comment = ""
        var token = ""
        var inQuotes = false
        var commentDepth = 0
        var inAngle = false
        var angle = ""

        func finish() {
            let bare = token.trimmingCharacters(in: .whitespaces)
            var name = phrase.trimmingCharacters(in: .whitespaces)
            var mailbox = address
            if mailbox == nil {
                // No angle brackets: the bare token is the address ("a@x" or "a@x (Name)").
                mailbox = (name + bare).replacingOccurrences(of: " ", with: "")
                name = ""
            } else if !bare.isEmpty {
                name += (name.isEmpty ? "" : " ") + bare
            }
            if name.isEmpty { name = comment.trimmingCharacters(in: .whitespaces) }
            let cleanedAddress = (mailbox ?? "").trimmingCharacters(in: .whitespaces)
            if cleanedAddress.contains("@") {
                result.append(MailAddress(name: MailText.headerSafe(EncodedWords.decode(collapse(name))), address: cleanedAddress))
            }
            phrase = ""
            address = nil
            comment = ""
            token = ""
        }

        for character in raw {
            if commentDepth > 0 {
                if character == "(" { commentDepth += 1 } else if character == ")" { commentDepth -= 1 }
                if commentDepth > 0 { comment.append(character) }
                continue
            }
            if inQuotes {
                if character == "\"" { inQuotes = false } else if character != "\\" { phrase.append(character) }
                continue
            }
            if inAngle {
                if character == ">" { inAngle = false; address = angle; angle = "" } else { angle.append(character) }
                continue
            }
            switch character {
            case "\"":
                phrase += token
                token = ""
                inQuotes = true
            case "(":
                commentDepth = 1
            case "<":
                phrase += token
                token = ""
                inAngle = true
            case ",", ";":
                finish()
            case ":":
                // Group display name: drop it, keep reading members.
                phrase = ""
                token = ""
            default:
                token.append(character)
            }
        }
        if inAngle { address = angle }
        finish()
        return result
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

// MARK: - Message-IDs

enum MessageIDs {
    /// Every `<id>` in a header (References, In-Reply-To), without brackets, in order. Values
    /// without brackets fall back to whitespace-separated tokens containing "@".
    static func list(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var ids: [String] = []
        var current: String?
        for character in raw {
            if character == "<" {
                current = ""
            } else if character == ">" {
                if let id = current?.trimmingCharacters(in: .whitespaces), isValid(id) { ids.append(id) }
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        if ids.isEmpty {
            ids = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
                .filter { $0.contains("@") && isValid($0) }
        }
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// A Message-ID that can be written into a header as `<id>`: not empty, no whitespace, no
    /// control characters, no angle brackets.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && !id.unicodeScalars.contains { scalar in
            scalar.properties.isWhitespace || MailText.isUnsafeInHeader(scalar) || scalar == "<" || scalar == ">"
        }
    }

    static func single(_ raw: String?) -> String {
        list(raw).first ?? ""
    }

    /// List-Id: the id inside the brackets ("CL <cl.lists.x>" → "cl.lists.x").
    static func listID(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
        if let open = raw.lastIndex(of: "<"), let close = raw.lastIndex(of: ">"), open < close {
            return String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return raw.lowercased()
    }
}

// MARK: - Dates

enum MailDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "EST": -5 * 60, "EDT": -4 * 60, "CST": -6 * 60, "CDT": -5 * 60,
        "MST": -7 * 60, "MDT": -6 * 60, "PST": -8 * 60, "PDT": -7 * 60, "CET": 60, "CEST": 120, "MET": 60, "MEST": 120,
    ]

    /// RFC 5322 dates and common variants: optional weekday, 2-digit years, missing seconds,
    /// named or numeric zones, trailing comments.
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        var text = raw
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]) }
        let tokens = text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var day: Int?
        var month: Int?
        var year: Int?
        var hour = 0, minute = 0, second = 0
        var offsetMinutes = 0
        var sawTime = false
        for token in tokens {
            let lower = token.lowercased()
            if let index = months.firstIndex(where: { lower.hasPrefix($0) }), month == nil, Int(token) == nil {
                month = index + 1
            } else if token.contains(":"), !sawTime {
                let parts = token.split(separator: ":").map { Int($0) }
                guard parts.count >= 2, let h = parts[0], let m = parts[1] else { continue }
                hour = h
                minute = m
                second = parts.count > 2 ? parts[2] ?? 0 : 0
                sawTime = true
            } else if (token.hasPrefix("+") || token.hasPrefix("-")) && token.count == 5, let value = Int(token.dropFirst()) {
                offsetMinutes = (value / 100 * 60 + value % 100) * (token.hasPrefix("-") ? -1 : 1)
            } else if let zone = zones[token.uppercased()] {
                offsetMinutes = zone
            } else if let number = Int(token) {
                if day == nil, number >= 1, number <= 31, month == nil || year == nil, token.count <= 2 {
                    day = number
                } else if year == nil {
                    year = token.count <= 2 ? (number < 50 ? 2000 + number : 1900 + number) : number
                }
            }
        }
        guard let day, let month, let year else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(secondsFromGMT: offsetMinutes * 60) else { return nil }
        calendar.timeZone = zone
        return calendar.date(from: components)
    }
}
