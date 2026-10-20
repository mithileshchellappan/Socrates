// Evaluates the aligner on the M0 fixtures and prints Markdown tables for docs/eval/alignment-m0.md.
//
//   swift run -c release --package-path Packages/Alignment alignment-eval [--timeline] [--set name=value ...]
//
// Fixtures are located via SOCRATES_FIXTURES or by walking up from this file to `.data/fixtures`.

import Alignment
import AlignmentEvaluation
import Foundation

let arguments = CommandLine.arguments.dropFirst()
let showTimeline = arguments.contains("--timeline")

var parameters = AlignmentParameters.default
let doubleParameters: [String: WritableKeyPath<AlignmentParameters, Double>] = [
    "stepDuration": \.stepDuration,
    "idfChunkDuration": \.idfChunkDuration,
    "fullEvidenceTokens": \.fullEvidenceTokens,
    "deckStoplistFraction": \.deckStoplistFraction,
    "glossaryBoost": \.glossaryBoost,
    "offScore": \.offScore,
    "forwardCost": \.forwardCost,
    "skipCost": \.skipCost,
    "backwardCost": \.backwardCost,
    "backwardDistanceCost": \.backwardDistanceCost,
    "offEnterCost": \.offEnterCost,
    "offExitCost": \.offExitCost,
    "offEndCost": \.offEndCost,
    "stampSnapBack": \.stampSnapBack,
    "confidenceTemperature": \.confidenceTemperature
]
let intParameters: [String: WritableKeyPath<AlignmentParameters, Int>] = [
    "contextRadius": \.contextRadius,
    "deckStoplistMinimumPages": \.deckStoplistMinimumPages,
    "fuzzyMatchMinimumLength": \.fuzzyMatchMinimumLength
]
let boolParameters: [String: WritableKeyPath<AlignmentParameters, Bool>] = [
    "joinsCompounds": \.joinsCompounds,
    "matchesCompoundPrefixes": \.matchesCompoundPrefixes
]

@MainActor func apply(_ name: String, _ value: String, to parameters: inout AlignmentParameters) {
    if let path = doubleParameters[name], let number = Double(value) {
        parameters[keyPath: path] = number
    } else if let path = intParameters[name], let number = Int(value) {
        parameters[keyPath: path] = number
    } else if let path = boolParameters[name] {
        parameters[keyPath: path] = value == "true"
    } else if name == "stemming", let stemming = Tokenizer.Stemming(rawValue: value) {
        parameters.stemming = stemming
    } else {
        FileHandle.standardError.write(Data("unknown parameter \(name)=\(value)\n".utf8))
    }
}

var pendingSet = false
for argument in arguments {
    if argument == "--set" {
        pendingSet = true
        continue
    }
    guard pendingSet else { continue }
    pendingSet = false
    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    apply(parts[0], parts[1], to: &parameters)
}

func percent(_ value: Double) -> String {
    String(format: "%.1f %%", value * 100)
}

func seconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f s", $0) } ?? "–"
}

