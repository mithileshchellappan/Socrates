import Filing
import StudyCore
import StudyUI
import SwiftUI

/// The toasts at the bottom right after a drop, newest at the bottom.
struct FilingToastStack: View {
    let center: FilingCenter
    /// Each toast's Change… menu, loaded when it shows and after its file moved.
    @State private var sections: [FilingCenter.Toast.ID: [FilingCenter.ChangeSection]] = [:]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                FilingToastView(
                    toast: toast,
                    changeSections: sections[toast.id] ?? [],
                    undo: { Task { await center.undo(toast.id) } },
                    change: { if let id = toast.outcome.filing?.id { center.presentChange(id) } },
                    changeTo: { choice in Task { await center.choose(toast.id, choice) } },
                    choose: { place in Task { await center.move(toast.id, to: place) } },
                    dismiss: { center.dismiss(toast.id) }
                )
                .onHover { center.setHovering(toast.id, $0) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .task(id: toast.outcome.filing) {
                    sections[toast.id] = await center.changeSections(for: toast)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: center.toasts.map(\.id))
        .onChange(of: center.toasts.map(\.id)) { _, ids in
            sections = sections.filter { ids.contains($0.key) }
        }
    }
}

/// One filed file (mockup 10): file tile, course, "Lecture 1 · Tue 13 Oct", "file · 44:34", and
/// Undo / Change…. Change… is a pull-down of places (each course with its lectures and sessions,
/// the current one checked, then New Lecture): no dialog. A file filed on a guess offers its
/// runner-up. A live capture offers Change… only (it was filed after Stop, not dropped).
struct FilingToastView: View {
    let toast: FilingCenter.Toast
    /// The Change… menu; while it is empty (loading, or nothing filed) Change… opens the sheet.
    var changeSections: [FilingCenter.ChangeSection] = []
    var undo: () -> Void = {}
    var change: () -> Void = {}
    var changeTo: (FilingCenter.ChangeChoice) -> Void = { _ in }
    var choose: (FilingPlace) -> Void = { _ in }
    var dismiss: () -> Void = {}
    @State private var isHovering = false

    private var outcome: FilingOutcome { toast.outcome }

    /// The widest a toast gets; it hugs its text up to this (mockup 10: about 420 pt with the
    /// longest course name), and a longer file name is shortened in the middle.
    static let maximumWidth: CGFloat = 444

    var body: some View {
        // Three columns: the tile centred on the text, the text, the actions at its top.
        HStack(alignment: .center, spacing: 12) {
            FileTile(kind: outcome.kind, course: outcome.place?.course, failed: isFailure)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    content
                }
                actions
            }
        }
        .padding(EdgeInsets(top: 13, leading: 12, bottom: 13, trailing: 14))
        .huggingWidth(upTo: Self.maximumWidth)
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
                .font(.body.weight(.semibold))
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
                .padding(.top, 2)
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
            .font(outcome.duration != nil ? FilingFont.inlineMono : .callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch outcome.status {
            case .failed:
                EmptyView()
            case _ where outcome.status == .known || outcome.kind == .capture:
                // A capture was not dropped by the user and its audio exists only here: nothing
                // to undo, only to file elsewhere.
                changeButton
            default:
                Button(action: undo) {
                    UndoLabel()
                }
                .buttonStyle(FilingSmallButtonStyle())
                changeButton
            }
        }
        .fixedSize()
    }

    /// Change…: the menu of places once loaded, else the sheet.
    @ViewBuilder
    private var changeButton: some View {
        if changeSections.isEmpty {
            Button("Change…", action: change)
                .buttonStyle(FilingSmallButtonStyle(isHighlighted: toast.wantsChange))
        } else {
            Menu {
                ForEach(changeSections) { section in
                    Section {
                        Picker(selection: currentChoice) {
                            ForEach(section.places, id: \.destination) { place in
                                Text(FilingText.line(place))
                                    .tag(Optional(FilingCenter.ChangeChoice.place(place.destination)))
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)
                    } header: {
                        Text(section.course.name)
                    }
                }
                if let courseID = outcome.place?.course.id {
                    Divider()
                    Button("New Lecture") { changeTo(.newLecture(courseID)) }
                }
            } label: {
                Text("Change…")
                    .filingSmallButtonChrome(isHighlighted: toast.wantsChange)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The file's lecture, checked in the Change… menu; choosing another moves the file there.
    private var currentChoice: Binding<FilingCenter.ChangeChoice?> {
        Binding(
            get: { outcome.place.map { .place($0.destination) } },
            set: { choice in
                guard let choice, choice != outcome.place.map({ .place($0.destination) }) else { return }
                changeTo(choice)
            }
        )
    }
}

/// The 38 pt tile on the toast's left (mockup 10): the window colour, so it reads inset in the
/// glass, with the file as a document outline in the course colour: a waveform inside for a
/// recording or capture, "PDF" for a deck.
struct FileTile: View {
    let kind: FilingKind?
    let course: Course?
    var failed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(Self.window)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
            .frame(width: 38, height: 38)
            .overlay {
                if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.secondary)
                } else {
                    FileGlyph(content: kind == .deck ? .pdf : .waveform)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(course.map { Color.course($0) } ?? .secondary)
                }
            }
            .accessibilityHidden(true)
    }

    /// The window's own colour, explicitly: darker than the card in dark, so the tile reads inset.
    private static var window: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

/// A document with a folded corner, drawn with a light stroke on a 24-point grid (mockup 10's
/// file glyphs), with waveform bars or "PDF" inside.
struct FileGlyph: View {
    enum Content {
        case waveform
        case pdf
    }

    let content: Content

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let style = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            var outline = Path()
            outline.addLines([point(6, 2.5), point(14.5, 2.5), point(18.5, 6.5), point(18.5, 21.5), point(6, 21.5)])
            outline.closeSubpath()
            outline.addLines([point(14.5, 2.5), point(14.5, 6.5), point(18.5, 6.5)])
            context.stroke(outline, with: .foreground, style: style)
            switch content {
            case .waveform:
                var bars = Path()
                for (x, top, bottom) in [(9.0, 13.0, 15.0), (11, 11, 17), (13, 12, 16), (15, 13, 15)] {
                    bars.move(to: point(x, top))
                    bars.addLine(to: point(x, bottom))
                }
                context.stroke(bars, with: .foreground, style: style)
            case .pdf:
                var label = context.resolve(Text(verbatim: "PDF").font(.system(size: 5.2 * scale, weight: .heavy)))
                label.shading = .foreground
                context.draw(label, at: point(12.2, 15.3), anchor: .center)
            }
        }
    }
}

extension View {
    /// As wide as the view wants up to `maximum` (narrower content keeps its own width; wider
    /// content is offered `maximum` and shortens its text).
    func huggingWidth(upTo maximum: CGFloat) -> some View {
        HuggingWidthLayout(maximum: maximum) { self }
    }
}

struct HuggingWidthLayout: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? maximum, maximum)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
