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
/// The cut is at the transport on purpose: these cases are `HerdrTransport` and
/// `ShellRunner` written down, so everything above — `HerdrClient`, the list
/// models, the host status probe — runs on the watch unchanged.
public enum RelayRequest: Sendable, Codable, Equatable {
    /// The paired hosts, as the phone knows them now.
    case peers
    /// One `herdr` command. The session travels with it rather than being
    /// selected on the phone's side, where it would be shared state between
    /// two commands in flight.
    case herdr(hostKey: String, args: [String], session: String?)
    /// One shell command — the host status probe.
    case shell(hostKey: String, command: String)
    /// The watch has stopped looking at this host; close what was opened for it.
    case release(hostKey: String)
    /// Something the watch did that the phone's record of the host should
    /// remember. See `PeerNote`.
    case note(hostKey: String, PeerNote)
}
