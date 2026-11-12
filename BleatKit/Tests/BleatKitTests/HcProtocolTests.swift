import Foundation
import Testing
@testable import BleatKit

@Suite("herdr-core: frames, terminals and events")
struct HcProtocolTests {

    // MARK: - Frames

    @Test("a frame is a 9-byte little-endian header and its payload")
    func frameLayout() {
        let bytes = HcFrame(channel: 7, kind: .data, payload: Data("hi".utf8)).encoded()
        #expect(Array(bytes) == [7, 0, 0, 0, 0, 2, 0, 0, 0, 0x68, 0x69])
        #expect(Array(HcFrame.credit(256 * 1024, on: 1).encoded()) == [1, 0, 0, 0, 1, 4, 0, 0, 0, 0, 0, 4, 0])
    }

    /// SSH delivers whatever chunks it likes; a frame split anywhere, or two in
    /// one chunk, must come out whole and in order.
    @Test("frames survive any chunking")
    func chunking() throws {
        let frames = [
            HcFrame(channel: 0, kind: .data, payload: Data(#"{"id":1}"#.utf8)),
            HcFrame(channel: 1, kind: .data, payload: Data("line\n".utf8)),
            HcFrame(channel: 1, kind: .close),
        ]
        let wire = frames.reduce(Data()) { $0 + $1.encoded() }
        for size in [1, 2, 5, 9, 10, wire.count] {
            var decoder = HcFrameDecoder()
            var out: [HcFrame] = []
            var index = wire.startIndex
            while index < wire.endIndex {
                let end = min(index + size, wire.endIndex)
                out += try decoder.push(Data(wire[index..<end]))
                index = end
            }
            #expect(out == frames, "chunks of \(size)")
        }
    }

    @Test("a length past the 16 MiB limit is refused, not allocated")
    func oversized() {
        var header = Data([0, 0, 0, 0, 0])
        header.append(littleEndian: UInt32(HcFrame.maxPayload + 1))
        var decoder = HcFrameDecoder()
        #expect(throws: HcFrameDecoder.Failure.oversized(HcFrame.maxPayload + 1)) { try decoder.push(header) }
    }

    @Test("an unknown kind decodes and is left for the reader to skip")
    func unknownKind() throws {
        var decoder = HcFrameDecoder()
        let frame = try decoder.push(HcFrame(channel: 3, rawKind: 42, payload: Data()).encoded()).first
        #expect(frame?.kind == 42)
        #expect(frame?.knownKind == nil)
    }

    // MARK: - Terminals

    private func snapshot() throws -> HcJSON {
        let reply = try JSONDecoder().decode(HcJSON.self, from: Fixture.data("hc-subscribe.json"))
        return try #require(reply["result"])
    }

    @Test("the captured snapshot reads as terminals, mirrors and finished ones included")
    func capturedSnapshot() throws {
        var set = HcTerminalSet()
        set.reset(to: try snapshot())
        let terminals = set.terminals
        #expect(terminals.count == 5)
        #expect(set.seq == 2488)
        let t58 = try #require(terminals.first { $0.address == "t58" })
        #expect(t58.isLocal && t58.isLive)
        #expect(t58.status?.state == .done)
        #expect(t58.location?.space == "project")
        #expect(t58.location?.tab == "Agent")
        #expect(t58.seenTurn == 16)
        #expect(t58.turn == 16)
        #expect(!t58.isUnseenDone, "seen at the turn it ended on")
        #expect(t58.displayName == "project Backend", "the title, not foreground.name, which is Claude Code's version")
        #expect(terminals.contains { !$0.isLocal }, "adam/t10 is a mirror")
        #expect(terminals.contains { !$0.isLive })
        // What a list shows: the three local live ones, no mirror, nothing finished.
        #expect(Set(set.listed.map(\.address)) == ["t58", "t59", "t5b"])
    }

    /// Captured from a scratch terminal's whole life (hc 0.1.20).
    @Test("captured events take a terminal from created to removed")
    func capturedEvents() throws {
        var set = HcTerminalSet()
        set.reset(to: try snapshot())
        let lines = try Fixture.text("hc-events.ndjson").split(separator: "\n")
        var seen: [String] = []
        for line in lines {
            let message = try JSONDecoder().decode(HcJSON.self, from: Data(line.utf8))
            guard case .event(let params) = HcNotification(message) else { continue }
            set.apply(event: params)
            let scratch = set.terminals.first { $0.address == "t5g" }
            seen.append("\(params["type"]?.string ?? "?"):\(scratch?.state ?? "gone")")
            if params["type"]?.string == "labels" {
                #expect(scratch?.labels?["where"] != nil)
            }
        }
        #expect(seen == [
            "created:live", "labels:live", "foreground:live", "labels:live", "finished:finished", "removed:gone",
        ])
    }

