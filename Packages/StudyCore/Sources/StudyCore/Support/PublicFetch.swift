import Foundation

/// The app's one way to read public web pages (M5's source check, moved from StudyPass's
/// `WebCheck` in mt for the links of course materials; DESIGN 1.4: moved, never copied): an
/// ephemeral `URLSession` (no cookies, no cache, no credentials, no tokens), GET only, https only
/// and public hosts only (`PublicHost`: the first request and every redirect hop; a refused hop
/// ends with the redirect's own 3xx), a time limit and a byte limit. What it reads is untrusted
/// data: callers never follow it, and delimit it as data in every model call.
public struct PublicFetch: Sendable {
    /// One answer: any status (callers decide; GitHub's 403/429 carry a reset), the bytes read
    /// (at most the limit), the lower-cased content type and the final URL after redirects.
    public struct Response: Sendable {
        public var status: Int
        public var data: Data
        public var contentType: String
        public var url: URL
        /// Response headers, names lower-cased.
        public var headers: [String: String]
        /// The body was cut at the byte limit.
        public var isTruncated: Bool

        public var isSuccess: Bool { (200..<300).contains(status) }
    }

    public let session: URLSession
    /// `download`'s session: the same settings, `timeout` between bytes, `downloadTimeout` in all.
    public let downloadSession: URLSession
    public let timeout: TimeInterval
    public let downloadTimeout: TimeInterval

    /// `userAgent`: "Socrates/1 (source check)", `MaterialCalls.userAgent`.
    public init(userAgent: String, timeout: TimeInterval = 8, downloadTimeout: TimeInterval = 120) {
        session = URLSession(configuration: Self.configuration(userAgent: userAgent, idle: timeout, total: timeout))
        downloadSession = URLSession(configuration: Self.configuration(userAgent: userAgent, idle: timeout, total: max(timeout, downloadTimeout)))
        self.timeout = timeout
        self.downloadTimeout = max(timeout, downloadTimeout)
    }

    /// Ephemeral: no cookies, no cache, no credentials; `idle` between bytes, `total` in all.
    static func configuration(userAgent: String, idle: TimeInterval, total: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = idle
        configuration.timeoutIntervalForResource = total
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    /// GET `url` with at most `maximumBytes` read within the time limit. Nil when the host is not
    /// public https (also a redirect hop), on a network error or at the time limit. `headers`:
    /// request headers such as `Accept` (never credentials).
    public func get(_ url: URL, headers: [String: String] = [:], maximumBytes: Int) async -> Response? {
        guard await PublicHost.allows(url) else {
            Log.web.notice("A fetch refused a non-public host")
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (name, value) in headers where name.lowercased() != "authorization" && name.lowercased() != "cookie" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let prepared = request
        let session = session
        let timeout = timeout
        do {
            return try await withThrowingTaskGroup(of: Response?.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: prepared, delegate: RedirectGuard())
                    guard let http = response as? HTTPURLResponse else { return nil }
                    var data = Data()
                    data.reserveCapacity(min(maximumBytes, 64 << 10))
                    var truncated = false
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= maximumBytes {
                            truncated = true
                            break
                        }
                    }
                    return Response(
                        status: http.statusCode, data: data, contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
                        url: http.url ?? url, headers: Self.headers(of: http), isTruncated: truncated
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            Log.web.info("A fetch failed for \(url.host ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// GET `url` into the file `destination` (a PDF behind a link, ≤ `maximumBytes`; the time
    /// limit is `timeout` for the first byte and between bytes, and `downloadTimeout` in all, at
    /// most the session's). Returns the response with empty `data` (the bytes are in the file);
    /// nil as `get`, or when the file would be larger (the partial file is removed).
    public func download(
        _ url: URL, to destination: URL, maximumBytes: Int, downloadTimeout limit: TimeInterval? = nil
    ) async -> Response? {
        let downloadTimeout = min(limit ?? self.downloadTimeout, self.downloadTimeout)
        guard await PublicHost.allows(url) else {
            Log.web.notice("A download refused a non-public host")
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let prepared = request
        let session = downloadSession
        do {
            return try await withThrowingTaskGroup(of: Response?.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: prepared, delegate: RedirectGuard())
                    guard let http = response as? HTTPURLResponse else { return nil }
                    FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
                    let handle = try FileHandle(forWritingTo: destination)
                    defer { try? handle.close() }
                    var buffer = Data()
                    buffer.reserveCapacity(1 << 20)
                    var written = 0
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 1 << 20 {
                            try handle.write(contentsOf: buffer)
                            written += buffer.count
                            buffer.removeAll(keepingCapacity: true)
                        }
                        if written + buffer.count > maximumBytes {
                            try? FileManager.default.removeItem(at: destination)
                            return nil
                        }
                    }
                    try handle.write(contentsOf: buffer)
                    return Response(
                        status: http.statusCode, data: Data(), contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
                        url: http.url ?? url, headers: Self.headers(of: http), isTruncated: false
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(downloadTimeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Log.web.info("A download failed for \(url.host ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return headers
    }

    /// Refuses a redirect hop to anything but a public https host (`PublicHost`).
    public final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        public func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let url = request.url, await PublicHost.allows(url) else {
                Log.web.notice("A fetch refused a redirect to a non-public host")
                return nil
            }
            return request
        }
    }
}
