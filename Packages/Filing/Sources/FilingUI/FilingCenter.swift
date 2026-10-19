import Filing
import Foundation
import Observation
import os
import StudyCore

/// The window's smart import state: the drag prediction the HUD shows, the toasts after a drop
/// (whose Change… is a menu of places, mockup 10), the change sheet (File menu, Course Settings)
/// and the file importer. One per main window; the app owns it next to its `FilingService`.
@MainActor
@Observable
public final class FilingCenter {
    public let service: FilingService

    /// A drag over the window: where it is and where its files would go.
    public struct Drag: Equatable {
        /// Cursor position in the window's content.
        public var location: CGPoint
        /// Where the HUD sits (it stops following the cursor when there is a choice to drop on).
        public var anchor: CGPoint
        public var predictions: [FilingPrediction]
        /// The HUD row under the cursor (drop there to file to that place), or the Change row.
        public var targeted: HUDTarget?
        /// Over a sidebar lecture or session row: the row shows the destination instead.
        public var isOverRow: Bool
    }

    /// A drop target inside the HUD.
    public enum HUDTarget: Hashable {
        case place(Int)
        case change
    }

    /// One filed (or failed) file after a drop.
    public struct Toast: Identifiable, Equatable {
        public let id: UUID
        public var outcome: FilingOutcome
        /// Undo or Change is running.
        public var isWorking = false
        /// Dropped on the HUD's Change…: the toast stays, its Change… lit, until a place is chosen.
        public var wantsChange = false

        public init(id: UUID = UUID(), outcome: FilingOutcome) {
            self.id = id
            self.outcome = outcome
        }

        /// Filed for sure (or failed): goes away on its own. Unsure ones wait for the user.
        var dismissesItself: Bool {
            guard !wantsChange else { return false }
            switch outcome.status {
            case .filed, .known, .failed: return true
            case .review, .needsCourse: return false
            }
        }
    }

    /// Identifies the filing the change sheet edits.
    public struct ChangeRequest: Identifiable, Hashable {
        public let id: Filing.ID
    }

    /// One course in a toast's Change… menu: its lectures and the sessions around now.
    public struct ChangeSection: Identifiable, Hashable {
        public var course: Course
        public var places: [FilingPlace]
        public var id: Course.ID { course.id }
    }

    /// What a Change… menu item does.
    public enum ChangeChoice: Hashable {
        case place(FilingDestination)
        case newLecture(Course.ID)
    }

    /// The file a previewed drag shows under the cursor (parity screenshots and snapshots only; a
    /// real drag's image is the system's).
    public struct DragGhost: Equatable, Sendable {
        /// A PDF whose first page is the thumbnail.
        public var url: URL
        public var fileName: String

        public init(url: URL, fileName: String) {
            self.url = url
            self.fileName = fileName
        }
    }

    public internal(set) var drag: Drag?
    /// Where the dragged files would go while they are over the window (not over a sidebar row):
    /// the HUD row under the cursor, else the HUD's first place. The sidebar lights its row
    /// (mockup 10), so every lecture row shows itself as a place to drop instead.
    public private(set) var predictedPlace: FilingPlace?
    /// The course the dragged files would go to, from the first prediction until the drag ends
    /// (also while the cursor is on a sidebar row): the sidebar keeps it expanded meanwhile.
    public private(set) var predictedCourseID: Course.ID?
    /// The sidebar row to light while dragging (`predictedPlace`'s destination).
    public var predictedDestination: FilingDestination? { predictedPlace?.destination }
    public internal(set) var toasts: [Toast] = []
    /// The change sheet's filing; set to present it.
    public var changing: ChangeRequest?
    /// File ▸ Import… presents the file importer.
    public var isImporterPresented = false
    /// A previewed drag's file (`preview(predictions:at:targeted:ghost:)`); never set by a drag.
    public private(set) var previewGhost: DragGhost?
    /// Where the importer's files go (nil: wherever smart import puts them).
    @ObservationIgnored var importDestination: FilingDestination?
    /// Called after every drop, import or row drop has been filed (the app takes a second look
    /// at unsure recordings once new slides are in).
    @ObservationIgnored public var didFile: (@MainActor ([FilingOutcome]) -> Void)?
    /// Timetable files (`.ics`) among a drop, a row drop or File ▸ Import… go here instead of
    /// being filed, with the row's (or the course's Import's) destination. Nil: they are filed
    /// (and fail as neither slides nor a recording).
    @ObservationIgnored public var timetableDrop: (@MainActor ([URL], FilingDestination?) -> Void)?

