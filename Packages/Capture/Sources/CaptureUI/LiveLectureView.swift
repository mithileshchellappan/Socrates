import Capture
import SwiftUI

/// The line under the slide: which course and lecture this recording is filed under.
public struct LiveLectureContext {
    /// e.g. "Data Centers · Lecture 2 · Virtualization Basics · Tue 13 Oct, 16:15 · Room 101".
    public var title: String
    public var color: Color?
    /// Shows "Change" to fix a wrong match.
    public var onChange: (() -> Void)?
    /// Shows a sidebar button as the toolbar's first item (mockup 02: the window's sidebar is
    /// collapsed). Leave nil when the window has a system sidebar toggle of its own.
    public var onShowSidebar: (() -> Void)?

    public init(
        title: String,
        color: Color? = nil,
        onChange: (() -> Void)? = nil,
        onShowSidebar: (() -> Void)? = nil
    ) {
        self.title = title
        self.color = color
        self.onChange = onChange
        self.onShowSidebar = onShowSidebar
    }
}

/// Live lecture mode: the slide large, the recording in the toolbar, a filmstrip of nearby
/// slides, and an inspector with captions, quick notes and stamps (mockup 02-live).
///
/// Install `LiveLectureCommands` for →, Space, ← and F (disabled while a text field has focus)
/// and `InspectorCommands` to show the inspector again (View ▸ Show Inspector, ⌃⌘I: the Mac
/// toolbar has no inspector button, as in the mockup). The slide also handles Space itself
/// where no menu exists (iPad without a keyboard menu).
/// The session must be owned by the app, not this view: it keeps recording when the view goes
/// away, and the owner files the finished package (`LiveLectureSession.onFinalized`).
public struct LiveLectureView: View {
    let session: LiveLectureSession
    let context: LiveLectureContext?

    @FocusState private var focus: LiveField?
    @State private var isEditingFlag = false
    @State private var showsInspector = true
    @State private var confirmsStop = false
    @State private var slideWidth: CGFloat = 0
    @State private var failure: LiveLectureSession.Failure?
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(session: LiveLectureSession, context: LiveLectureContext? = nil) {
        self.session = session
        self.context = context
    }

