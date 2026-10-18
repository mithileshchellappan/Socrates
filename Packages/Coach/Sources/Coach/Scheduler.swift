import Foundation
import StudyCore

/// The spaced-repetition scheduler (plan §4 "Scheduler"): FSRS-5 with its default weights and
/// `CoachRules.desiredRetention` (90 %). One card per question; the card is computed by replaying
/// the question's graded answers in order (so an override, or a grade that arrives late, gives the
/// same card as if it had been there from the start).
///
/// - wrong → Again (1), partial → Hard (2), right → Good (3); a pending answer does not count yet.
/// - A new or missed question stays `learning` / `relearning` until answered right once; the
///   round asks it again (successive relearning, `CoachEngine.answer` appends it).
/// - Same-day reviews use FSRS-5's short-term stability.
/// - The interval never passes the exam the student sits; in the runway at most 30 % of the days
///   left; in the final week at most 3 days (`Limits.cap`).
/// - A card due on an away day is pulled to the day before (`Limits.cap`).
public enum Scheduler {
    /// FSRS-5 default parameters w0…w18.
    static let w: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605,
        2.2698, 0.2315, 2.9898, 0.51655, 0.6621,
    ]
    /// A learning card comes back this long after a miss (later in the same round or day).
    static let relearnDelay: TimeInterval = 10 * 60

    /// What bounds a card's interval.
    public struct Limits: Sendable {
        /// The day of the exam the student sits for the question's course.
        public var examDay: CalendarDay?
        /// The runway's first day (`StudyBudget.runwayStart`).
        public var runwayStart: CalendarDay?
        public var rules: PlanRules

        public init(examDay: CalendarDay?, runwayStart: CalendarDay?, rules: PlanRules) {
            self.examDay = examDay
            self.runwayStart = runwayStart
            self.rules = rules
        }

        public static let none = Limits(examDay: nil, runwayStart: nil, rules: .none)

        /// The due date of a review card reviewed at `reviewed` with an interval of `days`.
        func due(reviewed: Date, days: Double) -> Date {
            let zone = CoachModule.timeZone
            let reviewDay = CalendarDay(reviewed, in: zone)
            var interval = max(1, Int(days.rounded()))
            if let examDay {
                let left = reviewDay.days(to: examDay)
                if left > 0 {
                    // Never past the exam: due at the latest the day before it.
                    interval = min(interval, max(1, left - 1))
                    if let runwayStart, reviewDay >= runwayStart { interval = min(interval, max(1, Int(Double(left) * 0.3))) }
                    if left <= 7 { interval = min(interval, 3) }
                }
            }
            var dueDay = reviewDay.adding(days: interval)
            // Away days: the day before (never before tomorrow).
            var steps = 0
            while rules.isAway(dueDay), dueDay > reviewDay.adding(days: 1), steps < 7 {
                dueDay = dueDay.adding(days: -1)
                steps += 1
            }
            return dueDay.start(in: zone)
        }
    }

    /// The rating an answer gives its card (nil while it waits for Claude's grade).
    public static func rating(of answer: StudyAnswer) -> Int? {
        switch answer.result {
        case .wrong: 1
        case .partial: 2
        case .correct: 3
        case .pending: nil
        }
    }

    /// The card after `answers` (any order; pending ones skipped).
    public static func card(after answers: [StudyAnswer], limits: Limits) -> StudyQuestion.Card {
        var card = StudyQuestion.Card(state: .new, dueAt: nil, stability: nil, difficulty: nil, reps: 0, lapses: 0, lastReviewedAt: nil)
        for answer in answers.sorted(by: { $0.answeredAt < $1.answeredAt }) {
            guard let rating = rating(of: answer) else { continue }
            card = review(card, rating: rating, at: answer.answeredAt, limits: limits)
        }
        return card
    }

    /// One review of `card` with `rating` (1…4) at `date`.
    public static func review(_ card: StudyQuestion.Card, rating: Int, at date: Date, limits: Limits) -> StudyQuestion.Card {
        let grade = min(4, max(1, rating))
        var next = card
        let stability: Double
        let difficulty: Double
        if card.state == .new || card.stability == nil || card.lastReviewedAt == nil {
            stability = w[grade - 1]
            difficulty = clampDifficulty(initialDifficulty(grade))
            next.state = grade == 1 ? .learning : .review
        } else {
            let old = card.stability ?? w[2]
            let oldDifficulty = card.difficulty ?? clampDifficulty(initialDifficulty(3))
            let last = card.lastReviewedAt ?? date
            let zone = CoachModule.timeZone
            if CalendarDay(date, in: zone) == CalendarDay(last, in: zone) {
                // FSRS-5 short-term stability (a review the same day).
                stability = old * exp(w[17] * (Double(grade) - 3 + w[18]))
            } else {
                let elapsed = max(0, date.timeIntervalSince(last) / 86_400)
                let recall = Recall.retrievability(stability: old, elapsedDays: elapsed)
                if grade == 1 {
                    let forgot = w[11] * pow(oldDifficulty, -w[12]) * (pow(old + 1, w[13]) - 1) * exp(w[14] * (1 - recall))
                    stability = min(forgot, old)
                } else {
                    let hard = grade == 2 ? w[15] : 1
                    let easy = grade == 4 ? w[16] : 1
                    stability = old * (1 + exp(w[8]) * (11 - oldDifficulty) * pow(old, -w[9]) * (exp(w[10] * (1 - recall)) - 1) * hard * easy)
                }
            }
            difficulty = nextDifficulty(oldDifficulty, grade: grade)
            if grade == 1 {
                if card.state == .review { next.lapses += 1 }
                next.state = card.state == .review || card.state == .relearning ? .relearning : .learning
            } else {
                next.state = .review
            }
        }
        next.stability = max(0.01, stability)
        next.difficulty = difficulty
        next.reps += 1
        next.lastReviewedAt = date
        if next.state == .review {
            next.dueAt = limits.due(reviewed: date, days: Recall.interval(stability: next.stability ?? 1))
        } else {
            next.dueAt = date.addingTimeInterval(relearnDelay)
        }
        return next
    }

    static func initialDifficulty(_ grade: Int) -> Double {
        w[4] - exp(w[5] * Double(grade - 1)) + 1
    }

    static func nextDifficulty(_ difficulty: Double, grade: Int) -> Double {
        let delta = -w[6] * (Double(grade) - 3)
        let damped = difficulty + delta * (10 - difficulty) / 9
        return clampDifficulty(w[7] * initialDifficulty(4) + (1 - w[7]) * damped)
    }

    static func clampDifficulty(_ value: Double) -> Double { min(10, max(1, value)) }
}
