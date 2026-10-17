import Review
import StudyCore
import StudyUI
import SwiftUI

/// The transcript zone: the recording's lines grouped by slide visit, or, before the transcript
/// exists, the transcription job's progress.
struct TranscriptZone: View {
    let model: ReviewModel
    let timeline: SlideTimeline

    private let segmentsQuery: FetchAll<TranscriptSegment>
    private var segments: [TranscriptSegment] { segmentsQuery.wrappedValue }
    private let markersQuery: FetchAll<SlideEvent>
    private var markers: [SlideEvent] { markersQuery.wrappedValue }

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
                    language: model.lecture.language
                )
            }
        }
        .onChange(of: segments, initial: true) { _, segments in
            model.player?.setCues(segments.map(LecturePlayer.Cue.init))
        }
    }
}

/// The lines in a lazy list with slide dividers. While following, the current line stays in
/// view; moving to a slide by hand scrolls to its first visit.
private struct TranscriptList: View {
    let model: ReviewModel
    let sections: [TranscriptSection]
    let markers: [SlideEvent]
    let language: String

    var body: some View {
        let rate = model.recording?.sampleRate ?? 48_000
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        if section.id != TranscriptSection.unalignedID {
                            SectionDivider(section: section)
                                .id(section.id)
                        }
                        ForEach(section.segments) { segment in
                            TranscriptRow(
                                model: model,
                                segment: segment,
                                language: language,
                                markers: AnchorEditor.markers(
                                    in: markers, from: segment.startTime - 0.25, to: max(segment.endTime, segment.startTime + 0.5),
                                    sampleRate: rate
                                )
                            )
                            .id(segment.id)
                        }
                    }
                }
                .padding(.bottom, 72)
            }
            .scrollIndicators(.automatic)
            // Rows are inset by their highlight's padding; the list reaches past the column so the
            // times line up with the slide's edge.
            .padding(.horizontal, -8)
            .background {
                TranscriptFollower(model: model, sections: sections, proxy: proxy)
            }
        }
        .accessibilityLabel(Text("Transcript"))
    }
}

/// Keeps the list where the user is looking. Reads the playhead's line and the slide on screen
/// itself, so the list does not re-render when they change.
private struct TranscriptFollower: View {
    let model: ReviewModel
    let sections: [TranscriptSection]
    let proxy: ScrollViewProxy

    var body: some View {
        let session = model.session
        let line = session.isFollowing ? model.player?.currentSegmentID : nil
        let page = session.isFollowing ? nil : session.shownPage
        Color.clear
            .onAppear {
                if let line = model.player?.currentSegmentID { scroll(to: line) }
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

    /// Near the start of a slide visit its divider goes to the top; further in, the line sits in
    /// the upper third.
    private func scroll(to line: UUID) {
        for section in sections {
            guard let index = section.segments.firstIndex(where: { $0.id == line }) else { continue }
            if index < 3, section.id != TranscriptSection.unalignedID {
                proxy.scrollTo(section.id, anchor: .top)
            } else {
                proxy.scrollTo(line, anchor: UnitPoint(x: 0, y: 0.3))
            }
            return
        }
    }
}

/// "Slide 16 36:57–38:28", or only the times for an off-slide stretch; a tick when the stretch
/// starts at a manual marker.
private struct SectionDivider: View {
    let section: TranscriptSection

    var body: some View {
        HStack(spacing: 8) {
            if let page = section.page {
                Text("Slide \(page)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "\(TimeText.clock(section.start))–\(TimeText.clock(section.end))")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if section.startsAtMarker {
                Capsule()
                    .fill(.tint)
                    .frame(width: 2, height: 9)
                    .accessibilityLabel(Text("Marker"))
            }
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "36:57  text". The current line is tinted; low-confidence words are dotted; a language tag
/// appears only when the line is not in the lecture's language. Click plays from the line.
private struct TranscriptRow: View {
    let model: ReviewModel
    let segment: TranscriptSegment
    let language: String
    let markers: [SlideEvent]

    var body: some View {
        let isCurrent = model.player?.currentSegmentID == segment.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TimeText.clock(segment.startTime))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 46, alignment: .leading)
            Text(TranscriptText.attributed(segment))
                .font(.system(size: 13))
                .lineSpacing(2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !segment.lang.isEmpty, !language.isEmpty, segment.lang != language {
                Text(segment.lang.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5))
                    .accessibilityLabel(Text(Locale.current.localizedString(forLanguageCode: segment.lang) ?? segment.lang))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            isCurrent ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.session.play(from: segment.startTime) }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Play from Here")) {
            Task { await model.session.play(from: segment.startTime) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if model.deck != nil, let page = model.session.shownPage {
            Button("Slide \(page) Starts Here") {
                model.setSlideStart(page: page, at: segment.startTime)
            }
            .disabled(!model.canSetAnchor)
        }
        Button("Not on Slides From Here") {
            model.setSlideStart(page: nil, at: segment.startTime)
        }
        .disabled(!model.canSetAnchor)
        if !markers.isEmpty {
            Button("Remove Marker") {
                model.removeMarkers(markers.map(\.id))
            }
            .disabled(model.recording == nil)
        }
    }
}

/// A transcript line as styled text: words below `lowConfidence` get a dotted underline.
enum TranscriptText {
    static let lowConfidence = 0.5

    static func attributed(_ segment: TranscriptSegment) -> AttributedString {
        var result = AttributedString(segment.text)
        guard let words = segment.words, words.contains(where: { ($0.confidence ?? 1) < lowConfidence }) else {
            return result
        }
        let text = segment.text
        var searchStart = text.startIndex
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let range = text.range(of: token, range: searchStart..<text.endIndex) else { continue }
            searchStart = range.upperBound
            guard (word.confidence ?? 1) < lowConfidence,
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: .secondary)
        }
        return result
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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } currentValueLabel: {
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)
            case .failed:
                Label(job.error ?? String(localized: "Transcription failed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
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
