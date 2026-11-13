import BleatKit
import Foundation
import Observation

/// A host's terminals on the watch, asked of the phone every few seconds
/// while the screen is up.
///
/// **Asked, not followed.** The phone's list subscribes to events on its own
/// `hc connect`; a watch cannot hold a stream through the phone, so it calls
/// `terminal.list` again (plan, question 18). Five seconds is quick enough to
/// see an agent stop and slow enough not to keep the phone busy.
@Observable
final class RelayedTerminalsModel {
    enum Phase: Equatable {
        case loading
        case live
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// Live terminals on this host, most urgent first.
    private(set) var terminals: [HcTerminal] = []

    private let call: RelayedCall
    /// Told about a failure, so a dead connection is dropped.
    private let report: (any Error) async -> Void

    static let interval = Duration.seconds(5)

    init(call: @escaping RelayedCall, report: @escaping (any Error) async -> Void = { _ in }) {
        self.call = call
        self.report = report
    }

    convenience init(peer: PairedPeer, connections: ConnectionStore) {
        self.init(call: connections.relayedCall(for: peer), report: { await connections.handle($0) })
    }

    /// Asks until cancelled: the view's task.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.interval)
        }
    }

    func refresh() async {
        do {
            let reply = try await call("terminal.list", [:])
            // Mirrors of federated machines are left out, as on the phone:
            // those machines are paired on their own.
            terminals = HcTerminal.list(inReply: reply).filter { $0.isLocal && $0.isLive }.sortedByAttention()
            phase = .live
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            phase = .failed(ErrorMessage.of(error))
            await report(error)
        }
    }
}
