import Link
import SwiftUI

/// What the Mac holds of a capture, as one line on the phone's outbox row under its day and
/// stamps (mockup 63; `RecorderScreen`'s delivery slot): while the Mac stores it, a 4 pt
/// determinate bar and "212 of 520 MB" in SF Mono 12.5 secondary (an interrupted copy keeps its
/// last value); once the Mac has it, `checkmark.circle` and "On Mac", 13 secondary; nothing when
/// nothing is known, so the row stays exactly as without a link. No copy explains a Mac out of
/// reach or Local Network turned off: Share stays on the row.
public struct CaptureDeliveryLabel: View {
    let delivery: CaptureDelivery?

    public init(delivery: CaptureDelivery?) {
        self.delivery = delivery
    }

    public var body: some View {
        switch delivery {
        case .sending(let onMac, let total)?:
            HStack(spacing: 8) {
                ProgressView(value: Double(min(onMac, total)), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text(TransferText.bytes(onMac, of: total))
                    .font(.system(size: 12.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 4)
        case .onMac?:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                Text("On Mac")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}
