import Capture
import Foundation
import StudyCore

/// One recording made on the phone, waiting in the outbox (`AppPaths.phoneCaptures`) until the
/// student shares it to the Mac and deletes it. Read from its package; never in the phone's
/// library.
public struct PhoneCapture: Identifiable, Sendable, Hashable {
    /// The package's id (= the recording's id on the Mac).
    public var id: UUID
    public var package: LecturePackage
    /// "DC Lecture 2" (the recorder's session name), else the course's short name and the day.
    public var title: String
    public var courseID: Course.ID?
    public var startedAt: Date?
    /// Seconds recorded (pauses left out, as the recorder's timer shows it).
    public var duration: TimeInterval
    /// Slide changes and flags (not the start, stop, pauses or resumes).
    public var stampCount: Int
    /// Stopped cleanly (false after a crash; the package is still complete enough to share).
    public var isComplete: Bool

    public init(
        id: UUID, package: LecturePackage, title: String, courseID: Course.ID?, startedAt: Date?,
        duration: TimeInterval, stampCount: Int, isComplete: Bool
    ) {
        self.id = id
        self.package = package
        self.title = title
        self.courseID = courseID
        self.startedAt = startedAt
        self.duration = duration
        self.stampCount = stampCount
        self.isComplete = isComplete
    }

    /// What Share sends: the package as one `.lecturebundle` named after the capture.
    public var bundleItem: CaptureBundleItem {
        CaptureBundleItem(package: package, title: title)
    }

    /// The phone's captures in `directory`, newest first, leaving out `excluding` (the one being
    /// recorded). Unreadable packages are skipped.
    @concurrent
    static func load(in directory: URL, excluding: UUID?) async -> [PhoneCapture] {
        let packages = (try? LecturePackage.all(in: directory)) ?? []
        var captures: [PhoneCapture] = []
        for package in packages where package.id != excluding {
            guard let contents = try? LecturePackageReader.read(package) else { continue }
            let manifest = contents.manifest
            let start = manifest.startedAt ?? contents.events.map(\.wallClock).min()
            captures.append(PhoneCapture(
                id: manifest.id,
                package: package,
                title: title(of: manifest, startedAt: start),
                courseID: manifest.courseID,
                startedAt: start,
                duration: contents.recordedDuration,
                stampCount: contents.events.count { ($0.kind.showsSlide && $0.kind != .start) || $0.kind == .flag },
                isComplete: contents.isComplete
            ))
        }
        return captures.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    private static func title(of manifest: LectureManifest, startedAt: Date?) -> String {
        if let name = manifest.sessionName { return name }
        let course = manifest.courseShortName ?? manifest.courseName
        let day = startedAt.map { RecorderText.day($0) }
        return [course, day].compactMap(\.self).joined(separator: " ")
    }
}
