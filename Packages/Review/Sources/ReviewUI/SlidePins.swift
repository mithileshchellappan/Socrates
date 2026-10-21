import Review
import StudyCore
import StudyUI
import SwiftUI

/// The pins on the slide on screen (docs/plan-m4.md §5, mockup 03), drawn in an overlay over the
/// slide's bitmap, which is never re-rendered for them:
/// - the professor's (amber): after the end of the line their `anchor_text` ends on (PDFKit
///   bounds, cached per page), else in the top-right stack; at most 3 at rest;
/// - one AI pin (purple) at the top right when the slide has further reading;
/// - the student's own (accent) where they were put; always shown.
///
/// Pins open their card on hover (Mac) or tap. Context menus: Hide on the professor's and the
/// AI's, Delete Pin on the student's, Add Pin on the slide (at the click point; the new pin's card
/// opens for typing). No pins when the slide is drawn narrower than 320 pt (and never on the
/// rail's thumbnails).
///
/// M6: `ink` (the student's ink canvas) lies between the slide and the pins. With a tool on it
/// takes the clicks and drags on the slide; the pins stay above it with their cards and menus, and
/// Add Pin (on the whole overlay) still works.
struct SlidePins<Ink: View>: View {
    let model: ReviewModel
    let page: Int
    private let ink: Ink

    private let annotationsQuery: FetchAll<Annotation>
    @State private var size: CGSize = .zero
    /// Where each professor item's anchor line ends (missing: the corner).
    @State private var anchors: [Annotation.ID: SlideTextLocator.Point] = [:]
    /// The pointer's last spot on the slide: where Add Pin puts the pin.
    @State private var pointer: CGPoint?

    init(model: ReviewModel, page: Int, @ViewBuilder ink: () -> Ink) {
        self.model = model
        self.page = page
        self.ink = ink()
        annotationsQuery = .studyItems(of: model)
    }

