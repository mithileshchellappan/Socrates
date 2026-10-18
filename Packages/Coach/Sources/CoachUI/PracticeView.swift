#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import StudyCore
import StudyUI
import SwiftUI

/// A practice round (mockup 15), full window: one question at a time from the student's own
/// lectures. Title "Practice", subtitle "Data Centers · 4 / 12", End. Zone 1: the course dot,
/// "Lecture 2 · Paravirtualization" and the topic's dots, the question, its four choices (1–4) or
/// the answer field (⌘↩). Zone 2 once answered: the slide, then the professor's own words under
/// an amber bar (the transcript's corrections drawn as ~~old~~ new) and the explanation in grey
/// with one sparkle; a written answer shows Claude's grade as that grey block (the model answer
/// while it waits) and Count as wrong. Next question (→); Space plays the professor's sentence.
public struct PracticeView: View {
    private let sessionID: StudySession.ID
    private let fixedNow: Date?

    @Fetch private var data: PracticeData

    /// - Parameter now: a fixed "now" (renders); nil follows the clock.
    public init(sessionID: StudySession.ID, now: Date? = nil) {
        self.sessionID = sessionID
        fixedNow = now
        _data = Fetch(wrappedValue: PracticeData(), PracticeRequest(sessionID: sessionID))
    }

    public var body: some View {
        PracticeContent(data: data, fixedNow: fixedNow)
    }
}

// MARK: - Rows

struct PracticeData: Hashable, Sendable {
    var session: StudySession?
    var questions: [StudyQuestion.ID: StudyQuestion] = [:]
    /// The session's answers, oldest first.
    var answers: [StudyAnswer] = []
    var courses: [Course.ID: Course] = [:]
    var lectures: [Lecture.ID: Lecture] = [:]
    var decks: [Deck.ID: Deck] = [:]
    var segments: [TranscriptSegment.ID: TranscriptSegment] = [:]
    /// The questions of the lectures asked about (a topic's mastery counts all of its questions).
    var mates: [StudyQuestion] = []

    /// The answer given at `position` (the n-th answer of a question asked n times so far).
    func answer(at position: Int) -> StudyAnswer? {
        guard let session, session.questionIDs.indices.contains(position) else { return nil }
        let questionID = session.questionIDs[position]
        let occurrence = session.questionIDs[..<position].filter { $0 == questionID }.count
        let given = answers.filter { $0.questionID == questionID }
        return given.indices.contains(occurrence) ? given[occurrence] : nil
    }

    func mastery(of question: StudyQuestion, at now: Date) -> TopicMastery {
        guard let key = question.topicKey else { return .unseen }
        return TopicMastery.of(mates.filter { $0.topicKey == key }, at: now)
    }
}

struct PracticeRequest: FetchKeyRequest {
    let sessionID: StudySession.ID

