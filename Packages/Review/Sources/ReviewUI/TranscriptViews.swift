import Review
import StudyCore
import StudyUI
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The transcript zone: the recording's lines grouped by slide visit, or, before the transcript
/// exists, the transcription job's progress.
struct TranscriptZone: View {
    let model: ReviewModel
    let timeline: SlideTimeline

    private let segmentsQuery: FetchAll<TranscriptSegment>
    private var segments: [TranscriptSegment] { segmentsQuery.wrappedValue }
    private let markersQuery: FetchAll<SlideEvent>
    private var markers: [SlideEvent] { markersQuery.wrappedValue }
    /// The study pass's rows: a line the professor is quoted from ends with their pin (M4).
    private let annotationsQuery: FetchAll<Annotation>

    init(model: ReviewModel, timeline: SlideTimeline) {
        self.model = model
        self.timeline = timeline
        let recordingID = model.recording?.id ?? UUID()
        segmentsQuery = FetchAll(
            TranscriptSegment.where { $0.recordingID.eq(recordingID) }.order(by: \.startTime),
            database: model.services.database
        )
        markersQuery = FetchAll(
            SlideEvent.where { $0.recordingID.eq(recordingID) && $0.kind.eq(SlideEventKind.manual) }.order(by: \.sampleTime),
            database: model.services.database
        )
        annotationsQuery = .studyItems(of: model)
    }

    var body: some View {
        Group {
            if segments.isEmpty {
                ProcessingProgress(recordingID: model.recording?.id, database: model.services.database)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptList(
                    model: model,
                    sections: timeline.sections(of: segments),
                    markers: markers,
                    language: model.lecture.language,
                    items: StudyItems(annotationsQuery.wrappedValue)
                )
            }
        }
        .onChange(of: segments, initial: true) { _, segments in
            model.player?.setCues(segments.map(LecturePlayer.Cue.init))
        }
    }
}

/// A slide visit's lines: its segments joined into sentences (`TranscriptLines`).
struct LinedSection: Identifiable {
    var section: TranscriptSection
    var lines: [TranscriptLine]
    var id: UUID { section.id }

    static func make(_ sections: [TranscriptSection]) -> [LinedSection] {
        sections.map { LinedSection(section: $0, lines: TranscriptLines.lines($0.segments)) }
    }
}

/// The lines in a lazy list with slide dividers: one row per sentence (mockup 03), its time the
/// first segment's. While following, the playhead's line stays in view; moving to a slide by hand
/// scrolls to its first visit.
private struct TranscriptList: View {
    let model: ReviewModel
    let sections: [TranscriptSection]
    let markers: [SlideEvent]
    let language: String
    let items: StudyItems

    var body: some View {
        let rate = model.recording?.sampleRate ?? 48_000
        let recordingID = model.recording?.id
        let lined = LinedSection.make(sections)
        let lineIDs = TranscriptLines.lineIDs(lined.flatMap(\.lines))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lined) { item in
                        if item.id != TranscriptSection.unalignedID {
                            SectionDivider(section: item.section)
                                .id(item.id)
                        }
                        ForEach(item.lines) { line in
                            TranscriptRow(
                                model: model,
                                line: line,
                                lineIDs: lineIDs,
                                language: language,
                                markers: AnchorEditor.markers(
                                    in: markers, from: line.start - 0.25, to: max(line.end, line.start + 0.5),
                                    sampleRate: rate
                                ),
                                professorItem: items.professorItem(
                                    recordingID: recordingID, segmentIDs: line.segmentIDs, start: line.start, end: line.end
                                )
                            )
                            .id(line.id)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            // The edge under the slide stays crisp (no blur band).
            .scrollEdgeEffectHidden(true, for: .top)
            // Nothing draws above the list, into the gap under the slide or behind it. Clipped
            // (and faded) before the negative padding: the padded view's frame is the column, and
            // clipping it would cut the rows' highlight overhang.
            .clipped()
            .fadesAbovePlayer(model.player != nil)
            // Rows are inset by their highlight's padding; the list reaches 8 pt past the column
            // on both sides so the times line up with the slide's edge and the current line's
            // highlight overhangs it (mockup 03).
            .padding(.horizontal, -8)
            .background {
                TranscriptFollower(model: model, sections: lined, lineIDs: lineIDs, proxy: proxy)
            }
        }
        .accessibilityLabel(Text("Transcript"))
    }
}