func clock(_ time: Double) -> String {
    let total = Int(time.rounded())
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func row(_ label: String, _ score: Score) -> String {
    let errors = score.boundaryErrors.map { $0.map { String(format: "%.0f", $0) } ?? "miss" }.joined(separator: ", ")
    return "| \(label) | \(percent(score.windowAccuracy)) (\(score.correctWindows)/\(score.windows)) | "
        + "\(percent(score.timeAccuracy)) | \(seconds(score.medianBoundaryError)) | "
        + "\(score.boundaries(within: 15))/\(score.boundaryErrors.count) | \(errors) |"
}

let header = """
| Run | 30 s windows correct | Time correct | Median boundary error | Boundaries ≤ 15 s | Boundary errors (s) |
|---|---|---|---|---|---|
"""

let clockTime = ContinuousClock()
let aligner = SlideAligner(parameters: parameters)

// --sweep name=v1,v2,…: compact accuracy per value (tuning aid).
if let sweepIndex = arguments.firstIndex(of: "--sweep"), sweepIndex + 1 < arguments.endIndex {
    let spec = arguments[sweepIndex + 1].split(separator: "=", maxSplits: 1).map(String.init)
    let library = FixtureLibrary.locate()
    let lectures = LectureFixture.all.compactMap { try? library?.lecture($0) }
    for value in spec[1].split(separator: ",").map(String.init) {
        var swept = parameters
        apply(spec[0], value, to: &swept)
        let sweptAligner = SlideAligner(parameters: swept)
        var line = "\(spec[0])=\(value):"
        var total = 0.0
        for lecture in lectures {
            let prepared = sweptAligner.prepare(slides: lecture.slides, transcript: lecture.transcript, duration: lecture.fixture.truth.end)
            let plain = Scorer.score(spans: prepared.align().spans, truth: lecture.fixture.truth)
            let stamped = Scorer.score(
                spans: prepared.align(anchors: lecture.fixture.truth.stamps(count: 5, delay: 2)).spans,
                truth: lecture.fixture.truth
            )
            total += plain.windowAccuracy
            line += " \(lecture.fixture.name) \(percent(plain.windowAccuracy)) med \(seconds(plain.medianBoundaryError)) ≤15s \(plain.boundaries(within: 15))"
                + " | stamped \(percent(stamped.windowAccuracy));"
        }
        let synthetic = SyntheticLecture.misaligned()
        let syntheticPrepared = sweptAligner.prepare(slides: synthetic.slides, transcript: synthetic.transcript, duration: synthetic.duration)
        let fixed = Scorer.score(
            spans: syntheticPrepared.align(anchors: synthetic.stamps(pages: SyntheticLecture.misalignedStampPages, delay: 2.5)).spans,
            truth: synthetic.truth
        )
        line += " mean \(percent(total / Double(max(1, lectures.count)))) synthetic-fixed \(percent(fixed.windowAccuracy))"
        print(line)
    }
    exit(0)
}

if let library = FixtureLibrary.locate() {
    for fixture in LectureFixture.all {
        guard let lecture = try? library.lecture(fixture) else {
            print("\(fixture.name): fixture missing\n")
            continue
        }
        print("### \(fixture.name)\n")
        print(header)
        if let prototype = lecture.prototype {
            print(row("Python prototype", Scorer.score(spans: prototype.spans, truth: fixture.truth)))
        }
        var prepared: PreparedAlignment?
        let prepareTime = clockTime.measure {
            prepared = aligner.prepare(slides: lecture.slides, transcript: lecture.transcript, duration: fixture.truth.end)
        }
        guard let prepared else { continue }
        var result = prepared.align()
        let alignTime = clockTime.measure { result = prepared.align() }
        print(row("Swift port", Scorer.score(spans: result.spans, truth: fixture.truth)))
        let stamps = fixture.truth.stamps(count: 5, delay: 2)
        var stamped = prepared.align(anchors: stamps)
        let stampedTime = clockTime.measure { stamped = prepared.align(anchors: stamps) }
        print(row("Swift port + 5 stamps (pressed 2 s late)", Scorer.score(spans: stamped.spans, truth: fixture.truth)))
        print("")
        print(String(
            format: "Prepare %.1f ms, align %.2f ms, align with 5 stamps %.2f ms; %d steps × %d slides; deck stoplist: %@\n",
            milliseconds(prepareTime), milliseconds(alignTime), milliseconds(stampedTime),
            prepared.stepCount, prepared.pages.count, prepared.deckStoplist.sorted().joined(separator: " ")
        ))
        if arguments.contains("--repairs") {
            print("Repairs: " + prepared.vocabularyRepairs.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: ", ") + "\n")
        }
        print("Stamps: " + stamps.map { "\($0.target) at \(clock($0.time))" }.joined(separator: ", ") + "\n")
        if arguments.contains("--windows") {
            print("```")
            for window in result.windows {
                let ranked = window.slideScores.indices.sorted { window.slideScores[$0] > window.slideScores[$1] }.prefix(3)
                let top = ranked.map { String(format: "%d:%.3f", result.pages[$0], window.slideScores[$0]) }.joined(separator: " ")
                let allowed = fixture.truth.allowed(at: (window.start + window.end) / 2)?
                    .map { $0.page.map(String.init) ?? "off" }.sorted().joined(separator: ",") ?? "?"
                print(String(format: "%@ ev=%.2f  %@  -> %@   truth=%@", clock(window.start), window.evidence, top, window.target.description, allowed))
            }
            print("```")
        }
        if showTimeline {
            print("Timeline (port):\n")
            print("| Target | Start | End | Confidence |")
            print("|---|---|---|---|")
            for span in result.spans {
                print("| \(span.target) | \(clock(span.start)) | \(clock(span.end)) | \(String(format: "%.2f", span.confidence)) |")
            }
            print("")
        }
    }
} else {
    print("Fixtures not found (set SOCRATES_FIXTURES).\n")
}

// Synthetic: five stamps fix a deliberately misaligned run.
let synthetic = SyntheticLecture.misaligned()
let syntheticPrepared = aligner.prepare(slides: synthetic.slides, transcript: synthetic.transcript, duration: synthetic.duration)
let unanchored = syntheticPrepared.align()
let syntheticStamps = synthetic.stamps(pages: SyntheticLecture.misalignedStampPages, delay: 2.5)
let anchored = syntheticPrepared.align(anchors: syntheticStamps)
print("### Synthetic: five stamps fix a misaligned run\n")
print(header)
print(row("No stamps", Scorer.score(spans: unanchored.spans, truth: synthetic.truth)))
print(row("5 stamps (pressed 2.5 s late)", Scorer.score(spans: anchored.spans, truth: synthetic.truth)))
print("")
if showTimeline {
    print("No stamps: " + unanchored.spans.map { "\($0.target) \(clock($0.start))" }.joined(separator: ", ") + "\n")
    print("5 stamps: " + anchored.spans.map { "\($0.target) \(clock($0.start))" }.joined(separator: ", ") + "\n")
}

// Performance: a 90-minute, 88-slide lecture.
let long = SyntheticLecture(slideCount: 88, secondsPerSlide: 60)
var longPrepared: PreparedAlignment?
let longPrepare = clockTime.measure {
    longPrepared = aligner.prepare(slides: long.slides, transcript: long.transcript, duration: long.duration)
}
if let longPrepared {
    let anchors = long.stamps(pages: Array(stride(from: 2, through: 88, by: 5)), delay: 2)
    var worst = Duration.zero
    var total = Duration.zero
    let runs = 20
    for _ in 0..<runs {
        let elapsed = clockTime.measure { _ = longPrepared.align(anchors: anchors) }
        worst = max(worst, elapsed)
        total += elapsed
    }
    print("### Performance (\(Int(long.duration / 60)) min, 88 slides, \(anchors.count) stamps)\n")
    print(String(
        format: "Prepare %.1f ms; re-align with anchors: mean %.2f ms, worst %.2f ms over %d runs.\n",
        milliseconds(longPrepare), milliseconds(total) / Double(runs), milliseconds(worst), runs
    ))
}
