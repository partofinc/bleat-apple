import Foundation
import Testing
@testable import BleatKit

/// The bound that was missing from the transcript read.
///
/// `turns` limits how many records come back and the per-record `awk` limits
/// how big any one may be, but **nothing limited the total** — so the payload
/// grew with the conversation. Measured 8 Sept 2026 across three live sessions
/// on the dev Mac, the last 120 turns came to 270KB, 386KB and **676KB**,
/// against the "couple of hundred kilobytes" the command was written for. All
/// of it has to cross one SSH exec channel before the chat can draw anything.
@Suite("The transcript read's byte budget")
struct TranscriptBudgetTests {

    private func command(budget: Int = 131_072) throws -> String {
        try #require(TranscriptCommand.read(
            sessionID: "0f7a74a0-560a-490e-8b83-b70930263a4a",
            budget: budget
        ))
    }

    @Test("the budget is applied on the host, after the other filters")
    func budgetIsLast() throws {
        let c = try command()
        let perRecord = try #require(c.range(of: "length($0) < 131072"))
        let total = try #require(c.range(of: "max=131072"))
        #expect(perRecord.upperBound < total.lowerBound,
                "the total budget must come after the per-record filter")
        // And after the turn count, or it would bound a list that is then
        // re-expanded.
        let turns = try #require(c.range(of: "tail -n 120"))
        #expect(turns.upperBound < total.lowerBound)
    }

    /// Newest first, because the end of the list is the part nobody scrolls to.
    /// The loop counts down from the last record and stops; `first` is where
    /// printing starts.
    @Test("it counts from the newest record backwards")
    func keepsTheNewest() throws {
        let c = try command()
        #expect(c.contains("for (i = NR; i >= 1; i--)"))
        #expect(c.contains("first = i"))
        #expect(c.contains("for (i = first; i <= NR; i++) print lines[i]"))
    }

    /// `tail -c` would cut a record in half and hand the parser a truncated
    /// line; `tail -r` is BSD-only and this command is meant to survive a Linux
    /// host, which the console tool is planned for.
    @Test("it uses neither tail -c nor tail -r")
    func portableAndLineSafe() throws {
        let c = try command()
        #expect(!c.contains("tail -c"))
        #expect(!c.contains("tail -r"))
        #expect(!c.contains("tac "))
    }

    @Test("the budget is a parameter, not a constant")
    func budgetIsConfigurable() throws {
        #expect(try command(budget: 4096).contains("max=4096"))
    }

    /// The whole command still has to survive the id check, and an id that
    /// fails it must not produce a command at all.
    @Test("an unsafe id still yields nothing")
    func unsafeIDIsRefused() {
        #expect(TranscriptCommand.read(sessionID: "abc; rm -rf /") == nil)
        #expect(TranscriptCommand.read(sessionID: "") == nil)
    }
}
