import StudyCore
import StudyPageFormat

/// Checks a figure block of the notes for the writer (StudyPass's `NotesWriter`, installed by the
/// app): a `math` fence must parse in SwiftMath, a `diagram` in the Mermaid subset within its
/// limits, a `chart` as a `ChartSpec` within its limits with expressions our parser reads. Nil when
/// it renders, else one short line for the repair call ("diagram: unknown arrow on line 4").
/// Other fences are not figures (nil).
public struct StudyPageFigureChecker: NotesFigureChecking {
    public init() {}

    public func problem(in fence: NotesFence) -> String? {
        let body = fence.body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch fence.kind {
        case .math:
            guard !body.isEmpty else { return "math: empty" }
            return MathRendering.problem(body)
        case .diagram:
            switch Diagram.parse(body) {
            case .success: return nil
            case .failure(let error): return error.message
            }
        case .chart:
            switch ChartSpec.parse(body) {
            case .success: return nil
            case .failure(let error): return error.message
            }
        case .slide, .quote, .note, .check, .code:
            return nil
        }
    }
}
