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
    /// The connection the list follows, while it is live. Starting a terminal
    /// asks on it rather than dialling another: framed, it takes requests
    /// while it carries the subscription.
    private var client: HcClient?

    let peer: PairedPeer
    private let connections: ConnectionStore

    init(peer: PairedPeer, connections: ConnectionStore) {
        self.peer = peer
        self.connections = connections
    }

    /// Connects, subscribes, and follows until cancelled or the connection
    /// ends. Never throws: how it ended is `phase`.
    func run() async {
        phase = .connecting
        guard let hcPath = peer.herdrCore?.path else {
            phase = .failed("this host has not been checked for herdr-core")
            return
        }
        do {
            let link = try await connections.link(for: peer)
            guard let opener = link as? any HcStreamOpening else {
                phase = .failed("herdr-core is not reachable this way yet")
                return
            }
            let stream = try await opener.openHcConnection(hcPath: hcPath)
            try await withTaskCancellationHandler {
                try await follow(stream)
            } onCancel: {
                Task { await stream.close() }
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(ErrorMessage.of(error))
            if case HcProtocolError.closed = error {
                // The stream ended without an error, which is how a dead SSH
                // connection can look from here. `handle` keeps the connection
                // for anything but a `TransportError`, so Try Again would reuse
                // the same dead link; dropping it makes the retry dial afresh.
                await connections.release()
            } else {
                await connections.handle(error)
            }
        }
    }

    private func follow(_ stream: any DuplexStream) async throws {
        let client = try await HcClient.connect(over: stream)
        self.client = client
        defer {
            // Only if it is still this run's. A run replaced by Try Again or a
            // return to the foreground can end after the next one connected,
            // and clearing unconditionally left a live list whose + did
            // nothing until the next reconnect.
            if self.client === client { self.client = nil }
            Task { await client.close() }
        }
        coreVersion = await client.hello?.version
        let subscription = try await client.subscribe()
        var set = HcTerminalSet()
        set.reset(to: subscription.snapshot)
        publish(set)
        phase = .live
        for try await notification in subscription.notifications {
            switch notification {
            case .event(let params):
                if set.apply(event: params) { publish(set) }
            case .missed(let snapshot):
                set.reset(to: snapshot)
                publish(set)
            case .heartbeat, .other:
                continue
            }
        }
        // The stream ended without an error: the host closed it.
        if !Task.isCancelled { throw HcProtocolError.closed }
    }

    private func publish(_ set: HcTerminalSet) {
        terminals = set.listed
    }

    // MARK: - Starting a terminal

    /// The host's templates, or none: a host without any, or a core that
    /// cannot list them, offers the shell and a command.
    func templates() async -> [HcTemplate] {
        guard let client else { return [] }
        guard let reply = try? await client.call("templates.list") else { return [] }
        return HcTemplate.list(inReply: reply)
    }

    /// Herdr.app's spaces on this host; none on a core Herdr.app never wrote
    /// to. A core that cannot answer (`needs_update`, `unavailable`, the list
    /// reconnecting) throws, so the form can say so.
    func spaces() async throws -> [HerdrSpace] {
        guard let client, phase == .live else { throw HcProtocolError.closed }
        return HerdrSpace.list(inReply: try await client.call("doc.get", ["name": .string(HerdrSpace.documentName)]))
    }

    /// Starts a terminal and returns its address. The list shows it from the
    /// `created` event, as it would one started on the Mac.
    func start(_ request: HcRunRequest) async throws -> String {
        guard let client, phase == .live else { throw HcProtocolError.closed }
        return try HcRunRequest.address(inReply: try await client.call("terminal.run", request.params))
    }

    /// A shell on the host, for the questions starting a terminal asks first.
    func shell() async throws -> any ShellRunner {
        try await connections.shell(for: peer)
    }
}

// Here, not beside the protocol: a class's Sendable conformance must be
// declared in its own file.
extension TerminalsModel: TerminalStarting {}
