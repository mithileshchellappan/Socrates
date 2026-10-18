import StudyCore
import SwiftUI

// Ink (PRD #17, M6; docs/plan-m6.md §3): the student's pen and highlighter strokes drawn as
// vectors over a slide (Review) or in a sketch inside a note (NotesUI). `InkView` only draws;
// `InkCanvas` also takes mouse and trackpad drags as strokes or erasing. The public API is the M6
// contract between the two workstreams; the internals belong to workstream B.

/// Where ink is drawn.
public enum InkSurface: Hashable, Sendable {
    /// Over a slide: white paper whatever the appearance; the highlighter multiplies with it.
    case slide
    /// A sketch on the canvas surface: ink colours follow light and dark.
    case sketch

    /// A new stroke's width in drawing units (slide: of 1000 across; sketch: points).
    public func width(for kind: InkStroke.Kind) -> Double {
        switch self {
        case .slide: kind == .highlighter ? 22 : 3
        case .sketch: kind == .highlighter ? 14 : 1.8
        }
    }
}

/// What a drag does on an `InkCanvas`.
public enum InkTool: Hashable, Sendable {
    case pen
    case highlighter
    /// Removes whole strokes it touches.
    case eraser

    /// The kind and colour of the strokes this tool draws; nil for the eraser.
    public var stroke: (kind: InkStroke.Kind, color: InkColor)? {
        switch self {
        case .pen: (.pen, .blue)
        case .highlighter: (.highlighter, .yellow)
        case .eraser: nil
        }
    }
}

/// A drawing, drawn: vectors scaled to fit the view (aspect fit, centred), never a bitmap.
/// Highlighter strokes go under the pen strokes. Takes no clicks.
public struct InkView: View, Equatable {
    private let drawing: InkDrawing
    private let surface: InkSurface
    @Environment(\.colorScheme) private var colorScheme

    public init(drawing: InkDrawing, surface: InkSurface = .slide) {
        self.drawing = drawing
        self.surface = surface
    }

