import Filing
import StudyCore
import StudyUI
import SwiftUI

/// The toasts at the bottom right after a drop, newest at the bottom.
struct FilingToastStack: View {
    let center: FilingCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                FilingToastView(
                    toast: toast,
                    undo: { Task { await center.undo(toast.id) } },
                    change: { if let id = toast.outcome.filing?.id { center.presentChange(id) } },
                    choose: { place in Task { await center.move(toast.id, to: place) } },
                    dismiss: { center.dismiss(toast.id) }
                )
                .onHover { center.setHovering(toast.id, $0) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: center.toasts.map(\.id))
    }
}

/// One filed file (mockup 10): file tile, course, "Lecture 1 · Tue 13 Oct", "file · 44:34", and
/// Undo / Change…. A file filed on a guess offers its runner-up; one without a course offers
/// Change… only until it has one.
struct FilingToastView: View {
    let toast: FilingCenter.Toast
    var undo: () -> Void = {}
    var change: () -> Void = {}
    var choose: (FilingPlace) -> Void = { _ in }
    var dismiss: () -> Void = {}
    @State private var isHovering = false

    private var outcome: FilingOutcome { toast.outcome }

    /// Mockup 10's toast width.
    static let width: CGFloat = 424

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileTile(kind: outcome.kind, course: outcome.place?.course, failed: isFailure)
            VStack(alignment: .leading, spacing: 1) {
                // The actions share the first line, so the lines below get the full width.
                HStack(alignment: .center, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    actions
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14))
        .frame(width: Self.width, alignment: .leading)
        .filingGlass()
        .overlay(alignment: .topLeading) {
            if isHovering, !toast.dismissesItself || isFailure {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .accessibilityLabel(Text("Close"))
            }
        }
        .onHover { isHovering = $0 }
        .disabled(toast.isWorking)
        .accessibilityElement(children: .contain)
    }

    private var isFailure: Bool {
        if case .failed = outcome.status { return true }
        return false
    }

    /// The first line: the course, or the file when there is none.
    @ViewBuilder
    private var title: some View {
        if !isFailure, outcome.status != .needsCourse, let place = outcome.place {
            CourseHeader(course: place.course)
        } else {
            Text(outcome.fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome.status {
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .needsCourse:
            if let size = FilingText.size(pageCount: outcome.pageCount, duration: outcome.duration) {
                sizeText(size)
            }
        default:
            if let place = outcome.place, !place.isCourseOnly {
                Text(FilingText.line(place))
                    .font(.body)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
            fileLine
            if outcome.status == .review, let other = outcome.alternatives.first {
                Button { choose(other) } label: {
                    HStack(spacing: 6) {
                        CourseDot(course: other.course, size: 7)
                        Text(Self.alternative(other, besides: outcome.place))
                            .lineLimit(1)
                            .foregroundStyle(.tint)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .padding(.top, 4)
            }
        }
    }

    /// The runner-up in one line: "Lecture 1 · Tue 13 Oct", with the course's short name first
    /// when it is another course ("CL · Lecture 1 · Tue 13 Oct").
    static func alternative(_ place: FilingPlace, besides chosen: FilingPlace?) -> String {
        guard place.course.id != chosen?.course.id else { return FilingText.line(place) }
        let name = place.course.shortName.isEmpty ? place.course.name : place.course.shortName
        return place.isCourseOnly ? place.course.name : "\(name) · \(FilingText.line(place))"
    }

    /// "Recording 6.m4a · 44:34"
    private var fileLine: some View {
        HStack(spacing: 0) {
            Text(outcome.fileName)
                .lineLimit(1)
                .truncationMode(.middle)
            if let size = FilingText.size(pageCount: outcome.pageCount, duration: outcome.duration) {
                Text(verbatim: " · ")
                sizeText(size)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, outcome.place == nil ? 0 : 16)
    }

    private func sizeText(_ text: String) -> some View {
        Text(text)
            .font(outcome.duration != nil ? .system(.callout, design: .monospaced) : .callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch outcome.status {
            case .failed:
                EmptyView()
            case .known:
                Button("Change…", action: change)
            default:
                Button(action: undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                Button("Change…", action: change)
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .fixedSize()
    }
}

/// The 38 pt tile on the toast's left: a slide or audio glyph in the course colour.
struct FileTile: View {
    let kind: FilingKind?
    let course: Course?
    var failed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.background)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(failed ? Color.secondary : course.map { Color.course($0) } ?? .secondary)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if failed { return "exclamationmark.triangle" }
        switch kind {
        case .deck?: return "doc.richtext"
        case .capture?: return "record.circle"
        default: return "waveform"
        }
    }
}
