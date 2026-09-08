import Foundation
import Testing
@testable import BleatKit

/// The bytes a page key is, and the record they travel in.
///
/// **Why bytes and not text.** `TerminalCommand.text` puts the string straight
/// into JSON, and a raw ESC is not legal inside a JSON string — the host would
/// answer `input ignored` on stderr and the screen would not move, which is
/// indistinguishable from a program that does not handle the key. `bytes`
/// base64-encodes, so the escape survives.
@Suite("Terminal keys")
struct TerminalKeyTests {

    @Test("page up and page down are the xterm sequences")
    func sequences() {
        #expect(TerminalKey.pageUp.bytes == Data("\u{1B}[5~".utf8))
        #expect(TerminalKey.pageDown.bytes == Data("\u{1B}[6~".utf8))
    }

    /// The record herdr actually receives. An escape sequence has to arrive
    /// base64-encoded, and the line has to be one JSON object with a newline.
    @Test("a key travels as base64 in a terminal.input record")
    func encodesAsBytes() throws {
        let line = try TerminalCommand.bytes(TerminalKey.pageUp.bytes).ndjsonLine()
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.hasSuffix("\n"))

        let object = try JSONSerialization.jsonObject(
            with: Data(text.dropLast().utf8)
        ) as? [String: Any]
        #expect(object?["type"] as? String == "terminal.input")
        #expect(object?["bytes"] as? String == Data("\u{1B}[5~".utf8).base64EncodedString())
        // Never as `text`: that is the form that would carry a raw ESC.
        #expect(object?["text"] == nil)
    }
}
