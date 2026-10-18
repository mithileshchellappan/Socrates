import StudyCore
import StudyUI
import SwiftUI

/// A submitted practice exam (mockup 19), pushed on its course's Progress with the sidebar back:
/// "71 of 90 points" and "1 h 24 min of 90 min", Review misses (filled: a round of the misses) and
/// Retake; then every question in exam order with its points and, for a miss, the chip to where it
/// was explained. A row opens the answer beside the model answer, then Claude's grade (grey, one
/// sparkle each); Change Points… in its context menu. No grade anywhere.
public struct PracticeExamResultsView: View {
    private let sessionID: StudySession.ID

    @Fetch private var data: PracticeData

    public init(sessionID: StudySession.ID) {
        self.sessionID = sessionID
        _data = Fetch(wrappedValue: PracticeData(), PracticeRequest(sessionID: sessionID))
    }

    public var body: some View {
        if let session = data.session {
            ResultsContent(session: session, data: data)
        } else {
            ContentUnavailableView {
                Image(systemName: "chart.bar")
            }
            .screenTitle(String(localized: "Practice exam"))
        }
    }
}

private struct ResultsContent: View {
    let session: StudySession
    let data: PracticeData

    @Environment(\.studyCoach) private var coach
    @Environment(\.openDestination) private var openDestination
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    /// Rows the student opened or closed (the first miss starts open).
    @State private var flipped: Set<Int> = []
    @State private var hovered: Int?
    @State private var changing: ChangePoints?
    @State private var isStarting = false

    private struct ChangePoints: Identifiable {
        let answer: StudyAnswer
        let maximum: Int
        var text: String
        var id: StudyAnswer.ID { answer.id }
    }

