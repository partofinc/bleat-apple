import Foundation

/// What the watch asks the phone to do for it.
///
/// **The watch cannot reach a host itself.** watchOS refuses an ordinary app
/// every kind of direct connection — `NWConnection` waits forever with
/// `ENETDOWN`, BSD sockets never work (Apple's TN3135) — and SSH is nothing but
/// a direct connection. The phone already holds the device key and the pairing
/// record, so the watch sends it the command and the phone runs it over its own
/// SSH connection.
///
/// The cut is at the transport on purpose: these cases are `ShellRunner`
/// written down, so the host status probe runs on the watch unchanged.
///
/// **herdr-core goes as single calls, not as its stream** (plan, question 18;
/// 13 Nov 2026). hc speaks a framed stream that stays open both ways; a
/// relayed message is one request and one reply. The watch never attaches, so
/// what it needs — the list, one terminal, its screen as text, the seen label
/// — is calls, and it asks again while a screen is up.
public enum RelayRequest: Sendable, Codable, Equatable {
    /// The paired hosts, as the phone knows them now.
    case peers
    /// One shell command — the host status probe.
    case shell(hostKey: String, command: String)
    /// One herdr-core call on that host, from `hcMethods` only.
    case hc(hostKey: String, method: String, params: [String: HcJSON])
    /// The watch has stopped looking at this host; close what was opened for it.
    case release(hostKey: String)
    /// Something the watch did that the phone's record of the host should
    /// remember. See `PeerNote`.
    case note(hostKey: String, PeerNote)

    /// The herdr-core calls the watch may relay: what it shows, and the seen
    /// label. The phone refuses any other — the watch reads, and marks what
    /// it read; it does not start, type into or end anything.
    public static let hcMethods: Set<String> = ["terminal.list", "terminal.get", "terminal.read", "terminal.label"]
}
