import Foundation

/// The parts of `tailscale status --json` that name this machine.
///
/// **Why bother, when `ifconfig` already yields the addresses.** It does — the
/// tunnel's `utun` interface holds them and passes every filter, which is how
/// Tailscale worked here before any of this existed. What `ifconfig` cannot
/// give is the **MagicDNS name**, and that is the endpoint worth having: a
/// node's `100.64.0.0/10` address is stable while the node record lives, but
/// removing the machine from the tailnet and re-adding it mints a new one, and
/// endpoints are captured at pair time and never re-discovered. The name
/// follows the machine across that; the address does not.
///
/// Parsing lives here rather than in `BleatProcess` for the reason
/// `InterfaceAddresses` does: it compiles for iOS, and it can be tested against
/// a captured reply without running anything. `Fixtures/tailscale-status.json`
/// is a real reply with the identifiers replaced — the shape is the point, and
/// the real one carries node keys, a user's email and every peer on the tailnet.
public struct TailscaleStatus: Decodable, Sendable {
    public struct Node: Decodable, Sendable {
        /// **Comes back with a trailing dot** — `somemac.tailexample.ts.net.`
        /// — which is a fully qualified name and not what belongs in an
        /// endpoint. Verified against a live install, 7 Sept 2026.
        public let dnsName: String?
        public let tailscaleIPs: [String]?

        enum CodingKeys: String, CodingKey {
            case dnsName = "DNSName"
            case tailscaleIPs = "TailscaleIPs"
        }
    }

    public struct Tailnet: Decodable, Sendable {
        /// Whether the name resolves at all. A tailnet can have MagicDNS off,
        /// and then the name is decoration — storing it would add an endpoint
        /// that cannot resolve and costs a connection timeout every time the
        /// phone races, which is exactly what the endpoint filters exist to
        /// prevent.
        public let magicDNSEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case magicDNSEnabled = "MagicDNSEnabled"
        }
    }

    public let backendState: String?
    public let node: Node?
    public let tailnet: Tailnet?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case node = "Self"
        case tailnet = "CurrentTailnet"
    }

    /// Endpoints for this machine, or none.
    ///
    /// Returns nothing unless the backend is actually `Running`. A stopped or
    /// logged-out Tailscale still reports the last state it knew, and pairing
    /// on the strength of that would record an endpoint from a tailnet this
    /// machine may no longer be on — indistinguishable, later, from a host
    /// that is merely offline.
    ///
    /// The addresses are included as well as the name even though `ifconfig`
    /// normally finds them, because it only finds them when there is a `utun`
    /// to find: userspace-networking mode has no interface. They cost nothing
    /// when duplicated — the caller de-duplicates.
    public static func endpoints(fromStatusJSON data: Data, port: Int) -> [Endpoint] {
        guard let status = try? JSONDecoder().decode(Self.self, from: data),
              status.backendState == "Running"
        else { return [] }

        var endpoints: [Endpoint] = []
        if status.tailnet?.magicDNSEnabled == true, let name = status.node?.dnsName {
            let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
            if !trimmed.isEmpty { endpoints.append(Endpoint(host: trimmed, port: port)) }
        }
        for address in status.node?.tailscaleIPs ?? [] where !address.isEmpty {
            endpoints.append(Endpoint(host: address, port: port))
        }
        return endpoints
    }
}
