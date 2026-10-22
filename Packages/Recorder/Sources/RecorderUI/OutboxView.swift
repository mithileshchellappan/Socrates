import CaptureUI
import Recorder
import StudyUI
import SwiftUI

/// After Stop (and from the recorder's tray button): the finished capture with Share, the one
/// thing to do next, then the other recordings still on the phone, newest first. Each row
/// shares its bundle; Delete… asks first and names the recording.
struct OutboxView: View {
    let recorder: PhoneRecorder
    /// The capture Stop just finished (nil: opened from the tray).
    let finished: PhoneCapture?
    let close: () -> Void

    @State private var deleting: PhoneCapture?

    var body: some View {
        let others = recorder.captures.filter { $0.id != finished?.id }
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Image(systemName: finished == nil ? "chevron.left" : "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .accessibilityLabel(finished == nil ? Text("Back") : Text("Close"))
                Spacer()
            }
            .frame(height: 44)
            .padding(.top, 4)

            List {
                if let finished {
                    Section {
                        CaptureRow(capture: finished, colorHex: recorder.colorHex(of: finished.courseID), isProminent: true)
                            .contextMenu { deleteButton(finished) }
                        ShareLink(item: finished.bundleItem, preview: SharePreview(finished.title)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 12, trailing: 14))
                        .listRowSeparator(.hidden)
                    }
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { capture in
                            HStack(spacing: 4) {
                                CaptureRow(capture: capture, colorHex: recorder.colorHex(of: capture.courseID), isProminent: false)
                                ShareLink(item: capture.bundleItem, preview: SharePreview(capture.title)) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 17))
                                        .frame(width: 44, height: 44)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Share"))
                            }
                            .swipeActions(edge: .trailing) { deleteButton(capture) }
                            .contextMenu { deleteButton(capture) }
                        }
                    }
                }
            }
            .outboxListStyle()
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(
            deleting.map { String(localized: "Delete “\($0.title)”?") } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { capture in
            Button("Delete", role: .destructive) {
                recorder.delete(capture)
            }
        }
    }

    private func deleteButton(_ capture: PhoneCapture) -> some View {
        Button(role: .destructive) {
            deleting = capture
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }
}

/// A capture: course dot, title, then the day and the stamp count; the length in SF Mono.
struct CaptureRow: View {
    let capture: PhoneCapture
    let colorHex: String?
    let isProminent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            CourseDot(hex: colorHex ?? "", size: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.title)
                    .font(.system(size: isProminent ? 17 : 15, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ClockText.string(capture.duration))
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "Tue 13 Oct · 37 stamps".
    private var detail: String {
        let day = capture.startedAt.map { RecorderText.day($0) }
        let stamps = capture.stampCount == 1 ? String(localized: "1 stamp") : String(localized: "\(capture.stampCount) stamps")
        return [day, stamps].compactMap(\.self).joined(separator: " · ")
    }
}

extension View {
    /// Inset grouped on the phone (the Mac build only compiles it).
    fileprivate func outboxListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}
