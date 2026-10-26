import CaptureUI
import Foundation
import Link
import SwiftUI

/// The capsule's content (one `HStack`, SF Mono 12).
struct PhoneCapsuleLabel: View {
    let item: PhoneShown.Item?
    let now: Date

    var body: some View {
        HStack(spacing: 5) {
            switch item {
            case .recording(let recording)?:
                let mark = RemoteMark(recording)
                Image(systemName: "iphone")
                    .imageScale(.small)
                    .foregroundStyle(mark == .frozen ? .secondary : .primary)
                if mark == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                } else {
                    RemoteDot(mark: mark, size: 8)
                }
                Text(ClockText.string(recording.elapsed(at: now)))
                    .foregroundStyle(mark == .recording ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                Text("S\(recording.snapshot.slide)")
                    .foregroundStyle(.secondary)
            case .arriving(let stored, let total)?:
                Image(systemName: "iphone")
                    .imageScale(.small)
                Text(TransferText.bytes(stored, of: total))
                    .foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
    }
}
