import CaptureUI
import Link
import SwiftUI

/// The menu bar extra's label (mockup 62a): a monochrome template of the glyph and SF Mono 12.
/// Recording: `circle.fill` "38:22 S10" ("1:38:22" past an hour; "S" + slide, the Dynamic
/// Island's copy); paused: `pause.fill` and the time standing still; not reachable: a hollow
/// `circle` and the last time and slide the phone sent, dimmed, never counted on; arriving:
/// `arrow.down.circle` "212 of 520 MB". One `Text` with the glyph inside (the dot and the pause
/// bars smaller than the digits, as in the mockup), so the menu bar draws it whole.
public struct PhoneRecordingMenuLabel: View {
    let link: PhoneLink

    public init(link: PhoneLink) {
        self.link = link
    }

    public var body: some View {
        Group {
            switch PhoneShown(link).item {
            case .recording(let recording)?:
                let mark = RemoteMark(recording)
                let text = "\(ClockText.string(recording.elapsed(at: link.now))) S\(recording.snapshot.slide)"
                Text("\(Text(Image(systemName: mark.menuGlyph)).font(.system(size: mark == .paused ? 9 : 8))) \(text)")
                    .opacity(mark == .frozen ? 0.42 : 1)
                    .accessibilityLabel(mark == .paused ? Text("Paused") : Text("Recording"))
                    .accessibilityValue(Text(text))
            case .arriving(let stored, let total)?:
                Text("\(Text(Image(systemName: "arrow.down.circle")).font(.system(size: 12))) \(TransferText.bytes(stored, of: total))")
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
    }
}
