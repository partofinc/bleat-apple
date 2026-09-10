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

    /// **The normal-mode arrows, not the application-cursor ones.** A program
    /// that enables DECCKM is sent `ESC O A` by a real terminal rather than
    /// `ESC [ A`, and choosing wrong gives a dialog that ignores every tap —
    /// a failure that looks exactly like the key not being handled at all.
    ///
    /// Settled by measurement rather than by reading: `ESC [ B` was sent over a
    /// real `terminal session control --takeover` to a Claude Code trust dialog
    /// on 10 Sept 2026 and moved its selection. The `O` form is pinned as
    /// *absent* so a later "tidy-up" cannot quietly swap them.
    @Test("the arrows are the normal-mode forms")
    func arrows() {
        #expect(TerminalKey.up.bytes == Data("\u{1B}[A".utf8))
        #expect(TerminalKey.down.bytes == Data("\u{1B}[B".utf8))
        #expect(TerminalKey.right.bytes == Data("\u{1B}[C".utf8))
        #expect(TerminalKey.left.bytes == Data("\u{1B}[D".utf8))

        for key in [TerminalKey.up, .down, .left, .right] {
            #expect(
                key.bytes[key.bytes.startIndex + 1] == 0x5B,
                "application cursor mode (ESC O …) is not what was measured"
            )
        }
    }

    /// The exact base64 that was put on the wire in that measurement, so the
    /// test and the thing that was verified cannot drift apart.
    @Test("down is the payload that moved a real dialog")
    func measuredPayload() {
        #expect(TerminalKey.down.bytes.base64EncodedString() == "G1tC")
    }

    @Test("escape is a bare ESC")
    func escape() {
        #expect(TerminalKey.escape.bytes == Data([0x1B]))
    }

    /// **CR, not LF.** Return sends carriage return on a pty — the line
    /// discipline is what turns it into a newline on the way out — and an
    /// Ink-based TUI like Claude Code reads a bare LF as a newline inside its
    /// composer rather than as a submit. Sending `\n` would type into the
    /// dialog instead of answering it.
    @Test("enter is a carriage return, not a line feed")
    func enter() {
        #expect(TerminalKey.enter.bytes == Data([0x0D]))
        #expect(TerminalKey.enter.bytes != Data([0x0A]))
    }

    /// Every key has to survive the encoding, not just the two that had tests.
    @Test("no key is empty, and all of them encode", arguments: TerminalKey.allCases)
    func allEncode(_ key: TerminalKey) throws {
        #expect(!key.bytes.isEmpty)
        let line = try TerminalCommand.bytes(key.bytes).ndjsonLine()
        let object = try JSONSerialization.jsonObject(
            with: Data(String(decoding: line, as: UTF8.self).dropLast().utf8)
        ) as? [String: Any]
        #expect(object?["bytes"] as? String == key.bytes.base64EncodedString())
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
