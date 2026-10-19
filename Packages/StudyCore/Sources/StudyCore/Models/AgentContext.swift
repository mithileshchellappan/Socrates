import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The agent panel's contract (ma, docs/plan-agent.md §3–4): what the student sees, passed with each
// message without being asked, and the files they attach.

// MARK: - Context

/// Where the student is and what they see when they send a message to the app agent: the screen,
/// the course, the open mail, the lecture with the slide on screen and the playhead, the calendar's
/// week or day, the search and its selected hits, the selected note or item. The panel builds it
/// from what the screens publish (`.agentContext`, StudyUI); the agent turns it into a `<context>`
/// block when it changed since the previous message. Ids only: the agent resolves names itself.
public struct AgentContext: Hashable, Sendable, Codable {
    /// The screen in the main window.
    public struct Screen: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let today: Self = "today"
        public static let calendar: Self = "calendar"
        public static let mail: Self = "mail"
        public static let notes: Self = "notes"
        public static let search: Self = "search"
        /// One of a course's screens (`courseScreen`).
        public static let course: Self = "course"
        /// A lecture's review.
        public static let lecture: Self = "lecture"
        public static let other: Self = "other"
    }

    public var screen: Screen
    public var courseID: Course.ID?
    /// A course's own screen: "lectures", "slides", "notes", "settings".
    public var courseScreen: String?
    public var lectureID: Lecture.ID?
    /// The recording the player shows (nil: the lecture's first).
    public var recordingID: Recording.ID?
    /// The slide on screen (1-based deck page).
    public var page: Int?
    /// The playhead, seconds on `recordingID`'s clock.
    public var time: Double?
    /// Mail's scope as the sidebar names it: "inbox", "course", "university", "newsletters",
    /// "drafts", "sent".
    public var mailScope: String?
    /// The open message.
    public var mailMessageID: MailMessage.ID?
    /// The open note.
    public var noteID: Note.ID?
    /// The calendar's week on screen (its Monday).
    public var week: CalendarDay?
    /// A selected day.
    public var day: CalendarDay?
    /// The search query (Search, Mail, Notes filter).
    public var query: String?
    /// Search's selected hits (never mail).
    public var selection: [ChatSource]
    /// A selected deadline, exercise, exam, task or event.
    public var itemID: TrackedItem.ID?
    /// A selected session.
    public var sessionID: LectureSession.ID?

    public init(
        screen: Screen,
        courseID: Course.ID? = nil,
        courseScreen: String? = nil,
        lectureID: Lecture.ID? = nil,
        recordingID: Recording.ID? = nil,
        page: Int? = nil,
        time: Double? = nil,
        mailScope: String? = nil,
        mailMessageID: MailMessage.ID? = nil,
        noteID: Note.ID? = nil,
        week: CalendarDay? = nil,
        day: CalendarDay? = nil,
        query: String? = nil,
        selection: [ChatSource] = [],
        itemID: TrackedItem.ID? = nil,
        sessionID: LectureSession.ID? = nil
    ) {
        self.screen = screen
        self.courseID = courseID
        self.courseScreen = courseScreen
        self.lectureID = lectureID
        self.recordingID = recordingID
        self.page = page
        self.time = time
        self.mailScope = mailScope
        self.mailMessageID = mailMessageID
        self.noteID = noteID
        self.week = week
        self.day = day
        self.query = query
        self.selection = selection
        self.itemID = itemID
        self.sessionID = sessionID
    }

    /// Today, nothing selected.
    public static let today = AgentContext(screen: .today)

    /// This context without the playhead (what decides whether the screen changed: the panel's
    /// prompt and the thread's context line ignore the moving playhead).
    public var settled: AgentContext {
        var context = self
        context.time = nil
        return context
    }

    /// Fields set in `other` replace these (a screen's own publication refines what the app knows:
    /// Review adds the slide and playhead to the lecture, Calendar its week).
    public func merging(_ other: AgentContext) -> AgentContext {
        var merged = other
        merged.courseID = other.courseID ?? courseID
        merged.courseScreen = other.courseScreen ?? courseScreen
        merged.lectureID = other.lectureID ?? lectureID
        merged.recordingID = other.recordingID ?? recordingID
        merged.page = other.page ?? page
        merged.time = other.time ?? time
        merged.mailScope = other.mailScope ?? mailScope
        merged.mailMessageID = other.mailMessageID ?? mailMessageID
        merged.noteID = other.noteID ?? noteID
        merged.week = other.week ?? week
        merged.day = other.day ?? day
        merged.query = other.query ?? query
        merged.selection = other.selection.isEmpty ? selection : other.selection
        merged.itemID = other.itemID ?? itemID
        merged.sessionID = other.sessionID ?? sessionID
        return merged
    }
}

/// What one stored user turn of an `app` conversation carried besides its words
/// (`agent_turn.context`, JSON; nil for other turns and kinds): the context it was sent in, the
/// faint line the panel draws when the context changed, and the files attached. The content
/// blocks themselves are in the turn's message, verbatim.
public struct AgentTurnContext: Hashable, Sendable, Codable {
    public var context: AgentContext?
    /// The thread's faint line before this exchange when the context changed: "DC Lecture 2",
    /// "Calendar", "Inbox", "Search", "Today". Written by the agent (names resolved once).
    public var label: String?
    /// The SF Symbol of that line (the screen's sidebar glyph: `waveform`, `calendar`, `tray`, …).
    public var glyph: String?
    /// The files sent with the message, in the student's order (tiles above the bubble).
    public var attachments: [AgentAttachment]

