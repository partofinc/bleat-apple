#if os(iOS)
import BleatKit
import Foundation
import Observation
import UIKit
import WatchConnectivity

/// The phone's end of the watch's line: runs what the watch asks for, and
/// keeps the watch's list of hosts in step with this phone's.
///
/// **Its own `ConnectionStore`, not the app's.** That store holds one
/// connection, and connecting to a second host closes the first — so a watch
/// asking about one Mac would close the pane somebody has open to another on
/// the phone. The two never share a connection, even to the same host.
///
/// **Nothing is left open on a host for a watch that has gone.** The watch
/// says when it has stopped looking; a watch that walks out of range cannot,
/// so the connection is also closed a few seconds after its last command. A
/// background task holds the app awake for that long — the system would
/// otherwise suspend it the moment the reply was sent, with the SSH session
/// still up on somebody's Mac.
public final class WatchRelayHost: NSObject {
    private let peers: PeerStore
    private let connections: ConnectionStore
    private var responder: RelayResponder?

    /// Commands running now. The idle clock starts when the last one ends, so
    /// a slow command is not cut off by a timer that began when it did.
    private var inFlight = 0
    private var idle: Task<Void, Never>?
    private var background = UIBackgroundTaskIdentifier.invalid
    /// How long a connection opened for the watch outlives its last command.
    /// Longer than a wrist coming back up to the next screen; shorter than the
    /// background time the system allows.
    static let linger = Duration.seconds(15)

    public init(peers: PeerStore, reachability: Reachability) {
        self.peers = peers
        self.connections = ConnectionStore(peers: peers, reachability: reachability)
        super.init()
    }

    /// Opens the session. Call once, at launch — including a launch the system
    /// made in the background to deliver a watch's message, which is why this
    /// is not in a view's `.task`.
    public func start() {
        guard WCSession.isSupported(), responder == nil else { return }
        responder = RelayResponder(
            link: { [weak self] hostKey in
                guard let self else { throw RelayFailure.cancelled }
                return try await self.link(hostKey)
            },
            peers: { [weak self] in await self?.currentPeers() ?? [] },
            release: { [weak self] hostKey in await self?.release(hostKey) },
            note: { [weak self] hostKey, note in await self?.peers.apply(note, forHostKey: hostKey) },
            failed: { [weak self] error in await self?.connections.handle(error) }
        )
        let session = WCSession.default
        session.delegate = self
        session.activate()
        observePeers()
    }

    // MARK: - Answering

    private func answer(_ request: Data) async -> Data {
        guard let responder else { return Data() }
        inFlight += 1
        idle?.cancel()
        holdAwake()
        let reply = await responder.reply(to: request)
        inFlight -= 1
        if inFlight == 0 { startIdleClock() }
        return reply
    }

    private func link(_ hostKey: String) async throws -> any PeerLink {
        guard let peer = peer(hostKey) else { throw RelayFailure.unknownPeer }
        return try await connections.link(for: peer)
    }

    private func peer(_ hostKey: String) -> PairedPeer? {
        if let known = peers.peers.first(where: { $0.hostKey == hostKey }) { return known }
        // A launch in the background has shown no screen, and the host list
        // is what loads the file.
        peers.reload()
        return peers.peers.first { $0.hostKey == hostKey }
    }

    private func currentPeers() -> [PairedPeer] {
        peers.reload()
        return peers.peers
    }

    private func release(_ hostKey: String) async {
        guard let peer = peer(hostKey), connections.isConnected(to: peer) else { return }
        await connections.release()
    }

    // MARK: - Not outstaying the watch

    private func startIdleClock() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled, let self else { return }
            await self.connections.release()
            self.letSleep()
        }
    }

    private func holdAwake() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Bleat watch relay") { [weak self] in
            // Out of time: close now rather than be suspended with it open.
            Task { @MainActor in
                guard let self else { return }
                self.idle?.cancel()
                await self.connections.release()
                self.letSleep()
            }
        }
    }

    private func letSleep() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    // MARK: - The watch's copy of the hosts

    /// Sends the hosts whenever they change — a pairing, an unpairing, a host
    /// reporting what it is.
    private func observePeers() {
        withObservationTracking {
            _ = peers.peers
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.push()
                self?.observePeers()
            }
        }
    }

    private func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(peers.peers)
        else { return }
        // Best effort: the watch also asks for the list itself when it opens.
        try? session.updateApplicationContext([WatchWire.peers: data])
    }
}

extension WatchRelayHost: WCSessionDelegate {
    public nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.peers.reload()
            self.push()
        }
    }

    public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// A different watch was switched to; the session has to be opened again
    /// for it.
    public nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The watch app was installed, or a watch was paired.
    public nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }

    public nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        // The handler is the system's and is called exactly once, from here.
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            reply(WatchWire.pack(await self.answer(messageData)))
        }
    }

    public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let request = userInfo[WatchWire.request] as? Data else { return }
        Task { @MainActor in _ = await self.answer(request) }
    }
}
#endif
