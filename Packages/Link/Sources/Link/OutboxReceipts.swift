import Foundation
import LinkCore
import RecorderContract

/// The phone's one persistent fact per capture: the Mac's answer, kept beside the outbox as
/// `PhoneCaptures/.link/<uuid>.json` (outside the package, whose format stays as it is). A capture
/// with a receipt is never offered again, even if it is later deleted on the Mac; Share stays.
struct OutboxReceipts: Sendable {
    struct Receipt: Codable, Hashable, Sendable {
        var recording: RecordingID
        var outcome: Received.Outcome
        var at: Date
    }

    /// `PhoneCaptures/.link`.
    let folder: URL

    init(outbox: URL) {
        folder = outbox.appending(path: ".link", directoryHint: .isDirectory)
    }

    /// Every receipt, by recording. Receipts of captures not in `existing` are deleted (the student
    /// deleted the capture); nil: the outbox could not be read, nothing is deleted.
    @concurrent
    func load(existing: Set<RecordingID>?) async -> [RecordingID: Received.Outcome] {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var receipts: [RecordingID: Received.Outcome] = [:]
        let decoder = JSONDecoder()
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let receipt = try? decoder.decode(Receipt.self, from: data) else {
                LinkLog.outbox.notice("Unreadable receipt \(url.lastPathComponent, privacy: .public)")
                continue
            }
            if let existing, !existing.contains(receipt.recording) {
                try? fileManager.removeItem(at: url)
            } else {
                receipts[receipt.recording] = receipt.outcome
            }
        }
        return receipts
    }

    /// Writes the receipt for `recording` (replacing one there).
    @concurrent
    func write(_ outcome: Received.Outcome, for recording: RecordingID, at date: Date) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Receipt(recording: recording, outcome: outcome, at: date))
        try data.write(to: folder.appending(path: "\(recording.uuidString).json"), options: .atomic)
    }
}
