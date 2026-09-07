import Foundation
import Testing
@testable import BleatKit

@Suite("Adding and removing an address by hand")
struct ManualEndpointTests {

    private static let hostKey = "ssh-ed25519 AAAAKEY"

    /// A registry in its own directory, cleaned up when the test's reference to
    /// it goes away.
    ///
    /// A class so `deinit` can do the removal: a `rethrows` helper taking a
    /// closure reads better but does not compile around `#expect`, whose
    /// expansion does not propagate a throw out through the closure it builds.
    ///
    /// The explicit location is not incidental. `NSHomeDirectory()` ignores
    /// `$HOME` on macOS — it reads the passwd entry — so `PeerRegistry.standard()`
    /// under a scratch `HOME` still writes to the real `~/.bleat`.
    private final class TempRegistry {
        let registry: PeerRegistry
        private let directory: URL

        init() {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bleat-manual-\(UUID().uuidString)")
            registry = PeerRegistry(url: directory.appendingPathComponent("peers.json"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// A host self-report shaped per probe, the way a real refresh produces
    /// one. Written out rather than flattened because pruning is per probe:
    /// see `EndpointDiscovery.Report`.
    private func report(
        name: [String]? = nil,
        interfaces: [String]? = nil
    ) -> EndpointDiscovery.Report {
        EndpointDiscovery.Report(
            localHostName: name?.compactMap { Endpoint(string: $0) },
            interfaces: interfaces?.compactMap { Endpoint(string: $0) }
        )
    }

    private func peer(_ endpoints: [String], lastGood: String? = nil) -> PairedPeer {
        PairedPeer(
            hostKey: Self.hostKey,
            name: "Mac",
            username: "ravil",
            endpoints: endpoints.compactMap { Endpoint(string: $0) },
            lastGoodEndpoint: lastGood.flatMap { Endpoint(string: $0) }
        )
    }

    // MARK: - Adding

    @Test("an added address joins the list")
    func addsAnAddress() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local"]))
        let stored = try registry.addEndpoint(
            Endpoint(host: "mac.internal.example.com"), forHostKey: Self.hostKey
        )
        #expect(stored?.endpoints.map(\.host) == ["mac.local", "mac.internal.example.com"])
    }

    /// **The reason this exists.** An address the user supplied is invisible to
    /// detection — a zero-trust overlay routes the *client* to a private DNS
    /// name held entirely on the client's side, so the host has nothing to
    /// report — and a refresh may only prune what the host once claimed. So it
    /// has to survive a refresh that does not mention it, forever.
    @Test("an added address survives every refresh that does not mention it")
    func addedAddressIsSticky() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local", "192.168.1.20"]))
        try registry.addEndpoint(
            Endpoint(host: "mac.internal.example.com"), forHostKey: Self.hostKey
        )
        // Two rounds: the first attributes the host's report, the second is
        // the one that could prune with that attribution in hand.
        for _ in 0..<2 {
            try registry.recordDiscoveredEndpoints(
                report(name: ["mac.local"], interfaces: ["192.168.1.20"]),
                forHostKey: Self.hostKey
            )
        }
        let stored = try #require(try registry.peer(hostKey: Self.hostKey))
        #expect(stored.endpoints.map(\.host).contains("mac.internal.example.com"))
    }

    /// A duplicate is not an error — the address the user wanted is on the list
    /// — but it must not appear twice, or it is dialled twice in every race and
    /// counted twice in every failure message.
    @Test("adding an address that is already there changes nothing")
    func duplicateIsANoOp() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local"]))
        try registry.addEndpoint(Endpoint(host: "mac.local"), forHostKey: Self.hostKey)
        #expect(try registry.peer(hostKey: Self.hostKey)?.endpoints.count == 1)
    }

    // MARK: - Removing

    @Test("a removed address leaves the list")
    func removesAnAddress() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local", "192.168.1.20"]))
        let stored = try registry.removeEndpoint(
            Endpoint(host: "mac.local"), forHostKey: Self.hostKey
        )
        #expect(stored?.endpoints.map(\.host) == ["192.168.1.20"])
    }

    /// **The interaction that would otherwise undo this feature.**
    /// `refreshingEndpoints` restores `lastGoodEndpoint` unconditionally — it
    /// completed a handshake, which outranks any report — so a removal that
    /// left the field pointing at the deleted address would be silently undone
    /// by the next connection's refresh, minutes later and with nothing on
    /// screen to explain it.
    @Test("removing the last-good address clears it, so no refresh restores it")
    func removingLastGoodClearsIt() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local", "192.168.1.20"], lastGood: "mac.local"))
        let stored = try registry.removeEndpoint(
            Endpoint(host: "mac.local"), forHostKey: Self.hostKey
        )
        #expect(stored?.lastGoodEndpoint == nil)

        try registry.recordDiscoveredEndpoints(
            report(name: [], interfaces: ["192.168.1.20"]), forHostKey: Self.hostKey
        )
        #expect(try registry.peer(hostKey: Self.hostKey)?
            .endpoints.map(\.host) == ["192.168.1.20"])
    }

    /// A peer with no addresses is unreachable *and* unrepairable from the
    /// phone: nothing is left to connect over, so nothing can add one back, and
    /// the only way out is a walk to the Mac. Unpairing is the deliberate way
    /// to be rid of a peer.
    @Test("the last address cannot be removed")
    func refusesToRemoveTheLastAddress() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local"]))
        #expect(try registry.removeEndpoint(
            Endpoint(host: "mac.local"), forHostKey: Self.hostKey
        ) == nil)
        #expect(try registry.peer(hostKey: Self.hostKey)?.endpoints.count == 1)
    }

    /// Documented rather than prevented. The host saying it answers there
    /// outranks a tap, and a tombstone that made removal stick would also be a
    /// way to blind the app permanently to a working address — much the more
    /// expensive mistake than racing one extra endpoint concurrently.
    @Test("an address the host still reports returns on the next refresh")
    func hostReportedAddressComesBack() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local", "192.168.1.20"]))
        try registry.removeEndpoint(Endpoint(host: "192.168.1.20"), forHostKey: Self.hostKey)
        #expect(try registry.peer(hostKey: Self.hostKey)?.endpoints.count == 1)

        try registry.recordDiscoveredEndpoints(
            report(name: ["mac.local"], interfaces: ["192.168.1.20"]),
            forHostKey: Self.hostKey
        )
        #expect(try registry.peer(hostKey: Self.hostKey)?
            .endpoints.map(\.host).contains("192.168.1.20") == true)
    }

    /// The pair that makes a stale QR entry removable for good: the host never
    /// claimed it, so no refresh will ever put it back.
    @Test("an address the host has never reported stays removed")
    func staleAddressStaysRemoved() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local", "10.9.9.9"]))
        try registry.removeEndpoint(Endpoint(host: "10.9.9.9"), forHostKey: Self.hostKey)
        try registry.recordDiscoveredEndpoints(
            report(name: ["mac.local"], interfaces: []), forHostKey: Self.hostKey
        )
        #expect(try registry.peer(hostKey: Self.hostKey)?
            .endpoints.map(\.host) == ["mac.local"])
    }

    @Test("editing an unknown peer writes nothing")
    func unknownPeerIsSilence() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        #expect(try registry.addEndpoint(Endpoint(host: "x"), forHostKey: "GONE") == nil)
        #expect(try registry.removeEndpoint(Endpoint(host: "x"), forHostKey: "GONE") == nil)
        #expect(try registry.all().isEmpty)
    }
}
