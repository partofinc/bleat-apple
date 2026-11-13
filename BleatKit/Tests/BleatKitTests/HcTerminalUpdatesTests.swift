import Foundation
import Testing
@testable import BleatKit

/// The one loop every subscriber reads a subscription through, fed the
/// events captured from a scratch Claude Code (`Fixtures/hc-turn-events.ndjson`).
@Suite("A subscription as terminal sets")
struct HcTerminalUpdatesTests {
    private func lines() throws -> [HcJSON] {
        try String(decoding: Fixture.data("hc-turn-events.ndjson"), as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(HcJSON.self, from: Data($0.utf8)) }
    }

    @Test("the snapshot first, then a set for each change, with its cause; heartbeats change nothing")
    func updates() async throws {
        let lines = try lines()
        let snapshot = try #require(lines.first?["result"])
        let (stream, feed) = AsyncThrowingStream<HcNotification, any Error>.makeStream()
        for line in lines.dropFirst() { feed.yield(HcNotification(line)) }
        feed.yield(HcNotification(.object(["jsonrpc": .string("2.0"), "method": .string("heartbeat"), "params": .object(["seq": .number(9999)])])))
        feed.finish()

        var causes: [HcTerminalUpdates.Update.Cause] = []
        var last: HcTerminalSet?
        for try await update in HcSubscription(snapshot: snapshot, notifications: stream).updates {
            causes.append(update.cause)
            last = update.terminals
        }
        let address = try #require(last?.terminals.first?.address)
        #expect(causes == [
            .snapshot,
            .event(type: "status", terminal: address),
            .event(type: "title", terminal: address),
            .event(type: "status", terminal: address),
            .event(type: "turn", terminal: address),
            .event(type: "status", terminal: address),
        ])
        #expect(last?.terminals.first?.turn == 1)
        #expect(last?.terminals.first?.status?.state == .done)
    }
}
