import Foundation

/// A source the tutor (and the mail chat, for lectures) cites after a claim, written in the answer
/// text as a marker the model copies from tool results and context blocks (docs/plan-m5.md §4):
///
/// | Marker | Meaning |
/// |---|---|
/// | `[[9a7d94d1 S13]]` | slide 13 of the lecture whose id starts with `9a7d94d1` |
/// | `[[9a7d94d1 37:59]]` | that moment on the lecture's first recording (`1:03:42` past an hour) |
/// | `[[9a7d94d1/b680d175 37:59]]` | that moment on another recording of the lecture |
/// | `[[web https://…]]` | a web page |
///
/// Parsing is pure; whether a marker may show is decided from the rows (ChatUI): the key must
/// name exactly one lecture, the slide be a page of its deck, the moment lie in the recording, a
/// web URL occur in a tool result of the same conversation. Anything else is removed, never shown.
public enum ChatCitation: Hashable, Sendable {
    /// A slide (1-based deck page) of a lecture, by the lecture's key.
    case slide(lecture: String, page: Int)
    /// A moment of a lecture, in whole seconds; `recording` is a recording's key, nil for the
    /// lecture's first recording.
    case moment(lecture: String, recording: String?, seconds: Int)
    /// A web page (http or https).
    case web(URL)

    /// The key of a lecture or recording id: its first 8 hex digits, lower case ("9a7d94d1").
    public static func key(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// The citation of a slide.
    public static func slide(_ lecture: Lecture.ID, page: Int) -> ChatCitation {
        .slide(lecture: key(lecture), page: page)
    }

    /// The citation of a moment (rounded down to the second); `recording` only when it is not the
    /// lecture's first.
    public static func moment(_ lecture: Lecture.ID, recording: Recording.ID? = nil, seconds: Double) -> ChatCitation {
        .moment(lecture: key(lecture), recording: recording.map(key), seconds: max(0, Int(seconds.rounded(.down))))
    }

    /// The lecture key, for lecture citations.
    public var lectureKey: String? {
        switch self {
        case .slide(let lecture, _), .moment(let lecture, _, _): lecture
        case .web: nil
        }
    }

    /// Whether this cites the lecture with `id`.
    public func cites(lecture id: Lecture.ID) -> Bool {
        lectureKey == Self.key(id)
    }

    /// The marker as the model writes it.
    public var marker: String {
        switch self {
        case .slide(let lecture, let page): "[[\(lecture) S\(page)]]"
        case .moment(let lecture, let recording, let seconds):
            "[[\(lecture)\(recording.map { "/" + $0 } ?? "") \(Self.clock(seconds))]]"
        case .web(let url): "[[web \(url.absoluteString)]]"
        }
    }

    /// "37:59", "1:03:42" (as `TimeChip` shows a moment).
    public static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// Seconds of "37:59" or "1:03:42"; nil otherwise.
    public static func seconds(_ clock: Substring) -> Int? {
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    /// The citation a marker's inside names ("9a7d94d1 S13", "web https://…"); nil when malformed.
    public init?(markerBody body: Substring) {
        let body = body.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("web ") {
            let text = body.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
            self = .web(url)
            return
        }
        let parts = body.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let ids = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(ids.count), ids.allSatisfy(Self.isKey) else { return nil }
        let lecture = String(ids[0])
        let recording = ids.count == 2 ? String(ids[1]) : nil
        let target = parts[1]
        if target.first == "S" || target.first == "s" {
            guard recording == nil, let page = Int(target.dropFirst()), page >= 1, page <= 9_999 else { return nil }
            self = .slide(lecture: lecture, page: page)
        } else if let seconds = Self.seconds(target) {
            self = .moment(lecture: lecture, recording: recording, seconds: seconds)
        } else {
            return nil
        }
    }

    static func isKey(_ text: Substring) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// The answer as text and citations in order. Markers that do not parse stay text; adjacent
    /// text runs are merged; a space before a citation stays in the text before it.
    public static func pieces(of text: String) -> [ChatAnswerPiece] {
        var pieces: [ChatAnswerPiece] = []
        var pending = ""
        var rest = text[...]
        while let open = rest.range(of: "[[") {
            guard let close = rest[open.upperBound...].range(of: "]]") else { break }
            let body = rest[open.upperBound..<close.lowerBound]
            pending += rest[..<open.lowerBound]
            if !body.contains("[["), !body.contains("\n"), let citation = ChatCitation(markerBody: body) {
                if !pending.isEmpty { pieces.append(.text(pending)) }
                pending = ""
                pieces.append(.citation(citation))
                rest = rest[close.upperBound...]
            } else {
                pending += "[["
                rest = rest[open.upperBound...]
            }
        }
        pending += rest
        if !pending.isEmpty { pieces.append(.text(pending)) }
        return pieces
    }

    /// Every citation in `text`, in order (duplicates kept).
    public static func citations(in text: String) -> [ChatCitation] {
        pieces(of: text).compactMap(\.citation)
    }
}

/// A piece of an answer: plain text (Markdown) or one citation.
public enum ChatAnswerPiece: Hashable, Sendable {
    case text(String)
    case citation(ChatCitation)

    public var citation: ChatCitation? {
        if case .citation(let citation) = self { return citation }
        return nil
    }
}
