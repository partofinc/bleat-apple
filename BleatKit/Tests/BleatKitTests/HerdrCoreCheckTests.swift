import Foundation
import Testing
@testable import BleatKit

@Suite("The herdr-core migration check")
struct HerdrCoreCheckTests {

    /// Answers each command from a table, in the order asked, and records
    /// what was asked.
    private final class ScriptedShell: ShellRunner, @unchecked Sendable {
        var replies: [Result<String, any Error>]
        private(set) var asked: [String] = []

        init(_ replies: [Result<String, any Error>]) { self.replies = replies }

        func run(shell command: String) async throws -> String {
            asked.append(command)
            return try replies.removeFirst().get()
        }
    }

    private let endpoint = Endpoint(host: "mac.local")

    // MARK: - Reading the answers

    @Test("the lookup asks a login shell for hc, and absence is empty output")
    func locateCommand() {
        #expect(HerdrCoreLookup.locate == "${SHELL:-/bin/sh} -lc 'command -v hc' || true")
        #expect(HerdrLookup.command == "${SHELL:-/bin/sh} -lc 'command -v herdr' || true")
    }

    @Test("the version is asked of the absolute path, quoted")
    func versionCommand() {
        #expect(HerdrCoreLookup.version(at: "/home/pi/.local/bin/hc") == "'/home/pi/.local/bin/hc' --version")
        #expect(HerdrCoreLookup.version(at: "/odd'path/hc") == "'/odd'\\''path/hc' --version")
    }

    @Test("hc --version, as captured, reads as a version")
    func capturedVersion() throws {
        let printed = try Fixture.text("hc-version.txt")
        #expect(HerdrCoreLookup.version(inOutput: printed) == "0.1.20")
        #expect(HerdrCoreLookup.path(inOutput: try Fixture.text("hc-locate.txt")) == "/Users/robin/.local/bin/hc")
    }

    @Test("a banner before the version is skipped")
    func bannerBeforeVersion() {
        #expect(HerdrCoreLookup.version(inOutput: "Welcome back!\nhc 0.1.18\n") == "0.1.18")
    }

    /// Read as missing, a later hc that says more would be stored and every
    /// user told to install what they already have.
    @Test("words after the version are ignored")
    func wordsAfterVersion() {
        #expect(HerdrCoreLookup.version(inOutput: "hc 0.2.0 (abc123)\n") == "0.2.0")
        #expect(HerdrCoreLookup.version(inOutput: "hc 0.2.0-dev+sha built today\n") == "0.2.0-dev+sha")
    }

    @Test("an hc that is not herdr-core has no version")
    func someOtherHc() {
        #expect(HerdrCoreLookup.version(inOutput: "usage: hc [-h] FILE\n") == nil)
        #expect(HerdrCoreLookup.version(inOutput: "hc version unknown\n") == nil)
        #expect(HerdrCoreLookup.version(inOutput: "") == nil)
    }

    // MARK: - The outcome

    @Test("a host with herdr-core answers installed, with path and version")
    func installed() async {
        let shell = ScriptedShell([.success("/home/pi/.local/bin/hc\n"), .success("hc 0.1.18\n")])
        let outcome = await HerdrCoreCheck.ask(shell, endpoint: endpoint)
        #expect(outcome == .answered(.installed(path: "/home/pi/.local/bin/hc", version: "0.1.18"), endpoint: endpoint))
        #expect(shell.asked == [HerdrCoreLookup.locate, "'/home/pi/.local/bin/hc' --version"])
    }

    @Test("a host without hc anywhere answers missing, and is asked nothing more")
    func missing() async {
        let shell = ScriptedShell([.success(""), .success("")])
        #expect(await HerdrCoreCheck.ask(shell, endpoint: endpoint) == .answered(.missing, endpoint: endpoint))
        #expect(shell.asked == [HerdrCoreLookup.locate, HerdrCoreLookup.installedByHerdrApp])
    }