    /// Seconds a confident toast stays (while not hovered).
    @ObservationIgnored var toastLifetime: Duration = .seconds(8)
    static let maximumToasts = 4
    /// Space the HUD keeps from the cursor (mockup 10: to the right of the dragged file).
    static let hudOffset = CGSize(width: 62, height: -34)

    @ObservationIgnored var containerSize: CGSize = .zero
    @ObservationIgnored var hudFrames: [HUDTarget: CGRect] = [:]
    @ObservationIgnored private var predictTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var hovered: Set<UUID> = []
    @ObservationIgnored private var rowTargets = 0
    /// Drops on the window or on a sidebar row so far: a drag that ended with one was not
    /// cancelled.
    @ObservationIgnored public private(set) var dropCount = 0

    public init(service: FilingService) {
        self.service = service
    }

    // MARK: - Drag

    /// A drag with `urls` (nil while the files cannot be read yet) entered at `location`.
    func dragEntered(at location: CGPoint, urls: @escaping @MainActor () async -> [URL]) {
        drag = Drag(location: location, anchor: hudAnchor(for: location), predictions: [], targeted: nil, isOverRow: rowTargets > 0)
        syncPrediction()
        predictTask?.cancel()
        let service = service
        predictTask = Task { [weak self] in
            let files = await urls()
            guard !files.isEmpty, !Task.isCancelled else { return }
            let predictions = await service.predict(files)
            guard !Task.isCancelled, let self, var drag = self.drag else { return }
            drag.predictions = predictions
            if !self.followsCursor(predictions) {
                drag.anchor = self.hudAnchor(for: drag.location)
            }
            self.drag = drag
            self.syncPrediction()
        }
    }

    func dragMoved(to location: CGPoint) {
        guard var drag else { return }
        drag.location = location
        if followsCursor(drag.predictions) {
            drag.anchor = hudAnchor(for: location)
            drag.targeted = nil
        } else {
            drag.targeted = hudFrames.first { $0.value.insetBy(dx: -2, dy: -2).contains(location) }?.key
        }
        if drag != self.drag {
            self.drag = drag
            syncPrediction()
        }
    }

    func dragExited() {
        predictTask?.cancel()
        drag = nil
        previewGhost = nil
        hudFrames = [:]
        syncPrediction()
    }

    /// The files were dropped on the window (not on a sidebar row).
    func dropped(urls: [URL]) {
        let drag = self.drag
        dropCount += 1
        dragExited()
        guard !urls.isEmpty else { return }
        var destination: FilingDestination?
        var opensChange = false
        if let drag, let targeted = drag.targeted, let prediction = drag.predictions.first {
            switch targeted {
            case .place(let index) where prediction.places.indices.contains(index):
                destination = prediction.places[index].destination
            case .change:
                opensChange = true
            default:
                break
            }
        }
        Task { await file(urls, to: destination, openChange: opensChange) }
    }

    /// A sidebar row became (or stopped being) the drop target.
    func rowTargeted(_ isTargeted: Bool) {
        rowTargets = max(0, rowTargets + (isTargeted ? 1 : -1))
        drag?.isOverRow = rowTargets > 0
        syncPrediction()
    }

    /// Files dropped on a sidebar row go exactly there.
    func dropped(_ urls: [URL], onRow destination: FilingDestination) async {
        dropCount += 1
        dragExited()
        await file(urls, to: destination)
    }