/// Keeps the list where the user is looking. Reads the playhead's line and the slide on screen
/// itself, so the list does not re-render when they change.
private struct TranscriptFollower: View {
    let model: ReviewModel
    let sections: [LinedSection]
    /// Each segment's line.
    let lineIDs: [UUID: UUID]
    let proxy: ScrollViewProxy

    var body: some View {
        let session = model.session
        let line = session.isFollowing ? model.player?.currentSegmentID.flatMap { lineIDs[$0] } : nil
        let page = session.isFollowing ? nil : session.shownPage
        Color.clear
            .task {
                // Opened at a moment (search hit, Today, saved position): go there once the list
                // has laid out; a scroll asked for while it appears is dropped.
                try? await Task.sleep(for: .milliseconds(60))
                if !session.isFollowing, let visit = openingVisit(session) {
                    // Opened on a slide the playhead is not in (yet): its divider is the first row.
                    proxy.scrollTo(visit, anchor: .top)
                } else if let line = model.player?.currentSegmentID.flatMap({ lineIDs[$0] }) {
                    scroll(to: line)
                }
            }
            .onChange(of: line) { _, line in
                guard let line else { return }
                withAnimation(.smooth) { scroll(to: line) }
            }
            .onChange(of: page) { _, page in
                guard let page, let visit = session.timeline.firstVisit(of: page),
                      sections.contains(where: { $0.id == visit.id })
                else { return }
                withAnimation(.smooth) { proxy.scrollTo(visit.id, anchor: .top) }
            }
    }

    /// The visit of the slide on screen to open at: the one holding the playhead, else the next one
    /// after it, else the first.
    private func openingVisit(_ session: ReviewSession) -> UUID? {
        guard let page = session.shownPage else { return nil }
        let visits = session.timeline.visits(of: page).filter { visit in sections.contains { $0.id == visit.id } }
        let time = model.player?.time ?? 0
        let visit = visits.first { $0.start <= time && time < $0.end } ?? visits.first { $0.start >= time } ?? visits.first
        return visit?.id
    }

    /// Within a slide visit's first three lines its divider goes to the top; further in, the line
    /// sits in the upper third.
    private func scroll(to line: UUID) {
        for section in sections {
            guard let index = section.lines.firstIndex(where: { $0.id == line }) else { continue }
            if index < 3, section.id != TranscriptSection.unalignedID {
                proxy.scrollTo(section.id, anchor: .top)
            } else {
                proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.3))
            }
            return
        }
    }
}

/// "Slide 16 36:57–38:28", or only the times for an off-slide stretch, then a hairline (mockup
/// 03). A stretch that starts at a manual marker shows nothing more: the line's menu removes it.
private struct SectionDivider: View {
    let section: TranscriptSection

