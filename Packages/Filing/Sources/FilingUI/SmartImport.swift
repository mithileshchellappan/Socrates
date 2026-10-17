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

    /// Makes a sidebar lecture or session row a drop target: files dropped on it go exactly
    /// there (filed as the user's choice).
    public func filingDropTarget(_ destination: FilingDestination, center: FilingCenter) -> some View {
        modifier(FilingDropTargetModifier(destination: destination, center: center))
    }
}

enum FilingTypes {
    /// What the importer accepts: slide PDFs, audio and video, captured lectures, timetables.
    static var importable: [UTType] {
        [.pdf, .audio, .audiovisualContent] + (lecturePackage.map { [$0] } ?? []) + timetable
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
}

struct SmartImportModifier: ViewModifier {
    @Bindable var center: FilingCenter
    /// What the screen below needs kept free at the bottom (the review player).
    @State private var insets = OverlayInsets()

    func body(content: Content) -> some View {
        content
            .environment(\.overlayInsets, insets)
            .overlay(alignment: .topLeading) {
                // A previewed drag's file (screenshots); a real drag's image is the system's.
                if let ghost = center.previewGhost, let drag = center.drag {
                    DropGhostPreview(ghost: ghost, location: drag.location)
                }
            }
            .overlay(alignment: .topLeading) {
                if let drag = center.drag, !drag.isOverRow, !drag.predictions.isEmpty {
                    DropHUD(predictions: drag.predictions, targeted: drag.targeted) { target, frame in
                        center.hudFrames[target] = frame
                    }
                    .offset(x: drag.anchor.x, y: drag.anchor.y)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                FilingToastStack(center: center)
                    .padding(16)
                    .padding(.bottom, insets.bottom > 0 ? insets.bottom - 8 : 0)
                    .animation(.smooth(duration: 0.2), value: insets.bottom)
            }
            .animation(.smooth(duration: 0.18), value: center.drag?.predictions.isEmpty)
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

struct FilingDropTargetModifier: ViewModifier {
    let destination: FilingDestination
    let center: FilingCenter
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        // Lit under the cursor, and while files dragged over the window would go here.
        let isLit = isTargeted || center.predictedPlace?.isShown(byRowOf: destination) == true
        content
            .environment(\.isFilingTarget, isLit)
            .listRowBackground(isLit ? FilingTargetHighlight() : nil)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                let destination = destination
                Task { @MainActor in
                    await center.dropped(await FileURLs.load(providers), onRow: destination)
                }
                return true
            }
            .onChange(of: isTargeted) { _, targeted in
                center.rowTargeted(targeted)
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
