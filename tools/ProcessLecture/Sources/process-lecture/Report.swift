import Alignment
import AlignmentEvaluation
import Foundation
import Processing
import StudyCore
import Synchronization

/// Wall time per processing stage, from the processor's events.
final class StageTimes: Sendable {
    private let seconds = Mutex<[JobStage: Double]>([:])

    func record(_ event: ProcessingEvent) {
        switch event {
        case .started(let job):
            print("  \(job.stage.rawValue) started (attempt \(job.attempt))")
        case .progress:
            break
        case .finished(let job, let elapsed):
            seconds.withLock { $0[job.stage, default: 0] += elapsed }
            let detail = job.error.map { " — \($0)" } ?? ""
            print(String(format: "  %@ %@ in %.1f s%@", job.stage.rawValue, job.state.rawValue, elapsed, detail))
        }
    }

    func seconds(_ stage: JobStage) -> Double {
        seconds.withLock { $0[stage] ?? 0 }
    }
}

/// What one lecture's processing produced, read back from the database.
struct Report: Encodable {
    struct Times: Encodable {
        var model: Double
        var importing: Double
        var processing: Double
        var transcribe: Double
        var align: Double
        var total: Double
    }

    struct Language: Encodable {
        var language: String
        var segments: Int
        var seconds: Double
    }

    struct Span: Encodable {
        var page: Int?
        var start: Double
        var end: Double
        var source: String
        var confidence: Double
    }

    struct StampCheck: Encodable {
        var page: Int
        var stampedAt: Double
        /// Start of the span for `page` that the stamp produced, if one exists.
        var spanStart: Double?
        var source: String?
        var honored: Bool
    }

    struct Accuracy: Encodable {
        var truth: String
        var windowAccuracy: Double
        var timeAccuracy: Double
        var medianBoundaryError: Double?
    }

    var database: String
    var lectureID: String
    var recordingDuration: Double
    var realTimeFactor: Double
    var times: Times
    var jobs: [String]
    var recordingSegments: Int
    var segments: Int
    var words: Int
    var languages: [Language]
    var slideSpans: Int
    var offSpans: Int
    var pagesCovered: [Int]
    var spans: [Span]
    var stamps: [StampCheck]
    var accuracy: Accuracy?
    var failures: [String]

