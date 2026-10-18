import Foundation
import StudyCore

/// The pass's settled lectures across launches (M5, docs/plan-m5.md §5.1: no launch burst):
/// `AppPaths.caches/StudyPass/settled.json`, the lecture id → `Fingerprint` of every lecture a
/// pass found nothing to do for, with `StudyPass.promptVersion`. Read once when the pipeline
/// starts, written (atomically) after a pass that changed it. A file of another prompt version,
/// or one that does not read, counts as empty: every lecture is planned once, as before. A cache:
/// deleting it costs one planning pass, never a model call (unchanged units are never called).
struct SettledFile: Sendable {
    let url: URL

    private struct Contents: Codable {
        var promptVersion: Int
        /// Lecture id (lower-case UUID) → its fingerprint.
        var lectures: [String: StudyPassPipeline.Fingerprint]
    }

    func read() -> [Lecture.ID: StudyPassPipeline.Fingerprint] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let contents = try Self.decoder.decode(Contents.self, from: data)
            guard contents.promptVersion == StudyPass.promptVersion else { return [:] }
            var settled: [Lecture.ID: StudyPassPipeline.Fingerprint] = [:]
            for (key, fingerprint) in contents.lectures {
                if let id = UUID(uuidString: key) { settled[id] = fingerprint }
            }
            return settled
        } catch {
            StudyPass.log.notice("Settled lectures unreadable; planning every lecture once: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// True when written.
    @discardableResult
    func write(_ settled: [Lecture.ID: StudyPassPipeline.Fingerprint]) -> Bool {
        let contents = Contents(
            promptVersion: StudyPass.promptVersion,
            lectures: Dictionary(uniqueKeysWithValues: settled.map { ($0.key.uuidString.lowercased(), $0.value) }))
        do {
            let data = try Self.encoder.encode(contents)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            StudyPass.log.error("Settled lectures not written: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Dates as the hex bit pattern of their reference-date seconds: fingerprints compare dates
    /// exactly, and a decimal round trip could differ in the last bit.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let bits = UInt64(text, radix: 16) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a date")
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        return decoder
    }
}
