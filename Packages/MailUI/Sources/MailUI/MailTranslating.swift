import Foundation
import Observation
import StudyCore
import SwiftUI
import Translation

/// Translates mail text on the device. The app uses Apple's Translation framework
/// (`SystemMailTranslator`, with the session `.translationTask` hands the reader); tests and
/// snapshots set a fake through `\.mailTranslator`. The mail never leaves the device and no model
/// of ours is asked.
protocol MailTranslating {
    /// `texts` in the student's language, in the same order.
    func translate(_ texts: [AttributedString]) async throws -> [AttributedString]
}

/// Apple's on-device translation through a session from `.translationTask`. When the language
/// pair is not installed yet, the session shows the system's own download prompt first. The
/// session is not `Sendable`: it stays in the nonisolated task `MailTranslationRunner` starts.
struct SystemMailTranslator: MailTranslating {
    let session: TranslationSession

    func translate(_ texts: [AttributedString]) async throws -> [AttributedString] {
        if #available(macOS 26.4, iOS 26.4, *) {
            do {
                // Styled requests keep the links (and emphasis) of the original where they can.
                let responses = try await session.translations(from: texts.enumerated().map { offset, text in
                    TranslationSession.Request(sourceText: text, clientIdentifier: String(offset))
                })
                return try Self.inOrder(responses, count: texts.count) { $0.attributedTargetText ?? AttributedString($0.targetText) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Only with the languages installed (no second download prompt): try the plain text.
                guard let source = session.sourceLanguage,
                      await LanguageAvailability().status(from: source, to: session.targetLanguage) == .installed else { throw error }
                Log.mail.error("Styled translation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let responses = try await session.translations(from: texts.enumerated().map { offset, text in
            TranslationSession.Request(sourceText: String(text.characters), clientIdentifier: String(offset))
        })
        return try Self.inOrder(responses, count: texts.count) { AttributedString($0.targetText) }
    }

    /// Whether the system translates `source` into the student's language (a pair still to
    /// download counts).
    static func supports(_ source: Locale.Language, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source, to: target) != .unsupported
    }

    private static func inOrder(
        _ responses: [TranslationSession.Response], count: Int, _ text: (TranslationSession.Response) -> AttributedString
    ) throws -> [AttributedString] {
        var ordered = [AttributedString?](repeating: nil, count: count)
        for response in responses {
            guard let index = response.clientIdentifier.flatMap({ Int($0) }), ordered.indices.contains(index) else { continue }
            ordered[index] = text(response)
        }
        let texts = ordered.compactMap { $0 }
        guard texts.count == count else { throw MailTranslationFailure.incomplete }
        return texts
    }
}

enum MailTranslationFailure: Error {
    /// The translator returned fewer texts than it was given.
    case incomplete
}

/// How the reader translates: into which language, and with which translator.
struct MailTranslator: Sendable {
    /// The student's language: a mail in another one offers Translate.
    var target: Locale.Language
    /// nil: Apple's Translation through `.translationTask` (the app). Tests and snapshots set a fake.
    var custom: (any MailTranslating & Sendable)?

    static let system = MailTranslator(target: MailLanguage.preferred, custom: nil)
}

extension EnvironmentValues {
    @Entry var mailTranslator: MailTranslator = .system
}

/// The reader's translations for this session, in memory only (nothing is written): per message,
/// the language it can be translated from, whether it is shown translated (the toolbar's
/// Translate is on), and the translation once it landed.
@MainActor
@Observable
final class MailTranslations {
    static let shared = MailTranslations()

    private struct Entry {
        var subject: String
        var body: MailBody
        var translated: MailTranslatedMail
    }

    /// The language each message can be translated from (only messages that offer Translate).
    private(set) var sources: [MailMessage.ID: Locale.Language] = [:]
    /// Messages shown translated.
    private(set) var shown: Set<MailMessage.ID> = []
    private var entries: [MailMessage.ID: Entry] = [:]
    @ObservationIgnored private var supported: [String: Bool] = [:]

    func canTranslate(_ id: MailMessage.ID) -> Bool {
        sources[id] != nil
    }

    func isShowingTranslation(_ id: MailMessage.ID) -> Bool {
        shown.contains(id)
    }

    /// Translate / Show Original.
    func toggle(_ id: MailMessage.ID) {
        if shown.remove(id) == nil { shown.insert(id) }
    }