    func fetch(_ db: Database) throws -> PracticeData {
        var data = PracticeData()
        guard let session = try StudySession.find(sessionID).fetchOne(db) else { return data }
        data.session = session
        let ids = Array(Set(session.questionIDs))
        let questions = try StudyQuestion.where { $0.id.in(ids) }.fetchAll(db)
        data.questions = Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessionID = StudySession.ID?.some(sessionID)
        data.answers = try StudyAnswer.where { $0.sessionID.eq(sessionID) }.order(by: \.answeredAt).fetchAll(db)
        let courses = try Course.all.fetchAll(db)
        data.courses = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lectureIDs = Array(Set(questions.compactMap(\.lectureID)))
        if !lectureIDs.isEmpty {
            let lectures = try Lecture.where { $0.id.in(lectureIDs) }.fetchAll(db)
            data.lectures = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let optional = lectureIDs.map { Lecture.ID?.some($0) }
            data.mates = try StudyQuestion.where { $0.lectureID.in(optional) && $0.retiredAt.is(nil) }.fetchAll(db)
        }
        let deckIDs = Array(Set(questions.compactMap(\.deckID)))
        if !deckIDs.isEmpty {
            let decks = try Deck.where { $0.id.in(deckIDs) }.fetchAll(db)
            data.decks = Dictionary(decks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let segmentIDs = Array(Set(questions.compactMap(\.transcriptSegmentID)))
        if !segmentIDs.isEmpty {
            let segments = try TranscriptSegment.where { $0.id.in(segmentIDs) }.fetchAll(db)
            data.segments = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return data
    }
}

// MARK: - Screen

/// An answer given on screen before its row lands.
private struct LocalAnswer: Equatable {
    var position: Int
    var response: StudyResponse
}

private struct PracticeContent: View {
    let data: PracticeData
    let fixedNow: Date?

    @Environment(\.studyCoach) private var coach
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    @State private var local: LocalAnswer?
    @State private var shownAt = Date()
    @State private var draft = ""
    @State private var player = SentencePlayer()
    @FocusState private var isEditing: Bool

    var body: some View {
        Group {
            if let session = data.session, let question = currentQuestion {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        questionZone(question, session: session)
                        if let response = response {
                            WhyZone(
                                question: question, answer: data.answer(at: position), response: response, data: data,
                                isLast: position + 1 >= session.questionIDs.count,
                                countAsWrong: countAsWrong, next: next, play: { play(question) }
                            )
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 20)
                }
                .screenTitle(String(localized: "Practice"), subtitle: "\(session.title) · \(position + 1) / \(session.questionIDs.count)")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("End") { end() }
                    }
                }
                .background {
                    PracticeActionsPublisher(actions: actions(question, session: session))
                }
            } else {
                ContentUnavailableView {
                    Image(systemName: "brain")
                }
                .screenTitle(String(localized: "Practice"))
            }
        }
        .onChange(of: position) {
            shownAt = Date()
            draft = ""
            local = nil
            player.stop()
        }
        .onDisappear { player.stop() }
    }

    // MARK: State

    /// The question on screen (the last one once the round is through).
    private var position: Int {
        guard let session = data.session, !session.questionIDs.isEmpty else { return 0 }
        return min(session.position, session.questionIDs.count - 1)
    }

    private var currentQuestion: StudyQuestion? {
        guard let session = data.session, session.questionIDs.indices.contains(position) else { return nil }
        return data.questions[session.questionIDs[position]]
    }

    /// What was answered here: the answer row, else the answer just given.
    private var response: StudyResponse? {
        if let answer = data.answer(at: position) { return answer.response }
        if let local, local.position == position { return local.response }
        return nil
    }

    // MARK: Zone 1

