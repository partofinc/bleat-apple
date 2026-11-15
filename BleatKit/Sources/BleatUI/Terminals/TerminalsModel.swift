import BleatKit
import Observation

/// One host's live terminals, from a herdr-core subscription.
///
/// **One `hc connect` per screen, on the shared SSH connection.** The exec
/// channel rides the connection `ConnectionStore` already holds, so opening
/// the list costs a channel, not a handshake. Events replace polling: the
/// snapshot fills the list and every change after it is applied as it comes.
///
/// `run()` lasts as long as the view's task. Cancelling it closes the stream,
/// which is also what unblocks a handshake still waiting for `hello` — without
/// that, leaving the screen mid-connect would leave the channel open on the
/// host.
///
/// **It reconnects by itself** while the app is in front (`inForeground`):
/// a stream that ends, or a connection that drops, is dialled again after a
/// short wait, a few times, before the list says it failed. Found on a phone
/// on adam, 14 Nov 2026: the list had lost its stream, and the new-terminal
/// sheet said "the connection to herdr-core closed" until Try Again.
@Observable
final class TerminalsModel {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    /// Live terminals on this host, most urgent first.
    private(set) var terminals: [HcTerminal] = []
    /// What `hello` said, for the screen to show beside the host's name.
    private(set) var coreVersion: String?
    /// Whether the app is in front (active or inactive), which is when a
    /// lost list may be dialled again by itself. Set by the view from its scene phase: in the
    /// background iOS takes the socket and `RootView` releases the
    /// connection, and dialling then would only fight it.
    var inForeground = true

    /// The connection the list follows, while it is live: the hc client, and
    /// the SSH connection it rides. Starting a terminal asks on both rather
    /// than dialling another: framed, the client takes requests while it
    /// carries the subscription, and the shell is the same connection.
    private var session: Session?

    private struct Session {
        let client: HcClient
        let shell: any ShellRunner
    }

    /// What one connect opened: the hc stream, and the connection under it.
    struct Opened {
        let stream: any DuplexStream
        let shell: any ShellRunner
    }

    let peer: PairedPeer
    private let open: () async throws -> Opened
    /// Told of an error that may mean the connection itself is finished
    /// (`ConnectionStore.handle`).
    private let handle: (any Error) async -> Void
    /// Drops the shared connection, so the next open dials afresh.
    private let release: () async -> Void
    /// The waits before each reconnect; once they are spent the list fails.
    private let retryDelays: [Duration]
    /// How long a list must stay live to earn its retries back.
    private let steadyLive: Duration
    /// How long a stream may take from opening to its first snapshot.
    private let handshakeLimit: Duration
    /// How long the sheet's questions wait for a reconnecting list.
    private let liveWait: Duration

    convenience init(peer: PairedPeer, connections: ConnectionStore) {
        self.init(
            peer: peer,
            open: {
                let opened = try await connections.openHc(for: peer)
                return Opened(stream: opened.stream, shell: opened.link)
            },
            handle: { await connections.handle($0) },
            release: { await connections.release() }
        )
    }

    init(
        peer: PairedPeer,
        open: @escaping () async throws -> Opened,
        handle: @escaping (any Error) async -> Void,
        release: @escaping () async -> Void,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        steadyLive: Duration = .seconds(10),
        handshakeLimit: Duration = .seconds(10),
        liveWait: Duration = .seconds(15)
    ) {
        self.peer = peer
        self.open = open
        self.handle = handle
        self.release = release
        self.retryDelays = retryDelays
        self.steadyLive = steadyLive
        self.handshakeLimit = handshakeLimit
        self.liveWait = liveWait
    }

