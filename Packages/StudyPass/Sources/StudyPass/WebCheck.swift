import CoreGraphics
import Deadlines
import Foundation
import StudyCore

/// The app's own check of a source the research run named (plan §4 "Web"): an ephemeral
/// `URLSession` (no cookies, no cache), GET over https only, 8 s, at most 1 MB read. A source is
/// kept when the answer is 2xx and at least 70 % of the title's words appear in the page's
/// `<title>`, its `citation_title`, or its first 64 KB of text (a PDF: its Title metadata). A DOI
/// is checked against `api.crossref.org/works/<doi>` instead. Pages are data: nothing in them is
/// followed or shown.
struct WebCheck: Sendable {
    struct Verified: Sendable {
        /// What the further-reading row links to.
        var url: URL
        /// The text the title was found in (bylines' numbers are checked against it).
        var pageText: String
    }

    static let timeout: TimeInterval = 8
    static let maximumBytes = 1 << 20
    static let textPrefixBytes = 64 << 10
    static let requiredShare = 0.7

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "StudyPortal/1 (source check)"]
        session = URLSession(configuration: configuration)
    }

    /// The source when the check confirms it, else nil.
    func verify(title: String, url: String, doi: String?) async -> Verified? {
        let words = TextFolding.titleWords(title)
        guard !words.isEmpty else { return nil }
        if let doi {
            guard let text = await crossref(doi), Self.share(of: words, in: text) >= Self.requiredShare else { return nil }
            let link = URL(string: url).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
                ?? URL(string: "https://doi.org/" + doi)
            return link.map { Verified(url: $0, pageText: text) }
        }
        guard let link = URL(string: url), link.scheme?.lowercased() == "https", link.host != nil,
              case let (data, type, final)? = await fetch(link) else { return nil }
        let text = Self.searchableText(data, contentType: type)
        guard Self.share(of: words, in: text) >= Self.requiredShare else { return nil }
        return Verified(url: final.scheme?.lowercased() == "https" ? final : link, pageText: text)
    }

    // MARK: Fetching

    /// GET with the 8 s and 1 MB limits: the bytes, the content type and the final URL; nil
    /// unless 2xx.
    func fetch(_ url: URL) async -> (Data, String, URL)? {
        let request: URLRequest = {
            var request = URLRequest(url: url, timeoutInterval: Self.timeout)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            return request
        }()
        let session = session
        do {
            return try await withThrowingTaskGroup(of: (Data, String, URL)?.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                    var data = Data()
                    data.reserveCapacity(64 << 10)
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= Self.maximumBytes { break }
                    }
                    let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                    return (data, type.lowercased(), http.url ?? url)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            StudyPass.log.info("Source check failed for \(url.host ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Crossref's record of a DOI as text (titles, container, authors, years); nil when unknown.
    func crossref(_ doi: String) async -> String? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/" + encoded),
              case let (data, _, _)? = await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        for key in ["title", "subtitle", "container-title", "short-container-title", "publisher"] {
            if let values = message[key] as? [String] { parts += values } else if let value = message[key] as? String { parts.append(value) }
        }
        for author in message["author"] as? [[String: Any]] ?? [] {
            parts += [author["family"] as? String, author["given"] as? String, author["name"] as? String].compactMap { $0 }
        }
        for key in ["issued", "published-print", "published-online", "published"] {
            if let date = message[key] as? [String: Any], let parts2 = date["date-parts"] as? [[Int]] {
                parts += parts2.flatMap { $0.map(String.init) }
            }
        }
        let text = parts.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    // MARK: Matching

    /// `<title>`, `citation_title` and the first 64 KB of text of an HTML page; a PDF's Title
    /// metadata; else the first 64 KB as text.
    static func searchableText(_ data: Data, contentType: String) -> String {
        if contentType.contains("pdf") || data.starts(with: Data("%PDF".utf8)) {
            return pdfTitle(data) ?? ""
        }
        let whole = String(decoding: data, as: UTF8.self)
        var parts: [String] = []
        if let title = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: whole) { parts.append(title) }
        if let citation = firstMatch(#"<meta[^>]+name=["']citation_title["'][^>]*content=["']([^"']*)["']"#, in: whole)
            ?? firstMatch(#"<meta[^>]+content=["']([^"']*)["'][^>]*name=["']citation_title["']"#, in: whole) {
            parts.append(citation)
        }
        let prefix = String(decoding: data.prefix(textPrefixBytes), as: UTF8.self)
        parts.append(prefix.replacing(#/<[^>]*>/#, with: " "))
        return entities(parts.joined(separator: " "))
    }

    /// Share of `words` (title words, folded) found among the words of `text`.
    static func share(of words: Set<String>, in text: String) -> Double {
        guard !words.isEmpty else { return 0 }
        let found = Set(TextFolding.words(entities(text)))
        return Double(words.filter(found.contains).count) / Double(words.count)
    }

    /// "10.1145/945445.945462" from a bare DOI, "doi:…" or a doi.org link; nil otherwise.
    static func normalizedDOI(_ text: String) -> String? {
        var doi = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:", "DOI:"] where doi.hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count))
        }
        guard doi.hasPrefix("10."), doi.contains("/"), doi.count <= 200, !doi.contains(where: \.isWhitespace) else { return nil }
        return doi
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func entities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// A PDF's Title metadata (Core Graphics, no PDFKit).
    static func pdfTitle(_ data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let info = document.info else { return nil }
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Title", &value), let value,
              let title = CGPDFStringCopyTextString(value) else { return nil }
        return title as String
    }
}