    var body: some View {
        HStack(spacing: 8) {
            if let page = section.page {
                Text("Slide \(page)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "\(TimeText.clock(section.start))–\(TimeText.clock(section.end))")
                .font(.caption.monospaced())
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(section.startsAtMarker ? Text("Marker") : Text(verbatim: ""))
    }
}

/// "36:57  So the hypervisor traps it, …" (a sentence; mockup 03). The current line is tinted;
/// low-confidence words are dotted; a corrected word reads ~~old~~ new (M4); a line the professor
/// is quoted from ends with their 16 pt pin and its card; a language tag appears only when the
/// line is not in the lecture's language. Click plays from the line.
private struct TranscriptRow: View {
    let model: ReviewModel
    let line: TranscriptLine
    let lineIDs: [UUID: UUID]
    let language: String
    let markers: [SlideEvent]
    /// The exam hint or highlight quoted from this line.
    var professorItem: Annotation?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isCurrent = model.player?.currentSegmentID.flatMap { lineIDs[$0] } == line.id
        let pieces = TranscriptText.pieces(line)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TimeText.clock(line.start))
                .font(.subheadline.monospaced())
                .monospacedDigit()
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 54, alignment: .leading)
            Group {
                if let professorItem {
                    QuotedLineText(pieces: pieces) {
                        AnnotationPin(.professor, style: .inline) {
                            ProfessorPinCard(model: model, item: professorItem)
                        }
                        .contextMenu {
                            Button("Hide") { model.hide(professorItem.id) }
                        }
                    }
                } else if pieces.contains(where: { $0.kind == .inserted }) {
                    TranscriptText.text(pieces)
                        .textRenderer(CorrectionRenderer(fill: TranscriptText.insertedFill(colorScheme)))
                } else {
                    TranscriptText.text(pieces)
                }
            }
            .font(.body)
            .lineSpacing(2.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !line.language.isEmpty, !language.isEmpty, line.language != language {
                Text(line.language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
                    .accessibilityLabel(Text(Locale.current.localizedString(forLanguageCode: line.language) ?? line.language))
            }
        }
        .padding(.vertical, 4.5)
        .padding(.horizontal, 8)
        .background(
            isCurrent ? AnyShapeStyle(.tint.opacity(ReviewTint.soft(colorScheme))) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.session.play(from: line.start) }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Play from Here")) {
            Task { await model.session.play(from: line.start) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if model.deck != nil, let page = model.session.shownPage {
            Button("Slide \(page) Starts Here") {
                model.setSlideStart(page: page, at: line.start)
            }
            .disabled(!model.canSetAnchor)
        }
        Button("Not on Slides From Here") {
            model.setSlideStart(page: nil, at: line.start)
        }
        .disabled(!model.canSetAnchor)
        if !markers.isEmpty {
            Button("Remove Marker") {
                model.removeMarkers(markers.map(\.id))
            }
            .disabled(model.recording == nil)
        }
        if line.segments.contains(where: { !$0.activePatches.isEmpty }) {
            Button("Revert Correction") {
                model.revertCorrections(line)
            }
        }
    }
}

/// A line the professor is quoted from: its words flow like the text would wrap, and the pin
/// sits right after the last word (mockup `.seg .pin.inline`).
private struct QuotedLineText<Pin: View>: View {
    let pieces: [TranscriptText.Piece]
    @ViewBuilder let pin: Pin
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NoteFlowLayout(lineSpacing: 2.5, wordSpacing: 3.6) {
            ForEach(Array(TranscriptText.words(pieces).enumerated()), id: \.offset) { _, word in
                switch word.kind {
                case .plain:
                    Text(word.text)
                case .deleted:
                    TranscriptText.deleted(word.text)
                case .inserted:
                    Text(word.text)
                        .padding(.horizontal, 2)
                        .background(TranscriptText.insertedFill(colorScheme), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .padding(.horizontal, -2)
                }
            }
            pin
        }
        .accessibilityElement(children: .combine)
    }
}

/// Marks an inserted correction in a line's `Text`, for `CorrectionRenderer`.
struct InsertedRun: TextAttribute {}

/// Draws a line with its inserted corrections on the green soft fill (radius 3, 2 pt past the
/// word on either side), under the glyphs.
struct CorrectionRenderer: TextRenderer {
    let fill: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[InsertedRun.self] != nil {
                let rect = run.typographicBounds.rect.insetBy(dx: -2, dy: 0)
                context.fill(Path(roundedRect: rect, cornerRadius: 3, style: .continuous), with: .color(fill))
            }
            context.draw(line)
        }
    }
}

/// A transcript line as styled text: genuine doubts get a dotted underline, that is content
/// words (3+ letters, not a function word) Whisper gave below `lowConfidence`. Calibrated on the
/// M1 end-to-end lectures: at 0.5 63 % of lines had a dotted word (mostly "on", "the", "to"),
/// now about 7 %.
enum TranscriptText {
    static let lowConfidence = 0.15

    /// English and German function words: never a doubt worth marking.
    static let functionWords: Set<String> = [
        "the", "and", "but", "for", "with", "from", "this", "that", "these", "those", "are", "was", "were", "been",
        "you", "they", "she", "not", "yes", "okay", "also", "again", "then", "there", "here", "what", "which", "who",
        "how", "why", "when", "where", "does", "did", "can", "could", "would", "should", "will", "just", "like", "very",
        "really", "one", "have", "has", "had", "all", "some", "our", "your", "their", "its", "now", "even", "still",
        "der", "die", "das", "und", "oder", "aber", "ein", "eine", "einen", "dem", "den", "des", "ist", "sind", "war",
        "mit", "von", "für", "auf", "aus", "bei", "nicht", "auch", "noch", "dann", "wenn", "wie", "was", "wer", "hier",
    ]