    /// Connects, subscribes, and follows until cancelled, reconnecting while
    /// it may. Never throws: how it ended is `phase`.
    func run() async {
        var retries = retryDelays[...]
        // Whether the attempt before this one also ended quietly without
        // going live: see `quietEnd`.
        var endedQuietly = false
        while !Task.isCancelled {
            phase = .connecting
            liveSince = nil
            let error: any Error
            do {
                let opened = try await open()
                try await withTaskCancellationHandler {
                    try await follow(opened)
                } onCancel: {
                    Task { await opened.stream.close() }
                }
                return
            } catch let thrown {
                error = thrown
            }
            guard !Task.isCancelled else { return }
            let wasSteady = liveSince.map { ContinuousClock.now - $0 >= steadyLive } ?? false
            let wentLive = liveSince != nil
            liveSince = nil
            if Self.quietEnd(error) {
                // **Not released on the first** (from review): the
                // connection is shared, and dropping it took an open
                // terminal's stream down with it, once per retry, for a
                // core that had only restarted. A stream that ends quietly
                // twice running without going live is how a dead SSH
                // connection looks, and that one is dropped, so the next
                // open dials afresh rather than reusing it until Try Again.
                if endedQuietly { await release() }
                endedQuietly = !wentLive
            } else {
                endedQuietly = false
                await handle(error)
            }
            // A list that stayed live a while has earned its retries back;
            // one that goes live and drops at once has not (from review), or
            // a core in a crash loop would be retried forever.
            if wasSteady { retries = retryDelays[...] }
            guard inForeground, Self.isWorthRetrying(error), let delay = retries.popFirst() else {
                phase = .failed(ErrorMessage.of(error))
                return
            }
            // `.connecting` while it waits, not still `.live`: the sheet's
            // questions wait for it, and the list keeps what it showed.
            phase = .connecting
            do { try await Task.sleep(for: delay) } catch { return }
            guard inForeground else {
                phase = .failed(ErrorMessage.of(error))
                return
            }
        }
    }

    /// When this run's stream went live; nil while it is not.
    @ObservationIgnored private var liveSince: ContinuousClock.Instant?

    /// The stream ended, or never said hello, without the network saying
    /// anything: a core that restarted, or an SSH connection that died.
    private nonisolated static func quietEnd(_ error: any Error) -> Bool {
        switch error {
        case HcProtocolError.closed, HcProtocolError.noHello, is TerminalListStalled: true
        default: false
        }
    }

    /// Whether another dial could help. Not when the host was reached and
    /// said no, or will say the same again: an old core, a key it refuses, a
    /// changed host key, a host never checked for herdr-core.
    ///
    /// A `CancellationError` is retried (from review): this run's own task
    /// being cancelled returns before here, so one that reaches here is a
    /// dial another screen's `release()` called off under it, the race a
    /// reconnect is for.
    nonisolated static func isWorthRetrying(_ error: any Error) -> Bool {
        switch error {
        case HcProtocolError.closed, HcProtocolError.noHello, is TerminalListStalled, is CancellationError:
            return true
        case let transport as TransportError:
            switch transport {
            case .notConnected, .connectionFailed, .overlayUnreachable, .channelClosed: return true
            case .hostKeyMismatch, .authenticationFailed, .oversizedRecord: return false
            }
        default:
            return false
        }
    }

    private func follow(_ opened: Opened) async throws {
        // **A limit on reaching the first snapshot.** Neither `hello` nor
        // the subscription has one of its own, so a channel that opened and
        // then stayed silent kept the list "connecting" for good. Closing
        // the stream ends both waits; the failure is then a quiet end, and
        // two in a row drop the connection for a fresh dial.
        // Whether it fired: cancelled first, it says false.
        let watchdog = Task { [stream = opened.stream, handshakeLimit] in
            do { try await Task.sleep(for: handshakeLimit) } catch { return false }
            await stream.close()
            return true
        }
        do {
            try await following(opened, live: { watchdog.cancel() })
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            if await watchdog.value { throw TerminalListStalled(limit: handshakeLimit) }
            throw error
        }
    }

    private func following(_ opened: Opened, live: () -> Void) async throws {
        let client = try await HcClient.connect(over: opened.stream)
        session = Session(client: client, shell: opened.shell)
        defer {
            // Only if it is still this run's. A run replaced by Try Again or a
            // return to the foreground can end after the next one connected,
            // and clearing unconditionally left a live list whose + did
            // nothing until the next reconnect.
            if session?.client === client { session = nil }
            Task { await client.close() }
        }
        coreVersion = await client.hello?.version
        let subscription = try await client.subscribe()
        for try await update in subscription.updates {
            publish(update.terminals)
            if liveSince == nil { liveSince = .now; live() }
            phase = .live
        }
        // The stream ended without an error: the host closed it.
        if !Task.isCancelled { throw HcProtocolError.closed }
    }

