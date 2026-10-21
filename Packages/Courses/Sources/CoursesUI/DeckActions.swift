import Foundation
import StudyCore
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Opening a deck

/// Where a deck opens: Review of a lecture that uses it, at the first page of that lecture's range
/// (when the deck is the slides Review shows for it; else where review left off).
@MainActor
enum DeckOpening {
    static func open(_ use: DeckUse, with openDestination: OpenDestinationAction) {
        openDestination(.lecture(use.lecture.id, ReviewTarget(page: use.isCurrent ? use.range.firstPage : nil)))
    }

    /// ↩ on a selected deck: its first lecture (in the order the lectures were held), else Quick Look.
    static func openFirst(_ item: CourseDeck, with openDestination: OpenDestinationAction, quickLook: () -> Void) {
        if let use = item.uses.first {
            open(use, with: openDestination)
        } else {
            quickLook()
        }
    }
}

/// A lecture's short name in deck rows and their menus: "Lecture 2", else its title.
enum DeckText {
    static func name(of lecture: Lecture) -> String {
        if let number = lecture.number { return String(localized: "Lecture \(number)") }
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Lecture") : title
    }

    /// "Lecture 2 · slides 1–23".
    static func label(of use: DeckUse) -> String {
        "\(name(of: use.lecture)) · \(use.range.pagesText)"
    }
}

// MARK: - Menus

/// One item per lecture that uses the deck ("Lecture 2 · slides 1–23"), each opening its review.
struct DeckLectureItems: View {
    let item: CourseDeck
    @Environment(\.openDestination) private var openDestination

    var body: some View {
        ForEach(item.uses) { use in
            Button(DeckText.label(of: use)) { DeckOpening.open(use, with: openDestination) }
        }
    }
}

/// A deck's menu: Open in Review (one item per lecture), Quick Look, Show in Finder (Mac),
/// Change… and Delete… (the window confirms, Edit ▸ Undo brings it back).
struct DeckMenu: View {
    let item: CourseDeck
    let change: () -> Void
    let quickLook: () -> Void
    @Environment(\.openDestination) private var openDestination
    @Environment(\.deleteFromLibrary) private var deleteFromLibrary
    @Environment(\.studyServices) private var services

    var body: some View {
        if item.uses.count == 1, let use = item.uses.first {
            Button("Open in Review") { DeckOpening.open(use, with: openDestination) }
        } else if item.uses.count > 1 {
            Menu("Open in Review") { DeckLectureItems(item: item) }
        }
        Button("Quick Look", action: quickLook)
        #if os(macOS)
        Button("Show in Finder") {
            if let services { DeckFiles.showInFinder(item.deck, blobs: services.blobs) }
        }
        .disabled(services == nil || item.deck.blob == nil)
        #endif
        Divider()
        Button("Change…", action: change)
        if let deleteFromLibrary {
            Divider()
            Button("Delete…", role: .destructive) { deleteFromLibrary(.deck(item.deck.id)) }
        }
    }
}

// MARK: - Row style

/// A deck row's press and hover (as the Lectures rows): the faint fill under the whole row.
struct DeckRowButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        DeckRowButtonBody(configuration: configuration)
    }
}

private struct DeckRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : isHovered ? 0.04 : 0))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

// MARK: - The deck's file

/// A deck's PDF as Quick Look and Finder see it (the file in the BlobStore is never changed).
enum DeckFiles {
    /// Where Quick Look opens a deck: a link named as the student's file ("Lecture 2.pdf", so the
    /// panel's title is the name, not the blob's hash) in a temporary folder of its own, removed
    /// again when the panel closes (`removePreview`); the blob itself when no link can be made; nil
    /// when the file is missing.
    static func previewURL(for deck: Deck, blobs: BlobStore) -> URL? {
        guard let blob = deck.blob else { return nil }
        let original = blobs.url(for: blob)
        guard FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) else { return nil }
        var name = (deck.fileName as NSString).lastPathComponent
        if name.isEmpty { name = deck.title }
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return original }
        if (name as NSString).pathExtension.isEmpty, !blob.fileExtension.isEmpty {
            name += ".\(blob.fileExtension)"
        }
        let folder = previewRoot.appending(path: deck.id.uuidString, directoryHint: .isDirectory)
        let link = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            return link
        } catch {
            CoursesUILog.ui.error("Could not link a deck for Quick Look: \(error.localizedDescription, privacy: .private)")
            return original
        }
    }

    /// Removes a preview link made by `previewURL` (never the blob).
    static func removePreview(_ url: URL) {
        guard url.path.hasPrefix(previewRoot.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    #if os(macOS)
    /// Selects the deck's file in a Finder window.
    @MainActor
    static func showInFinder(_ deck: Deck, blobs: BlobStore) {
        guard let blob = deck.blob else { return }
        let url = blobs.url(for: blob)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            CoursesUILog.ui.error("A deck's file is missing from the library")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    private static var previewRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "Socrates Slides", directoryHint: .isDirectory)
    }
}

/// Quick Look of a deck from its rows: the container keeps the URL (`.quickLookPreview`), removes
/// the link of the one it replaces, and Space toggles it.
struct DeckQuickLookState {
    var url: URL?

    mutating func open(_ deck: Deck, services: StudyServices?) {
        guard let services else { return }
        url = DeckFiles.previewURL(for: deck, blobs: services.blobs)
    }

    mutating func toggle(_ deck: Deck, services: StudyServices?) {
        if url != nil {
            url = nil
        } else {
            open(deck, services: services)
        }
    }
}
