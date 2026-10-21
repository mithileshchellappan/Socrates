import AVFoundation
import Capture
import Foundation
import StudyCore
import UniformTypeIdentifiers

/// What a dropped file says about where it belongs, read without importing it.
public struct FileEvidence: Sendable, Hashable {
    public var url: URL
    public var fileName: String
    public var kind: FilingKind
    public var deck: DeckEvidence?
    public var recording: RecordingEvidence?
    public var capture: CaptureEvidence?

    /// Lecture number from the file name ("02_…" → 2, "Slides I_ …" → 1).
    public var fileNumber: Int?
    /// The text the file number came from ("02", "Slides I").
    public var fileNumberEvidence: String?

    /// Pages of a deck.
    public var pageCount: Int? { deck?.pageCount }
    /// Seconds of a recording or capture.
    public var duration: Double? { recording?.duration ?? capture?.duration }

    /// A deck's facts.
    public struct DeckEvidence: Sendable, Hashable {
        public var pageCount: Int
        public var pdfTitle: String?
        public var pdfAuthor: String?
        /// Lines repeated on most slides, page numbers removed.
        public var footer: [String]
        /// The first slide's lines that are not footer lines.
        public var titleSlide: [String]
        /// "2 Virtualization Basics" on the title slide, or "I: Introduction" in the footer.
        public var slideNumber: Int?
        /// The heading after the number ("Virtualization Basics").
        public var numberedTitle: String?
        /// A date on the title slide ("13-Oct-26").
        public var titleDate: CalendarDay?
        /// The date as written, for the filing's signals.
        public var titleDateText: String?
        /// Normalized text of all sampled pages (glossary hits).
        public var sampledText: String
    }

    /// A recording's facts.
    public struct RecordingEvidence: Sendable, Hashable {
        /// When recording began: the container's creation date, else the file's.
        public var startedAt: Date?
        public var startSource: StartSource
        public var duration: Double?
    }

    public enum StartSource: String, Sendable, Hashable {
        /// QuickTime/MPEG-4 creation date in the file (the recording start; Voice Memos' Share
        /// writes the export time instead, see `writtenAt`).
        case metadata
        /// The file system's creation date (may be when the file was copied or exported).
        case fileDate
        /// Either date, read as when the file was written (the audio would otherwise end after
        /// it): the start is that moment minus the duration.
        case writtenAt
        /// Nothing known.
        case unknown
    }

    /// A live capture package's facts (a `.lecture` folder, or an iPhone's `.lecturebundle`).
    public struct CaptureEvidence: Sendable, Hashable {
        public var recordingID: UUID
        public var courseID: Course.ID?
        public var lectureID: Lecture.ID?
        public var startedAt: Date?
        public var duration: Double
        /// M7: the course and class in words (the phone's ids are not this library's until sync).
        public var courseName: String? = nil
        public var courseShortName: String? = nil
        public var sessionNumber: Int? = nil
        /// A capture bundle (one file), unpacked into the library's Recordings folder on filing.
        public var isBundle = false
    }

    /// When the recorded audio starts, for recordings and captures.
    public var startedAt: Date? { recording?.startedAt ?? capture?.startedAt }

    /// Slide title for a new lecture ("Virtualization Basics").
    public var lectureTitle: String {
        if let title = deck?.numberedTitle, !title.isEmpty { return title }
        if kind == .deck { return Self.cleanTitle(fileName) }
        return ""
    }

    /// The deck's own title, stored with it (Course Settings, search headers): the title slide's
    /// numbered heading ("Virtualization Basics", "Introduction"), else the PDF's title unless it
    /// is just the file name, else the cleaned file name.
    public var deckTitle: String {
        if let title = deck?.numberedTitle, !title.isEmpty { return title }
        let stem = (fileName as NSString).deletingPathExtension
        if let title = deck?.pdfTitle, !title.isEmpty, title != stem, !title.contains("_") { return title }
        let cleaned = Self.cleanTitle(fileName)
        return cleaned.isEmpty ? stem : cleaned
    }

