import DocumentsUI
import Foundation
import StudyCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What Materials takes (docs/plan-materials.md §2.2 "Drop and paste"): PDFs and the bank's
/// other files (`StudyDocument.acceptedTypes`), `.webloc` files (by the URL inside) and web URLs.
/// Here a PDF is always a material, never slides.
enum MaterialDrop {
    /// File ▸ Import… and [Import +].
    static var importTypes: [UTType] {
        var types = StudyDocument.acceptedTypes
        if !types.contains(.pdf) { types.insert(.pdf, at: 0) }
        return types
    }

    static func isPDF(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "pdf"
    }

    static func isWebloc(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "webloc"
    }

    /// A file the screen takes (the ring shows while one hovers).
    @Sendable
    static func isAcceptedFile(_ url: URL) -> Bool {
        isPDF(url) || isWebloc(url) || DocumentFileTypes.isAccepted(url)
    }

    /// A web address the screen takes as a link (http or https; anything but public https is kept
    /// as a card the library never fetches).
    static func isWebURL(_ url: URL) -> Bool {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Dropped or pasted URLs sorted into files to add and links to add (a `.webloc` file by its
    /// URL); anything else is left out.
    static func items(_ urls: [URL]) -> (files: [URL], links: [URL]) {
        var files: [URL] = []
        var links: [URL] = []
        for url in urls {
            if isWebloc(url) {
                if let link = weblocURL(url), isWebURL(link) { links.append(link) }
            } else if url.isFileURL {
                if isAcceptedFile(url) { files.append(url) }
            } else if isWebURL(url) {
                links.append(url)
            }
        }
        return (files, links)
    }

    /// The URL a `.webloc` file holds (its property list's `URL`).
    static func weblocURL(_ file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]), data.count < 64 * 1_024,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = plist["URL"] as? String
        else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Text that is one URL ("github.com/example-org/dc-labs" gets https).
    static func url(inText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), trimmed.count < 2_048 else { return nil }
        if let url = URL(string: trimmed), isWebURL(url), url.host() != nil { return url }
        let candidate = "https://" + trimmed
        guard trimmed.contains("."), let url = URL(string: candidate), let host = url.host(), host.contains(".") else { return nil }
        return url
    }
}

extension View {
    /// The shelf as a drop target: accepted files and web URLs set `isTargeted` while they hover
    /// and are handed to `drop`; a drag with none of them is refused (no ring).
    func materialDropTarget(isEnabled: Bool, isTargeted: Binding<Bool>, drop: @escaping @MainActor ([URL]) -> Void) -> some View {
        modifier(MaterialDropTargetModifier(isEnabled: isEnabled, isTargeted: isTargeted, drop: drop))
    }
}

private struct MaterialDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let drop: @MainActor ([URL]) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onDrop(of: [.fileURL, .url], delegate: MaterialDropDelegate(isEnabled: isEnabled, isTargeted: $isTargeted, drop: drop))
        #else
        content
        #endif
    }
}

#if os(macOS)
/// Reads the drag pasteboard directly (synchronously), so a drag the shelf does not take is
/// refused before it lands.
@MainActor
private struct MaterialDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let drop: @MainActor ([URL]) -> Void

    private var urls: [URL] {
        MaterialPasteboard.urls(NSPasteboard(name: .drag), textURLs: false)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        let items = MaterialDrop.items(urls)
        return !items.files.isEmpty || !items.links.isEmpty
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let urls = urls
        guard isEnabled, validateDrop(info: info) else { return false }
        drop(urls)
        return true
    }
}
#endif

/// The pasteboard as the shelf reads it.
@MainActor
enum MaterialPasteboard {
    #if os(macOS)
    /// File URLs, else web URLs, else (with `textURLs`) text that is one URL.
    static func urls(_ board: NSPasteboard = .general, textURLs: Bool = true) -> [URL] {
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files }
        let links = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).filter { !$0.isFileURL }
        if !links.isEmpty { return links }
        guard textURLs, let text = board.string(forType: .string), let url = MaterialDrop.url(inText: text) else { return [] }
        return [url]
    }
    #endif

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
