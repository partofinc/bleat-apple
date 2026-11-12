#if canImport(UIKit)
import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// The stores on a device that reaches its hosts through another — the watch
/// — with a closure standing where WatchConnectivity would be.
@Suite("Stores on a relayed device")
@MainActor
struct RelayedStoreTests {

    /// The phone, as far as the store can tell: keeps what it was asked and
    /// answers every command with `ok`.
    private nonisolated final class Phone: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [RelayRequest] = []
        private var failure: RelayFailure?
        var asked: [RelayRequest] { lock.withLock { log } }

        func fail(with failure: RelayFailure?) { lock.withLock { self.failure = failure } }

        var channel: RelayTransport.Channel {
            { [self] data in
                let request = try JSONDecoder().decode(RelayRequest.self, from: data)
                let failure = lock.withLock {
                    log.append(request)
                    return self.failure
                }
                return try JSONEncoder().encode(
                    failure.map(RelayReply.failed) ?? RelayReply.output(Data("ok".utf8))
                )
            }
        }
    }

    private func stores(_ phone: Phone) -> (ConnectionStore, PeerStore) {
        let peers = PeerStore(registry: .sample())
        peers.reload()
        return (ConnectionStore(peers: peers, reachability: Reachability(), relay: phone.channel), peers)
    }

    @Test("a command goes to the phone, and nothing is dialled or recorded here")
    func commandsGoThroughTheChannel() async throws {
        let phone = Phone()
        let (connections, peers) = stores(phone)
        let before = peers.peers
        let peer = PairedPeer.preview

        #expect(try await connections.shell(for: peer).run(shell: "uname") == "ok")
        #expect(phone.asked == [.shell(hostKey: peer.hostKey, command: "uname")])
        #expect(connections.isConnected(to: peer))
        // No address won a race, because there was no race; and nothing was
        // written back to the record, which is the phone's to keep.
        #expect(connections.endpoint == nil)
        #expect(peers.peers == before)
    }

    @Test("leaving the host tells the phone to close what it opened")
    func releaseIsSent() async throws {
        let phone = Phone()
        let (connections, _) = stores(phone)
        let peer = PairedPeer.preview

        _ = try await connections.shell(for: peer)
        await connections.release()
        #expect(phone.asked == [.release(hostKey: peer.hostKey)])
        #expect(!connections.isConnected(to: peer))
    }

    @Test("a connection the phone lost is a new one the next time, so a reading is not carried over")
    func transportFailureEndsTheConnection() async throws {
        let phone = Phone()
        let (connections, _) = stores(phone)
        let peer = PairedPeer.preview

        _ = try await connections.shell(for: peer)
        let first = connections.connectionID(for: peer)
        phone.fail(with: .transport(.channelClosed))
        do {
            _ = try await connections.shell(for: peer).run(shell: "uname")
            Issue.record("expected the command to fail")
        } catch {
            #expect(error as? TransportError == .channelClosed)
            await connections.handle(error)
        }
        #expect(connections.connectionID(for: peer) == nil)

        phone.fail(with: nil)
        _ = try await connections.shell(for: peer)
        #expect(connections.connectionID(for: peer) != first)
    }

    /// Closing the old connection is the suspension the race lived in: here
    /// it is the `.release` sent to the phone. Both callers used to find no
    /// connection and no dial in flight there, and each installed its own —
    /// the first overwritten without being closed. On a phone that is an SSH
    /// session left open on the host.
    @Test("two screens asking for another host at once share one connection")
    func concurrentCallersShareOneDial() async throws {
        let phone = Phone()
        let (connections, _) = stores(phone)
        let old = PairedPeer.preview
        let new = PairedPeer.previewSparse

        _ = try await connections.shell(for: old)
        let before = try #require(connections.connectionID(for: old))
        async let list = connections.link(for: new)
        async let load = connections.shell(for: new)
        _ = try await (list, load)
        #expect(connections.connectionID(for: new) == before + 1)

        await connections.release()
        #expect(phone.asked == [.release(hostKey: old.hostKey), .release(hostKey: new.hostKey)])
    }

    /// The host was reached and said no: dropping the connection for that
    /// would make every retry pay for a new one.
    @Test("a command the host refused does not end the connection")
    func refusalKeepsTheConnection() async throws {
        let phone = Phone()
        let (connections, _) = stores(phone)
        let peer = PairedPeer.preview
        let refusal = ShellError(command: "uname", exitCode: 1, stderr: "no")

        phone.fail(with: .shell(refusal))
        do {
            _ = try await connections.shell(for: peer).run(shell: "uname")
            Issue.record("expected the command to fail")
        } catch {
            #expect(error as? ShellError == refusal)
            await connections.handle(error)
        }
        #expect(connections.isConnected(to: peer))
    }

    @Test("the phone's records replace the watch's, host for host")
    func mirror() {
        let peers = PeerStore(registry: .sample())
        peers.reload()
        #expect(peers.peers.count > 1)

        var kept = PairedPeer.preview
        kept.name = "renamed on the phone"
        peers.mirror([kept])
        #expect(peers.peers == [kept])

        peers.mirror([])
        #expect(peers.peers.isEmpty)
    }

    @Test("an empty list from the phone empties a copy no screen has loaded yet")
    func mirrorBeforeTheFirstLoad() {
        // No `reload()`: this is the watch app launching, with the phone's
        // copy arriving before the host list has read the file.
        let peers = PeerStore(registry: .sample())
        #expect(peers.peers.isEmpty)
        peers.mirror([])
        peers.reload()
        #expect(peers.peers.isEmpty)
    }

    @Test("what the watch records about a host is also sent to the phone")
    func upstream() {
        let peers = PeerStore(registry: .sample())
        peers.reload()
        var sent: [PeerNote] = []
        peers.upstream = { _, note in sent.append(note) }
        let peer = PairedPeer.preview

        peers.recordHostInfo(HostInfo(system: "an OS nobody has reported"), for: peer)
        // The same report again changes nothing, so it is not sent again.
        peers.recordHostInfo(HostInfo(system: "an OS nobody has reported"), for: peer)

        #expect(sent == [.hostInfo(HostInfo(system: "an OS nobody has reported"))])
    }

    @Test("a note from the watch lands in the phone's record without going back out")
    func applyNote() throws {
        let peers = PeerStore(registry: .sample())
        peers.reload()
        var sent: [PeerNote] = []
        peers.upstream = { _, note in sent.append(note) }
        let hostKey = PairedPeer.preview.hostKey

        let info = HostInfo(system: "an OS the phone had not heard of")
        peers.apply(.hostInfo(info), forHostKey: hostKey)
        let stored = try #require(peers.peers.first { $0.hostKey == hostKey })
        #expect(stored.hostInfo?.system == info.system)
        #expect(sent.isEmpty)
    }

    @Test("a reply survives packing, whether or not it shrinks")
    func packing() {
        let prose = Data(String(repeating: "the agent is waiting for an answer. ", count: 400).utf8)
        let packed = WatchWire.pack(prose)
        #expect(packed.count < prose.count / 4)
        #expect(WatchWire.unpack(packed) == prose)

        // Too short to deflate: sent as it is, behind the same leading byte.
        let short = Data("ok".utf8)
        #expect(WatchWire.pack(short) == Data([0]) + short)
        #expect(WatchWire.unpack(WatchWire.pack(short)) == short)

        #expect(WatchWire.unpack(Data()) == nil)
        #expect(WatchWire.unpack(Data([7, 1, 2])) == nil)
    }
}
#endif
