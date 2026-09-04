import Foundation

/// One way to reach a peer: an address and a port, plus how far it carries.
///
/// A peer is not an address (see `PairedPeer`), so endpoints are plural and
/// ordered. The classification exists to stop the phone spending its timeout
/// budget on addresses that provably cannot work from where it is standing.
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Hostname or literal address. IPv6 is stored bare, without brackets.
    public let host: String
    public let port: Int

    public init(host: String, port: Int = 22) {
        self.host = host
        self.port = port
    }

    /// How far an endpoint carries, which decides whether it is worth trying.
    public enum Reach: Sendable, Hashable {
        /// mDNS names and private addresses. Reachable only on the same link.
        case lan
        /// A mesh VPN's own address space — Tailscale's CGNAT and ULA ranges.
        /// Private-looking, but routed by the tunnel, so it works from anywhere
        /// the tunnel is up, including cellular.
        case overlay
        /// A globally routable address or a public DNS name.
        case routable
    }

    /// Tailscale hands out `100.64.0.0/10` (CGNAT) and `fd7a:115c:a1e0::/48`.
    ///
    /// Both look private to the usual tests — CGNAT is not RFC1918 but is
    /// non-global, and the v6 range is a ULA. Classifying them as `.lan` would
    /// make the phone skip the one endpoint that actually works on cellular,
    /// so they are matched before the private-address checks below.
    public var reach: Reach {
        let name = host.lowercased()
        if Self.isTailscale(name) { return .overlay }
        if name.hasSuffix(".local") || name.hasSuffix(".local.") { return .lan }
        if Self.isPrivateAddress(name) { return .lan }
        return .routable
    }

    /// Whether this endpoint is worth attempting when off the local link.
    ///
    /// `.local` cannot resolve and RFC1918 cannot route once the phone is on
    /// cellular; attempting them only spends the timeout.
    public var isUsableOffLink: Bool { reach != .lan }

    /// `host:port`, bracketing IPv6 so the result can be parsed back.
    ///
    /// This string **is** the wire format — `PairingPayload` encodes endpoints
    /// as `map(\.description)` — so the `CustomStringConvertible` conformance
    /// is load-bearing, not cosmetic. Without it `"\(endpoint)"` yields the
    /// synthesised `Endpoint(host:port:)` reflection, which `Endpoint(string:)`
    /// cannot parse back; for an IPv6 endpoint that would reject the whole
    /// payload.
    public var description: String {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        // `:22` on every endpoint is three characters each of pure redundancy,
        // and the QR pays for all of them. `Endpoint(string:)` defaults to 22,
        // so this still round-trips.
        return port == Self.defaultPort ? bracketed : "\(bracketed):\(port)"
    }

    public static let defaultPort = 22

    /// Parses `host`, `host:port`, `[v6]` or `[v6]:port`.
    ///
    /// Brackets are what make a bare IPv6 literal unambiguous: `fe80::1` is all
    /// host and no port, while `[fe80::1]:22` is both. An unbracketed literal
    /// with more than one colon is therefore read as a whole address, matching
    /// how the console tool already parses `user@host`.
    /// - Parameter defaultPort: Used when the string carries no port of its
    ///   own. A user passing `--endpoint host` alongside `--port 2222` means
    ///   that host on 2222; silently defaulting it to 22 produces an endpoint
    ///   that looks right in the list and refuses every connection.
    public init?(string: String, defaultPort: Int = 22) {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let inner = String(text[text.index(after: text.startIndex)..<close])
            guard !inner.isEmpty else { return nil }
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { self.init(host: inner, port: defaultPort); return }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()),
                  (1...65535).contains(port)
            else { return nil }
            self.init(host: inner, port: port)
            return
        }

        let colons = text.filter { $0 == ":" }.count
        if colons == 0 { self.init(host: text, port: defaultPort); return }
        if colons > 1 { self.init(host: text, port: defaultPort); return }   // bare IPv6 literal
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty,
              let port = Int(parts[1]), (1...65535).contains(port)
        else { return nil }
        self.init(host: String(parts[0]), port: port)
    }

    // MARK: - Classification

    static func isTailscale(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") || host.hasSuffix(".ts.net.") { return true }
        if host.hasPrefix("fd7a:115c:a1e0:") { return true }
        // 100.64.0.0/10 — the second octet runs 64...127, and only for 100.x.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "100",
              let second = Int(parts[1]), (64...127).contains(second),
              parts[2...].allSatisfy({ Int($0) != nil })
        else { return false }
        return true
    }

    static func isPrivateAddress(_ host: String) -> Bool {
        // The v6 prefixes only mean anything in something that is actually an
        // address: `fdisk.example.com` starts with "fd" and is a public name.
        if host.contains(":") {
            if host.hasPrefix("fe80:") { return true }           // link-local
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }  // ULA, fc00::/7
        }
        if host == "::1" || host == "localhost" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }),
              let first = Int(parts[0]), let second = Int(parts[1])
        else { return false }
        switch (first, second) {
        case (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
