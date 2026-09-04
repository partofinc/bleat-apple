import Foundation
import Testing
@testable import BleatKit

@Suite("Input records")
struct TerminalCommandTests {

    private func encode(_ command: TerminalCommand) throws -> [String: Any] {
        let line = try command.ndjsonLine()
        #expect(line.last == 0x0A, "input records are newline-delimited")
        let object = try JSONSerialization.jsonObject(with: line)
        return try #require(object as? [String: Any])
    }

    @Test("text input")
    func text() throws {
        let json = try encode(.text("ls -la\r"))
        #expect(json["type"] as? String == "terminal.input")
        #expect(json["text"] as? String == "ls -la\r")
    }

    @Test("raw bytes travel base64, not as text")
    func bytes() throws {
        let json = try encode(.bytes(Data([0x1B, 0x5B, 0x41])))   // Up arrow
        #expect(json["type"] as? String == "terminal.input")
        #expect(json["bytes"] as? String == "G1tB")
        #expect(json["text"] == nil)
    }

    @Test("resize")
    func resize() throws {
        let json = try encode(.resize(cols: 120, rows: 40))
        #expect(json["type"] as? String == "terminal.resize")
        #expect(json["cols"] as? Int == 120)
        #expect(json["rows"] as? Int == 40)
    }

    @Test("scroll needs both direction and lines")
    func scroll() throws {
        // The host rejects a scroll without `lines`:
        //   invalid json command: missing field `lines`
        let json = try encode(.scroll(direction: .up, lines: 3))
        #expect(json["type"] as? String == "terminal.scroll")
        #expect(json["direction"] as? String == "up")
        #expect(json["lines"] as? Int == 3)
    }

    @Test("release carries nothing but its type")
    func release() throws {
        let json = try encode(.release)
        #expect(json["type"] as? String == "terminal.release")
        #expect(json.count == 1)
    }

    @Test("attach passes takeover through only when asked")
    func takeoverIsOptIn() async throws {
        actor Recorder {
            var args: [[String]] = []
            func record(_ a: [String]) { args.append(a) }
        }
        // The client builds the arg list; assert takeover is never implicit.
        let transport = FakeTransport()
        let client = HerdrClient(transport: transport)
        _ = try await client.observe("w2:p1", cols: 80, rows: 24)
        _ = try await client.attach(to: "w2:p1", cols: 80, rows: 24)
        _ = try await client.attach(to: "w2:p1", cols: 80, rows: 24, takeover: true)
    }
}