    /// A word to dot: a content word below `lowConfidence`.
    static func isDoubtful(_ word: TranscriptWord) -> Bool {
        guard let confidence = word.confidence, confidence < lowConfidence else { return false }
        let letters = word.text.lowercased().filter(\.isLetter)
        return letters.count >= 3 && !functionWords.contains(letters)
    }

    /// The dotted underline: a fine line in the tertiary label colour.
    #if canImport(AppKit)
    static let doubtColor = Color(nsColor: .tertiaryLabelColor)
    #else
    static let doubtColor = Color(uiColor: .tertiaryLabel)
    #endif

    /// A run of a line as drawn: plain text (with its doubt dots), or a correction's old word
    /// (tertiary, struck through in red) and new word (on green soft). Corrected words carry no
    /// doubt dots.
    struct Piece: Hashable {
        enum Kind: Hashable {
            case plain
            case deleted
            case inserted
        }

        var text: AttributedString
        var kind: Kind
    }

    /// A line's segments one space apart, each keeping its dotted doubts and drawing its active
    /// patches (`TranscriptPatch.runs` over `original_text`, M4), with the transcriber's cut-off
    /// marks as prose (`cleanCutOffs`). Adjacent plain runs are merged.
    static func pieces(_ line: TranscriptLine) -> [Piece] {
        var pieces: [Piece] = []
        func append(_ piece: Piece) {
            guard !piece.text.characters.isEmpty else { return }
            if piece.kind == .plain, let last = pieces.last, last.kind == .plain {
                pieces[pieces.count - 1].text += piece.text
            } else {
                pieces.append(piece)
            }
        }
        for segment in line.segments {
            let segmentPieces = TranscriptText.pieces(segment)
            guard !segmentPieces.isEmpty else { continue }
            if !pieces.isEmpty { append(Piece(text: AttributedString(" "), kind: .plain)) }
            segmentPieces.forEach(append)
        }
        for index in pieces.indices where pieces[index].kind == .plain {
            replaceDashes(&pieces[index].text)
        }
        if let last = pieces.indices.last, pieces[last].kind == .plain {
            endWithEllipsis(&pieces[last].text)
        }
        return pieces
    }

    /// One segment's pieces, trimmed. Without patches it reads its `text` as before M4.
    static func pieces(_ segment: TranscriptSegment) -> [Piece] {
        guard let patches = segment.patches, !patches.isEmpty else {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [Piece(text: dotted(text, words: segment.words), kind: .plain)]
        }
        let original = segment.originalText
        let dotted = dotted(original, words: segment.words)
        var pieces: [Piece] = []
        var offset = 0
        for run in TranscriptPatch.runs(patches, in: original) {
            switch run {
            case .text(let plain):
                let start = dotted.characters.index(dotted.startIndex, offsetBy: offset)
                let end = dotted.characters.index(start, offsetBy: plain.count)
                pieces.append(Piece(text: AttributedString(dotted[start..<end]), kind: .plain))
                offset += plain.count
            case .corrected(let from, let to, _):
                pieces.append(Piece(text: AttributedString(from), kind: .deleted))
                pieces.append(Piece(text: AttributedString(" "), kind: .plain))
                pieces.append(Piece(text: AttributedString(to), kind: .inserted))
                offset += from.count
            }
        }
        if let first = pieces.indices.first, pieces[first].kind == .plain {
            trimLeading(&pieces[first].text)
        }
        if let last = pieces.indices.last, pieces[last].kind == .plain {
            trimTrailing(&pieces[last].text)
        }
        return pieces.filter { !$0.text.characters.isEmpty }
    }

    /// The line as one `Text`: inserted corrections are tagged for `CorrectionRenderer`.
    static func text(_ pieces: [Piece]) -> Text {
        pieces.reduce(Text(verbatim: "")) { text, piece in
            switch piece.kind {
            case .plain:
                return Text("\(text)\(Text(piece.text))")
            case .deleted:
                return Text("\(text)\(deleted(piece.text))")
            case .inserted:
                return Text("\(text)\(Text(piece.text).customAttribute(InsertedRun()))")
            }
        }
    }

    /// A correction's old word: tertiary, struck through in red.
    static func deleted(_ text: AttributedString) -> Text {
        Text(text)
            .foregroundStyle(.tertiary)
            .strikethrough(color: .red)
    }

