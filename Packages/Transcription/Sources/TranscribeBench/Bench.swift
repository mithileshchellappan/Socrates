import Foundation
import Synchronization
@preconcurrency import WhisperKit
import Transcription

/// Real-model evaluation of the transcription engine.
///
/// Transcripts it writes contain lecture text: keep `--out` under the git-ignored `.data/`.
enum Bench {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            Console.error(usage)
            return 2
        }
        let options = Arguments(Array(arguments.dropFirst()))
        do {
            switch command {
            case "prepare": try await prepare(options)
            case "run": try await transcribe(options)
            case "analyze": try analyze(options)
            case "probe": try await probe(options)
            case "langmap": try await languageMap(options)
            default:
                Console.error(usage)
                return 2
            }
            return 0
        } catch {
            Console.error("error: \(error)")
            return 1
        }
    }

    static let usage = """
    usage: TranscribeBench <command> [options]
      prepare [--models DIR]
          Download and compile the Whisper model (large-v3-turbo).
      run --audio FILE --out FILE.json --strategy forced-en|forced-de|detect-any|detect-de-en
          [--pipeline builtin|engine] [--tuning lecture|whisperkit] [--no-guards]
          [--glossary "a, b, c"] [--limit SECONDS | --start SECONDS --end SECONDS] [--label NAME]
          [--models DIR]
          builtin = WhisperKit's own VAD chunking, no guards; engine = WhisperKitEngine.
          --start/--end transcribe an excerpt; times in the output stay on the file's clock.
          Writes the transcript (lecture text) as JSON: keep FILE under .data/.
      langmap --audio FILE --out FILE.json [--margin 0.15] [--base OLD.json --windows "870-900,2190-2220"]
          Reference language per 30 s window from forced en/de decoding likelihood. With --base,
          only the listed windows are decoded again and replace theirs in OLD.
      analyze --audio FILE --runs A.json B.json … [--srt FILE.srt …]
          [--reference "de:0-371,en:371-" | --reference-file LANGMAP.json] [--range START-END] [--json FILE]
          Prints text-free metrics as a Markdown table. --range limits every run to one excerpt.
      probe --audio FILE --strategy S --start SECONDS [--end SECONDS] [--temperature T]
          [--fallbacks N] [--raw [--language L] [--words] [--special] [--suppress-blank]
          [--no-first-token-threshold]]
          Decodes one window and prints its text (debugging only).
    """

    static func store(_ options: Arguments) throws -> WhisperModelStore {
        if let path = options.value("--models") {
            return WhisperModelStore(directory: URL(filePath: path, directoryHint: .isDirectory))
        }
        return try WhisperModelStore.shared()
    }

    // MARK: prepare

    static func prepare(_ options: Arguments) async throws {
        let store = try store(options)
        let decoder = WhisperKitDecoder(model: .largeV3Turbo, store: store)
        let started = ContinuousClock.now
        let reporter = ProgressPrinter()
        try await decoder.load { reporter.report($0) }
        Console.line("model ready at \(store.folder(for: .largeV3Turbo).path(percentEncoded: false)) after \(started.duration(to: .now))")
    }

    // MARK: run

    static func strategy(named name: String) throws -> LanguageStrategy {
        switch name {
        case "forced-en": return .forced("en")
        case "forced-de": return .forced("de")
        case "detect-any": return .detectAny
        case "detect-de-en": return .detect(among: ["de", "en"])
        default: throw BenchError.usage("unknown strategy \(name)")
        }
    }

    static func transcribe(_ options: Arguments) async throws {
        guard let audioPath = options.value("--audio"), let outPath = options.value("--out"),
              let strategyName = options.value("--strategy") else { throw BenchError.usage("run needs --audio, --out, --strategy") }
        let strategy = try strategy(named: strategyName)
        let pipeline = options.value("--pipeline") ?? "engine"
        let glossary = options.value("--glossary")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let store = try store(options)

        let tuning: WhisperKitDecoder.Tuning = options.value("--tuning") == "whisperkit" ? .whisperKitDefaults : .lecture
        let engine = WhisperKitEngine(model: .largeV3Turbo, store: store, tuning: tuning)
        let loadStarted = ContinuousClock.now
        try await engine.prepare()
        let loadSeconds = loadStarted.duration(to: .now).seconds

        var samples = try AudioTimeline.load(.file(URL(filePath: audioPath)))
        let rate = Double(AudioTimeline.sampleRate)
        if let limit = options.value("--limit").flatMap(Double.init) {
            samples = Array(samples.prefix(Int(limit * rate)))
        }
        var offset = 0.0
        if let start = options.value("--start").flatMap(Double.init) {
            let end = options.value("--end").flatMap(Double.init) ?? Double(samples.count) / rate
            let first = max(0, min(Int(start * rate), samples.count))
            let last = max(first, min(Int(end * rate), samples.count))
            samples = Array(samples[first..<last])
            offset = Double(first) / rate
        }
        let duration = Double(samples.count) / Double(AudioTimeline.sampleRate)
        Console.error("transcribing \(Int(duration)) s with \(strategyName) via \(pipeline)…")

        let reporter = ProgressPrinter()
        let started = ContinuousClock.now
        var record = RunRecord(
            label: options.value("--label") ?? "\(strategyName)-\(pipeline)",
            audio: URL(filePath: audioPath).deletingLastPathComponent().lastPathComponent,
            strategy: strategyName,
            pipeline: pipeline,
            guards: !options.has("--no-guards"),
            glossaryTerms: glossary.count,
            tuning: options.value("--tuning") ?? "lecture",
            audioSeconds: duration,
            offset: offset == 0 ? nil : offset,
            wallSeconds: 0,
            modelLoadSeconds: loadSeconds,
            chunks: [],
            segments: [],
            gaps: []
        )
        switch pipeline {
        case "builtin":
            let chunks = try await engine.decoder.transcribeWithBuiltInChunking(
                samples: samples,
                language: chunkLanguage(strategy),
                prompt: glossary.isEmpty ? nil : glossary.joined(separator: ", ")
            )
            record.wallSeconds = started.duration(to: .now).seconds
            let starts = chunks.map(\.start)
            for (index, chunk) in chunks.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1] : duration
                record.chunks.append(.init(start: chunk.start, end: end, language: chunk.language))
                record.segments += chunk.segments.map(RunRecord.Segment.init)
            }
        case "engine":
            let transcript = try await engine.transcriber.transcribe(
                samples: samples,
                options: TranscriptionOptions(
                    language: strategy,
                    glossary: glossary,
                    guards: options.has("--no-guards") ? .none : .standard
                ),
                progress: { reporter.report($0) }
            )
            record.wallSeconds = started.duration(to: .now).seconds
            record.chunks = transcript.chunks.map { .init(start: $0.start, end: $0.end, language: $0.language) }
            record.segments = transcript.segments.map(RunRecord.Segment.init)
            record.gaps = transcript.gaps
            record.loopsFound = transcript.chunks.reduce(0) { $0 + $1.loopsFound }
            record.loopsRemaining = transcript.chunks.reduce(0) { $0 + $1.loopsRemaining }
        default:
            throw BenchError.usage("unknown pipeline \(pipeline)")
        }

        if offset != 0 { record.shift(by: offset) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let outURL = URL(filePath: outPath)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: outURL)
        Console.line("\(record.label): \(String(format: "%.1f", record.wallSeconds)) s for \(Int(duration)) s audio, \(record.segments.count) segments -> \(outPath)")
    }

    /// Decodes one window (≤ 30 s) and prints the raw decoder output. For debugging only:
    /// prints transcript text to the terminal.
    static func probe(_ options: Arguments) async throws {
        guard let audioPath = options.value("--audio"), let strategyName = options.value("--strategy"),
              let start = options.value("--start").flatMap(Double.init) else { throw BenchError.usage("probe needs --audio, --strategy, --start") }
        let end = options.value("--end").flatMap(Double.init) ?? start + 30
        let decoder = WhisperKitDecoder(model: .largeV3Turbo, store: try store(options))
        try await decoder.load()
        let samples = try AudioTimeline.load(.file(URL(filePath: audioPath)))
        let rate = Double(AudioTimeline.sampleRate)
        let slice = Array(samples[Int(start * rate)..<min(Int(end * rate), samples.count)])
        let temperature = options.value("--temperature").flatMap(Float.init) ?? 0
        if options.has("--raw") {
            var decoding = DecodingOptions(
                verbose: true,
                language: options.value("--language"),
                temperature: temperature,
                temperatureFallbackCount: options.value("--fallbacks").flatMap(Int.init) ?? 5,
                detectLanguage: options.value("--language") == nil,
                skipSpecialTokens: !options.has("--special"),
                wordTimestamps: options.has("--words")
            )
            if options.has("--no-first-token-threshold") { decoding.firstTokenLogProbThreshold = nil }
            if options.has("--suppress-blank") { decoding.suppressBlank = true }
            let results = try await decoder.rawTranscribe(samples: slice, options: decoding)
            for result in results {
                Console.line("language \(result.language) segments \(result.segments.count)")
                for segment in result.segments {
                    Console.line(String(format: "%7.2f %7.2f lp %.2f t %.1f tokens %d | ", segment.start, segment.end, segment.avgLogprob, segment.temperature, segment.tokens.count) + segment.text)
                }
            }
            return
        }
        let outcome = try await decoder.decode([ChunkDecodeRequest(
            samples: slice, language: chunkLanguage(try strategy(named: strategyName)), temperature: temperature,
            temperatureFallbackCount: options.value("--fallbacks").flatMap(Int.init) ?? 5
        )])
        switch outcome.first {
        case .success(let result)?:
            Console.line("language \(result.language), \(result.segments.count) segments")
            for segment in result.segments {
                Console.line(String(format: "%7.2f %7.2f lp %.2f cr %.2f t %.1f w %d | ", start + segment.start, start + segment.end, segment.avgLogProb, segment.compressionRatio, segment.temperature, segment.words.count) + segment.text)
            }
        case .failure(let error)?:
            Console.line("failed: \(error)")
        case nil:
            Console.line("no result")
        }
    }

    /// Builds a reference "which language was spoken" map: every 30 s window with speech is
    /// decoded twice, forced to English and forced to German (temperature 0, no fallback), and the
    /// language whose decoding is clearly more likely wins. Forced decoding of a wrong language
    /// translates, which costs likelihood, so this is a far stronger signal than Whisper's
    /// one-token language detection.
    static func languageMap(_ options: Arguments) async throws {
        guard let audioPath = options.value("--audio"), let outPath = options.value("--out") else {
            throw BenchError.usage("langmap needs --audio and --out")
        }
        let margin = options.value("--margin").flatMap(Double.init) ?? 0.15
        let decoder = WhisperKitDecoder(model: .largeV3Turbo, store: try store(options))
        try await decoder.load()
        let samples = try AudioTimeline.load(.file(URL(filePath: audioPath)))
        let rate = Double(AudioTimeline.sampleRate)
        let duration = Double(samples.count) / rate
        let speech = SpeechActivityDetector().speechRegions(in: samples)

        var windows: [TimeRange] = []
        var start = 0.0
        while start < duration {
            let window = TimeRange(start: start, end: min(start + 30, duration))
            if TimeRanges.seconds(of: speech, within: window) >= 3 { windows.append(window) }
            start += 30
        }
        var base: LanguageMap?
        if let basePath = options.value("--base") {
            base = try JSONDecoder().decode(LanguageMap.self, from: Data(contentsOf: URL(filePath: basePath)))
            let starts = (options.value("--windows") ?? "").split(separator: ",").compactMap { item in
                item.split(separator: "-").first.flatMap { Double($0) }
            }
            windows = windows.filter { window in starts.contains { abs($0 - window.start) < 0.5 } }
        }
        func decodeAll(_ language: String) async throws -> [ChunkDecodeResult?] {
            var results: [ChunkDecodeResult?] = []
            for batchStart in stride(from: 0, to: windows.count, by: decoder.preferredBatchSize) {
                let batch = windows[batchStart..<min(batchStart + decoder.preferredBatchSize, windows.count)]
                let outcomes = try await decoder.decode(batch.map { window in
                    ChunkDecodeRequest(
                        samples: Array(samples[Int(window.start * rate)..<min(Int(window.end * rate), samples.count)]),
                        language: .fixed(language), temperature: 0, temperatureFallbackCount: 0, wordTimestamps: false
                    )
                })
                results += outcomes.map { try? $0.get() }
                Console.error("  \(language) \(results.count)/\(windows.count)")
            }
            return results
        }
        let started = ContinuousClock.now
        let english = try await decodeAll("en")
        let german = try await decodeAll("de")

        var map = LanguageMap(margin: margin, windows: [])
        for (index, window) in windows.enumerated() {
            let en = english[index].map(Self.meanLogProb) ?? -10
            let de = german[index].map(Self.meanLogProb) ?? -10
            let enText = english[index].map { $0.segments.map(\.text).joined(separator: " ") } ?? ""
            let deText = german[index].map { $0.segments.map(\.text).joined(separator: " ") } ?? ""
            let enWords = RepetitionDetector.words(in: enText).count
            let deWords = RepetitionDetector.words(in: deText).count
            // A forced decoding that loops or collapses scores a high likelihood without being
            // evidence ("Folle-Folle-Folle-…"), so it has to be well-formed to count.
            let enValid = english[index].map { Self.isWellFormed($0, words: enWords, otherWords: deWords) } ?? false
            let deValid = german[index].map { Self.isWellFormed($0, words: deWords, otherWords: enWords) } ?? false
            var label = "mixed"
            if enValid, en - de >= margin || !deValid { label = "en" }
            if deValid, de - en >= margin || !enValid { label = "de" }
            if !enValid, !deValid { label = "mixed" }
            // Forced German that still comes out English (or the reverse) settles it.
            if deValid, TextLanguage.guess(deText) == "en" { label = "en" }
            if enValid, TextLanguage.guess(enText) == "de" { label = "de" }
            map.windows.append(.init(
                range: window, english: en, german: de, englishWords: enWords, germanWords: deWords,
                englishValid: enValid, germanValid: deValid, label: label
            ))
        }
        if var merged = base {
            for window in map.windows {
                if let index = merged.windows.firstIndex(where: { abs($0.range.start - window.range.start) < 0.5 }) {
                    merged.windows[index] = window
                }
            }
            map = merged
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(map).write(to: URL(filePath: outPath))
        let counts = Dictionary(grouping: map.windows, by: \.label).mapValues(\.count)
        Console.line("language map: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) windows in \(started.duration(to: .now))")
        for window in map.windows where window.label != "en" || window.englishValid == false {
            let validity = "\(window.englishValid.map { $0 ? "ok" : "bad" } ?? "?")/\(window.germanValid.map { $0 ? "ok" : "bad" } ?? "?")"
            Console.line(String(format: "  %@ %@ en %.2f de %.2f en/de %@", window.label, "\(window.range)", window.english, window.german, validity))
        }
    }

    /// No compression-ratio failure, no repetition loop (also inside hyphenated words) and at
    /// least 40 % of the words the other language's decoding produced.
    static func isWellFormed(_ result: ChunkDecodeResult, words: Int, otherWords: Int) -> Bool {
        let text = result.segments.map(\.text).joined(separator: " ")
        let tokens = RepetitionDetector.words(in: text)
        return words > 0
            && result.segments.allSatisfy { $0.compressionRatio <= 2.4 }
            && RepetitionDetector.loopGuard.repetitions(in: tokens).isEmpty
            && tokens.allSatisfy { RepetitionDetector.hyphenatedCopies(in: $0) < 4 }
            && Double(words) >= 0.4 * Double(otherWords)
    }

    /// Mean token log probability over a decoding, weighting segments by word count.
    static func meanLogProb(_ result: ChunkDecodeResult) -> Double {
        let weights = result.segments.map { Double(max(RepetitionDetector.words(in: $0.text).count, 1)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return -10 }
        return zip(result.segments, weights).reduce(0) { $0 + $1.0.avgLogProb * $1.1 } / total
    }

    static func chunkLanguage(_ strategy: LanguageStrategy) -> ChunkLanguage {
        switch strategy {
        case .forced(let code): .fixed(code)
        case .detectAny: .detect(among: nil)
        case .detect(let candidates): .detect(among: candidates)
        }
    }

    // MARK: analyze

    static func analyze(_ options: Arguments) throws {
        guard let audioPath = options.value("--audio") else { throw BenchError.usage("analyze needs --audio") }
        let runs = options.values(after: "--runs")
        let srts = options.values(after: "--srt")
        var reference = options.value("--reference").flatMap(ReferenceLanguage.init(parsing:))
        if let path = options.value("--reference-file") {
            reference = try JSONDecoder().decode(LanguageMap.self, from: Data(contentsOf: URL(filePath: path))).reference
        }

        let samples = try AudioTimeline.load(.file(URL(filePath: audioPath)))
        let duration = Double(samples.count) / Double(AudioTimeline.sampleRate)
        var speech = SpeechActivityDetector().speechRegions(in: samples)
        // An excerpt: only speech, text and chunk labels inside it count.
        let excerpt = options.value("--range").flatMap { text -> TimeRange? in
            let bounds = text.split(separator: "-").compactMap { Double($0) }
            return bounds.count == 2 ? TimeRange(start: bounds[0], end: bounds[1]) : nil
        }
        if let excerpt {
            speech = speech.map { $0.clamped(to: excerpt) }.filter { $0.duration > 0 }
            Console.line("excerpt \(excerpt)")
        }
        func inExcerpt(_ start: Double, _ end: Double) -> Bool {
            excerpt.map { $0.contains((start + end) / 2) } ?? true
        }
        Console.line("audio \(TimeRange.clock(duration)), detected speech \(Int(TimeRanges.totalDuration(speech))) s in \(speech.count) regions\n")

        var rows: [(label: String, record: RunRecord?, metrics: TranscriptMetrics)] = []
        let decoder = JSONDecoder()
        for path in runs {
            let record = try decoder.decode(RunRecord.self, from: Data(contentsOf: URL(filePath: path)))
            let metrics = TranscriptMetrics.measure(
                segments: record.segments.filter { inExcerpt($0.start, $0.end) }.map { .init(start: $0.start, end: $0.end, text: $0.text) },
                chunkLabels: record.chunks.filter { inExcerpt($0.start, $0.end) }.compactMap { chunk in
                    chunk.language.map { (TimeRange(start: chunk.start, end: chunk.end), $0) }
                },
                speech: speech,
                duration: duration,
                reference: reference
            )
            rows.append((record.label, record, metrics))
        }
        for path in srts {
            let cues = SubRip.parse(try String(contentsOf: URL(filePath: path), encoding: .utf8))
            let metrics = TranscriptMetrics.measure(
                segments: cues.filter { inExcerpt($0.start, $0.end) }.map { .init(start: $0.start, end: $0.end, text: $0.text) },
                chunkLabels: [],
                speech: speech,
                duration: duration,
                reference: reference
            )
            rows.append(("whisper.cpp " + URL(filePath: path).lastPathComponent, nil, metrics))
        }

        Console.line("| Run | Wall | ×RT | T>0 segs | Segments | Words | Speech covered | Missing ≥3 s (speech s) | Loops (extra words) | Chunk labels | Labels ≠ spoken | DE written EN | EN written DE |")
        Console.line("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for row in rows {
            let wall = row.record.map { String(format: $0.wallSeconds < 60 ? "%.1f s" : "%.0f s", $0.wallSeconds) } ?? "n/a"
            let speed = row.record.map { String(format: "%.1f", $0.audioSeconds / max($0.wallSeconds, 0.001)) } ?? "n/a"
            let labels = row.metrics.languageSeconds.isEmpty ? "n/a" : row.metrics.languageSeconds
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \(Int($0.value)) s" }
                .joined(separator: ", ")
            let m = row.metrics
            let deAsEn = m.mismatches(spoken: "de", written: "en").count
            let enAsDe = m.mismatches(spoken: "en", written: "de").count
            let hot = row.record.map { record in String(format: "%.0f %%", 100 * Double(record.segments.filter { ($0.temperature ?? 0) > 0 }.count) / Double(max(record.segments.count, 1))) } ?? "n/a"
            let wrongLabels = m.labelsJudged == 0 ? "n/a" : "\(m.labelMismatches.count)/\(m.labelsJudged)"
            Console.line("| \(row.label) | \(wall) | \(speed) | \(hot) | \(m.segmentCount) | \(m.wordCount) | \(String(format: "%.1f %%", m.coverage * 100)) | \(m.missing.count) (\(Int(m.missingSpeechSeconds))) | \(m.loops) (\(m.loopRedundantWords)) | \(labels) | \(wrongLabels) | \(deAsEn) | \(enAsDe) |")
        }
        if rows.contains(where: { !$0.metrics.spans.filter { $0.spoken == "de" }.isEmpty }) {
            Console.line("")
            Console.line("| Run | German spans | written DE | translated | no text | unclear |")
            Console.line("|---|---|---|---|---|---|")
            for row in rows {
                let outcome = row.metrics.spanOutcome(spoken: "de")
                let total = row.metrics.spans.filter { $0.spoken == "de" }.count
                Console.line("| \(row.label) | \(total) | \(outcome.kept) | \(outcome.translated) | \(outcome.missing) | \(outcome.unclear) |")
            }
        }
        Console.line("")
        for row in rows {
            let m = row.metrics
            Console.line("\(row.label):")
            if !m.languageRuns.isEmpty {
                Console.line("  label runs (\(m.labelSwitches) switches): " + m.languageRuns.prefix(40).map { "\($0.language) \($0.range) (\($0.chunks))" }.joined(separator: "; "))
            }
            Console.line("  judged 30 s windows: \(m.judgedWindows); mismatches: " + m.mismatches.map { "\($0.spoken)→\($0.written) \($0.range)" }.joined(separator: ", "))
            Console.line("  chunk labels judged: \(m.labelsJudged); wrong: " + m.labelMismatches.map { "\($0.spoken) labelled \($0.written) \($0.range)" }.joined(separator: ", "))
            Console.line("  missing: " + m.missing.map { "\($0)" }.joined(separator: ", "))
            let german = m.spans.filter { $0.spoken == "de" }
            if !german.isEmpty {
                Console.line("  German spans: " + german.map { "\($0.range) \($0.written ?? ($0.words == 0 ? "none" : "?")) (\($0.words) w)" }.joined(separator: ", "))
            }
            if let record = row.record, record.pipeline == "engine" {
                let gaps = record.gaps.filter { inExcerpt($0.start, $0.end) }
                let repairs = Dictionary(grouping: record.segments.filter { inExcerpt($0.start, $0.end) }.compactMap(\.repair), by: { $0 })
                    .mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                Console.line("  engine: loops found \(record.loopsFound ?? 0), remaining \(record.loopsRemaining ?? 0); gaps \(gaps.count), recovered \(gaps.filter(\.recovered).count); repaired segments: \(repairs.isEmpty ? "none" : repairs)")
            }
        }

        if let jsonPath = options.value("--json") {
            let summary = rows.map { MetricsSummary(label: $0.label, wallSeconds: $0.record?.wallSeconds, audioSeconds: $0.record?.audioSeconds ?? duration, metrics: $0.metrics) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: URL(filePath: jsonPath))
        }
    }
}

/// Output of `langmap`: the spoken language per 30 s window, by forced-decoding likelihood.
struct LanguageMap: Codable {
    struct Window: Codable {
        var range: TimeRange
        var english: Double
        var german: Double
        var englishWords: Int?
        var germanWords: Int?
        var englishValid: Bool?
        var germanValid: Bool?
        /// "en", "de" or "mixed".
        var label: String
    }

    var margin: Double
    var windows: [Window]

    /// Windows labelled "mixed" are left out, so they never count as mismatches.
    var reference: ReferenceLanguage {
        ReferenceLanguage(spans: windows.filter { $0.label != "mixed" }.map { .init(range: $0.range, language: $0.label) })
    }
}

struct MetricsSummary: Codable {
    var label: String
    var wallSeconds: Double?
    var audioSeconds: Double
    var metrics: TranscriptMetrics
}

/// One transcription run as written by `run`. Contains lecture text.
struct RunRecord: Codable {
    struct Chunk: Codable {
        var start: Double
        var end: Double
        var language: String?
    }

    struct Segment: Codable {
        var start: Double
        var end: Double
        var text: String
        var language: String
        var repair: String?
        var avgLogProb: Double
        var temperature: Double?

        init(_ segment: TranscribedSegment) {
            start = segment.start
            end = segment.end
            text = segment.text
            language = segment.language
            repair = segment.repair?.rawValue
            avgLogProb = segment.avgLogProb
            temperature = segment.temperature
        }
    }

    var label: String
    var audio: String
    var strategy: String
    var pipeline: String
    var guards: Bool
    var glossaryTerms: Int
    var tuning: String?
    var audioSeconds: Double
    /// Start of the excerpt on the file's clock, when only an excerpt was transcribed.
    var offset: Double?
    var wallSeconds: Double
    var modelLoadSeconds: Double
    var chunks: [Chunk]
    var segments: [Segment]
    var gaps: [SpeechGap]
    var loopsFound: Int?
    var loopsRemaining: Int?

    /// Moves every time by `offset` seconds (excerpt clock → file clock).
    mutating func shift(by offset: Double) {
        chunks = chunks.map { Chunk(start: $0.start + offset, end: $0.end + offset, language: $0.language) }
        segments = segments.map { segment in
            var segment = segment
            segment.start += offset
            segment.end += offset
            return segment
        }
        gaps = gaps.map { SpeechGap(start: $0.start + offset, end: $0.end + offset, speechSeconds: $0.speechSeconds, recovered: $0.recovered) }
    }
}

enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let message): "\(message)\n\n\(Bench.usage)"
        }
    }
}

