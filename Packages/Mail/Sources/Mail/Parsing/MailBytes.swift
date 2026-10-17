import Foundation

// Byte-level helpers for MIME: transfer decodings and charset decoding with fallbacks.

enum TransferEncoding {
    /// Decodes a part body by its Content-Transfer-Encoding (unknown encodings pass through).
    static func decode(_ bytes: ArraySlice<UInt8>, encoding: String?) -> [UInt8] {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": base64(bytes)
        case "quoted-printable": quotedPrintable(bytes)
        default: Array(bytes)
        }
    }

    private static let base64Values: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (index, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(byte)] = Int8(index)
        }
        // URL-safe variants seen in the wild.
        table[Int(UInt8(ascii: "-"))] = 62
        table[Int(UInt8(ascii: "_"))] = 63
        return table
    }()

    /// Lenient base64: skips whitespace and junk, stops at padding.
    static func base64<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 3 / 4)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            if byte == UInt8(ascii: "=") { break }
            let value = base64Values[Int(byte)]
            guard value >= 0 else { continue }
            buffer = (buffer << 6) | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return output
    }

    /// Decoded size of base64 text without decoding it.
    static func base64DecodedCount<C: Collection>(_ bytes: C) -> Int where C.Element == UInt8 {
        var count = 0
        for byte in bytes {
            if byte == UInt8(ascii: "=") { break }
            if base64Values[Int(byte)] >= 0 { count += 1 }
        }
        return count * 3 / 4
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// Quoted-printable (RFC 2045 §6.7): "=XX" escapes, "=" at line end is a soft break.
    static func quotedPrintable<C: Collection>(_ bytes: C, underscoreIsSpace: Bool = false) -> [UInt8] where C.Element == UInt8 {
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "=") {
                // Soft line break: "=" followed by optional whitespace and CRLF / LF.
                var look = index + 1
                while look < input.count, input[look] == 0x20 || input[look] == 0x09 { look += 1 }
                if look < input.count, input[look] == 0x0D || input[look] == 0x0A {
                    if input[look] == 0x0D, look + 1 < input.count, input[look + 1] == 0x0A { look += 1 }
                    index = look + 1
                    continue
                }
                if look >= input.count { index = look; continue }
                if index + 2 < input.count, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
                output.append(byte)
                index += 1
            } else if underscoreIsSpace, byte == UInt8(ascii: "_") {
                output.append(0x20)
                index += 1
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }
}

enum Charset {
    /// Text of `bytes` in the declared charset, with fallbacks: a Latin label on bytes that are
    /// valid UTF-8 with non-ASCII characters is taken as UTF-8 (a common mislabel); a decoding
    /// failure falls back to UTF-8, then windows-1252 (which never fails).
    static func decode(_ bytes: [UInt8], declared: String?) -> String {
        let hasHighBytes = bytes.contains { $0 >= 0x80 }
        guard hasHighBytes else { return String(decoding: bytes, as: UTF8.self) }
        let label = declared?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) ?? ""
        let encoding = label.isEmpty ? nil : stringEncoding(label)

        if encoding == nil || isLatinFamily(label) {
            if let utf8 = strictUTF8(bytes) { return utf8 }
        }
        if let encoding, encoding != .utf8, let text = String(bytes: bytes, encoding: encoding) {
            return text
        }
        if let utf8 = strictUTF8(bytes) { return utf8 }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        String(validating: bytes, as: UTF8.self)
    }

    private static func isLatinFamily(_ label: String) -> Bool {
        ["us-ascii", "ascii", "iso-8859-1", "iso8859-1", "latin1", "latin-1", "iso-8859-15", "windows-1252", "cp1252", "ansi_x3.4-1968"]
            .contains(label)
    }

    static func stringEncoding(_ label: String) -> String.Encoding? {
        switch label {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }
}

extension Array where Element == UInt8 {
    /// Index of the first occurrence of `pattern` at or after `start`.
    func firstIndex(of pattern: [UInt8], from start: Int = 0) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count else { return nil }
        let first = pattern[0]
        var index = start
        let last = count - pattern.count
        while index <= last {
            if self[index] == first {
                var match = true
                var offset = 1
                while offset < pattern.count {
                    if self[index + offset] != pattern[offset] { match = false; break }
                    offset += 1
                }
                if match { return index }
            }
            index += 1
        }
        return nil
    }
}
