import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Sendable, Hashable {
    /// `event:` field; nil when the event had none.
    public var event: String?
    /// `data:` lines joined with "\n".
    public var data: String
    public var id: String?

    public init(event: String?, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental SSE parser (WHATWG event-stream rules) fed with raw bytes.
///
/// Works on bytes and only decodes complete lines, so chunks may split anywhere, including inside a
/// multi-byte UTF-8 character or between `\r` and `\n`.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastByteWasCR = false
    private var eventName: String?
    private var dataLines: [String] = []
    private var hasData = false
    private var lastEventID: String?
    private var isFirstLine = true

    public init() {}

    /// Feeds bytes; returns the events completed by them.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = push(byte) { events.append(event) }
        }
        return events
    }

    /// Feeds one byte; returns an event when this byte completed one.
    public mutating func push(_ byte: UInt8) -> SSEEvent? {
        switch byte {
        case 0x0A:  // \n
            if lastByteWasCR {
                lastByteWasCR = false
                return nil  // second half of \r\n
            }
            return endLine()
        case 0x0D:  // \r
            lastByteWasCR = true
            return endLine()
        default:
            lastByteWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// Flushes at end of stream. An event without its terminating blank line is dispatched
    /// only when `dispatchIncomplete` is true (the spec discards it).
    public mutating func finish(dispatchIncomplete: Bool = false) -> SSEEvent? {
        var event: SSEEvent?
        if !line.isEmpty { event = endLine() }
        if event == nil, dispatchIncomplete { event = dispatch() }
        resetEvent()
        return event
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if isFirstLine {
            isFirstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }  // BOM
        }
        if line.isEmpty { return dispatch() }
        if line.first == 0x3A { return nil }  // ":" comment

        let fieldEnd = line.firstIndex(of: 0x3A) ?? line.endIndex
        let field = String(decoding: line[..<fieldEnd], as: UTF8.self)
        var valueStart = fieldEnd < line.endIndex ? line.index(after: fieldEnd) : line.endIndex
        if valueStart < line.endIndex, line[valueStart] == 0x20 { valueStart = line.index(after: valueStart) }
        let value = String(decoding: line[valueStart...], as: UTF8.self)

        switch field {
        case "event": eventName = value
        case "data":
            dataLines.append(value)
            hasData = true
        case "id":
            if !value.contains("\0") { lastEventID = value }
        default: break  // "retry" and unknown fields are ignored
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { resetEvent() }
        guard hasData else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastEventID)
    }

    private mutating func resetEvent() {
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        hasData = false
    }
}
