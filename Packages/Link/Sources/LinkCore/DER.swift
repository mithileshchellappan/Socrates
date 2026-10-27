import Foundation

/// The few DER encodings the self-signed certificate needs (X.690), written by hand: tag, length,
/// contents.
enum DER {
    static func sequence(_ parts: [Data]) -> Data {
        element(0x30, parts.reduce(Data(), +))
    }

    static func set(_ parts: [Data]) -> Data {
        element(0x31, parts.reduce(Data(), +))
    }

    /// A non-negative INTEGER from its big-endian bytes: leading zeros dropped, a zero byte put in
    /// front when the high bit is set.
    static func integer(_ bytes: Data) -> Data {
        var content = Data(bytes.drop { $0 == 0 })
        if content.isEmpty { content = Data([0]) }
        if let first = content.first, first & 0x80 != 0 { content.insert(0, at: content.startIndex) }
        return element(0x02, content)
    }

    static func integer(_ value: UInt8) -> Data {
        integer(Data([value]))
    }

    /// An OBJECT IDENTIFIER from its arcs (the first two folded into one byte, the rest base 128).
    static func objectIdentifier(_ arcs: [UInt]) -> Data {
        guard arcs.count >= 2 else { return element(0x06, Data()) }
        var content = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { content.append(base128(arc)) }
        return element(0x06, content)
    }

    static func utf8String(_ text: String) -> Data {
        element(0x0C, Data(text.utf8))
    }

    /// UTCTime, "YYMMDDHHMMSSZ" (dates through 2049, RFC 5280).
    static func utcTime(_ text: String) -> Data {
        element(0x17, Data(text.utf8))
    }

    /// GeneralizedTime, "YYYYMMDDHHMMSSZ" (dates from 2050, RFC 5280).
    static func generalizedTime(_ text: String) -> Data {
        element(0x18, Data(text.utf8))
    }

    /// A BIT STRING of whole bytes (no unused bits).
    static func bitString(_ bytes: Data) -> Data {
        element(0x03, Data([0]) + bytes)
    }

    /// An explicitly tagged, context-specific, constructed element `[tag]`.
    static func explicit(_ tag: UInt8, _ content: Data) -> Data {
        element(0xA0 | tag, content)
    }

    static func element(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 {
            bytes.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func base128(_ value: UInt) -> Data {
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return Data(bytes)
    }
}
