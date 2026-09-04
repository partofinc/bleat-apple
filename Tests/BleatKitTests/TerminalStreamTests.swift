import Foundation
import Testing
@testable import BleatKit

@Suite("Terminal stream")
struct TerminalStreamTests {

    /// The one real frame captured from a live pane.
    private func capturedFrame() throws -> Data {
        try Fixture.data("terminal-observe.ndjson")
    }

    @Test("a captured frame decodes and yields untouched ANSI bytes")
    func decodeFrame() throws {
        let line = try capturedFrame()
        guard case .frame(let frame) = try JSONDecoder().decode(TerminalRecord.self, from: line) else {
            Issue.record("expected a terminal.frame"); return
        }
        #expect(frame.encoding == "ansi")
        #expect(frame.full)                 // the replay sent on attach
        #expect(frame.width == 80)
        #expect(frame.height == 24)
        #expect(frame.seq == 1)

        let bytes = try #require(frame.data)
        // Escape sequences must survive verbatim: BleatKit never interprets them.
        #expect(bytes.first == 0x1B)
        #expect(bytes.count > 1000)
    }

    @Test("records reassemble across arbitrary chunk boundaries")
    func chunkedReassembly() async throws {
        var line = try capturedFrame()
        if line.last != 0x0A { line.append(0x0A) }
        // Three frames split into 64-byte reads — nothing lands on a boundary.
        let feed = line + line + line
        var chunks: [Data] = []
        var offset = 0
        while offset < feed.count {
            let end = min(offset + 64, feed.count)
            chunks.append(Data(feed[offset..<end]))
            offset = end
        }
        #expect(chunks.count > 3)

        let stream = FakeStream(chunks: chunks)
        var seen = 0
        for try await record in stream.records {
            guard case .frame = record else { Issue.record("unexpected record"); continue }
            seen += 1
        }
        #expect(seen == 3)
    }

    @Test("unknown record types do not break the stream")
    func unknownRecord() async throws {
        let feed = Data(#"{"type":"terminal.bell"}"# .utf8) + Data("\n".utf8)
        let stream = FakeStream(chunks: [feed])
        var types: [String] = []
        for try await record in stream.records {
            if case .unknown(let type) = record { types.append(type) }
        }
        #expect(types == ["terminal.bell"])
    }

    @Test("blank lines are skipped")
    func blankLines() throws {
        var splitter = NDJSONSplitter()
        let lines = try splitter.push(Data("\n\n{\"type\":\"x\"}\n\n".utf8))
        #expect(lines.count == 1)
        #expect(splitter.pending.isEmpty)
    }

    @Test("a record with no newline stays pending")
    func pendingRecord() throws {
        var splitter = NDJSONSplitter()
        #expect(try splitter.push(Data("{\"type\":".utf8)).isEmpty)
        #expect(splitter.pending.count == 8)
        let lines = try splitter.push(Data("\"x\"}\n".utf8))
        #expect(lines.count == 1)
        #expect(splitter.pending.isEmpty)
    }

    @Test("a stream that never sends a newline is cut off, not grown forever")
    func oversized() throws {
        var splitter = NDJSONSplitter(byteLimit: 1024)
        #expect(throws: TransportError.oversizedRecord(limit: 1024)) {
            _ = try splitter.push(Data(repeating: 0x41, count: 2048))
        }
    }
}
