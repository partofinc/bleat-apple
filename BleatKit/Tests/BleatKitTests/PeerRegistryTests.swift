import Foundation
import Testing
@testable import BleatKit

@Suite("Paired peers on disk")
struct PeerRegistryTests {

    private func scratch() -> (PeerRegistry, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-peers-\(UUID().uuidString)")
        return (PeerRegistry(url: directory.appendingPathComponent("peers.json")), directory)
    }

    private func peer(
        key: String = "ssh-ed25519 AAAAKEY",
        endpoints: [String] = ["mac.local"],
        herdr: String? = nil
    ) -> PairedPeer {
        PairedPeer(
            hostKey: key,
            name: "Mac",
            username: "ravil",
            endpoints: endpoints.compactMap { Endpoint(string: $0) },
            herdrPath: herdr
        )
    }

    @Test("a copy of another device's records replaces what was there")
    func replaceAll() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(peer(key: "ssh-ed25519 OLD", endpoints: ["old.local"]))
        try store.save(peer(key: "ssh-ed25519 KEPT", endpoints: ["a.local", "b.local"]))

        // Not a merge: the host that is gone goes, and the one that stayed
        // has exactly the addresses it was sent with.
        let incoming = [peer(key: "ssh-ed25519 KEPT", endpoints: ["a.local"])]
        try store.replaceAll(with: incoming)
        #expect(try store.all() == incoming)
    }

    @Test("an empty store reads as empty rather than failing")
    func emptyStore() throws {
        let (store, _) = scratch()
        #expect(try store.all().isEmpty)
        #expect(try store.peer(hostKey: "ssh-ed25519 AAAAKEY") == nil)
    }

    @Test("a peer survives a round trip")
    func roundTrip() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(peer(herdr: "/opt/homebrew/bin/herdr"))
        let loaded = try #require(try store.peer(hostKey: "ssh-ed25519 AAAAKEY"))
        #expect(loaded.name == "Mac")
        #expect(loaded.herdrPath == "/opt/homebrew/bin/herdr")
    }

    /// The rule the whole peer model rests on: one machine, several addresses.
    /// Pairing again over Tailscale must not cost the peer its LAN addresses,
    /// which are the fast path when the phone is home.
    @Test("pairing the same machine from a second network merges, never duplicates")
    func mergesByHostKey() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(peer(endpoints: ["mac.local", "10.0.0.5"]))
        let merged = try store.save(peer(endpoints: ["mac.tail1234.ts.net"]))

        #expect(try store.all().count == 1)
        #expect(merged.endpoints.map(\.description) == ["mac.local", "10.0.0.5", "mac.tail1234.ts.net"])
    }

    /// Identity is the host key, so a different key is a different machine —
    /// two peers, not a merge.
    @Test("a different host key is a different peer")
    func differentKeyIsDifferentPeer() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(peer(key: "ssh-ed25519 AAAAONE"))
        try store.save(peer(key: "ssh-ed25519 AAAATWO"))
        #expect(try store.all().count == 2)
    }

    @Test("the winning endpoint is remembered, so the next connection tries it first")
    func recordsLastGood() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(peer(endpoints: ["mac.local", "10.0.0.5"]))
        let winner = try #require(Endpoint(string: "10.0.0.5"))
        try store.recordSuccess(endpoint: winner, forHostKey: "ssh-ed25519 AAAAKEY")

        let loaded = try #require(try store.peer(hostKey: "ssh-ed25519 AAAAKEY"))
        #expect(loaded.lastGoodEndpoint == winner)
        #expect(loaded.endpointsToTry(from: .localLink).first == winner)
    }

    /// Called on the success path of a connection. Failing there would turn a
    /// working connection into an error over bookkeeping.
    @Test("recording success for an unknown peer is not an error")
    func recordSuccessIsForgiving() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try #require(Endpoint(string: "10.0.0.5"))
        try store.recordSuccess(endpoint: endpoint, forHostKey: "ssh-ed25519 NOBODY")
        #expect(try store.all().isEmpty)
    }

    @Test("removing reports whether anything was there")
    func remove() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.save(peer())
        #expect(try store.remove(hostKey: "ssh-ed25519 AAAAKEY"))
        #expect(try store.remove(hostKey: "ssh-ed25519 AAAAKEY") == false)
        #expect(try store.all().isEmpty)
    }

    /// A re-pairing knows something the stored record does not: which address
    /// answered *just now*. Keeping the old one sends the next connection to
    /// the network the phone has left, and spends its timeout there.
    @Test("re-pairing over a new network updates which endpoint worked")
    func mergeTakesTheNewWinner() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        var home = peer(endpoints: ["mac.local", "10.0.0.5"])
        home.lastGoodEndpoint = Endpoint(string: "10.0.0.5")
        try store.save(home)

        var away = peer(endpoints: ["mac.tail1234.ts.net"])
        away.lastGoodEndpoint = Endpoint(string: "mac.tail1234.ts.net")
        let merged = try store.save(away)

        #expect(merged.lastGoodEndpoint == Endpoint(string: "mac.tail1234.ts.net"))
        #expect(merged.endpointsToTry(from: .offLink).first == Endpoint(string: "mac.tail1234.ts.net"))
    }

    /// …but a record that learned nothing must not erase what was known.
    @Test("a merge with no winner of its own keeps the stored one")
    func mergeKeepsTheOldWinnerWhenItLearnedNothing() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        var first = peer(endpoints: ["mac.local"])
        first.lastGoodEndpoint = Endpoint(string: "mac.local")
        try store.save(first)

        let merged = try store.save(peer(endpoints: ["10.0.0.5"]))
        #expect(merged.lastGoodEndpoint == Endpoint(string: "mac.local"))
    }

    /// The bug this pins: `~/.bleat` is the console tool's location, and on iOS
    /// `NSHomeDirectory()` is the app container's **read-only root**. A real
    /// pairing got all the way through — key installed on the host, proven by a
    /// second handshake, enrollment key deleted — and then failed to write the
    /// record with `NSCocoaErrorDomain 513`, leaving a key on the host the
    /// phone had no memory of.
    @Test("an app's peers live under Application Support, not in the home directory")
    func applicationSupportIsNotTheHomeDirectory() throws {
        let url = PeerRegistry.applicationSupport().fileURL
        let support = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        #expect(url.path.hasPrefix(support.path))
        #expect(url.deletingLastPathComponent().lastPathComponent == "Bleat")
        // The shape that fails: a dot-directory straight off the home root.
        #expect(!url.path.contains("/.bleat/"))
    }

    /// Writing has to create the directory it was pointed at — on a fresh
    /// install nothing under Application Support exists yet.
    @Test("the first save creates the directory it needs")
    func createsItsDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PeerRegistry(url: directory.appendingPathComponent("Bleat/peers.json"))
        try store.save(peer())
        #expect(try store.all().count == 1)
    }

    /// Both write-backs happen on the same successful connection, one after the
    /// other. Recording the herdr path by saving an edited copy of a peer
    /// loaded earlier would merge a stale `lastGoodEndpoint` over the winner
    /// just written — so it is a targeted mutation instead.
    @Test("recording a herdr path does not undo the endpoint just recorded")
    func herdrPathDoesNotClobberTheEndpoint() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        var stale = peer(endpoints: ["mac.local", "10.0.0.5"])
        stale.lastGoodEndpoint = Endpoint(string: "mac.local")
        try store.save(stale)

        let winner = try #require(Endpoint(string: "10.0.0.5"))
        try store.recordSuccess(endpoint: winner, forHostKey: stale.hostKey)
        try store.recordHerdrPath("/opt/homebrew/bin/herdr", forHostKey: stale.hostKey)

        let loaded = try #require(try store.peer(hostKey: stale.hostKey))
        #expect(loaded.lastGoodEndpoint == winner)
        #expect(loaded.herdrPath == "/opt/homebrew/bin/herdr")
    }

    /// Runs after every status read, and nearly every one says what the last
    /// one did — so it has to be able to say "nothing changed" without a write.
    @Test("what a host says it is is laid over what was known, and only written when it changed")
    func hostInfoIsLaidOver() throws {
        let (store, directory) = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        var paired = peer(endpoints: ["mac.local", "10.0.0.5"])
        paired.lastGoodEndpoint = Endpoint(string: "10.0.0.5")
        try store.save(paired)
        #expect(try store.peer(hostKey: paired.hostKey)?.hostInfo == nil)

        let first = HostInfo(system: "macOS 27.0.1", kernel: "Darwin 27.0.0", model: "Mac14,2")
        #expect(try store.recordHostInfo(first, forHostKey: paired.hostKey))
        #expect(try !store.recordHostInfo(first, forHostKey: paired.hostKey))
        // A reply that had nothing in it, and one missing what the last had.
        #expect(try !store.recordHostInfo(HostInfo(), forHostKey: paired.hostKey))
        #expect(try store.recordHostInfo(
            HostInfo(system: "macOS 27.1", herdrVersion: "0.9.3"), forHostKey: paired.hostKey
        ))

        let loaded = try #require(try store.peer(hostKey: paired.hostKey))
        #expect(loaded.hostInfo == HostInfo(
            system: "macOS 27.1", kernel: "Darwin 27.0.0", model: "Mac14,2", herdrVersion: "0.9.3"
        ))
        #expect(loaded.lastGoodEndpoint == paired.lastGoodEndpoint)
        #expect(try !store.recordHostInfo(first, forHostKey: "ssh-ed25519 nobody"))
    }

    /// A re-pair is built from a QR, which says nothing about the machine.
    @Test("pairing again keeps what the host said it is")
    func repairKeepsHostInfo() throws {
        var known = peer(endpoints: ["mac.local"])
        known.hostInfo = HostInfo(system: "macOS 27.0.1")
        let merged = try known.merging(peer(endpoints: ["10.0.0.5"]))
        #expect(merged.hostInfo == known.hostInfo)
    }
}
