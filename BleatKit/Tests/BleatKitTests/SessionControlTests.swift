import Foundation
import Testing
@testable import BleatKit

/// Stopping and deleting a session, and the record of which sessions this
/// phone is allowed to do that to.
///
/// The replies are the host's own, captured from herdr 0.9.0 into `Fixtures/`
/// rather than written from memory — which matters more here than usual,
/// because the delete reply says something that is not true.
@Suite("Stopping and deleting a session")
struct SessionControlTests {

    private func decode(_ name: String) throws -> SessionChange {
        try JSONDecoder().decode(SessionChange.self, from: Fixture.data(name))
    }

    @Test("the stop reply decodes, and says the session is no longer running")
    func stopReply() throws {
        let change = try decode("session-stop.json")
        #expect(change.stopped == true)
        #expect(change.deleted == nil)
        #expect(change.session.name == "bleatfix")
        #expect(change.session.running == false)
    }

    @Test("the delete reply decodes")
    func deleteReply() throws {
        let change = try decode("session-delete.json")
        #expect(change.deleted == true)
        #expect(change.stopped == nil)
        #expect(change.session.name == "bleatfix")
    }

    /// **The reason `deleted` must never be read as "it is gone".** Measured
    /// against the live host: `herdr session delete nosuchsession --json`
    /// answers exactly this shape with `deleted: true` and exits 0, having
    /// removed nothing and not even created the directory it names. Same class
    /// of lie as a removal from `authorized_keys` exiting 0 when it matched
    /// nothing, and it takes the same answer — read the list back.
    @Test("a delete reply is not evidence that anything was deleted")
    func deleteReplyProvesNothing() throws {
        let invented = #"{"deleted":true,"session":{"default":false,"name":"nosuchsession","running":false}}"#
        let change = try JSONDecoder().decode(SessionChange.self, from: Data(invented.utf8))
        #expect(change.deleted == true, "the host really does answer this for a session it never had")
    }

    /// herdr refuses to delete a running session, which is why the UI offers
    /// Stop *or* Delete and never both. Its refusal is the unenveloped
    /// client-side error shape, on stderr with a non-zero exit.
    @Test("deleting a running session is refused, with a reason worth showing")
    func refusalIsReadable() throws {
        let stderr = try Fixture.data("session-delete-running.json")
        let error = HerdrError.fromStderr(
            command: ["session", "delete"], exitCode: 1, stderr: stderr
        )
        #expect(error.code == "session_delete_failed")
        #expect(error.message == "session bleatfix is running; stop it before deleting")
    }

    // MARK: - Which sessions this phone may act on

    private var peer: PairedPeer {
        PairedPeer(
            hostKey: "ssh-ed25519 AAAA", name: "mac", username: "ravil",
            endpoints: [Endpoint(host: "mac.local")]
        )
    }

    /// The guard. A session this install did not start is not ours to end,
    /// however plainly it is listed.
    @Test("a session this phone did not create is not claimed")
    func notOurs() {
        #expect(!peer.createdHere("work"))
    }

    @Test("a session this phone created is claimed")
    func ours() {
        var peer = peer
        peer.createdSessions = ["scratch"]
        #expect(peer.createdHere("scratch"))
        #expect(!peer.createdHere("work"))
    }

    /// **A record written before this shipped has no such key**, and
    /// `PeerRegistry.all()` treats an undecodable file as a hard failure — so
    /// getting this wrong would strand every already-paired host on the next
    /// launch. The synthesized decoder does not apply default values, which is
    /// why the property is an optional rather than a defaulted array.
    @Test("a peer record written before this existed still decodes")
    func oldRecordsStillDecode() throws {
        let old = #"""
        {"hostKey":"ssh-ed25519 AAAA","name":"mac","username":"ravil",
         "endpoints":[{"host":"mac.local","port":22}]}
        """#
        let peer = try JSONDecoder().decode(PairedPeer.self, from: Data(old.utf8))
        #expect(peer.createdSessions == nil)
        #expect(!peer.createdHere("anything"))
    }

    /// A re-pair builds the incoming record straight from a scanned QR, which
    /// carries no sessions. Taking the newer value would make every session
    /// this phone started look like somebody else's and withdraw the actions
    /// from all of them.
    @Test("re-pairing does not forget the sessions this phone started")
    func mergingKeepsTheClaim() throws {
        var mine = peer
        mine.createdSessions = ["scratch", "spare"]
        let fromQR = PairedPeer(
            hostKey: mine.hostKey, name: "mac", username: "ravil",
            endpoints: [Endpoint(host: "100.64.0.1")]
        )
        let merged = try mine.merging(fromQR)
        #expect(merged.createdHere("scratch"))
        #expect(merged.createdHere("spare"))
    }

    @Test("merging unions both sides rather than picking one")
    func mergingUnions() throws {
        var mine = peer
        mine.createdSessions = ["a"]
        var other = peer
        other.createdSessions = ["a", "b"]
        let merged = try mine.merging(other)
        #expect(merged.createdSessions?.sorted() == ["a", "b"], "a name was lost or duplicated")
    }

    // MARK: - The registry

    private func registry() -> PeerRegistry {
        PeerRegistry(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bleat-sessions-\(UUID().uuidString)")
            .appendingPathComponent("peers.json"))
    }

    @Test("a created session is recorded, once")
    func recordsOnce() throws {
        let registry = registry()
        try registry.save(peer)
        try registry.recordCreatedSession("scratch", forHostKey: peer.hostKey)
        try registry.recordCreatedSession("scratch", forHostKey: peer.hostKey)
        #expect(try registry.all().first?.createdSessions == ["scratch"])
    }

    /// **Forgetting on delete is not tidiness.** The name is the only thing
    /// tying a session to this install, so one left behind would be inherited
    /// by the next session of that name — made by whoever is at the Mac — and
    /// hand the phone a Stop action over their work.
    @Test("deleting a session drops the claim on its name")
    func forgetsOnDelete() throws {
        let registry = registry()
        try registry.save(peer)
        try registry.recordCreatedSession("scratch", forHostKey: peer.hostKey)
        try registry.forgetCreatedSession("scratch", forHostKey: peer.hostKey)
        let stored = try registry.all().first
        #expect(stored?.createdHere("scratch") == false)
        #expect(stored?.createdSessions == nil, "an empty list should not linger as an empty array")
    }

    @Test("recording against an unknown host changes nothing")
    func unknownHost() throws {
        let registry = registry()
        try registry.save(peer)
        #expect(try registry.recordCreatedSession("x", forHostKey: "ssh-ed25519 OTHER") == nil)
        #expect(try registry.all().first?.createdSessions == nil)
    }
}
