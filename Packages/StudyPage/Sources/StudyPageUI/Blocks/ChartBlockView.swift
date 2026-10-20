import Charts
import StudyPageFormat
import SwiftUI

/// A `chart` fence with Swift Charts (docs/plan-learn-more.md §2.3): the title (12.5 semibold),
/// the plot (axes 11 pt mono secondary), a legend when there is more than one series (a colour and
/// a dash or symbol per series: colour is never alone), the caption (12 secondary).
struct ChartBlockView: View {
    let spec: ChartSpec
    let height: CGFloat

    /// Series colours that keep clear of the reserved meanings (DESIGN 3.1).
    static let palette: [Color] = [.indigo, .teal, .pink, .brown, .blue, .mint]

    private var seriesNames: [String] {
        switch spec.kind {
        case .bar:
            var names: [String] = []
            for bar in spec.bars ?? [] where !names.contains(bar.series ?? "") { names.append(bar.series ?? "") }
            return names
        case .function: return (spec.functions ?? []).map(\.name)
        default: return (spec.series ?? []).map(\.name)
        }
    }

    var body: some View {
        let names = seriesNames
        VStack(alignment: .leading, spacing: 6) {
            if let title = spec.title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            plot(names: names)
                .frame(height: height)
            if names.count > 1 {
                legend(names)
            }
            if let caption = spec.caption, !caption.isEmpty {
                Text(verbatim: caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func plot(names: [String]) -> some View {
        let colors = Array(Self.palette.prefix(max(1, names.count)))
        let base = Chart {
            switch spec.kind {
            case .bar:
                ForEach(Array((spec.bars ?? []).enumerated()), id: \.offset) { _, bar in
                    BarMark(
                        x: .value(spec.x?.title ?? "Item", bar.label),
                        y: .value(spec.y?.title ?? "Value", bar.value)
                    )
                    .foregroundStyle(by: .value("Series", bar.series ?? ""))
                    .cornerRadius(3)
                }
            default:
                ForEach(Array(spec.sampled().enumerated()), id: \.offset) { index, series in
                    ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                        switch spec.kind {
                        case .scatter:
                            PointMark(x: .value(spec.x?.title ?? "x", point[0]), y: .value(spec.y?.title ?? "y", point[1]))
                                .foregroundStyle(by: .value("Series", series.name))
                                .symbol(by: .value("Series", series.name))
                        case .area:
                            AreaMark(
                                x: .value(spec.x?.title ?? "x", point[0]), y: .value(spec.y?.title ?? "y", point[1]),
                                series: .value("Series", series.name)
                            )
                            .foregroundStyle(by: .value("Series", series.name))
                            .opacity(0.35)
                        default:
                            LineMark(
                                x: .value(spec.x?.title ?? "x", point[0]), y: .value(spec.y?.title ?? "y", point[1]),
                                series: .value("Series", series.name)
                            )
                            .foregroundStyle(by: .value("Series", series.name))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: index % 2 == 1 ? [6, 4] : []))
                            .interpolationMethod(.linear)
                        }
                    }
                }
            }
            ForEach(Array((spec.marks ?? []).enumerated()), id: \.offset) { _, mark in
                RuleMark(x: .value(spec.x?.title ?? "x", mark.x))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(verbatim: mark.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.09))
                AxisTick().foregroundStyle(Color.primary.opacity(0.25))
                AxisValueLabel().font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.09))
                AxisValueLabel().font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.secondary)
            }
        }
        .chartXAxisLabel {
            if let title = spec.x?.title { Text(verbatim: title).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .chartYAxisLabel {
            if let title = spec.y?.title { Text(verbatim: title).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        if spec.kind != .bar, spec.x?.scale == .log || spec.y?.scale == .log {
            base
                .chartXScale(type: spec.x?.scale == .log ? .log : .linear)
                .chartYScale(type: spec.y?.scale == .log ? .log : .linear)
        } else if spec.kind != .bar, let range = spec.x?.range {
            base.chartXScale(domain: range)
        } else {
            base
        }
    }

    private func legend(_ names: [String]) -> some View {
        HStack(spacing: 16) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 6) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: 18, y: 1))
                    }
                    .stroke(Self.palette[index % Self.palette.count], style: StrokeStyle(lineWidth: 2, dash: index % 2 == 1 ? [4, 3] : []))
                    .frame(width: 18, height: 2)
                    Text(verbatim: name.isEmpty ? " " : name)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
