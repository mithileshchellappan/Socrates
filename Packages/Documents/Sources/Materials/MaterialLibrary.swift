import CryptoKit
import Documents
import Foundation
import StudyCore
import UniformTypeIdentifiers

/// A course's materials (docs/plan-materials.md §3, "Build plan" workstream A): books, papers and
/// references (files kept in the document bank with role `material`) and links (repositories and
/// web pages, their text kept as a role-material snapshot document). Every add returns at once
/// with a `pending` row; reading (the bank's reader), sections and printed pages
/// (`SectionReader`), the cover (`MaterialCovers`) and link fetches (`LinkFetcher`, at most two
/// at once) follow in the background; the card is the bank's `document` task (AppAgent's queue
/// runs `MaterialCard` for it).
///
/// Wiring (the integrator):
///
///     let library = MaterialLibrary(services: s, bank: bank) { material in
///         await studyPass.queueCoverBackfill(courseID: material.courseID)   // StudyPass (B)
///     }
///     await library.start()     // after the bank; returns at once (resumes after 20 s)
///     // \.materialLibrary (MaterialsUI), FilingCenter.materials, AppAgent(…, materials: library)
///
/// Logs never carry a material's title, text or URL at `.public`.
public actor MaterialLibrary: MaterialLibraryActions {
    public let services: StudyServices
    public let bank: DocumentBank
    let onSectionsReady: @Sendable (CourseMaterial) async -> Void
    let now: @Sendable () -> Date
    let fetcher: LinkFetcher

    public static let resumeDelay: Duration = .seconds(20)
    static let fetchSlots = 2
    public static let notAWebAddress = "This is not a web address."

    private var started = false
    private var observing = false
    private var resumeWork: Task<Void, Never>?
    /// Link fetches running or waiting for their rate limit's reset, by material.
    private var linkWork: [CourseMaterial.ID: Task<Void, Never>] = [:]
    private var activeFetches = 0
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        services: StudyServices, bank: DocumentBank, onSectionsReady: @escaping @Sendable (CourseMaterial) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.bank = bank
        self.onSectionsReady = onSectionsReady
        self.now = now
        fetcher = LinkFetcher(paths: services.paths)
    }

    var repository: MaterialRepository { MaterialRepository(store: services.records) }
    var documents: DocumentRepository { DocumentRepository(store: services.records) }

    // MARK: - Launch

    /// At launch, after the bank: watches the bank's reads of role-material documents now; after
    /// `resumeDelay` resumes what a quit left pending (files whose text is read: their sections
    /// and cover; links: fetched again, or at their rate limit's reset). Returns at once.
    public func start() async {
        guard !started else { return }
        started = true
        await observe()
        resumeWork = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: Self.resumeDelay) } catch { return }
            await self?.resume()
        }
    }

    /// The app quits: fetches and scheduled retries stop (their rows stay pending).
    public func stop() {
        resumeWork?.cancel()
        resumeWork = nil
        for work in linkWork.values { work.cancel() }
        linkWork = [:]
    }

    private func observe() async {
        guard !observing else { return }
        observing = true
        await bank.observeMaterialReads { [weak self] id, error in
            await self?.documentRead(id, error: error)
        }
    }

    private func resume() async {
        do {
            for material in try await repository.pending() {
                if material.kind.isLink, material.documentID == nil || material.facts.retryAfter != nil {
                    fetchLater(material)
                } else if let documentID = material.documentID {
                    await settleKnown(documentID)
                } else {
                    try await fail(material.id, DocumentReadError.missing.sentence)
                }
            }
        } catch {
            Log.materials.error("Resuming materials failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Adding (MaterialLibraryActions)

    /// Files dropped, pasted or imported on a course's Materials (also a book or paper smart import
    /// sent here): PDFs and the bank's other types; a `.webloc` is its link. `kind` nil: the
    /// classifier's guess (neither book nor paper: a reference). A file that is already a material
    /// of the course comes back as it is. Throws the first readable sentence only when nothing
    /// could be added ("EPUB books can’t be read yet. Add the PDF.").
    public func add(files: [URL], to course: Course.ID, as kind: MaterialKind?) async throws -> [CourseMaterial] {
        try await add(files: files, to: course, as: kind, by: .user)
    }

    public func add(files: [URL], to course: Course.ID, as kind: MaterialKind?, by author: Author) async throws -> [CourseMaterial] {
        await observe()
        var added: [CourseMaterial] = []
        var firstError: (any Error)?
        for url in files {
            do {
                if url.pathExtension.lowercased() == "webloc" {
                    guard let link = Self.webloc(url) else { throw DocumentReadError.unreadable }
                    added.append(try await add(link: link, to: course, by: author))
                    continue
                }
                added.append(try await add(file: url, to: course, as: kind, by: author))
            } catch {
                Log.materials.notice("A material was not added: \(String(describing: error), privacy: .private)")
                firstError = firstError ?? error
            }
        }
        if added.isEmpty, let firstError { throw firstError }
        return added
    }

    private func add(file url: URL, to course: Course.ID, as kind: MaterialKind?, by author: Author) async throws -> CourseMaterial {
        if DocumentReadError.isEPUB(nil, fileName: url.lastPathComponent) { throw DocumentReadError.epub }
        var reading: MaterialClassifier.Reading?
        if url.pathExtension.lowercased() == "pdf" { reading = await MaterialClassifier.read(pdfAt: url) }
        guard let addition = try await bank.add([url], role: .material, by: author).first else { throw DocumentReadError.unreadable }
        return try await keep(addition, url: nil, to: course, kind: kind, reading: reading, by: author)
    }

    /// A file the student attached on the agent panel (`add_material {file}`): its bytes are in
    /// the BlobStore already.
    public func add(attachment: AgentAttachment, to course: Course.ID, kind: MaterialKind?, by author: Author) async throws -> CourseMaterial {
        await observe()
        let addition = try await bank.add(attachment: attachment, role: .material, by: author)
        var reading: MaterialClassifier.Reading?
        if attachment.kind == .pdf { reading = await MaterialClassifier.read(pdfAt: services.blobs.url(for: attachment.blob)) }
        return try await keep(addition, url: nil, to: course, kind: kind, reading: reading, by: author)
    }

    /// The row for a kept file (the course's own row when it has one), then its reading.
    private func keep(
        _ addition: DocumentAddition, url: URL?, to course: Course.ID, kind: MaterialKind?, reading: MaterialClassifier.Reading?, by author: Author
    ) async throws -> CourseMaterial {
        let document = addition.document
        if let known = try await repository.materials(documentID: document.id).first(where: { $0.courseID == course }) { return known }
        let guessed = kind ?? reading?.kind.materialKind ?? .reference
        let stem = (document.fileName as NSString).deletingPathExtension
        let material = try await repository.add(CourseMaterial(
            courseID: course, kind: guessed.isFile ? guessed : .reference,
            kindSource: kind == nil ? .guess : (author == .agent ? .agent : .student), state: .pending,
            title: document.summaryState == .done && !document.title.isEmpty ? document.title : (stem.isEmpty ? document.fileName : stem),
            url: url, documentID: document.id, pageCount: reading?.pageCount ?? document.pageCount, facts: Self.facts(reading),
            createdBy: author, addedAt: now(), updatedAt: now()
        ))
        // A file the bank had already: its text may be read (or have failed) long ago.
        if !addition.isNew { Task { await self.settleKnown(document.id) } }
        return material
    }

    /// A URL (pasted, dropped, a `.webloc`): public https is fetched; anything else is kept as a
    /// link card that opens in the browser. The same address on the course comes back.
    public func add(link: URL, to course: Course.ID) async throws -> CourseMaterial {
        try await add(link: link, to: course, by: .user)
    }

    public func add(link: URL, to course: Course.ID, by author: Author) async throws -> CourseMaterial {
        await observe()
        guard let url = LinkFetcher.normalized(link) else { throw DocumentReadError(Self.notAWebAddress) }
        if let known = try await repository.materials(of: course).first(where: { $0.url == url }) { return known }
        let repo = LinkFetcher.repository(url)
        let fetchable = LinkFetcher.isFetchable(url)
        let material = try await repository.add(CourseMaterial(
            courseID: course, kind: repo == nil ? .website : .repository, state: fetchable ? .pending : .ready,
            title: LinkFetcher.displayTitle(url), byline: repo?.owner ?? "", url: url,
            facts: MaterialFacts(owner: repo?.owner, repo: repo?.repo, path: repo?.path),
            createdBy: author, addedAt: now(), updatedAt: now()
        ))
        if fetchable { fetchLater(material) }
        return material
    }

    /// The agent's wanted book (`add_material {title, authors, source}`): a quiet cover that takes
    /// a dropped PDF (`fill`).
    public func addWanted(title: String, byline: String, to course: Course.ID, by author: Author) async throws -> CourseMaterial {
        try await repository.add(CourseMaterial(
            courseID: course, kind: .book, kindSource: .agent, state: .wanted, title: String(title.prefix(160)),
            byline: String(byline.prefix(200)), createdBy: author, addedAt: now(), updatedAt: now()
        ))
    }

    /// A PDF dropped on a wanted book's cover: the row becomes that file's material (its title and
    /// byline stay until the card writes its own).
    public func fill(_ wanted: CourseMaterial.ID, with file: URL) async throws -> CourseMaterial {
        await observe()
        guard let material = try await repository.material(wanted) else { throw DocumentReadError.missing }
        guard material.state == .wanted else { return material }
        if DocumentReadError.isEPUB(nil, fileName: file.lastPathComponent) { throw DocumentReadError.epub }
        let reading = file.pathExtension.lowercased() == "pdf" ? await MaterialClassifier.read(pdfAt: file) : nil
        guard let addition = try await bank.add([file], role: .material, by: .user).first else { throw DocumentReadError.unreadable }
        let document = addition.document
        let facts = Self.facts(reading)
        let filled = try await repository.update(wanted) { row in
            row.documentID = document.id
            row.state = .pending
            row.error = nil
            row.pageCount = reading?.pageCount ?? document.pageCount
            row.facts.pdfTitle = facts.pdfTitle
            row.facts.pdfAuthor = facts.pdfAuthor
            row.facts.isbn = facts.isbn
            row.facts.doi = facts.doi
            row.facts.arxivID = facts.arxivID
        }
        if !addition.isNew { Task { await self.settleKnown(document.id) } }
        return filled ?? material
    }

    // MARK: - Changing

    /// Show As ▸ Book / Paper / Reference (the student's choice: the card never changes it).
    public func setKind(_ kind: MaterialKind, of id: CourseMaterial.ID) async throws {
        guard let material = try await repository.material(id), material.kind.isFile == kind.isFile else { return }
        try await repository.update(id) { row in
            row.kind = kind
            row.kindSource = .student
        }
    }

    /// Read Again after a failure (a file: its text read again, or its card written again; then
    /// its sections), or Refresh (a link: fetched again; a new snapshot only when the text changed).
    public func readAgain(_ id: CourseMaterial.ID) async throws {
        await observe()
        guard let material = try await repository.material(id), material.state != .wanted else { return }
        if material.kind.isLink {
            try await repository.update(id) { row in
                row.state = .pending
                row.error = nil
                row.facts.retryAfter = nil
            }
            if let fresh = try await repository.material(id) { fetchLater(fresh, now: true) }
            return
        }
        guard let documentID = material.documentID, let document = try await documents.document(documentID) else {
            try await fail(id, DocumentReadError.missing.sentence)
            return
        }
        try await repository.update(id) { row in
            row.state = .pending
            row.error = nil
        }
        if document.textState == .failed || document.summaryState == .failed {
            await bank.retry(documentID)
        }
        if document.textState == .done { await afterRead(documentID) }
    }

    /// A drop's toast Change… (another course's Materials): the material moves there, at the end
    /// of its shelf, not its book; coverage of the old course's lectures goes.
    public func move(_ id: CourseMaterial.ID, to course: Course.ID) async throws -> CourseMaterial? {
        guard let material = try await repository.material(id), material.courseID != course else { return try await repository.material(id) }
        let last = try await repository.materials(of: course).map(\.sortOrder).max() ?? -1
        let stamp = now()
        try await services.database.write { db in
            try MaterialCoverage.where { $0.materialID.eq(id) }.delete().execute(db)
        }
        return try await repository.update(id) { row in
            row.courseID = course
            row.isPrimary = false
            row.sortOrder = last + 1
            row.updatedAt = stamp
        }
    }

    /// The cover image file of a PDF material (drawn now when the cache lost it); nil otherwise.
    public func coverURL(of material: CourseMaterial) async -> URL? {
        guard material.kind.isFile, let documentID = material.documentID,
              let document = try? await documents.document(documentID), document.fileKind == .pdf, let blob = document.blob
        else { return nil }
        let file = services.blobs.url(for: blob)
        let paths = services.paths
        return await Task.detached(priority: .userInitiated) { MaterialCovers.cover(pdfAt: file, sha256: blob.sha256, paths: paths) }.value
    }

    // MARK: - Deleting

    /// Deletes materials (no confirmation; Edit ▸ Undo "Delete Material" passes the result to
    /// `restore`): their rows (sections, coverage, book further reading and readings), then each
    /// role-material document no other material uses, through the bank (its summary task
    /// cancelled, its file removed at a later launch when unused).
    public func delete(_ ids: [CourseMaterial.ID]) async throws -> MaterialDeletion {
        for id in ids { linkWork.removeValue(forKey: id)?.cancel() }
        var deletion = try await repository.delete(ids)
        for documentID in Set(deletion.materials.compactMap(\.documentID)) {
            guard try await repository.materials(documentID: documentID).isEmpty,
                  let document = try await documents.document(documentID), document.role == .material,
                  let gone = try await bank.delete(documentID)
            else { continue }
            deletion.documents.append(gone)
        }
        return deletion
    }

    /// Undo of `delete`: the documents through the bank first, then every row as it was.
    public func restore(_ deletion: MaterialDeletion) async throws {
        for document in deletion.documents { try await bank.restore(document) }
        try await repository.restore(deletion)
        for material in deletion.materials where material.state == .pending {
            if material.kind.isLink, material.documentID == nil {
                fetchLater(material, now: true)
            } else if let documentID = material.documentID {
                await settleKnown(documentID)
            }
        }
    }

    /// The card's sections landed (AppAgent's `document` runner): the same follow-up as the
    /// library's own (the cover backfill).
    public func sectionsLanded(_ materials: [CourseMaterial]) async {
        for material in materials { await onSectionsReady(material) }
    }

    // MARK: - Reading files

    /// The bank read (or could not read) a role-material document.
    private func documentRead(_ documentID: StudyDocument.ID, error: String?) async {
        if let error {
            do {
                for material in try await repository.materials(documentID: documentID) where material.state == .pending {
                    try await fail(material.id, error)
                }
            } catch {
                Log.materials.error("Marking a material failed failed: \(String(describing: error), privacy: .public)")
            }
            return
        }
        await afterRead(documentID)
    }

    /// A document added again or resumed: read already (sections now), failed (the row fails), or
    /// still pending (the bank's reader tells us).
    private func settleKnown(_ documentID: StudyDocument.ID) async {
        do {
            guard let document = try await documents.document(documentID) else {
                for material in try await repository.materials(documentID: documentID) where material.state == .pending {
                    try await fail(material.id, DocumentReadError.missing.sentence)
                }
                return
            }
            switch document.textState {
            case .done: await afterRead(documentID)
            case .failed: await documentRead(documentID, error: document.error ?? DocumentReadError.unreadable.sentence)
            case .pending: break
            }
        } catch {
            Log.materials.error("Settling a material failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The text is read: each material of the document gets its sections and printed pages (a
    /// file), its cover (a PDF), its page count, and turns ready; then `onSectionsReady`.
    private func afterRead(_ documentID: StudyDocument.ID) async {
        do {
            guard let document = try await documents.document(documentID), document.textState == .done else { return }
            let materials = try await repository.materials(documentID: documentID).filter { $0.state != .wanted }
            guard !materials.isEmpty else { return }
            let pages = try await documents.pages(of: documentID)
            let isPDF = document.fileKind == .pdf
            let file = document.blob.map { services.blobs.url(for: $0) }
            var reading: MaterialClassifier.Reading?
            if isPDF, let file {
                reading = await MaterialClassifier.read(pdfAt: file)
                let sha = document.blobSHA256
                let paths = services.paths
                _ = await Task.detached(priority: .utility) { MaterialCovers.cover(pdfAt: file, sha256: sha, paths: paths) }.value
            }
            for material in materials {
                var sections: [MaterialSection] = []
                var offset: Int?
                if material.kind.isFile {
                    let result = await SectionReader.read(pdfAt: isPDF ? file : nil, pages: pages, materialID: material.id)
                    offset = result.printedOffset
                    if !result.sections.isEmpty {
                        sections = try await repository.replaceSections(of: material.id, with: result.sections)
                    }
                }
                let facts = Self.facts(reading)
                let count = document.pageCount
                let printedOffset = offset
                let ready = try await repository.update(material.id) { row in
                    row.state = .ready
                    row.error = nil
                    row.pageCount = count
                    if row.kind.isFile {
                        row.printedOffset = printedOffset
                        row.facts.pdfTitle = facts.pdfTitle ?? row.facts.pdfTitle
                        row.facts.pdfAuthor = facts.pdfAuthor ?? row.facts.pdfAuthor
                        row.facts.isbn = facts.isbn ?? row.facts.isbn
                        row.facts.doi = facts.doi ?? row.facts.doi
                        row.facts.arxivID = facts.arxivID ?? row.facts.arxivID
                    }
                }
                if let ready, !sections.isEmpty { await onSectionsReady(ready) }
            }
            Log.materials.info("Read a material: \(pages.count) pages")
        } catch {
            Log.materials.error("Reading a material's sections failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func fail(_ id: CourseMaterial.ID, _ sentence: String) async throws {
        try await repository.update(id) { row in
            row.state = .failed
            row.error = sentence
        }
    }

    // MARK: - Links

    /// Fetches a link now (`now`) or when its rate limit resets, at most `fetchSlots` at once.
    private func fetchLater(_ material: CourseMaterial, now immediate: Bool = false) {
        linkWork[material.id]?.cancel()
        let wait = immediate ? 0 : max(0, (material.facts.retryAfter ?? .distantPast).timeIntervalSince(now()))
        let id = material.id
        linkWork[id] = Task(priority: .utility) { [weak self] in
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            await self?.fetch(id)
        }
    }

    private func fetch(_ id: CourseMaterial.ID) async {
        await acquireFetch()
        defer { releaseFetch() }
        do {
            guard !Task.isCancelled, let material = try await repository.material(id), let url = material.url,
                  material.state == .pending, material.kind.isLink
            else { return }
            let result = await fetcher.read(url)
            guard !Task.isCancelled else { return }
            let stamp = now()
            switch result {
            case .rateLimited(let until):
                let waiting = try await repository.update(id) { row in row.facts.retryAfter = until }
                if let waiting { fetchLater(waiting) }
                return
            case .failed(let sentence):
                try await repository.update(id) { row in
                    row.state = .failed
                    row.error = sentence
                    row.fetchedAt = stamp
                }
            case .repository(let facts, let title, let description, let readme):
                try await repository.update(id) { row in
                    row.title = title
                    row.byline = facts.owner ?? row.byline
                    row.facts.owner = facts.owner
                    row.facts.repo = facts.repo
                    row.facts.path = facts.path
                    row.facts.defaultBranch = facts.defaultBranch
                    row.facts.language = facts.language
                    row.facts.license = facts.license
                    row.facts.topics = facts.topics
                    row.facts.isArchived = facts.isArchived
                    row.facts.retryAfter = nil
                    if !description.isEmpty {
                        row.summary = description
                        row.summarySource = .page
                    }
                    row.state = .ready
                    row.error = nil
                    row.fetchedAt = stamp
                }
                if let readme { try await keepSnapshot(id, text: readme, name: "\(facts.repo ?? "Repository") README.md") }
            case .page(let title, let description, let text, let facts):
                try await repository.update(id) { row in
                    row.title = title
                    row.facts.siteName = facts.siteName
                    row.facts.faviconHash = facts.faviconHash ?? row.facts.faviconHash
                    row.facts.isTitleOnly = facts.isTitleOnly
                    row.facts.retryAfter = nil
                    if !description.isEmpty {
                        row.summary = description
                        row.summarySource = .page
                    }
                    row.state = .ready
                    row.error = nil
                    row.fetchedAt = stamp
                }
                if let text { try await keepSnapshot(id, text: text, name: "\(LinkFetcher.displayTitle(url)).md") }
            case .pdf(let file, let finalURL):
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                let reading = await MaterialClassifier.read(pdfAt: file)
                guard let addition = try await bank.add([file], role: .material, by: material.createdBy).first else {
                    try await fail(id, DocumentReadError.unreadable.sentence)
                    return
                }
                let document = addition.document
                let facts = Self.facts(reading)
                try await repository.update(id) { row in
                    row.kind = reading?.kind.materialKind ?? .paper
                    row.kindSource = .guess
                    row.documentID = document.id
                    row.url = finalURL
                    row.pageCount = reading?.pageCount ?? 0
                    row.title = (document.fileName as NSString).deletingPathExtension
                    row.facts.pdfTitle = facts.pdfTitle
                    row.facts.pdfAuthor = facts.pdfAuthor
                    row.facts.doi = facts.doi
                    row.facts.arxivID = facts.arxivID
                    row.fetchedAt = stamp
                }
                if !addition.isNew { await settleKnown(document.id) }
            }
        } catch {
            Log.materials.error("Fetching a link failed: \(String(describing: error), privacy: .public)")
        }
        linkWork[id] = nil
    }

    /// A link's text as its snapshot document, only when its hash changed; the old snapshot is
    /// deleted when no other material uses it.
    private func keepSnapshot(_ id: CourseMaterial.ID, text: String, name: String) async throws {
        guard let material = try await repository.material(id) else { return }
        let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if material.textSHA256 == sha, material.documentID != nil { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let addition = try await bank.add(text: text, fileName: safeName, role: .material, by: material.createdBy)
        let old = material.documentID
        let documentID = addition.document.id
        try await repository.update(id) { row in
            row.documentID = documentID
            row.textSHA256 = sha
        }
        if let old, old != documentID, try await repository.materials(documentID: old).isEmpty,
           let document = try await documents.document(old), document.role == .material {
            _ = try await bank.delete(old)
        }
        if !addition.isNew { await settleKnown(documentID) }
    }

    private func acquireFetch() async {
        if activeFetches < Self.fetchSlots {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { continuation in fetchWaiters.append(continuation) }
    }

    private func releaseFetch() {
        if fetchWaiters.isEmpty {
            activeFetches = max(0, activeFetches - 1)
        } else {
            fetchWaiters.removeFirst().resume()
        }
    }

    // MARK: - Support

    static func facts(_ reading: MaterialClassifier.Reading?) -> MaterialFacts {
        MaterialFacts(isbn: reading?.isbn, doi: reading?.doi, arxivID: reading?.arxivID, pdfTitle: reading?.title, pdfAuthor: reading?.author)
    }

    /// A `.webloc` file's URL.
    static func webloc(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let text = plist["URL"] as? String
        else { return nil }
        return URL(string: text)
    }
}
