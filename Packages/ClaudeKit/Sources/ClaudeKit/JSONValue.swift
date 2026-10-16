import Foundation

/// A JSON object: the wire form of every request and response model in ClaudeKit.
public typealias JSONObject = [String: JSONValue]

/// Any JSON value. Used for tool inputs, JSON schemas, and response blocks ClaudeKit does not model,
/// so they round-trip unchanged when a conversation is sent back to the API.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Accessors

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value && abs(value) < 9.0e15: Int(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject(minimumCapacity: elements.count)
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
            var object = JSONObject(minimumCapacity: keyed.allKeys.count)
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            if let count = unkeyed.count { array.reserveCapacity(count) }
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Int.self) {
            self = .int(value)
        } else if let value = try? single.decode(Double.self) {
            self = .double(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        case .bool(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .int(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .double(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .string(let value):
            var single = encoder.singleValueContainer()
            try single.encode(value)
        case .array(let values):
            var unkeyed = encoder.unkeyedContainer()
            for value in values { try unkeyed.encode(value) }
        case .object(let object):
            var keyed = encoder.container(keyedBy: AnyCodingKey.self)
            for (key, value) in object {
                try keyed.encode(value, forKey: AnyCodingKey(key))
            }
        }
    }
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - Serialization

extension JSONValue {
    /// Deterministic serialization: sorted keys, unescaped slashes, compact.
    ///
    /// Requests are always encoded this way so the same conversation produces the same bytes on every
    /// call, which keeps the prompt cache and preserved thinking valid.
    public func serialized() throws -> Data {
        try JSONValue.encoder.encode(self)
    }

    /// `serialized()` as a UTF-8 string.
    public func serializedString() throws -> String {
        String(decoding: try serialized(), as: UTF8.self)
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    /// Converts any `Encodable` value (for example a structured-output model) to a `JSONValue`.
    public init(encoding value: some Encodable) throws {
        let data = try JSONValue.encoder.encode(value)
        self = try JSONValue.parse(data)
    }

    /// Decodes this value as `T`.
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: serialized())
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Object helpers used by the wire models

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func object(_ key: String) -> JSONObject? { self[key]?.objectValue }
    func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }

    func requiredString(_ key: String, in context: String) throws -> String {
        guard let value = self[key]?.stringValue else {
            throw ClaudeError.decoding("\(context): missing string field \"\(key)\"")
        }
        return value
    }

    /// The entries whose keys are not in `known`.
    func excluding(_ known: Set<String>) -> JSONObject {
        filter { !known.contains($0.key) }
    }

    /// Sets `key` only when `value` is non-nil.
    mutating func set(_ key: String, _ value: JSONValue?) {
        if let value { self[key] = value }
    }

    /// Adds entries of `other` that are not already present.
    mutating func merge(missingFrom other: JSONObject) {
        for (key, value) in other where self[key] == nil {
            self[key] = value
        }
    }
}
