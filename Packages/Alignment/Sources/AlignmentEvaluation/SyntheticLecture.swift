import Alignment

/// Deterministic generated lectures for tests that must run without fixtures.
///
/// Each slide gets its own pseudo-word vocabulary plus a shared footer; the transcript is one 4 s line
/// after another, mixing filler with words from the slide being discussed. `spokenVocabulary` lets a
/// slide's speech use another slide's words, which misleads the automatic aligner on purpose.
public struct SyntheticLecture: Sendable {
    public var slides: [SlideText]
    public var transcript: [TranscriptLine]
    public var truth: GroundTruth
    /// True start time of each page.
    public var starts: [Int: Double]
    public var duration: Double

    public init(
        slideCount: Int,
        secondsPerSlide: Double = 60,
        firstPage: Int = 1,
        spokenVocabulary: [Int: Int] = [:],
        seed: UInt64 = 7
    ) {
        var random = SplitMix64(seed: seed)
        let filler = ["system", "example", "people", "question", "point", "case", "problem", "idea", "part",
                      "approach", "result", "student", "number", "level", "detail", "model", "view", "side"]
        let glue = ["so", "and", "the", "we", "have", "here", "this", "is", "of", "that", "you", "can", "see", "now"]

        var vocabulary: [[String]] = []
        var used: Set<String> = []
        for _ in 0..<slideCount {
            var words: [String] = []
            while words.count < 10 {
                let word = random.pseudoWord()
                if used.insert(word).inserted { words.append(word) }
            }
            vocabulary.append(words)
        }

        slides = (0..<slideCount).map { index in
            let words = vocabulary[index]
            let title = words[0..<2].joined(separator: " ").capitalized
            let body = words[2...].map { "• \($0)" }.joined(separator: "\n")
            return SlideText(page: index + 1, text: "\(title)\n\(body)\nSynthetic Course by Jane Doe | Page \(index + 1)")
        }

        var lines: [TranscriptLine] = []
        var segments: [GroundTruth.Segment] = []
        var boundaries: [GroundTruth.Boundary] = []
        var starts: [Int: Double] = [:]
        let lineDuration = 4.0
        var clock = 0.0
        for index in (firstPage - 1)..<slideCount {
            let page = index + 1
            let spoken = vocabulary[(spokenVocabulary[page] ?? page) - 1]
            let start = clock
            starts[page] = start
            let lineCount = max(1, Int(secondsPerSlide / lineDuration))
            for lineIndex in 0..<lineCount {
                var words: [String] = []
                for position in 0..<10 {
                    switch position {
                    case 2, 6, 8: words.append(spoken[random.next(below: spoken.count)])
                    case 4: words.append(filler[random.next(below: filler.count)])
                    default: words.append(glue[random.next(below: glue.count)])
                    }
                }
                let ending = lineIndex == lineCount - 1 || lineIndex % 3 == 2 ? "." : ","
                lines.append(TranscriptLine(
                    start: clock,
                    end: clock + lineDuration,
                    text: words.joined(separator: " ").capitalizedFirst + ending
                ))
                clock += lineDuration
            }
            segments.append(GroundTruth.Segment(start: start, end: clock, allowed: [.slide(page)]))
            if index > firstPage - 1 {
                boundaries.append(GroundTruth.Boundary(time: start, targets: [.slide(page)], approximate: false))
            }
        }
        transcript = lines
        duration = clock
        self.starts = starts
        truth = GroundTruth(segments: segments, boundaries: boundaries, end: clock)
    }

    /// The scenario of the "five stamps fix a misaligned run" check: 16 one-minute slides; while slides 4–7
    /// are on screen the lecturer previews slides 8–11 (their words, not the current slide's), so the
    /// unanchored aligner runs ahead. Stamps at the starts of slides 4–8 bound every misleading stretch.
    public static func misaligned() -> SyntheticLecture {
        SyntheticLecture(slideCount: 16, spokenVocabulary: [4: 8, 5: 9, 6: 10, 7: 11])
    }

    /// Pages stamped in the "five stamps" check.
    public static let misalignedStampPages = [4, 5, 6, 7, 8]

    /// Stamps at the true starts of `pages`, pressed `delay` seconds late.
    public func stamps(pages: [Int], delay: Double) -> [AlignmentAnchor] {
        pages.compactMap { page in starts[page].map { AlignmentAnchor.stamp(page, at: $0 + delay) } }
    }
}

/// SplitMix64: tiny, deterministic, good enough for fixtures.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func pseudoWord() -> String {
        let consonants = Array("bdfgklmnprstvz")
        let vowels = Array("aeiou")
        var word = ""
        for _ in 0..<3 {
            word.append(consonants[next(below: consonants.count)])
            word.append(vowels[next(below: vowels.count)])
        }
        return word
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    var capitalized: String {
        split(separator: " ").map { String($0).capitalizedFirst }.joined(separator: " ")
    }
}