    var body: some View {
        let rows = self.rows
        let firstMiss = rows.firstIndex { $0.isMiss }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero(rows)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Questions")
                        .font(.title3.weight(.semibold))
                        .padding(.bottom, 4)
                    ForEach(rows) { row in
                        let isOpen = (row.index == firstMiss) != flipped.contains(row.index)
                        if row.index > 0 {
                            Hairline()
                                .padding(.leading, 38)
                                .padding(.trailing, 10)
                                .padding(.horizontal, -10)
                                .opacity(isOpen || hovered == row.index || hovered == row.index - 1 || isRowOpen(row.index - 1, firstMiss) ? 0 : 1)
                        }
                        ResultRow(row: row, lecture: row.question.lectureID.flatMap { data.lectures[$0] }, isOpen: isOpen, isHovered: hovered == row.index) {
                            if flipped.contains(row.index) { flipped.remove(row.index) } else { flipped.insert(row.index) }
                        }
                        .onHover { inside in
                            if inside { hovered = row.index } else if hovered == row.index { hovered = nil }
                        }
                        .contextMenu {
                            if coach != nil, let answer = row.answer, row.question.points > 0 {
                                Button("Change Points…") {
                                    changing = ChangePoints(answer: answer, maximum: row.question.points, text: CoachText.number(answer.points ?? 0))
                                }
                            }
                        }
                        if isOpen {
                            ResultDetail(row: row)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .padding(.horizontal, 22)
        }
        .screenTitle(String(localized: "Practice exam"), subtitle: subtitle)
        .agentContext(AgentContext(screen: .course, courseID: session.courseID, courseScreen: "progress"))
        .alert(String(localized: "Change Points…"), isPresented: Binding(get: { changing != nil }, set: { if !$0 { changing = nil } })) {
            TextField(String(localized: "Points"), text: Binding(get: { changing?.text ?? "" }, set: { changing?.text = $0 }))
            Button("Cancel", role: .cancel) { changing = nil }
            Button("Change") { applyChange() }
        } message: {
            if let changing {
                Text("of \(CoachText.points(changing.maximum))")
            }
        }
    }

    private func isRowOpen(_ index: Int, _ firstMiss: Int?) -> Bool {
        (index == firstMiss) != flipped.contains(index)
    }

    // MARK: Hero

    private func hero(_ rows: [ResultRowData]) -> some View {
        let scored = session.scorePoints ?? rows.compactMap { $0.answer?.points }.reduce(0, +)
        let used = Int((session.elapsed(at: session.endedAt ?? Date()) / 60).rounded())
        return HeroCard(spacing: 11, top: 15, bottom: 17) {
            HStack(alignment: .top, spacing: 34) {
                StatFigure(value: CoachFigure.count(scored), caption: Text("of \(CoachText.points(session.points))"))
                StatFigure(
                    value: CoachFigure.duration(minutes: used),
                    caption: session.minutes.map { Text("of \(DurationText.text(minutes: $0))") } ?? Text("Untimed")
                )
            }
            if coach != nil {
                HStack(spacing: 10) {
                    if rows.contains(where: \.isMiss) {
                        Button {
                            reviewMisses()
                        } label: {
                            HeroButtonLabel(title: String(localized: "Review misses"))
                        }
                        .heroButtonStyle()
                        .keyboardShortcut(.defaultAction)
                        .disabled(isStarting)
                    }
                    Button {
                        retake()
                    } label: {
                        HeroButtonLabel(title: String(localized: "Retake"))
                    }
                    .heroSecondaryButtonStyle()
                    .disabled(isStarting)
                }
                .padding(.top, 2)
            }
        }
    }

    /// "Data Centers · All lectures · Tue 19 Jan, 09:00".
    private var subtitle: String {
        let when = DayText.dayTime(session.startedAt, locale: locale, timeZone: timeZone)
        return [session.title, CoachText.source(session.scope), when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Rows

    private var rows: [ResultRowData] {
        session.questionIDs.enumerated().compactMap { index, id in
            guard let question = data.questions[id] else { return nil }
            let answer = data.answers.last { $0.questionID == id }
            return ResultRowData(index: index, question: question, answer: answer)
        }
    }

    // MARK: Actions

    private func reviewMisses() {
        guard let coach, !isStarting else { return }
        isStarting = true
        let scope = StudyScope(kind: .misses, courseIDs: session.courseID.map { [$0] } ?? [], sessionID: session.id)
        let open = openDestination
        Task {
            defer { isStarting = false }
            do {
                open(.practice(try await coach.startRound(scope)))
            } catch {
                CoachUILog.ui.error("Review misses failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func retake() {
        guard let coach, !isStarting else { return }
        isStarting = true
        let id = session.id
        let open = openDestination
        Task {
            defer { isStarting = false }
            do {
                open(.practice(try await coach.retake(id)))
            } catch {
                CoachUILog.ui.error("Retake failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyChange() {
        guard let coach, let changing else { return }
        self.changing = nil
        let text = changing.text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let points = Double(text) else { return }
        let score = min(1, max(0, points / Double(max(1, changing.maximum))))
        let id = changing.answer.id
        Task {
            do {
                try await coach.override(id, score: score)
            } catch {
                CoachUILog.ui.error("Change Points failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

struct ResultRowData: Identifiable {
    let index: Int
    let question: StudyQuestion
    let answer: StudyAnswer?

    var id: Int { index }

    /// Not full marks (a graded answer below its points, or no answer).
    var isMiss: Bool {
        guard let answer else { return true }
        guard answer.result != .pending, answer.grading != .pending else { return false }
        return (answer.score ?? 0) < 0.999
    }
}

/// [number | title | "9 / 12" | a miss's chip "L2 · 38:28"]; the examiner's question carries the
/// amber bar.
private struct ResultRow: View {
    let row: ResultRowData
    let lecture: Lecture?
    let isOpen: Bool
    let isHovered: Bool
    let toggle: () -> Void

    @Environment(\.openDestination) private var openDestination

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(row.index + 1)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            Text(row.question.title.isEmpty ? row.question.topic : row.question.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            points
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Group {
                if row.isMiss, let time = row.question.quoteTime, let lectureID = row.question.lectureID {
                    TimeChip(time, prefix: CoachText.lecturePrefix(lecture), showsPlayGlyph: false) {
                        openDestination(.lecture(lectureID, ReviewTarget(page: row.question.pageNumber, time: time, recordingID: row.question.recordingID)))
                    }
                }
            }
            .frame(width: 92, alignment: .trailing)
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 10)
        .background(
            isOpen || isHovered ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(.clear),
            in: UnevenRoundedRectangle(
                topLeadingRadius: 9, bottomLeadingRadius: isOpen ? 0 : 9, bottomTrailingRadius: isOpen ? 0 : 9, topTrailingRadius: 9,
                style: .continuous
            )
        )
        .overlay(alignment: .leading) {
            if row.question.origin == .oldExam {
                Rectangle().fill(Color.professor).frame(width: 3).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(isOpen ? "Close" : "Open"), toggle)
    }

    /// "9 / 12"; "– / 12" while Claude grades.
    private var points: Text {
        let maximum = row.question.points
        guard let answer = row.answer, answer.grading != .pending, let scored = answer.points ?? answer.score.map({ $0 * Double(maximum) }) else {
            return Text(verbatim: "– / \(maximum)")
        }
        return Text(verbatim: "\(CoachText.number(scored)) / \(maximum)")
    }
}

/// The open question: the prompt, your answer beside the model answer, then Claude's grade.
private struct ResultDetail: View {
    let row: ResultRowData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.question.prompt)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, row.question.origin == .oldExam ? 11 : 0)
                .overlay(alignment: .leading) {
                    if row.question.origin == .oldExam {
                        Rectangle().fill(Color.professor).frame(width: 3)
                    }
                }
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    label("Your answer")
                    yours
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
                        }
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    label("Model answer")
                    if !model.isEmpty {
                        AIBlock(text: model)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let answer = row.answer, answer.grading == .done, !answer.note.isEmpty {
                let parts = AIBlock.verdict(answer.note)
                AIBlock(text: parts.rest, lead: parts.lead)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .padding(.leading, 38)
        .padding(.trailing, 14)
        .background(QuietFill(), in: UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous))
        .padding(.horizontal, -10)
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The student's answer in words: the text, the picked option, the placed terms.
    private var yours: Text {
        switch row.answer?.response {
        case .text(let text)?:
            return Text(verbatim: text)
        case .choice(let index)?:
            return Text(verbatim: row.question.choices.indices.contains(index) ? row.question.choices[index] : "")
        case .labels(let labels)?:
            let boxes = row.question.diagram?.blanks ?? []
            let placed = boxes.compactMap { labels[$0.id] }
            return Text(verbatim: placed.joined(separator: ", "))
        case nil:
            return Text(verbatim: "–").foregroundStyle(.tertiary)
        }
    }

    /// The model answer: the written one, the right option, the boxes' terms.
    private var model: String {
        let written = row.question.modelAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return written }
        if let correct = row.question.correctChoice, row.question.choices.indices.contains(correct) {
            return row.question.choices[correct]
        }
        if let diagram = row.question.diagram {
            return diagram.blanks.map(\.text).joined(separator: ", ")
        }
        return ""
    }
}
