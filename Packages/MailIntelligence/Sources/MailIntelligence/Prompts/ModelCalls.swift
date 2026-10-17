import ClaudeKit
import Foundation
import StudyCore

/// Structured-output calls to Haiku and the `api_call` row each one left.
///
/// ClaudeKit reports every call to the app's `CostLedger`, which writes an `api_call` row with the
/// response's `request-id`; the row's id is found by that request id and written back to the mail
/// rows the call decided (`routing_api_call_id`, `extraction_api_call_id`, `mail_draft.api_call_id`).
struct ModelCaller: Sendable {
    let client: ClaudeClient
    let database: any DatabaseReader

    struct Answer<Value: Sendable>: Sendable {
        var value: Value
        var apiCallID: APICall.ID?
    }

    /// Streams `request` (which must set `outputFormat`) and decodes the JSON answer. A refused,
    /// truncated or undecodable answer throws `CallFailure` carrying the call's `api_call` id.
    func structured<Value: Decodable & Sendable>(_ type: Value.Type, _ request: MessageRequest, purpose: String) async throws -> Answer<Value> {
        let message = try await client.streamMessage(request, context: CallContext(purpose: purpose))
        let callID = try? await APICallLink.callID(requestID: message.requestID, purpose: purpose, in: database)
        do {
            return Answer(value: try message.decodeJSON(Value.self), apiCallID: callID)
        } catch {
            throw CallFailure(underlying: error, apiCallID: callID)
        }
    }
}

/// A call that returned but could not be used.
struct CallFailure: Error, CustomStringConvertible {
    var underlying: any Error
    var apiCallID: APICall.ID?

    var description: String { String(describing: underlying) }
}

enum APICallLink {
    /// The `api_call` row the ledger wrote for the response with `requestID`.
    static func callID(requestID: String?, purpose: String, in database: any DatabaseReader) async throws -> APICall.ID? {
        guard let requestID, !requestID.isEmpty else { return nil }
        return try await database.read { db in
            try APICall
                .where { $0.requestID.eq(String?.some(requestID)) && $0.purpose.eq(purpose) }
                .order { $0.createdAt.desc() }
                .select(\.id)
                .fetchOne(db)
        }
    }
}

/// JSON schemas of the structured outputs (every object closed and fully required, as
/// `output_config.format` needs; optional values are nullable instead).
enum Schemas {
    static func nullable(_ schema: JSONValue) -> JSONValue {
        ["anyOf": [schema, ["type": "null"]]]
    }

    static func object(_ properties: JSONObject) -> JSONValue {
        [
            "type": "object",
            "additionalProperties": false,
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "properties": .object(properties),
        ]
    }

    static func stringEnum(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string))]
    }
}
