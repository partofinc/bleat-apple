import Foundation

/// Where the phone is standing, as far as reaching a peer is concerned.
///
/// Two independent facts rather than one, because the addresses they license
/// are different. This used to be a single `onLocalLink: Bool`, which quietly
/// assumed that anything private needs the attached link — true until a VPN
/// carries the private subnet, which is exactly what Twingate does.
///
/// Lives in `BleatKit`, with no `Network` import, so the rules it feeds are
/// testable. `Reachability` in `BleatUI` is the part that answers the two
/// questions from `NWPathMonitor`, and is the only part that cannot be.
public struct LinkState: Sendable, Hashable, Codable {
    /// Wi-Fi, Ethernet or loopback: a directly attached network where
    /// multicast reaches the link and a private subnet is the one we are on.
    public var onLocalLink: Bool

    /// A tunnel interface is up — a VPN, a zero-trust client, a mesh.
    ///
    /// **This licenses private addresses, not `.local` names.** A tunnel can
    /// route `192.168.50.54` from anywhere; none of them carry multicast DNS,
    /// which is link-scoped by definition. Conflating the two is what would
    /// make a phone on cellular spend a timeout on an mDNS name that cannot
    /// resolve however many tunnels are up.
    ///
    /// Deliberately not "a tunnel that routes *this* address": nothing here can
    /// know which subnets a split-tunnel client has claimed, and asking the
    /// system would still not answer it for a private DNS name. Being wrong
    /// towards trying costs one slot in a concurrent race; being wrong towards
    /// refusing costs the connection.
    public var tunnelActive: Bool

    public init(onLocalLink: Bool, tunnelActive: Bool = false) {
        self.onLocalLink = onLocalLink
        self.tunnelActive = tunnelActive
    }

    /// Just the part that decides which endpoints are candidates.
    ///
    /// On the local link every endpoint is a candidate whatever the tunnel is
    /// doing — `Endpoint.isUsable(from:)` returns true for all four reach cases
    /// — so `tunnelActive` cannot change the raced list there, and comparing it
    /// would invalidate a perfectly good connection for nothing. An on-demand
    /// VPN profile connecting and dropping while the app sits on Wi-Fi would
    /// otherwise tear down the live SSH session and re-handshake on the next
    /// request, repeatedly.
    ///
    /// The tunnel half earns its place in that comparison only off the link,
    /// where it is the whole difference between racing a private address and
    /// discarding it.
    public var candidateIdentity: LinkState {
        onLocalLink ? .localLink : self
    }

    /// Cellular, no tunnel: only a globally routable address or a mesh address
    /// can work. The strictest case, and the one `bleat inspect` warns about.
    public static let offLink = LinkState(onLocalLink: false, tunnelActive: false)

    /// On Wi-Fi or Ethernet, with no tunnel.
    public static let localLink = LinkState(onLocalLink: true, tunnelActive: false)
}
