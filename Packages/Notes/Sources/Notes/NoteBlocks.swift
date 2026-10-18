import Foundation
import StudyCore

/// The pure parts of the blocks ⇄ editor mapping (docs/plan-m6.md §4).
///
/// - `block(…)` builds a block from an editor paragraph: `text` is the runs' texts concatenated
///   (attachments add nothing), and a paragraph of unstyled text keeps `inlines` nil, so an M1
///   note re-encodes byte for byte.
/// - `reconcile(_:previous:)` keeps every block the student did not change exactly as it was
///   (same value, so the same JSON): a block counts as unchanged when the editor shows it the same
///   way (`EditorForm`), e.g. `level` nil and 0 or `checked` nil and false.
public enum NoteBlocks {
    /// A block from an editor paragraph's runs.
    public static func block(kind: NoteBlock.Kind, level: Int? = nil, checked: Bool? = nil, runs: [NoteInline]) -> NoteBlock {
        let inlines = normalized(runs)
        let text = inlines.map(\.text).joined()
        let isPlain = inlines.allSatisfy { $0.type == .text && ($0.marks ?? []).isEmpty }
        return NoteBlock(
            type: kind,
            text: text,
            level: level,
            checked: checked,
            inlines: isPlain ? nil : inlines
        )
    }

    /// Adjacent text runs with the same marks merged, empty text runs dropped, empty mark lists
    /// as nil, marks in a stable order.
    public static func normalized(_ runs: [NoteInline]) -> [NoteInline] {
        var result: [NoteInline] = []
        for var run in runs {
            if let marks = run.marks {
                let unique = Array(Set(marks)).sorted { $0.rawValue < $1.rawValue }
                run.marks = unique.isEmpty ? nil : unique
            }
            if run.type == .text {
                guard !run.text.isEmpty else { continue }
                if let last = result.last, last.type == .text, last.marks == run.marks {
                    result[result.count - 1].text += run.text
                    continue
                }
            }
            result.append(run)
        }
        return result
    }

    /// What the editor shows of a block: two blocks with the same form look and behave the same.
    public struct EditorForm: Hashable, Sendable {
        var type: NoteBlock.Kind
        var level: Int
        var checked: Bool
        var runs: [NoteInline]
        var attachment: NoteAttachment?
        var source: SourceRef?
    }

    public static func form(_ block: NoteBlock) -> EditorForm {
        let isList = block.type == .bullet || block.type == .numbered || block.type == .checklist
        let level: Int = switch block.type {
        case .heading: min(max(block.level ?? 1, 1), 3)
        case _ where isList: max(block.level ?? 0, 0)
        default: block.level ?? 0
        }
        let runs = normalized(block.inlines ?? [NoteInline(text: block.text)])
        return EditorForm(
            type: block.type,
            level: level,
            checked: block.type == .checklist ? block.checked == true : false,
            runs: runs,
            attachment: block.attachment,
            source: block.source
        )
    }

    /// `blocks` with every block that is unchanged from one of `previous` replaced by that block.
    public static func reconcile(_ blocks: [NoteBlock], previous: [NoteBlock]) -> [NoteBlock] {
        guard !previous.isEmpty else { return blocks }
        var available: [EditorForm: [Int]] = [:]
        for (index, block) in previous.enumerated() {
            available[form(block), default: []].append(index)
        }
        return blocks.enumerated().map { index, block in
            let key = form(block)
            guard var candidates = available[key], !candidates.isEmpty else { return block }
            // The same position first, else the earliest unused one.
            let pick = candidates.firstIndex(of: index) ?? 0
            let old = candidates.remove(at: pick)
            available[key] = candidates
            return previous[old]
        }
    }

    /// True when the two bodies are the same to the editor (nothing to save).
    public static func sameContent(_ lhs: [NoteBlock], _ rhs: [NoteBlock]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 == $1 || form($0) == form($1) }
    }
}
