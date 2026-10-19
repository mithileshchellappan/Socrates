import StudyCore
import StudyUI
import SwiftUI

/// One document in the list column (docs/plan-docs.md §6 "List"): the title (13 semibold, one
/// line) and the added day trailing (SF Mono 11.5, tertiary); then the kind (12 medium, primary)
/// and the summary after ONE sparkle (12 secondary, one line). While the summary is pending the
/// summary is a skeleton bar; after a failure a secondary triangle with the reason as help.
struct DocumentRow: View {
    let document: StudyDocument
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: DocumentText.listDay(document.addedAt, now: now))
                    .font(.mono(11.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: DocumentText.kind(document.kind))
                    .font(.system(size: 12, weight: .medium))
                    .layoutPriority(1)
                state
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var state: some View {
        switch DocumentState(document) {
        case .failed(let reason):
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(Text(verbatim: reason))
                .accessibilityLabel(Text(verbatim: reason))
        case .pending:
            // The line's final size, redacted, no shimmer (DESIGN 6.6).
            Text(verbatim: "The summary of this document is written")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
        case .done:
            if !document.summary.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    AIMark()
                        .font(.system(size: 10))
                    Text(verbatim: document.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Where a document is, as the screen shows it.
enum DocumentState: Equatable {
    /// Its text is being read or its summary waits (for Claude Code, its turn, a usage limit).
    case pending
    case done
    /// Reading or summarising failed: the reason (one readable sentence).
    case failed(String)

    init(_ document: StudyDocument) {
        switch (document.textState, document.summaryState) {
        case (.failed, _), (_, .failed), (_, .skipped):
            let reason = document.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self = .failed(reason.isEmpty ? String(localized: "This file could not be read.") : reason)
        case (.done, .done):
            self = .done
        default:
            self = .pending
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
