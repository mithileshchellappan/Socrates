import Deadlines
import Foundation
import StudyCore

/// Grading in code (plan §4 "Grading"): choices and labels at once; written formats wait for
/// Claude (`AnswerGrader`).
public enum CodeGrading {
    /// The result and score of a choice or label answer; nil for a written one (pending).
    public static func grade(_ response: StudyResponse, for question: StudyQuestion) -> (result: StudyAnswerResult, score: Double)? {
        switch question.format {
        case .choice:
            guard case .choice(let picked) = response else { return (.wrong, 0) }
            return picked == question.correctChoice ? (.correct, 1) : (.wrong, 0)
        case .label:
            guard let diagram = question.diagram else { return (.wrong, 0) }
            let blanks = diagram.blanks
            guard !blanks.isEmpty else { return (.correct, 1) }
            guard case .labels(let placed) = response else { return (.wrong, 0) }
            let right = blanks.filter { box in
                placed[box.id].map { TextFolding.fold($0) == TextFolding.fold(box.text) } ?? false
            }.count
            let score = Double(right) / Double(blanks.count)
            return (right == blanks.count ? .correct : (right == 0 ? .wrong : .partial), score)
        default:
            // An empty written answer is wrong at once (nothing for Claude to grade).
            if response.isEmpty { return (.wrong, 0) }
            return nil
        }
    }
}

/// What a round asks (plan §4 "Rounds"): due cards first (misses, then the oldest due), then new
/// cards of the weakest and newest topics, then (when that is short of the round's size) seen cards
/// not due yet, weakest topic first; about 1.2 questions a minute, a written one counting 3,
/// at most 2 written; in the runway confusable topics (one lecture's neighbours) interleaved; a
/// Read block's round is its reading's 2–3 recall questions (a reading opened by its link: they
/// join the next rounds, first among the new). Pure: rows in, questions out.
public enum RoundBuilder {
    /// How big a round is.
    public enum Size: Sendable, Hashable {
        /// A plan block's number of questions.
        case questions(Int)
        /// About this many minutes.
        case minutes(Int)
    }

    /// A round outside the plan (Practice on Progress): about 10 minutes.
    public static let defaultMinutes = 10

    /// A question's weight in a round's time (`CoachRules.writtenWeight` for written ones).
    public static func weight(_ question: StudyQuestion) -> Int {
        question.format.isWritten ? CoachRules.writtenWeight : 1
    }

    /// The round's minutes ("12 questions · 10 min"), rounded up to 5.
    public static func minutes(for questions: [StudyQuestion]) -> Int {
        let weights = questions.reduce(0) { $0 + weight($1) }
        guard weights > 0 else { return 0 }
        let raw = Int((Double(weights) / CoachRules.questionsPerMinute).rounded(.up))
        return max(5, (raw + 4) / 5 * 5)
    }