    var body: some View {
        let items = StudyItems(annotationsQuery.wrappedValue)
        let professor = Array(items.professorItems(page: page).prefix(SlidePinLimits.professor))
        let readings = Array(items.furtherReading(page: page).prefix(2))
        let pins = items.pins(page: page)
        let shows = size.width >= SlidePinLimits.minimumWidth
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                #if !os(macOS)
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { pointer = $0.startLocation })
                #endif
            ink
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if shows {
                let corner = cornerPins(readings: readings, professor: professor)
                ForEach(Array(corner.enumerated()), id: \.element) { index, pin in
                    cornerPin(pin, readings: readings, professor: professor)
                        .position(cornerPosition(index))
                }
                ForEach(professor.filter { anchors[$0.id] != nil }) { item in
                    if let point = anchors[item.id] {
                        ProfessorSlidePin(model: model, item: item)
                            .position(anchoredPosition(point))
                    }
                }
                ForEach(pins) { pin in
                    StudentPin(model: model, pin: pin)
                        .position(x: size.width * (pin.anchorX ?? 0.5), y: size.height * (pin.anchorY ?? 0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // On the whole overlay (not only its empty base), so the pointer is tracked and Add Pin
        // works over the ink canvas too; a pin's own menu wins over it.
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointer = location }
        }
        #endif
        .contextMenu {
            if shows {
                Button("Add Pin") { addPin() }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: AnchorRequest(page: page, items: professor.map { AnchorRequest.Item(id: $0.id, text: $0.anchorText) })) {
            await locateAnchors(professor)
        }
    }

    /// The pins of the top-right stack: the AI's first, then the professor's without an anchor
    /// line on this page.
    private enum CornerPin: Hashable {
        case ai
        case professor(Annotation.ID)
    }

    private func cornerPins(readings: [Annotation], professor: [Annotation]) -> [CornerPin] {
        var pins: [CornerPin] = readings.isEmpty ? [] : [.ai]
        pins += professor.filter { anchors[$0.id] == nil }.map { .professor($0.id) }
        return pins
    }

    @ViewBuilder
    private func cornerPin(_ pin: CornerPin, readings: [Annotation], professor: [Annotation]) -> some View {
        switch pin {
        case .ai:
            AnnotationPin(.ai) {
                PinCard {
                    ForEach(readings) { reading in
                        FurtherReadingRow(reading: reading)
                    }
                }
            }
            .contextMenu {
                Button("Hide") { readings.forEach { model.hide($0.id) } }
            }
        case .professor(let id):
            if let item = professor.first(where: { $0.id == id }) {
                ProfessorSlidePin(model: model, item: item)
            }
        }
    }

    /// The stack at the top right (mockup `.pin.top`: 1.4 % of the width from the right edge, 5.6 %
    /// from the top), 24 pt apart.
    private func cornerPosition(_ index: Int) -> CGPoint {
        CGPoint(
            x: size.width - size.width * 0.014 - 10,
            y: size.width * 0.056 + 10 + CGFloat(index) * 24
        )
    }

    /// 8 pt after the end of the anchor's line, centred on it; kept on the slide.
    private func anchoredPosition(_ point: SlideTextLocator.Point) -> CGPoint {
        CGPoint(
            x: min(size.width - 12, size.width * point.x + 18),
            y: min(size.height - 12, max(12, size.height * point.y))
        )
    }

    private func addPin() {
        guard size.width > 0, size.height > 0 else { return }
        let spot = pointer ?? CGPoint(x: size.width / 2, y: size.height / 2)
        model.addPin(page: page, x: spot.x / size.width, y: spot.y / size.height)
    }

    private func locateAnchors(_ items: [Annotation]) async {
        guard let locator = model.slideText else {
            anchors = [:]
            return
        }
        var found: [Annotation.ID: SlideTextLocator.Point] = [:]
        for item in items {
            guard let text = item.anchorText, !text.isEmpty,
                  let point = await locator.endOfLine(of: text, page: page)
            else { continue }
            found[item.id] = point
        }
        guard !Task.isCancelled else { return }
        anchors = found
    }

    private struct AnchorRequest: Hashable {
        struct Item: Hashable {
            var id: Annotation.ID
            var text: String?
        }

        var page: Int
        var items: [Item]
    }
}

enum SlidePinLimits {
    /// No pins on a slide drawn narrower than this.
    static let minimumWidth: CGFloat = 320
    /// The professor's pins at rest per slide.
    static let professor = 3
}

/// The professor's pin on a slide: the quote over the who line; Hide in its menu.
private struct ProfessorSlidePin: View {
    let model: ReviewModel
    let item: Annotation

    var body: some View {
        AnnotationPin(.professor) {
            ProfessorPinCard(model: model, item: item)
        }
        .contextMenu {
            Button("Hide") { model.hide(item.id) }
        }
    }
}

/// The card of a professor item (on the slide and at the end of its transcript line).
struct ProfessorPinCard: View {
    let model: ReviewModel
    let item: Annotation

    var body: some View {
        PinCard {
            PinCardQuote(
                quote: item.body,
                who: model.professorSurname,
                time: model.player == nil ? nil : item.startTime,
                play: { time in model.play(from: time, on: item.recordingID) }
            )
        }
    }
}

/// The student's own pin: its card is their text, editable; saved when the card closes (an empty
/// pin is deleted). A pin just added opens for typing. Delete Pin in its menu.
private struct StudentPin: View {
    let model: ReviewModel
    let pin: Annotation

    @State private var isPresented = false
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        AnnotationPin(.user, isPresented: $isPresented, keepsOpen: isEditing) {
            PinCard {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($isEditing)
                    .accessibilityLabel(Text("Your pin"))
            }
            .onAppear {
                text = pin.body
                if model.newPinID == pin.id { isEditing = true }
            }
            .onDisappear(perform: save)
        }
        .contextMenu {
            Button("Delete Pin") { model.deletePin(pin.id) }
        }
        .onChange(of: isEditing) { _, editing in
            model.isEditingText = editing
        }
        .task(id: model.newPinID) {
            if model.newPinID == pin.id { isPresented = true }
        }
    }

    private func save() {
        if model.newPinID == pin.id { model.newPinID = nil }
        if isEditing {
            isEditing = false
            model.isEditingText = false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != pin.body || trimmed.isEmpty else { return }
        model.savePin(pin.id, body: text)
    }
}