    /// The Mac this was built on: hc 0.1.20 in `~/.local/bin`, which only
    /// `.zshrc` puts on `PATH`, so a login shell does not find it.
    @Test("hc outside the login shell's PATH is found where Herdr.app puts it")
    func foundInLocalBin() async {
        let shell = ScriptedShell([
            .success(""), .success("/Users/robin/.local/bin/hc\n"), .success(try! Fixture.text("hc-version.txt")),
        ])
        #expect(
            await HerdrCoreCheck.ask(shell, endpoint: endpoint)
                == .answered(.installed(path: "/Users/robin/.local/bin/hc", version: "0.1.20"), endpoint: endpoint)
        )
    }

    @Test("an hc on PATH is used without looking anywhere else")
    func pathWins() async {
        let shell = ScriptedShell([.success("/opt/homebrew/bin/hc\n"), .success("hc 0.1.20\n")])
        _ = await HerdrCoreCheck.ask(shell, endpoint: endpoint)
        #expect(!shell.asked.contains(HerdrCoreLookup.installedByHerdrApp))
    }

    /// An `hc` that exits non-zero is on the host but is not herdr-core that
    /// works, which is the "install herdr-core" case, not an unreachable one.
    @Test("an hc whose --version fails counts as missing")
    func brokenHc() async {
        let failed = ShellError(command: "hc --version", exitCode: 127, stderr: "not found")
        let shell = ScriptedShell([.success("/usr/local/bin/hc\n"), .failure(failed)])
        #expect(await HerdrCoreCheck.ask(shell, endpoint: endpoint) == .answered(.missing, endpoint: endpoint))
    }

    /// Caught as "missing" once: a host list cancelled mid-check stored
    /// "Install herdr-core" for a host that had it.
    @Test("a cancelled version command records nothing")
    func cancelledVersion() async {
        let shell = ScriptedShell([.success("/usr/local/bin/hc\n"), .failure(CancellationError())])
        #expect(await HerdrCoreCheck.ask(shell, endpoint: endpoint) == .cancelled)
    }

    @Test("a cancelled lookup records nothing")
    func cancelledLookup() async {
        let shell = ScriptedShell([.failure(CancellationError())])
        #expect(await HerdrCoreCheck.ask(shell, endpoint: endpoint) == .cancelled)
    }

    @Test("the connection going part way is unreachable, not missing")
    func droppedPartWay() async {
        let shell = ScriptedShell([.success("/usr/local/bin/hc\n"), .failure(TransportError.channelClosed)])
        guard case .unreachable = await HerdrCoreCheck.ask(shell, endpoint: endpoint) else {
            Issue.record("expected unreachable")
            return
        }
    }

    @Test("a peer with no address from here is unreachable without a dial")
    func noAddress() async {
        let peer = PairedPeer(
            hostKey: "ssh-ed25519 AAAAKEY", name: "Mac", username: "robin",
            endpoints: [Endpoint(host: "mac.local")]
        )
        guard case .unreachable = await HerdrCoreCheck.run(peer: peer, deviceKey: SSHKeyPair(), link: .offLink) else {
            Issue.record("expected unreachable")
            return
        }
    }

    // MARK: - The record

    /// Every peer paired under 1.x was written without the key, and an
    /// undecodable file would strand every one of them.
    @Test("a 1.x peer record decodes, with nothing known about herdr-core")
    func oldRecordDecodes() throws {
        let json = #"{"hostKey":"ssh-ed25519 AAAAKEY","name":"Mac","username":"robin","endpoints":[],"herdrPath":"/opt/homebrew/bin/herdr"}"#
        let peer = try JSONDecoder().decode(PairedPeer.self, from: Data(json.utf8))
        #expect(peer.herdrCore == nil)
        #expect(peer.herdrPath == "/opt/homebrew/bin/herdr")
    }

    @Test("the answer survives a round trip and a re-pair")
    func roundTripAndMerge() throws {
        var stored = PairedPeer(hostKey: "ssh-ed25519 AAAAKEY", name: "Mac", username: "robin", endpoints: [])
        stored.herdrCore = .installed(path: "/Users/robin/.local/bin/hc", version: "0.1.20")
        let decoded = try JSONDecoder().decode(PairedPeer.self, from: JSONEncoder().encode(stored))
        #expect(decoded == stored)

        let fromQR = PairedPeer(hostKey: "ssh-ed25519 AAAAKEY", name: "Mac", username: "robin", endpoints: [])
        #expect(try stored.merging(fromQR).herdrCore == stored.herdrCore)
    }

    @Test("the registry records an answer once, and a change again")
    func registryRecords() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-peers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PeerRegistry(url: directory.appendingPathComponent("peers.json"))
        let key = "ssh-ed25519 AAAAKEY"
        _ = try registry.save(PairedPeer(hostKey: key, name: "Mac", username: "robin", endpoints: [Endpoint(host: "mac.local")]))

        #expect(try registry.recordHerdrCore(.missing, forHostKey: key))
        #expect(try !registry.recordHerdrCore(.missing, forHostKey: key))
        #expect(try registry.recordHerdrCore(.installed(path: "/x/hc", version: "0.1.20"), forHostKey: key))
        #expect(try registry.all().first?.herdrCore == .installed(path: "/x/hc", version: "0.1.20"))
        #expect(try !registry.recordHerdrCore(.missing, forHostKey: "ssh-ed25519 NOBODY"))
    }

    /// One write for both: each write reloads every host list and re-mirrors
    /// the watch.
    @Test("the answer and the address that gave it are recorded together")
    func recordsEndpointWithAnswer() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-peers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PeerRegistry(url: directory.appendingPathComponent("peers.json"))
        let key = "ssh-ed25519 AAAAKEY"
        let tailnet = Endpoint(host: "mac.tailf00d42.ts.net")
        _ = try registry.save(PairedPeer(hostKey: key, name: "Mac", username: "robin", endpoints: [Endpoint(host: "mac.local"), tailnet]))

        #expect(try registry.recordHerdrCore(.missing, reachedAt: tailnet, forHostKey: key))
        let stored = try #require(try registry.all().first)
        #expect(stored.herdrCore == .missing)
        #expect(stored.lastGoodEndpoint == tailnet)
        // The same answer from the same address is no change at all.
        #expect(try !registry.recordHerdrCore(.missing, reachedAt: tailnet, forHostKey: key))
    }
}