    public var body: some View {
        VStack(spacing: 0) {
            canvas
            if let deck = session.deck {
                Hairline()
                FilmstripView(session: session, deck: deck)
            }
        }
        // The canvas colour runs up behind the toolbar's glass, with no toolbar band or hairline.
        .background(Color.liveCanvasBackground, ignoresSafeAreaEdges: .all)
        .toolbar { toolbar }
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .inspector(isPresented: $showsInspector) {
            LiveInspector(session: session, focus: $focus, isEditingFlag: $isEditingFlag)
                .inspectorColumnWidth(min: 280, ideal: 336, max: 440)
        }
        .focusedSceneValue(\.liveLecture, actions)
        .confirmationDialog("Stop recording?", isPresented: $confirmsStop) {
            Button("Stop", role: .destructive) {
                Task { await session.stop() }
            }
        }
        .alert(
            failure.map(Self.title(for:)) ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { failure in
            if failure == .microphoneDenied {
                Button("Open Settings") { openURL(Self.privacySettingsURL) }
            }
            Button("OK", role: .cancel) {}
        } message: { failure in
            if let message = Self.message(for: failure) { Text(message) }
        }
        .onChange(of: session.phase) { _, phase in
            if case .failed(let reason) = phase { failure = reason }
        }
        .onAppear {
            focus = .canvas
            #if os(iOS)
            // A compact width shows the inspector as a sheet; don't open it over the slide.
            if horizontalSizeClass == .compact { showsInspector = false }
            #endif
        }
    }

    // MARK: - Canvas

    /// The slide with the filing line right under it, centred as one group.
    private var canvas: some View {
        VStack(spacing: 10) {
            if let deck = session.deck {
                SlideImageView(deck: deck, page: session.currentPage)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slideWidth = $0 }
            } else {
                ContentUnavailableView {
                    Image(systemName: "waveform")
                }
                .frame(maxHeight: .infinity)
            }
            if let context {
                metaRow(context)
                    .frame(maxWidth: session.deck != nil && slideWidth > 0 ? slideWidth : .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .canvas)
        .onKeyPress(.space) {
            guard session.canGoNext else { return .ignored }
            session.next()
            return .handled
        }
        .onTapGesture { focus = .canvas }
    }

    private func metaRow(_ context: LiveLectureContext) -> some View {
        HStack(spacing: 8) {
            if let color = context.color {
                Circle().fill(color).frame(width: 9, height: 9)
            }
            Text(context.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let onChange = context.onChange {
                Button("Change", action: onChange)
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
        }
        // As tall with or without Change, so the slide does not move.
        .frame(minHeight: 20)
        .font(LiveFont.filingLine)
        .foregroundStyle(.secondary)
    }

    // MARK: - Toolbar

    /// Mac: the slide controls and Stop sit at the trailing edge of the main column, just left
    /// of the inspector. iPhone/iPad: in the navigation bar's trailing group.
    #if os(macOS)
    private static let controlsPlacement = ToolbarItemPlacement.automatic
    /// The recording and the slide position: leading, after the sidebar button and in a capsule
    /// of their own (navigation items share one).
    private static let statusPlacement = ToolbarItemPlacement.primaryAction
    #else
    private static let controlsPlacement = ToolbarItemPlacement.primaryAction
    private static let statusPlacement = ToolbarItemPlacement.navigation
    #endif

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let showSidebar = context?.onShowSidebar {
            ToolbarItem(placement: .navigation) {
                Button(action: showSidebar) {
                    // The main window's toggle: a small glyph in a wide pill (mockups 01, 02).
                    Label {
                        Text("Show Sidebar")
                    } icon: {
                        Image(systemName: "sidebar.left")
                            .imageScale(.small)
                            .frame(width: 43)
                    }
                    .labelStyle(.iconOnly)
                }
                .help("Show Sidebar")
            }
        }
        if session.startedAt != nil, session.phase == .recording || session.phase == .stopping {
            ToolbarItem(placement: Self.statusPlacement) {
                // 12 pt either side inside the glass, as the mockup's capsule.
                RecordingIndicator(session: session)
                    .padding(.horizontal, 6)
            }
        }
        if session.hasDeck {
            ToolbarItem(placement: Self.statusPlacement) {
                slidePosition
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #if os(macOS)
        ToolbarSpacer(.flexible)
        #endif
        ToolbarItemGroup(placement: Self.controlsPlacement) {
            // The mockup's 16 pt glyph boxes: an 8 pt chevron, a 12 pt pennant.
            Button { session.previous() } label: {
                Label {
                    Text("Previous Slide")
                } icon: {
                    Image(systemName: "chevron.left")
                        .imageScale(.small)
                        .fontWeight(.medium)
                }
                .labelStyle(.iconOnly)
            }
            .disabled(!session.canGoPrevious)
            Button { session.next() } label: {
                Label {
                    Text("Next Slide")
                } icon: {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .fontWeight(.medium)
                }
                .labelStyle(.iconOnly)
            }
            .disabled(!session.canGoNext)
            Button { session.flag() } label: {
                Label {
                    Text("Flag")
                        .font(.system(size: 13, weight: .regular))
                } icon: {
                    PennantShape()
                        .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                .labelStyle(.titleAndIcon)
            }
            .disabled(!session.isRecording)
        }
        ToolbarSpacer(.fixed, placement: Self.controlsPlacement)
        ToolbarItem(placement: Self.controlsPlacement) {
            recordButton
        }
        #if os(iOS)
        // No menu bar to reopen it from (the Mac has View ▸ Show Inspector, ⌃⌘I).
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
        #endif
    }

    private var slidePosition: some View {
        Text("Slide \(session.currentPage) \(Text("of \(session.pageCount)").fontWeight(.regular).foregroundStyle(.secondary))")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .fixedSize()
    }

    @ViewBuilder
    private var recordButton: some View {
        switch session.phase {
        case .ready, .starting, .failed:
            Button {
                Task { await session.start() }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!session.canStartRecording)
        case .recording, .paused, .stopping:
            Button {
                confirmsStop = true
            } label: {
                stopLabel(tint: .red)
            }
            .disabled(session.phase == .stopping)
        case .finished:
            Button {} label: {
                stopLabel(tint: .secondary)
            }
            .disabled(true)
        }
    }

    /// A small rounded stop square in a 16 pt box and "Stop" in 13 pt regular (mockup 02). A
    /// shape, not the stop.fill symbol, which the toolbar draws at its own (twice the size) icon
    /// scale. Text and square are tinted each: a tint on the whole label makes the toolbar set the
    /// title semibold.
    private func stopLabel(tint: some ShapeStyle) -> some View {
        Label {
            Text("Stop")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(tint)
        } icon: {
            RoundedRectangle(cornerRadius: 1.75, style: .continuous)
                .fill(tint)
                .frame(width: 7.5, height: 7.5)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: - Commands

    private var actions: LiveLectureActions {
        let session = session
        let isEditing = focus == .note || isEditingFlag
        return LiveLectureActions(
            canGoNext: session.canGoNext,
            canGoPrevious: session.canGoPrevious,
            canFlag: session.isRecording,
            isRecording: session.isRecording,
            canRecord: session.canStartRecording,
            isEditingText: isEditing,
            next: { session.next() },
            previous: { session.previous() },
            flag: { session.flag() },
            toggleRecording: {
                if session.isRecording {
                    confirmsStop = true
                } else {
                    Task { await session.start() }
                }
            }
        )
    }

    // MARK: - Failures

    public static func title(for failure: LiveLectureSession.Failure) -> String {
        switch failure {
        case .notConsented: String(localized: "Recording is off for this course")
        case .microphoneDenied: String(localized: "Microphone access is off")
        case .noInputDevice: String(localized: "No microphone")
        case .storage: String(localized: "Recording stopped")
        case .engine, .inputBusy: String(localized: "Recording couldn’t start")
        }
    }

    public static func message(for failure: LiveLectureSession.Failure) -> String? {
        switch failure {
        case .notConsented, .microphoneDenied, .noInputDevice: nil
        case .inputBusy: String(localized: "The microphone is in use.")
        case .storage(let detail), .engine(let detail): detail
        }
    }

    public static var privacySettingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            ?? URL(filePath: "/System/Applications/System Settings.app")
        #else
        URL(string: "app-settings:") ?? URL(filePath: "/")
        #endif
    }
}
