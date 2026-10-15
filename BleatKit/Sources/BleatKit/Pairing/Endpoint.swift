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

    /// The host is **lower-cased**, and that is not cosmetic.
    ///
    /// DNS is case-insensitive and `Equatable`/`Hashable` are not, so without
    /// this `Studio-Mac.local` and `studio-mac.local` are two endpoints for one
    /// machine. Every comparison in the refresh path runs on that equality:
    /// de-duplication, `Report.superseded`, `endpoints.contains`, the
    /// `lastGoodEndpoint` match. A differently-cased duplicate is therefore
    /// never pruned — the host reports one form, so the other looks like an
    /// address it never claimed and is sticky forever — and every race from
    /// then on dials the same host twice.
    ///
    /// Reachable two ways: a user typing an address by hand, and
    /// `scutil --get LocalHostName`, which is not guaranteed to answer in the
    /// same case twice. Normalising at the door closes both, and costs nothing
    /// — the wire format round-trips through `description` either way, and
    /// `reach` was already lower-casing to classify.
    public init(host: String, port: Int = Endpoint.defaultPort) {
        self.host = host.lowercased()
        self.port = port
    }

    /// How far an endpoint carries, which decides whether it is worth trying.
    ///
    /// `lan` used to cover both of the first two cases. They were split because
    /// a tunnel treats them differently: a VPN can route a private subnet from
    /// anywhere — which is precisely what a zero-trust client like Twingate
    /// does — while nothing carries multicast DNS off the link it is scoped to.
    public enum Reach: Sendable, Hashable {
        /// Scoped to the link it is on, with **nothing that can carry it off**:
        /// an mDNS `.local` name, a loopback address, an IPv4 or IPv6
        /// link-local.
        ///
        /// Loopback and link-local belong here rather than with the private
        /// addresses, and the difference is not academic. A VPN routes
        /// `192.168.1.20`; no VPN routes `127.0.0.1`, `::1` or `fe80::1` —
        /// those name this device or this wire. Filed as private, each would
        /// become a candidate the moment any tunnel came up, and cost a full
        /// TCP timeout in the race for a destination that cannot exist.
        /// `127.0.0.1:2222` is not hypothetical: it is what the throwaway-sshd
        /// flow in this repo's own test procedure uses, and endpoints can be
        /// added by hand.
        case linkScoped
        /// An RFC1918 or ULA address. Routable on the attached link, and also
        /// through any VPN that carries that subnet.
        case privateAddress
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
        // Multicast DNS, then the addresses nothing routes — both before the
        // private test, which would otherwise claim them and let a tunnel
        // license a dial that can never connect.
        if name.hasSuffix(".local") || name.hasSuffix(".local.") { return .linkScoped }
        if Self.isLinkScoped(name) { return .linkScoped }
        if Self.isPrivateAddress(name) { return .privateAddress }
        return .routable
    }

    /// Whether this endpoint is worth attempting from where the phone is.
    ///
    /// Attempting one that provably cannot work is not free: every candidate
    /// costs a socket and a full TCP timeout in `PeerConnector`'s race, and the
    /// failure message counts them. So the rule drops what cannot work rather
    /// than ordering it last.
    ///
    /// The private-address case is the one that changed. It was dropped
    /// whenever the phone left Wi-Fi — correct for a bare cellular connection,
    /// and wrong for the case that prompted this: with a zero-trust client like
    /// Twingate up, the host's ordinary `192.168.x` address is routable from
    /// cellular, and it is *the* address that works, because that kind of
    /// overlay gives the host no address of its own to discover. Dropping it
    /// meant the one candidate that would have connected was never dialled.
    public func isUsable(from link: LinkState) -> Bool {
        switch reach {
        case .linkScoped: link.onLocalLink
        case .privateAddress: link.onLocalLink || link.tunnelActive
        case .overlay, .routable: true
        }
    }

    /// Whether reaching this endpoint *from here* takes a tunnel.
    ///
    /// Link-dependent, which is the whole reason it is a function rather than a
    /// property on `Reach`. A mesh address always needs one. An ordinary
    /// private address needs one only off the local link — on Wi-Fi it is
    /// simply the network the phone is standing on, and a failure there means
    /// the host is asleep rather than that a VPN wants checking.
    ///
    /// This is what decides whether a failed race names the VPN, and getting it
    /// wrong in either direction sends the user to fix something that is not
    /// broken.
    public func needsTunnel(from link: LinkState) -> Bool {
        switch reach {
        case .overlay: true
        case .privateAddress: !link.onLocalLink
        case .linkScoped, .routable: false
        }
    }

    /// Whether this endpoint can work from cellular with no tunnel at all —
    /// the strictest case, which is what `bleat inspect` warns a user about.
    public var isUsableOffLink: Bool { isUsable(from: .offLink) }

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

    /// The port left out of `description`.
    ///
    /// Both initialisers default to this too. Consulting it only on the write
    /// side would mean changing it emits endpoints with no port that parse back
    /// as 22 — and since `description` *is* the QR wire format, that would ship
    /// endpoints pointing at the wrong port.
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
    public init?(string: String, defaultPort: Int = Endpoint.defaultPort) {
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

    /// Whether a string a *user typed* is plausibly a host at all.
    ///
    /// `Endpoint(string:)` is a parser, not a validator: anything with no colon
    /// is taken as a hostname verbatim, so `robin@mac.internal` — a very
    /// natural paste — `ssh mac.local`, and `mac.local/foo` all sail through.
    /// That matters more here than it looks. An address the user adds by hand
    /// is invisible to detection, so it is **permanently sticky**: it can never
    /// be pruned by a refresh, and it is dialled in every race from then on,
    /// costing a full connect timeout each time and inflating the "none of N
    /// address(es) could be reached" count that explains the failure.
    ///
    /// Deliberately a plausibility check rather than a grammar. The point is to
    /// catch the shapes a person actually pastes — a `user@host`, a command, a
    /// URL path — not to adjudicate hostname syntax, which would reject valid
    /// internal names.
    public static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        // A bare IPv6 literal is the one legitimate reason to hold colons, and
        // `Endpoint(string:)` has already stripped any brackets and port.
        let rejected: Set<Character> = ["@", "/", "\\", "?", "#", "%", "\"", "'", ",", "[", "]"]
        guard !host.contains(where: { $0.isWhitespace || rejected.contains($0) }) else {
            return false
        }
        if host.contains(":") { return true }   // IPv6 literal
        guard host != ".", !host.hasPrefix("."), !host.hasSuffix("..") else { return false }
        return !host.contains("..")
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

    /// Addresses that name this device or this wire, which no tunnel routes.
    ///
    /// Split out of `isPrivateAddress` so a tunnel cannot license them. They
    /// stay perfectly usable on the local link — `bleat redeem` against a
    /// throwaway sshd on `127.0.0.1:2222` is a documented flow — which is why
    /// they are `.linkScoped` rather than dropped outright.
    static func isLinkScoped(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        // The v6 prefix only means anything in something that is actually an
        // address: `fe80s-diner.example` is a public name.
        if host.contains(":") { return host.hasPrefix("fe80:") }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }),
              let first = Int(parts[0]), let second = Int(parts[1])
        else { return false }
        return first == 127 || (first == 169 && second == 254)
    }

    static func isPrivateAddress(_ host: String) -> Bool {
        // The v6 prefixes only mean anything in something that is actually an
        // address: `fdisk.example.com` starts with "fd" and is a public name.
        // Loopback and link-local have already been taken by `isLinkScoped`.
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd")  // ULA, fc00::/7
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }),
              let first = Int(parts[0]), let second = Int(parts[1])
        else { return false }
        switch (first, second) {
        case (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
