import ClaudeKit
import Foundation
import os
import StudyCore

/// The study pass's constants. Logs through `Log.logger(category: "study-pass")`; never logs
/// transcript text, quotes or slide text at `.public`.
public enum StudyPass {
    public static let moduleName = "StudyPass"

    /// Part of every unit's `input_hash`: bump it when a prompt or schema changes, so every unit
    /// is read again once.
    public static let promptVersion = 1

    static let log = Log.logger(category: "study-pass")
}

/// Runs the study pass over eligible lectures, one unit at a time, every call
/// `CallContext(purpose: stage.callPurpose, lectureID:, priority: .background)`. docs/plan-m4.md §3.
///
/// Contract for the app (integrator, Mac only): one instance with `ClaudeClient.studyPortal`;
/// `start()` in `startBackgroundWork` after the transcript pipeline; `wake()` when processing
/// finishes a lecture, after `Realigner.realign` and when availability turns ready;
/// `prefer(_:)` when a lecture opens in Review; `stop()` at quit.
///
/// Skeleton (contracts commit): workstream A fills in the planner, the stages, the verifiers and
/// the writes behind this surface.
public actor StudyPassPipeline {
    let services: StudyServices
    let client: ClaudeClient?
    let now: @Sendable () -> Date
    /// The lecture open in Review: its units go first.
    private(set) var preferred: Lecture.ID?

    public init(services: StudyServices, client: ClaudeClient?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.client = client
        self.now = now
    }

    /// Starts following lectures (transcripts, spans, deck pages, jobs); a first pass follows in
    /// the background. Returns at once.
    public func start() async {}

    /// Looks for work again (after processing, a realign, or the end of a usage pause).
    public func wake() async {}

    /// Puts this lecture's units first (the lecture open in Review); nil clears it.
    public func prefer(_ lectureID: Lecture.ID?) async {
        preferred = lectureID
        await wake()
    }

    /// Stops following and ends the loop; a unit in flight stays `pending` (nothing half-written).
    public func stop() {}
}
