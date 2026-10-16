import Foundation

/// Retries for 408, 409, 429, 5xx (incl. 529 overloaded) and connection errors, with exponential
/// backoff and jitter. A `retry-after` header (≤ 60 s) takes precedence; `x-should-retry` overrides
/// the status-based decision either way.
public struct RetryPolicy: Sendable, Hashable {
    /// Retries after the first attempt (2 means up to 3 attempts).
    public var maxRetries: Int
    public var initialDelay: Duration
    public var maxDelay: Duration
    /// The longest server-requested `retry-after` that is honoured as-is.
    public var maxRetryAfter: Duration
    /// Fraction of each backoff delay removed at random (0 disables jitter).
    public var jitter: Double

    public init(
        maxRetries: Int = 2, initialDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(8),
        maxRetryAfter: Duration = .seconds(60), jitter: Double = 0.25
    ) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
        self.jitter = jitter
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxRetries: 0)

    public static func isRetryableStatus(_ status: Int) -> Bool {
        status == 408 || status == 409 || status == 429 || status >= 500
    }

    static func isRetryableURLErrorCode(_ code: Int) -> Bool {
        let retryable: Set<URLError.Code> = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .notConnectedToInternet, .secureConnectionFailed,
        ]
        return retryable.contains(URLError.Code(rawValue: code))
    }

    /// Whether a failed attempt should be retried, given the status and response headers.
    public func shouldRetry(status: Int, headers: [String: String]) -> Bool {
        switch headers["x-should-retry"]?.lowercased() {
        case "true": true
        case "false": false
        default: Self.isRetryableStatus(status)
        }
    }

    /// Delay before retry number `retry` (0-based), preferring a server-requested delay.
    /// `random` returns a value in 0..<1 (injectable for tests).
    public func delay(beforeRetry retry: Int, retryAfter: Duration?, random: () -> Double = { Double.random(in: 0..<1) })
        -> Duration
    {
        if let retryAfter, retryAfter >= .zero, retryAfter <= maxRetryAfter {
            return retryAfter
        }
        let exponent = min(retry, 16)
        let base = min(initialDelay * Int(1 << exponent), maxDelay)
        let factor = 1 - jitter * min(max(random(), 0), 1)
        return base * factor
    }

    /// Parses `retry-after-ms` (milliseconds) or `retry-after` (seconds or an HTTP date).
    public static func retryAfter(headers: [String: String], now: Date = Date()) -> Duration? {
        if let value = headers["retry-after-ms"].flatMap(Double.init), value >= 0 {
            return .milliseconds(Int(value.rounded()))
        }
        guard let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Double(value), seconds >= 0 {
            return .milliseconds(Int((seconds * 1000).rounded()))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return .milliseconds(max(0, Int((date.timeIntervalSince(now) * 1000).rounded())))
        }
        return nil
    }
}
