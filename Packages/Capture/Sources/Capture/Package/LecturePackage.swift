import AVFAudio
import Foundation

/// A lecture captured on disk: a folder `<uuid>.lecture` that is complete on its own, so a
/// recording survives app crashes and never depends on the database during class.
///
///     <uuid>.lecture/
///       manifest.json     LectureManifest (format, deck, start time, segments)
///       events.json       LectureEventLog (start, slide, back, jump, flag, pause, resume, stop)
///       notes.json        QuickNoteLog (per-slide notes typed in class)
///       audio/seg-0001.caf, seg-0002.caf, …   rolling segments
public struct LecturePackage: Sendable, Hashable {
    public static let pathExtension = "lecture"
    public static let audioFolder = "audio"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The id encoded in the folder name, if it is a UUID.
    public var id: UUID? {
        UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    public var manifestURL: URL { url.appending(path: "manifest.json") }
    public var eventsURL: URL { url.appending(path: "events.json") }
    public var notesURL: URL { url.appending(path: "notes.json") }
    public var audioDirectory: URL { url.appending(path: Self.audioFolder, directoryHint: .isDirectory) }

    /// `seg-0001.caf` for sequence 1.
    public static func segmentFileName(sequence: Int, fileExtension: String = "caf") -> String {
        String(format: "seg-%04d.%@", sequence, fileExtension)
    }

    /// Sequence number parsed from a segment file name, or nil.
    public static func segmentSequence(fileName: String) -> Int? {
        let stem = (fileName as NSString).deletingPathExtension
        guard stem.hasPrefix("seg-") else { return nil }
        return Int(stem.dropFirst(4))
    }

    /// Path of a segment relative to the package root.
    public static func segmentRelativePath(sequence: Int, fileExtension: String = "caf") -> String {
        "\(audioFolder)/\(segmentFileName(sequence: sequence, fileExtension: fileExtension))"
    }

    public func url(forRelativePath path: String) -> URL {
        url.appending(path: path, directoryHint: .notDirectory)
    }

    /// Creates an empty package folder `<id>.lecture` (with `audio/`) inside `directory`.
    public static func create(in directory: URL, id: UUID = UUID()) throws -> LecturePackage {
        let package = LecturePackage(
            url: directory.appending(path: "\(id.uuidString).\(pathExtension)", directoryHint: .isDirectory)
        )
        try FileManager.default.createDirectory(at: package.audioDirectory, withIntermediateDirectories: true)
        return package
    }

    /// All packages directly inside `directory`, oldest first by folder creation.
    public static func all(in directory: URL) throws -> [LecturePackage] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        )
        return contents
            .filter { $0.pathExtension == pathExtension }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left == right ? lhs.lastPathComponent < rhs.lastPathComponent : left < right
            }
            .map { LecturePackage(url: directory.appending(path: $0.lastPathComponent, directoryHint: .isDirectory)) }
    }

    /// Folder name, e.g. `…UUID….lecture`; unique within a recordings folder.
    public var name: String { url.lastPathComponent }
}

public enum LecturePackageError: Error, Equatable, Sendable {
    case missingManifest(String)
    case unsupportedVersion(Int)
}

/// Everything in a package, with audio segments resolved against the files on disk.
public struct LecturePackageContents: Sendable, Hashable {
    public var package: LecturePackage
    public var manifest: LectureManifest
    public var events: [LectureEvent]
    public var notes: [QuickNote]
    /// Segments that exist on disk, ordered, each with a frame count.
    public var segments: [AudioSegmentInfo]

    /// True if recording stopped cleanly; false after a crash (the package is still usable).
    public var isComplete: Bool { manifest.endedAt != nil }

    /// Frames from sample 0 to the end of the last segment.
    public var endSample: Int64 {
        segments.compactMap(\.endSample).max() ?? 0
    }

    /// Seconds from sample 0 to the end of the last segment (pauses included: the clock keeps
    /// real time, so playback and filing see the real span).
    public var duration: TimeInterval {
        manifest.sampleRate > 0 ? Double(endSample) / manifest.sampleRate : 0
    }

    /// The pauses the events record (iPhone); empty for a recording never paused.
    public var pauses: RecordingPauses { RecordingPauses(events: events) }

    /// Seconds recorded: `duration` without the pauses inside it (the phone's timer and outbox).
    public var recordedDuration: TimeInterval {
        max(0, duration - pauses.gapSeconds(sampleRate: manifest.sampleRate, through: endSample))
    }

