/// Constrained Viterbi over slides plus OFF.
///
/// States:
/// - `on(i)` for each slide i,
/// - `off(i)`: off the slides mid-lecture after slide i (Q&A, demo), so the lecture resumes near i,
/// - `offStart`: off before any slide (admin talk while the recording starts),
/// - `offEnd`: off for the rest of the recording (chatter after the lecture).
///
/// Free start (any slide or `offStart`) and free end (any state).
///
/// Transitions (costs subtract from the score):
/// - stay: 0
/// - on(i) → on(j), j > i: `forward + skip·(j−i−1)`
/// - on(i) → on(j), j < i: `backward + backwardDistance·(i−j−1)`
/// - on(i) → off(i): `offEnter`; off(i) → on(j): `offExit` + the jump cost from i (0 for j = i)
/// - offStart → on(j): `offExit`
/// - on(i) → offEnd: `offEnd`
///
/// Both jump costs are linear in distance, so the best predecessor of every `on(j)` comes from two running
/// maxima: one ascending and one descending pass per step, O(steps × slides) overall.
///
/// Ties resolve towards the *later* change (staying on the current slide through stretches without
/// evidence, entering OFF as late as possible), which matches how lecturers introduce a slide's content
/// right after switching to it.
///
/// Anchors add two kinds of hard constraints: the anchored step must *enter* its target (``Constraint``),
/// and every step carries an allowed slide range (``Bounds``) derived from the surrounding anchors.
///
/// The loops use `while` and raw pointers on purpose: the app's Debug builds compile packages without
/// optimization, and this keeps a 90-minute re-alignment well under 100 ms there too.
struct Decoder: Sendable {
    /// Allowed slide indices per step (`lower...upper`, empty when `upper < lower`), applied to both
    /// `on(i)` and `off(i)`.
    struct Bounds: Sendable {
        var lower: [Int32]
        var upper: [Int32]

        static func unconstrained(stepCount: Int, slideCount: Int) -> Bounds {
            Bounds(
                lower: [Int32](repeating: 0, count: stepCount),
                upper: [Int32](repeating: Int32(slideCount - 1), count: stepCount)
            )
        }
    }

    enum Constraint: Hashable, Sendable {
        /// The state at this step must be `on(slide)`, entered at this step.
        case slide(Int)
        /// The state at this step must be an OFF state: entered at this step from a slide, or
        /// `offStart` when no slide came before (the lecture has not started yet).
        case off
    }

    struct Costs: Sendable {
        var forward: Float
        var skip: Float
        var backward: Float
        var backwardDistance: Float
        var offEnter: Float
        var offExit: Float
        var offEnd: Float
    }

    let slideCount: Int
    let stepCount: Int
    /// Row-major `stepCount × slideCount`.
    let emissions: [Float]
    let offEmissions: [Float]
    let costs: Costs

    var stateCount: Int { 2 * slideCount + 2 }
    var offStartState: Int { 2 * slideCount }
    var offEndState: Int { 2 * slideCount + 1 }

    /// Best state per step, or nil when the constraints and bounds leave no path at all.
    func decode(constraints: [Int: Constraint], bounds: Bounds) -> [Int]? {
        let slides = slideCount
        let states = stateCount
        let offStart = offStartState
        guard stepCount > 0, slides > 0 else { return [Int](repeating: offStart, count: stepCount) }

        var previous = [Float](repeating: -.infinity, count: states)
        var current = [Float](repeating: -.infinity, count: states)
        var reach = [Float](repeating: -.infinity, count: slides)
        var reachSource = [Int32](repeating: 0, count: slides)
        var back = [Int32](repeating: -1, count: stepCount * states)

        // Step 0: free start on any slide, or off at start.
        for slide in 0..<slides { previous[slide] = emissions[slide] }
        previous[offStart] = offEmissions[0]
        switch constraints[0] {
        case .slide(let slide)?:
            for state in 0..<states where state != slide { previous[state] = -.infinity }
        case .off?:
            for state in 0..<states where state != offStart { previous[state] = -.infinity }
        case nil:
            break
        }
        for slide in 0..<slides where slide < bounds.lower[0] || slide > bounds.upper[0] {
            previous[slide] = -.infinity
            previous[slides + slide] = -.infinity
        }

        emissions.withUnsafeBufferPointer { emissionBuffer in
        offEmissions.withUnsafeBufferPointer { offEmissionBuffer in
        back.withUnsafeMutableBufferPointer { backBuffer in
        reach.withUnsafeMutableBufferPointer { reachBuffer in
        reachSource.withUnsafeMutableBufferPointer { reachSourceBuffer in
        bounds.lower.withUnsafeBufferPointer { lowerBuffer in
        bounds.upper.withUnsafeBufferPointer { upperBuffer in
            guard let emission = emissionBuffer.baseAddress, let offEmission = offEmissionBuffer.baseAddress,
                  let backPointers = backBuffer.baseAddress, let u = reachBuffer.baseAddress,
                  let uSource = reachSourceBuffer.baseAddress, let lowers = lowerBuffer.baseAddress,
                  let uppers = upperBuffer.baseAddress else { return }
            var step = 1
            while step < stepCount {
                previous.withUnsafeBufferPointer { previousBuffer in
                current.withUnsafeMutableBufferPointer { currentBuffer in
                    guard let p = previousBuffer.baseAddress, let c = currentBuffer.baseAddress else { return }
                    advance(
                        step: step,
                        constraint: constraints[step],
                        p: p, c: c, u: u, uSource: uSource,
                        emission: emission + step * slides,
                        offScore: offEmission[step],
                        back: backPointers + step * states,
                        lower: Int(lowers[step]),
                        upper: Int(uppers[step])
                    )
                }
                }
                swap(&previous, &current)
                step += 1
            }
        }
        }
        }
        }
        }
        }
        }

        // Free end; with no evidence at all (exact ties) the recording is OFF rather than slide 1.
        var state = offStart
        for candidate in 0..<states where previous[candidate] > previous[state] { state = candidate }
        guard previous[state] > -.infinity else { return nil }
        var path = [Int](repeating: offStart, count: stepCount)
        var step = stepCount - 1
        while step >= 0 {
            path[step] = state
            if step > 0 {
                let source = Int(back[step * states + state])
                state = source >= 0 ? source : state
            }
            step -= 1
        }
        return path
    }

