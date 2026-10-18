import Darwin
import Foundation

/// Which hosts the app's own source check may reach (M5, docs/plan-m5.md §5.1: SSRF from
/// prompt-injected pages). A research run names URLs a web page could have planted; the check
/// fetches them from the student's Mac, so a URL must never reach the Mac itself, the local
/// network or a link-local service. Only public hosts over https:
///
/// - refused names: `localhost` and `*.localhost`, `*.local` (mDNS), `*.internal`, and single-label
///   names ("router", "nas"), which only resolve through local search domains;
/// - refused addresses (IP literals, and every address a name resolves to): loopback
///   (127/8, ::1), private (10/8, 172.16/12, 192.168/16, 100.64/10 shared, fc00::/7 unique
///   local), link-local (169.254/16, fe80::/10), unspecified (0/8, ::), multicast (224/4,
///   ff00::/8) and the reserved 240/4 (broadcast); IPv4-mapped, -compatible and NAT64 IPv6
///   addresses by their IPv4 part; the old site-local fec0::/10.
///
/// The name is resolved with `getaddrinfo` off the caller's executor; a name that does not
/// resolve is refused. Redirect hops get the same check (`WebCheck.RedirectGuard`). URLSession
/// resolves again when it connects, so a name that changes its answer in between (DNS
/// rebinding) is not caught; the check only reads public pages' titles, never sends anything.
enum PublicHost {
    /// The URL is https and its host passes `allowsName` and resolves only to public addresses.
    static func allows(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false), allowsName(host) else {
            return false
        }
        let bare = bareHost(host)
        if isIPLiteral(bare) { return true }
        return await resolvesPublicly(bare)
    }

    /// The host's text alone (no resolution): not a local name, and an IP literal must be public.
    static func allowsName(_ host: String) -> Bool {
        let name = bareHost(host)
        guard !name.isEmpty else { return false }
        if let v4 = ipv4(name) { return isPublic(v4: v4) }
        if let v6 = ipv6(name) { return isPublic(v6: v6) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
        for suffix in ["localhost", "local", "internal"] where name == suffix || name.hasSuffix("." + suffix) {
            return false
        }
        // No top-level domain is numeric: "0x7f.1" or "127.1" are IPv4 addresses in other spellings.
        if labels.last?.allSatisfy(\.isNumber) == true { return false }
        return true
    }

    /// Lower case, without brackets ("[::1]") or a trailing dot.
    static func bareHost(_ host: String) -> String {
        var name = host.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    static func isIPLiteral(_ host: String) -> Bool {
        ipv4(host) != nil || ipv6(host) != nil
    }

    // MARK: Resolution

    /// Every address `host` resolves to is public; false when it does not resolve. Runs
    /// `getaddrinfo` (blocking) on the concurrent executor, never on an actor.
    @concurrent
    static func resolvesPublicly(_ host: String) async -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var seen = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ai_next }
            guard let address = entry.pointee.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                // `s_addr` is in network byte order.
                let bytes = withUnsafeBytes(of: raw) { Array($0) }
                guard isPublic(v4: bytes) else { return false }
                seen = true
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
                guard isPublic(v6: bytes) else { return false }
                seen = true
            default:
                continue
            }
        }
        return seen
    }

    // MARK: Addresses

    /// The four bytes of a dotted IPv4 literal ("10.0.0.1"); nil otherwise.
    static func ipv4(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    /// The sixteen bytes of an IPv6 literal ("::1", "fe80::1%en0"); nil otherwise.
    static func ipv6(_ text: String) -> [UInt8]? {
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var value = in6_addr()
        guard inet_pton(AF_INET6, address, &value) == 1 else { return nil }
        return withUnsafeBytes(of: value) { Array($0) }
    }

    static func isPublic(v4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let (a, b) = (bytes[0], bytes[1])
        switch a {
        case 0, 10, 127: return false                       // unspecified, private, loopback
        case 100 where (64...127).contains(b): return false // 100.64/10 shared address space
        case 169 where b == 254: return false               // link-local
        case 172 where (16...31).contains(b): return false  // 172.16/12
        case 192 where b == 168: return false               // 192.168/16
        case 224...255: return false                        // multicast 224/4, reserved 240/4, broadcast
        default: return true
        }
    }

    static func isPublic(v6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let prefixZero = bytes[0..<10].allSatisfy { $0 == 0 }
        // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible): the IPv4 part decides.
        if prefixZero, bytes[10] == 0xff, bytes[11] == 0xff { return isPublic(v4: Array(bytes[12..<16])) }
        if prefixZero, bytes[10] == 0, bytes[11] == 0 {
            // :: (unspecified), ::1 (loopback) and the deprecated compatible form.
            let tail = Array(bytes[12..<16])
            if tail.allSatisfy({ $0 == 0 }) { return false }
            if tail == [0, 0, 0, 1] { return false }
            return isPublic(v4: tail)
        }
        // 64:ff9b::/96 (NAT64): the IPv4 part decides.
        if bytes[0..<12].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return isPublic(v4: Array(bytes[12..<16]))
        }
        if bytes[0] & 0xfe == 0xfc { return false }                     // fc00::/7 unique local
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }   // fe80::/10 link-local
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0xc0 { return false }   // fec0::/10 site-local (old)
        if bytes[0] == 0xff { return false }                            // ff00::/8 multicast
        return true
    }
}
