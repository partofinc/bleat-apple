import Foundation
import Testing
@testable import BleatKit

/// A composed line, as the records the host receives.
@Suite("Submitted lines")
struct SubmittedLineTests {

    private func payloads(_ line: SubmittedLine) throws -> [Data] {
        try line.commands.map { command in
            let json = try JSONSerialization.jsonObject(
                with: Data(String(decoding: try command.ndjsonLine(), as: UTF8.self).dropLast().utf8)
            ) as? [String: Any]
            #expect(json?["type"] as? String == "terminal.input")
            return try #require(Data(base64Encoded: json?["bytes"] as? String ?? ""))
        }
    }

    /// The shape that was measured: the text, then a carriage return, each in
    /// its own record.
    @Test("a line is its text and then Enter")
    func textThenEnter() throws {
        let line = try #require(SubmittedLine("echo hi"))
        #expect(try payloads(line) == [Data("echo hi".utf8), Data([0x0D])])
    }

    /// A newline is Enter to the program reading it, so one inside the text
    /// would submit the first half and type the second into whatever came next.
    @Test("line breaks become spaces", arguments: ["one\ntwo", "one\r\ntwo", "one\n\ntwo\n"])
    func lineBreaks(raw: String) throws {
        #expect(SubmittedLine(raw)?.text == "one two")
    }

    /// A bare Enter commits an agent's dialog. It must not be reachable by
    /// sending nothing.
    @Test("nothing typed is nothing sent", arguments: ["", "   ", "\n", " \n "])
    func empty(raw: String) {
        #expect(SubmittedLine(raw) == nil)
    }

    @Test("text beyond ASCII survives")
    func unicode() throws {
        let line = try #require(SubmittedLine("say “héllo” 👋"))
        #expect(try payloads(line).first == Data("say “héllo” 👋".utf8))
    }
}
