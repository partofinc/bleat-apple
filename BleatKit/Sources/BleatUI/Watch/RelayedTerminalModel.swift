import BleatKit
import Foundation
import Observation

/// One terminal on the watch: what it says about itself, and the bottom of
/// its screen as text (`terminal.read`), asked again every few seconds.
///
/// **Read, never attached.** The watch has no stream, so it takes no size
/// and types nothing: the Mac's pane is untouched by a look from the wrist.
///
/// **Looking marks it seen**, as on the phone (`HcSeen`): while this screen is
/// up and the watch is raised, each turn read is written to `herdr.seen`.
@Observable
final class RelayedTerminalModel {
    enum Phase: Equatable {
        case loading
        case live
        /// The program ended, or the terminal was removed.
        case ended
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var record: HcTerminal?
    /// The screen's last lines with something on them.
    private(set) var lines: [String] = []

    let address: String
    private let call: RelayedCall
    private let report: (any Error) async -> Void
    private var seen = HcSeen()
    /// Whether the watch is raised (`scenePhase == .active`).
    private var isInFront = true

    static let interval = Duration.seconds(3)
    /// What fits on a watch, more or less; the rest scrolls.
    static let lineCount = 14

    init(address: String, call: @escaping RelayedCall, report: @escaping (any Error) async -> Void = { _ in }) {
        self.address = address
        self.call = call
        self.report = report
    }

    convenience init(peer: PairedPeer, address: String, connections: ConnectionStore) {
        self.init(address: address, call: connections.relayedCall(for: peer), report: { await connections.handle($0) })
    }

    /// Asks while the watch is raised; lowered, it waits, so an always-on
    /// screen does not keep the phone and the Mac's SSH session busy.
    func run() async {
        while !Task.isCancelled, phase != .ended {
            if isInFront { await refresh() }
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// Raised or lowered. Raised again is a new look.
    func setInFront(_ inFront: Bool) {
        guard inFront != isInFront else { return }
        isInFront = inFront
        if inFront { seen = HcSeen() }
    }

    func refresh() async {
        do {
            let target: [String: HcJSON] = ["terminal": .string(address)]
            // Side by side: two round trips through the phone, not one after
            // the other.
            async let got = call("terminal.get", target)
            async let read = call("terminal.read", target.merging(["lines": .number(0)]) { $1 })
            let record = try await got.decode(HcTerminal.self)
            self.record = record
            guard record.isLive else {
                _ = try? await read
                phase = .ended
                return
            }
            lines = try HcScreenText(reply: try await read).lastLines(Self.lineCount)
            phase = .live
            await markSeen(record)
        } catch let error as HcError where error.kind == "not_found" {
            phase = .ended
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            phase = .failed(ErrorMessage.of(error))
            await report(error)
        }
    }

    private func markSeen(_ record: HcTerminal) async {
        guard isInFront, let turn = seen.turnToWrite(for: record) else { return }
        do {
            _ = try await call("terminal.label", HcSeen.params(address: address, turn: turn))
        } catch {
            seen.failed(turn)
        }
    }
}
