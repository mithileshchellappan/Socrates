import StudyCore
import StudyUI
import SwiftUI

/// A practice exam in progress (mockup 18), full window with nothing but the exam: subtitle
/// "Data Centers · 2 / 8 · 1:16:05 left" (the time in SF Mono), [Flag | Pause]; "Question 2 ·
/// 12 points", the question in its form (a choice, a short or long answer, a diagram to label: drag
/// a term onto a box or click the box and type); a glass bar at the bottom: ‹ 1…8 › (filled =
/// answered, ring = current, a small flag) and Submit (filled once every question has an answer;
/// else it asks once). Answers save as they are typed; Pause covers the question; leaving pauses;
/// at 0:00 the exam submits itself and its results open.
public struct PracticeExamView: View {
    private let sessionID: StudySession.ID
    private let fixedNow: Date?

    @Fetch private var data: PracticeData

    /// - Parameter now: a fixed "now" (renders: the clock stands, nothing is written); nil follows
    ///   the clock.
    public init(sessionID: StudySession.ID, now: Date? = nil) {
        self.sessionID = sessionID
        fixedNow = now
        _data = Fetch(wrappedValue: PracticeData(), PracticeRequest(sessionID: sessionID))
    }

    public var body: some View {
        if let session = data.session {
            ExamContent(session: session, data: data, fixedNow: fixedNow)
        } else {
            ContentUnavailableView {
                Image(systemName: "brain")
            }
        }
    }
}

private struct ExamContent: View {
    let session: StudySession
    let data: PracticeData
    let fixedNow: Date?

    @Environment(\.studyCoach) private var coach
    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    /// What was typed or placed, ahead of the saved drafts.
    @State private var typed: [StudyQuestion.ID: StudyResponse] = [:]
    @State private var saving: Task<Void, Never>?
    @State private var confirmsSubmit = false
    @State private var isSubmitting = false
    @FocusState private var isEditing: Bool

