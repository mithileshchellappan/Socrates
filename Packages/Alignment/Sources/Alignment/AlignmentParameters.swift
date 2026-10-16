/// Tunables. Defaults were fitted on the M0 fixtures (see docs/eval/alignment-m0.md); scores are
/// TF-IDF cosines summed per decoder step, so costs are in "cosine × steps".
public struct AlignmentParameters: Hashable, Sendable {
    // MARK: Windows
    /// Decoder resolution in seconds. Span boundaries are re-placed on speech onsets afterwards.
    public var stepDuration: Double = 5
    /// Steps on each side whose words also count for a step (triangular weights). 3 → ~35 s context.
    public var contextRadius: Int = 3
    /// Length of the non-overlapping transcript chunks used as IDF documents (the prototype's window).
    public var idfChunkDuration: Double = 30
    /// Weighted content-token count at which a window is fully trusted; fewer tokens scale its emissions down.
    public var fullEvidenceTokens: Double = 8

    // MARK: Vocabulary
    /// Porter on English words; `.plurals` or `.none` for experiments.
    public var stemming: Tokenizer.Stemming = .porter
    /// Map a transcript word that is on no slide to the longest slide word (≥ 6 letters) it starts with,
    /// when at least 3 letters remain ("healthcare" → "health", "serverless" → "server").
    public var matchesCompoundPrefixes: Bool = true
    /// Terms on at least this fraction of non-empty pages are deck boilerplate (footers, course name, author).
    public var deckStoplistFraction: Double = 0.5
    /// …and on at least this many pages.
    public var deckStoplistMinimumPages: Int = 3
    /// IDF multiplier for course glossary terms.
    public var glossaryBoost: Double = 2
    /// Map transcript words that are on no slide to a glossary term one edit away after the first two letters
    /// (ASR misspellings such as "elisa" → "eliza"); only words of at least this many letters. 0 disables.
    public var fuzzyMatchMinimumLength: Int = 5
    /// Join adjacent transcript words (≥ 3 letters each) when the joined form is a slide word ("para virtualization").
    public var joinsCompounds: Bool = true

    // MARK: Decoder
    /// Emission of the OFF state per fully-evidenced step (slides compete with their cosine). The most
    /// sensitive parameter: 0.055–0.07 on the fixtures.
    public var offScore: Double = 0.06
    /// Cost of moving to the next slide.
    public var forwardCost: Double = 0.2
    /// Extra cost per slide skipped when jumping ahead.
    public var skipCost: Double = 0.1
    /// Cost of going back one slide…
    public var backwardCost: Double = 1.2
    /// …plus this per additional slide of distance.
    public var backwardDistanceCost: Double = 0.4
    /// Cost of leaving the slides for OFF mid-lecture (Q&A, demo). High: talk about a text-poor slide looks
    /// just as "off" lexically, so only long off-topic stretches should win.
    public var offEnterCost: Double = 2.5
    /// Cost of returning from OFF (mid-lecture or at the start) to a slide.
    public var offExitCost: Double = 0.3
    /// Cost of leaving the slides for good (talk after the lecture until the recording ends).
    public var offEndCost: Double = 0.6

    // MARK: Anchors and boundaries
    /// Stamps are snapped back to a pause or sentence start at most this many seconds earlier.
    public var stampSnapBack: Double = 5
    /// …or this many seconds later (clock jitter).
    public var stampSnapForward: Double = 0.3
    /// Silence between words that counts as a pause.
    public var minimumPause: Double = 0.3
    /// A pause at least this long counts as a sentence start even without punctuation.
    public var sentencePause: Double = 0.7

    // MARK: Confidence
    /// Logistic temperature for automatic span confidence (margin over the best alternative).
    public var confidenceTemperature: Double = 0.03

    public init() {}

    public static let `default` = AlignmentParameters()
}