    public init(context: AgentContext? = nil, label: String? = nil, glyph: String? = nil, attachments: [AgentAttachment] = []) {
        self.context = context
        self.label = label
        self.glyph = glyph
        self.attachments = attachments
    }
}

// MARK: - Attachments

/// A file the student gave the agent (drop, paste or the paperclip): an image, a PDF or a text or
/// code file, the kinds Claude Code reads. The original is in the BlobStore; the agent sends it as
/// an image or document content block before the student's words (docs/plan-agent.md §4).
public struct AgentAttachment: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case image
        case pdf
        case text
    }

    public var kind: Kind
    /// The name the student saw ("Uebung01.pdf"; a pasted screenshot "Screenshot.png").
    public var fileName: String
    /// The uniform type identifier ("public.png", "com.adobe.pdf", "public.shell-script").
    public var contentType: String
    public var byteCount: Int
    /// A PDF's pages.
    public var pageCount: Int?
    /// Pixel size of an image.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var blob: BlobRef

    public var id: String { blob.sha256 + "/" + fileName }

    public init(
        kind: Kind,
        fileName: String,
        contentType: String,
        byteCount: Int,
        pageCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        blob: BlobRef
    ) {
        self.kind = kind
        self.fileName = fileName
        self.contentType = contentType
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.blob = blob
    }

    // MARK: Limits

    /// At most this many files per message.
    public static let maximumPerMessage = 5
    /// Images up to this size are accepted (the agent sends them downscaled, long edge ≤ 1,568 px).
    public static let maximumImageBytes = 20 * 1_024 * 1_024
    /// PDFs: at most this size and `maximumPDFPages` pages.
    public static let maximumPDFBytes = 32 * 1_024 * 1_024
    public static let maximumPDFPages = 100
    /// Text and code files (UTF-8).
    public static let maximumTextBytes = 512 * 1_024
    /// The long edge of an image as the agent sends it.
    public static let imageLongEdge = 1_568

    /// Opening of the data block that stands in a user turn for slides the agent filed instead of
    /// sending them whole: `<filed filing="…" change="1a2b3c4d" file="Lecture3.pdf"
    /// placed="DC · L3 · Virtualization">reason</filed>`. The transcript hides it (the attachment
    /// chip and the agent's one-line confirmation show the filing).
    public static let filedBlockOpening = "<filed"

    /// Why a file is refused.
    public enum Refusal: Error, Hashable, Sendable {
        /// Not an image, PDF or text/code file (a ZIP, a Keynote file, audio, video).
        case unsupportedType
        case tooLarge
        case tooManyPages
        /// A text file that is not UTF-8.
        case unreadableText
        /// The PDF cannot be opened.
        case unreadablePDF
    }

    /// The accept rule: images (PNG, JPEG, GIF, WebP, HEIC), PDFs, and text or code (anything that
    /// conforms to `public.text`: plain text, source code, scripts, JSON, XML, YAML, CSV, Markdown).
    /// Everything else is refused (nil): a drop of it gets no ring.
    public static func kind(for type: UTType) -> Kind? {
        if type.conforms(to: .pdf) { return .pdf }
        let images: [UTType] = [.png, .jpeg, .gif, .webP, .heic]
        if images.contains(where: { type.conforms(to: $0) }) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) { return .text }
        return nil
    }

    /// The accept rule for a file name or URL (by its extension).
    public static func kind(forFileName name: String) -> Kind? {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return kind(for: type)
    }

    /// Checks the file at `url` and stores it in the BlobStore: the attachment, or a `Refusal`.
    /// Blocking file I/O: call it off the main actor.
    public static func make(fileAt url: URL, blobs: BlobStore) throws -> AgentAttachment {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try make(data: data, contentType: type, fileName: url.lastPathComponent, blobs: blobs)
    }

    /// Checks pasted or dropped bytes of `contentType` and stores them in the BlobStore.
    public static func make(data: Data, contentType: UTType, fileName: String, blobs: BlobStore) throws -> AgentAttachment {
        guard let kind = kind(for: contentType) else { throw Refusal.unsupportedType }
        var pageCount: Int?
        var width: Int?
        var height: Int?
        switch kind {
        case .image:
            guard data.count <= maximumImageBytes else { throw Refusal.tooLarge }
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                width = properties[kCGImagePropertyPixelWidth] as? Int
                height = properties[kCGImagePropertyPixelHeight] as? Int
            }
        case .pdf:
            guard data.count <= maximumPDFBytes else { throw Refusal.tooLarge }
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
                throw Refusal.unreadablePDF
            }
            guard document.numberOfPages <= maximumPDFPages else { throw Refusal.tooManyPages }
            pageCount = document.numberOfPages
        case .text:
            guard data.count <= maximumTextBytes else { throw Refusal.tooLarge }
            guard String(data: data, encoding: .utf8) != nil else { throw Refusal.unreadableText }
        }
        let ext = contentType.preferredFilenameExtension ?? (fileName as NSString).pathExtension
        let blob = try blobs.put(data, fileExtension: ext)
        return AgentAttachment(
            kind: kind, fileName: fileName, contentType: contentType.identifier, byteCount: data.count,
            pageCount: pageCount, pixelWidth: width, pixelHeight: height, blob: blob
        )
    }
}