    private func publish(_ set: HcTerminalSet) {
        terminals = set.listed
    }

    // MARK: - Starting a terminal

    /// The list's session once it is live, waiting while it connects or
    /// reconnects until `deadline` (`liveWait` from now by default), and
    /// never for `stale`: a session whose stream was just seen to close,
    /// which can still be installed for a moment before its run notices.
    ///
    /// **Polled, kept from review**: a continuation resumed where `phase`
    /// changes would wake it once instead of every 100 ms, but it would need
    /// its own cancellation and timeout handling, and this only runs while
    /// the sheet waits on a reconnecting list, for 15 seconds at most.
    private func liveSession(
        not stale: HcClient? = nil, by deadline: ContinuousClock.Instant? = nil
    ) async throws -> Session {
        let deadline = deadline ?? .now + liveWait
        while true {
            if let session, phase == .live, session.client !== stale { return session }
            // A list that failed for good is not coming back by itself.
            if case .failed(let reason) = phase { throw TerminalListUnavailable.failed(reason) }
            guard ContinuousClock.now < deadline else { throw TerminalListUnavailable.reconnecting }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A request that only reads, on the live session. Asked once more on
    /// the next session if the stream closes under it: reading twice is
    /// harmless, and the stream closing is what a reconnect looks like. Both
    /// waits share one deadline (from review), so the sheet waits
    /// `liveWait` in all, not twice that.
    private func read(_ method: String, _ params: [String: HcJSON] = [:]) async throws -> HcJSON {
        let deadline = ContinuousClock.now + liveWait
        let session = try await liveSession(by: deadline)
        do {
            return try await session.client.call(method, params)
        } catch HcProtocolError.closed {
            return try await liveSession(not: session.client, by: deadline).client.call(method, params)
        }
    }

    /// The host's templates, or none: a host without any, or a core that
    /// cannot list them, offers the shell and a command.
    func templates() async -> [HcTemplate] {
        guard let reply = try? await read("templates.list") else { return [] }
        return HcTemplate.list(inReply: reply)
    }

    /// Herdr.app's spaces on this host; none on a core Herdr.app never wrote
    /// to. A core that cannot answer (`needs_update`, `unavailable`, a list
    /// that does not come back) throws, so the form can say so.
    func spaces() async throws -> [HerdrSpace] {
        HerdrSpace.list(inReply: try await read("doc.get", ["name": .string(HerdrSpace.documentName)]))
    }

    /// Starts a terminal and returns its address. The list shows it from the
    /// `created` event, as it would one started on the Mac.
    ///
    /// **Not asked again if the stream closes under it**: the terminal may
    /// have started, and a second would be a second terminal.
    func start(_ request: HcRunRequest) async throws -> String {
        let session = try await liveSession()
        return try HcRunRequest.address(inReply: try await session.client.call("terminal.run", request.params))
    }

    /// A shell on the host, for the questions starting a terminal asks first:
    /// the connection the list's stream rides.
    ///
    /// **Never `ConnectionStore.shell(for:)`** (found on a phone, 14 Nov
    /// 2026): that re-dials when the network has changed since the dial, and
    /// a re-dial closes the connection under the list's stream. The sheet
    /// asked for home that way as it opened, alongside the spaces, and the
    /// spaces read failed with "the connection to herdr-core closed". A
    /// connection that has been dropped refuses commands rather than dialling
    /// again (`SSHTransport.disconnect`), so holding it cannot open one.
    func shell() async throws -> any ShellRunner {
        try await liveSession().shell
    }
}

// Here, not beside the protocol: a class's Sendable conformance must be
// declared in its own file.
extension TerminalsModel: TerminalStarting {}
