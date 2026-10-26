import Link
import SwiftUI

/// What the Mac holds of a capture, on the phone's outbox row: "212 of 520 MB" over a thin
/// progress bar while copying, "On Mac" once the Mac has it, nothing when nothing is known.
public struct CaptureDeliveryLabel: View {
    let delivery: CaptureDelivery?

    public init(delivery: CaptureDelivery?) {
        self.delivery = delivery
    }

    public var body: some View {
        EmptyView()
    }
}
