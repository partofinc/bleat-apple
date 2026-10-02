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
/// so the connection is also closed a few seconds after its last command.
///
/// **Background time is held twice over, and not as one span.** The system
/// would otherwise suspend the app the moment a reply was sent, with the SSH
/// session still up on somebody's Mac. Each command holds a task of its own
/// for as long as it runs, and the wait after the last one holds another. One
/// task from the first command to the end of the wait would run out under a
/// watch that keeps asking, and the only thing its expiry could do is close
/// the connection under a command in flight.
public final class WatchRelayHost: NSObject {
    private let peers: PeerStore
    private let connections: ConnectionStore
    private var responder: RelayResponder?

    /// Commands running now. The idle clock starts when the last one ends, so
    /// a slow command is not cut off by a timer that began when it did.
    private var inFlight = 0
    private var idle: Task<Void, Never>?
    /// The background task held while the idle clock runs.
    private var lingering = UIBackgroundTaskIdentifier.invalid
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
        stopIdleClock()
        let awake = holdAwake("Bleat watch command")
        let reply = await responder.reply(to: request)
        inFlight -= 1
        // The clock takes its own hold before this command gives up its, so
        // there is no moment with neither.
        if inFlight == 0 { startIdleClock() }
        letSleep(awake)
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
        stopIdleClock()
        let awake = holdAwake("Bleat watch linger") { [weak self] in
            // Out of time while nothing was running: close now. The hold ends
            // as this returns, so the close is started rather than waited for.
            guard let self else { return }
            self.lingering = .invalid
            self.idle?.cancel()
            self.idle = nil
            Task { await self.connections.release() }
        }
        lingering = awake
        idle = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled, let self else { return }
            await self.connections.release()
            // A command that arrived during the close has already ended this
            // hold and taken one of its own; ending it again would end theirs.
            guard self.lingering == awake else { return }
            self.lingering = .invalid
            self.letSleep(awake)
        }
    }

    private func stopIdleClock() {
        idle?.cancel()
        idle = nil
        letSleep(lingering)
        lingering = .invalid
    }

    /// Holds the app awake until `letSleep`. The system calls `onExpiry` on
    /// the main thread if it runs out of patience first, and the hold ends
    /// there and then — it has to, before that call returns.
    private func holdAwake(
        _ name: String,
        onExpiry: @escaping @MainActor () -> Void = {}
    ) -> UIBackgroundTaskIdentifier {
        var held = UIBackgroundTaskIdentifier.invalid
        held = UIApplication.shared.beginBackgroundTask(withName: name) {
            onExpiry()
            UIApplication.shared.endBackgroundTask(held)
        }
        return held
    }

    private func letSleep(_ held: UIBackgroundTaskIdentifier) {
        guard held != .invalid else { return }
        UIApplication.shared.endBackgroundTask(held)
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
