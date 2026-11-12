import Foundation
import Testing
@testable import BleatKit

/// A composed line. What goes on the wire — the text, then Enter, in one
/// ordered batch — is `HcPaneModel.submit`'s, tested in `HcPaneModelTests`.
@Suite("Submitted lines")
struct SubmittedLineTests {

    @Test("a line keeps its text, trimmed")
    func text() throws {
        #expect(try #require(SubmittedLine("  echo hi ")).text == "echo hi")
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
        #expect(Data(line.text.utf8) == Data("say “héllo” 👋".utf8))
    }
}
