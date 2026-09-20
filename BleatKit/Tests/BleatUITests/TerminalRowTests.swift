import BleatKit
import Foundation
import Testing
@testable import BleatUI

/// When a terminal row draws its directory underneath the title.
///
/// The rule is small and was wrong twice, in both directions: a suffix test
/// hid a directory that was worth showing, and it failed to hide the one case
/// every phone-started session produces.
@Suite("Terminal row")
struct TerminalRowTests {

    private func pane(title: String?, cwd: String?) throws -> Pane {
        var fields = ["\"pane_id\":\"w2:p3\"", "\"workspace_id\":\"w2\"", "\"tab_id\":\"w2:t1\"",
                      "\"agent_status\":\"unknown\"", "\"focused\":false"]
        if let title { fields.append("\"terminal_title_stripped\":\"\(title)\"") }
        if let cwd { fields.append("\"foreground_cwd\":\"\(cwd)\"") }
        return try JSONDecoder().decode(Pane.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    @Test("an idle shell's title is its directory, so the path is not repeated")
    func titledWithItsOwnDirectory() throws {
        let shell = try pane(
            title: "ravil@rawillkair:~/Developer/autorq/link-apple",
            cwd: "/Users/ravil/Developer/autorq/link-apple"
        )
        #expect(TerminalRow.directory(for: shell) == nil)
    }

    /// The case the first version missed, and the one that matters most: a
    /// session the phone starts holds a single workspace in the SSH user's
    /// home, where the shell titles itself `~` and the path shares no name
    /// with it.
    @Test("a shell in the home directory says it with a tilde")
    func home() throws {
        let shell = try pane(title: "ravil@rawillkair:~", cwd: "/Users/ravil")
        #expect(TerminalRow.directory(for: shell) == nil)
    }

    @Test("a running command is not the directory, so the path is shown")
    func runningCommand() throws {
        let running = try pane(title: "swift test", cwd: "/Users/ravil/Developer/rawillk/bleat-apple")
        #expect(TerminalRow.directory(for: running) == "/Users/ravil/Developer/rawillk/bleat-apple")
    }

    /// The false positive a plain suffix test had: the command's last word is
    /// the directory's name without being the directory.
    @Test("a command ending in the directory's name is still a command")
    func commandThatEndsWithTheDirectoryName() throws {
        let running = try pane(title: "git log", cwd: "/var/log")
        #expect(TerminalRow.directory(for: running) == "/var/log")
    }

    @Test("an untitled pane falls back to its id, and keeps its path")
    func untitled() throws {
        let untitled = try pane(title: nil, cwd: "/Users/ravil/Developer")
        #expect(untitled.displayTitle == "w2:p3")
        #expect(TerminalRow.directory(for: untitled) == "/Users/ravil/Developer")
    }

    @Test("a pane the host gave no directory for shows none")
    func noDirectory() throws {
        #expect(TerminalRow.directory(for: try pane(title: "zsh", cwd: nil)) == nil)
    }
}
