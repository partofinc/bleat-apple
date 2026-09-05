import Foundation

/// How a connection decides it reached the right machine.
///
/// Two mechanisms, because the two callers learn the host key by different
/// routes and only one of them is trusting anything on first sight.
public enum HostKeyPolicy: Sendable {
    /// Trust on first use, pinned in a file keyed by `host:port`. What the
    /// console tool does: it is handed a hostname and has nothing else to go
    /// on, so the first key it sees becomes the pin and any later change is a
    /// hard error.
    case knownHosts(KnownHostsStore)

    /// Compare against a key learned **out of band** — from a pairing QR, and
    /// afterwards from the `PairedPeer` record that QR produced.
    ///
    /// Strictly stronger than trust-on-first-use: there is no first sighting to
    /// trust, so a machine-in-the-middle on the very first connection is caught
    /// rather than pinned. It also writes nothing, which matters because a peer
    /// is identified by its host key while its *addresses* come and go — a
    /// DHCP lease handed to another machine would otherwise leave a stale pin
    /// at `192.168.1.50:22` that no legitimate pairing could ever get past.
    case expect(String)

    /// The default for anything that has no key in hand.
    public static var standard: HostKeyPolicy { .knownHosts(.standard()) }
}
