import Foundation
import LocalTranslation
import Observation
import StudyCore
import SwiftUI

/// How the reader translates: into which language. The translation itself is local-translate's
/// OPUS-MT models on the device (`LocalTranslator`): the mail never leaves the device and no model
/// of Claude's is asked.
struct MailTranslator: Sendable {
    /// The student's language: a mail in another one offers Translate.
    var target: Locale.Language

    static let system = MailTranslator(target: MailLanguage.preferred)

    /// The code `LocalTranslator` takes ("de", "en", "zh-Hant").
    static func code(_ language: Locale.Language) -> String {
        language.minimalIdentifier
    }
}

extension EnvironmentValues {
    @Entry var mailTranslator: MailTranslator = .system
}

/// The reader's translations for this session, in memory only (nothing is written): per message,
/// the language it can be translated from, whether it is shown translated (the toolbar's
/// Translate is on), and the translation so far (the subject first, then each block as it lands).
@MainActor
@Observable
final class MailTranslations {
    static let shared = MailTranslations()

    private struct Entry {
        var subject: String
        var body: MailBody
        var translated: MailTranslatedMail
        /// Every text is back; nil `job` from now on.
        var isComplete: Bool
    }

    /// The language each message can be translated from (only messages that offer Translate).
    private(set) var sources: [MailMessage.ID: Locale.Language] = [:]
    /// Messages shown translated.
    private(set) var shown: Set<MailMessage.ID> = []
    /// Messages whose model is downloading: 0…1.
    private(set) var downloads: [MailMessage.ID: Double] = [:]
    /// Messages whose last translation could not be made (Translate turned off).
    private(set) var failed: Set<MailMessage.ID> = []
    private var entries: [MailMessage.ID: Entry] = [:]

    func canTranslate(_ id: MailMessage.ID) -> Bool {
        sources[id] != nil
    }

    func isShowingTranslation(_ id: MailMessage.ID) -> Bool {
        shown.contains(id)
    }

    /// Translate / Show Original.
    func toggle(_ id: MailMessage.ID) {
        if shown.remove(id) == nil {
            shown.insert(id)
            failed.remove(id)
        }
    }

    /// The reader found the message's language: `source` when it offers Translate, else nil.
    func setSource(_ source: Locale.Language?, for id: MailMessage.ID) {
        guard sources[id] != source else { return }
        sources[id] = source
        if source == nil { shown.remove(id) }
    }

    /// The translation to show for this version of the message, complete or partial; nil shows
    /// the original (not asked for, or nothing back yet).
    func translation(for id: MailMessage.ID, subject: String, body: MailBody) -> MailTranslatedMail? {
        guard shown.contains(id), let entry = entries[id], entry.subject == subject, entry.body == body else { return nil }
        return entry.translated
    }

    /// What still has to be translated for this version of the message, if anything. The same
    /// job while its entry is partial, so partial results do not restart it.
    func job(for id: MailMessage.ID, subject: String, body: MailBody, target: Locale.Language) -> MailTranslationJob? {
        guard shown.contains(id), let source = sources[id] else { return nil }
        if let entry = entries[id], entry.subject == subject, entry.body == body, entry.isComplete { return nil }
        return MailTranslationJob(messageID: id, source: source, target: target, subject: subject, body: body)
    }

    /// The translation so far (`complete`: every text is back).
    func update(_ translated: MailTranslatedMail, complete: Bool, for job: MailTranslationJob) {
        entries[job.messageID] = Entry(subject: job.subject, body: job.body, translated: translated, isComplete: complete)
        if complete { downloads[job.messageID] = nil }
    }

    /// The route's model is downloading (`fraction` 0…1), or not any more (nil).
    func setDownload(_ fraction: Double?, for job: MailTranslationJob) {
        guard downloads[job.messageID] != fraction else { return }
        downloads[job.messageID] = fraction
    }

    /// The job was cancelled (another message, Translate off): a partial translation goes, so
    /// the next job starts clean (finished sentences come back from the translator's cache).
    func discard(_ job: MailTranslationJob) {
        downloads[job.messageID] = nil
        guard let entry = entries[job.messageID], !entry.isComplete, entry.subject == job.subject, entry.body == job.body else { return }
        entries[job.messageID] = nil
    }

    /// The translation could not be made (no network for the first download, an error): the
    /// original stays, Translate turns off, and its help says so.
    func fail(_ job: MailTranslationJob) {
        discard(job)
        shown.remove(job.messageID)
        failed.insert(job.messageID)
    }

    /// Whether a model route exists from `source` into the student's language.
    func supports(_ source: Locale.Language, with translator: MailTranslator) -> Bool {
        LocalTranslator.canTranslate(from: MailTranslator.code(source), to: MailTranslator.code(translator.target))
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

    /// Translates on the device and hands the results to `translations` as they land: the
    /// subject, then each block once all its lines are back. Blocks are built here, off the main
    /// actor; the main actor gets a new value only when something changed.
    @concurrent
    func run(into translations: MailTranslations) async {
        let input = MailTranslationInput(subject: subject, body: body, source: source, target: target)
        var mail = MailTranslatedMail(subject: subject, body: body)
        guard !input.texts.isEmpty else {
            await translations.update(mail, complete: true, for: self)
            return
        }
        let stream = LocalTranslator.shared.translations(
            of: input.texts, from: MailTranslator.code(source), to: MailTranslator.code(target)
        )
        var texts: [Int: String] = [:]
        var isDownloading = false
        do {
            for try await event in stream {
                switch event {
                case .downloading(let fraction):
                    isDownloading = fraction < 1
                    await translations.setDownload(isDownloading ? fraction : nil, for: self)
                case .translated(let index, let text):
                    texts[index] = text
                    if isDownloading {
                        isDownloading = false
                        await translations.setDownload(nil, for: self)
                    }
                    if apply(index, input: input, texts: texts, to: &mail) {
                        await translations.update(mail, complete: false, for: self)
                    }
                }
            }
            // A cancelled consumer ends the stream without an error.
            guard !Task.isCancelled else {
                await translations.discard(self)
                return
            }
            await translations.update(mail, complete: true, for: self)
        } catch is CancellationError {
            await translations.discard(self)
        } catch {
            guard !Task.isCancelled else {
                await translations.discard(self)
                return
            }
            Log.mail.error("Translation failed: \(error.localizedDescription, privacy: .public)")
            await translations.fail(self)
        }
    }

    /// Puts text `index` in place: the subject, or its block once every line of the block is
    /// back. Whether the mail changed.
    private func apply(_ index: Int, input: MailTranslationInput, texts: [Int: String], to mail: inout MailTranslatedMail) -> Bool {
        if index == input.subjectIndex {
            mail.subject = texts[index] ?? subject
            return true
        }
        guard let block = input.blockOf[index], body.blocks.indices.contains(block) else { return false }
        guard let translated = input.translatedBlock(block, original: body.blocks[block], texts: texts) else { return false }
        mail.body.blocks[block] = translated
        return true
    }
}

/// Runs the translation the reader asks for. The reader shows the original until the subject
/// and the blocks land; switching messages or turning Translate off cancels it.
struct MailTranslationRunner: ViewModifier {
    let job: MailTranslationJob?
    let translations: MailTranslations

    func body(content: Content) -> some View {
        content
            .task(id: job) {
                await job?.run(into: translations)
            }
    }
}
