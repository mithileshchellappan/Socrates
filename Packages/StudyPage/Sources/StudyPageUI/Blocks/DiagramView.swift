import StudyPageFormat
import StudyUI
import SwiftUI

/// A diagram drawn in one `Canvas` (docs/plan-learn-more.md §2.4): node shapes on the card
/// surface with a 0.5 pt separator, labels 12 pt primary, edges 1 pt secondary with arrowheads,
/// edge labels 11 pt secondary on the page's background, lifelines dashed tertiary, replies dashed.
/// Wider than the column: it scrolls sideways.
///
/// nl (docs/plan-notes-layout.md §3, §11): drawn at `scale` (the content zoom: shapes and labels
/// together, as vectors). With `spreads` (the notes page, where a diagram breaks out to the page's
/// width) a diagram narrower than its line spreads: the gaps between its nodes and lifelines grow
/// up to 1.6 times, the labels keep their size, and what is left is centred. Its height never
/// changes with the width.
struct DiagramView: View {
    /// The most a diagram's gaps grow.
    static let spreadCap: CGFloat = 1.6

    let diagram: Diagram
    let layout: DiagramLayout
    let scale: CGFloat
    let spreads: Bool
    @State private var lineWidth: CGFloat = 0

    init(diagram: Diagram, scale: CGFloat = 1, spreads: Bool = false) {
        self.diagram = diagram
        self.scale = scale
        self.spreads = spreads
        layout = DiagramLayout.layout(diagram)
    }

