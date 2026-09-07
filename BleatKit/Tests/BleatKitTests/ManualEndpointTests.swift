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

    // MARK: - What a refresh does around a hand-typed address

    /// **The stranding case, and it is the feature used exactly as documented.**
    /// Discovery reports addresses and never ports — no probe knows what port
    /// sshd binds — so a refresh has to reuse the port the peer already
    /// associates with the host. Taking the port of the endpoint that just won
    /// looks right and is not: the winner can be a hand-typed port forward,
    /// which is the motivating reason to add one. Every discovered address
    /// would then be rebuilt at the forward's external port, superseding the
    /// three that worked — and back on Wi-Fi nothing connects, so no later
    /// refresh can repair it.
    @Test("a hand-typed port forward does not re-port the host's own addresses")
    func manualPortDoesNotRestampDiscoveredAddresses() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["mac.local", "192.168.1.20", "100.101.102.103"]))
        try registry.addEndpoint(
            Endpoint(string: "home.example.com:2222")!, forHostKey: Self.hostKey
        )
        // The forward won the race from cellular, and is the stored winner.
        try registry.recordSuccess(
            endpoint: Endpoint(string: "home.example.com:2222")!, forHostKey: Self.hostKey
        )
        let stored = try #require(try registry.peer(hostKey: Self.hostKey))

        // Three endpoints on 22 against one on 2222: the host's port is 22.
        #expect(stored.discoveryPort == 22)

        let refreshed = stored.refreshingEndpoints(discovered: report(
            name: ["mac.local"], interfaces: ["192.168.1.20", "100.101.102.103"]
        ))
        #expect(refreshed.endpoints.filter { $0.port == 22 }.count == 3)
        #expect(refreshed.endpoints.map(\.description).contains("home.example.com:2222"))
    }

    /// …and a host genuinely on a non-standard port keeps it, because the
    /// majority is what decides rather than a hardcoded 22.
    @Test("a host paired on a non-standard port keeps that port")
    func nonStandardPortIsKept() {
        #expect(peer(["mac.local:2222", "192.168.1.20:2222"]).discoveryPort == 2222)
        #expect(peer([]).discoveryPort == Endpoint.defaultPort)
    }

    // MARK: - What a user may type

    /// DNS is case-insensitive and `Hashable` is not, so an endpoint stores its
    /// host lower-cased. Without that, a differently-cased duplicate is a
    /// second endpoint for one machine — and it can never be pruned, because
    /// the host reports the other form, so every race dials the host twice
    /// forever.
    @Test("case does not create a second endpoint for one machine")
    func caseInsensitiveHosts() throws {
        let temp = TempRegistry()
        let registry = temp.registry
        try registry.save(peer(["rawillkair.local"]))
        try registry.addEndpoint(Endpoint(host: "RawillkAir.Local"), forHostKey: Self.hostKey)
        #expect(try registry.peer(hostKey: Self.hostKey)?.endpoints.count == 1)
        #expect(Endpoint(host: "MAC.local") == Endpoint(host: "mac.local"))
    }

    /// `Endpoint(string:)` is a parser, not a validator: anything without a
    /// colon becomes a hostname verbatim. That matters here because an address
    /// added by hand is permanently sticky — no refresh can prune what
    /// detection cannot see — so junk would be dialled in every race from then
    /// on and counted in the message explaining the failure.
    @Test("the shapes people actually paste are refused")
    func implausibleHostsAreRefused() {
        for text in [
            "ravil@mac.internal", "ssh mac.local", "mac.local/foo", "https://mac.local",
            "mac..local", ".mac.local", "mac local", "", "mac\"local",
        ] {
            let host = Endpoint(string: text)?.host
            #expect(host.map { !Endpoint.isPlausibleHost($0) } ?? true, "\(text)")
        }
    }

    /// …and the ones that are addresses still pass, including the awkward
    /// forms. Rejecting a valid internal name would be the worse failure: the
    /// user has no other way to add it.
    @Test("real addresses are still accepted")
    func plausibleHostsAreAccepted() {
        for text in [
            "mac.local", "192.168.1.20", "home.example.com:2222",
            "[fd7a:115c:a1e0::42a:771f]", "[fe80::1]:2222", "mac-01.internal", "mac",
        ] {
            let endpoint = Endpoint(string: text)
            #expect(endpoint.map { Endpoint.isPlausibleHost($0.host) } == true, "\(text)")
        }
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
