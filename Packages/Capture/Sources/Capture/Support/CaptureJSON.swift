import Foundation

/// JSON coding for lecture package files: sorted, pretty-printed keys and ISO 8601 dates with
/// millisecond precision, so files are stable, diffable and readable by hand.
enum CaptureJSON {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractional))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? fractional.parse(string) { return date }
            if let date = try? whole.parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected an ISO 8601 date, got \(string)"
            )
        }
        return decoder
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try encoder().encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder().decode(type, from: data)
    }

    /// Writes `value` atomically (temporary file + rename): readers never see a partial file,
    /// and a crash mid-write leaves the previous version in place.
    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try encode(value).write(to: url, options: .atomic)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try decode(type, from: Data(contentsOf: url))
    }
}
