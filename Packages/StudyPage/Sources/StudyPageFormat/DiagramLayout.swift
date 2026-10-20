import CoreGraphics
import CoreText
import Foundation

// The diagram's geometry, in pure Swift (docs/plan-learn-more.md §2.4), top-left origin, points:
// - a flowchart that is a tree (one parent each, no cycle): a tidy tree (Walker's rule: each
//   subtree packed against its left siblings by their contours, the parent centred over its
//   children), for parse trees, recursion trees and B-trees;
// - other flowcharts and state diagrams: Sugiyama layers (DFS cycle breaking, longest-path
//   layers, dummy nodes for long edges, 4 barycenter sweeps, balanced coordinates), edges as
//   smooth curves through their dummies;
// - a sequence diagram: participant columns and message rows, lifelines, replies dashed.
// Labels wrap at about 24 characters and are measured with CoreText at the drawn size.

public struct DiagramLayout: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public var lines: [String]
        /// Where the lines are drawn, centred.
        public var rect: CGRect
        public var lineHeight: CGFloat
    }

    public struct Node: Equatable, Sendable {
        public var id: String
        public var shape: Diagram.Shape
        public var rect: CGRect
        public var label: Label
    }

    public struct Edge: Equatable, Sendable {
        /// From the source's border to the target's border; drawn as a smooth curve through them.
        public var points: [CGPoint]
        public var line: Diagram.Line
        public var hasArrow: Bool
        public var label: Label?
    }

    public struct Message: Equatable, Sendable {
        public var fromX: CGFloat
        public var toX: CGFloat
        public var y: CGFloat
        public var style: Diagram.MessageStyle
        /// A message to itself: a loop out to the right this far.
        public var loopWidth: CGFloat?
        public var label: Label
    }

    public struct Note: Equatable, Sendable {
        public var rect: CGRect
        public var label: Label
    }

    public struct Lifeline: Equatable, Sendable {
        public var x: CGFloat
        public var top: CGFloat
        public var bottom: CGFloat
    }

    public var size: CGSize
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var lifelines: [Lifeline] = []
    public var messages: [Message] = []
    public var notes: [Note] = []

    /// Node labels' size; edge, message and note labels are one point smaller.
    public static let nodeFontSize: CGFloat = 12
    public static let edgeFontSize: CGFloat = 11

    public static func layout(_ diagram: Diagram) -> DiagramLayout {
        switch diagram.kind {
        case .sequence: SequenceLayout(diagram).layout()
        case .flowchart, .state: GraphLayout(diagram).layout()
        }
    }

    // MARK: Text

    /// Words wrapped at about `width` characters (a long word stays whole).
    static func wrap(_ text: String, width: Int = 24) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [""] : lines
    }

    /// A label's lines and their size at `fontSize` (system font, CoreText).
    static func label(_ text: String, fontSize: CGFloat, wrapAt: Int = 24) -> (lines: [String], size: CGSize, lineHeight: CGFloat) {
        let lines = wrap(text, width: wrapAt)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) + 1
        var width: CGFloat = 0
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            width = max(width, ceil(CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))) + 2)
        }
        return (lines, CGSize(width: width, height: lineHeight * CGFloat(lines.count)), lineHeight)
    }
}

// MARK: - Graphs (flowchart, state)

struct GraphLayout {
    let diagram: Diagram
    /// The layer axis: down (y) or right (x).
    let alongIsY: Bool

    init(_ diagram: Diagram) {
        self.diagram = diagram
        alongIsY = diagram.direction == .down
    }

    static let nodeGap: CGFloat = 22
    static let layerGap: CGFloat = 34
    static let margin: CGFloat = 2

    func nodeSize(_ node: Diagram.Node) -> (CGSize, DiagramLayout.Label) {
        // Left to right, narrower nodes keep the layers within the column.
        let text = DiagramLayout.label(node.label, fontSize: DiagramLayout.nodeFontSize, wrapAt: alongIsY ? 24 : 16)
        let size: CGSize
        switch node.shape {
        case .start: size = CGSize(width: 14, height: 14)
        case .end: size = CGSize(width: 18, height: 18)
        case .circle:
            let d = max(text.size.width, text.size.height) + 18
            size = CGSize(width: d, height: d)
        case .decision:
            size = CGSize(width: text.size.width + text.size.height + 34, height: text.size.height + 26)
        case .store:
            size = CGSize(width: max(48, text.size.width + 22), height: text.size.height + 22)
        case .box, .rounded:
            size = CGSize(width: max(44, text.size.width + 22), height: text.size.height + 14)
        }
        let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
        let label = DiagramLayout.Label(
            lines: node.shape == .start || node.shape == .end ? [] : text.lines,
            rect: CGRect(origin: .zero, size: text.size), lineHeight: text.lineHeight
        )
        return (rounded, label)
    }

