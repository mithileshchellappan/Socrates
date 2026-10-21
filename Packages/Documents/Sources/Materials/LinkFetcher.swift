import CryptoKit
import Foundation
import ImageIO
import StudyCore
import UniformTypeIdentifiers

/// Reads a course material's link (docs/plan-materials.md §6), device work, no model, through
/// `PublicFetch` (ephemeral session, no cookies, no tokens, GET only, public https hosts only on
/// every hop, 8 s, ≤ 1 MB):
///
/// - GitHub (`github.com/<owner>/<repo>[/tree/<branch>/<path>]`): `api.github.com/repos/…`
///   (description, language, license, topics, default branch, archived) and its README (or the
///   linked folder's) as raw text, unauthenticated. A 403/429 with a reset waits until it (the
///   row stays pending); 404: "This repository could not be found." Links in the README are
///   never followed.
/// - Other pages: one GET; the title (`og:title`, else `<title>`), the description
///   (`og:description`, else `meta description`), the favicon (`link rel="icon"`, else
///   `/favicon.ico`; ≤ 64 KB, PNG / ICO / JPEG only, stored as PNG), the readable text read in
///   code (no WebView, no JavaScript, no `NSAttributedString(html:)`). A page with a password
///   field or under 500 characters of text keeps its title and host only. An `application/pdf`
///   answer is downloaded as a file (≤ 200 MB); `arxiv.org/abs/<id>` is read as its PDF.
///
/// Everything read is untrusted text: callers keep it as data.
public struct LinkFetcher: Sendable {
    /// What one fetch found.
    public enum Result: Sendable {
        /// A repository: its facts, its own description and its README (Markdown), if any.
        case repository(facts: MaterialFacts, title: String, description: String, readme: String?)
        /// A page: title, description, readable text (nil: title only), its facts (site name,
        /// favicon, title-only).
        case page(title: String, description: String, text: String?, facts: MaterialFacts)
        /// A PDF behind the link, downloaded to `file` (a temporary file the caller moves away).
        case pdf(file: URL, url: URL)
        /// GitHub's rate limit: try again after `until`.
        case rateLimited(until: Date)
        /// It could not be read: one readable sentence.
        case failed(String)
    }

    public static let unreachable = "The page could not be reached."
    public static let repositoryMissing = "This repository could not be found."
    static let faviconBytes = 64 * 1_024
    static let minimumText = 500

    public let fetch: PublicFetch
    public let paths: AppPaths

    public init(paths: AppPaths, fetch: PublicFetch = PublicFetch(userAgent: MaterialCalls.userAgent, timeout: MaterialCalls.fetchTimeout)) {
        self.paths = paths
        self.fetch = fetch
    }

    // MARK: - Addresses

    /// The URL as it is fetched: a scheme added to a bare "github.com/…" ("https://"), arXiv's
    /// abstract page as its PDF. Nil when it is no web address.
    public static func normalized(_ url: URL) -> URL? {
        var text = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.scheme == nil { text = "https://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        return components.url
    }

    /// Whether the link is fetched at all: public https only (`PublicHost`'s name rules; the
    /// addresses are checked when it is fetched). Anything else is kept as a link card.
    public static func isFetchable(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host(percentEncoded: false) else { return false }
        return PublicHost.allowsName(host)
    }

    /// A GitHub repository link: owner, repo and the linked folder (`tree/<branch>/<path>`).
    public static func repository(_ url: URL) -> (owner: String, repo: String, branch: String?, path: String?)? {
        guard let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let reserved: Set<String> = ["orgs", "settings", "marketplace", "topics", "explore", "features", "login", "sponsors", "about"]
        guard !reserved.contains(parts[0].lowercased()) else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        var branch: String?
        var path: String?
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            branch = parts[3]
            if parts.count > 4 { path = parts[4...].joined(separator: "/") }
        }
        return (parts[0], repo, branch, path)
    }

