import Foundation

/// Writes a lecture package's JSON files off the main actor.
///
/// Events and notes are written as whole snapshots tagged with a revision; a snapshot older
/// than the last one written is dropped, so callers can fire-and-forget from the UI without
/// worrying about task ordering. Every write is atomic.
public actor LecturePackageWriter {
    public nonisolated let package: LecturePackage
    public private(set) var manifest: LectureManifest
    private var eventsRevision = Int.min
    private var notesRevision = Int.min

    /// Creates the package folder if needed and writes `manifest` immediately.
    public init(package: LecturePackage, manifest: LectureManifest) throws {
        self.package = package
        self.manifest = manifest
        try FileManager.default.createDirectory(at: package.audioDirectory, withIntermediateDirectories: true)
        try CaptureJSON.write(manifest, to: package.manifestURL)
    }

    /// Applies `change` to the manifest and writes it.
    @discardableResult
    public func updateManifest(_ change: @Sendable (inout LectureManifest) -> Void) throws -> LectureManifest {
        change(&manifest)
        try CaptureJSON.write(manifest, to: package.manifestURL)
        return manifest
    }

    /// Writes `events` unless a newer revision was already written. Returns whether it wrote.
    @discardableResult
    public func writeEvents(_ events: [LectureEvent], revision: Int) throws -> Bool {
        guard revision > eventsRevision else { return false }
        try CaptureJSON.write(LectureEventLog(events: events), to: package.eventsURL)
        eventsRevision = revision
        return true
    }

    /// Writes `notes` unless a newer revision was already written. Returns whether it wrote.
    @discardableResult
    public func writeNotes(_ notes: [QuickNote], revision: Int) throws -> Bool {
        guard revision > notesRevision else { return false }
        try CaptureJSON.write(QuickNoteLog(notes: notes), to: package.notesURL)
        notesRevision = revision
        return true
    }

    /// Rewrites the manifest of an existing package (e.g. to mark it imported).
    public static func updateManifest(
        of package: LecturePackage,
        _ change: (inout LectureManifest) -> Void
    ) throws -> LectureManifest {
        var manifest = try CaptureJSON.read(LectureManifest.self, from: package.manifestURL)
        change(&manifest)
        try CaptureJSON.write(manifest, to: package.manifestURL)
        return manifest
    }
}
