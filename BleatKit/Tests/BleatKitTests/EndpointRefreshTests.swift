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
        hostReport: EndpointDiscovery.Report? = nil
    ) -> PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAAKEY",
            name: "Mac",
            username: "robin",
            endpoints: endpoints.compactMap { Endpoint(string: $0) },
            lastGoodEndpoint: lastGood.flatMap { Endpoint(string: $0) },
            hostReport: hostReport
        )
    }

    /// A report shaped the way a real probe run produces one, per category.
    private func report(
        name: [String]? = nil,
        interfaces: [String]? = nil,
        tailscale: [String]? = nil
    ) -> EndpointDiscovery.Report {
        EndpointDiscovery.Report(
            localHostName: name?.compactMap { Endpoint(string: $0) },
            interfaces: interfaces?.compactMap { Endpoint(string: $0) },
            tailscale: tailscale?.compactMap { Endpoint(string: $0) }
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
        let found = await EndpointDiscovery.probe(shell).all

        // mDNS name first, then the interface addresses, then whatever only the
        // CLI knows — which is the MagicDNS name.
        #expect(found.first?.host == "studio-mac.local")
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

        #expect(found.answered)
        #expect(!found.all.isEmpty)
        // …and the probes that failed report `nil`, not an empty answer, so
        // nothing of theirs is prunable.
        #expect(found.localHostName == nil)
        #expect(found.tailscale == nil)
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
    @Test("a report no probe answered changes nothing at all")
    func silentReportIsNotAnAnswer() {
        let before = peer(["mac.local", "192.168.1.20"], lastGood: "192.168.1.20")
        #expect(before.refreshingEndpoints(discovered: EndpointDiscovery.Report()) == before)
    }

    /// The second rule, in the direction that helps: a host that has moved
    /// network gains its new address without a re-pair.
    @Test("a new address the host reports is added")
    func addsWhatIsNew() {
        let refreshed = peer(
            ["mac.local", "192.168.1.20"],
            hostReport: report(name: ["mac.local"], interfaces: ["192.168.1.20"])
        ).refreshingEndpoints(
            discovered: report(name: ["mac.local"], interfaces: ["10.0.5.9"])
        )
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
            hostReport: report(name: ["mac.local"], interfaces: ["192.168.1.20"])
        ).refreshingEndpoints(discovered: report(name: ["mac.local"], interfaces: []))
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
            hostReport: report(name: ["mac.local"])
        ).refreshingEndpoints(discovered: report(name: [], interfaces: ["10.0.5.9"]))
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
            .refreshingEndpoints(discovered: report(interfaces: ["10.0.5.9"]))
        #expect(refreshed.endpoints.map(\.host)
            == ["mac.local", "192.168.1.20", "vpn.example.com", "10.0.5.9"])
        #expect(refreshed.hostReport?.interfaces?.map(\.host) == ["10.0.5.9"])
    }

    /// The third rule. It completed a handshake minutes ago, which outranks any
    /// report about it — and dropping the one address known to work would be
    /// the worst possible outcome of a bookkeeping pass nobody asked for.
    @Test("the endpoint that just worked survives being dropped from the report")
    func lastGoodAlwaysSurvives() {
        let refreshed = peer(
            ["mac.local", "192.168.1.20"],
            lastGood: "192.168.1.20",
            hostReport: report(name: ["mac.local"], interfaces: ["192.168.1.20"])
        ).refreshingEndpoints(discovered: report(name: ["mac.local"], interfaces: []))

        #expect(refreshed.endpoints.map(\.host).contains("192.168.1.20"))
        #expect(refreshed.lastGoodEndpoint == Endpoint(host: "192.168.1.20"))
        #expect(refreshed.endpointsToTry(from: .localLink).first?.host == "192.168.1.20")
        // Recorded, so the exemption is one refresh long rather than forever.
        #expect(refreshed.hostReport?.reinstated == [Endpoint(host: "192.168.1.20")])
    }

    /// **The finding this whole shape exists for.** Tailscale being switched
    /// off is not an error — the CLI exits 0 with `BackendState: "Stopped"` —
    /// so a flattened report would come back perfectly non-empty with no
    /// overlay endpoints in it, and one pass would delete the MagicDNS name and
    /// both tunnel addresses. The next time the phone was on cellular the host
    /// would be unreachable, permanently, from a transient condition. That is
    /// the exact cost this feature exists to remove.
    @Test("a probe that did not answer prunes nothing of its own")
    func aSilentProbePrunesNothing() {
        let before = peer(
            ["mac.local", "192.168.1.20", "100.101.102.103", "mac.tail1234.ts.net"],
            hostReport: report(
                name: ["mac.local"],
                interfaces: ["192.168.1.20", "100.101.102.103"],
                tailscale: ["mac.tail1234.ts.net"]
            )
        )
        // scutil and ifconfig answer; the tunnel is down so neither the CLI nor
        // the `utun` interface has anything to say.
        let refreshed = before.refreshingEndpoints(
            discovered: report(name: ["mac.local"], interfaces: ["192.168.1.20"])
        )

        // The `utun` address goes — `ifconfig` answered and no longer lists it,
        // which is a real observation about the interfaces.
        #expect(!refreshed.endpoints.contains(Endpoint(host: "100.101.102.103")))
        // The MagicDNS name stays. The only probe that could have spoken for it
        // said nothing, and its absence is not evidence.
        #expect(refreshed.endpoints.contains(Endpoint(host: "mac.tail1234.ts.net")))
        #expect(refreshed.hostReport?.tailscale?.map(\.host) == ["mac.tail1234.ts.net"])
    }

    /// The other side of it: once the CLI does answer and no longer names it,
    /// the name goes. Silence is not an answer, but an answer is.
    @Test("a probe that answers does prune its own category")
    func ananswringProbePrunesItsOwn() {
        let before = peer(
            ["mac.local", "mac.tail1234.ts.net"],
            hostReport: report(name: ["mac.local"], tailscale: ["mac.tail1234.ts.net"])
        )
        let refreshed = before.refreshingEndpoints(
            discovered: report(name: ["mac.local"], tailscale: [])
        )
        #expect(refreshed.endpoints.map(\.host) == ["mac.local"])
    }

    /// **The exemption has to expire.** Putting the last-good address back
    /// without recording it leaves it looking like an address the host never
    /// claimed — permanently sticky, and still there long after `recordSuccess`
    /// has moved on. A recycled DHCP lease that won one race would then live in
    /// the peer forever, and per this file's own reasoning a recycled address
    /// reaching an unrelated machine yields a `hostKeyMismatch` that
    /// `PeerConnector` promotes over every other failure.
    @Test("a reinstated address becomes prunable again on the next refresh")
    func reinstatedAddressIsNotPermanent() {
        let first = peer(
            ["mac.local", "192.168.1.20"],
            lastGood: "192.168.1.20",
            hostReport: report(name: ["mac.local"], interfaces: ["192.168.1.20"])
        ).refreshingEndpoints(discovered: report(name: ["mac.local"], interfaces: []))
        #expect(first.endpoints.map(\.host).contains("192.168.1.20"))

        // The race has since been won elsewhere, so nothing exempts it now.
        var moved = first
        moved.lastGoodEndpoint = Endpoint(host: "mac.local")
        let second = moved.refreshingEndpoints(
            discovered: report(name: ["mac.local"], interfaces: [])
        )
        #expect(second.endpoints.map(\.host) == ["mac.local"])
    }

    // MARK: - A refresh nobody is waiting for

    /// **Cancellation has to reach the probe, and a partial answer is worse
    /// than none.** `SSHTransport` re-dials lazily when its client is nil and
    /// `SSHClient.connect` does not observe cancellation, so a command run
    /// after `release()` disconnects opens a brand new session nothing will
    /// close. And a report truncated part way through is non-empty, so it would
    /// be written — pruning every category the cancelled probes never reached.
    @Test("a cancelled probe reports nothing at all")
    func cancelledProbeReportsNothing() async throws {
        let shell = FakeDiscoveryShell(
            localHostName: "mac",
            ifconfig: try Fixture.text("ifconfig.txt"),
            tailscale: try Fixture.text("tailscale-status.json")
        )
        let task = Task { await EndpointDiscovery.probe(shell) }
        task.cancel()
        let found = await task.value

        #expect(!found.answered)
        #expect(found.all.isEmpty)
        // And so it is inert against a peer, rather than emptying one.
        let before = peer(["mac.local", "192.168.1.20"])
        #expect(before.refreshingEndpoints(discovered: found) == before)
    }

    // MARK: - Which tailscale answered

    /// Exit status is not the success condition, and taking it for one drops
    /// the MagicDNS name in silence. A Homebrew CLI that cannot reach the App
    /// Store app's daemon exits cleanly reporting `Stopped` or `NeedsLogin`;
    /// the loop has to keep going to the binary that can answer.
    @Test("only a running tailnet counts as an answer")
    func onlyRunningCounts() throws {
        #expect(TailscaleStatus.isRunning(statusJSON: try Fixture.data("tailscale-status.json")))
        for state in ["Stopped", "NeedsLogin", "NoState"] {
            let json = Data(
                "{\"BackendState\":\"\(state)\",\"Self\":{\"DNSName\":\"mac.ts.net.\"}}".utf8
            )
            #expect(!TailscaleStatus.isRunning(statusJSON: json), "\(state)")
        }
        #expect(!TailscaleStatus.isRunning(statusJSON: Data("not json".utf8)))
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
            report(name: ["mac.local"], interfaces: ["10.0.5.9"]),
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
            report(interfaces: ["10.0.5.9"]), forHostKey: "ssh-ed25519 GONE"
        ) == nil)
        #expect(try registry.all().isEmpty)
    }
}
