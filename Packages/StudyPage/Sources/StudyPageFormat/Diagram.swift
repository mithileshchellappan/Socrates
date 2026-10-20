import Foundation

// A `diagram` (or `mermaid`) fence: a strict Mermaid subset (docs/plan-learn-more.md §2.4),
// parsed here and laid out natively (`DiagramLayout`). Accepted:
// - `flowchart TD|LR` (alias `graph`): nodes `A[box]`, `A(rounded)`, `A{decision}`,
//   `A((circle))`, `A[(store)]`; edges `-->`, `---`, `-.->`, `==>`, with `|label|` or
//   `-- label -->`; chains `A --> B --> C`;
// - `sequenceDiagram`: `participant X as Label` (or `actor`), `->>`, `-->>` (a reply), `-x` (a
//   lost message), `->` / `-->`, `Note over A,B:`, `Note right of A:`, `Note left of A:`;
// - `stateDiagram-v2` (or `stateDiagram`): `[*]`, `A --> B : event`, `state "Name" as A`.
// Refused (the block goes to repair): `classDef`, `style`, `class`, `click`, `linkStyle`,
// `subgraph`, HTML in labels, every other diagram type. Limits: 30 nodes, 60 edges, 40 messages.

public struct Diagram: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case flowchart
        case sequence
        case state
    }

    public enum Direction: Hashable, Sendable {
        /// Top to bottom.
        case down
        /// Left to right.
        case right
    }

    public enum Shape: Hashable, Sendable {
        case box, rounded, decision, circle, store
        /// A state diagram's `[*]`: a start dot or an end ring.
        case start, end
    }

    public struct Node: Hashable, Sendable {
        public var id: String
        public var label: String
        public var shape: Shape
    }

    public enum Line: Hashable, Sendable {
        case solid, dotted, thick
    }

    public struct Edge: Hashable, Sendable {
        public var from: String
        public var to: String
        public var label: String?
        public var line: Line
        public var hasArrow: Bool
    }

    public struct Participant: Hashable, Sendable {
        public var id: String
        public var label: String
    }

    public enum MessageStyle: Hashable, Sendable {
        /// `->>`: a call.
        case call
        /// `-->>`: a reply (dashed).
        case reply
        /// `-x`: lost.
        case lost
        /// `->` / `-->`: a line without an arrowhead.
        case plain(dashed: Bool)
    }

    public enum NotePlacement: Hashable, Sendable {
        case over, left, right
    }

    public enum SequenceItem: Hashable, Sendable {
        case message(from: String, to: String, text: String, style: MessageStyle)
        case note(over: [String], placement: NotePlacement, text: String)
    }

    public var kind: Kind
    public var direction: Direction
    public var nodes: [Node]
    public var edges: [Edge]
    public var participants: [Participant]
    public var items: [SequenceItem]

    public static let nodeLimit = 30
    public static let edgeLimit = 60
    public static let messageLimit = 40

    /// The diagram of a fence body, or why not (one short line for the repair call, with the line
    /// number).
    public static func parse(_ source: String) -> Result<Diagram, DiagramError> {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let headerIndex = lines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("%%") }) else {
            return .failure(DiagramError("diagram: empty"))
        }
        let header = lines[headerIndex]
        let words = header.split(separator: " ").map { $0.lowercased() }
        var parser = DiagramParser(lines: Array(lines[(headerIndex + 1)...]), firstLine: headerIndex + 2)
        do {
            switch words.first {
            case "flowchart", "graph":
                let direction: Direction = switch words.dropFirst().first {
                case "lr", "rl": .right
                case "td", "tb", "bt", nil: .down
                default: throw DiagramError("diagram: unknown direction \"\(words[1])\" on line \(headerIndex + 1)")
                }
                return .success(try parser.flowchart(direction: direction))
            case "sequencediagram":
                return .success(try parser.sequence())
            case "statediagram-v2", "statediagram":
                return .success(try parser.state())
            default:
                return .failure(DiagramError("diagram: only flowchart, sequenceDiagram and stateDiagram-v2 are drawn"))
            }
        } catch let error as DiagramError {
            return .failure(error)
        } catch {
            return .failure(DiagramError("diagram: unreadable"))
        }
    }

    /// For VoiceOver: "Guest kernel block, then Translated before?; …" / "P1 sends m1 to P2".
    public var spokenDescription: String {
        switch kind {
        case .flowchart, .state:
            let names = Dictionary(nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            return edges.map { edge in
                let from = names[edge.from] ?? edge.from
                let to = names[edge.to] ?? edge.to
                return edge.label.map { "\(from) to \(to), \($0)" } ?? "\(from) to \(to)"
            }.joined(separator: "; ")
        case .sequence:
            let names = Dictionary(participants.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            return items.map { item in
                switch item {
                case .message(let from, let to, let text, _): "\(names[from] ?? from) sends \(text) to \(names[to] ?? to)"
                case .note(let over, _, let text): "Note over \(over.map { names[$0] ?? $0 }.joined(separator: " and ")): \(text)"
                }
            }.joined(separator: "; ")
        }
    }
}

public struct DiagramError: Error, Hashable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

struct DiagramParser {
    let lines: [String]
    let firstLine: Int
    var nodes: [Diagram.Node] = []
    var edges: [Diagram.Edge] = []
    var participants: [Diagram.Participant] = []
    var items: [Diagram.SequenceItem] = []
    private var starts = 0
    private var ends = 0

    init(lines: [String], firstLine: Int) {
        self.lines = lines
        self.firstLine = firstLine
    }

    func refuse(_ line: String, number: Int) throws {
        let lower = line.lowercased()
        let first = lower.split(separator: " ").first.map(String.init) ?? ""
        if ["classdef", "style", "class", "click", "linkstyle", "subgraph", "loop", "alt", "par", "opt", "rect", "critical", "break", "activate", "deactivate", "box"].contains(first) {
            throw DiagramError("diagram: \"\(first)\" is not drawn (line \(number))")
        }
        if lower.contains("<br") || lower.contains("</") || lower.contains("<b>") || lower.contains("<i>") {
            throw DiagramError("diagram: HTML in a label (line \(number))")
        }
    }

    // MARK: Flowchart

    mutating func flowchart(direction: Diagram.Direction) throws -> Diagram {
        for (offset, raw) in lines.enumerated() {
            let number = firstLine + offset
            let line = raw.hasSuffix(";") ? String(raw.dropLast()) : raw
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            try refuse(line, number: number)
            if line.lowercased() == "end" { throw DiagramError("diagram: \"end\" without a subgraph (line \(number))") }
            try flowLine(line, number: number)
        }
        try checkLimits()
        guard !nodes.isEmpty else { throw DiagramError("diagram: no nodes") }
        return Diagram(kind: .flowchart, direction: direction, nodes: nodes, edges: edges, participants: [], items: [])
    }

    /// `A[x] --> B{y} -->|z| C`: nodes and the edges between them.
    mutating func flowLine(_ line: String, number: Int) throws {
        var rest = Substring(line)
        var previous = try node(&rest, number: number)
        while true {
            rest = rest.drop { $0 == " " }
            guard !rest.isEmpty else { break }
            guard let (lineStyle, arrow, label) = try edgeOperator(&rest, number: number) else {
                throw DiagramError("diagram: unknown arrow near \"\(rest.prefix(12))\" on line \(number)")
            }
            rest = rest.drop { $0 == " " }
            let next = try node(&rest, number: number)
            edges.append(Diagram.Edge(from: previous, to: next, label: label, line: lineStyle, hasArrow: arrow))
            previous = next
        }
    }

    /// A node reference with an optional shape and label; registers it (the first label wins).
    mutating func node(_ rest: inout Substring, number: Int) throws -> String {
        let id = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !id.isEmpty else { throw DiagramError("diagram: a node name is missing on line \(number)") }
        rest = rest.dropFirst(id.count)
        var label: String?
        var shape: Diagram.Shape = .box
        let pairs: [(open: String, close: String, shape: Diagram.Shape)] = [
            ("((", "))", .circle), ("[(", ")]", .store), ("[", "]", .box), ("(", ")", .rounded), ("{", "}", .decision)
        ]
        for pair in pairs where rest.hasPrefix(pair.open) {
            let inner = rest.dropFirst(pair.open.count)
            guard let close = inner.range(of: pair.close) else {
                throw DiagramError("diagram: \"\(pair.open)\" is not closed on line \(number)")
            }
            label = Self.unquoted(String(inner[..<close.lowerBound]))
            shape = pair.shape
            rest = inner[close.upperBound...]
            break
        }
        let name = String(id)
        if let index = nodes.firstIndex(where: { $0.id == name }) {
            if let label, nodes[index].label == name {
                nodes[index].label = label
                nodes[index].shape = shape
            }
        } else {
            nodes.append(Diagram.Node(id: name, label: label ?? name, shape: shape))
        }
        return name
    }

    /// `-->`, `---`, `-.->`, `==>`, `-->|label|`, `-- label -->`.
    func edgeOperator(_ rest: inout Substring, number: Int) throws -> (Diagram.Line, Bool, String?)? {
        let operators: [(String, Diagram.Line, Bool)] = [
            ("-.->", .dotted, true), ("-.-", .dotted, false), ("==>", .thick, true), ("===", .thick, false),
            ("-->", .solid, true), ("---", .solid, false)
        ]
        for (op, style, arrow) in operators where rest.hasPrefix(op) {
            rest = rest.dropFirst(op.count)
            var label: String?
            if rest.hasPrefix("|") {
                let inner = rest.dropFirst()
                guard let close = inner.firstIndex(of: "|") else { throw DiagramError("diagram: a \"|label|\" is not closed on line \(number)") }
                label = Self.unquoted(String(inner[..<close]))
                rest = inner[inner.index(after: close)...]
            }
            return (style, arrow, label)
        }
        // `-- label -->`
        if rest.hasPrefix("-- ") {
            let inner = rest.dropFirst(3)
            for (op, style, arrow) in [("-->", Diagram.Line.solid, true), ("---", .solid, false)] {
                if let close = inner.range(of: " " + op) {
                    let label = Self.unquoted(String(inner[..<close.lowerBound]))
                    rest = inner[close.upperBound...]
                    return (style, arrow, label)
                }
            }
        }
        return nil
    }

    static func unquoted(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    func checkLimits() throws {
        guard nodes.count <= Diagram.nodeLimit else { throw DiagramError("diagram: more than \(Diagram.nodeLimit) nodes") }
        guard edges.count <= Diagram.edgeLimit else { throw DiagramError("diagram: more than \(Diagram.edgeLimit) edges") }
    }

    // MARK: State

    mutating func state() throws -> Diagram {
        for (offset, raw) in lines.enumerated() {
            let number = firstLine + offset
            let line = raw.hasSuffix(";") ? String(raw.dropLast()) : raw
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            try refuse(line, number: number)
            let lower = line.lowercased()
            if lower.hasPrefix("state ") {
                // state "Name" as A
                let body = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("\""), let close = body.dropFirst().firstIndex(of: "\"") {
                    let name = String(body[body.index(after: body.startIndex)..<close])
                    let after = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    guard after.lowercased().hasPrefix("as ") else { throw DiagramError("diagram: state \"…\" needs \"as Name\" (line \(number))") }
                    let id = after.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    try declareState(id, label: name, number: number)
                    continue
                }
                if body.contains("{") { throw DiagramError("diagram: composite states are not drawn (line \(number))") }
                try declareState(body, label: body, number: number)
                continue
            }
            if lower.hasPrefix("note ") { throw DiagramError("diagram: notes are not drawn in state diagrams (line \(number))") }
            if !line.contains("-->") {
                // "A : description": not drawn, never an error; else a state on its own.
                if line.contains(":") { continue }
                try declareState(line, label: line, number: number)
                continue
            }
            guard let arrow = line.range(of: "-->") else { throw DiagramError("diagram: unreadable line \(number)") }
            let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            var right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            var label: String?
            if let colon = right.firstIndex(of: ":") {
                label = right[right.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                right = right[..<colon].trimmingCharacters(in: .whitespaces)
            }
            let from = try stateID(left, isSource: true, number: number)
            let to = try stateID(right, isSource: false, number: number)
            edges.append(Diagram.Edge(from: from, to: to, label: label.flatMap { $0.isEmpty ? nil : $0 }, line: .solid, hasArrow: true))
        }
        try checkLimits()
        guard !nodes.isEmpty else { throw DiagramError("diagram: no states") }
        return Diagram(kind: .state, direction: .down, nodes: nodes, edges: edges, participants: [], items: [])
    }

    mutating func declareState(_ id: String, label: String, number: Int) throws {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw DiagramError("diagram: \"\(id)\" is not a state name (line \(number))")
        }
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index].label = label
        } else {
            nodes.append(Diagram.Node(id: id, label: label, shape: .rounded))
        }
    }

    /// `[*]` is a start (as a source) or an end (as a target): one of each per diagram.
    mutating func stateID(_ text: String, isSource: Bool, number: Int) throws -> String {
        if text == "[*]" {
            let id = isSource ? "__start" : "__end"
            if !nodes.contains(where: { $0.id == id }) {
                nodes.append(Diagram.Node(id: id, label: "", shape: isSource ? .start : .end))
            }
            return id
        }
        if !nodes.contains(where: { $0.id == text }) { try declareState(text, label: text, number: number) }
        return text
    }

    // MARK: Sequence

    mutating func sequence() throws -> Diagram {
        for (offset, raw) in lines.enumerated() {
            let number = firstLine + offset
            let line = raw.hasSuffix(";") ? String(raw.dropLast()) : raw
            guard !line.isEmpty, !line.hasPrefix("%%") else { continue }
            try refuse(line, number: number)
            let lower = line.lowercased()
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let body = line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                if let range = body.range(of: " as ") {
                    participant(
                        String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
                        label: String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces), declared: true
                    )
                } else {
                    participant(body, label: body, declared: true)
                }
                continue
            }
            if lower.hasPrefix("note ") {
                try note(line, number: number)
                continue
            }
            try message(line, number: number)
        }
        guard items.count <= Diagram.messageLimit else { throw DiagramError("diagram: more than \(Diagram.messageLimit) messages") }
        guard participants.count <= 12 else { throw DiagramError("diagram: more than 12 participants") }
        guard !participants.isEmpty else { throw DiagramError("diagram: no participants") }
        return Diagram(kind: .sequence, direction: .down, nodes: [], edges: [], participants: participants, items: items)
    }

    /// A participant (`declared`: its own line, whose label wins over a first mention).
    mutating func participant(_ id: String, label: String, declared: Bool = false) {
        guard !id.isEmpty else { return }
        if let index = participants.firstIndex(where: { $0.id == id }) {
            if declared { participants[index].label = label }
        } else {
            participants.append(Diagram.Participant(id: id, label: label.isEmpty ? id : label))
        }
    }

    mutating func note(_ line: String, number: Int) throws {
        guard let colon = line.firstIndex(of: ":") else { throw DiagramError("diagram: a note needs \": text\" (line \(number))") }
        let head = line[..<colon].dropFirst(5).trimmingCharacters(in: .whitespaces)
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let lower = head.lowercased()
        let placement: Diagram.NotePlacement
        let names: String
        if lower.hasPrefix("over ") {
            placement = .over
            names = String(head.dropFirst(5))
        } else if lower.hasPrefix("right of ") {
            placement = .right
            names = String(head.dropFirst(9))
        } else if lower.hasPrefix("left of ") {
            placement = .left
            names = String(head.dropFirst(8))
        } else {
            throw DiagramError("diagram: a note is \"over\", \"left of\" or \"right of\" (line \(number))")
        }
        let ids = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...2).contains(ids.count) else { throw DiagramError("diagram: a note names one or two participants (line \(number))") }
        for id in ids { participant(id, label: id) }
        items.append(.note(over: ids, placement: placement, text: text))
    }

    mutating func message(_ line: String, number: Int) throws {
        // The longest arrows first.
        let arrows: [(String, Diagram.MessageStyle)] = [
            ("-->>", .reply), ("->>", .call), ("--x", .lost), ("-x", .lost), ("--)", .reply), ("-)", .call),
            ("-->", .plain(dashed: true)), ("->", .plain(dashed: false))
        ]
        guard let colon = line.firstIndex(of: ":") else { throw DiagramError("diagram: a message needs \": text\" (line \(number))") }
        let head = String(line[..<colon])
        let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        for (arrow, style) in arrows {
            guard let range = head.range(of: arrow) else { continue }
            let from = head[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var to = head[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // Activation shorthand `->>+B` / `-->>-A`.
            if to.hasPrefix("+") || to.hasPrefix("-") { to.removeFirst() }
            guard !from.isEmpty, !to.isEmpty else { break }
            participant(from, label: from)
            participant(to, label: to)
            items.append(.message(from: from, to: to, text: text, style: style))
            return
        }
        throw DiagramError("diagram: unknown arrow on line \(number)")
    }
}
