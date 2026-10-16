import Foundation

extension Message {
    /// Returns `self` if the response ended normally; throws `.refused` or `.truncated` otherwise.
    /// Check this (or `stopReason`) before trusting `content`: a refusal can arrive mid-stream with
    /// partial output that must be discarded.
    @discardableResult
    public func requireComplete() throws -> Message {
        switch stopReason {
        case .refusal?: throw ClaudeError.refused(stopDetails, message: self)
        case .maxTokens?, .modelContextWindowExceeded?: throw ClaudeError.truncated(message: self)
        default: return self
        }
    }

    /// Decodes the text of a structured-output response (`output_config.format`) as `T`.
    public func decodeJSON<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try requireComplete()
        let body = text
        do {
            return try decoder.decode(T.self, from: Data(body.utf8))
        } catch {
            throw ClaudeError.decoding("structured output did not decode as \(T.self): \(error)")
        }
    }
}

extension ClaudeClient {
    /// Streams a structured-output request and decodes the result. `request.outputFormat` must be set.
    public func structured<T: Decodable & Sendable>(
        _ type: T.Type, _ request: MessageRequest, context: CallContext = CallContext(),
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        guard request.outputFormat != nil else {
            throw ClaudeError.invalidArgument("structured(_:) needs request.outputFormat")
        }
        let message = try await streamMessage(request, context: context)
        return try message.decodeJSON(T.self, decoder: decoder)
    }
}
