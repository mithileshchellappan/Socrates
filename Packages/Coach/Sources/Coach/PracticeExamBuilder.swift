import Foundation
import StudyCore

/// The practice exam (plan §4 "Practice exam"), assembled in code: from All lectures (taught
/// topics, weighted to the weak ones), Weakest topics, or one old exam (its own questions and
/// points); length = the announced `CourseRule.minutes`, else the profile's default (90, within the
/// handbook's 60–120); about a point a minute (choice / short ≈ 2, label ≈ 1 per box, explanation /
/// calculation 10–18); exam-pool questions least recently used first; Retake = new questions,
/// same settings. Untimed keeps the questions and drops the clock. Never a grade estimate.
public enum PracticeExamBuilder {
    /// What one question is worth in a practice exam.
    public static func points(of question: StudyQuestion) -> Int {
        if question.pool == .exam || question.origin == .oldExam { return max(1, question.points) }
        switch question.format {
        case .label: return max(1, question.diagram?.blanks.count ?? 1)
        case .explain, .calculation: return 10
        default: return 2
        }
    }

    public struct Exam: Sendable {
        public var questions: [StudyQuestion]
        public var points: Int
        /// Nil: untimed.
        public var minutes: Int?
    }

    /// - Parameters:
    ///   - questions: the course's questions (not retired).
    ///   - taught: the course's taught topics (`CoachRows.taughtTopics`).
    ///   - defaultMinutes: the announced length, else the profile's default.
    ///   - exclude: a retake's earlier questions (used only when nothing else is left).
    public static func build(
        source: StudyScope, minutes: Int?, questions: [StudyQuestion], taught: [TopicKey], defaultMinutes: Int,
        exclude: Set<StudyQuestion.ID> = [], now: Date
    ) -> Exam {
        if source.kind == .oldExam {
            let own = questions
                .filter { $0.origin == .oldExam && $0.sourceTitle == (source.oldExamTitle ?? "") }
                .sorted { ($0.sourceNumber ?? Int.max, $0.createdAt) < ($1.sourceNumber ?? Int.max, $1.createdAt) }
            return Exam(questions: own, points: own.reduce(0) { $0 + points(of: $1) }, minutes: minutes)
        }
        let target = minutes ?? defaultMinutes
        let mastery = TopicMastery.byTopic(questions, at: now)
        let taughtSet = Set(taught)
        // Topics weakest first; the weakest third (at least 3) for Weakest topics.
        var topics = taught.sorted { TopicMastery.weakestFirst(mastery[$0] ?? .unseen, mastery[$1] ?? .unseen) }
        if source.kind == .weakest {
            let seen = topics.filter { mastery[$0]?.seen == true }
            let base = seen.isEmpty ? topics : seen
            topics = Array(base.prefix(max(3, base.count / 3)))
        }
        let allowed = Set(topics)
        func usable(_ question: StudyQuestion) -> Bool {
            guard question.origin == .generated, question.readingID == nil, let key = question.topicKey else { return false }
            return taughtSet.contains(key) && allowed.contains(key)
        }
        // Least recently used first (never answered first), then the newest drafted.
        func older(_ lhs: StudyQuestion, _ rhs: StudyQuestion) -> Bool {
            let left = lhs.lastReviewedAt ?? .distantPast
            let right = rhs.lastReviewedAt ?? .distantPast
            if left != right { return left < right }
            return lhs.createdAt > rhs.createdAt
        }
        func pick(excluding: Set<StudyQuestion.ID>) -> [StudyQuestion] {
            let examPool = questions.filter { $0.pool == .exam && usable($0) && !excluding.contains($0.id) }
            let fillers = questions.filter { $0.pool == .round && $0.format == .choice && usable($0) && !excluding.contains($0.id) }
            var byTopic: [TopicKey: [StudyQuestion]] = [:]
            for question in examPool.sorted(by: older) {
                if let key = question.topicKey { byTopic[key, default: []].append(question) }
            }
            var chosen: [StudyQuestion] = []
            var total = 0
            // One exam question per topic, weakest topics first; then a second for weak topics
            // (≤ 1 dot); then a second for any.
            var pass = 0
            while total < target, pass < 3 {
                var added = false
                for topic in topics {
                    guard total < target, let list = byTopic[topic], pass < list.count else { continue }
                    if pass == 1, (mastery[topic]?.level ?? 0) > 1 { continue }
                    let question = list[pass]
                    // Never far past the length: a long question that overshoots by more than 10 is left.
                    if total > 0, total + points(of: question) > target + 10 { continue }
                    chosen.append(question)
                    total += points(of: question)
                    added = true
                }
                if !added { break }
                pass += 1
            }
            // Fill with choices (2 points) of the weakest topics, least recently used first.
            let rank = Dictionary(topics.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            for question in fillers.sorted(by: { lhs, rhs in
                let left = lhs.topicKey.flatMap { rank[$0] } ?? Int.max
                let right = rhs.topicKey.flatMap { rank[$0] } ?? Int.max
                return left != right ? left < right : older(lhs, rhs)
            }) where total < target {
                chosen.append(question)
                total += points(of: question)
            }
            return chosen
        }
        var chosen = pick(excluding: exclude)
        if chosen.isEmpty, !exclude.isEmpty { chosen = pick(excluding: []) }
        // In the order an exam goes: by lecture, then slide.
        let order = Dictionary(taught.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        chosen.sort { lhs, rhs in
            let left = lhs.topicKey.flatMap { order[$0] } ?? Int.max
            let right = rhs.topicKey.flatMap { order[$0] } ?? Int.max
            if left != right { return left < right }
            return points(of: lhs) < points(of: rhs)
        }
        return Exam(questions: chosen, points: chosen.reduce(0) { $0 + points(of: $1) }, minutes: minutes)
    }
}
