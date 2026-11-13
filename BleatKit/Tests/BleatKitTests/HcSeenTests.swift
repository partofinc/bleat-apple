import Foundation
import Testing
@testable import BleatKit

/// herdr-app's `docs/labels.md`, as `HcSeen` follows it.
@Suite("Marking a terminal seen")
struct HcSeenTests {
    private func terminal(turn: Int?, seen: String? = nil, state: String = "live") throws -> HcTerminal {
        var record: [String: Any] = ["address": "t5", "state": state]
        if let turn { record["turn"] = turn }
        if let seen { record["labels"] = ["herdr.seen": seen] }
        return try JSONDecoder().decode(HcTerminal.self, from: JSONSerialization.data(withJSONObject: record))
    }

    @Test("a missing label is written, so terminals started elsewhere join")
    func missing() throws {
        var seen = HcSeen()
        #expect(seen.turnToWrite(for: try terminal(turn: 0)) == 0)
    }

    @Test("only to raise it")
    func raises() throws {
        var seen = HcSeen()
        #expect(seen.turnToWrite(for: try terminal(turn: 5, seen: "5")) == nil)
        #expect(seen.turnToWrite(for: try terminal(turn: 5, seen: "7")) == nil)
        #expect(seen.turnToWrite(for: try terminal(turn: 5, seen: "4")) == 5)
    }

    /// So a "mark unread" from another client is not overruled by a screen
    /// left on.
    @Test("once per turn in one look; a new look writes again")
    func oncePerTurn() throws {
        var seen = HcSeen()
        #expect(seen.turnToWrite(for: try terminal(turn: 5)) == 5)
        #expect(seen.turnToWrite(for: try terminal(turn: 5, seen: "4")) == nil)
        #expect(seen.turnToWrite(for: try terminal(turn: 6, seen: "4")) == 6)
        var again = HcSeen()
        #expect(again.turnToWrite(for: try terminal(turn: 6, seen: "5")) == 6)
    }

    @Test("a failed write is tried again")
    func failed() throws {
        var seen = HcSeen()
        #expect(seen.turnToWrite(for: try terminal(turn: 2)) == 2)
        seen.failed(2)
        #expect(seen.turnToWrite(for: try terminal(turn: 2)) == 2)
    }

    @Test("nothing for a finished terminal or one with no turn")
    func nothing() throws {
        var seen = HcSeen()
        #expect(seen.turnToWrite(for: try terminal(turn: 2, state: "finished")) == nil)
        #expect(seen.turnToWrite(for: try terminal(turn: nil)) == nil)
    }

    @Test("the request sets the label as a string")
    func params() {
        #expect(HcSeen.params(address: "t5", turn: 12) == [
            "terminal": .string("t5"), "labels": .object(["herdr.seen": .string("12")]),
        ])
    }
}
