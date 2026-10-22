import Capture
import Courses
import Foundation
import RecorderContract
import StudyCore

// What an earlier run of the app left behind, handled once at launch (`activate()`), queued
// before any command.
//
// Pausing releases the input, so iOS may suspend the app and later kill it. The Live Activity
// outlives the process and still offers Resume and Stop; a tap relaunches the app in the
// background. So a recording left paused whose activity is still up is taken up again, paused,
// in the same package (`LiveLectureSession.reopen(paused:)`): Resume records on after the time
// paused, Stop finishes it, and the snapshot's sequence goes on from what the activity showed.
// A recording left paused without its activity (or that cannot be taken up) is finished where
// it paused, so the outbox shows it complete.

extension PhoneRecorder {
    func recoverLeftovers() async {
        let showing = activity.showing()
        let leftovers = await Self.pausedLeftovers(in: services.paths.phoneCaptures)
        for contents in leftovers {
            let id = RecordingID(contents.manifest.id)
            if !isCapturing, let shownSequence = showing[id], await takeUp(contents, shownSequence: shownSequence) {
                continue
            }
            do {
                try await Self.finishLeftPaused(contents)
                RecorderLog.recorder.notice("Finished a recording left paused: \(id.uuidString, privacy: .public)")
            } catch {
                RecorderLog.recorder.error("Finishing a recording left paused failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Activities whose recording the app no longer has: their buttons would act on nothing.
        activity.endStale()
        await Self.removeSharedBundles()
    }

    /// Takes up `contents` paused for its course and follows its Live Activity again. False when
    /// it cannot (its course gone or without consent, the package unreadable); the caller then
    /// finishes it.
    private func takeUp(_ contents: LecturePackageContents, shownSequence: Int) async -> Bool {
        await loadCourses()
        guard let courseID = contents.manifest.courseID, let course = courses.first(where: { $0.id == courseID }) else {
            RecorderLog.recorder.notice("A recording left paused has no course that may record")
            return false
        }
        self.course = course
        let start = contents.manifest.startedAt ?? Date()
        classSession = try? await CourseSchedule(services: services).session(forRecordingAt: start, courseID: course.id)
        lecture = await lecture(of: classSession)
        let reopened = await makeSession(for: course)
        do {
            try await reopened.reopen(paused: contents)
        } catch {
            RecorderLog.recorder.error("Taking up a recording left paused failed: \(String(describing: error), privacy: .public)")
            return false
        }
        session = reopened
        snapshot = nil
        machine = RecorderMachine()
        lastSequence = max(lastSequence, shownSequence)
        activity.adopt(RecordingID(contents.manifest.id))
        publish()
        RecorderLog.recorder.notice("Took up a recording left paused: \(contents.manifest.id.uuidString, privacy: .public)")
        return true
    }

    /// The outbox's packages that ended in a pause without being finished, newest first.
    @concurrent
    private nonisolated static func pausedLeftovers(in directory: URL) async -> [LecturePackageContents] {
        let packages = (try? LecturePackage.all(in: directory)) ?? []
        return packages
            .compactMap { try? LecturePackageReader.read($0) }
            .filter { !$0.isComplete && $0.events.last?.kind == .pause }
            .sorted { ($0.manifest.startedAt ?? .distantPast) > ($1.manifest.startedAt ?? .distantPast) }
    }

    @concurrent
    private nonisolated static func finishLeftPaused(_ contents: LecturePackageContents) async throws {
        try LecturePackageWriter.finishLeftPaused(contents)
    }

    /// Bundles an earlier Share wrote to the temporary folder.
    @concurrent
    private nonisolated static func removeSharedBundles() async {
        CaptureBundle.removeTemporaryBundles(olderThan: 0)
    }
}
