import Foundation

/// Aligns a lecture transcript to its slide deck.
///
/// ```swift
/// let prepared = SlideAligner().prepare(slides: pages, transcript: lines, duration: recording.duration)
/// let result = prepared.align(anchors: stamps.map { .stamp($0.page, at: $0.time) })
/// // later, after the user drops a "slide starts here" marker:
/// let updated = prepared.align(anchors: stamps + [.manual(.slide(17), at: 263.4)])
/// ```
public struct SlideAligner: Sendable {
    public var parameters: AlignmentParameters

    public init(parameters: AlignmentParameters = .default) {
        self.parameters = parameters
    }

    /// Tokenizes, builds TF-IDF vectors and scores every window against every slide. O(transcript + steps × slides).
    ///
    /// - Parameters:
    ///   - slides: deck pages in deck order (page numbers must be unique).
    ///   - transcript: transcript lines on the recording clock.
    ///   - duration: recording length; defaults to the end of the last transcript line.
    ///   - glossary: course terms to weigh up.
    public func prepare(
        slides: [SlideText],
        transcript: [TranscriptLine],
        duration: Double? = nil,
        glossary: Glossary = .empty
    ) -> PreparedAlignment {
        let lastSpeech = transcript.map(\.end).max() ?? 0
        let total = max(duration ?? lastSpeech, parameters.stepDuration)
        let stepCount = max(1, Int((total / parameters.stepDuration).rounded(.up)))
        let evidence = Evidence(
            slides: slides,
            transcript: transcript,
            stepCount: stepCount,
            glossary: glossary,
            parameters: parameters
        )
        return PreparedAlignment(
            parameters: parameters,
            pages: slides.map(\.page),
            duration: total,
            evidence: evidence,
            boundaries: BoundaryCandidates(transcript: transcript, parameters: parameters)
        )
    }

    /// One-shot convenience: prepare and align.
    public func align(
        slides: [SlideText],
        transcript: [TranscriptLine],
        anchors: [AlignmentAnchor] = [],
        duration: Double? = nil,
        glossary: Glossary = .empty
    ) -> AlignmentResult {
        prepare(slides: slides, transcript: transcript, duration: duration, glossary: glossary).align(anchors: anchors)
    }
}

/// A lecture ready for (re-)alignment. Immutable and `Sendable`; ``align(anchors:)`` is a pure function
/// that runs in a few milliseconds for a 90-minute lecture.
public struct PreparedAlignment: Sendable {
    public let parameters: AlignmentParameters
    public let pages: [Int]
    public let duration: Double
    let evidence: Evidence
    public let boundaries: BoundaryCandidates
    /// Decoder emissions (similarity × evidence), row-major `stepCount × slides`, and OFF's per step.
    let emissions: [Float]
    let offEmissions: [Float]
    /// Running sums of `emissions` over steps (`(stepCount + 1) × slides`) for O(slides) span confidence.
    let cumulativeEmissions: [Double]
    let cumulativeOffEmissions: [Double]

    init(parameters: AlignmentParameters, pages: [Int], duration: Double, evidence: Evidence, boundaries: BoundaryCandidates) {
        self.parameters = parameters
        self.pages = pages
        self.duration = duration
        self.evidence = evidence
        self.boundaries = boundaries

        let slideCount = pages.count
        let stepCount = evidence.stepCount
        let offScore = Float(parameters.offScore)
        var emissions = [Float](repeating: 0, count: stepCount * slideCount)
        var offEmissions = [Float](repeating: 0, count: stepCount)
        var cumulative = [Double](repeating: 0, count: (stepCount + 1) * slideCount)
        var cumulativeOff = [Double](repeating: 0, count: stepCount + 1)
        var step = 0
        while step < stepCount {
            let weight = evidence.evidence[step]
            offEmissions[step] = offScore * weight
            cumulativeOff[step + 1] = cumulativeOff[step] + Double(offEmissions[step])
            let row = step * slideCount
            var slide = 0
            while slide < slideCount {
                let value = evidence.similarity[row + slide] * weight
                emissions[row + slide] = value
                cumulative[row + slideCount + slide] = cumulative[row + slide] + Double(value)
                slide += 1
            }
            step += 1
        }
        self.emissions = emissions
        self.offEmissions = offEmissions
        cumulativeEmissions = cumulative
        cumulativeOffEmissions = cumulativeOff
    }

