import SwiftUI

/// The mockups' quiet fill (`--fill`: rgb(120,120,128) at 10 % light, 20 % dark): neutral
/// selection (selected inspector rows, segmented knobs), Calendar's weekend columns. Not
/// `.quaternary`, which is another grey (docs/DESIGN.md §3.1).
public struct QuietFill: ShapeStyle {
    public init() {}

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
            .opacity(environment.colorScheme == .dark ? 0.20 : 0.10)
            .resolve(in: environment)
    }
}

/// A 0.5 pt separator line inside content (`Divider` is twice as heavy: use it between columns).
public struct Hairline: View {
    @Environment(\.pixelLength) private var pixelLength
    private let axis: Axis

    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: axis == .vertical ? max(pixelLength, 0.5) : nil, height: axis == .horizontal ? max(pixelLength, 0.5) : nil)
            .accessibilityHidden(true)
    }
}
