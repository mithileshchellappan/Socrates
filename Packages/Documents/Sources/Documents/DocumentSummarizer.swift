import ClaudeKit
import Foundation
import StudyCore

/// Reads one kept document with one Haiku call and writes its title, kind, summary, related
/// courses, key facts and dates (docs/plan-docs.md §4 "Summary"): run in code by AppAgent's task
/// queue for an `agent_task` of kind `document` (one at a time, only with Claude Code). One
/// document per call, never a batch (a batch's JSON could outgrow the output cap). One-shot
/// `claude -p` (`--tools "" --safe-mode --no-session-persistence --json-schema`), Haiku 5.5, effort
/// low, `.background`, ≤ `maxTokens` output; the document's text goes in as delimited, escaped
/// data (≤ `inputCharacters`, picked by code), never instructions.
///
/// Contract skeleton (md architect): workstream A builds it.
public struct DocumentSummarizer: Sendable {
    /// `api_call.purpose` of the call.
    public static let purpose = "documents.summary"
    /// Part of `document.summary_hash`: a new prompt version reads documents again.
    public static let promptVersion = 1
    public static let model: ClaudeModel = .haiku55
    public static let effort: Effort = .low
    /// Room for the largest answer the schema allows (summary 400, 8 facts of 160, 12 dates of
    /// 100, 24 sections) with margin.
    public static let maxTokens = 4_000
    /// The most document text one call carries.
    public static let inputCharacters = 40_000

    /// What one run did (the queue finishes, pauses or fails the task with it).
    public enum Outcome: Sendable, Hashable {
        /// The document has its summary; `title` for the task's result.
        case done(title: String)
        /// Claude Code is paused (a usage limit, until then) or not ready: the task waits.
        case waiting(until: Date?)
        /// One readable sentence.
        case failed(String)
    }

    public let services: StudyServices
    public let client: ClaudeClient
    public let now: @Sendable () -> Date

    public init(services: StudyServices, client: ClaudeClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.client = client
        self.now = now
    }

    /// `document.summary_hash` for a text at this prompt version.
    public static func summaryHash(textSHA256: String) -> String {
        StudyDocument.summaryHash(textSHA256: textSHA256, promptVersion: promptVersion)
    }

    /// Reads the document and stores its summary (`DocumentRepository.setSummary`). A document
    /// that is gone, or whose `summary_hash` matches already, is `done` without a call.
    public func run(documentID: StudyDocument.ID) async -> Outcome {
        _ = documentID
        return .failed("The summary could not be written.")
    }
}
