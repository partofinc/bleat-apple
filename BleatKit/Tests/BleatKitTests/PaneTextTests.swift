import Foundation
import Testing
@testable import BleatKit

@Suite("Reading a pane as plain text")
struct PaneTextTests {

    /// Straight off the host: `herdr pane read w5:p1 --source recent-unwrapped
    /// --format text --lines 60`, captured 6 Sept 2026 — the same 142-column
    /// pane the sizing work was measured against.
    @Test("the fixture decodes to the lines the host printed")
    func decodesTheFixture() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: [Self.command: try Fixture.data("pane-read.txt")]
        ))
        let lines = try await client.paneText(target: "w5:p1", lines: 60)

        #expect(!lines.isEmpty)
        // Box-drawing survives the decode. If UTF-8 were mishandled this is
        // where it would show, since the screen is mostly table borders.
        #expect(lines.contains { $0.contains("│") })
    }

    /// The exact argv, because every part of it is load-bearing and none of it
    /// is checked at compile time. `--format text` is what strips the escape
    /// sequences; without `--source recent-unwrapped` the host defaults to
    /// `recent`, which does not unwrap a shell's long echoed line.
    @Test("it asks for unwrapped text, not the default source")
    func asksForUnwrappedText() async throws {
        let transport = FakeTransport(
            responses: [Self.command: try Fixture.data("pane-read.txt")]
        )
        let client = HerdrClient(transport: transport)
        // FakeTransport throws on any command it was not given, so reaching
        // this line at all is the assertion.
        _ = try await client.paneText(target: "w5:p1", lines: 60)
    }

    /// `pane_id` is already the full target. Joining the workspace on again
    /// gives `w2:w2:p1` and the host answers `pane_not_found` — the mistake
    /// `Agent.target` exists to stop, and this command takes the same argument.
    @Test("a wrong target reaches the host as a HerdrError")
    func aWrongTargetFails() async throws {
        let client = HerdrClient(transport: FakeTransport(
            responses: [Self.command: try Fixture.data("pane-read.txt")]
        ))
        await #expect(throws: HerdrError.self) {
            _ = try await client.paneText(target: "w5:w5:p1", lines: 60)
        }
    }

    /// The payload ends in a newline and a terminal's bottom rows are usually
    /// blank. In a scroll view anchored to the bottom that is empty space where
    /// the newest output should be — the reader would open showing nothing.
    @Test("trailing blank lines are dropped")
    func dropsTrailingBlanks() {
        let lines = PaneText.lines(from: Data("one\ntwo\n\n   \n\n".utf8))
        #expect(lines == ["one", "two"])
    }

    /// Kept, because they are the paragraph breaks — an agent's prose is
    /// separated by them and collapsing them runs every reply together.
    @Test("interior blank lines are kept")
    func keepsInteriorBlanks() {
        let lines = PaneText.lines(from: Data("one\n\ntwo\n".utf8))
        #expect(lines == ["one", "", "two"])
    }

    /// Not seen from this herdr, and cheap to be right about: a stray `\r`
    /// renders as a blank glyph at the end of every line.
    @Test("CRLF does not leave a carriage return on each line")
    func handlesCRLF() {
        #expect(PaneText.lines(from: Data("one\r\ntwo\r\n".utf8)) == ["one", "two"])
    }

    /// `--lines N` cuts at a line boundary, but the screen is full of
    /// box-drawing characters and the reader must not vanish over one bad byte.
    @Test("invalid UTF-8 costs a glyph, not the snapshot")
    func decodingIsTotal() {
        var data = Data("ok\n".utf8)
        data.append(contentsOf: [0xE2, 0x94])  // a truncated box-drawing char
        let lines = PaneText.lines(from: data)
        #expect(lines.first == "ok")
        #expect(lines.count == 2)
    }

    private static let command =
        "pane read w5:p1 --source recent-unwrapped --format text --lines 60"
}