    /// The segment's file: always inside the package's audio folder, whatever `segment.file` says.
    public func url(for segment: AudioSegmentInfo) -> URL {
        let name = (segment.file as NSString).lastPathComponent
        return package.audioDirectory.appending(path: name, directoryHint: .notDirectory)
    }
}

/// Reads lecture packages, including ones left behind by a crash.
public enum LecturePackageReader {
    public static func read(_ package: LecturePackage) throws -> LecturePackageContents {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: package.manifestURL.path(percentEncoded: false)) else {
            throw LecturePackageError.missingManifest(package.url.lastPathComponent)
        }
        let manifest = try CaptureJSON.read(LectureManifest.self, from: package.manifestURL)
        guard manifest.version <= LectureManifest.currentVersion else {
            throw LecturePackageError.unsupportedVersion(manifest.version)
        }
        let events = fileManager.fileExists(atPath: package.eventsURL.path(percentEncoded: false))
            ? try CaptureJSON.read(LectureEventLog.self, from: package.eventsURL).events
            : []
        let notes = fileManager.fileExists(atPath: package.notesURL.path(percentEncoded: false))
            ? try CaptureJSON.read(QuickNoteLog.self, from: package.notesURL).notes
            : []
        let sorted = events.sorted(by: eventOrder)
        return LecturePackageContents(
            package: package,
            manifest: manifest,
            events: sorted,
            notes: notes,
            segments: resolveSegments(package: package, manifest: manifest, events: sorted)
        )
    }

    public static func read(at url: URL) throws -> LecturePackageContents {
        try read(LecturePackage(url: url))
    }

    /// Packages in `directory` that were not imported yet (including crashed ones).
    public static func pending(in directory: URL) throws -> [LecturePackage] {
        try LecturePackage.all(in: directory).filter { package in
            guard let manifest = try? CaptureJSON.read(LectureManifest.self, from: package.manifestURL) else {
                return false
            }
            return manifest.importedAt == nil
        }
    }

    /// Matches the manifest's segment list with the audio files on disk.
    ///
    /// After a crash the manifest may lack the last segment's frame count or even the segment
    /// itself (crash right after a rollover, or right after a resume). Frame counts then come
    /// from the files, and an unknown file is placed right after the previous segment, or at the
    /// first `resume` at or after that end (the audio after a pause starts there, not at the
    /// pause).
    static func resolveSegments(package: LecturePackage, manifest: LectureManifest, events: [LectureEvent]) -> [AudioSegmentInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: package.audioDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let onDisk: [Int: URL] = Dictionary(
            files.compactMap { url in
                LecturePackage.segmentSequence(fileName: url.lastPathComponent).map { ($0, url) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let known = Dictionary(manifest.segments.map { ($0.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        let resumes = events.filter { $0.kind == .resume }.compactMap(\.sampleTime).sorted()

        var resolved: [AudioSegmentInfo] = []
        for sequence in onDisk.keys.sorted() {
            guard let url = onDisk[sequence] else { continue }
            let previousEnd = resolved.last?.endSample ?? 0
            let resumed = resumes.first { $0 >= previousEnd }
            var segment = known[sequence] ?? AudioSegmentInfo(
                sequence: sequence,
                file: "",
                startSample: resumed ?? previousEnd,
                startReason: sequence == 1 ? .start : (resumed == nil ? .rollover : .discontinuity)
            )
            // Always the file actually found: the manifest's path is untrusted (a package can
            // come from anywhere) and must never point outside the audio folder.
            segment.file = "\(LecturePackage.audioFolder)/\(url.lastPathComponent)"
            if segment.frameCount == nil {
                segment.frameCount = frameCount(of: url)
            }
            guard let frames = segment.frameCount, frames > 0 else {
                CaptureLog.capture.notice("Skipping empty segment \(url.lastPathComponent, privacy: .public)")
                continue
            }
            if segment.startSample < previousEnd {
                segment.startSample = previousEnd
            }
            resolved.append(segment)
        }
        return resolved
    }

    /// Frames readable from an audio file, or nil if it cannot be opened.
    static func frameCount(of url: URL) -> Int64? {
        do {
            return try AVAudioFile(forReading: url).length
        } catch {
            CaptureLog.capture.error(
                "Unreadable segment \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func eventOrder(_ lhs: LectureEvent, _ rhs: LectureEvent) -> Bool {
        lhs.hostTime == rhs.hostTime ? lhs.wallClock < rhs.wallClock : lhs.hostTime < rhs.hostTime
    }
}
