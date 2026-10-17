import Foundation
import Observation
import StudyCore

/// Keyboard focus shared by the Mail screen's zones: the list asks the reader to take focus (↩),
/// the reader hands it back (Escape), Reply asks the editor of a draft to take it, and the
/// editors report while text is being typed (the Message menu detaches its keys then).
@MainActor
@Observable
final class MailFocus {
    var readerRequest: UUID?
    var listRequest: UUID?
    /// The draft whose editor should take focus (Reply, New Message).
    var editorRequest: MailDraft.ID?
    /// A text editor of the screen has focus.
    var isEditingText = false

    init() {}
}

/// One draft being written: what the editor shows, what the agent wrote, saving, Send and Discard.
///
/// - The editor is the source of the text once the student typed; before that, the agent's text
///   streaming into the row replaces it.
/// - The first keystroke while the agent writes stops it (`MailActions.stopDrafting`).
/// - Typing is saved (`MailDraftRepository.editBody`) a moment after it pauses, and before Send.
/// - Send first adds an address still being typed in To, waits for the recipients and text to
///   be saved, and stops when they could not be: what is sent is what the editor shows.
/// - Send calls `MailActions.send` once, never while the agent writes or a send runs; a failure
///   shows its reason and Send works again. A draft that may have gone out already asks first
///   (`confirmsResend`), then calls `MailActions.sendAgain`.
@MainActor
@Observable
final class DraftEditorModel {
    let draftID: MailDraft.ID
    private(set) var text: String
    private(set) var generated: String?
    private(set) var state: MailDraftState
    private(set) var to: [MailAddress]
    private(set) var cc: [MailAddress]
    private(set) var bcc: [MailAddress]
    private(set) var subject: String
    private(set) var isReply: Bool
    /// The row's own error (a send that failed earlier).
    private(set) var storedError: String?
    /// Why the last Send failed here.
    private(set) var sendError: String?
    private(set) var isSending = false
    /// The student typed in this editor: the agent's later text no longer replaces it.
    private(set) var hasUserEdits = false
    /// Typed in To and not yet a recipient token; Send adds it first.
    var pendingRecipient = ""
    /// Send was pressed on a draft that may have gone out already: the composer asks first.
    var confirmsResend = false

    @ObservationIgnored private let actions: MailActions
    @ObservationIgnored private let services: StudyServices?
    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The latest recipients/subject save (each waits for the one before); false when it failed.
    @ObservationIgnored private var headerSave: Task<Bool, Never>?
    @ObservationIgnored private let saveDelay: Duration

    init(draft: MailDraft, actions: MailActions, services: StudyServices?, saveDelay: Duration = .milliseconds(400)) {
        draftID = draft.id
        text = draft.body
        savedText = draft.body
        generated = draft.generatedBody
        state = draft.state
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        subject = draft.subject
        isReply = draft.mailMessageID != nil
        storedError = draft.error
        hasUserEdits = draft.isEditedByUser && draft.generatedBody != nil
        self.actions = actions
        self.services = services
        self.saveDelay = saveDelay
    }

    /// The agent writes into this draft (its text is shown, Send waits).
    var isGenerating: Bool { state == .generating }

    var canEdit: Bool { state == .generating || state == .draft || state == .failed }