    /// The reader found the message's language: `source` when it offers Translate, else nil.
    func setSource(_ source: Locale.Language?, for id: MailMessage.ID) {
        guard sources[id] != source else { return }
        sources[id] = source
        if source == nil { shown.remove(id) }
    }

    /// The translation to show for this version of the message; nil shows the original (not asked
    /// for, or not landed yet).
    func translation(for id: MailMessage.ID, subject: String, body: MailBody) -> MailTranslatedMail? {
        guard shown.contains(id), let entry = entries[id], entry.subject == subject, entry.body == body else { return nil }
        return entry.translated
    }

    /// What still has to be translated for this version of the message, if anything.
    func job(for id: MailMessage.ID, subject: String, body: MailBody, target: Locale.Language) -> MailTranslationJob? {
        guard shown.contains(id), let source = sources[id] else { return nil }
        if let entry = entries[id], entry.subject == subject, entry.body == body { return nil }
        return MailTranslationJob(messageID: id, source: source, target: target, subject: subject, body: body)
    }

    func store(_ translated: MailTranslatedMail, for job: MailTranslationJob) {
        entries[job.messageID] = Entry(subject: job.subject, body: job.body, translated: translated)
    }

    /// The translation could not be made (the download was declined, an error): the original
    /// stays and Translate turns off.
    func fail(_ job: MailTranslationJob) {
        shown.remove(job.messageID)
    }

    /// Whether `translator` translates `source` (the system's answer is kept per language).
    func supports(_ source: Locale.Language, with translator: MailTranslator) async -> Bool {
        if translator.custom != nil { return true }
        let key = source.minimalIdentifier
        if let known = supported[key] { return known }
        let answer = await SystemMailTranslator.supports(source, to: translator.target)
        supported[key] = answer
        return answer
    }
}

/// One translation the reader asks for: a version of a message, from its language to the
/// student's.
struct MailTranslationJob: Hashable, Sendable {
    var messageID: MailMessage.ID
    var source: Locale.Language
    var target: Locale.Language
    var subject: String
    var body: MailBody

    /// The message translated by `translator`, off the main actor (splitting the text, checking
    /// each line's language, translating).
    @concurrent
    func translated(with translator: some MailTranslating) async throws -> MailTranslatedMail {
        let input = MailTranslationInput(subject: subject, body: body, source: source, target: target)
        guard !input.texts.isEmpty else { return MailTranslatedMail(subject: subject, body: body) }
        let output = try await translator.translate(input.texts)
        guard let translated = input.applying(output, subject: subject, body: body) else { throw MailTranslationFailure.incomplete }
        return translated
    }

    /// Translates and hands the result to `translations` (on the main actor).
    @concurrent
    func run(with translator: some MailTranslating, into translations: MailTranslations) async {
        do {
            let translated = try await translated(with: translator)
            await translations.store(translated, for: self)
        } catch {
            guard !Task.isCancelled else { return }
            Log.mail.error("Translation failed: \(error.localizedDescription, privacy: .public)")
            await translations.fail(self)
        }
    }
}

/// Runs the translation the reader asks for: through `.translationTask` (Apple's Translation,
/// which shows the system's download prompt when the languages are missing), or the custom
/// translator. The reader keeps showing the original until the translation lands.
struct MailTranslationRunner: ViewModifier {
    let job: MailTranslationJob?
    let translator: MailTranslator
    let translations: MailTranslations
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        if let custom = translator.custom {
            content
                .task(id: job) {
                    guard let job else { return }
                    await job.run(with: custom, into: translations)
                }
        } else {
            content
                .translationTask(configuration, action: Self.action(job, into: translations))
                .onChange(of: job, initial: true) { _, job in
                    guard let job else { return }
                    if configuration?.source == job.source {
                        configuration?.invalidate()
                    } else {
                        // Always an explicit target: with none, the system picks one from the Mac's
                        // region, not the student's language.
                        configuration = TranslationSession.Configuration(source: job.source, target: job.target)
                    }
                }
        }
    }

    /// The `.translationTask` action, made outside the main actor: the session it is handed is not
    /// `Sendable`, so it is used only in this nonisolated task and never crosses to the main actor.
    private nonisolated static func action(
        _ job: MailTranslationJob?, into translations: MailTranslations
    ) -> (TranslationSession) async -> Void {
        { session in
            guard let job else { return }
            await job.run(with: SystemMailTranslator(session: session), into: translations)
        }
    }
}
