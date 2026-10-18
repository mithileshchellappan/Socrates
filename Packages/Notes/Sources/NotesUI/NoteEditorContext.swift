import Capture
import Foundation
import ImageIO
import Notes
import Observation
import StudyCore
import StudyUI
import SwiftUI

/// What an editor's attachments need from the screen around them: the library, navigation, the
/// professor's name for quote by-lines, the sketch being edited, and the editor to tell about a
/// change (a sketch's strokes).
@MainActor
@Observable
final class NoteEditorContext {
    let metrics: NoteMetrics
    /// The sketch being drawn on (an attachment's identity), nil when none.
    var editingSketch: ObjectIdentifier?

    @ObservationIgnored var services: StudyServices?
    @ObservationIgnored var open = OpenDestinationAction { _ in }
    @ObservationIgnored var handleLink: ((NoteLink) -> Bool)?
    /// "Prof. Example" for professor quotes.
    @ObservationIgnored var professor: String?
    /// The note's lecture: chips that do not name one open this lecture.
    @ObservationIgnored var lectureID: Lecture.ID?
    @ObservationIgnored var isEditable = true
    /// The student changed something an attachment holds (a sketch).
    @ObservationIgnored var edited: () -> Void = {}

    init(metrics: NoteMetrics) {
        self.metrics = metrics
    }

    /// A chip was clicked: the host first (Review plays its own recording), else navigation.
    func activate(_ link: NoteLink) {
        if handleLink?(link) == true { return }
        switch link {
        case .slide(let source):
            guard let lecture = source.lectureID ?? lectureID else { return }
            open(.lecture(lecture, ReviewTarget(page: source.pageNumber)))
        case .time(let source):
            guard let lecture = source.lectureID ?? lectureID, let time = source.time else { return }
            open(.lecture(lecture, ReviewTarget(time: time, plays: true, recordingID: source.recordingID)))
        }
    }

    func beginEditing(_ sketch: ObjectIdentifier) {
        guard isEditable else { return }
        editingSketch = sketch
    }

    func endEditingSketch() {
        if editingSketch != nil { editingSketch = nil }
    }
}

/// Images drawn at their display size, decoded with ImageIO (never at full resolution), kept for
/// the notes on screen.
@MainActor
enum NoteImageCache {
    private static var images: [String: CGImage] = [:]
    private static var order: [String] = []
    private static let limit = 48

    static func cached(_ key: String) -> CGImage? { images[key] }

    static func image(at url: URL, sha: String, maxPixelSize: Int) async -> CGImage? {
        let key = "\(sha)@\(maxPixelSize)"
        if let image = images[key] { return image }
        guard let image = await downsample(url, maxPixelSize: maxPixelSize) else { return nil }
        images[key] = image
        order.append(key)
        if order.count > limit { images[order.removeFirst()] = nil }
        return image
    }

    @concurrent
    nonisolated private static func downsample(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Slide decks opened for slide clips and the Slide picker, one per PDF.
@MainActor
enum NoteDeckCache {
    private static var decks: [String: SlideDeck] = [:]

    static func cached(sha: String) -> SlideDeck? { decks[sha] }

    static func deck(blob: BlobRef, services: StudyServices) async -> SlideDeck? {
        if let deck = decks[blob.sha256] { return deck }
        let url = services.blobs.url(for: blob)
        let caches = services.paths.caches.appending(path: "Slides", directoryHint: .isDirectory)
        guard let deck = await open(url: url, sha: blob.sha256, caches: caches) else { return nil }
        decks[blob.sha256] = deck
        return deck
    }

    @concurrent
    nonisolated private static func open(url: URL, sha: String, caches: URL) async -> SlideDeck? {
        try? SlideDeck(url: url, sha256: sha, cacheDirectory: caches, memoryBudgetBytes: 24 << 20)
    }
}
