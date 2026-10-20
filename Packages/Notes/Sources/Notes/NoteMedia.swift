import Foundation
import ImageIO
import StudyCore
import UniformTypeIdentifiers

/// Media inside a note's text (docs/plan-m6.md §4): images and sketches as BlobStore files, slide
/// clips drawn from the deck's own PDF, professor quotes from the transcript. Every inserted
/// medium is a `NoteInline(.attachment)` inside a paragraph, never a block of its own.
public enum NoteMedia {
    public enum ImportError: Error, Sendable {
        case notAnImage
    }

    /// The widest the document's text gets (DESIGN 3.3: at most 680 pt): an image's display width
    /// never exceeds it.
    public static let maximumDisplayWidth: Double = 680

    // MARK: - Images

    /// Stores the image's original bytes and returns its attachment with a display size: the
    /// pixel size in points (from the image's resolution, 72 dpi when it has none), at most
    /// `maxWidth` wide. Blocking file I/O: call it off the main actor.
    public static func importImage(data: Data, fileExtension: String? = nil, blobs: BlobStore, maxWidth: Double = maximumDisplayWidth) throws -> NoteAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let size = displaySize(source)
        else { throw ImportError.notAnImage }
        let type = CGImageSourceGetType(source).map { $0 as String }
        let ext = fileExtension.flatMap { $0.isEmpty ? nil : $0 }
            ?? type.flatMap { UTType($0)?.preferredFilenameExtension }
            ?? "img"
        let ref = try blobs.put(data, fileExtension: ext)
        let scale = size.width > maxWidth ? maxWidth / size.width : 1
        return NoteAttachment(
            kind: .image, blobSHA256: ref.sha256, blobPath: ref.relativePath, contentType: type,
            width: rounded(size.width * scale), height: rounded(size.height * scale)
        )
    }

    /// An image file dropped or picked (its extension kept).
    public static func importImage(at url: URL, blobs: BlobStore, maxWidth: Double = maximumDisplayWidth) throws -> NoteAttachment {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try importImage(data: data, fileExtension: url.pathExtension, blobs: blobs, maxWidth: maxWidth)
    }

    /// The inline that shows `attachment` in a paragraph.
    public static func inline(_ attachment: NoteAttachment, source: SourceRef? = nil) -> NoteInline {
        NoteInline(type: .attachment, text: "", source: source, attachment: attachment)
    }

    /// The image's size in points, upright (EXIF orientation applied).
    static func displaySize(_ source: CGImageSource) -> (width: Double, height: Double)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let factor = dpi > 0 ? 72 / dpi : 1
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = orientation >= 5 && orientation <= 8
        let width = (rotated ? pixelHeight : pixelWidth) * factor
        let height = (rotated ? pixelWidth : pixelHeight) * factor
        return (width, height)
    }

    // MARK: - Sketches

    /// A new sketch's canvas: as wide as the text allows (at most 480 pt), 200 pt high.
    public static func newSketch(width: Double) -> InkDrawing {
        InkDrawing(width: rounded(min(max(width, 160), 480)), height: 200)
    }

    /// Stores `drawing` as a sketch blob (`InkDrawing.data()`) and returns its attachment, sized as
    /// the drawing. Content-addressed: the same strokes are stored once.
    public static func storeSketch(_ drawing: InkDrawing, blobs: BlobStore) throws -> NoteAttachment {
        let ref = try blobs.put(drawing.data(), fileExtension: InkDrawing.fileExtension)
        return NoteAttachment(
            kind: .drawing, blobSHA256: ref.sha256, blobPath: ref.relativePath, contentType: InkDrawing.contentType,
            width: drawing.width, height: drawing.height
        )
    }

    /// The drawing a sketch attachment stores; nil when the blob is missing or not ink (an older
    /// PencilKit drawing is shown as an empty canvas and kept as it is).
    public static func drawing(of attachment: NoteAttachment, blobs: BlobStore) -> InkDrawing? {
        guard InkDrawing.isInk(contentType: attachment.contentType),
              let data = try? blobs.data(for: attachment.blob)
        else { return nil }
        return try? InkDrawing.decode(data)
    }

    // MARK: - Slides and quotes

    /// A slide clip: page `page` of `deck`, drawn from the deck's own PDF (no copy), `width` pt
    /// wide; the inline's source is the deck and page (and the lecture it was taken from).
    public static func slideClip(deck: Deck, page: Int, lectureID: Lecture.ID?, aspectRatio: Double, width: Double = 256) -> NoteInline {
        let ratio = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        return NoteInline(
            type: .attachment, text: "",
            source: SourceRef(kind: .slide, lectureID: lectureID, deckID: deck.id, pageNumber: page),
            attachment: NoteAttachment(
                kind: .slide, blobSHA256: deck.blobSHA256, blobPath: deck.blobPath, contentType: UTType.pdf.identifier,
                width: width, height: rounded(width / ratio)
            )
        )
    }

    /// A slide chip ("S13") that opens the slide.
    public static func slideRef(deckID: Deck.ID?, page: Int, lectureID: Lecture.ID?) -> NoteInline {
        NoteInline(type: .slideRef, text: "S\(page)", source: SourceRef(kind: .slide, lectureID: lectureID, deckID: deckID, pageNumber: page))
    }

    /// A professor quote: one transcript line with its moment (`source`), as its own block.
    public static func quote(_ segment: TranscriptSegment, lectureID: Lecture.ID?) -> NoteBlock {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return NoteBlock(
            type: .quote, text: text,
            source: SourceRef(kind: .transcript, lectureID: lectureID ?? segment.lectureID, recordingID: segment.recordingID, time: segment.startTime, quote: text)
        )
    }

    static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
