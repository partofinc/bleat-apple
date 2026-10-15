import Foundation
import Testing
@testable import BleatKit

@Suite("Trust on first use")
struct KnownHostsTests {

    /// A store in a fresh temp directory, removed when the test ends.
    private func makeStore() -> (KnownHostsStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-tests-\(UUID().uuidString)")
        return (KnownHostsStore(url: directory.appendingPathComponent("known_hosts")), directory)
    }

    @Test("an unseen host is pinned, and the pin survives a reload")
    func pinsOnFirstUse() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try store.pinnedKey(for: "h:22") == nil)
        try store.pin("ssh-ed25519 AAAA", for: "h:22")
        #expect(try store.pinnedKey(for: "h:22") == "ssh-ed25519 AAAA")

        let reopened = KnownHostsStore(url: directory.appendingPathComponent("known_hosts"))
        #expect(try reopened.pinnedKey(for: "h:22") == "ssh-ed25519 AAAA")
    }

    @Test("re-pinning the same key is a no-op, not an error")
    func idempotent() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.pin("k", for: "h:22")
        try store.pin("k", for: "h:22")
        #expect(try store.allEntries().count == 1)
    }

    @Test("a changed key is a hard error and never overwrites the pin")
    func mismatchIsFatal() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.pin("original", for: "h:22")

        #expect(throws: TransportError.hostKeyMismatch(expected: "original", actual: "attacker")) {
            try store.pin("attacker", for: "h:22")
        }
        // The original pin must still stand after the rejection.
        #expect(try store.pinnedKey(for: "h:22") == "original")
    }

    @Test("forgetting a host allows an intentional rekey")
    func forget() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.pin("old", for: "h:22")
        try store.forget("h:22")
        try store.pin("new", for: "h:22")
        #expect(try store.pinnedKey(for: "h:22") == "new")
    }

    @Test("hosts are pinned independently")
    func perHost() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.pin("a", for: "h1:22")
        try store.pin("b", for: "h2:22")
        #expect(try store.pinnedKey(for: "h1:22") == "a")
        #expect(try store.pinnedKey(for: "h2:22") == "b")
    }

    @Test("a missing store reads as empty rather than throwing")
    func missingFile() throws {
        let store = KnownHostsStore(
            url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/known_hosts")
        )
        #expect(try store.allEntries().isEmpty)
        #expect(try store.pinnedKey(for: "anything") == nil)
    }
}

@Suite("Host registry")
struct HostRegistryTests {

    private func makeRegistry() -> (HostRegistry, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-tests-\(UUID().uuidString)")
        return (HostRegistry(url: directory.appendingPathComponent("hosts.json")), directory)
    }

    @Test("saving, listing and removing hosts")
    func roundTrip() throws {
        let (registry, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try registry.all().isEmpty)
        try registry.save(HostEntry(name: "dev", spec: "robin@10.0.0.5", keyPath: "~/.bleat/id_ed25519"))
        try registry.save(HostEntry(name: "box", spec: "robin@box:2222", keyPath: "~/k", session: "work"))

        let entries = try registry.all()
        #expect(entries.map(\.name) == ["box", "dev"])          // sorted
        #expect(try registry.entry(named: "box")?.session == "work")
        #expect(try registry.entry(named: "dev")?.host().port == 22)

        try registry.remove(named: "dev")
        #expect(try registry.all().map(\.name) == ["box"])
    }

    @Test("removing a name that was never saved reports the miss")
    func removeMissing() throws {
        let (registry, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        try registry.save(HostEntry(name: "dev", spec: "a@one", keyPath: "~/k"))

        #expect(try registry.remove(named: "devv") == false)   // typo
        #expect(try registry.remove(named: "dev") == true)
        #expect(try registry.all().isEmpty)
    }

    @Test("removing from a store whose directory does not exist is a no-op")
    func removeWithoutDirectory() throws {
        // `bleat hosts remove` used to throw a raw Cocoa write error here.
        let registry = HostRegistry(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("bleat-missing-\(UUID().uuidString)")
                .appendingPathComponent("hosts.json")
        )
        #expect(try registry.remove(named: "anything") == false)
    }

    @Test("saving the same name replaces rather than duplicates")
    func replaces() throws {
        let (registry, directory) = makeRegistry()
        defer { try? FileManager.default.removeItem(at: directory) }
        try registry.save(HostEntry(name: "dev", spec: "a@one", keyPath: "~/k"))
        try registry.save(HostEntry(name: "dev", spec: "a@two", keyPath: "~/k"))
        #expect(try registry.all().count == 1)
        #expect(try registry.entry(named: "dev")?.spec == "a@two")
    }
}