    private var position: Int { min(max(0, session.position), max(0, session.questionIDs.count - 1)) }
    private var question: StudyQuestion? {
        session.questionIDs.indices.contains(position) ? data.questions[session.questionIDs[position]] : nil
    }
    private var isPaused: Bool { session.state == .paused }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                if let question {
                    questionView(question)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 26)
                        .padding(.bottom, 88)
                        .padding(.horizontal, 20)
                        .id(question.id)
                }
            }
            .scrollDisabled(isPaused)
            .overlay {
                if isPaused {
                    pausedCover
                }
            }
            QuestionBar(
                session: session, answered: answered, position: position,
                go: go, submit: requestSubmit, isSubmitting: isSubmitting
            )
            .padding(.bottom, 16)
        }
        .reservesBottomOverlaySpace(16 + 36 + 8)
        .modifier(ExamTitle(session: session, position: position, fixedNow: fixedNow))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    toggleFlag()
                } label: {
                    Label("Flag", systemImage: isFlagged ? "flag.fill" : "flag")
                        .labelStyle(.titleAndIcon)
                }
                .help("Flag (⇧⌘L)")
                Button {
                    pauseOrResume()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                }
                .help(isPaused ? "Resume" : "Pause")
            }
        }
        .confirmationDialog(String(localized: "Submit"), isPresented: $confirmsSubmit) {
            Button("Submit") { submit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let open = session.questionIDs.count - answered.count
            Text(open == 1 ? String(localized: "1 question has no answer") : String(localized: "\(open) questions have no answer"))
        }
        .background {
            PracticeActionsPublisher(actions: actions)
        }
        .task(id: ClockKey(state: session.state, resumedAt: session.resumedAt)) {
            await submitAtZero()
        }
        .onDisappear {
            flush()
            pause()
        }
    }

    // MARK: The question

    private func questionView(_ question: StudyQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Question \(position + 1) · \(CoachText.points(question.points))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question.prompt)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
                .padding(.leading, question.origin == .oldExam ? 14 : 0)
                .overlay(alignment: .leading) {
                    // The examiner's own question: the amber quote bar.
                    if question.origin == .oldExam {
                        Rectangle().fill(Color.professor).frame(width: 3).padding(.bottom, 16)
                    }
                }
            form(question)
        }
    }

    @ViewBuilder
    private func form(_ question: StudyQuestion) -> some View {
        switch question.format {
        case .choice:
            let picked: Int? = if case .choice(let index)? = response(question) { index } else { nil }
            VStack(spacing: 6) {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                    ChoiceRow(number: index + 1, text: choice, state: .open, isPicked: picked == index, examPick: true) {
                        set(.choice(index), for: question, now: true)
                    }
                }
            }
        case .label:
            if let diagram = question.diagram {
                LabelDiagramView(diagram: diagram, labels: Binding(
                    get: { if case .labels(let labels)? = response(question) { labels } else { [:] } },
                    set: { set(.labels($0), for: question, now: false) }
                ), isEditing: $isEditing)
            }
        default:
            ExamEditor(text: Binding(
                get: { if case .text(let text)? = response(question) { text } else { "" } },
                set: { set(.text($0), for: question, now: false) }
            ), minHeight: question.format == .short ? 96 : 300, isEditing: $isEditing)
        }
    }

    private var pausedCover: some View {
        ZStack {
            Rectangle()
                .fill(Color.contentBackground)
            Button {
                pauseOrResume()
            } label: {
                HeroButtonLabel(title: String(localized: "Resume"), systemImage: "play.fill")
            }
            .heroButtonStyle()
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Answers

    private func response(_ question: StudyQuestion) -> StudyResponse? {
        typed[question.id] ?? session.draft(for: question.id)
    }

    /// The questions with an answer (a saved or typed one that is not empty).
    private var answered: Set<StudyQuestion.ID> {
        Set(session.questionIDs.filter { id in
            guard let response = typed[id] ?? session.draft(for: id) else { return false }
            return !response.isEmpty
        })
    }

    private func set(_ response: StudyResponse, for question: StudyQuestion, now: Bool) {
        guard !isPaused, session.state.isOpen else { return }
        typed[question.id] = response
        saving?.cancel()
        let pending = typed
        saving = Task {
            if !now { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await save(pending)
        }
    }

    /// Writes the typed answers that differ from the saved drafts.
    private func save(_ pending: [StudyQuestion.ID: StudyResponse]) async {
        guard let services, fixedNow == nil else { return }
        let repository = StudySessionRepository(store: services.records)
        for (questionID, response) in pending where session.draft(for: questionID) != response {
            do {
                try await repository.saveDraft(session.id, question: questionID, response)
            } catch {
                CoachUILog.ui.error("Saving an exam answer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flush() {
        saving?.cancel()
        let pending = typed
        Task { await save(pending) }
    }

    // MARK: Moving, flags, the clock

    private var isFlagged: Bool { question.map { session.flags.contains($0.id) } ?? false }

    private func go(_ target: Int) {
        guard let services, fixedNow == nil, session.questionIDs.indices.contains(target), target != position else { return }
        isEditing = false
        let id = session.id
        Task {
            do {
                try await StudySessionRepository(store: services.records).setPosition(id, target)
            } catch {
                CoachUILog.ui.error("Moving in the exam failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func toggleFlag() {
        guard let services, fixedNow == nil, let question else { return }
        let id = session.id
        Task {
            do {
                try await StudySessionRepository(store: services.records).toggleFlag(id, question: question.id)
            } catch {
                CoachUILog.ui.error("Flag failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func pauseOrResume() {
        guard let services, fixedNow == nil, session.state.isOpen else { return }
        let id = session.id
        let paused = isPaused
        if !paused { flush() }
        Task {
            do {
                let repository = StudySessionRepository(store: services.records)
                if paused {
                    try await repository.resume(id, at: Date())
                } else {
                    try await repository.pause(id, at: Date())
                }
            } catch {
                CoachUILog.ui.error("Pause failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Leaving the exam pauses it (Progress then offers to resume it).
    private func pause() {
        guard let services, fixedNow == nil, session.state == .active else { return }
        let id = session.id
        Task {
            try? await StudySessionRepository(store: services.records).pause(id, at: Date())
        }
    }

    private struct ClockKey: Hashable {
        var state: StudySessionState
        var resumedAt: Date?
    }

    /// 0:00 hands the exam in.
    private func submitAtZero() async {
        guard fixedNow == nil, session.state == .active, let left = session.remaining(at: Date()) else { return }
        try? await Task.sleep(for: .seconds(left + 0.2))
        guard !Task.isCancelled, session.state == .active else { return }
        submit()
    }

    // MARK: Submit

    private func requestSubmit() {
        if answered.count < session.questionIDs.count {
            confirmsSubmit = true
        } else {
            submit()
        }
    }

    private func submit() {
        guard let coach, !isSubmitting, session.state.isOpen, fixedNow == nil else { return }
        isSubmitting = true
        saving?.cancel()
        let pending = typed
        let id = session.id
        let open = openDestination
        Task {
            await save(pending)
            do {
                try await coach.submitExam(id)
                open(.practiceResults(id))
            } catch {
                CoachUILog.ui.error("Submit failed: \(error.localizedDescription, privacy: .public)")
            }
            isSubmitting = false
        }
    }

    private var actions: PracticeActions {
        var actions = PracticeActions(isEditingText: isEditing || isSearchFieldFocused)
        guard session.state.isOpen else { return actions }
        actions.isPaused = isPaused
        actions.pauseOrResume = { pauseOrResume() }
        guard !isPaused else { return actions }
        actions.isFlagged = isFlagged
        actions.toggleFlag = { toggleFlag() }
        if position > 0 { actions.previousQuestion = { go(position - 1) } }
        if position + 1 < session.questionIDs.count { actions.nextQuestion = { go(position + 1) } }
        if let question, question.format == .choice {
            let count = question.choices.count
            actions.pick = { index in if index < count { set(.choice(index), for: question, now: true) } }
        }
        if coach != nil { actions.submitExam = { requestSubmit() } }
        return actions
    }
}

// MARK: - Title

/// "Practice exam" over "Data Centers · 2 / 8 · 1:16:05 left" with the time in SF Mono (the
/// shared `.screenTitle` takes a plain string; README asks for a `Text` subtitle).
private struct ExamTitle: ViewModifier {
    let session: StudySession
    let position: Int
    let fixedNow: Date?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationTitle(String(localized: "Practice exam"))
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Group {
                        if let fixedNow {
                            title(now: fixedNow)
                        } else {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                title(now: context.date)
                            }
                        }
                    }
                    .padding(.leading, ScreenTitleInset.firstItem)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        #else
        content
            .navigationTitle(String(localized: "Practice exam"))
            .navigationSubtitle(plain(now: fixedNow ?? Date()))
        #endif
    }

    private func title(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Practice exam")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            subtitle(now: now)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func subtitle(now: Date) -> Text {
        let place = "\(session.title) · \(position + 1) / \(session.questionIDs.count)"
        guard let left = session.remaining(at: now) else { return Text(verbatim: place) }
        let clock = Text(verbatim: TimeText.clock(left)).monospaced().monospacedDigit()
        return Text("\(place) · \(clock) left")
    }

    private func plain(now: Date) -> String {
        let place = "\(session.title) · \(position + 1) / \(session.questionIDs.count)"
        guard let left = session.remaining(at: now) else { return place }
        return String(localized: "\(place) · \(TimeText.clock(left)) left")
    }
}

// MARK: - The bar

/// The glass bar (mockup `.qbar`): ‹ 1…8 › | Submit.
private struct QuestionBar: View {
    let session: StudySession
    let answered: Set<StudyQuestion.ID>
    let position: Int
    let go: (Int) -> Void
    let submit: () -> Void
    let isSubmitting: Bool

    var body: some View {
        HStack(spacing: 3) {
            stepButton("chevron.left", target: position - 1, label: "Previous Question")
            ForEach(Array(session.questionIDs.enumerated()), id: \.offset) { index, id in
                Button {
                    go(index)
                } label: {
                    number(index, isAnswered: answered.contains(id), isFlagged: session.flags.contains(id))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Question \(index + 1)"))
            }
            stepButton("chevron.right", target: position + 1, label: "Next Question")
            Rectangle()
                .fill(.separator)
                .frame(width: 0.5, height: 18)
                .padding(.horizontal, 6)
            submitButton
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder
    private var submitButton: some View {
        let ready = answered.count == session.questionIDs.count
        if ready {
            Button("Submit", action: submit)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(isSubmitting)
        } else {
            Button("Submit", action: submit)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(isSubmitting)
        }
    }

    private func stepButton(_ symbol: String, target: Int, label: LocalizedStringKey) -> some View {
        let enabled = session.questionIDs.indices.contains(target)
        return Button {
            go(target)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    private func number(_ index: Int, isAnswered: Bool, isFlagged: Bool) -> some View {
        let isCurrent = index == position
        return Text(verbatim: "\(index + 1)")
            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isAnswered || isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 28, height: 28)
            .background(isAnswered ? AnyShapeStyle(Fill2()) : AnyShapeStyle(.clear), in: Circle())
            .overlay {
                if isCurrent {
                    Circle().strokeBorder(.primary, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(x: 3, y: -3)
                        .accessibilityLabel(Text("Flagged"))
                }
            }
            .contentShape(Circle())
    }
}

// MARK: - Answer forms

/// A written answer's field: the content surface, radius 10, a focus ring in the accent.
private struct ExamEditor: View {
    @Binding var text: String
    let minHeight: CGFloat
    var isEditing: FocusState<Bool>.Binding

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .focused(isEditing)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isEditing.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isEditing.wrappedValue ? 1 : 0.5)
            }
            .overlay {
                if isEditing.wrappedValue {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.26), lineWidth: 3)
                        .padding(-2)
                }
            }
    }
}

/// A diagram to label (mockup 18's last question): stacks of boxes side by side; printed boxes
/// grey (the base row darker), blanks dashed with the placed term as a token. Drag a term from the
/// bank onto a box, or click a box and type; drag a token back to the bank to take it off.
struct LabelDiagramView: View {
    let diagram: LabelDiagram
    @Binding var labels: [String: String]
    var isEditing: FocusState<Bool>.Binding
    var isReadOnly = false

    @State private var editing: String?
    @State private var entry = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 40) {
                ForEach(Array(diagram.stacks.enumerated()), id: \.offset) { _, stack in
                    VStack(spacing: 5) {
                        ForEach(Array(stack.rows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 5) {
                                ForEach(row) { box in
                                    boxView(box, isBase: rowIndex == stack.rows.count - 1)
                                }
                            }
                        }
                        Text(stack.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 2)
            if !isReadOnly {
                bank
            }
        }
    }

    @ViewBuilder
    private func boxView(_ box: LabelDiagram.Box, isBase: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if box.blank {
            ZStack {
                shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary)
                if editing == box.id {
                    TextField("", text: $entry)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.center)
                        .focused(isEditing)
                        .onSubmit { commit(box.id) }
                        .padding(.horizontal, 6)
                } else if let term = labels[box.id] {
                    Token(term: term, inBank: false)
                        .draggable(term)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(shape)
            .onTapGesture {
                guard !isReadOnly else { return }
                if let editing, editing != box.id { commit(editing) }
                entry = labels[box.id] ?? ""
                editing = box.id
                isEditing.wrappedValue = true
            }
            .dropDestination(for: String.self) { items, _ in
                guard !isReadOnly, let term = items.first else { return false }
                var labels = labels
                if let from = labels.first(where: { $0.value == term && $0.key != box.id && !bankTerms.contains(term) })?.key {
                    labels[from] = nil
                }
                labels[box.id] = term
                self.labels = labels
                return true
            }
            .onChange(of: isEditing.wrappedValue) { _, focused in
                if !focused, let editing { commit(editing) }
            }
        } else {
            Text(box.text)
                .font(.system(size: 12.5, weight: isBase ? .medium : .regular))
                .foregroundStyle(isBase ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(isBase ? AnyShapeStyle(Fill2()) : AnyShapeStyle(QuietFill()), in: shape)
        }
    }

    /// The terms not placed yet (each term as often as the bank holds it).
    private var bankTerms: [String] {
        var placed = Array(labels.values)
        var left: [String] = []
        for term in diagram.terms {
            if let index = placed.firstIndex(of: term) {
                placed.remove(at: index)
            } else {
                left.append(term)
            }
        }
        return left
    }

    private var bank: some View {
        HStack(spacing: 8) {
            ForEach(Array(bankTerms.enumerated()), id: \.offset) { _, term in
                Token(term: term, inBank: true)
                    .draggable(term)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22)
        .padding(.top, 16)
        .overlay(alignment: .top) { Hairline() }
        .padding(.top, 22)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let term = items.first, let box = labels.first(where: { $0.value == term })?.key else { return false }
            labels[box] = nil
            return true
        }
    }

    private func commit(_ boxID: String) {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        var labels = labels
        labels[boxID] = value.isEmpty ? nil : value
        self.labels = labels
        editing = nil
        entry = ""
    }
}

/// A term (mockup `.tok`): on a box accent soft and primary; in the bank the quiet fill, secondary.
private struct Token: View {
    let term: String
    let inBank: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(term)
            .font(.system(size: 12.5))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(inBank ? .secondary : .primary)
            .background(
                inBank ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(Color.accentSoft(colorScheme)),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}