    /// "example-org/ds-labs", else the host without "www.".
    public static func displayTitle(_ url: URL) -> String {
        if let repository = repository(url) { return "\(repository.owner)/\(repository.repo)" }
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// arXiv's abstract page read as its PDF.
    static func arxivPDF(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host == "arxiv.org" || host == "www.arxiv.org", url.path.hasPrefix("/abs/") else { return nil }
        let id = url.path.dropFirst("/abs/".count)
        return URL(string: "https://arxiv.org/pdf/\(id)")
    }

    // MARK: - Fetching

    public func read(_ link: URL) async -> Result {
        guard let url = Self.normalized(link), Self.isFetchable(url) else { return .failed(Self.unreachable) }
        if let repository = Self.repository(url) { return await readRepository(repository) }
        if let pdf = Self.arxivPDF(url) { return await download(pdf) }
        if url.pathExtension.lowercased() == "pdf" { return await download(url) }
        guard let response = await fetch.get(url, headers: ["Accept": "text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.5"],
                                              maximumBytes: MaterialCalls.fetchBytes)
        else { return .failed(Self.unreachable) }
        guard response.isSuccess else { return .failed(Self.unreachable) }
        if response.contentType.contains("application/pdf") { return await download(response.url) }
        let html = String(decoding: response.data, as: UTF8.self)
        var page = HTMLPage(html)
        var facts = MaterialFacts(siteName: page.siteName)
        if let icon = await favicon(page.iconURL(base: response.url) ?? URL(string: "/favicon.ico", relativeTo: response.url)?.absoluteURL) {
            facts.faviconHash = icon
        }
        let title = page.title.isEmpty ? Self.displayTitle(response.url) : page.title
        let text = page.readableText
        if page.hasPasswordField || text.count < Self.minimumText {
            facts.isTitleOnly = true
            page.description = page.hasPasswordField ? "" : page.description
            return .page(title: title, description: page.description, text: nil, facts: facts)
        }
        return .page(title: title, description: page.description, text: String(text.prefix(MaterialCalls.snapshotCharacters)), facts: facts)
    }

    /// A PDF behind a link, into a temporary file (≤ 200 MB).
    func download(_ url: URL) async -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Socrates-link-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed(Self.unreachable)
        }
        var name = url.lastPathComponent.isEmpty ? "Paper" : url.lastPathComponent
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }
        let file = directory.appending(path: name)
        guard let response = await fetch.download(url, to: file, maximumBytes: MaterialCalls.maximumFileBytes), response.isSuccess else {
            try? FileManager.default.removeItem(at: directory)
            return .failed(Self.unreachable)
        }
        // Only a PDF is kept (a page that said otherwise is not a file material).
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 5)
        }
        guard head == Data("%PDF-".utf8) else {
            try? FileManager.default.removeItem(at: directory)
            return .failed(Self.unreachable)
        }
        return .pdf(file: file, url: response.url)
    }

    // MARK: GitHub

    func readRepository(_ repository: (owner: String, repo: String, branch: String?, path: String?)) async -> Result {
        let owner = repository.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository.owner
        let repo = repository.repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repository.repo
        guard let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else { return .failed(Self.repositoryMissing) }
        guard let response = await fetch.get(api, headers: ["Accept": "application/vnd.github+json"], maximumBytes: 256 * 1_024) else {
            return .failed(Self.unreachable)
        }
        if let until = Self.rateLimit(response) { return .rateLimited(until: until) }
        guard response.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else { return .failed(response.status == 404 ? Self.repositoryMissing : Self.unreachable) }
        var facts = MaterialFacts(owner: repository.owner, repo: repository.repo, path: repository.path)
        facts.defaultBranch = object["default_branch"] as? String
        facts.language = object["language"] as? String
        facts.license = (object["license"] as? [String: Any])?["spdx_id"] as? String
        facts.topics = (object["topics"] as? [String]).map { Array($0.prefix(12)) }
        facts.isArchived = object["archived"] as? Bool
        let title = (object["full_name"] as? String) ?? "\(repository.owner)/\(repository.repo)"
        let description = ((object["description"] as? String) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var readmePath = "readme"
        if let path = repository.path, !path.isEmpty {
            readmePath += "/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        }
        var readme: String?
        if let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/\(readmePath)"),
           let answer = await fetch.get(url, headers: ["Accept": "application/vnd.github.raw+json"], maximumBytes: MaterialCalls.fetchBytes) {
            if let until = Self.rateLimit(answer) { return .rateLimited(until: until) }
            if answer.isSuccess {
                let text = String(decoding: answer.data, as: UTF8.self)
                readme = text.isEmpty ? nil : String(text.prefix(MaterialCalls.snapshotCharacters))
            }
        }
        return .repository(facts: facts, title: title, description: String(description.prefix(CourseMaterial.summaryLimit)), readme: readme)
    }

    /// GitHub's 403/429 with a reset (`x-ratelimit-reset`, `retry-after`): when to try again.
    static func rateLimit(_ response: PublicFetch.Response) -> Date? {
        guard response.status == 403 || response.status == 429 else { return nil }
        if let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init) { return Date(timeIntervalSince1970: reset + 5) }
        if let wait = response.headers["retry-after"].flatMap(TimeInterval.init) { return Date().addingTimeInterval(wait + 5) }
        if response.headers["x-ratelimit-remaining"] == "0" { return Date().addingTimeInterval(3_600) }
        return nil
    }

    // MARK: Favicon

    /// The favicon (≤ 64 KB, PNG / ICO / JPEG, never SVG) stored as PNG in the favicon cache;
    /// its hash, or nil.
    func favicon(_ url: URL?) async -> String? {
        guard let url, url.scheme == "https" else { return nil }
        guard let response = await fetch.get(url, headers: ["Accept": "image/png,image/x-icon,image/jpeg"], maximumBytes: Self.faviconBytes + 1),
              response.isSuccess, !response.isTruncated, !response.data.isEmpty
        else { return nil }
        let bytes = [UInt8](response.data.prefix(4))
        let isPNG = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isICO = bytes.starts(with: [0x00, 0x00, 0x01, 0x00])
        let isJPEG = bytes.starts(with: [0xFF, 0xD8])
        guard isPNG || isICO || isJPEG, !response.contentType.contains("svg") else { return nil }
        guard let source = CGImageSourceCreateWithData(response.data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // The largest frame of an ICO.
        var best = 0
        var bestWidth = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > bestWidth { best = index; bestWidth = width }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, best, nil) else { return nil }
        let hash = String(SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined().prefix(16))
        let file = MaterialCovers.faviconURL(hash: hash, paths: paths)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return hash }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? hash : nil
    }
}

