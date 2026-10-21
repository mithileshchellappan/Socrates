import Alignment
import AlignmentEvaluation
import Capture
import Foundation
import Processing
import StudyCore
import Transcription

// process-lecture: runs one lecture through the same import + processing code the app uses and
// prints what landed in the database. Output contains lecture text: keep libraries under .data/.
//
//   process-lecture run     --audio A [--deck PDF] --library DIR [--course NAME] [--language en] [--truth FIXTURE] [--json OUT]
//   process-lecture capture --audio A  --deck PDF  --library DIR --stamps "m:ss=page,…" [--start-page N] [--truth FIXTURE] [--json OUT]
//
// `--truth` names a fixture folder with a `truth.json` (git-ignored, see `LectureFixture`); the
// report then scores the alignment against it.
//
// `capture` first writes a lecture package from the audio, as live capture would (48 kHz CAF,
// 5-minute segments, a start event on --start-page and one slide event per stamp), then imports
// that package. The library is created if needed; an existing one is reused.

struct Options {
    var mode = ""
    var audio: URL?
    var deck: URL?
    var library: URL?
    var course = "Computational Linguistics"
    var language = "en"
    var stamps: [CaptureStamp] = []
    var startPage: Int?
    var truth: URL?
    var json: URL?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.dropFirst().makeIterator()
        guard let mode = iterator.next(), ["run", "capture"].contains(mode) else { throw Usage() }
        options.mode = mode
        while let flag = iterator.next() {
            guard let value = iterator.next() else { throw Usage() }
            switch flag {
            case "--audio": options.audio = URL(filePath: value)
            case "--deck": options.deck = URL(filePath: value)
            case "--library": options.library = URL(filePath: value, directoryHint: .isDirectory)
            case "--course": options.course = value
            case "--language": options.language = value
            case "--start-page": options.startPage = Int(value)
            case "--truth": options.truth = URL(filePath: value, directoryHint: .isDirectory)
            case "--json": options.json = URL(filePath: value)
            case "--stamps":
                options.stamps = try value.split(separator: ",").map { item in
                    let parts = item.split(separator: "=")
                    guard parts.count == 2, let page = Int(parts[1]) else { throw Usage() }
                    return CaptureStamp(time: clockSeconds(String(parts[0])), page: page)
                }
            default: throw Usage()
            }
        }
        guard options.audio != nil, options.library != nil else { throw Usage() }
        if mode == "capture", options.deck == nil { throw Usage() }
        return options
    }
}

struct Usage: Error, CustomStringConvertible {
    var description: String {
        """
        usage: process-lecture run     --audio FILE [--deck PDF] --library DIR [--course NAME] [--language en] [--truth FIXTURE] [--json OUT]
               process-lecture capture --audio FILE --deck PDF --library DIR --stamps "m:ss=page,…" [--start-page N] [--truth …] [--json OUT]
        """
    }
}

/// "m:ss" / "h:mm:ss" / seconds → seconds.
func clockSeconds(_ text: String) -> Double {
    text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

func elapsed(since start: ContinuousClock.Instant) -> Double {
    let parts = (ContinuousClock.now - start).components
    return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
}

@main
struct ProcessLecture {
    static func main() async {
        do {
            try await run(Options.parse(CommandLine.arguments))
        } catch let usage as Usage {
            FileHandle.standardError.write(Data((usage.description + "\n").utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        guard let library = options.library, let audio = options.audio else { throw Usage() }
        let total = ContinuousClock.now
        let paths = AppPaths(root: library)
        try paths.createDirectories()
        let services = StudyServices(
            paths: paths,
            database: try StudyDatabase.open(at: paths.database),
            blobs: BlobStore(root: paths.blobs),
            secrets: InMemorySecretStore()
        )
        print("Library: \(paths.database.path(percentEncoded: false))")

        // Model first, so its load time is reported apart from the lecture's.
        let engine = WhisperKitEngine(store: try .shared())
        let modelStart = ContinuousClock.now
        try await engine.prepare { _ in }
        let modelSeconds = elapsed(since: modelStart)
        print(String(format: "Model ready in %.1f s (%@)", modelSeconds, engine.identifier))

        let course = try await findOrCreateCourse(named: options.course, language: options.language, services: services)
        let importStart = ContinuousClock.now
        let imported: ImportedLecture
        switch options.mode {
        case "capture":
            guard let deckURL = options.deck else { throw Usage() }
            let (deck, _) = try await DeckImporter(services: services).importDeck(at: deckURL, courseID: course.id)
            let package = try await LecturePackageBuilder.build(
                audio: audio,
                in: paths.recordings,
                stamps: options.stamps,
                startPage: options.startPage,
                courseID: course.id,
                lectureID: UUID(),
                deck: DeckReference(sha256: deck.blobSHA256, pageCount: deck.pageCount, title: deck.title, deckID: deck.id),
                startedAt: LectureImporterDates.creationDate(of: audio) ?? Date()
            )
            print(String(format: "Wrote package %@ in %.1f s", package.name, elapsed(since: importStart)))
            imported = try await LectureImporter(services: services).importCapture(at: package.url)
        default:
            imported = try await LectureImporter(services: services)
                .importRecording(audio: audio, deck: options.deck, courseID: course.id)
        }
        let importSeconds = elapsed(since: importStart)
        print(String(
            format: "Imported lecture %@ (%@, %@ audio) in %.1f s%@",
            imported.lecture.id.uuidString, imported.lecture.title, clock(imported.recording.duration), importSeconds,
            imported.wasAlreadyImported ? " — already imported" : ""
        ))

        let stageTimes = StageTimes()
        let processor = LectureProcessor(services: services, engine: engine, onIdle: {
            await engine.decoder.unload()
        }, observer: { event in
            stageTimes.record(event)
        })
        try await processor.recover()
        let processStart = ContinuousClock.now
        await processor.runUntilIdle()
        let processSeconds = elapsed(since: processStart)

        let report = try await Report.make(
            services: services, imported: imported, stamps: options.stamps, startPage: options.startPage,
            truth: try options.truth.map { folder in
                let fixture = try LectureFixture.load(directory: folder)
                return (fixture.name, fixture.truth)
            },
            times: Report.Times(
                model: modelSeconds, importing: importSeconds, processing: processSeconds,
                transcribe: stageTimes.seconds(.transcribe), align: stageTimes.seconds(.align),
                total: elapsed(since: total)
            )
        )
        report.print()
        if let json = options.json {
            try report.json().write(to: json, options: .atomic)
            print("Report: \(json.path(percentEncoded: false))")
        }
        if !report.failures.isEmpty { exit(3) }
    }

    static func findOrCreateCourse(named name: String, language: String, services: StudyServices) async throws -> Course {
        if let course = try await CourseRepository(store: services.records).all().first(where: { $0.name == name }) {
            return course
        }
        return try await services.records.save(Course(name: name, language: language, adminLanguage: "de", recordingConsentAt: Date()))
    }
}

enum LectureImporterDates {
    static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
