import Foundation
import StudyCore

extension TranscribedSegment {
    /// A `transcript_segment` row for this segment.
    ///
    /// `timeOffset` is added to every time, for transcripts made from audio that does not start
    /// at the recording's sample 0.
    public func record(
        recordingID: Recording.ID,
        lectureID: Lecture.ID?,
        timeOffset: Double = 0
    ) -> TranscriptSegment {
        TranscriptSegment(
            recordingID: recordingID,
            lectureID: lectureID,
            startTime: start + timeOffset,
            endTime: end + timeOffset,
            text: text,
            lang: language,
            confidence: confidence,
            words: words.isEmpty ? nil : words.map {
                TranscriptWord(text: $0.text, start: $0.start + timeOffset, end: $0.end + timeOffset, confidence: $0.probability)
            }
        )
    }
}

extension Transcript {
    /// `transcript_segment` rows in time order, ready for `TranscriptRepository.replaceSegments`.
    public func records(recordingID: Recording.ID, lectureID: Lecture.ID?, timeOffset: Double = 0) -> [TranscriptSegment] {
        segments
            .sorted { $0.start < $1.start }
            .map { $0.record(recordingID: recordingID, lectureID: lectureID, timeOffset: timeOffset) }
    }
}

extension TranscriptionOptions {
    /// Options for a course: per-chunk detection among the course's teaching and admin languages
    /// plus German and English, and the course glossary as the decoder prompt.
    ///
    /// German and English are always candidates: either can come up in any course
    /// (admin notes, questions, student talks), and a language that is not a candidate comes
    /// out translated. The course language is listed first and is the fallback.
    public init(course: Course, guards: TranscriptionGuards = .standard) {
        var languages: [String] = []
        for code in [course.language, course.adminLanguage, "de", "en"] {
            let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
            // Whisper uses the bare language subtag ("de" for "de-DE").
            let base = String(trimmed.split(separator: "-").first ?? "")
            if !base.isEmpty, !languages.contains(base) { languages.append(base) }
        }
        self.init(
            language: .detect(among: languages),
            glossary: Self.glossaryTerms(course.glossary),
            guards: guards
        )
    }

    /// Splits a course glossary (one term per line, or separated by commas/semicolons) into terms.
    public static func glossaryTerms(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension TranscriptionAudio {
    /// Audio for a recording's segment files. `files` maps each segment to its local file URL
    /// (from `BlobStore.url(for:)`); segments without a file are skipped.
    public init(recording: Recording, segments: [RecordingSegment], files: (RecordingSegment) -> URL?) {
        let rate = recording.sampleRate > 0 ? recording.sampleRate : 48_000
        self.init(parts: segments
            .sorted { $0.sequence < $1.sequence }
            .compactMap { segment in
                files(segment).map {
                    Part(url: $0, startTime: Double(segment.startSample) / rate, duration: Double(segment.frameCount) / rate)
                }
            })
    }
}