    /// The questions of a round of `scope`, in the order asked.
    /// - Parameters:
    ///   - questions: the scope's courses' questions (not retired).
    ///   - lectures: the courses' lectures (held dates: nothing new from a lecture not yet held).
    ///   - misses: for `.misses`, the exam's questions answered wrong or partly.
    ///   - runway: interleave confusable topics.
    ///   - readings: readings read or opened (`PlanEngine.readReadings`): their recall questions
    ///     join the round, the ones not answered yet first among the new.
    public static func build(
        scope: StudyScope, size: Size, questions: [StudyQuestion], lectures: [Lecture], misses: [StudyQuestion.ID] = [],
        runway: Bool, now: Date, readings: Set<StudyReading.ID> = []
    ) -> [StudyQuestion] {
        let held = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mastery = TopicMastery.byTopic(questions, at: now)
        let endOfDay = CalendarDay(now, in: CoachModule.timeZone).adding(days: 1).start(in: CoachModule.timeZone)
        var pool: [StudyQuestion]
        var limit = size
        switch scope.kind {
        case .reading:
            // A Read block: its recall questions, all of them.
            pool = questions.filter { $0.readingID != nil && $0.readingID == scope.readingID }
            return pool.sorted { $0.createdAt < $1.createdAt }
        case .misses:
            let wanted = Set(misses)
            pool = questions.filter { wanted.contains($0.id) }
            limit = .questions(max(1, pool.count))
        case .topic:
            pool = questions.filter { $0.topicKey == scope.topic && ($0.readingID.map(readings.contains) ?? true) && $0.pool == .round }
        default:
            let courses = Set(scope.courseIDs)
            pool = questions.filter {
                (courses.isEmpty || courses.contains($0.courseID)) && ($0.readingID.map(readings.contains) ?? true) && $0.pool == .round
            }
        }
        // Nothing new from a lecture not held yet.
        pool = pool.filter { question in
            guard let lectureID = question.lectureID, let lecture = held[lectureID] else { return true }
            return (lecture.heldAt ?? .distantPast) <= now
        }
        let due = pool
            .filter { $0.reps > 0 && ($0.dueAt ?? .distantFuture) < endOfDay }
            .sorted { lhs, rhs in
                let lhsMiss = lhs.cardState == .learning || lhs.cardState == .relearning
                let rhsMiss = rhs.cardState == .learning || rhs.cardState == .relearning
                if lhsMiss != rhsMiss { return lhsMiss }
                return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
            }
        let fresh = pool
            .filter { $0.reps == 0 }
            .sorted { lhs, rhs in
                // A reading's recall questions right after it was read.
                if (lhs.readingID != nil) != (rhs.readingID != nil) { return lhs.readingID != nil }
                let left = lhs.topicKey.flatMap { mastery[$0] } ?? .unseen
                let right = rhs.topicKey.flatMap { mastery[$0] } ?? .unseen
                // Weakest first (unseen topics count as weakest of all for new cards), then newest lecture.
                if left.level != right.level { return left.level < right.level }
                if left.seen != right.seen { return left.seen }
                let leftHeld = lhs.lectureID.flatMap { held[$0]?.heldAt } ?? .distantPast
                let rightHeld = rhs.lectureID.flatMap { held[$0]?.heldAt } ?? .distantPast
                if leftHeld != rightHeld { return leftHeld > rightHeld }
                return (lhs.topic, lhs.createdAt) < (rhs.topic, rhs.createdAt)
            }
        // Practice asked for when little is due (Progress's Practice, Practice This Topic, a plan
        // block sized ahead): seen cards that are not due yet fill the round, weakest topic first,
        // then the soonest due (an early review; FSRS takes the shorter interval into account).
        let taken = Set((due + fresh).map(\.id))
        let ahead = pool
            .filter { $0.reps > 0 && !taken.contains($0.id) }
            .sorted { lhs, rhs in
                let left = lhs.topicKey.flatMap { mastery[$0] }?.level ?? 0
                let right = rhs.topicKey.flatMap { mastery[$0] }?.level ?? 0
                if left != right { return left < right }
                return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
            }
        // A misses round asks every miss; others fill to their size.
        let candidates = scope.kind == .misses ? pool : due + fresh + ahead
        var picked: [StudyQuestion] = []
        var weights = 0
        var written = 0
        selection: for question in candidates {
            switch limit {
            case .questions(let count): if picked.count >= count { break selection }
            case .minutes(let minutes): if Double(weights) >= Double(minutes) * CoachRules.questionsPerMinute { break selection }
            }
            if question.format.isWritten {
                guard written < CoachRules.writtenPerRound || scope.kind == .misses else { continue }
                written += 1
            }
            picked.append(question)
            weights += weight(question)
        }
        return runway ? interleave(picked, lectures: held) : picked
    }

    /// Confusable topics interleaved: questions taken in turn from each topic, topics ordered by
    /// lecture and slide (a lecture's neighbours alternate). Misses stay first.
    static func interleave(_ questions: [StudyQuestion], lectures: [Lecture.ID: Lecture]) -> [StudyQuestion] {
        let misses = questions.filter { $0.cardState == .learning || $0.cardState == .relearning }
        let rest = questions.filter { !($0.cardState == .learning || $0.cardState == .relearning) }
        var groups: [(key: String, items: [StudyQuestion])] = []
        for question in rest {
            let number = question.lectureID.flatMap { lectures[$0]?.number } ?? 0
            let key = String(format: "%04d|", number) + TopicKey.fold(question.topic)
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].items.append(question)
            } else {
                groups.append((key, [question]))
            }
        }
        groups.sort { $0.key < $1.key }
        var output = misses
        var round = 0
        while output.count < questions.count {
            var added = false
            for group in groups where round < group.items.count {
                output.append(group.items[round])
                added = true
            }
            if !added { break }
            round += 1
        }
        return output
    }
}
