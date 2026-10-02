#if os(watchOS)
import BleatKit
import Foundation
import WatchConnectivity

/// The watch's line to the phone: where commands go out, and where the list of
/// paired hosts comes in.
///
/// **Everything the watch shows comes through here**, because watchOS gives an
/// ordinary app no direct connection of its own — see `RelayRequest`. A command
/// is a message with a reply, which wakes Bleat on the phone if it is not
/// running; the hosts arrive as the session's application context, which the
/// system keeps and hands over even when the phone is out of reach.
public final class WatchLink: NSObject {
    private weak var peers: PeerStore?

    /// Carries one request to the phone. Handed to `ConnectionStore`.
    public nonisolated let channel: RelayTransport.Channel = { request in
        let session = WCSession.default
        try await WatchLink.waitForActivation(of: session)
        guard session.isReachable else {
            throw TransportError.connectionFailed(
                "the iPhone is out of reach — Bleat on the watch connects through it"
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessageData(request) { reply in
                // Bytes that do not unpack are passed on as they came, and
                // `RelayTransport` reports them as a reply it could not read.
                continuation.resume(returning: WatchWire.unpack(reply) ?? reply)
            } errorHandler: { error in
                continuation.resume(throwing: TransportError.connectionFailed(
                    "the iPhone did not answer: \(error.localizedDescription)"
                ))
            }
        }
    }

    public override init() {
        super.init()
    }

    /// Opens the session and keeps `peers` in step with the phone from then on.
    public func start(mirroringInto peers: PeerStore) {
        self.peers = peers
        // A change that starts on the watch has to arrive even if the phone
        // is out of reach right now, and nobody is waiting on an answer. Sent
        // as a message while the phone can be reached — it is there at once,
        // before the next copy of the hosts is — and queued with the system
        // when it cannot, or when the message fails.
        peers.upstream = { hostKey, note in
            guard let data = try? JSONEncoder().encode(RelayRequest.note(hostKey: hostKey, note)) else {
                return
            }
            WatchLink.send(note: data)
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Asks the phone for its hosts now, which also wakes it. The application
    /// context covers every later change; this covers a phone that has not run
    /// Bleat since the watch app was installed and so has sent nothing yet.
    public func refreshPeers() async {
        guard case .peers(let incoming)? = try? await RelayTransport.send(.peers, over: channel) else {
            return
        }
        peers?.mirror(incoming)
    }

    /// **`nonisolated`, and that is what keeps the app alive.** The system
    /// calls a message's reply and error handlers on a queue of its own. A
    /// closure written inside main-actor code is taken to be main-actor code,
    /// and Swift 6 checks that on entry — so the first version, which passed
    /// these from the `upstream` closure, trapped in `dispatch_assert_queue`
    /// the moment the phone answered a note. It reached the simulator: opening
    /// a host recorded what the host is, and the watch app died.
    private nonisolated static func send(note data: Data) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            session.transferUserInfo([WatchWire.request: data])
            return
        }
        session.sendMessageData(data, replyHandler: { _ in }, errorHandler: { _ in
            WCSession.default.transferUserInfo([WatchWire.request: data])
        })
    }

    /// Activation is asynchronous and the first screen asks at once.
    private nonisolated static func waitForActivation(of session: WCSession) async throws {
        for _ in 0..<50 where session.activationState != .activated {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard session.activationState == .activated else {
            throw TransportError.connectionFailed("the link to the iPhone did not open")
        }
    }

    private func mirror(_ context: [String: Any]) {
        guard let incoming = WatchWire.peers(from: context) else { return }
        peers?.mirror(incoming)
    }
}

extension WatchLink: WCSessionDelegate {
    public nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        // The dictionary is property-list values; only the decoded peers cross.
        let incoming = WatchWire.peers(from: session.receivedApplicationContext)
        Task { @MainActor in
            if let incoming { self.peers?.mirror(incoming) }
            await self.refreshPeers()
        }
    }

    public nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let incoming = WatchWire.peers(from: applicationContext) else { return }
        Task { @MainActor in self.peers?.mirror(incoming) }
    }
}
#endif
