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

    @Test("line breaks are kept, as one kind", arguments: ["one\ntwo", "one\r\ntwo", "one\rtwo", "\none\ntwo\n"])
    func lineBreaks(raw: String) throws {
        let line = try #require(SubmittedLine(raw))
        #expect(line.text == "one\ntwo")
        #expect(line.isMultiline)
    }

    @Test("one line is its text, then Enter, whatever the mode")
    func oneLine() throws {
        let line = try #require(SubmittedLine("echo hi"))
        let enter = Data([0x0D])
        #expect(line.records(bracketedPaste: false) == [Data("echo hi".utf8), enter])
        #expect(line.records(bracketedPaste: true) == [Data("echo hi".utf8), enter])
    }

    /// Measured: zsh ran both lines, and Claude Code took them as one prompt.
    @Test("several lines go as one bracketed paste where the program takes one")
    func paste() throws {
        let line = try #require(SubmittedLine("first\n\nsecond"))
        #expect(line.records(bracketedPaste: true) == [
            Data("\u{1B}[200~first\n\nsecond\u{1B}[201~".utf8), Data([0x0D]),
        ])
    }

    /// A newline is Enter to a program reading a line at a time: sent bare,
    /// it would submit the first line and type the rest into whatever came
    /// next.
    @Test("several lines become one line of spaces where it does not")
    func flattened() throws {
        let line = try #require(SubmittedLine("one\n\ntwo  \nthree"))
        #expect(line.records(bracketedPaste: false) == [Data("one two   three".utf8), Data([0x0D])])
    }

    @Test("a paste's end marker inside the text cannot end it early")
    func injectedEnd() throws {
        let line = try #require(SubmittedLine("a\n\u{1B}[201~rm -rf x\nb"))
        let paste = String(decoding: try #require(line.records(bracketedPaste: true).first), as: UTF8.self)
        #expect(paste == "\u{1B}[200~a\nrm -rf x\nb\u{1B}[201~")
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
