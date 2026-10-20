import Foundation

// The student's ink (PRD #17, M6; docs/plan-m6.md §3–4): pen and highlighter strokes on a slide
// page (`slide_ink`) or in a sketch inside a note (a `NoteAttachment(kind: .drawing)` blob).

/// Strokes in the drawing's own coordinate space, `width` × `height`, origin top left.
///
/// Slide ink is `slideWidth` (1000) units across and as tall as the page's aspect ratio makes it
/// (`slide(aspectRatio:)`), so it lines up with the slide at any size; a sketch's space is its
/// canvas in points. Stroke widths are in the same units. Never written into a PDF.
///
/// JSON (the `slide_ink.drawing` column; `json()` / `data()`, with sorted keys, for a sketch blob):
/// `{"height":…,"strokes":[…],"width":…}`; a stroke is `{"color","kind","points","width"}` with its
/// points as one flat array `[x0, y0, x1, y1, …]` rounded to 0.1. Missing fields decode to
/// defaults, so `{}` (the column's default) is an empty 16:9 slide drawing.
public struct InkDrawing: Hashable, Sendable, Codable {
    /// The content type of a sketch blob (`NoteAttachment.contentType`).
    public static let contentType = "socrates.ink"

    /// True for a sketch attachment's content type: none, `contentType`, or the one sketches
    /// stored before the app was renamed had (`<prefix>.studyportal.ink`, kept in their rows).
    public static func isInk(contentType type: String?) -> Bool {
        guard let type else { return true }
        return type == contentType || type.hasSuffix(".studyportal.ink")
    }
    /// File extension of a sketch blob in the BlobStore.
    public static let fileExtension = "json"
    /// Width of a slide drawing's coordinate space.
    public static let slideWidth: Double = 1000

    public var width: Double
    public var height: Double
    /// In drawing order (later strokes on top).
    public var strokes: [InkStroke]

    public init(width: Double, height: Double, strokes: [InkStroke] = []) {
        self.width = width
        self.height = height
        self.strokes = strokes
    }

    /// An empty drawing for a slide page of `aspectRatio` (width / height; 16:9 when not positive).
    public static func slide(aspectRatio: Double) -> InkDrawing {
        let ratio = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        return InkDrawing(width: slideWidth, height: (slideWidth / ratio * 10).rounded() / 10)
    }

    public var isEmpty: Bool { strokes.isEmpty }

    /// The drawing without the strokes that pass within `radius` of `point` (the stroke eraser).
    /// A stroke's own half width counts, so a thick highlighter is easier to hit.
    public func erasing(at point: InkPoint, radius: Double) -> InkDrawing {
        var copy = self
        copy.strokes.removeAll { $0.distance(to: point) <= radius + $0.width / 2 }
        return copy
    }

    // MARK: - JSON

    public func data() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    public func json() -> String {
        String(decoding: data(), as: UTF8.self)
    }

    public static func decode(_ data: Data) throws -> InkDrawing {
        try JSONDecoder().decode(InkDrawing.self, from: data)
    }

    public static func decode(_ json: String) throws -> InkDrawing {
        try decode(Data(json.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, strokes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? Self.slideWidth
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? (Self.slideWidth * 9 / 16)
        strokes = try container.decodeIfPresent([InkStroke].self, forKey: .strokes) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(strokes, forKey: .strokes)
    }
}

/// One stroke: a pen line or a highlighter band through `points`.
public struct InkStroke: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// A thin opaque line.
        public static let pen: Self = "pen"
        /// A wide translucent band, drawn under the pen strokes.
        public static let highlighter: Self = "highlighter"
    }

    public var kind: Kind
    public var color: InkColor
    /// In the drawing's units.
    public var width: Double
    public var points: [InkPoint]

    public init(kind: Kind, color: InkColor, width: Double, points: [InkPoint]) {
        self.kind = kind
        self.color = color
        self.width = width
        self.points = points
    }

    /// Distance from `point` to the stroke's polyline (0 on it).
    public func distance(to point: InkPoint) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return first.distance(to: point) }
        var best = Double.infinity
        for index in 1..<points.count {
            best = min(best, point.distance(toSegment: points[index - 1], points[index]))
        }
        return best
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case kind, color, width, points
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .pen
        color = try container.decodeIfPresent(InkColor.self, forKey: .color) ?? .blue
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 3
        let flat = try container.decodeIfPresent([Double].self, forKey: .points) ?? []
        points = stride(from: 0, to: flat.count - 1, by: 2).map { InkPoint(x: flat[$0], y: flat[$0 + 1]) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(color, forKey: .color)
        try container.encode(Self.rounded(width), forKey: .width)
        try container.encode(points.flatMap { [Self.rounded($0.x), Self.rounded($0.y)] }, forKey: .points)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}

/// A stroke's colour as a token (StudyUI maps it to light and dark values): the student's ink is
/// blue, the highlighter yellow. Orange is the professor's and never ink.
public struct InkColor: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let blue: Self = "blue"
    public static let yellow: Self = "yellow"
}

/// A point in a drawing's units.
public struct InkPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: InkPoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }

    /// Distance to the segment `a`–`b`.
    public func distance(toSegment a: InkPoint, _ b: InkPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return distance(to: a) }
        let t = max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / length))
        return distance(to: InkPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