    private func questionZone(_ question: StudyQuestion, session: StudySession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            eyebrow(question)
            Text(question.prompt)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
                .textSelection(.enabled)
            if question.format == .choice {
                choices(question)
            } else if let response, case .text(let text) = response {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
                    }
                    .textSelection(.enabled)
            } else if response == nil {
                answerField
            }
        }
    }

    private func eyebrow(_ question: StudyQuestion) -> some View {
        let lecture = question.lectureID.flatMap { data.lectures[$0] }
        let place: String = {
            if let number = lecture?.number { return String(localized: "Lecture \(number)") }
            return question.sourceTitle
        }()
        let topic = question.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = [place, topic].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 6) {
            CourseDot(course: data.courses[question.courseID], size: 7)
            Text(line)
                .lineLimit(1)
            if question.topicKey != nil {
                MasteryDots(data.mastery(of: question, at: fixedNow ?? Date()))
                    .fixedSize()
                    .padding(.leading, 6)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func choices(_ question: StudyQuestion) -> some View {
        let picked: Int? = if case .choice(let index)? = response { index } else { nil }
        return VStack(spacing: 6) {
            ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                ChoiceRow(
                    number: index + 1, text: choice,
                    state: picked == nil ? .open : (index == question.correctChoice ? .right : (index == picked ? .wrong : .dim)),
                    isPicked: index == picked
                ) {
                    answer(.choice(index))
                }
                .disabled(picked != nil || coach == nil)
            }
        }
    }

    private var answerField: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($isEditing)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(minHeight: 96)
                .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isEditing ? 1 : 0.5)
                }
            if coach != nil {
                Button("Submit") { submitDraft() }
                    .heroSecondaryButtonStyle()
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { isEditing = true }
    }

    // MARK: Actions

    private func answer(_ response: StudyResponse) {
        guard let coach, let session = data.session, let question = currentQuestion, self.response == nil else { return }
        local = LocalAnswer(position: position, response: response)
        isEditing = false
        let seconds = max(1, Date().timeIntervalSince(shownAt))
        Task {
            do {
                try await coach.answer(response, to: question.id, in: session.id, seconds: seconds)
            } catch {
                local = nil
                CoachUILog.ui.error("Answer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer(.text(text))
    }

    private func next() {
        guard let session = data.session, response != nil else { return }
        let following = position + 1
        guard following < session.questionIDs.count else {
            end()
            return
        }
        guard let services else { return }
        let id = session.id
        Task {
            do {
                try await StudySessionRepository(store: services.records).setPosition(id, following)
            } catch {
                CoachUILog.ui.error("Next question failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// End: the round ends (its plan block is done) and the screen it came from opens again.
    private func end() {
        guard let session = data.session else { return }
        player.stop()
        let destination: StudyDestination = if session.blockID != nil {
            .today
        } else if let course = session.courseID {
            .courseProgress(course)
        } else {
            .study
        }
        let coach = coach
        let open = openDestination
        Task {
            if let coach, session.state.isOpen {
                do {
                    try await coach.end(session.id)
                } catch {
                    CoachUILog.ui.error("End failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            open(destination)
        }
    }

    private var countAsWrong: (() -> Void)? {
        guard let coach, let answer = data.answer(at: position), currentQuestion?.format.isWritten == true,
              answer.result != .wrong, answer.overriddenAt == nil
        else { return nil }
        return {
            Task {
                do {
                    try await coach.override(answer.id, score: 0)
                } catch {
                    CoachUILog.ui.error("Count as wrong failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func play(_ question: StudyQuestion) {
        guard let services, let recordingID = question.recordingID, let start = question.quoteTime else { return }
        player.play(recordingID: recordingID, from: start, to: question.quoteEnd, services: services)
    }

    private func actions(_ question: StudyQuestion, session: StudySession) -> PracticeActions {
        let answered = response != nil
        var actions = PracticeActions(isEditingText: isEditing || isSearchFieldFocused)
        if question.format == .choice, !answered, coach != nil {
            let count = question.choices.count
            actions.pick = { index in if index < count { answer(.choice(index)) } }
        }
        if question.format.isWritten, !answered, coach != nil {
            actions.submitAnswer = { submitDraft() }
        }
        if answered, question.recordingID != nil, question.quoteTime != nil {
            actions.playSentence = { play(question) }
        }
        if answered {
            actions.next = { next() }
        }
        actions.end = { end() }
        return actions
    }
}

// MARK: - Choices

/// A choice (mockup `.opt`): its key, its text; answered, the pick keeps the neutral fill with a
/// grey cross, the right one is semibold with the green check, the others dim.
struct ChoiceRow: View {
    enum Mark {
        case open, right, wrong, dim
    }

    let number: Int
    let text: String
    let state: Mark
    let isPicked: Bool
    var examPick = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                KeyCap(number: number, filled: examPick && isPicked)
                    .opacity(state == .dim ? 0.6 : 1)
                Text(text)
                    .fontWeight(state == .right || (examPick && isPicked) ? .semibold : .regular)
                    .foregroundStyle(state == .dim || (state == .wrong) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch state {
                case .right:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Right"))
                case .wrong:
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Wrong"))
                default:
                    EmptyView()
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 42)
            .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
                    .opacity(isPicked ? 0 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fill: AnyShapeStyle {
        isPicked ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(Color.contentBackground)
    }
}

// MARK: - Zone 2

/// Why: the slide beside the professor's words and the explanation (or Claude's grade).
private struct WhyZone: View {
    let question: StudyQuestion
    let answer: StudyAnswer?
    let response: StudyResponse
    let data: PracticeData
    let isLast: Bool
    let countAsWrong: (() -> Void)?
    let next: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if let deckID = question.deckID, let deck = data.decks[deckID], let page = question.pageNumber {
                QuestionSlide(deck: deck, page: page)
                    .frame(width: 232)
            }
            VStack(alignment: .leading, spacing: 9) {
                if question.format.isWritten {
                    verdict
                    professor
                } else {
                    professor
                    let explanation = question.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !explanation.isEmpty {
                        AIBlock(text: explanation)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if let countAsWrong {
                        Button("Count as wrong", action: countAsWrong)
                            .heroSecondaryButtonStyle()
                    }
                    Button(action: next) {
                        HStack(spacing: 6) {
                            Text(isLast ? String(localized: "End") : String(localized: "Next question"))
                                .fontWeight(.medium)
                            if !isLast {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .heroButtonStyle()
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 18)
        .overlay(alignment: .top) { Hairline() }
    }

    /// Claude's grade as one grey block; the model answer while it waits.
    @ViewBuilder
    private var verdict: some View {
        if let answer, answer.grading == .done, !answer.note.isEmpty {
            let parts = AIBlock.verdict(answer.note)
            AIBlock(text: parts.rest, lead: parts.lead)
        } else {
            let model = question.modelAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                AIBlock(text: model)
            }
        }
    }

    /// The professor's pin, name and moment, then the quote under the amber bar.
    @ViewBuilder
    private var professor: some View {
        let quote = question.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !quote.isEmpty {
            ProfessorLine(question: question, lecture: question.lectureID.flatMap { data.lectures[$0] }, course: data.courses[question.courseID])
            QuoteView(quote: quote, segment: question.transcriptSegmentID.flatMap { data.segments[$0] })
                .onTapGesture(perform: play)
        }
    }
}

/// [professor pin] Example [▶ 37:10]: the chip opens the lecture at the slide and second.
struct ProfessorLine: View {
    let question: StudyQuestion
    let lecture: Lecture?
    let course: Course?

    @Environment(\.openDestination) private var openDestination

    var body: some View {
        HStack(spacing: 7) {
            ProvenancePin(.professor)
            if let professor = course?.professors.first {
                Text(SourceTrailText.surname(professor))
            }
            if let time = question.quoteTime, let lectureID = question.lectureID {
                TimeChip(time, showsPlayGlyph: true) {
                    openDestination(.lecture(lectureID, ReviewTarget(page: question.pageNumber, time: time, recordingID: question.recordingID)))
                }
                .padding(.leading, 4)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// The professor's exact words in curly quotes under a 3 pt amber bar (DESIGN §5.1), the line's
/// corrections inside the quote drawn as ~~old~~ new (TranscriptPatch.runs within its span).
struct QuoteView: View {
    let quote: String
    let segment: TranscriptSegment?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(QuoteView.attributed(quote, segment: segment, colorScheme: colorScheme))
            .font(.system(size: 14))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .padding(.vertical, 1)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.professor)
                    .frame(width: 3)
            }
            .textSelection(.enabled)
    }

    static func attributed(_ quote: String, segment: TranscriptSegment?, colorScheme: ColorScheme) -> AttributedString {
        var result = AttributedString("“")
        guard let segment, let range = segment.originalText.range(of: quote) else {
            result += AttributedString(quote)
            result += AttributedString("”")
            return result
        }
        let original = segment.originalText
        let quoteStart = original.distance(from: original.startIndex, to: range.lowerBound)
        let quoteEnd = quoteStart + quote.count
        var offset = 0
        for run in TranscriptPatch.runs(segment.patches ?? [], in: original) {
            switch run {
            case .text(let plain):
                let start = offset
                let end = offset + plain.count
                offset = end
                let low = max(start, quoteStart)
                let high = min(end, quoteEnd)
                guard low < high else { continue }
                let from = plain.index(plain.startIndex, offsetBy: low - start)
                let to = plain.index(plain.startIndex, offsetBy: high - start)
                result += AttributedString(String(plain[from..<to]))
            case .corrected(let old, let new, _):
                let start = offset
                let end = offset + old.count
                offset = end
                guard start < quoteEnd, end > quoteStart else { continue }
                var struck = AttributedString(old)
                struck.swiftUI.foregroundColor = tertiary
                struck.swiftUI.strikethroughStyle = Text.LineStyle(pattern: .solid, color: tertiary)
                var inserted = AttributedString(new)
                inserted.swiftUI.backgroundColor = Color.green.opacity(colorScheme == .dark ? 0.18 : 0.14)
                result += struck
                result += AttributedString(" ")
                result += inserted
            }
        }
        result += AttributedString("”")
        return result
    }

    private static var tertiary: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }
}