    static func make(
        services: StudyServices,
        imported: ImportedLecture,
        stamps: [CaptureStamp],
        startPage: Int?,
        truth: (String, GroundTruth)?,
        times: Times
    ) async throws -> Report {
        let store = services.records
        let lectureID = imported.lecture.id
        let recordingID = imported.recording.id
        let jobs = try await JobRepository(store: store).jobs(lectureID: lectureID)
        let recordingSegments = try await RecordingRepository(store: store).segments(recordingID: recordingID)
        let segments = try await TranscriptRepository(store: store).segments(recordingID: recordingID)
        let spans = try await LectureRepository(store: store).timedSpans(lectureID: lectureID, recordingID: recordingID)

        var languages: [String: Language] = [:]
        for segment in segments {
            languages[segment.lang, default: Language(language: segment.lang, segments: 0, seconds: 0)].segments += 1
            languages[segment.lang]?.seconds += segment.endTime - segment.startTime
        }

        var failures: [String] = []
        if jobs.isEmpty || !jobs.allSatisfy({ $0.state == .succeeded }) {
            failures.append("not every job succeeded: \(jobs.map { "\($0.stage.rawValue)=\($0.state.rawValue)" })")
        }
        if segments.isEmpty { failures.append("no transcript segments") }
        if segments.contains(where: { $0.lang.isEmpty }) { failures.append("segments without a language tag") }
        if imported.deck != nil, spans.isEmpty { failures.append("no slide spans") }

        // A stamp is honored when its slide's span starts within the snap window around it
        // (back ≤ 5 s to a sentence start or pause, forward ≤ 0.3 s) and came from the stamp.
        var checks: [StampCheck] = []
        let allStamps = (startPage.map { [CaptureStamp(time: 0, page: $0)] } ?? []) + stamps
        for stamp in allStamps {
            let span = spans
                .filter { $0.firstPage == stamp.page && $0.startTime.map { abs($0 - stamp.time) <= 5.5 } == true }
                .min { abs(($0.startTime ?? 0) - stamp.time) < abs(($1.startTime ?? 0) - stamp.time) }
            let start = span?.startTime
            let honored = start.map { $0 <= stamp.time + 0.3 && $0 >= stamp.time - 5 } == true && span?.source == .stamp
            checks.append(StampCheck(page: stamp.page, stampedAt: stamp.time, spanStart: start, source: span?.source.rawValue, honored: honored))
            if !honored { failures.append("stamp \(stamp.page) at \(clock(stamp.time)) not honored") }
        }

        var accuracy: Accuracy?
        if let (name, truth) = truth {
            let aligned = spans.map { span in
                AlignedSpan(
                    target: span.firstPage.map(AlignmentTarget.slide) ?? .off,
                    start: span.startTime ?? 0, end: span.endTime ?? 0,
                    confidence: span.confidence, origin: .automatic
                )
            }
            let score = Scorer.score(spans: aligned, truth: truth)
            accuracy = Accuracy(
                truth: name, windowAccuracy: score.windowAccuracy, timeAccuracy: score.timeAccuracy,
                medianBoundaryError: score.medianBoundaryError
            )
        }

        let duration = imported.recording.duration
        return Report(
            database: services.paths.database.path(percentEncoded: false),
            lectureID: lectureID.uuidString,
            recordingDuration: duration,
            realTimeFactor: times.transcribe > 0 ? duration / times.transcribe : 0,
            times: times,
            jobs: jobs.map { "\($0.stage.rawValue): \($0.state.rawValue), attempt \($0.attempt), progress \($0.progress)" },
            recordingSegments: recordingSegments.count,
            segments: segments.count,
            words: segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count },
            languages: languages.values.sorted { $0.segments > $1.segments },
            slideSpans: spans.filter { !$0.isOffSlide }.count,
            offSpans: spans.filter(\.isOffSlide).count,
            pagesCovered: Array(Set(spans.compactMap(\.firstPage))).sorted(),
            spans: spans.map {
                Span(page: $0.firstPage, start: $0.startTime ?? 0, end: $0.endTime ?? 0, source: $0.source.rawValue, confidence: $0.confidence)
            },
            stamps: checks,
            accuracy: accuracy,
            failures: failures
        )
    }

    func print() {
        Swift.print("")
        Swift.print("Database        \(database)")
        Swift.print(String(format: "Audio           %@ in %d file(s)", clock(recordingDuration), recordingSegments))
        Swift.print(String(
            format: "Wall time       model %.1f s · import %.1f s · transcribe %.1f s (%.1f× real time) · align %.2f s · total %.1f s",
            times.model, times.importing, times.transcribe, realTimeFactor, times.align, times.total
        ))
        Swift.print("Jobs            \(jobs.joined(separator: "; "))")
        Swift.print("Segments        \(segments) (\(words) words)")
        for language in languages {
            Swift.print(String(format: "  %@             %d segments, %@", language.language, language.segments, clock(language.seconds)))
        }
        Swift.print("Spans           \(slideSpans) on slides, \(offSpans) off slides; pages \(pagesCovered.map(String.init).joined(separator: " "))")
        for span in spans {
            Swift.print(String(
                format: "  %@–%@  %@  %@ %.2f",
                clock(span.start), clock(span.end), span.page.map { "slide \($0)" } ?? "off     ", span.source, span.confidence
            ))
        }
        if !stamps.isEmpty {
            Swift.print("Stamps          \(stamps.filter(\.honored).count) of \(stamps.count) honored")
            for check in stamps {
                Swift.print(String(
                    format: "  slide %d stamped %@ → span starts %@ (%@)%@",
                    check.page, clock(check.stampedAt), check.spanStart.map(clock) ?? "—", check.source ?? "—",
                    check.spanStart.map { String(format: ", %+.1f s", $0 - check.stampedAt) } ?? ""
                ))
            }
        }
        if let accuracy {
            Swift.print(String(
                format: "Accuracy        %@: %.1f %% of 30 s windows, %.1f %% of seconds%@",
                accuracy.truth, accuracy.windowAccuracy * 100, accuracy.timeAccuracy * 100,
                accuracy.medianBoundaryError.map { String(format: ", median boundary error %.0f s", $0) } ?? ""
            ))
        }
        Swift.print(failures.isEmpty ? "Result          OK" : "Result          FAILED: \(failures.joined(separator: "; "))")
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
