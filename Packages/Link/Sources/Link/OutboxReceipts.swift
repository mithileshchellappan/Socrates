import Foundation
import LinkCore
import RecorderContract

/// The phone's one sidecar per capture, kept beside the outbox as `PhoneCaptures/.link/<uuid>.json`
/// (outside the package, whose format stays as it is): while the Mac copies the capture, the bytes
/// it acknowledged, so the outbox row shows them after a relaunch before the Mac is reachable
/// again; once the Mac answered, its answer (the receipt). A capture with a receipt is never
/// offered again, even if it is later deleted on the Mac; Share stays.
struct OutboxReceipts: Sendable {
    /// What one sidecar says.
    enum Fact: Hashable, Sendable {
        /// The Mac holds these bytes, by path in the package, and has not answered.
        case copying(onMac: [String: Int64])
        /// The Mac answered.
        case answered(Received.Outcome)
    }

    /// Every sidecar's fact, by recording.
    struct Contents: Sendable {
        var receipts: [RecordingID: Received.Outcome] = [:]
        var onMac: [RecordingID: [String: Int64]] = [:]
    }

    /// The file: an answered capture has `outcome`, one being copied `onMac`. Files written before
    /// `onMac` existed hold an outcome only and read the same.
    private struct Record: Codable, Hashable, Sendable {
        var recording: RecordingID
        var outcome: Received.Outcome?
        var at: Date
        var onMac: [String: Int64]?
    }

    /// `PhoneCaptures/.link`.
    let folder: URL

    init(outbox: URL) {
        folder = outbox.appending(path: ".link", directoryHint: .isDirectory)
    }

    /// Every sidecar's fact. Sidecars of captures not in `existing` are deleted (the student
    /// deleted the capture); nil: the outbox could not be read, nothing is deleted.
    @concurrent
    func load(existing: Set<RecordingID>?) async -> Contents {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var contents = Contents()
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let record = try? decoder.decode(Record.self, from: data) else {
                LinkLog.outbox.notice("Unreadable sidecar \(url.lastPathComponent, privacy: .public)")
                continue
            }
            if let existing, !existing.contains(record.recording) {
                try? fileManager.removeItem(at: url)
            } else if let outcome = record.outcome {
                contents.receipts[record.recording] = outcome
            } else if let onMac = record.onMac, !onMac.isEmpty {
                contents.onMac[record.recording] = onMac
            }
        }
        return contents
    }

    /// Writes `fact` as `recording`'s sidecar, replacing the one there.
    @concurrent
    func write(_ fact: Fact, for recording: RecordingID, at date: Date) async throws {
        let record = switch fact {
        case .copying(let onMac): Record(recording: recording, outcome: nil, at: date, onMac: onMac)
        case .answered(let outcome): Record(recording: recording, outcome: outcome, at: date, onMac: nil)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: folder.appending(path: "\(recording.uuidString).json"), options: .atomic)
    }
}
