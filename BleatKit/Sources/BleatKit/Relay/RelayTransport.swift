import Foundation

/// A host reached through another device: every command is sent to the phone,
/// which runs it and sends back what the host said.
///
/// The second `HerdrTransport`. Nothing above it knows — `HerdrClient` is handed
/// this where the phone hands it an `SSHTransport`.
///
/// **There is no pane stream.** A relayed message is one request and one
/// reply, and a terminal is a channel that stays open in both directions;
/// `openStream` throws rather than pretending.
public final class RelayTransport: PeerLink {
    /// Carries one encoded request to the phone and returns its encoded reply.
    ///
    /// Throws a `TransportError` when the phone could not be asked at all.
    public typealias Channel = @Sendable (Data) async throws -> Data

    private let hostKey: String
    private let channel: Channel
    private let sessionBox: LockedBox<String?>

    public init(hostKey: String, session: String? = nil, channel: @escaping Channel) {
        self.hostKey = hostKey
        self.channel = channel
        self.sessionBox = LockedBox(session)
    }

    public func useSession(_ session: String?) {
        sessionBox.withLock { $0 = session }
    }

    public func run(_ args: [String]) async throws -> Data {
        try await run(args, inSession: sessionBox.current)
    }

    public func run(_ args: [String], inSession session: String?) async throws -> Data {
        try await Self.output(of: .herdr(hostKey: hostKey, args: args, session: session), over: channel)
    }

    public func run(shell command: String) async throws -> String {
        let stdout = try await Self.output(of: .shell(hostKey: hostKey, command: command), over: channel)
        return String(decoding: stdout, as: UTF8.self)
    }

    public func openStream(_ args: [String]) async throws -> any HerdrStream {
        throw TransportError.connectionFailed("a pane cannot be opened through the iPhone")
    }

    /// Tells the phone to close what it opened. Best effort: a phone that
    /// cannot be told closes it on its own a few seconds after the last
    /// command — see `RelayResponder`'s caller.
    public func disconnect() async {
        _ = try? await Self.send(.release(hostKey: hostKey), over: channel)
    }

    /// One request and its reply, decoded. A `.failed` reply is thrown as the
    /// error it carries.
    public static func send(_ request: RelayRequest, over channel: Channel) async throws -> RelayReply {
        let reply = try await channel(try JSONEncoder().encode(request))
        guard let decoded = try? JSONDecoder().decode(RelayReply.self, from: reply) else {
            // Not a `DecodingError`: that means herdr's JSON drifted, and this
            // is the two halves of one app disagreeing.
            throw TransportError.connectionFailed(
                "the iPhone sent a reply this watch could not read; update Bleat on both"
            )
        }
        if case .failed(let failure) = decoded { throw failure.error }
        return decoded
    }

    private static func output(of request: RelayRequest, over channel: Channel) async throws -> Data {
        guard case .output(let data) = try await send(request, over: channel) else {
            throw TransportError.connectionFailed("the iPhone sent a reply of the wrong kind")
        }
        return data
    }
}