// MARK: - HTML

/// What a page's HTML says, read in code: title, description, site name, the icon link, whether
/// it asks for a password, and its readable text (script, style, nav, header, footer, aside and
/// forms dropped; `<main>` or `<article>` when present; block elements end lines). Never
/// rendered; the text is untrusted data.
struct HTMLPage {
    var title = ""
    var description = ""
    var siteName: String?
    var hasPasswordField = false
    private(set) var readableText = ""
    private var icon: String?

    init(_ html: String) {
        let head = String(html.prefix(200_000))
        var ogTitle: String?
        var ogDescription: String?
        var metaDescription: String?
        for tag in Self.tags(named: ["meta", "link", "input"], in: head) {
            let name = tag.name
            let attributes = tag.attributes
            if name == "meta" {
                let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
                let content = Self.decode(attributes["content"] ?? "")
                switch key {
                case "og:title": ogTitle = ogTitle ?? content
                case "og:description": ogDescription = ogDescription ?? content
                case "description": metaDescription = metaDescription ?? content
                case "og:site_name": siteName = siteName ?? content
                default: break
                }
            } else if name == "link" {
                let rel = (attributes["rel"] ?? "").lowercased().split(separator: " ")
                if rel.contains("icon"), let href = attributes["href"], !href.lowercased().hasSuffix(".svg"),
                   attributes["type"]?.lowercased().contains("svg") != true, icon == nil {
                    icon = Self.decode(href)
                }
            } else if (attributes["type"] ?? "").lowercased() == "password" {
                hasPasswordField = true
            }
        }
        let plainTitle = Self.element("title", in: head).map { Self.flatten(Self.decode($0)) }
        title = Self.clip(Self.flatten(ogTitle ?? plainTitle ?? ""), 200)
        description = Self.clip(Self.flatten(ogDescription ?? metaDescription ?? ""), CourseMaterial.summaryLimit)
        siteName = siteName.map { Self.clip(Self.flatten($0), 80) }
        readableText = Self.readable(html)
    }

