import Filing
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Smart import on a window: files dropped anywhere are filed on their own, with the
    /// destination HUD while dragging, toasts after the drop (Undo, the Change… menu), the change
    /// sheet (File menu, Course Settings) and the File ▸ Import… panel.
    public func smartImport(_ center: FilingCenter) -> some View {
        modifier(SmartImportModifier(center: center))
    }

    /// Makes a sidebar course, lecture or session row a drop target across its whole width and
    /// height: files dropped on it go exactly there (filed as the user's choice; on a course,
    /// smart import picks the lecture).
    public func filingDropTarget(_ destination: FilingDestination, center: FilingCenter) -> some View {
        modifier(FilingDropTargetModifier(destination: destination, center: center))
    }

    /// Makes the whole sidebar one drop area around its row targets: while files are dragged
    /// over it the window's HUD and predicted row stand down (the window's drag ends at the
    /// sidebar's edge), so only the row under the cursor lights; a drop between rows is filed as
    /// on the window. It keeps no state: moving between rows changes nothing but the lit row.
    public func filingDropZone(_ center: FilingCenter) -> some View {
        onDrop(of: [.fileURL], delegate: SidebarDropZoneDelegate(center: center))
    }
}

enum FilingTypes {
    /// What the importer accepts: slide PDFs, audio and video, captured lectures (packages and
    /// the iPhone's bundles), timetables.
    static var importable: [UTType] {
        [.pdf, .audio, .audiovisualContent] + [lecturePackage, lectureBundle].compactMap(\.self) + timetable
    }

    /// Timetable files (`.ics`), which the timetable import reads (`FilingCenter.timetableDrop`).
    static var timetable: [UTType] {
        [UTType(filenameExtension: "ics"), .calendarEvent].compactMap(\.self)
    }

    static func isTimetable(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "ics"
    }

    /// `.lecture` packages (declared by the app).
    static let lecturePackage = UTType("com.example.studyportal.lecture")
    /// `.lecturebundle` files, one package shared from the iPhone (M7; declared by the app).
    static let lectureBundle = UTType("com.example.studyportal.lecture-bundle")
}

struct SmartImportModifier: ViewModifier {
    @Bindable var center: FilingCenter
    /// What the screen below needs kept free at the bottom (the review player).
    @State private var insets = OverlayInsets()

    func body(content: Content) -> some View {
        content
            .environment(\.overlayInsets, insets)
            .overlay(alignment: .topLeading) {
                // Its own view: a drag's moves redraw the HUD only, never the window under it.
                DragLayer(center: center)
            }
            .overlay(alignment: .bottomTrailing) {
                FilingToastStack(center: center)
                    .padding(16)
                    .padding(.bottom, insets.bottom > 0 ? insets.bottom - 8 : 0)
                    .animation(.smooth(duration: 0.2), value: insets.bottom)
            }
            .coordinateSpace(.named(DropHUD.space))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { center.containerSize = $0 }
            .onDrop(of: [.fileURL], delegate: SmartDropDelegate(center: center))
            .sheet(item: $center.changing) { request in
                ChangeFilingSheet(filingID: request.id, center: center)
            }
            .fileImporter(
                isPresented: $center.isImporterPresented,
                allowedContentTypes: FilingTypes.importable,
                allowsMultipleSelection: true
            ) { result in
                let destination = center.importDestination
                center.importDestination = nil
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                Task { await center.file(urls, to: destination) }
            }
    }
}

/// The drag's HUD and a previewed drag's file over the window. Only the HUD fades in and out:
/// the sidebar and the screen below never animate with it.
private struct DragLayer: View {
    let center: FilingCenter

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A previewed drag's file (screenshots); a real drag's image is the system's.
            if let ghost = center.previewGhost, let drag = center.drag {
                DropGhostPreview(ghost: ghost, location: drag.location)
            }
            if let drag = center.drag, !drag.isOverRow, !drag.predictions.isEmpty {
                DropHUD(predictions: drag.predictions, targeted: drag.targeted) { target, frame in
                    center.hudFrames[target] = frame
                }
                .offset(x: drag.anchor.x, y: drag.anchor.y)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.18), value: center.drag?.predictions.isEmpty)
    }
}

/// Drops on the window: predicts while dragging, files on drop.
@MainActor
struct SmartDropDelegate: DropDelegate {
    let center: FilingCenter

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let providers = info.itemProviders(for: [.fileURL])
        center.dragEntered(at: info.location) { await FileURLs.load(providers) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        center.dragMoved(to: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        center.dragExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        center.dragMoved(to: info.location)
        Task { @MainActor in
            center.dropped(urls: await FileURLs.load(providers))
        }
        return true
    }
}

/// Drops on the sidebar between its rows (`filingDropZone`): filed as on the window.
@MainActor
struct SidebarDropZoneDelegate: DropDelegate {
    let center: FilingCenter

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            center.dropped(urls: await FileURLs.load(providers))
        }
        return true
    }
}

struct FilingDropTargetModifier: ViewModifier {
    let destination: FilingDestination
    let center: FilingCenter
    @State private var isTargeted = false

    /// How far the drop area reaches past the row's content, up and down: half the space between
    /// sidebar rows (the mockups' 29 pt pitch around 21 pt content), so the rows' areas meet and
    /// the lit row never goes dark between two rows or at its own edge.
    static let rowReach: CGFloat = 4

    func body(content: Content) -> some View {
        // Lit under the cursor, and while files dragged over the window's screen would go here.
        let isLit = isTargeted || center.predictedPlace?.isShown(byRowOf: destination) == true
        content
            .environment(\.isFilingTarget, isLit)
            .listRowBackground(isLit ? FilingTargetHighlight() : nil)
            // The whole row is the target, not only its text; the layout stays as it was.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Self.rowReach)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                let destination = destination
                Task { @MainActor in
                    await center.dropped(await FileURLs.load(providers), onRow: destination)
                }
                return true
            }
            .padding(.vertical, -Self.rowReach)
            .onChange(of: isTargeted) { _, targeted in
                center.rowTargeted(targeted)
            }
            // A row that goes while targeted (its session's lecture was just filed) lets go, so
            // the window's next drag shows its HUD.
            .onDisappear {
                if isTargeted { center.rowTargeted(false) }
            }
    }
}

extension EnvironmentValues {
    /// True inside a sidebar row lit as the place dragged files go (`filingDropTarget`): a row
    /// that draws its title in secondary text shows it in the primary colour meanwhile.
    @Entry public var isFilingTarget = false
}

/// A sidebar row lit as the place dropped files go (mockup 10): the accent at 12 % (24 % in
/// dark) with an inset 1.5 pt accent ring, the size and shape of the selection.
struct FilingTargetHighlight: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.12))
            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
            .padding(.horizontal, 10)
    }
}

/// File URLs from drag-and-drop item providers.
enum FileURLs {
    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        return urls
    }
}