/// Minimal `--flag value` parser.
struct Arguments {
    let raw: [String]
    init(_ raw: [String]) { self.raw = raw }

    func value(_ flag: String) -> String? {
        guard let index = raw.firstIndex(of: flag), raw.indices.contains(index + 1) else { return nil }
        return raw[index + 1]
    }

    /// Every value after `flag` up to the next `--flag`.
    func values(after flag: String) -> [String] {
        guard let index = raw.firstIndex(of: flag) else { return [] }
        return Array(raw[(index + 1)...].prefix { !$0.hasPrefix("--") })
    }

    func has(_ flag: String) -> Bool { raw.contains(flag) }
}

enum Console {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Prints progress lines at most every 5 % or on phase changes.
final class ProgressPrinter: Sendable {
    private let state = Mutex<(phase: Transcription.TranscriptionProgress.Phase?, bucket: Int)>((nil, -1))

    func report(_ progress: Transcription.TranscriptionProgress) {
        let bucket = Int(progress.fractionCompleted * 20)
        let shouldPrint = state.withLock { state in
            guard state.phase != progress.phase || state.bucket != bucket else { return false }
            state = (progress.phase, bucket)
            return true
        }
        if shouldPrint {
            Console.error("  \(progress.phase.rawValue) \(Int(progress.fractionCompleted * 100))%")
        }
    }
}