    /// The icon's absolute https URL, else nil.
    func iconURL(base: URL) -> URL? {
        guard let icon, let url = URL(string: icon, relativeTo: base)?.absoluteURL, url.scheme == "https" else { return nil }
        return url
    }

    // MARK: Reading

    struct Tag {
        var name: String
        var attributes: [String: String]
    }

    /// Start tags of `names` with their attributes (names lower-cased).
    static func tags(named names: Set<String>, in html: String) -> [Tag] {
        guard let expression = try? NSRegularExpression(pattern: #"<([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>"#) else { return [] }
        var tags: [Tag] = []
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let nameRange = Range(match.range(at: 1), in: html), let attributesRange = Range(match.range(at: 2), in: html) else { continue }
            let name = html[nameRange].lowercased()
            guard names.contains(name) else { continue }
            tags.append(Tag(name: name, attributes: attributes(String(html[attributesRange]))))
        }
        return tags
    }

    static func attributes(_ text: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return [:] }
        var values: [String: String] = [:]
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            var value = ""
            for group in 2...4 {
                if let range = Range(match.range(at: group), in: text) {
                    value = String(text[range])
                    break
                }
            }
            let key = text[keyRange].lowercased()
            if values[key] == nil { values[key] = value }
        }
        return values
    }

    /// The inner HTML of the first `<name>` element.
    static func element(_ name: String, in html: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>(.*?)</\(name)\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    /// The page's text: comments and dropped elements removed, `<main>` / `<article>` when
    /// present, tags removed with block elements as line ends, entities decoded, whitespace runs
    /// collapsed, blank lines merged.
    static func readable(_ html: String) -> String {
        var text = html
        text = replacing(#"<!--.*?-->"#, in: text, with: " ")
        for name in ["script", "style", "noscript", "template", "svg", "nav", "header", "footer", "aside", "form", "iframe", "head", "button", "select"] {
            text = replacing("<\(name)\\b[^>]*>.*?</\(name)\\s*>", in: text, with: " ")
        }
        if let main = element("main", in: text) ?? element("article", in: text) { text = main }
        text = replacing(#"<(?:br|/p|/div|/li|/h[1-6]|/tr|/section|/pre|/blockquote|/dt|/dd|/table)\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"<li\b[^>]*>"#, in: text, with: "\n• ")
        text = replacing(#"<[^>]+>"#, in: text, with: " ")
        text = decode(text)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return lines.filter { !$0.isEmpty && $0 != "•" }.joined(separator: "\n")
    }

    static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    /// The common entities and numeric references.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
                     "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü", "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß"]
        for (entity, value) in named where output.contains(entity) { output = output.replacingOccurrences(of: entity, with: value) }
        guard output.contains("&#"), let expression = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]{1,6});"#) else { return output }
        var result = ""
        var last = output.startIndex
        for match in expression.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let range = Range(match.range, in: output), let hexRange = Range(match.range(at: 1), in: output),
                  let digitsRange = Range(match.range(at: 2), in: output) else { continue }
            result += output[last..<range.lowerBound]
            let radix = output[hexRange].isEmpty ? 10 : 16
            if let value = UInt32(output[digitsRange], radix: radix), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            }
            last = range.upperBound
        }
        result += output[last...]
        return result
    }

    static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clip(_ text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        return String(text.prefix(max(0, count - 1))) + "…"
    }
}
