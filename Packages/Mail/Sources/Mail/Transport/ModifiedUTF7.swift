import Foundation

/// IMAP mailbox names (RFC 3501 §5.1.3): printable ASCII as is, "&" as "&-", everything else as
/// UTF-16 in modified base64 ("," instead of "/") between "&" and "-". "Entwürfe" ⇄ "Entw&APw-rfe".
enum ModifiedUTF7 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,".utf8)
    private static let values: [UInt8: UInt8] = {
        var map: [UInt8: UInt8] = [:]
        for (index, byte) in alphabet.enumerated() { map[byte] = UInt8(index) }
        return map
    }()

    static func encode(_ name: String) -> String {
        var output = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            output += "&" + base64(bytes) + "-"
            pending.removeAll()
        }

        for scalar in name.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                output += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return output
    }

    /// Decodes a server name; returns it unchanged when it is not valid modified UTF-7.
    static func decode(_ name: String) -> String {
        guard name.contains("&") else { return name }
        var output = ""
        var index = name.startIndex
        while index < name.endIndex {
            let character = name[index]
            guard character == "&" else {
                output.append(character)
                index = name.index(after: index)
                continue
            }
            guard let end = name[index...].firstIndex(of: "-") else { return name }
            let encoded = name[name.index(after: index)..<end]
            if encoded.isEmpty {
                output.append("&")
            } else {
                guard let bytes = unbase64(Array(encoded.utf8)), bytes.count.isMultiple(of: 2) else { return name }
                var units: [UInt16] = []
                var position = 0
                while position < bytes.count {
                    units.append(UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
                    position += 2
                }
                output += String(decoding: units, as: UTF16.self)
            }
            index = name.index(after: end)
        }
        return output
    }

    private static func base64(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let b0 = bytes[index]
            let b1 = index + 1 < bytes.count ? bytes[index + 1] : 0
            let b2 = index + 2 < bytes.count ? bytes[index + 2] : 0
            output.append(alphabet[Int(b0 >> 2)])
            output.append(alphabet[Int((b0 & 0x03) << 4 | b1 >> 4)])
            if index + 1 < bytes.count { output.append(alphabet[Int((b1 & 0x0F) << 2 | b2 >> 6)]) }
            if index + 2 < bytes.count { output.append(alphabet[Int(b2 & 0x3F)]) }
            index += 3
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func unbase64(_ characters: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in characters {
            guard let value = values[character] else { return nil }
            buffer = buffer << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return output
    }
}
