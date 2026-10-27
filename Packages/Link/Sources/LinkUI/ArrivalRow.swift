import Link
import StudyUI
import SwiftUI

/// One recording arriving on the Mac: the course dot (when its colour is known: the arrival's
/// course in the Mac's library, else the link's snapshot of it; `Arrival.colorHex`) and the
/// title, a determinate bar, then "212 of 520 MB" in SF Mono 11 secondary.
struct ArrivalRow: View {
    let arrival: Arrival

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if let colorHex = arrival.colorHex {
                    CourseDot(hex: colorHex, size: 8)
                }
                Text(arrival.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            ProgressView(value: Double(min(arrival.stored, arrival.total)), total: Double(max(arrival.total, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(TransferText.bytes(arrival.stored, of: arrival.total))
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