    /// The place the dragged files would go and its course, set only when they change (each
    /// sidebar row reads them, and the cursor moves many times a second).
    private func syncPrediction() {
        var place: FilingPlace?
        if let drag, !drag.isOverRow, let prediction = drag.predictions.first {
            if case .place(let index)? = drag.targeted, prediction.places.indices.contains(index) {
                place = prediction.places[index]
            } else {
                place = prediction.places.first
            }
        }
        if place != predictedPlace { predictedPlace = place }
        let isDragging = drag != nil || rowTargets > 0
        let course = isDragging ? place?.course.id ?? predictedCourseID : nil
        if course != predictedCourseID { predictedCourseID = course }
    }

    /// The HUD follows the cursor while it shows one destination; with a choice it stays put so
    /// the cursor can reach a row.
    private func followsCursor(_ predictions: [FilingPrediction]) -> Bool {
        guard predictions.count == 1, let prediction = predictions.first else { return true }
        return prediction.places.count <= 1
    }

    private func hudAnchor(for location: CGPoint) -> CGPoint {
        let width = DropHUD.width
        let height = DropHUD.estimatedHeight
        var x = location.x + Self.hudOffset.width
        var y = location.y + Self.hudOffset.height
        if containerSize.width > 0 {
            if x + width > containerSize.width - 12 { x = location.x - Self.hudOffset.width - width + 20 }
            x = min(max(12, x), max(12, containerSize.width - width - 12))
            y = min(max(12, y), max(12, containerSize.height - height - 12))
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Filing

    /// Files `urls` (drop, sidebar row, File ▸ Import…) and shows a toast per file.
    public func file(_ urls: [URL], to destination: FilingDestination? = nil) async {
        await file(urls, to: destination, openChange: false)
    }

    private func file(_ urls: [URL], to destination: FilingDestination?, openChange: Bool) async {
        var urls = urls
        if let timetableDrop {
            let timetables = urls.filter(FilingTypes.isTimetable)
            if !timetables.isEmpty {
                timetableDrop(timetables, destination)
                urls.removeAll(where: FilingTypes.isTimetable)
                guard !urls.isEmpty else { return }
            }
        }
        let outcomes = await service.file(urls, to: destination)
        for outcome in outcomes { show(outcome, wantsChange: openChange && outcome.filing != nil) }
        didFile?(outcomes)
    }

    /// A toast for `outcome`; one dropped on the HUD's Change… stays with its Change… lit (no
    /// dialog: the menu is one click away).
    func show(_ outcome: FilingOutcome, wantsChange: Bool = false) {
        var toast = Toast(outcome: outcome)
        toast.wantsChange = wantsChange
        toasts.append(toast)
        while toasts.count > Self.maximumToasts, let oldest = toasts.first(where: \.dismissesItself) ?? toasts.first {
            dismiss(oldest.id)
        }
        scheduleDismissal(toast.id)
    }

    public func dismiss(_ id: Toast.ID) {
        dismissTasks.removeValue(forKey: id)?.cancel()
        hovered.remove(id)
        toasts.removeAll { $0.id == id }
    }

    func setHovering(_ id: Toast.ID, _ isHovering: Bool) {
        if isHovering {
            hovered.insert(id)
            dismissTasks.removeValue(forKey: id)?.cancel()
        } else {
            hovered.remove(id)
            scheduleDismissal(id)
        }
    }

    private func scheduleDismissal(_ id: Toast.ID) {
        guard let toast = toasts.first(where: { $0.id == id }), toast.dismissesItself, !hovered.contains(id) else { return }
        dismissTasks[id]?.cancel()
        let lifetime = toastLifetime
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    /// Undo from a toast: removes what the filing created. A capture is un-filed instead (never
    /// deleted); its toast then waits for a course.
    func undo(_ id: Toast.ID) async {
        guard let index = toasts.firstIndex(where: { $0.id == id }), let filing = toasts[index].outcome.filing else { return }
        toasts[index].isWorking = true
        do {
            if let kept = try await service.undo(filing.id) {
                update(id) { toast in
                    toast.outcome.filing = kept
                    toast.outcome.place = nil
                    toast.outcome.status = .needsCourse
                    toast.outcome.alternatives = []
                    toast.isWorking = false
                }
                dismissTasks.removeValue(forKey: id)?.cancel()
            } else {
                dismiss(id)
            }
        } catch {
            update(id) { $0.isWorking = false }
        }
    }

    /// Files the toast's file to one of its alternatives (one click on a review toast).
    func move(_ id: Toast.ID, to place: FilingPlace) async {
        guard let filing = toasts.first(where: { $0.id == id })?.outcome.filing else { return }
        update(id) { $0.isWorking = true }
        await change(filing.id, to: place.destination, newLectureIn: nil)
    }

    /// The Change… menu of a toast: each course with its lectures and the sessions from two weeks
    /// back to two weeks ahead, the toast's course first. Empty when the file has no filing.
    func changeSections(for toast: Toast, now: Date = Date()) async -> [ChangeSection] {
        guard toast.outcome.filing != nil, let courses = try? await service.courses() else { return [] }
        let window = now.addingTimeInterval(-14 * 86_400)...now.addingTimeInterval(14 * 86_400)
        let first = toast.outcome.place?.course.id
        var sections: [ChangeSection] = []
        for course in courses.sorted(by: { ($0.id == first ? 0 : 1) < ($1.id == first ? 0 : 1) }) {
            let places = ((try? await service.places(courseID: course.id)) ?? []).filter { place in
                place.lectureID != nil || place.date.map(window.contains) == true
            }
            if !places.isEmpty { sections.append(ChangeSection(course: course, places: places)) }
        }
        return sections
    }

    /// A Change… menu item: moves the toast's file there.
    func choose(_ id: Toast.ID, _ choice: ChangeChoice) async {
        guard let filing = toasts.first(where: { $0.id == id })?.outcome.filing else { return }
        update(id) { toast in
            toast.isWorking = true
            toast.wantsChange = false
        }
        switch choice {
        case .place(let destination):
            await change(filing.id, to: destination, newLectureIn: nil)
        case .newLecture(let courseID):
            await change(filing.id, to: nil, newLectureIn: courseID)
        }
        update(id) { $0.isWorking = false }
        scheduleDismissal(id)
    }

    /// Opens the change sheet for a filing.
    public func presentChange(_ filingID: Filing.ID) {
        changing = ChangeRequest(id: filingID)
    }

    /// Moves a filing (change sheet, alternatives) and refreshes its toast.
    func change(_ filingID: Filing.ID, to destination: FilingDestination?, newLectureIn courseID: Course.ID?) async {
        do {
            let filing: Filing
            if let courseID {
                filing = try await service.changeToNewLecture(filingID, courseID: courseID)
            } else if let destination {
                filing = try await service.change(filingID, to: destination)
            } else {
                return
            }
            let place = try await service.place(of: filing)
            for index in toasts.indices where toasts[index].outcome.filing?.id == filingID {
                toasts[index].outcome.filing = filing
                toasts[index].outcome.place = place
                toasts[index].outcome.status = .filed
                toasts[index].outcome.alternatives = []
                toasts[index].isWorking = false
                scheduleDismissal(toasts[index].id)
            }
        } catch {
            for index in toasts.indices where toasts[index].outcome.filing?.id == filingID {
                toasts[index].isWorking = false
            }
        }
    }

    /// A filing changed without the toast (smart import's second look by what was said): its
    /// toast, if one is still up, shows where the file is now and leaves on its own when sure.
    public func refresh(_ filing: Filing) async {
        guard toasts.contains(where: { $0.outcome.filing?.id == filing.id }) else { return }
        let place = try? await service.place(of: filing)
        for index in toasts.indices where toasts[index].outcome.filing?.id == filing.id {
            toasts[index].outcome.filing = filing
            toasts[index].outcome.place = place
            toasts[index].outcome.status = filing.lectureID == nil ? .needsCourse : (filing.needsReview ? .review : .filed)
            toasts[index].outcome.alternatives = []
            scheduleDismissal(toasts[index].id)
        }
    }

    private func update(_ id: Toast.ID, _ change: (inout Toast) -> Void) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        change(&toasts[index])
    }

    /// File ▸ Import… (or a course's Import, which files into that course).
    public func importFiles(to destination: FilingDestination? = nil) {
        importDestination = destination
        isImporterPresented = true
    }

    // MARK: - Delete

    /// Delete… on a deck, a lecture or a recording, waiting for the window's confirmation, with
    /// what goes (`LibraryDeleteConfirmation`).
    public struct PendingDeletion: Identifiable, Equatable {
        public let id = UUID()
        public var item: LibraryItem
        public var summary: DeletionSummary
    }

    /// Set to ask for the confirmation; cleared by Delete or Cancel.
    public var pendingDeletion: PendingDeletion?

    /// Delete… (a row's menu, Review, the Edit menu): reads what goes, then asks.
    public func requestDelete(_ item: LibraryItem) {
        let service = service
        Task {
            do {
                let summary = try await service.deletionSummary(item)
                pendingDeletion = PendingDeletion(item: item, summary: summary)
            } catch {
                Self.log.error("Reading what a delete takes failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The confirmation's Delete: deletes, then Edit ▸ Undo ("Undo Delete Slides") puts everything
    /// back and Redo deletes it again. The files stay until the undo window has passed.
    public func delete(_ pending: PendingDeletion, undoManager: UndoManager?) async throws {
        if pendingDeletion?.id == pending.id { pendingDeletion = nil }
        let deletion = try await service.delete(pending.item)
        if let undoManager { registerUndo(deletion, undoManager: undoManager) }
    }

    private func registerUndo(_ deletion: Deletion, undoManager: UndoManager) {
        let name = Self.undoName(deletion.item)
        undoManager.registerUndo(withTarget: self) { center in
            let service = center.service
            let restoring = Task {
                do {
                    try await service.restore(deletion)
                } catch {
                    Self.log.error("Restoring a deleted item failed: \(String(describing: error), privacy: .public)")
                }
            }
            // Redo: deletes it again once it is back (and registers the next Undo then).
            undoManager.registerUndo(withTarget: center) { center in
                Task {
                    await restoring.value
                    do {
                        let again = try await center.service.delete(deletion.item)
                        center.registerUndo(again, undoManager: undoManager)
                    } catch {
                        Self.log.error("Deleting again failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            undoManager.setActionName(name)
        }
        undoManager.setActionName(name)
    }

    /// "Delete Slides", "Delete Lecture", "Delete Recording" (Edit ▸ Undo …).
    static func undoName(_ item: LibraryItem) -> String {
        switch item {
        case .deck: String(localized: "Delete Slides")
        case .lecture: String(localized: "Delete Lecture")
        case .recording: String(localized: "Delete Recording")
        }
    }

    static let log = Log.logger(category: "filing-ui")

    // MARK: - Previews and snapshots

    /// Shows the HUD for `urls` as if they were dragged to `location` (previews and snapshots of
    /// the whole window). `dragExited()` hides it.
    public func previewDrag(_ urls: [URL], at location: CGPoint) async {
        let predictions = await service.predict(urls)
        drag = Drag(location: location, anchor: hudAnchor(for: location), predictions: predictions, targeted: nil, isOverRow: false)
        syncPrediction()
    }

    /// Hides a previewed drag.
    public func endPreviewDrag() {
        dragExited()
    }

    /// Shows a drag prediction without a drag (snapshots, previews, the app's parity screenshots),
    /// with `ghost` drawn as the dragged file under the cursor at `location` (the system draws a
    /// real drag's image). `endPreviewDrag()` hides it.
    public func preview(predictions: [FilingPrediction], at location: CGPoint, targeted: HUDTarget? = nil, ghost: DragGhost? = nil) {
        drag = Drag(location: location, anchor: hudAnchor(for: location), predictions: predictions, targeted: targeted, isOverRow: false)
        previewGhost = ghost
        syncPrediction()
    }

    /// Shows a toast without filing anything (snapshots, previews, the app's parity screenshots);
    /// it stays until dismissed.
    public func preview(toast outcome: FilingOutcome) {
        toasts.append(Toast(outcome: outcome))
    }
}