    /// "02_Virtualization_Basics_IaaS_v1.pdf" → "Virtualization Basics IaaS".
    static func cleanTitle(_ fileName: String) -> String {
        var words = ((fileName as NSString).deletingPathExtension)
            .split(whereSeparator: { $0 == "_" || $0 == " " })
            .map(String.init)
        if let first = words.first, Int(first) != nil { words.removeFirst() }
        if let last = words.last, last.lowercased().hasPrefix("v"), last.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }), last.count > 1 {
            words.removeLast()
        }
        if let first = words.first, Numbering.keywords.contains(first.lowercased()), words.count > 2, Numbering.value(words[1]) != nil {
            words.removeFirst(2)
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Reading

extension FileEvidence {
    static let audioExtensions: Set<String> = [
        "qta", "m4a", "mp3", "wav", "caf", "aif", "aiff", "aac", "flac", "mp4", "mov", "m4v", "3gp", "ogg", "opus"
    ]

    /// What kind of file `url` is for filing, or nil when it is none of deck, recording, capture.
    public static func kind(of url: URL) -> FilingKind? {
        let ext = url.pathExtension.lowercased()
        if ext == LecturePackage.pathExtension || ext == CaptureBundle.pathExtension { return .capture }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) { return .deck }
            if type.conforms(to: .audio) || type.conforms(to: .audiovisualContent) { return .recording }
        }
        return audioExtensions.contains(ext) ? .recording : nil
    }

    /// Reads what the file says. Nil when it is not a deck, recording or capture, or unreadable.
    public static func read(_ url: URL) async -> FileEvidence? {
        guard let kind = kind(of: url) else { return nil }
        let name = url.lastPathComponent
        let number = Numbering.fileNumber(name)
        var evidence = FileEvidence(url: url, fileName: name, kind: kind, fileNumber: number?.number, fileNumberEvidence: number?.evidence)
        switch kind {
        case .deck:
            guard let probe = DeckProbe.read(url) else { return nil }
            evidence.deck = deckEvidence(probe)
        case .capture:
            let manifest: LectureManifest
            let events: [LectureEvent]
            let duration: Double
            let isBundle = url.pathExtension.lowercased() == CaptureBundle.pathExtension
            if isBundle {
                // Its first entries only: the audio stays packed until it is filed.
                guard let summary = try? CaptureBundle.summary(of: url) else { return nil }
                manifest = summary.manifest
                events = summary.events
                duration = summary.duration
            } else {
                guard let contents = try? LecturePackageReader.read(LecturePackage(url: url)) else { return nil }
                manifest = contents.manifest
                events = contents.events
                duration = contents.duration
            }
            evidence.capture = CaptureEvidence(
                recordingID: manifest.id, courseID: manifest.courseID, lectureID: manifest.lectureID,
                startedAt: manifest.startedAt ?? events.map(\.wallClock).min(), duration: duration,
                courseName: manifest.courseName, courseShortName: manifest.courseShortName,
                sessionNumber: manifest.sessionNumber, isBundle: isBundle
            )
            // The class the phone recorded ("DC Lecture 2"), when its name says no number.
            if evidence.fileNumber == nil, let number = manifest.sessionNumber, (1...Numbering.maximum).contains(number) {
                evidence.fileNumber = number
                evidence.fileNumberEvidence = String(localized: "Lecture \(number)")
            }
        default:
            evidence.recording = await recordingEvidence(url)
        }
        return evidence
    }

    static func deckEvidence(_ probe: DeckProbe) -> DeckEvidence {
        let footer = Footer.lines(pages: probe.pages.map(\.text))
        let footerKeys = Set(footer.map(TextMatch.normalize))
        let first = probe.pages.first { $0.number == 1 }?.text ?? ""
        let titleSlide = first.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !footerKeys.contains(TextMatch.normalize(Footer.stripPageNumber($0))) }

        // The numbered heading on the title slide ("2 Virtualization Basics"); among the first lines.
        var number = titleSlide.prefix(8).lazy.compactMap(Numbering.numberedTitle).first
        // Else a numbered footer ("II: Syntax Computational Linguistics - Bo Sample").
        if number == nil { number = footer.lazy.compactMap(Numbering.numberedTitle).first.map { ($0.number, "") } }
        var dateText: String?
        var date: CalendarDay?
        for line in titleSlide {
            if let day = SlideDate.day(in: line) {
                date = day
                dateText = line
                break
            }
        }
        let numberedTitle = titleSlide.prefix(8).lazy.compactMap(Numbering.numberedTitle).first?.title
        return DeckEvidence(
            pageCount: probe.pageCount,
            pdfTitle: probe.pdfTitle,
            pdfAuthor: probe.pdfAuthor,
            footer: footer,
            titleSlide: titleSlide,
            slideNumber: number?.number,
            numberedTitle: numberedTitle,
            titleDate: date,
            titleDateText: dateText,
            sampledText: TextMatch.normalize(probe.pages.map(\.text).joined(separator: "\n"))
        )
    }

    static func recordingEvidence(_ url: URL) async -> RecordingEvidence {
        let asset = AVURLAsset(url: url)
        var start: Date?
        var source = StartSource.unknown
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            start = date
            source = .metadata
        } else if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
            start = date
            source = .fileDate
        }
        var duration: Double?
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            duration = Double(file.length) / file.fileFormat.sampleRate
        } else if let time = try? await asset.load(.duration), time.isNumeric {
            duration = time.seconds
        }
        // A stamp the audio would end after the file was last written (or after now) is not when
        // it began: Voice Memos' Share writes the export time, some recorders the end. The audio
        // ended by then, so it began `duration` earlier.
        if let stamped = start, let duration, duration > 0 {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let written = min(Date(), modified ?? Date())
            if stamped.addingTimeInterval(duration) > written.addingTimeInterval(writeSlack) {
                start = stamped.addingTimeInterval(-duration)
                source = .writtenAt
            }
        }
        return RecordingEvidence(startedAt: start, startSource: source, duration: duration)
    }

    /// How far past the file's last write a recording's end may fall (clocks, a slow write).
    static let writeSlack: TimeInterval = 120
}