    /// One Viterbi step: `p` = previous scores, `c` = current scores, `back` = this step's back pointers.
    @inline(__always)
    private func advance(
        step: Int,
        constraint: Constraint?,
        p: UnsafePointer<Float>,
        c: UnsafeMutablePointer<Float>,
        u: UnsafeMutablePointer<Float>,
        uSource: UnsafeMutablePointer<Int32>,
        emission: UnsafePointer<Float>,
        offScore: Float,
        back: UnsafeMutablePointer<Int32>,
        lower: Int,
        upper: Int
    ) {
        let slides = slideCount
        let offStart = offStartState
        let offEnd = offEndState
        let impossible = -Float.infinity
        let forward = costs.forward
        let skip = costs.skip
        let backward = costs.backward
        let distance = costs.backwardDistance
        let enter = costs.offEnter
        let exit = costs.offExit
        var enteredSlide = -1
        if case .slide(let target)? = constraint { enteredSlide = target }

        // Ascending pass: stay, return from off(j), forward jump, start; ties prefer the later change.
        let fromStart = p[offStart] - exit
        var forwardBest = impossible
        var forwardSource: Int32 = 0
        var bestOn = impossible
        var bestOnSource: Int32 = 0
        var slide = 0
        while slide < slides {
            let on = p[slide]
            let returning = p[slides + slide] - exit
            var best = impossible
            var source: Int32 = -1
            if slide != enteredSlide {
                best = on
                source = Int32(slide)
            }
            if returning >= best, returning > impossible {
                best = returning
                source = Int32(slides + slide)
            }
            let jump = forwardBest - forward - skip * Float(slide - 1)
            if jump >= best, jump > impossible {
                best = jump
                source = forwardSource
            }
            if fromStart >= best, fromStart > impossible {
                best = fromStart
                source = Int32(offStart)
            }
            c[slide] = best
            back[slide] = source

            // Best way to "be at this slide" for jumping elsewhere: on(i), or returning from off(i).
            if on >= returning {
                u[slide] = on
                uSource[slide] = Int32(slide)
            } else {
                u[slide] = returning
                uSource[slide] = Int32(slides + slide)
            }
            let candidate = u[slide] + skip * Float(slide)
            if candidate > forwardBest {
                forwardBest = candidate
                forwardSource = uSource[slide]
            }
            if on > bestOn {
                bestOn = on
                bestOnSource = Int32(slide)
            }
            slide += 1
        }

        // Descending pass: backward jumps (only when strictly better), emissions, off(j).
        var backwardBest = impossible
        var backwardSource: Int32 = 0
        slide = slides - 1
        while slide >= 0 {
            let jump = backwardBest - backward + distance * Float(slide + 1)
            if jump > c[slide] {
                c[slide] = jump
                back[slide] = backwardSource
            }
            let candidate = u[slide] - distance * Float(slide)
            if candidate > backwardBest {
                backwardBest = candidate
                backwardSource = uSource[slide]
            }
            c[slide] += emission[slide]

            let offState = slides + slide
            let stay = p[offState]
            let enters = p[slide] - enter
            if enters >= stay, enters > impossible {
                c[offState] = enters + offScore
                back[offState] = Int32(slide)
            } else {
                c[offState] = stay + offScore
                back[offState] = Int32(offState)
            }
            slide -= 1
        }

        c[offStart] = p[offStart] + offScore
        back[offStart] = Int32(offStart)
        let endEnters = bestOn - costs.offEnd
        if endEnters >= p[offEnd], endEnters > impossible {
            c[offEnd] = endEnters + offScore
            back[offEnd] = bestOnSource
        } else {
            c[offEnd] = p[offEnd] + offScore
            back[offEnd] = Int32(offEnd)
        }

        switch constraint {
        case .slide(let target)?:
            var state = 0
            while state < stateCount {
                if state != target { c[state] = impossible }
                state += 1
            }
        case .off?:
            // Must enter OFF here (from a slide), not stay in it; before any slide, staying in
            // `offStart` (computed above) is that OFF. Forbidding it made an OFF anchor ahead of a
            // first-page slide anchor infeasible, and one ahead of a later page forced a slide in.
            slide = 0
            while slide < slides {
                c[slide] = impossible
                c[slides + slide] = p[slide] - enter + offScore
                back[slides + slide] = Int32(slide)
                slide += 1
            }
            c[offEnd] = bestOn - costs.offEnd + offScore
            back[offEnd] = bestOnSource
        case nil:
            break
        }

        if lower > 0 || upper < slides - 1 {
            slide = 0
            while slide < slides {
                if slide < lower || slide > upper {
                    c[slide] = impossible
                    c[slides + slide] = impossible
                }
                slide += 1
            }
        }
    }
}