    public var body: some View {
        let drawing = drawing
        let surface = surface
        let scheme = colorScheme
        ZStack {
            Canvas { context, size in
                InkRenderer.draw(drawing.strokes.filter { $0.kind == .highlighter }, of: drawing, in: context, size: size, surface: surface, scheme: scheme)
            }
            .blendMode(surface == .slide ? .multiply : .normal)
            Canvas { context, size in
                InkRenderer.draw(drawing.strokes.filter { $0.kind != .highlighter }, of: drawing, in: context, size: size, surface: surface, scheme: scheme)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated public static func == (lhs: InkView, rhs: InkView) -> Bool {
        lhs.drawing == rhs.drawing && lhs.surface == rhs.surface
    }
}

/// A drawing the student draws on with the mouse or trackpad.
///
/// - `tool` nil: draws only and lets clicks through (pins and menus under it keep working).
/// - Pen and highlighter: a drag adds one stroke (a click adds a dot); the stroke in progress is
///   drawn on its own layer, so the finished strokes are not redrawn while it grows.
/// - Eraser: a drag removes every stroke it touches (a 7 pt ring under the pointer shows its
///   reach).
/// - While a tool is on the pointer is a crosshair (Mac); a finished stroke is thinned to the
///   points that shape it.
/// - Every stroke and every erase gesture is one undo step on the window's `UndoManager` (⌘Z /
///   ⇧⌘Z); the steps are dropped when the canvas leaves the screen, so give the canvas an `.id`
///   per drawing (per slide page) and an undo never lands on another page.
///
/// The owner persists `drawing` when it changes (strokes, erasing, undo, redo).
public struct InkCanvas: View {
    @Binding private var drawing: InkDrawing
    private let tool: InkTool?
    private let surface: InkSurface
    @Environment(\.undoManager) private var undoManager
    @State private var undoTarget = InkUndoTarget()

    public init(drawing: Binding<InkDrawing>, tool: InkTool?, surface: InkSurface = .slide) {
        _drawing = drawing
        self.tool = tool
        self.surface = surface
    }

    public var body: some View {
        ZStack {
            InkView(drawing: drawing, surface: surface)
                .equatable()
            if let tool {
                InkInput(drawing: $drawing, tool: tool, surface: surface, undoTarget: undoTarget)
            }
        }
        .onDisappear { [undoManager, undoTarget] in
            undoManager?.removeAllActions(withTarget: undoTarget)
        }
    }
}

// MARK: - Input

/// The drag that draws or erases, and the stroke in progress (on its own layer, so the finished
/// strokes are not redrawn while it grows). A crosshair pointer while the tool is on (Mac); the
/// eraser shows its reach as a ring under the pointer.
private struct InkInput: View {
    @Binding var drawing: InkDrawing
    let tool: InkTool
    let surface: InkSurface
    let undoTarget: InkUndoTarget
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var size = CGSize.zero
    /// The stroke in progress, in drawing units.
    @State private var live: [InkPoint] = []
    /// The drawing when the current gesture began.
    @State private var before: InkDrawing?
    /// The eraser's last position in view points (while erasing).
    @State private var lastEraser: CGPoint?
    /// The pointer over the canvas (the eraser's ring).
    @State private var hover: CGPoint?

    /// The eraser's reach in view points.
    private static let eraserRadius: Double = 7
    /// Points closer than this (view points) to the previous one are skipped.
    private static let minimumSpacing: Double = 1
    /// A finished stroke keeps only the points that move it by more than this (view points); the
    /// curve through the midpoints hides the difference.
    private static let simplification: Double = 0.3

    var body: some View {
        let stroke = liveStroke
        let drawing = drawing
        let surface = surface
        let scheme = colorScheme
        let ring = tool == .eraser ? (lastEraser ?? hover) : nil
        Canvas { context, size in
            if let stroke {
                InkRenderer.draw([stroke], of: drawing, in: context, size: size, surface: surface, scheme: scheme)
            }
            if let ring {
                let radius = Self.eraserRadius
                let circle = Path(ellipseIn: CGRect(x: ring.x - radius, y: ring.y - radius, width: radius * 2, height: radius * 2))
                // The slide is white paper in both appearances; a sketch follows the appearance.
                let edge: GraphicsContext.Shading = surface == .slide ? .color(.black.opacity(0.45)) : .style(.secondary)
                context.stroke(circle, with: edge, lineWidth: 1)
            }
        }
        .blendMode(surface == .slide && tool == .highlighter ? .multiply : .normal)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        #if os(macOS)
        .pointerStyle(.rectSelection)
        .onContinuousHover { phase in
            guard tool == .eraser else { return }
            if case .active(let location) = phase { hover = location } else { hover = nil }
        }
        #endif
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { changed(at: $0.location) }
                .onEnded { ended(at: $0.location) }
        )
        .accessibilityHidden(true)
    }

    private var liveStroke: InkStroke? {
        guard let style = tool.stroke, !live.isEmpty else { return nil }
        return InkStroke(kind: style.kind, color: style.color, width: surface.width(for: style.kind), points: live)
    }

    private var frame: InkFrame { InkFrame(drawing: drawing, size: size) }

    private func changed(at location: CGPoint) {
        if before == nil { before = drawing }
        let frame = frame
        if tool == .eraser {
            // Every stroke the ring passed over since the last event, not only where it lands.
            let from = lastEraser ?? location
            let distance = hypot(location.x - from.x, location.y - from.y)
            let steps = max(1, Int((distance / (Self.eraserRadius / 2)).rounded(.up)))
            var erased = drawing
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let point = CGPoint(x: from.x + (location.x - from.x) * t, y: from.y + (location.y - from.y) * t)
                erased = erased.erasing(at: frame.drawingPoint(point), radius: Self.eraserRadius / frame.scale)
            }
            if erased.strokes.count != drawing.strokes.count { drawing = erased }
            lastEraser = location
            return
        }
        let point = frame.drawingPoint(location)
        if let last = live.last, last.distance(to: point) * frame.scale < Self.minimumSpacing { return }
        live.append(point)
    }

    private func ended(at location: CGPoint) {
        defer {
            before = nil
            lastEraser = nil
            live = []
        }
        guard let before else { return }
        if tool == .eraser {
            InkUndo.register(undoManager, target: undoTarget, drawing: $drawing, restoring: before, current: drawing)
            return
        }
        guard var stroke = liveStroke else { return }
        stroke.points = InkSimplifier.simplified(stroke.points, tolerance: Self.simplification / frame.scale)
        // A click is a dot.
        if stroke.points.count == 1 { stroke.points.append(stroke.points[0]) }
        var next = drawing
        next.strokes.append(stroke)
        drawing = next
        InkUndo.register(undoManager, target: undoTarget, drawing: $drawing, restoring: before, current: next)
    }
}

/// Ramer–Douglas–Peucker: the points a polyline needs to stay within `tolerance` of itself, so a
/// slow drag does not store a point per pixel.
enum InkSimplifier {
    static func simplified(_ points: [InkPoint], tolerance: Double) -> [InkPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keeps = [Bool](repeating: false, count: points.count)
        keeps[0] = true
        keeps[points.count - 1] = true
        var ranges = [(first: 0, last: points.count - 1)]
        while let range = ranges.popLast() {
            guard range.last > range.first + 1 else { continue }
            var farthest = range.first
            var distance = 0.0
            for index in (range.first + 1)..<range.last {
                let candidate = points[index].distance(toSegment: points[range.first], points[range.last])
                if candidate > distance {
                    distance = candidate
                    farthest = index
                }
            }
            guard distance > tolerance else { continue }
            keeps[farthest] = true
            ranges.append((range.first, farthest))
            ranges.append((farthest, range.last))
        }
        return points.indices.filter { keeps[$0] }.map { points[$0] }
    }
}

/// The identity a canvas's undo steps are registered with (removed when the canvas leaves).
@MainActor
final class InkUndoTarget {}

enum InkUndo {
    /// One undo step from `current` back to `old`; undoing it registers the redo step.
    @MainActor
    static func register(_ manager: UndoManager?, target: InkUndoTarget, drawing: Binding<InkDrawing>, restoring old: InkDrawing, current: InkDrawing) {
        guard let manager, old != current else { return }
        manager.registerUndo(withTarget: target) { target in
            drawing.wrappedValue = old
            register(manager, target: target, drawing: drawing, restoring: current, current: old)
        }
    }
}

// MARK: - Drawing

/// A drawing's space mapped into a view: aspect fit, centred.
struct InkFrame {
    let scale: Double
    let origin: CGPoint

