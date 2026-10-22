#if os(macOS)
import Foundation
import StudyUI

/// One screen kind's arrangement, as the student left it: the columns right of the screen (each a
/// stack of panes, open or closed), their widths and stack heights, which panes are open and which
/// one is maximized. A closed pane keeps its place, so its toggle brings it back where it was and
/// as wide as it was; a column whose panes are all closed takes no room. Stored per kind in
/// UserDefaults (`PaneLayoutStore`), written only when a student's action ends (a divider or
/// header drag, a toggle, Close, Maximize): never during a drag, never for a width a narrow
/// window imposed.
public struct PaneLayout: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable {
        /// Top to bottom.
        public var panes: [PaneID]
        /// The student's width for the column (points).
        public var width: Double
        /// Each pane's share of the column's height (one per entry of `panes`, summing to 1).
        public var heights: [Double]

        public init(panes: [PaneID], width: Double, heights: [Double]? = nil) {
            self.panes = panes
            self.width = width
            self.heights = heights ?? Array(repeating: 1 / Double(max(panes.count, 1)), count: panes.count)
        }
    }

    public static let currentVersion = 1

    public var version: Int
    /// Left to right, after the screen.
    public var columns: [Column]
    /// The kind's open panes. Window-wide panes (`PaneSpec.opensPerWindow`) are not listed: the
    /// host keeps their state for the window.
    public var open: [PaneID]
    public var maximized: PaneID?

    public init(version: Int = PaneLayout.currentVersion, columns: [Column], open: [PaneID], maximized: PaneID? = nil) {
        self.version = version
        self.columns = columns
        self.open = open
        self.maximized = maximized
    }

    /// A kind's first layout: one column per offered pane in toolbar order at its ideal width,
    /// open where the spec says so.
    public static func initial(for specs: [PaneSpec]) -> PaneLayout {
        PaneLayout(
            columns: specs.map { Column(panes: [$0.id], width: Double($0.idealWidth)) },
            open: specs.filter { $0.opensByDefault && !$0.opensPerWindow }.map(\.id)
        )
    }

    /// This layout for `specs`: panes no longer offered leave their stacks (an emptied column goes),
    /// panes not placed yet get a column of their own at the end, widths stay within each column's
    /// panes' limits. A stored layout of another version starts over.
    public func normalized(for specs: [PaneSpec]) -> PaneLayout {
        guard version == Self.currentVersion else { return Self.initial(for: specs) }
        let offered = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var columns: [Column] = []
        var placed = Set<PaneID>()
        for column in self.columns {
            var kept = Column(panes: [], width: column.width, heights: [])
            for (index, id) in column.panes.enumerated() where offered[id] != nil && !placed.contains(id) {
                kept.panes.append(id)
                kept.heights.append(index < column.heights.count ? column.heights[index] : 1)
                placed.insert(id)
            }
            guard !kept.panes.isEmpty else { continue }
            let total = kept.heights.reduce(0, +)
            kept.heights = kept.heights.map { total > 0 ? $0 / total : 1 / Double(kept.heights.count) }
            let lower = kept.panes.compactMap { offered[$0]?.minWidth }.max() ?? PaneSpec.minimumWidth
            let upper = kept.panes.compactMap { offered[$0]?.maxWidth }.min() ?? PaneSpec.maximumWidth
            kept.width = min(max(kept.width, Double(lower)), Double(max(lower, upper)))
            columns.append(kept)
        }
        for spec in specs where !placed.contains(spec.id) {
            columns.append(Column(panes: [spec.id], width: Double(spec.idealWidth)))
        }
        return PaneLayout(
            columns: columns,
            open: open.filter { offered[$0].map { !$0.opensPerWindow } ?? false },
            maximized: maximized.flatMap { offered[$0] == nil ? nil : $0 }
        )
    }

    /// The column holding `id`.
    func columnIndex(of id: PaneID) -> Int? {
        columns.firstIndex { $0.panes.contains(id) }
    }

    /// This layout with `id` dropped at `drop` (a header drag). The pane leaves its column (an
    /// emptied column goes); in a column of its own it keeps the width it had alone, else
    /// `width`. Stacked, it takes half of what the pane above it had of the column's height.
    func moving(_ id: PaneID, to drop: PaneDrop, width: Double) -> PaneLayout {
        var layout = self
        guard let source = layout.columnIndex(of: id) else { return self }
        let wasAlone = layout.columns[source].panes.count == 1
        let aloneWidth = layout.columns[source].width
        layout.columns[source].remove(id)
        if layout.columns[source].panes.isEmpty { layout.columns.remove(at: source) }
        switch drop {
        case .column(let anchor, let after):
            guard anchor != id, let target = layout.columnIndex(of: anchor) else { return self }
            let column = Column(panes: [id], width: wasAlone ? aloneWidth : width)
            layout.columns.insert(column, at: after ? target + 1 : target)
        case .stack(let anchor):
            guard anchor != id, let target = layout.columnIndex(of: anchor),
                  let row = layout.columns[target].panes.firstIndex(of: anchor),
                  row < layout.columns[target].heights.count
            else { return self }
            let half = layout.columns[target].heights[row] / 2
            layout.columns[target].heights[row] = half
            layout.columns[target].panes.insert(id, at: row + 1)
            layout.columns[target].heights.insert(half, at: row + 1)
        }
        return layout
    }
}

extension PaneLayout.Column {
    /// Takes `id` out of the stack; the others share its height.
    mutating func remove(_ id: PaneID) {
        guard let row = panes.firstIndex(of: id) else { return }
        panes.remove(at: row)
        if row < heights.count { heights.remove(at: row) }
        let total = heights.reduce(0, +)
        heights = heights.map { total > 0 ? $0 / total : 1 / Double(heights.count) }
    }
}

/// Reads and writes the layouts: `Socrates.panes.<kind>` (JSON), and the window-wide open panes
/// (`Socrates.panes.windowOpen`).
@MainActor
public enum PaneLayoutStore {
    public static let keyPrefix = "Socrates.panes."
    public static let windowOpenKey = "Socrates.panes.windowOpen"

    public static func load(_ kind: PaneScreenKind, defaults: UserDefaults = .standard) -> PaneLayout? {
        guard let data = defaults.data(forKey: keyPrefix + kind.rawValue) else { return nil }
        do {
            return try JSONDecoder().decode(PaneLayout.self, from: data)
        } catch {
            PanesLog.layout.error("A stored layout could not be read: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public static func save(_ layout: PaneLayout, for kind: PaneScreenKind, defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(layout), forKey: keyPrefix + kind.rawValue)
        } catch {
            PanesLog.layout.error("A layout could not be stored: \(String(describing: error), privacy: .public)")
        }
    }

    public static func loadWindowOpen(defaults: UserDefaults = .standard) -> Set<PaneID> {
        Set((defaults.stringArray(forKey: windowOpenKey) ?? []).map(PaneID.init(rawValue:)))
    }

    public static func saveWindowOpen(_ open: Set<PaneID>, defaults: UserDefaults = .standard) {
        defaults.set(open.map(\.rawValue).sorted(), forKey: windowOpenKey)
    }
}
#endif