    func layout() -> DiagramLayout {
        let nodes = diagram.nodes
        let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let measured = nodes.map(nodeSize)
        // Sizes along the layer axis and across it.
        let along = measured.map { alongIsY ? $0.0.height : $0.0.width }
        let across = measured.map { alongIsY ? $0.0.width : $0.0.height }
        let links: [(Int, Int, Int)] = diagram.edges.enumerated().compactMap { edgeIndex, edge in
            guard let from = index[edge.from], let to = index[edge.to] else { return nil }
            return (from, to, edgeIndex)
        }
        let edgeLabels: [Int: (lines: [String], size: CGSize, lineHeight: CGFloat)] = Dictionary(
            diagram.edges.enumerated().compactMap { edgeIndex, edge in
                guard let label = edge.label, !label.isEmpty else { return nil }
                return (edgeIndex, DiagramLayout.label(label, fontSize: DiagramLayout.edgeFontSize))
            },
            uniquingKeysWith: { first, _ in first }
        )

        let placement: Placement
        if let tree = Self.tree(count: nodes.count, links: links.filter { $0.0 != $0.1 }) {
            placement = Self.tidyTree(tree, along: along, across: across, labelExtent: { child in
                guard let edge = links.first(where: { $0.1 == child })?.2, let label = edgeLabels[edge] else { return 0 }
                return alongIsY ? label.size.height + 6 : label.size.width + 10
            })
        } else {
            placement = Self.layered(count: nodes.count, links: links, along: along, across: across, labelExtent: { edge in
                guard let label = edgeLabels[edge] else { return 0 }
                return alongIsY ? label.size.height + 6 : label.size.width + 10
            })
        }

        // Map (along, across) centres to x, y.
        func point(_ a: CGFloat, _ c: CGFloat) -> CGPoint {
            alongIsY ? CGPoint(x: c, y: a) : CGPoint(x: a, y: c)
        }
        var result = DiagramLayout(size: .zero)
        var rects: [CGRect] = []
        for (i, node) in nodes.enumerated() {
            let size = measured[i].0
            let center = point(placement.along[i], placement.across[i])
            let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            rects.append(rect)
            var label = measured[i].1
            label.rect = CGRect(
                x: center.x - label.rect.width / 2, y: center.y - label.rect.height / 2 + (node.shape == .store ? 3 : 0),
                width: label.rect.width, height: label.rect.height
            )
            result.nodes.append(DiagramLayout.Node(id: node.id, shape: node.shape, rect: rect, label: label))
        }
        for (from, to, edgeIndex) in links {
            let edge = diagram.edges[edgeIndex]
            var points: [CGPoint]
            if from == to {
                // A loop on the node's far side.
                let rect = rects[from]
                points = alongIsY
                    ? [CGPoint(x: rect.maxX, y: rect.midY - 6), CGPoint(x: rect.maxX + 18, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY + 6)]
                    : [CGPoint(x: rect.midX - 6, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY + 18), CGPoint(x: rect.midX + 6, y: rect.maxY)]
            } else {
                let inner = (placement.bends[edgeIndex] ?? []).map { point($0.along, $0.across) }
                let start = rects[from].center
                let end = rects[to].center
                let firstTarget = inner.first ?? end
                let lastSource = inner.last ?? start
                points = [Self.border(of: rects[from], shape: nodes[from].shape, toward: firstTarget)]
                    + inner
                    + [Self.border(of: rects[to], shape: nodes[to].shape, toward: lastSource)]
            }
            var label: DiagramLayout.Label?
            if let text = edgeLabels[edgeIndex], points.count >= 2 {
                let a = points[0]
                let b = points[1]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                label = DiagramLayout.Label(
                    lines: text.lines,
                    rect: CGRect(x: mid.x - text.size.width / 2, y: mid.y - text.size.height / 2, width: text.size.width, height: text.size.height),
                    lineHeight: text.lineHeight
                )
            }
            result.edges.append(DiagramLayout.Edge(points: points, line: edge.line, hasArrow: edge.hasArrow, label: label))
        }
        // Everything inside the frame, from (margin, margin).
        var bounds = rects.reduce(CGRect.null) { $0.union($1) }
        for edge in result.edges {
            for point in edge.points { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
            if let label = edge.label { bounds = bounds.union(label.rect) }
        }
        guard !bounds.isNull else { return result }
        let dx = Self.margin - bounds.minX
        let dy = Self.margin - bounds.minY
        result.nodes = result.nodes.map { node in
            var node = node
            node.rect = node.rect.offsetBy(dx: dx, dy: dy)
            node.label.rect = node.label.rect.offsetBy(dx: dx, dy: dy)
            return node
        }
        result.edges = result.edges.map { edge in
            var edge = edge
            edge.points = edge.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            if var label = edge.label {
                label.rect = label.rect.offsetBy(dx: dx, dy: dy)
                edge.label = label
            }
            return edge
        }
        result.size = CGSize(width: ceil(bounds.width + 2 * Self.margin), height: ceil(bounds.height + 2 * Self.margin))
        return result
    }

    /// Where the line from the node's centre toward `target` leaves its outline.
    static func border(of rect: CGRect, shape: Diagram.Shape, toward target: CGPoint) -> CGPoint {
        let center = rect.center
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let hw = rect.width / 2
        let hh = rect.height / 2
        let t: CGFloat
        switch shape {
        case .circle, .start, .end:
            let r = min(hw, hh)
            t = r / (dx * dx + dy * dy).squareRoot()
        case .decision:
            t = 1 / (abs(dx) / hw + abs(dy) / hh)
        default:
            t = min(dx == 0 ? .infinity : hw / abs(dx), dy == 0 ? .infinity : hh / abs(dy))
        }
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    // MARK: Placement

    struct Placement {
        /// Node centres: along the layer axis, across it.
        var along: [CGFloat]
        var across: [CGFloat]
        /// Bend points of an edge (by the diagram's edge index), source to target.
        var bends: [Int: [(along: CGFloat, across: CGFloat)]] = [:]
    }

    /// Children per node and the roots, when the links make a forest (one parent each, no cycle).
    static func tree(count: Int, links: [(Int, Int, Int)]) -> (roots: [Int], children: [[Int]])? {
        var parent = [Int?](repeating: nil, count: count)
        var children = [[Int]](repeating: [], count: count)
        for (from, to, _) in links {
            guard parent[to] == nil else { return nil }
            parent[to] = from
            children[from].append(to)
        }
        let roots = (0..<count).filter { parent[$0] == nil }
        guard !roots.isEmpty else { return nil }
        // Reaching every node from the roots means there is no cycle.
        var seen = Set<Int>()
        var stack = roots
        while let node = stack.popLast() {
            guard seen.insert(node).inserted else { return nil }
            stack += children[node]
        }
        guard seen.count == count, links.count >= 1 else { return nil }
        return (roots, children)
    }

    /// A tidy tree: depth along the layer axis, each subtree packed against its left siblings by
    /// contours, the parent centred over its children.
    static func tidyTree(
        _ tree: (roots: [Int], children: [[Int]]), along: [CGFloat], across: [CGFloat], labelExtent: (Int) -> CGFloat
    ) -> Placement {
        let count = along.count
        var depth = [Int](repeating: 0, count: count)
        var order: [Int] = []
        var queue = tree.roots
        while !queue.isEmpty {
            let node = queue.removeFirst()
            order.append(node)
            for child in tree.children[node] {
                depth[child] = depth[node] + 1
                queue.append(child)
            }
        }
        let levels = (depth.max() ?? 0) + 1
        var levelAlong = [CGFloat](repeating: 0, count: levels)
        for node in 0..<count { levelAlong[depth[node]] = max(levelAlong[depth[node]], along[node]) }
        var gapAfter = [CGFloat](repeating: layerGap, count: levels)
        for node in 0..<count where depth[node] > 0 {
            gapAfter[depth[node] - 1] = max(gapAfter[depth[node] - 1], layerGap + labelExtent(node))
        }
        var position = [CGFloat](repeating: 0, count: levels)
        for level in 1..<max(1, levels) {
            position[level] = position[level - 1] + levelAlong[level - 1] / 2 + gapAfter[level - 1] + levelAlong[level] / 2
        }

        /// Relative offsets of each node to its parent, and each subtree's contour per depth
        /// below its root: (left, right) across extents relative to the root's centre.
        var offset = [CGFloat](repeating: 0, count: count)
        func contour(_ node: Int) -> [(CGFloat, CGFloat)] {
            let own = (-across[node] / 2, across[node] / 2)
            let kids = tree.children[node]
            guard !kids.isEmpty else { return [own] }
            var merged: [(CGFloat, CGFloat)] = []
            var placed: [CGFloat] = []
            for kid in kids {
                let shape = contour(kid)
                var shift: CGFloat = 0
                if !merged.isEmpty {
                    for level in 0..<min(merged.count, shape.count) {
                        shift = max(shift, merged[level].1 - shape[level].0 + nodeGap)
                    }
                }
                placed.append(shift)
                for level in 0..<shape.count {
                    let moved = (shape[level].0 + shift, shape[level].1 + shift)
                    if level < merged.count {
                        merged[level] = (min(merged[level].0, moved.0), max(merged[level].1, moved.1))
                    } else {
                        merged.append(moved)
                    }
                }
            }
            let center = ((placed.first ?? 0) + (placed.last ?? 0)) / 2
            for (kid, shift) in zip(kids, placed) { offset[kid] = shift - center }
            return [own] + merged.map { ($0.0 - center, $0.1 - center) }
        }
        var forest: [(CGFloat, CGFloat)] = []
        var rootX = [Int: CGFloat]()
        for root in tree.roots {
            let shape = contour(root)
            var shift: CGFloat = 0
            if !forest.isEmpty {
                for level in 0..<min(forest.count, shape.count) {
                    shift = max(shift, forest[level].1 - shape[level].0 + nodeGap * 1.5)
                }
            }
            rootX[root] = shift
            for level in 0..<shape.count {
                let moved = (shape[level].0 + shift, shape[level].1 + shift)
                if level < forest.count {
                    forest[level] = (min(forest[level].0, moved.0), max(forest[level].1, moved.1))
                } else {
                    forest.append(moved)
                }
            }
        }
        var acrossPosition = [CGFloat](repeating: 0, count: count)
        for node in order {
            if let x = rootX[node] {
                acrossPosition[node] = x
            }
            for child in tree.children[node] {
                acrossPosition[child] = acrossPosition[node] + offset[child]
            }
        }
        return Placement(along: (0..<count).map { position[depth[$0]] }, across: acrossPosition)
    }

    /// Sugiyama layers.
    static func layered(
        count: Int, links: [(Int, Int, Int)], along: [CGFloat], across: [CGFloat], labelExtent: (Int) -> CGFloat
    ) -> Placement {
        // 1. Cycle breaking: edges into a node on the DFS stack are reversed.
        var outgoing = [[(Int, Int)]](repeating: [], count: count)
        for (from, to, edge) in links where from != to { outgoing[from].append((to, edge)) }
        var state = [Int](repeating: 0, count: count) // 0 new, 1 on stack, 2 done
        var reversed = Set<Int>()
        func visit(_ node: Int) {
            state[node] = 1
            for (next, edge) in outgoing[node] {
                if state[next] == 1 {
                    reversed.insert(edge)
                } else if state[next] == 0 {
                    visit(next)
                }
            }
            state[node] = 2
        }
        for node in 0..<count where state[node] == 0 { visit(node) }
        let directed: [(from: Int, to: Int, edge: Int)] = links.compactMap { from, to, edge in
            guard from != to else { return nil }
            return reversed.contains(edge) ? (to, from, edge) : (from, to, edge)
        }

        // 2. Longest-path layers (Kahn's order).
        var indegree = [Int](repeating: 0, count: count)
        var successors = [[Int]](repeating: [], count: count)
        for link in directed {
            indegree[link.to] += 1
            successors[link.from].append(link.to)
        }
        var layer = [Int](repeating: 0, count: count)
        var ready = (0..<count).filter { indegree[$0] == 0 }
        var topological: [Int] = []
        while !ready.isEmpty {
            let node = ready.removeFirst()
            topological.append(node)
            for next in successors[node] {
                layer[next] = max(layer[next], layer[node] + 1)
                indegree[next] -= 1
                if indegree[next] == 0 { ready.append(next) }
            }
        }
        let layerCount = (layer.max() ?? 0) + 1

        // 3. Dummy nodes for edges over more than one layer (ids from `count` on).
        var vertexLayer = layer
        var vertexAlong = along
        var vertexAcross = across
        var chains: [Int: [Int]] = [:]
        var segments: [(Int, Int)] = []
        for link in directed {
            var chain = [link.from]
            var previous = link.from
            if layer[link.to] - layer[link.from] > 1 {
                for level in (layer[link.from] + 1)..<layer[link.to] {
                    let dummy = vertexLayer.count
                    vertexLayer.append(level)
                    vertexAlong.append(0)
                    vertexAcross.append(8)
                    segments.append((previous, dummy))
                    chain.append(dummy)
                    previous = dummy
                }
            }
            segments.append((previous, link.to))
            chain.append(link.to)
            chains[link.edge] = chain
        }
        let vertices = vertexLayer.count
        var up = [[Int]](repeating: [], count: vertices)
        var down = [[Int]](repeating: [], count: vertices)
        for (from, to) in segments {
            down[from].append(to)
            up[to].append(from)
        }

        // 4. Order: first appearance, then 4 barycenter sweeps down and up.
        var layers = [[Int]](repeating: [], count: layerCount)
        var seen = Set<Int>()
        func place(_ vertex: Int) {
            guard seen.insert(vertex).inserted else { return }
            layers[vertexLayer[vertex]].append(vertex)
            for next in down[vertex] { place(next) }
        }
        for node in topological { place(node) }
        for vertex in 0..<vertices where !seen.contains(vertex) { place(vertex) }
        var rank = [Int](repeating: 0, count: vertices)
        func reindex() {
            for row in layers { for (position, vertex) in row.enumerated() { rank[vertex] = position } }
        }
        reindex()
        for _ in 0..<4 {
            for level in 1..<max(1, layerCount) {
                layers[level] = barycenterOrder(layers[level], by: up, rank: rank)
                reindex()
            }
            for level in stride(from: layerCount - 2, through: 0, by: -1) {
                layers[level] = barycenterOrder(layers[level], by: down, rank: rank)
                reindex()
            }
        }

        // 5. Positions along: each layer's thickest node; gaps grow for edge labels.
        var thickness = [CGFloat](repeating: 0, count: layerCount)
        for vertex in 0..<vertices { thickness[vertexLayer[vertex]] = max(thickness[vertexLayer[vertex]], vertexAlong[vertex]) }
        var gapAfter = [CGFloat](repeating: layerGap, count: layerCount)
        for link in directed {
            let extent = labelExtent(link.edge)
            if extent > 0 { gapAfter[layer[link.from]] = max(gapAfter[layer[link.from]], layerGap + extent) }
        }
        var layerPosition = [CGFloat](repeating: 0, count: layerCount)
        for level in 1..<max(1, layerCount) {
            layerPosition[level] = layerPosition[level - 1] + thickness[level - 1] / 2 + gapAfter[level - 1] + thickness[level] / 2
        }

        // 6. Positions across: packed, then balanced toward neighbours (the mean of a left-packed
        //    and a right-packed placement keeps every gap).
        var x = [CGFloat](repeating: 0, count: vertices)
        for row in layers {
            var cursor: CGFloat = 0
            for vertex in row {
                x[vertex] = cursor + vertexAcross[vertex] / 2
                cursor += vertexAcross[vertex] + nodeGap
            }
        }
        func gap(_ a: Int, _ b: Int) -> CGFloat { (vertexAcross[a] + vertexAcross[b]) / 2 + nodeGap }
        func balance(_ row: [Int], neighbours: [[Int]]) {
            guard !row.isEmpty else { return }
            let desired = row.map { vertex -> CGFloat in
                let others = neighbours[vertex]
                guard !others.isEmpty else { return x[vertex] }
                return others.reduce(0) { $0 + x[$1] } / CGFloat(others.count)
            }
            var left = desired
            for i in 1..<row.count { left[i] = max(desired[i], left[i - 1] + gap(row[i - 1], row[i])) }
            var right = desired
            for i in stride(from: row.count - 2, through: 0, by: -1) { right[i] = min(desired[i], right[i + 1] - gap(row[i], row[i + 1])) }
            for i in row.indices { x[row[i]] = (left[i] + right[i]) / 2 }
        }
        for _ in 0..<4 {
            for level in 1..<max(1, layerCount) { balance(layers[level], neighbours: up) }
            for level in stride(from: layerCount - 2, through: 0, by: -1) { balance(layers[level], neighbours: down) }
        }

        var placement = Placement(along: (0..<count).map { layerPosition[layer[$0]] }, across: (0..<count).map { x[$0] })
        for (edge, chain) in chains {
            var bends = chain.dropFirst().dropLast().map { (along: layerPosition[vertexLayer[$0]], across: x[$0]) }
            if reversed.contains(edge) { bends.reverse() }
            placement.bends[edge] = bends
        }
        return placement
    }

    static func barycenterOrder(_ row: [Int], by neighbours: [[Int]], rank: [Int]) -> [Int] {
        let keyed = row.map { vertex -> (Int, Double) in
            let others = neighbours[vertex]
            guard !others.isEmpty else { return (vertex, Double(rank[vertex])) }
            return (vertex, Double(others.reduce(0) { $0 + rank[$1] }) / Double(others.count))
        }
        return keyed.enumerated().sorted { lhs, rhs in
            lhs.element.1 != rhs.element.1 ? lhs.element.1 < rhs.element.1 : lhs.offset < rhs.offset
        }.map(\.element.0)
    }
}

// MARK: - Sequence

struct SequenceLayout {
    let diagram: Diagram

    init(_ diagram: Diagram) {
        self.diagram = diagram
    }

    func layout() -> DiagramLayout {
        let participants = diagram.participants
        let index = Dictionary(participants.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let heads = participants.map { DiagramLayout.label($0.label, fontSize: DiagramLayout.nodeFontSize) }
        let headSizes = heads.map { CGSize(width: max(56, ceil($0.size.width + 24)), height: ceil($0.size.height + 14)) }
        let headHeight = headSizes.map(\.height).max() ?? 28

        // Distances between neighbouring columns: the heads, then every label that spans them.
        var gaps = (0..<max(0, participants.count - 1)).map { (headSizes[$0].width + headSizes[$0 + 1].width) / 2 + 28 }
        var leading: CGFloat = 0
        func require(_ from: Int, _ to: Int, _ width: CGFloat) {
            let lo = min(from, to)
            let hi = max(from, to)
            guard hi > lo else { return }
            let current = gaps[lo..<hi].reduce(0, +)
            if current < width { gaps[hi - 1] += width - current }
        }
        var measured: [(lines: [String], size: CGSize, lineHeight: CGFloat)] = []
        for item in diagram.items {
            switch item {
            case .message(let from, let to, let text, _):
                let label = DiagramLayout.label(text, fontSize: DiagramLayout.edgeFontSize)
                measured.append(label)
                guard let a = index[from], let b = index[to] else { continue }
                if a == b {
                    if a < participants.count - 1 { require(a, a + 1, label.size.width + 34) }
                } else {
                    require(a, b, label.size.width + 24)
                }
            case .note(let over, let placement, let text):
                let label = DiagramLayout.label(text, fontSize: DiagramLayout.edgeFontSize)
                measured.append(label)
                let width = label.size.width + 16
                let ids = over.compactMap { index[$0] }
                guard let first = ids.min(), let last = ids.max() else { continue }
                switch placement {
                case .over:
                    if first == last {
                        if first > 0 { require(first - 1, first, width / 2 + headSizes[first - 1].width / 2 + 8) } else { leading = max(leading, width / 2) }
                        if first < participants.count - 1 { require(first, first + 1, width / 2 + headSizes[first + 1].width / 2 + 8) }
                    } else {
                        require(first, last, width - 32)
                    }
                case .right:
                    if first < participants.count - 1 { require(first, first + 1, width + 16) }
                case .left:
                    if first > 0 { require(first - 1, first, width + 16) } else { leading = max(leading, width + 8) }
                }
            }
        }

        let firstHalf = (headSizes.first?.width ?? 56) / 2
        var centers: [CGFloat] = [max(firstHalf, leading) + 2]
        for gap in gaps { centers.append((centers.last ?? 0) + gap) }
        var result = DiagramLayout(size: .zero)
        for (i, participant) in participants.enumerated() {
            let size = headSizes[i]
            let rect = CGRect(x: centers[i] - size.width / 2, y: 0, width: size.width, height: headHeight)
            let label = heads[i]
            result.nodes.append(DiagramLayout.Node(
                id: participant.id, shape: .box, rect: rect,
                label: DiagramLayout.Label(
                    lines: label.lines,
                    rect: CGRect(x: rect.midX - label.size.width / 2, y: rect.midY - label.size.height / 2, width: label.size.width, height: label.size.height),
                    lineHeight: label.lineHeight
                )
            ))
        }

        var y = headHeight + 12
        for (item, label) in zip(diagram.items, measured) {
            switch item {
            case .message(let from, let to, _, let style):
                guard let a = index[from], let b = index[to] else { continue }
                let lineY = y + label.size.height + 3
                if a == b {
                    let rect = CGRect(x: centers[a] + 8, y: y, width: label.size.width, height: label.size.height)
                    result.messages.append(DiagramLayout.Message(
                        fromX: centers[a], toX: centers[a], y: lineY, style: style, loopWidth: 22,
                        label: DiagramLayout.Label(lines: label.lines, rect: rect, lineHeight: label.lineHeight)
                    ))
                    y = lineY + 26
                } else {
                    let mid = (centers[a] + centers[b]) / 2
                    let rect = CGRect(x: mid - label.size.width / 2, y: y, width: label.size.width, height: label.size.height)
                    result.messages.append(DiagramLayout.Message(
                        fromX: centers[a], toX: centers[b], y: lineY, style: style, loopWidth: nil,
                        label: DiagramLayout.Label(lines: label.lines, rect: rect, lineHeight: label.lineHeight)
                    ))
                    y = lineY + 12
                }
            case .note(let over, let placement, _):
                let ids = over.compactMap { index[$0] }
                guard let first = ids.min(), let last = ids.max() else { continue }
                let width = label.size.width + 16
                let height = label.size.height + 10
                let rect: CGRect
                switch placement {
                case .over:
                    let left = min(centers[first], centers[last]) - (first == last ? width / 2 : 16)
                    let span = first == last ? width : max(width, centers[last] - centers[first] + 32)
                    rect = CGRect(x: left, y: y, width: span, height: height)
                case .right:
                    rect = CGRect(x: centers[first] + 8, y: y, width: width, height: height)
                case .left:
                    rect = CGRect(x: centers[first] - 8 - width, y: y, width: width, height: height)
                }
                result.notes.append(DiagramLayout.Note(
                    rect: rect,
                    label: DiagramLayout.Label(
                        lines: label.lines,
                        rect: CGRect(x: rect.midX - label.size.width / 2, y: rect.midY - label.size.height / 2, width: label.size.width, height: label.size.height),
                        lineHeight: label.lineHeight
                    )
                ))
                y += height + 10
            }
        }
        let bottom = y + 4
        result.lifelines = centers.map { DiagramLayout.Lifeline(x: $0, top: headHeight, bottom: bottom) }
        var bounds = result.nodes.reduce(CGRect.null) { $0.union($1.rect) }
        for message in result.messages {
            bounds = bounds.union(message.label.rect)
            if let loop = message.loopWidth { bounds = bounds.union(CGRect(x: message.fromX, y: message.y, width: loop + 2, height: 1)) }
        }
        for note in result.notes { bounds = bounds.union(note.rect) }
        bounds = bounds.union(CGRect(x: 0, y: 0, width: 1, height: bottom))
        let dx = 2 - min(0, bounds.minX)
        if dx != 0 {
            result.nodes = result.nodes.map { node in
                var node = node
                node.rect = node.rect.offsetBy(dx: dx, dy: 0)
                node.label.rect = node.label.rect.offsetBy(dx: dx, dy: 0)
                return node
            }
            result.messages = result.messages.map { message in
                var message = message
                message.fromX += dx
                message.toX += dx
                message.label.rect = message.label.rect.offsetBy(dx: dx, dy: 0)
                return message
            }
            result.notes = result.notes.map { note in
                var note = note
                note.rect = note.rect.offsetBy(dx: dx, dy: 0)
                note.label.rect = note.label.rect.offsetBy(dx: dx, dy: 0)
                return note
            }
            result.lifelines = result.lifelines.map { DiagramLayout.Lifeline(x: $0.x + dx, top: $0.top, bottom: $0.bottom) }
        }
        result.size = CGSize(width: ceil(bounds.maxX + dx + 2), height: ceil(bottom + 2))
        return result
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