    init(drawing: InkDrawing, size: CGSize) {
        guard drawing.width > 0, drawing.height > 0, size.width > 0, size.height > 0 else {
            scale = 1
            origin = .zero
            return
        }
        scale = min(size.width / drawing.width, size.height / drawing.height)
        origin = CGPoint(x: (size.width - drawing.width * scale) / 2, y: (size.height - drawing.height * scale) / 2)
    }

    func viewPoint(_ point: InkPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func drawingPoint(_ point: CGPoint) -> InkPoint {
        InkPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
}

enum InkRenderer {
    /// Strokes `strokes` of `drawing` into `context`, smoothed through their points' midpoints.
    static func draw(_ strokes: [InkStroke], of drawing: InkDrawing, in context: GraphicsContext, size: CGSize, surface: InkSurface, scheme: ColorScheme) {
        let frame = InkFrame(drawing: drawing, size: size)
        for stroke in strokes {
            let path = path(stroke.points.map(frame.viewPoint))
            context.stroke(
                path,
                with: .color(color(of: stroke, surface: surface, scheme: scheme)),
                style: StrokeStyle(lineWidth: max(0.5, stroke.width * frame.scale), lineCap: .round, lineJoin: .round)
            )
        }
    }

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points[points.count - 1])
            return path
        }
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// The student's blue (the mockups' `--ink-you`) and the highlighter's yellow (`--ink-hl`).
    static func color(of stroke: InkStroke, surface: InkSurface, scheme: ColorScheme) -> Color {
        let dark = surface == .sketch && scheme == .dark
        let highlighter = stroke.color == .yellow || (stroke.color != .blue && stroke.kind == .highlighter)
        if highlighter {
            return Color.highlighter(dark ? .dark : .light)
        }
        return dark
            ? Color(.sRGB, red: 0x5a / 255, green: 0xa2 / 255, blue: 1, opacity: 1)
            : Color(.sRGB, red: 0x0a / 255, green: 0x5b / 255, blue: 0xd6 / 255, opacity: 1)
    }
}
