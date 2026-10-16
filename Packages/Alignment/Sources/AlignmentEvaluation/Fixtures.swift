import Alignment
import Foundation

/// The git-ignored lecture fixtures in `.data/fixtures` (see SOURCES.md there).
///
/// Located via `STUDYPORTAL_FIXTURES`, else by walking up from a source file until a directory
/// containing `.data/fixtures/SOURCES.md` is found (works from git worktrees inside the repo).
public struct FixtureLibrary: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func locate(from filePath: String = #filePath) -> FixtureLibrary? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["STUDYPORTAL_FIXTURES"], !override.isEmpty {
            let url = URL(filePath: override, directoryHint: .isDirectory)
            return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? FixtureLibrary(root: url) : nil
        }
        var directory = URL(filePath: filePath).deletingLastPathComponent()
        while directory.path(percentEncoded: false) != "/" {
            let candidate = directory.appending(path: ".data/fixtures", directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: candidate.appending(path: "SOURCES.md").path(percentEncoded: false)) {
                return FixtureLibrary(root: candidate)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    public func lecture(_ fixture: LectureFixture) throws -> LoadedLecture {
        let directory = root.appending(path: fixture.directory, directoryHint: .isDirectory)
        let slides = try Self.loadSlides(directory.appending(path: "slides.json"))
        let srt = try String(contentsOf: directory.appending(path: fixture.transcriptFile), encoding: .utf8)
        let prototypeURL = directory.appending(path: "align-prototype.json")
        let prototype = FileManager.default.fileExists(atPath: prototypeURL.path(percentEncoded: false))
            ? try PrototypeOutput.load(prototypeURL)
            : nil
        return LoadedLecture(fixture: fixture, slides: slides, transcript: SRT.parse(srt), prototype: prototype)
    }

    /// `slides.json` = `[[page, text], ...]`.
    static func loadSlides(_ url: URL) throws -> [SlideText] {
        let data = try Data(contentsOf: url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw FixtureError.malformed(url.lastPathComponent)
        }
        return try rows.map { row in
            guard row.count >= 2, let page = row[0] as? Int, let text = row[1] as? String else {
                throw FixtureError.malformed(url.lastPathComponent)
            }
            return SlideText(page: page, text: text)
        }
    }
}

public enum FixtureError: Error, Equatable {
    case malformed(String)
}

/// A fixture lecture with verified ground truth.
public struct LectureFixture: Hashable, Sendable, CustomStringConvertible {
    public var name: String
    public var directory: String
    public var transcriptFile: String
    public var truth: GroundTruth

    public static let clL1 = LectureFixture(
        name: "CL L1",
        directory: "cl-l1",
        transcriptFile: "whisper-fixed.srt",
        truth: .clL1
    )

    public static let dcL2 = LectureFixture(
        name: "DC L2",
        directory: "dc-l2",
        transcriptFile: "whisper-mc0.srt",
        truth: .dcL2
    )

    public static let all: [LectureFixture] = [.clL1, .dcL2]

    public var description: String { name }
}

public struct LoadedLecture: Sendable {
    public var fixture: LectureFixture
    public var slides: [SlideText]
    public var transcript: [TranscriptLine]
    public var prototype: PrototypeOutput?
}

/// Output of `tools/prototype/align.py` (`{"spans": [[page, start, end, match, title], ...]}`).
public struct PrototypeOutput: Sendable {
    public var spans: [AlignedSpan]

    public static func load(_ url: URL) throws -> PrototypeOutput {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["spans"] as? [[Any]] else {
            throw FixtureError.malformed(url.lastPathComponent)
        }
        let spans = try rows.map { row -> AlignedSpan in
            guard row.count >= 4, let page = row[0] as? Int,
                  let start = (row[1] as? NSNumber)?.doubleValue,
                  let end = (row[2] as? NSNumber)?.doubleValue,
                  let match = (row[3] as? NSNumber)?.doubleValue else {
                throw FixtureError.malformed(url.lastPathComponent)
            }
            return AlignedSpan(target: .slide(page), start: start, end: end, confidence: match, origin: .automatic)
        }
        return PrototypeOutput(spans: spans)
    }
}
