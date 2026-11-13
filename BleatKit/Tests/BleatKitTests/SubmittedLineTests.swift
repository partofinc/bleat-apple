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

    /// From review: vertical tab and form feed went out raw, and zsh reads
    /// them as Ctrl-K and Ctrl-L.
    @Test("line breaks are kept, as one kind", arguments: [
        "one\ntwo", "one\r\ntwo", "one\rtwo", "\none\ntwo\n",
        "one\u{0B}two", "one\u{0C}two", "one\u{85}two", "one\u{2028}two", "one\u{2029}two",
    ])
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

    /// From review: stripping the end marker once let a nested one rebuild
    /// itself and run the rest as typed keys.
    @Test("no escape survives, so no paste marker can end a paste early", arguments: [
        "a\n\u{1B}[201~rm -rf x\nb",
        "a\n\u{1B}[201\u{1B}[201~~rm -rf x\nb",
    ])
    func injectedEnd(raw: String) throws {
        let line = try #require(SubmittedLine(raw))
        let paste = String(decoding: try #require(line.records(bracketedPaste: true).first), as: UTF8.self)
        #expect(paste.filter { $0 == "\u{1B}" }.count == 2, "only the paste's own markers")
        #expect(paste.hasPrefix("\u{1B}[200~") && paste.hasSuffix("\u{1B}[201~"))
    }

    @Test("control characters go, tab stays", arguments: [("ls\u{07}\u{1B}[A -la", "ls[A -la"), ("a\tb", "a\tb"), ("x\u{7F}y\u{9B}z", "xyz")])
    func controls(raw: String, expected: String) throws {
        #expect(try #require(SubmittedLine(raw)).text == expected)
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