    var body: some View {
        let drawn = spreadLayout
        Group {
            if spreads {
                ViewThatFits(in: .horizontal) {
                    canvas(drawn)
                        .frame(maxWidth: .infinity)
                    ScrollView(.horizontal) { canvas(drawn) }
                        .scrollIndicators(.automatic)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
            } else {
                ViewThatFits(in: .horizontal) {
                    canvas(drawn)
                    ScrollView(.horizontal) { canvas(drawn) }
                        .scrollIndicators(.automatic)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Diagram"))
        .accessibilityValue(Text(verbatim: diagram.spokenDescription))
    }

    /// The layout spread toward the line's width (in steps of 0.05, so a live resize lays out a
    /// few times, not at every point), or as laid out.
    private var spreadLayout: DiagramLayout {
        let natural = layout.size.width * scale
        guard spreads, natural > 0, lineWidth > natural + 1 else { return layout }
        let factor = min(Self.spreadCap, lineWidth / natural)
        let stepped = (factor * 20).rounded(.down) / 20
        guard stepped > 1 else { return layout }
        return DiagramLayout.layout(diagram, spread: stepped)
    }

    private func canvas(_ layout: DiagramLayout) -> some View {
        DiagramCanvas(layout: layout, scale: scale)
            .frame(width: layout.size.width * scale, height: layout.size.height * scale)
    }
}

struct DiagramCanvas: View {
    let layout: DiagramLayout
    /// Shapes and labels drawn at this scale (vectors: sharp at any zoom).
    var scale: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            let separator = colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)
            let card = colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.965)
            let line = Color.secondary
            // Lifelines first, under everything.
            for lifeline in layout.lifelines {
                var path = Path()
                path.move(to: CGPoint(x: lifeline.x, y: lifeline.top))
                path.addLine(to: CGPoint(x: lifeline.x, y: lifeline.bottom))
                context.stroke(path, with: .style(.tertiary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            // Edges.
            for edge in layout.edges {
                let path = Self.smooth(edge.points)
                let width: CGFloat = edge.line == .thick ? 2 : 1
                let dash: [CGFloat] = edge.line == .dotted ? [3, 3] : []
                context.stroke(path, with: .style(line), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
                if edge.hasArrow, edge.points.count >= 2 {
                    Self.arrowhead(context, from: edge.points[edge.points.count - 2], to: edge.points[edge.points.count - 1], color: line)
                }
            }
            // Nodes.
            for node in layout.nodes {
                let shape = Self.shape(node.shape, in: node.rect)
                switch node.shape {
                case .start:
                    context.fill(shape, with: .style(.primary))
                case .end:
                    context.stroke(shape, with: .style(.primary), lineWidth: 1.2)
                    context.fill(Path(ellipseIn: node.rect.insetBy(dx: 4, dy: 4)), with: .style(.primary))
                default:
                    context.fill(shape, with: .color(card))
                    context.stroke(shape, with: .color(separator), lineWidth: 0.5)
                    if node.shape == .store {
                        var lid = Path()
                        let rect = node.rect
                        lid.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 8))
                        context.stroke(lid, with: .color(separator), lineWidth: 0.5)
                    }
                }
                draw(node.label, size: DiagramLayout.nodeFontSize, color: .primary, in: context)
            }
            // Edge labels on the page's background.
            for edge in layout.edges {
                guard let label = edge.label else { continue }
                context.fill(Path(roundedRect: label.rect.insetBy(dx: -3, dy: -1), cornerRadius: 3), with: .style(.background))
                draw(label, size: DiagramLayout.edgeFontSize, color: .secondary, in: context)
            }
            // Messages.
            for message in layout.messages {
                let dashed: Bool = switch message.style {
                case .reply: true
                case .plain(let dashed): dashed
                default: false
                }
                var path = Path()
                if let loop = message.loopWidth {
                    path.move(to: CGPoint(x: message.fromX, y: message.y))
                    path.addLine(to: CGPoint(x: message.fromX + loop, y: message.y))
                    path.addLine(to: CGPoint(x: message.fromX + loop, y: message.y + 12))
                    path.addLine(to: CGPoint(x: message.fromX + 1, y: message.y + 12))
                } else {
                    path.move(to: CGPoint(x: message.fromX, y: message.y))
                    path.addLine(to: CGPoint(x: message.toX, y: message.y))
                }
                context.stroke(path, with: .style(line), style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [4, 3] : []))
                let end = message.loopWidth == nil ? CGPoint(x: message.toX, y: message.y) : CGPoint(x: message.fromX + 1, y: message.y + 12)
                let start = message.loopWidth == nil ? CGPoint(x: message.fromX, y: message.y) : CGPoint(x: message.fromX + 10, y: message.y + 12)
                switch message.style {
                case .plain:
                    break
                case .lost:
                    var cross = Path()
                    cross.move(to: CGPoint(x: end.x - 4, y: end.y - 4))
                    cross.addLine(to: CGPoint(x: end.x + 4, y: end.y + 4))
                    cross.move(to: CGPoint(x: end.x - 4, y: end.y + 4))
                    cross.addLine(to: CGPoint(x: end.x + 4, y: end.y - 4))
                    context.stroke(cross, with: .style(line), lineWidth: 1.2)
                default:
                    Self.arrowhead(context, from: start, to: end, color: line)
                }
                draw(message.label, size: DiagramLayout.edgeFontSize, color: .secondary, in: context)
            }
            // Notes on the quiet fill.
            for note in layout.notes {
                let shape = Path(roundedRect: note.rect, cornerRadius: 5)
                context.fill(shape, with: .style(QuietFill()))
                draw(note.label, size: DiagramLayout.edgeFontSize, color: .secondary, in: context)
            }
        }
    }

    private func draw(_ label: DiagramLayout.Label, size: CGFloat, color: Color, in context: GraphicsContext) {
        for (index, line) in label.lines.enumerated() {
            let text = context.resolve(Text(verbatim: line).font(.system(size: size)).foregroundStyle(color))
            let y = label.rect.minY + label.lineHeight * (CGFloat(index) + 0.5)
            context.draw(text, at: CGPoint(x: label.rect.midX, y: y), anchor: .center)
        }
    }

    static func shape(_ shape: Diagram.Shape, in rect: CGRect) -> Path {
        switch shape {
        case .box: Path(roundedRect: rect, cornerRadius: 3)
        case .rounded: Path(roundedRect: rect, cornerRadius: min(10, rect.height / 2))
        case .circle, .start, .end: Path(ellipseIn: rect)
        case .store: Path(roundedRect: rect, cornerRadius: 4)
        case .decision:
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.closeSubpath()
            }
        }
    }

    /// A curve through the points (Catmull-Rom as cubic Béziers); straight for two points.
    static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    static func arrowhead(_ context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length: CGFloat = 7
        let spread: CGFloat = .pi / 7
        var head = Path()
        head.move(to: to)
        head.addLine(to: CGPoint(x: to.x - length * cos(angle - spread), y: to.y - length * sin(angle - spread)))
        head.addLine(to: CGPoint(x: to.x - length * cos(angle + spread), y: to.y - length * sin(angle + spread)))
        head.closeSubpath()
        context.fill(head, with: .style(color))
    }
}
