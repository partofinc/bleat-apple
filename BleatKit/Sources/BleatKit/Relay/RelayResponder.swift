import Foundation

/// The phone's half of the relay: takes one encoded `RelayRequest`, does it,
/// and returns the encoded `RelayReply`.
///
/// Closures rather than the stores themselves, so the half that decides what a
/// request means is tested here with no connection and no WatchConnectivity,
/// and the half that owns the SSH connection stays in the app.
public struct RelayResponder: Sendable {
    /// A live connection to the host with this key, dialling if needed.
    /// Throws `RelayFailure.unknownPeer` for a host that is not paired.
    public var link: @Sendable (_ hostKey: String) async throws -> any PeerLink
    public var peers: @Sendable () async -> [PairedPeer]
    public var release: @Sendable (_ hostKey: String) async -> Void
    public var note: @Sendable (_ hostKey: String, PeerNote) async -> Void
    /// Told about an error a command threw, so a dead connection is dropped
    /// rather than asked again. `ConnectionStore.handle` on the phone.
    public var failed: @Sendable (any Error) async -> Void

    public init(
        link: @escaping @Sendable (_ hostKey: String) async throws -> any PeerLink,
        peers: @escaping @Sendable () async -> [PairedPeer],
        release: @escaping @Sendable (_ hostKey: String) async -> Void,
        note: @escaping @Sendable (_ hostKey: String, PeerNote) async -> Void,
        failed: @escaping @Sendable (any Error) async -> Void
    ) {
        self.link = link
        self.peers = peers
        self.release = release
        self.note = note
        self.failed = failed
    }

    public func reply(to request: Data) async -> Data {
        let reply: RelayReply
        do {
            reply = try await answer(try JSONDecoder().decode(RelayRequest.self, from: request))
        } catch is DecodingError {
            reply = .failed(.other("the watch sent a request this iPhone could not read; update Bleat on both"))
        } catch {
            await failed(error)
            reply = .failed(RelayFailure(error))
        }
        // Encoding these cannot fail: every payload is strings and data.
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    private func answer(_ request: RelayRequest) async throws -> RelayReply {
        switch request {
        case .peers:
            return .peers(await peers())
        case .herdr(let hostKey, let args, let session):
            return .output(try await link(hostKey).run(args, inSession: session))
        case .shell(let hostKey, let command):
            return .output(Data(try await link(hostKey).run(shell: command).utf8))
        case .release(let hostKey):
            await release(hostKey)
            return .output(Data())
        case .note(let hostKey, let note):
            await self.note(hostKey, note)
            return .output(Data())
        }
    }
}
