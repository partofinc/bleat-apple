import Foundation
import Testing
@testable import BleatKit

/// A host that answers the three discovery probes with whatever it was given.
///
/// Keyed on the commands `EndpointDiscovery` publishes rather than on
/// substrings, so a change to one of them fails these tests instead of quietly
/// making the fake answer a question nobody asks any more.
private struct FakeDiscoveryShell: ShellRunner {
    var localHostName: String?
    var ifconfig: String?
    var tailscale: String?
    /// Commands the host refuses outright, as a missing tool does.
    var failing: Set<String> = []

    func run(shell command: String) async throws -> String {
        if failing.contains(command) {
            throw ShellError(command: command, exitCode: 127, stderr: "command not found")
        }
        switch command {
        case EndpointDiscovery.localHostNameCommand: return localHostName ?? ""
        case EndpointDiscovery.ifconfigCommand: return ifconfig ?? ""
        case EndpointDiscovery.tailscaleStatusCommand: return tailscale ?? ""
        default:
            Issue.record("unexpected command: \(command)")
            return ""
        }
    }
}

@Suite("Refreshing a peer's endpoints from the host")
struct EndpointRefreshTests {

    private func peer(
        _ endpoints: [String],
        lastGood: String? = nil,
        hostReported: [String]? = nil
    ) -> PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAAKEY",
            name: "Mac",
            username: "ravil",
            endpoints: endpoints.compactMap { Endpoint(string: $0) },
            lastGoodEndpoint: lastGood.flatMap { Endpoint(string: $0) },
            hostReportedEndpoints: hostReported?.compactMap { Endpoint(string: $0) }
        )
    }

    // MARK: - Assembling what the host said

    /// The same three answers `bleat pair` reads locally, from the same
    /// captured fixtures, so the phone and the tool cannot disagree about what
    /// a host offers.
    @Test("the host's own bytes assemble in the documented order")
    func assemblesFromFixtures() async throws {
        let shell = FakeDiscoveryShell(
            localHostName: try Fixture.text("localhostname.txt"),
            ifconfig: try Fixture.text("ifconfig.txt"),
            tailscale: try Fixture.text("tailscale-status.json")
        )
        let found = await EndpointDiscovery.probe(shell)

        // mDNS name first, then the interface addresses, then whatever only the
        // CLI knows — which is the MagicDNS name.
        #expect(found.first?.host == "rawillkair.local")
        #expect(found.contains { $0.reach == .overlay && $0.host.hasSuffix(".ts.net") })
        #expect(Set(found).count == found.count, "endpoints must be de-duplicated")
    }

    /// A tunnel address appears on `utun` *and* in the CLI's report, and the
    /// de-duplication keeps whichever came first. Which one wins is not
    /// arbitrary: `ifconfig` runs first so the address is credited to the
    /// interface, leaving the CLI to contribute only the name.
    @Test("an address in both ifconfig and tailscale appears once")
    func deduplicates() {
        let found = EndpointDiscovery.endpoints(from: .init(
            ifconfig: """
            utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
            \tinet 100.101.102.103 --> 100.101.102.103 netmask 0xff000000
            """,
            tailscaleStatusJSON: """
            {"BackendState":"Running","MagicDNSSuffix":"tail1234.ts.net",
             "Self":{"DNSName":"mac.tail1234.ts.net.","TailscaleIPs":["100.101.102.103"]}}
            """
        ))
        #expect(found.map(\.host) == ["100.101.102.103", "mac.tail1234.ts.net"])
    }

    /// A host without `scutil`, or without `tailscale`, still reports the
    /// addresses that did come back. Pairing has always behaved this way and a
    /// refresh must not be stricter — a missing optional tool would otherwise
    /// look like a host that had lost its addresses.
    @Test("a probe the host refuses contributes nothing and fails nothing")
    func toleratesAMissingTool() async throws {
        let shell = FakeDiscoveryShell(
            ifconfig: try Fixture.text("ifconfig.txt"),
            failing: [
                EndpointDiscovery.localHostNameCommand,
                EndpointDiscovery.tailscaleStatusCommand,
            ]
        )
        let found = await EndpointDiscovery.probe(shell)

        #expect(!found.isEmpty)
        #expect(!found.contains { $0.host.hasSuffix(".local") })
        #expect(!found.contains { $0.host.hasSuffix(".ts.net") })
    }

    /// The peer's port, not 22. A host reached on 2222 whose refreshed
    /// addresses were recorded on 22 would gain a full set of new, wrong
    /// endpoints alongside the working ones.
    @Test("the port is carried onto every refreshed endpoint")
    func carriesThePort() async throws {
        let found = EndpointDiscovery.endpoints(
            from: .init(localHostName: "mac", ifconfig: try Fixture.text("ifconfig.txt")),
            port: 2222
        )
        #expect(found.allSatisfy { $0.port == 2222 })
    }

    // MARK: - Folding it in

    /// The first rule. A probe answers empty when it could not run at all, and
    /// that is not the host saying it has no addresses — reading it as one
    /// would empty the peer and strand the phone with a record it can never
    /// connect through again.
    @Test("an empty report changes nothing at all")
    func emptyReportIsNotAnAnswer() {
        let before = peer(["mac.local", "192.168.1.20"], lastGood: "192.168.1.20")
        #expect(before.refreshingEndpoints(discovered: []) == before)
    }

    /// The second rule, in the direction that helps: a host that has moved
    /// network gains its new address without a re-pair.
    @Test("a new address the host reports is added")
    func addsWhatIsNew() {
        let refreshed = peer(["mac.local", "192.168.1.20"], hostReported: ["mac.local", "192.168.1.20"])
            .refreshingEndpoints(discovered: [Endpoint(host: "mac.local"), Endpoint(host: "10.0.5.9")])
        #expect(refreshed.endpoints.map(\.host) == ["mac.local", "10.0.5.9"])
    }

    /// The second rule, in the direction that is easy to skip — and skipping it
    /// is worse than it looks. A list that only grows accumulates recycled DHCP
    /// leases, each dialled on every connection afterwards; and a recycled
    /// address reaches an unrelated machine, which fails *host key
    /// verification*. `PeerConnector` promotes a mismatch over every other
    /// failure, so a sleeping Mac plus one stale address reports a security
    /// warning rather than "could not reach it".
    @Test("an address the host has stopped reporting is pruned")
    func prunesWhatTheHostDropped() {
        let refreshed = peer(
            ["mac.local", "192.168.1.20"],
            hostReported: ["mac.local", "192.168.1.20"]
        ).refreshingEndpoints(discovered: [Endpoint(host: "mac.local")])
        #expect(refreshed.endpoints.map(\.host) == ["mac.local"])
    }

    /// **The case that protects Twingate.** A private DNS name given with
    /// `--endpoint` is invisible to detection — the host has no idea it exists
    /// — so its absence from a report is not evidence of anything. Pruning it
    /// would delete the one endpoint that works for a zero-trust overlay, on
    /// the first successful connection after this feature shipped.
    @Test("an endpoint the host never claimed is sticky")
    func keepsWhatTheHostNeverClaimed() {
        let refreshed = peer(
            ["mac.local", "mac.internal.example.com"],
            hostReported: ["mac.local"]
        ).refreshingEndpoints(discovered: [Endpoint(host: "10.0.5.9")])
        #expect(refreshed.endpoints.map(\.host).contains("mac.internal.example.com"))
        #expect(!refreshed.endpoints.map(\.host).contains("mac.local"))
    }

    /// `nil` is not the empty list. A record made before refreshing existed has
    /// no attribution for any of its endpoints, so the first refresh may add
    /// but must not prune — otherwise every `--endpoint` extra baked into a QR
    /// disappears the first time the phone connects after an update.
    @Test("the first refresh of an older record prunes nothing")
    func firstRefreshIsAdditive() {
        let refreshed = peer(["mac.local", "192.168.1.20", "vpn.example.com"])
            .refreshingEndpoints(discovered: [Endpoint(host: "10.0.5.9")])
        #expect(refreshed.endpoints.map(\.host)
            == ["mac.local", "192.168.1.20", "vpn.example.com", "10.0.5.9"])
        #expect(refreshed.hostReportedEndpoints?.map(\.host) == ["10.0.5.9"])
    }

    /// The third rule. It completed a handshake minutes ago, which outranks any
    /// report about it — and dropping the one address known to work would be
    /// the worst possible outcome of a bookkeeping pass nobody asked for.
    @Test("the endpoint that just worked survives being dropped from the report")
    func lastGoodAlwaysSurvives() {
        let refreshed = peer(
            ["mac.local", "192.168.1.20"],
            lastGood: "192.168.1.20",
            hostReported: ["mac.local", "192.168.1.20"]
        ).refreshingEndpoints(discovered: [Endpoint(host: "mac.local")])

        #expect(refreshed.endpoints.map(\.host).contains("192.168.1.20"))
        #expect(refreshed.lastGoodEndpoint == Endpoint(host: "192.168.1.20"))
        #expect(refreshed.endpointsToTry(from: .localLink).first?.host == "192.168.1.20")
    }

    // MARK: - Through the registry

    /// A targeted mutation, for the reason `recordHerdrPath` is one: `save`
    /// merges, and a merge takes the newer record's `lastGoodEndpoint`. This
    /// runs moments after `recordSuccess`, so writing an edited copy loaded
    /// before the connection would undo the winner just recorded.
    @Test("recording a report does not disturb the winner recorded a moment ago")
    func registryKeepsTheRecordedWinner() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-refresh-\(UUID().uuidString)/peers.json")
        let registry = PeerRegistry(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try registry.save(peer(["mac.local", "192.168.1.20"]))
        try registry.recordSuccess(endpoint: Endpoint(host: "192.168.1.20"), forHostKey: "ssh-ed25519 AAAAKEY")
        let stored = try registry.recordDiscoveredEndpoints(
            [Endpoint(host: "mac.local"), Endpoint(host: "10.0.5.9")],
            forHostKey: "ssh-ed25519 AAAAKEY"
        )

        #expect(stored?.lastGoodEndpoint == Endpoint(host: "192.168.1.20"))
        #expect(try registry.peer(hostKey: "ssh-ed25519 AAAAKEY")?.lastGoodEndpoint
            == Endpoint(host: "192.168.1.20"))
        #expect(stored?.endpoints.map(\.host).contains("10.0.5.9") == true)
    }

    /// A peer removed while the refresh was in flight. It runs in the
    /// background after a connection, so this race is real and its only correct
    /// outcome is silence — resurrecting a peer the user has just unpaired
    /// would be considerably worse than doing nothing.
    @Test("a report for a peer that has been forgotten writes nothing")
    func unknownPeerIsSilence() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-refresh-\(UUID().uuidString)/peers.json")
        let registry = PeerRegistry(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(try registry.recordDiscoveredEndpoints(
            [Endpoint(host: "10.0.5.9")], forHostKey: "ssh-ed25519 GONE"
        ) == nil)
        #expect(try registry.all().isEmpty)
    }
}
