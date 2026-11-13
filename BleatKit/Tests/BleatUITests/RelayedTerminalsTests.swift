import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// The watch's terminal screens, against herdr-core replies captured live
/// (`Fixtures/hc-terminal-list.json`, `hc-terminal-read.json`), with the
/// phone's relay replaced by a script.
@Suite("Terminals on the watch")
@MainActor
struct RelayedTerminalsTests {

    private static func fixture(_ name: String) throws -> HcJSON {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(name)")
        return try JSONDecoder().decode(HcJSON.self, from: Data(contentsOf: url))["result"] ?? .null
    }

    /// Plays the phone: answers each call, and keeps what was asked.
    final class Script {
        var calls: [(method: String, params: [String: HcJSON])] = []
        var record: HcJSON = .object(["address": .string("t5s"), "state": .string("live"), "turn": .number(4)])
        var failure: (any Error)?

        func call(_ method: String, _ params: [String: HcJSON]) throws -> HcJSON {
            calls.append((method, params))
            if let failure { throw failure }
            switch method {
            case "terminal.list": return try RelayedTerminalsTests.fixture("hc-terminal-list.json")
            case "terminal.get": return record
            case "terminal.read": return try RelayedTerminalsTests.fixture("hc-terminal-read.json")
            default: return .object([:])
            }
        }

        var seenWrites: [String] {
            calls.filter { $0.method == "terminal.label" }.compactMap { $0.params["labels"]?["herdr.seen"]?.string }
        }
    }

    @Test("the list is the host's live terminals, most urgent first")
    func list() async {
        let script = Script()
        let model = RelayedTerminalsModel(call: { try script.call($0, $1) })
        await model.refresh()
        #expect(model.phase == .live)
        // t5s is done and not yet seen (seen 41, turn 43); t6g is a plain shell.
        #expect(model.terminals.map(\.address) == ["t5s", "t6g"])
    }

    @Test("a failure is said, in the error's words")
    func listFails() async {
        let script = Script()
        script.failure = TransportError.connectionFailed("the iPhone is not reachable")
        let model = RelayedTerminalsModel(call: { try script.call($0, $1) })
        await model.refresh()
        guard case .failed = model.phase else {
            Issue.record("expected failed, got \(model.phase)")
            return
        }
    }

    @Test("a terminal shows its record and the bottom of its screen, and is marked seen once")
    func terminal() async {
        let script = Script()
        let model = RelayedTerminalModel(address: "t5s", call: { try script.call($0, $1) })
        await model.refresh()
        #expect(model.phase == .live)
        #expect(model.record?.address == "t5s")
        #expect(model.lines.last == "sh-3.2$")
        #expect(script.calls.first { $0.method == "terminal.read" }?.params["lines"] == .number(0))
        #expect(script.seenWrites == ["4"])
        await model.refresh()
        #expect(script.seenWrites == ["4"], "once per turn per look")
    }

    @Test("a lowered watch marks nothing; raised again it does")
    func lowered() async {
        let script = Script()
        let model = RelayedTerminalModel(address: "t5s", call: { try script.call($0, $1) })
        model.setInFront(false)
        await model.refresh()
        #expect(script.seenWrites.isEmpty)
        model.setInFront(true)
        await model.refresh()
        #expect(script.seenWrites == ["4"])
    }

    /// From review: an always-on watch kept the phone and the Mac's SSH
    /// session busy for screens nobody was reading.
    @Test("a lowered watch stops asking")
    func pausedWhenLowered() async throws {
        let script = Script()
        let list = RelayedTerminalsModel(call: { try script.call($0, $1) })
        let terminal = RelayedTerminalModel(address: "t5s", call: { try script.call($0, $1) })
        list.setInFront(false)
        terminal.setInFront(false)
        let running = Task {
            async let a: Void = list.run()
            async let b: Void = terminal.run()
            _ = await (a, b)
        }
        try await Task.sleep(for: .milliseconds(200))
        running.cancel()
        #expect(script.calls.isEmpty)
    }

    @Test("a terminal that finished or was removed has ended")
    func ended() async {
        let script = Script()
        script.record = .object(["address": .string("t5s"), "state": .string("finished"), "turn": .number(4)])
        let finished = RelayedTerminalModel(address: "t5s", call: { try script.call($0, $1) })
        await finished.refresh()
        #expect(finished.phase == .ended)
        #expect(script.seenWrites.isEmpty)

        let gone = Script()
        gone.failure = HcError(code: -32000, message: "no terminal t5s", kind: "not_found")
        let removed = RelayedTerminalModel(address: "t5s", call: { try gone.call($0, $1) })
        await removed.refresh()
        #expect(removed.phase == .ended)
    }
}
