#if os(macOS)
import AppKit
import Observation
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// One Ask popover: the passage, the exchanges asked in it (follow-ups stack), the one streaming.
/// Closing it keeps nothing; Keep and Continue in Chat take the latest exchange.
@MainActor
@Observable
final class AskSession {
    struct Exchange: Identifiable {
        let id = UUID()
        var question: String
        var answer: String = ""
        var update: NotesAskUpdate?
        var isFinished: Bool { update?.isFinished ?? false }
    }

    let passage: NotesSelection
    let notesID: LectureNotes.ID
    let lectureID: Lecture.ID
    var field = ""
    var exchanges: [Exchange] = []
    /// The latest exchange was kept (Keep turns into nothing more to do).
    var kept: Set<UUID> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let asker: any LectureNotesAsking

    init(passage: NotesSelection, notesID: LectureNotes.ID, lectureID: Lecture.ID, asker: any LectureNotesAsking) {
        self.passage = passage
        self.notesID = notesID
        self.lectureID = lectureID
        self.asker = asker
    }

    var isAsking: Bool { exchanges.last.map { !$0.isFinished && $0.update?.error == nil } ?? false }

    /// A quick choice reads `Why? “entry-wise maximum”` (at most 6 words of the passage).
    static func title(for style: NotesAskStyle, passage: String) -> String {
        let words = passage.split(whereSeparator: \.isWhitespace)
        let quote = words.prefix(6).joined(separator: " ") + (words.count > 6 ? "…" : "")
        let name = switch style {
        case .simpler: String(localized: "Explain simpler")
        case .example: String(localized: "Example")
        case .why: String(localized: "Why?")
        }
        return "\(name) “\(quote)”"
    }

    func send(style: NotesAskStyle? = nil) {
        let typed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || style != nil, !isAsking else { return }
        field = ""
        let question = typed.isEmpty ? Self.title(for: style ?? .why, passage: passage.exact) : typed
        let earlier = exchanges.filter(\.isFinished).map { NotesAskExchange(question: $0.question, answer: $0.answer) }
        exchanges.append(Exchange(question: question))
        let request = NotesAskRequest(
            lectureID: lectureID, notesID: notesID, sectionKey: passage.sectionKey, passage: passage.exact,
            question: typed, style: style, earlier: earlier
        )
        let index = exchanges.count - 1
        let stream = asker.ask(request)
        task = Task { [weak self] in
            for await update in stream {
                guard let self, !Task.isCancelled, self.exchanges.indices.contains(index) else { return }
                self.exchanges[index].update = update
                if !update.text.isEmpty { self.exchanges[index].answer = update.text }
            }
        }
    }

    /// Esc, a click outside: the call stops, nothing stays.
    func close() {
        task?.cancel()
        task = nil
    }

    var latestFinished: Exchange? {
        exchanges.last.flatMap { $0.isFinished && !$0.answer.isEmpty ? $0 : nil }
    }
}

/// The Ask popover (docs/plan-lecture-notes.md §3, mockup 31): 340 pt, one focused field ("Ask
/// about the selection", then "Ask a follow-up…"), Explain simpler / Example / Why? that send at
/// once; each question in primary over Claude's answer streaming in grey with its sparkle (a
/// skeleton line before the first words); under the latest answer [Keep] (⌘↩) and [Continue in
/// Chat]. Past about 360 pt it scrolls.
struct AskPopoverView: View {
    @Bindable var session: AskSession
    let chips: NotesChipResolver
    let open: (NotesChipTarget) -> Void
    let keep: (AskSession.Exchange) -> Void
    let continueInChat: () -> Void
    @FocusState private var fieldFocused: Bool
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(
                session.exchanges.isEmpty ? String(localized: "Ask about the selection") : String(localized: "Ask a follow-up…"),
                text: $session.field
            )
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit { session.send() }
            HStack(spacing: 6) {
                Button("Explain simpler") { session.send(style: .simpler) }
                Button("Example") { session.send(style: .example) }
                Button("Why?") { session.send(style: .why) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.isAsking)
            .padding(.top, 8)
            if !session.exchanges.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.exchanges) { exchange in
                            exchangeView(exchange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .top) { Hairline() }
                .padding(.top, 12)
                if let latest = session.latestFinished {
                    HStack(spacing: 8) {
                        Button("Keep") { keep(latest) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(session.kept.contains(latest.id))
                        Button("Continue in Chat", action: continueInChat)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 9)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: 340, alignment: .leading)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder
    private func exchangeView(_ exchange: AskSession.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: exchange.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !exchange.answer.isEmpty {
                NotesAnswerView(text: exchange.answer, size: 13, chips: chips, open: open)
            } else if let until = exchange.update?.pausedUntil {
                Text("Paused until \(Text(verbatim: DayText.time(until, timeZone: timeZone)).font(.mono(11.5)).monospacedDigit())")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if exchange.update?.error == nil {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle").foregroundStyle(Color.ai).font(.system(size: 12))
                    Capsule().fill(.fill.secondary).frame(height: 10).frame(maxWidth: 220)
                }
                .accessibilityHidden(true)
            }
            if let error = exchange.update?.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(verbatim: error)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
