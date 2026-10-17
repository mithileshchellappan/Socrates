import Capture
import SwiftUI

/// The line under the slide: which course and lecture this recording is filed under.
public struct LiveLectureContext {
    /// e.g. "Data Centers · Lecture 2 · Virtualization Basics · Tue 13 Oct, 16:15 · Room 115".
    public var title: String
    public var color: Color?
    /// Shows "Change" to fix a wrong match.
    public var onChange: (() -> Void)?

    public init(title: String, color: Color? = nil, onChange: (() -> Void)? = nil) {
        self.title = title
        self.color = color
        self.onChange = onChange
    }
}

/// Live lecture mode: the slide large, the recording in the toolbar, a filmstrip of nearby
/// slides, and an inspector with captions, quick notes and stamps (mockup 02-live).
///
/// Install `LiveLectureCommands` for →, Space, ← and F (disabled while a text field has focus)
/// and `InspectorCommands` to show the inspector again. The slide also handles Space itself
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
                Divider()
                FilmstripView(session: session, deck: deck)
            }
        }
        .background(.background.secondary)
        .toolbar { toolbar }
        .inspector(isPresented: $showsInspector) {
            LiveInspector(session: session, focus: $focus, isEditingFlag: $isEditingFlag)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
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
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(context.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let onChange = context.onChange {
                Button("Change", action: onChange)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if session.startedAt != nil, session.phase == .recording || session.phase == .stopping {
            ToolbarItem(placement: .navigation) {
                RecordingIndicator(session: session)
            }
        }
        if session.hasDeck {
            ToolbarItem(placement: .navigation) {
                slidePosition
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { session.previous() } label: {
                Label("Previous Slide", systemImage: "chevron.left")
            }
            .disabled(!session.canGoPrevious)
            Button { session.next() } label: {
                Label("Next Slide", systemImage: "chevron.right")
            }
            .disabled(!session.canGoNext)
            Button { session.flag() } label: {
                Label("Flag", systemImage: "flag")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!session.isRecording)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            recordButton
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }

    private var slidePosition: some View {
        Text("Slide \(session.currentPage) \(Text("of \(session.pageCount)").fontWeight(.regular).foregroundStyle(.secondary))")
            .font(.system(size: 13, weight: .semibold))
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
        case .recording, .stopping:
            Button {
                confirmsStop = true
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
            }
            .disabled(session.phase == .stopping)
        case .finished:
            Button {} label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(true)
        }
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

    static func title(for failure: LiveLectureSession.Failure) -> String {
        switch failure {
        case .notConsented: String(localized: "Recording is off for this course")
        case .microphoneDenied: String(localized: "Microphone access is off")
        case .noInputDevice: String(localized: "No microphone")
        case .storage: String(localized: "Recording stopped")
        case .engine: String(localized: "Recording couldn’t start")
        }
    }

    static func message(for failure: LiveLectureSession.Failure) -> String? {
        switch failure {
        case .notConsented, .microphoneDenied, .noInputDevice: nil
        case .storage(let detail), .engine(let detail): detail
        }
    }

    static var privacySettingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            ?? URL(filePath: "/System/Applications/System Settings.app")
        #else
        URL(string: "app-settings:") ?? URL(filePath: "/")
        #endif
    }
}
