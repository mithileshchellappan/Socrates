import Foundation

/// One block of a note body, stored as a JSON array in `note.blocks`.
///
/// This is the final format: M1 writes plain `paragraph` / `checklist` blocks with only `text`;
/// the Apple Notes-style editor (M6) adds rich `inlines` (styled runs, slide and time references,
/// inline images and sketches) and attachment blocks without a migration. Rules:
/// - `text` is always the block's plain text (search, previews, simple editors). When `inlines`
///   is set, `text` equals their texts concatenated (inline attachments contribute nothing).
/// - Unknown block or inline types decode as-is and round-trip, so an older build never drops
///   what a newer one wrote; a simple editor shows their `text`.
/// - Encoding omits nil fields and sorts keys, so a plain paragraph is exactly
///   `{"text":"…","type":"paragraph"}` (what live capture's quick notes have written since M0).
public struct NoteBlock: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let paragraph: Self = "paragraph"
        /// `level` 1…3.
        public static let heading: Self = "heading"
        /// Bulleted list item; `level` is the indent (0 = top).
        public static let bullet: Self = "bullet"
        /// Numbered list item; `level` is the indent.
        public static let numbered: Self = "numbered"
        /// Checklist item; `checked`, `level` is the indent.
        public static let checklist: Self = "checklist"
        /// A transcript quote; `source` points at the lecture/recording time, `text` is the quote.
        public static let quote: Self = "quote"
        /// A block image; `attachment`.
        public static let image: Self = "image"
        /// A block sketch (PencilKit/PaperKit drawing); `attachment`.
        public static let drawing: Self = "drawing"
        /// A slide shown as an image; `source` (deck + page), optional `attachment` snapshot.
        public static let slide: Self = "slide"
        public static let divider: Self = "divider"
    }

    public var type: Kind
    public var text: String
    public var level: Int?
    public var checked: Bool?
    /// Rich text runs (M6). Nil for plain blocks.
    public var inlines: [NoteInline]?
    public var attachment: NoteAttachment?
    /// Where the block came from or points to (quote, slide).
    public var source: SourceRef?

    public init(
        type: Kind,
        text: String = "",
        level: Int? = nil,
        checked: Bool? = nil,
        inlines: [NoteInline]? = nil,
        attachment: NoteAttachment? = nil,
        source: SourceRef? = nil
    ) {
        self.type = type
        self.text = text
        self.level = level
        self.checked = checked
        self.inlines = inlines
        self.attachment = attachment
        self.source = source
    }

    public static func paragraph(_ text: String) -> NoteBlock {
        NoteBlock(type: .paragraph, text: text)
    }

    public static func checklist(_ text: String, checked: Bool = false) -> NoteBlock {
        NoteBlock(type: .checklist, text: text, checked: checked)
    }

    /// One paragraph per line, as live capture's quick notes have always been stored. Empty lines
    /// are kept so the text round-trips through `plainText`.
    public static func paragraphs(from text: String) -> [NoteBlock] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { paragraph(String($0)) }
    }

    /// Plain text of `blocks`, one line per block.
    public static func plainText(of blocks: [NoteBlock]) -> String {
        blocks.map(\.text).joined(separator: "\n")
    }

    // MARK: - JSON

    /// Encodes blocks as stored in `note.blocks` (sorted keys, nil fields omitted).
    public static func json(_ blocks: [NoteBlock]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(blocks) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes `note.blocks`. Throws on malformed JSON.
    public static func decode(_ json: String) throws -> [NoteBlock] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([NoteBlock].self, from: Data(json.utf8))
    }
}

/// A run inside a rich block (M6): styled text, a slide or time reference chip, a link, or an
/// inline attachment (an image or sketch inside a paragraph, as in Apple Notes).
public struct NoteInline: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let text: Self = "text"
        /// "S13": `source` (deck + page).
        public static let slideRef: Self = "slide_ref"
        /// "37:59": `source` (lecture/recording + time).
        public static let timeRef: Self = "time_ref"
        /// `url`.
        public static let link: Self = "link"
        /// Inline image or sketch: `attachment`; `text` is empty.
        public static let attachment: Self = "attachment"
    }

    public struct Mark: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let bold: Self = "bold"
        public static let italic: Self = "italic"
        public static let underline: Self = "underline"
        public static let strikethrough: Self = "strikethrough"
        public static let highlight: Self = "highlight"
        public static let code: Self = "code"
    }

    public var type: Kind
    public var text: String
    public var marks: [Mark]?
    public var url: URL?
    public var source: SourceRef?
    public var attachment: NoteAttachment?

    public init(
        type: Kind = .text,
        text: String,
        marks: [Mark]? = nil,
        url: URL? = nil,
        source: SourceRef? = nil,
        attachment: NoteAttachment? = nil
    ) {
        self.type = type
        self.text = text
        self.marks = marks
        self.url = url
        self.source = source
        self.attachment = attachment
    }
}

/// A file shown in a note (image, sketch, slide snapshot). The file lives in the BlobStore.
public struct NoteAttachment: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let image: Self = "image"
        /// PencilKit / PaperKit drawing data.
        public static let drawing: Self = "drawing"
        public static let slide: Self = "slide"
    }

    public var kind: Kind
    public var blobSHA256: String
    /// Relative to the BlobStore root.
    public var blobPath: String
    /// Uniform type identifier, e.g. "public.png", "com.apple.drawing".
    public var contentType: String?
    /// Display size in points.
    public var width: Double?
    public var height: Double?

    public init(
        kind: Kind,
        blobSHA256: String,
        blobPath: String,
        contentType: String? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.kind = kind
        self.blobSHA256 = blobSHA256
        self.blobPath = blobPath
        self.contentType = contentType
        self.width = width
        self.height = height
    }

    public var blob: BlobRef { BlobRef(sha256: blobSHA256, relativePath: blobPath) }
}

extension Note {
    /// The note body. A body that is not valid block JSON reads as one paragraph holding the raw
    /// text, so an editor that saves it back never loses it.
    public var blocks: [NoteBlock] {
        get { (try? NoteBlock.decode(blocksJSON)) ?? [.paragraph(blocksJSON)] }
        set { blocksJSON = NoteBlock.json(newValue) }
    }

    /// Plain text of the body, one line per block (search, previews).
    public var plainText: String { NoteBlock.plainText(of: blocks) }

    /// True when the body has no visible text and no attachments.
    public var isBlank: Bool {
        blocks.allSatisfy { block in
            block.text.allSatisfy(\.isWhitespace) && block.attachment == nil
                && (block.inlines ?? []).allSatisfy { $0.attachment == nil }
        }
    }
}