    /// The fill under an inserted correction: green at 14 % (18 % in dark mode).
    static func insertedFill(_ colorScheme: ColorScheme) -> Color {
        Color.green.opacity(colorScheme == .dark ? 0.18 : 0.14)
    }

    /// The pieces cut into words (attributes kept), for a line that ends with a pin.
    static func words(_ pieces: [Piece]) -> [Piece] {
        var words: [Piece] = []
        for piece in pieces {
            let characters = piece.text.characters
            var start: AttributedString.Index?
            var index = characters.startIndex
            while index < characters.endIndex {
                let next = characters.index(after: index)
                if characters[index].isWhitespace {
                    if let begun = start {
                        words.append(Piece(text: AttributedString(piece.text[begun..<index]), kind: piece.kind))
                        start = nil
                    }
                } else if start == nil {
                    start = index
                }
                index = next
            }
            if let begun = start {
                words.append(Piece(text: AttributedString(piece.text[begun..<characters.endIndex]), kind: piece.kind))
            }
        }
        return words
    }

    /// Whisper marks a broken-off phrase with "--" ("the guest can-- on the other side"): a
    /// spaced em dash inside the line ("the guest can — on the other side"), an ellipsis at its
    /// end ("in order…"). Display only; the transcript keeps its text.
    static func cleanCutOffs(_ text: inout AttributedString) {
        replaceDashes(&text)
        endWithEllipsis(&text)
    }

    static func replaceDashes(_ text: inout AttributedString) {
        while let range = text.range(of: "--") {
            let afterSpace = range.lowerBound > text.startIndex
                && text.characters[text.characters.index(before: range.lowerBound)].isWhitespace
            text.replaceSubrange(range, with: AttributedString(afterSpace ? "—" : " —"))
        }
    }

    static func endWithEllipsis(_ text: inout AttributedString) {
        guard let dash = text.range(of: "—", options: .backwards),
              text.characters[dash.upperBound...].allSatisfy(\.isWhitespace)
        else { return }
        var start = dash.lowerBound
        if start > text.startIndex, text.characters[text.characters.index(before: start)] == " " {
            start = text.characters.index(before: start)
        }
        text.replaceSubrange(start..<text.endIndex, with: AttributedString("…"))
    }

    /// `text` with its doubtful words (`words`, matched in order) dotted.
    static func dotted(_ text: String, words: [TranscriptWord]?) -> AttributedString {
        var result = AttributedString(text)
        guard let words, words.contains(where: isDoubtful) else {
            return result
        }
        var searchStart = text.startIndex
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let range = text.range(of: token, range: searchStart..<text.endIndex) else { continue }
            searchStart = range.upperBound
            guard isDoubtful(word),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: doubtColor)
        }
        return result
    }

    private static func trimLeading(_ text: inout AttributedString) {
        while let first = text.characters.first, first.isWhitespace {
            text.characters.removeFirst()
        }
    }

    private static func trimTrailing(_ text: inout AttributedString) {
        while let last = text.characters.last, last.isWhitespace {
            text.characters.removeLast()
        }
    }
}

/// Before the transcript exists: the transcription job's determinate progress (no spinner).
struct ProcessingProgress: View {
    private let jobsQuery: FetchAll<Job>
    private var jobs: [Job] { jobsQuery.wrappedValue }

    init(recordingID: Recording.ID?, database: any DatabaseReader) {
        let recordingID = recordingID ?? UUID()
        jobsQuery = FetchAll(Job.where { $0.recordingID.eq(recordingID) }.order(by: \.createdAt), database: database)
    }

    var body: some View {
        if let job = jobs.last(where: { $0.stage == .transcribe }) ?? jobs.last {
            switch job.state {
            case .queued, .running:
                ProgressView(value: job.progress) {
                    Text(Self.title(of: job))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } currentValueLabel: {
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospaced())
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            case .failed:
                Label(job.error ?? String(localized: "Transcription failed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            case .succeeded, .cancelled:
                EmptyView()
            }
        }
    }

    static func title(of job: Job) -> LocalizedStringKey {
        if job.phase == .downloadingModel { return "Downloading model" }
        if job.phase == .loadingModel { return "Loading model" }
        return job.stage == .align ? "Aligning" : "Transcribing"
    }
}