    public var stepCount: Int { evidence.stepCount }

    /// Terms dropped as deck boilerplate (footer, course title, lecturer names).
    public var deckStoplist: Set<String> { evidence.deckStoplist }

    /// Transcript words mapped onto slide words (one edit away, compound prefix, or two words joined).
    public var vocabularyRepairs: [String: String] { evidence.repairs }

    /// Where a stamp pressed at `time` is moved to: the nearest sentence start (else pause/line start)
    /// within ``AlignmentParameters/stampSnapBack`` seconds before it.
    public func snappedStampTime(_ time: Double) -> Double {
        boundaries.best(
            near: time,
            back: parameters.stampSnapBack,
            forward: parameters.stampSnapForward,
            preferEarlier: false
        )?.time ?? time
    }

    /// Resolves anchors (snap stamps, drop unknown pages, one anchor per step, drop repeats) and decodes.
    public func align(anchors: [AlignmentAnchor] = []) -> AlignmentResult {
        let resolved = resolve(anchors)
        var constraints: [Int: Decoder.Constraint] = [:]
        let slideIndex = Dictionary(pages.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for anchor in resolved {
            switch anchor.anchor.target {
            case .slide(let page):
                if let index = slideIndex[page] { constraints[anchor.step] = .slide(index) }
            case .off:
                constraints[anchor.step] = .off
            }
        }

        let slideCount = pages.count
        let decoder = Decoder(
            slideCount: slideCount,
            stepCount: evidence.stepCount,
            emissions: emissions,
            offEmissions: offEmissions,
            costs: Decoder.Costs(
                forward: Float(parameters.forwardCost),
                skip: Float(parameters.skipCost),
                backward: Float(parameters.backwardCost),
                backwardDistance: Float(parameters.backwardDistanceCost),
                offEnter: Float(parameters.offEnterCost),
                offExit: Float(parameters.offExitCost),
                offEnd: Float(parameters.offEndCost)
            )
        )
        let path = decoder.decode(constraints: constraints, bounds: bounds(for: resolved, slideIndex: slideIndex))
        let targets = path.map { $0 < slideCount ? AlignmentTarget.slide(pages[$0]) : .off }

        let spans = makeSpans(path: path, targets: targets, anchors: resolved)
        let windows = WindowTable(
            stepDuration: parameters.stepDuration,
            duration: duration,
            slideCount: slideCount,
            similarity: evidence.similarity,
            offScores: offEmissions,
            evidence: evidence.evidence,
            targets: targets
        )
        return AlignmentResult(pages: pages, spans: spans, windows: windows, anchors: resolved, duration: duration)
    }

    // MARK: - Anchors

    /// Slide ranges implied by the anchors. Between a slide anchor `p` and the next slide anchor `q`, the
    /// lecture stays within `p…q−1` when `q > p` (missed stamps are filled in order) or at `p` and beyond when
    /// it went back; before the first slide anchor only slides before it, after the last only it and later.
    /// OFF is allowed everywhere; OFF anchors do not change the ranges.
    func bounds(for anchors: [ResolvedAnchor], slideIndex: [Int: Int]) -> Decoder.Bounds {
        let slideCount = pages.count
        var bounds = Decoder.Bounds.unconstrained(stepCount: evidence.stepCount, slideCount: slideCount)
        let slideAnchors: [(step: Int, index: Int)] = anchors.compactMap { anchor in
            guard let page = anchor.anchor.target.page, let index = slideIndex[page] else { return nil }
            return (anchor.step, index)
        }
        guard let first = slideAnchors.first else { return bounds }
        for step in 0..<first.step { bounds.upper[step] = Int32(first.index - 1) }
        for (position, anchor) in slideAnchors.enumerated() {
            let end = position + 1 < slideAnchors.count ? slideAnchors[position + 1].step : evidence.stepCount
            let next = position + 1 < slideAnchors.count ? slideAnchors[position + 1].index : nil
            let upper = next.map { $0 > anchor.index ? $0 - 1 : slideCount - 1 } ?? slideCount - 1
            for step in anchor.step..<end {
                bounds.lower[step] = Int32(anchor.index)
                bounds.upper[step] = Int32(upper)
            }
        }
        return bounds
    }

    func step(for time: Double) -> Int {
        min(evidence.stepCount - 1, max(0, Int(time / parameters.stepDuration)))
    }

    func resolve(_ anchors: [AlignmentAnchor]) -> [ResolvedAnchor] {
        let known = Set(pages)
        var byStep: [Int: ResolvedAnchor] = [:]
        for anchor in anchors {
            if case .slide(let page) = anchor.target, !known.contains(page) {
                alignmentLog.debug("Ignoring anchor for unknown page \(page)")
                continue
            }
            guard anchor.time.isFinite else { continue }
            var time = anchor.kind == .stamp ? snappedStampTime(anchor.time) : anchor.time
            time = min(max(0, time), max(0, duration - 0.001))
            let resolved = ResolvedAnchor(anchor: anchor, time: time, step: step(for: time))
            if let existing = byStep[resolved.step] {
                // Manual beats stamp; otherwise the later one wins.
                let keepExisting = existing.anchor.kind == .manual && anchor.kind == .stamp
                    || (existing.anchor.kind == anchor.kind && existing.anchor.time > anchor.time)
                if keepExisting { continue }
            }
            byStep[resolved.step] = resolved
        }
        var ordered = byStep.values.sorted { $0.step < $1.step }
        // A repeat of the previous anchor's target is not a change.
        var index = 1
        while index < ordered.count {
            if ordered[index].anchor.target == ordered[index - 1].anchor.target {
                ordered.remove(at: index)
            } else {
                index += 1
            }
        }
        return ordered
    }

    // MARK: - Spans

    private func makeSpans(path: [Int], targets: [AlignmentTarget], anchors: [ResolvedAnchor]) -> [AlignedSpan] {
        guard !path.isEmpty else { return [] }
        let anchorByStep = Dictionary(anchors.map { ($0.step, $0) }, uniquingKeysWith: { first, _ in first })

        // Runs of equal targets.
        var runs: [(target: AlignmentTarget, first: Int, end: Int)] = []
        var runStart = 0
        for step in 1...path.count where step == path.count || targets[step] != targets[runStart] {
            runs.append((targets[runStart], runStart, step))
            runStart = step
        }

        // Boundary times: anchors exactly; otherwise re-split locally and moved onto a speech onset.
        var starts: [Double] = []
        var fixed: [Bool] = []
        var origins: [SpanOrigin] = []
        for (index, run) in runs.enumerated() {
            let nominal = Double(run.first) * parameters.stepDuration
            if let anchor = anchorByStep[run.first], anchor.anchor.target == run.target {
                origins.append(anchor.anchor.kind == .manual ? .manual : .stamp)
                starts.append(index == 0 ? 0 : anchor.time)
                fixed.append(true)
                continue
            }
            origins.append(.automatic)
            fixed.append(index == 0)
            guard index > 0 else {
                starts.append(0)
                continue
            }
            let radius = Double(max(1, parameters.contextRadius)) * parameters.stepDuration
            starts.append(refineBoundary(
                from: runs[index - 1].target,
                to: run.target,
                nominal: nominal,
                low: max(nominal - radius, Double(runs[index - 1].first) * parameters.stepDuration),
                high: min(nominal + radius, Double(run.end) * parameters.stepDuration)
            ))
        }
        // Refined boundaries must stay strictly between their neighbours (anchored ones never move).
        let gap = 0.01
        for index in starts.indices where !fixed[index] {
            let floor = starts[index - 1] + gap
            let ceiling = (index + 1 < starts.count ? starts[index + 1] : duration) - gap
            if starts[index] < floor || starts[index] > ceiling {
                let nominal = Double(runs[index].first) * parameters.stepDuration
                starts[index] = ceiling > floor ? min(max(nominal, floor), ceiling) : (floor + ceiling) / 2
            }
        }

        var spans: [AlignedSpan] = []
        for (index, run) in runs.enumerated() {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : duration
            let confidence: Double = origins[index] == .automatic
                ? spanConfidence(target: run.target, steps: run.first..<run.end)
                : 1
            spans.append(AlignedSpan(target: run.target, start: start, end: end, confidence: confidence, origin: origins[index]))
        }
        return spans
    }

    /// Places a decoded boundary precisely. The decoder works on ±`contextRadius` windows, which blur a
    /// change over that radius (and bias slide↔OFF changes towards the slide, because OFF's score is low).
    /// Within that radius, pick the speech onset that best splits the per-step (context-free) scores of
    /// the two targets; sentence starts get a small bonus.
    private func refineBoundary(from left: AlignmentTarget, to right: AlignmentTarget, nominal: Double, low: Double, high: Double) -> Double {
        let step = parameters.stepDuration
        let slideCount = pages.count
        let offScore = Float(parameters.offScore)
        let leftIndex = left.page.flatMap { pages.firstIndex(of: $0) }
        let rightIndex = right.page.flatMap { pages.firstIndex(of: $0) }
        let firstStep = max(0, Int(low / step))
        let lastStep = min(evidence.stepCount - 1, Int(high / step))
        guard firstStep <= lastStep, high > low else { return nominal }

        func stepScore(_ index: Int?, _ k: Int) -> Double {
            let weight = evidence.stepEvidence[k]
            guard let index else { return Double(offScore * weight) }
            return Double(evidence.stepSimilarity[k * slideCount + index] * weight)
        }

        /// Left target before `time`, right target after it, over `[low, high)`.
        func splitScore(_ time: Double) -> Double {
            var total = 0.0
            for k in firstStep...lastStep {
                let begin = max(low, Double(k) * step)
                let end = min(high, Double(k + 1) * step)
                guard end > begin else { continue }
                let leftPart = max(0, min(end, time) - begin)
                let rightPart = max(0, end - max(begin, time))
                total += (leftPart * stepScore(leftIndex, k) + rightPart * stepScore(rightIndex, k)) / step
            }
            return total
        }

        let sentenceBonus = 0.05
        var best = nominal
        var bestScore = splitScore(nominal) - 0.01
        var index = boundaries.firstIndex(atOrAfter: low)
        while index < boundaries.candidates.count, boundaries.candidates[index].time <= high {
            let candidate = boundaries.candidates[index]
            let score = splitScore(candidate.time) + (candidate.isSentenceStart ? sentenceBonus : 0)
            if score > bestScore || (score == bestScore && abs(candidate.time - nominal) < abs(best - nominal)) {
                best = candidate.time
                bestScore = score
            }
            index += 1
        }
        return best
    }

    /// Logistic of (mean emission of the chosen target − best alternative's mean) over the span.
    /// Slides with identical text do not count as alternatives to each other.
    private func spanConfidence(target: AlignmentTarget, steps: Range<Int>) -> Double {
        let slideCount = pages.count
        guard !steps.isEmpty else { return 0.5 }
        let count = Double(steps.count)
        let first = steps.lowerBound * slideCount
        let last = steps.upperBound * slideCount
        func mean(_ slide: Int) -> Double {
            (cumulativeEmissions[last + slide] - cumulativeEmissions[first + slide]) / count
        }
        let offMean = (cumulativeOffEmissions[steps.upperBound] - cumulativeOffEmissions[steps.lowerBound]) / count
        let chosenIndex = target.page.flatMap { page in pages.firstIndex(of: page) }
        let chosen = chosenIndex.map(mean) ?? offMean
        var alternative = chosenIndex == nil ? 0 : offMean
        var slide = 0
        while slide < slideCount {
            if chosenIndex.map({ evidence.duplicateGroup[slide] != evidence.duplicateGroup[$0] }) ?? true {
                alternative = max(alternative, mean(slide))
            }
            slide += 1
        }
        let margin = (chosen - alternative) / parameters.confidenceTemperature
        return 1 / (1 + exp(-margin))
    }
}