    @Test("an event at or below the set's sequence is already in it")
    func staleEventIgnored() throws {
        var set = HcTerminalSet()
        set.reset(to: try snapshot())
        let stale: HcJSON = .object([
            "type": .string("title"), "terminal": .string("t58"), "seq": .number(2488),
            "data": .object(["title": .string("stale")]),
        ])
        let changed = set.apply(event: stale)
        #expect(!changed)
        #expect(set.terminals.first { $0.address == "t58" }?.title != "stale")
    }

    @Test("each event sets exactly the keys herdr-core's own mirror sets")
    func applyRules() {
        var record: [String: HcJSON] = [
            "state": .string("live"), "pid": .number(10),
            "foreground": .object(["name": .string("zsh")]), "title": .string("old"),
        ]
        HcTerminalSet.apply("lost", data: .object(["reason": .string("lost")]), to: &record)
        #expect(record["state"] == .string("live"))
        #expect(record["pid"] == .null)
        #expect(record["foreground"] == nil)
        HcTerminalSet.apply("status", data: .object(["status": .object(["state": .string("blocked")])]), to: &record)
        #expect(record["status"]?["state"]?.string == "blocked")
        HcTerminalSet.apply("size", data: .object(["cols": .number(80), "rows": .number(24)]), to: &record)
        #expect(record["cols"] == .number(80))
        HcTerminalSet.apply("unheard-of", data: .object(["title": .string("new")]), to: &record)
        #expect(record["title"] == .string("old"))
    }

    @Test("one record that does not read does not empty the list")
    func badRecordSkipped() {
        var set = HcTerminalSet()
        set.reset(to: .object([
            "seq": .number(1),
            "terminals": .array([
                .object(["address": .string("t1"), "state": .string("live")]),
                .object(["address": .string("t2"), "turn": .string("not a number")]),
            ]),
        ]))
        #expect(set.terminals.map(\.address) == ["t1"])
    }

    // MARK: - Attention

    private func terminal(_ address: String, _ state: String?, turn: Int? = nil, seen: Int? = nil) throws -> HcTerminal {
        var json: [String: Any] = ["address": address, "state": "live"]
        if let state { json["status"] = ["state": state] }
        if let turn { json["turn"] = turn }
        if let seen { json["labels"] = ["herdr.seen": String(seen)] }
        return try JSONDecoder().decode(HcTerminal.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("blocked and error first, then done and unseen, then working, then the rest")
    func attentionOrder() throws {
        let sorted = try [
            terminal("t1", nil),
            terminal("t2", "idle"),
            terminal("t3", "done", turn: 5, seen: 5),
            terminal("t4", "working"),
            terminal("t5", "done", turn: 5, seen: 4),
            terminal("t6", "error"),
            terminal("t7", "blocked"),
            terminal("t8", "sleeping"),
        ].sortedByAttention().map(\.address)
        #expect(sorted == ["t6", "t7", "t5", "t4", "t2", "t3", "t8", "t1"])
    }

    @Test("done with nothing recorded as seen counts as unseen")
    func doneNeverSeen() throws {
        #expect(try terminal("t1", "done", turn: 3).isUnseenDone)
        #expect(try !terminal("t1", "working", turn: 3).isUnseenDone)
    }

    @Test("t9 sorts before t10")
    func numericTieBreak() throws {
        let sorted = try [terminal("t10", "idle"), terminal("t9", "idle")].sortedByAttention()
        #expect(sorted.map(\.address) == ["t9", "t10"])
    }
}
