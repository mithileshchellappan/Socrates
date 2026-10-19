import Filing
import os
import StudyCore
import SwiftUI

extension View {
    /// The window's one confirmation for Delete… (`FilingCenter.requestDelete`): it names what
    /// goes, and says so when the student's notes, ink or practice go with it. Delete deletes with
    /// Edit ▸ Undo. `willDelete` runs first (the app leaves a lecture's or a course's screen that
    /// is about to go), `didDelete` after (a course's calendar events go); a failure's sentence
    /// goes to `failed`.
    public func libraryDeleteConfirmation(
        center: FilingCenter,
        willDelete: @escaping @MainActor (StudyCore.LibraryItem) async -> Void = { _ in },
        didDelete: @escaping @MainActor (StudyCore.LibraryItem) async -> Void = { _ in },
        failed: @escaping @MainActor (String) -> Void = { _ in }
    ) -> some View {
        modifier(LibraryDeleteConfirmationModifier(center: center, willDelete: willDelete, didDelete: didDelete, failed: failed))
    }
}

struct LibraryDeleteConfirmationModifier: ViewModifier {
    let center: FilingCenter
    let willDelete: @MainActor (StudyCore.LibraryItem) async -> Void
    let didDelete: @MainActor (StudyCore.LibraryItem) async -> Void
    let failed: @MainActor (String) -> Void
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                center.pendingDeletion.map { LibraryDeleteText.title($0.item, $0.summary) } ?? "",
                isPresented: Binding(get: { center.pendingDeletion != nil }, set: { if !$0 { center.pendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: center.pendingDeletion
            ) { pending in
                Button("Delete", role: .destructive) { confirm(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                if let message = LibraryDeleteText.message(pending.item, pending.summary) {
                    Text(verbatim: message)
                }
            }
    }

    private func confirm(_ pending: FilingCenter.PendingDeletion) {
        let center = center
        let undoManager = undoManager
        Task {
            await willDelete(pending.item)
            do {
                try await center.delete(pending, undoManager: undoManager)
                await didDelete(pending.item)
            } catch {
                FilingCenter.log.error("Deleting failed: \(String(describing: error), privacy: .public)")
                failed(String(localized: "“\(pending.summary.title)” could not be deleted."))
            }
        }
    }
}

/// The confirmation's words: "Delete “Virtualization & IaaS” (88 slides)?" over "Your 3 notes and
/// the ink on its slides go too."; a course: "Delete “Data Centers”?" over "3 lectures and 2
/// recordings are deleted with it."; zero counts are left out.
enum LibraryDeleteText {
    static func title(_ item: StudyCore.LibraryItem, _ summary: DeletionSummary) -> String {
        if case .deck = item, summary.slides > 0 {
            return String(localized: "Delete “\(summary.title)” (\(counted(summary.slides, "slide")))?")
        }
        return String(localized: "Delete “\(summary.title)”?")
    }

    /// What goes with it besides the item itself; nil when nothing of the student's does.
    static func message(_ item: StudyCore.LibraryItem, _ summary: DeletionSummary) -> String? {
        var parts: [(text: String, isSingular: Bool)] = []
        switch item {
        case .deck:
            // The deck's own pages are in the title; what goes with them is the student's.
            if summary.notes > 0 {
                parts.append(summary.notes == 1 ? (String(localized: "your note"), true) : (String(localized: "your \(summary.notes) notes"), false))
            }
            if summary.inkPages > 0 { parts.append((String(localized: "the ink on its slides"), true)) }
            if summary.practisedQuestions > 0 {
                parts.append((counted(summary.practisedQuestions, "practised question"), summary.practisedQuestions == 1))
            }
            return sentence(parts)
        case .lecture:
            if summary.slides > 0 { parts.append((counted(summary.slides, "slide"), summary.slides == 1)) }
            if summary.recordings > 0 {
                parts.append((counted(summary.recordings, "recording"), summary.recordings == 1))
                parts.append((String(localized: "transcript"), true))
            }
            if summary.notes > 0 { parts.append((counted(summary.notes, "note"), summary.notes == 1)) }
            if summary.inkPages > 0 { parts.append((String(localized: "ink"), true)) }
            if summary.practisedQuestions > 0 {
                parts.append((counted(summary.practisedQuestions, "practised question"), summary.practisedQuestions == 1))
            }
            return sentence(parts, possessive: true)
        case .recording:
            // Notes and flags on it stay with the lecture.
            return String(localized: "Its transcript goes too.")
        case .course:
            // "3 lectures, 88 slides and 2 recordings are deleted with it." The student's notes
            // stay (unlinked from it), so they are not named.
            if summary.lectures > 0 { parts.append((counted(summary.lectures, "lecture"), summary.lectures == 1)) }
            if summary.slides > 0 { parts.append((counted(summary.slides, "slide"), summary.slides == 1)) }
            if summary.recordings > 0 { parts.append((counted(summary.recordings, "recording"), summary.recordings == 1)) }
            if summary.inkPages > 0 { parts.append((String(localized: "your ink"), true)) }
            if summary.practisedQuestions > 0 {
                parts.append((counted(summary.practisedQuestions, "practised question"), summary.practisedQuestions == 1))
            }
            guard !parts.isEmpty else { return nil }
            let list = parts.map(\.text).formatted(.list(type: .and))
            let subject = list.prefix(1).uppercased() + list.dropFirst()
            return parts.count == 1 && parts[0].isSingular
                ? String(localized: "\(subject) is deleted with it.")
                : String(localized: "\(subject) are deleted with it.")
        }
    }

    /// "Your 3 notes and the ink on its slides go too.", "Its 2 recordings, transcript and 3
    /// notes go too."
    private static func sentence(_ parts: [(text: String, isSingular: Bool)], possessive: Bool = false) -> String? {
        guard !parts.isEmpty else { return nil }
        let list = parts.map(\.text).formatted(.list(type: .and))
        let subject = possessive ? String(localized: "Its \(list)") : list.prefix(1).uppercased() + list.dropFirst()
        let single = parts.count == 1 && parts[0].isSingular
        return single ? String(localized: "\(subject) goes too.") : String(localized: "\(subject) go too.")
    }

    /// "88 slides", "1 slide".
    private static func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}