    var canSend: Bool {
        (state == .draft || state == .failed) && !isSending
            && (to + MailText.addresses(from: pendingRecipient)).contains { MailText.isAddress($0.address) }
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The last send may have gone out (`MailDraft.mayHaveBeenSent`).
    var mayHaveBeenSent: Bool { state == .failed && storedError == MailDraft.unknownSendOutcome }

    /// The reason the last send failed, shown under the editor.
    var errorText: String? {
        if let sendError { return sendError }
        guard state == .failed else { return nil }
        return storedError?.isEmpty == false ? storedError : String(localized: "Not sent")
    }

    /// The agent's unchanged words get the AI style and its one sparkle.
    var showsAgentMark: Bool {
        if isGenerating && !hasUserEdits { return true }
        return !ProvenanceDiff.agentRanges(generated: generated, body: text).isEmpty
    }

    /// A newer version of the row (the agent's stream, a send's state, headers).
    func update(from draft: MailDraft) {
        guard draft.id == draftID else { return }
        generated = draft.generatedBody
        state = draft.state
        storedError = draft.error
        to = draft.to
        cc = draft.cc
        bcc = draft.bcc
        subject = draft.subject
        if !hasUserEdits, saveTask == nil, draft.body != text {
            text = draft.body
            savedText = draft.body
        }
        if draft.state == .sent { sendError = nil }
    }

    /// The student changed the text.
    func edit(_ newText: String) {
        guard newText != text, canEdit else { return }
        text = newText
        if !hasUserEdits {
            hasUserEdits = true
            if state == .generating {
                let actions = actions
                let id = draftID
                Task { await actions.stopDrafting(id) }
            }
        }
        scheduleSave()
    }

    /// Recipients or subject changed (saved at once, in order).
    func setHeaders(to: [MailAddress]? = nil, subject: String? = nil) {
        if let to { self.to = to }
        if let subject { self.subject = subject }
        guard let services else { return }
        let id = draftID
        let (to, cc, bcc, subject) = (self.to, self.cc, self.bcc, self.subject)
        let previous = headerSave
        headerSave = Task {
            _ = await previous?.value
            do {
                return try await MailDraftRepository(store: services.records).editHeaders(id, to: to, cc: cc, bcc: bcc, subject: subject)
            } catch {
                Log.mail.error("Saving draft headers failed: \(error.localizedDescription, privacy: .private)")
                return false
            }
        }
    }

    /// Adds what is typed in To as recipients; false when it is not an address.
    @discardableResult
    func commitPendingRecipient() -> Bool {
        let typed = pendingRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return true }
        let added = MailText.addresses(from: typed)
        guard !added.isEmpty else { return false }
        let known = Set(to.map(\.normalizedAddress))
        pendingRecipient = ""
        setHeaders(to: to + added.filter { !known.contains($0.normalizedAddress) })
        return true
    }

    /// Writes pending text now.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await save()
    }

    /// Send: adds the recipient being typed, saves recipients and text, then asks the app to
    /// send, once. Nothing is sent when what the editor shows could not be saved. A draft that may
    /// have gone out already is sent again only with `confirmingResend` (the composer asks).
    func send(confirmingResend: Bool = false) async {
        guard canSend else { return }
        if mayHaveBeenSent, !confirmingResend {
            confirmsResend = true
            return
        }
        isSending = true
        sendError = nil
        defer { isSending = false }
        guard commitPendingRecipient() else {
            sendError = String(localized: "“\(pendingRecipient)” is not a valid address.")
            return
        }
        await flush()
        let headersSaved = await headerSave?.value ?? true
        guard headersSaved, savedText == text else {
            sendError = String(localized: "The draft could not be saved.")
            return
        }
        do {
            if confirmingResend {
                try await actions.sendAgain(draftID)
            } else {
                try await actions.send(draftID)
            }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Discard: stops the agent and deletes the draft (not while it is being sent).
    func discard() async {
        saveTask?.cancel()
        saveTask = nil
        guard state != .sending, state != .sent, !isSending else { return }
        if state == .generating { await actions.stopDrafting(draftID) }
        guard let services else { return }
        do {
            try await services.records.delete(MailDraft.self, id: draftID)
        } catch {
            Log.mail.error("Discarding a draft failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            await self.save()
        }
    }

    /// Writes the text when it changed; `savedText` follows only a write that took.
    private func save() async {
        let text = text
        guard text != savedText, let services else { return }
        do {
            if try await MailDraftRepository(store: services.records).editBody(draftID, text) {
                savedText = text
            } else {
                Log.mail.error("Saving a draft failed: the draft is no longer editable")
            }
        } catch {
            Log.mail.error("Saving a draft failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
