import Courses
import CoursesUI
import AppAgent
import Deadlines
import Filing
import FilingUI
import StudyCore
import SwiftUI

extension View {
    /// The timetable import (`.ics`, docs/DESIGN.md §8.3): files dropped on the window (any
    /// screen, Calendar included) or on a course row, picked with File ▸ Import… or Course
    /// Settings' Import .ics open one confirm sheet per drop. A course row or Course Settings
    /// sends everything to that course.
    func timetableImport(center: FilingCenter) -> some View {
        modifier(TimetableImportModifier(center: center))
    }
}

/// The proposal of the latest timetable drop, waiting for the sheet.
@Observable
final class TimetableDrops {
    var pending: TimetableImport?
}

private struct TimetableImportModifier: ViewModifier {
    let center: FilingCenter
    @Environment(AppModel.self) private var model
    @State private var drops = TimetableDrops()

    func body(content: Content) -> some View {
        @Bindable var drops = drops
        content
            .environment(\.importTimetable, TimetableImportAction { [drops, model] urls, courseID in
                Self.prepare(urls, destination: courseID.map(FilingDestination.course), model: model, drops: drops)
            })
            .onAppear {
                center.timetableDrop = { [drops, model] urls, destination in
                    Self.prepare(urls, destination: destination, model: model, drops: drops)
                }
            }
            .sheet(item: $drops.pending) { proposal in
                TimetableImportSheet(proposal: proposal) { included in
                    Self.apply(proposal, including: included, model: model)
                }
            }
    }

    /// Reads the files and proposes what they add; nothing shows when they add nothing.
    static func prepare(_ urls: [URL], destination: FilingDestination?, model: AppModel, drops: TimetableDrops) {
        guard let services = model.services else { return }
        let files = urls.compactMap(TimetableFile.read)
        guard !files.isEmpty else { return }
        Task {
            do {
                let courseID = try await course(of: destination, services: services)
                let proposal = try await TimetableImporter(services: services).prepare(files, courseID: courseID)
                guard !proposal.isEmpty else { return }
                drops.pending = proposal
            } catch {
                Log.app.error("Reading a timetable failed: \(error.localizedDescription, privacy: .public)")
                model.failure = error.localizedDescription
            }
        }
    }

    /// Writes what the student confirmed. Exam dates go through the deadline memory (in the
    /// calendar on their own, with Undo), their source the file; exam reviews are added to the
    /// calendar too. The calendar mirror then writes the new sessions.
    static func apply(_ proposal: TimetableImport, including included: Set<UUID>, model: AppModel) {
        guard let services = model.services else { return }
        let memory = model.deadlines
        let store = services.records
        Task {
            do {
                let now = Date()
                let record: TimetableItemRecorder? = memory == nil ? nil : Self.recorder(store: store, now: now)
                // ma: sessions the import changes (meetings the series skips) go into the agent's
                // activity log with Undo; the import's diff event is triaged after.
                let result = try await TimetableImporter(services: services).apply(
                    proposal, including: included, now: now, record: record, sessionChange: model.appAgent?.timetableRecorder
                )
                for itemID in result.eventItemIDs {
                    _ = try await memory?.addToCalendar(itemID)
                }
                await model.syncCalendar()
                await model.appAgent?.wake()
            } catch {
                Log.app.error("Importing a timetable failed: \(error.localizedDescription, privacy: .public)")
                model.failure = error.localizedDescription
            }
        }
    }

    /// An exam date into the deadline memory as a finding the file confirms (trusted, its date
    /// verified), so it goes into the calendar on its own with Undo; it merges with the same exam
    /// from mail.
    nonisolated static func recorder(store: RecordStore, now: Date) -> TimetableItemRecorder {
        { draft, db in
            let finding = ItemFinding(
                draft: DeadlineDraft(
                    kind: draft.kind, title: draft.title, details: draft.details, courseID: draft.courseID,
                    dueAt: draft.dueAt, room: draft.room
                ),
                source: .chat(nil),
                quote: draft.quote,
                dateVerified: true,
                trusted: true,
                createdBy: .agent
            )
            let recorded = try DeadlineMemory.record(finding, in: db, store: store, now: now)
            return TimetableRecordedItem(itemID: recorded.item.id, sourceID: recorded.source?.id)
        }
    }

    /// The course a row drop or a course's import is for.
    nonisolated static func course(of destination: FilingDestination?, services: StudyServices) async throws -> Course.ID? {
        switch destination {
        case .course(let id):
            return id
        case .lecture(let id):
            return try await services.database.read { db in try Lecture.find(id).fetchOne(db)?.courseID }
        case .session(let id):
            return try await services.database.read { db in try LectureSession.find(id).fetchOne(db)?.courseID }
        case nil:
            return nil
        }
    }
}
