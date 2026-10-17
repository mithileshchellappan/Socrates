import Filing
import Foundation
import Observation
import StudyCore

/// The window's smart import state: the drag prediction the HUD shows, the toasts after a drop,
/// the change sheet and the file importer. One per main window; the app owns it next to its
/// `FilingService`.
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

        public init(id: UUID = UUID(), outcome: FilingOutcome) {
            self.id = id
            self.outcome = outcome
        }

        /// Filed for sure (or failed): goes away on its own. Unsure ones wait for the user.
        var dismissesItself: Bool {
            switch outcome.status {
            case .filed, .known, .failed: true
            case .review, .needsCourse: false
            }
        }
    }

    /// Identifies the filing the change sheet edits.
    public struct ChangeRequest: Identifiable, Hashable {
        public let id: Filing.ID
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
    /// Where the importer's files go (nil: wherever smart import puts them).
    @ObservationIgnored var importDestination: FilingDestination?
    /// Called after every drop, import or row drop has been filed (the app takes a second look
    /// at unsure recordings once new slides are in).
    @ObservationIgnored public var didFile: (@MainActor ([FilingOutcome]) -> Void)?

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
        let outcomes = await service.file(urls, to: destination)
        for outcome in outcomes { show(outcome) }
        didFile?(outcomes)
        if openChange, let filing = outcomes.first(where: { $0.filing != nil })?.filing {
            changing = ChangeRequest(id: filing.id)
        }
    }

    func show(_ outcome: FilingOutcome) {
        let toast = Toast(outcome: outcome)
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

    /// Shows a drag prediction without a drag (snapshots, previews, the app's parity screenshots).
    /// `endPreviewDrag()` hides it.
    public func preview(predictions: [FilingPrediction], at location: CGPoint, targeted: HUDTarget? = nil) {
        drag = Drag(location: location, anchor: hudAnchor(for: location), predictions: predictions, targeted: targeted, isOverRow: false)
        syncPrediction()
    }

    /// Shows a toast without filing anything (snapshots, previews, the app's parity screenshots);
    /// it stays until dismissed.
    public func preview(toast outcome: FilingOutcome) {
        toasts.append(Toast(outcome: outcome))
    }
}
