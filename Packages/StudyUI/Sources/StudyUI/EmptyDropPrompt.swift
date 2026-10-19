import StudyCore
import SwiftUI

/// Where imported or dropped files go: a course (smart import picks the lecture) or one lecture.
public enum ImportTarget: Hashable, Sendable {
    case course(Course.ID)
    case lecture(Lecture.ID)
}

/// The app's smart import for a screen: the file importer for a target, or files dropped there.
/// The app installs it (`.environment(\.importFiles, …)`); nil in previews, where screens offer no
/// Import.
public struct ImportFilesAction: Sendable {
    private let openHandler: @MainActor @Sendable (ImportTarget?) -> Void
    private let dropHandler: @MainActor @Sendable ([URL], ImportTarget?) -> Void

    public init(
        open: @escaping @MainActor @Sendable (ImportTarget?) -> Void,
        drop: @escaping @MainActor @Sendable ([URL], ImportTarget?) -> Void
    ) {
        openHandler = open
        dropHandler = drop
    }

    /// Import…: the file importer; its files go to `target` (nil: wherever smart import puts them).
    @MainActor
    public func open(to target: ImportTarget?) {
        openHandler(target)
    }

    /// Files dropped on a screen, filed to `target` (nil: smart import decides).
    @MainActor
    public func drop(_ urls: [URL], to target: ImportTarget?) {
        dropHandler(urls, target)
    }
}

extension EnvironmentValues {
    /// Smart import for the screens (empty Lectures, Slides, Progress, Study, Review's slides).
    @Entry public var importFiles: ImportFilesAction?
}

/// An empty screen that invites the next step (PRD "Empty screens invite the next action"): the
/// screen's glyph, one short line and Import…, over the whole detail; files dropped anywhere on it
/// are filed to `target` (an accent ring while they are over it).
public struct EmptyDropPrompt: View {
    private let systemImage: String
    private let line: LocalizedStringKey
    private let target: ImportTarget?

    @Environment(\.importFiles) private var importFiles

    public init(systemImage: String, line: LocalizedStringKey, target: ImportTarget?) {
        self.systemImage = systemImage
        self.line = line
        self.target = target
    }

    public var body: some View {
        ContentUnavailableView {
            Image(systemName: systemImage)
        } description: {
            Text(line)
        } actions: {
            if let importFiles {
                Button("Import…") { importFiles.open(to: target) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .importDropTarget(target)
    }
}

extension View {
    /// Files dropped anywhere on this view are filed to `target` through the app's smart import
    /// (`\.importFiles`), with an accent ring while they are over it.
    public func importDropTarget(_ target: ImportTarget?) -> some View {
        modifier(ImportDropTargetModifier(target: target))
    }
}

private struct ImportDropTargetModifier: ViewModifier {
    let target: ImportTarget?
    @Environment(\.importFiles) private var importFiles
    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                if isTargeted {
                    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    shape
                        .fill(Color.accentSoft(colorScheme))
                        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let importFiles, !urls.isEmpty else { return false }
                importFiles.drop(urls, to: target)
                return true
            } isTargeted: {
                isTargeted = $0
            }
    }
}
